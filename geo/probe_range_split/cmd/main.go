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
// Without -repeat this tool is READ ONLY. It writes nothing to the database, so it cannot pollute
// the probe table with /24 rows that the pipeline did not create. It does consume
// ip-api budget, so it honours the same 45 calls per minute ceiling.
//
// # STABILITY MODE, AND WHY IT WAS ADDED
//
// Everything above measures whether a range is split ACROSS SPACE. It cannot see
// the other failure, which is a range that changes answer ACROSS TIME.
//
// 172.56.54.0/24 was measured at /28 twice. The first run returned three Los
// Angeles ZIPs. Later runs returned Dallas 75237 for all sixteen /28s, twice in
// succession. Nothing in the pipeline noticed, and nothing could have: ran_at
// records when a range was measured, but no second measurement is ever taken, so
// an answer that stops being true stays in the output indefinitely.
//
// -repeat probes the SAME addresses repeatedly and stores every observation in
// probe_stability_tbl, so drift becomes a measured quantity. The addresses are
// fixed for the life of a cohort, which is the crux of the design: with a fresh
// random address each round, a changed city could mean either that the block moved
// or that two hosts inside it are in different places, and nothing afterwards
// could separate those. A cohort label can be re-used to add rounds days apart
// without keeping a process alive.
//
// A cohort is not evidence on its own. Run an identical schedule against a
// wireline operator as a control: if wireline holds still while mobile churns the
// cause is carrier behaviour, and if both move together the cause is the vendor
// revising its data.
//
// Usage:
//
//	probe_range_split -range 76.90.64.0/20
//	probe_range_split -range 68.100.0.0/16 -samples 24
//	probe_range_split -asn 21928 -samples 40 -repeat 4 -interval 6h -cohort tmobile-as21928
//	probe_range_split -asn 7922  -samples 40 -repeat 4 -interval 6h -cohort comcast-as7922
//
// Only stability mode writes to the database, and only ever to
// probe_stability_tbl, which nothing in the targeting path reads.
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
	Status      string  `json:"status"`
	Message     string  `json:"message"`
	Country     string  `json:"country"`
	CountryCode string  `json:"countryCode"`
	Region      string  `json:"region"`
	RegionName  string  `json:"regionName"`
	City        string  `json:"city"`
	Zip         string  `json:"zip"`
	Lat         float64 `json:"lat"`
	Lon         float64 `json:"lon"`
	ISP         string  `json:"isp"`
	Org         string  `json:"org"`
	As          string  `json:"as"`
	Query       string  `json:"query"`

	// Mobile is ip-api's OWN judgement, and it is NOT part of ip-api's default
	// field set, so it has to be requested explicitly. Nothing in this project
	// captured it before: likely_mobile_cgnat is set from a keyword match on isp
	// and org, which is a different judgement that happens to agree most of the
	// time. Recording both is what makes the disagreement visible.
	Mobile bool `json:"mobile"`
}

type sample struct {
	subnet netip.Prefix
	addr   netip.Addr
	res    geoResult
	err    error
}

// target is a sub-block paired with the address that will be probed inside it.
// In a stability run the pairing is fixed for the life of the cohort.
type target struct {
	subnet netip.Prefix
	addr   netip.Addr
}

func main() {
	rangeFlag := flag.String("range", "", "the range to test, as a CIDR, for example 76.90.64.0/20")
	asnFlag := flag.Int("asn", 0, "instead of one range, sample /24s spread across every IPv4 prefix this ASN originates; answers whether a carrier IPv4 space is geographically resolvable at all")
	samples := flag.Int("samples", 16, "how many distinct sub-blocks to probe")
	block := flag.Int("block", 24, "sub-block prefix length to sample at. 24 compares /24s inside a range; 28 compares /28s, which tests whether a provider resolves finer than a /24")
	rate := flag.Int("rate", 45, "maximum ip-api calls per rolling minute")
	endpoint := flag.String("endpoint", "http://ip-api.com/json/", "ip-api endpoint prefix")
	timeout := flag.Duration("http-timeout", 20*time.Second, "per call timeout")
	repeat := flag.Int("repeat", 1,
		"probe the SAME addresses this many times, measuring whether the answers drift. Above 1 this becomes a stability run and requires -cohort")
	interval := flag.Duration("interval", time.Hour, "wait between rounds of a stability run")
	cohort := flag.String("cohort", "",
		"label for a stability run, for example tmobile-as21928. Re-using a label resumes that cohort with its original addresses, so rounds can be days apart across separate invocations")
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
	if *block < 1 || *block > 32 {
		log.Fatal("-block must be between 1 and 32")
	}
	if *repeat < 1 {
		log.Fatal("-repeat must be at least 1")
	}
	stability := *repeat > 1 || *cohort != ""
	if stability && *cohort == "" {
		log.Fatal("-repeat above 1 needs -cohort, because the observations are stored and compared by cohort label")
	}
	if stability && *interval <= 0 {
		log.Fatal("-interval must be greater than zero for a stability run")
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
			chosen = append(chosen, randomSubBlockIn(prefixes[i%len(prefixes)], *block))
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
		if parent.Bits() > *block {
			log.Fatalf("%s is narrower than a /%d, so it has no internal /%d structure to compare", parent, *block, *block)
		}
		subnets := subBlocksOf(parent, *block)
		total24 = len(subnets)
		log.Printf("%s contains %d /%d blocks", parent, len(subnets), *block)
		chosen = subnets
		if len(subnets) > *samples {
			rand.Shuffle(len(subnets), func(i, j int) { subnets[i], subnets[j] = subnets[j], subnets[i] })
			chosen = subnets[:*samples]
			sort.Slice(chosen, func(i, j int) bool { return chosen[i].Addr().Less(chosen[j].Addr()) })
		}
		label = parent.String()
	}
	client := &http.Client{Timeout: *timeout}

	if !stability {
		// Single-shot behaviour, unchanged. A fresh random address per sub-block,
		// one round, no database write of any kind.
		targets := make([]target, 0, len(chosen))
		for _, sn := range chosen {
			targets = append(targets, target{subnet: sn, addr: randomAddrIn(sn)})
		}
		log.Printf("probing %d /%d blocks at %d calls per minute, roughly %ds", len(targets), *block, *rate,
			(len(targets)*60)/(*rate)+1)
		results := probeRound(client, *endpoint, *rate, targets)
		report(label, results, total24, *asnFlag != 0, *block)
		return
	}

	// ------------------------------------------------------------------
	// Stability run.
	//
	// The addresses are fixed for the life of the cohort. That is the entire
	// point: if each round re-randomised the address inside the block, a change
	// in the answer could mean either that the block moved or that two hosts
	// inside it are in different places, and nothing afterwards could tell those
	// apart. Holding the address constant makes any change unambiguously drift.
	//
	// Re-using a cohort label reloads its original addresses and continues the
	// round numbering, so rounds can be days apart across separate invocations
	// rather than requiring one long-lived process.
	// ------------------------------------------------------------------
	conn, err := connect()
	if err != nil {
		log.Fatalf("stability runs need the database to store observations: %v", err)
	}
	defer conn.Close(context.Background())
	if err := ensureStabilityTable(conn); err != nil {
		log.Fatalf("%v", err)
	}

	targets, startRound, err := resumeCohort(conn, *cohort)
	if err != nil {
		log.Fatalf("reading cohort %q: %v", *cohort, err)
	}
	if len(targets) == 0 {
		for _, sn := range chosen {
			targets = append(targets, target{subnet: sn, addr: randomAddrIn(sn)})
		}
		log.Printf("cohort %q is new: %d addresses chosen and now fixed for its lifetime", *cohort, len(targets))
	} else {
		log.Printf("cohort %q resumed: %d addresses reloaded, next round is %d", *cohort, len(targets), startRound)
	}

	log.Printf("stability run: %d rounds of %d probes, %s apart, at %d calls per minute",
		*repeat, len(targets), *interval, *rate)

	for r := 0; r < *repeat; r++ {
		round := startRound + r
		log.Printf("--- round %d of cohort %q ---", round, *cohort)
		results := probeRound(client, *endpoint, *rate, targets)
		written, err := storeRound(conn, *cohort, round, results)
		if err != nil {
			log.Fatalf("storing round %d: %v", round, err)
		}
		log.Printf("round %d stored %d observations", round, written)
		if r < *repeat-1 {
			log.Printf("sleeping %s before the next round", *interval)
			time.Sleep(*interval)
		}
	}

	churnReport(conn, *cohort)
}

// probeRound probes every target once, honouring the per-minute ceiling, and
// returns the results in target order.
func probeRound(client *http.Client, endpoint string, rate int, targets []target) []sample {
	results := make([]sample, 0, len(targets))
	windowStart := time.Now()
	inWindow := 0
	for i, t := range targets {
		if inWindow == 0 {
			windowStart = time.Now()
		}
		res, err := lookup(client, endpoint, t.addr)
		results = append(results, sample{subnet: t.subnet, addr: t.addr, res: res, err: err})

		if err != nil {
			log.Printf("[%d/%d] %s ip=%s ERROR %v", i+1, len(targets), t.subnet, t.addr, err)
		} else {
			log.Printf("[%d/%d] %s ip=%s status=%s city=%q region=%q zip=%q isp=%q mobile=%v",
				i+1, len(targets), t.subnet, t.addr, res.Status, res.City, res.Region, res.Zip,
				res.ISP, res.Mobile)
		}

		inWindow++
		if inWindow >= rate && i < len(targets)-1 {
			if elapsed := time.Since(windowStart); elapsed < time.Minute {
				wait := time.Minute - elapsed
				log.Printf("rate limit reached, sleeping %s", wait.Round(time.Second))
				time.Sleep(wait)
			}
			inWindow = 0
		}
	}
	return results
}

// connect opens the database using the same convention as the rest of the
// pipeline: an empty DATABASE_URL falls back to the libpq environment, so peer
// authentication over the Unix socket works with no credential on disk.
func connect() (*pgx.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
}

func ensureStabilityTable(conn *pgx.Conn) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var exists bool
	if err := conn.QueryRow(ctx,
		"SELECT to_regclass('public.probe_stability_tbl') IS NOT NULL").Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("probe_stability_tbl does not exist: run geo/probe_stability_tbl.sql first")
	}
	return nil
}

// resumeCohort reloads the fixed addresses of an existing cohort and reports the
// round number to use next. An unknown cohort returns no targets and round 1.
func resumeCohort(conn *pgx.Conn, cohort string) ([]target, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	rows, err := conn.Query(ctx,
		"SELECT DISTINCT network::text, host(probe_ip) FROM probe_stability_tbl "+
			"WHERE cohort = $1 ORDER BY 1", cohort)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []target
	for rows.Next() {
		var sn, ip string
		if err := rows.Scan(&sn, &ip); err != nil {
			return nil, 0, err
		}
		p, err1 := netip.ParsePrefix(sn)
		a, err2 := netip.ParseAddr(ip)
		if err1 != nil || err2 != nil {
			continue
		}
		out = append(out, target{subnet: p, addr: a})
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 {
		return nil, 1, nil
	}

	var maxRound int
	if err := conn.QueryRow(ctx,
		"SELECT coalesce(max(round), 0) FROM probe_stability_tbl WHERE cohort = $1",
		cohort).Scan(&maxRound); err != nil {
		return nil, 0, err
	}
	return out, maxRound + 1, nil
}

// storeRound writes one round of observations. Failed probes are stored too, with
// err populated: a round that silently omitted its failures would make a cohort
// look more stable than it is.
func storeRound(conn *pgx.Conn, cohort string, round int, results []sample) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	const q = `
INSERT INTO probe_stability_tbl
  (cohort, network, probe_ip, round, observed_at, status, country, country_code,
   city, state_code, zip, isp, org, as_text, mobile_ipapi, err)
VALUES ($1, $2, $3, $4, now(), $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
ON CONFLICT (cohort, probe_ip, round) DO NOTHING`

	written := 0
	for _, s := range results {
		errText := interface{}(nil)
		if s.err != nil {
			errText = s.err.Error()
		}
		status := s.res.Status
		if s.err != nil {
			status = "error"
		}
		_, err := conn.Exec(ctx, q, cohort, s.subnet.String(), s.addr.String(), round,
			nullIfEmpty(status), nullIfEmpty(s.res.Country), nullIfEmpty(s.res.CountryCode),
			nullIfEmpty(s.res.City), nullIfEmpty(s.res.Region), nullIfEmpty(s.res.Zip),
			nullIfEmpty(s.res.ISP), nullIfEmpty(s.res.Org), nullIfEmpty(s.res.As),
			s.res.Mobile, errText)
		if err != nil {
			return written, err
		}
		written++
	}
	return written, nil
}

// churnReport prints what the cohort has measured so far. It is deliberately the
// same arithmetic as sections 1 and 2 of probe_stability_tbl.sql, so a psql result
// and this output cannot disagree.
func churnReport(conn *pgx.Conn, cohort string) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	var addresses, minRounds, maxRounds, cityChurned, zipChurned int
	err := conn.QueryRow(ctx, `
WITH per_addr AS (
    SELECT probe_ip,
           count(DISTINCT city || '|' || coalesce(state_code, '')) AS places,
           count(DISTINCT zip) FILTER (WHERE zip IS NOT NULL AND zip <> '') AS zips,
           count(*) AS seen
    FROM probe_stability_tbl
    WHERE cohort = $1 AND status = 'success'
    GROUP BY probe_ip
)
SELECT count(*), coalesce(min(seen), 0), coalesce(max(seen), 0),
       count(*) FILTER (WHERE places > 1), count(*) FILTER (WHERE zips > 1)
FROM per_addr`, cohort).Scan(&addresses, &minRounds, &maxRounds, &cityChurned, &zipChurned)
	if err != nil {
		log.Printf("churn report failed: %v", err)
		return
	}

	fmt.Println()
	fmt.Println("=== stability of cohort " + cohort + " ===")
	if addresses == 0 {
		fmt.Println("no successful observations, so nothing can be concluded")
		return
	}
	outf("addresses tracked:       %d", addresses)
	outf("rounds per address:      %d to %d", minRounds, maxRounds)
	outf("addresses whose CITY moved: %d of %d (%.1f%%)", cityChurned, addresses,
		100*float64(cityChurned)/float64(addresses))
	outf("addresses whose ZIP moved:  %d of %d (%.1f%%)", zipChurned, addresses,
		100*float64(zipChurned)/float64(addresses))

	if maxRounds < 2 {
		fmt.Println()
		fmt.Println("Only one round exists, so churn is not yet measurable. Re-run with the same -cohort")
		fmt.Println("after the interval you care about. Drift cannot be inferred from a single observation.")
		return
	}

	var fastestCity, fastestZip *time.Duration
	var cityChanges, zipChanges int
	var fc, fz *float64
	err = conn.QueryRow(ctx, `
WITH ordered AS (
    SELECT probe_ip, observed_at, city, state_code, zip,
           lag(city)        OVER w AS prev_city,
           lag(state_code)  OVER w AS prev_state,
           lag(zip)         OVER w AS prev_zip,
           lag(observed_at) OVER w AS prev_at
    FROM probe_stability_tbl
    WHERE cohort = $1 AND status = 'success'
    WINDOW w AS (PARTITION BY probe_ip ORDER BY round)
)
SELECT count(*) FILTER (WHERE city IS DISTINCT FROM prev_city OR state_code IS DISTINCT FROM prev_state),
       extract(epoch FROM min(observed_at - prev_at) FILTER (WHERE city IS DISTINCT FROM prev_city OR state_code IS DISTINCT FROM prev_state)),
       count(*) FILTER (WHERE zip IS DISTINCT FROM prev_zip),
       extract(epoch FROM min(observed_at - prev_at) FILTER (WHERE zip IS DISTINCT FROM prev_zip))
FROM ordered
WHERE prev_at IS NOT NULL`, cohort).Scan(&cityChanges, &fc, &zipChanges, &fz)
	if err != nil {
		log.Printf("change-rate query failed: %v", err)
		return
	}
	if fc != nil {
		d := time.Duration(*fc) * time.Second
		fastestCity = &d
	}
	if fz != nil {
		d := time.Duration(*fz) * time.Second
		fastestZip = &d
	}

	outf("city changes observed:   %d", cityChanges)
	if fastestCity != nil {
		outf("fastest city change:     %s", fastestCity.Round(time.Second))
	}
	outf("ZIP changes observed:    %d", zipChanges)
	if fastestZip != nil {
		outf("fastest ZIP change:      %s", fastestZip.Round(time.Second))
	}

	fmt.Println()
	if cityChanges == 0 && zipChanges == 0 {
		fmt.Println("VERDICT: STABLE over the interval observed. Note the interval: stability over an hour says")
		fmt.Println("nothing about stability over a month, and this cohort can only speak for the span it covers.")
	} else {
		fmt.Println("VERDICT: DRIFTING. Answers for fixed addresses changed within this cohort, so a stored")
		fmt.Println("geolocation for this operator has a shelf life. Compare the fastest change above against")
		fmt.Println("the probe cycle time: if the cycle is slower than the drift, output carries stale rows")
		fmt.Println("no matter how correct each measurement was when taken.")
	}
	fmt.Println()
	fmt.Println("A cohort is only interpretable against a control. Run the same schedule on a wireline")
	fmt.Println("operator: if wireline holds still while this churns, the cause is carrier behaviour, and if")
	fmt.Println("both churn together the cause is the vendor revising its data.")
}

func nullIfEmpty(s string) interface{} {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

// subBlocksOf returns every prefix of length blockBits inside p. p must be at
// least as wide as blockBits.
func subBlocksOf(p netip.Prefix, blockBits int) []netip.Prefix {
	first := p.Addr().As4()
	base := binary.BigEndian.Uint32(first[:])
	count := 1 << uint(blockBits-p.Bits())
	step := uint32(1) << uint(32-blockBits)
	out := make([]netip.Prefix, 0, count)
	for i := 0; i < count; i++ {
		var b [4]byte
		binary.BigEndian.PutUint32(b[:], base+uint32(i)*step)
		out = append(out, netip.PrefixFrom(netip.AddrFrom4(b), blockBits))
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
	url := endpoint + addr.String() +
		"?fields=status,message,country,countryCode,region,regionName,city,zip,lat,lon,isp,org,as,mobile,query"
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

func report(label string, results []sample, total24 int, asnMode bool, blockBits int) {
	cities := map[string]int{}
	zips := map[string]int{}
	isps := map[string]int{}
	countries := map[string]int{}
	ok := 0
	mobileCount := 0
	noZip := 0
	for _, s := range results {
		if s.err != nil || s.res.Status != "success" {
			continue
		}
		ok++
		cities[s.res.City+", "+s.res.Region]++
		if s.res.Zip != "" {
			zips[s.res.Zip]++
		} else {
			noZip++
		}
		isps[s.res.ISP]++
		countries[s.res.CountryCode+" "+s.res.Country]++
		if s.res.Mobile {
			mobileCount++
		}
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
	if noZip > 0 {
		outf("  %-40s %d", "(no ZIP returned)", noZip)
	}
	fmt.Println("ISPs returned:")
	for _, k := range sortedKeys(isps) {
		outf("  %-40s %d", k, isps[k])
	}
	if len(countries) > 1 {
		// More than one country in one range or one ASN is worth seeing rather than
		// averaging away: Puerto Rico in particular is a separate country to ip-api,
		// not a US state, so a US-filtered pipeline drops it silently.
		fmt.Println("countries returned:")
		for _, k := range sortedKeys(countries) {
			outf("  %-40s %d", k, countries[k])
		}
	}
	outf("ip-api's own mobile flag true for %d of %d successful probes", mobileCount, ok)

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

	addresses := total24 * (1 << uint(32-blockBits))
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
		outf("SAMPLING CAVEAT: %d of the %d /%d blocks were probed. A verdict of UNITARY from a partial",
			len(results), total24, blockBits)
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

// randomSubBlockIn picks a random prefix of length blockBits inside p. A prefix
// already that narrow or narrower is returned as itself, since BGP occasionally
// carries longer prefixes and there is no internal structure to choose from.
func randomSubBlockIn(p netip.Prefix, blockBits int) netip.Prefix {
	if p.Bits() >= blockBits {
		return p
	}
	first := p.Addr().As4()
	base := binary.BigEndian.Uint32(first[:])
	blocks := uint32(1) << uint(blockBits-p.Bits())
	step := uint32(1) << uint(32-blockBits)
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], base+uint32(rand.Int31n(int32(blocks)))*step)
	return netip.PrefixFrom(netip.AddrFrom4(b), blockBits)
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
