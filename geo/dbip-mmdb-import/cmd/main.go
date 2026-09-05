// Command dbip-mmdb-import loads a DB-IP City Lite MMDB file into PostgreSQL,
// building a new table and swapping it into place atomically.
//
// Strategy 1 of the two considered: replace the db-ip rows wholesale from the
// monthly MMDB, then recompute the derived columns. The db-ip PHP updater
// (dbip-phpsrc-4.0) was rejected because it is MySQL-only: it contains no
// pgsql references at all, uses "create table X like Y" and the multi-table
// "rename table A to B, C to D" statement (neither of which PostgreSQL has),
// hardcodes backquote identifier quoting, and requires a paid account key.
//
// Columns beyond the 12 MMDB-derived ones:
//
//	start_ip, end_ip  derived from network
//	city              city_names ->> 'en' with any " (...)" suffix removed
//	state             subdivisions_names -> 0 -> 'names' ->> 'en'
//	source            provenance: 'dbip' or 'routeviews'
//
// All four are recomputable, so replacing the table destroys no unique data.
// The source column distinguishes db-ip rows from RouteViews-derived child
// prefixes inserted by the split pipeline, so an import can replace the former
// without discarding the latter.
//
// -preserve-routeviews controls what happens to RouteViews rows:
//
//	conditional  (default) keep a RouteViews child only if the NEW db-ip
//	             edition still has a strictly wider row covering it, i.e.
//	             db-ip has not yet caught up. Once db-ip provides equal or
//	             finer granularity, defer to db-ip and drop the child.
//	all          keep every RouteViews row regardless.
//	none         discard them; the split pipeline will regenerate them.
//
// NOTE: this file contains NO backtick raw strings and NO backslash escape
// sequences anywhere, so it survives copy/paste through chat and heredocs.
// The city regex uses the bracket expression " [(].*" rather than the
// backslash-escaped parenthesis form; the two are equivalent in POSIX ERE and
// the bracket form needs no backslash.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"iter"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5"
	"github.com/oschwald/maxminddb-golang/v2"
)

const (
	liveTable = "ip2city_dbiplite_tbl"
	loadTable = "ip2city_dbiplite_tbl_load"

	// Refuse installation if the new db-ip row count is more than this
	// fraction lower than the existing live table's db-ip count. Guards
	// against a structurally-valid but truncated MMDB release silently
	// replacing good data.
	maxAllowedDropFraction = 0.20

	// Lock wait before DROP TABLE on the live table. If another session
	// holds a conflicting lock, fail fast and roll back rather than
	// queueing every subsequent reader behind an indefinite wait.
	dropLockTimeout = "5s"
)

// copyColumns are the columns fed by COPY from the MMDB, in order.
var copyColumns = []string{
	"network",
	"continent_code",
	"continent_geoname_id",
	"continent_names",
	"country_geoname_id",
	"country_iso_code",
	"country_is_in_eu",
	"country_names",
	"city_names",
	"latitude",
	"longitude",
	"subdivisions_names",
}

// allColumns is the full column list, used when carrying rows forward from the
// previous live table.
const allColumns = "network, continent_code, continent_geoname_id, continent_names, " +
	"country_geoname_id, country_iso_code, country_is_in_eu, country_names, " +
	"city_names, latitude, longitude, subdivisions_names, " +
	"start_ip, end_ip, city, state, source"

type Subdivision struct {
	GeonameID *uint32           `maxminddb:"geoname_id" json:"geoname_id,omitempty"`
	ISOCode   string            `maxminddb:"iso_code"   json:"iso_code,omitempty"`
	Names     map[string]string `maxminddb:"names"      json:"names"`
}

type DBIPRecord struct {
	City struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"city"`

	Continent struct {
		Code      string            `maxminddb:"code"`
		GeonameID *uint32           `maxminddb:"geoname_id"`
		Names     map[string]string `maxminddb:"names"`
	} `maxminddb:"continent"`

	Country struct {
		GeonameID         *uint32           `maxminddb:"geoname_id"`
		ISOCode           string            `maxminddb:"iso_code"`
		IsInEuropeanUnion *bool             `maxminddb:"is_in_european_union"`
		Names             map[string]string `maxminddb:"names"`
	} `maxminddb:"country"`

	Location struct {
		Latitude  *float64 `maxminddb:"latitude"`
		Longitude *float64 `maxminddb:"longitude"`
	} `maxminddb:"location"`

	Subdivisions []Subdivision `maxminddb:"subdivisions"`
}

type MMDBCopySource struct {
	next func() (maxminddb.Result, bool)
	stop func()

	current []any
	err     error
	done    bool
}

func newMMDBCopySource(reader *maxminddb.Reader) *MMDBCopySource {
	// iter.Pull converts the push-style Networks() iterator into a
	// resumable pull cursor. This is required: calling the Seq function
	// returned by Networks() more than once restarts the tree traversal
	// from the root each time, it does not resume. An early version of
	// this file called that Seq directly from Next() and therefore always
	// returned the same first network.
	var seq iter.Seq[maxminddb.Result] = reader.Networks()
	next, stop := iter.Pull(seq)

	return &MMDBCopySource{next: next, stop: stop}
}

func (s *MMDBCopySource) Next() bool {
	if s.done || s.err != nil {
		return false
	}

	result, ok := s.next()
	if !ok {
		s.done = true
		return false
	}

	record, err := decodeRecord(result)
	if err != nil {
		s.err = err
		s.done = true
		return false
	}

	s.current = record
	return true
}

func (s *MMDBCopySource) Values() ([]any, error) {
	if s.current == nil {
		return nil, errors.New("Values called without a current row")
	}

	return s.current, nil
}

func (s *MMDBCopySource) Err() error {
	return s.err
}

// Close releases the goroutine backing iter.Pull. Safe to call whether or not
// the sequence was exhausted.
func (s *MMDBCopySource) Close() {
	s.stop()
}

func decodeRecord(result maxminddb.Result) ([]any, error) {
	var record DBIPRecord

	if err := result.Decode(&record); err != nil {
		return nil, fmt.Errorf("decode MMDB network %s: %w", result.Prefix(), err)
	}

	continentNames, err := jsonObject(record.Continent.Names)
	if err != nil {
		return nil, fmt.Errorf("encode continent.names for %s: %w", result.Prefix(), err)
	}

	countryNames, err := jsonObject(record.Country.Names)
	if err != nil {
		return nil, fmt.Errorf("encode country.names for %s: %w", result.Prefix(), err)
	}

	cityNames, err := jsonObject(record.City.Names)
	if err != nil {
		return nil, fmt.Errorf("encode city.names for %s: %w", result.Prefix(), err)
	}

	subdivisionNames, err := jsonSubdivisions(record.Subdivisions)
	if err != nil {
		return nil, fmt.Errorf("encode subdivisions.names for %s: %w", result.Prefix(), err)
	}

	return []any{
		result.Prefix().String(),

		record.Continent.Code,
		geonameID(record.Continent.GeonameID),
		continentNames,

		geonameID(record.Country.GeonameID),
		nullIfEmpty(record.Country.ISOCode),
		record.Country.IsInEuropeanUnion,
		countryNames,

		cityNames,

		record.Location.Latitude,
		record.Location.Longitude,

		subdivisionNames,
	}, nil
}

// jsonObject and jsonSubdivisions return string, not []byte.
//
// pgx encodes []byte as bytea regardless of the destination column's type;
// string is required for text-family types including json and jsonb. Passing
// []byte here previously risked writing raw bytes without the version-byte
// prefix that PostgreSQL's binary jsonb format requires.
func jsonObject(v map[string]string) (string, error) {
	if v == nil {
		return "{}", nil
	}

	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}

	return string(b), nil
}

func jsonSubdivisions(v []Subdivision) (string, error) {
	if v == nil {
		return "[]", nil
	}

	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}

	return string(b), nil
}

func geonameID(v *uint32) *int64 {
	if v == nil {
		return nil
	}

	// DB-IP specifies uint32. PostgreSQL bigint represents the complete
	// uint32 domain without loss; PostgreSQL integer (signed 32-bit, max
	// about 2.1e9) cannot represent the top of the uint32 range.
	x := int64(*v)
	return &x
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}

	return &s
}

func main() {
	preserve := flag.String("preserve-routeviews", "conditional",
		"what to do with source='routeviews' rows: conditional, all, or none")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: dbip-mmdb-import [flags] /path/to/dbip-city-lite.mmdb")
		flag.PrintDefaults()
	}
	flag.Parse()

	switch *preserve {
	case "conditional", "all", "none":
	default:
		log.Fatalf("invalid -preserve-routeviews %q: want conditional, all, or none", *preserve)
	}

	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	mmdbPath := flag.Arg(0)

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is not set")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	log.Printf("opening MMDB: %s", mmdbPath)

	reader, err := maxminddb.Open(mmdbPath)
	if err != nil {
		log.Fatalf("open MMDB: %v", err)
	}
	defer reader.Close()

	if err := reader.Verify(); err != nil {
		log.Fatalf("MMDB verification failed: %v", err)
	}

	log.Printf("verified MMDB: nodes=%d ip_version=%d database_type=%q build=%s",
		reader.Metadata.NodeCount, reader.Metadata.IPVersion,
		reader.Metadata.DatabaseType, reader.Metadata.BuildTime())

	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		log.Fatalf("PostgreSQL connection failed: %v", err)
	}
	defer conn.Close(context.Background())

	if err := conn.Ping(ctx); err != nil {
		log.Fatalf("PostgreSQL ping failed: %v", err)
	}

	tx, err := conn.Begin(ctx)
	if err != nil {
		log.Fatalf("begin transaction: %v", err)
	}

	rollback := func() {
		if err := tx.Rollback(ctx); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			log.Printf("rollback failed: %v", err)
		}
	}

	// Inspect the existing live table before touching anything.
	var liveTableExists bool
	if err := tx.QueryRow(ctx,
		"SELECT to_regclass('public.ip2city_dbiplite_tbl') IS NOT NULL").Scan(&liveTableExists); err != nil {
		rollback()
		log.Fatalf("check for existing live table: %v", err)
	}

	// A live table created before the source column existed holds only db-ip
	// rows, so there is nothing to preserve in that case.
	var hasSourceColumn bool
	if liveTableExists {
		if err := tx.QueryRow(ctx,
			"SELECT EXISTS (SELECT 1 FROM information_schema.columns "+
				"WHERE table_schema = 'public' AND table_name = 'ip2city_dbiplite_tbl' "+
				"AND column_name = 'source')").Scan(&hasSourceColumn); err != nil {
			rollback()
			log.Fatalf("check for source column: %v", err)
		}
	}

	var oldTotal, oldDbip, oldRouteviews int64
	if liveTableExists {
		if err := tx.QueryRow(ctx,
			"SELECT count(*) FROM ip2city_dbiplite_tbl").Scan(&oldTotal); err != nil {
			rollback()
			log.Fatalf("count existing live table: %v", err)
		}
		if hasSourceColumn {
			if err := tx.QueryRow(ctx,
				"SELECT count(*) FILTER (WHERE source = 'dbip'), "+
					"count(*) FILTER (WHERE source = 'routeviews') "+
					"FROM ip2city_dbiplite_tbl").Scan(&oldDbip, &oldRouteviews); err != nil {
				rollback()
				log.Fatalf("count by source: %v", err)
			}
		} else {
			oldDbip = oldTotal
			log.Printf("existing live table has no source column; treating all %d rows as db-ip", oldTotal)
		}
		log.Printf("existing live table: %d rows (db-ip %d, routeviews %d)",
			oldTotal, oldDbip, oldRouteviews)
	}

	if _, err := tx.Exec(ctx, "DROP TABLE IF EXISTS ip2city_dbiplite_tbl_load"); err != nil {
		rollback()
		log.Fatalf("remove previous load table: %v", err)
	}

	// bigint/text are deliberate: DB-IP defines GeoNames IDs as uint32, so
	// bigint avoids overflow, and char(2) is avoided in favour of text.
	createLoad := "CREATE UNLOGGED TABLE ip2city_dbiplite_tbl_load (" +
		"network cidr NOT NULL, " +
		"continent_code text NOT NULL, " +
		"continent_geoname_id bigint, " +
		"continent_names jsonb NOT NULL, " +
		"country_geoname_id bigint, " +
		"country_iso_code text, " +
		"country_is_in_eu boolean, " +
		"country_names jsonb NOT NULL, " +
		"city_names jsonb NOT NULL, " +
		"latitude double precision, " +
		"longitude double precision, " +
		"subdivisions_names jsonb NOT NULL, " +
		"start_ip inet, " +
		"end_ip inet, " +
		"city text, " +
		"state text, " +
		"source text NOT NULL DEFAULT 'dbip', " +
		"PRIMARY KEY (network))"
	if _, err := tx.Exec(ctx, createLoad); err != nil {
		rollback()
		log.Fatalf("create load table: %v", err)
	}

	log.Println("streaming MMDB networks into PostgreSQL COPY")

	source := newMMDBCopySource(reader)
	defer source.Close()

	count, err := tx.CopyFrom(ctx, pgx.Identifier{loadTable}, copyColumns, source)
	if err != nil {
		rollback()
		log.Fatalf("COPY aborted: %v", err)
	}

	if count == 0 {
		rollback()
		log.Fatal("MMDB produced zero networks; refusing installation")
	}

	if liveTableExists && oldDbip > 0 {
		dropped := float64(oldDbip-count) / float64(oldDbip)
		if dropped > maxAllowedDropFraction {
			rollback()
			log.Fatalf("refusing install: new db-ip count %d is %.1f%% below existing db-ip count %d (threshold %.0f%%)",
				count, dropped*100, oldDbip, maxAllowedDropFraction*100)
		}
	}

	log.Printf("COPY completed: %d networks (previous db-ip count: %d)", count, oldDbip)

	var loaded int64
	if err := tx.QueryRow(ctx,
		"SELECT count(*) FROM ip2city_dbiplite_tbl_load").Scan(&loaded); err != nil {
		rollback()
		log.Fatalf("load-table count failed: %v", err)
	}
	if loaded != count {
		rollback()
		log.Fatalf("row-count verification failed: COPY=%d table=%d", count, loaded)
	}

	// Derive the four computed columns. The city expression uses the bracket
	// expression " [(].*" instead of the backslash-escaped parenthesis form so
	// this source stays free of backslashes; the two are equivalent in POSIX
	// ERE (verified against seven cases including nested and unbalanced
	// parentheses).
	log.Println("computing start_ip, end_ip, city, state")
	deriveSQL := "UPDATE ip2city_dbiplite_tbl_load SET " +
		"start_ip = host(network)::inet, " +
		"end_ip = host(broadcast(network))::inet, " +
		"city = regexp_replace(city_names ->> 'en', ' [(].*', ''), " +
		"state = subdivisions_names -> 0 -> 'names' ->> 'en'"
	derived, err := tx.Exec(ctx, deriveSQL)
	if err != nil {
		rollback()
		log.Fatalf("deriving computed columns: %v", err)
	}
	log.Printf("derived columns for %d rows", derived.RowsAffected())

	if _, err := tx.Exec(ctx,
		"CREATE INDEX ip2city_dbiplite_tbl_load_network_gist "+
			"ON ip2city_dbiplite_tbl_load USING gist (network inet_ops)"); err != nil {
		rollback()
		log.Fatalf("GiST index creation failed: %v", err)
	}

	if _, err := tx.Exec(ctx,
		"CREATE INDEX ip2city_dbiplite_tbl_load_source_idx "+
			"ON ip2city_dbiplite_tbl_load (source)"); err != nil {
		rollback()
		log.Fatalf("source index creation failed: %v", err)
	}

	// Carry RouteViews-derived rows forward. The GiST index above exists
	// already so the containment test in the conditional case is indexed.
	var kept int64
	if liveTableExists && hasSourceColumn && oldRouteviews > 0 && *preserve != "none" {
		cond := ""
		if *preserve == "conditional" {
			// Keep the child only if the NEW db-ip edition still has a
			// strictly wider row covering it, meaning db-ip has not yet
			// caught up to the split RouteViews already reported.
			cond = " AND EXISTS (SELECT 1 FROM ip2city_dbiplite_tbl_load l " +
				"WHERE l.source = 'dbip' AND o.network << l.network)"
		}
		preserveSQL := "INSERT INTO ip2city_dbiplite_tbl_load (" + allColumns + ") " +
			"SELECT " + allColumns + " FROM ip2city_dbiplite_tbl o " +
			"WHERE o.source = 'routeviews'" + cond +
			" ON CONFLICT (network) DO NOTHING"
		res, err := tx.Exec(ctx, preserveSQL)
		if err != nil {
			rollback()
			log.Fatalf("preserving routeviews rows: %v", err)
		}
		kept = res.RowsAffected()
		log.Printf("preserved %d of %d routeviews rows (-preserve-routeviews=%s)",
			kept, oldRouteviews, *preserve)
	} else if oldRouteviews > 0 {
		log.Printf("discarding %d routeviews rows (-preserve-routeviews=%s)",
			oldRouteviews, *preserve)
	}

	// Convert the load table and its indexes from UNLOGGED to LOGGED before it
	// becomes the live table. Building unlogged and converting once is faster
	// than logging every row during COPY, but skipping this step leaves the
	// live table permanently UNLOGGED: invisible on streaming replicas and
	// truncated on any unclean PostgreSQL restart.
	if _, err := tx.Exec(ctx, "ALTER TABLE ip2city_dbiplite_tbl_load SET LOGGED"); err != nil {
		rollback()
		log.Fatalf("SET LOGGED failed: %v", err)
	}

	// Bound how long we wait for the exclusive lock the DROP needs. Without
	// this, a stuck reader blocks the DROP indefinitely and every subsequent
	// query against the live table queues behind it, since PostgreSQL lock
	// acquisition is FIFO.
	if _, err := tx.Exec(ctx,
		fmt.Sprintf("SET LOCAL lock_timeout = '%s'", dropLockTimeout)); err != nil {
		rollback()
		log.Fatalf("set lock_timeout failed: %v", err)
	}

	if _, err := tx.Exec(ctx, "DROP TABLE IF EXISTS ip2city_dbiplite_tbl"); err != nil {
		rollback()
		log.Fatalf("drop old live table failed (possibly lock timeout): %v", err)
	}

	if _, err := tx.Exec(ctx,
		"ALTER TABLE ip2city_dbiplite_tbl_load RENAME TO ip2city_dbiplite_tbl"); err != nil {
		rollback()
		log.Fatalf("rename load table failed: %v", err)
	}

	renames := [][2]string{
		{"ip2city_dbiplite_tbl_load_pkey", "ip2city_dbiplite_tbl_pkey"},
		{"ip2city_dbiplite_tbl_load_network_gist", "ip2city_dbiplite_tbl_network_gist"},
		{"ip2city_dbiplite_tbl_load_source_idx", "ip2city_dbiplite_tbl_source_idx"},
	}
	for _, r := range renames {
		if _, err := tx.Exec(ctx,
			"ALTER INDEX "+r[0]+" RENAME TO "+r[1]); err != nil {
			rollback()
			log.Fatalf("rename index %s failed: %v", r[0], err)
		}
	}

	if _, err := tx.Exec(ctx, "ANALYZE ip2city_dbiplite_tbl"); err != nil {
		rollback()
		log.Fatalf("ANALYZE failed: %v", err)
	}

	if err := tx.Commit(ctx); err != nil {
		log.Fatalf("commit failed: %v", err)
	}

	fmt.Println()
	fmt.Println("=== import complete ===")
	fmt.Println(fmt.Sprintf("table:              %s", liveTable))
	fmt.Println(fmt.Sprintf("db-ip rows:         %d (was %d)", count, oldDbip))
	fmt.Println(fmt.Sprintf("routeviews rows:    %d (was %d)", kept, oldRouteviews))
	fmt.Println(fmt.Sprintf("total rows:         %d", count+kept))
	fmt.Println("NOTE: dbip_split_candidates is now stale; re-run check_range_splits.")
}
