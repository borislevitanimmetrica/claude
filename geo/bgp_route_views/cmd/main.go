// Command bgp_route_views populates the bgp_route_views table from University
// of Oregon RouteViews MRT data (http://archive.routeviews.org).
//
// Data source (confirmed against the live archive):
//   base:    http://archive.routeviews.org/<collector>/bgpdata/
//   RIBs:    <base>/<YYYY.MM>/RIBS/rib.<YYYYMMDD>.<HHMM>.bz2      (every ~2h)
//   UPDATES: <base>/<YYYY.MM>/UPDATES/updates.<YYYYMMDD>.<HHMM>.bz2 (every 15m)
// File names are UTC. RIBs are MRT TABLE_DUMP_V2; UPDATES are MRT BGP4MP_ET
// (extended-timestamp) which we normalize to BGP4MP before decoding.
//
// Modes (runtime option -mode):
//   full    - download the latest full RIB to a temp file, TRUNCATE the table,
//             and COPY it in. Deduped by default to one row per prefix (~1M
//             rows for route-views2); -per-peer stores one row per (prefix,
//             peer) instead (tens of millions). -peer restricts to one peer.
//   updates - download only the UPDATES files newer than the last processed
//             file (tracked in bgp_rv_ingest_state, or -since) and apply them.
//
// Row: cidr_block, start_address, end_address, origin_asn (last ASN in
// AS_PATH), peer_ip, as_path, updated_at (source file's UTC timestamp). In the
// default deduped mode peer_ip/as_path are NULL, since geography does not
// depend on routing.
package main

import (
	"compress/bzip2"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/osrg/gobgp/v3/pkg/packet/bgp"
	"github.com/osrg/gobgp/v3/pkg/packet/mrt"
)

const fileTSLayout = "20060102.1504" // e.g. 20260831.1045 (UTC)

func main() {
	mode := flag.String("mode", "updates", "which data to ingest: 'full' (latest RIB, full reload) or 'updates' (incremental changes only)")
	collector := flag.String("collector", "route-views2", "RouteViews collector name (archive path component)")
	archiveBase := flag.String("archive-url", "http://archive.routeviews.org/", "RouteViews archive base URL")
	sinceFlag := flag.String("since", "", "updates mode: only files strictly after this UTC time (format 20060102.1504 or RFC3339); default = last processed file from state")
	peerFilter := flag.String("peer", "", "only ingest entries/updates from this peer IP (empty = all peers)")
	perPeer := flag.Bool("per-peer", false, "store one row per (prefix, peer) instead of one row per prefix; default is deduped (one row per prefix, peer_ip/as_path NULL), since geography does not depend on routing")
	dryRun := flag.Bool("dry-run", false, "parse and report without touching the database (DATABASE_URL not required)")
	limit := flag.Int("limit", 0, "cap the number of rows/actions processed (0 = no cap); useful with -dry-run")
	headerTimeout := flag.Duration("http-timeout", 2*time.Minute, "timeout for connection + response headers (NOT the whole transfer, which is never timed out)")
	flag.Parse()

	if *mode != "full" && *mode != "updates" {
		log.Fatalf("-mode must be 'full' or 'updates', got %q", *mode)
	}
	dedupe := !*perPeer

	// Timeout: 0 means no cap on total transfer time — the full RIB is streamed
	// through a long-running COPY (or a large download), so a whole-request
	// deadline would kill it mid-stream (the original 10m bug). We instead bound
	// only connection setup and time-to-first-byte via the transport.
	client := &http.Client{
		Timeout: 0,
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			DialContext:           (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout:   30 * time.Second,
			ResponseHeaderTimeout: *headerTimeout,
			IdleConnTimeout:       90 * time.Second,
		},
	}
	bgpdata := strings.TrimRight(*archiveBase, "/") + "/" + *collector + "/bgpdata/"

	var conn *pgx.Conn
	ctx := context.Background()
	if !*dryRun {
		databaseURL := os.Getenv("DATABASE_URL")
		if databaseURL == "" {
			log.Fatal("DATABASE_URL is not set (or pass -dry-run)")
		}
		var err error
		conn, err = pgx.Connect(ctx, databaseURL)
		if err != nil {
			log.Fatalf("PostgreSQL connection failed: %v", err)
		}
		defer conn.Close(context.Background())
		if err := ensureStateTable(ctx, conn); err != nil {
			log.Fatalf("ensuring state table: %v", err)
		}
	}

	switch *mode {
	case "full":
		runFull(ctx, conn, client, bgpdata, *collector, *peerFilter, dedupe, *dryRun, *limit)
	case "updates":
		runUpdates(ctx, conn, client, bgpdata, *collector, *sinceFlag, *peerFilter, dedupe, *dryRun, *limit)
	}
}

// ---------------------------------------------------------------------------
// full RIB load
// ---------------------------------------------------------------------------

func runFull(ctx context.Context, conn *pgx.Conn, client *http.Client, bgpdata, collector, peerFilter string, dedupe, dryRun bool, limit int) {
	ref, err := latestRIB(client, bgpdata)
	if err != nil {
		log.Fatalf("locating latest RIB: %v", err)
	}
	log.Printf("full load: RIB %s (%s) dedupe=%v", ref.url, ref.ts.Format(time.RFC3339), dedupe)

	if dryRun {
		body, closer, err := openMRT(client, ref.url)
		if err != nil {
			log.Fatalf("open RIB: %v", err)
		}
		defer closer()
		it := newRIBIterator(body, ref.ts, peerFilter, dedupe, limit)
		n := 0
		for it.Next() {
			if n < 10 {
				v, _ := it.Values()
				log.Printf("  row: cidr=%v start=%v end=%v origin=%v peer=%v path=%q", v[0], v[1], v[2], v[3], v[4], v[5])
			}
			n++
		}
		if it.Err() != nil {
			log.Fatalf("parse RIB: %v", it.Err())
		}
		log.Printf("dry-run full: %d rows would be loaded (dedupe=%v peer filter %q)", n, dedupe, peerFilter)
		return
	}

	// Download the RIB to a temp file first, then COPY from local disk. This
	// decouples the (slow) database ingest from the network. The download
	// itself is NOT time-limited; only connection setup / response headers are
	// bounded (via the transport), never the transfer duration.
	log.Printf("downloading RIB to temp file (no transfer timeout)...")
	path, cleanup, err := downloadToTemp(ctx, client, ref.url)
	if err != nil {
		log.Fatalf("download RIB: %v", err)
	}
	defer cleanup()
	f, err := os.Open(path)
	if err != nil {
		log.Fatalf("open temp RIB: %v", err)
	}
	defer f.Close()
	log.Printf("download complete; parsing + loading...")

	tx, err := conn.Begin(ctx)
	if err != nil {
		log.Fatalf("begin tx: %v", err)
	}
	defer tx.Rollback(context.Background())

	if _, err := tx.Exec(ctx, `TRUNCATE bgp_route_views`); err != nil {
		log.Fatalf("truncate: %v", err)
	}

	it := newRIBIterator(bzip2.NewReader(f), ref.ts, peerFilter, dedupe, limit)
	cols := []string{"cidr_block", "start_address", "end_address", "origin_asn", "peer_ip", "as_path", "updated_at"}
	n, err := tx.CopyFrom(ctx, pgx.Identifier{"bgp_route_views"}, cols, it)
	if err != nil {
		log.Fatalf("COPY: %v", err)
	}
	if it.Err() != nil {
		log.Fatalf("parse RIB: %v", it.Err())
	}

	// Index that makes updates-mode (prefix, peer) deletes/replaces feasible.
	if _, err := tx.Exec(ctx, `CREATE INDEX IF NOT EXISTS bgp_route_views_cidr_peer_idx ON bgp_route_views (cidr_block, peer_ip)`); err != nil {
		log.Fatalf("create index: %v", err)
	}
	if err := setState(ctx, tx, collector, ref.ts); err != nil {
		log.Fatalf("set state: %v", err)
	}
	if err := tx.Commit(ctx); err != nil {
		log.Fatalf("commit: %v", err)
	}
	log.Printf("full load complete: %d rows, state=%s", n, ref.ts.Format(time.RFC3339))
}

// ---------------------------------------------------------------------------
// incremental updates
// ---------------------------------------------------------------------------

func runUpdates(ctx context.Context, conn *pgx.Conn, client *http.Client, bgpdata, collector, sinceFlag, peerFilter string, dedupe, dryRun bool, limit int) {
	var since time.Time
	switch {
	case sinceFlag != "":
		s, err := parseSince(sinceFlag)
		if err != nil {
			log.Fatalf("bad -since: %v", err)
		}
		since = s
	case dryRun:
		// Default dry-run window: the last hour, so it does something useful
		// without DB state.
		since = time.Now().UTC().Add(-1 * time.Hour)
		log.Printf("dry-run updates: no -since given; defaulting to last hour (since %s)", since.Format(time.RFC3339))
	default:
		s, ok, err := getState(ctx, conn, collector)
		if err != nil {
			log.Fatalf("reading state: %v", err)
		}
		if !ok {
			log.Fatal("no ingest state for this collector: run -mode full first, or pass -since")
		}
		since = s
	}

	refs, err := updatesSince(client, bgpdata, since)
	if err != nil {
		log.Fatalf("listing updates: %v", err)
	}
	if len(refs) == 0 {
		log.Printf("no new updates files after %s", since.Format(time.RFC3339))
		return
	}
	log.Printf("updates: %d files after %s (%s .. %s)", len(refs), since.Format(time.RFC3339),
		refs[0].ts.Format("2006-01-02 15:04"), refs[len(refs)-1].ts.Format("2006-01-02 15:04"))

	totalAnn, totalWd := 0, 0
	for _, ref := range refs {
		body, closer, err := openMRT(client, ref.url)
		if err != nil {
			log.Fatalf("open %s: %v", ref.url, err)
		}
		ann, wd, err := applyUpdatesFile(ctx, conn, body, ref.ts, collector, peerFilter, dedupe, dryRun, limit)
		closer()
		if err != nil {
			log.Fatalf("applying %s: %v", ref.url, err)
		}
		totalAnn += ann
		totalWd += wd
		log.Printf("  %s: announced=%d withdrawn=%d", ref.ts.Format("2006-01-02 15:04"), ann, wd)
		if limit > 0 && totalAnn+totalWd >= limit {
			break
		}
	}
	log.Printf("updates complete: announced=%d withdrawn=%d over %d files", totalAnn, totalWd, len(refs))
}

// applyUpdatesFile decodes one UPDATES file and applies it.
//
// Per-peer mode: announcements replace the (prefix, peer) route (DELETE then
// INSERT); withdrawals DELETE that (prefix, peer) row.
//
// Deduped mode (default): the table holds one row per prefix, so announcements
// upsert the single prefix row (DELETE by cidr_block, INSERT with peer_ip/
// as_path NULL). Withdrawals are NOT applied: a withdrawal from one peer does
// not mean the prefix is globally gone, and without per-peer state we cannot
// know when the last peer withdraws — and since a prefix's geography is stable,
// a lingering row is harmless. Withdrawals are still counted for reporting.
//
// All changes for one file happen in a single transaction; state advances to
// the file's timestamp on commit. In dry-run nothing is written.
func applyUpdatesFile(ctx context.Context, conn *pgx.Conn, r io.Reader, fileTS time.Time, collector, peerFilter string, dedupe, dryRun bool, limit int) (int, int, error) {
	var tx pgx.Tx
	var err error
	if !dryRun {
		tx, err = conn.Begin(ctx)
		if err != nil {
			return 0, 0, err
		}
		defer tx.Rollback(context.Background())
	}

	annCount, wdCount := 0, 0
	err = eachMRT(r, func(h *mrt.MRTHeader, msg *mrt.MRTMessage) error {
		bm, ok := msg.Body.(*mrt.BGP4MPMessage)
		if !ok || bm.BGPMessage == nil {
			return nil
		}
		upd, ok := bm.BGPMessage.Body.(*bgp.BGPUpdate)
		if !ok {
			return nil
		}
		peer := bm.PeerIpAddress.String()
		if peerFilter != "" && peer != peerFilter {
			return nil
		}

		announced := nlriPrefixes(upd.NLRI)
		withdrawn := nlriPrefixes(upd.WithdrawnRoutes)
		for _, attr := range upd.PathAttributes {
			switch a := attr.(type) {
			case *bgp.PathAttributeMpReachNLRI:
				announced = append(announced, nlriPrefixes(a.Value)...)
			case *bgp.PathAttributeMpUnreachNLRI:
				withdrawn = append(withdrawn, nlriPrefixes(a.Value)...)
			}
		}

		asPath, origin := originAndPath(upd.PathAttributes)

		for _, cidr := range withdrawn {
			// In deduped mode we cannot safely delete on a single-peer
			// withdrawal (the prefix may still be routed via other peers), so
			// we only count it. In per-peer mode we delete that (prefix,peer).
			if !dryRun && !dedupe {
				if _, err := tx.Exec(ctx, `DELETE FROM bgp_route_views WHERE cidr_block=$1 AND peer_ip=$2`, cidr, peer); err != nil {
					return err
				}
			}
			wdCount++
		}
		for _, cidr := range announced {
			start, end, err := prefixRange(cidr)
			if err != nil {
				continue
			}
			if !dryRun {
				if dedupe {
					if _, err := tx.Exec(ctx, `DELETE FROM bgp_route_views WHERE cidr_block=$1`, cidr); err != nil {
						return err
					}
					if _, err := tx.Exec(ctx, `INSERT INTO bgp_route_views
						(cidr_block, start_address, end_address, origin_asn, peer_ip, as_path, updated_at)
						VALUES ($1,$2,$3,$4,NULL,NULL,$5)`,
						cidr, start, end, nullASN(origin), fileTS); err != nil {
						return err
					}
				} else {
					if _, err := tx.Exec(ctx, `DELETE FROM bgp_route_views WHERE cidr_block=$1 AND peer_ip=$2`, cidr, peer); err != nil {
						return err
					}
					if _, err := tx.Exec(ctx, `INSERT INTO bgp_route_views
						(cidr_block, start_address, end_address, origin_asn, peer_ip, as_path, updated_at)
						VALUES ($1,$2,$3,$4,$5,$6,$7)`,
						cidr, start, end, nullASN(origin), peer, nullStr(asPath), fileTS); err != nil {
						return err
					}
				}
			}
			annCount++
		}
		if limit > 0 && annCount+wdCount >= limit {
			return errStopEarly
		}
		return nil
	})
	if err != nil && err != errStopEarly {
		return annCount, wdCount, err
	}

	if !dryRun {
		if err := setState(ctx, tx, collector, fileTS); err != nil {
			return annCount, wdCount, err
		}
		if err := tx.Commit(ctx); err != nil {
			return annCount, wdCount, err
		}
	}
	return annCount, wdCount, nil
}

var errStopEarly = fmt.Errorf("stop early (limit reached)")

// ---------------------------------------------------------------------------
// MRT decoding
// ---------------------------------------------------------------------------

// eachMRT reads MRT records from r and calls fn for each, normalizing the
// BGP4MP_ET / *_ET extended-timestamp records (which prepend a 4-byte
// microsecond field) down to their non-ET equivalent before parsing.
func eachMRT(r io.Reader, fn func(*mrt.MRTHeader, *mrt.MRTMessage) error) error {
	hdrBuf := make([]byte, 12)
	for {
		if _, err := io.ReadFull(r, hdrBuf); err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				return nil
			}
			return err
		}
		h := &mrt.MRTHeader{}
		if err := h.DecodeFromBytes(hdrBuf); err != nil {
			return err
		}
		body := make([]byte, h.Len)
		if _, err := io.ReadFull(r, body); err != nil {
			return err
		}
		if h.Type == mrt.BGP4MP_ET {
			if len(body) < 4 {
				continue
			}
			body = body[4:]
			h.Type = mrt.BGP4MP
			h.Len -= 4
		}
		msg, err := mrt.ParseMRTBody(h, body)
		if err != nil {
			// Skip record types this build can't decode rather than aborting.
			continue
		}
		if err := fn(h, msg); err != nil {
			return err
		}
	}
}

// originAndPath returns the space-joined AS_PATH and the origin ASN (the last
// ASN in the path). Handles both 4-byte (As4PathParam) and 2-byte (AsPathParam)
// encodings.
func originAndPath(attrs []bgp.PathAttributeInterface) (string, uint32) {
	var asns []uint32
	for _, attr := range attrs {
		if a, ok := attr.(*bgp.PathAttributeAsPath); ok {
			for _, p := range a.Value {
				switch seg := p.(type) {
				case *bgp.As4PathParam:
					asns = append(asns, seg.AS...)
				case *bgp.AsPathParam:
					for _, x := range seg.AS {
						asns = append(asns, uint32(x))
					}
				}
			}
		}
	}
	if len(asns) == 0 {
		return "", 0
	}
	parts := make([]string, len(asns))
	for i, a := range asns {
		parts[i] = fmt.Sprintf("%d", a)
	}
	return strings.Join(parts, " "), asns[len(asns)-1]
}

func nlriPrefixes[T interface{ String() string }](nlri []T) []string {
	out := make([]string, 0, len(nlri))
	for _, p := range nlri {
		out = append(out, p.String())
	}
	return out
}

// ---------------------------------------------------------------------------
// RIB -> rows, as a pgx.CopyFromSource (pull-based, streaming)
// ---------------------------------------------------------------------------

type ribIterator struct {
	r          io.Reader
	hdrBuf     []byte
	peers      []*mrt.Peer
	fileTS     time.Time
	peerFilter string
	dedupe     bool
	limit      int

	queue [][]any
	qi    int
	cur   []any
	count int
	err   error
	done  bool
}

func newRIBIterator(r io.Reader, fileTS time.Time, peerFilter string, dedupe bool, limit int) *ribIterator {
	return &ribIterator{r: r, hdrBuf: make([]byte, 12), fileTS: fileTS, peerFilter: peerFilter, dedupe: dedupe, limit: limit}
}

func (it *ribIterator) Next() bool {
	if it.done {
		return false
	}
	if it.limit > 0 && it.count >= it.limit {
		it.done = true
		return false
	}
	if it.qi < len(it.queue) {
		it.cur = it.queue[it.qi]
		it.qi++
		it.count++
		return true
	}
	// Refill from subsequent MRT records until we have rows or hit EOF.
	for {
		h := &mrt.MRTHeader{}
		if _, err := io.ReadFull(it.r, it.hdrBuf); err != nil {
			if err != io.EOF && err != io.ErrUnexpectedEOF {
				it.err = err
			}
			it.done = true
			return false
		}
		if err := h.DecodeFromBytes(it.hdrBuf); err != nil {
			it.err = err
			it.done = true
			return false
		}
		body := make([]byte, h.Len)
		if _, err := io.ReadFull(it.r, body); err != nil {
			it.err = err
			it.done = true
			return false
		}
		msg, err := mrt.ParseMRTBody(h, body)
		if err != nil {
			continue
		}
		switch b := msg.Body.(type) {
		case *mrt.PeerIndexTable:
			it.peers = b.Peers
		case *mrt.Rib:
			it.queue = it.buildRows(b)
			it.qi = 0
			if len(it.queue) > 0 {
				it.cur = it.queue[0]
				it.qi = 1
				it.count++
				return true
			}
		}
	}
}

func (it *ribIterator) buildRows(rib *mrt.Rib) [][]any {
	cidr := rib.Prefix.String()
	start, end, err := prefixRange(cidr)
	if err != nil {
		return nil
	}

	// Deduped (default): one row per prefix. A TABLE_DUMP_V2 record already IS
	// one prefix, so we emit a single row using a representative entry (the
	// first one, honoring the peer filter) for origin_asn, with peer_ip and
	// as_path NULL — geography does not depend on which peer observed the route.
	if it.dedupe {
		for _, e := range rib.Entries {
			if int(e.PeerIndex) >= len(it.peers) {
				continue
			}
			if it.peerFilter != "" && it.peers[e.PeerIndex].IpAddress.String() != it.peerFilter {
				continue
			}
			_, origin := originAndPath(e.PathAttributes)
			return [][]any{{cidr, start, end, nullASN(origin), nil, nil, it.fileTS}}
		}
		return nil
	}

	// Per-peer: one row per (prefix, peer).
	rows := make([][]any, 0, len(rib.Entries))
	for _, e := range rib.Entries {
		if int(e.PeerIndex) >= len(it.peers) {
			continue
		}
		peer := it.peers[e.PeerIndex].IpAddress.String()
		if it.peerFilter != "" && peer != it.peerFilter {
			continue
		}
		asPath, origin := originAndPath(e.PathAttributes)
		rows = append(rows, []any{cidr, start, end, nullASN(origin), peer, nullStr(asPath), it.fileTS})
	}
	return rows
}

func (it *ribIterator) Values() ([]any, error) { return it.cur, nil }
func (it *ribIterator) Err() error             { return it.err }

// ---------------------------------------------------------------------------
// archive discovery
// ---------------------------------------------------------------------------

type fileRef struct {
	url string
	ts  time.Time
}

func openMRT(client *http.Client, url string) (io.Reader, func(), error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, nil, fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}
	return bzip2.NewReader(resp.Body), func() { resp.Body.Close() }, nil
}

// downloadToTemp streams url to a temp .bz2 file and returns its path plus a
// cleanup func. The transfer is NOT time-limited (the client has Timeout:0 and
// no per-download deadline), so an arbitrarily long/slow download will run to
// completion. The returned file is local, so the subsequent (slow) COPY has no
// network dependency.
func downloadToTemp(ctx context.Context, client *http.Client, url string) (string, func(), error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", nil, fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}

	f, err := os.CreateTemp("", "routeviews-*.bz2")
	if err != nil {
		return "", nil, err
	}
	name := f.Name()
	cleanup := func() { os.Remove(name) }
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		cleanup()
		return "", nil, fmt.Errorf("downloading %s: %w", url, err)
	}
	if err := f.Close(); err != nil {
		cleanup()
		return "", nil, err
	}
	return name, cleanup, nil
}

var fileNameRE = regexp.MustCompile(`(rib|updates)\.(\d{8}\.\d{4})\.bz2`)

// listArchive fetches an autoindex directory and returns the matching files.
func listArchive(client *http.Client, dirURL, kind string) ([]fileRef, error) {
	resp, err := client.Get(dirURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: HTTP %d", dirURL, resp.StatusCode)
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []fileRef
	for _, m := range fileNameRE.FindAllStringSubmatch(string(data), -1) {
		if m[1] != kind || seen[m[0]] {
			continue
		}
		seen[m[0]] = true
		ts, err := time.Parse(fileTSLayout, m[2])
		if err != nil {
			continue
		}
		out = append(out, fileRef{url: strings.TrimRight(dirURL, "/") + "/" + m[0], ts: ts.UTC()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ts.Before(out[j].ts) })
	return out, nil
}

func monthDir(bgpdata string, t time.Time) string {
	return bgpdata + t.UTC().Format("2006.01") + "/"
}

// latestRIB finds the newest RIB, checking the current month and falling back
// to the previous month if the current one has none yet.
func latestRIB(client *http.Client, bgpdata string) (fileRef, error) {
	now := time.Now().UTC()
	for _, t := range []time.Time{now, now.AddDate(0, -1, 0)} {
		refs, err := listArchive(client, monthDir(bgpdata, t)+"RIBS/", "rib")
		if err != nil {
			return fileRef{}, err
		}
		if len(refs) > 0 {
			return refs[len(refs)-1], nil
		}
	}
	return fileRef{}, fmt.Errorf("no RIB files found in current or previous month under %s", bgpdata)
}

// updatesSince returns all UPDATES files strictly after `since`, across every
// month spanning [since, now], in ascending time order.
func updatesSince(client *http.Client, bgpdata string, since time.Time) ([]fileRef, error) {
	now := time.Now().UTC()
	var all []fileRef
	// Iterate month by month from `since` to `now` inclusive.
	m := time.Date(since.UTC().Year(), since.UTC().Month(), 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	for !m.After(end) {
		refs, err := listArchive(client, monthDir(bgpdata, m)+"UPDATES/", "updates")
		if err != nil {
			return nil, err
		}
		for _, r := range refs {
			if r.ts.After(since) {
				all = append(all, r)
			}
		}
		m = m.AddDate(0, 1, 0)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ts.Before(all[j].ts) })
	return all, nil
}

// ---------------------------------------------------------------------------
// state tracking
// ---------------------------------------------------------------------------

func ensureStateTable(ctx context.Context, conn *pgx.Conn) error {
	_, err := conn.Exec(ctx, `
CREATE TABLE IF NOT EXISTS bgp_rv_ingest_state (
    collector    text PRIMARY KEY,
    last_file_ts timestamptz NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now()
)`)
	return err
}

func setState(ctx context.Context, tx pgx.Tx, collector string, ts time.Time) error {
	_, err := tx.Exec(ctx, `
INSERT INTO bgp_rv_ingest_state (collector, last_file_ts, updated_at)
VALUES ($1, $2, now())
ON CONFLICT (collector) DO UPDATE SET last_file_ts = EXCLUDED.last_file_ts, updated_at = now()`,
		collector, ts)
	return err
}

func getState(ctx context.Context, conn *pgx.Conn, collector string) (time.Time, bool, error) {
	var ts time.Time
	err := conn.QueryRow(ctx, `SELECT last_file_ts FROM bgp_rv_ingest_state WHERE collector=$1`, collector).Scan(&ts)
	if err != nil {
		if err == pgx.ErrNoRows {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	return ts.UTC(), true, nil
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func parseSince(s string) (time.Time, error) {
	if t, err := time.Parse(fileTSLayout, s); err == nil {
		return t.UTC(), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("want %q or RFC3339, got %q", fileTSLayout, s)
}

// prefixRange returns the canonical CIDR's first and last host address as
// strings, for INET columns. Works for IPv4 and IPv6.
func prefixRange(cidr string) (string, string, error) {
	p, err := netip.ParsePrefix(cidr)
	if err != nil {
		return "", "", err
	}
	p = p.Masked()
	start := p.Addr()
	hostBits := start.BitLen() - p.Bits()
	startInt := new(big.Int).SetBytes(start.AsSlice())
	size := new(big.Int).Lsh(big.NewInt(1), uint(hostBits))
	endInt := new(big.Int).Add(startInt, new(big.Int).Sub(size, big.NewInt(1)))
	buf := make([]byte, len(start.AsSlice()))
	endInt.FillBytes(buf)
	end, ok := netip.AddrFromSlice(buf)
	if !ok {
		return "", "", fmt.Errorf("bad end address for %s", cidr)
	}
	return start.String(), end.String(), nil
}

func nullASN(a uint32) any {
	if a == 0 {
		return nil
	}
	return int64(a)
}

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}
