-- migrate_ca_cde.sql
--
-- Copy the California CDE public-school rows from lm_places_usa into
-- landmarks_usa. Insert only. Deletes nothing.
--
-- WHY THIS FILE EXISTS INSTEAD OF RUNNING migrate_into_landmarks_usa.sql
--
-- That script's section 3 begins:
--
--     DELETE FROM landmarks_usa
--     WHERE source IN (SELECT DISTINCT source FROM lm_places_usa);
--
-- which removes EVERY landmarks_usa row belonging to any source present in
-- lm_places_usa -- osm, wikidata, dotgov, nces_ipeds, nps -- and then
-- re-inserts them from lm_places_usa, carrying lm_places_usa's enrichment
-- columns.
--
-- The enrichment chain does not run there. resolve, rdap, registrants,
-- overture-zip and onpremises all operate on landmarks_usa (the chain is
-- invoked with --table landmarks_usa). So lm_places_usa holds little or no
-- enrichment for those rows, and the re-insert would replace populated
-- ip_address, url_location, lookup_status, registrant_1, registrant_1_zip,
-- registrant_2, registrant_2_zip, overture_zip and onpremises values with
-- empty ones.
--
-- WHAT THAT WOULD COST, counted rather than estimated: 1,139,855 osm rows,
-- 24,721 wikidata, 14,149 dotgov and 6,075 nces_ipeds, about 1.18 million rows
-- whose RDAP results would have to be fetched again. The original national
-- RDAP pass took roughly ten hours before the native client; even at the
-- current 14 addresses a second it is hours of work to recover something that
-- is already correct on disk.
--
-- The script was written when those sources were being migrated for the first
-- time, where delete-then-insert is harmless because there is nothing to lose.
-- It is no longer harmless, and adding a new source must not trigger it. That
-- is a defect in the shared script rather than something to work around
-- forever, but fixing it is a separate change with its own blast radius, so
-- this file does the narrow thing safely in the meantime.
--
-- SAFETY PROPERTIES OF THIS FILE
--
--   * no DELETE, no UPDATE, no TRUNCATE
--   * scoped to source = 'ca_cde' and touches no other source
--   * ON CONFLICT DO NOTHING, so re-running adds only what is missing and
--     never overwrites enrichment already computed for a school
--   * loads only the 15 descriptive columns; every enrichment column is left
--     NULL for the chain to fill
--
-- The websites filter matches the shared script: a row with no website cannot
-- resolve to an address and so can never become a landmark.

-- WHY THIS FILE REPORTS TIMINGS AND REFUSES TO WAIT FOR LOCKS
--
-- A load of this data ran for 45 minutes with no output and looked hung. Two
-- causes, both removable. psql printed nothing because no statement reported
-- its duration, and a writer waiting on a lock waits for ever by default. A
-- psql session left at a pager prompt inside a transaction holds its locks,
-- and the next writer queues behind it silently.
--
-- \timing on makes every statement announce how long it took. lock_timeout
-- makes a blocked statement fail in 30 seconds with a clear error instead of
-- hanging. Neither limits how long legitimate work may run: statement_timeout
-- is deliberately NOT set, because a large insert is allowed to be slow.

\timing on
SET lock_timeout = '30s';

\echo '=== ca_cde rows available in lm_places_usa ==='
SELECT count(*) AS total,
       count(*) FILTER (WHERE websites IS NOT NULL AND btrim(websites) <> '') AS with_website,
       count(DISTINCT left(lpad(btrim(postcode), 5, '0'), 5))                 AS distinct_zips
FROM lm_places_usa
WHERE source = 'ca_cde';

\echo '=== ca_cde rows already in landmarks_usa, before ==='
SELECT count(*) AS before_rows FROM landmarks_usa WHERE source = 'ca_cde';

INSERT INTO landmarks_usa
    (source, source_id, source_release, name, address, locality, region,
     postcode, country, website, latitude, longitude, category,
     websites, addresses)
SELECT l.source, l.source_id, l.source_release,
       l.name, l.address, l.locality, l.region, l.postcode, l.country,
       l.website, l.latitude, l.longitude, l.category,
       l.websites, l.addresses
FROM lm_places_usa l
WHERE l.source = 'ca_cde'
  AND l.websites IS NOT NULL
  AND btrim(l.websites) <> ''
ON CONFLICT (source, source_id) WHERE source_id IS NOT NULL DO NOTHING;

-- No ANALYZE here, deliberately. ANALYZE on landmarks_usa reads a sample of a
-- 15.2-million-row table, and adding roughly 8,800 rows to it does not shift
-- the planner's statistics enough to matter. The chain's own steps ANALYZE when
-- they need to. Running it here only lengthens a step whose purpose is to
-- insert a few thousand rows and report what happened.

\echo '=== ca_cde rows in landmarks_usa, after ==='
SELECT count(*)                                                   AS after_rows,
       count(*) FILTER (WHERE lookup_status IS NULL)               AS awaiting_rdap,
       count(DISTINCT left(lpad(btrim(postcode), 5, '0'), 5))      AS distinct_zips,
       count(DISTINCT lower(btrim(website)))                       AS distinct_websites
FROM landmarks_usa
WHERE source = 'ca_cde';

-- The per-source comparison that used to sit here has been removed from this
-- file. It was
--
--     SELECT source, count(*), count(*) FILTER (WHERE lookup_status IS NOT NULL),
--            count(*) FILTER (WHERE onpremises)
--     FROM landmarks_usa GROUP BY source;
--
-- which is a sequential scan of every one of the 15.2 million rows, attached to
-- a step that otherwise touches a few thousand. Reassurance that other sources
-- were untouched does not need to be bought at that price on every run, and it
-- made this script look like the slow part when it was not.
--
-- Run it separately when you actually want it. It is in
-- geo/landmarks/landmarks_per_source.sql.
