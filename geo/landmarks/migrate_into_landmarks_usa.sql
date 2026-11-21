-- migrate_into_landmarks_usa.sql - fill landmarks_usa from the three imports.
--
-- =========================================================================
-- STOP. DO NOT RUN THIS FILE. USE migrate_new_sources.sql INSTEAD.
--
-- Added 2026-11-06. This file is safe ONLY on a first migration, when
-- landmarks_usa holds no enrichment worth keeping. That stopped being true
-- long ago and it is now destructive.
--
-- Section 3 opens with
--
--     DELETE FROM landmarks_usa
--     WHERE source IN (SELECT DISTINCT source FROM lm_places_usa);
--
-- which deletes every landmarks_usa row belonging to ANY source present in the
-- staging table and re-inserts it from staging, where there is no enrichment,
-- because the chain runs on landmarks_usa and not on lm_places_usa.
--
-- Measured cost as of 2026-11-06, from the institution_ledger run:
--
--     source        rows         rdap_ok      onpremises true
--     osm           1,139,855      986,630              8,735
--     wikidata         24,721       21,951                876
--     dotgov           14,149       10,248                 51
--     ca_cde            8,816        8,322                 54
--     nces_ipeds        6,075        5,593                328
--     TOTAL         1,193,616    1,032,744             10,044
--
-- Over a million completed RDAP lookups and 10,044 on-premises determinations,
-- destroyed with no prompt. migrate_ca_cde.sql was written to avoid exactly
-- this and its header documents the same trap.
--
-- Use geo/landmarks/migrate_new_sources.sql. It is insert-only, has no DELETE,
-- UPDATE or TRUNCATE, uses ON CONFLICT DO NOTHING so existing enrichment can
-- never be overwritten, needs no list of source names, and is safe to re-run.
--
-- Scoping the DELETE here is the real fix. It is a separate change with its own
-- blast radius and has not been made.
-- =========================================================================
--
-- NOTHING IS DROPPED OR ALTERED in the SOURCE tables. ovt_places_usa,
-- fsq_places_usa and lm_places_usa are read only. They remain the raw imports
-- and can be re-migrated at any time by re-running this file, which replaces
-- each source's rows in landmarks_usa rather than appending to them. That
-- replacement is the hazard described above.
--
-- ONLY ROWS WITH A WEBSITE ARE MIGRATED. A place with no website can never
-- become a landmark: the chain has nothing to resolve, so it gets
-- lookup_status 'no_website' and stops. Carrying roughly 11 million such rows
-- into the operational table would cost storage and scan time for rows that
-- are permanently ineligible. They stay in ovt_places_usa, which is where the
-- full Overture import belongs.
--
-- ENRICHMENT ALREADY DONE IS CARRIED OVER, not recomputed. ovt_places_usa holds
-- 543,336 distinct IPs worth of completed RDAP lookups, which took about 20
-- hours. ip_address, registrants, url_location, overture_zip and onpremises all
-- come across, so the chain picks up where it left off instead of starting
-- again.

-- ---------------------------------------------------------------------------
-- 1. OVERTURE
--
-- websites holds a JSON array AS TEXT, for example ["https://a.com"], so the
-- first quoted string is extracted. A value that is not an array is used as-is,
-- which is the same precedence the resolve step applies.
-- ---------------------------------------------------------------------------

DELETE FROM landmarks_usa WHERE source = 'overture';

INSERT INTO landmarks_usa
    (source, source_id, source_release, name, address, locality, region,
     postcode, country, website, category, source_attrs, websites, addresses,
     ip_address, ip_last_carrier_node, ip_address_range,
     ip_last_carrier_node_range, url_location, onpremises, url_location_zip,
     lookup_status, registrant_1, registrant_1_zip, registrant_2,
     registrant_2_zip, overture_zip, overture_zip_source, onpremises_reason)
SELECT 'overture',
       p.id,
       'overture',
       substring(p.names from '"primary"\s*:\s*"([^"]*)"'),
       substring(p.addresses from '"freeform"\s*:\s*"([^"]*)"'),
       substring(p.addresses from '"locality"\s*:\s*"([^"]*)"'),
       upper(substring(p.addresses from '"region"\s*:\s*"([^"]*)"')),
       substring(p.addresses from '"postcode"\s*:\s*"([0-9]{5})'),
       'US',
       btrim(coalesce(substring(p.websites from '"([^"]*)"'), p.websites)),
       p.basic_category,
       jsonb_strip_nulls(jsonb_build_object(
           'confidence',       p.confidence,
           'brand',            p.brand,
           'operating_status', p.operating_status,
           'taxonomy',         p.taxonomy,
           'version',          p.version,
           'emails',           p.emails,
           'socials',          p.socials,
           'phones',           p.phones,
           'sources',          p.sources)),
       btrim(coalesce(substring(p.websites from '"([^"]*)"'), p.websites)),
       p.addresses,
       p.ip_address, p.ip_last_carrier_node, p.ip_address_range,
       p.ip_last_carrier_node_range, p.url_location, p.onpremises,
       p.url_location_zip, p.lookup_status, p.registrant_1, p.registrant_1_zip,
       p.registrant_2, p.registrant_2_zip, p.overture_zip,
       p.overture_zip_source,
       CASE WHEN p.onpremises IS NOT NULL
            THEN 'migrated from ovt_places_usa' END
FROM ovt_places_usa p
WHERE p.websites IS NOT NULL
  AND btrim(p.websites) <> ''
  AND btrim(coalesce(substring(p.websites from '"([^"]*)"'), p.websites)) <> ''
ON CONFLICT (source, source_id) WHERE source_id IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 2. FOURSQUARE
-- ---------------------------------------------------------------------------

DELETE FROM landmarks_usa WHERE source = 'foursquare';

INSERT INTO landmarks_usa
    (source, source_id, source_release, name, address, locality, region,
     postcode, country, website, latitude, longitude, category, source_attrs,
     websites, addresses, ip_address, ip_last_carrier_node, ip_address_range,
     ip_last_carrier_node_range, url_location, onpremises, url_location_zip,
     lookup_status, registrant_1, registrant_1_zip, registrant_2,
     registrant_2_zip, overture_zip, overture_zip_source, onpremises_reason)
SELECT 'foursquare',
       f.fsq_place_id,
       f.dt,
       f.name, f.address, f.locality, upper(f.region),
       substring(btrim(f.postcode) from '([0-9]{5})'),
       'US',
       f.website, f.latitude, f.longitude,
       substring(f.fsq_category_labels from '"([^"]*)"'),
       jsonb_strip_nulls(jsonb_build_object(
           'tel',                 f.tel,
           'email',               f.email,
           'facebook_id',         f.facebook_id,
           'instagram',           f.instagram,
           'twitter',             f.twitter,
           'fsq_category_ids',    f.fsq_category_ids,
           'fsq_category_labels', f.fsq_category_labels,
           'date_created',        f.date_created,
           'date_refreshed',      f.date_refreshed,
           'date_closed',         f.date_closed,
           'admin_region',        f.admin_region,
           'post_town',           f.post_town,
           'po_box',              f.po_box)),
       f.websites, f.addresses,
       f.ip_address, f.ip_last_carrier_node, f.ip_address_range,
       f.ip_last_carrier_node_range, f.url_location, f.onpremises,
       f.url_location_zip, f.lookup_status, f.registrant_1, f.registrant_1_zip,
       f.registrant_2, f.registrant_2_zip, f.overture_zip,
       f.overture_zip_source,
       CASE WHEN f.onpremises IS NOT NULL
            THEN 'migrated from fsq_places_usa' END
FROM fsq_places_usa f
WHERE f.websites IS NOT NULL AND btrim(f.websites) <> ''
ON CONFLICT (source, source_id) WHERE source_id IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. THE SMALLER SOURCES. lm_places_usa already carries its own source column
-- (osm, nces_ipeds, wikidata, nps), which is preserved rather than flattened.
-- ---------------------------------------------------------------------------

DELETE FROM landmarks_usa
WHERE source IN (SELECT DISTINCT source FROM lm_places_usa);

INSERT INTO landmarks_usa
    (source, source_id, source_release, name, address, locality, region,
     postcode, country, website, latitude, longitude, category,
     websites, addresses, ip_address, ip_last_carrier_node, ip_address_range,
     ip_last_carrier_node_range, url_location, onpremises, url_location_zip,
     lookup_status, registrant_1, registrant_1_zip, registrant_2,
     registrant_2_zip, overture_zip, overture_zip_source, onpremises_reason)
SELECT l.source, l.source_id, l.source_release,
       l.name, l.address, l.locality, l.region, l.postcode, l.country,
       l.website, l.latitude, l.longitude, l.category,
       l.websites, l.addresses,
       l.ip_address, l.ip_last_carrier_node, l.ip_address_range,
       l.ip_last_carrier_node_range, l.url_location, l.onpremises,
       l.url_location_zip, l.lookup_status, l.registrant_1, l.registrant_1_zip,
       l.registrant_2, l.registrant_2_zip, l.overture_zip,
       l.overture_zip_source,
       CASE WHEN l.onpremises IS NOT NULL
            THEN 'migrated from lm_places_usa' END
FROM lm_places_usa l
WHERE l.websites IS NOT NULL AND btrim(l.websites) <> ''
ON CONFLICT (source, source_id) WHERE source_id IS NOT NULL DO NOTHING;


ANALYZE landmarks_usa;


-- ---------------------------------------------------------------------------
-- VERIFY. Row counts per source, and how much enrichment came across.
-- ---------------------------------------------------------------------------

SELECT '=== rows migrated per source ===' AS section;

SELECT source,
       count(*)                                                   AS rows,
       count(DISTINCT lower(btrim(website)))                      AS distinct_hosts,
       count(*) FILTER (WHERE ip_address IS NOT NULL)             AS have_ip,
       count(*) FILTER (WHERE lookup_status = 'true')             AS rdap_done,
       count(*) FILTER (WHERE onpremises IS TRUE)                  AS onpremises_true,
       count(*) FILTER (WHERE overture_zip ~ '^[0-9]{5}$')         AS have_zip
FROM landmarks_usa
GROUP BY 1
ORDER BY 2 DESC;

SELECT '=== nothing lost: source rows WITH a website vs rows migrated ===' AS section;

SELECT 'overture' AS source,
       (SELECT count(*) FROM ovt_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''
          AND btrim(coalesce(substring(websites from '"([^"]*)"'), websites)) <> '')
                                                                   AS eligible_in_source,
       (SELECT count(*) FROM landmarks_usa WHERE source = 'overture')
                                                                   AS migrated
UNION ALL
SELECT 'foursquare',
       (SELECT count(*) FROM fsq_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''),
       (SELECT count(*) FROM landmarks_usa WHERE source = 'foursquare')
UNION ALL
SELECT 'lm_places_usa (all)',
       (SELECT count(*) FROM lm_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''),
       (SELECT count(*) FROM landmarks_usa
        WHERE source IN (SELECT DISTINCT source FROM lm_places_usa));
