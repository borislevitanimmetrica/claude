-- node_location.sql - one view of every node location, carrying its PRECISION.
--
-- WHY THIS REPLACES THE "IS IT A PLACE" TEST
--
-- Boris's ip-api run located 22,769 of 22,770 node addresses and my own
-- report said "3. a place, 100.0 per cent". That number was misleading and
-- the fault is mine: the test asked whether the answer carried a CITY NAME,
-- and ip-api essentially always does. It is not a test of whether the
-- coordinate is a building.
--
-- MEASURED 2026-11-18. The coordinates his run returned, against the same
-- cities geocoded independently through Nominatim:
--
--   city        node answer           city centroid         apart
--   New York    40.7128, -74.0060     40.7127, -74.0060      11 m
--   Dallas      32.7767, -96.7970     32.7763, -96.7969      45 m
--   Toronto     43.6532, -79.3832     43.6535, -79.3839      60 m
--   Denver      39.7392, -104.9900    39.7392, -104.9849    430 m, same lat
--   Boston      42.3601, -71.0589     42.3588, -71.0578     170 m
--
-- Those are city centroids, not facilities. "charter.com, New York, 102
-- nodes, 40.7128 -74.0060" means ip-api knows the city and not where in it.
--
-- A SECOND ARTIFACT, which is not a centroid. Monroe, Louisiana carried 107
-- level3.net nodes and 91 lumen.tech nodes at one identical point,
-- 32.5891 -92.0664, which is 10 km from Monroe's centroid. Level 3 and Lumen
-- are the same company and Monroe is its corporate headquarters. 198 nodes
-- at a head office is a registered-address artifact, not a serving site.
--
-- WHAT TO DO ABOUT IT, AND WHAT NOT TO DO
--
-- Not a blacklist of centroid coordinates. I tried the Census place
-- gazetteer as the reference and it is the wrong one: its INTPTLAT is a
-- point guaranteed to lie inside the place polygon, which sits 4 to 8 km
-- from these values, so matching against it would miss the very rows it was
-- meant to catch.
--
-- Instead every location carries the precision its SOURCE can support, and
-- nothing downstream is allowed to pretend otherwise:
--
--   facility      an internet exchange facility, from the ITDK 'ix' method.
--                 A known building.
--   operator_named the ITDK 'hoiho' method, decoded from the operator's own
--                 DNS naming. As precise as the operator chose to be, which
--                 for a small town is the town and for a metro is a site
--                 code. Independent of IP geolocation entirely.
--   city          a commercial geolocation answer carrying a city. The
--                 coordinate is the city, not the building. This is most of
--                 the estate and it is NOT useless: where a census tract is
--                 larger than the city, a city-level coordinate is adequate.
--                 In a dense metro it is not.
--   region        an answer with a region but no city.
--   none          a vendor sentinel, or no coordinate at all.
--
-- THE CONSEQUENCE FOR STEP 4, stated rather than discovered later. Step 5
-- picks the nearest site unless another within twice the distance has
-- uninterrupted coverage. Between two city-level sites in different towns
-- that comparison is meaningful. Between two city-level sites in the SAME
-- city it is not, because both are the same point. So step 4 must either
-- work at a precision tier where the distances separate, or report that it
-- cannot distinguish.

BEGIN;

CREATE OR REPLACE VIEW node_location AS
WITH itdk AS (
    SELECT l.address                        AS node_ip,
           l.lat, l.lon,
           l.city, l.region, l.country,
           l.method                         AS source_detail,
           'itdk'                           AS source,
           CASE l.method
                WHEN 'ix'     THEN 'facility'
                WHEN 'hoiho'  THEN 'operator_named'
                WHEN 'maxmind' THEN
                     CASE WHEN coalesce(l.city, '') <> '' THEN 'city'
                          WHEN coalesce(l.region, '') <> '' THEN 'region'
                          ELSE 'none' END
                ELSE 'city' END             AS precision
    FROM itdk_node_located l
    WHERE NOT l.on_sentinel
), api AS (
    SELECT q.node_ip, q.lat, q.lon,
           q.city, q.region_name AS region, q.country,
           q.source              AS source_detail,
           'ipapi'               AS source,
           CASE WHEN q.lat IS NULL THEN 'none'
                WHEN coalesce(q.city, '') <> '' THEN 'city'
                WHEN coalesce(q.region_name, '') <> '' THEN 'region'
                ELSE 'none' END  AS precision
    FROM node_ipapi_tbl q
    WHERE q.status = 'success'
      AND q.lat IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM geo_sentinel_tbl s
            WHERE s.kind = 'sentinel'
              AND round(s.lat::numeric, 3) = round(q.lat::numeric, 3)
              AND round(s.lon::numeric, 3) = round(q.lon::numeric, 3))
)
-- ONE ROW PER NODE ADDRESS, best precision winning. The ITDK's independent
-- methods are preferred over a commercial answer at the same precision,
-- because hoiho and ix do not share ip-api's systematic bias and so can
-- serve as a check on it.
SELECT DISTINCT ON (node_ip)
       node_ip, lat, lon, city, region, country,
       precision, source, source_detail
FROM (SELECT * FROM itdk UNION ALL SELECT * FROM api) u
WHERE precision <> 'none'
ORDER BY node_ip,
         CASE precision WHEN 'facility' THEN 1
                        WHEN 'operator_named' THEN 2
                        WHEN 'city' THEN 3
                        WHEN 'region' THEN 4
                        ELSE 5 END,
         CASE source WHEN 'itdk' THEN 1 ELSE 2 END;

COMMENT ON VIEW node_location IS
'One location per carrier node address, carrying the PRECISION its source can support: facility from an IXP, operator_named from the operator''s own DNS naming via Hoiho, city from a commercial geolocation answer whose coordinate is the city rather than the building, region, or none. Best precision wins, and the ITDK methods are preferred over a commercial answer at equal precision because they do not share ip-api''s bias. Measured 2026-11-18: ip-api''s answers for New York, Dallas, Toronto, Denver and Boston sat within 11 to 430 m of those cities'' own centroids, so a city-level row is the city and not a site.';

COMMIT;

\echo
\echo PRECISION MIX. This is the number that matters for step 4, not the
\echo count of located addresses.
\echo
SELECT precision, source,
       count(*)                                   AS node_addresses,
       count(DISTINCT (lat, lon))                 AS distinct_points,
       count(DISTINCT city)                       AS distinct_cities
FROM node_location
GROUP BY 1, 2
ORDER BY CASE precision WHEN 'facility' THEN 1 WHEN 'operator_named' THEN 2
                        WHEN 'city' THEN 3 ELSE 4 END, source;

\echo
\echo IS A "SITE" REALLY A SITE, OR IS IT A CITY. If points and cities are
\echo the same number for city-level rows, then every site IS a city and the
\echo --min-nodes threshold is counting cities, not headends.
\echo
SELECT precision,
       count(DISTINCT (lat, lon)) AS distinct_points,
       count(DISTINCT (city, region, country)) AS distinct_city_names,
       round(count(DISTINCT (lat, lon))::numeric
             / nullif(count(DISTINCT (city, region, country)), 0), 2)
         AS points_per_city
FROM node_location
GROUP BY 1 ORDER BY 1;

\echo
\echo US ONLY. The plan maps US census tracts to US ZIP codes, so a node
\echo located abroad cannot contribute and should not inflate any count.
\echo
SELECT CASE WHEN country IN ('US', 'United States') THEN 'United States'
            ELSE coalesce(nullif(country, ''), '(blank)') END AS country,
       count(*) AS node_addresses
FROM node_location
GROUP BY 1 ORDER BY count(*) DESC LIMIT 12;
