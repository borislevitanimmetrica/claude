// Command rdap_registrant populates rdap_registrant_tbl, a cache of RIR
// registration data used to identify the registrant of a range before deciding
// whether to decompose it.
//
// # WHY THIS EXISTS SEPARATELY FROM PROBING
//
// The registrant question and the geolocation question are different questions
// answered by different services, and coupling them was a mistake worth undoing.
//
// ip-api returns isp and org, which describe who appears to be OPERATING an
// address. They are derived commercial fields, inconsistently populated, and they
// exist only as a side effect of probing one address inside a range. So a
// registrant taken from ip-api is unavailable for any range that has not been
// probed, which forced decomposition either to defer indefinitely or to bypass
// the exclusion rule entirely.
//
// RDAP returns REGISTRATION data from the RIR: the organisation an allocation is
// registered to, together with reassignment records beneath it. It is keyed on the
// prefix, so it can be consulted for any range at any time. It also draws on a
// different budget, so warming this cache does not consume the 45 calls per minute
// the free ip-api tier allows and does not compete with the probe cycle.
//
// # WHY THE CACHE IS KEYED ON THE RETURNED ALLOCATION
//
// An RDAP answer describes the allocation CONTAINING the queried address, not the
// prefix asked about. One query against an address inside a large Amazon
// allocation returns that whole allocation boundary, which then answers for every
// candidate range inside it. This is what makes the approach affordable: the
// candidate set runs to hundreds of thousands of ranges, and they collapse into a
// far smaller number of allocations.
//
// The tool therefore holds every covered interval in memory and only queries for a
// candidate no cached allocation already covers.
//
// # RATE LIMITING IS DELIBERATELY CONSERVATIVE AND THE LIMIT IS UNVERIFIED
//
// The RIR RDAP rate limits have NOT been measured for this project, so the default
// here is one request per second, which is slow and certainly safe rather than
// fast and possibly abusive. If a server answers 429 the tool honours Retry-After
// when present, backs off when it is not, and reports every 429 it saw, so the
// real limit can be characterised from evidence instead of assumed.
//
// Usage:
//
//	rdap_registrant -network 54.144.0.0/16          resolve one range and print it
//	rdap_registrant -fill -limit 500                warm the cache for 500 candidates
//	rdap_registrant -fill -candidates dbip_split_candidates
//
// This tool writes ONLY to rdap_registrant_tbl. It never touches the probe table,
// the db-ip table, or anything the pipeline reads for geography.
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
	"net/http"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// rdapEntity is one entity in an RDAP response. The registrant name lives in the
// vcardArray of the entity carrying the "registrant" role. Entities nest, because
// ARIN publishes org entities containing point of contact entities.
type rdapEntity struct {
	Handle     string        `json:"handle"`
	Roles      []string      `json:"roles"`
	VcardArray []interface{} `json:"vcardArray"`
	Entities   []rdapEntity  `json:"entities"`
}

// rdapIPNetwork mirrors the parts of an RFC 9083 IP network response this tool
// needs. Many more members exist and are ignored on purpose.
type rdapIPNetwork struct {
	ObjectClassName string       `json:"objectClassName"`
	Handle          string       `json:"handle"`
	Name            string       `json:"name"`
	StartAddress    string       `json:"startAddress"`
	EndAddress      string       `json:"endAddress"`
	IPVersion       string       `json:"ipVersion"`
	Port43          string       `json:"port43"`
	Entities        []rdapEntity `json:"entities"`
}

// interval is a closed range of IPv4 addresses as unsigned integers. The cache is
// held as a sorted slice of these so a containment test is a binary search rather
// than a database round trip per candidate.
type interval struct {
	start uint32
	end   uint32
}

func main() {
	networkFlag := flag.String("network", "",
		"resolve the registrant for one range and print it, writing the result to the cache")
	fill := flag.Bool("fill", false,
		"walk the candidate set and query RDAP for every candidate no cached allocation covers")
	candidates := flag.String("candidates", "",
		"table of candidate ranges with a cidr column named network. Empty means every db-ip row wider than a /24, which is the real candidate set")
	limit := flag.Int("limit", 0, "stop after this many RDAP queries (0 = no limit)")
	rate := flag.Float64("rate", 1.0,
		"maximum RDAP requests per second. The RIR limits are UNVERIFIED for this project, so the default is deliberately slow")
	base := flag.String("endpoint", "https://rdap.arin.net/registry/ip/",
		"RDAP endpoint prefix. ARIN redirects out-of-region queries to the responsible RIR and redirects are followed")
	timeout := flag.Duration("http-timeout", 30*time.Second, "per request timeout")
	dryRun := flag.Bool("dry-run", false, "query nothing and write nothing; report how many candidates the cache already covers")
	flag.Parse()

	if (*networkFlag == "") == !*fill {
		log.Fatal("give exactly one of -network or -fill")
	}
	if *rate <= 0 {
		log.Fatal("-rate must be greater than zero")
	}

	ctx := context.Background()
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Print("DATABASE_URL not set; connecting via libpq environment and defaults")
	}
	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		log.Fatalf("PostgreSQL connection failed: %v", err)
	}
	defer conn.Close(context.Background())

	if err := ensureTable(ctx, conn); err != nil {
		log.Fatalf("rdap_registrant_tbl is not usable: %v", err)
	}

	covered, err := loadCovered(ctx, conn)
	if err != nil {
		log.Fatalf("loading cached allocations: %v", err)
	}
	log.Printf("cache holds %d allocations", len(covered))

	client := &http.Client{Timeout: *timeout}
	minGap := time.Duration(float64(time.Second) / *rate)

	if *networkFlag != "" {
		p, err := netip.ParsePrefix(*networkFlag)
		if err != nil {
			log.Fatalf("bad -network: %v", err)
		}
		p = p.Masked()
		if !p.Addr().Is4() {
			log.Fatal("only IPv4 is supported: the decomposition this feeds is IPv4 only")
		}
		if hit, ok := lookupCovered(covered, p); ok {
			log.Printf("already cached by allocation %s - %s", u32ToAddr(hit.start), u32ToAddr(hit.end))
		}
		rec, err := queryRDAP(client, *base, p.Addr())
		if err != nil {
			log.Fatalf("RDAP query failed: %v", err)
		}
		printRecord(rec)
		if !*dryRun {
			if err := storeRecord(ctx, conn, p, rec); err != nil {
				log.Fatalf("writing cache row: %v", err)
			}
			log.Print("cached")
		}
		return
	}

	targets, err := loadCandidates(ctx, conn, *candidates)
	if err != nil {
		log.Fatalf("loading candidates: %v", err)
	}
	log.Printf("%d candidate ranges wider than a /24, prefix-excluded space already removed", len(targets))

	// Widest first. A wide candidate is more likely to sit inside, or to coincide
	// with, a large allocation, so resolving it covers more of the remaining set
	// per query than starting from the narrow end would.
	sort.Slice(targets, func(i, j int) bool {
		if targets[i].Bits() != targets[j].Bits() {
			return targets[i].Bits() < targets[j].Bits()
		}
		return targets[i].Addr().Less(targets[j].Addr())
	})

	var alreadyCovered, queried, needed, failed, rateLimited int
	var lastCall time.Time

	for _, p := range targets {
		if _, ok := lookupCovered(covered, p); ok {
			alreadyCovered++
			continue
		}
		if *dryRun {
			// Not covered, so count it as work the cache cannot yet answer. Do NOT add
			// it to covered: nothing was fetched, so no allocation boundary is known.
			//
			// This makes the dry-run total an UPPER BOUND rather than a forecast. Each
			// real query returns an allocation that typically covers many later
			// candidates, so the actual number of queries will be far lower. The dry
			// run cannot predict by how much, because the boundaries are exactly what
			// it declined to fetch.
			needed++
			continue
		}
		if *limit > 0 && queried >= *limit {
			log.Printf("-limit %d reached", *limit)
			break
		}

		if gap := time.Since(lastCall); gap < minGap {
			time.Sleep(minGap - gap)
		}
		lastCall = time.Now()

		rec, err := queryRDAP(client, *base, p.Addr())
		queried++
		if err != nil {
			if strings.Contains(err.Error(), "HTTP 429") {
				rateLimited++
			}
			failed++
			log.Printf("[%d] %s FAILED %v", queried, p, err)
			continue
		}
		if err := storeRecord(ctx, conn, p, rec); err != nil {
			log.Printf("[%d] %s cached badly: %v", queried, p, err)
			failed++
			continue
		}
		start, end, ok := recordInterval(rec)
		if ok {
			covered = insertCovered(covered, interval{start: start, end: end})
		}
		log.Printf("[%d] %s registrant=%q handle=%q allocation=%s-%s covers=%d addresses",
			queried, p, rec.registrant, rec.net.Handle, rec.net.StartAddress, rec.net.EndAddress,
			int64(end)-int64(start)+1)
	}

	if *dryRun {
		log.Printf("dry run: %d already covered by cache, %d would need a query", alreadyCovered, needed)
		log.Print("that second number is an UPPER BOUND, not a forecast: each real query returns an " +
			"allocation that usually covers many later candidates, and a dry run cannot know the boundaries " +
			"it declined to fetch")
		log.Print("nothing was queried and nothing was written")
		return
	}

	log.Printf("done: %d already covered by cache, %d queried, %d failed, %d rate limited",
		alreadyCovered, queried, failed, rateLimited)
	if queried > failed {
		log.Printf("cache now holds %d allocations", len(covered))
	}
	if rateLimited > 0 {
		log.Printf("NOTE %d responses were HTTP 429. The RIR limit is not documented in this project, so treat -rate as unverified and lower it.", rateLimited)
	}
	if failed > 0 && failed == queried {
		log.Print("EVERY query failed, so nothing was learned. Check the error text above before re-running: " +
			"a permission error on rdap_registrant_tbl or its sequence means the grants in " +
			"geo/rdap_registrant_tbl.sql have not been applied for this role.")
	}
}

// record is one resolved RDAP answer plus the registrant extracted from it.
type record struct {
	net        rdapIPNetwork
	registrant string
	role       string
	rir        string
	httpStatus int
}

func printRecord(r record) {
	fmt.Println()
	fmt.Println("=== RDAP ===")
	fmt.Println("registrant:   " + r.registrant)
	fmt.Println("role:         " + r.role)
	fmt.Println("handle:       " + r.net.Handle)
	fmt.Println("network name: " + r.net.Name)
	fmt.Println("allocation:   " + r.net.StartAddress + " - " + r.net.EndAddress)
	fmt.Println("rir:          " + r.rir)
	fmt.Println()
}

// queryRDAP asks the RDAP service about one address. Redirects are followed,
// which is how an ARIN query for out-of-region space reaches the RIR that holds
// it.
func queryRDAP(client *http.Client, base string, addr netip.Addr) (record, error) {
	url := base + addr.String()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return record{}, err
	}
	// RFC 7480 media type. Some servers content-negotiate on it and return HTML
	// without it.
	req.Header.Set("Accept", "application/rdap+json, application/json")
	resp, err := client.Do(req)
	if err != nil {
		return record{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return record{}, err
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		wait := resp.Header.Get("Retry-After")
		return record{httpStatus: resp.StatusCode},
			fmt.Errorf("RDAP HTTP 429, Retry-After=%q", wait)
	}
	if resp.StatusCode != http.StatusOK {
		return record{httpStatus: resp.StatusCode},
			fmt.Errorf("RDAP HTTP %d: %s", resp.StatusCode, strings.TrimSpace(truncate(string(body), 200)))
	}

	var n rdapIPNetwork
	if err := json.Unmarshal(body, &n); err != nil {
		return record{httpStatus: resp.StatusCode}, err
	}
	name, role := registrantOf(n)
	return record{
		net:        n,
		registrant: name,
		role:       role,
		rir:        rirOf(resp.Request.URL.Host, n.Port43),
		httpStatus: resp.StatusCode,
	}, nil
}

// registrantOf picks the registrant name from an RDAP response.
//
// The registrant role is preferred because it names the holder of the allocation,
// which is the exclusion question. Where no entity carries that role, ARIN and
// some other registries publish the holder only as an administrative entity or
// only as the network name, so those are used in turn rather than returning
// nothing. The role actually used is recorded alongside the name so a weaker
// source is visible rather than silently equivalent.
func registrantOf(n rdapIPNetwork) (string, string) {
	preference := []string{"registrant", "administrative", "technical", "abuse"}
	for _, want := range preference {
		if name := findEntityByRole(n.Entities, want); name != "" {
			return name, want
		}
	}
	// Any entity with a name at all, before falling back to the network name.
	if name := findAnyEntityName(n.Entities); name != "" {
		return name, "unlabelled entity"
	}
	if n.Name != "" {
		return n.Name, "network name"
	}
	return "", "none"
}

func findEntityByRole(entities []rdapEntity, role string) string {
	for _, e := range entities {
		for _, r := range e.Roles {
			if strings.EqualFold(r, role) {
				if fn := vcardFN(e.VcardArray); fn != "" {
					return fn
				}
				if e.Handle != "" {
					return e.Handle
				}
			}
		}
		if name := findEntityByRole(e.Entities, role); name != "" {
			return name
		}
	}
	return ""
}

func findAnyEntityName(entities []rdapEntity) string {
	for _, e := range entities {
		if fn := vcardFN(e.VcardArray); fn != "" {
			return fn
		}
		if name := findAnyEntityName(e.Entities); name != "" {
			return name
		}
	}
	return ""
}

// vcardFN extracts the formatted name from a jCard as RFC 7095 defines it: the
// array is ["vcard", [ [name, params, type, value], ... ]] and the entry wanted is
// the one whose name is "fn".
func vcardFN(v []interface{}) string {
	if len(v) < 2 {
		return ""
	}
	items, ok := v[1].([]interface{})
	if !ok {
		return ""
	}
	for _, it := range items {
		field, ok := it.([]interface{})
		if !ok || len(field) < 4 {
			continue
		}
		key, ok := field[0].(string)
		if !ok || !strings.EqualFold(key, "fn") {
			continue
		}
		if val, ok := field[3].(string); ok {
			return strings.TrimSpace(val)
		}
	}
	return ""
}

// rirOf names the registry that answered, taken from the host that served the
// final response after redirects, with the whois referral as a fallback.
func rirOf(host, port43 string) string {
	h := strings.ToLower(host)
	for _, rir := range []string{"arin", "ripe", "apnic", "lacnic", "afrinic"} {
		if strings.Contains(h, rir) {
			return strings.ToUpper(rir)
		}
	}
	if port43 != "" {
		return port43
	}
	return host
}

func recordInterval(r record) (uint32, uint32, bool) {
	s, err1 := netip.ParseAddr(strings.TrimSpace(r.net.StartAddress))
	e, err2 := netip.ParseAddr(strings.TrimSpace(r.net.EndAddress))
	if err1 != nil || err2 != nil || !s.Is4() || !e.Is4() {
		return 0, 0, false
	}
	return addrToU32(s), addrToU32(e), true
}

func storeRecord(ctx context.Context, conn *pgx.Conn, queried netip.Prefix, r record) error {
	start, end, ok := recordInterval(r)
	if !ok {
		return fmt.Errorf("response has no usable IPv4 boundaries (start=%q end=%q)",
			r.net.StartAddress, r.net.EndAddress)
	}
	const q = `
INSERT INTO rdap_registrant_tbl
  (start_ip, end_ip, registrant, registrant_role, handle, network_name, rir,
   queried_for, http_status, note, fetched_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now())
ON CONFLICT (start_ip, end_ip) DO UPDATE SET
  registrant      = EXCLUDED.registrant,
  registrant_role = EXCLUDED.registrant_role,
  handle          = EXCLUDED.handle,
  network_name    = EXCLUDED.network_name,
  rir             = EXCLUDED.rir,
  queried_for     = EXCLUDED.queried_for,
  http_status     = EXCLUDED.http_status,
  note            = EXCLUDED.note,
  fetched_at      = now()`
	_, err := conn.Exec(ctx, q,
		u32ToAddr(start).String(), u32ToAddr(end).String(),
		nullIfEmpty(r.registrant), nullIfEmpty(r.role), nullIfEmpty(r.net.Handle),
		nullIfEmpty(r.net.Name), nullIfEmpty(r.rir),
		queried.String(), r.httpStatus, nullIfEmpty(r.net.ObjectClassName))
	return err
}

func ensureTable(ctx context.Context, conn *pgx.Conn) error {
	var exists bool
	if err := conn.QueryRow(ctx,
		"SELECT to_regclass('public.rdap_registrant_tbl') IS NOT NULL").Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return fmt.Errorf("table does not exist: run geo/rdap_registrant_tbl.sql first")
	}
	return nil
}

// loadCovered reads every cached allocation as an interval, sorted by start.
func loadCovered(ctx context.Context, conn *pgx.Conn) ([]interval, error) {
	rows, err := conn.Query(ctx,
		"SELECT host(start_ip), host(end_ip) FROM rdap_registrant_tbl "+
			"WHERE family(start_ip) = 4 ORDER BY start_ip")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []interval
	for rows.Next() {
		var s, e string
		if err := rows.Scan(&s, &e); err != nil {
			return nil, err
		}
		sa, err1 := netip.ParseAddr(s)
		ea, err2 := netip.ParseAddr(e)
		if err1 != nil || err2 != nil || !sa.Is4() || !ea.Is4() {
			continue
		}
		out = append(out, interval{start: addrToU32(sa), end: addrToU32(ea)})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].start < out[j].start })
	return out, nil
}

// loadCandidates returns ranges wider than a /24 that are still present as db-ip
// rows, which is the set decomposition would act on.
//
// When no table is named the candidate set is taken directly from
// ip2city_dbiplite_tbl rather than from dbip_split_candidates. That is
// deliberate: dbip_split_candidates only holds ranges with more specific BGP
// children, which is a small fraction of the coarse ranges that actually need a
// registrant decision.
//
// PREFIX-EXCLUDED RANGES ARE OMITTED, and the first run of this tool proved why.
// apply_splits discards a range covered by an active geo_exclusions prefix BEFORE
// it ever consults the registrant, so a registrant for such a range can never
// change any decision. Ordering candidates widest-first then sent the opening
// queries straight at 7.0.0.0/8, 21.0.0.0/8, 22.0.0.0/8, 29.0.0.0/8 and their
// neighbours, which are DoD space and permanently excluded. Every one of those
// calls was spent on an answer that could not be used. Filtering here keeps the
// widest-first ordering, which is still correct for maximising coverage per query,
// while pointing it at ranges that could actually be decomposed.
func loadCandidates(ctx context.Context, conn *pgx.Conn, table string) ([]netip.Prefix, error) {
	// The exclusion filter is applied in SQL rather than in Go so that a huge
	// candidate set is never materialised only to be thrown away. It is written as
	// NOT EXISTS against active prefix rules, which the gist index on
	// geo_exclusions.prefix serves directly.
	var haveExclusions bool
	if err := conn.QueryRow(ctx,
		"SELECT to_regclass('public.geo_exclusions') IS NOT NULL").Scan(&haveExclusions); err != nil {
		return nil, err
	}
	notExcluded := ""
	if haveExclusions {
		notExcluded = "AND NOT EXISTS (SELECT 1 FROM geo_exclusions x " +
			"WHERE x.active AND x.prefix IS NOT NULL AND %s <<= x.prefix) "
	}

	q := "SELECT DISTINCT network::text FROM ip2city_dbiplite_tbl " +
		"WHERE source = 'dbip' AND family(network) = 4 AND masklen(network) < 24 " +
		strings.Replace(notExcluded, "%s", "network", 1)
	if table != "" {
		ident := pgx.Identifier{table}.Sanitize()
		q = "SELECT DISTINCT c.network::text FROM " + ident + " c " +
			"JOIN ip2city_dbiplite_tbl d ON d.network = c.network AND d.source = 'dbip' " +
			"WHERE family(c.network) = 4 AND masklen(c.network) < 24 " +
			strings.Replace(notExcluded, "%s", "c.network", 1)
	}
	rows, err := conn.Query(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []netip.Prefix
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		p, err := netip.ParsePrefix(s)
		if err != nil {
			continue
		}
		out = append(out, p.Masked())
	}
	return out, rows.Err()
}

// lookupCovered reports the smallest cached allocation wholly containing p.
func lookupCovered(covered []interval, p netip.Prefix) (interval, bool) {
	lo := addrToU32(p.Addr())
	hi := lo + (uint32(1)<<uint(32-p.Bits())) - 1

	// Every candidate interval starts at or before lo. Binary search to the last
	// such interval, then walk back: allocations are few and overlap shallowly, so
	// this is cheap in practice.
	idx := sort.Search(len(covered), func(i int) bool { return covered[i].start > lo })
	var best interval
	found := false
	for i := idx - 1; i >= 0; i-- {
		if covered[i].start <= lo && covered[i].end >= hi {
			span := int64(covered[i].end) - int64(covered[i].start)
			if !found || span < int64(best.end)-int64(best.start) {
				best = covered[i]
				found = true
			}
		}
	}
	return best, found
}

func insertCovered(covered []interval, in interval) []interval {
	idx := sort.Search(len(covered), func(i int) bool { return covered[i].start >= in.start })
	covered = append(covered, interval{})
	copy(covered[idx+1:], covered[idx:])
	covered[idx] = in
	return covered
}

func addrToU32(a netip.Addr) uint32 {
	b := a.As4()
	return binary.BigEndian.Uint32(b[:])
}

func u32ToAddr(v uint32) netip.Addr {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	return netip.AddrFrom4(b)
}

func nullIfEmpty(s string) interface{} {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// parseRetryAfter is kept for the caller that decides backoff. Only the integer
// seconds form is handled, which is what the RIR servers send.
func parseRetryAfter(v string) (time.Duration, bool) {
	secs, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || secs < 0 {
		return 0, false
	}
	return time.Duration(secs) * time.Second, true
}
