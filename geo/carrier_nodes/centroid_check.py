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


def derive_states(args_limit=None):
    """Fill the state of every city whose source did not give one.

    WHY THIS IS NOT COSMETIC. Boris, 2026-11-18: "In cases like Layton,
    where state is not available in the source, derive state from the
    coordinates (here, Utah)."

    His run showed "[25/2781] Layton,  (34 addresses)" with a blank region,
    so the geocoder was asked for "Layton, USA". It returned 41.0751,
    -111.9742, which is Layton UTAH, but there are also Laytons in New
    Jersey and Florida and nothing in the question distinguished them. A
    wrong city centroid produces a wrong distance and therefore a wrong
    grade, silently.

    And the blank is SYSTEMATIC, not occasional. His
    ip2city_dbiplite_probe_tbl has no region column at all, which `fill`
    reported at the time, so every one of the 21,342 addresses filled from
    it carries a null region. Roughly a quarter of the candidate cities in
    his top 25 had no state.

    THE NODE'S OWN COORDINATE SETTLES IT. We are geocoding the city only to
    compare it against a coordinate we already have, and that coordinate
    lies in exactly one state. Nearest county centroid from
    census_county_tbl gives the state: counties are small relative to
    states, so the only risk is a point within a few kilometres of a state
    line, and for a city NAME that is a far smaller risk than picking the
    wrong state entirely.

    Done per distinct coordinate rather than per node, so it is a few
    thousand comparisons against 3,222 counties rather than tens of
    millions.
    """
    if psql_q("SELECT to_regclass('census_county_tbl') IS NOT NULL") != "t":
        print("census_county_tbl does not exist, so a state cannot be "
              "derived from coordinates. Load the gazetteer first:")
        print(f"  python3 -u {script('coverage_holes.py')} fetch "
              f"--dir /home/boris/geo/census")
        print(f"  python3 -u {script('coverage_holes.py')} load "
              f"--dir /home/boris/geo/census")
        return False

    psql("-qc", """
CREATE TABLE IF NOT EXISTS city_state_derived_tbl (
    city        text NOT NULL,
    lat         double precision NOT NULL,
    lon         double precision NOT NULL,
    state_usps  text NOT NULL,
    county_name text,
    km_to_county double precision,
    PRIMARY KEY (city, lat, lon));
COMMENT ON TABLE city_state_derived_tbl IS
  'State inferred from a node coordinate, for cities whose source gave no region. Needed because ip-api answers filled from the probe estate carry no region at all, which made the city name ambiguous: "Layton" exists in Utah, New Jersey and Florida. The state comes from the nearest county centroid, so the only material risk is a point within a few kilometres of a state line.';""")

    psql("-qc", """
INSERT INTO city_state_derived_tbl
    (city, lat, lon, state_usps, county_name, km_to_county)
SELECT d.city, d.lat, d.lon, v.state_usps, v.name, v.km
FROM (SELECT DISTINCT city, lat, lon
      FROM node_location
      WHERE precision = 'city'
        AND coalesce(city, '') <> ''
        AND coalesce(region, '') = ''
        AND lat IS NOT NULL) d
CROSS JOIN LATERAL (
    SELECT c.state_usps, c.name,
           6371 * sqrt(pow(radians(c.lat - d.lat), 2) +
                       pow(radians(c.lon - d.lon) * cos(radians(d.lat)), 2))
             AS km
    FROM census_county_tbl c
    ORDER BY pow(c.lat - d.lat, 2) +
             pow((c.lon - d.lon) * cos(radians(d.lat)), 2)
    LIMIT 1) v
ON CONFLICT (city, lat, lon) DO UPDATE SET
    state_usps = excluded.state_usps,
    county_name = excluded.county_name,
    km_to_county = excluded.km_to_county""")

    n = psql_q("SELECT count(*) FROM city_state_derived_tbl")
    print(f"state derived from coordinates for {int(n or 0):,} "
          f"city-and-coordinate pair(s) whose source gave none.", flush=True)
    print(psql("-c", """
SELECT state_usps, count(*) AS cities
FROM city_state_derived_tbl GROUP BY 1 ORDER BY count(*) DESC LIMIT 8"""))
    far = psql_q("SELECT count(*) FROM city_state_derived_tbl "
                 "WHERE km_to_county > 60")
    if far and far != "0":
        print(f"NOTE: {int(far):,} are more than 60 km from the nearest "
              f"county centroid, so the derived state is weaker evidence "
              f"for those. They are listed by `states --check`.", flush=True)
    return True


def cmd_states(args):
    """Derive and report the states inferred from coordinates."""
    require_view()
    if not derive_states():
        return 1
    if args.check:
        print()
        print("Furthest from a county centroid, where the derived state "
              "is least certain:")
        print()
        print(psql("-c", """
SELECT city, state_usps, county_name,
       round(km_to_county::numeric, 1) AS km_to_county,
       round(lat::numeric, 4) AS lat, round(lon::numeric, 4) AS lon
FROM city_state_derived_tbl
ORDER BY km_to_county DESC LIMIT 20"""))
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
LEFT JOIN city_state_derived_tbl d
       ON d.city = n.city AND d.lat = n.lat AND d.lon = n.lon
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
  LEFT JOIN city_state_derived_tbl ds
         ON ds.city = n.city AND ds.lat = n.lat AND ds.lon = n.lon
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
                    help="list the ones furthest from a county centroid, "
                         "where the derived state is least certain")
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
