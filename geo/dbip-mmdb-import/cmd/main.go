// Command dbip-mmdb-import loads a DB-IP City Lite MMDB into PostgreSQL,
// building a new table and swapping it into place atomically. It can fetch the
// current month's free edition itself, so it is safe to run from crontab on the
// 1st or 2nd of each month.
//
// Strategy 1 of the two considered. The db-ip PHP updater (dbip-phpsrc-4.0) was
// rejected because it is MySQL-only: no pgsql references anywhere, it uses
// "create table X like Y" and the multi-table "rename table A to B, C to D"
// statement (neither of which PostgreSQL has), hardcodes backquote identifier
// quoting, and requires a paid account key. The free MMDB needs no key.
//
// Pipeline, all inside ONE transaction:
//
//  1. build an UNLOGGED load table with the full column set
//  2. COPY every network from the MMDB into it (source defaults to 'dbip')
//  3. delete rows outside the kept-country list (see keepCountriesDefault)
//  4. derive start_ip, end_ip, city, state
//  5. carry forward source='routeviews' rows from the previous live table
//  6. SET LOGGED, then atomically DROP + RENAME into place
//
// Why build-and-swap rather than DELETE then INSERT in place: deleting ~5.4M
// rows in place bloats the heap and needs VACUUM FULL to reclaim, and leaves the
// live table incomplete for the duration. The swap produces the same end state
// atomically, with no bloat and no window where readers see partial data.
//
// Row provenance is carried in the source column ('dbip' or 'routeviews') so an
// import can replace db-ip rows without discarding the RouteViews-derived child
// prefixes the split pipeline inserted. Identifying db-ip rows by "city IS NOT
// NULL" would NOT be safe: city is populated for every db-ip row and would also
// be populated for RouteViews rows once ip-api has enriched them, so such a
// predicate would delete the RouteViews work too.
//
// NOTE: this file contains NO backslash escape sequences and no backtick raw
// strings. The only backticks are Go struct tags, which the language requires.
// The city regex uses the bracket expression " [(].*" rather than the
// backslash-escaped parenthesis form; the two are equivalent in POSIX ERE.
package main

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"iter"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/oschwald/maxminddb-golang/v2"
)

const (
	liveTable = "ip2city_dbiplite_tbl"
	loadTable = "ip2city_dbiplite_tbl_load"

	// Free City Lite editions live at a predictable monthly URL and need no
	// account key: dbip-city-lite-YYYY-MM.mmdb.gz
	downloadBase = "https://download.db-ip.com/free/"

	// Refuse installation if the new db-ip row count is more than this
	// fraction below the previous db-ip count, after the same country filter
	// is applied to both. Guards against a structurally valid but truncated
	// release silently replacing good data.
	maxAllowedDropFraction = 0.20

	// Lock wait before DROP TABLE on the live table. If another session holds
	// a conflicting lock, fail fast rather than queueing every subsequent
	// reader behind an indefinite wait, since lock acquisition is FIFO.
	dropLockTimeout = "5s"
)

// keepCountriesDefault lists the ISO country codes to KEEP. Everything else is
// deleted from the load table before the derived columns are computed.
//
// EDIT THIS (or pass -countries) WHEN ADDING COUNTRIES. For example, to add
// Canada and Mexico:
//
//	var keepCountriesDefault = []string{"US", "CA", "MX"}
//
// Pass -countries "" to keep every country, i.e. disable the filter entirely.
//
// Rows with a NULL country_iso_code are also deleted when a filter is active,
// on the basis that a row of unknown country is not a row in the kept set.
var keepCountriesDefault = []string{"US"}

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

// allColumns is the full column list, used when carrying RouteViews rows
// forward from the previous live table.
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
	// iter.Pull converts the push-style Networks() iterator into a resumable
	// pull cursor. This is required: calling the Seq returned by Networks()
	// more than once restarts the tree traversal from the root, it does not
	// resume. An early version called that Seq directly from Next() and so
	// always returned the same first network.
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

// Close releases the goroutine backing iter.Pull. Safe whether or not the
// sequence was exhausted.
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
// pgx encodes []byte as bytea regardless of the destination column type; string
// is required for text-family types including json and jsonb. Passing []byte
// risks writing raw bytes without the version-byte prefix that PostgreSQL's
// binary jsonb format requires.
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

	// DB-IP specifies uint32. PostgreSQL bigint covers the whole uint32
	// domain; PostgreSQL integer (signed 32-bit) does not.
	x := int64(*v)
	return &x
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}

	return &s
}

// editionForMonth returns the edition label and download URL for a month given
// as YYYY-MM.
func editionForMonth(month string) (string, string) {
	name := "dbip-city-lite-" + month + ".mmdb.gz"
	return month, downloadBase + name
}

// currentMonth and previousMonth normalise to the first of the month before
// arithmetic, so running on the 31st cannot skip a month.
func currentMonth(now time.Time) string {
	return time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC).Format("2006-01")
}

func previousMonth(now time.Time) string {
	first := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	return first.AddDate(0, -1, 0).Format("2006-01")
}

// newHTTPClient returns a client with NO overall timeout, per the standing
// requirement not to time out these downloads at all. Connection-level
// timeouts remain so a dead peer still fails rather than hanging forever.
func newHTTPClient() *http.Client {
	transport := &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 120 * time.Second,
		ExpectContinueTimeout: 10 * time.Second,
	}

	return &http.Client{Transport: transport, Timeout: 0}
}

// fetchAndDecompress downloads url and writes the gunzipped MMDB to destPath.
// It downloads to a temporary file first so an interrupted transfer cannot
// leave a truncated file that looks complete.
func fetchAndDecompress(ctx context.Context, client *http.Client, url, destPath string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d for %s", resp.StatusCode, url)
	}

	log.Printf("downloading %s (content-length %d)", url, resp.ContentLength)

	tmp, err := os.CreateTemp(filepath.Dir(destPath), ".dbip-download-")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		tmp.Close()
		os.Remove(tmpName)
	}()

	gz, err := gzip.NewReader(resp.Body)
	if err != nil {
		return fmt.Errorf("opening gzip stream: %w", err)
	}
	defer gz.Close()

	written, err := io.Copy(tmp, gz)
	if err != nil {
		return fmt.Errorf("decompressing to %s: %w", tmpName, err)
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}

	if err := os.Rename(tmpName, destPath); err != nil {
		return err
	}

	log.Printf("wrote %s (%d bytes decompressed)", destPath, written)
	return nil
}

func main() {
	month := flag.String("month", "", "edition to fetch as YYYY-MM (default: current month)")
	fallbackPrev := flag.Bool("fallback-previous", true,
		"if the requested month is not published yet, fall back to the previous month")
	downloadDir := flag.String("download-dir", os.TempDir(), "directory for the downloaded MMDB")
	keepDownload := flag.Bool("keep-download", false, "do not delete the decompressed MMDB afterwards")
	countries := flag.String("countries", "",
		"comma-separated ISO codes to KEEP, overriding the built-in list; empty string uses the built-in list, and the literal value none keeps all countries")
	preserve := flag.String("preserve-routeviews", "conditional",
		"what to do with source='routeviews' rows: conditional, all, or none")
	maxDropFraction := flag.Float64("max-drop-fraction", maxAllowedDropFraction,
		"refuse the install if the new db-ip row count falls more than this fraction below the previous one; raise it for the first run that introduces a country filter")
	force := flag.Bool("force", false, "import even if this edition is already recorded as imported")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: dbip-mmdb-import [flags] [/path/to/local.mmdb]")
		fmt.Fprintln(os.Stderr, "With no path argument, the current month's free edition is downloaded.")
		flag.PrintDefaults()
	}
	flag.Parse()

	switch *preserve {
	case "conditional", "all", "none":
	default:
		log.Fatalf("invalid -preserve-routeviews %q: want conditional, all, or none", *preserve)
	}

	keep := keepCountriesDefault
	switch *countries {
	case "":
		// use built-in list
	case "none":
		keep = nil
	default:
		keep = splitAndTrim(*countries)
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is not set")
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		log.Fatalf("PostgreSQL connection failed: %v", err)
	}
	defer conn.Close(context.Background())

	if err := conn.Ping(ctx); err != nil {
		log.Fatalf("PostgreSQL ping failed: %v", err)
	}

	if err := ensureStateTable(ctx, conn); err != nil {
		log.Fatalf("creating dbip_import_state: %v", err)
	}

	// Resolve the MMDB: either a local path given on the command line, or the
	// month's free edition downloaded now.
	var mmdbPath, edition, sourceURL string
	cleanup := false

	if flag.NArg() == 1 {
		mmdbPath = flag.Arg(0)
		edition = "local:" + filepath.Base(mmdbPath)
		sourceURL = mmdbPath
	} else if flag.NArg() > 1 {
		flag.Usage()
		os.Exit(2)
	} else {
		want := *month
		if want == "" {
			want = currentMonth(time.Now())
		}
		edition, sourceURL = editionForMonth(want)

		if !*force {
			done, err := alreadyImported(ctx, conn, edition)
			if err != nil {
				log.Fatalf("checking import state: %v", err)
			}
			if done {
				log.Printf("edition %s already imported; nothing to do (use -force to repeat)", edition)
				return
			}
		}

		client := newHTTPClient()
		mmdbPath = filepath.Join(*downloadDir, "dbip-city-lite-"+want+".mmdb")

		err := fetchAndDecompress(ctx, client, sourceURL, mmdbPath)
		if err != nil && *fallbackPrev {
			prev := previousMonth(time.Now())
			log.Printf("edition %s unavailable (%v); falling back to %s", want, err, prev)
			edition, sourceURL = editionForMonth(prev)

			if !*force {
				done, derr := alreadyImported(ctx, conn, edition)
				if derr != nil {
					log.Fatalf("checking import state: %v", derr)
				}
				if done {
					log.Printf("fallback edition %s already imported; nothing to do", edition)
					return
				}
			}

			mmdbPath = filepath.Join(*downloadDir, "dbip-city-lite-"+prev+".mmdb")
			err = fetchAndDecompress(ctx, client, sourceURL, mmdbPath)
		}
		if err != nil {
			log.Fatalf("download failed: %v", err)
		}
		cleanup = !*keepDownload
	}

	if cleanup {
		defer func() {
			if rmErr := os.Remove(mmdbPath); rmErr != nil {
				log.Printf("could not remove %s: %v", mmdbPath, rmErr)
			}
		}()
	}

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

	tx, err := conn.Begin(ctx)
	if err != nil {
		log.Fatalf("begin transaction: %v", err)
	}

	rollback := func() {
		if err := tx.Rollback(ctx); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			log.Printf("rollback failed: %v", err)
		}
	}

	var liveTableExists bool
	if err := tx.QueryRow(ctx,
		"SELECT to_regclass('public.ip2city_dbiplite_tbl') IS NOT NULL").Scan(&liveTableExists); err != nil {
		rollback()
		log.Fatalf("check for existing live table: %v", err)
	}

	// A live table predating the source column holds only db-ip rows, so there
	// is nothing to preserve in that case.
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

	// bigint/text are deliberate: DB-IP defines GeoNames IDs as uint32 so
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

	src := newMMDBCopySource(reader)
	defer src.Close()

	copied, err := tx.CopyFrom(ctx, pgx.Identifier{loadTable}, copyColumns, src)
	if err != nil {
		rollback()
		log.Fatalf("COPY aborted: %v", err)
	}
	if copied == 0 {
		rollback()
		log.Fatal("MMDB produced zero networks; refusing installation")
	}
	log.Printf("COPY completed: %d networks", copied)

	// Country filter. Rows with a NULL country_iso_code are treated as not in
	// the kept set and removed, since a row of unknown country cannot be
	// asserted to be in it. Edit keepCountriesDefault (or pass -countries) to
	// add countries; -countries none disables the filter.
	kept := copied
	if len(keep) > 0 {
		res, err := tx.Exec(ctx,
			"DELETE FROM ip2city_dbiplite_tbl_load "+
				"WHERE coalesce(country_iso_code, '') <> ALL($1::text[])", keep)
		if err != nil {
			rollback()
			log.Fatalf("country filter failed: %v", err)
		}
		kept = copied - res.RowsAffected()
		log.Printf("country filter %v: deleted %d rows, %d remain",
			keep, res.RowsAffected(), kept)
		if kept == 0 {
			rollback()
			log.Fatalf("country filter %v removed every row; refusing installation", keep)
		}
	} else {
		log.Printf("country filter disabled; keeping all %d rows", copied)
	}

	// Plausibility guard, comparing like with like: the previous db-ip count
	// was already country-filtered by the prior run, so compare against the
	// post-filter count here.
	//
	// IMPORTANT on the FIRST run that introduces a country filter: the existing
	// live table holds every country, so the post-filter count is legitimately
	// far below it and this guard will refuse the install. That is the guard
	// working correctly, not a bug. Raise the threshold for that one run, for
	// example -max-drop-fraction 0.95, then leave it at the default afterwards.
	if liveTableExists && oldDbip > 0 {
		dropped := float64(oldDbip-kept) / float64(oldDbip)
		if dropped > *maxDropFraction {
			rollback()
			log.Fatalf("refusing install: new db-ip count %d is %.1f%% below previous db-ip count %d (threshold %.0f%%). "+
				"If this is the first run with a country filter, re-run with -max-drop-fraction 0.95",
				kept, dropped*100, oldDbip, *maxDropFraction*100)
		}
	}

	// Derive the four computed columns. The city expression strips a trailing
	// parenthesised qualifier, matching the UPDATE previously run by hand.
	//
	// Scoped to source = 'dbip' deliberately. RouteViews-derived rows have no
	// db-ip city_names to derive from, and their city/state are filled from
	// ip-api instead. An unscoped UPDATE would overwrite that ip-api result
	// with NULL. The scope is redundant at this point in the sequence (the
	// RouteViews rows are carried forward below, after this runs) but it makes
	// the invariant explicit and keeps the statement safe if reordered.
	log.Println("computing start_ip, end_ip, city, state")
	deriveSQL := "UPDATE ip2city_dbiplite_tbl_load SET " +
		"start_ip = host(network)::inet, " +
		"end_ip = host(broadcast(network))::inet, " +
		"city = regexp_replace(city_names ->> 'en', ' [(].*', ''), " +
		"state = subdivisions_names -> 0 -> 'names' ->> 'en' " +
		"WHERE source = 'dbip'"
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

	// Carry RouteViews rows forward. The GiST index above already exists, so
	// the containment test in the conditional case is indexed.
	var preserved int64
	if liveTableExists && hasSourceColumn && oldRouteviews > 0 && *preserve != "none" {
		cond := ""
		if *preserve == "conditional" {
			// Keep a child only if the NEW db-ip edition still has a strictly
			// wider row covering it, meaning db-ip has not yet caught up to
			// the split RouteViews already reported. Once db-ip provides equal
			// or finer granularity, defer to db-ip.
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
		preserved = res.RowsAffected()
		log.Printf("preserved %d of %d routeviews rows (-preserve-routeviews=%s)",
			preserved, oldRouteviews, *preserve)
	} else if oldRouteviews > 0 {
		log.Printf("discarding %d routeviews rows (-preserve-routeviews=%s)",
			oldRouteviews, *preserve)
	}

	// Convert to LOGGED before it becomes the live table. Building UNLOGGED
	// and converting once is faster than logging every COPY row, but skipping
	// this leaves the live table permanently UNLOGGED: invisible on streaming
	// replicas and truncated on any unclean restart.
	if _, err := tx.Exec(ctx, "ALTER TABLE ip2city_dbiplite_tbl_load SET LOGGED"); err != nil {
		rollback()
		log.Fatalf("SET LOGGED failed: %v", err)
	}

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
		if _, err := tx.Exec(ctx, "ALTER INDEX "+r[0]+" RENAME TO "+r[1]); err != nil {
			rollback()
			log.Fatalf("rename index %s failed: %v", r[0], err)
		}
	}

	if _, err := tx.Exec(ctx, "ANALYZE ip2city_dbiplite_tbl"); err != nil {
		rollback()
		log.Fatalf("ANALYZE failed: %v", err)
	}

	countriesLabel := "all"
	if len(keep) > 0 {
		countriesLabel = joinComma(keep)
	}
	if _, err := tx.Exec(ctx,
		"INSERT INTO dbip_import_state (edition, source_url, dbip_rows, routeviews_rows_preserved, countries_kept) "+
			"VALUES ($1, $2, $3, $4, $5) "+
			"ON CONFLICT (edition) DO UPDATE SET source_url = excluded.source_url, "+
			"imported_at = now(), dbip_rows = excluded.dbip_rows, "+
			"routeviews_rows_preserved = excluded.routeviews_rows_preserved, "+
			"countries_kept = excluded.countries_kept",
		edition, sourceURL, kept, preserved, countriesLabel); err != nil {
		rollback()
		log.Fatalf("recording import state: %v", err)
	}

	if err := tx.Commit(ctx); err != nil {
		log.Fatalf("commit failed: %v", err)
	}

	fmt.Println()
	fmt.Println("=== import complete ===")
	fmt.Println(fmt.Sprintf("edition:            %s", edition))
	fmt.Println(fmt.Sprintf("countries kept:     %s", countriesLabel))
	fmt.Println(fmt.Sprintf("db-ip rows:         %d (was %d)", kept, oldDbip))
	fmt.Println(fmt.Sprintf("routeviews rows:    %d (was %d)", preserved, oldRouteviews))
	fmt.Println(fmt.Sprintf("total rows:         %d", kept+preserved))
	fmt.Println("NOTE: dbip_split_candidates is now stale; re-run check_range_splits.")
}

func ensureStateTable(ctx context.Context, conn *pgx.Conn) error {
	ddl := "CREATE TABLE IF NOT EXISTS dbip_import_state (" +
		"edition text PRIMARY KEY, " +
		"source_url text, " +
		"imported_at timestamptz NOT NULL DEFAULT now(), " +
		"dbip_rows bigint, " +
		"routeviews_rows_preserved bigint, " +
		"countries_kept text)"
	_, err := conn.Exec(ctx, ddl)
	return err
}

func alreadyImported(ctx context.Context, conn *pgx.Conn, edition string) (bool, error) {
	var exists bool
	err := conn.QueryRow(ctx,
		"SELECT EXISTS (SELECT 1 FROM dbip_import_state WHERE edition = $1)",
		edition).Scan(&exists)
	return exists, err
}

func splitAndTrim(s string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ',' {
			field := trimSpace(s[start:i])
			if field != "" {
				out = append(out, field)
			}
			start = i + 1
		}
	}
	return out
}

func trimSpace(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == 9) {
		i++
	}
	j := len(s)
	for j > i && (s[j-1] == ' ' || s[j-1] == 9) {
		j--
	}
	return s[i:j]
}

func joinComma(v []string) string {
	out := ""
	for i, s := range v {
		if i > 0 {
			out += ","
		}
		out += s
	}
	return out
}
