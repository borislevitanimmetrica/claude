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
// # THIS IS A STORE, NOT A CACHE, AND THAT DISTINCTION WAS THE BUG
//
// Everything above calls rdap_registrant_tbl a cache. It is not one. A cache has
// an invalidation policy and falls back to origin on a miss. This table had
// neither:
//
//   - No consumer filtered on fetched_at. Verified 2026-11-09 by grepping the
//     whole tree: the column was written here and read by nothing.
//   - The fill never re-queried a covered candidate, so once an allocation
//     covered a range, that range was never asked about again.
//   - apply_splits makes zero HTTP calls, so a miss cannot fall back to origin.
//     It defers the range instead.
//
// The consequence was that a row fetched in September still answered in November
// and nothing would ever refresh it. IPv4 registrations do change: ARIN 8.3 and
// 8.4 transfers, reassignments added and withdrawn, org renames and mergers. The
// RATE of change for the allocations held here has NOT been measured.
//
// -max-age is the provision. An allocation older than it is omitted from the
// covered set, so its candidates are queried again and storeRecord's ON CONFLICT
// updates the row in place. Refresh needs no deletion and is idempotent. The
// default is 0, meaning never expire, so existing invocations keep their old
// behaviour; a run with 0 now says so in its opening log line rather than leaving
// it implicit.
//
// # RETIREMENT BY CONTAINMENT HAS A COST THAT -verify-sample MEASURES
//
// Skipping a candidate that a cached allocation contains means a narrower ARIN
// reassignment for that candidate is never fetched. Consumers prefer the
// narrowest containing allocation but cannot prefer an absent row. -verify-sample
// queries already-covered candidates directly and reports how often a narrower
// allocation exists and how often it changes the registrant.
//
// Usage:
//
//	rdap_registrant -network 54.144.0.0/16          resolve one range and print it
//	rdap_registrant -fill -limit 500                warm the store for 500 candidates
//	rdap_registrant -fill -candidates dbip_split_candidates
//
//	rdap_registrant -fill -max-age 720h             re-query anything older than 30 days
//	rdap_registrant -fill -verify-sample 200        measure what containment retirement costs
//
//	give decomposed /25 children their own identification, which needs
//	-ignore-cache because a child always sits inside its parent's allocation:
//	rdap_registrant -fill -sources routeviews -max-masklen 25 -ignore-cache
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
	sources := flag.String("sources", "dbip",
		"comma-separated ip2city_dbiplite_tbl.source values a candidate may carry. apply_splits writes "+
			"decomposed children as 'routeviews', so 'routeviews' selects them and 'dbip,routeviews' selects both")
	maxMasklen := flag.Int("max-masklen", 23,
		"accept candidates with masklen <= this. 23 reproduces the historical behaviour of taking only "+
			"ranges wider than a /24. Set 25 to include decomposed /25 children")
	ignoreCache := flag.Bool("ignore-cache", false,
		"query EVERY candidate even when a cached allocation already covers it. REQUIRED to give decomposed "+
			"subranges their own identification, because a child always sits inside its parent's cached "+
			"allocation and would otherwise be skipped. Costs one query per candidate with no containment saving")
	minCoverPrefix := flag.Int("min-cover-prefix", 0,
		"an allocation WIDER than this prefix length may not retire a candidate, so the candidate is "+
			"queried directly instead. 0 lets any allocation retire, which is the historical behaviour. "+
			"Measured 2026-11-09 on a 200-candidate sample: 23.5 per cent of retired candidates had a "+
			"narrower allocation available, and the worst offenders were /8-wide registry rows such as "+
			"192.0.0.0-192.255.255.255 'Internet Assigned Numbers Authority', which hid "+
			"'University of Texas System' at 192.88.12.0/23")
	maxAge := flag.Duration("max-age", 0,
		"treat a cached allocation fetched longer ago than this as absent, so its candidates are queried "+
			"again and the row is updated in place (0 = never expire, which is the historical behaviour)")
	verifySample := flag.Int("verify-sample", 0,
		"measure instead of filling: take this many candidates the cache ALREADY covers, query each one "+
			"directly, and report how often the RIR returns a NARROWER allocation than the cached one and "+
			"how often that changes the registrant. Needs -fill for the candidate loading")
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
	// BOUND THE CLOSE. This was conn.Close(context.Background()), which has no
	// deadline, and it is the ONLY unbounded operation between the final log line
	// and process exit. On 2026-11-09 a completed fill printed its summary and
	// then never returned to the shell, which is exactly the shape an
	// indefinitely blocking Terminate on a wedged socket produces.
	//
	// I have NOT confirmed that was the cause: confirming it needs a goroutine
	// dump from the stuck process, and the process in question was ended. The fix
	// is correct regardless, because a network close at process exit must not be
	// able to outlive the work it is tidying up after. Every result is already
	// committed by storeRecord one query at a time, so abandoning the close costs
	// nothing.
	defer func() {
		closeCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := conn.Close(closeCtx); err != nil {
			log.Printf("closing the database connection: %v (results were already committed)", err)
		}
	}()

	if err := ensureTable(ctx, conn); err != nil {
		log.Fatalf("rdap_registrant_tbl is not usable: %v", err)
	}

	covered, err := loadCovered(ctx, conn, *maxAge)
	if err != nil {
		log.Fatalf("loading cached allocations: %v", err)
	}
	if *maxAge > 0 {
		total, err := countCached(ctx, conn)
		if err != nil {
			log.Fatalf("counting cached allocations: %v", err)
		}
		log.Printf("cache holds %d allocations, of which %d are within -max-age %s and %d have expired",
			total, len(covered), *maxAge, total-len(covered))
	} else {
		log.Printf("cache holds %d allocations; -max-age is 0, so NOTHING EXPIRES and a row fetched "+
			"months ago still answers", len(covered))
	}
	logCacheAges(ctx, conn)

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

	srcList := strings.Split(*sources, ",")
	for i := range srcList {
		srcList[i] = strings.TrimSpace(srcList[i])
	}
	if *maxMasklen < 1 || *maxMasklen > 32 {
		log.Fatalf("-max-masklen must be between 1 and 32, not %d", *maxMasklen)
	}
	targets, err := loadCandidates(ctx, conn, *candidates, srcList, *maxMasklen)
	if err != nil {
		log.Fatalf("loading candidates: %v", err)
	}
	log.Printf("%d candidate ranges at /%d or wider from source(s) %v, prefix-excluded space already removed",
		len(targets), *maxMasklen, srcList)

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

	if *verifySample > 0 {
		runVerifySample(ctx, conn, client, *base, targets, covered,
			*verifySample, minGap, *dryRun)
		return
	}

	if *ignoreCache {
		log.Printf("-ignore-cache is set, so all %d candidates will be queried directly and containment "+
			"saves nothing. At -rate %g that is about %s", len(targets), *rate,
			(time.Duration(len(targets)) * minGap).Round(time.Minute))
	}

	var coverTooWide int64
	if *minCoverPrefix > 0 {
		coverTooWide = int64(1) << uint(32-*minCoverPrefix)
		log.Printf("-min-cover-prefix %d: an allocation spanning more than %d addresses will not retire "+
			"a candidate", *minCoverPrefix, coverTooWide)
	}
	var tooWideToRetire int

	for _, p := range targets {
		if hit, ok := lookupCovered(covered, p); ok && !*ignoreCache {
			// A very wide allocation is poor evidence about a narrow candidate
			// inside it. Retiring on one trades a query for an answer that may name
			// the registry rather than the holder.
			if coverTooWide == 0 || int64(hit.end)-int64(hit.start)+1 <= coverTooWide {
				alreadyCovered++
				continue
			}
			tooWideToRetire++
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
	if tooWideToRetire > 0 {
		log.Printf("  %d candidates WERE covered but only by an allocation wider than /%d, so they were "+
			"queried directly instead", tooWideToRetire, *minCoverPrefix)
	}
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

// cachedRegistrant reads the registrant of one held allocation, identified by its
// exact boundaries, which are the table's unique key.
func cachedRegistrant(ctx context.Context, conn *pgx.Conn, it interval) (string, error) {
	var reg *string
	err := conn.QueryRow(ctx,
		"SELECT registrant FROM rdap_registrant_tbl WHERE start_ip = $1::inet AND end_ip = $2::inet",
		u32ToAddr(it.start).String(), u32ToAddr(it.end).String()).Scan(&reg)
	if err != nil {
		return "", err
	}
	if reg == nil {
		return "", nil
	}
	return *reg, nil
}

// runVerifySample measures the one thing retirement by containment can cost.
//
// The fill skips any candidate a cached allocation wholly contains. ARIN returns
// the MOST SPECIFIC network containing the address asked about, so if a
// reassignment narrower than the cached allocation exists for a skipped
// candidate, it is never fetched. apply_splits and landmark2zip_tbl both prefer
// the narrowest containing allocation, but neither can prefer a row that is
// absent.
//
// Whether that costs anything cannot be answered from held data, because the
// answer IS what was declined. So: take candidates the cache already covers,
// query them directly, and compare.
//
// The decision-relevant number is not how often a narrower allocation exists. It
// is how often the narrower allocation carries a DIFFERENT registrant, because a
// narrower allocation with the same registrant changes no exclusion decision.
//
// Fresh answers are stored unless -dry-run. A narrower allocation is strictly
// more precise and the consumers already prefer it, so storing it improves the
// cache rather than disturbing it. It does mean a second run reports those as
// identical.
func runVerifySample(ctx context.Context, conn *pgx.Conn, client *http.Client, base string,
	targets []netip.Prefix, covered []interval, want int, minGap time.Duration, dryRun bool) {

	type probe struct {
		p   netip.Prefix
		cov interval
	}
	var pool []probe
	for _, p := range targets {
		if hit, ok := lookupCovered(covered, p); ok {
			pool = append(pool, probe{p: p, cov: hit})
		}
	}
	log.Printf("%d of %d candidates are already covered by the cache", len(pool), len(targets))
	if len(pool) == 0 {
		log.Print("nothing to verify: no candidate is covered, so containment has retired nothing")
		return
	}
	if want > len(pool) {
		want = len(pool)
		log.Printf("only %d covered candidates exist, so sampling all of them", want)
	}

	// Even stride, not the first N. targets is sorted widest-first, so the first N
	// would be entirely wide candidates and would say nothing about the /22 and
	// /23 bulk where four fifths of the set lives.
	stride := len(pool) / want
	if stride < 1 {
		stride = 1
	}
	log.Printf("sampling %d of them at a stride of %d, so the sample spans every prefix width", want, stride)

	var narrower, identical, other, regChanged, staleRegistrant, failed, done int
	var lastCall time.Time
	for i := 0; i < len(pool) && done < want; i += stride {
		it := pool[i]
		if gap := time.Since(lastCall); gap < minGap {
			time.Sleep(minGap - gap)
		}
		lastCall = time.Now()
		done++

		rec, err := queryRDAP(client, base, it.p.Addr())
		if err != nil {
			failed++
			log.Printf("[%d/%d] %s FAILED %v", done, want, it.p, err)
			continue
		}
		start, end, ok := recordInterval(rec)
		if !ok {
			failed++
			log.Printf("[%d/%d] %s returned no usable IPv4 boundaries", done, want, it.p)
			continue
		}
		cachedReg, regErr := cachedRegistrant(ctx, conn, it.cov)
		if regErr != nil {
			log.Printf("[%d/%d] %s could not read the cached registrant: %v", done, want, it.p, regErr)
		}
		cachedSpan := int64(it.cov.end) - int64(it.cov.start)
		freshSpan := int64(end) - int64(start)

		switch {
		case start == it.cov.start && end == it.cov.end:
			identical++
			// Identical boundaries make this a STALENESS test rather than a
			// precision test: the registry returned the same allocation, so any
			// difference in the registrant is drift since the row was fetched.
			// This is the only measurement of the change rate the project has.
			if !strings.EqualFold(strings.TrimSpace(cachedReg), strings.TrimSpace(rec.registrant)) {
				staleRegistrant++
				log.Printf("[%d/%d] %s STALE same allocation, registrant %q -> %q",
					done, want, it.p, cachedReg, rec.registrant)
			} else {
				log.Printf("[%d/%d] %s same allocation, same registrant", done, want, it.p)
			}
		case freshSpan < cachedSpan:
			narrower++
			changed := !strings.EqualFold(strings.TrimSpace(cachedReg), strings.TrimSpace(rec.registrant))
			if changed {
				regChanged++
			}
			log.Printf("[%d/%d] %s NARROWER cached %s-%s %q -> fresh %s-%s %q registrant_changed=%t",
				done, want, it.p,
				u32ToAddr(it.cov.start), u32ToAddr(it.cov.end), cachedReg,
				rec.net.StartAddress, rec.net.EndAddress, rec.registrant, changed)
		default:
			other++
			log.Printf("[%d/%d] %s OTHER cached span %d, fresh span %d", done, want, it.p,
				cachedSpan+1, freshSpan+1)
		}
		if !dryRun {
			if err := storeRecord(ctx, conn, it.p, rec); err != nil {
				log.Printf("[%d/%d] %s cached badly: %v", done, want, it.p, err)
			}
		}
	}

	answered := done - failed
	log.Printf("verify-sample: %d sampled, %d answered, %d failed", done, answered, failed)
	log.Printf("  identical to the cached allocation: %d", identical)
	log.Printf("  NARROWER than the cached allocation: %d", narrower)
	log.Printf("  neither (wider or disjoint boundaries): %d", other)
	if answered > 0 {
		log.Printf("  narrower rate: %.2f per cent of answered queries",
			100*float64(narrower)/float64(answered))
	}
	if identical > 0 {
		log.Printf("  STALENESS: of the %d identical allocations, %d had a registrant that has CHANGED "+
			"since the row was stored (%.2f per cent). Identical boundaries make that drift, not "+
			"imprecision, and it is the only measurement of the change rate this project has. Use it "+
			"to choose -max-age rather than picking a duration by feel",
			identical, staleRegistrant, 100*float64(staleRegistrant)/float64(identical))
	}
	if narrower > 0 {
		log.Printf("  of those %d narrower answers, %d carry a DIFFERENT registrant. That is the number "+
			"that decides whether retirement by containment costs anything: a narrower allocation with "+
			"the same registrant changes no exclusion decision", narrower, regChanged)
	} else {
		log.Print("  no narrower allocation was found in this sample, which is evidence that retirement " +
			"by containment loses nothing at this sample size. It is not proof for the whole set")
	}
	if dryRun {
		log.Print("  -dry-run: nothing was written")
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
// SEVERAL ENTITIES CAN CARRY THE REGISTRANT ROLE, and taking the first one is
// wrong. Measured against live RIPE for 51.180.0.0 - 51.181.255.255, three do:
//
//	MNT-ADSI          fn "MNT-ADSI"          a maintainer object
//	ORG-ARI3-RIPE     fn "A100 ROW Inc"      the actual organisation
//	RIPE-NCC-HM-MNT   fn "RIPE-NCC-HM-MNT"   RIPE's hostmaster maintainer
//
// Document order put the maintainer first, so the cache recorded "MNT-ADSI" as the
// registrant of 26 allocations, along with APPLE-MNT, MICROSOFT-MAINT, ORCL-MNT and
// OPENDNS-MNT from the same fault. A maintainer is an access-control object, not a
// holder, and its name does not match the ARIN-style names any pattern is written
// against.
//
// The discriminator that generalises is that a maintainer's formatted name equals
// its handle, because it has no separate human name, whereas a real organisation
// has fn "A100 ROW Inc" against handle "ORG-ARI3-RIPE". Handle shape is used as a
// second signal.
func registrantOf(n rdapIPNetwork) (string, string) {
	preference := []string{"registrant", "administrative", "technical", "abuse"}
	for _, want := range preference {
		if name := bestEntityForRole(n.Entities, want); name != "" {
			return name, want
		}
	}
	// Any entity with a name at all, before falling back to the network name.
	if name := findAnyEntityName(n.Entities); name != "" {
		return name, "unlabelled entity"
	}
	// A record with no entities whose name is an administrative placeholder is NOT
	// a registrant answer. RIPE returns the whole of 151.0.0.0/8 as
	// RIPE-NCC-MANAGED-ADDRESS-BLOCK with no entities at all, and recording that as
	// a registrant spanning 16.7 million addresses is worse than recording nothing:
	// it suppresses every future query inside the block and hands a placeholder to
	// anything that reads the registrant.
	if isPlaceholderName(n.Name) {
		return "", "placeholder:" + n.Name
	}
	if n.Name != "" {
		return n.Name, "network name"
	}
	return "", "none"
}

// bestEntityForRole returns the most organisation-like name among all entities
// carrying the role, searching nested entities too.
func bestEntityForRole(entities []rdapEntity, role string) string {
	type cand struct {
		name  string
		score int
	}
	var found []cand

	var walk func([]rdapEntity)
	walk = func(list []rdapEntity) {
		for _, e := range list {
			for _, r := range e.Roles {
				if !strings.EqualFold(r, role) {
					continue
				}
				fn := vcardFN(e.VcardArray)
				name := fn
				if name == "" {
					name = e.Handle
				}
				if name == "" {
					continue
				}
				score := 0
				if isMaintainerHandle(e.Handle) || isMaintainerHandle(fn) {
					// An access-control object, never the holder.
					score -= 10
				}
				if strings.HasPrefix(strings.ToUpper(e.Handle), "ORG-") {
					score += 3
				}
				if fn != "" && !strings.EqualFold(fn, e.Handle) {
					// A human name distinct from the handle is the strongest signal
					// that this entity is a real organisation.
					score += 2
				}
				found = append(found, cand{name: name, score: score})
				break
			}
			walk(e.Entities)
		}
	}
	walk(entities)

	best := ""
	bestScore := 0
	for i, c := range found {
		if i == 0 || c.score > bestScore {
			best, bestScore = c.name, c.score
		}
	}
	// Every candidate was a maintainer, so there is no holder to report.
	if bestScore <= -10 {
		return ""
	}
	return best
}

// isMaintainerHandle recognises RIPE and APNIC maintainer objects, which carry the
// registrant role but are access-control records rather than holders.
func isMaintainerHandle(h string) bool {
	u := strings.ToUpper(strings.TrimSpace(h))
	if u == "" {
		return false
	}
	return strings.HasPrefix(u, "MNT-") ||
		strings.HasSuffix(u, "-MNT") ||
		strings.HasSuffix(u, "-MAINT")
}

// isPlaceholderName recognises administrative filler in the network name field. A
// record carrying one of these is a statement that the registry has no assignment
// recorded for the range, not a statement about who holds it.
func isPlaceholderName(name string) bool {
	u := strings.ToUpper(strings.TrimSpace(name))
	if u == "" {
		return false
	}
	for _, frag := range []string{
		"MANAGED-ADDRESS-BLOCK",
		"NON-RIPE-NCC",
		"AVAILABLE",
		"IANA-BLK",
		"RESERVED",
	} {
		if strings.Contains(u, frag) {
			return true
		}
	}
	return false
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
	// The note carries the object class and, when the answer was administrative
	// filler rather than a holder, says so explicitly. A row with a NULL registrant
	// and a placeholder note is a POSITIVE finding: the registry was asked and has
	// no assignment recorded for the range. That is different from having no row at
	// all, which means nothing has been asked yet.
	note := r.net.ObjectClassName
	if strings.HasPrefix(r.role, "placeholder:") {
		note = r.role
	}
	_, err := conn.Exec(ctx, q,
		u32ToAddr(start).String(), u32ToAddr(end).String(),
		nullIfEmpty(r.registrant), nullIfEmpty(r.role), nullIfEmpty(r.net.Handle),
		nullIfEmpty(r.net.Name), nullIfEmpty(r.rir),
		queried.String(), r.httpStatus, nullIfEmpty(note))
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

// logCacheAges prints the age distribution of held allocations on every run, so
// drift is visible by default instead of needing to be asked about. Nothing read
// fetched_at before this, which is how rows from September went on answering in
// November unnoticed.
func logCacheAges(ctx context.Context, conn *pgx.Conn) {
	rows, err := conn.Query(ctx, `
SELECT CASE WHEN fetched_at > now() - interval '7 days'   THEN 'under 7 days'
            WHEN fetched_at > now() - interval '30 days'  THEN '7 to 30 days'
            WHEN fetched_at > now() - interval '90 days'  THEN '30 to 90 days'
            WHEN fetched_at > now() - interval '365 days' THEN '90 to 365 days'
            ELSE 'over a year' END AS bucket,
       count(*)
FROM rdap_registrant_tbl
WHERE family(start_ip) = 4
GROUP BY 1
ORDER BY min(fetched_at) DESC`)
	if err != nil {
		log.Printf("could not read the cache age distribution: %v", err)
		return
	}
	defer rows.Close()
	log.Print("age of held allocations:")
	for rows.Next() {
		var bucket string
		var n int
		if err := rows.Scan(&bucket, &n); err != nil {
			log.Printf("  age row unreadable: %v", err)
			return
		}
		log.Printf("  %-16s %8d", bucket, n)
	}
	if err := rows.Err(); err != nil {
		log.Printf("  age distribution incomplete: %v", err)
	}
}

// countCached reports every IPv4 allocation held, ignoring age, so an expiry run
// can report how much of the cache it is choosing to disregard.
func countCached(ctx context.Context, conn *pgx.Conn) (int, error) {
	var n int
	err := conn.QueryRow(ctx,
		"SELECT count(*) FROM rdap_registrant_tbl WHERE family(start_ip) = 4").Scan(&n)
	return n, err
}

// loadCovered reads cached allocations as intervals, sorted by start.
//
// maxAge > 0 omits any allocation fetched longer ago than that, which is the whole
// of the staleness provision: an omitted allocation stops covering its candidates,
// so the fill queries them again and storeRecord's ON CONFLICT updates the row in
// place. Refresh is therefore idempotent and needs no deletion.
//
// The age is passed as a seconds interval rather than as Go's duration text,
// because '720h0m0s' is not PostgreSQL interval syntax.
func loadCovered(ctx context.Context, conn *pgx.Conn, maxAge time.Duration) ([]interval, error) {
	q := "SELECT host(start_ip), host(end_ip) FROM rdap_registrant_tbl WHERE family(start_ip) = 4"
	var args []interface{}
	if maxAge > 0 {
		q += " AND fetched_at > now() - $1::interval"
		args = append(args, fmt.Sprintf("%d seconds", int64(maxAge.Seconds())))
	}
	q += " ORDER BY start_ip"
	rows, err := conn.Query(ctx, q, args...)
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
func loadCandidates(ctx context.Context, conn *pgx.Conn, table string,
	sources []string, maxMasklen int) ([]netip.Prefix, error) {
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

	// source and masklen are bound as parameters rather than interpolated, because
	// -sources is operator input and must not reach the statement text.
	q := "SELECT DISTINCT network::text FROM ip2city_dbiplite_tbl " +
		"WHERE source = ANY($1::text[]) AND family(network) = 4 AND masklen(network) <= $2 " +
		strings.Replace(notExcluded, "%s", "network", 1)
	if table != "" {
		ident := pgx.Identifier{table}.Sanitize()
		q = "SELECT DISTINCT c.network::text FROM " + ident + " c " +
			"JOIN ip2city_dbiplite_tbl d ON d.network = c.network AND d.source = ANY($1::text[]) " +
			"WHERE family(c.network) = 4 AND masklen(c.network) <= $2 " +
			strings.Replace(notExcluded, "%s", "c.network", 1)
	}
	rows, err := conn.Query(ctx, q, sources, maxMasklen)
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
