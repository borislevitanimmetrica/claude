-- geo_sentinel_tbl.sql - coordinates that mean "not located", not a place.
--
-- WHY THIS EXISTS
--
-- Boris's first concentration run, 2026-11-18, returned these as the five
-- largest candidate serving sites:
--
--   charter.com       843 node addresses   37.7510, -97.8220
--   comcast.net       391                  37.7510, -97.8220
--   verizon-gni.net   383                  37.7510, -97.8220
--   spectrum.com      327                  37.7510, -97.8220
--   frontiernet.net   232                  37.7510, -97.8220
--
-- One coordinate, five carriers, every row with a BLANK CITY. At least 2,597
-- node addresses of the 13,774 located sit on that single point, which is
-- roughly a fifth of everything.
--
-- It is not a facility. From MaxMind's own release note of 2016-04-11, "Change
-- in default lat/lon": for IP addresses in the United States that they are
-- unable to locate to a particular state or city, they return 37.751,
-- -97.822. It is a deliberate sentinel meaning NOT LOCATED, placed near the
-- geographic centre of the contiguous United States. The earlier default was
-- a real farm near Potwin, Kansas, whose occupants were harassed for years as
-- a result, and MaxMind moved it to the middle of a lake.
--   https://dev.maxmind.com/geoip/release-notes/2016-04-11-change-in-default-lat-lon/
--
-- Treating a sentinel as a serving site would have been the worst error in
-- this project. Step 4 measures the distance from a headend to each census
-- tract centroid and step 5 picks the nearest; measured from central Kansas,
-- Charter's 843 nodes would be nearest to Kansas tracts, and the ZIP codes
-- that fell out would be confidently wrong rather than missing. Missing is
-- recoverable. Wrong and plausible is not.
--
-- THE SECOND MAXMIND DEFAULT is in the same release note: addresses resolving
-- to Ashburn, Virginia with ZIP 20147 return 39.018, -77.539. Ashburn is a
-- genuine data centre concentration, so that one is ambiguous: it may be a
-- real location or a catch-all. It is recorded here as 'suspect' rather than
-- 'sentinel' so it can be reported without being silently discarded.
--
-- THE GENERAL RULE, which catches sentinels this table does not list: a row
-- with NO CITY is a country or region centroid, not a place. In Boris's
-- output every sentinel row had a blank city, and so did the non-US ones at
-- 48.8582/2.3387 which is central Paris and 51.4964/-0.1224 which is central
-- London. Those are country-level defaults for addresses MaxMind could place
-- no better than the nation. The rule is applied in the view below rather
-- than depending on this list being complete, because it cannot be.

BEGIN;

CREATE TABLE IF NOT EXISTS geo_sentinel_tbl (
    lat      double precision NOT NULL,
    lon      double precision NOT NULL,
    kind     text NOT NULL CHECK (kind IN ('sentinel', 'suspect')),
    scope    text NOT NULL,
    vendor   text NOT NULL,
    source   text NOT NULL,
    note     text,
    PRIMARY KEY (lat, lon)
);

COMMENT ON TABLE geo_sentinel_tbl IS
'Coordinates published by a geolocation vendor to mean "could not locate", which must never be treated as a serving site. kind sentinel is documented by the vendor as a default; kind suspect is a coordinate that may be either a real concentration or a catch-all and is reported rather than discarded.';

INSERT INTO geo_sentinel_tbl (lat, lon, kind, scope, vendor, source, note)
VALUES
    (37.751, -97.822, 'sentinel', 'country', 'maxmind',
     'https://dev.maxmind.com/geoip/release-notes/2016-04-11-change-in-default-lat-lon/',
     'Returned for US addresses MaxMind cannot place to a state or city. Near the geographic centre of the contiguous United States.'),
    (39.018, -77.539, 'suspect', 'city', 'maxmind',
     'https://dev.maxmind.com/geoip/release-notes/2016-04-11-change-in-default-lat-lon/',
     'Returned for addresses resolving to Ashburn, Virginia ZIP 20147. Ashburn is a genuine data centre concentration, so this may be real; reported, not discarded.')
ON CONFLICT (lat, lon) DO UPDATE SET
    kind = excluded.kind, scope = excluded.scope,
    vendor = excluded.vendor, source = excluded.source,
    note = excluded.note;

COMMIT;

\echo
\echo geo_sentinel_tbl:
\echo
SELECT lat, lon, kind, scope, vendor FROM geo_sentinel_tbl ORDER BY kind, lat;

\echo
\echo HOW MANY OF THE LOCATED NODES SIT ON A SENTINEL OR HAVE NO CITY.
\echo A row with no city is a country or region centroid, not a place, and is
\echo excluded whether or not its coordinate is in the table above.
\echo
SELECT CASE
         WHEN s.lat IS NOT NULL AND s.kind = 'sentinel'
           THEN '1. on a documented vendor sentinel'
         WHEN coalesce(g.city, '') = ''
           THEN '2. no city, so a country or region centroid'
         WHEN s.lat IS NOT NULL AND s.kind = 'suspect'
           THEN '3. on a suspect coordinate, reported not discarded'
         ELSE '4. usable as a candidate site'
       END                                    AS verdict,
       count(*)                               AS node_addresses,
       count(DISTINCT g.node_id)              AS nodes
FROM itdk_iface_tbl i
JOIN itdk_node_geo_tbl g USING (node_id)
LEFT JOIN geo_sentinel_tbl s
       ON round(g.lat::numeric, 3) = round(s.lat::numeric, 3)
      AND round(g.lon::numeric, 3) = round(s.lon::numeric, 3)
WHERE g.lat IS NOT NULL
GROUP BY 1 ORDER BY 1;
