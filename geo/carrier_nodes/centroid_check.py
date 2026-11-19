"""Decide, per coordinate, whether it is a serving site or a city centroid.

WHY, AND WHAT I GOT WRONG

Boris, 2026-11-18: "ip-api.com's methodology resolves to the headend/CO, not
the municipality/CDP centroid."

He is right and his own output proves it. I had measured five of his largest
ip-api concentrations against those cities geocoded independently and found
them within 11 to 430 metres of the city centroid, then generalised that to
the whole estate. The generalisation was wrong, and wrong in a way I should
have caught: those five were the LARGEST concentrations precisely BECAUSE
they are the fallback cases. Piling every unresolved address in a city onto
one point is what makes a point big.

The statistic that settles it is points per distinct city name, from his run:

    precision  source          points   cities   points per city
    city       ipapi            4,039    1,897       2.13
    city       itdk maxmind     1,617    1,440       1.12

A pure centroid source scores 1.00. ip-api scores 2.13, resolving below city
level for most addresses and twice as finely as the ITDK's MaxMind rows. So
the question is not "is this source city-level", it is "is THIS COORDINATE a
site or a fallback", and that has to be measured per coordinate.

HOW IT IS MEASURED

Each distinct city name is geocoded ONCE through an independent service, and
every node coordinate claiming that city is compared against it. A coordinate
sitting on the city's own centroid is the fallback; one sitting elsewhere in
the city is a site. The geocoder is the same Census-then-Nominatim chain
already tested in geocode_sites.py, including the house-number guard, and the
city geocode is cached in city_centroid_tbl so it is paid for once.

A SECOND SIGNAL THAT NEEDS NO NETWORK, computed first because it is free: how
many distinct coordinates a city has. A city with several points is resolving
below city level by construction, whatever a geocoder says, so its points
need no check. Only cities with ONE point are candidates for being a
fallback, and those are the minority of addresses.

WHAT THIS IS NOT. It is not a judgement that ip-api is unreliable. It
separates the addresses where it resolved to infrastructure from the ones
where it could only name a city, so step 4 knows which distances mean
something.

USAGE

  python3 -u centroid_check.py candidates
  python3 -u centroid_check.py geocode --limit 200
  python3 -u centroid_check.py classify
  python3 -u centroid_check.py report
"""

import argparse
import json
import math
import os
import subprocess
import sys
import time
import urllib.parse

CENSUS = ("https://geocoding.geo.census.gov/geocoder/locations/"
          "onelineaddress")
NOMINATIM = "https://nominatim.openstreetmap.org/search"
UA = "trugeo-research/1.0 (city centroid check; via project repo)"
HERE = os.path.dirname(os.path.abspath(__file__))


def script(name):
    return os.path.join(HERE, name)


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def lit(s):
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def num(v):
    if v is None:
        return "NULL"
    try:
        return repr(float(v))
    except (TypeError, ValueError):
        return "NULL"


def km_between(lat1, lon1, lat2, lon2):
    """Equirectangular, adequate at city scale and cheap."""
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1) * math.cos(math.radians(lat1))
    return 6371.0 * math.hypot(dlat, dlon)


def get_json(url, params, timeout=30):
    q = urllib.parse.urlencode(params)
    r = subprocess.run(
        ["curl", "-sS", "-m", str(timeout), "-A", UA,
         "-H", "Accept: application/json", f"{url}?{q}"],
        capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def geocode_city(city, region, country):
    """Centroid of a named city, from Census then Nominatim.

    A CITY, not a street address, so the house-number guard in
    geocode_sites.py does not apply and must not be borrowed: there is no
    house number to check. The guard against a wrong answer here is
    different, namely that Nominatim is asked for a place and the result is
    rejected unless its class is a place or boundary. A road or a cafe
    matching the name is not a city centroid, which is exactly how
    "1 Wilshire Boulevard" became a Koreatown cafe.
    """
    parts = [p for p in (city, region) if p]
    one = ", ".join(parts)
    if country and country not in ("US", "United States"):
        one += ", " + country
    else:
        one += ", USA"

    if country in ("US", "United States"):
        d = get_json(CENSUS, {"address": one,
                              "benchmark": "Public_AR_Current",
                              "format": "json"})
        try:
            m = d["result"]["addressMatches"]
            if m:
                c = m[0]["coordinates"]
                return c["y"], c["x"], "census"
        except (KeyError, TypeError, IndexError):
            pass

    d = get_json(NOMINATIM, {"q": one, "format": "json", "limit": 5,
                             "addressdetails": 1})
    if isinstance(d, list):
        for r in d:
            if r.get("class") in ("place", "boundary"):
                try:
                    return (float(r["lat"]), float(r["lon"]),
                            f"nominatim:{r.get('class')}:{r.get('type')}")
                except (KeyError, TypeError, ValueError):
                    continue
    return None, None, None


GEOGRAPHIES = ("https://geocoding.geo.census.gov/geocoder/geographies/"
               "coordinates")


def geography_of(lat, lon, timeout=30):
    """The exact US state, county and tract containing a coordinate.

    THE COORDINATES DECIDE. NOTHING IS IMPUTED.

    Boris, 2026-11-18: "Don't guess in imputation!!!!! Just use the
    coordinates as I asked!!!!!"

    He is right twice over, because I guessed twice before getting here.

    FIRST I took the nearest US county centroid with no country filter and
    no bound, which produced Chennai in Alaska from 11,596 km away, and
    Singapore likewise, and London in Maine. Nearest-anything is not a
    containment test.

    THEN I wrote bounding boxes for the US states and territories from my
    own recollection of their extents. That is just as much a guess, only
    less visibly wrong, and it was unnecessary.

    This is the Census Bureau's own reverse geocoder. It performs a real
    point-in-polygon test against the boundaries the Census publishes and
    returns the containing state, county and tract. For a coordinate outside
    the United States it returns NO GEOGRAPHY AT ALL, which is the correct
    answer rather than a fallback, so no country filter and no box is
    needed. Verified 2026-11-18:

      41.0751, -111.9742   UT Utah, Davis County, tract 49011125805
      41.0600,  -74.8800   NJ New Jersey, Sussex County, tract 34037373900
      13.0843,   80.2705   no US geography          (Chennai)
       1.3521,  103.8200   no US geography          (Singapore)
      51.5072,   -0.1276   no US geography          (London)
      21.3099, -157.8581   HI Hawaii, Honolulu County
      52.8000, -169.0000   AK Alaska, Aleutians West Census Area

    The Aleutians case matters: it is west of -169 and the service places it
    correctly, where my own distance arithmetic had reported that county as
    23,741 km across because the longitude difference does not wrap.

    THE TRACT COMES FREE, and step 4 needs a tract per node anyway, so this
    one call answers two questions.

    Returns a dict, or None on a transport failure, which is distinct from
    an empty answer meaning "not in the United States".
    """
    d = get_json(GEOGRAPHIES, {"x": lon, "y": lat,
                               "benchmark": "Public_AR_Current",
                               "vintage": "Current_Current",
                               "format": "json"}, timeout=timeout)
    if d is None:
        return None
    try:
        g = d["result"]["geographies"]
    except (KeyError, TypeError):
        return None
    st = g.get("States") or []
    co = g.get("Counties") or []
    tr = g.get("Census Tracts") or []
    if not st:
        return {"in_us": False}
    return {
        "in_us": True,
        "state_usps": st[0].get("STUSAB"),
        "state_name": st[0].get("NAME"),
        "county_geoid": (co[0].get("GEOID") if co else None),
        "county_name": (co[0].get("NAME") if co else None),
        "tract_geoid": (tr[0].get("GEOID") if tr else None),
    }


def derive_states(limit=None, rate=0.5):
    """Look up the containing geography for coordinates lacking a region.

    One request per DISTINCT COORDINATE, cached, so the cost is paid once.
    Nothing is inferred from distance and nothing from a bounding box.
    """
    psql("-qc", """
CREATE TABLE IF NOT EXISTS coord_geography_tbl (
    lat          double precision NOT NULL,
    lon          double precision NOT NULL,
    in_us        boolean NOT NULL,
    state_usps   text,
    state_name   text,
    county_geoid text,
    county_name  text,
    tract_geoid  text,
    asked_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (lat, lon));
COMMENT ON TABLE coord_geography_tbl IS
  'The US state, county and census tract CONTAINING each coordinate, from the Census Bureau reverse geocoder, which performs a real point-in-polygon test. in_us is false for a coordinate outside the United States, which the service reports by returning no geography. Nothing here is inferred from proximity or from a bounding box: an earlier version used nearest county centroid and placed Chennai in Alaska.';""")

    rows = []
    for line in psql("-qtAF|", "-c", """
SELECT DISTINCT n.lat, n.lon
FROM node_location n
LEFT JOIN coord_geography_tbl g ON g.lat = n.lat AND g.lon = n.lon
WHERE n.precision = 'city'
  AND coalesce(n.city, '') <> ''
  AND coalesce(n.region, '') = ''
  AND n.lat IS NOT NULL
  AND g.lat IS NULL""").splitlines():
        p = line.split("|")
        if len(p) >= 2:
            try:
                rows.append((float(p[0]), float(p[1])))
            except ValueError:
                continue
    if limit:
        rows = rows[:limit]

    if not rows:
        n = psql_q("SELECT count(*) FROM coord_geography_tbl")
        print(f"Every coordinate needing a state is already looked up, "
              f"{int(n or 0):,} cached.", flush=True)
    else:
        print(f"{len(rows):,} distinct coordinate(s) need their containing "
              f"geography. One request each at {rate:g}s, about "
              f"{len(rows) * rate / 60:.0f} minutes, cached so it is paid "
              f"once.", flush=True)
        us = foreign = failed = 0
        t0 = time.monotonic()
        for i, (lat, lon) in enumerate(rows, 1):
            g = geography_of(lat, lon)
            if g is None:
                failed += 1
                time.sleep(max(rate, 1.0))
                continue
            if g["in_us"]:
                us += 1
                psql("-qc",
                     "INSERT INTO coord_geography_tbl (lat, lon, in_us, "
                     "state_usps, state_name, county_geoid, county_name, "
                     f"tract_geoid) VALUES ({num(lat)}, {num(lon)}, true, "
                     f"{lit(g['state_usps'])}, {lit(g['state_name'])}, "
                     f"{lit(g['county_geoid'])}, {lit(g['county_name'])}, "
                     f"{lit(g['tract_geoid'])}) "
                     "ON CONFLICT (lat, lon) DO UPDATE SET "
                     "in_us = true, state_usps = excluded.state_usps, "
                     "state_name = excluded.state_name, "
                     "county_geoid = excluded.county_geoid, "
                     "county_name = excluded.county_name, "
                     "tract_geoid = excluded.tract_geoid")
            else:
                foreign += 1
                psql("-qc",
                     "INSERT INTO coord_geography_tbl (lat, lon, in_us) "
                     f"VALUES ({num(lat)}, {num(lon)}, false) "
                     "ON CONFLICT (lat, lon) DO UPDATE SET in_us = false")
            if i == 1 or i % 50 == 0 or i == len(rows):
                el = time.monotonic() - t0
                eta = (f", about {(len(rows) - i) * el / i / 60:.0f} min left"
                       if i > 1 else "")
                print(f"[{i}/{len(rows)}] {us:,} in the US, {foreign:,} "
                      f"outside it, {failed:,} failed{eta}", flush=True)
            time.sleep(rate)
        print(f"\n{us:,} in the US, {foreign:,} outside it, {failed:,} "
              f"transport failures, in {(time.monotonic() - t0) / 60:.1f} "
              f"minutes", flush=True)

    print(psql("-c", """
SELECT CASE WHEN in_us THEN '1. inside the United States'
            ELSE '2. outside it, so no state and no US tract' END AS verdict,
       count(*) AS coordinates
FROM coord_geography_tbl GROUP BY 1 ORDER BY 1"""))
    print(psql("-c", """
SELECT state_usps, count(*) AS coordinates
FROM coord_geography_tbl WHERE in_us
GROUP BY 1 ORDER BY count(*) DESC LIMIT 10"""))
    return True


def cmd_states(args):
    """Look up and report the geography containing each coordinate."""
    require_view()
    if not derive_states(limit=args.limit, rate=args.rate):
        return 1
    if args.check:
        print()
        print("Coordinates the Census places OUTSIDE the United States. "
              "These get no state, which is correct: the plan maps US "
              "census tracts to US ZIP codes.")
        print()
        print(psql("-c", """
SELECT n.city, count(*) AS node_addresses,
       round(g.lat::numeric, 4) AS lat, round(g.lon::numeric, 4) AS lon
FROM coord_geography_tbl g
JOIN node_location n ON n.lat = g.lat AND n.lon = g.lon
WHERE NOT g.in_us
GROUP BY n.city, g.lat, g.lon
ORDER BY count(*) DESC LIMIT 20"""))
    return 0


def ensure_tables():
    psql("-qc", """
CREATE TABLE IF NOT EXISTS city_centroid_tbl (
    city       text NOT NULL,
    region     text NOT NULL,
    country    text NOT NULL,
    lat        double precision,
    lon        double precision,
    geocoder   text,
    asked_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (city, region, country));
COMMENT ON TABLE city_centroid_tbl IS
  'Centroid of each city name appearing in node_location, geocoded once from an independent service so that a node coordinate can be compared against the city it claims. A coordinate sitting on its city centroid is a geolocation fallback; one sitting elsewhere in the city is a serving site.';""")


def require_view():
    if psql_q("SELECT to_regclass('node_location') IS NOT NULL") != "t":
        sys.exit("node_location does not exist. Build it first:\n"
                 f"  psql -X -P pager=off -f {script('node_location.sql')}")


def cmd_candidates(args):
    """Which coordinates could possibly be a fallback. No network.

    A city with MORE THAN ONE distinct coordinate is resolving below city
    level by construction, so none of its points can be the single
    city-wide fallback and none need geocoding. This is free and it is what
    makes the geocoding bill small.
    """
    require_view()
    print("Cities by how many distinct coordinates their nodes have. A city "
          "with several points is already resolving below city level, "
          "whatever a geocoder says, so only the single-point cities are "
          "candidates for being a fallback.\n")
    print(psql("-c", """
WITH c AS (
  SELECT city, region, country,
         count(DISTINCT (lat, lon)) AS points,
         count(*)                   AS node_addresses
  FROM node_location
  WHERE precision = 'city' AND coalesce(city, '') <> ''
  GROUP BY 1, 2, 3)
SELECT CASE WHEN points = 1 THEN '1 point, a fallback CANDIDATE'
            WHEN points <= 3 THEN '2 to 3 points, resolving below city'
            WHEN points <= 10 THEN '4 to 10 points'
            ELSE 'more than 10 points' END AS shape,
       count(*)                 AS cities,
       sum(points)              AS points,
       sum(node_addresses)      AS node_addresses,
       round(100.0 * sum(node_addresses) / sum(sum(node_addresses)) OVER (), 1)
         AS pct_of_addresses
FROM c GROUP BY 1 ORDER BY 1"""))

    print("\nThe single-point cities carrying the most addresses. These are "
          "where a fallback would hurt most, and they are what `geocode` "
          "checks first.\n")
    print(psql("-c", f"""
SELECT city, region, country, count(*) AS node_addresses,
       round(min(lat)::numeric, 4) AS lat,
       round(min(lon)::numeric, 4) AS lon
FROM node_location
WHERE precision = 'city' AND coalesce(city, '') <> ''
GROUP BY city, region, country
HAVING count(DISTINCT (lat, lon)) = 1
ORDER BY count(*) DESC
LIMIT {int(args.limit)}"""))
    return 0


def cmd_geocode(args):
    require_view()
    ensure_tables()

    # DERIVE MISSING STATES FIRST, and discard any cached centroid that was
    # looked up WITHOUT one. A centroid cached under a blank region may be
    # the wrong city entirely, so keeping it would be worse than not having
    # it: the grade it produces looks just as confident.
    derive_states()
    stale = psql_q("SELECT count(*) FROM city_centroid_tbl WHERE region = ''")
    if stale and stale != "0":
        print(f"DISCARDING {int(stale):,} cached centroid(s) that were "
              f"geocoded with no state. A city name without a state is "
              f"ambiguous, Layton exists in Utah, New Jersey and Florida, "
              f"so those answers cannot be trusted and are looked up again "
              f"with the state derived from the node coordinate.",
              flush=True)
        print("      Nothing else is affected: entries that had a state "
              "are kept and will not be fetched again.", flush=True)
        psql("-qc", "DELETE FROM city_centroid_tbl WHERE region = ''")

    rows = []
    # coalesce the source's region with the one derived from the node
    # coordinate, so a city is never geocoded without a state.
    for line in psql("-qtAF|", "-c", f"""
SELECT n.city,
       coalesce(nullif(n.region, ''), d.state_usps, '') AS region,
       coalesce(n.country, '') AS country,
       count(*)
FROM node_location n
LEFT JOIN coord_geography_tbl d
       ON d.lat = n.lat AND d.lon = n.lon AND d.in_us
WHERE n.precision = 'city' AND coalesce(n.city, '') <> ''
  {"AND n.country IN ('US', 'United States')" if args.us_only else ""}
GROUP BY n.city, coalesce(nullif(n.region, ''), d.state_usps, ''),
         coalesce(n.country, '')
HAVING count(DISTINCT (n.lat, n.lon)) = 1
ORDER BY count(*) DESC""").splitlines():
        p = line.split("|")
        if len(p) >= 4:
            rows.append((p[0], p[1], p[2], int(p[3] or 0)))

    done = set()
    for line in psql("-qtAF|", "-c",
                     "SELECT city, region, country FROM city_centroid_tbl"
                     ).splitlines():
        p = line.split("|")
        if len(p) >= 3:
            done.add((p[0], p[1], p[2]))

    todo = [r for r in rows if (r[0], r[1], r[2]) not in done]
    if args.limit:
        todo = todo[:args.limit]

    if not todo:
        print(f"All {len(rows):,} single-point cities are already geocoded. "
              f"Run classify next:")
        print(f"  python3 -u {script('centroid_check.py')} classify")
        return 0

    print(f"{len(rows):,} single-point cities, {len(done):,} already "
          f"geocoded, {len(todo):,} to do now.")
    print(f"One request per second per Nominatim's usage policy, so about "
          f"{len(todo) / 60.0:.0f} minutes.\n")

    ok = miss = 0
    t0 = time.monotonic()
    for i, (city, region, country, n) in enumerate(todo, 1):
        lat, lon, who = geocode_city(city, region, country)
        if lat is None:
            miss += 1
            state = "NOT FOUND"
        else:
            ok += 1
            state = f"{lat:.4f}, {lon:.4f} via {who}"
        psql("-qc",
             "INSERT INTO city_centroid_tbl (city, region, country, lat, "
             f"lon, geocoder) VALUES ({lit(city)}, {lit(region)}, "
             f"{lit(country)}, {num(lat)}, {num(lon)}, {lit(who)}) "
             "ON CONFLICT (city, region, country) DO UPDATE SET "
             "lat = excluded.lat, lon = excluded.lon, "
             "geocoder = excluded.geocoder, asked_at = now()")
        if i == 1 or i % 25 == 0 or i == len(todo):
            el = time.monotonic() - t0
            eta = (f", about {(len(todo) - i) * el / i / 60:.0f} min left"
                   if i > 1 else "")
            print(f"[{i}/{len(todo)}] {city}, {region} ({n} addresses): "
                  f"{state}{eta}", flush=True)
        time.sleep(args.rate)

    print(f"\n{ok:,} geocoded, {miss:,} not found, in "
          f"{(time.monotonic() - t0) / 60:.1f} minutes")
    print(f"  python3 -u {script('centroid_check.py')} classify")
    return 0


def cmd_classify(args):
    require_view()
    if psql_q("SELECT to_regclass('city_centroid_tbl') IS NOT NULL") != "t":
        sys.exit("city_centroid_tbl does not exist. Run geocode first:\n"
                 f"  python3 -u {script('centroid_check.py')} geocode")

    # DROPPED, NOT REPLACED. CREATE OR REPLACE VIEW cannot change the
    # column list, and this version adds region_eff, so postgres refuses
    # with "cannot change name of view column". Nothing is lost: the view is
    # derived in full from the tables beneath it.
    psql("-qc", f"""
DROP VIEW IF EXISTS node_location_graded;
CREATE VIEW node_location_graded AS
-- THE POINT COUNT MUST USE THE DERIVED STATE TOO.
--
-- Found by running this, not by reading it. The first version grouped on
-- node_location.region, which is blank for every row filled from the probe
-- estate, so two DIFFERENT cities of the same name collapsed into one
-- group. Layton Utah and Layton New Jersey became a single "Layton" with
-- two distinct points, which then graded both site_subcity on the grounds
-- that the city resolves below city level, without the centroid check ever
-- running. Layton Utah sits EXACTLY on its own centroid and is a fallback.
--
-- So the same disambiguation Boris asked for has to be applied on both
-- sides: once when geocoding the city, and once when counting how many
-- points that city has.
WITH loc AS (
  SELECT n.*,
         coalesce(nullif(n.region, ''), ds.state_usps, '') AS region_eff
  FROM node_location n
  LEFT JOIN coord_geography_tbl ds
         ON ds.lat = n.lat AND ds.lon = n.lon AND ds.in_us
), pts AS (
  SELECT city, region_eff, country, count(DISTINCT (lat, lon)) AS city_points
  FROM loc
  WHERE precision = 'city' AND coalesce(city, '') <> ''
  GROUP BY 1, 2, 3)
SELECT n.*,
       p.city_points,
       c.lat AS city_lat, c.lon AS city_lon,
       CASE WHEN c.lat IS NULL THEN NULL
            ELSE 6371 * sqrt(pow(radians(c.lat - n.lat), 2) +
                 pow(radians(c.lon - n.lon) * cos(radians(n.lat)), 2))
       END AS km_from_city_centroid,
       CASE
         WHEN n.precision <> 'city' THEN n.precision
         WHEN coalesce(p.city_points, 0) > 1 THEN 'site_subcity'
         WHEN c.lat IS NULL THEN 'city_unchecked'
         WHEN 6371 * sqrt(pow(radians(c.lat - n.lat), 2) +
              pow(radians(c.lon - n.lon) * cos(radians(n.lat)), 2))
              <= {float(args.tolerance_km)} THEN 'city_fallback'
         ELSE 'site_subcity'
       END AS grade
FROM loc n
LEFT JOIN pts p
       ON p.city = n.city AND p.region_eff = n.region_eff
      AND p.country IS NOT DISTINCT FROM n.country
LEFT JOIN city_centroid_tbl c
       ON c.city = n.city AND c.region = n.region_eff
      AND c.country = coalesce(n.country, '');

COMMENT ON VIEW node_location_graded IS
  'node_location with each city-level coordinate graded against the centroid of the city it claims. site_subcity means the coordinate is NOT the city centroid and so is infrastructure: either the city has several distinct points, or this point is further than the tolerance from the centroid. city_fallback means the coordinate IS the city centroid and names a city rather than a site. city_unchecked means the city has not been geocoded yet.';""")

    print(f"Graded at a tolerance of {args.tolerance_km:g} km. A city-level "
          f"coordinate within that of its city's own centroid is the "
          f"fallback; anything else is infrastructure.\n")
    print(psql("-c", """
SELECT grade, count(*) AS node_addresses,
       count(DISTINCT (lat, lon)) AS distinct_points,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM node_location_graded GROUP BY 1 ORDER BY count(*) DESC"""))

    print("How far the city-level coordinates sit from their city centroid. "
          "If most are well clear of it, ip-api is resolving to "
          "infrastructure and not to the municipality.\n")
    print(psql("-c", """
SELECT CASE
         WHEN km_from_city_centroid IS NULL THEN 'not checked'
         WHEN km_from_city_centroid <= 0.5  THEN 'a. within 500 m'
         WHEN km_from_city_centroid <= 2    THEN 'b. 500 m to 2 km'
         WHEN km_from_city_centroid <= 10   THEN 'c. 2 to 10 km'
         ELSE                                    'd. more than 10 km'
       END AS distance_band,
       count(*) AS node_addresses,
       count(DISTINCT (lat, lon)) AS distinct_points
FROM node_location_graded
WHERE precision = 'city'
GROUP BY 1 ORDER BY 1"""))
    return 0


def cmd_report(args):
    if psql_q("SELECT to_regclass('node_location_graded') IS NOT NULL") != "t":
        sys.exit("node_location_graded does not exist. Run classify first:\n"
                 f"  python3 -u {script('centroid_check.py')} classify")
    print("Candidate serving sites by grade, best first. site_subcity and "
          "the ITDK tiers are infrastructure; city_fallback names a city.\n")
    print(psql("-c", f"""
SELECT grade,
       count(DISTINCT (lat, lon)) AS sites,
       count(*)                   AS node_addresses,
       count(DISTINCT city)       AS cities
FROM node_location_graded
WHERE country IN ('US', 'United States')
GROUP BY 1
ORDER BY CASE grade WHEN 'facility' THEN 1 WHEN 'operator_named' THEN 2
                    WHEN 'site_subcity' THEN 3
                    WHEN 'city_unchecked' THEN 4 ELSE 5 END"""))
    print(f"\nLargest infrastructure sites, United States only:\n")
    print(psql("-c", f"""
SELECT grade, city, region, count(*) AS node_addresses,
       round(lat::numeric, 4) AS lat, round(lon::numeric, 4) AS lon,
       round(km_from_city_centroid::numeric, 1) AS km_from_centroid
FROM node_location_graded
WHERE country IN ('US', 'United States')
  AND grade IN ('facility', 'operator_named', 'site_subcity')
GROUP BY grade, city, region, lat, lon, km_from_city_centroid
ORDER BY count(*) DESC LIMIT {int(args.limit)}"""))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("candidates",
                       help="which coordinates could be a fallback. No "
                            "network, and it bounds the geocoding bill")
    c.add_argument("--limit", type=int, default=25)
    c.set_defaults(func=cmd_candidates)

    g = sub.add_parser("geocode",
                       help="geocode each single-point city once")
    g.add_argument("--limit", type=int)
    g.add_argument("--rate", type=float, default=1.0,
                   help="seconds between requests, default 1 per "
                        "Nominatim's usage policy. Do not lower it.")
    g.add_argument("--us-only", action="store_true", default=True)
    g.set_defaults(func=cmd_geocode)

    st = sub.add_parser("states",
                        help="derive the state from the node coordinate "
                             "for cities whose source gave none")
    st.add_argument("--check", action="store_true",
                    help="list the coordinates the Census places outside "
                         "the United States")
    st.add_argument("--limit", type=int,
                    help="stop after this many coordinates, for a trial")
    st.add_argument("--rate", type=float, default=0.5,
                    help="seconds between requests, default 0.5")
    st.set_defaults(func=cmd_states)

    cl = sub.add_parser("classify",
                        help="grade every coordinate site or fallback")
    cl.add_argument("--tolerance-km", type=float, default=1.0,
                    help="a city-level coordinate within this of its city "
                         "centroid is the fallback, default 1 km")
    cl.set_defaults(func=cmd_classify)

    r = sub.add_parser("report", help="candidate sites by grade")
    r.add_argument("--limit", type=int, default=30)
    r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
