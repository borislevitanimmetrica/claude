// Command dma_api serves DMA address lookups over HTTP, plus a small GUI.
//
// A caller sends a numeric DMA code and receives every individual IPv4 address
// in the ranges belonging to that DMA. Codes rather than names are used
// deliberately: DMA names vary in punctuation and suffix between sources, and a
// name mismatch silently returns nothing.
//
// THE QUERY
//
// dma2city_tbl is joined to ip2city_dbiplite_probe_tbl on city and state_code.
// state_code is the two letter form, which avoids the full-name variance that
// affects the state column. DISTINCT is required because dma2city_tbl has one row
// per (state_code, county, dma, city, city_type), so a single city appears several
// times and would otherwise multiply the ranges.
//
// SCALE, WHICH DOMINATES THE DESIGN
//
// Expanding ranges to individual addresses multiplies the payload by roughly 250.
// A measured example from this project: Indianapolis was 5654 ranges, which is
// 3444280 addresses, about 50MB as text. A large DMA is plausibly ten times that.
//
// Consequently:
//   - the address endpoint STREAMS, so neither the server nor the database holds
//     a full result in memory
//   - gzip is offered, and typically cuts the payload by about 80 percent
//   - a summary endpoint returns the counts cheaply, so a caller can find out
//     what it is asking for before asking for it
//   - the address count is checked BEFORE streaming starts, so an oversized
//     request fails cleanly with 413 rather than half way through a response
//   - a CIDR endpoint returns the same information 250 times smaller, for callers
//     that can accept prefixes
//
// Network and broadcast addresses are INCLUDED. In a range wider than /24 they
// are ordinary usable addresses, and the cost of a few never-assigned addresses
// is negligible.
//
// NOTE: contains no backslash escape sequences. Newlines are written as byte 10.
package main

import (
	"compress/gzip"
	"context"
	"embed"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const newline = byte(10)

//go:embed index.html
var uiFiles embed.FS

// dmaListSQL powers the GUI selector. dma_code is nullable, so rows without one
// are unreachable by this API and are excluded rather than shown as null.
const dmaListSQL = `
SELECT DISTINCT dma_code, dma
FROM dma2city_tbl
WHERE dma_code IS NOT NULL
ORDER BY dma`

// rangesSQL is the canonical join. Kept identical between the summary, the CIDR
// endpoint and the address endpoint so all three agree by construction.
// There is deliberately NO address family filter here. The table holds only IPv4
// today, so a filter would be redundant, and a redundant filter is worse than
// none: when IPv6 is switched on with PROBE_IPV4_ONLY=0 it would keep excluding
// IPv6 silently, to be discovered by its absence rather than by an error.
//
// Where a family distinction is genuinely unavoidable, which is address
// enumeration, it is enforced explicitly and loudly instead. See handleAddresses.
const rangesSQL = `
SELECT DISTINCT p.network
FROM ip2city_dbiplite_probe_tbl p
JOIN dma2city_tbl d
  ON d.city = p.city
 AND d.state_code = p.state_code
WHERE d.dma_code = $1
ORDER BY 1`

// summarySQL counts without materialising an address list. The address total is
// summed in numeric because a wide prefix overflows an int before the cast.
// Families are counted separately rather than filtered. addresses covers the IPv4
// ranges only, because an IPv6 prefix cannot be enumerated: a single /64 is
// 18446744073709551616 addresses. Reporting the two counts side by side means a
// caller can see that IPv6 space exists rather than having it quietly omitted.
const summarySQL = `
WITH m AS (
    SELECT DISTINCT p.network, p.ran_at
    FROM ip2city_dbiplite_probe_tbl p
    JOIN dma2city_tbl d
      ON d.city = p.city
     AND d.state_code = p.state_code
    WHERE d.dma_code = $1
)
SELECT count(*)::bigint                                          AS ranges,
       count(*) FILTER (WHERE family(network) = 4)::bigint        AS ipv4_ranges,
       count(*) FILTER (WHERE family(network) = 6)::bigint        AS ipv6_ranges,
       coalesce(sum(2::numeric ^ (32 - masklen(network)))
                FILTER (WHERE family(network) = 4), 0)::bigint    AS addresses,
       count(*) FILTER (WHERE ran_at IS NOT NULL)::bigint         AS measured_ranges,
       coalesce(min(masklen(network))
                FILTER (WHERE family(network) = 4), 0)::int       AS widest_masklen
FROM m`

const dmaNameSQL = `
SELECT DISTINCT dma
FROM dma2city_tbl
WHERE dma_code = $1
LIMIT 1`

// citiesSQL is a diagnostic. A DMA returning zero ranges is nearly always a city
// or state_code spelling mismatch rather than an absence of address space, and
// this shows which side of the join failed.
const citiesSQL = `
SELECT d.city,
       d.state_code,
       count(p.network)::bigint AS ranges
FROM dma2city_tbl d
LEFT JOIN ip2city_dbiplite_probe_tbl p
       ON d.city = p.city
      AND d.state_code = p.state_code
WHERE d.dma_code = $1
GROUP BY d.city, d.state_code
ORDER BY ranges DESC, d.city`

type summary struct {
	DMACode        int    `json:"dma_code"`
	DMA            string `json:"dma"`
	Ranges         int64  `json:"ranges"`
	IPv4Ranges     int64  `json:"ipv4_ranges"`
	IPv6Ranges     int64  `json:"ipv6_ranges"`
	Addresses      int64  `json:"addresses"`
	MeasuredRanges int64  `json:"measured_ranges"`
	WidestMasklen  int    `json:"widest_masklen"`
	TextBytesEst   int64  `json:"text_bytes_estimate"`
}

type server struct {
	pool    *pgxpool.Pool
	maxAddr int64
}

func main() {
	listen := flag.String("listen", "127.0.0.1:8080", "address to listen on")
	maxAddr := flag.Int64("max-addresses", 0, "refuse an address request larger than this; 0 means no limit")
	timeout := flag.Duration("query-timeout", 10*time.Minute, "per request database timeout")
	flag.Parse()

	// DATABASE_URL is optional, exactly as in the rest of the pipeline. When it is
	// empty pgx falls back to the libpq environment and defaults, so a service
	// account can use peer authentication with no credentials anywhere.
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		log.Print("DATABASE_URL not set; connecting via libpq environment and defaults")
	}

	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("parsing database configuration: %v", err)
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatalf("connecting to PostgreSQL: %v", err)
	}
	defer pool.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var who string
	if err := pool.QueryRow(ctx, "SELECT current_user || '@' || current_database()").Scan(&who); err != nil {
		log.Fatalf("database unreachable: %v", err)
	}
	log.Printf("database reachable as %s", who)

	s := &server{pool: pool, maxAddr: *maxAddr}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /api/v1/dmas", s.handleDMAs)
	mux.HandleFunc("GET /api/v1/dma/{code}/summary", s.handleSummary)
	mux.HandleFunc("GET /api/v1/dma/{code}/cities", s.handleCities)
	mux.HandleFunc("GET /api/v1/dma/{code}/cidrs", s.handleCIDRs)
	mux.HandleFunc("GET /api/v1/dma/{code}/addresses", s.handleAddresses)
	mux.Handle("GET /", http.FileServerFS(uiFiles))

	srv := &http.Server{
		Addr:    *listen,
		Handler: withLogging(withTimeout(mux, *timeout)),
		// No WriteTimeout: an address stream for a large DMA legitimately runs for
		// minutes, and a write deadline would truncate it mid-response. The client
		// can disconnect, and the request context cancellation stops the query.
		ReadHeaderTimeout: 15 * time.Second,
	}

	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		log.Print("shutting down")
		shutCtx, shutCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer shutCancel()
		if err := srv.Shutdown(shutCtx); err != nil {
			log.Printf("shutdown: %v", err)
		}
		close(idle)
	}()

	log.Printf("listening on %s", *listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("serving: %v", err)
	}
	<-idle
}

func withTimeout(next http.Handler, d time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s from %s in %s", r.Method, r.URL.RequestURI(), clientIP(r), time.Since(start).Truncate(time.Millisecond))
	})
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := s.pool.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unreachable: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) handleDMAs(w http.ResponseWriter, r *http.Request) {
	rows, err := s.pool.Query(r.Context(), dmaListSQL)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	type entry struct {
		DMACode int    `json:"dma_code"`
		DMA     string `json:"dma"`
	}
	out := make([]entry, 0, 256)
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.DMACode, &e.DMA); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out = append(out, e)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, rows.Err().Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) summaryFor(ctx context.Context, code int) (summary, error) {
	var sum summary
	sum.DMACode = code
	err := s.pool.QueryRow(ctx, summarySQL, code).
		Scan(&sum.Ranges, &sum.IPv4Ranges, &sum.IPv6Ranges,
			&sum.Addresses, &sum.MeasuredRanges, &sum.WidestMasklen)
	if err != nil {
		return sum, err
	}
	// Mean textual address length is a little over 14 bytes including the newline,
	// which is close enough to size a download or a disk.
	sum.TextBytesEst = sum.Addresses * 15
	if err := s.pool.QueryRow(ctx, dmaNameSQL, code).Scan(&sum.DMA); err != nil {
		// A code with no row in dma2city_tbl is a client error, not a failure, and
		// the zero counts already convey it.
		sum.DMA = ""
	}
	return sum, nil
}

func (s *server) handleSummary(w http.ResponseWriter, r *http.Request) {
	code, ok := dmaCode(w, r)
	if !ok {
		return
	}
	sum, err := s.summaryFor(r.Context(), code)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, sum)
}

func (s *server) handleCities(w http.ResponseWriter, r *http.Request) {
	code, ok := dmaCode(w, r)
	if !ok {
		return
	}
	rows, err := s.pool.Query(r.Context(), citiesSQL, code)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	type entry struct {
		City      string `json:"city"`
		StateCode string `json:"state_code"`
		Ranges    int64  `json:"ranges"`
	}
	out := make([]entry, 0, 128)
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.City, &e.StateCode, &e.Ranges); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out = append(out, e)
	}
	if rows.Err() != nil {
		writeError(w, http.StatusInternalServerError, rows.Err().Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) handleCIDRs(w http.ResponseWriter, r *http.Request) {
	code, ok := dmaCode(w, r)
	if !ok {
		return
	}
	sum, err := s.summaryFor(r.Context(), code)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// The CIDR endpoint is family agnostic: a prefix is a prefix, so IPv6 needs no
	// special handling and is returned alongside IPv4.
	s.streamRanges(w, r, code, sum, false, false)
}

func (s *server) handleAddresses(w http.ResponseWriter, r *http.Request) {
	code, ok := dmaCode(w, r)
	if !ok {
		return
	}
	sum, err := s.summaryFor(r.Context(), code)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// The ceiling is enforced BEFORE any bytes are written, so an oversized
	// request produces a clean 413 that names the size, rather than a response
	// that is cut off part way through and looks like a network fault.
	limit := s.maxAddr
	if v := r.URL.Query().Get("max"); v != "" {
		parsed, err := strconv.ParseInt(v, 10, 64)
		if err != nil || parsed < 0 {
			writeError(w, http.StatusBadRequest, "max must be a non negative integer")
			return
		}
		if limit == 0 || parsed < limit {
			limit = parsed
		}
	}
	if limit > 0 && sum.Addresses > limit {
		writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf(
			"DMA %d expands to %d addresses, above the limit of %d. Use the cidrs endpoint, or raise max.",
			code, sum.Addresses, limit))
		return
	}

	// IPv6 cannot be enumerated, so if this DMA contains any IPv6 range the request
	// is refused by default and says why. Skipping those ranges quietly would hand
	// back an answer that looks complete and is not, which is exactly how a
	// forgotten family filter causes damage. Skipping is available, but only when
	// the caller asks for it, and it is then reported in a response header.
	skipIPv6 := r.URL.Query().Get("skip_ipv6") == "1"
	if sum.IPv6Ranges > 0 && !skipIPv6 {
		writeError(w, http.StatusConflict, fmt.Sprintf(
			"DMA %d contains %d IPv6 ranges alongside %d IPv4 ranges. IPv6 prefixes have no finite address list, so this endpoint cannot return a complete answer. Use the cidrs endpoint for all families, or add skip_ipv6=1 to enumerate the IPv4 ranges only and accept an incomplete result.",
			code, sum.IPv6Ranges, sum.IPv4Ranges))
		return
	}
	s.streamRanges(w, r, code, sum, true, skipIPv6)
}

// streamRanges writes either the prefixes or every address in them, straight from
// the cursor to the socket.
func (s *server) streamRanges(w http.ResponseWriter, r *http.Request, code int, sum summary, expand, skipIPv6 bool) {
	rows, err := s.pool.Query(r.Context(), rangesSQL, code)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-DMA-Code", strconv.Itoa(code))
	w.Header().Set("X-Range-Count", strconv.FormatInt(sum.Ranges, 10))
	w.Header().Set("X-Address-Count", strconv.FormatInt(sum.Addresses, 10))
	w.Header().Set("X-Measured-Ranges", strconv.FormatInt(sum.MeasuredRanges, 10))
	w.Header().Set("X-IPv4-Ranges", strconv.FormatInt(sum.IPv4Ranges, 10))
	w.Header().Set("X-IPv6-Ranges", strconv.FormatInt(sum.IPv6Ranges, 10))
	if expand && skipIPv6 && sum.IPv6Ranges > 0 {
		// The result is knowingly incomplete, so it says so in a header rather than
		// looking like a full answer.
		w.Header().Set("X-Incomplete", fmt.Sprintf("%d IPv6 ranges omitted at caller request", sum.IPv6Ranges))
	}

	kind := "cidrs"
	if expand {
		kind = "addresses"
	}
	name := fmt.Sprintf("dma_%d_%s.txt", code, kind)

	var out io.Writer = w
	var gz *gzip.Writer
	if wantsGzip(r) {
		w.Header().Set("Content-Encoding", "gzip")
		name = name + ".gz"
		gz = gzip.NewWriter(w)
		out = gz
	}
	w.Header().Set("Content-Disposition", "attachment; filename="+name)
	w.WriteHeader(http.StatusOK)

	buf := newFlushWriter(out, w)
	var written int64
	var skipped int64

	for rows.Next() {
		var p netip.Prefix
		if err := rows.Scan(&p); err != nil {
			log.Printf("dma %d: scanning prefix after %d written: %v", code, written, err)
			break
		}
		if expand {
			if skipIPv6 && !p.Addr().Is4() {
				skipped++
				continue
			}
			n, err := writeAddresses(buf, p)
			if err != nil {
				log.Printf("dma %d: writing addresses: %v", code, err)
				break
			}
			written += n
			continue
		}
		if _, err := buf.WriteString(p.String()); err != nil {
			break
		}
		if err := buf.WriteByte(newline); err != nil {
			break
		}
		written++
	}
	if rows.Err() != nil {
		// The response is already committed, so this cannot become an HTTP error.
		// Logging it is the only honest option, and the client sees a short read.
		log.Printf("dma %d: query ended early after %d written: %v", code, written, rows.Err())
	}
	if err := buf.Flush(); err != nil {
		log.Printf("dma %d: final flush: %v", code, err)
	}
	if gz != nil {
		if err := gz.Close(); err != nil {
			log.Printf("dma %d: closing gzip: %v", code, err)
		}
	}
	if skipped > 0 {
		log.Printf("dma %d: streamed %d %s, omitting %d IPv6 ranges at caller request", code, written, kind, skipped)
		return
	}
	log.Printf("dma %d: streamed %d %s", code, written, kind)
}

// writeAddresses enumerates every address in p, network and broadcast included.
// In a prefix wider than /24 both are ordinary usable addresses, and a handful of
// never-assigned addresses costs nothing.
//
// Addresses are formatted by hand into a small stack buffer rather than through
// netip.Addr.String, which allocates. At tens of millions of addresses per
// response that difference is the whole cost of the endpoint.
func writeAddresses(w *flushWriter, p netip.Prefix) (int64, error) {
	p = p.Masked()
	// Returning zero here would silently omit the prefix, which is the same trap as
	// a redundant family filter in the SQL. An IPv6 prefix reaching this function
	// is a caller or routing error, so it is reported rather than skipped. The
	// endpoint decides the policy; this function refuses to guess.
	if !p.Addr().Is4() {
		return 0, fmt.Errorf("cannot enumerate %s: an IPv6 prefix has no finite address list, a single /64 being 18446744073709551616 addresses", p)
	}
	first := p.Addr().As4()
	base := binary.BigEndian.Uint32(first[:])
	count := int64(1) << uint(32-p.Bits())

	var quad [4]byte
	var text [16]byte
	for i := int64(0); i < count; i++ {
		binary.BigEndian.PutUint32(quad[:], base+uint32(i))
		pos := 0
		for oct := 0; oct < 4; oct++ {
			if oct > 0 {
				text[pos] = '.'
				pos++
			}
			pos += formatOctet(text[pos:], quad[oct])
		}
		text[pos] = newline
		pos++
		if _, err := w.Write(text[:pos]); err != nil {
			return i, err
		}
	}
	return count, nil
}

func formatOctet(dst []byte, v byte) int {
	switch {
	case v >= 100:
		dst[0] = '0' + v/100
		dst[1] = '0' + (v/10)%10
		dst[2] = '0' + v%10
		return 3
	case v >= 10:
		dst[0] = '0' + v/10
		dst[1] = '0' + v%10
		return 2
	default:
		dst[0] = '0' + v
		return 1
	}
}

func dmaCode(w http.ResponseWriter, r *http.Request) (int, bool) {
	raw := r.PathValue("code")
	code, err := strconv.Atoi(raw)
	if err != nil {
		writeError(w, http.StatusBadRequest, "dma code must be an integer, got "+raw)
		return 0, false
	}
	return code, true
}

func wantsGzip(r *http.Request) bool {
	if r.URL.Query().Get("gzip") == "1" {
		return true
	}
	if r.URL.Query().Get("gzip") == "0" {
		return false
	}
	for _, v := range r.Header.Values("Accept-Encoding") {
		if containsToken(v, "gzip") {
			return true
		}
	}
	return false
}

func containsToken(header, token string) bool {
	for i := 0; i+len(token) <= len(header); i++ {
		if header[i:i+len(token)] == token {
			return true
		}
	}
	return false
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(body); err != nil {
		log.Printf("encoding response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
