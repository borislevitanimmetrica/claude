-- rdap_fill_followup.sql
--
-- Two corrections and one question, all arising from the targeting run.
--
-- CORRECTION 1: I WAS WRONG ABOUT THE CANDIDATE THRESHOLD.
--
-- I wrote that "every db-ip row wider than a /24" was completeness rather than
-- a requirement. That mis-states the project's own decision. apply_splits
-- declares, at main.go line 5, "THE UNIT IS /25, AND THAT IS A MEASURED
-- CHOICE, NOT A DEFAULT", and -unit defaults to 25. The measurement behind it
-- is in zip_granularity_findings.md: of 96 /24s probed at /27 midpoints, 3.3
-- pct carried TWO ZIPs, split cleanly at .128, and /25 resolved every real
-- case.
--
-- So a /24 is not atomic. It is a range that may itself need splitting, which
-- means it needs a registrant like any other. loadCandidates at main.go line
-- 667 filters masklen < 24, so EVERY /24 IS EXCLUDED FROM THE CANDIDATE SET,
-- and /24s are precisely the width where the two-ZIP problem was measured.
--
-- Section 1 counts what that exclusion costs. I am not changing the Go filter:
-- that is a decision about scope and budget, not a defect to patch quietly.
--
-- CORRECTION 2: MY TIME ESTIMATES FOR THE TARGETING FILE WERE BOTH WRONG.
--
--   step 2, candidate build   predicted about 5 min   actual 13:19
--   step 3, containment test  predicted about 10 min  actual  3:30
--
-- Step 2 was slower because I compared it to CREATE TEMP TABLE AS while
-- writing an INSERT into a permanent table with a cidr primary key, so every
-- row pays for an index entry and WAL. Step 3 was faster because it is now one
-- UPDATE over a table in primary-key order instead of two LATERAL passes over
-- an unordered temp table. The net was 16:49 against the sizing run's 21:00,
-- and every report after step 3 now returns in under a second, which was the
-- actual goal.
--
-- Also noted: 281,951 candidates here against the sizing run's 281,957. The
-- six-row difference is this table's cidr PRIMARY KEY collapsing rows that
-- SELECT DISTINCT on an inet column kept apart, because inet 1.2.3.0/23 and
-- inet 1.2.3.1/23 are distinct inet values and the same cidr. The cidr dedupe
-- is the correct one.
--
-- THE QUESTION: WHAT IS BUCKET A, REALLY?
--
-- The targeting run put 120,427 of the 251,940 in "no operator name at all",
-- 204,232,192 addresses, and only 31 of those 120,427 carry an ip-api ZIP.
-- That shape is suspicious. Either ip-api was asked and had no answer, or
-- THOSE ROWS WERE NEVER PROBED. The difference decides everything: if they are
-- unprobed, the cheap move is to finish the ip-api pass, which is free and
-- already built, not to spend 120,427 RDAP queries.
--
-- I do not know the probe table's full column list, so section 2 prints it
-- rather than assuming a status column exists, and section 3 separates NULL
-- from empty string, which distinguishes a row that was never written from one
-- that was written with no answer.
--
-- READ-ONLY apart from reading rdap_fill_cand_tbl, which the targeting file
-- created. Nothing is created, altered or dropped here.

\timing on
\set ON_ERROR_STOP on

SET work_mem = '512MB';

\echo ''
\echo '=== 1 of 4: the /24s the candidate filter excludes ==='
\echo '    The decomposition unit is /25, so a /24 can still carry two ZIPs and'
\echo '    needs a registrant. masklen < 24 excludes all of them. This is the'
\echo '    size of that exclusion. Expect a few minutes: it is the same join as'
\echo '    the candidate build, restricted to exactly /24.'
SELECT count(*) AS exact_24_candidates
FROM (
    SELECT DISTINCT c.network
    FROM ip2city_dbiplite_probe_tbl c
    JOIN ip2city_dbiplite_tbl d
      ON d.network = c.network
     AND d.source = 'dbip'
    WHERE family(c.network) = 4
      AND masklen(c.network) = 24
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                      WHERE x.active AND x.prefix IS NOT NULL
                        AND c.network <<= x.prefix)
) s;

\echo ''
\echo '--- how many of those /24s the current cache ALREADY answers ---'
\echo '    A /24 inside an allocation we already hold costs nothing to add.'
\echo '    If most are already covered, widening the filter to /25 is cheap.'
SELECT count(*)                           AS exact_24_candidates,
       count(*) FILTER (WHERE cov.ok)     AS already_covered,
       count(*) FILTER (WHERE NOT cov.ok) AS would_need_a_query
FROM (
    SELECT DISTINCT c.network
    FROM ip2city_dbiplite_probe_tbl c
    JOIN ip2city_dbiplite_tbl d
      ON d.network = c.network
     AND d.source = 'dbip'
    WHERE family(c.network) = 4
      AND masklen(c.network) = 24
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                      WHERE x.active AND x.prefix IS NOT NULL
                        AND c.network <<= x.prefix)
) s
CROSS JOIN LATERAL (
    SELECT EXISTS (
        SELECT 1 FROM rdap_registrant_tbl r
        WHERE r.start_ip <= host(network(s.network))::inet
          AND r.end_ip   >= host(broadcast(s.network))::inet
    ) AS ok
) cov;

\echo ''
\echo '=== 2 of 4: the probe table column list, printed not assumed ==='
\echo '    If there is a probe status or timestamp column, bucket A can be'
\echo '    settled exactly rather than by the NULL test in section 3.'
SELECT ordinal_position, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'ip2city_dbiplite_probe_tbl'
ORDER BY ordinal_position;

\echo ''
\echo '=== 3 of 4: is bucket A unprobed, or probed with no answer? ==='
\echo '    NULL means the column was never written. Empty string means it was'
\echo '    written and ip-api returned nothing. The two call for opposite moves.'
SELECT CASE WHEN c.covered THEN 'covered already'
            ELSE 'still to resolve' END                       AS state,
       count(*)                                               AS networks,
       count(*) FILTER (WHERE p.zip IS NULL)                  AS zip_is_null,
       count(*) FILTER (WHERE p.zip IS NOT NULL
                          AND btrim(p.zip) = '')              AS zip_is_empty,
       count(*) FILTER (WHERE p.isp IS NULL)                  AS isp_is_null,
       count(*) FILTER (WHERE p.isp IS NOT NULL
                          AND btrim(p.isp) = '')              AS isp_is_empty,
       count(*) FILTER (WHERE p.org IS NULL)                  AS org_is_null,
       count(*) FILTER (WHERE p.org IS NOT NULL
                          AND btrim(p.org) = '')              AS org_is_empty
FROM rdap_fill_cand_tbl c
JOIN LATERAL (
    SELECT min(zip) AS zip, min(isp) AS isp, min(org) AS org
    FROM ip2city_dbiplite_probe_tbl q
    WHERE q.network = c.network
) p ON true
WHERE NOT coalesce(c.has_isp, false)
  AND NOT coalesce(c.has_org, false)
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '--- the whole probe table for comparison, so bucket A has a denominator ---'
SELECT count(*)                                              AS probe_rows,
       count(*) FILTER (WHERE zip IS NULL)                   AS zip_null,
       count(*) FILTER (WHERE zip IS NOT NULL
                          AND btrim(zip) = '')               AS zip_empty,
       count(*) FILTER (WHERE btrim(coalesce(zip, '')) <> '') AS zip_present,
       count(*) FILTER (WHERE btrim(coalesce(isp, '')) <> '') AS isp_present,
       count(*) FILTER (WHERE btrim(coalesce(org, '')) <> '') AS org_present
FROM ip2city_dbiplite_probe_tbl;

\echo ''
\echo '=== 4 of 4: the work queue, in the order it is worth doing ==='
\echo '    From the targeting run: 86,489 of the 251,940 are droppable, being'
\echo '    5,648 hosting providers out of scope and 80,841 already named by'
\echo '    ip-api as a known ISP. That is 34.3 pct of the remaining work gone'
\echo '    before a single query is sent.'
SELECT CASE
         WHEN NOT coalesce(c.has_isp, false)
          AND NOT coalesce(c.has_org, false) THEN '1 no name at all, RDAP only source'
         WHEN p.name IS NOT NULL             THEN '4 hosting provider, DROP'
         WHEN i.name IS NOT NULL             THEN '3 known ISP, defer'
         ELSE                                     '2 unclassified or enterprise, IN scope'
       END                                        AS priority,
       count(*)                                   AS candidates,
       count(*) FILTER (WHERE c.prefix_width <= 20) AS at_20_or_wider,
       count(*) FILTER (WHERE c.prefix_width >= 22) AS at_22_or_narrower,
       sum(2 ^ (32 - c.prefix_width))::bigint     AS addresses
FROM rdap_fill_cand_tbl c
LEFT JOIN isp_names      i ON btrim(i.name) = c.ipapi_isp
LEFT JOIN provider_names p ON btrim(p.name) = c.ipapi_isp
WHERE NOT c.covered
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '    Next, the 500-row /23 sample that measures the marginal rate:'
\echo '      rdap_registrant -fill -candidates rdap_fill_sample_tbl -rate 1.0'
\echo '    then re-run rdap_fill_targeting.sql, whose step 3 will skip the rows'
\echo '    it has already tested.'
\echo ''
\echo '=== done ==='
\timing off
