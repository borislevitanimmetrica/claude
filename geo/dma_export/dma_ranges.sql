-- dma_ranges.sql
-- Matched IPv4 ranges for one DMA, plus a size estimate for full address
-- enumeration. Run this FIRST: enumeration can be very large.
--
-- Usage:
--   psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -f dma_ranges.sql
--
-- Contains NO backslashes (no psql meta-commands) so it survives copy/paste.

SELECT '1. size of the match' AS section;
WITH m AS (
    SELECT DISTINCT s.network
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = :'DMA'
      AND family(s.network) = 4
)
SELECT count(*) AS ranges,
       sum((2::numeric ^ (32 - masklen(network)))::bigint) AS addresses,
       min(masklen(network)) AS widest,
       max(masklen(network)) AS narrowest,
       pg_size_pretty((sum((2::numeric ^ (32 - masklen(network)))::bigint) * 15)::bigint)
           AS approx_text_size
FROM m;

SELECT '2. breakdown by mask length' AS section;
WITH m AS (
    SELECT DISTINCT s.network
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = :'DMA'
      AND family(s.network) = 4
)
SELECT masklen(network) AS len, count(*) AS ranges,
       sum((2::numeric ^ (32 - masklen(network)))::bigint) AS addresses
FROM m GROUP BY 1 ORDER BY 1;

SELECT '3. provenance of the matched ranges' AS section;
-- dbip rows carry db-ip's own city; routeviews rows carry the city INHERITED
-- from the parent that apply_splits deleted, not a per-/24 measured value.
WITH m AS (
    SELECT DISTINCT s.network, s.source
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = :'DMA'
      AND family(s.network) = 4
)
SELECT source, count(*) AS ranges FROM m GROUP BY 1 ORDER BY 1;

SELECT '4. how many matched ranges have a MEASURED ip-api city yet' AS section;
WITH m AS (
    SELECT DISTINCT s.network
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = :'DMA'
      AND family(s.network) = 4
)
SELECT count(*) AS matched_ranges,
       count(tr.network) FILTER (WHERE tr.city IS NOT NULL) AS with_measured_city
FROM m
LEFT JOIN ip2city_dbiplite_traceroute_tbl tr ON tr.network = m.network;
