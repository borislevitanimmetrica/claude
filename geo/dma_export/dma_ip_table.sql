-- dma_ip_table.sql
-- Materialise every IPv4 address belonging to one DMA into a table.
--
-- Usage:
--   psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -f dma_ip_table.sql
--
-- RUN SECTION 1 FIRST AND READ IT. Enumeration is one row per address; a single
-- matched /12 is 1,048,576 rows. Section 3 is the expensive step.
--
-- Every address in each range is emitted, INCLUDING those ending in .0 and .255.
-- That is deliberate: whether an address is a network or broadcast address
-- depends on the subnet mask actually in use, not on the last octet. An ISP
-- assigning a /22 makes x.x.1.0 and x.x.1.255 ordinary assignable host
-- addresses, and ISPs commonly run DHCP and CGNAT pools wider than a /24.
-- Excluding them would omit real subscribers.
--
-- PROVENANCE WARNING: city and state here come from ip2city_dbiplite_tbl. For
-- source='routeviews' rows those were inherited from the parent range that
-- apply_splits deleted, so a split /16 still asserts one city across all 256 of
-- its /24s. Measured per-/24 values live in ip2city_dbiplite_traceroute_tbl and
-- are only present where check_geo_ip-api has already probed. The dbip_city_only
-- column below records which is which so the partner can see the difference.
--
-- Contains NO backslashes so it survives copy/paste.

SELECT '1. SIZE CHECK - read this before running section 3' AS section;
WITH m AS (
    SELECT DISTINCT s.network
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = :'DMA'
      AND family(s.network) = 4
)
SELECT count(*) AS ranges,
       sum((2::numeric ^ (32 - masklen(network)))::bigint) AS addresses_to_insert,
       min(masklen(network)) AS widest,
       max(masklen(network)) AS narrowest,
       pg_size_pretty((sum((2::numeric ^ (32 - masklen(network)))::bigint) * 40)::bigint)
           AS rough_table_size
FROM m;

SELECT '2. create the destination table' AS section;
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
    'true when the city/state came from db-ip only, with no ip-api measurement for this range yet';

SELECT '3. populate - this is the slow step' AS section;
WITH m AS (
    SELECT DISTINCT s.network, s.city, s.state, s.source,
           (tr.city IS NULL) AS dbip_only
    FROM ip2city_dbiplite_tbl s
    LEFT JOIN ip2city_dbiplite_traceroute_tbl tr
           ON tr.network = s.network AND tr.city IS NOT NULL
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE d.dma = :'DMA'
      AND family(s.network) = 4
)
INSERT INTO dma_ip_export (ip, network, city, state, dma, source, dbip_city_only)
SELECT host(m.network)::inet + g.i,
       m.network, m.city, m.state, :'DMA', m.source, m.dbip_only
FROM m
CROSS JOIN LATERAL generate_series(
        0,
        (2::numeric ^ (32 - masklen(m.network)))::bigint - 1
     ) AS g(i)
ON CONFLICT (ip) DO NOTHING;

SELECT '4. verify' AS section;
SELECT count(*) AS addresses,
       count(DISTINCT network) AS ranges,
       count(*) FILTER (WHERE dbip_city_only) AS from_dbip_only,
       count(*) FILTER (WHERE NOT dbip_city_only) AS ip_api_measured,
       min(ip) AS lowest, max(ip) AS highest
FROM dma_ip_export;

SELECT '5. sanity: addresses per city' AS section;
SELECT city, state, count(*) AS addresses, count(DISTINCT network) AS ranges
FROM dma_ip_export
GROUP BY city, state
ORDER BY addresses DESC;

SELECT '6. sanity: confirm .0 and .255 are present as intended' AS section;
SELECT count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '0')   AS ending_dot_zero,
       count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '255') AS ending_dot_255
FROM dma_ip_export;

ANALYZE dma_ip_export;
