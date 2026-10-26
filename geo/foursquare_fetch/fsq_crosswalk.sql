-- fsq_crosswalk.sql - what Foursquare actually ADDS over Overture.
--
-- The reason for importing a second source is a measured shortage: Overture
-- yields 120,154 on-premises places over only 28,324 distinct addresses, and
-- those cover 15,963 ZIPs out of roughly 44,000 inhabited ones. Nearly two
-- thirds of inhabited ZIPs have no landmark at all. The question this file
-- answers is whether Foursquare closes that gap or merely restates it.
--
-- On duplicates. Duplicates are tolerable and are NOT deleted here, by
-- decision: they cost processing time, not correctness. But the unit that
-- matters is not the place, it is the HOST. The chain resolves a host to an IP,
-- RDAPs the IP and decides onpremises from the registrant, so two places
-- sharing a host produce one landmark address and one RDAP call's worth of
-- information. A Foursquare row whose host Overture already has adds a name and
-- nothing else. Counting new HOSTS and new ZIPS is therefore the honest measure
-- of value, and counting new places is not.
--
-- Run AFTER fsq_fetch.py load. Sections 1 and 2 need only the load; sections 3
-- and 4 need the resolve and onpremises steps to have run on both tables.

-- ---------------------------------------------------------------------------
-- Host extraction, matching how ovt_resolve_hosts.py reads a URL: lower-cased,
-- protocol stripped, path and port and credentials discarded. Deliberately
-- written without backslashes so this file stays safe to paste.
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS fsq_host_v CASCADE;
CREATE VIEW fsq_host_v AS
SELECT fsq_place_id AS id,
       lower(rtrim(split_part(split_part(regexp_replace(btrim(websites),
              '^[a-zA-Z][a-zA-Z0-9+.-]*://', '', 'g'), '/', 1), ':', 1), '.')) AS host,
       left(lpad(btrim(overture_zip), 5, '0'), 5) AS zip,
       onpremises
FROM fsq_places_usa
WHERE websites IS NOT NULL AND btrim(websites) <> '';

DROP VIEW IF EXISTS ovt_host_v CASCADE;
CREATE VIEW ovt_host_v AS
SELECT id,
       lower(rtrim(split_part(split_part(regexp_replace(
              btrim(coalesce(substring(websites from '"([^"]*)"'), websites)),
              '^[a-zA-Z][a-zA-Z0-9+.-]*://', '', 'g'), '/', 1), ':', 1), '.')) AS host,
       left(lpad(btrim(overture_zip), 5, '0'), 5) AS zip,
       onpremises
FROM ovt_places_usa
WHERE websites IS NOT NULL AND btrim(websites) <> '';


-- 1. HOST OVERLAP. The headline number is hosts_only_in_fsq: that is the new
--    RDAP work, and the ceiling on new landmarks.

SELECT (SELECT count(DISTINCT host) FROM ovt_host_v WHERE host <> '')  AS hosts_overture,
       (SELECT count(DISTINCT host) FROM fsq_host_v WHERE host <> '')  AS hosts_foursquare,
       (SELECT count(*) FROM (SELECT DISTINCT host FROM fsq_host_v WHERE host <> ''
                              INTERSECT
                              SELECT DISTINCT host FROM ovt_host_v WHERE host <> '') x)
                                                                       AS hosts_in_both,
       (SELECT count(*) FROM (SELECT DISTINCT host FROM fsq_host_v WHERE host <> ''
                              EXCEPT
                              SELECT DISTINCT host FROM ovt_host_v WHERE host <> '') x)
                                                                       AS hosts_only_in_fsq;


-- 2. ZIP COVERAGE, counting ZIPs that have at least one place with a website.
--    This is coverage BEFORE the RDAP verdict, so it is an upper bound, not a
--    promise: a ZIP only becomes usable once some host there is on premises.

SELECT (SELECT count(DISTINCT zip) FROM ovt_host_v WHERE zip ~ '^[0-9]{5}$') AS zips_overture,
       (SELECT count(DISTINCT zip) FROM fsq_host_v WHERE zip ~ '^[0-9]{5}$') AS zips_foursquare,
       (SELECT count(*) FROM (SELECT DISTINCT zip FROM fsq_host_v WHERE zip ~ '^[0-9]{5}$'
                              EXCEPT
                              SELECT DISTINCT zip FROM ovt_host_v WHERE zip ~ '^[0-9]{5}$') x)
                                                                             AS zips_only_in_fsq;


-- 3. THE NUMBER THAT DECIDES WHETHER THIS WAS WORTH IT. ZIPs that have an
--    on-premises landmark in Foursquare and none in Overture. Needs onpremises
--    to have been computed on both tables.

SELECT count(*) AS zips_gained_onpremises
FROM (SELECT DISTINCT zip FROM fsq_host_v WHERE onpremises IS TRUE AND zip ~ '^[0-9]{5}$'
      EXCEPT
      SELECT DISTINCT zip FROM ovt_host_v WHERE onpremises IS TRUE AND zip ~ '^[0-9]{5}$') x;


-- 4. DUPLICATE SHAPE WITHIN Foursquare itself. A host serving many ZIPs is
--    either a chain or a hosting provider, and node_fanout.sql already treats
--    multi-ZIP-cluster addresses as hosting. Listed here so the biggest
--    offenders are visible before they reach the trace stage and spend time.

SELECT host, count(*) AS places, count(DISTINCT zip) AS zips
FROM fsq_host_v
WHERE host <> ''
GROUP BY host
HAVING count(*) > 1
ORDER BY count(DISTINCT zip) DESC, count(*) DESC
LIMIT 40;
