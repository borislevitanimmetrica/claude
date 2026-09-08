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
-- The probe table stores state_code as the two-letter code and state as the full
-- state name; db-ip's state column holds the full name, so state is the correct
-- column to compare against dma2city_tbl.state. If your dma2city_tbl.state holds
-- two-letter codes, use tr.state_code instead.
--
-- MEASURED IS tr.ran_at IS NOT NULL, NOT tr.city IS NOT NULL. The probe table is
-- seeded with db-ip's city and state for every range when it is rebuilt, so city
-- is populated whether or not the range has been probed. ran_at is NULL until a
-- probe stamps it, so it is the only reliable test.
--
-- Single statement with the DMA name inlined, so the output pipes cleanly.
-- To change the DMA, edit the quoted name below.
--
-- Contains NO backslashes so it survives copy/paste.

SELECT DISTINCT s.network::text
FROM ip2city_dbiplite_tbl s
LEFT JOIN ip2city_dbiplite_probe_tbl tr
       ON tr.network = s.network AND tr.ran_at IS NOT NULL
JOIN dma2city_tbl d
  ON coalesce(tr.city, s.city) = d.city
 AND coalesce(tr.state, s.state) = d.state
WHERE d.dma = 'Indianapolis, IN DMA'
  AND family(s.network) = 4
ORDER BY 1;
