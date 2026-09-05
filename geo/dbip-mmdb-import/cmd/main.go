package main

import (
	"context"
	"encoding/json"
	"errors"
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

	// Refuse installation if the new network count is more than this
	// fraction lower than the existing live table's count. Guards
	// against a structurally-valid but truncated/bad MMDB release
	// silently replacing good data. Adjust to taste.
	maxAllowedDropFraction = 0.20

	// Lock wait before DROP TABLE on the live table. If another
	// session is holding a conflicting lock, fail fast and roll back
	// rather than queueing every subsequent reader behind an
	// indefinite wait.
	dropLockTimeout = "5s"
)

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
	/*
		iter.Pull converts the push-style Networks() iterator into a
		resumable pull cursor. This is required: calling the Seq
		function returned by Networks() more than once restarts the
		tree traversal from the root each time, it does not resume.
		A prior version of this file called that Seq function
		directly from Next() and always returned the same first
		network.
	*/
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

// Close releases the goroutine backing iter.Pull. Safe to call
// whether or not the sequence was exhausted.
func (s *MMDBCopySource) Close() {
	s.stop()
}

func decodeRecord(result maxminddb.Result) ([]any, error) {
	var record DBIPRecord

	if err := result.Decode(&record); err != nil {
		return nil, fmt.Errorf(
			"decode MMDB network %s: %w",
			result.Prefix(),
			err,
		)
	}

	continentNames, err := jsonObject(record.Continent.Names)
	if err != nil {
		return nil, fmt.Errorf(
			"encode continent.names for %s: %w",
			result.Prefix(),
			err,
		)
	}

	countryNames, err := jsonObject(record.Country.Names)
	if err != nil {
		return nil, fmt.Errorf(
			"encode country.names for %s: %w",
			result.Prefix(),
			err,
		)
	}

	cityNames, err := jsonObject(record.City.Names)
	if err != nil {
		return nil, fmt.Errorf(
			"encode city.names for %s: %w",
			result.Prefix(),
			err,
		)
	}

	subdivisionNames, err := jsonSubdivisions(record.Subdivisions)
	if err != nil {
		return nil, fmt.Errorf(
			"encode subdivisions.names for %s: %w",
			result.Prefix(),
			err,
		)
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

/*
	jsonObject and jsonSubdivisions return string, not []byte.

	pgx encodes []byte as bytea regardless of the destination
	column's type; string is required for text-family types
	including json/jsonb. Passing []byte here previously risked
	writing raw bytes without the jsonb wire-format version-byte
	prefix that PostgreSQL's binary jsonb format requires.
*/

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

	/*
		DB-IP specifies uint32. PostgreSQL bigint can represent
		the complete uint32 domain without loss; PostgreSQL integer
		(signed 32-bit, max ~2.1B) cannot represent the top of the
		uint32 range (max ~4.29B).
	*/
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
	if len(os.Args) != 2 {
		fmt.Fprintf(
			os.Stderr,
			"usage: %s /path/to/dbip-city-lite.mmdb\n",
			os.Args[0],
		)
		os.Exit(2)
	}

	mmdbPath := os.Args[1]

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is not set")
	}

	ctx, cancel := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
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

	log.Printf(
		"verified MMDB: nodes=%d ip_version=%d database_type=%q",
		reader.Metadata.NodeCount,
		reader.Metadata.IPVersion,
		reader.Metadata.DatabaseType,
	)

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
		if err := tx.Rollback(ctx); err != nil &&
			!errors.Is(err, pgx.ErrTxClosed) {
			log.Printf("rollback failed: %v", err)
		}
	}

	/*
		Record the existing live table's row count (if it exists)
		before touching anything, for the post-COPY plausibility
		check below.
	*/
	var liveTableExists bool
	err = tx.QueryRow(ctx, `
SELECT to_regclass('public.ip2city_dbiplite_tbl') IS NOT NULL
`).Scan(&liveTableExists)
	if err != nil {
		rollback()
		log.Fatalf("check for existing live table: %v", err)
	}

	var oldCount int64
	if liveTableExists {
		err = tx.QueryRow(ctx, `
SELECT count(*) FROM ip2city_dbiplite_tbl
`).Scan(&oldCount)
		if err != nil {
			rollback()
			log.Fatalf("count existing live table: %v", err)
		}
	}

	_, err = tx.Exec(ctx, `
DROP TABLE IF EXISTS ip2city_dbiplite_tbl_load
`)
	if err != nil {
		rollback()
		log.Fatalf("remove previous load table: %v", err)
	}

	/*
		bigint/text here are deliberate and must match
		table_create_ip2city_dbiplite_tbl.sql: DB-IP defines
		GeoNames IDs as uint32 (bigint avoids overflow), and char(2)
		is avoided in favor of text.
	*/
	_, err = tx.Exec(ctx, `
CREATE UNLOGGED TABLE ip2city_dbiplite_tbl_load (
    network                   cidr NOT NULL,

    continent_code            text NOT NULL,
    continent_geoname_id      bigint,
    continent_names           jsonb NOT NULL,

    country_geoname_id        bigint,
    country_iso_code          text,
    country_is_in_eu          boolean,
    country_names             jsonb NOT NULL,

    city_names                jsonb NOT NULL,

    latitude                  double precision,
    longitude                 double precision,

    subdivisions_names        jsonb NOT NULL,

    PRIMARY KEY (network)
)
`)
	if err != nil {
		rollback()
		log.Fatalf("create load table: %v", err)
	}

	log.Println("streaming MMDB networks into PostgreSQL COPY")

	source := newMMDBCopySource(reader)
	defer source.Close()

	count, err := tx.CopyFrom(
		ctx,
		pgx.Identifier{loadTable},
		[]string{
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
		},
		source,
	)
	if err != nil {
		rollback()
		log.Fatalf("COPY aborted: %v", err)
	}

	if count == 0 {
		rollback()
		log.Fatal("MMDB produced zero networks; refusing installation")
	}

	if liveTableExists && oldCount > 0 {
		dropped := float64(oldCount-count) / float64(oldCount)
		if dropped > maxAllowedDropFraction {
			rollback()
			log.Fatalf(
				"refusing install: new count %d is %.1f%% below existing live count %d (threshold %.0f%%)",
				count, dropped*100, oldCount, maxAllowedDropFraction*100,
			)
		}
	}

	log.Printf("COPY completed: %d networks (previous live count: %d)", count, oldCount)

	var loaded int64

	err = tx.QueryRow(
		ctx,
		`SELECT count(*) FROM ip2city_dbiplite_tbl_load`,
	).Scan(&loaded)
	if err != nil {
		rollback()
		log.Fatalf("load-table count failed: %v", err)
	}

	if loaded != count {
		rollback()
		log.Fatalf(
			"row-count verification failed: COPY=%d table=%d",
			count,
			loaded,
		)
	}

	_, err = tx.Exec(ctx, `
CREATE INDEX ip2city_dbiplite_tbl_load_network_gist
ON ip2city_dbiplite_tbl_load
USING gist (network inet_ops)
`)
	if err != nil {
		rollback()
		log.Fatalf("GiST index creation failed: %v", err)
	}

	/*
		Convert the load table (and its indexes) from UNLOGGED to
		LOGGED before it becomes the live table. Building unlogged
		and converting once here is faster than logging every row
		during COPY, but skipping this step entirely (as the prior
		version did) leaves the live table permanently UNLOGGED:
		invisible on streaming replicas and truncated on any
		unclean PostgreSQL restart.
	*/
	_, err = tx.Exec(ctx, `
ALTER TABLE ip2city_dbiplite_tbl_load SET LOGGED
`)
	if err != nil {
		rollback()
		log.Fatalf("SET LOGGED failed: %v", err)
	}

	/*
		Bound how long we'll wait to acquire the exclusive lock the
		DROP below needs. Without this, a stuck reader elsewhere
		blocks this DROP indefinitely, and every subsequent query
		against the live table queues up behind it (PostgreSQL lock
		acquisition is FIFO).
	*/
	_, err = tx.Exec(ctx, fmt.Sprintf(
		`SET LOCAL lock_timeout = '%s'`, dropLockTimeout,
	))
	if err != nil {
		rollback()
		log.Fatalf("set lock_timeout failed: %v", err)
	}

	_, err = tx.Exec(ctx, `
DROP TABLE IF EXISTS ip2city_dbiplite_tbl
`)
	if err != nil {
		rollback()
		log.Fatalf("drop old live table failed (possibly lock timeout): %v", err)
	}

	_, err = tx.Exec(ctx, `
ALTER TABLE ip2city_dbiplite_tbl_load
RENAME TO ip2city_dbiplite_tbl
`)
	if err != nil {
		rollback()
		log.Fatalf("rename load table failed: %v", err)
	}

	_, err = tx.Exec(ctx, `
ALTER INDEX ip2city_dbiplite_tbl_load_pkey
RENAME TO ip2city_dbiplite_tbl_pkey
`)
	if err != nil {
		rollback()
		log.Fatalf("rename primary-key index failed: %v", err)
	}

	_, err = tx.Exec(ctx, `
ALTER INDEX ip2city_dbiplite_tbl_load_network_gist
RENAME TO ip2city_dbiplite_tbl_network_gist
`)
	if err != nil {
		rollback()
		log.Fatalf("rename GiST index failed: %v", err)
	}

	_, err = tx.Exec(ctx, `
ANALYZE ip2city_dbiplite_tbl
`)
	if err != nil {
		rollback()
		log.Fatalf("ANALYZE failed: %v", err)
	}

	if err := tx.Commit(ctx); err != nil {
		log.Fatalf("commit failed: %v", err)
	}

	log.Printf(
		"SUCCESS: installed %s with %d networks",
		liveTable,
		count,
	)
}
