// Command probe_range_split tests whether a range that both db-ip and RouteViews
// treat as unitary is in fact geographically split.
//
// THE HYPOTHESIS
//
// apply_splits decomposes a db-ip parent into /24 rows only when BGP shows the
// parent being split by more specific announcements. If a provider serves several
// towns from one announced block without deaggregating it, no evidence of the
// split exists in either source, and the whole range inherits one city. Every
// address in it would then be targeted as that city, which is a false negative for
// every other locality inside it.
//
// This probes several /24s inside one range and reports whether the answers vary.
//
// READING THE RESULT
//
// Three outcomes, and they mean different things:
//
//   Cities and ZIPs vary          the range IS split. Decomposition cannot rely on
//                                 BGP evidence alone.
//   One city, one ZIP, plausible  the range is genuinely unitary, or the provider
//                                 serves it from one location.
//   One city across a huge range   registrant or facility address, not subscriber
//                                 geography. Same signature as the DoD /8s and as
//                                 4.0.0.0/8 resolving to Monroe LA, which is
//                                 Lumen headquarters. Such a range is not
//                                 targetable at any granularity and is a
//                                 candidate for exclusion rather than for
//                                 decomposition.
//
// CHOOSE EYEBALL RANGES. Testing cloud or backbone space answers nothing: AWS
// 3.0.0.0/8 and Lumen 4.0.0.0/8 report facility and headquarters locations. Pick
// ranges belonging to cable, fibre or DSL providers.
//
// This tool is READ ONLY. It writes nothing to the database, so it cannot pollute
// the probe table with /24 rows that the pipeline did not create. It does consume
// ip-api budget, so it honours the same 45 calls per minute ceiling.
//
// Usage:
//
//	probe_range_split -range 76.90.64.0/20
//	probe_range_split -range 68.100.0.0/16 -samples 24
//
// NOTE: contains no backslash escape sequences.
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"net/netip"
	"os"
	"sort"
	"strings"
	"time"
)

type geoResult struct {
	Status     string  `json:"status"`
	Message    string  `json:"message"`
	Country    string  `json:"country"`
	Region     string  `json:"region"`
	RegionName string  `json:"regionName"`
	City       string  `json:"city"`
	Zip        string  `json:"zip"`
	Lat        float64 `json:"lat"`
	Lon        float64 `json:"lon"`
	ISP        string  `json:"isp"`
	Org        string  `json:"org"`
	As         string  `json:"as"`
	Query      string  `json:"query"`
}

type sample struct {
	subnet netip.Prefix
	addr   netip.Addr
	res    geoResult
	err    error
}

func main() {
	rangeFlag := flag.String("range", "", "the range to test, as a CIDR, for example 76.90.64.0/20; required")
	samples := flag.Int("samples", 16, "how many distinct /24s inside the range to probe")
	rate := flag.Int("rate", 45, "maximum ip-api calls per rolling minute")
	endpoint := flag.String("endpoint", "http://ip-api.com/json/", "ip-api endpoint prefix")
	timeout := flag.Duration("http-timeout", 20*time.Second, "per call timeout")
	flag.Parse()

	if *rangeFlag == "" {
		log.Fatal("-range is required, for example -range 76.90.64.0/20")
	}
	if *samples < 2 {
		log.Fatal("-samples must be at least 2: a single probe cannot show variation")
	}
	if *rate <= 0 {
		log.Fatal("-rate must be greater than zero")
	}

	parent, err := netip.ParsePrefix(*rangeFlag)
	if err != nil {
		log.Fatalf("bad -range: %v", err)
	}
	parent = parent.Masked()
	if !parent.Addr().Is4() {
		log.Fatal("only IPv4 ranges can be tested this way: an IPv6 prefix has no enumerable /24 structure")
	}
	if parent.Bits() > 24 {
		log.Fatalf("%s is narrower than a /24, so it has no internal /24 structure to compare", parent)
	}

	subnets := quarterSubnets(parent)
	log.Printf("%s contains %d /24 blocks", parent, len(subnets))

	chosen := subnets
	if len(subnets) > *samples {
		rand.Shuffle(len(subnets), func(i, j int) { subnets[i], subnets[j] = subnets[j], subnets[i] })
		chosen = subnets[:*samples]
		sort.Slice(chosen, func(i, j int) bool { return chosen[i].Addr().Less(chosen[j].Addr()) })
	}
	log.Printf("probing %d of them at %d calls per minute, roughly %ds", len(chosen), *rate,
		(len(chosen)*60)/(*rate)+1)

	client := &http.Client{Timeout: *timeout}
	results := make([]sample, 0, len(chosen))

	windowStart := time.Now()
	inWindow := 0
	for i, sn := range chosen {
		addr := randomAddrIn(sn)
		if inWindow == 0 {
			windowStart = time.Now()
		}
		res, err := lookup(client, *endpoint, addr)
		results = append(results, sample{subnet: sn, addr: addr, res: res, err: err})

		if err != nil {
			log.Printf("[%d/%d] %s ip=%s ERROR %v", i+1, len(chosen), sn, addr, err)
		} else {
			log.Printf("[%d/%d] %s ip=%s status=%s city=%q region=%q zip=%q isp=%q",
				i+1, len(chosen), sn, addr, res.Status, res.City, res.Region, res.Zip, res.ISP)
		}

		inWindow++
		if inWindow >= *rate && i < len(chosen)-1 {
			if elapsed := time.Since(windowStart); elapsed < time.Minute {
				wait := time.Minute - elapsed
				log.Printf("rate limit reached, sleeping %s", wait.Round(time.Second))
				time.Sleep(wait)
			}
			inWindow = 0
		}
	}

	report(parent, results)
}

// quarterSubnets returns every /24 inside p. p is assumed to be a /24 or wider.
func quarterSubnets(p netip.Prefix) []netip.Prefix {
	first := p.Addr().As4()
	base := binary.BigEndian.Uint32(first[:])
	count := 1 << uint(24-p.Bits())
	out := make([]netip.Prefix, 0, count)
	for i := 0; i < count; i++ {
		var b [4]byte
		binary.BigEndian.PutUint32(b[:], base+uint32(i)*256)
		out = append(out, netip.PrefixFrom(netip.AddrFrom4(b), 24))
	}
	return out
}

// randomAddrIn picks an address inside a /24. The network and broadcast addresses
// are included, since usability is determined by the subnet mask rather than by
// the last octet, and a probe of either still returns the provider geography.
func randomAddrIn(p netip.Prefix) netip.Addr {
	first := p.Addr().As4()
	base := binary.BigEndian.Uint32(first[:])
	span := uint32(1) << uint(32-p.Bits())
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], base+uint32(rand.Int31n(int32(span))))
	return netip.AddrFrom4(b)
}

func lookup(client *http.Client, endpoint string, addr netip.Addr) (geoResult, error) {
	url := endpoint + addr.String() + "?fields=status,message,country,region,regionName,city,zip,lat,lon,isp,org,as,query"
	resp, err := client.Get(url)
	if err != nil {
		return geoResult{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return geoResult{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return geoResult{}, fmt.Errorf("ip-api HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var g geoResult
	if err := json.Unmarshal(body, &g); err != nil {
		return geoResult{}, err
	}
	return g, nil
}

func report(parent netip.Prefix, results []sample) {
	cities := map[string]int{}
	zips := map[string]int{}
	isps := map[string]int{}
	ok := 0
	for _, s := range results {
		if s.err != nil || s.res.Status != "success" {
			continue
		}
		ok++
		cities[s.res.City+", "+s.res.Region]++
		if s.res.Zip != "" {
			zips[s.res.Zip]++
		}
		isps[s.res.ISP]++
	}

	fmt.Println()
	fmt.Println("=== result for " + parent.String() + " ===")
	fmt.Printf("probes succeeding: %d of %d\n", ok, len(results))
	if ok == 0 {
		fmt.Println("no successful probes, so nothing can be concluded")
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("cities returned:")
	for _, k := range sortedKeys(cities) {
		fmt.Printf("  %-40s %d\n", k, cities[k])
	}
	fmt.Println("ZIPs returned:")
	for _, k := range sortedKeys(zips) {
		fmt.Printf("  %-40s %d\n", k, zips[k])
	}
	fmt.Println("ISPs returned:")
	for _, k := range sortedKeys(isps) {
		fmt.Printf("  %-40s %d\n", k, isps[k])
	}

	addresses := 1 << uint(32-parent.Bits())
	fmt.Println()
	switch {
	case len(cities) > 1 || len(zips) > 1:
		fmt.Printf("VERDICT: SPLIT. %d distinct cities and %d distinct ZIPs inside a range that both db-ip and RouteViews treat as one.\n",
			len(cities), len(zips))
		fmt.Printf("Assigning one city to all %d addresses is wrong for at least some of them, and BGP evidence alone would never have revealed it.\n", addresses)
		fmt.Println("Implication: decomposition needs to be driven by measurement, not only by observed BGP splits.")
	case parent.Bits() <= 16:
		fmt.Printf("VERDICT: SUSPECT UNITARY. One city and one ZIP across %d addresses.\n", addresses)
		fmt.Println("A single answer for a range this wide is more likely a registrant or facility address than real subscriber geography.")
		fmt.Println("Compare against the DoD /8s and 4.0.0.0/8 resolving to Monroe LA, which is Lumen headquarters.")
		fmt.Println("Such a range is a candidate for exclusion rather than for decomposition. Verify the ISP above is an eyeball provider.")
	default:
		fmt.Printf("VERDICT: UNITARY. One city and one ZIP across %d addresses, at a width where that is plausible.\n", addresses)
		fmt.Println("No decomposition needed for this range on this evidence.")
	}
	fmt.Println()
	fmt.Println("This tool wrote nothing to the database.")
}

func sortedKeys(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
