-- range2zip.sql - assign ZIP codes to IP ranges by last-carrier-node match.
--
-- This is the point of the pipeline. Two independent traces, matched at the
-- node:
--
--   LANDMARK side   a landmark address whose ZIP we KNOW, traced to its last
--                   carrier node.
--   RANGE side      a dbip prefix whose ZIP we do NOT know, traced to its last
--                   carrier node.
--
-- Same node means the two sit behind the same piece of carrier equipment, so
-- the landmark's ZIP is evidence about the range. That is the whole inference,
-- and it is node-to-node only: the node HOSTNAME is an identity for matching,
-- never a location. A hostname saying "brockton" tells us where the router is,
-- not where the subscriber is, which is why West Roxbury is served through
-- Brockton.
--
-- A RANGE CAN SERVE MANY ZIPS, and the table is keyed (network, zip) to say so.
-- One row per (range, ZIP) pair, because a node that serves a cluster of
-- adjacent ZIPs genuinely serves all of them and picking one would be a
-- fabrication. zips_at_range records the multiplicity on every row.
--
-- NOTHING IS SILENTLY DISCARDED. Matches through a node that fans out across
-- DISJOINT ZIP clusters are still written, tagged 'disjoint', because a range
-- behind a node spanning 36 unconnected areas is not located by that match.
-- They are kept for audit and excluded by the usable view, rather than dropped
-- where the loss would be invisible.
--
-- PREREQUISITES
--   landmarks_usa            migrate_into_landmarks_usa.sql, chain run
--   ovt_places_usa_ip_trace  landmark-side traces
--   ip2city_dbiplite_traceroute_tbl  range-side traces
--   zip_clusters(), zip_adj_sym      created by node_fanout.sql

DROP TABLE IF EXISTS range2zip_tbl CASCADE;

-- ---------------------------------------------------------------------------
-- 1. LANDMARK SIDE. Every on-premises landmark that reached a carrier node,
--    with the ZIP we know it to be in.
--
--    self_trace rows are excluded: a trace whose last hop IS the traced
--    address never left the building and identifies no carrier equipment.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE lm_node AS
SELECT host(t.last_hop_ip)                                        AS node_ip,
       lower(nullif(btrim(coalesce(t.last_hop_hostname, '')), '')) AS node_host,
       l.overture_zip                                             AS zip,
       t.mobile_transit                                           AS lm_tier,
       l.source                                                   AS lm_source
FROM landmarks_usa l
JOIN ovt_places_usa_ip_trace t ON t.ip = l.ip_address
WHERE l.onpremises IS TRUE
  AND l.overture_zip ~ '^[0-9]{5}$'
  AND t.status LIKE 'reached%'
  AND t.last_hop_ip IS NOT NULL
  AND host(t.last_hop_ip) <> host(l.ip_address)
GROUP BY 1, 2, 3, 4, 5;

CREATE INDEX ON lm_node (node_ip);
CREATE INDEX ON lm_node (node_host);

-- ---------------------------------------------------------------------------
-- 2. RANGE SIDE.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE rg_node AS
SELECT r.network,
       host(r.last_hop_ip)                                        AS node_ip,
       lower(nullif(btrim(coalesce(r.last_hop_hostname, '')), '')) AS node_host,
       r.mobile_transit                                           AS rg_tier
FROM ip2city_dbiplite_traceroute_tbl r
WHERE r.status LIKE 'reached%'
  AND r.last_hop_ip IS NOT NULL
GROUP BY 1, 2, 3, 4;

CREATE INDEX ON rg_node (node_ip);
CREATE INDEX ON rg_node (node_host);

-- ---------------------------------------------------------------------------
-- 3. MATCH. Node IP is the strong match. Hostname is the fallback, for when
--    the two traces ended on different interfaces of the SAME router, which is
--    common: a router answers with whichever interface faced the probe.
--    Hostname equality still means one device, so it is a real match, but it
--    is recorded as the weaker of the two.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE matched AS
SELECT r.network, l.zip, r.node_ip, l.node_host,
       'node_ip'::text AS match_method, l.lm_tier, r.rg_tier, l.lm_source
FROM rg_node r
JOIN lm_node l ON l.node_ip = r.node_ip
UNION
SELECT r.network, l.zip, r.node_ip, l.node_host,
       'node_hostname', l.lm_tier, r.rg_tier, l.lm_source
FROM rg_node r
JOIN lm_node l ON l.node_host = r.node_host
WHERE r.node_host IS NOT NULL
  AND l.node_ip <> r.node_ip;

-- ---------------------------------------------------------------------------
-- 4. CLUSTER the ZIP set each range picked up, so adjacency decides whether
--    the multiplicity is one neighbourhood or several unconnected places.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE rng_cl AS
SELECT * FROM zip_clusters(
    (SELECT array_agg(network::text) FROM (SELECT DISTINCT network, zip FROM matched) x),
    (SELECT array_agg(zip)           FROM (SELECT DISTINCT network, zip FROM matched) x), 40);

-- ---------------------------------------------------------------------------
-- 5. THE TABLE.
-- ---------------------------------------------------------------------------

CREATE TABLE range2zip_tbl AS
WITH agg AS (
    SELECT m.network, m.zip,
           min(m.match_method)                       AS match_method,
           count(DISTINCT m.node_ip)                 AS nodes_matched,
           min(m.node_host)                          AS node_hostname,
           -- Mobile wins over transit where both apply, the standing rule.
           CASE WHEN 'm' = ANY(array_agg(m.lm_tier) || array_agg(m.rg_tier)) THEN 'm'
                WHEN 't' = ANY(array_agg(m.lm_tier) || array_agg(m.rg_tier)) THEN 't'
                WHEN 'f' = ANY(array_agg(m.lm_tier) || array_agg(m.rg_tier)) THEN 'f'
                END                                   AS mobile_transit,
           string_agg(DISTINCT m.lm_source, ',')      AS landmark_sources
    FROM matched m
    GROUP BY 1, 2
)
SELECT a.network::cidr                                AS network,
       a.zip,
       a.match_method,
       a.nodes_matched,
       a.node_hostname,
       a.mobile_transit,
       a.landmark_sources,
       c.zips                                         AS zips_at_range,
       c.clusters                                     AS clusters_at_range,
       c.too_wide,
       CASE WHEN c.too_wide     THEN 'disjoint: too wide to cluster'
            WHEN c.clusters > 1 THEN 'disjoint: ' || c.clusters || ' areas'
            WHEN c.zips = 1     THEN 'zip: single'
            ELSE 'zip: one contiguous area of ' || c.zips END  AS verdict
FROM agg a
JOIN rng_cl c ON c.grp = a.network::text;

CREATE INDEX ON range2zip_tbl (network);
CREATE INDEX ON range2zip_tbl (zip);
CREATE UNIQUE INDEX ON range2zip_tbl (network, zip);

COMMENT ON TABLE range2zip_tbl IS
    'ZIP codes assigned to IP ranges by last-carrier-node match between a landmark of known ZIP and a range of unknown ZIP. Keyed (network, zip): a range can serve many ZIPs. verdict zip means the ZIPs form one contiguous area; disjoint means the match does not locate the range and is kept only for audit.';

-- Usable assignments only. Disjoint matches are excluded here rather than
-- deleted above, so the exclusion is visible and reversible.
CREATE OR REPLACE VIEW range2zip_usable_v AS
SELECT * FROM range2zip_tbl WHERE verdict LIKE 'zip:%';


-- ---------------------------------------------------------------------------
-- REPORT
-- ---------------------------------------------------------------------------

SELECT '=== 1. INPUTS ===' AS section;

SELECT (SELECT count(*) FROM lm_node)                       AS landmark_node_pairs,
       (SELECT count(DISTINCT node_ip) FROM lm_node)        AS distinct_landmark_nodes,
       (SELECT count(*) FROM rg_node)                       AS range_node_pairs,
       (SELECT count(DISTINCT node_ip) FROM rg_node)        AS distinct_range_nodes,
       (SELECT count(DISTINCT node_ip) FROM lm_node
        WHERE node_ip IN (SELECT node_ip FROM rg_node))     AS nodes_on_both_sides;

SELECT '=== 2. VERDICT. zip rows are usable, disjoint rows are not. ===' AS section;

SELECT verdict,
       count(*)                                             AS range_zip_pairs,
       count(DISTINCT network)                              AS ranges,
       count(DISTINCT zip)                                  AS zips
FROM range2zip_tbl
GROUP BY 1
ORDER BY 2 DESC;

SELECT '=== 3. HOW MANY ZIPS DOES A USABLE RANGE SERVE ===' AS section;

SELECT zips_at_range                                        AS zips_served,
       count(DISTINCT network)                              AS ranges
FROM range2zip_usable_v
GROUP BY 1
ORDER BY 1
LIMIT 20;

SELECT '=== 4. MATCH METHOD AND ACCURACY TIER ===' AS section;

SELECT match_method,
       coalesce(mobile_transit, 'unclassified')              AS tier,
       count(*)                                             AS range_zip_pairs,
       count(DISTINCT network)                              AS ranges
FROM range2zip_usable_v
GROUP BY 1, 2
ORDER BY 3 DESC;

SELECT '=== 5. COVERAGE DELIVERED ===' AS section;

SELECT count(DISTINCT network)                              AS ranges_located,
       count(DISTINCT zip)                                  AS zips_reached,
       round(avg(zips_at_range), 2)                         AS mean_zips_per_range
FROM range2zip_usable_v;
