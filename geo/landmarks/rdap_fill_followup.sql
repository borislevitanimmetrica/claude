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
-- The targeting run put 120,427 of the 251,940 in "ip-api has no name for this
-- range", 204,232,192 addresses, and only 31 of those 120,427 carry an ip-api
-- ZIP. That shape is suspicious. Either ip-api was asked and had no answer, or
-- THOSE ROWS WERE NEVER PROBED.
--
-- This is about ORDER, not about avoiding RDAP. Every range still needs a
-- registrant, because that is what onpremises decides on. But a demand pair is
-- (ZIP, ISP), and the probe owns the ZIP half, so a range with no ip-api ZIP
-- cannot pair even with a perfect registrant. If those 120,396 are simply
-- unprobed then the free step should run before the rate-limited one. If ip-api
-- genuinely has no ZIP for them, that is a different and more serious finding:
-- 204 million addresses that the ZIP tier cannot place at all.
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
\echo '=== 4 of 4: RETRACTED. ip-api cannot stand in for the registrant ==='
\echo ''
\echo '    I claimed 86,489 of the 251,940 were droppable because ip-api had'
\echo '    already named a known ISP or a hosting provider for them. That was'
\echo '    wrong, and it was wrong about what RDAP is for.'
\echo ''
\echo '    RDAP is queried to establish the REGISTRANT, and the registrant is'
\echo '    what onpremises decides on. The rule needs two things ip-api does'
\echo '    not supply:'
\echo ''
\echo '      the registrant NAME as RDAP spells it, because rules 2 and 3 test'
\echo '      exact membership in provider_names and isp_names, and those lists'
\echo '      are keyed on RDAP registrant names, not on ip-api isp strings'
\echo ''
\echo '      the registrant ZIP, which rules 4 and 5 compare against the'
\echo '      landmark ZIP. ip-api has no registrant ZIP at all. Its location is'
\echo '      an estimate for the ADDRESS, which is a different fact.'
\echo ''
\echo '    So an ip-api isp of Comcast tells us nothing about who RDAP will'
\echo '    name as registrant of that range, and an ip-api isp that looks like'
\echo '    a hosting provider does not mean the REGISTRANT is in'
\echo '    provider_names. Nothing can be dropped on that basis. The section'
\echo '    below reports the same partition as DIAGNOSIS only, so that'
\echo '    disagreement between the two sources stays visible.'
\echo ''
\echo '    The one legitimate reduction is the one the tool already implements:'
\echo '    widest-first ordering, where every allocation fetched covers all the'
\echo '    candidates inside it. That is why the marginal rate has to be'
\echo '    measured rather than argued about.'
SELECT CASE
         WHEN NOT coalesce(c.has_isp, false)
          AND NOT coalesce(c.has_org, false) THEN 'a ip-api has no name for this range'
         WHEN p.name IS NOT NULL             THEN 'd ip-api name matches provider_names'
         WHEN i.name IS NOT NULL             THEN 'c ip-api name matches isp_names'
         ELSE                                     'b ip-api name matches neither list'
       END                                        AS ipapi_says,
       count(*)                                   AS candidates,
       count(*) FILTER (WHERE c.has_zip)          AS has_ipapi_zip,
       count(*) FILTER (WHERE NOT coalesce(c.has_zip, false))
                                                  AS no_ipapi_zip,
       count(*) FILTER (WHERE c.prefix_width <= 20) AS at_20_or_wider,
       sum(2 ^ (32 - c.prefix_width))::bigint     AS addresses
FROM rdap_fill_cand_tbl c
LEFT JOIN isp_names      i ON btrim(i.name) = c.ipapi_isp
LEFT JOIN provider_names p ON btrim(p.name) = c.ipapi_isp
WHERE NOT c.covered
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '--- the ONE thing ip-api legitimately governs: can this range ever pair? ---'
\echo '    A demand pair is (ZIP, ISP). RDAP supplies the ISP half. The ZIP half'
\echo '    comes from the ip-api probe, so a range with NO ip-api ZIP yields no'
\echo '    demand pair however good its registrant is. That is an ORDERING fact,'
\echo '    not a reason to drop anything: probe first, then RDAP, because the'
\echo '    probe is free and the RDAP query is rate limited.'
\echo ''
\echo '    From the targeting run, 121,250 of the 251,940 had no ip-api ZIP.'
\echo '    Section 3 above says whether that is because they were never probed.'
SELECT CASE WHEN coalesce(has_zip, false) THEN 'has an ip-api ZIP, can pair now'
            ELSE 'no ip-api ZIP, probe it before spending an RDAP query' END
                                                  AS state,
       count(*)                                   AS candidates,
       count(*) FILTER (WHERE prefix_width <= 20) AS at_20_or_wider,
       count(*) FILTER (WHERE prefix_width = 23)  AS at_23,
       sum(2 ^ (32 - prefix_width))::bigint       AS addresses
FROM rdap_fill_cand_tbl
WHERE NOT covered
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
