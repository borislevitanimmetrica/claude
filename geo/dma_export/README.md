# DMA address export

Turns a DMA name into the complete list of IPv4 addresses covered by matching
ranges. Built for a partner proof of concept.

## Caveat on data quality, read this first

The match joins `ip2city_dbiplite_tbl.city` / `.state` to `dma2city_tbl`. Those
columns hold:

- for `source = 'dbip'` rows: db-ip's own city and state
- for `source = 'routeviews'` rows: the city and state **inherited from the
  parent range that `apply_splits` deleted** — not a per-/24 measured value

The per-/24 measured values produced by `check_geo_ip-api` live in
`ip2city_dbiplite_traceroute_tbl` (`city`, `region`, `regionname`). Until that
tool has worked through the /24 rows, this export reflects **db-ip granularity**,
which for a range that was split means one city asserted across the whole
original parent.

So: `dma_cidrs.sql` is the db-ip baseline, and `dma_cidrs_measured.sql` prefers
the measured value and falls back to db-ip. Re-run the measured variant once
probing has progressed to see the refinement.

## Step 1: size the match

Enumeration grows fast. A single /12 is 1,048,576 addresses.

    psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -f dma_ranges.sql

Reports the range count, address count, mask distribution, provenance split
(`dbip` vs `routeviews`), and how many matched ranges have a measured city yet.

## Step 2: extract the CIDR list

    psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -At -f dma_cidrs.sql > dma_cidrs.txt
    wc -l dma_cidrs.txt

`-A` is unaligned and `-t` suppresses headers, so the output is one CIDR per
line with nothing else.

## Step 3: enumerate the addresses

    cd expand_cidrs/cmd && go build -trimpath -o ../bin/expand_cidrs .

    ../bin/expand_cidrs -count-only ../../dma_cidrs.txt
    ../bin/expand_cidrs -out ../../dma_ips.txt.gz ../../dma_cidrs.txt

Flags:

- `-count-only` report counts and exit
- `-out FILE` write to FILE; a `.gz` suffix compresses
- `-skip-network-broadcast` omit the first and last address of each /30 or wider
- `-max N` refuse to enumerate more than N addresses

Reads stdin when given no file, so this also works:

    psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -At -f dma_cidrs.sql | ./bin/expand_cidrs -out dma_ips.txt.gz

## dma2city_tbl must list EVERY city in the DMA

Verified by test, and it matters: switching from db-ip values to ip-api measured
values can **remove** ranges from a DMA.

A range db-ip labels "Indianapolis" may measure as "Greenwood", "Carmel",
"Fishers", "Noblesville" and so on, because the measurement is per-/24 and
finer-grained. If `dma2city_tbl` maps only "Indianapolis" to
`Indianapolis, IN DMA`, then every range that measures to a suburb silently drops
out of the export.

In the test fixture, `dma_cidrs.sql` returned 3 ranges and
`dma_cidrs_measured.sql` returned 2, purely because the measured city
("Greenwood") was absent from `dma2city_tbl`.

So before trusting the measured variant, compare the two row counts:

    psql "$DATABASE_URL" -At -f dma_cidrs.sql          | wc -l
    psql "$DATABASE_URL" -At -f dma_cidrs_measured.sql | wc -l

A measured count LOWER than the db-ip count means missing city-to-DMA mappings,
not a better result. Find the gaps with:

    SELECT DISTINCT tr.city, tr.regionname
    FROM ip2city_dbiplite_traceroute_tbl tr
    WHERE tr.city IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dma2city_tbl d
                      WHERE d.city = tr.city AND d.state = tr.regionname)
    ORDER BY 1;

Everything that query returns is a measured city with no DMA mapping, and every
range resolving to it is currently invisible to the export.

## Notes

- IPv4 only, enforced in both the SQL (`family(network) = 4`) and the tool.
- `DISTINCT` in the SQL prevents duplicate ranges when `dma2city_tbl` holds more
  than one row for a city and state.
- All addresses in each range are emitted by default, including the network and
  broadcast addresses, since a routed range legitimately contains them. Use
  `-skip-network-broadcast` if the partner expects only host addresses.
