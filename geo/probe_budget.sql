-- probe_budget.sql
-- Size the probe job for the 24,168 flagged split ranges, before and after the
-- geo_exclusions rules, at one probe per /24.
--
-- Requires: dbip_split_candidates (check_range_splits -write) and
--           geo_exclusions (geo_exclusions.sql + geo_exclusions_seed_dod.sql).
--
-- Contains NO backslashes so it survives copy/paste.

SELECT '1. mask distribution of flagged split ranges' AS section;
SELECT masklen(network) AS len, count(*) AS ranges,
       sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) AS probes
FROM dbip_split_candidates
GROUP BY 1 ORDER BY 1;

SELECT '2. TOTAL probe budget, no exclusions' AS section;
SELECT count(*) AS ranges,
       sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) AS probes,
       round(sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) / 64800.0, 1)
           AS days_at_45_per_min
FROM dbip_split_candidates;

SELECT '3. TOTAL probe budget, DoD prefixes excluded' AS section;
SELECT count(*) AS ranges,
       sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) AS probes,
       round(sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) / 64800.0, 1)
           AS days_at_45_per_min
FROM dbip_split_candidates c
WHERE NOT EXISTS (SELECT 1 FROM geo_exclusions x
                  WHERE x.active AND x.prefix IS NOT NULL
                    AND c.network <<= x.prefix);

SELECT '4. what the DoD exclusion removed' AS section;
SELECT count(*) AS ranges_excluded,
       sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) AS probes_avoided,
       round(sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) / 64800.0, 1)
           AS days_saved
FROM dbip_split_candidates c
WHERE EXISTS (SELECT 1 FROM geo_exclusions x
              WHERE x.active AND x.prefix IS NOT NULL
                AND c.network <<= x.prefix);

SELECT '5. cost if capped: exclude DoD AND ranges wider than /12' AS section;
SELECT count(*) AS ranges,
       sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) AS probes,
       round(sum(pow(2, greatest(0, 24 - masklen(network)))::bigint) / 64800.0, 1)
           AS days_at_45_per_min
FROM dbip_split_candidates c
WHERE masklen(network) >= 12
  AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                  WHERE x.active AND x.prefix IS NOT NULL
                    AND c.network <<= x.prefix);

SELECT '6. the 20 costliest surviving ranges after DoD exclusion' AS section;
SELECT c.network, c.country_iso_code, c.bgp_children,
       pow(2, greatest(0, 24 - masklen(c.network)))::bigint AS probes
FROM dbip_split_candidates c
WHERE NOT EXISTS (SELECT 1 FROM geo_exclusions x
                  WHERE x.active AND x.prefix IS NOT NULL
                    AND c.network <<= x.prefix)
ORDER BY probes DESC, c.bgp_children DESC
LIMIT 20;

SELECT '7. how many flagged ranges already hold finer db-ip rows' AS section;
-- These are the ranges where a /24 probe must NOT overwrite existing detail.
SELECT count(DISTINCT c.network) AS flagged_ranges_containing_sub24_dbip_rows
FROM dbip_split_candidates c
JOIN ip2city_dbiplite_tbl d ON d.network << c.network
WHERE masklen(d.network) > 24;
