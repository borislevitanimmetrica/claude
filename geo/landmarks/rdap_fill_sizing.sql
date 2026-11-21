-- rdap_fill_sizing.sql
--
-- How much work is left in the RDAP fill, and how it is distributed by prefix
-- width. Read only: it creates one TEMP table and drops it.
--
-- PROGRESS IS REPORTED AT EVERY STEP. An earlier version of this file printed
-- nothing until its first aggregate completed and drove Postgres to 100 percent
-- CPU for ten minutes with no output, which is indistinguishable from a hang.
-- Every step below announces itself before it runs, so run it with tail -f and
-- the position is always visible.
--
-- IT ALSO BUILDS THE CANDIDATE SET ONCE. The earlier version rebuilt it three
-- times, in sections 1, 3 and 4. That set is a join of the 2,097,870-row probe
-- table against the db-ip master table with a DISTINCT on top, and the Go tool
-- needed 4 minutes 49 seconds for exactly the same query, from 09:50:35 to
-- 09:55:24 in its own log. Three passes was therefore a quarter of an hour of
-- repeated work for no reason.
--
-- WHY IT EXISTS RATHER THAN AN EXTRAPOLATION
--
-- The first bounded fill reported 1,146 already covered and 500 queried, which
-- is 0.30 queries per candidate. Extrapolating that over 281,957 candidates
-- gives about 85,000 queries and 24 hours at one per second.
--
-- That is wrong, because of the tool's own ordering. main.go line 187 sorts
-- candidates WIDEST FIRST, with the stated rationale that a wide candidate is
-- more likely to coincide with a large allocation and so covers more of the
-- remaining set per query. Every entry in the observed 500 was a /16 returning
-- an allocation of exactly 65,536 addresses, covering itself and nothing
-- further. So those came from the tier where a query buys the LEAST, and 0.30
-- is an upper bound rather than an average. The payoff arrives in the narrow
-- tiers, where a /20 or /23 inside an already-fetched /16 costs nothing.
--
-- THE CANDIDATE SET IS THE TOOL'S OWN, copied from loadCandidates at main.go
-- lines 658 to 667 rather than reconstructed from the flag help: the probe
-- table joined to db-ip-sourced master rows on an exact network match, IPv4
-- only, strictly wider than a /24, minus active prefix exclusions. If that
-- changes, this must change too.

\timing on
\set ON_ERROR_STOP on

\echo ''
\echo '=== step 0 of 5: raising work_mem for this session only ==='
-- The candidate build is a large hash join with a DISTINCT on top, and the
-- default work_mem spills it to disk. This is a SESSION setting and reverts
-- when psql exits; it changes no stored configuration.
SET work_mem = '512MB';
SHOW work_mem;

\echo ''
\echo '=== step 1 of 5: what the cache holds now (fast, a few seconds) ==='
SELECT count(*)                                   AS allocations,
       sum((end_ip - start_ip) + 1)               AS addresses_covered,
       round(100.0 * sum((end_ip - start_ip) + 1) / 4294967296.0, 2)
                                                  AS pct_of_ipv4
FROM rdap_registrant_tbl
WHERE family(start_ip) = 4;

\echo ''
\echo '--- allocations by size, which decides how many candidates each covers ---'
SELECT CASE
         WHEN (end_ip - start_ip) + 1 >= 16777216 THEN 'a /8 or wider'
         WHEN (end_ip - start_ip) + 1 >= 1048576  THEN 'b /12 to /9'
         WHEN (end_ip - start_ip) + 1 >= 65536    THEN 'c /16 to /13'
         WHEN (end_ip - start_ip) + 1 >= 4096     THEN 'd /20 to /17'
         WHEN (end_ip - start_ip) + 1 >= 256      THEN 'e /24 to /21'
         ELSE                                          'f narrower than a /24'
       END                          AS allocation_size,
       count(*)                     AS allocations,
       sum((end_ip - start_ip) + 1) AS addresses
FROM rdap_registrant_tbl
WHERE family(start_ip) = 4
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== step 2 of 5: building the candidate set ONCE ==='
\echo '    This is the slow one. The Go tool needed 4m49s for the same query,'
\echo '    so expect roughly five minutes. Nothing prints until it finishes.'
CREATE TEMP TABLE cand AS
SELECT DISTINCT c.network
FROM ip2city_dbiplite_probe_tbl c
JOIN ip2city_dbiplite_tbl d
  ON d.network = c.network
 AND d.source = 'dbip'
WHERE family(c.network) = 4
  AND masklen(c.network) < 24
  AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                  WHERE x.active AND x.prefix IS NOT NULL
                    AND c.network <<= x.prefix);

\echo '    candidates built, row count follows (compare with the tool: 281,957)'
SELECT count(*) AS candidates FROM cand;

CREATE INDEX ON cand (network);
ANALYZE cand;
\echo '    indexed and analysed'

\echo ''
\echo '=== step 3 of 5: where the work is, by prefix width (fast now) ==='
\echo '    Read top to bottom: the fill works widest first, so once a width is'
\echo '    done, candidates lower down that fall inside those allocations are free.'
SELECT masklen(network)        AS prefix_width,
       count(*)                AS candidates,
       sum(count(*)) OVER (ORDER BY masklen(network)) AS cumulative
FROM cand
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== step 4 of 5: how many candidates the CURRENT cache already answers ==='
\echo '    Same whole-containment test the tool does in Go at main.go line 700.'
\echo '    Subtract this from the total and the remainder is the real work.'
SELECT count(*)                            AS candidates,
       count(*) FILTER (WHERE cov.ok)      AS already_covered,
       count(*) FILTER (WHERE NOT cov.ok)  AS still_to_resolve,
       round(100.0 * count(*) FILTER (WHERE cov.ok)
             / greatest(count(*), 1), 1)   AS pct_covered
FROM cand
CROSS JOIN LATERAL (
    SELECT EXISTS (
        SELECT 1 FROM rdap_registrant_tbl r
        WHERE r.start_ip <= host(network(cand.network))::inet
          AND r.end_ip   >= host(broadcast(cand.network))::inet
    ) AS ok
) cov;

\echo ''
\echo '=== step 5 of 5: the same split by width, which predicts the run ==='
\echo '    If the narrow tiers are already covered the fill is nearly done,'
\echo '    whatever the raw candidate count says.'
SELECT masklen(cand.network)                 AS prefix_width,
       count(*)                              AS candidates,
       count(*) FILTER (WHERE cov.ok)        AS already_covered,
       count(*) FILTER (WHERE NOT cov.ok)    AS still_to_resolve
FROM cand
CROSS JOIN LATERAL (
    SELECT EXISTS (
        SELECT 1 FROM rdap_registrant_tbl r
        WHERE r.start_ip <= host(network(cand.network))::inet
          AND r.end_ip   >= host(broadcast(cand.network))::inet
    ) AS ok
) cov
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '=== done ==='
DROP TABLE IF EXISTS cand;
\timing off
