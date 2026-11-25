-- ===========================================================================
-- load_llm_pairings.sql
--
-- STEP 3 of the algorithm Boris gave on 2026-11-24:
--
--   1. From the table.
--   2. For items not in the table, exact match after punctuation and
--      suffixes "Inc.", "LLC" etc. are dropped. Record in table.
--   3. Remaining matches should be run through an LLM to determine whether
--      there is any relationship between the two brands. If there is,
--      record in table.
--
-- This file is step 3's recording half. The adjudication itself is done by
-- the LLM in conversation and arrives as a TSV of verdicts with a reason per
-- row, which is loaded here.
--
--   y     the two brands are related. Recorded with status 'llm', which
--         carrier_keys_are_recorded treats as a match, exactly as a
--         confirmed pairing is.
--   n     not related. Recorded in carrier_unrelated_tbl, so no later rule
--         can offer the pair again in either orientation, and removed from
--         the pairing list.
--   flag  the LLM will not decide. Left as 'proposed', which matches
--         nothing, and listed for Boris at the end.
--
-- WHY 'llm' RATHER THAN 'confirmed'. His algorithm authorises the LLM
-- verdict to be recorded and used, so it matches. It is kept under its own
-- status because he must be able to audit or revoke the machine's judgements
-- without touching his own. Every row carries the reason it was given.
--
-- THE REASON IS MANDATORY. A row with an empty reason is rejected, because a
-- verdict without a stated basis cannot be audited and is indistinguishable
-- from a guess.
--
-- INPUT: the verdicts file committed alongside this file in the repository,
-- at the fixed path in the copy command below. To adjudicate a different
-- set, overwrite that file, or copy yours over it.
--
-- The path is fixed deliberately. A psql variable in a copy command is one
-- of the few things I could not verify this turn, because the sandbox
-- database was unavailable, and an unverified construct in the one statement
-- that reads the input is not worth the convenience.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/load_llm_pairings.sql
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
    IF EXISTS (SELECT 1 FROM pg_constraint con
               JOIN pg_class rel ON rel.oid = con.conrelid
               WHERE rel.relname = 'carrier_alias_tbl' AND con.contype = 'c'
                 AND pg_get_constraintdef(con.oid) LIKE '%status%'
                 AND pg_get_constraintdef(con.oid) NOT LIKE '%llm%') THEN
        RAISE EXCEPTION 'carrier_alias_tbl still forbids the status llm. Re-run carrier_asn_match.sql, which widens the constraint. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

DROP TABLE IF EXISTS llm_verdict_stage_tbl;
CREATE TABLE llm_verdict_stage_tbl (
    ipapi_side text,
    bdc_side   text,
    verdict    text,
    reason     text);

\copy llm_verdict_stage_tbl FROM '/home/boris/geo/src/claude/geo/carrier_nodes/llm_pairing_verdicts.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

ANALYZE llm_verdict_stage_tbl;

DO $check$
DECLARE bad bigint; detail text;
BEGIN
    SELECT count(*), string_agg(format('%s to %s had %L', ipapi_side, bdc_side, verdict), '; ')
      INTO bad, detail
    FROM llm_verdict_stage_tbl
    WHERE lower(btrim(coalesce(verdict, ''))) NOT IN ('y', 'yes', 'n', 'no', 'flag');
    IF bad > 0 THEN
        RAISE EXCEPTION 'the verdict column holds % value that is neither y, n nor flag: %. Nothing was written.', bad, left(detail, 400);
    END IF;

    SELECT count(*), string_agg(format('%s to %s', ipapi_side, bdc_side), '; ')
      INTO bad, detail
    FROM llm_verdict_stage_tbl
    WHERE btrim(coalesce(reason, '')) = '';
    IF bad > 0 THEN
        RAISE EXCEPTION '% verdict(s) carry no reason: %. A verdict without a stated basis cannot be audited. Nothing was written.', bad, left(detail, 300);
    END IF;

    SELECT count(*), string_agg(format('%s to %s', ipapi_side, bdc_side), '; ')
      INTO bad, detail
    FROM llm_verdict_stage_tbl s
    WHERE carrier_name_compact(s.ipapi_side) IS NULL
       OR carrier_name_compact(s.bdc_side) IS NULL;
    IF bad > 0 THEN
        RAISE EXCEPTION '% row(s) have a name that compacts to nothing: %. Nothing was written.', bad, left(detail, 300);
    END IF;
    RAISE NOTICE 'precheck on the verdicts passed';
END
$check$;

\echo
\echo What the LLM decided.
\echo
SELECT lower(btrim(verdict)) AS verdict, count(*) AS pairs
FROM llm_verdict_stage_tbl GROUP BY 1 ORDER BY 2 DESC;

-- A pair Boris has ruled unrelated is NOT reopened by the LLM. His ruling
-- outranks step 3, and the count is printed rather than passed over.
DO $hisfirst$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n
    FROM llm_verdict_stage_tbl s
    WHERE lower(btrim(s.verdict)) IN ('y', 'yes')
      AND carrier_keys_are_unrelated(carrier_name_compact(s.ipapi_side),
                                     carrier_name_compact(s.bdc_side));
    IF n > 0 THEN
        RAISE NOTICE 'skipping % pair(s) the LLM called related that YOU have ruled unrelated. Your ruling wins.', n;
    END IF;
END
$hisfirst$;

-- RELATED: record it, as status llm.
INSERT INTO carrier_alias_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, status, note)
SELECT DISTINCT ON (carrier_name_compact(s.ipapi_side), carrier_name_compact(s.bdc_side))
       s.ipapi_side, s.bdc_side,
       carrier_name_compact(s.ipapi_side), carrier_name_compact(s.bdc_side),
       'llm', 'llm step 3: ' || btrim(s.reason)
FROM llm_verdict_stage_tbl s
WHERE lower(btrim(s.verdict)) IN ('y', 'yes')
  AND NOT carrier_keys_are_unrelated(carrier_name_compact(s.ipapi_side),
                                     carrier_name_compact(s.bdc_side))
ON CONFLICT (ipapi_key, bdc_key) DO UPDATE
SET status = CASE WHEN carrier_alias_tbl.status = 'confirmed'
                  THEN 'confirmed' ELSE 'llm' END,
    note = CASE WHEN carrier_alias_tbl.status = 'confirmed'
                THEN carrier_alias_tbl.note
                ELSE excluded.note END,
    ruled_at = now();

-- NOT RELATED: record the negative so nothing can offer it again.
INSERT INTO carrier_unrelated_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, note)
SELECT DISTINCT ON (carrier_name_compact(s.ipapi_side), carrier_name_compact(s.bdc_side))
       s.ipapi_side, s.bdc_side,
       carrier_name_compact(s.ipapi_side), carrier_name_compact(s.bdc_side),
       'llm step 3: ' || btrim(s.reason)
FROM llm_verdict_stage_tbl s
WHERE lower(btrim(s.verdict)) IN ('n', 'no')
ON CONFLICT (ipapi_key, bdc_key) DO NOTHING;

DELETE FROM carrier_alias_tbl x
USING llm_verdict_stage_tbl s
WHERE x.ipapi_key = carrier_name_compact(s.ipapi_side)
  AND x.bdc_key   = carrier_name_compact(s.bdc_side)
  AND x.status <> 'confirmed'
  AND lower(btrim(s.verdict)) IN ('n', 'no');

ANALYZE carrier_alias_tbl;
ANALYZE carrier_unrelated_tbl;

-- The invariant that cost 769 decisions when it was absent elsewhere: a pair
-- cannot be both recorded as the same network and recorded as unrelated.
DO $contradiction$
DECLARE bad bigint; detail text;
BEGIN
    SELECT count(*), string_agg(x.ipapi_side || ' to ' || x.bdc_side, '; ')
      INTO bad, detail
    FROM carrier_alias_tbl x
    WHERE x.status IN ('confirmed', 'llm')
      AND carrier_keys_are_unrelated(x.ipapi_key, x.bdc_key);
    IF bad > 0 THEN
        RAISE EXCEPTION 'CONTRADICTION: % pairing(s) are recorded as the same network AND as unrelated: %. The unrelated ruling wins, so the pairing would silently do nothing.', bad, left(detail, 300);
    END IF;
    RAISE NOTICE 'no pairing is both recorded and unrelated';
END
$contradiction$;

\echo
\echo The pairing table now. confirmed is yours, llm is step 3, proposed
\echo decides nothing.
\echo
SELECT status, count(*) AS pairings FROM carrier_alias_tbl GROUP BY 1 ORDER BY 1;

\echo
\echo WHAT THE LLM WOULD NOT DECIDE. These stay proposed and match nothing.
\echo They need you, and the reason each was refused is given.
\echo
SELECT s.ipapi_side, s.bdc_side, s.reason
FROM llm_verdict_stage_tbl s
WHERE lower(btrim(s.verdict)) = 'flag'
ORDER BY 1, 2;

\echo
\echo Pairings still proposed after this, which the LLM has not yet seen.
\echo
SELECT count(*) AS still_proposed FROM carrier_alias_tbl WHERE status = 'proposed';

\echo
\echo Writing them out for the next adjudication round.
\echo
\copy (SELECT x.ipapi_side, x.bdc_side, ''::text AS verdict, ''::text AS reason FROM carrier_alias_tbl x WHERE x.status = 'proposed' ORDER BY x.ipapi_side, x.bdc_side) TO '/home/boris/geo/llm_pairings_todo.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\echo
\echo NOW RE-RUN, or nothing recorded here takes effect:
\echo   psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_asn_match.sql
\echo   psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_link_rederive.sql
\echo

\timing off
