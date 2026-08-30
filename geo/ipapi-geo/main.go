// Command ipapi-geo geolocates a random IP address from each sampled network
// range using the free ip-api.com JSON endpoint and writes the result into the
// identically-named columns of ip2city_dbiplite_traceroute_tbl.
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

	ranges, err := sampleRanges(ctx, conn, *count, *country, *ipv4Only)
	if err != nil {
		log.Fatalf("sampling ranges: %v", err)
	}
	if len(ranges) == 0 {
		log.Fatal("no eligible ranges found (all already geolocated, or filters too strict)")
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
			log.Printf("[%d/%d] %s ip=%s status=%s city=%q region=%q country=%q isp=%q",
				i+1, len(ranges), tgt.network, tgt.ip, g.Status, g.City, g.RegionName, g.Country, g.ISP)
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
	query := `
SELECT t.network::text,
       host(network(t.network))::inet   AS start_ip,
       host(broadcast(t.network))::inet AS end_ip
FROM ip2city_dbiplite_tbl t
WHERE NOT EXISTS (
    SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
    WHERE tr.network = t.network
      AND tr.city IS NOT NULL
)
AND NOT (t.network <<= '100.64.0.0/10'::cidr)`

	args := []any{n}
	if ipv4Only {
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

// writeGeo upserts one geolocation result into ip2city_dbiplite_traceroute_tbl.
// The geographic values map to identically-named columns. On a transport error
// or an ip-api "fail" response, the geographic columns are left NULL and the
// reason is recorded in status/classification_note so the range can be retried
// on a later run (it stays city IS NULL).
//
// On INSERT (a range with no prior row) the mtr-only numeric/bool columns are
// given zero-values to satisfy any NOT NULL constraints; on UPDATE they are
// left untouched so an existing mtr row's hop data is not clobbered.
func writeGeo(ctx context.Context, conn *pgx.Conn, tgt geoTarget, g geoResult, callErr error) error {
	var (
		status any
		note   any
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

	query := nullIfEmpty(g.Query)
	if query == nil {
		query = tgt.ip.String()
	}

	_, err := conn.Exec(ctx, `
INSERT INTO ip2city_dbiplite_traceroute_tbl
    (network, sampled_ip, status, probe_method, likely_mobile_cgnat, hop_count, attempts,
     classification_note, country, countrycode, region, regionname, city, zip, lat, lon,
     timezone, isp, org, "as", query, ran_at)
VALUES ($1, $2, $3, 'ip-api', false, 0, 0,
        $4, $5, $6, $7, $8, $9, $10, $11, $12,
        $13, $14, $15, $16, $17, now())
ON CONFLICT (network) DO UPDATE SET
    sampled_ip          = EXCLUDED.sampled_ip,
    status              = EXCLUDED.status,
    probe_method        = EXCLUDED.probe_method,
    classification_note = EXCLUDED.classification_note,
    country             = EXCLUDED.country,
    countrycode         = EXCLUDED.countrycode,
    region              = EXCLUDED.region,
    regionname          = EXCLUDED.regionname,
    city                = EXCLUDED.city,
    zip                 = EXCLUDED.zip,
    lat                 = EXCLUDED.lat,
    lon                 = EXCLUDED.lon,
    timezone            = EXCLUDED.timezone,
    isp                 = EXCLUDED.isp,
    org                 = EXCLUDED.org,
    "as"                = EXCLUDED."as",
    query               = EXCLUDED.query,
    ran_at              = now()
`,
		tgt.network, tgt.ip, status, note,
		nullIfEmpty(g.Country), nullIfEmpty(g.CountryCode), nullIfEmpty(g.Region), nullIfEmpty(g.RegionName),
		nullIfEmpty(g.City), nullIfEmpty(g.Zip), latArg, lonArg,
		nullIfEmpty(g.Timezone), nullIfEmpty(g.ISP), nullIfEmpty(g.Org), nullIfEmpty(g.As), query)
	return err
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
