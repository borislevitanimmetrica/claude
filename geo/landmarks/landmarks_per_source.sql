-- landmarks_per_source.sql
--
-- Per-source state of landmarks_usa: rows, how far the enrichment chain has
-- got, and how many landmarks each source actually produced.
--
-- SEPARATE FILE ON PURPOSE. This is a sequential scan of all 15.2 million rows
-- and takes minutes. It used to be appended to migrate_ca_cde.sql, where it
-- dominated the runtime of a step that inserts a few thousand rows and made
-- that step look like the slow one. Diagnostics that cost minutes belong
-- behind their own command, run when the answer is wanted.
--
-- Read only. Nothing here writes, locks or alters anything.

\timing on
SET lock_timeout = '30s';

\echo '=== per-source state of landmarks_usa ==='
SELECT source,
       count(*)                                                  AS rows,
       count(*) FILTER (WHERE lookup_status IS NOT NULL)          AS have_rdap,
       count(*) FILTER (WHERE lookup_status IS NULL)              AS awaiting_rdap,
       count(*) FILTER (WHERE onpremises)                         AS onpremises_true,
       count(DISTINCT ip_address) FILTER (WHERE onpremises)       AS onpremises_addresses,
       count(DISTINCT left(lpad(btrim(overture_zip), 5, '0'), 5))
           FILTER (WHERE onpremises)                              AS onpremises_zips
FROM landmarks_usa
GROUP BY source
ORDER BY 2 DESC;

\echo '=== national coverage, the number that matters ==='
SELECT count(DISTINCT left(lpad(btrim(overture_zip), 5, '0'), 5)) AS zips_with_landmark,
       count(*)                                                   AS onpremises_places,
       count(DISTINCT ip_address)                                 AS onpremises_addresses
FROM landmarks_usa
WHERE onpremises
  AND overture_zip IS NOT NULL;
