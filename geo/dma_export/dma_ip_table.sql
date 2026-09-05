-- dma_ip_table.sql
-- Materialise every IPv4 address belonging to one DMA into table dma_ip_export.
--
-- Usage:
--   psql "$DATABASE_URL" -f dma_ip_table.sql
--
-- To change the DMA, edit the ONE line marked "EDIT THIS LINE" below.
--
-- This file uses no psql variables and no psql meta-commands, so plain
-- "psql -f" works and it can also be pasted straight into an interactive
-- session. An earlier version required "-v DMA=..." and failed with
-- "syntax error at or near :" when that flag was omitted.
--
-- RUN SECTION 2 FIRST AND READ IT. Enumeration is one row per address; a single
-- matched /12 is 1,048,576 rows. Section 4 is the expensive step.
--
-- Every address in each range is emitted, INCLUDING those ending in .0 and .255.
-- That is deliberate: whether an address is a network or broadcast address
-- depends on the subnet mask actually in use, not on the last octet. An ISP
-- assigning a /22 makes x.x.1.0 and x.x.1.255 ordinary assignable host
-- addresses, and ISPs commonly run DHCP and CGNAT pools wider than a /24.
-- Excluding them would omit real subscribers.
--
-- PROVENANCE WARNING: city and state come from ip2city_dbiplite_tbl. For
-- source='routeviews' rows those were inherited from the parent range that
-- apply_splits deleted, so a split /16 still asserts one city across all 256 of
-- its /24s. Measured per-/24 values live in ip2city_dbiplite_traceroute_tbl and
-- exist only where check_geo_ip-api has already probed. Column dbip_city_only
-- records which is which, so a partner can see exactly what is measured and what
-- is inherited.
--
-- Contains NO backslashes so it survives copy/paste.

SELECT '1. parameter' AS section;
DROP TABLE IF EXISTS dma_param;
CREATE TEMP TABLE dma_param AS
    SELECT 'Indianapolis, IN DMA'::text AS dma;   -- EDIT THIS LINE
SELECT dma AS dma_being_exported FROM dma_param;

SELECT '2. SIZE CHECK - read this before section 4 runs' AS section;
WITH m AS (
    SELECT DISTINCT s.network
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = (SELECT dma FROM dma_param)
      AND family(s.network) = 4
)
SELECT count(*) AS ranges,
       coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0) AS addresses_to_insert,
       min(masklen(network)) AS widest,
       max(masklen(network)) AS narrowest,
       pg_size_pretty((coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0) * 40)::bigint)
           AS rough_table_size
FROM m;

SELECT '3. create the destination table' AS section;
DROP TABLE IF EXISTS dma_ip_export;
CREATE TABLE dma_ip_export (
    ip              inet    NOT NULL,
    network         cidr    NOT NULL,
    city            text,
    state           text,
    dma             text    NOT NULL,
    source          text    NOT NULL,
    dbip_city_only  boolean NOT NULL,
    PRIMARY KEY (ip)
);

COMMENT ON COLUMN dma_ip_export.dbip_city_only IS
    'true when city/state came from db-ip only, with no ip-api measurement for this range yet';

SELECT '4. populate - this is the slow step' AS section;
WITH m AS (
    SELECT DISTINCT s.network, s.city, s.state, s.source,
           (tr.city IS NULL) AS dbip_only
    FROM ip2city_dbiplite_tbl s
    LEFT JOIN ip2city_dbiplite_traceroute_tbl tr
           ON tr.network = s.network AND tr.city IS NOT NULL
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = (SELECT dma FROM dma_param)
      AND family(s.network) = 4
)
INSERT INTO dma_ip_export (ip, network, city, state, dma, source, dbip_city_only)
SELECT host(m.network)::inet + g.i,
       m.network, m.city, m.state, (SELECT dma FROM dma_param), m.source, m.dbip_only
FROM m
CROSS JOIN LATERAL generate_series(
        0,
        (2::numeric ^ (32 - masklen(m.network)))::bigint - 1
     ) AS g(i)
ON CONFLICT (ip) DO NOTHING;

SELECT '5. verify' AS section;
SELECT count(*) AS addresses,
       count(DISTINCT network) AS ranges,
       count(*) FILTER (WHERE dbip_city_only) AS from_dbip_only,
       count(*) FILTER (WHERE NOT dbip_city_only) AS ip_api_measured,
       min(ip) AS lowest, max(ip) AS highest
FROM dma_ip_export;

SELECT '6. addresses per city' AS section;
SELECT city, state, count(*) AS addresses, count(DISTINCT network) AS ranges
FROM dma_ip_export
GROUP BY city, state
ORDER BY addresses DESC;

SELECT '7. confirm .0 and .255 are present as intended' AS section;
SELECT count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '0')   AS ending_dot_zero,
       count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '255') AS ending_dot_255
FROM dma_ip_export;

ANALYZE dma_ip_export;
