-- ===========================================================================
-- load_alias_decisions.sql
--
-- Reads back the file carrier_alias_review.sql wrote and applies the rulings.
--
--   y, yes, Y    the two names are the same network. status becomes
--                confirmed, carrier_name_tier returns 2 for the pair, and
--                every ASN carrying that ip-api name becomes eligible and
--                starts drawing candidates from that brand.
--   n, no, N     different companies. The pairing is DELETED from
--                carrier_alias_tbl and recorded in carrier_unrelated_tbl, so
--                no rule can offer it again, in either orientation.
--   blank        untouched. Still proposed, still matching nothing.
--
-- Anything else in the decision column stops the file with the row named,
-- rather than being guessed at.
--
-- AFTER RUNNING THIS, re-run carrier_asn_match.sql and then
-- load_candidate_decisions.sql. The confirmed pairings only become matches
-- when the matcher next evaluates them.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/load_alias_decisions.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'carrier_alias_tbl') THEN
        RAISE EXCEPTION 'carrier_alias_tbl does not exist. Run carrier_asn_match.sql first. Nothing was written.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'carrier_unrelated_tbl') THEN
        RAISE EXCEPTION 'carrier_unrelated_tbl does not exist. Run carrier_asn_match.sql first. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

DROP TABLE IF EXISTS alias_decision_stage_tbl;
CREATE TABLE alias_decision_stage_tbl (
    ipapi_side            text,
    bdc_side              text,
    asns_with_that_name   text,
    zip_capable_ranges    text,
    brand_wireline_tracts text,
    caveat                text,
    note                  text,
    decision              text);

\copy alias_decision_stage_tbl FROM '/home/boris/geo/carrier_alias_approval.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

ANALYZE alias_decision_stage_tbl;

-- A decision column holding something that is neither yes, no nor blank is
-- not interpreted. It stops the file, because a typo in a column that
-- controls 283,233 ranges must not be read as a no.
DO $check$
DECLARE bad bigint; detail text;
BEGIN
    SELECT count(*), string_agg(format('%s -> %s had %L', ipapi_side, bdc_side, decision), '; ')
      INTO bad, detail
    FROM alias_decision_stage_tbl
    WHERE btrim(coalesce(decision, '')) <> ''
      AND lower(btrim(decision)) NOT IN ('y', 'yes', 'n', 'no');
    IF bad > 0 THEN
        RAISE EXCEPTION 'the decision column holds % value(s) that are neither yes, no nor blank: %. Nothing was written.', bad, left(detail, 400);
    END IF;

    SELECT count(*) INTO bad
    FROM alias_decision_stage_tbl s
    WHERE NOT EXISTS (SELECT 1 FROM carrier_alias_tbl x
                      WHERE x.ipapi_key = carrier_name_compact(s.ipapi_side)
                        AND x.bdc_key   = carrier_name_compact(s.bdc_side));
    IF bad > 0 THEN
        RAISE NOTICE '% row(s) in the file no longer correspond to a pairing in carrier_alias_tbl and will be ignored', bad;
    END IF;
END
$check$;

\echo
\echo What is about to change.
\echo
SELECT lower(btrim(coalesce(decision, ''))) AS decision,
       count(*) AS pairings
FROM alias_decision_stage_tbl
GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo CONFIRMING these, which makes them match from the next run onwards.
\echo
SELECT s.ipapi_side, s.bdc_side, s.zip_capable_ranges
FROM alias_decision_stage_tbl s
WHERE lower(btrim(coalesce(s.decision, ''))) IN ('y', 'yes')
ORDER BY s.ipapi_side, s.bdc_side;

UPDATE carrier_alias_tbl x
SET status = 'confirmed',
    note = coalesce(x.note, '') || ' | confirmed by boris',
    ruled_at = now()
FROM alias_decision_stage_tbl s
WHERE x.ipapi_key = carrier_name_compact(s.ipapi_side)
  AND x.bdc_key   = carrier_name_compact(s.bdc_side)
  AND lower(btrim(coalesce(s.decision, ''))) IN ('y', 'yes')
  AND x.status <> 'confirmed';

\echo
\echo RULED UNRELATED. Deleted from the pairings and recorded, so that no
\echo rule can offer either orientation again.
\echo
SELECT s.ipapi_side, s.bdc_side
FROM alias_decision_stage_tbl s
WHERE lower(btrim(coalesce(s.decision, ''))) IN ('n', 'no')
ORDER BY s.ipapi_side, s.bdc_side;

INSERT INTO carrier_unrelated_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, note)
SELECT DISTINCT ON (carrier_name_compact(s.ipapi_side), carrier_name_compact(s.bdc_side))
       s.ipapi_side, s.bdc_side,
       carrier_name_compact(s.ipapi_side), carrier_name_compact(s.bdc_side),
       'boris ruled the proposed pairing unrelated'
FROM alias_decision_stage_tbl s
WHERE lower(btrim(coalesce(s.decision, ''))) IN ('n', 'no')
  AND carrier_name_compact(s.ipapi_side) IS NOT NULL
  AND carrier_name_compact(s.bdc_side) IS NOT NULL
ON CONFLICT (ipapi_key, bdc_key) DO NOTHING;

DELETE FROM carrier_alias_tbl x
USING alias_decision_stage_tbl s
WHERE x.ipapi_key = carrier_name_compact(s.ipapi_side)
  AND x.bdc_key   = carrier_name_compact(s.bdc_side)
  AND lower(btrim(coalesce(s.decision, ''))) IN ('n', 'no');

ANALYZE carrier_alias_tbl;
ANALYZE carrier_unrelated_tbl;

-- A pairing cannot be confirmed AND unrelated. If that ever holds, the
-- unrelated ruling wins in carrier_name_tier, but the contradiction means
-- one of the two files was answered twice with different words.
DO $contradiction$
DECLARE bad bigint; detail text;
BEGIN
    SELECT count(*), string_agg(x.ipapi_side || ' -> ' || x.bdc_side, '; ')
      INTO bad, detail
    FROM carrier_alias_tbl x
    WHERE x.status = 'confirmed'
      AND carrier_keys_are_unrelated(x.ipapi_key, x.bdc_key);
    IF bad > 0 THEN
        RAISE EXCEPTION 'CONTRADICTION: % pairing(s) are confirmed as the same network AND recorded as unrelated: %. The unrelated ruling would win and the pairing would silently do nothing. Fix one of them.', bad, left(detail, 300);
    END IF;
    RAISE NOTICE 'no pairing is both confirmed and unrelated';
END
$contradiction$;

\echo
\echo The pairings table now.
\echo
SELECT status, count(*) AS pairings FROM carrier_alias_tbl GROUP BY 1 ORDER BY 1;

\echo
\echo Still waiting on you, worth the most first.
\echo
SELECT x.ipapi_side, x.bdc_side,
       (SELECT coalesce(sum(a.zip_capable_ranges), 0) FROM ipapi_asn_tbl a
        WHERE carrier_name_compact(a.as_operator) = x.ipapi_key) AS zip_capable_ranges
FROM carrier_alias_tbl x
WHERE x.status = 'proposed'
ORDER BY 3 DESC, 1, 2
LIMIT 20;

\echo
\echo NOW RE-RUN, in this order, or nothing you just confirmed takes effect:
\echo   psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_asn_match.sql
\echo   psql -f /home/boris/geo/src/claude/geo/carrier_nodes/load_candidate_decisions.sql
\echo

\timing off
