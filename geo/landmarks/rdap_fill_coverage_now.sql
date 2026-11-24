-- rdap_fill_coverage_now.sql
--
-- READ-ONLY. How much of the candidate set the 2,379 cached allocations
-- already retire, BROKEN OUT BY PREFIX LENGTH. That breakdown is the point:
-- it settles, from data rather than from argument, which way retirement per
-- query actually moves as the fill walks from wide candidates to narrow ones.
--
--
-- THE QUESTION THIS DECIDES
--
-- The fill retires a candidate only when one allocation contains it WHOLLY:
--
--     if covered[i].start <= lo && covered[i].end >= hi
--
-- I first claimed retirement per query must DECAY, because main.go sorts
-- candidates widest-first and the big legacy allocations are consumed early.
-- Then I retracted that, because full containment favours narrow candidates: a
-- /23 is easily swallowed whole by a /12, a /10 almost never is. Both effects
-- are real and I refused to guess which dominates.
--
-- rdap_fill_decay.sql settled the shape of the work. Measured 2026-11-09:
--
--     prefix 23      151,239 candidates      53.6 per cent
--     prefix 22       76,052                 27.0
--     prefix 21       28,196                 10.0
--     prefix 20       12,537                  4.4
--     prefix 19 and wider  13,911             4.9
--
--     total          281,935
--
-- So four fifths of the candidate set is /22 or /23, and those are precisely
-- the candidates most likely to sit wholly inside an allocation already
-- fetched. The one-query-per-candidate upper bound of 168,405 queries, 1.95
-- days at -rate 1, is therefore not a plausible outcome. It would require
-- almost every /22 and /23 to fall outside every allocation ever returned.
--
-- What remains unmeasured is how far inside. This file measures it: coverage
-- per prefix length. If coverage climbs steeply with prefix length, narrow
-- candidates are being retired in bulk and the remaining run is short. If it
-- is flat, they are not, and the bound matters after all.
--
--
-- HOW IT WORKS
--
-- Both sides are reduced to integer offsets from 0.0.0.0 with inet
-- subtraction, which yields bigint, then compared as int8range with a GiST
-- index. Done as inet comparisons instead, the mask length participates in the
-- ordering and a cidr with a mask does not compare as its first address, which
-- is a quiet source of wrong answers. Ranges are half-open, hence the + 1 on
-- each upper bound.
--
-- The candidate set is materialised once because building it costs three
-- minutes, nearly all of it the db-ip join. Filters replicate loadCandidates
-- for the -candidates case exactly.
--
--
-- HOW TO RUN
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f rdap_fill_coverage_now.sql
--
-- Expect about four minutes, three of them in section 1. No RDAP calls, no
-- writes to any permanent table.

\timing on
\pset pager off

\echo ''
\echo '================================================================'
\echo ' 1. MATERIALISE THE CANDIDATE SET (about three minutes).'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_cand_rng;

CREATE UNLOGGED TABLE tmp_cand_rng AS
SELECT masklen(c.network) AS bits,
       int8range(host(c.network)::inet - '0.0.0.0'::inet,
                 (host(broadcast(c.network))::inet - '0.0.0.0'::inet) + 1) AS r
FROM (
    SELECT DISTINCT c.network
    FROM rdap_fill_cand_tbl c
    JOIN ip2city_dbiplite_tbl d
      ON d.network = c.network AND d.source = 'dbip'
    WHERE family(c.network) = 4
      AND masklen(c.network) < 24
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                       WHERE x.active AND x.prefix IS NOT NULL
                         AND c.network <<= x.prefix)
) c;

ANALYZE tmp_cand_rng;

SELECT count(*) AS candidates_materialised FROM tmp_cand_rng;

\echo ''
\echo 'Must read 281,935, matching rdap_fill_decay.sql. Note that figure is 16'
\echo 'short of the 281,951 I have been quoting, so the candidate set is live,'
\echo 'not frozen. Sixteen rows is immaterial to any projection here, but it'
\echo 'means a stated candidate total has a date attached to it.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 2. THE CACHED ALLOCATIONS AS RANGES.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_alloc_rng;

CREATE UNLOGGED TABLE tmp_alloc_rng AS
SELECT int8range(start_ip - '0.0.0.0'::inet,
                 (end_ip - '0.0.0.0'::inet) + 1) AS r
FROM rdap_registrant_tbl
WHERE family(start_ip) = 4 AND family(end_ip) = 4
  AND end_ip >= start_ip;

CREATE INDEX ON tmp_alloc_rng USING gist (r);
ANALYZE tmp_alloc_rng;

SELECT count(*)                        AS allocations,
       min(upper(r) - lower(r))        AS smallest_addresses,
       round(avg(upper(r) - lower(r))) AS mean_addresses,
       max(upper(r) - lower(r))        AS largest_addresses
FROM tmp_alloc_rng;

\echo ''
\echo 'Allocation size is the proximate driver of how many candidates a single'
\echo 'query retires, so the mean here is worth more than any rate I quoted'
\echo 'from memory.'
\echo ''

\echo 'Allocation size distribution, as the equivalent prefix length:'
SELECT CASE WHEN upper(r) - lower(r) >= 16777216 THEN 'a  /8 or wider'
            WHEN upper(r) - lower(r) >=  1048576 THEN 'b  /12 to /9'
            WHEN upper(r) - lower(r) >=    65536 THEN 'c  /16 to /13'
            WHEN upper(r) - lower(r) >=     4096 THEN 'd  /20 to /17'
            WHEN upper(r) - lower(r) >=      256 THEN 'e  /24 to /21'
            ELSE                                      'f  narrower than /24' END AS alloc_size,
       count(*) AS allocations
FROM tmp_alloc_rng
GROUP BY 1
ORDER BY 1;

\echo ''
\echo 'An allocation narrower than /24 can never retire any candidate, because'
\echo 'every candidate is wider than a /24 and containment must be total. Those'
\echo 'rows are cache weight that buys nothing on this candidate set.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. THE ANSWER. COVERAGE BY PREFIX LENGTH.'
\echo '================================================================'
\echo ''

WITH cov AS (
    SELECT c.bits,
           EXISTS (SELECT 1 FROM tmp_alloc_rng a WHERE a.r @> c.r) AS covered
    FROM tmp_cand_rng c
)
SELECT bits                                            AS prefix_len,
       count(*)                                        AS candidates,
       count(*) FILTER (WHERE covered)                 AS covered,
       count(*) FILTER (WHERE NOT covered)             AS still_to_do,
       round(100.0 * count(*) FILTER (WHERE covered)
             / nullif(count(*), 0), 1)                 AS covered_pct
FROM cov
GROUP BY bits
ORDER BY bits;

\echo ''
\echo 'READ THE covered_pct COLUMN DOWN THE PAGE. That is the whole question.'
\echo ''
\echo '  Rising with prefix length means full containment dominates: narrow'
\echo '  candidates are being retired in bulk by allocations already held, so'
\echo '  retirement per query RISES as the run proceeds and my original decay'
\echo '  claim was backwards.'
\echo ''
\echo '  Flat or falling means the legacy-allocation effect dominates after'
\echo '  all, the remaining narrow candidates sit outside everything fetched,'
\echo '  and the one-query-each bound is close to the truth.'
\echo ''

\echo 'Totals, to reconcile against the 113,546 covered / 168,405 remaining'
\echo 'figures taken earlier:'
WITH cov AS (
    SELECT EXISTS (SELECT 1 FROM tmp_alloc_rng a WHERE a.r @> c.r) AS covered
    FROM tmp_cand_rng c
)
SELECT count(*)                            AS candidates,
       count(*) FILTER (WHERE covered)     AS covered,
       count(*) FILTER (WHERE NOT covered) AS still_to_do
FROM cov;

\echo ''
\echo 'Divide covered by the allocation count in section 2 for the cumulative'
\echo 'candidates-retired-per-allocation. Compare that with the 234 per query I'
\echo 'quoted from unreconciled numbers, and trust this one: both terms come'
\echo 'from the same database at the same moment.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 4. THE REMAINING WORK, WIDEST FIRST, AS THE RUN WILL MEET IT.'
\echo '================================================================'
\echo ''

WITH cov AS (
    SELECT c.bits,
           EXISTS (SELECT 1 FROM tmp_alloc_rng a WHERE a.r @> c.r) AS covered
    FROM tmp_cand_rng c
), todo AS (
    SELECT bits, count(*) AS still_to_do
    FROM cov WHERE NOT covered GROUP BY bits
)
SELECT bits                                                  AS prefix_len,
       still_to_do,
       sum(still_to_do) OVER (ORDER BY bits)                 AS cumulative_to_do,
       round(sum(still_to_do) OVER (ORDER BY bits) / 3600.0, 2)
                                                             AS hours_if_one_query_each
FROM todo
ORDER BY bits;

\echo ''
\echo 'hours_if_one_query_each is the WORST CASE at -rate 1, assuming no'
\echo 'candidate is ever retired by another query answer. It is an upper bound'
\echo 'by construction. The real figure is lower by whatever section 3 shows.'
\echo ''
\echo 'The row for prefix 20 is the one to read: everything /20 and wider is'
\echo 'the part of the run that cannot benefit much from bulk containment, so'
\echo 'its cumulative figure is close to a floor on the time still needed.'
\echo ''

DROP TABLE IF EXISTS tmp_cand_rng;
DROP TABLE IF EXISTS tmp_alloc_rng;

\echo 'Done. Nothing permanent was modified.'
\echo ''
