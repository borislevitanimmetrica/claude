-- ===========================================================================
-- state_gov_out_of_scope.sql
--
-- Boris 2026-11-25: "Remove state governments. They are DIA customers and
-- out of scope for the ITDK-BDC work."
--
-- WHAT THIS CHANGES ABOUT MY UNDERSTANDING. I had built
-- carrier_name_is_state_government as a MATCHING rule, forcing tier 0, and
-- then disclosed it as an extra step not in his algorithm. It is neither. It
-- is a SCOPE filter, the same kind as wireless and the same kind as
-- 1-800-Flowers: a state government buys dedicated internet access, ip-api
-- locates it at its own premises, and no headend inference applies to it.
-- So these ASNs do not belong in the queue at all, matched or unmatched.
--
-- Measured on his 2026-11-25 run: 50 ASNs, 5,799 ZIP-capable ranges, led by
-- State of WI Dept. of Administration at 1,484 and State of NC - State
-- Telecommunications Services at 926.
--
-- WHAT IT WRITES. One out_of_scope row per state-government ASN in
-- asn_bdc_brand_map_tbl, which is the same mechanism that retired
-- 1-800-Flowers. An out_of_scope ASN is never offered a candidate again.
--
-- PRE-MORTEM, in this turn rather than after it. The DELETE below removes
-- brand decisions for these ASNs, because an ASN cannot be both out of scope
-- and mapped to plant. What it can destroy: machine-written brand rows for
-- the 50 state-government ASNs, all reproducible by re-running the matcher
-- and the loaders. What it cannot reach: any ASN that is not a state
-- government by carrier_name_is_state_government, whose 10 positive and 14
-- negative test cases run on every execution of carrier_asn_match.sql and
-- raise if either direction breaks. Municipal carriers are explicitly NOT
-- caught: City of Fort Collins holds Fort Collins Connexion and Carthage
-- Water and Electric holds its own plant, and both stay in scope. The rows
-- removed are listed BEFORE the delete and counted after.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/state_gov_out_of_scope.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('ipapi_asn_tbl'), ('asn_bdc_brand_map_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_asn_match.sql first. Nothing was written.', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc
                   WHERE proname = 'carrier_name_is_state_government') THEN
        RAISE EXCEPTION 'carrier_name_is_state_government does not exist. Run carrier_asn_match.sql first. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

\echo
\echo ================================================================
\echo THE STATE GOVERNMENT ASNs, going out of scope. DIA customers:
\echo ip-api locates them at their own premises, so no headend
\echo inference applies. Boris 2026-11-25.
\echo ================================================================
\echo
SELECT a.asn, a.as_operator, a.zip_capable_ranges,
       EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
               WHERE m.asn = a.asn AND m.decision = 'brand') AS had_a_brand_decision
FROM ipapi_asn_tbl a
WHERE carrier_name_is_state_government(a.as_operator)
ORDER BY a.zip_capable_ranges DESC NULLS LAST, a.asn;

\echo
\echo Brand decisions about to be removed from these ASNs, if any.
\echo
SELECT m.asn, a.as_operator, m.bdc_brand_name, m.note
FROM asn_bdc_brand_map_tbl m
JOIN ipapi_asn_tbl a ON a.asn = m.asn
WHERE m.decision = 'brand'
  AND carrier_name_is_state_government(a.as_operator)
ORDER BY m.asn;

DO $write$
DECLARE
    brands_removed bigint;
    scoped          bigint;
    municipal_hit   bigint;
BEGIN
    -- A municipal carrier must never be caught by this. Asserted rather than
    -- trusted, because the cost of being wrong is deleting real plant.
    SELECT count(*) INTO municipal_hit
    FROM (VALUES ('City of Fort Collins'), ('Carthage Water and Electric'),
                 ('The City of New York'), ('City of Chattanooga')) AS v(n)
    WHERE carrier_name_is_state_government(v.n);
    IF municipal_hit > 0 THEN
        RAISE EXCEPTION 'the state government test catches % municipal name(s). Municipal carriers own real plant and must stay in scope. Nothing was written.', municipal_hit;
    END IF;

    DELETE FROM asn_bdc_brand_map_tbl m
    WHERE m.decision = 'brand'
      AND EXISTS (SELECT 1 FROM ipapi_asn_tbl a
                  WHERE a.asn = m.asn
                    AND carrier_name_is_state_government(a.as_operator));
    GET DIAGNOSTICS brands_removed = ROW_COUNT;

    INSERT INTO asn_bdc_brand_map_tbl (asn, decision, bdc_brand_name,
                                       bdc_provider_id, note)
    SELECT a.asn, 'out_of_scope', NULL, NULL,
           'boris 2026-11-25: state governments are DIA customers and out of scope for the ITDK-BDC work. ip-api locates them at their own premises, so no headend inference applies. Registry name: ' || a.as_operator
    FROM ipapi_asn_tbl a
    WHERE carrier_name_is_state_government(a.as_operator)
      AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                      WHERE m.asn = a.asn AND m.decision = 'out_of_scope');
    GET DIAGNOSTICS scoped = ROW_COUNT;

    RAISE NOTICE 'removed % brand decision(s) and marked % ASN(s) out of scope', brands_removed, scoped;
END
$write$;

ANALYZE asn_bdc_brand_map_tbl;

\echo
\echo The decision map now.
\echo
SELECT count(*)                                            AS rows_held,
       count(DISTINCT asn)                                 AS distinct_asns,
       count(*) FILTER (WHERE decision = 'brand')          AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier')  AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')   AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo Contradictions. An ASN cannot be out of scope and mapped to plant.
\echo Must be empty.
\echo
SELECT m.asn, string_agg(DISTINCT m.decision, ' and ') AS decisions
FROM asn_bdc_brand_map_tbl m
WHERE m.decision IN ('brand', 'out_of_scope')
GROUP BY m.asn
HAVING count(DISTINCT m.decision) > 1;

\echo
\echo ZIP-capable address space now out of scope for this subsystem, which is
\echo address space that needs no headend and is not a gap in the result.
\echo
SELECT count(DISTINCT a.asn)              AS asns,
       sum(a.zip_capable_ranges)          AS zip_capable_ranges
FROM ipapi_asn_tbl a
JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
WHERE m.decision = 'out_of_scope';

\timing off
