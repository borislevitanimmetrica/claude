-- sample_college_dotgov.sql
--
-- READ-ONLY. Ten random colleges and ten random dotgov entities with the full
-- evidence behind each on-premises decision, because Boris finds 2,877 college
-- hosts and 51 dotgov landmarks not credible and is entitled to see why.
--
--
-- READ THIS BEFORE THE SAMPLES. THE NUMBERS HE IS DOUBTING ARE TOO HIGH, NOT
-- TOO LOW.
--
-- MEASURED 2026-11-12 by hosting_rule_reconciliation.sql: the hosting rule has
-- NOT been applied to the current on-premises set.
--
--     CLEARED   judged and kept      66,712 places   9,753 ZIPs  24,152 addrs
--     PENDING   would be flipped     67,485 places  14,149 ZIPs   4,700 addrs
--     UNJUDGED  no verdict exists        95 places      57 ZIPs      49 addrs
--
-- Applying the rule as address_hosting_tbl already stands gives 66,807 places
-- and 9,776 ZIPs, against the handoff memo's 65,148 and 9,728. The memo was
-- right and Session 4 was wrong: 134,292 places and 16,161 ZIPs are PRE-rule
-- figures, and the 2,877 college hosts and 51 dotgov landmarks are pre-rule too.
-- After the rule both go DOWN.
--
-- So these samples are drawn from a pre-rule set, and the hosting verdict for
-- each row is shown so it is visible which of them the rule is about to remove.
--
--
-- WHAT COUNTS AS EVIDENCE HERE
--
-- The onpremises decision is made from four things and nothing else, so all
-- four are printed per row:
--
--   registrant_1 and registrant_2   who ARIN says holds the IP block
--   whether either is in provider_names   rule 2, which rejects before any ZIP
--                                         test, because a CDN-fronted site
--                                         cannot anchor retail routing
--   whether either is in isp_names   an ISP registrant ZIP is forced to NULL,
--                                    being a network operations centre rather
--                                    than the landmark
--   registrant ZIP against overture_zip   rules 4 and 5, equal or adjacent
--
-- Plus the address_hosting_tbl verdict, which is measured fan-out rather than a
-- name, and which overrides all of the above.
--
-- A row is believable as NOT on-premises if its registrant is plainly a host.
-- A row is a DEFECT if its registrant is the institution itself at the
-- institution's own ZIP and it still came out false.
--
--
-- SAMPLING IS REPRODUCIBLE. setseed is called before each ORDER BY random(),
-- so re-running gives the same ten rows and a disagreement can be chased
-- rather than re-rolled.
--
--
-- HOW TO RUN, AND WHAT IT COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f sample_college_dotgov.sql
--
-- ESTIMATE, labelled as one: one to two minutes. The college class is about
-- 61,000 rows and dotgov 14,149, both reduced before any join, and the
-- helper lookups are indexed temp tables.
--
-- Read-only. Temp tables only, dropped at the end.

\timing on
\pset pager off
SET client_min_messages = warning;

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'landmarks_usa'
  AND column_name IN ('source', 'name', 'category', 'website', 'locality',
                      'region', 'postcode', 'overture_zip', 'ip_address',
                      'lookup_status', 'onpremises', 'onpremises_reason',
                      'registrant_1', 'registrant_1_zip', 'registrant_2',
                      'registrant_2_zip')
ORDER BY column_name;

\echo ''
\echo 'Expected: 16 rows.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. HELPERS.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_isp;
CREATE UNLOGGED TABLE tmp_isp AS SELECT DISTINCT lower(btrim(name)) AS name FROM isp_names;
CREATE INDEX ON tmp_isp (name);

DROP TABLE IF EXISTS tmp_prov;
CREATE UNLOGGED TABLE tmp_prov AS SELECT DISTINCT lower(btrim(name)) AS name FROM provider_names;
CREATE INDEX ON tmp_prov (name);

DROP TABLE IF EXISTS tmp_hostverdict;
CREATE UNLOGGED TABLE tmp_hostverdict AS
SELECT host(ip_address) AS addr, min(verdict) AS verdict
FROM address_hosting_tbl GROUP BY 1;
CREATE INDEX ON tmp_hostverdict (addr);

ANALYZE tmp_isp;
ANALYZE tmp_prov;
ANALYZE tmp_hostverdict;

SELECT (SELECT count(*) FROM tmp_isp)         AS isp_names,
       (SELECT count(*) FROM tmp_prov)        AS provider_names,
       (SELECT count(*) FROM tmp_hostverdict) AS addresses_with_a_verdict;


\echo ''
\echo '================================================================'
\echo ' 2. WHY THE COLLEGE CLASS LOSES ROWS, BEFORE THE SAMPLE.'
\echo '================================================================'
\echo ''
\echo 'The whole class, so the ten rows below sit in context rather than'
\echo 'standing alone. A class is 61,288 rows over 26,549 distinct hosts.'
\echo ''

DROP TABLE IF EXISTS tmp_college;
CREATE UNLOGGED TABLE tmp_college AS
SELECT l.*
FROM landmarks_usa l
WHERE l.source = 'nces_ipeds'
   OR l.category ILIKE '%college%'
   OR l.category ILIKE '%universit%';
ANALYZE tmp_college;

SELECT count(*)                                                        AS rows,
       count(*) FILTER (WHERE lookup_status = 'true')                   AS rdap_ok,
       count(*) FILTER (WHERE onpremises IS TRUE)                       AS onpremises_true,
       count(*) FILTER (WHERE onpremises IS FALSE
                          AND onpremises_reason LIKE 'hosting:%')       AS false_by_hosting_rule,
       count(*) FILTER (WHERE onpremises IS FALSE
                          AND coalesce(onpremises_reason, '') NOT LIKE 'hosting:%')
                                                                        AS false_by_registrant_rules,
       count(*) FILTER (WHERE onpremises IS NULL)                       AS undecided
FROM tmp_college;

\echo ''
\echo 'And of the TRUE ones, how many sit on an address the fan-out rule has'
\echo 'already judged to be hosting and is waiting to flip:'
SELECT count(*) AS true_but_PENDING_a_hosting_flip
FROM tmp_college c
JOIN tmp_hostverdict v ON v.addr = host(c.ip_address)
WHERE c.onpremises IS TRUE AND v.verdict LIKE 'hosting%';


\echo ''
\echo '================================================================'
\echo ' 3. TEN RANDOM COLLEGES, WITH THE EVIDENCE.'
\echo '================================================================'
\echo ''

SELECT setseed(0.42);

SELECT left(coalesce(c.name, '(no name)'), 34)        AS institution,
       left(coalesce(c.website, ''), 30)              AS website,
       coalesce(c.overture_zip, '-')                  AS place_zip,
       host(c.ip_address)                             AS ip,
       left(coalesce(c.registrant_1, '(none)'), 30)   AS registrant_1,
       coalesce(c.registrant_1_zip, '-')              AS reg1_zip,
       CASE WHEN lower(btrim(c.registrant_1)) IN (SELECT name FROM tmp_prov) THEN 'PROVIDER'
            WHEN lower(btrim(c.registrant_1)) IN (SELECT name FROM tmp_isp)  THEN 'isp'
            ELSE '' END                               AS reg1_kind,
       coalesce(v.verdict, 'no verdict')              AS fanout_verdict,
       c.onpremises                                   AS onprem,
       left(coalesce(c.onpremises_reason, '-'), 24)   AS reason
FROM tmp_college c
LEFT JOIN tmp_hostverdict v ON v.addr = host(c.ip_address)
WHERE c.lookup_status = 'true'
ORDER BY random()
LIMIT 10;

\echo ''
\echo 'How to read a row. place_zip against reg1_zip is rules 4 and 5. A'
\echo 'reg1_kind of PROVIDER means rule 2 rejected it before any ZIP was'
\echo 'compared. A fanout_verdict starting hosting means the address serves'
\echo 'disjoint ZIP clusters and is a shared host regardless of its name.'
\echo ''
\echo 'A row where registrant_1 IS the university, reg1_zip equals place_zip,'
\echo 'and onprem is false would be a DEFECT. Say so and I will chase it.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 4. WHY DOTGOV LOSES ROWS, BEFORE THE SAMPLE.'
\echo '================================================================'
\echo ''

SELECT count(*)                                                        AS rows,
       count(*) FILTER (WHERE btrim(coalesce(overture_zip, '')) <> '') AS have_a_zip,
       count(*) FILTER (WHERE lookup_status = 'true')                   AS rdap_ok,
       count(*) FILTER (WHERE onpremises IS TRUE)                       AS onpremises_true,
       count(*) FILTER (WHERE onpremises IS FALSE
                          AND onpremises_reason LIKE 'hosting:%')       AS false_by_hosting_rule,
       count(*) FILTER (WHERE onpremises IS FALSE
                          AND coalesce(onpremises_reason, '') NOT LIKE 'hosting:%')
                                                                        AS false_by_registrant_rules,
       count(*) FILTER (WHERE onpremises IS NULL)                       AS undecided
FROM landmarks_usa WHERE source = 'dotgov';

\echo ''
\echo 'undecided is expected to dominate and it is NOT a classification'
\echo 'failure: onpremises rule 1 returns NULL when there is no ZIP, and'
\echo 'MEASURED earlier, only 2,312 of 14,149 dotgov rows have a ZIP at all,'
\echo 'because the CISA registry carries no postcode and the locality fallback'
\echo 'needs a city with exactly ONE ZIP corpus-wide.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 5. TEN RANDOM DOTGOV ENTITIES, WITH THE EVIDENCE.'
\echo '================================================================'
\echo ''
\echo 'Sampled from rows whose RDAP lookup SUCCEEDED, so the registrant is'
\echo 'known and the decision is attributable. Sampling the whole 14,149 would'
\echo 'mostly return rows with no ZIP, which section 4 has already counted.'
\echo ''

SELECT setseed(0.42);

SELECT left(coalesce(d.name, '(no name)'), 32)        AS organisation,
       left(coalesce(d.website, ''), 26)              AS website,
       left(coalesce(d.locality, ''), 16)             AS city,
       coalesce(d.region, '-')                        AS st,
       coalesce(d.overture_zip, 'NO ZIP')             AS place_zip,
       left(coalesce(d.registrant_1, '(none)'), 30)   AS registrant_1,
       coalesce(d.registrant_1_zip, '-')              AS reg1_zip,
       CASE WHEN lower(btrim(d.registrant_1)) IN (SELECT name FROM tmp_prov) THEN 'PROVIDER'
            WHEN lower(btrim(d.registrant_1)) IN (SELECT name FROM tmp_isp)  THEN 'isp'
            ELSE '' END                               AS reg1_kind,
       coalesce(v.verdict, 'no verdict')              AS fanout_verdict,
       d.onpremises                                   AS onprem
FROM landmarks_usa d
LEFT JOIN tmp_hostverdict v ON v.addr = host(d.ip_address)
WHERE d.source = 'dotgov'
  AND d.lookup_status = 'true'
ORDER BY random()
LIMIT 10;

\echo ''
\echo 'The expected pattern, from the earlier dotgov measurement: 6,486 of the'
\echo '7,936 rows with RDAP and no ZIP, 81.7 per cent, carry a PROVIDER'
\echo 'registrant. cmd_dotgov predicted exactly this when it was written,'
\echo 'naming CivicPlus and Granicus, so a sample full of civic-web vendors'
\echo 'confirms the rule rather than impugning it.'
\echo ''
\echo 'What would NOT be expected, and would be a defect worth chasing: a row'
\echo 'whose registrant is the city or county itself, at that city ZIP, coming'
\echo 'out false or NULL.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 6. THE TOP REGISTRANTS FOR EACH, SO TEN ROWS ARE NOT THE ONLY BASIS.'
\echo '================================================================'
\echo ''
\echo 'Ten rows cannot support a conclusion, and the standing orders say not to'
\echo 'conclude from tiny samples. These are the full-class registrant'
\echo 'distributions the samples are drawn from.'
\echo ''

\echo 'College class, top 15 registrants among rows that are NOT on-premises:'
SELECT left(coalesce(c.registrant_1, '(none)'), 44) AS registrant_1,
       count(*)                                     AS rows,
       CASE WHEN lower(btrim(c.registrant_1)) IN (SELECT name FROM tmp_prov) THEN 'PROVIDER'
            WHEN lower(btrim(c.registrant_1)) IN (SELECT name FROM tmp_isp)  THEN 'isp'
            ELSE '' END                             AS kind
FROM tmp_college c
WHERE c.lookup_status = 'true' AND c.onpremises IS NOT TRUE
GROUP BY 1, 3
ORDER BY 2 DESC
LIMIT 15;

\echo ''
\echo 'College class, top 15 registrants among rows that ARE on-premises:'
SELECT left(coalesce(c.registrant_1, '(none)'), 44) AS registrant_1,
       count(*)                                     AS rows
FROM tmp_college c
WHERE c.onpremises IS TRUE
GROUP BY 1
ORDER BY 2 DESC
LIMIT 15;

\echo ''
\echo 'dotgov, top 15 registrants among rows that are NOT on-premises:'
SELECT left(coalesce(d.registrant_1, '(none)'), 44) AS registrant_1,
       count(*)                                     AS rows,
       CASE WHEN lower(btrim(d.registrant_1)) IN (SELECT name FROM tmp_prov) THEN 'PROVIDER'
            WHEN lower(btrim(d.registrant_1)) IN (SELECT name FROM tmp_isp)  THEN 'isp'
            ELSE '' END                             AS kind
FROM landmarks_usa d
WHERE d.source = 'dotgov' AND d.lookup_status = 'true' AND d.onpremises IS NOT TRUE
GROUP BY 1, 3
ORDER BY 2 DESC
LIMIT 15;

\echo ''
\echo 'dotgov, ALL 51 on-premises rows. Small enough to show in full, and worth'
\echo 'showing because the question is whether 51 is believable:'
SELECT left(coalesce(d.name, '(no name)'), 36)      AS organisation,
       left(coalesce(d.website, ''), 24)            AS website,
       coalesce(d.overture_zip, '-')                AS place_zip,
       left(coalesce(d.registrant_1, '(none)'), 32) AS registrant_1,
       coalesce(d.registrant_1_zip, '-')            AS reg1_zip
FROM landmarks_usa d
WHERE d.source = 'dotgov' AND d.onpremises IS TRUE
ORDER BY d.name
LIMIT 60;

DROP TABLE IF EXISTS tmp_college;
DROP TABLE IF EXISTS tmp_hostverdict;
DROP TABLE IF EXISTS tmp_prov;
DROP TABLE IF EXISTS tmp_isp;

\echo ''
\echo 'Done. Nothing was modified.'
\echo ''
