-- sub24_analysis.sql
-- Question: how many ranges narrower than /24 exist in bgp_route_views and in
-- ip2city_dbiplite_tbl, and do any of them CONFLICT (different city) inside a
-- single /24? Conflicts matter because ip-api was measured to return a constant
-- answer within a /24, so one probe per /24 cannot distinguish sub-/24 blocks.

\echo '=== 1a. BGP prefixes narrower than /24, by mask length ==='
SELECT masklen(cidr_block) AS len, count(*) AS prefixes
FROM bgp_route_views
WHERE family(cidr_block) = 4 AND masklen(cidr_block) > 24
GROUP BY 1 ORDER BY 1;

\echo '=== 1b. BGP overall split around /24 ==='
SELECT count(*) FILTER (WHERE masklen(cidr_block) < 24) AS wider_than_24,
       count(*) FILTER (WHERE masklen(cidr_block) = 24) AS exactly_24,
       count(*) FILTER (WHERE masklen(cidr_block) > 24) AS narrower_than_24,
       count(*) AS total_ipv4
FROM bgp_route_views
WHERE family(cidr_block) = 4;

\echo '=== 2a. db-ip ranges narrower than /24, by mask length ==='
SELECT masklen(network) AS len, count(*) AS ranges
FROM ip2city_dbiplite_tbl
WHERE family(network) = 4 AND masklen(network) > 24
GROUP BY 1 ORDER BY 1;

\echo '=== 2b. db-ip overall split around /24 ==='
SELECT count(*) FILTER (WHERE masklen(network) < 24) AS wider_than_24,
       count(*) FILTER (WHERE masklen(network) = 24) AS exactly_24,
       count(*) FILTER (WHERE masklen(network) > 24) AS narrower_than_24,
       count(*) AS total_ipv4
FROM ip2city_dbiplite_tbl
WHERE family(network) = 4;

\echo '=== 3. Are the sub-/24 db-ip ranges even LABELED with a city? ==='
SELECT count(*) AS sub24_rows,
       count(*) FILTER (WHERE nullif(btrim(coalesce(city, '')), '') IS NOT NULL) AS labeled_city,
       count(*) FILTER (WHERE nullif(btrim(coalesce(city, '')), '') IS NULL) AS unlabeled_city
FROM ip2city_dbiplite_tbl
WHERE family(network) = 4 AND masklen(network) > 24;

\echo '=== 4. DECISIVE: do sub-/24 ranges inside one /24 disagree on city? ==='
WITH sub AS (
  SELECT set_masklen(network, 24) AS parent24,
         nullif(btrim(coalesce(city, '')), '') AS city
  FROM ip2city_dbiplite_tbl
  WHERE family(network) = 4 AND masklen(network) > 24
), agg AS (
  SELECT parent24, count(*) AS rows_in_block,
         count(DISTINCT city) AS distinct_cities
  FROM sub GROUP BY parent24
)
SELECT count(*) AS parent24_blocks_holding_sub24_rows,
       count(*) FILTER (WHERE distinct_cities > 1) AS blocks_with_CONFLICTING_cities,
       count(*) FILTER (WHERE distinct_cities = 1) AS blocks_one_city,
       count(*) FILTER (WHERE distinct_cities = 0) AS blocks_entirely_unlabeled
FROM agg;

\echo '=== 5. Worst conflicting /24s (empty result = problem can be disregarded) ==='
WITH sub AS (
  SELECT set_masklen(network, 24) AS parent24,
         nullif(btrim(coalesce(city, '')), '') AS city
  FROM ip2city_dbiplite_tbl
  WHERE family(network) = 4 AND masklen(network) > 24
)
SELECT parent24, count(*) AS rows_in_block,
       count(DISTINCT city) AS distinct_cities,
       string_agg(DISTINCT city, ' | ' ORDER BY city) AS cities
FROM sub
GROUP BY parent24
HAVING count(DISTINCT city) > 1
ORDER BY distinct_cities DESC, rows_in_block DESC
LIMIT 25;

\echo '=== 6. Exposure: sub-/24 BGP children inside flagged split ranges ==='
-- How many of the prefixes we would INSERT are narrower than /24, and how many
-- distinct /24s do they collapse into (that is the real probe count).
SELECT count(*) AS sub24_bgp_children,
       count(DISTINCT set_masklen(b.cidr_block, 24)) AS distinct_parent24_to_probe
FROM dbip_split_candidates c
JOIN bgp_route_views b ON b.cidr_block << c.network
WHERE family(b.cidr_block) = 4 AND masklen(b.cidr_block) > 24;
