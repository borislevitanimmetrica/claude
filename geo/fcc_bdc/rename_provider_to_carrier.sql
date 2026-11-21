-- geo/fcc_bdc/rename_provider_to_carrier.sql
--
-- Rename bdc_provider_tbl to bdc_carrier_tbl, and provider_key to
-- carrier_key, on a database that already has the old names.
--
-- IN ITS OWN FILE, not inside schema_v2.sql, and that matters. schema_v2.sql
-- DROPS and recreates bdc_availability_tbl and TRUNCATES bdc_carrier_tbl,
-- which it is entitled to do because it is a schema replacement guarded on
-- the availability table being empty. A pure rename needs none of that and
-- must not be reachable only by running a file that can also empty tables.
--
-- This file is SAFE and idempotent. It renames and nothing else: no DROP, no
-- TRUNCATE, no DELETE. ALTER TABLE RENAME carries the data, the indexes and
-- the foreign keys, so nothing is lost and nothing is reloaded. Running it
-- twice is a no-op.
--
-- provider_id KEEPS ITS NAME. It is the FCC's own column in the BDC
-- download and renaming it would break the correspondence to the source
-- file that the loader and every comment depend on.

\set ON_ERROR_STOP on

-- A LOCK TIMEOUT, AND WHY IT IS THE WHOLE POINT OF THIS HEADER.
--
-- ALTER TABLE ... RENAME takes ACCESS EXCLUSIVE, the strongest lock
-- PostgreSQL has. If anything else holds any lock on the table, this waits.
-- Worse, a WAITING AccessExclusiveLock request sits at the head of the lock
-- queue and blocks every later request behind it, including weak ones. So a
-- queued rename does not merely fail to finish, IT STALLS THE WRITERS TOO.
--
-- That is exactly what happened on 2026-11-17: this file was run while
-- bdc_load.py was loading availability data, which writes to this very
-- table. The rename queued, nothing returned for minutes, and Boris's load
-- was behind it.
--
-- lock_timeout makes the rename give up after two seconds and say so,
-- rather than queueing. It never blocks a writer for longer than that.
SET lock_timeout = '2s';
SET statement_timeout = '30s';

-- ---------------------------------------------------------------------------
-- RENAME MIGRATION
--
-- Boris 2026-11-17: "bdc_provider_tbl should be renamed bdc_carrier_tbl. We
-- have heretofore used carrier to denote ISPs and provider to denote hosting
-- and cloud services." This table lists ISPs.
--
-- provider_id KEEPS ITS NAME throughout: it is the FCC's own column in the
-- BDC download and renaming it would break the correspondence to the source
-- file. Only the table and the surrogate key I invented are renamed.
--
-- ALTER TABLE RENAME carries the data, the indexes and the foreign keys, so
-- nothing is lost and nothing is reloaded. Runs before the guard so the rest
-- of this file sees the new name either way.
-- ---------------------------------------------------------------------------

-- WHO ELSE IS USING THESE TABLES. Reported BEFORE attempting the rename,
-- because the useful information is which session holds the lock, and that
-- is unobtainable once this session is itself stuck in the queue.
\echo
\echo Sessions currently holding a lock on the tables this file renames:
\echo

SELECT a.pid,
       a.state,
       a.wait_event_type,
       now() - a.query_start AS running,
       left(a.query, 54)     AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation IN (
        coalesce(to_regclass('bdc_provider_tbl'), 0::oid),
        coalesce(to_regclass('bdc_carrier_tbl'), 0::oid),
        coalesce(to_regclass('bdc_availability_tbl'), 0::oid))
  AND a.pid <> pg_backend_pid()
ORDER BY a.query_start;

\echo
\echo If any row appeared above, a load or query is using these tables. The
\echo rename below will give up after two seconds rather than queue ahead of
\echo it, because a waiting ACCESS EXCLUSIVE request blocks the writers too.
\echo Let that finish, then run this file again. It is idempotent.
\echo

DO $$
BEGIN
    IF to_regclass('bdc_provider_tbl') IS NOT NULL
       AND to_regclass('bdc_carrier_tbl') IS NULL THEN
        ALTER TABLE bdc_provider_tbl RENAME TO bdc_carrier_tbl;
        RAISE NOTICE 'bdc_provider_tbl renamed to bdc_carrier_tbl; data, indexes and foreign keys carried over, nothing reloaded';
    END IF;

    IF to_regclass('bdc_carrier_tbl') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'bdc_carrier_tbl'
                     AND column_name = 'provider_key') THEN
        ALTER TABLE bdc_carrier_tbl RENAME COLUMN provider_key TO carrier_key;
        RAISE NOTICE 'bdc_carrier_tbl.provider_key renamed to carrier_key';
    END IF;

    IF to_regclass('bdc_availability_tbl') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'bdc_availability_tbl'
                     AND column_name = 'provider_key') THEN
        ALTER TABLE bdc_availability_tbl RENAME COLUMN provider_key TO carrier_key;
        RAISE NOTICE 'bdc_availability_tbl.provider_key renamed to carrier_key';
    END IF;
EXCEPTION
    WHEN lock_not_available THEN
        RAISE EXCEPTION 'Could not get the lock to rename bdc_provider_tbl within 2 seconds, so NOTHING WAS CHANGED and no writer was blocked. Something else is using the table, almost certainly bdc_load.py. The list printed above names it. Let it finish and run this file again; it is idempotent and the rest of step 2 does not depend on the rename having happened yet.';
END
$$;


