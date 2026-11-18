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
END
$$;


