-- rdap_fill_targeting.sql
--
-- The sizing run answered "how much is left": 251,940 of 281,957 candidates.
-- This file answers the two questions that actually decide what to do about it.
--
--   1. Which of that 251,940 can produce a demand pair at all, and in what
--      order should the queries be spent?
--
--      RETRACTED, 2026-11-03. This section originally claimed that where ip-api
--      had already named an ISP, "RDAP would tell us nothing we do not already
--      have", and that 86,489 candidates were therefore droppable. That was
--      wrong about what RDAP is for. RDAP establishes the REGISTRANT, and
--      onpremises decides on the registrant: rules 2 and 3 test exact
--      membership of the registrant NAME in provider_names and isp_names, and
--      rules 4 and 5 compare the registrant ZIP with the landmark ZIP. ip-api
--      supplies neither. Its isp string is not an RDAP registrant name, and it
--      has no registrant ZIP at all, only a location estimate for the address,
--      which is a different fact about a different thing.
--
--      Nothing can be dropped on the strength of an ip-api name. What ip-api
--      legitimately governs is narrower: a demand pair is (ZIP, ISP), and the
--      ZIP half comes from the probe, so a range with no ip-api ZIP yields no
--      pair however good its registrant turns out to be. That is an ordering
--      argument, probe before RDAP because the probe is free, not a reduction.
--      The buckets below are kept as DIAGNOSIS, to show where the two sources
--      disagree, and the labels have been corrected to say so.
--
--      CORRECTION, 2026-11-03. An earlier version of this comment called the
--      candidate set's "wider than a /24" rule completeness rather than a
--      requirement. That mis-stated the project's own decision. apply_splits
--      says at main.go line 5 "THE UNIT IS /25, AND THAT IS A MEASURED CHOICE,
--      NOT A DEFAULT", and -unit defaults to 25, because of 96 /24s probed at
--      /27 midpoints 3.3 pct carried two ZIPs splitting cleanly at .128.
--      A /24 is therefore NOT atomic and needs a registrant like anything else,
--      yet loadCandidates filters masklen < 24 and excludes every one of them.
--      rdap_fill_followup.sql section 1 measures what that exclusion costs.
--
--   2. What is the real marginal rate in the tier that dominates? 208,663 of
--      the 251,940 remaining are /22 and /23. Every rate we have was measured
--      in the /16 tier, where the tool starts. Section 5 builds a stratified
--      sample so that rate can be MEASURED instead of extrapolated.
--
-- WHAT THE SIZING RUN ESTABLISHED, FROM YOUR OWN LOG, 2026-11-03
--
--   cache now           1,065 allocations, 509,250,304 addresses, 11.86 pct of IPv4
--   candidates          281,957
--   already covered     30,017, which is 10.6 pct
--   still to resolve    251,940
--   remaining by width  /23 139,525   /22 69,138   /21 23,984   /20 10,230
--                       /19 4,589     /18 2,162    /17 1,120    /16 1,152
--                       /15 31        /14 7        /13 2        wider 0
--
-- THE MARGINAL RATE WE CAN COMPUTE, AND ITS LIMIT
--
-- Between the dry run and now the cache grew from 609 allocations to 1,065,
-- and coverage grew from 26,798 candidates to 30,017. That is +456 allocations
-- buying +3,219 covered candidates, so 7.06 candidates per allocation.
--
-- Projecting that over the remainder gives about 35,700 more queries, which at
-- the tool's default of one per second is just under ten hours. DO NOT TRUST
-- THAT NUMBER. It was earned in the /13 to /16 tiers, where one allocation can
-- swallow thousands of narrow candidates. At the other extreme every query
-- buys exactly itself, which is 251,940 queries and about 70 days. A seven-fold
-- spread is not a plan, and section 5 exists to close it with 500 queries.
--
-- ONE DISCREPANCY I CANNOT EXPLAIN AND AM NOT GOING TO PAPER OVER. The fill
-- tool reported the cache at 1,107 after its 500-row batch; step 1 of the
-- sizing run counts 1,065 rows with family(start_ip) = 4. The 42-row
-- difference may be IPv6 rows, rows with an unparseable range, or a different
-- definition of "cached" inside the tool. Section 1 below reports both counts
-- side by side so the gap is visible rather than assumed away.
--
-- WHY THIS FILE CACHES THE CANDIDATE SET
--
-- The sizing run spent 4m43s building the candidate set and then 9m52s and
-- 6m36s running the SAME whole-containment test twice, once for the total and
-- once for the by-width split. That is 21 minutes, and about 16 of them were
-- avoidable. Here the set is built once into a PERSISTENT table, the coverage
-- test runs ONCE into a stored column, and every report afterwards reads that
-- column and returns instantly.
--
-- NOTHING IS DROPPED. If rdap_fill_cand_tbl already exists this file leaves it
-- alone and reports what it holds. Refreshing it means deleting a derived cache,
-- so that is deliberately NOT automatic; the exact command is printed at the end
-- for you to run if and when you want it.

\timing on
\set ON_ERROR_STOP on

\echo ''
\echo '=== step 0 of 6: session settings only, nothing stored ==='
SET work_mem = '512MB';
SHOW work_mem;

\echo ''
\echo '=== step 1 of 6: cache size, counted two ways (fast) ==='
\echo '    The tool said 1,107 after its batch; the sizing SQL said 1,065.'
\echo '    Both counts are printed so the 42-row gap is visible.'
SELECT count(*)                                        AS rows_all_families,
       count(*) FILTER (WHERE family(start_ip) = 4)    AS rows_ipv4,
       count(*) FILTER (WHERE family(start_ip) = 6)    AS rows_ipv6,
       count(*) FILTER (WHERE start_ip IS NULL
                           OR end_ip IS NULL)          AS rows_null_range,
       count(*) FILTER (WHERE family(start_ip) = 4
                           AND end_ip < start_ip)      AS rows_inverted
FROM rdap_registrant_tbl;

\echo ''
\echo '=== step 2 of 6: the candidate cache ==='
\echo '    If rdap_fill_cand_tbl already exists this step does nothing and the'
\echo '    row count below is what it already holds. If it does not, building it'
\echo '    takes about 5 minutes, measured: your sizing run needed 4m43s.'

CREATE TABLE IF NOT EXISTS rdap_fill_cand_tbl (
    network      cidr PRIMARY KEY,
    prefix_width smallint NOT NULL,
    covered      boolean,
    covered_at   timestamptz,
    has_zip      boolean,
    has_isp      boolean,
    has_org      boolean,
    ipapi_isp    text
);

\echo '    table present; filling it only if it is empty'

INSERT INTO rdap_fill_cand_tbl (network, prefix_width)
SELECT c.network, masklen(c.network)
FROM (
    SELECT DISTINCT c.network
    FROM ip2city_dbiplite_probe_tbl c
    JOIN ip2city_dbiplite_tbl d
      ON d.network = c.network
     AND d.source = 'dbip'
    WHERE family(c.network) = 4
      AND masklen(c.network) < 24
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                      WHERE x.active AND x.prefix IS NOT NULL
                        AND c.network <<= x.prefix)
) c
WHERE NOT EXISTS (SELECT 1 FROM rdap_fill_cand_tbl)
ON CONFLICT (network) DO NOTHING;

SELECT count(*) AS candidates_cached,
       count(*) FILTER (WHERE covered IS NULL) AS coverage_not_yet_tested
FROM rdap_fill_cand_tbl;

\echo ''
\echo '=== step 3 of 6: the containment test, ONCE, into a stored column ==='
\echo '    This is the slow step: your run took 9m52s for exactly this test.'
\echo '    It runs only for rows whose coverage has never been tested, so a'
\echo '    second invocation of this file skips it entirely.'
\echo '    Nothing prints until it finishes. Expect about ten minutes.'

UPDATE rdap_fill_cand_tbl c
SET covered = EXISTS (
        SELECT 1 FROM rdap_registrant_tbl r
        WHERE r.start_ip <= host(network(c.network))::inet
          AND r.end_ip   >= host(broadcast(c.network))::inet
    ),
    covered_at = now()
WHERE c.covered IS NULL;

\echo '    coverage stored; every report below is now instant'

SELECT count(*)                                  AS candidates,
       count(*) FILTER (WHERE covered)           AS already_covered,
       count(*) FILTER (WHERE NOT covered)       AS still_to_resolve,
       round(100.0 * count(*) FILTER (WHERE covered)
             / greatest(count(*), 1), 1)         AS pct_covered
FROM rdap_fill_cand_tbl;

\echo ''
\echo '--- the same split by width, read straight from the column ---'
SELECT prefix_width,
       count(*)                            AS candidates,
       count(*) FILTER (WHERE covered)     AS already_covered,
       count(*) FILTER (WHERE NOT covered) AS still_to_resolve
FROM rdap_fill_cand_tbl
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== step 4 of 6: what ip-api ALREADY knows about the remaining work ==='
\echo '    This is the targeting question. The probe table carries ip-api zip,'
\echo '    isp and org for these same networks, so for some candidates RDAP'
\echo '    would only confirm what we hold. Takes a couple of minutes.'

UPDATE rdap_fill_cand_tbl c
SET has_zip   = p.has_zip,
    has_isp   = p.has_isp,
    has_org   = p.has_org,
    ipapi_isp = p.isp
FROM (
    SELECT network,
           bool_or(btrim(coalesce(zip, '')) <> '')  AS has_zip,
           bool_or(btrim(coalesce(isp, '')) <> '')  AS has_isp,
           bool_or(btrim(coalesce(org, '')) <> '')  AS has_org,
           min(btrim(coalesce(nullif(btrim(isp), ''), org)))
               FILTER (WHERE btrim(coalesce(nullif(btrim(isp), ''), org)) <> '')
                                                    AS isp
    FROM ip2city_dbiplite_probe_tbl
    GROUP BY network
) p
WHERE p.network = c.network
  AND c.has_zip IS NULL;

\echo '    ip-api attributes attached'

\echo ''
\echo '--- the remaining 251,940, by what ip-api says, as DIAGNOSIS not a plan ---'
\echo '    These labels describe ip-api only. None of them is a reason to skip an'
\echo '    RDAP query: ip-api cannot supply a registrant name or a registrant'
\echo '    ZIP, which is what onpremises decides on. Read with_ipapi_zip as the'
\echo '    column that matters, because that is the half of a demand pair the'
\echo '    probe owns.'
SELECT CASE
         WHEN NOT coalesce(c.has_isp, false)
          AND NOT coalesce(c.has_org, false) THEN 'a ip-api has no name for this range'
         WHEN NOT coalesce(c.has_isp, false)
          AND c.has_org                      THEN 'b ip-api gave org but no isp'
         WHEN p.name IS NOT NULL             THEN 'd ip-api name matches provider_names'
         WHEN i.name IS NOT NULL             THEN 'c ip-api name matches isp_names'
         ELSE                                     'e ip-api name matches neither list'
       END                                          AS ipapi_says,
       count(*)                                     AS candidates,
       count(*) FILTER (WHERE c.has_zip)            AS with_ipapi_zip,
       count(DISTINCT c.ipapi_isp)                  AS distinct_names,
       sum(2 ^ (32 - c.prefix_width))::bigint       AS addresses
FROM rdap_fill_cand_tbl c
LEFT JOIN isp_names      i ON btrim(i.name) = c.ipapi_isp
LEFT JOIN provider_names p ON btrim(p.name) = c.ipapi_isp
WHERE NOT c.covered
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '--- the same, by width, so the cost of each bucket is visible ---'
SELECT prefix_width,
       count(*) FILTER (WHERE NOT coalesce(has_isp, false)
                          AND NOT coalesce(has_org, false)) AS a_no_name,
       count(*) FILTER (WHERE NOT coalesce(has_isp, false)
                          AND has_org)                      AS b_enterprise,
       count(*) FILTER (WHERE has_isp)                      AS c_has_isp
FROM rdap_fill_cand_tbl
WHERE NOT covered
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== step 5 of 6: the stratified sample that closes the 7x spread ==='
\echo '    500 rows drawn at random from the /23 tier among the still-to-resolve,'
\echo '    which is 139,525 of the 251,940 and the single largest block. Running'
\echo '    the fill against THIS table measures the marginal rate where the work'
\echo '    actually is, instead of in the /16 tier where the tool starts.'

CREATE TABLE IF NOT EXISTS rdap_fill_sample_tbl (
    network cidr PRIMARY KEY,
    built_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO rdap_fill_sample_tbl (network)
SELECT network
FROM rdap_fill_cand_tbl
WHERE NOT covered
  AND prefix_width = 23
  AND NOT EXISTS (SELECT 1 FROM rdap_fill_sample_tbl)
ORDER BY random()
LIMIT 500
ON CONFLICT (network) DO NOTHING;

SELECT count(*)                  AS sample_rows,
       min(prefix_width)         AS min_width,
       max(prefix_width)         AS max_width
FROM rdap_fill_sample_tbl s
JOIN rdap_fill_cand_tbl c USING (network);

\echo ''
\echo '=== step 6 of 6: what to run next, and how to refresh this cache ==='
\echo ''
\echo '  Measure the marginal rate in the tier that dominates:'
\echo '    rdap_registrant -fill -candidates rdap_fill_sample_tbl -rate 1.0'
\echo ''
\echo '  Then re-run THIS file. Step 3 retests only the rows it has not tested,'
\echo '  so it will be fast, and the still_to_resolve drop tells you exactly how'
\echo '  many candidates 500 narrow queries bought.'
\echo ''
\echo '  To force a full recount after the fill has run, clear the stored'
\echo '  coverage column and re-run this file. This deletes DERIVED data only'
\echo '  and leaves rdap_registrant_tbl untouched:'
\echo '    UPDATE rdap_fill_cand_tbl SET covered = NULL, covered_at = NULL;'
\echo ''
\echo '  To rebuild the candidate set itself, for instance after db-ip is'
\echo '  reloaded, empty the cache table first. This is the only destructive'
\echo '  command here and it is deliberately not run for you:'
\echo '    TRUNCATE rdap_fill_cand_tbl;'
\echo ''
\echo '=== done ==='
\timing off
