-- ingest_status.sql - where every landmark source stands, in one page.
--
-- Answers four questions per source, in the order they gate each other:
--   loaded      is the raw import present
--   in table    did it reach landmarks_usa
--   resolved    does it have an IP yet
--   on premises has the onpremises verdict been computed
--
-- A source can be fully loaded and still contribute nothing, because the chain
-- has not run on it. onpremises_true = 0 against a large row count means
-- loaded but not yet enriched, NOT a bad source.

SELECT '=== 1. RAW IMPORTS: is the source loaded at all ===' AS section;

SELECT 'overture'    AS source,
       (SELECT count(*) FROM ovt_places_usa)                            AS rows_total,
       (SELECT count(*) FROM ovt_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> '')           AS with_website,
       (SELECT count(*) FROM ovt_places_usa WHERE onpremises IS TRUE)   AS onpremises_true
UNION ALL
SELECT 'foursquare',
       (SELECT count(*) FROM fsq_places_usa),
       (SELECT count(*) FROM fsq_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''),
       (SELECT count(*) FROM fsq_places_usa WHERE onpremises IS TRUE)
UNION ALL
SELECT 'lm_places_usa (osm + ipeds + wikidata)',
       (SELECT count(*) FROM lm_places_usa),
       (SELECT count(*) FROM lm_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''),
       (SELECT count(*) FROM lm_places_usa WHERE onpremises IS TRUE);


SELECT '=== 1b. lm_places_usa broken out per source ===' AS section;

SELECT source,
       count(*)                                                   AS rows,
       count(DISTINCT lower(btrim(website)))                      AS distinct_hosts,
       round(100.0 * count(DISTINCT lower(btrim(website)))
             / nullif(count(*), 0), 1)                            AS pct_unique_hosts,
       count(DISTINCT postcode) FILTER (WHERE postcode ~ '^[0-9]{5}$') AS distinct_zips,
       count(DISTINCT region)                                     AS states_covered
FROM lm_places_usa
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 2. UNIFIED TABLE: has the migration been run ===' AS section;

SELECT CASE WHEN (SELECT count(*) FROM landmarks_usa) = 0
            THEN 'EMPTY - run migrate_into_landmarks_usa.sql'
            ELSE 'populated' END                                  AS landmarks_usa_state,
       (SELECT count(*) FROM landmarks_usa)                        AS rows;

SELECT source,
       count(*)                                                   AS rows,
       count(*) FILTER (WHERE ip_address IS NOT NULL)              AS resolved,
       count(*) FILTER (WHERE lookup_status = 'true')              AS rdap_done,
       count(*) FILTER (WHERE overture_zip ~ '^[0-9]{5}$')         AS have_zip,
       count(*) FILTER (WHERE onpremises IS TRUE)                   AS onpremises_true,
       count(*) FILTER (WHERE onpremises IS FALSE)                  AS onpremises_false,
       count(*) FILTER (WHERE onpremises IS NULL)                   AS onpremises_null
FROM landmarks_usa
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 3. THE CHAIN: next step needed per source ===' AS section;

SELECT source,
       count(*)                                                       AS rows,
       CASE WHEN count(*) FILTER (WHERE ip_address IS NOT NULL) = 0
                 THEN 'run: resolve'
            WHEN count(*) FILTER (WHERE lookup_status = 'true') = 0
                 THEN 'run: rdap'
            WHEN count(*) FILTER (WHERE registrant_1 IS NOT NULL) = 0
                 THEN 'run: registrants'
            WHEN count(*) FILTER (WHERE overture_zip IS NOT NULL) = 0
                 THEN 'run: overture-zip'
            WHEN count(*) FILTER (WHERE onpremises IS NOT NULL) = 0
                 THEN 'run: onpremises'
            ELSE 'chain complete' END                                 AS next_step
FROM landmarks_usa
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 4. ZIP COVERAGE, the point of the whole exercise ===' AS section;

SELECT count(DISTINCT overture_zip)                                   AS zips_with_onprem_landmark,
       44000                                                          AS inhabited_zips_approx,
       round(100.0 * count(DISTINCT overture_zip) / 44000.0, 1)        AS pct_covered
FROM landmarks_usa
WHERE onpremises IS TRUE AND overture_zip ~ '^[0-9]{5}$';


SELECT '=== 4b. ZIPs each source contributes that NO other source covers ===' AS section;

WITH z AS (
    SELECT DISTINCT source, overture_zip AS zip
    FROM landmarks_usa
    WHERE onpremises IS TRUE AND overture_zip ~ '^[0-9]{5}$'
)
SELECT a.source,
       count(*)                                                       AS zips,
       count(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM z b WHERE b.zip = a.zip AND b.source <> a.source))
                                                                      AS zips_unique_to_source
FROM z a
GROUP BY 1
ORDER BY 3 DESC;
