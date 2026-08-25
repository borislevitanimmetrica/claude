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
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

type target struct {
	network string
	start   netip.Addr
	end     netip.Addr
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
		pattern = strings.ToLower(pattern)
		switch ruleType {
		case "tld_exclude":
			if statusLabel != nil {
				rules.tldExclusions[pattern] = *statusLabel
			}
		case "domain_exclude":
			if statusLabel != nil {
				rules.domainExclusions[pattern] = *statusLabel
			}
		case "customer_marker":
			rules.customerMarkers = append(rules.customerMarkers, pattern)
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
	sampleSize := flag.Int("n", 200, "number of ranges to sample")
	concurrency := flag.Int("concurrency", 5, "concurrent mtr runs")
	maxHops := flag.Int("max-hops", 15, "mtr max hops (-m)")
	cycles := flag.Int("cycles", 5, "mtr report cycles per hop (-c)")
	interval := flag.Float64("interval", 1.0, "seconds between mtr probe cycles (-i)")
	useUDP := flag.Bool("udp", false, "use UDP probes instead of mtr's default ICMP")
	country := flag.String("country", "", "restrict to this country_iso_code (e.g. US); empty = no filter")
	maxAttempts := flag.Int("max-attempts", 3, "retry with a new random address from the same range while status is incomplete, up to this many tries")
	backtrackHops := flag.Int("backtrack-hops", 5, "how many responding hops back from the trace's far end to search for a usable carrier hostname")
	rdapScriptFlag := flag.String("rdap-script", "./rdap-lookup.sh", "path to rdap-lookup.sh; run on the sampled IP as an ownership/location fallback when status is excluded-internal (empty string disables the fallback)")
	flag.Parse()

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

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is not set")
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
	log.Printf("loaded classification rules: %d tld, %d domain, %d customer-marker",
		len(rules.tldExclusions), len(rules.domainExclusions), len(rules.customerMarkers))

	ipv6OK := ipv6Available()
	log.Printf("IPv6 connectivity probe: available=%v", ipv6OK)

	targets, err := sampleTargets(ctx, conn, *sampleSize, *country, ipv6OK)
	if err != nil {
		log.Fatalf("sampling targets: %v", err)
	}
	method := "mtr-icmp"
	if *useUDP {
		method = "mtr-udp"
	}
	log.Printf("sampled %d ranges (country filter: %q, ipv6 included: %v, method: %s, cycles: %d, max-attempts: %d)",
		len(targets), *country, ipv6OK, method, *cycles, *maxAttempts)

	if len(targets) == 0 {
		log.Fatal("no eligible ranges found")
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

	go func() {
		for _, t := range targets {
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
		if err := writeResult(ctx, conn, r); err != nil {
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

	r := classifyHops(hops, reverseDNS, backtrackHops, rules)
	r.network = network
	r.sampledIP = sampled
	r.probeMethod = method
	return r
}

// classifyHops implements the full classification pipeline over an ordered
// hop list, taking resolve() for reverse DNS so it is decoupled from the
// network:
//  1. Order all responding hops from the far end of the trace backward.
//  2. Find the nearest one with ANY resolvable hostname (content not
//     yet considered) — if that's at position 2 or 3, the whole path
//     died right at the local ISP boundary: status=unreachable,
//     terminal, regardless of what the hostname actually says.
//  3. Otherwise, walk backward through resolved hostnames: a match
//     against a TLD/domain exclusion rule is terminal with that
//     rule's status label; a match against a customer-equipment
//     marker is skipped (keep searching further back); the first
//     hostname that's neither is accepted as the carrier hop.
//  4. Once accepted, compare the accepted hop's latency to the very next
//     hop: a large *delta* (a jump of more than 20ms from this hop to the
//     next) signals a long-haul backbone link beyond the accepted hop,
//     meaning it is core infrastructure far from the customer, and
//     overrides to status=excluded-internal. This is a delta, NOT the next
//     hop's absolute latency — on a transcontinental path every terminal
//     hop sits well above 20ms, so an absolute test misfires and buries
//     legitimate customer-serving edge nodes as excluded-internal.
func classifyHops(hops []hop, resolve func(netip.Addr) *string, backtrackHops int, rules classificationRules) result {
	r := result{hopCount: len(hops)}

	var candidates []hop
	for i := len(hops) - 1; i >= 0; i-- {
		if hops[i].ok {
			candidates = append(candidates, hops[i])
		}
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
		sampled, err := randomAddrInRangeExcluding(t.start, t.end, tried)
		if err != nil {
			break
		}
		tried[sampled] = true
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
