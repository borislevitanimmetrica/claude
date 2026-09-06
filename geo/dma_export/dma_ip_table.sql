-- dma_ip_table.sql
-- Materialise every IPv4 address belonging to a DMA into table dma_ip_export.
--
-- ONE DMA:
--   psql "$DATABASE_URL" -v DMA="Indianapolis, IN DMA" -f dma_ip_table.sql
--
-- ALL DMAs (omit the flag entirely):
--   psql "$DATABASE_URL" -f dma_ip_table.sql
--
-- Both forms work. The block below defines DMA as an empty string when the flag
-- is absent, and an empty string means "every DMA". An earlier version failed
-- with "syntax error at or near :" when the flag was omitted.
--
-- This is the only file here that uses psql meta-commands (the backslash lines
-- below). It is pulled from the repository rather than pasted, so the backslash
-- transfer hazard does not apply. Every other statement is plain SQL.
--
-- READ SECTION 2 BEFORE SECTION 4 RUNS. Enumeration is one row per address. A
-- single matched /12 is 1,048,576 rows, and running for ALL DMAs enumerates
-- every matched range in the country.
--
-- Every address in each range is emitted, INCLUDING those ending in .0 and .255.
-- Whether an address is a network or broadcast address depends on the subnet mask
-- actually in use, not on the last octet: an ISP assigning a /22 makes x.x.1.0
-- and x.x.1.255 ordinary assignable host addresses, and ISPs commonly run DHCP
-- and CGNAT pools wider than a /24. Excluding them would omit real subscribers.
--
-- PROVENANCE: city and state come from ip2city_dbiplite_tbl. For
-- source='routeviews' rows those were inherited from the parent range that
-- apply_splits deleted, so a split /16 still asserts one city across all 256 of
-- its /24s. Measured per-/24 values live in ip2city_dbiplite_traceroute_tbl and
-- exist only where check_geo_ip-api has already probed. Column dbip_city_only
-- records which is which.
--
-- COVERAGE CAVEAT: the join is on city name. Nielsen DMAs are defined by COUNTY,
-- so dma2city_tbl must list every city in every county of the DMA. Any city it
-- omits is a silent false negative, and this becomes more visible as measured
-- values resolve ranges to suburbs rather than the principal city. Section 7
-- reports measured cities that have no dma2city_tbl mapping.

\if :{?DMA}
\else
  \set DMA ''
\endif

SELECT '1. parameter' AS section;
SELECT CASE WHEN :'DMA' = '' THEN 'ALL DMAs' ELSE :'DMA' END AS exporting;

SELECT '2. SIZE CHECK - read before section 4' AS section;
WITH m AS (
    SELECT DISTINCT s.network, d.dma
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE (:'DMA' = '' OR d.dma = :'DMA')
      AND family(s.network) = 4
)
SELECT count(*) AS range_dma_pairs,
       count(DISTINCT network) AS distinct_ranges,
       count(DISTINCT dma) AS distinct_dmas,
       coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0) AS addresses_to_insert,
       pg_size_pretty((coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0) * 40)::bigint)
           AS rough_table_size
FROM m;

SELECT '2b. largest DMAs by address count' AS section;
WITH m AS (
    SELECT DISTINCT s.network, d.dma
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE (:'DMA' = '' OR d.dma = :'DMA')
      AND family(s.network) = 4
)
SELECT dma, count(*) AS ranges,
       sum((2::numeric ^ (32 - masklen(network)))::bigint) AS addresses
FROM m GROUP BY dma ORDER BY addresses DESC LIMIT 25;

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
    PRIMARY KEY (ip, dma)
);

COMMENT ON COLUMN dma_ip_export.dbip_city_only IS
    'true when city/state came from db-ip only, with no ip-api measurement for this range yet';

-- The primary key is (ip, dma) rather than (ip) alone. A single address can
-- legitimately appear under more than one DMA if dma2city_tbl maps its city to
-- several, and an ip-only key would silently discard those rows.
CREATE INDEX dma_ip_export_dma_idx ON dma_ip_export (dma);
CREATE INDEX dma_ip_export_network_idx ON dma_ip_export (network);

SELECT '4. populate - this is the slow step' AS section;
WITH m AS (
    SELECT DISTINCT s.network, s.city, s.state, s.source, d.dma,
           (tr.city IS NULL) AS dbip_only
    FROM ip2city_dbiplite_tbl s
    LEFT JOIN ip2city_dbiplite_traceroute_tbl tr
           ON tr.network = s.network AND tr.city IS NOT NULL
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE (:'DMA' = '' OR d.dma = :'DMA')
      AND family(s.network) = 4
)
INSERT INTO dma_ip_export (ip, network, city, state, dma, source, dbip_city_only)
SELECT host(m.network)::inet + g.i,
       m.network, m.city, m.state, m.dma, m.source, m.dbip_only
FROM m
CROSS JOIN LATERAL generate_series(
        0,
        (2::numeric ^ (32 - masklen(m.network)))::bigint - 1
     ) AS g(i)
ON CONFLICT (ip, dma) DO NOTHING;

SELECT '5. verify' AS section;
SELECT count(*) AS rows_written,
       count(DISTINCT ip) AS distinct_addresses,
       count(DISTINCT network) AS ranges,
       count(DISTINCT dma) AS dmas,
       count(*) FILTER (WHERE dbip_city_only) AS from_dbip_only,
       count(*) FILTER (WHERE NOT dbip_city_only) AS ip_api_measured,
       min(ip) AS lowest, max(ip) AS highest
FROM dma_ip_export;

SELECT '6. addresses per DMA and city' AS section;
SELECT dma, city, state, count(*) AS addresses, count(DISTINCT network) AS ranges
FROM dma_ip_export
GROUP BY dma, city, state
ORDER BY dma, addresses DESC;

SELECT '7. COVERAGE GAP: measured cities with no dma2city_tbl mapping' AS section;
-- Every row here is a city ip-api has measured for which no DMA is known, so
-- ranges resolving to it are invisible to this export. Nielsen DMAs are
-- county-based, so suburbs must be listed individually.
SELECT tr.city, tr.regionname, count(*) AS ranges_affected
FROM ip2city_dbiplite_traceroute_tbl tr
WHERE tr.city IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dma2city_tbl d
                  WHERE d.city = tr.city AND d.state = tr.regionname)
GROUP BY tr.city, tr.regionname
ORDER BY ranges_affected DESC
LIMIT 40;

SELECT '8. confirm .0 and .255 are present as intended' AS section;
SELECT count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '0')   AS ending_dot_zero,
       count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '255') AS ending_dot_255
FROM dma_ip_export;

ANALYZE dma_ip_export;
