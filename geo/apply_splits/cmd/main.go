// Command apply_splits decomposes each split db-ip range into its aligned /24
// subnets, inserts them as source='routeviews' rows, and deletes the parent.
//
// Why /24 decomposition rather than inserting the BGP child prefixes directly:
// BGP children do NOT tile their parent. Measured 2026-09-01 on live data, only
// 4,031 of 24,168 split ranges were detectably short of full coverage, yet
// 47.3% of the address space in split ranges has no BGP child covering it (and
// that 47.3% is a FLOOR: the measurement sums child sizes, which double-counts
// nested children such as 22.0.0.0/14 and 22.0.0.0/16 both appearing under
// 22.0.0.0/8, so real uncovered space is higher). Deleting a parent and
// inserting only its BGP children would therefore orphan roughly half the
// space, turning a correct-but-coarse answer into no answer at all.
//
// Aligned /24s, by contrast, tile the parent EXACTLY: a /16 is precisely 256
// /24s. So deleting the parent is safe, coverage is complete, single-row lookups
// are preserved, and every /24 can carry its own measured city rather than
// inheriting one city for a range spanning several DMAs.
//
// /24 is the right unit because it is the finest granularity ip-api expresses:
// 21 probes inside three separate /24s returned byte-identical city and ZIP,
// while /24s within one /16 differed by city and even by DMA.
//
// Probing is NOT done here. check_geo_ip-api already selects ranges from
// ip2city_dbiplite_tbl that lack a geolocated row in
// ip2city_dbiplite_traceroute_tbl, so the /24 rows inserted here are picked up
// by it automatically and written back with city, region and regionname.
//
// Ranges already at /24 or narrower are left untouched: they are already at
// maximum useful granularity and have nothing to decompose.
//
// NOTE: contains NO backslash escape sequences and no backtick raw strings.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/netip"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

// insertColumns is the full column list of ip2city_dbiplite_tbl, in the order
// used by the decomposition INSERT below.
const insertColumns = "network, continent_code, continent_geoname_id, continent_names, " +
	"country_geoname_id, country_iso_code, country_is_in_eu, country_names, " +
	"city_names, latitude, longitude, subdivisions_names, " +
	"start_ip, end_ip, city, state, source"

type parent struct {
	network  string
	masklen  int
	children int64
	probes   int64
}

func main() {
	sourceTable := flag.String("candidates", "dbip_split_candidates",
		"table of split ranges to decompose (needs a cidr column named network)")
	inherit := flag.Bool("inherit-location", true,
		"copy the parent's city/state/city_names/subdivisions_names onto the new /24 rows; "+
			"false leaves them empty so unprobed /24s report no city at all")
	limit := flag.Int("limit", 0, "process at most this many parent ranges (0 = all)")
	maxProbes := flag.Int64("max-probes", 0,
		"skip any parent whose decomposition would add more than this many /24 rows (0 = no cap)")
	ensureSource := flag.Bool("ensure-source-column", true,
		"add the source column to ip2city_dbiplite_tbl if the monthly importer has not yet created it")
	dryRun := flag.Bool("dry-run", false, "report what would be done and write nothing")
	flag.Parse()

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

	if *ensureSource && !*dryRun {
		if err := ensureSourceColumn(ctx, conn); err != nil {
			log.Fatalf("ensuring source column: %v", err)
		}
	}

	excluded, err := loadExcludedPrefixes(ctx, conn)
	if err != nil {
		log.Fatalf("loading geo_exclusions: %v", err)
	}
	log.Printf("loaded %d active prefix exclusions", len(excluded))

	parents, err := loadParents(ctx, conn, *sourceTable)
	if err != nil {
		log.Fatalf("loading candidates: %v", err)
	}
	log.Printf("%d candidate ranges still present as db-ip rows", len(parents))

	var work []parent
	var skippedExcluded, skippedNarrow, skippedTooBig int
	var totalProbes int64

	for _, p := range parents {
		if p.masklen >= 24 {
			// Already at or below /24: nothing to decompose.
			skippedNarrow++
			continue
		}
		if coveredBy(p.network, excluded) {
			skippedExcluded++
			continue
		}
		if *maxProbes > 0 && p.probes > *maxProbes {
			skippedTooBig++
			continue
		}
		work = append(work, p)
		totalProbes += p.probes
	}

	log.Printf("skipped: %d already /24 or narrower, %d excluded, %d over -max-probes",
		skippedNarrow, skippedExcluded, skippedTooBig)
	log.Printf("to decompose: %d parents into %d /24 rows", len(work), totalProbes)

	if *limit > 0 && len(work) > *limit {
		work = work[:*limit]
		var t int64
		for _, p := range work {
			t += p.probes
		}
		totalProbes = t
		log.Printf("limited to %d parents (%d /24 rows)", len(work), totalProbes)
	}

	if len(work) == 0 {
		fmt.Println("Nothing to do.")
		return
	}

	fmt.Println()
	fmt.Println(fmt.Sprintf("/24 rows to insert: %d", totalProbes))
	fmt.Println(fmt.Sprintf("ip-api probe time at 45/min once inserted: %.1f days",
		float64(totalProbes)/64800.0))

	if *dryRun {
		fmt.Println()
		fmt.Println("DRY RUN: largest 20 decompositions that would run:")
		shown := 0
		for _, p := range work {
			if shown >= 20 {
				break
			}
			fmt.Println(fmt.Sprintf("  %-20s /%d -> %d /24 rows (%d bgp children)",
				p.network, p.masklen, p.probes, p.children))
			shown++
		}
		return
	}

	var doneParents int
	var doneRows, deleted int64
	t0 := time.Now()

	for i, p := range work {
		ins, del, err := decompose(ctx, conn, p, *inherit)
		if err != nil {
			log.Printf("decomposing %s failed, skipping: %v", p.network, err)
			continue
		}
		doneParents++
		doneRows += ins
		deleted += del

		if (i+1)%200 == 0 || i+1 == len(work) {
			log.Printf("progress: %d/%d parents, %d /24 rows inserted (%s elapsed)",
				i+1, len(work), doneRows, time.Since(t0).Round(time.Second))
		}
	}

	fmt.Println()
	fmt.Println("=== apply_splits complete ===")
	fmt.Println(fmt.Sprintf("parents decomposed: %d", doneParents))
	fmt.Println(fmt.Sprintf("parents deleted:    %d", deleted))
	fmt.Println(fmt.Sprintf("/24 rows inserted:  %d", doneRows))
	fmt.Println(fmt.Sprintf("elapsed:            %s", time.Since(t0).Round(time.Second)))
	fmt.Println("Next: check_geo_ip-api will probe these rows (city IS NULL in the traceroute table).")
}

// ensureSourceColumn adds the provenance column if the monthly importer has not
// yet run. ADD COLUMN with a constant DEFAULT does not rewrite the table on
// PostgreSQL 11 and later, so this is cheap even at millions of rows.
func ensureSourceColumn(ctx context.Context, conn *pgx.Conn) error {
	var has bool
	if err := conn.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM information_schema.columns "+
			"WHERE table_schema = 'public' AND table_name = 'ip2city_dbiplite_tbl' "+
			"AND column_name = 'source')").Scan(&has); err != nil {
		return err
	}
	if has {
		return nil
	}
	log.Printf("adding source column to ip2city_dbiplite_tbl (importer has not run yet)")
	if _, err := conn.Exec(ctx,
		"ALTER TABLE ip2city_dbiplite_tbl "+
			"ADD COLUMN source text NOT NULL DEFAULT 'dbip'"); err != nil {
		return err
	}
	_, err := conn.Exec(ctx,
		"CREATE INDEX IF NOT EXISTS ip2city_dbiplite_tbl_source_idx "+
			"ON ip2city_dbiplite_tbl (source)")
	return err
}

func loadExcludedPrefixes(ctx context.Context, conn *pgx.Conn) ([]netip.Prefix, error) {
	var exists bool
	if err := conn.QueryRow(ctx,
		"SELECT to_regclass('public.geo_exclusions') IS NOT NULL").Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		log.Printf("geo_exclusions does not exist; no exclusions applied")
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

// loadParents returns candidate ranges that are STILL present as db-ip rows, so
// re-running after a partial pass does no double work.
func loadParents(ctx context.Context, conn *pgx.Conn, table string) ([]parent, error) {
	ident := pgx.Identifier{table}.Sanitize()

	var hasChildren bool
	if err := conn.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM information_schema.columns "+
			"WHERE table_name = $1 AND column_name = 'bgp_children')",
		table).Scan(&hasChildren); err != nil {
		return nil, err
	}
	childExpr := "0::bigint"
	if hasChildren {
		childExpr = "coalesce(c.bgp_children, 0)"
	}

	q := "SELECT c.network::text, masklen(c.network), " + childExpr + ", " +
		"(2::numeric ^ greatest(0, 24 - masklen(c.network)))::bigint " +
		"FROM " + ident + " c " +
		"JOIN ip2city_dbiplite_tbl d ON d.network = c.network AND d.source = 'dbip' " +
		"WHERE family(c.network) = 4 " +
		"ORDER BY masklen(c.network), c.network"

	rows, err := conn.Query(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []parent
	for rows.Next() {
		var p parent
		if err := rows.Scan(&p.network, &p.masklen, &p.children, &p.probes); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func coveredBy(network string, excluded []netip.Prefix) bool {
	p, err := netip.ParsePrefix(network)
	if err != nil {
		return false
	}
	for _, x := range excluded {
		if x.Bits() <= p.Bits() && x.Contains(p.Addr()) {
			return true
		}
	}
	return false
}

// decompose expands one parent into aligned /24 rows and deletes the parent,
// atomically. The /24 addresses are generated as parent_base + i*256, which for
// a CIDR-aligned parent enumerates exactly its constituent /24s in order.
func decompose(ctx context.Context, conn *pgx.Conn, p parent, inherit bool) (int64, int64, error) {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer tx.Rollback(context.Background())

	// city_names and subdivisions_names are NOT NULL, so they always receive a
	// value: the parent's when inheriting, otherwise an empty object/array.
	insertSQL := "WITH p AS (SELECT * FROM ip2city_dbiplite_tbl " +
		"WHERE network = $1::cidr AND source = 'dbip'), " +
		"kids AS (SELECT set_masklen((host(p.network)::inet + (g.i * 256))::inet, 24)::cidr AS net, p.* " +
		"FROM p CROSS JOIN generate_series(0, " +
		"(2::numeric ^ (24 - masklen(p.network)))::bigint - 1) AS g(i)) " +
		"INSERT INTO ip2city_dbiplite_tbl (" + insertColumns + ") " +
		"SELECT k.net, k.continent_code, k.continent_geoname_id, k.continent_names, " +
		"k.country_geoname_id, k.country_iso_code, k.country_is_in_eu, k.country_names, " +
		cityNamesExprFor(inherit, "k") + ", k.latitude, k.longitude, " +
		subdivExprFor(inherit, "k") + ", " +
		"host(k.net)::inet, host(broadcast(k.net))::inet, " +
		cityExprFor(inherit, "k") + ", " + stateExprFor(inherit, "k") + ", " +
		"'routeviews' FROM kids k " +
		"ON CONFLICT (network) DO NOTHING"

	res, err := tx.Exec(ctx, insertSQL, p.network)
	if err != nil {
		return 0, 0, fmt.Errorf("insert /24 rows: %w", err)
	}
	inserted := res.RowsAffected()

	if inserted == 0 {
		// Nothing inserted means the parent was already gone or already
		// decomposed; leave the parent alone rather than deleting blindly.
		return 0, 0, nil
	}

	del, err := tx.Exec(ctx,
		"DELETE FROM ip2city_dbiplite_tbl WHERE network = $1::cidr AND source = 'dbip'",
		p.network)
	if err != nil {
		return 0, 0, fmt.Errorf("delete parent: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, 0, err
	}
	return inserted, del.RowsAffected(), nil
}

func cityNamesExprFor(inherit bool, alias string) string {
	if inherit {
		return alias + ".city_names"
	}
	return "'{}'::jsonb"
}

func subdivExprFor(inherit bool, alias string) string {
	if inherit {
		return alias + ".subdivisions_names"
	}
	return "'[]'::jsonb"
}

func cityExprFor(inherit bool, alias string) string {
	if inherit {
		return alias + ".city"
	}
	return "NULL::text"
}

func stateExprFor(inherit bool, alias string) string {
	if inherit {
		return alias + ".state"
	}
	return "NULL::text"
}
