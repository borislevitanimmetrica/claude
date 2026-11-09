-- source_ledger.sql
--
-- Per source: records, records with both a ZIP and a URL, and records with
-- onpremises = true. One pass over landmarks_usa, grouped by source, so the
-- numbers can be checked against the loaders' own output for anything odd.
--
-- EVERY COLUMN HERE WAS CONFIRMED FROM create_table_landmarks_usa.sql BEFORE
-- THIS FILE WAS WRITTEN: source, website, websites, overture_zip, onpremises,
-- lookup_status, ip_address, onpremises_reason. Four nonexistent columns in
-- this session earned that sentence.
--
-- WHICH ZIP AND WHICH URL, because the table has more than one of each.
--
--   the URL is `website`, with `websites` as the chain's own copy. Both are
--   populated by every loader and the migration filters on websites being
--   non-empty, so a row in this table with no URL should not exist. If
--   with_url is ever below records, that is the unexpected value to chase
--
--   the ZIP is `overture_zip`, NOT `postcode`. postcode is what the source
--   file said; overture_zip is what the chain resolved and is the only one the
--   onpremises rule reads. dotgov has no postcode at all by design and gets an
--   overture_zip from the locality fallback, so comparing the two columns is
--   how that fallback is audited
--
-- READ-ONLY. One TEMP table, dropped at the end, private to this session.

\timing on
\set ON_ERROR_STOP on
SET work_mem = '512MB';

\echo ''
\echo 'One scan of landmarks_usa, about 15.4M rows. Expect under a minute.'

CREATE TEMP TABLE src_ledger AS
SELECT source,
       count(*)                                                       AS records,
       count(*) FILTER (WHERE btrim(coalesce(website, '')) <> ''
                           OR btrim(coalesce(websites, '')) <> '')     AS with_url,
       count(*) FILTER (WHERE overture_zip ~ '^[0-9]{5}$')             AS with_zip,
       count(*) FILTER (WHERE overture_zip ~ '^[0-9]{5}$'
                          AND (btrim(coalesce(website, '')) <> ''
                            OR btrim(coalesce(websites, '')) <> ''))   AS with_zip_and_url,
       count(*) FILTER (WHERE btrim(coalesce(postcode, '')) ~ '^[0-9]{5}') AS with_source_postcode,
       count(*) FILTER (WHERE ip_address IS NOT NULL)                  AS resolved,
       count(*) FILTER (WHERE lookup_status = 'true')                  AS rdap_ok,
       count(*) FILTER (WHERE onpremises)                              AS onpremises_true,
       count(*) FILTER (WHERE onpremises IS NULL)                      AS onpremises_null,
       count(*) FILTER (WHERE onpremises_reason LIKE 'hosting:%')      AS hosting_rule_rows,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises)          AS zips_delivered,
       count(DISTINCT ip_address)   FILTER (WHERE onpremises)          AS addresses_delivered
FROM landmarks_usa
GROUP BY source;

ANALYZE src_ledger;

\echo ''
\echo '=== THE TABLE ASKED FOR: source, records, zip and url, onpremises ==='
SELECT source,
       records,
       with_zip_and_url                      AS records_with_zip_and_url,
       onpremises_true                       AS records_onpremises_true
FROM src_ledger
ORDER BY records DESC;

\echo ''
\echo '=== the same with the columns that expose an unexpected value ==='
\echo '    with_url BELOW records should be impossible: the migration requires'
\echo '    a non-empty websites. with_zip far below with_source_postcode means'
\echo '    the chain lost a ZIP the source file had. onpremises_null is rule 0'
\echo '    or rule 1, meaning no registrant or no ZIP.'
SELECT source,
       records,
       with_url,
       with_source_postcode,
       with_zip,
       with_zip_and_url,
       resolved,
       rdap_ok,
       onpremises_true,
       onpremises_null,
       hosting_rule_rows,
       zips_delivered,
       addresses_delivered
FROM src_ledger
ORDER BY records DESC;

\echo ''
\echo '=== rates, for spotting a source that behaves unlike its neighbours ==='
SELECT source,
       records,
       round(100.0 * with_zip_and_url / greatest(records, 1), 1)     AS pct_zip_and_url,
       round(100.0 * rdap_ok          / greatest(records, 1), 1)     AS pct_rdap_ok,
       round(100.0 * onpremises_true  / greatest(records, 1), 2)     AS pct_onpremises,
       round(onpremises_true::numeric / greatest(zips_delivered, 1), 2)
                                                                     AS landmarks_per_zip
FROM src_ledger
ORDER BY pct_onpremises DESC;

\echo ''
\echo '=== totals, which must reconcile with the ledger and the chain ==='
SELECT sum(records)            AS records,
       sum(with_zip_and_url)   AS with_zip_and_url,
       sum(rdap_ok)            AS rdap_ok,
       sum(onpremises_true)    AS onpremises_true,
       sum(onpremises_null)    AS onpremises_null,
       sum(hosting_rule_rows)  AS hosting_rule_rows
FROM src_ledger;

\echo ''
\echo '    Expected from the 2026-11-06 runs: records 15,388,679,'
\echo '    rdap_ok 12,897,538, onpremises_true 134,292, hosting_rule_rows'
\echo '    243,716. zips_delivered does not sum, because two sources can'
\echo '    deliver the same ZIP; the corpus figure is 16,161.'

DROP TABLE IF EXISTS src_ledger;

\echo ''
\echo '=== done ==='
\timing off
