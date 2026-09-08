// Command check_geo_ip-api geolocates a random IP address from each sampled
// network range using the free ip-api.com JSON endpoint and writes the result
// into the identically-named columns of ip2city_dbiplite_probe_tbl.
//
// This replaces the mtr traceroute method for populating geography. It reuses
// the same "one random address per range" sampling.
//
// Rate limiting: the free ip-api.com service refuses service above ~45
// requests/minute and will ban the WAN IP on persistent overage. We therefore
// issue at most -rate calls per rolling window: after every -rate calls, if
// less than a minute has elapsed since the first call of that window, we sleep
// until a minute has passed before issuing more. HTTP 429 is also honored
// defensively via the X-Ttl header.
//
// Batch mode (paid ip-api.com service, which lifts the rate limit and accepts
// batches of addresses per query) is scaffolded but intentionally NOT
// implemented — see readIPBatch / parseBatchResponse — because the paid
// request/response format is not yet confirmed.
package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// geoResult mirrors the ip-api.com /json/<ip> response. Field names use the
// exact JSON keys via struct tags so the mapping to the identically-named
// table columns is explicit.
type geoResult struct {
	Status      string  `json:"status"`  // "success" | "fail"
	Message     string  `json:"message"` // populated only on "fail"
	Country     string  `json:"country"`
	CountryCode string  `json:"countryCode"`
	Region      string  `json:"region"`
	RegionName  string  `json:"regionName"`
	City        string  `json:"city"`
	Zip         string  `json:"zip"`
	Lat         float64 `json:"lat"`
	Lon         float64 `json:"lon"`
	Timezone    string  `json:"timezone"`
	ISP         string  `json:"isp"`
	Org         string  `json:"org"`
	As          string  `json:"as"`
	Query       string  `json:"query"`
}

// rangeRow is a sampled network range and its inclusive address bounds.
type rangeRow struct {
	network string
	start   netip.Addr
	end     netip.Addr
}

// geoTarget is a single (network, sampled address) unit of work.
type geoTarget struct {
	network string
	ip      netip.Addr
}

func main() {
	count := flag.Int("count", 0, "total number of ip-api.com calls to make (one random IP per range); required")
	rate := flag.Int("rate", 45, "maximum calls per rolling one-minute window")
	country := flag.String("country", "", "restrict to this country_iso_code (e.g. US); empty = no filter")
	ipv4Only := flag.Bool("ipv4-only", false, "sample only IPv4 ranges")
	httpTimeout := flag.Duration("http-timeout", 10*time.Second, "per-request HTTP timeout")
	endpoint := flag.String("endpoint", "http://ip-api.com/json/", "ip-api.com single-IP JSON endpoint prefix (free tier is http-only)")
	flag.Parse()

	if *count <= 0 {
		log.Fatal("-count must be > 0 (total number of ip-api calls to make)")
	}
	if *rate <= 0 {
		log.Fatal("-rate must be > 0")
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

	ranges, err := sampleRanges(ctx, conn, *count, *country, *ipv4Only)
	if err != nil {
		log.Fatalf("sampling ranges: %v", err)
	}
	if len(ranges) == 0 {
		// An empty backlog is success, not failure. This used to be log.Fatal,
		// which exited 1, so probe_batch.sh treated a fully drained backlog as
		// an error and sent an error email. On an hourly schedule that would be
		// 24 spurious alerts a day, starting the moment the work was finished.
		//
		// A genuine misconfiguration still surfaces: too-strict filters are
		// named in this message, and every other failure mode still exits
		// non-zero.
		log.Printf("no eligible ranges found: nothing left to probe for country=%q ipv4-only=%v, or the filters exclude everything. Exiting successfully with no work done.", *country, *ipv4Only)
		return
	}
	log.Printf("selected %d ranges (requested %d; country=%q ipv4-only=%v); rate=%d/min",
		len(ranges), *count, *country, *ipv4Only, *rate)

	client := &http.Client{Timeout: *httpTimeout}

	var (
		windowStart time.Time
		inWindow    int
		written     int
	)

	for i, rr := range ranges {
		ip, err := randomAddrInRange(rr.start, rr.end)
		if err != nil {
			log.Printf("[%d/%d] %s: cannot sample address: %v", i+1, len(ranges), rr.network, err)
			continue
		}
		tgt := geoTarget{network: rr.network, ip: ip}

		// Rate-limit gate: anchor the window on the first call of each set.
		if inWindow == 0 {
			windowStart = time.Now()
		}

		g, callErr := lookupGeo(client, *endpoint, tgt.ip)

		if err := writeGeo(ctx, conn, tgt, g, callErr); err != nil {
			log.Printf("[%d/%d] %s: write failed: %v", i+1, len(ranges), tgt.network, err)
		} else {
			written++
		}

		if callErr != nil {
			log.Printf("[%d/%d] %s ip=%s ERROR %v", i+1, len(ranges), tgt.network, tgt.ip, callErr)
		} else {
			log.Printf("[%d/%d] %s ip=%s status=%s city=%q region=%q country=%q isp=%q mobile=%v",
				i+1, len(ranges), tgt.network, tgt.ip, g.Status, g.City, g.RegionName, g.Country, g.ISP,
				g.Status == "success" && isMobileISP(g.ISP, g.Org))
		}

		inWindow++
		// After each full window of -rate calls, hold until a minute has
		// elapsed since that window's first call (unless we're finished).
		if inWindow >= *rate {
			if i < len(ranges)-1 {
				if elapsed := time.Since(windowStart); elapsed < time.Minute {
					wait := time.Minute - elapsed
					log.Printf("rate limit: %d calls in %s, sleeping %s to complete the minute",
						*rate, elapsed.Round(time.Millisecond), wait.Round(time.Millisecond))
					time.Sleep(wait)
				}
			}
			inWindow = 0
		}
	}

	log.Printf("done: %d rows written", written)
}

// sampleRanges picks up to n network ranges that do not yet have a geolocated
// row (city IS NULL), excluding RFC 6598 CGNAT space, optionally IPv4-only and
// country-filtered, in random order.
func sampleRanges(ctx context.Context, conn *pgx.Conn, n int, country string, ipv4Only bool) ([]rangeRow, error) {
	// Source of work is ip2city_dbiplite_probe_tbl, which daily_pipeline.sh
	// rebuilds from the reconciled db-ip and RouteViews data once per cycle. A
	// row awaits probing exactly when ran_at IS NULL: the rebuild seeds every row
	// with ran_at NULL and db-ip's city and state, and this tool stamps ran_at
	// when it probes.
	//
	// ran_at, not city, is the measured/unmeasured test. city is seeded from
	// db-ip for every row at populate time, so "city IS NOT NULL" no longer
	// distinguishes a measured range from an inherited one.
	//
	// The scope filters (address family, country, CGNAT, geo_exclusions) are
	// applied by the rebuild, not here, so this query does not repeat them. That
	// is deliberate and it is load bearing: if this query filtered out rows the
	// rebuild had loaded, those rows would keep ran_at NULL forever and the
	// cycle-complete gate would never open again. The family and country
	// predicates below are therefore assertions that the caller and the rebuild
	// agree, not independent filters, and they are applied only when explicitly
	// requested.
	query := `
SELECT p.network::text,
       host(network(p.network))::inet   AS start_ip,
       host(broadcast(p.network))::inet AS end_ip
FROM ip2city_dbiplite_probe_tbl p
WHERE p.ran_at IS NULL`

	args := []any{n}
	if ipv4Only {
		query += " AND family(p.network) = 4"
	}
	if country != "" {
		query += fmt.Sprintf(" AND p.countrycode = $%d", len(args)+1)
		args = append(args, country)
	}
	// RouteViews-derived /24 rows are the time-sensitive ones: they exist
	// because a db-ip range was seen to split and we do not want to wait for
	// next month's edition. Under a plain ORDER BY random() they would compete
	// with millions of other unprobed rows and take months to be reached by
	// chance, so probe them first and fall back to random order within each
	// group.
	//
	// The probe table has no source column, so that ordering is recovered by
	// joining back to ip2city_dbiplite_tbl. A missing row there sorts last,
	// which is correct: it can only be a range that has since disappeared from
	// the reconciled set.
	query += ` ORDER BY (coalesce((SELECT s.source FROM ip2city_dbiplite_tbl s WHERE s.network = p.network), 'dbip') = 'routeviews') DESC, random() LIMIT $1`

	rows, err := conn.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []rangeRow
	for rows.Next() {
		var netText string
		var start, end netip.Addr
		if err := rows.Scan(&netText, &start, &end); err != nil {
			return nil, err
		}
		out = append(out, rangeRow{network: netText, start: start, end: end})
	}
	return out, rows.Err()
}

// lookupGeo performs one GET against the free ip-api.com endpoint. On HTTP 429
// it honors the X-Ttl header (seconds until the limit resets) and retries once.
func lookupGeo(client *http.Client, endpointPrefix string, ip netip.Addr) (geoResult, error) {
	url := endpointPrefix + ip.String()

	for attempt := 0; attempt < 2; attempt++ {
		req, err := http.NewRequest(http.MethodGet, url, nil)
		if err != nil {
			return geoResult{}, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return geoResult{}, err
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode == http.StatusTooManyRequests {
			ttl := parseTTLSeconds(resp.Header.Get("X-Ttl"))
			wait := time.Duration(ttl+1) * time.Second
			log.Printf("HTTP 429 from ip-api (X-Ttl=%q); backing off %s", resp.Header.Get("X-Ttl"), wait)
			time.Sleep(wait)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			return geoResult{}, fmt.Errorf("ip-api HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}

		var g geoResult
		if err := json.Unmarshal(body, &g); err != nil {
			return geoResult{}, fmt.Errorf("decoding ip-api json: %w (body=%q)", err, strings.TrimSpace(string(body)))
		}
		return g, nil
	}
	return geoResult{}, errors.New("ip-api: still HTTP 429 after backoff")
}

func parseTTLSeconds(h string) int {
	if h == "" {
		return 60
	}
	n, err := strconv.Atoi(strings.TrimSpace(h))
	if err != nil || n < 0 {
		return 60
	}
	return n
}

// mobileISPKeywords are lower-case substrings that, when present in the ip-api
// isp/org fields, mark a network as a US mobile carrier (likely_mobile_cgnat).
//
// The generic radio-access words cover the great majority of carriers and
// their MVNOs/brands whose ownership string carries them (Verizon Wireless,
// AT&T Mobility, T-Mobile USA — including T-Mobile Home Internet on AS21928 —
// US Cellular, Xfinity Mobile, Spectrum Mobile, Mint Mobile, Visible→Verizon
// Wireless, etc.). The remaining entries are carriers/brands whose ownership
// name can lack those words.
//
// Deliberately NOT included: bare "verizon", "at&t", "metro", "dish", "ting" —
// each has a fixed-line or unrelated sibling (Verizon FiOS, AT&T Fiber,
// MetroNet fiber, Dish satellite TV, hosTING) that would be wrongly flagged.
// We rely on the wireless-specific tokens instead. Not exhaustive; extend as
// new names surface.
var mobileISPKeywords = []string{
	// generic radio-access indicators
	"wireless", "cellular", "mobile", "mobility", "pcs",
	// carrier / MVNO brands whose org string may lack the words above
	"vzw", "cellco", // Verizon Wireless (Cellco Partnership)
	"sprint",                    // Sprint / Sprint PCS (now T-Mobile)
	"cingular",                  // legacy AT&T
	"cricket",                   // Cricket Wireless (AT&T)
	"metropcs",                  // Metro / MetroPCS (T-Mobile)
	"boost",                     // Boost Mobile / Boost Infinite (Dish)
	"tracfone", "straight talk", // TracFone family (Verizon)
	"cellcom", // Cellcom (regional, WI)
	"uscc",    // U.S. Cellular internal naming
	// (C Spire intentionally omitted: it sells both mobile and fixed fiber
	// under the same "C Spire" ownership name, so a token would misflag its
	// fiber home-internet customers as mobile.)
	// (Google Fi intentionally omitted: it egresses via its host MNO, so it is
	// already caught by "mobile"/"cellular", and a "google fi" token would
	// wrongly match "Google Fiber".)
}

// isMobileISP reports whether the ip-api isp/org fields indicate a US mobile
// carrier — used to set likely_mobile_cgnat — via a case-insensitive substring
// match against mobileISPKeywords.
func isMobileISP(isp, org string) bool {
	s := strings.ToLower(isp + " " + org)
	for _, kw := range mobileISPKeywords {
		if strings.Contains(s, kw) {
			return true
		}
	}
	return false
}

// writeGeo records one geolocation result against the seeded row in
// ip2city_dbiplite_probe_tbl.
// The geographic values map to identically-named columns. The sampled IP is
// stored in the "query" column (aligned with the JSON schema — ip-api echoes
// the queried IP there); there is no separate sampled_ip column. On a transport
// error or an ip-api "fail" response, the geographic columns are left NULL and
// the reason is recorded in status/classification_note so the range can be
// retried on a later run (it stays city IS NULL).
//
// likely_mobile_cgnat is set true when the resolved isp/org looks like a mobile
// carrier (see isMobileISP). On INSERT (a range with no prior row) the mtr-only
// numeric columns are given zero-values to satisfy any NOT NULL constraints; on
// UPDATE hop_count/attempts are left untouched so an existing mtr row's hop data
// is not clobbered, while likely_mobile_cgnat IS refreshed from this lookup.
func writeGeo(ctx context.Context, conn *pgx.Conn, tgt geoTarget, g geoResult, callErr error) error {
	var (
		status  any
		note    any
		success bool
	)
	switch {
	case callErr != nil:
		status = "error"
		note = callErr.Error()
	case g.Status == "success":
		status = "success"
		success = true
	default:
		// ip-api "fail" (e.g. reserved/private range, invalid query).
		status = nullIfEmpty(g.Status) // usually "fail"
		note = nullIfEmpty(g.Message)
	}

	var latArg, lonArg any
	if success {
		latArg, lonArg = g.Lat, g.Lon
	}
	mobile := success && isMobileISP(g.ISP, g.Org)

	// UPDATE, not INSERT. The row already exists: daily_pipeline.sh seeded it from
	// the reconciled db-ip and RouteViews data with ran_at NULL. Probing replaces
	// the inherited values with the measured ones and stamps ran_at.
	//
	// The measured city and state OVERWRITE the db-ip seed. That is the purpose of
	// probing, and the seed is the pre-probe baseline so that a range never
	// probed still carries a best-known location.
	//
	// last_hop_ip receives the address actually probed. query keeps the network
	// base address written at populate time, since it is NOT NULL there and
	// records nothing about the probe.
	//
	// ran_at is stamped on EVERY outcome, including an API error or a "fail"
	// status. If a permanently failing range were left with ran_at NULL it would
	// never leave the backlog, the cycle would never complete, and the probe table
	// would never be rebuilt again. status and classification_note record what
	// happened; ran_at records only that it was attempted.
	tag, err := conn.Exec(ctx, `
UPDATE ip2city_dbiplite_probe_tbl SET
    last_hop_ip         = $2,
    status              = $3,
    probe_method        = 'ip-api',
    likely_mobile_cgnat = $4,
    classification_note = $5,
    country             = $6,
    countrycode         = coalesce($7, countrycode),
    state_code          = coalesce($8, state_code),
    state               = coalesce($9, state),
    city                = coalesce($10, city),
    zip                 = $11,
    lat                 = $12,
    lon                 = $13,
    timezone            = $14,
    isp                 = $15,
    org                 = $16,
    "as"                = $17,
    attempts            = coalesce(attempts, 0) + 1,
    ran_at              = now()
WHERE network = $1
`,
		tgt.network, tgt.ip.String(), status, mobile, note,
		nullIfEmpty(g.Country), nullIfEmpty(g.CountryCode), nullIfEmpty(g.Region), nullIfEmpty(g.RegionName),
		nullIfEmpty(g.City), nullIfEmpty(g.Zip), latArg, lonArg,
		nullIfEmpty(g.Timezone), nullIfEmpty(g.ISP), nullIfEmpty(g.Org), nullIfEmpty(g.As))
	if err != nil {
		return err
	}
	// A miss means the row vanished between sampling and writing, which should be
	// impossible inside one cycle. Report it rather than silently leaving the
	// range unprobed and the gate blocked.
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("no row in ip2city_dbiplite_probe_tbl for network %s, so ran_at was not stamped", tgt.network)
	}
	return nil
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
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

// ---------------------------------------------------------------------------
// Batch-mode scaffolding for the PAID ip-api.com service (lifts the rate limit
// and accepts many addresses per query). These are intentionally NOT
// implemented: the paid batch request/response format is unconfirmed. They are
// arranged here so batch mode can be dropped into the pipeline without
// reworking sampling or persistence. Do NOT implement until verified against
// the live paid endpoint.
// ---------------------------------------------------------------------------

// readIPBatch would collect up to size (network, ip) targets to submit as one
// batch request to the paid endpoint.
func readIPBatch(ctx context.Context, conn *pgx.Conn, size int, country string, ipv4Only bool) ([]geoTarget, error) {
	_ = ctx
	_ = conn
	_ = size
	_ = country
	_ = ipv4Only
	return nil, errors.New("readIPBatch: not implemented (awaiting paid ip-api batch request format)")
}

// parseBatchResponse would map a paid batch JSON response body back to
// per-query results, in the input order the paid API documents.
func parseBatchResponse(body []byte) ([]geoResult, error) {
	_ = body
	return nil, errors.New("parseBatchResponse: not implemented (awaiting paid ip-api batch response format)")
}
