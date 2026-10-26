-- node_fanout_report.sql - the small answer, read off the tables the long run built.
--
-- node_fanout.sql already produced node_fanout_tbl and address_hosting_tbl, so
-- nothing is recomputed here and nothing is traced again. This only reads them.
--
-- Section 1 comes first on purpose. A fan-out computed from one or two
-- landmarks measures sample size, not the node, which is exactly what
-- invalidated the earlier "Comcast is nearly ZIP-specific" claim: 14 router IPs
-- over 16 landmarks is 1.14 landmarks per router, so zips_at_node = 1 was
-- arithmetic rather than measurement. If section 1 says the mean is below about
-- 3, sections 3 to 5 are noise and should be read as such.

SELECT '=== 1. STATISTICAL POWER. Read this before anything else. ===' AS section;

SELECT count(*)                                                        AS nodes,
       sum(landmarks_at_node)                                          AS landmarks,
       round(avg(landmarks_at_node), 2)                                AS mean_landmarks_per_node,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY landmarks_at_node)   AS median_landmarks,
       max(landmarks_at_node)                                          AS max_landmarks,
       count(*) FILTER (WHERE landmarks_at_node >= 3)                  AS nodes_measurable,
       round(100.0 * count(*) FILTER (WHERE landmarks_at_node >= 3)
             / nullif(count(*), 0), 1)                                 AS pct_measurable
FROM node_fanout_tbl;

SELECT '=== 2. VERDICT SUMMARY, all nodes ===' AS section;

SELECT verdict,
       count(*)                                                        AS nodes,
       sum(landmarks_at_node)                                          AS landmarks,
       round(100.0 * sum(landmarks_at_node)
             / nullif(sum(sum(landmarks_at_node)) OVER (), 0), 1)      AS pct_landmarks
FROM node_fanout_tbl
GROUP BY 1
ORDER BY 3 DESC;

SELECT '=== 3. PER OPERATOR, MEASURABLE NODES ONLY (>= 3 landmarks), top 15 ===' AS section;

SELECT coalesce(reverse(split_part(reverse(node_hostname), '.', 2)) || '.'
                || reverse(split_part(reverse(node_hostname), '.', 1)),
                '(unnamed)')                                           AS domain,
       count(*)                                                        AS nodes,
       sum(landmarks_at_node)                                          AS landmarks,
       round(avg(landmarks_at_node), 2)                                AS mean_landmarks_per_node,
       round(avg(zips_at_node), 2)                                     AS mean_zips,
       round(avg(clusters_at_node), 2)                                 AS mean_clusters,
       count(*) FILTER (WHERE verdict LIKE 'zip-level%')               AS zip_level,
       count(*) FILTER (WHERE verdict LIKE 'reject%')                  AS rejected
FROM node_fanout_tbl
WHERE landmarks_at_node >= 3
GROUP BY 1
ORDER BY 3 DESC
LIMIT 15;

SELECT '=== 4. THE BROCKTON TEST. Worst measurable rejects, 20 only ===' AS section;

SELECT node_hostname,
       tier,
       landmarks_at_node                                               AS lm,
       zips_at_node                                                    AS zips,
       clusters_at_node                                                AS clusters
FROM node_fanout_tbl
WHERE verdict LIKE 'reject%'
  AND landmarks_at_node >= 3
ORDER BY clusters_at_node DESC NULLS FIRST, zips_at_node DESC
LIMIT 20;

SELECT '=== 5. COMCAST SPECIFICALLY, since that was the claim under test ===' AS section;

SELECT count(*)                                                        AS comcast_nodes,
       sum(landmarks_at_node)                                          AS landmarks,
       round(avg(landmarks_at_node), 2)                                AS mean_landmarks_per_node,
       count(*) FILTER (WHERE landmarks_at_node >= 3)                  AS measurable,
       count(*) FILTER (WHERE landmarks_at_node >= 3
                          AND verdict LIKE 'zip-level%')               AS measurable_zip_level,
       count(*) FILTER (WHERE landmarks_at_node >= 3
                          AND verdict LIKE 'reject%')                  AS measurable_rejected
FROM node_fanout_tbl
WHERE node_hostname ILIKE '%comcast%';

SELECT '=== 6. ADDRESS-LEVEL HOSTING, the rule that replaces registrant names ===' AS section;

SELECT verdict,
       count(*)                                                        AS addresses,
       sum(places)                                                     AS places
FROM address_hosting_tbl
GROUP BY 1
ORDER BY 2 DESC;

SELECT '=== 7. RULE 3a HOLE: hosting addresses whose registrant is in isp_names ===' AS section;
SELECT '    These are ISP web-hosting addresses admitted as landmarks unconditionally.' AS section;

SELECT count(*)                                                        AS hosting_addresses,
       sum(h.places)                                                   AS places_affected,
       count(*) FILTER (WHERE i.name IS NOT NULL)                      AS registrant_is_isp,
       sum(h.places) FILTER (WHERE i.name IS NOT NULL)                 AS places_via_isp
FROM address_hosting_tbl h
LEFT JOIN isp_names i
       ON lower(btrim(i.name)) = lower(btrim(h.registrant))
WHERE h.verdict LIKE 'hosting%';

SELECT '=== 8. The 12 biggest hosting registrants, to size the hole ===' AS section;

SELECT coalesce(h.registrant, '(none)')                                AS registrant,
       count(*)                                                        AS addresses,
       sum(h.places)                                                   AS places,
       max(h.zips_at_address)                                          AS max_zips,
       max(h.clusters_at_address)                                      AS max_clusters
FROM address_hosting_tbl h
WHERE h.verdict LIKE 'hosting%'
GROUP BY 1
ORDER BY 3 DESC
LIMIT 12;
