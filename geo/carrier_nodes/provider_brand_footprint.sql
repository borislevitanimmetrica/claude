-- provider_brand_footprint.sql - re-grain the BDC footprint to the BRAND,
-- because provider_id has been shown to group unrelated companies.
--
-- WHAT SECTION 0 OF THE QA RUN FOUND, 2026-11-20
--
-- 2,069 provider_ids over 2,765 FRNs, and 326 provider_ids carry more than
-- one FRN. Most of that is correct and expected: provider_id 131413 carries
-- more than thirty FRNs, every one of them a Windstream subsidiary, and
-- 130077 carries ten FRNs all branded AT&T. A holding company filing through
-- many legal entities is exactly what the FCC scheme describes.
--
-- Three of the top twenty are NOT that:
--
--   130077   AT&T on ten FRNs, and FRN 0005937974 under the brand
--            QUANTUM FIBER, which is Lumen's consumer brand, not AT&T's.
--   130403   eleven FRNs branded Lumos or lumos, and FRN 0006945950 under
--            the brand T-MOBILE. This provider_id holds 85,801 pairs over
--            84,474 tracts, which is 98.8 pct of the country. Lumos is a
--            regional fibre carrier in Virginia and the Carolinas and
--            cannot serve 98.8 pct of US census tracts. T-Mobile fixed
--            wireless can.
--   130982   FRN 0016555849 under BOTH Allstream Business US LLC and
--            ZAYO GROUP LLC, with ENA Healthcare Services on a third FRN.
--
-- Against those, 130335 carrying Consolidated Communications and Fidium
-- Fiber is one company with two brands, and 240041 carrying Google Fiber
-- and Webpass likewise. So several brands under one provider_id is normal
-- and is not itself the problem.
--
-- WHY THIS MATTERS MORE THAN THE RANKING
--
-- provider_tract_tech_tbl is grouped by provider_id alone. If one
-- provider_id spans unrelated companies then its footprint is the UNION of
-- their footprints, and every number downstream inherits it:
--
--   the 97.2 pct tract coverage I used to explain the ranking failure,
--   the 156,524 pairs credited to AT&T,
--   step 4's distances for every domain linked to such a provider,
--   and the "lumos" row that appeared to serve almost every tract.
--
-- I CANNOT TELL FROM THE ABOVE whether the mixing is material. One brand
-- row in the carrier table says nothing about how many availability records
-- carry it. Quantum Fiber under AT&T might be two tracts or forty thousand.
-- That is what this file measures, and until it has run I am not proposing
-- any new matching, because a score computed on a contaminated footprint
-- would be meaningless either way.
--
-- COST, STATED UP FRONT
--
-- One pass over bdc_availability_tbl, 519,469,683 rows. The comparable
-- measured operation this session was the technology scan at 126 seconds,
-- and this one aggregates to roughly a million rows rather than seven, so
-- expect several minutes rather than seconds. It is one statement because
-- 56 per-state statements would each need the same scan: there is no index
-- on state_usps, so splitting it would multiply the work rather than
-- divide it. work_mem is raised for this session only so the aggregate
-- spills to disk less.
--
-- PRE-MORTEM. Creates provider_brand_tract_tech_tbl, which is NEW, and
-- drops it first so the file is re-runnable. provider_tract_tech_tbl is
-- READ ONLY here and is not replaced: nothing that currently works stops
-- working, and step 4 keeps its existing input until the numbers below
-- justify changing it. If the statement is interrupted the new table is
-- left absent or empty and nothing else is touched.

\timing on

SET work_mem = '512MB';

\echo
\echo ================================================================
\echo STEP 1. The brand-grained footprint. One pass over the whole
\echo availability table, several minutes. Nothing is printed while it
\echo runs; the row count below is the completion signal.
\echo ================================================================
\echo
-- THE COALESCE IS NOT COSMETIC. bdc_carrier_tbl stores
-- nullif(brand_name, '') and nullif(provider_id, '')::integer, so a filing
-- with a blank brand or a blank provider id lands as NULL. A PRIMARY KEY
-- requires every column NOT NULL, so one such row would abort the ALTER
-- AFTER the several-minute scan had already run, losing all of it. The
-- sentinels make the key safe, and the count below says whether any row
-- needed them rather than leaving it unknown.
DROP TABLE IF EXISTS provider_brand_tract_tech_tbl;
CREATE TABLE provider_brand_tract_tech_tbl AS
SELECT coalesce(c.provider_id, -1)                      AS provider_id,
       coalesce(c.brand_name, '(no brand name filed)')  AS brand_name,
       a.technology,
       a.tract_geoid
FROM bdc_availability_tbl a
JOIN bdc_carrier_tbl c ON c.carrier_key = a.carrier_key
GROUP BY 1, 2, 3, 4;

ALTER TABLE provider_brand_tract_tech_tbl
    ADD PRIMARY KEY (provider_id, brand_name, technology, tract_geoid);
CREATE INDEX provider_brand_tract_ix
    ON provider_brand_tract_tech_tbl (tract_geoid);
CREATE INDEX provider_brand_name_ix
    ON provider_brand_tract_tech_tbl (brand_name);
ANALYZE provider_brand_tract_tech_tbl;

COMMENT ON TABLE provider_brand_tract_tech_tbl IS
'The BDC footprint at the grain of (provider_id, brand_name, technology, tract_geoid), built because provider_id alone was shown on 2026-11-20 to group unrelated companies: provider 130403 carries both Lumos and T-Mobile and appeared to serve 98.8 percent of US census tracts, and 130077 carries both AT&T and Quantum Fiber. A brand is what a subscriber buys and what an ITDK domain corresponds to, so it is the grain the carrier crosswalk needs. provider_tract_tech_tbl is retained unchanged; this does not replace it.';

SELECT count(*)                          AS brand_grain_rows,
       count(DISTINCT provider_id)       AS providers,
       count(DISTINCT brand_name)        AS brands,
       count(DISTINCT tract_geoid)       AS tracts,
       count(*) FILTER (WHERE provider_id = -1)   AS rows_with_no_provider_id,
       count(*) FILTER (
         WHERE brand_name = '(no brand name filed)') AS rows_with_no_brand
FROM provider_brand_tract_tech_tbl;

\echo
\echo For comparison, the provider-grained table it is built beside.
\echo
SELECT count(*)                    AS provider_grain_rows,
       count(DISTINCT provider_id) AS providers
FROM provider_tract_tech_tbl;

\echo
\echo ================================================================
\echo STEP 2. THE QUESTION THIS FILE EXISTS TO ANSWER. For each of the
\echo twenty largest provider ids, every brand with the share of that
\echo provider footprint it accounts for. A provider whose pairs are
\echo dominated by a brand that is not its label is mislabelled, and its
\echo footprint is a union rather than a company.
\echo ================================================================
\echo
WITH top AS (
    SELECT provider_id, count(*) AS provider_pairs
    FROM provider_tract_tech_tbl GROUP BY 1
    ORDER BY 2 DESC LIMIT 20
), brand AS (
    SELECT provider_id, brand_name,
           count(*)                    AS brand_pairs,
           count(DISTINCT tract_geoid) AS brand_tracts
    FROM provider_brand_tract_tech_tbl GROUP BY 1, 2
)
SELECT b.provider_id,
       t.provider_pairs,
       b.brand_name,
       b.brand_pairs,
       b.brand_tracts,
       round(100.0 * b.brand_pairs / t.provider_pairs, 1) AS pct_of_provider,
       round(100.0 * b.brand_tracts
             / (SELECT count(*) FROM census_tract_tbl), 1) AS pct_of_all_tracts
FROM brand b
JOIN top t ON t.provider_id = b.provider_id
ORDER BY t.provider_pairs DESC, b.brand_pairs DESC;

\echo
\echo The three named suspects on their own, so the answer is not buried.
\echo Quantum Fiber against AT&T, T-Mobile against Lumos, Zayo against
\echo Allstream. If the foreign brand is a rounding error these provider
\echo footprints are sound; if it dominates, they are not.
\echo
SELECT provider_id, brand_name,
       count(*)                    AS brand_pairs,
       count(DISTINCT tract_geoid) AS brand_tracts,
       count(DISTINCT technology)  AS technologies
FROM provider_brand_tract_tech_tbl
WHERE provider_id IN (130077, 130403, 130982)
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

\echo
\echo ================================================================
\echo STEP 3. The country as the BRANDS see it. Every brand with ten
\echo thousand pairs or more, which is the real list of large carriers
\echo and the list the crosswalk should be matching against.
\echo ================================================================
\echo
SELECT brand_name,
       count(DISTINCT provider_id)                        AS provider_ids,
       count(*)                                           AS brand_pairs,
       count(DISTINCT tract_geoid)                        AS brand_tracts,
       round(100.0 * count(DISTINCT tract_geoid)
             / (SELECT count(*) FROM census_tract_tbl), 1) AS pct_of_all_tracts
FROM provider_brand_tract_tech_tbl
GROUP BY 1
HAVING count(*) >= 10000
ORDER BY 3 DESC;

\echo
\echo How the footprint distribution changes at brand grain. Compare with
\echo the provider-grained version: three providers were above 80 pct of
\echo all tracts, which is what destroyed the containment test.
\echo
WITH b AS (
    SELECT provider_id, brand_name, count(DISTINCT tract_geoid) AS tracts
    FROM provider_brand_tract_tech_tbl GROUP BY 1, 2
), tot AS (SELECT count(*) AS all_tracts FROM census_tract_tbl)
SELECT CASE WHEN 100.0 * b.tracts / tot.all_tracts >= 80 THEN 'a. 80 pct or more of all tracts'
            WHEN 100.0 * b.tracts / tot.all_tracts >= 40 THEN 'b. 40 to 80 pct'
            WHEN 100.0 * b.tracts / tot.all_tracts >= 10 THEN 'c. 10 to 40 pct'
            WHEN 100.0 * b.tracts / tot.all_tracts >= 1  THEN 'd. 1 to 10 pct'
            ELSE                                              'e. under 1 pct' END AS footprint_band,
       count(*)      AS brands,
       sum(b.tracts) AS tracts_summed
FROM b CROSS JOIN tot
GROUP BY 1 ORDER BY 1;

\echo
\echo ================================================================
\echo STEP 4. Brands that appear under more than one provider_id, which
\echo would be the mirror image of the same problem: one company split
\echo across ids so no single id holds its whole footprint.
\echo ================================================================
\echo
SELECT brand_name,
       count(DISTINCT provider_id) AS provider_ids,
       count(*)                    AS brand_pairs
FROM provider_brand_tract_tech_tbl
GROUP BY 1
HAVING count(DISTINCT provider_id) > 1
ORDER BY 3 DESC
LIMIT 40;

RESET work_mem;
\timing off
