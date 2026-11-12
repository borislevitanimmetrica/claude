-- institution_ledger.sql
--
-- The funnel, by landmark category: how many records exist, how many were
-- accepted into landmarks_usa, and how many reached onpremises = true.
--
-- FOUR STAGES, AND THEY MEAN DIFFERENT THINGS
--
--   1. source file rows     what the authoritative file contains. NOT in any
--                           table, because every loader drops rows with no
--                           usable website before loading. Section 3 supplies
--                           it from the loaders' own row accounting, and says
--                           which categories have no knowable figure at all
--   2. staging rows         lm_places_usa, so rows that survived the loader
--   3. accepted rows        landmarks_usa, after migrate_new_sources.sql,
--                           which additionally requires a non-null source_id
--   4. onpremises = true    the landmarks
--
-- A category showing accepted rows but zero onpremises has not been through
-- the chain yet. As of 2026-11-06 that is every school source except ca_cde,
-- plus usfa_fire: 121,760 rows awaiting resolve.
--
-- WHY THE CLASS IS DERIVED, AND WHY category ALONE WILL NOT DO
--
-- The category column is not comparable across loaders:
--
--   state_loader, so ccd and all 20 state files   writes 'public school'
--   lm_fetch ca-cde                               writes SOCType or EILName,
--                                                 so 'High Schools (Public)'
--                                                 and about a dozen others
--   lm_fetch usfa-fire                            writes the USFA Dept Type,
--                                                 so 'volunteer', 'career',
--                                                 'combination' and so on
--   lm_fetch nces-ipeds                           writes 'college'
--   lm_fetch osm                                  writes the raw OSM amenity
--
-- Grouping on category would therefore split fire departments three ways,
-- scatter California across a dozen buckets, and merge nothing useful. The
-- class below is derived from source first and category second, in one place,
-- and the 'public school' test is what makes a newly added state file fall
-- into the right bucket with no edit here.
--
-- READ-ONLY. Two TEMP tables, dropped at the end, private to this session.

\timing on
\set ON_ERROR_STOP on
SET work_mem = '512MB';

\echo ''
\echo 'Timing: section 1 scans lm_places_usa, about 1.3M rows, seconds.'
\echo 'Section 2 scans landmarks_usa, about 15.4M rows, under a minute.'
\echo 'Sections 3 and 4 are instant.'

\echo ''
\echo '=== 1 of 4: staging, lm_places_usa ==='

CREATE TEMP TABLE led_stage AS
SELECT CASE
         WHEN p.source = 'ca_cde'                           THEN 'school, public'
         WHEN p.source = 'usfa_fire'                        THEN 'fire station'
         WHEN p.source = 'nces_ipeds'                       THEN 'college or university'
         WHEN p.source = 'dotgov'                           THEN 'government, municipal domain'
         WHEN p.source = 'wikidata'                         THEN 'wikidata, mixed'
         WHEN p.source = 'overture'                         THEN 'overture, mixed'
         WHEN p.source = 'foursquare'                       THEN 'foursquare, mixed'
         WHEN p.category = 'public school'                  THEN 'school, public'
         WHEN p.source = 'osm' AND p.category = 'school'            THEN 'school, OSM tagged'
         WHEN p.source = 'osm' AND p.category = 'fire_station'      THEN 'fire station'
         WHEN p.source = 'osm' AND p.category IN ('university', 'college')
                                                                    THEN 'college or university'
         WHEN p.source = 'osm' AND p.category = 'library'           THEN 'library'
         WHEN p.source = 'osm' AND p.category = 'police'            THEN 'police'
         WHEN p.source = 'osm' AND p.category = 'hospital'          THEN 'hospital'
         WHEN p.source = 'osm' AND p.category = 'clinic'            THEN 'clinic'
         WHEN p.source = 'osm' AND p.category IN ('government', 'townhall')
                                                                    THEN 'government, OSM tagged'
         WHEN p.source = 'osm' AND p.category = 'telecommunication' THEN 'telecommunication'
         WHEN p.source = 'osm' AND p.category = 'place_of_worship'  THEN 'place of worship'
         WHEN p.source = 'osm' AND p.category IN ('courthouse', 'prison')
                                                                    THEN 'courthouse or prison'
         WHEN p.source = 'osm' AND p.category IN ('research', 'research_institute')
                                                                    THEN 'research'
         WHEN p.source = 'osm'                                      THEN 'osm, other'
         ELSE p.source
       END                                                           AS class,
       left(lpad(btrim(coalesce(p.postcode, '')), 5, '0'), 5)        AS zip5,
       lower(btrim(coalesce(p.website, '')))                         AS host_text,
       btrim(coalesce(p.postcode, '')) ~ '^[0-9]{5}'                 AS has_zip,
       p.source_id IS NOT NULL                                       AS has_id
FROM lm_places_usa p;

CREATE INDEX ON led_stage (class);
ANALYZE led_stage;

SELECT class,
       count(*)                                     AS staging_rows,
       count(*) FILTER (WHERE has_zip)              AS with_zip,
       count(*) FILTER (WHERE has_id)               AS with_source_id,
       count(DISTINCT host_text)                    AS distinct_hosts,
       count(DISTINCT zip5) FILTER (WHERE has_zip)  AS distinct_zips
FROM led_stage
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 2 of 4: THE ANSWER. accepted in landmarks_usa, and onpremises ==='

CREATE TEMP TABLE led_enriched AS
SELECT CASE
         WHEN t.source = 'ca_cde'                           THEN 'school, public'
         WHEN t.source = 'usfa_fire'                        THEN 'fire station'
         WHEN t.source = 'nces_ipeds'                       THEN 'college or university'
         WHEN t.source = 'dotgov'                           THEN 'government, municipal domain'
         WHEN t.source = 'wikidata'                         THEN 'wikidata, mixed'
         WHEN t.source = 'overture'                         THEN 'overture, mixed'
         WHEN t.source = 'foursquare'                       THEN 'foursquare, mixed'
         WHEN t.category = 'public school'                  THEN 'school, public'
         WHEN t.source = 'osm' AND t.category = 'school'            THEN 'school, OSM tagged'
         WHEN t.source = 'osm' AND t.category = 'fire_station'      THEN 'fire station'
         WHEN t.source = 'osm' AND t.category IN ('university', 'college')
                                                                    THEN 'college or university'
         WHEN t.source = 'osm' AND t.category = 'library'           THEN 'library'
         WHEN t.source = 'osm' AND t.category = 'police'            THEN 'police'
         WHEN t.source = 'osm' AND t.category = 'hospital'          THEN 'hospital'
         WHEN t.source = 'osm' AND t.category = 'clinic'            THEN 'clinic'
         WHEN t.source = 'osm' AND t.category IN ('government', 'townhall')
                                                                    THEN 'government, OSM tagged'
         WHEN t.source = 'osm' AND t.category = 'telecommunication' THEN 'telecommunication'
         WHEN t.source = 'osm' AND t.category = 'place_of_worship'  THEN 'place of worship'
         WHEN t.source = 'osm' AND t.category IN ('courthouse', 'prison')
                                                                    THEN 'courthouse or prison'
         WHEN t.source = 'osm' AND t.category IN ('research', 'research_institute')
                                                                    THEN 'research'
         WHEN t.source = 'osm'                                      THEN 'osm, other'
         ELSE t.source
       END                                                   AS class,
       t.ip_address,
       t.overture_zip,
       t.lookup_status,
       t.onpremises,
       t.onpremises_reason
FROM landmarks_usa t;

CREATE INDEX ON led_enriched (class);
ANALYZE led_enriched;

SELECT e.class,
       coalesce(s.staging_rows, 0)                                AS total_records,
       count(*)                                                   AS accepted,
       count(*) FILTER (WHERE e.lookup_status = 'true')            AS rdap_ok,
       count(*) FILTER (WHERE e.onpremises)                        AS onpremises_true,
       round(100.0 * count(*) FILTER (WHERE e.onpremises)
             / greatest(count(*), 1), 2)                          AS pct,
       count(DISTINCT e.overture_zip) FILTER (WHERE e.onpremises)  AS zips_delivered,
       count(DISTINCT e.ip_address)   FILTER (WHERE e.onpremises)  AS addresses_delivered,
       count(*) FILTER (WHERE e.lookup_status IS NULL)             AS awaiting_chain
FROM led_enriched e
LEFT JOIN (SELECT class, count(*) AS staging_rows FROM led_stage GROUP BY 1) s
       ON s.class = e.class
GROUP BY e.class, s.staging_rows
ORDER BY onpremises_true DESC;

\echo ''
\echo '--- totals across every class ---'
SELECT (SELECT count(*) FROM led_stage)                             AS staging_total,
       count(*)                                                     AS accepted_total,
       count(*) FILTER (WHERE lookup_status = 'true')                AS rdap_ok_total,
       count(*) FILTER (WHERE onpremises)                            AS onpremises_total,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises)        AS zips_delivered,
       count(*) FILTER (WHERE lookup_status IS NULL)                 AS awaiting_chain,
       count(*) FILTER (WHERE onpremises_reason LIKE 'hosting:%')    AS hosting_rule_rows
FROM led_enriched;

\echo ''
\echo '=== 3 of 4: the SOURCE FILE totals, which no table holds ==='
\echo '    Every loader drops rows with no usable website before loading, so'
\echo '    staging can never show them. These come from the loaders own row'
\echo '    accounting, measured 2026-11-06.'

SELECT * FROM (VALUES
  ('school, public',                'NCES CCD 2023-24',        102274, 99631,  67438, 'source file, and CCD is the census of public schools'),
  ('school, public',                '20 state directories',     91966,  NULL,  45637, 'source files, OVERLAPPING with CCD, so not additive'),
  ('school, public',                'lm_fetch ca-cde',           NULL,  NULL,   8816, 'needs a local file, pre-filter total not measured'),
  ('fire station',                  'USFA national registry',   27117, 27117,   8685, 'source file, about 92 pct of the estimated 29,452'),
  ('college or university',         'NCES IPEDS',                NULL,  NULL,   6075, 'pre-filter total not measured; universe about 5,629'),
  ('government, municipal domain',  'CISA .gov registry',        17025, 15706,  14149, 'source file, local government is the 15,706'),
  ('library',                       'OSM only',                  NULL,  NULL,  14264, 'NOT KNOWABLE: Overpass required a website tag'),
  ('police',                        'OSM only',                  NULL,  NULL,   2519, 'NOT KNOWABLE: same. Universe about 11,824'),
  ('hospital',                      'OSM only',                  NULL,  NULL,  12222, 'NOT KNOWABLE: same'),
  ('telecommunication',             'OSM only',                  NULL,  NULL,    595, 'NOT KNOWABLE: same'),
  ('place of worship',              'OSM only',                  NULL,  NULL,  47280, 'NOT KNOWABLE: same'),
  ('overture, mixed',               'Overture places',           NULL,  NULL,13797786, 'pre-filter total is in ovt_places_usa, not measured here'),
  ('foursquare, mixed',             'Foursquare OS Places',      NULL,  NULL, 275517, 'pre-filter total is in fsq_places_usa, not measured here')
) AS t(class, source_file, file_rows, file_rows_eligible, loaded, basis);

\echo ''
\echo '=== 4 of 4: the school universe, de-duplicated ==='
\echo '    The 194,240 rows read across 21 files OVERLAP: a Texas school is in'
\echo '    both CCD and tx_askted. CCD is the census, so the denominator for'
\echo '    public schools is its 99,631 open schools, and the state files exist'
\echo '    to supply websites for the 32,003 CCD leaves blank.'
\echo ''
\echo '    Against Boris figure of 129,000 to 133,000 K-12 schools:'
\echo '      public, CCD census                  99,631'
\echo '      private, NCES PSS, no URL anywhere  22,510'
\echo '      the rest is the gap between those and the 129,000'

SELECT count(DISTINCT left(lpad(btrim(postcode), 5, '0'), 5))  AS distinct_zips_all_school_sources,
       count(DISTINCT lower(btrim(website)))                   AS distinct_hosts_all_school_sources,
       count(*)                                                AS rows_all_school_sources
FROM lm_places_usa
WHERE category = 'public school' OR source = 'ca_cde';

DROP TABLE IF EXISTS led_enriched;
DROP TABLE IF EXISTS led_stage;

\echo ''
\echo '=== done ==='
\timing off
