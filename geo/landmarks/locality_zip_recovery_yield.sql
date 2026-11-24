-- locality_zip_recovery_yield.sql
--
-- READ-ONLY. The one number locality_zip_recovery.sql did not produce: how
-- many NEW ZIP CODES the registrant-ZIP tier would deliver, not how many new
-- landmarks.
--
--
-- WHY THIS IS THE DECIDING NUMBER
--
-- locality_zip_recovery.sql measured, 2026-11-09:
--
--     source       no-ZIP with city   usable reg ZIP   confirmed recoverable
--     overture              173,414           21,501                   1,729
--     dotgov                  7,931            1,263                     184
--     foursquare                541               61                      11
--     total                 181,886           22,825                   1,924
--
-- 1,924 new landmarks against a corpus of 134,292 is 1.4 per cent, which is
-- not interesting on its own. What matters is ZIP COVERAGE: 16,161 ZIPs
-- delivered against roughly 41,000 US ZIPs, and the last full enrichment
-- chain bought 2,167 landmarks for only 47 new ZIPs.
--
-- So 1,924 landmarks could be worth anywhere between nothing and a few
-- hundred ZIPs, and nothing measured so far distinguishes those. This file
-- measures it directly.
--
-- There is a reason to expect the answer to be poor, and it should be stated
-- before the measurement rather than after. The tier only accepts a ZIP that
-- the corpus already attests for the place's own city. Those are ZIPs we have
-- seen. A ZIP already DELIVERED by an existing on-premises landmark adds
-- nothing. So the yield depends entirely on the gap between "a ZIP the corpus
-- has a place in" and "a ZIP an on-premises landmark delivers", and I have not
-- measured that gap. I am NOT predicting the result.
--
--
-- THE SECOND THING THIS DECIDES: THE CONFIRMATION THRESHOLD
--
-- The 25-row sample in section 5 of the previous file contained three clear
-- errors, and all three share one signature:
--
--     City of Chicago       chi.gov          would assign 10001  registrant Bitly Inc
--     Elmwood Place, OH     elmwoodplace-oh  would assign 45011  registrant M-Tec Systems
--     Town of Granite Quarry NC              would assign 28144  registrant Walser Technology
--
-- 10001 is Manhattan. chi.gov is a Bitly-hosted redirect, so the registrant
-- sits in New York and the tier would place the City of Chicago there. Every
-- one of those three had places_confirming = 1, while the correct rows had
-- hundreds or thousands: City of Austin 7,095, City of Dallas 4,413, City of
-- Richardson 3,959, City of Albuquerque 2,859.
--
-- A places_confirming of 1 means ONE row somewhere in the corpus pairs that
-- city with that ZIP, and a single corpus row can be wrong. 10001 is not a
-- Chicago ZIP; some place in the corpus is mislabelled, and the agreement test
-- believed it.
--
-- So the tier needs a minimum. This file reports the yield at several
-- thresholds so the threshold is chosen from the curve rather than by feel.
--
--
-- HOW TO RUN, AND WHAT IT COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f locality_zip_recovery_yield.sql
--
-- MEASURED components, from the previous file on this data: the evidence build
-- is 50 seconds, the adjacency build 2 seconds, and the all-source confirmed
-- set 9 seconds. This file runs the same three plus two aggregations over at
-- most 22,825 rows. ESTIMATE, labelled as one: two to three minutes. The
-- correlated subqueries all hit indexed temp tables, which is the structural
-- difference from rdap_filler_allocations.sql section 3 that cost four hours.
--
-- Read-only. Temp tables only, dropped at the end. Ctrl-C costs nothing.

\timing on
\pset pager off

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'landmarks_usa'
  AND column_name IN ('source', 'locality', 'region', 'postcode', 'website',
                      'lookup_status', 'overture_zip', 'onpremises',
                      'registrant_1', 'registrant_1_zip', 'registrant_2',
                      'registrant_2_zip')
ORDER BY column_name;

\echo ''
\echo 'Expected: 12 rows.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. EVIDENCE SET AND THE ZIPS ALREADY DELIVERED.'
\echo '================================================================'
\echo ''
\echo 'The evidence set is the same as before: file-provided postcodes only,'
\echo 'never chain-inferred ones. Expect about 50 seconds and 117,737 pairs.'
\echo ''

DROP TABLE IF EXISTS tmp_loc_zip_evidence;

CREATE UNLOGGED TABLE tmp_loc_zip_evidence AS
SELECT lower(btrim(locality)) AS lk,
       upper(btrim(region))   AS rk,
       left(btrim(postcode), 5) AS zip,
       count(*)               AS places
FROM landmarks_usa
WHERE btrim(coalesce(locality, '')) <> ''
  AND btrim(coalesce(region,   '')) <> ''
  AND btrim(coalesce(postcode, '')) ~ '^[0-9]{5}'
GROUP BY 1, 2, 3;

CREATE INDEX ON tmp_loc_zip_evidence (lk, rk, zip);
ANALYZE tmp_loc_zip_evidence;

\echo 'ZIPs an on-premises landmark already delivers. This is the baseline the'
\echo 'new ZIPs must beat, and it should read about 16,161.'

DROP TABLE IF EXISTS tmp_delivered_zip;

CREATE UNLOGGED TABLE tmp_delivered_zip AS
SELECT DISTINCT left(btrim(overture_zip), 5) AS zip
FROM landmarks_usa
WHERE onpremises IS TRUE
  AND btrim(coalesce(overture_zip, '')) <> '';

CREATE INDEX ON tmp_delivered_zip (zip);
ANALYZE tmp_delivered_zip;

SELECT (SELECT count(*) FROM tmp_loc_zip_evidence) AS locality_zip_pairs,
       (SELECT count(*) FROM tmp_delivered_zip)    AS zips_already_delivered;


\echo ''
\echo '================================================================'
\echo ' 2. THE CONFIRMED-RECOVERABLE SET, WITH ITS EVIDENCE WEIGHT.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_recoverable;

CREATE UNLOGGED TABLE tmp_recoverable AS
WITH d AS (
    SELECT l.landmark_id,
           l.source,
           lower(btrim(l.locality)) AS lk,
           upper(btrim(l.region))   AS rk,
           coalesce(
             CASE WHEN lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_1_zip), 5) END,
             CASE WHEN lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_2_zip), 5) END
           ) AS reg_zip
    FROM landmarks_usa l
    WHERE l.lookup_status = 'true'
      AND l.overture_zip IS NULL
      AND l.registrant_1 IS NOT NULL
      AND btrim(coalesce(l.locality, '')) <> ''
      AND btrim(coalesce(l.region,   '')) <> ''
      AND NOT (lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM provider_names)
            OR lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM provider_names))
)
SELECT d.landmark_id, d.source, d.reg_zip,
       (SELECT sum(e.places) FROM tmp_loc_zip_evidence e
         WHERE e.lk = d.lk AND e.rk = d.rk AND e.zip = d.reg_zip) AS places_confirming
FROM d
WHERE d.reg_zip IS NOT NULL
  AND EXISTS (SELECT 1 FROM tmp_loc_zip_evidence e
               WHERE e.lk = d.lk AND e.rk = d.rk AND e.zip = d.reg_zip);

ANALYZE tmp_recoverable;

\echo 'Total should be about 1,924, matching the previous run.'
SELECT count(*) AS confirmed_recoverable FROM tmp_recoverable;

\echo ''
\echo 'How thin the evidence is, per row. The three known-bad rows from the'
\echo 'earlier sample all sat in the "exactly 1" bucket.'

SELECT CASE WHEN places_confirming IS NULL  THEN 'x no weight computed'
            WHEN places_confirming = 1      THEN 'a exactly 1 place confirms'
            WHEN places_confirming <= 5     THEN 'b 2 to 5'
            WHEN places_confirming <= 25    THEN 'c 6 to 25'
            WHEN places_confirming <= 100   THEN 'd 26 to 100'
            ELSE                                 'e more than 100' END AS evidence_weight,
       count(*) AS rows
FROM tmp_recoverable
GROUP BY 1
ORDER BY 1;


\echo ''
\echo '================================================================'
\echo ' 3. THE ANSWER. NEW ZIPS BY CONFIRMATION THRESHOLD.'
\echo '================================================================'
\echo ''
\echo 'For each minimum places_confirming: how many rows qualify, how many'
\echo 'distinct ZIPs they would assign, and how many of those ZIPs are NOT'
\echo 'already delivered by an existing on-premises landmark.'
\echo ''

WITH thresholds AS (SELECT * FROM (VALUES (1), (2), (6), (26), (101)) AS t(min_conf))
SELECT t.min_conf,
       (SELECT count(*) FROM tmp_recoverable r
         WHERE coalesce(r.places_confirming, 0) >= t.min_conf)            AS rows_qualifying,
       (SELECT count(DISTINCT r.reg_zip) FROM tmp_recoverable r
         WHERE coalesce(r.places_confirming, 0) >= t.min_conf)            AS distinct_zips,
       (SELECT count(DISTINCT r.reg_zip) FROM tmp_recoverable r
         WHERE coalesce(r.places_confirming, 0) >= t.min_conf
           AND NOT EXISTS (SELECT 1 FROM tmp_delivered_zip d
                            WHERE d.zip = r.reg_zip))                     AS NEW_zips
FROM thresholds t
ORDER BY t.min_conf;

\echo ''
\echo 'NEW_zips is the whole decision. Compare it against the 47 new ZIPs the'
\echo 'last full enrichment chain delivered for 2,167 landmarks. If NEW_zips is'
\echo 'in single digits the tier is not worth the circularity risk in the'
\echo 'objection recorded in locality_zip_recovery.sql. If it is in the'
\echo 'hundreds, it is the best ZIP-coverage move found this session.'
\echo ''

\echo 'Same split by source, at a minimum of 26 confirming places:'
SELECT r.source,
       count(*)                      AS rows_qualifying,
       count(DISTINCT r.reg_zip)     AS distinct_zips,
       count(DISTINCT r.reg_zip) FILTER (
           WHERE NOT EXISTS (SELECT 1 FROM tmp_delivered_zip d WHERE d.zip = r.reg_zip)
       )                             AS new_zips
FROM tmp_recoverable r
WHERE coalesce(r.places_confirming, 0) >= 26
GROUP BY r.source
ORDER BY new_zips DESC;


\echo ''
\echo '================================================================'
\echo ' 4. THE NEW ZIPS THEMSELVES, FOR EYEBALLING.'
\echo '================================================================'
\echo ''
\echo 'Thirty ZIPs the tier would newly deliver, with how many rows and how'
\echo 'much evidence each rests on. A ZIP here that looks nothing like its'
\echo 'claimed city is the Chicago-10001 failure recurring above the'
\echo 'threshold, which would mean the threshold is not the right instrument.'
\echo ''

SELECT r.reg_zip                       AS new_zip,
       count(*)                        AS rows,
       min(r.places_confirming)        AS min_confirming,
       max(r.places_confirming)        AS max_confirming,
       string_agg(DISTINCT r.source, ', ') AS sources
FROM tmp_recoverable r
WHERE coalesce(r.places_confirming, 0) >= 26
  AND NOT EXISTS (SELECT 1 FROM tmp_delivered_zip d WHERE d.zip = r.reg_zip)
GROUP BY r.reg_zip
ORDER BY count(*) DESC, r.reg_zip
LIMIT 30;

DROP TABLE IF EXISTS tmp_recoverable;
DROP TABLE IF EXISTS tmp_delivered_zip;
DROP TABLE IF EXISTS tmp_loc_zip_evidence;

\echo ''
\echo 'Done. Nothing was modified.'
\echo ''
