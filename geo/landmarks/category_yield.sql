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
\echo 'Timing, measured on the 2026-11-03 run rather than estimated. Sections 1'
\echo 'to 4 took 6 to 9 seconds each. Section 5 is rewritten: its first version'
\echo 'hung, and the note that replaced this one claimed it would be fast, which'
\echo 'was wrong. It now runs as four short statements over the on-premises rows'
\echo 'only, about 132,000 of them, and each prints as it finishes.'
\echo ''
\echo 'This file is READ-ONLY apart from two TEMP tables in section 5, which are'
\echo 'dropped at the end and are private to this session. It is therefore safe'
\echo 'to interrupt with Ctrl-C at any point, and safe to run at the same time'
\echo 'as rdap_fill_followup.sql, which is read-only throughout. The only cost'
\echo 'of running both at once is that they compete for CPU and disk.'

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
\echo ''
\echo '    REWRITTEN 2026-11-03 because the first version hung. It put a'
\echo '    correlated NOT EXISTS inside an aggregate FILTER, which the planner'
\echo '    evaluated per category-and-ZIP pair against the full 15.2M-row table'
\echo '    instead of using the partial index. My claim that it would be fast'
\echo '    was wrong, and worse, psql cannot report progress INSIDE a single'
\echo '    statement, so there was no way to see it was stuck. The obligation'
\echo '    is therefore to keep every statement short, not to promise progress.'
\echo ''
\echo '    This version makes one pass over the on-premises rows only, roughly'
\echo '    132,000 of them, and counts contributors per ZIP once. Seconds.'

\echo '    5a: one pass, materialising the on-premises rows'
CREATE TEMP TABLE cat_onprem AS
SELECT overture_zip                                        AS zip,
       source,
       coalesce(nullif(btrim(category), ''), '(none)')      AS cat
FROM landmarks_usa
WHERE onpremises
  AND overture_zip IS NOT NULL;

SELECT count(*) AS onpremises_rows, count(DISTINCT zip) AS zips
FROM cat_onprem;

\echo '    5b: how many distinct source-and-category pairs deliver each ZIP'
CREATE TEMP TABLE cat_zip_contrib AS
SELECT zip, count(DISTINCT (source, cat)) AS contributors
FROM cat_onprem
GROUP BY 1;

CREATE INDEX ON cat_zip_contrib (zip);
ANALYZE cat_zip_contrib;

SELECT contributors, count(*) AS zips
FROM cat_zip_contrib
GROUP BY 1
ORDER BY 1
LIMIT 15;

\echo ''
\echo '    5c: per OSM category, ZIPs delivered and ZIPs it alone delivers'
SELECT c.cat                                              AS category,
       count(*)                                           AS zips,
       count(*) FILTER (WHERE z.contributors = 1)         AS zips_only_this_category
FROM (SELECT DISTINCT cat, zip FROM cat_onprem WHERE source = 'osm') c
JOIN cat_zip_contrib z ON z.zip = c.zip
GROUP BY 1
HAVING count(*) >= 10
ORDER BY zips_only_this_category DESC, zips DESC
LIMIT 40;

\echo ''
\echo '    5d: and the same per SOURCE, which is the more useful cut'
SELECT c.source,
       count(*)                                     AS zips,
       count(*) FILTER (WHERE z.contributors = 1)   AS zips_only_this_source
FROM (SELECT DISTINCT source, zip FROM cat_onprem) c
JOIN cat_zip_contrib z ON z.zip = c.zip
GROUP BY 1
ORDER BY zips_only_this_source DESC;

DROP TABLE IF EXISTS cat_zip_contrib;
DROP TABLE IF EXISTS cat_onprem;

\echo ''
\echo '=== done ==='
\timing off
