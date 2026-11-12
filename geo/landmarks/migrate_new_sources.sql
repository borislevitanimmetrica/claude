-- migrate_new_sources.sql
--
-- Copy every lm_places_usa row that is not yet in landmarks_usa. Insert only.
--
-- =========================================================================
-- WHY YOU MUST NOT RUN migrate_into_landmarks_usa.sql INSTEAD
-- =========================================================================
--
-- I was about to tell Boris to run it. That would have been destructive, and
-- the damage would have been large and silent. Its section 3 opens with
--
--     DELETE FROM landmarks_usa
--     WHERE source IN (SELECT DISTINCT source FROM lm_places_usa);
--
-- lm_places_usa now holds seven sources: osm, ccd, wikidata, dotgov, ca_cde,
-- usfa_fire and nces_ipeds. Five of those are already enriched in
-- landmarks_usa. That DELETE would have removed all of them and then
-- re-inserted them from lm_places_usa, which carries no enrichment, because
-- the chain runs on landmarks_usa and not on the staging table.
--
-- WHAT WOULD HAVE BEEN LOST, counted from the institution_ledger run of
-- 2026-11-06 rather than estimated:
--
--     source        rows         rdap_ok      onpremises true
--     osm           1,139,855      986,630              8,735
--     wikidata         24,721       21,951                876
--     dotgov           14,149       10,248                 51
--     ca_cde            8,816        8,322                 54
--     nces_ipeds        6,075        5,593                328
--     TOTAL         1,193,616    1,032,744             10,044
--
-- Over a million completed RDAP lookups, and 10,044 on-premises determinations,
-- destroyed with no confirmation prompt. The original national RDAP pass took
-- roughly ten hours; recovering this would be hours of work at best.
--
-- This is not a new discovery. migrate_ca_cde.sql was written for exactly this
-- reason and its header documents the same trap. The shared script is only safe
-- on a first migration, where there is nothing to lose. It has been unsafe ever
-- since and will stay unsafe until that DELETE is scoped, which is a separate
-- change with its own blast radius.
--
-- =========================================================================
-- SAFETY PROPERTIES OF THIS FILE
-- =========================================================================
--
--   * no DELETE, no UPDATE, no TRUNCATE anywhere
--   * ON CONFLICT (source, source_id) DO NOTHING, so a row already present is
--     left exactly as it is and no enrichment can be overwritten
--   * source_id IS NOT NULL is required, which guarantees the partial unique
--     index landmarks_usa_source_id_idx applies to every row inserted. Without
--     that condition a NULL-id row would bypass the conflict clause and
--     duplicate. No loader currently produces one, and this does not rely on
--     that staying true
--   * only the 15 descriptive columns are written. Every enrichment column is
--     left NULL for the chain to fill
--   * it generalises migrate_ca_cde.sql rather than replacing it, and needs no
--     list of source names to keep up to date
--
-- Re-running it is harmless and is the correct way to pick up a newly loaded
-- jurisdiction.
--
-- lock_timeout is set because a blocked writer waits for ever by default, and a
-- psql session parked at a pager prompt inside a transaction holds its locks.
-- statement_timeout is deliberately NOT set: a large insert is allowed to be
-- slow. \timing on means no statement is silent.

\timing on
\set ON_ERROR_STOP on
SET lock_timeout = '30s';

\echo ''
\echo '=== 1 of 4: what is in staging and what is already enriched ==='
\echo '    One scan of landmarks_usa, about 15.2M rows, so roughly 25 seconds.'

CREATE TEMP TABLE mig_enriched AS
SELECT source, count(*) AS enriched_rows,
       count(*) FILTER (WHERE lookup_status = 'true') AS rdap_ok,
       count(*) FILTER (WHERE onpremises)             AS onpremises_true
FROM landmarks_usa
GROUP BY 1;

CREATE TEMP TABLE mig_staging AS
SELECT source, count(*) AS staging_rows,
       count(*) FILTER (WHERE websites IS NOT NULL
                          AND btrim(websites) <> ''
                          AND source_id IS NOT NULL)  AS eligible
FROM lm_places_usa
GROUP BY 1;

SELECT coalesce(s.source, e.source)             AS source,
       coalesce(s.staging_rows, 0)              AS staging_rows,
       coalesce(s.eligible, 0)                  AS eligible_to_insert,
       coalesce(e.enriched_rows, 0)             AS enriched_rows,
       coalesce(e.rdap_ok, 0)                   AS rdap_ok,
       coalesce(e.onpremises_true, 0)           AS onpremises_true,
       CASE WHEN e.source IS NULL THEN 'NEW, will be inserted'
            WHEN s.source IS NULL THEN 'enriched only, not in staging'
            ELSE 'present in both, conflicts will be skipped' END
                                                AS action
FROM mig_staging s
FULL JOIN mig_enriched e USING (source)
ORDER BY staging_rows DESC, enriched_rows DESC;

\echo ''
\echo '=== 2 of 4: the insert. Nothing above this line was modified. ==='
\echo '    Every row already present conflicts and is skipped untouched, so the'
\echo '    enrichment in the table above cannot be affected. Expect a couple of'
\echo '    minutes: it reads about 1.27M staging rows and most of them conflict.'

INSERT INTO landmarks_usa
    (source, source_id, source_release, name, address, locality, region,
     postcode, country, website, latitude, longitude, category,
     websites, addresses)
SELECT l.source, l.source_id, l.source_release,
       l.name, l.address, l.locality, l.region, l.postcode, l.country,
       l.website, l.latitude, l.longitude, l.category,
       l.websites, l.addresses
FROM lm_places_usa l
WHERE l.websites IS NOT NULL
  AND btrim(l.websites) <> ''
  AND l.source_id IS NOT NULL
ON CONFLICT (source, source_id) WHERE source_id IS NOT NULL DO NOTHING;

\echo ''
\echo '=== 3 of 4: per source, after. Compare rdap_ok with section 1. ==='
\echo '    Any source whose rdap_ok or onpremises_true FELL is a bug and should'
\echo '    stop everything. They cannot fall: the insert touched no existing'
\echo '    row. This prints so that claim is checked rather than asserted.'

SELECT t.source,
       count(*)                                        AS rows_now,
       m.enriched_rows                                 AS rows_before,
       count(*) - coalesce(m.enriched_rows, 0)         AS rows_added,
       count(*) FILTER (WHERE t.lookup_status = 'true') AS rdap_ok_now,
       coalesce(m.rdap_ok, 0)                          AS rdap_ok_before,
       count(*) FILTER (WHERE t.onpremises)            AS onpremises_now,
       coalesce(m.onpremises_true, 0)                  AS onpremises_before,
       count(*) FILTER (WHERE t.lookup_status IS NULL) AS awaiting_the_chain
FROM landmarks_usa t
LEFT JOIN mig_enriched m ON m.source = t.source
GROUP BY t.source, m.enriched_rows, m.rdap_ok, m.onpremises_true
ORDER BY rows_added DESC;

\echo ''
\echo '=== 4 of 4: what the chain has to do next ==='
\echo '    awaiting_the_chain above is the work. The chain MUST be run with'
\echo '    --table landmarks_usa: the default is ovt_places_usa and getting that'
\echo '    wrong enriches the wrong table.'
\echo ''
\echo '    The hosting-rule guard was verified present on this branch before'
\echo '    this file was written: ovt_resolve_hosts.py lines 1351 to 1352 carry'
\echo '    the onpremises_reason NOT LIKE hosting: condition, and 99e8206 is an'
\echo '    ancestor of HEAD. Without it the onpremises step reverts the 66,923'
\echo '    rows the hosting rule had set, which is what happened on the'
\echo '    geo-ca-cde-schools branch.'

SELECT count(*) FILTER (WHERE lookup_status IS NULL)        AS need_resolve,
       count(*) FILTER (WHERE ip_address IS NOT NULL
                          AND lookup_status IS NULL)        AS resolved_awaiting_rdap,
       count(*) FILTER (WHERE onpremises_reason LIKE 'hosting:%')
                                                            AS hosting_rule_rows_to_protect
FROM landmarks_usa;

DROP TABLE IF EXISTS mig_staging;
DROP TABLE IF EXISTS mig_enriched;

\echo ''
\echo '=== done ==='
\timing off
