// Command probe_range_split tests whether a range that both db-ip and RouteViews
// treat as unitary is in fact geographically split.
//
// # THE HYPOTHESIS
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
// # READING THE RESULT
//
// Three outcomes, and they mean different things:
//
//	Cities and ZIPs vary          the range IS split. Decomposition cannot rely on
//	                              BGP evidence alone.
//	One city, one ZIP, plausible  the range is genuinely unitary, or the provider
//	                              serves it from one location.
//	One city across a huge range   registrant or facility address, not subscriber
//	                              geography. Same signature as the DoD /8s and as
//	                              4.0.0.0/8 resolving to Monroe LA, which is
//	                              Lumen headquarters. Such a range is not
//	                              targetable at any granularity and is a
//	                              candidate for exclusion rather than for
//	                              decomposition.
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
	"context"
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

	"github.com/jackc/pgx/v5"
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
	rangeFlag := flag.String("range", "", "the range to test, as a CIDR, for example 76.90.64.0/20")
	asnFlag := flag.Int("asn", 0, "instead of one range, sample /24s spread across every IPv4 prefix this ASN originates; answers whether a carrier IPv4 space is geographically resolvable at all")
	samples := flag.Int("samples", 16, "how many distinct /24s inside the range to probe")
	rate := flag.Int("rate", 45, "maximum ip-api calls per rolling minute")
	endpoint := flag.String("endpoint", "http://ip-api.com/json/", "ip-api endpoint prefix")
	timeout := flag.Duration("http-timeout", 20*time.Second, "per call timeout")
	flag.Parse()

	if (*rangeFlag == "") == (*asnFlag == 0) {
		log.Fatal("give exactly one of -range or -asn")
	}
	if *samples < 2 {
		log.Fatal("-samples must be at least 2: a single probe cannot show variation")
	}
	if *rate <= 0 {
		log.Fatal("-rate must be greater than zero")
	}

	var chosen []netip.Prefix
	var label string
	total24 := 0

	if *asnFlag != 0 {
		// Carrier mode. The question here is not whether one range is split but
		// whether an entire operator IPv4 space carries any usable geography at
		// all. A mobile carrier translating IPv6-only subscribers through a shared
		// NAT64 pool will answer with the location of the translator, so the whole
		// ASN collapses to a handful of cities however many addresses it holds.
		prefixes, err := prefixesForASN(*asnFlag)
		if err != nil {
			log.Fatalf("reading prefixes for AS%d: %v", *asnFlag, err)
		}
		if len(prefixes) == 0 {
			log.Fatalf("AS%d originates no IPv4 prefixes in bgp_route_views", *asnFlag)
		}
		log.Printf("AS%d originates %d IPv4 prefixes", *asnFlag, len(prefixes))
		rand.Shuffle(len(prefixes), func(i, j int) { prefixes[i], prefixes[j] = prefixes[j], prefixes[i] })
		// One /24 per distinct prefix first, so the sample spreads as widely across
		// the operator footprint as possible before repeating any prefix.
		for i := 0; i < *samples; i++ {
			chosen = append(chosen, randomSubnet24In(prefixes[i%len(prefixes)]))
		}
		label = fmt.Sprintf("AS%d across %d distinct prefixes", *asnFlag, min(len(prefixes), *samples))
		total24 = len(chosen)
	} else {
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
		total24 = len(subnets)
		log.Printf("%s contains %d /24 blocks", parent, len(subnets))
		chosen = subnets
		if len(subnets) > *samples {
			rand.Shuffle(len(subnets), func(i, j int) { subnets[i], subnets[j] = subnets[j], subnets[i] })
			chosen = subnets[:*samples]
			sort.Slice(chosen, func(i, j int) bool { return chosen[i].Addr().Less(chosen[j].Addr()) })
		}
		label = parent.String()
	}
	log.Printf("probing %d blocks at %d calls per minute, roughly %ds", len(chosen), *rate,
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

	report(label, results, total24, *asnFlag != 0)
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

func report(label string, results []sample, total24 int, asnMode bool) {
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
	fmt.Println("=== result for " + label + " ===")
	outf("probes succeeding: %d of %d", ok, len(results))
	if ok == 0 {
		fmt.Println("no successful probes, so nothing can be concluded")
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("cities returned:")
	for _, k := range sortedKeys(cities) {
		outf("  %-40s %d", k, cities[k])
	}
	fmt.Println("ZIPs returned:")
	for _, k := range sortedKeys(zips) {
		outf("  %-40s %d", k, zips[k])
	}
	fmt.Println("ISPs returned:")
	for _, k := range sortedKeys(isps) {
		outf("  %-40s %d", k, isps[k])
	}

	fmt.Println()
	if asnMode {
		// Carrier verdict. The diagnostic quantity is how many distinct places the
		// operator space resolves to, relative to how widely it was sampled.
		switch {
		case len(cities) == 1:
			outf("VERDICT: NON GEOGRAPHIC. Every one of %d probes spread across this operator returned the same city.", ok)
			fmt.Println("That is the signature of a shared translator or gateway pool: the address identifies the carrier")
			fmt.Println("egress point, not the subscriber. Targeting any address in this space by locality is wrong for")
			fmt.Println("almost every subscriber behind it, so including it pollutes output with confidently incorrect rows.")
		case len(cities)*4 <= ok:
			outf("VERDICT: HIGHLY CONCENTRATED. %d distinct cities from %d probes spread across the operator.", len(cities), ok)
			fmt.Println("Consistent with a small number of regional egress gateways rather than per-market addressing.")
			fmt.Println("Usable at region level at best. Check the counts above: a few cities dominating means most")
			fmt.Println("subscribers are being attributed to a gateway city they do not live in.")
		default:
			outf("VERDICT: RESOLVABLE. %d distinct cities and %d distinct ZIPs from %d probes.", len(cities), len(zips), ok)
			fmt.Println("The operator space varies geographically, so per-market attribution is meaningful for it.")
		}
		fmt.Println()
		fmt.Println("Caveat: this measures what ip-api asserts, not where subscribers are. A carrier could be")
		fmt.Println("geographically resolvable in truth while ip-api reports gateways, or the reverse. It answers")
		fmt.Println("whether the data you hold can distinguish markets for this operator, which is the operative question.")
		return
	}

	addresses := total24 * 256
	switch {
	case len(cities) > 1:
		// City variation breaks BOTH services, because the DMA path resolves through
		// city and the ZIP path resolves through it too.
		outf("VERDICT: SPLIT BY CITY. %d distinct cities and %d distinct ZIPs across %d addresses that both db-ip and RouteViews treat as one range.",
			len(cities), len(zips), addresses)
		fmt.Println("This breaks DMA targeting as well as ZIP targeting: assigning one city to the whole range is wrong for part of it,")
		fmt.Println("and BGP evidence alone would never have revealed it. Decomposition must be driven by measurement.")
	case len(zips) > 1:
		// ZIP variation with a constant city is the more interesting case: the DMA
		// service is unaffected, because DMA is resolved through city, while the ZIP
		// service is wrong for part of the range.
		outf("VERDICT: SPLIT BY ZIP ONLY. One city but %d distinct ZIPs across %d addresses.", len(zips), addresses)
		fmt.Println("DMA targeting is unaffected, since that resolves through city. ZIP targeting is wrong for part of this range.")
		fmt.Println("A single range therefore cannot carry one ZIP, which is an argument for landmark-derived ZIPs rather than range-level ones.")
	case total24 >= 256:
		outf("VERDICT: SUSPECT UNITARY. One city and one ZIP across %d addresses.", addresses)
		fmt.Println("A single answer for a range this wide is more likely a registrant or facility address than real subscriber geography.")
		fmt.Println("Compare against the DoD /8s and 4.0.0.0/8 resolving to Monroe LA, which is Lumen headquarters.")
		fmt.Println("Verify from the ISP above that this is an eyeball provider before drawing any conclusion.")
	default:
		outf("VERDICT: UNITARY. One city and one ZIP across %d addresses, at a width where that is plausible.", addresses)
		fmt.Println("No decomposition needed for this range on this evidence.")
	}

	// A partial sample can only ever prove variation, never absence of it. This is
	// not a theoretical caveat: on 76.90.64.0/20, four samples found two ZIPs, eight
	// samples found one and reported UNITARY, and all sixteen found three. The
	// eight-sample run was simply wrong, because 92544 and 92545 occupy three of
	// the sixteen blocks and a random eight missed them.
	if len(results) < total24 {
		fmt.Println()
		outf("SAMPLING CAVEAT: %d of the %d /24 blocks were probed. A verdict of UNITARY from a partial",
			len(results), total24)
		fmt.Println("sample is provisional: minority blocks are easily missed. Re-run with -samples set to the")
		outf("full %d to settle it. Only a verdict of SPLIT is safe to trust from a partial sample.", total24)
	}

	fmt.Println()
	fmt.Println("This tool wrote nothing to the database.")
}

// outf prints a formatted line. It exists so that no format string in this file
// needs a backslash escape: the repository convention is that every file survives
// a copy and paste path that converts backslash sequences into real newlines.
// prefixesForASN reads every IPv4 prefix the ASN originates. Read only.
//
// DATABASE_URL is optional, as everywhere else in this pipeline: when empty, pgx
// falls back to the libpq environment and defaults, so peer authentication over
// the Unix socket works with no credential on disk.
func prefixesForASN(asn int) ([]netip.Prefix, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return nil, err
	}
	defer conn.Close(context.Background())

	rows, err := conn.Query(ctx,
		"SELECT DISTINCT cidr_block FROM bgp_route_views WHERE origin_asn = $1 AND family(cidr_block) = 4", asn)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []netip.Prefix
	for rows.Next() {
		var p netip.Prefix
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p.Masked())
	}
	return out, rows.Err()
}

// randomSubnet24In picks a random /24 inside p. A prefix already /24 or narrower
// is returned as itself, since BGP occasionally carries longer prefixes and there
// is no /24 structure inside them to choose from.
func randomSubnet24In(p netip.Prefix) netip.Prefix {
	if p.Bits() >= 24 {
		return p
	}
	first := p.Addr().As4()
	base := binary.BigEndian.Uint32(first[:])
	blocks := uint32(1) << uint(24-p.Bits())
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], base+uint32(rand.Int31n(int32(blocks)))*256)
	return netip.PrefixFrom(netip.AddrFrom4(b), 24)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func outf(format string, args ...any) {
	fmt.Println(fmt.Sprintf(format, args...))
}

func sortedKeys(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
