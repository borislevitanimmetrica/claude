-- dma_cidrs_measured.sql
-- Same as dma_cidrs.sql but PREFERS the ip-api measured city/state from
-- ip2city_dbiplite_traceroute_tbl, falling back to the db-ip values only where
-- no measurement exists yet.
--
-- Use this once check_geo_ip-api has worked through the /24 rows. Until then it
-- returns nearly the same result as dma_cidrs.sql, because the traceroute table
-- has few rows for the newly inserted ranges.
--
-- The traceroute table stores region as the two-letter code and regionname as
-- the full state name; db-ip's state column holds the full name, so regionname
-- is the correct column to compare against dma2city_tbl.state.
--
-- Usage:
--   psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -At -f dma_cidrs_measured.sql > dma_cidrs.txt
--
-- Contains NO backslashes so it survives copy/paste.

SELECT DISTINCT s.network::text
FROM ip2city_dbiplite_tbl s
LEFT JOIN ip2city_dbiplite_traceroute_tbl tr
       ON tr.network = s.network AND tr.city IS NOT NULL
JOIN dma2city_tbl d
  ON coalesce(tr.city, s.city) = d.city
 AND coalesce(tr.regionname, s.state) = d.state
WHERE d.dma = :'DMA'
  AND family(s.network) = 4
ORDER BY 1;
