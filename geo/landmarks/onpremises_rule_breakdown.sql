-- onpremises_rule_breakdown.sql
--
-- READ-ONLY. WHICH RULE rejects the 789,689 landmarks that sit in the 16,238
-- ZIP codes delivering nothing.
--
--
-- WHY THIS IS NOW THE ONLY QUESTION
--
-- zip_coverage_funnel.sql, measured 2026-11-09, located the ZIP gap exactly:
--
--     NO PLACE AT ALL in the corpus                      344 ZIPs
--     websites exist, none resolved and passed RDAP      557 ZIPs
--     ALL STAGES PASSED, CLASSIFIED NOT ON PREMISES   16,238 ZIPs
--
-- and inside that last bucket: 970,919 places, of which 789,689 resolved, got
-- RDAP, and had a ZIP established. Then the chain rejected every one of them.
--
-- Only 344 ZIPs lack a place. The landmark corpus already reaches essentially
-- the whole country. So the source hunting that occupied most of this session
-- was aimed at the wrong constraint, and the pre-committed reading in
-- zip_coverage_funnel.sql said what follows if bucket e dominated: the places
-- are there and the chain is throwing them away, rule 2 and rule 6 need
-- examining rather than extending.
--
-- This file does the examining. It does not propose a change.
--
--
-- WHY THE RULE HAS TO BE RECOMPUTED RATHER THAN READ
--
-- onpremises_reason cannot answer this. VERIFIED at ovt_resolve_hosts.py line
-- 1368: the rule string is built only to print a summary under --dry-run and
-- is never written to the column. onpremises_reason carries only the
-- 'hosting:' values written by onpremises_hosting_rule.sql, and is NULL for
-- every row decided by the registrant rules.
--
-- So the CASE below is transcribed from cmd_onpremises. It must stay identical
-- to it or this file reports fiction. The ordering is load-bearing: rule 2
-- runs BEFORE the ZIP tests on purpose, because a CDN-fronted site is
-- unusable as a landmark whether or not its ZIP happens to match.
--
--   0   no registrant data                          -> NULL
--   1   no Overture ZIP                              -> NULL
--   2   ANY registrant is a CDN, cloud or web host   -> false
--   3a  single ISP registrant                        -> true
--   3b  two ISP registrants                          -> true
--   4   a non-ISP registrant ZIP equals the place ZIP -> true
--   5   a non-ISP registrant ZIP is adjacent         -> true
--   6a  no non-ISP registrant ZIP at all             -> false
--   6b  ZIPs differ and are not adjacent             -> false
--
-- An ISP registrant's ZIP is forced to NULL before the ZIP tests, because it
-- is the ZIP of a network operations centre and not of the landmark.
--
-- Rows carrying a 'hosting:' reason are reported SEPARATELY, because
-- cmd_onpremises excludes them from the base rule so the measured fan-out
-- decision is not silently reverted.
--
--
-- HOW TO RUN, AND WHAT IT COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f onpremises_rule_breakdown.sql
--
-- ESTIMATE, labelled as one: three to six minutes. Basis, all measured on this
-- data: a grouped pass over landmarks_usa is 16 to 50 seconds, the adjacency
-- normalisation is 2 seconds, and the rule evaluation touches ~970,919 rows
-- with every lookup served by an indexed temp table. No correlated subquery
-- runs against an unindexed table, which is the pathology that cost four hours
-- in rdap_filler_allocations.sql section 3.
--
-- Read-only. Temp tables only, dropped at the end. Ctrl-C costs nothing.

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
  AND column_name IN ('source', 'postcode', 'lookup_status', 'overture_zip',
                      'onpremises', 'onpremises_reason', 'registrant_1',
                      'registrant_1_zip', 'registrant_2', 'registrant_2_zip')
ORDER BY column_name;

\echo ''
\echo 'Expected: 10 rows. onpremises_reason must be among them or the hosting'
\echo 'rows cannot be separated and every count below is wrong.'
\echo ''

SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('isp_names', 'provider_names', 'zip_adjacency')
ORDER BY table_name, ordinal_position;

\echo ''
\echo 'isp_names and provider_names must each expose name; zip_adjacency must'
\echo 'expose zip_a and zip_b.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. HELPERS, BUILT THE SAME WAY cmd_onpremises BUILDS THEM.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_isp;
CREATE UNLOGGED TABLE tmp_isp AS SELECT DISTINCT lower(btrim(name)) AS name FROM isp_names;
CREATE INDEX ON tmp_isp (name);

DROP TABLE IF EXISTS tmp_prov;
CREATE UNLOGGED TABLE tmp_prov AS SELECT DISTINCT lower(btrim(name)) AS name FROM provider_names;
CREATE INDEX ON tmp_prov (name);

DROP TABLE IF EXISTS tmp_adj;
CREATE UNLOGGED TABLE tmp_adj (a text, b text, PRIMARY KEY (a, b));
INSERT INTO tmp_adj
SELECT a, b FROM (
    SELECT left(lpad(btrim(zip_a::text), 5, '0'), 5) AS a,
           left(lpad(btrim(zip_b::text), 5, '0'), 5) AS b FROM zip_adjacency
    UNION
    SELECT left(lpad(btrim(zip_b::text), 5, '0'), 5),
           left(lpad(btrim(zip_a::text), 5, '0'), 5) FROM zip_adjacency) x
WHERE a IS NOT NULL AND b IS NOT NULL;

ANALYZE tmp_isp;
ANALYZE tmp_prov;
ANALYZE tmp_adj;

SELECT (SELECT count(*) FROM tmp_isp)  AS isp_names,
       (SELECT count(*) FROM tmp_prov) AS provider_names,
       (SELECT count(*) FROM tmp_adj)  AS adjacency_pairs;

\echo ''
\echo 'The ZIP codes that deliver nothing. Keyed on postcode, matching the'
\echo 'funnel, because the question is which ZIPs we fail to cover.'
\echo ''

DROP TABLE IF EXISTS tmp_undelivered;
CREATE UNLOGGED TABLE tmp_undelivered AS
SELECT DISTINCT left(btrim(l.postcode), 5) AS zip
FROM landmarks_usa l
WHERE btrim(coalesce(l.postcode, '')) ~ '^[0-9]{5}'
  AND NOT EXISTS (
        SELECT 1 FROM landmarks_usa d
         WHERE d.onpremises IS TRUE
           AND left(btrim(d.overture_zip), 5) = left(btrim(l.postcode), 5));

CREATE INDEX ON tmp_undelivered (zip);
ANALYZE tmp_undelivered;

SELECT count(*) AS undelivered_zips_with_places FROM tmp_undelivered;


\echo ''
\echo '================================================================'
\echo ' 2. THE ANSWER. WHICH RULE REJECTS THEM.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_ruled;
CREATE UNLOGGED TABLE tmp_ruled AS
WITH p AS (
    SELECT l.source,
           l.overture_zip                                        AS ovz,
           l.registrant_1, l.registrant_2,
           l.onpremises, l.onpremises_reason,
           coalesce(lower(btrim(l.registrant_1)) IN (SELECT name FROM tmp_isp), false)  AS isp1,
           coalesce(lower(btrim(l.registrant_2)) IN (SELECT name FROM tmp_isp), false)  AS isp2,
           coalesce(lower(btrim(l.registrant_1)) IN (SELECT name FROM tmp_prov), false) AS prov1,
           coalesce(lower(btrim(l.registrant_2)) IN (SELECT name FROM tmp_prov), false) AS prov2,
           l.registrant_1_zip, l.registrant_2_zip
    FROM landmarks_usa l
    JOIN tmp_undelivered u ON u.zip = left(btrim(l.postcode), 5)
    WHERE l.lookup_status = 'true'
)
SELECT p.source,
       p.registrant_1,
       p.onpremises_reason,
       CASE
         WHEN p.onpremises_reason LIKE 'hosting:%'
              THEN 'H  held by the hosting fan-out rule: false'
         WHEN p.registrant_1 IS NULL          THEN '0  no registrant data: NULL'
         WHEN p.ovz IS NULL                   THEN '1  no Overture ZIP: NULL'
         WHEN p.prov1 OR p.prov2              THEN '2  CDN, cloud or web host registrant: false'
         WHEN p.isp1 AND (p.registrant_2 IS NULL OR p.isp2) AND p.registrant_2 IS NULL
                                              THEN '3a single ISP registrant: true'
         WHEN p.isp1 AND (p.registrant_2 IS NULL OR p.isp2)
                                              THEN '3b two ISP registrants: true'
         WHEN p.ovz IN (CASE WHEN p.isp1 THEN NULL ELSE p.registrant_1_zip END,
                        CASE WHEN p.isp2 THEN NULL ELSE p.registrant_2_zip END)
                                              THEN '4  non-ISP registrant ZIP matches: true'
         WHEN EXISTS (SELECT 1 FROM tmp_adj adj
                       WHERE adj.a = p.ovz
                         AND adj.b IN (CASE WHEN p.isp1 THEN NULL ELSE p.registrant_1_zip END,
                                       CASE WHEN p.isp2 THEN NULL ELSE p.registrant_2_zip END))
                                              THEN '5  non-ISP registrant ZIP adjacent: true'
         WHEN (CASE WHEN p.isp1 THEN NULL ELSE p.registrant_1_zip END) IS NULL
          AND (CASE WHEN p.isp2 THEN NULL ELSE p.registrant_2_zip END) IS NULL
                                              THEN '6a no non-ISP registrant ZIP: false'
         ELSE                                      '6b ZIPs differ and are not adjacent: false'
       END AS deciding_rule
FROM p;

ANALYZE tmp_ruled;

SELECT deciding_rule, count(*) AS places
FROM tmp_ruled
GROUP BY deciding_rule
ORDER BY count(*) DESC;

\echo ''
\echo 'How to read this, decided in advance:'
\echo ''
\echo '  Rule 2 dominating means provider_names is doing the damage. That is'
\echo '  the rule the earlier audit cleared as CORRECT, and it may still be'
\echo '  correct: a CDN-fronted site genuinely cannot anchor retail routing.'
\echo '  But if it rejects most of 789,689 places across 16,238 ZIPs, then the'
\echo '  landmark method as specified cannot cover those ZIPs AT ALL, and that'
\echo '  is a finding about the method rather than a bug to fix.'
\echo ''
\echo '  Rule 6b dominating is the opposite and much better news. It means the'
\echo '  registrant is a real organisation whose ZIP simply is not the place'
\echo '  ZIP or adjacent to it. Some of those are genuinely remote hosting.'
\echo '  Some will be large institutions whose registered address is a head'
\echo '  office while the server sits at a branch. Those are recoverable and'
\echo '  section 3 sizes them.'
\echo ''
\echo '  Rule 6a dominating means the registrant has no parseable ZIP, which'
\echo '  is an RDAP vCard parsing question, not a policy question.'
\echo ''
\echo '  Rules 3a, 3b, 4 and 5 appearing at all would be a CONTRADICTION'
\echo '  needing investigation before anything else: they return true, so a'
\echo '  place deciding on them should have delivered its ZIP. A non-zero'
\echo '  count means either my transcription of the rule differs from'
\echo '  cmd_onpremises, or the chain has not been re-run since something'
\echo '  changed. Check that line FIRST.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. WHO THE REJECTING REGISTRANTS ARE.'
\echo '================================================================'
\echo ''
\echo 'Top 30 registrants under rule 2. If these are Cloudflare, Akamai and'
\echo 'Squarespace, the rule is working as designed and the ZIPs are simply'
\echo 'unreachable by this method. If they include ordinary ISPs or local'
\echo 'businesses, provider_names is over-broad and that is correctable.'
\echo ''

SELECT left(coalesce(registrant_1, '(null)'), 46) AS registrant_1,
       count(*)                                   AS places
FROM tmp_ruled
WHERE deciding_rule LIKE '2 %'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 30;

\echo ''
\echo 'Top 30 registrants under rule 6b, the ZIP-mismatch rejections:'
SELECT left(coalesce(registrant_1, '(null)'), 46) AS registrant_1,
       count(*)                                   AS places
FROM tmp_ruled
WHERE deciding_rule LIKE '6b %'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 30;

\echo ''
\echo 'And by source, so it is clear whether this is an Overture problem or a'
\echo 'problem with the institution directories loaded this session:'
SELECT source,
       count(*)                                                      AS places,
       count(*) FILTER (WHERE deciding_rule LIKE '2 %')              AS rule_2_provider,
       count(*) FILTER (WHERE deciding_rule LIKE '6a %')             AS rule_6a_no_zip,
       count(*) FILTER (WHERE deciding_rule LIKE '6b %')             AS rule_6b_mismatch,
       count(*) FILTER (WHERE deciding_rule LIKE 'H %')              AS held_by_hosting_rule
FROM tmp_ruled
GROUP BY source
ORDER BY places DESC;

DROP TABLE IF EXISTS tmp_ruled;
DROP TABLE IF EXISTS tmp_undelivered;
DROP TABLE IF EXISTS tmp_adj;
DROP TABLE IF EXISTS tmp_prov;
DROP TABLE IF EXISTS tmp_isp;

\echo ''
\echo 'Done. Nothing was modified.'
\echo ''
