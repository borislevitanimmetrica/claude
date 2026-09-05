-- dma_cidrs_measured.sql
-- Same as dma_cidrs.sql but PREFERS the ip-api measured city/state from
-- ip2city_dbiplite_traceroute_tbl, falling back to the db-ip values only where
-- no measurement exists yet.
--
-- Usage:
--   psql "$DATABASE_URL" -At -f dma_cidrs_measured.sql > dma_cidrs.txt
--
-- IMPORTANT, verified by test: switching to measured values can REMOVE ranges
-- from a DMA. A range db-ip labelled "Indianapolis" may measure as "Greenwood",
-- "Carmel", "Fishers" and so on. If dma2city_tbl does not map that finer city to
-- the DMA, the range silently drops out of the result. So dma2city_tbl must list
-- every city in the DMA, not just the principal one, before this variant can be
-- trusted. Compare its row count against dma_cidrs.sql and investigate any
-- shortfall rather than assuming it is an improvement.
--
-- The traceroute table stores region as the two-letter code and regionname as
-- the full state name; db-ip's state column holds the full name, so regionname
-- is the correct column to compare against dma2city_tbl.state. If your
-- dma2city_tbl.state holds two-letter codes, use tr.region instead.
--
-- Single statement with the DMA name inlined, so the output pipes cleanly.
-- To change the DMA, edit the quoted name below.
--
-- Contains NO backslashes so it survives copy/paste.

SELECT DISTINCT s.network::text
FROM ip2city_dbiplite_tbl s
LEFT JOIN ip2city_dbiplite_traceroute_tbl tr
       ON tr.network = s.network AND tr.city IS NOT NULL
JOIN dma2city_tbl d
  ON coalesce(tr.city, s.city) = d.city
 AND coalesce(tr.regionname, s.state) = d.state
WHERE d.dma = 'Indianapolis, IN DMA'
  AND family(s.network) = 4
ORDER BY 1;
