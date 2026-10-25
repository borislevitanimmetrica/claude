package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// The two target sources. "ranges" is the original behaviour and the default,
// so every existing invocation keeps working unchanged.
const (
	sourceRanges    = "ranges"
	sourceLandmarks = "landmarks"
)

// identRe bounds the table names that arrive from flags. They are interpolated
// into SQL because a table name cannot be a bind parameter, so the only safe
// course is to refuse anything that is not a plain identifier.
var identRe = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)

// zipPrefixRe bounds -zip-prefix, which is interpolated into a LIKE pattern.
// Digits only, so there is no way to smuggle a wildcard or a quote.
var zipPrefixRe = regexp.MustCompile(`^[0-9]{1,5}$`)

func checkIdent(name string) error {
	if !identRe.MatchString(name) {
		return fmt.Errorf("%q is not a plain lower-case identifier", name)
	}
	return nil
}

// target is one unit of work. For the default range source, start/end bound a
// prefix and the address actually traced is drawn at random inside it. For the
// landmark source the address is not a sample but THE datum, so start==end and
// exact is set: see runRange, which must then retry the same address rather
// than rerolling a new one.
type target struct {
	network string
	start   netip.Addr
	end     netip.Addr
	exact   bool
}

type result struct {
	network            string
	sampledIP          netip.Addr
	lastHopIP          *netip.Addr
	lastHopName        *string
	lastHopNumber      int
	hopCount           int
	status             string
	probeMethod        string
	attempts           int
	likelyMobileCGN    bool
	classificationNote *string
	rdapLookup         *string
}

// classificationRules holds the contents of traceroute_hostname_rules,
// loaded once at startup rather than queried per hostname.
type classificationRules struct {
	tldExclusions    map[string]string // ".mil" -> "excluded-mil"
	domainExclusions map[string]string // "alter.net" -> "excluded-internal"
	customerMarkers  []string          // "res.", "static.", ...
	// customerMarkerRegexes holds compiled "customer_marker_regex" rules —
	// full-hostname regexes for CPE reverse-DNS forms that a plain
	// label-prefix marker cannot express (e.g. auto-generated PTRs that
	// encode the customer's own IP address).
	customerMarkerRegexes []*regexp.Regexp
}

func loadClassificationRules(ctx context.Context, conn *pgx.Conn) (classificationRules, error) {
	rules := classificationRules{
		tldExclusions:    map[string]string{},
		domainExclusions: map[string]string{},
	}

	rows, err := conn.Query(ctx, `SELECT rule_type, pattern, status_label FROM traceroute_hostname_rules`)
	if err != nil {
		return rules, err
	}
	defer rows.Close()

	for rows.Next() {
		var ruleType, pattern string
		var statusLabel *string
		if err := rows.Scan(&ruleType, &pattern, &statusLabel); err != nil {
			return rules, err
		}
		switch ruleType {
		case "tld_exclude":
			if statusLabel != nil {
				rules.tldExclusions[strings.ToLower(pattern)] = *statusLabel
			}
		case "domain_exclude":
			if statusLabel != nil {
				rules.domainExclusions[strings.ToLower(pattern)] = *statusLabel
			}
		case "customer_marker":
			rules.customerMarkers = append(rules.customerMarkers, strings.ToLower(pattern))
		case "customer_marker_regex":
			// Patterns are matched against a lower-cased hostname (see
			// matchCustomerMarker), so they are compiled as-is rather than
			// lower-cased, which would corrupt regex metacharacters. An
			// invalid pattern is skipped with a warning instead of aborting
			// the whole run.
			re, compileErr := regexp.Compile(pattern)
			if compileErr != nil {
				log.Printf("skipping invalid customer_marker_regex %q: %v", pattern, compileErr)
				continue
			}
			rules.customerMarkerRegexes = append(rules.customerMarkerRegexes, re)
		}
	}
	return rules, rows.Err()
}

// matchExclusion checks TLD and 2nd-level-domain exclusions with
// domain-boundary suffix matching (hostname equals the pattern, or
// ends with "." + pattern) — not raw substring, so a 2nd-level
// exclusion like "alter.net" doesn't accidentally match an unrelated
// domain that merely contains that text.
func (r classificationRules) matchExclusion(hostname string) (string, bool) {
	lower := strings.ToLower(hostname)
	for tld, label := range r.tldExclusions {
		if strings.HasSuffix(lower, tld) {
			return label, true
		}
	}
	for domain, label := range r.domainExclusions {
		if lower == domain || strings.HasSuffix(lower, "."+domain) {
			return label, true
		}
	}
	return "", false
}

// matchCustomerMarker reports whether any customer-equipment marker
// appears at a DNS label boundary — i.e. the marker begins the hostname
// or immediately follows a "." separator. Markers carry their own
// trailing "." (e.g. "res.", "cust.") to bound the right side, so a
// match corresponds to a full leading label component such as
// "res.spectrum.com" or "...cust.rr.com".
//
// Requiring the LEFT boundary is what prevents a marker from matching
// mid-label. A plain substring check misfired on carrier customer-edge
// zones: e.g. Telia's "arizonastate-ic-373367.ip.twelve99-cust.net" is a
// CARRIER interconnect node that names the customer, but "cust." matched
// inside the label "twelve99-cust", so it was wrongly skipped as customer
// CPE and the trace fell back to an upstream backbone hop. "cust" here is
// preceded by "-" (not a label boundary), so it no longer matches.
func (r classificationRules) matchCustomerMarker(hostname string) bool {
	lower := strings.ToLower(hostname)
	for _, re := range r.customerMarkerRegexes {
		if re.MatchString(lower) {
			return true
		}
	}
	for _, marker := range r.customerMarkers {
		if marker == "" {
			continue
		}
		from := 0
		for {
			idx := strings.Index(lower[from:], marker)
			if idx < 0 {
				break
			}
			pos := from + idx
			if pos == 0 || lower[pos-1] == '.' {
				return true
			}
			from = pos + 1
		}
	}
	return false
}

func main() {
	sampleSize := flag.Int("n", 200, "how many targets to take this run: ranges with -source ranges, distinct landmark addresses with -source landmarks")
	concurrency := flag.Int("concurrency", 5, "concurrent mtr runs")
	maxHops := flag.Int("max-hops", 15, "mtr max hops (-m)")
	cycles := flag.Int("cycles", 5, "mtr report cycles per hop (-c)")
	interval := flag.Float64("interval", 1.0, "seconds between mtr probe cycles (-i)")
	useUDP := flag.Bool("udp", false, "use UDP probes instead of mtr's default ICMP")
	country := flag.String("country", "", "restrict to this country_iso_code (e.g. US); empty = no filter")
	maxAttempts := flag.Int("max-attempts", 3, "retries while the status is not terminal, up to this many tries; with -source ranges each try takes a new random address in the range, with -source landmarks each try re-traces the same landmark address")
	backtrackHops := flag.Int("backtrack-hops", 5, "how many responding hops back from the trace's far end to search for a usable carrier hostname")
	rdapScriptFlag := flag.String("rdap-script", "./rdap-lookup.sh", "path to rdap-lookup.sh; run on the sampled IP as an ownership/location fallback when status is excluded-internal (empty string disables the fallback)")
	ipv4Only := flag.Bool("ipv4-only", false, "sample only IPv4 ranges even when IPv6 connectivity is available (skips the IPv6 connectivity probe)")
	source := flag.String("source", sourceRanges, "where targets come from: \"ranges\" traces a random address inside each ip2city_dbiplite_tbl prefix and writes ip2city_dbiplite_traceroute_tbl keyed on network (the original behaviour); \"landmarks\" traces each distinct on-premises landmark address from -landmark-table exactly and writes -trace-table keyed on that address")
	landmarkTable := flag.String("landmark-table", "ovt_places_usa", "landmark table read by -source landmarks; needs columns ip_address inet and onpremises boolean")
	traceTable := flag.String("trace-table", "ovt_places_usa_ip_trace", "destination table for -source landmarks, keyed on ip; create with geo/overture_fetch/create_table_ovt_places_usa_ip_trace.sql")
	pauseFile := flag.String("pause-file", "", "if this path exists, stop feeding new traces and wait for it to be removed; in-flight traces finish (empty string disables the check)")
	zipPrefix := flag.String("zip-prefix", "", "with -source landmarks, trace only landmarks whose Overture ZIP starts with this, e.g. 021 for the Boston area or 0 for all of New England; empty = no restriction. Use it to measure yield and throughput on one region before committing to a national pass")
	flag.Parse()

	if *zipPrefix != "" {
		if *source != sourceLandmarks {
			log.Fatalf("-zip-prefix only applies to -source landmarks")
		}
		if !zipPrefixRe.MatchString(*zipPrefix) {
			log.Fatalf("-zip-prefix must be 1 to 5 digits, got %q", *zipPrefix)
		}
	}

	if *source != sourceRanges && *source != sourceLandmarks {
		log.Fatalf("-source must be %q or %q, got %q", sourceRanges, sourceLandmarks, *source)
	}
	if err := checkIdent(*landmarkTable); err != nil {
		log.Fatalf("-landmark-table: %v", err)
	}
	if err := checkIdent(*traceTable); err != nil {
		log.Fatalf("-trace-table: %v", err)
	}

	if _, err := exec.LookPath("mtr"); err != nil {
		log.Fatalf("mtr binary not found on PATH: %v", err)
	}

	// The RDAP fallback is only a last resort for excluded-internal
	// results (see runRange). If the script isn't present we disable
	// the fallback with a warning rather than aborting the whole run —
	// the traceroute classification is still useful without it.
	rdapScript := *rdapScriptFlag
	if rdapScript != "" {
		if _, err := os.Stat(rdapScript); err != nil {
			log.Printf("warning: rdap script %q not usable (%v); excluded-internal RDAP fallback disabled", rdapScript, err)
			rdapScript = ""
		} else {
			log.Printf("excluded-internal RDAP fallback enabled via %q", rdapScript)
		}
	} else {
		log.Printf("excluded-internal RDAP fallback disabled (-rdap-script empty)")
	}

	// An empty DATABASE_URL is NOT an error. pgx.Connect with an empty string
	// resolves the connection from the standard libpq environment (PGHOST,
	// PGPORT, PGUSER, PGDATABASE, PGPASSFILE) and its built-in defaults, which
	// is exactly what "psql" with no connection string does. That lets a service
	// account connect over a Unix socket with peer authentication and no
	// credentials anywhere on disk or in a crontab.
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Printf("DATABASE_URL not set; connecting via libpq environment and defaults")
	}

	ctx := context.Background()

	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		log.Fatalf("PostgreSQL connection failed: %v", err)
	}
	defer conn.Close(context.Background())

	rules, err := loadClassificationRules(ctx, conn)
	if err != nil {
		log.Fatalf("loading classification rules: %v", err)
	}
	log.Printf("loaded classification rules: %d tld, %d domain, %d customer-marker, %d customer-marker-regex",
		len(rules.tldExclusions), len(rules.domainExclusions), len(rules.customerMarkers), len(rules.customerMarkerRegexes))

	// includeIPv6 gates whether IPv6 ranges are sampled at all. It requires
	// both working IPv6 connectivity AND that -ipv4-only was not set. With
	// -ipv4-only we skip the connectivity probe entirely and force IPv4.
	ipv6OK := false
	if *ipv4Only {
		log.Printf("IPv6 sampling disabled via -ipv4-only")
	} else {
		ipv6OK = ipv6Available()
		log.Printf("IPv6 connectivity probe: available=%v", ipv6OK)
	}

	// The two sources differ in what they select, what identity they write
	// against, and whether a retry rerolls the address. Everything between
	// here and the write is shared, so the classification of a landmark hop
	// and of a probe-range hop is by construction the same code: a divergence
	// there would silently make the two sides unmatchable.
	var targets []target
	var write func(context.Context, *pgx.Conn, result) error
	var unit string

	switch *source {
	case sourceRanges:
		targets, err = sampleTargets(ctx, conn, *sampleSize, *country, ipv6OK)
		write = writeResult
		unit = "ranges"
	case sourceLandmarks:
		targets, err = sampleLandmarks(ctx, conn, *sampleSize, *landmarkTable, *traceTable, *zipPrefix, ipv6OK)
		tt := *traceTable
		write = func(c context.Context, cn *pgx.Conn, r result) error { return writeTrace(c, cn, tt, r) }
		unit = "landmark addresses"
	}
	if err != nil {
		log.Fatalf("sampling targets: %v", err)
	}
	method := "mtr-icmp"
	if *useUDP {
		method = "mtr-udp"
	}
	log.Printf("source=%s: selected %d %s (country filter: %q, ipv6 included: %v, method: %s, cycles: %d, max-attempts: %d)",
		*source, len(targets), unit, *country, ipv6OK, method, *cycles, *maxAttempts)

	if len(targets) == 0 {
		log.Printf("no eligible %s found; nothing to do", unit)
		return
	}

	jobs := make(chan target)
	results := make(chan result)

	var wg sync.WaitGroup
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for t := range jobs {
				results <- runRange(t, *maxHops, *cycles, *interval, *useUDP, method, *maxAttempts, *backtrackHops, rules, rdapScript)
			}
		}()
	}

	// The pause check sits in the feeder, not in the workers, so pausing stops
	// NEW traces and lets in-flight ones finish and be written. A worker-side
	// check would instead strand partial work. A full landmark pass is tens of
	// hours of ICMP, so being able to stand it down without losing the
	// completed portion is the difference between an interruption and a
	// restart. Mirrors probe_batch.sh's PAUSE_FILE.
	go func() {
		for _, t := range targets {
			waitWhilePaused(*pauseFile)
			jobs <- t
		}
		close(jobs)
	}()

	go func() {
		wg.Wait()
		close(results)
	}()

	written := 0
	for r := range results {
		if err := write(ctx, conn, r); err != nil {
			log.Printf("write failed for %s: %v", r.network, err)
			continue
		}
		written++
		rdapNote := "-"
		if r.rdapLookup != nil {
			rdapNote = firstLine(*r.rdapLookup)
		}
		log.Printf("[%d/%d] %s -> sampled %s (%d attempts) status=%s last_hop=%v(#%d) hostname=%v note=%v rdap=%q",
			written, len(targets), r.network, r.sampledIP, r.attempts, r.status,
			derefAddr(r.lastHopIP), r.lastHopNumber, derefStr(r.lastHopName), derefStr(r.classificationNote), rdapNote)
	}

	log.Printf("done: %d results written", written)
}

func ipv6Available() bool {
	c, err := net.DialTimeout("udp6", "[2001:4860:4860::8888]:33434", 2*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// sampleTargets excludes RFC 6598 shared/CGNAT space outright, plus
// any network whose latest result is already terminal: a satisfactory
// "reached" (non-mobile), an "unreachable" classification, or any
// dynamic "excluded-*" label from traceroute_hostname_rules.
func sampleTargets(ctx context.Context, conn *pgx.Conn, n int, country string, includeIPv6 bool) ([]target, error) {
	query := `
SELECT t.network::text,
       host(network(t.network))::inet   AS start_ip,
       host(broadcast(t.network))::inet AS end_ip
FROM ip2city_dbiplite_tbl t
WHERE NOT EXISTS (
    SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
    WHERE tr.network = t.network
      AND (
        (tr.status = 'reached' AND tr.last_hop_hostname IS NOT NULL AND tr.likely_mobile_cgnat = false)
        OR tr.status = 'unreachable'
        OR tr.status LIKE 'excluded-%'
      )
)
AND NOT (t.network <<= '100.64.0.0/10'::cidr)`

	args := []any{n}
	if !includeIPv6 {
		query += " AND family(t.network) = 4"
	}
	if country != "" {
		query += fmt.Sprintf(" AND t.country_iso_code = $%d", len(args)+1)
		args = append(args, country)
	}
	query += " ORDER BY random() LIMIT $1"

	rows, err := conn.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []target
	for rows.Next() {
		var netText string
		var start, end netip.Addr
		if err := rows.Scan(&netText, &start, &end); err != nil {
			return nil, err
		}
		out = append(out, target{network: netText, start: start, end: end})
	}
	return out, rows.Err()
}

// sampleLandmarks selects distinct on-premises landmark addresses that have no
// trace yet.
//
// DISTINCT is load-bearing and not just an optimisation. Many Overture places
// share one resolved address — a health system's clinics all point at the same
// server — and tracing that address once per place would multiply tens of hours
// of ICMP by a factor of roughly ten for identical results. The trace is a
// property of the ADDRESS, so it is stored per address in the trace table and
// fanned back out to places by join, exactly as ovt_places_usa_ip_rdap does for
// RDAP results.
//
// onpremises = true is the whole filter on quality: it already encodes the ISP
// rule, the CDN/cloud/web-host provider exclusion and the registrant-ZIP
// adjacency test. A provider-hosted address is deliberately absent, because the
// node adjacent to it is the provider's edge router and can never converge with
// retail routing.
//
// The NOT EXISTS against the trace table makes the pass resumable, which a
// multi-day run requires. ORDER BY random() is kept rather than any stable
// order so that a partial pass is a representative sample of the whole country
// instead of an alphabetical or address-ordered prefix of it; interrupted after
// 10%, the result is still usable for measuring the fan-out distribution.
// zipPrefix restricts the pass to one region so yield and throughput can be
// measured before committing to a national run. It filters on the landmark's
// Overture ZIP, not on the carrier node's location, because the Overture ZIP is
// the thing being transferred and so it is the thing whose coverage matters.
func sampleLandmarks(ctx context.Context, conn *pgx.Conn, n int, landmarkTable, traceTable, zipPrefix string, includeIPv6 bool) ([]target, error) {
	// The DISTINCT has to be wrapped before ORDER BY random(), because
	// PostgreSQL rejects "SELECT DISTINCT ... ORDER BY random()" outright:
	// every ORDER BY expression must appear in the select list of a DISTINCT
	// query, and random() cannot (SQLSTATE 42P10). Deduplicating in an inner
	// query and shuffling the result outside is the standard shape.
	inner := fmt.Sprintf(`
SELECT DISTINCT p.ip_address
FROM %s p
WHERE p.onpremises = true
  AND p.ip_address IS NOT NULL
  AND NOT (p.ip_address <<= '100.64.0.0/10'::cidr)
  AND NOT EXISTS (SELECT 1 FROM %s t WHERE t.ip = p.ip_address)`, landmarkTable, traceTable)

	if !includeIPv6 {
		inner += " AND family(p.ip_address) = 4"
	}
	if zipPrefix != "" {
		// zipPrefix is digits only, checked in main, so interpolating it into a
		// LIKE pattern cannot inject anything. left() rather than LIKE on the
		// raw column so a ZIP stored with a leading space or as numeric text
		// still matches, consistent with the padding the onpremises step uses.
		inner += fmt.Sprintf(" AND left(lpad(btrim(p.overture_zip::text), 5, '0'), %d) = '%s'",
			len(zipPrefix), zipPrefix)
	}
	query := fmt.Sprintf("SELECT d.ip_address FROM (%s) d ORDER BY random() LIMIT $1", inner)

	rows, err := conn.Query(ctx, query, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []target
	for rows.Next() {
		var ip netip.Addr
		if err := rows.Scan(&ip); err != nil {
			return nil, err
		}
		// network carries the address only so the progress log and error
		// messages have an identity to print; the trace table is keyed on
		// sampled_ip, which for an exact target is this same address.
		out = append(out, target{network: ip.String(), start: ip, end: ip, exact: true})
	}
	return out, rows.Err()
}

// waitWhilePaused blocks while the pause file exists, logging once per
// transition so a paused run is visible in the log without flooding it.
func waitWhilePaused(path string) {
	if path == "" {
		return
	}
	announced := false
	for {
		if _, err := os.Stat(path); err != nil {
			if announced {
				log.Printf("pause file %s removed, resuming", path)
			}
			return
		}
		if !announced {
			log.Printf("pause file %s present, holding off new traces (remove it to resume)", path)
			announced = true
		}
		time.Sleep(15 * time.Second)
	}
}

// flexFloat accepts either a JSON number or a numeric string for
// mtr's --json latency fields, defensively, since the exact wire
// type wasn't independently confirmed against this mtr build's output.
type flexFloat float64

func (f *flexFloat) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "" || s == "null" {
		*f = 0
		return nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		*f = 0
		return nil // don't fail the whole parse over one unreadable field
	}
	*f = flexFloat(v)
	return nil
}

type hop struct {
	num        int
	addr       netip.Addr
	ok         bool
	avgMs      float64
	hasLatency bool
}

type mtrJSON struct {
	Report struct {
		Hubs []struct {
			Count int       `json:"count"`
			Host  string    `json:"host"`
			Avg   flexFloat `json:"Avg"`
		} `json:"hubs"`
	} `json:"report"`
}

func mtrTrace(ctx context.Context, dst netip.Addr, maxHops, cycles int, interval float64, useUDP bool) ([]hop, error) {
	args := []string{
		"--report", "--json", "-n",
		"-c", strconv.Itoa(cycles),
		"-m", strconv.Itoa(maxHops),
		"-i", strconv.FormatFloat(interval, 'f', -1, 64),
	}
	if useUDP {
		args = append(args, "--udp")
	}
	args = append(args, dst.String())

	cmd := exec.CommandContext(ctx, "mtr", args...)
	out, err := cmd.Output()

	if len(out) == 0 {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("timed out with no output: %w", ctx.Err())
		}
		if err != nil {
			return nil, fmt.Errorf("mtr produced no output: %w", err)
		}
	}

	var parsed mtrJSON
	if jsonErr := json.Unmarshal(out, &parsed); jsonErr != nil {
		return nil, nil // known mtr issue: malformed JSON when destination never responds at all
	}

	var hops []hop
	for _, h := range parsed.Report.Hubs {
		host := strings.TrimSpace(h.Host)
		if host == "" || host == "???" {
			hops = append(hops, hop{num: h.Count, ok: false})
			continue
		}
		addr, addrErr := netip.ParseAddr(host)
		if addrErr != nil {
			hops = append(hops, hop{num: h.Count, ok: false})
			continue
		}
		hops = append(hops, hop{num: h.Count, addr: addr, ok: true, avgMs: float64(h.Avg), hasLatency: true})
	}

	return hops, nil
}

// runOne runs the mtr trace for one sampled address and hands the hop list
// to classifyHops. It stamps the network/sampled/method fields; all
// classification logic lives in classifyHops so it can be exercised
// deterministically without invoking mtr or live DNS.
func runOne(network string, sampled netip.Addr, maxHops, cycles int, interval float64, useUDP bool, method string, backtrackHops int, rules classificationRules) result {
	overallTimeout := time.Duration(float64(cycles)*interval+float64(maxHops)+10) * time.Second

	ctx, cancel := context.WithTimeout(context.Background(), overallTimeout)
	defer cancel()

	hops, err := mtrTrace(ctx, sampled, maxHops, cycles, interval, useUDP)
	if err != nil {
		return result{network: network, sampledIP: sampled, status: "mtr_error: " + err.Error(), probeMethod: method}
	}

	r := classifyHops(hops, sampled, reverseDNS, backtrackHops, rules)
	r.network = network
	r.sampledIP = sampled
	r.probeMethod = method
	return r
}

// classifyHops implements the full classification pipeline over an ordered
// hop list, taking resolve() for reverse DNS so it is decoupled from the
// network:
//
//  0. Discard any responding hop whose address IS the address being traced.
//     The destination is not a carrier node, by definition. This matters
//     enormously for landmark targets and barely at all for range targets,
//     which is why it went unnoticed: a random address inside a range almost
//     never answers, so the trace dies short and the last responding hop
//     really is carrier equipment. A landmark is a WEB SERVER and it does
//     answer, so the trace completes, the final responding hop is the landmark
//     itself, and a hostname like box5184.bluehost.com matches no exclusion
//     and no customer marker and was therefore accepted as the "carrier node".
//     That result is unusable: a probe range's carrier node can never match a
//     landmark's own web server, so every such row was wasted. Measured on a
//     2,000-address landmark pass, this was between a third and a half of all
//     rows. The hop that IS wanted is already in the trace, one position
//     earlier; only the choice was wrong.
//
//     The rule is correct for the range source too, where it fixes the same
//     bug in its rare form: if a randomly chosen probe address does answer, it
//     is a customer host, not carrier equipment, and must not be accepted.
//
//  1. Order the remaining responding hops from the far end of the trace backward.
//
//  2. Find the nearest one with ANY resolvable hostname (content not
//     yet considered) — if that's at position 2 or 3, the whole path
//     died right at the local ISP boundary: status=unreachable,
//     terminal, regardless of what the hostname actually says.
//
//  3. Otherwise, walk backward through resolved hostnames: a match
//     against a TLD/domain exclusion rule is terminal with that
//     rule's status label; a match against a customer-equipment
//     marker is skipped (keep searching further back); the first
//     hostname that's neither is accepted as the carrier hop.
//
//  4. Once accepted, compare the accepted hop's latency to the very next
//     hop: a large *delta* (a jump of more than 20ms from this hop to the
//     next) signals a long-haul backbone link beyond the accepted hop,
//     meaning it is core infrastructure far from the customer, and
//     overrides to status=excluded-internal. This is a delta, NOT the next
//     hop's absolute latency — on a transcontinental path every terminal
//     hop sits well above 20ms, so an absolute test misfires and buries
//     legitimate customer-serving edge nodes as excluded-internal.
func classifyHops(hops []hop, traced netip.Addr, resolve func(netip.Addr) *string, backtrackHops int, rules classificationRules) result {
	r := result{hopCount: len(hops)}

	var candidates []hop
	for i := len(hops) - 1; i >= 0; i-- {
		if !hops[i].ok {
			continue
		}
		// Step 0: the destination is never a carrier node. Compared by address
		// rather than by position because mtr can report the destination at
		// more than one hop when the final hops repeat.
		if traced.IsValid() && hops[i].addr == traced {
			continue
		}
		candidates = append(candidates, hops[i])
	}
	if len(candidates) == 0 {
		r.status = "incomplete"
		return r
	}

	limit := len(candidates)
	if limit > backtrackHops+1 {
		limit = backtrackHops + 1
	}

	byNum := map[int]hop{}
	for _, h := range hops {
		byNum[h.num] = h
	}

	nearestIdx := -1
	var nearestName string
	for i := 0; i < limit; i++ {
		if name := resolve(candidates[i].addr); name != nil {
			nearestIdx = i
			nearestName = *name
			break
		}
	}

	if nearestIdx == -1 {
		r.status = "incomplete"
		return r
	}

	if n := candidates[nearestIdx].num; n == 2 || n == 3 {
		r.status = "unreachable"
		r.lastHopIP = &candidates[nearestIdx].addr
		r.lastHopName = &nearestName
		r.lastHopNumber = n
		note := fmt.Sprintf("nearest resolved hop at position %d", n)
		r.classificationNote = &note
		return r
	}

	for i := nearestIdx; i < limit; i++ {
		c := candidates[i]

		var hn string
		if i == nearestIdx {
			hn = nearestName
		} else {
			resolved := resolve(c.addr)
			if resolved == nil {
				continue
			}
			hn = *resolved
		}

		if label, excluded := rules.matchExclusion(hn); excluded {
			r.status = label
			r.lastHopIP = &c.addr
			r.lastHopName = &hn
			r.lastHopNumber = c.num
			note := "matched exclusion rule: " + hn
			r.classificationNote = &note
			return r
		}

		if rules.matchCustomerMarker(hn) {
			continue
		}

		r.status = "reached"
		r.lastHopIP = &c.addr
		r.lastHopName = &hn
		r.lastHopNumber = c.num
		r.likelyMobileCGN = isLikelyMobileCarrierHostname(hn)

		if next, ok := byNum[c.num+1]; ok && next.ok && next.hasLatency && c.hasLatency && (next.avgMs-c.avgMs) > 20.0 {
			r.status = "excluded-internal"
			note := fmt.Sprintf("long-haul latency jump after hop %d: +%.1fms to hop %d (%.1fms)",
				c.num, next.avgMs-c.avgMs, next.num, next.avgMs)
			r.classificationNote = &note
		}

		return r
	}

	r.status = "incomplete"
	return r
}

func isLikelyMobileCarrierHostname(name string) bool {
	lower := strings.ToLower(name)
	keywords := []string{
		"vzw", "cellular", "wireless", "mobility",
		"sprintpcs", "sprint.net", "tmobile", "t-mobile",
		"cingular", "uscc", "cricketwireless", "boostmobile", "metropcs",
	}
	for _, k := range keywords {
		if strings.Contains(lower, k) {
			return true
		}
	}
	return false
}

func resultRank(status string) int {
	switch {
	case status == "reached":
		return 300
	case status == "unreachable" || strings.HasPrefix(status, "excluded-"):
		return 200
	case status == "incomplete":
		return 100
	default:
		return 0 // errors
	}
}

func isTerminal(status string) bool {
	return status == "reached" || status == "unreachable" || strings.HasPrefix(status, "excluded-")
}

func runRange(t target, maxHops, cycles int, interval float64, useUDP bool, method string, maxAttempts, backtrackHops int, rules classificationRules, rdapScript string) result {
	var best result
	haveBest := false
	tried := map[netip.Addr]bool{}
	totalAttempts := 0

	for i := 0; i < maxAttempts; i++ {
		// An exact target retries the SAME address. Rerolling would defeat the
		// purpose: the landmark's own address is the measurement, and a
		// neighbouring address in the same prefix is a different host that may
		// sit behind different equipment. Retrying still has value, because a
		// single trace can lose the decisive hop to transient ICMP rate
		// limiting. Note that the sampling path cannot be reused here even
		// though start==end would return that one address: it records the
		// address in `tried` and would then fail the second attempt with
		// "range exhausted", silently capping an exact target at one try.
		var sampled netip.Addr
		if t.exact {
			sampled = t.start
		} else {
			var err error
			sampled, err = randomAddrInRangeExcluding(t.start, t.end, tried)
			if err != nil {
				break
			}
			tried[sampled] = true
		}
		totalAttempts++

		r := runOne(t.network, sampled, maxHops, cycles, interval, useUDP, method, backtrackHops, rules)

		if !haveBest || resultRank(r.status) >= resultRank(best.status) {
			best = r
			haveBest = true
		}

		if isTerminal(r.status) {
			// "reached" still retries if it's mobile-flagged (not
			// truly satisfactory); everything else terminal stops.
			if r.status != "reached" || !r.likelyMobileCGN {
				break
			}
		}
	}

	if !haveBest {
		return result{network: t.network, status: "range_error: no addresses available", probeMethod: method, attempts: totalAttempts}
	}

	best.attempts = totalAttempts

	// RDAP ownership/location fallback.
	//
	// Only excluded-internal reaches here for RDAP: that status means the
	// trace terminated inside carrier-internal backbone with no usable,
	// customer-locating domain-resolvable carrier node. Those are exactly
	// the customers served directly off a wholesale/trunk operator with no
	// domain-resolvable routing equipment, whose city we can't read from a
	// hostname. When such a node *does* exist the range resolves to
	// "reached" instead and its domain-encoded location takes precedence —
	// we deliberately never RDAP those, because for retail ISPs the ARIN
	// address is the ISP headquarters, not the customer.
	if rdapScript != "" && best.status == "excluded-internal" {
		out, err := runRDAP(rdapScript, best.sampledIP)
		if err != nil {
			note := "rdap_lookup failed: " + err.Error()
			if out != "" {
				note += " | " + firstLine(out)
			}
			best.rdapLookup = &note
		} else if out != "" {
			best.rdapLookup = &out
		}
	}

	return best
}

// runRDAP invokes rdap-lookup.sh against the sampled IP to recover the
// registrant's ownership and geographic address from ARIN's RDAP registry.
// It is invoked via `bash <script>` so it works regardless of the script's
// executable bit. Combined stdout+stderr is returned so the script's own
// diagnostic messages (e.g. non-200 responses) are preserved on failure.
func runRDAP(scriptPath string, ip netip.Addr) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", scriptPath, ip.String())
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func randomAddrInRangeExcluding(start, end netip.Addr, tried map[netip.Addr]bool) (netip.Addr, error) {
	const maxRerolls = 20
	for i := 0; i < maxRerolls; i++ {
		addr, err := randomAddrInRange(start, end)
		if err != nil {
			return netip.Addr{}, err
		}
		if !tried[addr] {
			return addr, nil
		}
	}
	return netip.Addr{}, fmt.Errorf("range exhausted of untried addresses")
}

func randomAddrInRange(start, end netip.Addr) (netip.Addr, error) {
	startBytes := start.AsSlice()
	endBytes := end.AsSlice()

	startInt := new(big.Int).SetBytes(startBytes)
	endInt := new(big.Int).SetBytes(endBytes)

	count := new(big.Int).Sub(endInt, startInt)
	count.Add(count, big.NewInt(1))

	offsetMax := new(big.Int).Set(count)
	excludeEnds := count.Cmp(big.NewInt(2)) > 0
	if excludeEnds {
		offsetMax.Sub(count, big.NewInt(2))
	}

	r, err := rand.Int(rand.Reader, offsetMax)
	if err != nil {
		return netip.Addr{}, err
	}

	if excludeEnds {
		r.Add(r, big.NewInt(1))
	}

	targetInt := new(big.Int).Add(startInt, r)

	buf := make([]byte, len(startBytes))
	targetInt.FillBytes(buf)

	addr, ok := netip.AddrFromSlice(buf)
	if !ok {
		return netip.Addr{}, fmt.Errorf("could not reconstruct address from %x", buf)
	}
	return addr, nil
}

func reverseDNS(ip netip.Addr) *string {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	names, err := net.DefaultResolver.LookupAddr(ctx, ip.String())
	if err != nil || len(names) == 0 {
		return nil
	}
	name := strings.TrimSuffix(names[0], ".")
	return &name
}

func writeResult(ctx context.Context, conn *pgx.Conn, r result) error {
	_, err := conn.Exec(ctx, `
INSERT INTO ip2city_dbiplite_traceroute_tbl
    (network, sampled_ip, last_hop_ip, last_hop_hostname, last_hop_number, hop_count, status,
     probe_method, likely_mobile_cgnat, classification_note, attempts, rdap_lookup, ran_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
ON CONFLICT (network) DO UPDATE SET
    sampled_ip           = EXCLUDED.sampled_ip,
    last_hop_ip           = EXCLUDED.last_hop_ip,
    last_hop_hostname     = EXCLUDED.last_hop_hostname,
    last_hop_number        = EXCLUDED.last_hop_number,
    hop_count                = EXCLUDED.hop_count,
    status                    = EXCLUDED.status,
    probe_method                = EXCLUDED.probe_method,
    likely_mobile_cgnat           = EXCLUDED.likely_mobile_cgnat,
    classification_note             = EXCLUDED.classification_note,
    attempts                          = EXCLUDED.attempts,
    rdap_lookup                         = EXCLUDED.rdap_lookup,
    ran_at                              = now()
`, r.network, r.sampledIP, r.lastHopIP, r.lastHopName, nullIfZero(r.lastHopNumber), r.hopCount, r.status,
		r.probeMethod, r.likelyMobileCGN, r.classificationNote, r.attempts, r.rdapLookup)
	return err
}

// writeTrace stores a landmark trace keyed on the traced ADDRESS.
//
// It cannot share ip2city_dbiplite_traceroute_tbl, which is keyed ON CONFLICT
// (network) with one row per prefix. Landmarks are addresses, and many
// landmarks commonly sit in one prefix, so writing them to a network-keyed
// table would have each landmark overwrite the previous one's carrier node and
// leave a single arbitrary survivor per prefix. That failure would not be
// visible as an error; it would just quietly discard most of the pass.
func writeTrace(ctx context.Context, conn *pgx.Conn, table string, r result) error {
	if !r.sampledIP.IsValid() {
		return fmt.Errorf("no address was traced for %s (status %q), nothing to key on", r.network, r.status)
	}
	_, err := conn.Exec(ctx, fmt.Sprintf(`
INSERT INTO %s
    (ip, last_hop_ip, last_hop_hostname, last_hop_number, hop_count, status,
     probe_method, likely_mobile_cgnat, classification_note, attempts, traced_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now())
ON CONFLICT (ip) DO UPDATE SET
    last_hop_ip         = EXCLUDED.last_hop_ip,
    last_hop_hostname   = EXCLUDED.last_hop_hostname,
    last_hop_number     = EXCLUDED.last_hop_number,
    hop_count           = EXCLUDED.hop_count,
    status              = EXCLUDED.status,
    probe_method        = EXCLUDED.probe_method,
    likely_mobile_cgnat = EXCLUDED.likely_mobile_cgnat,
    classification_note = EXCLUDED.classification_note,
    attempts            = EXCLUDED.attempts,
    traced_at           = now()
`, table), r.sampledIP, r.lastHopIP, r.lastHopName, nullIfZero(r.lastHopNumber), r.hopCount, r.status,
		r.probeMethod, r.likelyMobileCGN, r.classificationNote, r.attempts)
	return err
}

func nullIfZero(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

func derefAddr(a *netip.Addr) any {
	if a == nil {
		return nil
	}
	return *a
}

func derefStr(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}
