-- institution_ledger.sql
--
-- Per institution class: how many records exist, how many carry a website and a
-- ZIP, and how many reached onpremises = true.
--
-- READ THIS BEFORE READING THE NUMBERS, because one column cannot be produced
-- from the database at all.
--
-- "RECORDS WITHOUT THE WEBSITE FIELD" IS NOT IN ANY TABLE. Every loader drops
-- rows with no usable website BEFORE loading, by design, because a row with no
-- hostname cannot anchor a landmark. So in lm_places_usa the count without a
-- website is zero for every source, and that zero is an artefact of the loader,
-- not a fact about the world. The OSM source is worse: its Overpass query is
--
--     nwr["website"]["addr:postcode"](area.a);
--
-- so rows without a website were never FETCHED, and no query against this
-- database can recover how many there are.
--
-- The honest denominators therefore come from the source files' own row
-- accounting, which the loaders print and which is recorded in
-- institution_ledger.md beside this file. Sections 1 to 3 below report what the
-- database does know; section 4 states plainly which classes have a real
-- denominator and which do not.
--
-- WHY THE CLASS IS DERIVED AND NOT READ FROM category. The category column is
-- not comparable across sources. state_loader writes the literal 'public
-- school' for CCD and every state file. lm_fetch usfa-fire writes the USFA
-- Dept Type, so fire departments arrive as 'volunteer', 'career', 'combination'
-- and similar rather than one value. OSM carries the raw amenity tag. Grouping
-- on category alone would therefore split fire stations across several rows and
-- merge nothing usefully, so the class is derived from (source, category) in
-- one place below.
--
-- READ-ONLY. One TEMP table, dropped at the end, private to this session.

\timing on
\set ON_ERROR_STOP on
SET work_mem = '512MB';

\echo ''
\echo 'Timing: section 1 scans lm_places_usa, about 1.3M rows, seconds.'
\echo 'Section 2 scans landmarks_usa, about 15.2M rows, expect under a minute.'
\echo 'Sections 3 and 4 read the temp tables and are instant.'

\echo ''
\echo '=== 1 of 4: staging, lm_places_usa, what has been loaded ==='
\echo '    with_website is 100 pct by construction. It is printed anyway so the'
\echo '    artefact is visible rather than inferred.'

CREATE TEMP TABLE ledger_staging AS
SELECT CASE
         WHEN p.source IN ('ccd', 'ca_cde') THEN 'school, public'
         WHEN p.source = 'usfa_fire'        THEN 'fire station'
         WHEN p.source = 'nces_ipeds'       THEN 'college or university'
         WHEN p.source = 'dotgov'           THEN 'government, municipal domain'
         WHEN p.source = 'wikidata'         THEN 'wikidata, mixed'
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
       p.source,
       btrim(coalesce(p.website, '')) <> ''                          AS has_website,
       btrim(coalesce(p.postcode, '')) ~ '^[0-9]{5}'                 AS has_zip,
       lower(btrim(coalesce(p.website, '')))                         AS host_text,
       left(lpad(btrim(coalesce(p.postcode, '')), 5, '0'), 5)        AS zip5
FROM lm_places_usa p;

CREATE INDEX ON ledger_staging (class);
ANALYZE ledger_staging;

SELECT class,
       count(*)                                        AS records,
       count(*) FILTER (WHERE has_website)             AS with_website,
       count(*) FILTER (WHERE NOT has_website)         AS without_website,
       count(*) FILTER (WHERE has_zip)                 AS with_zip,
       count(*) FILTER (WHERE NOT has_zip)             AS without_zip,
       count(*) FILTER (WHERE has_website AND has_zip) AS with_both,
       count(DISTINCT host_text)                       AS distinct_hosts,
       count(DISTINCT zip5) FILTER (WHERE has_zip)     AS distinct_zips
FROM ledger_staging
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 2 of 4: enriched, landmarks_usa, where onpremises is decided ==='

CREATE TEMP TABLE ledger_enriched AS
SELECT CASE
         WHEN t.source IN ('ccd', 'ca_cde') THEN 'school, public'
         WHEN t.source = 'usfa_fire'        THEN 'fire station'
         WHEN t.source = 'nces_ipeds'       THEN 'college or university'
         WHEN t.source = 'dotgov'           THEN 'government, municipal domain'
         WHEN t.source = 'wikidata'         THEN 'wikidata, mixed'
         WHEN t.source = 'overture'         THEN 'overture, mixed'
         WHEN t.source = 'foursquare'       THEN 'foursquare, mixed'
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
       END                                                           AS class,
       t.ip_address IS NOT NULL                                      AS resolved,
       t.lookup_status = 'true'                                      AS rdap_ok,
       t.overture_zip IS NOT NULL                                    AS has_zip,
       t.onpremises,
       t.overture_zip,
       t.ip_address
FROM landmarks_usa t;

CREATE INDEX ON ledger_enriched (class);
ANALYZE ledger_enriched;

SELECT class,
       count(*)                                                     AS records,
       count(*) FILTER (WHERE resolved)                             AS resolved,
       count(*) FILTER (WHERE rdap_ok)                              AS rdap_ok,
       count(*) FILTER (WHERE has_zip)                              AS have_zip,
       count(*) FILTER (WHERE onpremises)                           AS onpremises_true,
       round(100.0 * count(*) FILTER (WHERE onpremises)
             / greatest(count(*), 1), 2)                            AS pct,
       count(DISTINCT overture_zip) FILTER (WHERE onpremises)       AS zips_delivered,
       count(DISTINCT ip_address)   FILTER (WHERE onpremises)       AS addresses_delivered
FROM ledger_enriched
GROUP BY 1
ORDER BY onpremises_true DESC;

\echo ''
\echo '=== 3 of 4: the two tables side by side, which exposes what is PENDING ==='
\echo '    A class with staging rows and no enriched rows has been loaded but'
\echo '    not yet migrated and enriched. ccd and usfa_fire are in that state'
\echo '    until migrate_into_landmarks_usa.sql and the chain have run.'
SELECT coalesce(s.class, e.class)                  AS class,
       coalesce(s.records, 0)                      AS staging_records,
       coalesce(e.records, 0)                      AS enriched_records,
       coalesce(e.onpremises_true, 0)              AS onpremises_true,
       CASE WHEN coalesce(e.records, 0) = 0 AND coalesce(s.records, 0) > 0
            THEN 'PENDING: loaded, not enriched'
            WHEN coalesce(s.records, 0) = 0
            THEN 'enriched only, no staging source'
            ELSE 'enriched' END                    AS state
FROM (SELECT class, count(*) AS records FROM ledger_staging GROUP BY 1) s
FULL JOIN (SELECT class, count(*) AS records,
                  count(*) FILTER (WHERE onpremises) AS onpremises_true
           FROM ledger_enriched GROUP BY 1) e USING (class)
ORDER BY staging_records DESC, enriched_records DESC;

\echo ''
\echo '=== 4 of 4: which classes have a REAL denominator, and which do not ==='
\echo ''
\echo '    These classes have a true total, because the loader read a complete'
\echo '    authoritative file and printed the accounting:'
\echo ''
\echo '      school, public       CCD 2023-24: 102,274 rows, 99,596 open,'
\echo '                           32,003 with no website, 2,643 not operating,'
\echo '                           190 unusable, 67,438 usable'
\echo '      fire station         USFA registry: 27,117 departments, all with a'
\echo '                           5-digit HQ ZIP, 18,432 with no usable website,'
\echo '                           8,685 usable'
\echo '      college or univ      NCES IPEDS: about 6,000, essentially complete'
\echo '      government           CISA .gov: 17,025 domains, 15,706 local'
\echo ''
\echo '    These classes have NO knowable denominator from this database,'
\echo '    because the OSM Overpass query required a website tag AND a postcode'
\echo '    before fetching anything:'
\echo ''
\echo '      library, police, hospital, clinic, telecommunication,'
\echo '      place of worship, courthouse or prison, research, osm other'
\echo ''
\echo '    For those, the row count is a sample of unknown bias, not a census.'
\echo '    Recovering the denominator means re-querying OSM without the website'
\echo '    filter, which is a different and much larger fetch, or taking the'
\echo '    denominator from an external registry per class.'
\echo ''
\echo '    External counts supplied by Boris, for comparison against section 1:'
\echo '      police departments            11,824'
\echo '      fire departments              29,452'
\echo '      municipalities                19,429'
\echo '      counties                       3,144'
\echo '      colleges and universities      2,609'
\echo '      other degree-granting          3,020'
\echo '      K-12 schools            129,000 to 133,000, almost 100,000 public'

DROP TABLE IF EXISTS ledger_enriched;
DROP TABLE IF EXISTS ledger_staging;

\echo ''
\echo '=== done ==='
\timing off
