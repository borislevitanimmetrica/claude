-- step4_tract_site.sql - step 4 of the plan, and an honest account of what
-- of it can run today.
--
-- STEP 4, IN BORIS'S WORDS
--
--   "Calculate the distance from the nearest headends and COs to the census
--    tract centroid of each census tract in which that carrier offers
--    service."
--
-- Three inputs are needed. Two are ready and one is not.
--
--   READY  the serving sites. node_location_graded carries 3,560 sites at
--          an infrastructure grade: 9 facility, 595 operator_named, 2,947
--          site_subcity, 9 site_subcity_unmeasured. The 1,688 city_fallback
--          points are excluded, being city names rather than sites.
--
--   READY  the tracts a carrier serves. bdc_availability_tbl carries
--          tract_geoid as a STORED GENERATED column, left(block_geoid, 11),
--          with its own index, so the pairing is a scan and an aggregate
--          rather than a computation per row. 519,469,683 rows across 333
--          files.
--
--   READY  the link from an ITDK domain to a BDC carrier, via
--          carrier_resolved_tbl, which applies the 87 rulings Boris gave on
--          2026-11-17. by_decision marks the rows resting on a ruling.
--
--          I previously reported this input as MISSING, citing
--          "0 approved" from carrier_crosswalk_tbl.approved. That was my
--          error: nothing in this repository ever sets that column. It is a
--          boolean I added and never wired up, so it was always going to
--          read zero, and his completed work was reported as a pending
--          decision. carrier_resolved_tbl's own comment, which I wrote,
--          says "Steps 4 to 7 should join to this".
--
-- SAN DIEGO COUNTY IS A CITY HERE, deliberately. Boris, 2026-11-18: "San
-- Diego County should be treated as a city. There are multiple
-- headends/COs for several carriers within it." ip-api sometimes returns a
-- county name in the city field and that is not a defect for this purpose:
-- the name is only a label, the coordinate is the datum, and a
-- county-shaped name with several distinct coordinates behaves exactly like
-- a city with several sites. Nothing here filters on the shape of the name.
--
-- WHAT THIS FILE THEREFORE DOES
--
-- Section 1 materialises the serving sites, graded, with no node-count
-- threshold.
-- Section 2 reports the resolved carrier link from Boris's rulings, and
-- names the carriers with sites that do not yet resolve.
-- Section 2b is STEP 4 AS WRITTEN: per carrier, per tract that carrier
-- serves, the distance to that carrier's own nearest site, plus its second
-- nearest, which step 5 needs.
-- Section 3 keeps the carrier-agnostic geometry as a cross-check. It is not
-- step 4 and is labelled as not being step 4.
--
-- STEP 5's RULE AND WHY SECTION 3 MATTERS. Boris: "Select the headend or CO
-- nearest the centroid, UNLESS another headend less than twice the distance
-- has uninterrupted coverage between it and the centroid." If the nearest
-- and second-nearest sites are routinely within a factor of two of each
-- other, the coverage test decides almost every tract and must be built
-- carefully. If they are routinely far apart, the nearest site wins outright
-- and the coverage test is an edge case. Section 3 answers that.

\timing on
\echo
\echo ================================================================
\echo SECTION 1. The serving sites, materialised and indexed.
\echo ================================================================
\echo
\echo A table rather than the view, because the view cannot be indexed and
\echo the nearest-site search needs a coordinate index. City fallbacks are
\echo excluded here, once, so no later query can forget to.
\echo

DROP TABLE IF EXISTS serving_site_tbl;

CREATE TABLE serving_site_tbl AS
SELECT row_number() OVER (ORDER BY count(*) DESC, g.lat, g.lon) AS site_key,
       split_part(n.hostname, '.', -2) || '.' ||
       split_part(n.hostname, '.', -1)          AS carrier_domain,
       g.grade,
       g.city,
       g.region_eff                             AS region,
       g.lat,
       g.lon,
       count(DISTINCT g.node_ip)                AS node_addresses,
       count(DISTINCT n.hostname)               AS hostnames
FROM node_location_graded g
JOIN carrier_node_tbl n ON n.node_ip = g.node_ip
WHERE g.grade IN ('facility', 'operator_named', 'site_subcity',
                  'site_subcity_unmeasured')
  AND g.country IN ('US', 'United States')
  AND g.lat IS NOT NULL
GROUP BY 2, 3, 4, 5, 6, 7;

ALTER TABLE serving_site_tbl ADD PRIMARY KEY (site_key);
CREATE INDEX serving_site_latlon_idx ON serving_site_tbl (lat, lon);
CREATE INDEX serving_site_domain_idx ON serving_site_tbl (carrier_domain);

COMMENT ON TABLE serving_site_tbl IS
'Candidate headend and central office locations for step 4, one row per carrier and coordinate, at an infrastructure grade only. city_fallback coordinates are excluded here so that no later query can include them by omission. NOT filtered by node count: a site observed with one node is a site where the ITDK found one node, not a site with one node, so the observation count is not evidence of absence.';

\echo
\echo Sites by grade. No minimum node count is applied, deliberately.
\echo
SELECT grade,
       count(*)                   AS sites,
       sum(node_addresses)        AS node_addresses,
       count(DISTINCT carrier_domain) AS carriers,
       count(*) FILTER (WHERE node_addresses = 1) AS single_node_sites
FROM serving_site_tbl
GROUP BY 1 ORDER BY count(*) DESC;

\echo
\echo ================================================================
\echo SECTION 2. The carrier link, from Boris decisions.
\echo ================================================================
\echo
\echo A CORRECTION OF MINE. The previous version of this file reported
\echo "0 approved" from carrier_crosswalk_tbl.approved and called that the
\echo blocker. Boris asked what approval that referred to, and the answer
\echo is: none of his. NOTHING IN THIS REPOSITORY EVER SETS THAT COLUMN. It
\echo is a boolean I added to carrier_crosswalk_tbl and never wired to
\echo anything, so it was always going to read zero.
\echo
\echo His decisions were never missing. He ruled on all 87 records he was
\echo sent; they live in carrier_decision_tbl and are resolved into
\echo carrier_resolved_tbl, whose own comment, which I wrote, says
\echo "Steps 4 to 7 should join to this." I then wrote step 4 against the
\echo wrong table and reported his completed work as a pending decision.
\echo
\echo carrier_resolved_tbl is therefore the link, and by_decision marks the
\echo rows that came from his rulings rather than from name matching.
\echo

SELECT CASE WHEN to_regclass('carrier_resolved_tbl') IS NULL
            THEN 'carrier_resolved_tbl ABSENT, run carrier_decisions.sql and load_decisions.py'
            ELSE 'carrier_resolved_tbl present' END AS state;

\echo
\echo The resolved crosswalk. by_decision is true where the link rests on a
\echo ruling of Boris rather than on a name match.
\echo
SELECT count(*)                                        AS resolved_rows,
       count(DISTINCT itdk_domain)                     AS itdk_domains,
       count(*) FILTER (WHERE by_decision)             AS by_his_decision,
       count(*) FILTER (WHERE bdc_provider_id IS NOT NULL) AS with_bdc_provider,
       count(DISTINCT bdc_provider_id)                 AS distinct_bdc_providers
FROM carrier_resolved_tbl;

\echo
\echo How many carriers WITH SERVING SITES now resolve to a BDC provider.
\echo This is what step 4 can actually run over.
\echo
SELECT count(DISTINCT s.carrier_domain)                        AS carriers_with_sites,
       count(DISTINCT s.carrier_domain) FILTER (
           WHERE EXISTS (SELECT 1 FROM carrier_resolved_tbl r
                         WHERE r.itdk_domain = s.carrier_domain
                           AND r.bdc_provider_id IS NOT NULL)) AS resolve_to_bdc,
       sum(s.node_addresses) FILTER (
           WHERE EXISTS (SELECT 1 FROM carrier_resolved_tbl r
                         WHERE r.itdk_domain = s.carrier_domain
                           AND r.bdc_provider_id IS NOT NULL)) AS node_addresses_covered
FROM serving_site_tbl s;

\echo
\echo Carriers with the most sites that do NOT resolve to a BDC provider.
\echo These are the gap, and they are what a further ruling would address.
\echo
SELECT s.carrier_domain,
       count(*)              AS sites,
       sum(s.node_addresses) AS node_addresses
FROM serving_site_tbl s
WHERE NOT EXISTS (SELECT 1 FROM carrier_resolved_tbl r
                  WHERE r.itdk_domain = s.carrier_domain
                    AND r.bdc_provider_id IS NOT NULL)
GROUP BY 1 ORDER BY count(*) DESC LIMIT 20;

\echo
\echo ================================================================
\echo SECTION 2b. STEP 4 PROPER, per carrier, over the resolved link.
\echo ================================================================
\echo
\echo For each carrier and each census tract in which that carrier offers
\echo service per the BDC, the distance from the tract centroid to that
\echo carriers nearest serving site. This is step 4 as written.
\echo
\echo The carrier-and-tract pairing is materialised first because it is the
\echo expensive part: a scan of 519,469,683 availability rows. It is
\echo restricted to carriers that HAVE sites, which cuts it substantially,
\echo since a pairing for a carrier with no known site cannot contribute.
\echo

DROP TABLE IF EXISTS carrier_tract_tbl;

CREATE TABLE carrier_tract_tbl AS
SELECT DISTINCT r.itdk_domain, a.tract_geoid
FROM bdc_availability_tbl a
JOIN bdc_carrier_tbl c ON c.carrier_key = a.carrier_key
JOIN carrier_resolved_tbl r ON r.bdc_provider_id = c.provider_id
WHERE EXISTS (SELECT 1 FROM serving_site_tbl s
              WHERE s.carrier_domain = r.itdk_domain)
  -- WIRELINE ONLY. Added 2026-11-24, and its absence is the second of two
  -- bugs behind the distances I published. Without it this table holds every
  -- technology, including licensed fixed wireless at 70, 71 and 72, where
  -- Verizon and AT&T have near-national footprints and NO central office
  -- serves the tract at all. The nearest-site distance for such a tract is
  -- meaningless and it dominated the median: verizon.net measured 718.2 km
  -- over all technologies and 6.4 km over wireline tracts with the SAME 157
  -- sites. Boris had already made me fix this exact defect in the footprint
  -- percentage on 2026-11-22, in provider_brand_footprint, and I left it
  -- here, which is what he meant by not checking my work.
  AND a.technology IN (10, 40, 50);

CREATE INDEX carrier_tract_domain_idx ON carrier_tract_tbl (itdk_domain);
CREATE INDEX carrier_tract_tract_idx ON carrier_tract_tbl (tract_geoid);

COMMENT ON TABLE carrier_tract_tbl IS
'One row per ITDK domain and census tract in which the BDC says that carrier offers service, restricted to domains that have at least one known serving site. The link from domain to BDC provider comes from carrier_resolved_tbl, which applies Boris decisions.';

\echo
\echo Carrier and tract pairs available to step 4.
\echo
SELECT count(*)                       AS carrier_tract_pairs,
       count(DISTINCT itdk_domain)    AS carriers,
       count(DISTINCT tract_geoid)    AS tracts
FROM carrier_tract_tbl;

DROP TABLE IF EXISTS step4_carrier_tract_site_tbl;

CREATE TABLE step4_carrier_tract_site_tbl AS
SELECT ct.itdk_domain,
       ct.tract_geoid,
       t.state_usps,
       n.site_key,
       n.grade,
       n.city,
       n.km AS nearest_km,
       n2.site_key AS second_site_key,
       n2.km       AS second_km
FROM carrier_tract_tbl ct
JOIN census_tract_tbl t ON t.tract_geoid = ct.tract_geoid
LEFT JOIN LATERAL (
    SELECT s.site_key, s.grade, s.city,
           6371 * sqrt(
             pow(radians(s.lat - t.lat), 2) +
             pow(radians(
               ((s.lon - t.lon + 540) -
                floor((s.lon - t.lon + 540) / 360) * 360) - 180
             ) * cos(radians(t.lat)), 2)) AS km
    FROM serving_site_tbl s
    WHERE s.carrier_domain = ct.itdk_domain
    ORDER BY pow(s.lat - t.lat, 2) +
             pow((s.lon - t.lon) * cos(radians(t.lat)), 2)
    LIMIT 1) n ON true
LEFT JOIN LATERAL (
    SELECT s.site_key,
           6371 * sqrt(
             pow(radians(s.lat - t.lat), 2) +
             pow(radians(
               ((s.lon - t.lon + 540) -
                floor((s.lon - t.lon + 540) / 360) * 360) - 180
             ) * cos(radians(t.lat)), 2)) AS km
    FROM serving_site_tbl s
    WHERE s.carrier_domain = ct.itdk_domain
      AND s.site_key <> n.site_key
    ORDER BY pow(s.lat - t.lat, 2) +
             pow((s.lon - t.lon) * cos(radians(t.lat)), 2)
    LIMIT 1) n2 ON true;

CREATE INDEX step4_domain_idx ON step4_carrier_tract_site_tbl (itdk_domain);
CREATE INDEX step4_tract_idx ON step4_carrier_tract_site_tbl (tract_geoid);

COMMENT ON TABLE step4_carrier_tract_site_tbl IS
'Step 4 of the plan: for each carrier and each tract that carrier serves per the BDC, the distance from the tract centroid to that carriers nearest serving site, and to its second nearest, which step 5 needs for the twice-the-distance rule. No bounding box is applied here: a carrier has few sites, so the search is cheap and an unrestricted nearest is correct rather than merely affordable.';

\echo
\echo STEP 4 RESULT. Distance from the tract centroid to the serving
\echo carriers own nearest site.
\echo
SELECT CASE WHEN nearest_km IS NULL THEN 'no site for this carrier'
            WHEN nearest_km <= 2   THEN 'a. within 2 km'
            WHEN nearest_km <= 10  THEN 'b. 2 to 10 km'
            WHEN nearest_km <= 25  THEN 'c. 10 to 25 km'
            WHEN nearest_km <= 50  THEN 'd. 25 to 50 km'
            ELSE                        'e. more than 50 km' END AS band,
       count(*)                              AS carrier_tract_pairs,
       count(DISTINCT tract_geoid)           AS tracts
FROM step4_carrier_tract_site_tbl GROUP BY 1 ORDER BY 1;

\echo
\echo WHAT STEP 5 WILL FACE, per carrier rather than across all carriers.
\echo
SELECT CASE WHEN second_km IS NULL THEN 'only one site for this carrier'
            WHEN second_km / nullif(nearest_km, 0) < 1.2
              THEN 'a. under 1.2, nearly tied'
            WHEN second_km / nullif(nearest_km, 0) < 2.0
              THEN 'b. 1.2 to 2.0, coverage test decides'
            ELSE 'c. over 2.0, nearest wins outright' END AS ratio_band,
       count(*) AS carrier_tract_pairs,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM step4_carrier_tract_site_tbl GROUP BY 1 ORDER BY 1;

\echo ================================================================
\echo SECTION 3. The geometry, carrier-agnostic. NOT step 4 itself.
\echo ================================================================
\echo
\echo For each census tract, the nearest and second-nearest serving site of
\echo ANY carrier. This cannot answer "which carrier serves this tract",
\echo which is step 4's actual question; it measures whether step 5's
\echo twice-the-distance rule can discriminate.
\echo
\echo A BOUNDING BOX PREFILTER IS USED. There are 85,396 tracts and some
\echo thousands of sites, and a haversine expression cannot use an index, so
\echo an unrestricted nearest-neighbour search is a cross join. The box is
\echo 1.5 degrees of latitude by 2.0 of longitude, which is about 167 km
\echo north-south and 160 km east-west at 40 degrees latitude. It is a
\echo SINGLE box, not widened in stages.
\echo
\echo A tract with no site inside it is reported as having NONE rather than
\echo matched to something far away. That is deliberate: a nearest-neighbour
\echo query always returns a neighbour and cannot say "none of these", which
\echo is exactly how an earlier version of this project assigned Alaska to
\echo Chennai from 11,596 km away. The count of such tracts is printed
\echo below, and if it is large the box is the thing to widen.
\echo

DROP TABLE IF EXISTS tract_nearest_site_tbl;

CREATE TABLE tract_nearest_site_tbl AS
WITH t AS (
    SELECT tract_geoid, state_usps, lat, lon, aland_sqmi
    FROM census_tract_tbl
), near AS (
    SELECT t.tract_geoid, t.state_usps, t.aland_sqmi,
           s.site_key, s.carrier_domain, s.grade, s.city,
           6371 * sqrt(
             pow(radians(s.lat - t.lat), 2) +
             pow(radians(
               ((s.lon - t.lon + 540) -
                floor((s.lon - t.lon + 540) / 360) * 360) - 180
             ) * cos(radians(t.lat)), 2)) AS km,
           row_number() OVER (PARTITION BY t.tract_geoid
                              ORDER BY pow(s.lat - t.lat, 2) +
                                       pow((s.lon - t.lon) *
                                           cos(radians(t.lat)), 2)) AS rn
    FROM t
    JOIN serving_site_tbl s
      ON s.lat BETWEEN t.lat - 1.5 AND t.lat + 1.5
     AND s.lon BETWEEN t.lon - 2.0 AND t.lon + 2.0
)
SELECT n1.tract_geoid, n1.state_usps, n1.aland_sqmi,
       n1.site_key      AS nearest_site_key,
       n1.carrier_domain AS nearest_carrier,
       n1.grade         AS nearest_grade,
       n1.city          AS nearest_city,
       n1.km            AS nearest_km,
       n2.site_key      AS second_site_key,
       n2.carrier_domain AS second_carrier,
       n2.km            AS second_km
FROM near n1
LEFT JOIN near n2 ON n2.tract_geoid = n1.tract_geoid AND n2.rn = 2
WHERE n1.rn = 1;

ALTER TABLE tract_nearest_site_tbl ADD PRIMARY KEY (tract_geoid);

COMMENT ON TABLE tract_nearest_site_tbl IS
'For each census tract, the nearest and second-nearest serving site of ANY carrier, within a 1.5 by 2.0 degree box. This is NOT step 4: it cannot say which carrier serves the tract, which is step 4''s question and which waits on an approved carrier crosswalk. It measures whether step 5''s twice-the-distance rule can discriminate between candidate sites.';

\echo
\echo Tracts with no serving site inside the search box. Reported, not
\echo matched to something far away.
\echo
SELECT (SELECT count(*) FROM census_tract_tbl)            AS tracts_total,
       (SELECT count(*) FROM tract_nearest_site_tbl)      AS tracts_with_a_site,
       (SELECT count(*) FROM census_tract_tbl c
        WHERE NOT EXISTS (SELECT 1 FROM tract_nearest_site_tbl n
                          WHERE n.tract_geoid = c.tract_geoid))
                                                          AS tracts_with_none;

\echo
\echo Distance to the nearest serving site.
\echo
SELECT CASE WHEN nearest_km <= 2   THEN 'a. within 2 km'
            WHEN nearest_km <= 10  THEN 'b. 2 to 10 km'
            WHEN nearest_km <= 25  THEN 'c. 10 to 25 km'
            WHEN nearest_km <= 50  THEN 'd. 25 to 50 km'
            ELSE                        'e. more than 50 km' END AS band,
       count(*)                                   AS tracts,
       round(sum(aland_sqmi)::numeric)            AS land_sqmi
FROM tract_nearest_site_tbl GROUP BY 1 ORDER BY 1;

\echo
\echo CAN STEP 5 DISCRIMINATE. The ratio of second-nearest to nearest. At a
\echo ratio under two, step 5 must run its coverage test; at a ratio over
\echo two, the nearest site wins outright and the coverage test does not
\echo arise for that tract.
\echo
SELECT CASE WHEN second_km IS NULL THEN 'only one site in range'
            WHEN second_km / nullif(nearest_km, 0) < 1.2
              THEN 'a. under 1.2, nearly tied'
            WHEN second_km / nullif(nearest_km, 0) < 2.0
              THEN 'b. 1.2 to 2.0, coverage test decides'
            ELSE 'c. over 2.0, nearest wins outright' END AS ratio_band,
       count(*) AS tracts,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM tract_nearest_site_tbl GROUP BY 1 ORDER BY 1;

\timing off
\echo
\echo DONE. serving_site_tbl and tract_nearest_site_tbl are built.
\echo
\echo Step 4 proper is in step4_carrier_tract_site_tbl, joined through
\echo carrier_resolved_tbl which applies Boris decisions. Section 2 names
\echo the carriers with sites that do NOT yet resolve to a BDC provider,
\echo which is the remaining gap.
\echo
