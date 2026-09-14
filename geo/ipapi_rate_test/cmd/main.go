// Command ipapi_rate_test characterises the ip-api.com free-tier rate limit from
// evidence instead of from assumption.
//
// # WHY THIS IS NEEDED
//
// Two contradictory observations exist. ip-api documents 45 requests per minute for
// the free tier, and this project has seen HTTP 429 when two of its own tools
// probed concurrently. Against that, the same limit was reportedly exceeded on
// another project with no errors at all. Those cannot both describe the same
// enforcement, so the limit is unknown rather than known, and the arithmetic that
// depends on it is currently unfounded.
//
// # THE RISK, STATED BEFORE THE TOOL IS RUN
//
// This is the part that matters more than the measurement. Deliberately exceeding
// the limit risks the SOURCE IP being blocked, and ip-api's remedy for repeated
// violation is a temporary block that this project cannot lift on demand. The
// production probe cycle runs from that same IP. So a careless run of this tool
// does not merely fail: it can halt the pipeline for an interval outside our
// control, and no data is recovered in exchange.
//
// Three consequences follow, and they are built into the defaults:
//
//  1. The tool STOPS at the first 429 rather than pushing through the remaining
//     calls. Continuing past a refusal is what converts a measurement into a
//     violation. Overriding this needs -continue-past-429 said explicitly.
//
//  2. It reads the X-Rl and X-Ttl response headers, which state how many calls
//     remain in the current window and how long until it resets. Those headers are
//     the authoritative answer, and reading them costs nothing beyond the calls
//     already being made. Provoking a 429 is only needed if the headers turn out
//     to be absent.
//
//  3. It prefers ranges that have ALREADY been probed, so it never consumes the
//     unprobed backlog and never has a reason to write anything back.
//
// # BEFORE RUNNING IT, NOTE THE WINDOW PROBLEM
//
// probe_batch processes 2400 ranges an hour at 45 calls a minute, which occupies
// roughly 53 minutes of every hour. A 1000-call test needs about 22 minutes at that
// rate, so it CANNOT fit in the roughly 7 minutes an hour that remain. Run
// concurrently it will contend with the production cycle for the same budget, and
// the 429s observed would then be caused partly by this tool rather than
// characterising the limit cleanly.
//
// The clean ways to run it are, in order of preference: from a DIFFERENT source IP
// than the pipeline uses, so a block cannot touch production; or in a window where
// probe_batch is not running; or, least good, concurrently and knowingly, reading
// the results as a joint measurement of both tools together.
//
// This tool writes NOTHING to the database. It only reads a sample of addresses.
//
// Usage:
//
//	ipapi_rate_test -count 1000                  measure at the documented 45/min
//	ipapi_rate_test -count 1000 -rate 90         test whether 90/min is tolerated
//	ipapi_rate_test -count 60 -rate 600          short sharp probe of the ceiling
//	ipapi_rate_test -count 1000 -headers-only    one call, just report the headers
//
// NOTE: contains no backslash escape sequences.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type geoResult struct {
	Status  string `json:"status"`
	Message string `json:"message"`
	City    string `json:"city"`
	Query   string `json:"query"`
}

type callOutcome struct {
	seq        int
	at         time.Time
	httpStatus int
	xrl        int
	xttl       int
	haveXrl    bool
	haveXttl   bool
	apiStatus  string
	err        error
}

func main() {
	count := flag.Int("count", 1000, "how many addresses to probe, one per range")
	rate := flag.Int("rate", 45, "target calls per minute. The documented free-tier limit is 45")
	endpoint := flag.String("endpoint", "http://ip-api.com/json/", "ip-api endpoint prefix")
	timeout := flag.Duration("http-timeout", 20*time.Second, "per call timeout")
	continuePast := flag.Bool("continue-past-429", false,
		"keep calling after a 429. Off by default: continuing past a refusal is what turns a measurement into a violation, and the source IP this runs from is the one the production cycle needs")
	headersOnly := flag.Bool("headers-only", false,
		"make a single call and report the rate-limit headers. Costs one call and answers whether the headers exist at all")
	dumpEvery := flag.Int("dump-every", 45, "log the rate-limit headers every N calls")
	flag.Parse()

	if *count < 1 {
		log.Fatal("-count must be at least 1")
	}
	if *rate < 1 {
		log.Fatal("-rate must be at least 1")
	}

	client := &http.Client{Timeout: *timeout}

	if *headersOnly {
		// A single call against a fixed, uncontroversial address. This exists so the
		// header question can be settled for the price of one call, before spending a
		// thousand.
		out := call(client, *endpoint, "8.8.8.8", 1)
		reportHeaders(out)
		return
	}

	addrs, err := sampleAddresses(*count)
	if err != nil {
		log.Fatalf("sampling addresses: %v", err)
	}
	if len(addrs) == 0 {
		log.Fatal("no addresses sampled: this needs probed rows in ip2city_dbiplite_probe_tbl to draw from")
	}
	log.Printf("sampled %d addresses, one per range, all from ALREADY PROBED rows so the backlog is untouched", len(addrs))
	log.Printf("target rate %d per minute, so %d calls should take about %s",
		*rate, len(addrs), (time.Duration(len(addrs))*time.Minute/time.Duration(*rate)).Round(time.Second))
	log.Print("this tool writes nothing to the database")

	gap := time.Minute / time.Duration(*rate)
	outcomes := make([]callOutcome, 0, len(addrs))
	start := time.Now()
	var last time.Time
	stopped := ""

	for i, a := range addrs {
		if !last.IsZero() {
			if elapsed := time.Since(last); elapsed < gap {
				time.Sleep(gap - elapsed)
			}
		}
		last = time.Now()
		out := call(client, *endpoint, a, i+1)
		outcomes = append(outcomes, out)

		if out.httpStatus == http.StatusTooManyRequests {
			log.Printf("[%d] HTTP 429 after %s at an offered rate of %d per minute",
				out.seq, time.Since(start).Round(time.Millisecond), *rate)
			if out.haveXttl {
				log.Printf("[%d] X-Ttl says the window resets in %d seconds", out.seq, out.xttl)
			}
			if !*continuePast {
				stopped = "stopped at the first 429, which is the default"
				break
			}
		}
		if *dumpEvery > 0 && out.seq%*dumpEvery == 0 {
			log.Printf("[%d] http=%d x-rl=%s x-ttl=%s elapsed=%s",
				out.seq, out.httpStatus, intOrDash(out.xrl, out.haveXrl), intOrDash(out.xttl, out.haveXttl),
				time.Since(start).Round(time.Second))
		}
	}

	report(outcomes, start, *rate, stopped)
}

func call(client *http.Client, endpoint, addr string, seq int) callOutcome {
	out := callOutcome{seq: seq, at: time.Now()}
	url := endpoint + addr + "?fields=status,message,city,query"
	resp, err := client.Get(url)
	if err != nil {
		out.err = err
		return out
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	out.httpStatus = resp.StatusCode

	// X-Rl is the number of requests remaining in the current window and X-Ttl the
	// seconds until it resets. These are the authoritative statement of the limit,
	// which is why reading them is preferred over inferring the limit from failures.
	if v := resp.Header.Get("X-Rl"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			out.xrl = n
			out.haveXrl = true
		}
	}
	if v := resp.Header.Get("X-Ttl"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			out.xttl = n
			out.haveXttl = true
		}
	}

	var g geoResult
	if err := json.Unmarshal(body, &g); err == nil {
		out.apiStatus = g.Status
	}
	return out
}

func reportHeaders(out callOutcome) {
	fmt.Println()
	fmt.Println("=== rate-limit headers on a single call ===")
	outf("http status:  %d", out.httpStatus)
	outf("api status:   %s", out.apiStatus)
	if out.haveXrl {
		outf("X-Rl:         %d calls remaining in the current window", out.xrl)
	} else {
		fmt.Println("X-Rl:         ABSENT")
	}
	if out.haveXttl {
		outf("X-Ttl:        %d seconds until the window resets", out.xttl)
	} else {
		fmt.Println("X-Ttl:        ABSENT")
	}
	fmt.Println()
	if out.haveXrl && out.haveXttl {
		outf("The limit can therefore be read directly: %d remaining with %d seconds left in the window.",
			out.xrl, out.xttl)
		fmt.Println("Adding this header logging to check_geo_ip-api would characterise the limit continuously")
		fmt.Println("from the calls the production cycle already makes, at no extra cost and no risk of a block.")
	} else {
		fmt.Println("The headers are not both present, so the limit cannot be read directly and would have to be")
		fmt.Println("inferred from where refusals begin. That is the risky method, because inference requires")
		fmt.Println("provoking the refusal from the same IP the pipeline depends on.")
	}
	fmt.Println()
	fmt.Println("This tool wrote nothing to the database.")
}

func report(outcomes []callOutcome, start time.Time, offered int, stopped string) {
	elapsed := time.Since(start)
	var ok, refused, errored int
	byStatus := map[int]int{}
	minXrl := -1
	sawXrl := false
	var first429 *callOutcome
	for i := range outcomes {
		o := outcomes[i]
		switch {
		case o.err != nil:
			errored++
		case o.httpStatus == http.StatusTooManyRequests:
			refused++
			if first429 == nil {
				first429 = &outcomes[i]
			}
		case o.httpStatus == http.StatusOK:
			ok++
		}
		byStatus[o.httpStatus]++
		if o.haveXrl {
			sawXrl = true
			if minXrl < 0 || o.xrl < minXrl {
				minXrl = o.xrl
			}
		}
	}

	fmt.Println()
	fmt.Println("=== ip-api rate test ===")
	outf("calls attempted:        %d", len(outcomes))
	outf("elapsed:                %s", elapsed.Round(time.Millisecond))
	if elapsed > 0 {
		outf("effective rate:         %.1f calls per minute", float64(len(outcomes))/elapsed.Minutes())
	}
	outf("offered rate:           %d calls per minute", offered)
	outf("HTTP 200:               %d", ok)
	outf("HTTP 429:               %d", refused)
	outf("transport errors:       %d", errored)
	fmt.Println("status code tally:")
	codes := make([]int, 0, len(byStatus))
	for c := range byStatus {
		codes = append(codes, c)
	}
	sort.Ints(codes)
	for _, c := range codes {
		outf("  %-6d %d", c, byStatus[c])
	}
	if sawXrl {
		outf("lowest X-Rl seen:       %d", minXrl)
	} else {
		fmt.Println("lowest X-Rl seen:       header absent throughout")
	}
	if stopped != "" {
		fmt.Println(stopped)
	}

	fmt.Println()
	switch {
	case refused == 0 && sawXrl && minXrl > 0:
		outf("VERDICT: %d calls at an offered %d per minute drew no refusal, and X-Rl never fell below %d.",
			len(outcomes), offered, minXrl)
		fmt.Println("The effective ceiling is therefore at least the offered rate. Raise -rate and repeat to")
		fmt.Println("find where X-Rl approaches zero, which locates the limit without ever being refused.")
	case refused == 0:
		outf("VERDICT: %d calls at an offered %d per minute drew no refusal.", len(outcomes), offered)
		fmt.Println("Without the X-Rl header this cannot say how much headroom remained, only that the limit")
		fmt.Println("was not reached. Do not conclude the limit is far higher on this evidence alone.")
	case first429 != nil:
		outf("VERDICT: refused after %d calls in %s, an offered rate of %d per minute.",
			first429.seq, first429.at.Sub(start).Round(time.Millisecond), offered)
		fmt.Println("That locates an upper bound on the sustainable rate. Note it is an upper bound for THIS")
		fmt.Println("source IP at THIS moment, and if the production cycle was running concurrently the two")
		fmt.Println("tools shared one budget, so the bound belongs to the pair rather than to this tool.")
	}
	fmt.Println()
	fmt.Println("Arithmetic worth doing before acting on any of this: 45 calls a minute is 64,800 a day.")
	fmt.Println("A backlog above about two million ranges therefore needs roughly a month at the documented")
	fmt.Println("rate, so a daily cycle is not reachable by finding a little extra headroom. It needs the")
	fmt.Println("paid batch endpoint, which takes many addresses per request and lifts the limit outright.")
	fmt.Println()
	fmt.Println("This tool wrote nothing to the database.")
}

// sampleAddresses draws one address per range from rows that have ALREADY been
// probed. Drawing from the unprobed backlog would consume ranges the production
// cycle is about to reach, and would invite writing results back, which this tool
// must never do.
func sampleAddresses(n int) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Print("DATABASE_URL not set; connecting via libpq environment and defaults")
	}
	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		return nil, err
	}
	defer conn.Close(context.Background())

	rows, err := conn.Query(ctx,
		"SELECT host(query) FROM ip2city_dbiplite_probe_tbl "+
			"WHERE ran_at IS NOT NULL AND query IS NOT NULL AND family(query) = 4 "+
			"ORDER BY random() LIMIT $1", n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func intOrDash(v int, have bool) string {
	if !have {
		return "-"
	}
	return strconv.Itoa(v)
}

func outf(format string, args ...any) {
	fmt.Println(fmt.Sprintf(format, args...))
}
