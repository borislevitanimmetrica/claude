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

-- TWO CORRECTIONS AFTER THE FIRST RUN
--
-- The table is rdap_registrant_tbl. The first version of this file said
-- rdap_registrant, which is the FILENAME, not the relation, and every section
-- from 2 onward failed with "relation does not exist". Taking a table name from
-- a filename is guessing, and the DDL was in the repository the whole time.
--
-- The containment join is now a LATERAL taking the MOST SPECIFIC allocation,
-- not a BETWEEN join. RDAP allocations NEST: ARIN publishes reassignments and
-- reallocations beneath a parent, so a /8 and a /16 inside it both contain the
-- same address and a BETWEEN join returns a row for each. That would have
-- multiplied the demand pairs by the nesting depth and inflated the
-- denominator, which is a wrong answer rather than an error. Ordering by
-- start_ip DESC and taking one row uses the (start_ip, end_ip) index and
-- returns the narrowest containing allocation, which is the operator.

-- ---------------------------------------------------------------------------
-- 0a. DOES EVERY RELATION THIS FILE NEEDS ACTUALLY EXIST.
--
-- Run first so that a missing one is reported ONCE, here, instead of as ten
-- cascading "relation does not exist" errors from every later section, which
-- is what the first run produced.
--
-- rdap_registrant_tbl is in the repository's DDL and the Session 3 transcript
-- shows it being filled, but I have NOT verified it exists in this database.
-- This is how that gets checked rather than assumed.
-- ---------------------------------------------------------------------------
SELECT r.needed,
       CASE WHEN c.oid IS NULL THEN 'MISSING' ELSE 'present' END AS status,
       CASE WHEN c.oid IS NULL THEN NULL
            ELSE pg_size_pretty(pg_total_relation_size(c.oid)) END AS size
FROM (VALUES ('landmarks_usa'),
             ('ip2city_dbiplite_probe_tbl'),
             ('rdap_registrant_tbl'),
             ('city2zip_tbl')) AS r(needed)
LEFT JOIN pg_class c
       ON c.relname = r.needed
      AND c.relnamespace = 'public'::regnamespace
ORDER BY 2, 1;

-- ---------------------------------------------------------------------------
-- 0b. What the tables actually contain.
--
-- Kept because it is how the two corrections above were found, and because
-- this file still does NOT join to city2zip_tbl. Its real columns are state,
-- state_code, census_placename and zip, so a city-to-ZIP expansion is now
-- possible; it is deliberately not done here because one city maps to many
-- ZIPs and every range in that city would then match all of them, which is the
-- large false-positive expansion the ZIP service design already rejected.
-- ---------------------------------------------------------------------------
SELECT table_name, ordinal_position AS pos, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('city2zip_tbl', 'ip2city_dbiplite_probe_tbl',
                     'rdap_registrant_tbl', 'landmarks_usa')
  AND (table_name <> 'landmarks_usa'
       OR column_name IN ('overture_zip', 'registrant_1', 'registrant_2',
                          'onpremises', 'onpremises_reason', 'ip_address',
                          'ip_last_carrier_node', 'source'))
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

-- 1b. WHY THAT ZIP COUNT MAY NOT BE THE ONE YOU REMEMBER.
--
-- The first run of this file reported 16,114 ZIPs with a landmark. The Session
-- 3 notes record 9,728, measured after node_fanout.sql and
-- onpremises_hosting_rule.sql, and 15,954 measured before them. I do not know
-- which of those this 16,114 is comparable to, and I am not going to assert
-- one. These three breakdowns distinguish the possibilities with data:
--
--   if onpremises_reason is populated on few or no rows, the hosting rule has
--   not been applied to the current set, which the Session 3 notes list as an
--   open item, and 16,114 is a PRE-hosting-rule figure comparable to 15,954
--
--   if it is populated broadly, the rule has run and the set has grown since
--
-- The per-source counts show what has been loaded, which is the other way the
-- number could have moved.
SELECT count(*)                                                   AS onpremises_rows,
       count(*) FILTER (WHERE btrim(coalesce(onpremises_reason,'')) <> '')
                                                                  AS with_reason,
       count(*) FILTER (WHERE btrim(coalesce(onpremises_reason,'')) =  '')
                                                                  AS without_reason
FROM landmarks_usa
WHERE onpremises;

SELECT coalesce(onpremises_reason, '(null)') AS onpremises_reason,
       count(*) AS rows
FROM landmarks_usa
WHERE onpremises
GROUP BY 1
ORDER BY rows DESC
LIMIT 15;

SELECT source,
       count(*)                                        AS rows,
       count(*) FILTER (WHERE onpremises)              AS onpremises_rows,
       count(DISTINCT left(lpad(btrim(overture_zip),5,'0'),5))
         FILTER (WHERE onpremises AND overture_zip IS NOT NULL) AS onprem_zips
FROM landmarks_usa
GROUP BY 1
ORDER BY onpremises_rows DESC;

-- ---------------------------------------------------------------------------
-- 2. DEMAND. The (ZIP, ISP) pairs that carry addresses.
--
-- The containment lookup is on start_ip and end_ip rather than on a cidr
-- because an RDAP allocation is not required to be a single CIDR block, which
-- is why rdap_registrant_tbl stores boundaries. The probe range's first address
-- is the probe point into the allocation.
--
-- IT IS A LATERAL TAKING ONE ROW, NOT A JOIN. RDAP allocations nest, because
-- ARIN publishes reassignments and reallocations beneath a parent, so a /8 and
-- a /16 inside it both contain the same address. A BETWEEN join returns a row
-- for each and would multiply the demand pairs by the nesting depth, inflating
-- the denominator. ORDER BY start_ip DESC LIMIT 1 walks the
-- (start_ip, end_ip) index backwards and stops at the narrowest containing
-- allocation, which is the operator rather than the parent holder.
--
-- The first run measured 2,097,870 probe ranges, of which 1,010,244 carry a
-- ZIP. Expect this to take minutes, not seconds: it is a million index
-- lookups.
--
-- Ranges with no ZIP are counted separately rather than dropped silently,
-- because a denominator built only from rows that happen to have one is a
-- different population from the one the percentages below describe.
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
CROSS JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= (host(network(p.network)))::inet
      AND r.end_ip   >= (host(network(p.network)))::inet
    ORDER BY r.start_ip DESC
    LIMIT 1
) r
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
-- The probe table's ZIP is populated on 1,010,244 of 2,097,870 ranges, so
-- sections 2 to 5 describe only 48.2 percent of the table. This asks the same
-- question over all of it, and the two answers bracket the truth.
--
-- I have NOT verified that city and state_code are populated on every probed
-- range; the first query below reports how many carry them, so the coverage of
-- this section is visible rather than assumed. This is the slowest section:
-- roughly two million index lookups.
-- ---------------------------------------------------------------------------
SELECT count(*)                                                     AS probe_ranges,
       count(*) FILTER (WHERE btrim(coalesce(city, '')) <> '')       AS with_city,
       count(*) FILTER (WHERE btrim(coalesce(state_code, '')) <> '') AS with_state_code
FROM ip2city_dbiplite_probe_tbl;

CREATE TEMP TABLE demand_city AS
SELECT btrim(p.city)       AS city,
       btrim(p.state_code) AS state_code,
       btrim(r.registrant) AS isp,
       count(*)            AS ranges,
       sum((2::numeric) ^ (32 - masklen(p.network))) AS addresses
FROM ip2city_dbiplite_probe_tbl p
CROSS JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= (host(network(p.network)))::inet
      AND r.end_ip   >= (host(network(p.network)))::inet
    ORDER BY r.start_ip DESC
    LIMIT 1
) r
WHERE btrim(coalesce(p.city, '')) <> ''
  AND btrim(coalesce(r.registrant, '')) <> ''
GROUP BY 1, 2, 3;

SELECT count(*)                                  AS city_isp_pairs,
       count(DISTINCT city || '|' || state_code) AS cities,
       round(count(*)::numeric
             / greatest(count(DISTINCT city || '|' || state_code), 1), 2)
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
