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
--   NOT READY  the link from an ITDK domain to a BDC carrier.
--          carrier_crosswalk_tbl.approved defaults false and the design
--          states that nothing downstream should join through an unapproved
--          row. There are 8,673 BDC name proposals and ZERO approved. So
--          "that carrier" cannot yet be evaluated, and the per-carrier form
--          of step 4 returns nothing by construction, not by accident.
--
-- WHAT THIS FILE THEREFORE DOES
--
-- Section 1 materialises the carrier-and-tract pairing, which is needed
-- whatever happens next and is the expensive part.
-- Section 2 reports the crosswalk state, so the blocker is a number rather
-- than a claim.
-- Section 3 computes the CARRIER-AGNOSTIC geometry: for every tract, the
-- nearest and second-nearest serving site of any carrier. That is not step 4
-- and is not labelled as though it were. It is the measurement that tells us
-- whether step 5's rule can discriminate at all, which is worth knowing
-- before the crosswalk is approved rather than after.
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
\echo SECTION 2. The carrier link, which is what step 4 is waiting on.
\echo ================================================================
\echo

SELECT CASE WHEN to_regclass('carrier_crosswalk_tbl') IS NULL
            THEN 'carrier_crosswalk_tbl does not exist'
            ELSE 'carrier_crosswalk_tbl exists' END AS state;

\echo
\echo How many carrier links are APPROVED. Nothing downstream may join
\echo through an unapproved row, so this number is the gate on the
\echo per-carrier form of step 4.
\echo
SELECT count(*)                                  AS crosswalk_rows,
       count(*) FILTER (WHERE approved)          AS approved,
       count(*) FILTER (WHERE bdc_provider_id IS NOT NULL
                          AND NOT approved)      AS bdc_proposals_awaiting,
       count(DISTINCT itdk_domain)               AS itdk_domains
FROM carrier_crosswalk_tbl;

\echo
\echo Of the carriers that actually HAVE serving sites, how many could be
\echo linked to a BDC carrier today. This is the practical size of the
\echo approval task, which is smaller than the full proposal list because
\echo most proposals concern carriers with no sites.
\echo
SELECT count(DISTINCT s.carrier_domain)                      AS carriers_with_sites,
       count(DISTINCT s.carrier_domain) FILTER (
           WHERE EXISTS (SELECT 1 FROM carrier_crosswalk_tbl x
                         WHERE x.itdk_domain = s.carrier_domain
                           AND x.approved))                  AS linked_and_approved,
       count(DISTINCT s.carrier_domain) FILTER (
           WHERE EXISTS (SELECT 1 FROM carrier_crosswalk_tbl x
                         WHERE x.itdk_domain = s.carrier_domain
                           AND x.bdc_provider_id IS NOT NULL
                           AND NOT x.approved))              AS proposed_not_approved
FROM serving_site_tbl s;

\echo
\echo The carriers with the most sites and no approved BDC link. These are
\echo where approval buys the most, ordered by how much step 4 they unblock.
\echo
SELECT s.carrier_domain,
       count(*)            AS sites,
       sum(s.node_addresses) AS node_addresses
FROM serving_site_tbl s
WHERE NOT EXISTS (SELECT 1 FROM carrier_crosswalk_tbl x
                  WHERE x.itdk_domain = s.carrier_domain AND x.approved)
GROUP BY 1 ORDER BY count(*) DESC LIMIT 20;

\echo
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
\echo Step 4 proper, per carrier, is blocked on approved rows in
\echo carrier_crosswalk_tbl. Section 2 names the carriers where approval
\echo unblocks the most.
\echo
