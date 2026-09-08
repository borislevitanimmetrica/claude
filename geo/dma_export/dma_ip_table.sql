-- dma_ip_table.sql
-- Materialise every IPv4 address belonging to a DMA into table dma_ip_export.
--
-- ONE DMA:
--   psql "$DATABASE_URL" -c "SET geo.dma = 'Indianapolis, IN DMA'" -f dma_ip_table.sql
--
-- ALL DMAs (just omit the SET):
--   psql "$DATABASE_URL" -f dma_ip_table.sql
--
-- The parameter is a PostgreSQL run-time setting rather than a psql variable, so
-- this file contains NO backslashes and no psql meta-commands: it survives
-- copy/paste and works with a plain "psql -f". An unset geo.dma means all DMAs.
-- Verified: -c SET and -f share one session, so the setting reaches this file.
--
-- SAFETY GUARD. Section 3 aborts if the enumeration would exceed geo.max_addresses
-- (default 50 million rows). ALL-DMA mode is genuinely enormous: at the observed
-- average of roughly 600 addresses per range, the full US range set enumerates to
-- over a billion rows. To raise the ceiling deliberately:
--   psql "$DATABASE_URL" -c "SET geo.max_addresses = '200000000'" -f dma_ip_table.sql
--
-- Every address in each range is emitted, INCLUDING those ending in .0 and .255.
-- Whether an address is a network or broadcast address depends on the subnet mask
-- actually in use, not on the last octet: an ISP assigning a /22 makes x.x.1.0
-- and x.x.1.255 ordinary assignable host addresses, and ISPs commonly run DHCP
-- and CGNAT pools wider than a /24. Excluding them would create false negatives.
--
-- PROVENANCE: city and state come from ip2city_dbiplite_tbl. For
-- source='routeviews' rows those were inherited from the parent range that
-- apply_splits deleted, so a split /16 still asserts one city across all 256 of
-- its /24s. Measured per-/24 values live in ip2city_dbiplite_traceroute_tbl.
-- Column dbip_city_only records which is which.
--
-- IPv4 ONLY. family(network) = 4 throughout. IPv6 cannot be enumerated
-- address-by-address (a single /64 is 18 quintillion addresses), so IPv6 needs a
-- prefix-list export and prefix matching on the consuming side. Until that
-- exists, every IPv6 bid request is a false negative.

SELECT '1. parameters' AS section;
SELECT coalesce(nullif(current_setting('geo.dma', true), ''), 'ALL DMAs') AS exporting,
       coalesce(current_setting('geo.max_addresses', true), '50000000') AS max_addresses;

SELECT '2. SIZE CHECK' AS section;
WITH m AS (
    SELECT DISTINCT s.network, d.dma
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE (coalesce(current_setting('geo.dma', true), '') = ''
           OR d.dma = current_setting('geo.dma', true))
      AND family(s.network) = 4
)
SELECT count(*) AS range_dma_pairs,
       count(DISTINCT network) AS distinct_ranges,
       count(DISTINCT dma) AS distinct_dmas,
       coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0) AS addresses_to_insert,
       pg_size_pretty((coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0) * 40)::bigint)
           AS rough_table_size
FROM m;

SELECT '2b. addresses per DMA, largest first' AS section;
WITH m AS (
    SELECT DISTINCT s.network, d.dma
    FROM ip2city_dbiplite_tbl s
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE (coalesce(current_setting('geo.dma', true), '') = ''
           OR d.dma = current_setting('geo.dma', true))
      AND family(s.network) = 4
)
SELECT dma, count(*) AS ranges,
       sum((2::numeric ^ (32 - masklen(network)))::bigint) AS addresses
FROM m GROUP BY dma ORDER BY addresses DESC LIMIT 25;

SELECT '3. guard' AS section;
DO $guard$
DECLARE
    n   bigint;
    cap bigint := coalesce(current_setting('geo.max_addresses', true)::bigint, 50000000);
BEGIN
    SELECT coalesce(sum((2::numeric ^ (32 - masklen(network)))::bigint), 0)
      INTO n
      FROM (SELECT DISTINCT s.network
              FROM ip2city_dbiplite_tbl s
              JOIN dma2city_tbl d
                ON s.city = d.city AND s.state = d.state
             WHERE (coalesce(current_setting('geo.dma', true), '') = ''
                    OR d.dma = current_setting('geo.dma', true))
               AND family(s.network) = 4) m;

    IF n > cap THEN
        RAISE EXCEPTION
            'refusing to enumerate % addresses, over geo.max_addresses = %. Set a single DMA, or raise the cap with: SET geo.max_addresses = ''%'';',
            n, cap, (n + n / 10);
    END IF;

    RAISE NOTICE 'guard passed: % addresses, cap %', n, cap;
END
$guard$;

SELECT '4. create the destination table' AS section;
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

-- Key is (ip, dma), not (ip). One address can legitimately belong to more than
-- one DMA if dma2city_tbl maps its city to several, and an ip-only key would
-- silently discard those rows.
CREATE INDEX dma_ip_export_dma_idx ON dma_ip_export (dma);
CREATE INDEX dma_ip_export_network_idx ON dma_ip_export (network);

SELECT '5. populate - the slow step' AS section;
WITH m AS (
    SELECT DISTINCT s.network, s.city, s.state, s.source, d.dma,
           (tr.ran_at IS NULL) AS dbip_only
    FROM ip2city_dbiplite_tbl s
    LEFT JOIN ip2city_dbiplite_probe_tbl tr
           ON tr.network = s.network AND tr.ran_at IS NOT NULL
    JOIN dma2city_tbl d
      ON s.city = d.city AND s.state = d.state
    WHERE (coalesce(current_setting('geo.dma', true), '') = ''
           OR d.dma = current_setting('geo.dma', true))
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

SELECT '6. verify' AS section;
SELECT count(*) AS rows_written,
       count(DISTINCT ip) AS distinct_addresses,
       count(DISTINCT network) AS ranges,
       count(DISTINCT dma) AS dmas,
       count(*) FILTER (WHERE dbip_city_only) AS from_dbip_only,
       count(*) FILTER (WHERE NOT dbip_city_only) AS ip_api_measured,
       min(ip) AS lowest, max(ip) AS highest
FROM dma_ip_export;

SELECT '7. addresses per DMA and city' AS section;
SELECT dma, city, state, count(*) AS addresses, count(DISTINCT network) AS ranges
FROM dma_ip_export
GROUP BY dma, city, state
ORDER BY dma, addresses DESC
LIMIT 60;

SELECT '8. confirm .0 and .255 are present as intended' AS section;
SELECT count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '0')   AS ending_dot_zero,
       count(*) FILTER (WHERE split_part(host(ip), '.', 4) = '255') AS ending_dot_255
FROM dma_ip_export;

SELECT '9. FALSE NEGATIVE audit' AS section;
-- What this export cannot see. These are the gaps that cost money in a workflow
-- where false negatives are unacceptable and false positives are not.
SELECT 'IPv6 US ranges excluded (need a prefix-list export)' AS gap,
       count(*)::text AS n
FROM ip2city_dbiplite_tbl WHERE family(network) = 6
UNION ALL
SELECT 'IPv4 ranges whose city has no dma2city_tbl mapping',
       count(*)::text
FROM ip2city_dbiplite_tbl s
WHERE family(s.network) = 4
  AND NOT EXISTS (SELECT 1 FROM dma2city_tbl d
                  WHERE d.city = s.city AND d.state = s.state)
UNION ALL
SELECT 'IPv4 ranges with no city at all',
       count(*)::text
FROM ip2city_dbiplite_tbl
WHERE family(network) = 4 AND (city IS NULL OR city = '')
UNION ALL
SELECT 'IPv4 ranges suppressed by geo_exclusions',
       count(*)::text
FROM ip2city_dbiplite_tbl s
WHERE family(s.network) = 4
  AND EXISTS (SELECT 1 FROM geo_exclusions x
              WHERE x.active AND x.prefix IS NOT NULL AND s.network <<= x.prefix);

ANALYZE dma_ip_export;
