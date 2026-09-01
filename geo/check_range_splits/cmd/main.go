// Command check_range_splits answers one question: which "unitary" db-ip
// ranges (ip2city_dbiplite_tbl, one range = one location) have since been
// split into multiple, separately-routed sub-prefixes in the live RouteViews
// BGP table (bgp_route_views)?
//
// A db-ip range R is considered SPLIT if RouteViews contains >= -min-children
// distinct prefixes that are STRICTLY more specific than R (i.e. proper subnets
// of R: b.cidr_block << R.network). That means the block db-ip treats as a
// single location is now announced as several smaller routes -- a timely signal
// (RouteViews updates every ~2h vs db-ip monthly) that R's geography may have
// fragmented and should be re-checked with ip-api before the next db-ip drop.
//
// This does NOT claim the pieces actually moved (a routing split can be pure
// traffic engineering); it produces the candidate set to re-geolocate. Ranges
// that are wholly inside a single larger BGP prefix (e.g. a db-ip /24 inside
// Comcast's 73.0.0.0/8) are NOT split -- R must contain the more-specifics.
//
// NOTE: all SQL is written as plain double-quoted single-line strings (no Go
// backtick raw-strings) so this file survives copy/paste through chat/heredocs.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	minChildren := flag.Int("min-children", 2, "minimum BGP sub-prefixes strictly inside a db-ip range to call it split")
	topN := flag.Int("top", 50, "how many of the most-fragmented ranges to print")
	examples := flag.Int("examples", 6, "how many child prefixes to show per printed range")
	ipv4Only := flag.Bool("ipv4-only", false, "consider only IPv4 db-ip ranges")
	country := flag.String("country", "", "restrict to this db-ip country_iso_code (empty = all)")
	createIndex := flag.Bool("create-index", true, "ensure the GiST containment index on ip2city_dbiplite_tbl(network) exists first")
	write := flag.Bool("write", false, "(re)populate table dbip_split_candidates with the flagged ranges for downstream re-geolocation")
	flag.Parse()

	if *minChildren < 1 {
		log.Fatal("-min-children must be >= 1")
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

	// WHERE fragment (parameterized args appended in order).
	where := ""
	args := []any{*minChildren}
	if *ipv4Only {
		where += " AND family(d.network) = 4"
	}
	if *country != "" {
		where += fmt.Sprintf(" AND d.country_iso_code = $%d", len(args)+1)
		args = append(args, *country)
	}

	if *createIndex {
		log.Printf("ensuring GiST index ip2city_network_gist (one-time; can take minutes on ~14M rows)...")
		t0 := time.Now()
		if _, err := conn.Exec(ctx, "CREATE INDEX IF NOT EXISTS ip2city_network_gist ON ip2city_dbiplite_tbl USING gist (network inet_ops)"); err != nil {
			log.Fatalf("creating index: %v", err)
		}
		log.Printf("index ready (%s)", time.Since(t0).Round(time.Second))
	}

	// Aggregate once into a session-temp table: for every db-ip range, the count
	// of BGP prefixes strictly inside it, keeping only those >= min-children.
	log.Printf("scanning for db-ip ranges split into >= %d BGP sub-prefixes%s ...",
		*minChildren, filterDesc(*ipv4Only, *country))
	t0 := time.Now()
	buildSQL := "CREATE TEMP TABLE _splits AS " +
		"SELECT d.network AS network, d.country_iso_code AS country, count(*) AS bgp_children " +
		"FROM ip2city_dbiplite_tbl d " +
		"JOIN bgp_route_views b ON b.cidr_block << d.network" + where + " " +
		"GROUP BY d.network, d.country_iso_code HAVING count(*) >= $1"
	if _, err := conn.Exec(ctx, buildSQL, args...); err != nil {
		log.Fatalf("scan failed: %v", err)
	}
	log.Printf("scan complete (%s)", time.Since(t0).Round(time.Second))

	// Headline answer.
	var total, maxChildren, sumChildren int64
	if err := conn.QueryRow(ctx,
		"SELECT count(*), coalesce(max(bgp_children),0), coalesce(sum(bgp_children),0) FROM _splits").
		Scan(&total, &maxChildren, &sumChildren); err != nil {
		log.Fatalf("summary: %v", err)
	}
	fmt.Printf("\n=== SPLIT db-ip ranges (>= %d BGP sub-prefixes): %d ===\n", *minChildren, total)
	if total == 0 {
		fmt.Println("No unitary db-ip ranges are split in the current RouteViews table.")
		return
	}
	fmt.Printf("most-fragmented range has %d sub-prefixes; %d BGP prefixes total fall inside split ranges\n\n", maxChildren, sumChildren)

	// Distribution by child-count bucket.
	fmt.Println("distribution (bgp_children -> #db-ip ranges):")
	distSQL := "SELECT CASE " +
		"WHEN bgp_children >= 100 THEN '100+' " +
		"WHEN bgp_children >= 10 THEN '10-99' " +
		"WHEN bgp_children >= 5 THEN '5-9' " +
		"WHEN bgp_children = 4 THEN '4' " +
		"WHEN bgp_children = 3 THEN '3' " +
		"ELSE '2' END AS bucket, count(*) AS n " +
		"FROM _splits GROUP BY 1 ORDER BY min(bgp_children)"
	rows, err := conn.Query(ctx, distSQL)
	if err != nil {
		log.Fatalf("distribution: %v", err)
	}
	for rows.Next() {
		var bucket string
		var n int64
		if err := rows.Scan(&bucket, &n); err != nil {
			rows.Close()
			log.Fatalf("distribution scan: %v", err)
		}
		fmt.Printf("  %-6s %d\n", bucket, n)
	}
	rows.Close()

	// Top offenders with a few example children.
	fmt.Printf("\ntop %d most-fragmented db-ip ranges:\n", *topN)
	top, err := conn.Query(ctx,
		"SELECT network::text, coalesce(country,''), bgp_children FROM _splits ORDER BY bgp_children DESC, network LIMIT $1", *topN)
	if err != nil {
		log.Fatalf("top query: %v", err)
	}
	type row struct {
		net, country string
		children     int64
	}
	var list []row
	for top.Next() {
		var r row
		if err := top.Scan(&r.net, &r.country, &r.children); err != nil {
			top.Close()
			log.Fatalf("top scan: %v", err)
		}
		list = append(list, r)
	}
	top.Close()

	exSQL := "SELECT cidr_block::text, coalesce(origin_asn::text,'?') FROM bgp_route_views " +
		"WHERE cidr_block << $1::cidr ORDER BY masklen(cidr_block), cidr_block LIMIT $2"
	for _, r := range list {
		fmt.Printf("\n  %s  [%s]  %d sub-prefixes:\n", r.net, r.country, r.children)
		ex, err := conn.Query(ctx, exSQL, r.net, *examples)
		if err != nil {
			log.Fatalf("examples: %v", err)
		}
		for ex.Next() {
			var cidr, asn string
			if err := ex.Scan(&cidr, &asn); err != nil {
				ex.Close()
				log.Fatalf("examples scan: %v", err)
			}
			fmt.Printf("      %-20s origin AS%s\n", cidr, asn)
		}
		ex.Close()
		if r.children > int64(*examples) {
			fmt.Printf("      ... and %d more\n", r.children-int64(*examples))
		}
	}

	if *write {
		log.Printf("\nwriting %d candidates to dbip_split_candidates ...", total)
		createCand := "CREATE TABLE IF NOT EXISTS dbip_split_candidates (" +
			"network cidr PRIMARY KEY, country_iso_code text, bgp_children int NOT NULL, " +
			"detected_at timestamptz NOT NULL DEFAULT now())"
		if _, err := conn.Exec(ctx, createCand); err != nil {
			log.Fatalf("create candidates table: %v", err)
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			log.Fatalf("begin: %v", err)
		}
		defer tx.Rollback(context.Background())
		if _, err := tx.Exec(ctx, "TRUNCATE dbip_split_candidates"); err != nil {
			log.Fatalf("truncate candidates: %v", err)
		}
		if _, err := tx.Exec(ctx, "INSERT INTO dbip_split_candidates (network, country_iso_code, bgp_children, detected_at) "+
			"SELECT network, country, bgp_children, now() FROM _splits"); err != nil {
			log.Fatalf("insert candidates: %v", err)
		}
		if err := tx.Commit(ctx); err != nil {
			log.Fatalf("commit candidates: %v", err)
		}
		log.Printf("dbip_split_candidates populated")
	}
}

func filterDesc(ipv4Only bool, country string) string {
	s := ""
	if ipv4Only {
		s += " [IPv4 only]"
	}
	if country != "" {
		s += " [country=" + country + "]"
	}
	return s
}
