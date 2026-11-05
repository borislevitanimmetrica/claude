-- rdap_fill_sizing.sql
--
-- How much work is left in the RDAP fill, and how it is distributed by prefix
-- width. Read only.
--
-- WHY THIS EXISTS RATHER THAN AN EXTRAPOLATION
--
-- The first bounded run reported 1,146 already covered, 500 queried, which is
-- 0.30 queries per candidate processed. Extrapolating that over 281,957
-- candidates gives about 85,000 queries and 24 hours at one per second.
--
-- That extrapolation is WRONG, and the reason is in the tool's own ordering.
-- geo/rdap_registrant/cmd/main.go line 187 sorts candidates WIDEST FIRST, with
-- the stated rationale that a wide candidate is more likely to sit inside or
-- coincide with a large allocation, so resolving it covers more of the
-- remaining set per query. Every entry in the first 500 was a /16 returning an
-- allocation of exactly 65,536 addresses, i.e. covering itself and nothing
-- further. So those 500 came from the tier where a query buys the LEAST, and
-- 0.30 is an upper bound on the ratio rather than an average.
--
-- The payoff arrives in the narrow tiers: a /20 or /23 candidate inside a /16
-- already fetched needs no query at all. So the real question is how many
-- candidates sit at each width, and that is a counting question with an exact
-- answer rather than something to estimate.
--
-- THE CANDIDATE SET BELOW IS THE TOOL'S OWN, COPIED FROM loadCandidates at
-- main.go lines 658 to 667, not reconstructed from the flag documentation:
-- the probe table joined to dbip-sourced master rows on an exact network
-- match, IPv4 only, strictly wider than a /24, minus active prefix exclusions.
-- Anything that changes there must change here too.

\timing on

-- ---------------------------------------------------------------------------
-- 1. WHERE THE WORK IS, by prefix width.
--
-- Read this with the ordering in mind: the fill works top to bottom. Once a
-- row's width has been processed, candidates in every LOWER row that fall
-- inside one of those allocations cost nothing.
-- ---------------------------------------------------------------------------
SELECT masklen(c.network)        AS prefix_width,
       count(DISTINCT c.network) AS candidates,
       sum(count(DISTINCT c.network)) OVER (ORDER BY masklen(c.network))
                                 AS cumulative
FROM ip2city_dbiplite_probe_tbl c
JOIN ip2city_dbiplite_tbl d
  ON d.network = c.network
 AND d.source = 'dbip'
WHERE family(c.network) = 4
  AND masklen(c.network) < 24
  AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                  WHERE x.active AND x.prefix IS NOT NULL
                    AND c.network <<= x.prefix)
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 2. WHAT THE CACHE ALREADY HOLDS, by allocation size.
--
-- A wide allocation covers many narrow candidates, so this is the other half
-- of the arithmetic. Sizes are reported as the equivalent prefix width where
-- the allocation happens to be a power of two; RDAP allocations are not
-- required to be single CIDR blocks, which is why the table stores boundaries.
-- ---------------------------------------------------------------------------
SELECT count(*)                                            AS allocations,
       sum((end_ip - start_ip) + 1)                        AS addresses_covered,
       round(100.0 * sum((end_ip - start_ip) + 1) / 4294967296.0, 2)
                                                           AS pct_of_ipv4
FROM rdap_registrant_tbl
WHERE family(start_ip) = 4;

SELECT CASE
         WHEN (end_ip - start_ip) + 1 >= 16777216 THEN 'a /8 or wider'
         WHEN (end_ip - start_ip) + 1 >= 1048576  THEN 'b /12 to /9'
         WHEN (end_ip - start_ip) + 1 >= 65536    THEN 'c /16 to /13'
         WHEN (end_ip - start_ip) + 1 >= 4096     THEN 'd /20 to /17'
         WHEN (end_ip - start_ip) + 1 >= 256      THEN 'e /24 to /21'
         ELSE                                          'f narrower than a /24'
       END                                      AS allocation_size,
       count(*)                                 AS allocations,
       sum((end_ip - start_ip) + 1)             AS addresses
FROM rdap_registrant_tbl
WHERE family(start_ip) = 4
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 3. HOW MANY CANDIDATES THE CURRENT CACHE ALREADY ANSWERS.
--
-- This is the same containment test the tool does in Go, done in SQL so the
-- answer can be had without another walk. A candidate counts as covered only
-- if an allocation contains it WHOLLY, which is the tool's lookupCovered
-- condition at main.go line 700: start <= lo AND end >= hi.
--
-- Subtract this from section 1's total and the remainder is the real work, not
-- an extrapolation from the widest tier.
-- ---------------------------------------------------------------------------
WITH cand AS (
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
)
SELECT count(*)                                        AS candidates,
       count(*) FILTER (WHERE cov.ok)                  AS already_covered,
       count(*) FILTER (WHERE NOT cov.ok)              AS still_to_resolve,
       round(100.0 * count(*) FILTER (WHERE cov.ok)
             / greatest(count(*), 1), 1)               AS pct_covered
FROM cand
CROSS JOIN LATERAL (
    SELECT EXISTS (
        SELECT 1 FROM rdap_registrant_tbl r
        WHERE r.start_ip <= host(network(cand.network))::inet
          AND r.end_ip   >= host(broadcast(cand.network))::inet
    ) AS ok
) cov;

-- ---------------------------------------------------------------------------
-- 4. THE SAME SPLIT BY WIDTH, which is what predicts the remaining run.
--
-- If the narrow tiers are mostly already covered, the fill is nearly done
-- whatever the raw candidate count says. If they are not, the width
-- distribution in section 1 says how many queries each tier will cost.
-- ---------------------------------------------------------------------------
WITH cand AS (
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
)
SELECT masklen(cand.network)                     AS prefix_width,
       count(*)                                  AS candidates,
       count(*) FILTER (WHERE cov.ok)            AS already_covered,
       count(*) FILTER (WHERE NOT cov.ok)        AS still_to_resolve
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

\timing off
