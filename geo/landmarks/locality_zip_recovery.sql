-- locality_zip_recovery.sql
--
-- READ-ONLY. Measures whether the RDAP registrant ZIP can supply a ZIP to
-- landmarks that arrived with a city and a state but no postcode. Changes
-- nothing; every statement is a SELECT or a temp-table build.
--
--
-- WHY THIS EXISTS
--
-- source_ledger.sql showed dotgov delivering 51 on-premises landmarks from
-- 14,149 rows, and the reason is not the hit rate: only 2,312 of those rows
-- (16.3 per cent) have a ZIP at all. The onpremises step's rule 1 is
--
--     WHEN overture_zip IS NULL THEN NULL
--
-- so a row whose ZIP was never established can never become a landmark no
-- matter how good its registrant is. 11,837 dotgov rows are shut out by that
-- gate. That is the single largest known ceiling in the corpus.
--
--
-- WHY THE EXISTING FALLBACK MISSES THEM
--
-- The CISA .gov registry carries Organization, City and State and no postcode,
-- which lm_fetch.py cmd_dotgov records explicitly rather than inventing a ZIP.
-- It relies on the overture-zip step's third tier, which builds
--
--     SELECT lk, rk, min(z) FROM (...) GROUP BY lk, rk HAVING count(DISTINCT z) = 1
--
-- That HAVING clause demands the city carry exactly ONE ZIP across the whole
-- table. Any city large enough to have two ZIPs is disqualified, so the tier
-- fires only for small single-ZIP towns. Section 2 below measures the size of
-- that effect instead of asserting it.
--
-- The uniqueness rule is not a defect. Picking one of Springfield, Illinois's
-- ZIPs for "City of Springfield" would be a guess, and the step is right to
-- refuse. The question this file asks is whether a DIFFERENT, measured fact
-- can supply the ZIP where the locality cannot.
--
--
-- THE PROPOSED FACT, AND WHY IT IS NOT A GUESS
--
-- registrant_1_zip is not inferred. ovt_resolve_hosts.py parse_registrants
-- reads the vCard "geographic address" field out of the RDAP response and
-- zip_from_address pulls the postcode out of that text. It is the postal ZIP
-- the registrant filed with ARIN for the organisation that holds the IP block
-- the landmark's webserver answers on.
--
-- So for a dotgov row we may hold two independent facts:
--
--   from the CISA file   this place is in Springfield, Illinois
--   from ARIN via RDAP   the holder of its webserver's IP block is at 62701
--
-- If the corpus independently confirms that 62701 IS one of Springfield,
-- Illinois's ZIPs, the two facts agree and the landmark's ZIP is established
-- by measurement. Nothing was chosen or assumed. If they disagree, the
-- registrant is somewhere else, which is itself the correct answer: the site
-- is hosted off premises and must be rejected.
--
--
-- THE OBJECTION, STATED PLAINLY
--
-- Rule 4 of the onpremises step is "a non-ISP registrant's ZIP equals the
-- place's ZIP -> true". Deriving the place's ZIP from the registrant's ZIP
-- makes rule 4 pass by construction, so the rule stops being a test for these
-- rows. That is real and it must not be glossed over.
--
-- Two things limit the damage, and one does not.
--
--   Rule 2 still runs first and still rejects any CDN, cloud or web-host
--   registrant from provider_names, so the Squarespace and CivicPlus cases
--   are thrown out before any ZIP is considered.
--
--   The locality agreement test is the real check, and it is not circular.
--   It asks whether the registrant sits in the SAME CITY as the place. A
--   town whose site is run by a regional hosting company two counties away
--   fails it. What survives is the case where the registrant's address is in
--   the place's own city.
--
--   What does NOT survive scrutiny: a county that hosts a small town's site
--   from the county seat, when the town IS the county seat, would be
--   accepted. Section 5 prints a sample precisely so that case can be looked
--   at rather than argued about. Note that for the landmark METHOD this may
--   still be the right answer, because what the method needs is the ZIP where
--   the webserver physically sits, not the ZIP of the institution that owns
--   the name. I flag that as a hypothesis, not a finding: nothing here
--   measures it.
--
--
-- HOW TO RUN
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f locality_zip_recovery.sql
--
-- Section 2 and the evidence build each cross landmarks_usa once. There is no
-- index on (locality, region), so expect a sequential scan of roughly 12.9
-- million rows per pass, in the ten-minute range on the basis that the
-- overture-zip step's comparable whole-table locality scan was timed at 600
-- seconds. That number is from the comment in ovt_resolve_hosts.py, not from
-- this file.

\timing on
\pset pager off

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION. Nothing below runs on a guessed column.'
\echo '================================================================'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'landmarks_usa'
  AND column_name IN ('source', 'name', 'locality', 'region', 'postcode',
                      'website', 'lookup_status', 'overture_zip',
                      'overture_zip_source', 'registrant_1',
                      'registrant_1_zip', 'registrant_2', 'registrant_2_zip',
                      'onpremises', 'onpremises_reason')
ORDER BY column_name;

\echo ''
\echo 'Expected: 15 rows. A missing row means a later section is wrong, not'
\echo 'that the data is missing. Stop and tell me which one is absent.'
\echo ''

SELECT c.relname AS helper_table,
       (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS columns
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('isp_names', 'provider_names', 'zip_adjacency')
ORDER BY c.relname;

\echo ''
\echo 'Expected: isp_names, provider_names, zip_adjacency all present.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. THE DOTGOV FUNNEL. Where the 14,149 rows actually stop.'
\echo '================================================================'
\echo ''

SELECT count(*)                                                    AS rows_total,
       count(*) FILTER (WHERE btrim(coalesce(website, '')) <> '')   AS with_website,
       count(*) FILTER (WHERE btrim(coalesce(postcode, '')) <> '')  AS with_file_postcode,
       count(*) FILTER (WHERE overture_zip IS NOT NULL)             AS with_any_zip,
       count(*) FILTER (WHERE lookup_status = 'true')               AS rdap_ok,
       count(*) FILTER (WHERE lookup_status = 'true'
                          AND overture_zip IS NULL)                 AS rdap_ok_no_zip,
       count(*) FILTER (WHERE onpremises IS TRUE)                   AS onpremises_true
FROM landmarks_usa
WHERE source = 'dotgov';

\echo ''
\echo 'with_file_postcode should be 0: the CISA registry carries no postcode.'
\echo 'rdap_ok_no_zip is the population this file is about.'
\echo ''

\echo 'Which overture_zip_source tier each dotgov row landed in:'
SELECT coalesce(overture_zip_source, '(never set)') AS zip_source,
       count(*)                                    AS rows,
       count(*) FILTER (WHERE onpremises IS TRUE)   AS onpremises_true
FROM landmarks_usa
WHERE source = 'dotgov'
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo 'Why onpremises holds its value, for dotgov rows that reached the rule:'
SELECT coalesce(onpremises_reason, '(not set)') AS reason,
       count(*)                                AS rows
FROM landmarks_usa
WHERE source = 'dotgov'
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo 'Rule 1 (no Overture ZIP) should dominate. If it does not, the ZIP gate'
\echo 'is NOT the binding constraint and the rest of this file is beside the'
\echo 'point. Read that number before reading any other.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 2. WHY THE LOCALITY TIER MISSES. Measured, not asserted.'
\echo '================================================================'
\echo ''
\echo 'Building the locality -> ZIP evidence set. This crosses landmarks_usa'
\echo 'once. Only FILE-PROVIDED postcodes are used as evidence: the postcode'
\echo 'column is written by the loaders and the migrations and is never filled'
\echo 'by the chain, so inferred ZIPs cannot become evidence for further'
\echo 'inference. overture_zip is deliberately NOT used here.'
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

CREATE INDEX ON tmp_loc_zip_evidence (lk, rk);
CREATE INDEX ON tmp_loc_zip_evidence (lk, rk, zip);
ANALYZE tmp_loc_zip_evidence;

-- Normalise zip_adjacency once, both directions, instead of calling lpad on
-- its columns inside a correlated EXISTS. Done inline that way the functions
-- sit on the indexed side of the comparison and no index can be used, so
-- every probed row would drive a fresh sequential scan. This mirrors what the
-- onpremises step builds for the same reason. The ::text cast and the lpad
-- restore leading zeros that a numeric ZIP column loses.
DROP TABLE IF EXISTS tmp_zip_adj;

CREATE UNLOGGED TABLE tmp_zip_adj (a text, b text, PRIMARY KEY (a, b));

INSERT INTO tmp_zip_adj
SELECT a, b FROM (
    SELECT left(lpad(btrim(zip_a::text), 5, '0'), 5) AS a,
           left(lpad(btrim(zip_b::text), 5, '0'), 5) AS b FROM zip_adjacency
    UNION
    SELECT left(lpad(btrim(zip_b::text), 5, '0'), 5),
           left(lpad(btrim(zip_a::text), 5, '0'), 5) FROM zip_adjacency) x
WHERE a IS NOT NULL AND b IS NOT NULL;

ANALYZE tmp_zip_adj;

SELECT count(*) AS adjacency_pairs_both_directions FROM tmp_zip_adj;

SELECT count(*)                       AS locality_zip_pairs,
       count(DISTINCT (lk, rk))        AS distinct_localities,
       sum(places)                     AS places_behind_the_evidence
FROM tmp_loc_zip_evidence;

\echo ''
\echo 'How many ZIPs the city of each dotgov row has in that evidence set.'
\echo 'The existing locality tier can only fire on the "exactly 1" line.'
\echo ''

WITH d AS (
    SELECT l.landmark_id,
           lower(btrim(l.locality)) AS lk,
           upper(btrim(l.region))   AS rk
    FROM landmarks_usa l
    WHERE l.source = 'dotgov'
      AND l.lookup_status = 'true'
      AND l.overture_zip IS NULL
), n AS (
    SELECT d.landmark_id,
           (SELECT count(*) FROM tmp_loc_zip_evidence e
             WHERE e.lk = d.lk AND e.rk = d.rk) AS zips
    FROM d
)
SELECT CASE WHEN zips = 0 THEN '0  city not in the evidence set'
            WHEN zips = 1 THEN '1  exactly one ZIP (the current tier fires)'
            WHEN zips BETWEEN 2 AND 5   THEN '2  two to five ZIPs'
            WHEN zips BETWEEN 6 AND 20  THEN '3  six to twenty ZIPs'
            ELSE                             '4  more than twenty ZIPs' END AS bucket,
       count(*) AS rows
FROM n
GROUP BY 1
ORDER BY 1;

\echo ''
\echo 'Read the "0" line carefully. Those rows are in cities the corpus has no'
\echo 'postcode evidence for at all, which is exactly where dotgov was loaded'
\echo 'to help. No registrant test can rescue them, because there is nothing'
\echo 'to agree with. They are the hard floor on this whole idea.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. IS THERE A REGISTRANT ZIP TO USE AT ALL?'
\echo '================================================================'
\echo ''
\echo 'An ISP registrant ZIP is excluded, matching the onpremises step, which'
\echo 'sets z1/z2 to NULL when the registrant is an ISP because an ISP ZIP is'
\echo 'the ZIP of a network operations centre, not of the landmark. A provider'
\echo 'registrant is excluded too: rule 2 would reject the row anyway.'
\echo ''

WITH d AS (
    SELECT l.landmark_id,
           l.registrant_1, l.registrant_2,
           lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM isp_names)      AS isp1,
           lower(btrim(l.registrant_2)) IN (SELECT lower(btrim(name)) FROM isp_names)      AS isp2,
           lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM provider_names) AS prov1,
           lower(btrim(l.registrant_2)) IN (SELECT lower(btrim(name)) FROM provider_names) AS prov2,
           l.registrant_1_zip, l.registrant_2_zip
    FROM landmarks_usa l
    WHERE l.source = 'dotgov'
      AND l.lookup_status = 'true'
      AND l.overture_zip IS NULL
)
SELECT count(*)                                                        AS rdap_ok_no_zip,
       count(*) FILTER (WHERE registrant_1 IS NOT NULL)                AS have_registrant,
       count(*) FILTER (WHERE coalesce(prov1, false) OR coalesce(prov2, false))
                                                                       AS provider_rejected,
       count(*) FILTER (WHERE coalesce(isp1, false) AND
                              (registrant_2 IS NULL OR coalesce(isp2, false)))
                                                                       AS all_isp,
       count(*) FILTER (WHERE NOT coalesce(prov1, false) AND NOT coalesce(prov2, false)
                          AND coalesce(
                                CASE WHEN coalesce(isp1, false) THEN NULL ELSE registrant_1_zip END,
                                CASE WHEN coalesce(isp2, false) THEN NULL ELSE registrant_2_zip END
                              ) IS NOT NULL)                           AS usable_registrant_zip
FROM d;

\echo ''
\echo 'usable_registrant_zip is the ceiling on section 4. If it is small, the'
\echo 'idea is dead on availability alone and section 4 only says by how much.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 4. THE AGREEMENT TEST. The actual answer.'
\echo '================================================================'
\echo ''

WITH d AS (
    SELECT l.landmark_id,
           lower(btrim(l.locality)) AS lk,
           upper(btrim(l.region))   AS rk,
           NOT (lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM provider_names)
             OR lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM provider_names))
               AS not_provider,
           coalesce(
             CASE WHEN lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_1_zip), 5) END,
             CASE WHEN lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_2_zip), 5) END
           ) AS reg_zip
    FROM landmarks_usa l
    WHERE l.source = 'dotgov'
      AND l.lookup_status = 'true'
      AND l.overture_zip IS NULL
      AND l.registrant_1 IS NOT NULL
), t AS (
    SELECT d.*,
           EXISTS (SELECT 1 FROM tmp_loc_zip_evidence e
                    WHERE e.lk = d.lk AND e.rk = d.rk)                       AS city_known,
           EXISTS (SELECT 1 FROM tmp_loc_zip_evidence e
                    WHERE e.lk = d.lk AND e.rk = d.rk AND e.zip = d.reg_zip) AS zip_in_city,
           EXISTS (SELECT 1 FROM tmp_loc_zip_evidence e
                    JOIN tmp_zip_adj z ON z.a = e.zip
                   WHERE e.lk = d.lk AND e.rk = d.rk
                     AND z.b = d.reg_zip) AS zip_adjacent_to_city
    FROM d WHERE d.not_provider AND d.reg_zip IS NOT NULL
)
SELECT CASE
         WHEN zip_in_city          THEN 'A  CONFIRMED: registrant ZIP is a known ZIP of the place''s city'
         WHEN zip_adjacent_to_city THEN 'B  ADJACENT: registrant ZIP adjoins a known ZIP of that city'
         WHEN NOT city_known       THEN 'C  UNVERIFIABLE: no postcode evidence for that city at all'
         ELSE                           'D  CONTRADICTED: city is known and the registrant is not in it'
       END AS verdict,
       count(*) AS rows
FROM t
GROUP BY 1
ORDER BY 1;

\echo ''
\echo 'How to read these four lines.'
\echo ''
\echo '  A is the recoverable set. Two independent sources agree, so the ZIP'
\echo '    is established rather than chosen. This is the number that decides'
\echo '    whether to change overture-zip.'
\echo ''
\echo '  B is weaker and I am NOT proposing to accept it here. It is printed'
\echo '    because the onpremises step already treats adjacency as sufficient'
\echo '    in rule 5, so excluding it needs to be a decision rather than an'
\echo '    oversight. Accepting B would assign a ZIP the place is probably'
\echo '    not in, which is a different and worse claim than rule 5 makes.'
\echo ''
\echo '  C cannot be decided from data we hold. Accepting it would be exactly'
\echo '    the guess the standing orders forbid.'
\echo ''
\echo '  D is a genuine finding, not a loss: the site is hosted away from the'
\echo '    municipality. Those rows are correctly excluded today and would'
\echo '    stay excluded.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 5. A SAMPLE OF THE CONFIRMED SET, FOR EYEBALLING.'
\echo '================================================================'
\echo ''
\echo 'Twenty-five rows that the proposed tier would newly admit. Check that'
\echo 'registrant reads like the municipality itself and not like a vendor or'
\echo 'a county that is not the place. A vendor here means provider_names is'
\echo 'incomplete, which is a finding about provider_names, not about this.'
\echo ''

WITH d AS (
    SELECT l.landmark_id, l.name, l.website, l.locality, l.region,
           l.registrant_1, l.registrant_2,
           lower(btrim(l.locality)) AS lk,
           upper(btrim(l.region))   AS rk,
           coalesce(
             CASE WHEN lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_1_zip), 5) END,
             CASE WHEN lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_2_zip), 5) END
           ) AS reg_zip
    FROM landmarks_usa l
    WHERE l.source = 'dotgov'
      AND l.lookup_status = 'true'
      AND l.overture_zip IS NULL
      AND l.registrant_1 IS NOT NULL
      AND NOT (lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM provider_names)
            OR lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM provider_names))
)
SELECT left(coalesce(d.name, ''), 38)         AS organisation,
       left(coalesce(d.website, ''), 30)      AS website,
       left(coalesce(d.locality, ''), 18)     AS city,
       d.region                               AS st,
       d.reg_zip                              AS would_assign,
       left(coalesce(d.registrant_1, ''), 34) AS registrant_1,
       (SELECT sum(e.places) FROM tmp_loc_zip_evidence e
         WHERE e.lk = d.lk AND e.rk = d.rk AND e.zip = d.reg_zip) AS places_confirming
FROM d
WHERE d.reg_zip IS NOT NULL
  AND EXISTS (SELECT 1 FROM tmp_loc_zip_evidence e
               WHERE e.lk = d.lk AND e.rk = d.rk AND e.zip = d.reg_zip)
ORDER BY d.landmark_id
LIMIT 25;

\echo ''
\echo 'places_confirming is how many corpus places carry that exact city/ZIP'
\echo 'pair. A 1 there is thin evidence resting on a single other row; a large'
\echo 'number is solid. If the confirmed set is mostly 1s, say so and I will'
\echo 'add a minimum to the tier rather than shipping it as it stands.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 6. THE SAME TEST FOR EVERY OTHER SOURCE.'
\echo '================================================================'
\echo ''
\echo 'dotgov is the worst case but it is not the only source with rows that'
\echo 'have a city, a successful RDAP lookup and no ZIP. If the change is made'
\echo 'in overture-zip it applies to all of them, so the size of that needs to'
\echo 'be on the table before deciding, not discovered afterwards.'
\echo ''

WITH d AS (
    SELECT l.source,
           lower(btrim(l.locality)) AS lk,
           upper(btrim(l.region))   AS rk,
           coalesce(
             CASE WHEN lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_1_zip), 5) END,
             CASE WHEN lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM isp_names)
                  THEN NULL ELSE left(btrim(l.registrant_2_zip), 5) END
           ) AS reg_zip,
           NOT (lower(btrim(l.registrant_1)) IN (SELECT lower(btrim(name)) FROM provider_names)
             OR lower(btrim(coalesce(l.registrant_2, ''))) IN (SELECT lower(btrim(name)) FROM provider_names))
               AS not_provider
    FROM landmarks_usa l
    WHERE l.lookup_status = 'true'
      AND l.overture_zip IS NULL
      AND l.registrant_1 IS NOT NULL
      AND btrim(coalesce(l.locality, '')) <> ''
      AND btrim(coalesce(l.region,   '')) <> ''
)
SELECT d.source,
       count(*) AS rdap_ok_no_zip_with_city,
       count(*) FILTER (WHERE d.not_provider AND d.reg_zip IS NOT NULL)
            AS usable_registrant_zip,
       count(*) FILTER (WHERE d.not_provider AND d.reg_zip IS NOT NULL
                          AND EXISTS (SELECT 1 FROM tmp_loc_zip_evidence e
                                       WHERE e.lk = d.lk AND e.rk = d.rk
                                         AND e.zip = d.reg_zip))
            AS confirmed_recoverable
FROM d
GROUP BY d.source
ORDER BY confirmed_recoverable DESC, rdap_ok_no_zip_with_city DESC;

\echo ''
\echo 'The confirmed_recoverable column summed over all sources is the total'
\echo 'the change would buy. Compare it against 134,292 on-premises landmarks'
\echo 'and 16,161 ZIPs delivered before deciding it is worth the risk in the'
\echo 'objection above.'
\echo ''

DROP TABLE IF EXISTS tmp_loc_zip_evidence;
DROP TABLE IF EXISTS tmp_zip_adj;

\echo 'Done. Nothing was modified.'
\echo ''
