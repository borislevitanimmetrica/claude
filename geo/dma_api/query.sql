-- query.sql
-- The canonical DMA address query, for use directly from psql. The dma_api
-- service runs exactly these statements, so results from the API and from a
-- shell match by construction.
--
-- THE JOIN
--
-- dma2city_tbl is joined to ip2city_dbiplite_probe_tbl on city and state_code.
-- state_code is used rather than state because the two letter form has no
-- variance, whereas full state names differ between sources.
--
-- DISTINCT IS REQUIRED, NOT OPTIONAL. dma2city_tbl has primary key
-- (state_code, county, dma, city, city_type), so one city appears on several rows
-- when it spans counties or has more than one city_type. Without DISTINCT every
-- matched range is returned once per matching dma2city_tbl row, silently
-- multiplying the output. Measured on fixtures: Indianapolis appearing twice
-- doubled the address list.
--
-- WHICH city AND state_code THESE ARE
--
-- Both columns are seeded from db-ip when the probe table is rebuilt and then
-- OVERWRITTEN with the measured values when a range is probed. So a row with
-- ran_at IS NOT NULL carries the ip-api city; a row with ran_at IS NULL still
-- carries the db-ip city and its DMA assignment is unverified. Section 4 below
-- reports that split.
--
-- INDEXES
--
-- Section 5 creates the indexes this join needs. Without them every request
-- sequentially scans two million probe rows. TRUNCATE preserves indexes, so they
-- survive a cycle rollover and need creating only once.
--
-- Contains NO backslashes so it survives copy/paste.


-- ---------------------------------------------------------------------------
-- 1. Set the DMA code. Everything below reads it.
-- ---------------------------------------------------------------------------

SET geo.dma_code = '527';


-- ---------------------------------------------------------------------------
-- 2. The matched ranges, one CIDR per line.
--    This is the compact form: about 250 times smaller than the address list.
-- ---------------------------------------------------------------------------

SELECT DISTINCT p.network::text
FROM ip2city_dbiplite_probe_tbl p
JOIN dma2city_tbl d
  ON d.city = p.city
 AND d.state_code = p.state_code
WHERE d.dma_code = current_setting('geo.dma_code')::int
  AND family(p.network) = 4
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- 3. Every individual address, one per line.
--
--    Network and broadcast addresses are INCLUDED. In a prefix wider than /24
--    they are ordinary usable addresses, and a few never-assigned addresses cost
--    nothing.
--
--    generate_series over the integer form is used rather than any inet
--    arithmetic shortcut, because it is the only formulation that stays correct
--    for every prefix length.
--
--    RUN THE COUNT IN SECTION 4 FIRST. A large DMA is tens of millions of rows,
--    and psql buffers a result set in client memory by default. Either redirect
--    to a file with -At -o, or use the API, which streams.
-- ---------------------------------------------------------------------------

WITH m AS (
    SELECT DISTINCT p.network
    FROM ip2city_dbiplite_probe_tbl p
    JOIN dma2city_tbl d
      ON d.city = p.city
     AND d.state_code = p.state_code
    WHERE d.dma_code = current_setting('geo.dma_code')::int
      AND family(p.network) = 4
)
SELECT host((network(m.network)::inet + g.i))::text AS ip
FROM m
CROSS JOIN LATERAL generate_series(0, (2 ^ (32 - masklen(m.network)))::bigint - 1) AS g(i)
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- 4. Counts. Run this before section 3.
--
--    measured_ranges is the number whose city came from an actual ip-api probe.
--    The remainder still carry the db-ip city, so their DMA assignment has not
--    been verified.
-- ---------------------------------------------------------------------------

WITH m AS (
    SELECT DISTINCT p.network, p.ran_at
    FROM ip2city_dbiplite_probe_tbl p
    JOIN dma2city_tbl d
      ON d.city = p.city
     AND d.state_code = p.state_code
    WHERE d.dma_code = current_setting('geo.dma_code')::int
      AND family(p.network) = 4
)
SELECT count(*)                                                    AS ranges,
       coalesce(sum(2::numeric ^ (32 - masklen(network))), 0)::bigint AS addresses,
       count(*) FILTER (WHERE ran_at IS NOT NULL)                  AS measured_ranges,
       min(masklen(network))                                       AS widest_masklen,
       pg_size_pretty(coalesce(sum(2::numeric ^ (32 - masklen(network))), 0)::bigint * 15) AS text_size_estimate
FROM m;


-- ---------------------------------------------------------------------------
-- 5. Indexes. Create once. Safe to re-run.
--
--    The probe table is rebuilt with TRUNCATE, which preserves indexes, so these
--    persist across cycle rollovers. They do add cost to the two million row
--    repopulate, which is the correct trade: the rebuild happens once per cycle,
--    lookups happen per request.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ip2city_dbiplite_probe_tbl_city_state_idx
    ON ip2city_dbiplite_probe_tbl (city, state_code);

CREATE INDEX IF NOT EXISTS dma2city_tbl_dma_code_idx
    ON dma2city_tbl (dma_code) WHERE dma_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS dma2city_tbl_city_state_idx
    ON dma2city_tbl (city, state_code);


-- ---------------------------------------------------------------------------
-- 6. Diagnostic: which cities in this DMA matched nothing.
--
--    A DMA returning zero ranges is almost always a city or state_code spelling
--    difference between the two tables, not an absence of address space. This
--    shows which side of the join failed, per city.
-- ---------------------------------------------------------------------------

SELECT d.city,
       d.state_code,
       count(p.network) AS ranges
FROM dma2city_tbl d
LEFT JOIN ip2city_dbiplite_probe_tbl p
       ON d.city = p.city
      AND d.state_code = p.state_code
      AND family(p.network) = 4
WHERE d.dma_code = current_setting('geo.dma_code')::int
GROUP BY d.city, d.state_code
ORDER BY ranges DESC, d.city;
