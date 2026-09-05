// Command classify_ranges spends a small number of ip-api probes to find out
// which large candidate ranges are government/DoD space that is not worth
// geolocating at all.
//
// Leverage: measured 2026-09-01 on live data, 715 candidate ranges (masklen /8
// to /16) account for 791,552 of the 986,450 total /24 probes -- 80% of the
// budget in 3% of the ranges. Probing ONE address in each of those 715 costs
// about 16 minutes and lets the DoD ones be excluded wholesale, converting
// roughly 12 days of pointless probing into a short triage pass.
//
// Classification uses ONLY the isp, org and as text fields. It deliberately
// never matches on city, region or zip: the DoD registrant addresses observed
// so far are Columbus OH, Whitehall OH and Sierra Vista AZ, all of which are
// real metros containing legitimate commercial ranges. Matching on location
// would silently discard good data.
//
// Nothing is written to geo_exclusions unless -auto-exclude is passed, and
// -dry-run performs no writes at all.
//
// This file contains NO backslash escape sequences anywhere, so it survives
// copy/paste through chat and heredocs. Output uses fmt.Println rather than
// format strings ending in a newline escape.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// govSignatures are matched, lowercased, against the isp, org and as fields.
// Every entry below was observed in a real ip-api response during this work.
var govSignatures = []string{
	"department of defense",
	"dod network information center",
	"dod intel",
	"defense information systems",
	"defense technical information",
	"dla systems",
	"army information systems",
	"usaisc",
	"us-dod",
	"ddn-rvn",
	"dsi-north",
	"conus-",
	"headquarters, usaisc",
	"united states air force",
	"united states army",
	"united states navy",
	"navy network information center",
	"marine corps",
}

type apiResponse struct {
	Status     string  `json:"status"`
	Message    string  `json:"message"`
	Country    string  `json:"countryCode"`
	RegionName string  `json:"regionName"`
	City       string  `json:"city"`
	Zip        string  `json:"zip"`
	Lat        float64 `json:"lat"`
	Lon        float64 `json:"lon"`
	ISP        string  `json:"isp"`
	Org        string  `json:"org"`
	AS         string  `json:"as"`
	Query      string  `json:"query"`
}

type candidate struct {
	network  string
	probeIP  string
	children int64
}

func main() {
	sourceTable := flag.String("source", "dbip_split_candidates", "table holding candidate ranges (needs a cidr column named network)")
	maxMasklen := flag.Int("max-masklen", 16, "only classify ranges at least this wide, i.e. masklen <= this value")
	minMasklen := flag.Int("min-masklen", 0, "skip ranges wider than this, i.e. masklen >= this value")
	limit := flag.Int("limit", 0, "stop after this many ranges (0 = no limit)")
	rate := flag.Int("rate", 45, "maximum ip-api calls per minute")
	autoExclude := flag.Bool("auto-exclude", false, "insert ranges classified as government into geo_exclusions")
	dryRun := flag.Bool("dry-run", false, "probe nothing and write nothing; just list what would be probed")
	recheck := flag.Bool("recheck", false, "re-probe ranges already present in range_classification")
	flag.Parse()

	if *rate < 1 {
		log.Fatal("-rate must be >= 1")
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

	if !*dryRun {
		if err := ensureTable(ctx, conn); err != nil {
			log.Fatalf("creating range_classification: %v", err)
		}
	}

	// Active prefix exclusions, applied in Go so the query stays index-friendly
	// and we avoid a correlated EXISTS in the hot path.
	excluded, err := loadExcludedPrefixes(ctx, conn)
	if err != nil {
		log.Fatalf("loading geo_exclusions: %v", err)
	}
	log.Printf("loaded %d active prefix exclusions", len(excluded))

	cands, err := loadCandidates(ctx, conn, *sourceTable, *minMasklen, *maxMasklen, *recheck)
	if err != nil {
		log.Fatalf("loading candidates from %s: %v", *sourceTable, err)
	}
	log.Printf("%d candidate ranges in %s with masklen between %d and %d",
		len(cands), *sourceTable, *minMasklen, *maxMasklen)

	// Drop anything already covered by an exclusion rule.
	var work []candidate
	skippedExcluded := 0
	for _, c := range cands {
		if coveredBy(c.network, excluded) {
			skippedExcluded++
			continue
		}
		work = append(work, c)
	}
	log.Printf("%d already covered by exclusions, %d to probe", skippedExcluded, len(work))

	if *limit > 0 && len(work) > *limit {
		work = work[:*limit]
		log.Printf("limited to %d ranges", len(work))
	}

	if len(work) == 0 {
		fmt.Println("Nothing to probe.")
		return
	}

	estimate := time.Duration(float64(len(work))/float64(*rate)*60.0) * time.Second
	log.Printf("estimated probe time at %d/min: %s", *rate, estimate.Round(time.Second))

	if *dryRun {
		fmt.Println()
		fmt.Println("DRY RUN: ranges that would be probed (first 50):")
		for i, c := range work {
			if i >= 50 {
				fmt.Println(fmt.Sprintf("  ... and %d more", len(work)-50))
				break
			}
			fmt.Println(fmt.Sprintf("  %-20s probe %-16s (%d bgp children)",
				c.network, c.probeIP, c.children))
		}
		return
	}

	client := &http.Client{Timeout: 20 * time.Second}
	var govFound, ok, failed int
	var govProbesSaved int64
	var govRanges []string

	// Rate limiting: after every *rate calls, wait until a full minute has
	// elapsed since the first call of that batch, matching the approach used by
	// check_geo_ip-api.
	batchStart := time.Now()
	inBatch := 0

	for i, c := range work {
		if inBatch >= *rate {
			elapsed := time.Since(batchStart)
			if elapsed < time.Minute {
				wait := time.Minute - elapsed
				log.Printf("rate limit: sleeping %s (%d/%d done)",
					wait.Round(time.Second), i, len(work))
				time.Sleep(wait)
			}
			batchStart = time.Now()
			inBatch = 0
		}
		if inBatch == 0 {
			batchStart = time.Now()
		}

		resp, err := probe(client, c.probeIP)
		inBatch++
		if err != nil {
			failed++
			log.Printf("probe %s (%s) failed: %v", c.network, c.probeIP, err)
			continue
		}
		if resp.Status != "success" {
			failed++
			log.Printf("probe %s (%s) returned status %q: %s",
				c.network, c.probeIP, resp.Status, resp.Message)
			continue
		}
		ok++

		isGov, sig := classify(resp)
		if err := record(ctx, conn, c, resp, isGov, sig); err != nil {
			log.Printf("recording %s: %v", c.network, err)
		}
		if isGov {
			govFound++
			govRanges = append(govRanges, c.network)
			govProbesSaved += probesFor(c.network)
			fmt.Println(fmt.Sprintf("  GOV  %-20s %-34s [%s]",
				c.network, truncate(resp.Org+" / "+resp.ISP, 34), sig))
		}
	}

	fmt.Println()
	fmt.Println("=== classification summary ===")
	fmt.Println(fmt.Sprintf("probed successfully: %d", ok))
	fmt.Println(fmt.Sprintf("failed or refused:   %d", failed))
	fmt.Println(fmt.Sprintf("classified as gov:   %d", govFound))
	fmt.Println(fmt.Sprintf("/24 probes avoidable by excluding them: %d (%.1f days at 45/min)",
		govProbesSaved, float64(govProbesSaved)/64800.0))

	if govFound == 0 {
		fmt.Println("No government ranges found; nothing to exclude.")
		return
	}

	if !*autoExclude {
		fmt.Println()
		fmt.Println("Run again with -auto-exclude to add these to geo_exclusions,")
		fmt.Println("or insert them by hand after reviewing range_classification.")
		return
	}

	inserted := 0
	for _, netStr := range govRanges {
		var reason string
		err := conn.QueryRow(ctx,
			"SELECT 'classify_ranges: ' || coalesce(gov_signature,'?') || ' (' || coalesce(org,'') || ' / ' || coalesce(isp,'') || ')' FROM range_classification WHERE network = $1::cidr",
			netStr).Scan(&reason)
		if err != nil {
			reason = "classify_ranges: government signature in isp/org/as"
		}
		_, err = conn.Exec(ctx,
			"INSERT INTO geo_exclusions (prefix, reason) VALUES ($1::cidr, $2) ON CONFLICT DO NOTHING",
			netStr, reason)
		if err != nil {
			log.Printf("excluding %s: %v", netStr, err)
			continue
		}
		inserted++
	}
	fmt.Println(fmt.Sprintf("inserted %d exclusion rules", inserted))
}

func ensureTable(ctx context.Context, conn *pgx.Conn) error {
	ddl := "CREATE TABLE IF NOT EXISTS range_classification (" +
		"network cidr PRIMARY KEY, " +
		"probe_ip inet NOT NULL, " +
		"country_iso_code text, region_name text, city text, zip text, " +
		"latitude double precision, longitude double precision, " +
		"isp text, org text, as_text text, " +
		"is_gov boolean NOT NULL DEFAULT false, gov_signature text, " +
		"probed_at timestamptz NOT NULL DEFAULT now())"
	if _, err := conn.Exec(ctx, ddl); err != nil {
		return err
	}
	_, err := conn.Exec(ctx,
		"CREATE INDEX IF NOT EXISTS range_classification_gov_idx ON range_classification (is_gov)")
	return err
}

func loadExcludedPrefixes(ctx context.Context, conn *pgx.Conn) ([]netip.Prefix, error) {
	var exists bool
	if err := conn.QueryRow(ctx,
		"SELECT to_regclass('public.geo_exclusions') IS NOT NULL").Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		log.Printf("geo_exclusions does not exist yet; no exclusions applied")
		return nil, nil
	}
	rows, err := conn.Query(ctx,
		"SELECT prefix::text FROM geo_exclusions WHERE active AND prefix IS NOT NULL")
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
			log.Printf("skipping unparseable exclusion %q: %v", s, err)
			continue
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func loadCandidates(ctx context.Context, conn *pgx.Conn, table string, minLen, maxLen int, recheck bool) ([]candidate, error) {
	// The source table is an operator-supplied identifier, so quote it.
	ident := pgx.Identifier{table}.Sanitize()

	hasChildren := false
	if err := conn.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = 'bgp_children')",
		table).Scan(&hasChildren); err != nil {
		return nil, err
	}
	childExpr := "0::bigint"
	if hasChildren {
		childExpr = "coalesce(bgp_children, 0)"
	}

	notClassified := ""
	if !recheck {
		notClassified = " AND NOT EXISTS (SELECT 1 FROM range_classification rc WHERE rc.network = c.network)"
	}

	q := "SELECT c.network::text, host(c.network::inet + 1), " + childExpr + " FROM " + ident + " c " +
		"WHERE family(c.network) = 4 AND masklen(c.network) >= $1 AND masklen(c.network) <= $2" +
		notClassified + " ORDER BY masklen(c.network), c.network"

	rows, err := conn.Query(ctx, q, minLen, maxLen)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []candidate
	for rows.Next() {
		var c candidate
		if err := rows.Scan(&c.network, &c.probeIP, &c.children); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func coveredBy(network string, excluded []netip.Prefix) bool {
	p, err := netip.ParsePrefix(network)
	if err != nil {
		return false
	}
	for _, x := range excluded {
		// x covers p if x contains p's base address and x is no more specific.
		if x.Bits() <= p.Bits() && x.Contains(p.Addr()) {
			return true
		}
	}
	return false
}

func probe(client *http.Client, ip string) (*apiResponse, error) {
	url := "http://ip-api.com/json/" + ip +
		"?fields=status,message,countryCode,regionName,city,zip,lat,lon,isp,org,as,query"
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, fmt.Errorf("HTTP 429: rate limited, lower -rate")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var out apiResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decoding response %q: %w", truncate(string(body), 120), err)
	}
	return &out, nil
}

// classify inspects ONLY isp, org and as. Never city, region or zip.
func classify(r *apiResponse) (bool, string) {
	haystack := strings.ToLower(r.ISP + " | " + r.Org + " | " + r.AS)
	for _, sig := range govSignatures {
		if strings.Contains(haystack, sig) {
			return true, sig
		}
	}
	return false, ""
}

func record(ctx context.Context, conn *pgx.Conn, c candidate, r *apiResponse, isGov bool, sig string) error {
	q := "INSERT INTO range_classification (network, probe_ip, country_iso_code, region_name, city, zip, " +
		"latitude, longitude, isp, org, as_text, is_gov, gov_signature, probed_at) " +
		"VALUES ($1::cidr, $2::inet, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, now()) " +
		"ON CONFLICT (network) DO UPDATE SET probe_ip = excluded.probe_ip, " +
		"country_iso_code = excluded.country_iso_code, region_name = excluded.region_name, " +
		"city = excluded.city, zip = excluded.zip, latitude = excluded.latitude, " +
		"longitude = excluded.longitude, isp = excluded.isp, org = excluded.org, " +
		"as_text = excluded.as_text, is_gov = excluded.is_gov, " +
		"gov_signature = excluded.gov_signature, probed_at = now()"
	var sigVal any
	if sig == "" {
		sigVal = nil
	} else {
		sigVal = sig
	}
	_, err := conn.Exec(ctx, q, c.network, c.probeIP, nullIfEmpty(r.Country),
		nullIfEmpty(r.RegionName), nullIfEmpty(r.City), nullIfEmpty(r.Zip),
		r.Lat, r.Lon, nullIfEmpty(r.ISP), nullIfEmpty(r.Org), nullIfEmpty(r.AS),
		isGov, sigVal)
	return err
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// probesFor returns the number of /24 probes a range would cost at one per /24.
func probesFor(network string) int64 {
	p, err := netip.ParsePrefix(network)
	if err != nil {
		return 0
	}
	bits := p.Bits()
	if bits >= 24 {
		return 1
	}
	return int64(1) << uint(24-bits)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	if n <= 3 {
		return s[:n]
	}
	return s[:n-3] + "..."
}
