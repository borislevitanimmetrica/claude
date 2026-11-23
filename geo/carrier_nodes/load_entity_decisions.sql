-- ===========================================================================
-- load_entity_decisions.sql
--
-- Writes the entity proposals Boris approved into asn_bdc_brand_map_tbl.
--
-- Boris 2026-11-22: "Proposals confirmed."
--
-- WHAT IS WRITTEN AND WHAT IS NOT
--   weakest_status = 'confirmed'  written. Both the ip-api name and the BDC
--                                 brand are names Boris confirmed.
--   weakest_status = 'proposed'   NOT written. One side is a spelling I
--                                 supplied. These are listed for an explicit
--                                 yes, because "proposals confirmed" cannot
--                                 reasonably extend to names he never saw
--                                 attributed. Set the variable below to load
--                                 them too.
--
-- To include the proposed ones:
--   psql -v include_proposed=yes -f .../load_entity_decisions.sql
--
-- Uses NOT EXISTS, never ON CONFLICT: asn_map_multibrand_migration.sql
-- replaces the primary key with a unique index over an expression, and
-- ON CONFLICT (asn) then fails. That failure has now happened twice on this
-- database.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/load_entity_decisions.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\if :{?include_proposed}
\else
  \set include_proposed no
\endif
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('carrier_entity_proposal_tbl'), ('asn_bdc_brand_map_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_entity.sql first. Nothing was written.', missing;
    END IF;

    -- The multi-brand migration is a hard prerequisite. Without it the
    -- single-column primary key silently refuses the second brand of any
    -- carrier that files under more than one, which is most of them.
    IF EXISTS (SELECT 1 FROM pg_constraint con
               JOIN pg_class rel ON rel.oid = con.conrelid
               WHERE rel.relname = 'asn_bdc_brand_map_tbl' AND con.contype = 'p') THEN
        RAISE EXCEPTION 'asn_bdc_brand_map_tbl still has a primary key on asn, so it can hold only one brand per ASN. Run asn_map_multibrand_migration.sql first. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

\echo
\echo What is about to be written, grouped by entity.
\echo
SELECT p.entity_key, p.display_name,
       count(*)                                     AS rows_to_write,
       count(DISTINCT p.asn)                        AS asns,
       count(DISTINCT p.brand_name)                 AS brands,
       p.weakest_status
FROM carrier_entity_proposal_tbl p
GROUP BY p.entity_key, p.display_name, p.weakest_status
ORDER BY p.weakest_status, count(DISTINCT p.asn) DESC;

\echo
\echo Rows held back because one side is a spelling I supplied rather than
\echo one you confirmed. Re-run with -v include_proposed=yes to load these.
\echo
SELECT p.asn, p.entity_key, p.provider_id, left(p.brand_name, 26) AS brand_name,
       left(p.ipapi_names, 34) AS ipapi_names, p.zip_capable_ranges
FROM carrier_entity_proposal_tbl p
WHERE p.weakest_status = 'proposed'
ORDER BY p.zip_capable_ranges DESC NULLS LAST, p.asn
LIMIT 40;

\echo
\echo HELD BACK: the ISP evidence contradicts the entity. These are the
\echo Frontier ASNs. The entity layer resolves the operator name Verizon
\echo Business to the verizon entity, while the ip-api ISP name on the same
\echo ranges says Frontier, and the plant is Frontier plant. Writing the
\echo entity answer here would be the error you refuted, so they are NOT
\echo written and need one word from you.
\echo
SELECT p.asn, p.entity_key, left(p.brand_name, 20) AS entity_brand,
       left(d.isp_commonest, 26) AS ipapi_isp_says,
       d.isp_suggests_provider_id AS isp_provider,
       left(d.isp_suggests_brand, 20) AS isp_brand,
       p.zip_capable_ranges
FROM carrier_entity_proposal_tbl p
JOIN asn_isp_disagree_tbl d ON d.asn = p.asn
WHERE NOT d.isp_is_a_larger_asn_upstream
  AND d.isp_suggests_brand IS DISTINCT FROM p.brand_name
ORDER BY p.zip_capable_ranges DESC NULLS LAST, p.asn;

-- The INSERT is plain SQL rather than a DO block because psql does NOT
-- interpolate its variables inside a dollar-quoted body; :'include_proposed'
-- there is a syntax error, which is how the first version of this file
-- failed. The row count is the INSERT tag printed below.
\echo
\echo Writing. The INSERT tag below is the number of rows added.
\echo
INSERT INTO asn_bdc_brand_map_tbl
       (asn, decision, bdc_brand_name, bdc_provider_id, note)
SELECT p.asn, 'brand', p.brand_name, p.provider_id,
       'Boris 2026-11-22 confirmed the entity proposals. Entity '
       || p.entity_key || '. Reached from the ip-api name(s) '
       || p.ipapi_names || ' matched on ' || p.matched_on
       || '. Status ' || p.weakest_status || '.'
FROM carrier_entity_proposal_tbl p
WHERE (p.weakest_status = 'confirmed' OR :'include_proposed' = 'yes')
  AND p.brand_name IS NOT NULL
  AND p.provider_id IS NOT NULL
  -- Not where the ISP name contradicts the entity and is not mere transit.
  AND NOT EXISTS (SELECT 1 FROM asn_isp_disagree_tbl d
                  WHERE d.asn = p.asn
                    AND NOT d.isp_is_a_larger_asn_upstream
                    AND d.isp_suggests_brand IS DISTINCT FROM p.brand_name)
  AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                  WHERE m.asn = p.asn
                    AND m.bdc_brand_name = p.brand_name
                    AND m.bdc_provider_id = p.provider_id);

ANALYZE asn_bdc_brand_map_tbl;

\echo
\echo The decision map now.
\echo
SELECT count(*)                                           AS rows_held,
       count(DISTINCT asn)                                AS distinct_asns,
       count(*) FILTER (WHERE decision = 'brand')         AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier')  AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')   AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo Contradictions. An ASN cannot be a carrier and not one. Must be empty.
\echo
SELECT asn, string_agg(DISTINCT decision, ', ' ORDER BY decision) AS decisions
FROM asn_bdc_brand_map_tbl
GROUP BY asn HAVING count(DISTINCT decision) > 1
ORDER BY asn;

\echo
\echo How much probed ZIP-capable address space is now decided.
\echo
SELECT (SELECT sum(a.zip_capable_ranges) FROM ipapi_asn_tbl a
        JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
        WHERE m.decision = 'brand')                        AS mapped_to_a_brand,
       (SELECT sum(a.zip_capable_ranges) FROM ipapi_asn_tbl a
        JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
        WHERE m.decision IN ('not_a_carrier', 'out_of_scope')) AS retired,
       (SELECT sum(a.zip_capable_ranges) FROM ipapi_asn_tbl a
        WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                          WHERE m.asn = a.asn))            AS still_undecided,
       (SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl)  AS all_probed;

\echo
\echo The largest ASNs still undecided, which is the remaining work.
\echo
SELECT a.asn, left(a.as_operator, 38) AS as_operator,
       left(coalesce(a.isp_commonest, ''), 28) AS ipapi_isp,
       a.zip_capable_ranges
FROM ipapi_asn_tbl a
WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn)
ORDER BY a.zip_capable_ranges DESC NULLS LAST
LIMIT 30;

\timing off
