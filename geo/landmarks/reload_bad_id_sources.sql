-- reload_bad_id_sources.sql
--
-- Remove the three state sources whose rows were collapsed by a guessed id
-- column, so they can be reloaded correctly. GUARDED: it refuses to delete
-- anything that carries enrichment.
--
-- =========================================================================
-- SCOPE: az_azgeo ONLY. Florida and Alabama are already correct.
-- =========================================================================
--
-- This file first ran against fl_msid, az_azgeo and al_alsde, and after the
-- reload two of the three came out right:
--
--   fl_msid   80 -> 3,693 rows. Correct: the dry run reports 3,693 distinct
--             keys over 3,700 usable, and the 7 collapsed rows are virtual
--             programmes that really do share a name and ZIP
--   al_alsde  1,797 -> 1,788 rows, which looked like a failure and is not.
--             2,238 rows collapse, but report_id_collisions shows 1,786 of
--             the 1,788 keys carry exactly ONE website, so those are
--             duplicated entity rows in the ALSDE export and collapsing them
--             loses nothing. Only 2 websites are genuinely lost. Alabama
--             really does have about 1,788 distinct school sites, and 4,026
--             was the inflated number
--   az_azgeo  1,163 -> 3,159, still 331 short of the correct 3,490
--
-- ARIZONA HAD A SECOND, DIFFERENT DEFECT. Its feature service returns rows
-- with an EMPTY SchoolName, so the name-plus-ZIP fallback produced "|85020"
-- as the key for every unnamed school in that ZIP: 21 collapsed onto one row
-- there, 15 in 85053, 12 in 85258, and 354 distinct websites were lost across
-- the state. Fixed by falling back to the HOST when the name is blank, which
-- is never empty because unusable websites are already skipped. Arizona now
-- yields 3,490 keys with 23 websites lost instead of 354.
--
-- So only az_azgeo needs removing. Re-running this file is still safe for the
-- others; they are simply not named any more.
--
-- =========================================================================
-- WHAT WENT WRONG ORIGINALLY
-- =========================================================================
--
-- state_loader.resolve_columns falls back to the probe's ncesid detector when
-- states.json names no id column, and the detected column became the upsert
-- key without anyone checking that it is unique per row. It was not:
--
--   source      guessed id column   unique   rows lost
--   fl_msid     FEDERAL_DIST_NO      1.2 pct   3,620 of 3,700   98 pct
--   az_azgeo    NCES_DID            21.7 pct   2,402 of 3,565   67 pct
--   al_alsde    NCES ID             43.8 pct   2,229 of 4,026   55 pct
--
-- All three are DISTRICT identifiers. Florida has about 80 districts, so every
-- school in a district collapsed onto one row and the loader reported the loss
-- as "3,620 duplicate ids skipped", which reads like success.
--
-- Fixed in state_loader.verify_id_column: an auto-detected id must be unique
-- on at least 95 per cent of the rows carrying a value, or it is rejected with
-- a printed reason and name plus ZIP is used instead. A CONFIGURED id is still
-- trusted, because a human read the file. Texas and Illinois name theirs and
-- were never affected. Tennessee's sde_ncesnumber auto-detects at 100.0 per
-- cent unique and still passes.
--
-- RESIDUAL, measured across all 21 jurisdictions and left in place: 79
-- websites in total, being AZ 23, PA 19, TX 17, MN 16, AL 2, FL 1, IL 1. Each
-- is two genuinely different institutions sharing a name and a ZIP. Fixing
-- them needs the host in the key for every row, which would change every
-- existing id and make the next load insert a duplicate of everything.
-- report_id_collisions prints the figure on every run so it stays visible.
--
-- =========================================================================
-- PRE-MORTEM FOR THE DELETE, WRITTEN BEFORE PROPOSING IT
-- =========================================================================
--
-- WHAT IS DESTROYED: 3,159 az_azgeo rows in landmarks_usa. Every one has
-- lookup_status NULL
-- and ip_address NULL, confirmed by the migrate_new_sources run of 2026-11-06
-- which reported rdap_ok_now = 0 and awaiting_the_chain equal to the full row
-- count for all three. No RDAP lookup, no registrant, no ZIP inference and no
-- onpremises decision is lost.
--
-- WHAT IS NOT TOUCHED: every other source. The 1,032,744 completed RDAP
-- lookups and the 243,716 hosting-rule rows are outside the scope of this
-- DELETE, which names three sources explicitly.
--
-- REVERSIBILITY: complete. All three loaders re-fetch from live URLs and all
-- three were re-run successfully minutes before this file was written.
--
-- WHY NOT JUST RELOAD WITHOUT DELETING: the loader upserts on
-- (source, source_id). The corrected ids are name plus ZIP and differ from the
-- district numbers already stored, so a plain reload would ADD the missing
-- rows and leave the 3,040 old ones beside them. That is 3,040 duplicate
-- landmarks in three states, inflating counts and feeding node_fanout spurious
-- input. Deleting first is cleaner.
--
-- TIMING IS THE WHOLE POINT. Run this BEFORE the enrichment chain. Right now
-- these rows cost nothing to discard. After the chain they carry hours of RDAP
-- work and this file will refuse to run, by design.
--
-- =========================================================================

\timing on
\set ON_ERROR_STOP on
SET lock_timeout = '30s';

\echo ''
\echo '=== 1 of 4: what is here, and does any of it carry enrichment? ==='
SELECT source,
       count(*)                                           AS rows,
       count(*) FILTER (WHERE lookup_status IS NOT NULL)   AS has_lookup_status,
       count(*) FILTER (WHERE ip_address IS NOT NULL)      AS has_ip,
       count(*) FILTER (WHERE onpremises IS NOT NULL)      AS has_onpremises,
       count(*) FILTER (WHERE registrant_1 IS NOT NULL)    AS has_registrant
FROM landmarks_usa
WHERE source IN ('az_azgeo')
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== 2 of 4: the guard. It aborts rather than destroy enrichment. ==='
DO $guard$
DECLARE
    enriched bigint;
BEGIN
    SELECT count(*) INTO enriched
    FROM landmarks_usa
    WHERE source IN ('az_azgeo')
      AND (lookup_status IS NOT NULL
        OR ip_address IS NOT NULL
        OR onpremises IS NOT NULL
        OR registrant_1 IS NOT NULL);

    IF enriched > 0 THEN
        RAISE EXCEPTION
            'REFUSING TO DELETE: % of these rows already carry enrichment. '
            'The chain has run since they were loaded, so discarding them '
            'would throw away RDAP work. Reload them with state_loader '
            '--replace instead, which only touches lm_places_usa, and then '
            're-run migrate_new_sources.sql to add the missing rows beside '
            'the existing ones.', enriched;
    END IF;

    RAISE NOTICE 'guard passed: no enrichment present, the delete is free';
END
$guard$;

\echo ''
\echo '=== 3 of 4: the delete, scoped to exactly three sources ==='
DELETE FROM landmarks_usa
WHERE source IN ('az_azgeo');

\echo ''
\echo '=== 4 of 4: confirm they are gone and nothing else moved ==='
SELECT count(*) AS az_rows_remaining
FROM landmarks_usa
WHERE source IN ('az_azgeo');

SELECT count(*)                                              AS landmarks_usa_total,
       count(*) FILTER (WHERE lookup_status = 'true')         AS rdap_ok_total,
       count(*) FILTER (WHERE onpremises)                     AS onpremises_total,
       count(*) FILTER (WHERE onpremises_reason LIKE 'hosting:%')
                                                              AS hosting_rule_rows
FROM landmarks_usa;

\echo ''
\echo '    rdap_ok_total must still be 12,799,143 and hosting_rule_rows 243,716.'
\echo '    If either moved, stop.'
\echo ''
\echo '    Next, reload the three with the fix, then re-migrate:'
\echo '      python3 state_loader.py --state AZ --replace'
\echo '      psql -f geo/landmarks/migrate_new_sources.sql'
\echo ''
\echo '=== done ==='
\timing off
