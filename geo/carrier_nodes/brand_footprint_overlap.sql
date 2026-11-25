-- brand_footprint_overlap.sql
--
-- Does a recorded pairing join two networks that serve the same ground, or
-- two networks that share only an owner?
--
-- WHY THIS EXISTS. Step 3 asks an LLM whether there is any relationship
-- between two brands, which is boris's wording and is the right question for
-- identity. On 2026-11-25 gemini-3.6-flash answered 25 queued pairs and got
-- all 25 right as corporate facts, but nine of them were sister brands of one
-- holding company rather than one network:
--
--   Grande Communications Networks, LLC  ||  RCN
--   Grande Communications Networks, LLC  ||  Wave
--   Grande Communications Networks, LLC  ||  Digital West
--   RCN  ||  Wave, RCN  ||  Digital West, RCN  ||  Grande
--   Wave Broadband  ||  RCN, Wave Broadband  ||  Grande, Wave Broadband  ||  Digital West
--
-- all answered with "sister operating companies and brands under Astound
-- Broadband", plus Cablevision Systems Corp. || Suddenlink under Altice and
-- Level 3 Communications, Inc. || Quantum Fiber under Lumen.
--
-- Shared ownership is not shared plant. If those brands serve disjoint sets
-- of census tracts then accepting the pairing attaches one ISP's address
-- space to geography it does not serve, which is the same failure as a tract
-- sitting hundreds of kilometres from the nearest site of its own carrier.
--
-- I AM NOT ASSERTING THE FOOTPRINTS ARE DISJOINT. I cannot see the BDC data
-- from here, so this file measures it instead of guessing. The reading is in
-- the shared_tracts and jaccard columns:
--
--   jaccard near 0        the brands serve different ground. Merging them
--                         would spread one ISP's ranges across geography it
--                         does not serve. These pairings need your ruling.
--   jaccard near 1        the brands serve the same ground, so the pairing is
--                         a rebrand or a legal-entity split and is safe.
--   in between            overlapping but distinct build, which needs a look.
--
-- It reads and reports. It writes no decision and changes no table, because
-- which way to resolve a disjoint pairing is boris's call, not mine.
--
-- INPUT   carrier_alias_tbl, provider_brand_tract_tech_tbl
-- OUTPUT  reports only
--
-- provider_brand_tract_tech_tbl is built by provider_brand_footprint.sql. If
-- it is absent this file stops without reporting anything, rather than
-- printing an empty result that could be mistaken for "no overlap problem".

\timing on
\pset pager off

-- This is set here rather than left to the caller. Without it the precheck
-- below raises and psql carries on, so the report headings still print and
-- the output reads as a report that found nothing. Measured 2026-11-25: two
-- heading lines were emitted after the precheck had already failed.
\set ON_ERROR_STOP on

-- PRECHECK. It blocks. A missing table or column must stop the file, not
-- produce a report with holes in it that reads as evidence.
DO $precheck$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(needed, ', ')
      INTO missing
    FROM (VALUES ('carrier_alias_tbl'), ('provider_brand_tract_tech_tbl')) AS v(needed)
    WHERE to_regclass(v.needed) IS NULL;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'these tables are missing: %. provider_brand_tract_tech_tbl is built by provider_brand_footprint.sql. Nothing was reported.', missing;
    END IF;

    SELECT string_agg(needed, ', ')
      INTO missing
    FROM (VALUES ('ipapi_side'), ('bdc_side'), ('status')) AS v(needed)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'carrier_alias_tbl' AND column_name = v.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'carrier_alias_tbl is missing: %. Nothing was reported.', missing;
    END IF;

    SELECT string_agg(needed, ', ')
      INTO missing
    FROM (VALUES ('brand_name'), ('technology'), ('tract_geoid')) AS v(needed)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'provider_brand_tract_tech_tbl' AND column_name = v.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'provider_brand_tract_tech_tbl is missing: %. Nothing was reported.', missing;
    END IF;

    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- The wireline footprint of each brand, one row per brand and tract.
-- Technologies 10, 40 and 50 are copper, cable and fibre to the premises.
-- Fixed wireless and satellite are excluded because a tract they cover says
-- nothing about where the brand has plant on the ground.
DROP TABLE IF EXISTS brand_tract_tmp_tbl;
CREATE TEMP TABLE brand_tract_tmp_tbl AS
SELECT brand_name, tract_geoid
FROM provider_brand_tract_tech_tbl
WHERE technology IN (10, 40, 50)
GROUP BY 1, 2;

CREATE INDEX brand_tract_tmp_ix ON brand_tract_tmp_tbl (brand_name);
ANALYZE brand_tract_tmp_tbl;

DROP TABLE IF EXISTS brand_size_tmp_tbl;
CREATE TEMP TABLE brand_size_tmp_tbl AS
SELECT brand_name, count(*) AS tracts
FROM brand_tract_tmp_tbl
GROUP BY 1;

CREATE UNIQUE INDEX brand_size_tmp_ix ON brand_size_tmp_tbl (brand_name);
ANALYZE brand_size_tmp_tbl;

\echo
\echo Brands in the BDC wireline footprint, and how many tracts each covers.
\echo
SELECT count(*) AS brands, sum(tracts) AS brand_tract_rows
FROM brand_size_tmp_tbl;

-- One ISP name mapped to two or more BDC brands is the case that matters.
-- Each such ISP has its address space attached to every brand it maps to, so
-- if those brands do not overlap, the ranges land on ground the ISP does not
-- serve.
DROP TABLE IF EXISTS multi_brand_isp_tmp_tbl;
CREATE TEMP TABLE multi_brand_isp_tmp_tbl AS
SELECT a.ipapi_side, count(DISTINCT a.bdc_side) AS brands
FROM carrier_alias_tbl a
WHERE a.status IN ('confirmed', 'llm')
GROUP BY 1
HAVING count(DISTINCT a.bdc_side) > 1;

ANALYZE multi_brand_isp_tmp_tbl;

\echo
\echo ISP names that one or more recorded pairings map to several BDC brands.
\echo Each of these spreads one address space over several footprints.
\echo
SELECT count(*) AS isps_mapped_to_several_brands,
       coalesce(max(brands), 0) AS most_brands_for_one_isp
FROM multi_brand_isp_tmp_tbl;

\echo
\echo Every pair of brands that share an ISP name, with the overlap of their
\echo wireline footprints. jaccard near zero means they serve different ground
\echo and the pairing needs your ruling. Ordered with the worst first.
\echo
WITH pairs AS (
    SELECT DISTINCT
           m.ipapi_side,
           least(x.bdc_side, y.bdc_side)    AS brand_a,
           greatest(x.bdc_side, y.bdc_side) AS brand_b
    FROM multi_brand_isp_tmp_tbl m
    JOIN carrier_alias_tbl x ON x.ipapi_side = m.ipapi_side
                            AND x.status IN ('confirmed', 'llm')
    JOIN carrier_alias_tbl y ON y.ipapi_side = m.ipapi_side
                            AND y.status IN ('confirmed', 'llm')
                            AND y.bdc_side <> x.bdc_side
)
SELECT p.ipapi_side,
       p.brand_a,
       p.brand_b,
       coalesce(sa.tracts, 0) AS tracts_a,
       coalesce(sb.tracts, 0) AS tracts_b,
       coalesce(ov.shared, 0) AS shared_tracts,
       CASE WHEN coalesce(sa.tracts, 0) + coalesce(sb.tracts, 0)
                 - coalesce(ov.shared, 0) = 0 THEN NULL
            ELSE round(coalesce(ov.shared, 0)::numeric
                 / (sa.tracts + sb.tracts - coalesce(ov.shared, 0)), 4)
       END AS jaccard,
       CASE WHEN sa.tracts IS NULL OR sb.tracts IS NULL
                 THEN 'one side is not a BDC wireline brand, so this cannot be measured'
            WHEN coalesce(ov.shared, 0) = 0
                 THEN 'DISJOINT, these brands share no tract'
            WHEN coalesce(ov.shared, 0)::numeric
                 / least(sa.tracts, sb.tracts) < 0.1
                 THEN 'almost disjoint'
            WHEN coalesce(ov.shared, 0)::numeric
                 / least(sa.tracts, sb.tracts) > 0.9
                 THEN 'the smaller brand sits inside the larger, consistent with a rebrand'
            ELSE 'partly overlapping'
       END AS reading
FROM pairs p
LEFT JOIN brand_size_tmp_tbl sa ON sa.brand_name = p.brand_a
LEFT JOIN brand_size_tmp_tbl sb ON sb.brand_name = p.brand_b
LEFT JOIN LATERAL (
    SELECT count(*) AS shared
    FROM brand_tract_tmp_tbl ta
    JOIN brand_tract_tmp_tbl tb ON tb.tract_geoid = ta.tract_geoid
                               AND tb.brand_name = p.brand_b
    WHERE ta.brand_name = p.brand_a
) ov ON true
ORDER BY coalesce(ov.shared, 0) ASC,
         coalesce(sa.tracts, 0) + coalesce(sb.tracts, 0) DESC;

\echo
\echo How many of those brand pairs fall in each reading.
\echo
WITH pairs AS (
    SELECT DISTINCT
           least(x.bdc_side, y.bdc_side)    AS brand_a,
           greatest(x.bdc_side, y.bdc_side) AS brand_b
    FROM multi_brand_isp_tmp_tbl m
    JOIN carrier_alias_tbl x ON x.ipapi_side = m.ipapi_side
                            AND x.status IN ('confirmed', 'llm')
    JOIN carrier_alias_tbl y ON y.ipapi_side = m.ipapi_side
                            AND y.status IN ('confirmed', 'llm')
                            AND y.bdc_side <> x.bdc_side
), measured AS (
    SELECT p.brand_a, p.brand_b, sa.tracts AS ta, sb.tracts AS tb,
           coalesce(ov.shared, 0) AS shared
    FROM pairs p
    LEFT JOIN brand_size_tmp_tbl sa ON sa.brand_name = p.brand_a
    LEFT JOIN brand_size_tmp_tbl sb ON sb.brand_name = p.brand_b
    LEFT JOIN LATERAL (
        SELECT count(*) AS shared
        FROM brand_tract_tmp_tbl ta
        JOIN brand_tract_tmp_tbl tb ON tb.tract_geoid = ta.tract_geoid
                                   AND tb.brand_name = p.brand_b
        WHERE ta.brand_name = p.brand_a
    ) ov ON true
)
SELECT CASE WHEN ta IS NULL OR tb IS NULL THEN 'not measurable'
            WHEN shared = 0 THEN 'disjoint'
            WHEN shared::numeric / least(ta, tb) < 0.1 THEN 'almost disjoint'
            WHEN shared::numeric / least(ta, tb) > 0.9 THEN 'nested, looks like a rebrand'
            ELSE 'partly overlapping'
       END AS reading,
       count(*) AS brand_pairs
FROM measured
GROUP BY 1
ORDER BY 2 DESC;

\echo
\echo Nothing was written. Every pairing reported above is still recorded
\echo exactly as it was. The disjoint ones are the ones to rule on.
\echo
