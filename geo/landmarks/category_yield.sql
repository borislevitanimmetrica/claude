-- category_yield.sql
--
-- WHICH KINDS OF INSTITUTION ACTUALLY DELIVER A LANDMARK.
--
-- This is the question behind "consider police station landmarks", and it does
-- not need a new source to answer. The OSM load is already national and already
-- enriched: 1,139,855 rows, 1,070,335 resolved, 986,630 with RDAP and a ZIP.
-- For OSM rows, lm_fetch.py's osm_tags_to_row writes the OSM `amenity` value
-- into `category`, so `category = 'police'` IS the police stations and
-- `category = 'fire_station'` IS the fire stations.
--
-- So every institution type anyone might propose has already been run through
-- the full chain at national scale, and the yield can be read rather than
-- guessed. Section 2 answers police directly. Section 3 answers fire stations,
-- which matters because it PREDICTS what the USFA registry will deliver from
-- your own data instead of from my analogy.
--
-- WHY THE TOP-LEVEL PER-SOURCE RATES MAKE THIS URGENT. From lm_fetch.py status,
-- 2026-11-03, onpremises_true divided by rows:
--
--   nces_ipeds    328 of   6,075   5.40 pct   312 ZIPs delivered
--   wikidata      876 of  24,721   3.54 pct   582
--   overture  119,890 of 13.80M    0.87 pct 15,962
--   foursquare  2,191 of 275,517   0.80 pct   387
--   osm         8,735 of 1.14M     0.77 pct 2,755
--   ca_cde         54 of   8,816   0.61 pct    26
--   dotgov         51 of  14,149   0.36 pct    44
--
-- Colleges are seven times better than municipalities and nine times better than
-- California schools. That spread is the whole game, and a per-category read of
-- the OSM corpus is the cheapest way to find the rest of it.
--
-- READ-ONLY. No table is created, altered or dropped.

\timing on
\set ON_ERROR_STOP on

\echo ''
\echo 'Timing note, so no step looks like a hang. Sections 1 to 4 scan the'
\echo 'landmarks_usa rows for source = osm, 1,139,855 of about 15.2 million, so'
\echo 'expect tens of seconds each rather than minutes. Section 5 probes the'
\echo 'partial index landmarks_usa_onprem_zip_idx once per delivered'
\echo 'category-and-ZIP pair, at most 8,735 probes, and is fast.'

\echo ''
\echo '=== 1 of 5: is the category column populated for OSM at all? ==='
\echo '    If nearly everything is NULL this file cannot answer and that is the'
\echo '    answer: the OSM loader only fills category from amenity, shop, office,'
\echo '    tourism, healthcare or leisure, so untagged features have none.'
SELECT count(*)                                            AS osm_rows,
       count(*) FILTER (WHERE btrim(coalesce(category, '')) <> '')
                                                           AS with_category,
       count(DISTINCT category)                            AS distinct_categories
FROM landmarks_usa
WHERE source = 'osm';

\echo ''
\echo '=== 2 of 5: POLICE, answered from the data already loaded ==='
SELECT count(*)                                        AS rows,
       count(*) FILTER (WHERE ip_address IS NOT NULL)  AS resolved,
       count(*) FILTER (WHERE overture_zip IS NOT NULL) AS have_zip,
       count(*) FILTER (WHERE onpremises)              AS onpremises_true,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises) AS zips_delivered,
       count(DISTINCT ip_address)   FILTER (WHERE onpremises) AS addresses_delivered,
       round(100.0 * count(*) FILTER (WHERE onpremises)
             / greatest(count(*), 1), 2)               AS pct_onpremises
FROM landmarks_usa
WHERE source = 'osm'
  AND category = 'police';

\echo ''
\echo '--- and why the rest failed, which decides whether a registry would help ---'
SELECT coalesce(onpremises_reason, '(null)') AS reason,
       count(*)                              AS rows
FROM landmarks_usa
WHERE source = 'osm'
  AND category = 'police'
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 3 of 5: FIRE STATIONS, which predict the USFA registry ==='
\echo '    Same chain, same rule, same country. If OSM fire stations deliver'
\echo '    poorly then 8,685 USFA rows will deliver poorly too, and the reason'
\echo '    will be visible below rather than discovered after the load.'
SELECT count(*)                                        AS rows,
       count(*) FILTER (WHERE ip_address IS NOT NULL)  AS resolved,
       count(*) FILTER (WHERE onpremises)              AS onpremises_true,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises) AS zips_delivered,
       round(100.0 * count(*) FILTER (WHERE onpremises)
             / greatest(count(*), 1), 2)               AS pct_onpremises
FROM landmarks_usa
WHERE source = 'osm'
  AND category = 'fire_station';

\echo ''
SELECT coalesce(onpremises_reason, '(null)') AS reason,
       count(*)                              AS rows
FROM landmarks_usa
WHERE source = 'osm'
  AND category = 'fire_station'
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 4 of 5: EVERY category, ranked by ZIPs actually delivered ==='
\echo '    This is the shopping list. A category near the top is worth finding'
\echo '    an authoritative registry for; one near the bottom is not, however'
\echo '    many rows it has.'
SELECT category,
       count(*)                                               AS rows,
       count(*) FILTER (WHERE onpremises)                     AS onpremises_true,
       round(100.0 * count(*) FILTER (WHERE onpremises)
             / greatest(count(*), 1), 2)                      AS pct,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises) AS zips_delivered,
       count(DISTINCT ip_address)   FILTER (WHERE onpremises) AS addresses_delivered
FROM landmarks_usa
WHERE source = 'osm'
  AND btrim(coalesce(category, '')) <> ''
GROUP BY 1
HAVING count(*) >= 200
ORDER BY zips_delivered DESC, pct DESC
LIMIT 60;

\echo ''
\echo '--- the same, ranked by hit RATE, for categories with at least 200 rows ---'
\echo '    Rate matters where a registry is small: 6,075 colleges at 5.40 pct'
\echo '    beat 14,149 municipalities at 0.36 pct on both counts.'
SELECT category,
       count(*)                                               AS rows,
       count(*) FILTER (WHERE onpremises)                     AS onpremises_true,
       round(100.0 * count(*) FILTER (WHERE onpremises)
             / greatest(count(*), 1), 2)                      AS pct,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises) AS zips_delivered
FROM landmarks_usa
WHERE source = 'osm'
  AND btrim(coalesce(category, '')) <> ''
GROUP BY 1
HAVING count(*) >= 200
ORDER BY pct DESC, zips_delivered DESC
LIMIT 40;

\echo ''
\echo '=== 5 of 5: the ZIPs these categories reach that NOTHING else delivers ==='
\echo '    A category that only delivers ZIPs other sources already cover adds'
\echo '    landmark density, which node_fanout needs, but no new coverage. Both'
\echo '    are worth having and they are different things, so both are counted.'
WITH delivered AS (
    SELECT DISTINCT overture_zip AS zip
    FROM landmarks_usa
    WHERE onpremises AND overture_zip IS NOT NULL
), per_cat AS (
    SELECT category, overture_zip AS zip
    FROM landmarks_usa
    WHERE source = 'osm' AND onpremises AND overture_zip IS NOT NULL
      AND btrim(coalesce(category, '')) <> ''
    GROUP BY 1, 2
), others AS (
    SELECT p.category, count(DISTINCT p.zip) AS zips,
           count(DISTINCT p.zip) FILTER (
               WHERE NOT EXISTS (
                   SELECT 1 FROM landmarks_usa o
                   WHERE o.onpremises
                     AND o.overture_zip = p.zip
                     AND (o.source <> 'osm' OR coalesce(o.category,'') <> p.category)
               )) AS zips_only_this_category
    FROM per_cat p
    GROUP BY 1
)
SELECT category, zips, zips_only_this_category
FROM others
WHERE zips >= 10
ORDER BY zips_only_this_category DESC, zips DESC
LIMIT 40;

\echo ''
\echo '=== done ==='
\timing off
