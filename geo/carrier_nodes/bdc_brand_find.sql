-- bdc_brand_find.sql - what BDC brand names match a string, with the
-- footprint each one carries.
--
-- WHY THIS EXISTS
--
-- Boris, 2026-11-19: "afes.com and snowcrest.net are carriers.
-- charlestoncounty.org is not."
--
-- The two negatives need nothing but a not_an_isp row. The two positives
-- need a BDC provider name, and the decision mechanism takes that name
-- VERBATIM: carrier_decision_tbl.decision = 'use_bdc_name' joins
-- bdc_carrier_tbl ON brand_name = value, an exact match. A name I invent
-- from a company's own website will not necessarily be the string the FCC
-- filing carries, and resolve_asn.sql would then record
-- 'named by Boris, NOT FOUND in bdc_carrier_tbl' with a null provider_id.
-- That is visible rather than silent, which is right, but it is still a
-- wasted round trip.
--
-- So the exact string comes out of Boris's own loaded data, not out of me.
--
-- WHAT IS ESTABLISHED ABOUT THE TWO, and it is identification only
--
-- Boris, 2026-11-19: "afes.net is AFES, a Northern California carrier
-- acquired by cal.net. No relation to Alaska."
--
-- He is pre-empting exactly the guess the letters invite, and it is the
-- Chennai-in-Alaska failure in miniature: AFES reads like an Alaska
-- abbreviation and is not one. The domain in the data is afes.com.
--
-- Confirmed by search, consistent with what he said:
-- AFES Network Services LLC is a fixed wireless provider in Yolo, Colusa,
-- Solano and Sutter counties, California, and Cal.net announced its
-- acquisition on 19 March 2026 from Shingle Springs, California.
--   https://broadbandnow.com/AFES-Network-Services
--   https://www.cal.net/press-releas/cal-net-acquires-afes-network-services-strengthening-local-broadband-and-expanding-affordable-high-quality-connectivity/
-- snowcrest.net is SnowCrest, Inc. of Mount Shasta, California, serving
-- Siskiyou and Shasta counties with DSL and broadband since 1994.
--   https://sc.snowcrest.net/index.php/about-us
-- Content from these sources was rephrased for licensing compliance.
--
-- THE ACQUISITION IS WHY THE NAME MUST COME FROM THE DATA. Which name AFES
-- files under depends on the vintage of the loaded availability files
-- against March 2026: before it, AFES files in its own right; after it, the
-- footprint may sit under Cal.net. I will not decide that from a press
-- release. Search BOTH patterns and let the row counts say:
--
--   psql -X -P pager=off -v pat=afes      -f .../bdc_brand_find.sql
--   psql -X -P pager=off -v pat=cal.net   -f .../bdc_brand_find.sql
--   psql -X -P pager=off -v pat=snowcrest -f .../bdc_brand_find.sql
--
-- All three report WHO they are. None of them tells us the brand_name
-- string in the BDC filing, and that string is what use_bdc_name needs.
-- Both domains report 'AT&T Enterprises, LLC' to ip-api because their
-- address space is registered under AT&T, which is the inheritance that
-- broke step 4; the difference from charlestoncounty.org is that these two
-- file in the BDC in their own right, so there is a footprint to find.
--
-- The pattern is matched case-insensitively against brand_name.
--
-- tract_tech_pairs is what the domain would inherit in step 4 if linked to
-- that provider. A small county provider should show thousands at most; a
-- six-figure number means the wrong provider.

\if :{?pat}
\else
\echo
\echo No pattern given. Re-run with -v pat=SOMETHING, for example
\echo     psql -X -P pager=off -v pat=afes -f THIS_FILE
\echo Nothing was queried.
\echo
\quit
\endif

\echo
\echo ================================================================
\echo BDC brand names matching the pattern, with their own footprints.
\echo ================================================================

SELECT :'pat' AS pattern_searched;

WITH f AS (
    SELECT provider_id,
           count(*)                    AS tract_tech_pairs,
           count(DISTINCT tract_geoid) AS tracts,
           count(DISTINCT technology)  AS technologies
    FROM provider_tract_tech_tbl
    GROUP BY 1
)
SELECT DISTINCT
       c.provider_id,
       c.frn,
       c.brand_name,
       coalesce(f.tract_tech_pairs, 0) AS tract_tech_pairs,
       coalesce(f.tracts, 0)           AS tracts,
       coalesce(f.technologies, 0)     AS technologies
FROM bdc_carrier_tbl c
LEFT JOIN f ON f.provider_id = c.provider_id
WHERE c.brand_name ILIKE '%' || :'pat' || '%'
ORDER BY 4 DESC, 3;

\echo
\echo Any ITDK domain already linked to those providers, so an existing
\echo link is visible before a new one is recorded.
\echo
SELECT DISTINCT r.itdk_domain, r.bdc_provider_id, r.by_decision,
       left(r.label_basis, 44) AS label_basis
FROM carrier_resolved_tbl r
WHERE r.bdc_provider_id IN (
        SELECT c.provider_id FROM bdc_carrier_tbl c
        WHERE c.brand_name ILIKE '%' || :'pat' || '%')
ORDER BY 1;

\echo
\echo The ITDK side: any domain whose own name matches the pattern, with
\echo the sites it has and what step 4 credited it with.
\echo
SELECT d.itdk_domain, d.sites, d.node_addresses, d.cities, d.triples,
       d.median_km, d.any_by_decision,
       left(coalesce(d.ipapi_isp, d.rdap_name, ''), 30) AS reported_as
FROM domain_classification_tbl d
WHERE d.itdk_domain ILIKE '%' || :'pat' || '%'
ORDER BY 1;
