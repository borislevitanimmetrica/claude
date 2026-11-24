-- rdap_fill_decay.sql
--
-- READ-ONLY. One table: the candidate set by prefix length, cumulative.
--
--
-- WHAT THIS IS FOR
--
-- To answer "how many RDAP queries will the fill actually take", which is NOT
-- the number of uncovered candidates. The fill loop queries only a candidate
-- that no cached allocation wholly contains, and each answer retires every
-- later candidate inside it. 168,405 uncovered candidates is therefore an
-- upper bound (1.95 days at -rate 1), not a forecast.
--
-- The retirement rate cannot be read out of rdap_registrant_tbl, because
-- storeRecord has ON CONFLICT (start_ip, end_ip) DO UPDATE ... fetched_at =
-- now(). The table holds one row per DISTINCT allocation, not one per query,
-- and a re-returned allocation has its timestamp overwritten. Query count is
-- simply not in the database.
--
-- It CAN be read off the running log, because main.go sorts candidates
-- widest-first:
--
--     sort.Slice(targets, func(i, j int) bool {
--         if targets[i].Bits() != targets[j].Bits() { return targets[i].Bits() < targets[j].Bits() }
--         return targets[i].Addr().Less(targets[j].Addr()) })
--
-- Prefix length along the run is therefore monotonically non-decreasing. Every
-- candidate narrower than the one being queried is untouched; every candidate
-- wider has been either queried or retired. So, reading the last [N] line of
-- the log for the query counter N and the prefix it is on:
--
--     candidates passed   = cumulative_candidates at that masklen   (this table)
--     candidates retired  = candidates passed - N
--     retired per query   = (candidates passed - N) / N
--
-- Run it at two different points in the log and the change between them is the
-- marginal rate, which is the number that forecasts the rest. That is a
-- measurement, not an extrapolation.
--
--
-- WHY THE DIRECTION OF THE TREND IS AN OPEN QUESTION
--
-- I previously claimed retirement per query must decay because the widest
-- candidates are queried first. That was asserted, not measured, and
-- lookupCovered argues against it:
--
--     if covered[i].start <= lo && covered[i].end >= hi
--
-- Retirement needs an allocation to contain the candidate WHOLLY. A /10
-- candidate is unlikely to sit inside any single ARIN allocation, so wide
-- candidates largely cost one query each and retire little. A /23 is easily
-- contained by a legacy /8, so narrow candidates can retire in bulk. That
-- pushes the rate UP as the run proceeds. Against it, the large legacy
-- allocations are consumed early. Which effect dominates is exactly what the
-- arithmetic above measures, and I am not going to predict it.
--
--
-- HOW TO RUN
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f rdap_fill_decay.sql
--
-- Cheap: one pass over the candidate table and its db-ip join, no RDAP calls,
-- no writes.

\timing on
\pset pager off

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT c.relname AS table_name,
       (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS columns
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('rdap_fill_cand_tbl', 'ip2city_dbiplite_tbl',
                    'geo_exclusions', 'rdap_registrant_tbl')
ORDER BY c.relname;

\echo ''
\echo 'All four must be present. geo_exclusions is optional to the Go tool but'
\echo 'it IS present in this database, so the filter below must include it or'
\echo 'the denominators will not match what the tool loaded.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. THE CANDIDATE SET BY PREFIX LENGTH, CUMULATIVE.'
\echo '================================================================'
\echo ''
\echo 'Filters replicate loadCandidates for the -candidates rdap_fill_cand_tbl'
\echo 'case exactly: the db-ip join on source = dbip, family 4, masklen < 24,'
\echo 'and NOT EXISTS against active geo_exclusions prefixes. DISTINCT is on'
\echo 'network before masking, as the Go query does it.'
\echo ''

WITH cand AS (
    SELECT DISTINCT c.network
    FROM rdap_fill_cand_tbl c
    JOIN ip2city_dbiplite_tbl d
      ON d.network = c.network AND d.source = 'dbip'
    WHERE family(c.network) = 4
      AND masklen(c.network) < 24
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                       WHERE x.active AND x.prefix IS NOT NULL
                         AND c.network <<= x.prefix)
), per AS (
    SELECT masklen(network) AS bits, count(*) AS candidates
    FROM cand GROUP BY 1
)
SELECT bits AS prefix_len,
       candidates,
       sum(candidates) OVER (ORDER BY bits) AS cumulative_candidates,
       round(100.0 * sum(candidates) OVER (ORDER BY bits)
             / nullif(sum(candidates) OVER (), 0), 2) AS cumulative_pct
FROM per
ORDER BY bits;

\echo ''
\echo 'cumulative_candidates is the column to use. Take the prefix length from'
\echo 'the last [N] line of the fill log, read cumulative_candidates on that'
\echo 'row, subtract N, and that is how many candidates the run has retired'
\echo 'without querying them.'
\echo ''
\echo 'The total on the last row should reconcile with 281,951 candidates. If'
\echo 'it does not, the candidate set has changed since that figure was taken'
\echo 'and every projection built on it needs redoing. Check that first.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 2. WHAT THE CACHE HOLDS NOW.'
\echo '================================================================'
\echo ''
\echo 'Allocations, NOT queries, for the ON CONFLICT reason above. This is the'
\echo 'number to compare against the 1,065 and 1,457 figures I quoted earlier,'
\echo 'which cannot both be right alongside a 357-query run: each query inserts'
\echo 'at most one row, so +392 rows from 357 queries is impossible. Whichever'
\echo 'is wrong, the 234-candidates-per-query rate derived from them is'
\echo 'unsourced until this reconciles.'
\echo ''

SELECT count(*)                                              AS allocations_cached,
       count(*) FILTER (WHERE family(start_ip) = 4)          AS ipv4_allocations,
       min(fetched_at)                                       AS earliest_fetch,
       max(fetched_at)                                       AS latest_fetch
FROM rdap_registrant_tbl;

\echo ''
\echo 'Distinct fetch seconds, which bounds the queries whose timestamps have'
\echo 'not been overwritten. At -rate 1 a run makes about one query per second,'
\echo 'so this is a floor on queries made, not a count of them.'
\echo ''

SELECT count(DISTINCT date_trunc('second', fetched_at)) AS distinct_fetch_seconds
FROM rdap_registrant_tbl;

\echo ''
\echo 'Done. Nothing was modified.'
\echo ''
