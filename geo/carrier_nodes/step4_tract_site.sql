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
       -- BUG FIX 2026-11-24. The last two labels of a hostname are not
       -- always a domain. Boris's audit showed in-addr.arpa as a carrier
       -- with 10 sites: those are reverse PTR names, where the last two
       -- labels are the arpa suffix and carry no operator at all. A
       -- hostname with fewer than two labels produced a key beginning with
       -- a dot for the same reason. Both are now excluded in the WHERE
       -- below rather than renamed, because neither is a carrier.
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
  -- a real hostname, with at least two labels and not a reverse PTR name
  AND n.hostname LIKE '%.%'
  AND split_part(n.hostname, '.', -2) <> ''
  AND n.hostname NOT LIKE '%.arpa'
  AND n.hostname NOT LIKE '%.in-addr.arpa'
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
\echo ================================================================
\echo THE PAIRING. Rewritten 2026-11-24 because the previous version
\echo did not finish.
\echo
\echo It scanned bdc_availability_tbl, 519,469,683 rows, and then
\echo multiplied each surviving row by the number of ITDK domains
\echo resolving to that provider: 87 for AT&T, 101 for Verizon, 56 for
\echo CenturyLink. Hundreds of millions of rows fanned out by up to a
\echo hundred, then de-duplicated. That is why it sat without
\echo progressing.
\echo
\echo Step 1 already aggregated those 519 million rows into
\echo provider_tract_tech_tbl, 785,168 provider-technology-tract rows,
\echo and that is the table this needs: 662 times smaller. The key is
\echo now the PROVIDER and the TECHNOLOGY, not the domain, so there is
\echo no fan-out at all, and per-technology is the grain the plan asks
\echo for rather than something recovered later.
\echo
\echo MEASURED ESTIMATE, from his own audit run: the same nearest-site
\echo pattern did 21,860 rows in 2.565 s, which is 8,520 rows a second.
\echo The wireline pairing is about 409,000 rows, so expect roughly one
\echo minute, not the tens of minutes the old version failed to finish.
\echo ================================================================
\echo

DROP TABLE IF EXISTS carrier_tract_tbl;

CREATE TABLE carrier_tract_tbl AS
SELECT DISTINCT p.provider_id, p.technology, p.tract_geoid
FROM provider_tract_tech_tbl p
-- WIRELINE ONLY. Technologies 70, 71 and 72 are licensed and unlicensed
-- fixed wireless; no central office serves such a tract, so a distance to
-- one is meaningless. This bug shipped three times before being fixed here,
-- in provider_brand_footprint, in this table and in carrier_link_audit.
WHERE p.technology IN (10, 40, 50)
  -- and only providers that can be placed at all, which is what makes this
  -- cheap: a provider with no located site contributes nothing downstream
  AND EXISTS (SELECT 1 FROM carrier_resolved_tbl r
              WHERE r.bdc_provider_id = p.provider_id
                AND EXISTS (SELECT 1 FROM serving_site_tbl s
                            WHERE s.carrier_domain = r.itdk_domain));

CREATE INDEX carrier_tract_provider_idx ON carrier_tract_tbl (provider_id);
CREATE INDEX carrier_tract_tract_idx ON carrier_tract_tbl (tract_geoid);
ANALYZE carrier_tract_tbl;

COMMENT ON TABLE carrier_tract_tbl IS
'One row per BDC provider, wireline technology and census tract in which that provider offers service, restricted to providers that have at least one located serving site. Built from provider_tract_tech_tbl, the step 1 aggregate, NOT from bdc_availability_tbl: the raw table is 519,469,683 rows and joining it to the domain list fanned each row out by up to a hundred, which is why the previous version never finished.';

\echo
\echo Provider and tract pairs available to step 4, by technology.
\echo
SELECT technology,
       count(*)                       AS pairs,
       count(DISTINCT provider_id)    AS providers,
       count(DISTINCT tract_geoid)    AS tracts
FROM carrier_tract_tbl
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- WHICH SITES BELONG TO A PROVIDER.
--
-- Built once, so the nearest-site search joins to a small table instead of
-- resolving the domain list per tract.
--
-- THE CONTAMINATION, AND WHERE IT IS CUT. carrier_resolved_tbl links a
-- provider to every domain whose name matched it, and on his data that
-- includes DIA customers: AT&T has 87 domains among them
-- americanadoptions.com, Verizon 101 including 255.208, which is not a
-- domain. A customer hostname contributes a SITE, so the distance would be
-- measured partly to customer premises.
--
-- So when a provider has a CONFIRMED suffix group, only the suffixes of that
-- group contribute sites. Where no grouping is confirmed the behaviour is
-- unchanged, every linked domain contributes, and the count of providers in
-- each case is printed below so the difference is never silent.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS provider_site_tbl;

CREATE TABLE provider_site_tbl AS
WITH confirmed AS (
    SELECT DISTINCT r.bdc_provider_id AS provider_id, g.carrier_key
    FROM carrier_resolved_tbl r
    JOIN carrier_suffix_group_tbl g
      ON g.suffix = r.itdk_domain AND g.status = 'confirmed'
    WHERE r.bdc_provider_id IS NOT NULL
)
SELECT DISTINCT r.bdc_provider_id AS provider_id, s.site_key, s.lat, s.lon,
                s.carrier_domain, s.grade
FROM carrier_resolved_tbl r
JOIN serving_site_tbl s ON s.carrier_domain = r.itdk_domain
WHERE r.bdc_provider_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM confirmed c WHERE c.provider_id = r.bdc_provider_id)
UNION
SELECT DISTINCT c.provider_id, s.site_key, s.lat, s.lon,
                s.carrier_domain, s.grade
FROM confirmed c
JOIN carrier_suffix_group_tbl g2
  ON g2.carrier_key = c.carrier_key AND g2.status = 'confirmed'
JOIN serving_site_tbl s ON s.carrier_domain = g2.suffix;

CREATE INDEX provider_site_provider_idx ON provider_site_tbl (provider_id);
ANALYZE provider_site_tbl;

COMMENT ON TABLE provider_site_tbl IS
'The located sites that count as a BDC provider for the nearest-site search. Where a CONFIRMED suffix group exists for the provider, only that group''s suffixes contribute, which is what keeps DIA customer domains out of a carrier site set. Where no grouping is confirmed, every linked domain contributes, exactly as before.';

\echo
\echo How many providers draw their sites from a confirmed grouping rather
\echo than from every domain that name-matched them. The second number is
\echo the contamination still in place.
\echo
SELECT count(*) FILTER (WHERE from_group)     AS providers_from_a_confirmed_group,
       count(*) FILTER (WHERE NOT from_group) AS providers_from_every_matched_domain
FROM (
    SELECT r.bdc_provider_id,
           EXISTS (SELECT 1 FROM carrier_resolved_tbl r2
                   JOIN carrier_suffix_group_tbl g
                     ON g.suffix = r2.itdk_domain AND g.status = 'confirmed'
                   WHERE r2.bdc_provider_id = r.bdc_provider_id) AS from_group
    FROM carrier_resolved_tbl r
    WHERE r.bdc_provider_id IS NOT NULL
    GROUP BY 1, 2) x;

\echo
\echo Sites per provider, the largest first. A provider with one site cannot
\echo produce a usable distance however good the rest of the pipeline is.
\echo
SELECT p.provider_id,
       left(coalesce((SELECT string_agg(DISTINCT b.brand_name, ' / ')
                      FROM bdc_carrier_tbl b
                      WHERE b.provider_id = p.provider_id), ''), 34) AS brand,
       count(*)                           AS sites,
       count(DISTINCT p.carrier_domain)   AS suffixes
FROM provider_site_tbl p
GROUP BY p.provider_id
ORDER BY count(*) DESC
LIMIT 25;

\echo
\echo ================================================================
\echo STEP 4 PROPER. For each provider, wireline technology and served
\echo tract, the distance to the nearest located site of that provider
\echo to its second nearest. The second is what step 5 needs for the
\echo twice-the-distance test.
\echo ================================================================
\echo

DROP TABLE IF EXISTS step4_carrier_tract_site_tbl;

CREATE TABLE step4_carrier_tract_site_tbl AS
SELECT ct.provider_id,
       ct.technology,
       ct.tract_geoid,
       t.state_usps,
       n.site_key,
       n.grade,
       n.carrier_domain,
       n.km AS nearest_km,
       n2.site_key AS second_site_key,
       n2.km       AS second_km
FROM carrier_tract_tbl ct
JOIN census_tract_tbl t ON t.tract_geoid = ct.tract_geoid
LEFT JOIN LATERAL (
    SELECT s.site_key, s.grade, s.carrier_domain,
           6371 * sqrt(
             pow(radians(s.lat - t.lat), 2) +
             pow(radians(
               ((s.lon - t.lon + 540) -
                floor((s.lon - t.lon + 540) / 360) * 360) - 180
             ) * cos(radians(t.lat)), 2)) AS km
    FROM provider_site_tbl s
    WHERE s.provider_id = ct.provider_id
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
    FROM provider_site_tbl s
    WHERE s.provider_id = ct.provider_id
      AND s.site_key <> n.site_key
    ORDER BY pow(s.lat - t.lat, 2) +
             pow((s.lon - t.lon) * cos(radians(t.lat)), 2)
    LIMIT 1) n2 ON true
WHERE t.lat IS NOT NULL AND t.lon IS NOT NULL;

CREATE INDEX step4_provider_idx ON step4_carrier_tract_site_tbl (provider_id);
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
