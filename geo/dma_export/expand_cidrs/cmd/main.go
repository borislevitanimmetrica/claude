// Command expand_cidrs reads IPv4 CIDR ranges (one per line) and writes every
// address in them, one per line. It exists so a DMA range list can be turned
// into a complete address list without needing database access.
//
// Enumeration grows fast: a single /12 is 1,048,576 addresses and a /8 is
// 16,777,216. Run with -count-only first.
//
// Usage:
//
//	expand_cidrs -count-only dma_cidrs.txt
//	expand_cidrs -out dma_ips.txt.gz dma_cidrs.txt
//	psql ... | expand_cidrs -out dma_ips.txt.gz
//
// An output path ending in .gz is gzip-compressed. Reading from stdin works when
// no file argument is given.
//
// NOTE: contains NO backslash escape sequences and no backtick strings. Newlines
// are written as byte 10 rather than an escape.
package main

import (
	"bufio"
	"compress/gzip"
	"flag"
	"fmt"
	"io"
	"log"
	"net/netip"
	"os"
	"strings"
)

const newline = byte(10)

func main() {
	countOnly := flag.Bool("count-only", false, "report the address count and exit without enumerating")
	outPath := flag.String("out", "", "output file; .gz suffix compresses; empty writes to stdout")
	skipEdges := flag.Bool("skip-network-broadcast", false,
		"omit the first and last address of each range of /30 or wider")
	maxAddrs := flag.Int64("max", 0, "refuse to enumerate more than this many addresses (0 = no limit)")
	flag.Parse()

	var in io.Reader = os.Stdin
	if flag.NArg() >= 1 {
		f, err := os.Open(flag.Arg(0))
		if err != nil {
			log.Fatalf("opening %s: %v", flag.Arg(0), err)
		}
		defer f.Close()
		in = f
	}

	prefixes, total, err := readPrefixes(in, *skipEdges)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Fprintln(os.Stderr, fmt.Sprintf("ranges: %d", len(prefixes)))
	fmt.Fprintln(os.Stderr, fmt.Sprintf("addresses: %d", total))
	if *skipEdges {
		fmt.Fprintln(os.Stderr, "(network and broadcast addresses omitted for /30 and wider)")
	}

	if *countOnly {
		return
	}
	if *maxAddrs > 0 && total > *maxAddrs {
		log.Fatalf("refusing to enumerate %d addresses, over the -max limit of %d", total, *maxAddrs)
	}

	var out io.Writer = os.Stdout
	var closers []io.Closer
	if *outPath != "" {
		f, err := os.Create(*outPath)
		if err != nil {
			log.Fatalf("creating %s: %v", *outPath, err)
		}
		closers = append(closers, f)
		out = f
		if strings.HasSuffix(*outPath, ".gz") {
			gz := gzip.NewWriter(f)
			closers = append([]io.Closer{gz}, closers...)
			out = gz
		}
	}

	bw := bufio.NewWriterSize(out, 1<<20)
	var written int64
	for _, p := range prefixes {
		addr := p.Masked().Addr()
		n := addressCount(p, *skipEdges)
		if *skipEdges && shouldSkipEdges(p) {
			addr = addr.Next()
		}
		for i := int64(0); i < n; i++ {
			bw.WriteString(addr.String())
			bw.WriteByte(newline)
			addr = addr.Next()
			written++
		}
	}
	if err := bw.Flush(); err != nil {
		log.Fatalf("flushing output: %v", err)
	}
	for _, c := range closers {
		if err := c.Close(); err != nil {
			log.Fatalf("closing output: %v", err)
		}
	}

	fmt.Fprintln(os.Stderr, fmt.Sprintf("wrote %d addresses", written))
}

func readPrefixes(in io.Reader, skipEdges bool) ([]netip.Prefix, int64, error) {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var out []netip.Prefix
	var total int64
	line := 0
	for sc.Scan() {
		line++
		s := strings.TrimSpace(sc.Text())
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		p, err := netip.ParsePrefix(s)
		if err != nil {
			// Tolerate a bare address by treating it as a /32.
			a, aerr := netip.ParseAddr(s)
			if aerr != nil {
				return nil, 0, fmt.Errorf("line %d: cannot parse %q as a CIDR or address", line, s)
			}
			p = netip.PrefixFrom(a, a.BitLen())
		}
		if !p.Addr().Is4() {
			return nil, 0, fmt.Errorf("line %d: %q is not IPv4", line, s)
		}
		p = p.Masked()
		out = append(out, p)
		total += addressCount(p, skipEdges)
	}
	if err := sc.Err(); err != nil {
		return nil, 0, err
	}
	return out, total, nil
}

func addressCount(p netip.Prefix, skipEdges bool) int64 {
	n := int64(1) << uint(32-p.Bits())
	if skipEdges && shouldSkipEdges(p) {
		n -= 2
		if n < 0 {
			n = 0
		}
	}
	return n
}

// shouldSkipEdges reports whether a range is large enough for the first and last
// address to be a network and broadcast address worth omitting. A /31 and /32
// have no such pair.
func shouldSkipEdges(p netip.Prefix) bool {
	return p.Bits() <= 30
}
