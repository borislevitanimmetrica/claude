-- ===========================================================================
-- load_candidate_decisions.sql
--
-- Writes the STRING-RULE candidates into asn_bdc_brand_map_tbl.
--
-- Boris 2026-11-22, on the list of the largest ASNs still undecided: "all
-- matched properly." Those ASNs had candidates at tier 1 which were never
-- written, which is the only reason they read as undecided. AT&T to AT&T,
-- CenturyLink to CenturyLink, Windstream to Windstream, Google to Google
-- Fiber, Cox, Cogent, Brightspeed and the rest.
--
-- WHAT IS WRITTEN
--   Every tier 1 or tier 2 candidate for an ASN whose candidates all point
--   at ONE provider_id. Several brand spellings under that one provider are
--   all written, because a carrier files under several and all of them are
--   the answer: AS7029 Windstream holds both Windstream and
--   "Windstream Communications," under provider 131413.
--
-- WHAT IS HELD BACK, AND WHY IT NEEDS YOU AND NOT ME
--   1. ASNs whose candidates span SEVERAL provider_ids. That is a choice
--      between different companies, not a spelling: AS7782 Alaska
--      Communications drew ALASKA COMMUNICATIONS at 130081, Alaska Telephone
--      Company at 130029 and Fibre Alaska at 330010.
--   2. ASNs where the ip-api ISP name contradicts the registry name and
--      points at a different brand. These are the six Frontier ASNs.
--   3. Pairs in carrier_unrelated_tbl, which cannot appear as candidates at
--      all.
--
-- To include the multi-provider ones anyway, which I do NOT advise:
--   psql -v include_multi_provider=yes -f .../load_candidate_decisions.sql
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/load_candidate_decisions.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\if :{?include_multi_provider}
\else
  \set include_multi_provider no
\endif
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('asn_brand_candidate_tbl'), ('asn_bdc_brand_map_tbl'),
                 ('asn_isp_disagree_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_asn_match.sql first. Nothing was written.', missing;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint con
               JOIN pg_class rel ON rel.oid = con.conrelid
               WHERE rel.relname = 'asn_bdc_brand_map_tbl' AND con.contype = 'p') THEN
        RAISE EXCEPTION 'asn_bdc_brand_map_tbl still has a primary key on asn and can hold only one brand per ASN. Run asn_map_multibrand_migration.sql first. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- One row per ASN saying how many providers its candidates point at.
DROP TABLE IF EXISTS candidate_shape_tbl;
CREATE TABLE candidate_shape_tbl AS
SELECT c.asn,
       count(DISTINCT c.provider_id) AS providers,
       count(*)                      AS candidate_rows,
       min(c.tier)                   AS best_tier,
       max(c.zip_capable_ranges)     AS zip_capable_ranges,
       EXISTS (SELECT 1 FROM asn_isp_disagree_tbl d
               WHERE d.asn = c.asn
                 AND NOT d.isp_is_a_larger_asn_upstream
                 AND NOT EXISTS (SELECT 1 FROM asn_brand_candidate_tbl c2
                                 WHERE c2.asn = c.asn
                                   AND c2.brand_name = d.isp_suggests_brand))
                                     AS isp_contradicts
FROM asn_brand_candidate_tbl c
WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = c.asn)
GROUP BY c.asn;

ANALYZE candidate_shape_tbl;

\echo
\echo The shape of what is on offer.
\echo
SELECT CASE WHEN isp_contradicts THEN 'held: ip-api ISP name disagrees'
            WHEN providers > 1   THEN 'held: candidates span several providers'
            ELSE 'writing: one provider, no contradiction' END AS disposition,
       count(*)                AS asns,
       sum(candidate_rows)     AS candidate_rows,
       sum(zip_capable_ranges) AS zip_capable_ranges
FROM candidate_shape_tbl
GROUP BY 1 ORDER BY sum(zip_capable_ranges) DESC;

\echo
\echo HELD BACK, candidates spanning several providers. This is a choice
\echo between companies and only you can make it.
\echo
SELECT c.asn, left(c.as_operator, 28) AS as_operator,
       c.provider_id, left(c.brand_name, 26) AS brand_name, c.tier,
       c.brand_tracts, c.zip_capable_ranges
FROM asn_brand_candidate_tbl c
JOIN candidate_shape_tbl s ON s.asn = c.asn
WHERE s.providers > 1 AND NOT s.isp_contradicts
ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn, c.tier, c.brand_name
LIMIT 40;

\echo
\echo HELD BACK, the ip-api ISP name points at a different brand.
\echo
SELECT c.asn, left(c.as_operator, 24) AS registry_says,
       c.brand_name AS candidate_brand,
       left(d.isp_commonest, 24) AS ipapi_isp_says,
       d.isp_suggests_brand AS isp_brand,
       c.zip_capable_ranges
FROM asn_brand_candidate_tbl c
JOIN candidate_shape_tbl s ON s.asn = c.asn AND s.isp_contradicts
JOIN asn_isp_disagree_tbl d ON d.asn = c.asn AND NOT d.isp_is_a_larger_asn_upstream
ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn
LIMIT 20;

\echo
\echo Writing. The INSERT tag below is the number of rows added.
\echo
INSERT INTO asn_bdc_brand_map_tbl
       (asn, decision, bdc_brand_name, bdc_provider_id, note)
SELECT c.asn, 'brand', c.brand_name, c.provider_id,
       'Boris 2026-11-22: the undecided list was all matched properly. Name '
       || 'rule tier ' || c.tier || ' from the operator name ' || c.as_operator
       || '; ip-api ISP agreed at tier ' || c.tier_isp_agrees || '.'
FROM asn_brand_candidate_tbl c
JOIN candidate_shape_tbl s ON s.asn = c.asn
WHERE NOT s.isp_contradicts
  AND (s.providers = 1 OR :'include_multi_provider' = 'yes')
  AND c.brand_name IS NOT NULL
  AND c.provider_id IS NOT NULL
  AND NOT carrier_pair_is_unrelated(c.as_operator, c.brand_name)
  AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                  WHERE m.asn = c.asn
                    AND m.bdc_brand_name = c.brand_name
                    AND m.bdc_provider_id = c.provider_id);

ANALYZE asn_bdc_brand_map_tbl;

\echo
\echo The decision map now.
\echo
SELECT count(*)                                          AS rows_held,
       count(DISTINCT asn)                               AS distinct_asns,
       count(*) FILTER (WHERE decision = 'brand')        AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier') AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')  AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo Contradictions. Must be empty.
\echo
SELECT asn, string_agg(DISTINCT decision, ', ' ORDER BY decision) AS decisions
FROM asn_bdc_brand_map_tbl
GROUP BY asn HAVING count(DISTINCT decision) > 1
ORDER BY asn;

\echo
\echo Probed ZIP-capable address space, by what is now known about it.
\echo
SELECT (SELECT sum(z.r) FROM (SELECT DISTINCT a.asn, a.zip_capable_ranges AS r
          FROM ipapi_asn_tbl a JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
          WHERE m.decision = 'brand') z)                   AS mapped_to_a_brand,
       (SELECT sum(z.r) FROM (SELECT DISTINCT a.asn, a.zip_capable_ranges AS r
          FROM ipapi_asn_tbl a JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
          WHERE m.decision IN ('not_a_carrier','out_of_scope')) z) AS retired,
       (SELECT sum(a.zip_capable_ranges) FROM ipapi_asn_tbl a
        WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                          WHERE m.asn = a.asn))            AS still_undecided,
       (SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl)  AS all_probed;

\timing off
