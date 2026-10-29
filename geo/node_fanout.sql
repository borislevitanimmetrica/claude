-- node_fanout.sql
--
-- How wide is a last carrier node, measured in ZIP CLUSTERS rather than ZIPs,
-- and is an address a shared host because it spans clusters that do not touch?
--
-- WHY CLUSTERS AND NOT ZIPS
--
-- A raw count of distinct ZIPs cannot tell a multi-site business from a web
-- host, and cannot tell a node serving one neighbourhood from a node serving
-- two distant towns. A hospital with clinics spans several ZIPs that BORDER one
-- another; a web host spans ZIPs on opposite sides of the country. The number
-- that distinguishes them is the number of connected components in the ZIP
-- adjacency graph restricted to the ZIPs in question. One component means one
-- contiguous area however many ZIPs it contains. Two or more disjoint
-- components mean two or more places.
--
-- This replaces two cruder rules:
--
--   The ZIP-count fan-out guard in landmark_carrier_node.sql section 5, which
--   rejected a node serving 3 adjacent ZIPs exactly as harshly as one serving 3
--   ZIPs in 3 states.
--
--   The registrant-name provider list, for the hosting test. A name list can
--   only catch hosts someone has already researched; a disjoint-cluster test
--   catches any address that behaves like a host regardless of who registered
--   it. See the limits section below for where the name list is still needed.
--
-- WHY THE EARLIER "COMCAST IS NEARLY ZIP-SPECIFIC" CLAIM WAS NOT EVIDENCE
--
-- Section 4b of landmark_carrier_node.sql reported comcast.net at 14 router IPs
-- with 16 landmark addresses, mean 1.14 ZIPs per node, 13 of 14 nodes serving
-- exactly one ZIP. That is 1.14 landmarks per router. With about one landmark
-- behind each router, a node CANNOT show more than one ZIP whatever its true
-- breadth, so the statistic was saturated by sample size and measured nothing.
-- Cogent fared slightly better at 5.9 landmarks per router, but its 89
-- addresses are dominated by a few universities each occupying one ZIP, so that
-- is weak too.
--
-- The counter-evidence is concrete and goes the other way: Comcast serves West
-- Roxbury through a Brockton node about an hour away, and Lynn through a Woburn
-- node. Both are single nodes spanning demographically unlike areas, and both
-- would appear only once many landmarks across many towns sit behind one node.
--
-- A RELATED ERROR IN HOW THE HOSTNAME WAS READ. A node named
-- po-1-rur201.westroxbury.ma.boston.comcast.net records where the ROUTER is,
-- not where the subscriber is. Treating the town in the name as the subscriber's
-- town is exactly the mistake the Brockton example refutes. The hostname is an
-- identity for matching and nothing more; the ZIP must come from the landmark's
-- own Overture address, which is what section 5 assigns. The design was right
-- and the commentary around it was wrong.
--
-- So every query here reports LANDMARKS PER NODE beside the fan-out, because a
-- fan-out figure computed from one landmark is not a measurement.
--
-- Prerequisites: ovt_places_usa_ip_trace populated, zip_adjacency, and
-- landmarks_usa with onpremises set.
--
-- Reads landmarks_usa, not ovt_places_usa, so the fan-out measurement and
-- address_hosting_tbl cover EVERY source rather than Overture alone. The trace
-- table keeps its ovt_ name: it is keyed on ip and is still the only
-- landmark-side trace store, whatever source the landmark came from.
--
-- Contains NO backslashes so it survives copy/paste.


-- ---------------------------------------------------------------------------
-- 1. THE ADJACENCY GRAPH, symmetric. zip_adjacency stores each pair one way
-- round only and the ZIPs may be numeric, so both are fixed here once.
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS zip_adj_sym CASCADE;

CREATE VIEW zip_adj_sym AS
SELECT left(lpad(btrim(zip_a::text), 5, '0'), 5) AS a,
       left(lpad(btrim(zip_b::text), 5, '0'), 5) AS b FROM zip_adjacency
UNION
SELECT left(lpad(btrim(zip_b::text), 5, '0'), 5),
       left(lpad(btrim(zip_a::text), 5, '0'), 5) FROM zip_adjacency;

COMMENT ON VIEW zip_adj_sym IS
    'zip_adjacency made symmetric and padded to five characters. zip_adjacency holds each adjacent pair once, in one direction, so a containment test against it alone silently misses half the graph.';


-- ---------------------------------------------------------------------------
-- 2. CLUSTER COUNTING. Given any grouping of ZIPs, how many disjoint
-- contiguous areas do they form?
--
-- Implemented as label propagation in a recursive CTE: every ZIP starts
-- labelled with itself, labels spread along adjacency edges WITHIN a group, and
-- the minimum label a ZIP can reach identifies its component. The count of
-- distinct minima per group is the number of components.
--
-- Bounded deliberately. A group with k ZIPs can generate k squared edges, so
-- groups above max_zips are not expanded at all and are reported as
-- 'too wide to cluster'. A node serving more ZIPs than that is disqualified on
-- any reading, so computing its exact component count would buy nothing and
-- the recursion could run away.
--
-- Defined as a function so the node test and the address test share one
-- implementation and cannot drift apart.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION zip_clusters(member_key text[], member_zip text[],
                                        max_zips integer DEFAULT 40)
RETURNS TABLE (grp text, zips integer, clusters integer, too_wide boolean)
LANGUAGE sql STABLE AS $$
WITH RECURSIVE
g AS (
    SELECT DISTINCT k AS grp, z AS zip
    FROM unnest(member_key, member_zip) AS u(k, z)
    WHERE z ~ '^[0-9]{5}$'
),
sized AS (
    SELECT grp, count(*) AS n FROM g GROUP BY 1
),
small AS (
    SELECT g.grp, g.zip FROM g JOIN sized s ON s.grp = g.grp WHERE s.n <= max_zips
),
e AS (
    SELECT p.grp, p.zip AS z1, q.zip AS z2
    FROM small p
    JOIN small q ON q.grp = p.grp AND q.zip <> p.zip
    JOIN zip_adj_sym adj ON adj.a = p.zip AND adj.b = q.zip
),
lab AS (
    SELECT grp, zip, zip AS label FROM small
    UNION
    SELECT e.grp, e.z2, l.label
    FROM lab l
    JOIN e ON e.grp = l.grp AND e.z1 = l.zip
),
comp AS (
    SELECT grp, zip, min(label) AS component FROM lab GROUP BY 1, 2
)
SELECT s.grp,
       s.n::integer,
       (SELECT count(DISTINCT c.component)::integer FROM comp c WHERE c.grp = s.grp),
       s.n > max_zips
FROM sized s;
$$;

COMMENT ON FUNCTION zip_clusters(text[], text[], integer) IS
    'Number of disjoint contiguous ZIP areas per group. One cluster means one contiguous area however many ZIPs; two or more means two or more separate places, which is what distinguishes a multi-site business from a web host, and a neighbourhood node from one spanning distant towns. Groups wider than max_zips are returned with too_wide true and clusters NULL rather than expanded.';


-- ---------------------------------------------------------------------------
-- 3. NODE FAN-OUT, the measurement that was asked for.
--
-- Reported per node with landmarks_at_node alongside, because a fan-out of 1
-- computed from 1 landmark is not a measurement. Read the two columns together:
-- only rows with several landmarks say anything, and a node with one landmark
-- is listed as unmeasured rather than as clean.
--
-- A node whose landmarks form ONE cluster is available for ZIP-level
-- targeting, including a transit node. A narrow transit node carries
-- institutional housing and at-work media use, which is biddable, so there is
-- no reason to hold it at DMA merely because the operator is a transit
-- provider. Width, not operator identity, is the test.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS node_fanout_tbl;

CREATE TABLE node_fanout_tbl AS
WITH addr AS (
    SELECT t.ip,
           t.last_hop_ip,
           t.last_hop_hostname,
           t.mobile_transit,
           min(p.overture_zip)                                       AS zip,
           count(DISTINCT p.overture_zip)                            AS zips_at_addr
    FROM ovt_places_usa_ip_trace t
    JOIN landmarks_usa p ON p.ip_address = t.ip
    WHERE t.status LIKE 'reached%'
      AND t.last_hop_ip IS NOT NULL
      AND p.onpremises = true
      AND p.overture_zip ~ '^[0-9]{5}$'
    GROUP BY 1, 2, 3, 4
),
unambiguous AS (
    SELECT * FROM addr WHERE zips_at_addr = 1
),
agg AS (
    SELECT host(last_hop_ip)                                          AS node,
           min(last_hop_hostname)                                     AS node_hostname,
           min(mobile_transit)                                        AS tier,
           count(DISTINCT ip)                                         AS landmarks_at_node,
           array_agg(zip)                                             AS zips
    FROM unambiguous
    GROUP BY 1
),
flat AS (
    SELECT node, unnest(zips) AS zip FROM agg
),
cl AS (
    SELECT * FROM zip_clusters(
        (SELECT array_agg(node) FROM flat),
        (SELECT array_agg(zip)  FROM flat), 40)
)
SELECT a.node::inet                                                   AS node_ip,
       a.node_hostname,
       a.tier,
       a.landmarks_at_node,
       cl.zips                                                        AS zips_at_node,
       cl.clusters                                                    AS clusters_at_node,
       cl.too_wide,
       CASE WHEN a.landmarks_at_node < 3        THEN 'unmeasured: too few landmarks'
            WHEN cl.too_wide                    THEN 'reject: too wide to cluster'
            WHEN cl.clusters = 1                THEN 'zip-level: one contiguous area'
            ELSE 'reject: ' || cl.clusters || ' disjoint areas' END   AS verdict
FROM agg a
JOIN cl ON cl.grp = a.node;

CREATE INDEX ON node_fanout_tbl (node_ip);

COMMENT ON TABLE node_fanout_tbl IS
    'Fan-out of each last carrier node, in disjoint ZIP clusters rather than raw ZIP count, with landmarks_at_node beside it because a fan-out computed from one or two landmarks measures sample size and not the node. Verdict zip-level means the node is available for ZIP targeting whatever its operator, transit included.';


-- The report. Nodes that FAIL, which is what was asked for, worst first.

SELECT node_ip, node_hostname, tier, landmarks_at_node, zips_at_node,
       clusters_at_node, verdict
FROM node_fanout_tbl
WHERE verdict LIKE 'reject%'
ORDER BY clusters_at_node DESC NULLS FIRST, zips_at_node DESC
LIMIT 60;


-- The summary, which is the honest picture of how much this data can support.

SELECT verdict,
       count(*)                                                       AS nodes,
       sum(landmarks_at_node)                                         AS landmarks,
       round(100.0 * sum(landmarks_at_node)
             / sum(sum(landmarks_at_node)) OVER (), 1)                AS pct_landmarks
FROM node_fanout_tbl
GROUP BY 1
ORDER BY 3 DESC;


-- Per operator, with the power of the statistic visible. Read
-- mean_landmarks_per_node first: below about 3 the fan-out columns are noise.

SELECT coalesce(reverse(split_part(reverse(node_hostname), '.', 2)) || '.'
                || reverse(split_part(reverse(node_hostname), '.', 1)),
                'unnamed')                                            AS node_domain,
       count(*)                                                       AS nodes,
       sum(landmarks_at_node)                                         AS landmarks,
       round(avg(landmarks_at_node), 2)                               AS mean_landmarks_per_node,
       count(*) FILTER (WHERE landmarks_at_node >= 3)                 AS nodes_with_enough_landmarks,
       count(*) FILTER (WHERE landmarks_at_node >= 3 AND clusters_at_node = 1)
                                                                      AS of_those_one_cluster,
       max(clusters_at_node)                                          AS worst_clusters
FROM node_fanout_tbl
GROUP BY 1
ORDER BY 3 DESC;


-- ---------------------------------------------------------------------------
-- 4. THE BROCKTON TEST. Does any node span ZIPs that are far apart?
--
-- Clusters alone do not say HOW far apart the disjoint areas are, and the
-- concrete worry is a node serving West Roxbury and Brockton, about an hour
-- apart with unlike demographics. Distance needs coordinates, and the probe
-- table carries lat and lon per range from db-ip, so the ZIP centroid is
-- approximated by averaging the coordinates of the ranges whose zip matches.
--
-- Approximate, and labelled so. It is a screen for the pathological case, not
-- a distance measurement. A node flagged here should be looked at by hand.
-- ---------------------------------------------------------------------------

WITH zip_pt AS (
    SELECT zip,
           avg(lat)                                                   AS lat,
           avg(lon)                                                   AS lon
    FROM ip2city_dbiplite_probe_tbl
    WHERE zip ~ '^[0-9]{5}$' AND lat IS NOT NULL AND lon IS NOT NULL
    GROUP BY 1
),
node_zip AS (
    SELECT DISTINCT host(t.last_hop_ip) AS node, t.last_hop_hostname, p.overture_zip AS zip
    FROM ovt_places_usa_ip_trace t
    JOIN landmarks_usa p ON p.ip_address = t.ip
    WHERE t.status LIKE 'reached%'
      AND t.last_hop_ip IS NOT NULL
      AND p.onpremises = true
      AND p.overture_zip ~ '^[0-9]{5}$'
),
pairs AS (
    SELECT n1.node,
           n1.last_hop_hostname,
           n1.zip                                                     AS zip_a,
           n2.zip                                                     AS zip_b,
           -- great-circle distance in miles, spherical earth
           3958.8 * acos(least(1.0, greatest(-1.0,
               sin(radians(p1.lat)) * sin(radians(p2.lat))
             + cos(radians(p1.lat)) * cos(radians(p2.lat))
             * cos(radians(p1.lon - p2.lon)))))                       AS miles
    FROM node_zip n1
    JOIN node_zip n2 ON n2.node = n1.node AND n2.zip > n1.zip
    JOIN zip_pt p1 ON p1.zip = n1.zip
    JOIN zip_pt p2 ON p2.zip = n2.zip
)
SELECT node,
       last_hop_hostname,
       count(*)                                                       AS zip_pairs,
       round(max(miles))                                              AS widest_miles,
       (array_agg(zip_a || ' to ' || zip_b || ' ' || round(miles) || 'mi'
                  ORDER BY miles DESC))[1:3]                          AS widest_examples
FROM pairs
GROUP BY 1, 2
HAVING max(miles) > 15
ORDER BY 4 DESC
LIMIT 40;


-- ---------------------------------------------------------------------------
-- 5. HOSTING BY DISJOINT CLUSTER, replacing the ZIP-count rule.
--
-- An address whose landmark places occupy more than one cluster that do not
-- border each other is a shared host, whoever registered it. This catches hosts
-- that no name list knows about, and it correctly spares a multi-site business
-- whose sites are contiguous.
--
-- WHERE IT CANNOT REPLACE THE NAME LIST, which matters before provider_names is
-- retired. The test needs at least two landmarks at an address to see any
-- spread at all. A CDN or cloud address carrying exactly ONE landmark is
-- invisible to it and will pass as on-premises. On the 312-address Massachusetts
-- pass most provider addresses carried many places, so the test would have
-- caught them, but that is a property of that sample rather than a guarantee.
-- The two are complementary: the name list covers the known single-landmark
-- case, this covers the unknown multi-landmark case.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS address_hosting_tbl;

CREATE TABLE address_hosting_tbl AS
WITH addr_zip AS (
    SELECT host(p.ip_address)                                         AS addr,
           p.overture_zip                                             AS zip
    FROM landmarks_usa p
    WHERE p.onpremises = true
      AND p.ip_address IS NOT NULL
      AND p.overture_zip ~ '^[0-9]{5}$'
    GROUP BY 1, 2
),
cl AS (
    SELECT * FROM zip_clusters(
        (SELECT array_agg(addr) FROM addr_zip),
        (SELECT array_agg(zip)  FROM addr_zip), 40)
)
SELECT cl.grp::inet                                                   AS ip_address,
       cl.zips                                                        AS zips_at_address,
       cl.clusters                                                    AS clusters_at_address,
       cl.too_wide,
       (SELECT count(*) FROM landmarks_usa p
        WHERE p.ip_address = cl.grp::inet AND p.onpremises = true)     AS places,
       (SELECT min(p.registrant_1) FROM landmarks_usa p
        WHERE p.ip_address = cl.grp::inet)                            AS registrant,
       CASE WHEN cl.too_wide          THEN 'hosting: too wide to cluster'
            WHEN cl.clusters > 1      THEN 'hosting: ' || cl.clusters || ' disjoint areas'
            WHEN cl.zips = 1          THEN 'on-premises: single zip'
            ELSE 'on-premises: one contiguous area' END                AS verdict
FROM cl;

CREATE INDEX ON address_hosting_tbl (ip_address);

COMMENT ON TABLE address_hosting_tbl IS
    'Whether an address behaves like a shared web host, decided by whether its landmark places occupy more than one NON-ADJACENT ZIP cluster rather than by a registrant name. Catches hosts no name list knows about and spares a multi-site business whose sites are contiguous. Blind to a provider address carrying only one landmark, which is why provider_names is still needed.';


SELECT verdict, count(*) AS addresses, sum(places) AS places
FROM address_hosting_tbl
GROUP BY 1
ORDER BY 2 DESC;


-- The worst offenders, which is the candidate hosting list. Compare the
-- registrant column against isp_names: an ISP appearing here is an ISP selling
-- web hosting, which rule 3a admits unconditionally and should not.

SELECT ip_address, zips_at_address, clusters_at_address, places, registrant, verdict
FROM address_hosting_tbl
WHERE verdict LIKE 'hosting%'
ORDER BY clusters_at_address DESC NULLS FIRST, zips_at_address DESC
LIMIT 40;


-- How many of those sit behind a registrant that is in isp_names, which sizes
-- the rule 3a hole directly.

SELECT count(*)                                                       AS hosting_addresses,
       count(*) FILTER (WHERE lower(btrim(h.registrant))
                              IN (SELECT lower(btrim(name)) FROM isp_names))
                                                                      AS registrant_is_an_isp,
       count(*) FILTER (WHERE lower(btrim(h.registrant))
                              IN (SELECT lower(btrim(name)) FROM provider_names))
                                                                      AS already_a_known_provider
FROM address_hosting_tbl h
WHERE h.verdict LIKE 'hosting%';
