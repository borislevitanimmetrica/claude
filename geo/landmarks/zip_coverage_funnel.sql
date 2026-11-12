-- zip_coverage_funnel.sql
--
-- READ-ONLY. Where ZIP codes are lost, measured over ZIP SPACE rather than
-- over landmark rows. This is the diagnostic that should have been built
-- before any new landmark source was researched.
--
--
-- WHY
--
-- Two independent measurements now say the same thing:
--
--     full enrichment chain, 2026-11-06   +2,167 landmarks   ->  +47 ZIPs
--     registrant-ZIP tier,   2026-11-09   +1,924 landmarks   ->  +31 ZIPs
--                                                                 (+4 reliable)
--
-- Adding landmarks is not adding ZIPs. 16,161 ZIPs are delivered against
-- roughly 41,000 US ZIPs, and every source added this session fed the same
-- funnel and moved coverage by rounding error.
--
-- All previous counting has been per ROW: how many landmarks, how many
-- on-premises, what rate per source. None of it answers the question that
-- decides where effort goes, which is per ZIP: for a ZIP that delivers
-- nothing, WHICH STAGE loses it?
--
--   no place at all        the corpus has no row in that ZIP. No classification
--                          work can ever reach it. Only new sources can.
--   no website             places exist but none publishes a URL. A discovery
--                          problem, not a classification one.
--   website does not resolve, or RDAP failed
--   no ZIP established     the overture-zip gate, which is what dotgov hit
--   classified false       rule 2 provider, or rule 6 ZIP mismatch. THIS is
--                          the only bucket where better classification helps.
--
-- The shape of that distribution decides whether to keep hunting sources or
-- to stop and work on classification. I am NOT predicting it.
--
--
-- THE DENOMINATOR IS REAL, NOT ASSUMED
--
-- The US ZIP universe is taken from zip_adjacency, which is already in this
-- database and held 182,388 directed pairs when measured 2026-11-09. Its
-- distinct ZIPs are a far better denominator than the "roughly 41,000" figure
-- I have been quoting from memory, which is UNVERIFIED and should stop being
-- repeated once this file has run.
--
-- NOTE ON TWO DIFFERENT ZIP COLUMNS, and they are not interchangeable:
--   postcode      comes from the source file. It says where a place IS.
--   overture_zip  is established by the chain. It is what a landmark DELIVERS.
-- A ZIP can have places by postcode and deliver nothing. That gap is the
-- entire subject of this file.
--
--
-- HOW TO RUN, AND WHAT IT COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f zip_coverage_funnel.sql
--
-- ESTIMATE, labelled as one: two to three minutes. Basis, measured on this
-- data: a single grouped pass over landmarks_usa took 50 seconds in
-- locality_zip_recovery_yield.sql, and this file makes two such passes plus
-- aggregations over at most ~41,000 ZIP rows. There are no correlated
-- subqueries against unindexed tables, which is the pathology that cost four
-- hours in rdap_filler_allocations.sql section 3.
--
-- Read-only. Temp tables only, dropped at the end. Ctrl-C costs nothing.

\timing on
\pset pager off

-- Suppress the NOTICE that DROP TABLE IF EXISTS emits on a first run. On
-- 2026-11-09 those three notices read as "table does not exist" and were taken
-- for a guessed table name. They were nothing of the kind, but a diagnostic
-- file that prints alarming-looking noise it does not mean is a badly written
-- diagnostic file. A real problem still raises a WARNING or an ERROR.
SET client_min_messages = warning;

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'landmarks_usa'
  AND column_name IN ('source', 'postcode', 'website', 'lookup_status',
                      'overture_zip', 'onpremises')
ORDER BY column_name;

\echo ''
\echo 'Expected: 6 rows.'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'zip_adjacency'
ORDER BY ordinal_position;

\echo ''
\echo 'zip_adjacency supplies the denominator. Both zip_a and zip_b are read'
\echo 'and normalised to 5 characters, restoring leading zeros that a numeric'
\echo 'column loses. A ZIP beginning 0 is a real New England ZIP, so losing'
\echo 'those would silently shrink the denominator.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. THE ZIP UNIVERSE.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_zip_universe;

CREATE UNLOGGED TABLE tmp_zip_universe AS
SELECT DISTINCT zip FROM (
    SELECT left(lpad(btrim(zip_a::text), 5, '0'), 5) AS zip FROM zip_adjacency
    UNION
    SELECT left(lpad(btrim(zip_b::text), 5, '0'), 5)       FROM zip_adjacency) x
WHERE zip ~ '^[0-9]{5}$';

CREATE INDEX ON tmp_zip_universe (zip);
ANALYZE tmp_zip_universe;

SELECT count(*) AS zips_in_universe FROM tmp_zip_universe;

\echo ''
\echo 'This replaces the unverified "roughly 41,000" I have been repeating.'
\echo 'Whatever it reads is the denominator from here on.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 2. ONE PASS OVER THE CORPUS, GROUPED BY THE ZIP A PLACE IS IN.'
\echo '================================================================'
\echo ''
\echo 'Keyed on postcode, the file-provided column, because the question is'
\echo 'which ZIPs we have any presence in. Expect about 50 seconds.'
\echo ''

DROP TABLE IF EXISTS tmp_zip_by_place;

CREATE UNLOGGED TABLE tmp_zip_by_place AS
SELECT left(btrim(postcode), 5) AS zip,
       count(*)                                                      AS places,
       count(*) FILTER (WHERE btrim(coalesce(website, '')) <> '')     AS with_website,
       count(*) FILTER (WHERE lookup_status = 'true')                 AS rdap_ok,
       count(*) FILTER (WHERE lookup_status = 'true'
                          AND overture_zip IS NOT NULL)               AS zip_established,
       count(*) FILTER (WHERE onpremises IS TRUE)                     AS onpremises_true
FROM landmarks_usa
WHERE btrim(coalesce(postcode, '')) ~ '^[0-9]{5}'
GROUP BY 1;

CREATE INDEX ON tmp_zip_by_place (zip);
ANALYZE tmp_zip_by_place;

SELECT count(*)                                           AS zips_with_any_place,
       sum(places)                                        AS places_total,
       count(*) FILTER (WHERE with_website > 0)            AS zips_with_a_website,
       count(*) FILTER (WHERE rdap_ok > 0)                 AS zips_with_rdap_ok,
       count(*) FILTER (WHERE zip_established > 0)         AS zips_with_a_zip_established,
       count(*) FILTER (WHERE onpremises_true > 0)         AS zips_with_an_onpremises_place
FROM tmp_zip_by_place;

\echo ''
\echo 'Read these as a funnel across ZIP SPACE. Each column counts ZIPs that'
\echo 'retain at least one place at that stage. The drop between any two'
\echo 'adjacent columns is the number of ZIPs that stage eliminates entirely.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. WHAT THE DELIVERED SET ACTUALLY COVERS.'
\echo '================================================================'
\echo ''
\echo 'Keyed on overture_zip now, which is what a landmark DELIVERS, and that'
\echo 'is not the same set as section 2. Should read 16,161.'
\echo ''

DROP TABLE IF EXISTS tmp_zip_delivered;

CREATE UNLOGGED TABLE tmp_zip_delivered AS
SELECT left(btrim(overture_zip), 5) AS zip, count(*) AS landmarks
FROM landmarks_usa
WHERE onpremises IS TRUE
  AND btrim(coalesce(overture_zip, '')) ~ '^[0-9]{5}'
GROUP BY 1;

CREATE INDEX ON tmp_zip_delivered (zip);
ANALYZE tmp_zip_delivered;

SELECT count(*)                  AS zips_delivered,
       sum(landmarks)            AS landmarks_total,
       round(avg(landmarks), 1)  AS mean_landmarks_per_zip,
       max(landmarks)            AS most_in_one_zip,
       count(*) FILTER (WHERE landmarks = 1) AS zips_resting_on_ONE_landmark
FROM tmp_zip_delivered;

\echo ''
\echo 'zips_resting_on_ONE_landmark matters independently of coverage: a ZIP'
\echo 'held by a single landmark is one bad classification away from being'
\echo 'lost, and it is the case where ADDING a landmark in an already-covered'
\echo 'ZIP has real value. That is the measurement I lacked when I declined'
\echo 'to claim the registrant tier was worthless on that ground.'
\echo ''

-- THIS WAS WRONG AND IS NOW SET ARITHMETIC.
--
-- It used to compute gap as count(universe) - count(delivered), which is only
-- the gap if every delivered ZIP is inside the universe. MEASURED 2026-11-09:
-- it is not. zip_adjacency holds 32,989 distinct ZIPs while landmarks_usa has
-- places in 40,859 distinct postcodes, so zip_adjacency is not a superset and
-- cannot be the ZIP universe at all. It is an adjacency table, presumably
-- built only for ZIPs with usable centroids.
--
-- So I replaced an unverified "roughly 41,000" with a different unverified
-- number and called it "the real denominator". It is not. What IS established:
-- the corpus itself has places in 40,859 postcodes, which is a lower bound on
-- the US ZIP count. Settling the true figure needs an external list, Census
-- ZCTA or USPS, and nothing in this database supplies one.
SELECT (SELECT count(*) FROM tmp_zip_universe)  AS adjacency_zips,
       (SELECT count(*) FROM tmp_zip_delivered) AS delivered_zips,
       (SELECT count(*) FROM tmp_zip_delivered d
         WHERE EXISTS (SELECT 1 FROM tmp_zip_universe u WHERE u.zip = d.zip))
                                                AS delivered_inside_adjacency,
       (SELECT count(*) FROM tmp_zip_delivered d
         WHERE NOT EXISTS (SELECT 1 FROM tmp_zip_universe u WHERE u.zip = d.zip))
                                                AS delivered_OUTSIDE_adjacency,
       (SELECT count(*) FROM tmp_zip_universe u
         WHERE NOT EXISTS (SELECT 1 FROM tmp_zip_delivered d WHERE d.zip = u.zip))
                                                AS adjacency_zips_undelivered;

\echo ''
\echo 'delivered_OUTSIDE_adjacency being non-zero is the proof that the old'
\echo 'subtraction was invalid, and that zip_adjacency is not the ZIP universe.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 4. THE ANSWER. WHERE EACH UNDELIVERED ZIP IS LOST.'
\echo '================================================================'
\echo ''
\echo 'Every ZIP in the universe that delivers no landmark, classified by the'
\echo 'FIRST stage at which it ran out of places. This is the distribution'
\echo 'that decides whether to hunt more sources or to work on classification.'
\echo ''

SELECT CASE
         WHEN p.zip IS NULL        THEN 'a  NO PLACE AT ALL in the corpus'
         WHEN p.with_website = 0   THEN 'b  places exist, none has a website'
         WHEN p.rdap_ok = 0        THEN 'c  websites exist, none resolved and passed RDAP'
         WHEN p.zip_established = 0 THEN 'd  RDAP ok, but no ZIP was established'
         ELSE                           'e  all stages passed, classified NOT on premises'
       END AS lost_at,
       count(*) AS zips
FROM tmp_zip_universe u
LEFT JOIN tmp_zip_by_place p ON p.zip = u.zip
WHERE NOT EXISTS (SELECT 1 FROM tmp_zip_delivered d WHERE d.zip = u.zip)
GROUP BY 1
ORDER BY 1;

\echo ''
\echo 'How to read it, decided in advance so the result cannot be narrated'
\echo 'after the fact:'
\echo ''
\echo '  If a dominates, the landmark corpus simply is not present in those'
\echo '  ZIPs. No classification change can reach them and only new sources'
\echo '  can. That would vindicate the source hunting and mean the sources'
\echo '  tried so far were the wrong ones, not that the approach is wrong.'
\echo ''
\echo '  If b dominates, it is a website-discovery problem. That is what'
\echo '  website_discovery_sequencing.md was about, and the measured MX/NS'
\echo '  yield of 2.80 per cent becomes the relevant lever.'
\echo ''
\echo '  If d dominates, the overture-zip gate is the binding constraint'
\echo '  corpus-wide and not just for dotgov, which would make a general ZIP'
\echo '  fallback worth far more than the registrant tier just rejected.'
\echo ''
\echo '  If e dominates, the places are there and the chain is throwing them'
\echo '  away. That is the only case where classification work pays, and it'
\echo '  would mean rule 2 and rule 6 need examining rather than extending.'
\echo ''

\echo 'For the ZIPs in bucket e, how much is being discarded:'
SELECT count(*)                       AS zips,
       sum(p.places)                  AS places,
       sum(p.rdap_ok)                 AS rdap_ok_places,
       sum(p.zip_established)         AS places_with_a_zip
FROM tmp_zip_universe u
JOIN tmp_zip_by_place p ON p.zip = u.zip
WHERE NOT EXISTS (SELECT 1 FROM tmp_zip_delivered d WHERE d.zip = u.zip)
  AND p.zip_established > 0;

\echo ''
\echo 'If that places_with_a_zip figure is large, those are landmarks that'
\echo 'resolved, got RDAP, got a ZIP, and were then rejected. Recovering even'
\echo 'a fraction would beat every new source tried this session.'
\echo ''

DROP TABLE IF EXISTS tmp_zip_by_place;
DROP TABLE IF EXISTS tmp_zip_delivered;
DROP TABLE IF EXISTS tmp_zip_universe;

\echo 'Done. Nothing was modified.'
\echo ''
