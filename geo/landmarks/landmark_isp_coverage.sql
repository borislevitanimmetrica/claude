-- landmark_isp_coverage.sql
--
-- Coverage measured in ZIP-and-ISP pairs rather than in ZIPs.
--
-- WHY THE DENOMINATOR IS NOT ZIP CODES
--
-- Every coverage figure this project has reported counts ZIPs: 9,728 covered
-- against roughly 41,700. That denominator is wrong, and wrong in the
-- optimistic direction.
--
-- A landmark yields a ZIP for one carrier's access network, because the method
-- is node-to-node: mtr the landmark, keep the last carrier node before the
-- customer equipment, and label ranges whose node is the SAME node. That node
-- belongs to one ISP. Most ZIPs are served by several ISPs, and a landmark on
-- one of them says nothing about the others. A ZIP with a cable incumbent, a
-- telco and a fixed-wireless operator needs THREE landmarks, not one, and
-- counting it as covered after the first overstates reach by the number of
-- carriers we have not reached.
--
-- So the real denominator is the set of (ZIP, ISP) pairs that actually carry
-- addresses, and the real numerator is the pairs where a landmark exists on
-- that ISP in that ZIP.
--
-- WHAT THIS CANNOT DECIDE, AND SAYS SO RATHER THAN GUESSING
--
-- Some ISPs in a ZIP sell dedicated or private access only. Their addresses
-- never appear in a consumer bid request, so a missing landmark on them costs
-- nothing, and counting them in the denominator would understate coverage the
-- way counting only ZIPs overstates it. RDAP cannot tell them apart: it
-- returns the registrant of an allocation, not what the allocation is sold as.
--
-- This query therefore does NOT classify them. It ranks every uncovered pair
-- by how many addresses the ISP holds in that ZIP, because that is the
-- available evidence: an ISP with one small range in a ZIP is a plausible
-- dedicated-access operator, and one with tens of thousands of addresses is
-- not. The judgement is the operator's and the ranking is what makes it
-- cheap.
--
-- READ ONLY. Every statement is a SELECT. Nothing here writes, locks or
-- changes a row.

\timing on

-- ---------------------------------------------------------------------------
-- 0. What the tables actually contain.
--
-- Printed first because the ZIP-to-city mapping lives in city2zip_tbl and this
-- file does NOT join to it: its column names were not verified when this was
-- written, and a join written against assumed names would silently produce a
-- wrong denominator rather than an error. Section 6 measures the same thing at
-- city level, which needs no such join. Run this section, then the join can be
-- written against the real names.
-- ---------------------------------------------------------------------------
SELECT table_name, ordinal_position AS pos, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('city2zip_tbl', 'ip2city_dbiplite_probe_tbl',
                     'rdap_registrant', 'landmarks_usa')
  AND (table_name <> 'landmarks_usa'
       OR column_name IN ('overture_zip', 'registrant_1', 'registrant_2',
                          'onpremises', 'ip_address', 'ip_last_carrier_node'))
ORDER BY table_name, ordinal_position;

-- ---------------------------------------------------------------------------
-- 1. SUPPLY. The (ZIP, ISP) pairs a landmark actually gives us.
--
-- registrant_1 is the RDAP registrant of the landmark's own address, which is
-- the ISP whose access network the landmark sits on. That is the pair the
-- node-to-node method can label.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE supply_pairs AS
SELECT DISTINCT
       left(lpad(btrim(overture_zip), 5, '0'), 5) AS zip,
       btrim(registrant_1)                        AS isp
FROM landmarks_usa
WHERE onpremises
  AND overture_zip IS NOT NULL
  AND btrim(coalesce(registrant_1, '')) <> '';

SELECT count(*)                AS supply_pairs,
       count(DISTINCT zip)     AS zips_with_any_landmark,
       count(DISTINCT isp)     AS isps_with_any_landmark
FROM supply_pairs;

-- ---------------------------------------------------------------------------
-- 2. DEMAND. The (ZIP, ISP) pairs that carry addresses.
--
-- The containment join is on start_ip and end_ip rather than on a cidr because
-- an RDAP allocation is not required to be a single CIDR block, which is why
-- rdap_registrant stores boundaries. The probe range's first address is used as
-- the probe point into the allocation.
--
-- Ranges with no ZIP are counted separately rather than dropped silently: the
-- probe table's ZIP is known to be sparse, and a denominator built only from
-- rows that happen to have one would be a different population from the one
-- the percentages below are about.
-- ---------------------------------------------------------------------------
SELECT count(*)                                              AS probe_ranges,
       count(*) FILTER (WHERE btrim(coalesce(zip, '')) <> '') AS with_zip,
       count(*) FILTER (WHERE btrim(coalesce(zip, '')) =  '') AS without_zip,
       round(100.0 * count(*) FILTER (WHERE btrim(coalesce(zip, '')) <> '')
             / greatest(count(*), 1), 1)                      AS pct_with_zip
FROM ip2city_dbiplite_probe_tbl;

CREATE TEMP TABLE demand_pairs AS
SELECT left(lpad(btrim(p.zip), 5, '0'), 5)  AS zip,
       btrim(r.registrant)                  AS isp,
       count(*)                             AS ranges,
       sum((2::numeric) ^ (32 - masklen(p.network))) AS addresses
FROM ip2city_dbiplite_probe_tbl p
JOIN rdap_registrant r
  ON inet(host(network(p.network))) BETWEEN r.start_ip AND r.end_ip
WHERE btrim(coalesce(p.zip, '')) <> ''
  AND btrim(coalesce(r.registrant, '')) <> ''
GROUP BY 1, 2;

CREATE INDEX ON demand_pairs (zip, isp);
ANALYZE demand_pairs;

SELECT count(*)            AS demand_pairs,
       count(DISTINCT zip) AS zips_with_addresses,
       count(DISTINCT isp) AS isps_serving_anywhere
FROM demand_pairs;

-- ---------------------------------------------------------------------------
-- 3. THE NUMBER THIS FILE EXISTS FOR.
--
-- Covered means a landmark exists on that ISP in that ZIP. Compare the
-- pair-level percentage with the ZIP-level one directly beneath it: the gap
-- between them is the amount by which counting ZIPs has been overstating
-- reach.
-- ---------------------------------------------------------------------------
SELECT count(*)                                        AS demand_pairs,
       count(*) FILTER (WHERE s.zip IS NOT NULL)        AS covered_pairs,
       count(*) FILTER (WHERE s.zip IS NULL)            AS uncovered_pairs,
       round(100.0 * count(*) FILTER (WHERE s.zip IS NOT NULL)
             / greatest(count(*), 1), 2)                AS pct_pairs_covered
FROM demand_pairs d
LEFT JOIN supply_pairs s ON s.zip = d.zip AND s.isp = d.isp;

SELECT count(DISTINCT d.zip)                                     AS zips_with_addresses,
       count(DISTINCT d.zip) FILTER (WHERE s.zip IS NOT NULL)    AS zips_with_any_landmark,
       round(100.0 * count(DISTINCT d.zip) FILTER (WHERE s.zip IS NOT NULL)
             / greatest(count(DISTINCT d.zip), 1), 2)            AS pct_zips_covered
FROM demand_pairs d
LEFT JOIN supply_pairs s ON s.zip = d.zip;

-- ---------------------------------------------------------------------------
-- 4. HOW MANY ISPs PER ZIP, which is the multiplier on the work remaining.
-- ---------------------------------------------------------------------------
SELECT isps_in_zip,
       count(*)      AS zips,
       sum(isps_in_zip) AS pairs_those_zips_need
FROM (SELECT zip, count(DISTINCT isp) AS isps_in_zip
      FROM demand_pairs GROUP BY 1) z
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 5. THE UNCOVERED PAIRS THAT MATTER MOST, ranked by addresses.
--
-- This is the work queue. A large address count means a lot of potential bid
-- requests behind one missing landmark. A small one is plausibly a dedicated
-- or private access allocation that no landmark would ever help, which is the
-- judgement RDAP cannot make for us.
-- ---------------------------------------------------------------------------
SELECT d.isp,
       count(*)              AS uncovered_zips,
       sum(d.ranges)         AS ranges,
       sum(d.addresses)::bigint AS addresses
FROM demand_pairs d
LEFT JOIN supply_pairs s ON s.zip = d.zip AND s.isp = d.isp
WHERE s.zip IS NULL
GROUP BY 1
ORDER BY addresses DESC
LIMIT 40;

SELECT d.zip,
       d.isp,
       d.ranges,
       d.addresses::bigint AS addresses
FROM demand_pairs d
LEFT JOIN supply_pairs s ON s.zip = d.zip AND s.isp = d.isp
WHERE s.zip IS NULL
ORDER BY d.addresses DESC
LIMIT 40;

-- ---------------------------------------------------------------------------
-- 6. THE SAME MEASUREMENT AT CITY LEVEL, which needs no ZIP mapping.
--
-- The probe table's ZIP is sparse, so sections 2 to 5 describe only the subset
-- of ranges carrying one. City and state_code are populated for every probed
-- range, so this is the same question asked over the whole table, and the two
-- answers bracket the truth.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE demand_city AS
SELECT btrim(p.city)       AS city,
       btrim(p.state_code) AS state_code,
       btrim(r.registrant) AS isp,
       count(*)            AS ranges,
       sum((2::numeric) ^ (32 - masklen(p.network))) AS addresses
FROM ip2city_dbiplite_probe_tbl p
JOIN rdap_registrant r
  ON inet(host(network(p.network))) BETWEEN r.start_ip AND r.end_ip
WHERE btrim(coalesce(p.city, '')) <> ''
  AND btrim(coalesce(r.registrant, '')) <> ''
GROUP BY 1, 2, 3;

SELECT count(*)                                  AS city_isp_pairs,
       count(DISTINCT (city, state_code))        AS cities,
       round(count(*)::numeric
             / greatest(count(DISTINCT (city, state_code)), 1), 2)
                                                 AS mean_isps_per_city
FROM demand_city;

SELECT isps_in_city, count(*) AS cities
FROM (SELECT city, state_code, count(DISTINCT isp) AS isps_in_city
      FROM demand_city GROUP BY 1, 2) c
GROUP BY 1
ORDER BY 1
LIMIT 25;

DROP TABLE IF EXISTS supply_pairs;
DROP TABLE IF EXISTS demand_pairs;
DROP TABLE IF EXISTS demand_city;

\timing off
