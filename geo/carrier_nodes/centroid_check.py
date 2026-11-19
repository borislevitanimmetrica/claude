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

    rows = []
    for line in psql("-qtAF|", "-c", f"""
SELECT city, coalesce(region, ''), coalesce(country, ''), count(*)
FROM node_location
WHERE precision = 'city' AND coalesce(city, '') <> ''
  {"AND country IN ('US', 'United States')" if args.us_only else ""}
GROUP BY city, coalesce(region, ''), coalesce(country, '')
HAVING count(DISTINCT (lat, lon)) = 1
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

    psql("-qc", f"""
CREATE OR REPLACE VIEW node_location_graded AS
WITH pts AS (
  SELECT city, region, country, count(DISTINCT (lat, lon)) AS city_points
  FROM node_location
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
FROM node_location n
LEFT JOIN pts p USING (city, region, country)
LEFT JOIN city_centroid_tbl c
       ON c.city = n.city AND c.region = coalesce(n.region, '')
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
