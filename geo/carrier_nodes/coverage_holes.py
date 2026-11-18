"""Find large areas with no concentration of more than one node.

WHY

Boris, 2026-11-18: "You are correct that ignoring single nodes may blind us
to genuine rural connectivity, such as from REI companies. Once everything is
loaded, we should check for large areas in which there are no concentrations
of more than one node. Rural parts of the West, Alaska, Michigan Upper
Peninsula, or any REI company's territory, should give a good indication."

This is the test of the --min-nodes threshold, and it is a better test than
arguing about the number. For every county it measures the distance to the
nearest concentration at each threshold. The quantity that matters is the
DIFFERENCE: where the nearest two-node concentration is a hundred kilometres
away but the nearest single-node one is eight, the singleton IS the local
serving site and excluding it blinds us to that county entirely.

A county with no concentration within any sane distance is a different
finding again: it means the ITDK has no visibility of whatever serves it, and
no threshold can fix that.

WHAT THE GEOGRAPHY COMES FROM

The Census gazetteer, which is open and small. Verified by download
2026-11-18: the 2024 national county file is 141,679 bytes and holds 3,222
counties with an internal point and land area; the tract file is 2,420,663
bytes. Columns are read from the file's own header rather than by position,
because assuming a column name has cost this project four round trips.

Land area is the reason counties are the unit here rather than tracts. A
tract is drawn to hold roughly equal population, so rural tracts are
enormous and urban ones tiny, and "large area with no concentration" is a
statement about square miles. ALAND_SQMI is in the file.

USAGE

  python3 -u coverage_holes.py fetch --dir /home/boris/geo/census
  python3 -u coverage_holes.py load  --dir /home/boris/geo/census
  python3 -u coverage_holes.py holes
  python3 -u coverage_holes.py holes --state AK
  python3 -u coverage_holes.py holes --carrier-like '%coop%'
  python3 -u coverage_holes.py selftest
"""

import argparse
import csv
import io
import os
import subprocess
import sys
import time
import zipfile

GAZ_BASE = ("https://www2.census.gov/geo/docs/maps-data/data/gazetteer/"
            "2024_Gazetteer")
COUNTY_ZIP = "2024_Gaz_counties_national.zip"
TRACT_ZIP = "2024_Gaz_tracts_national.zip"
UA = "trugeo-research/1.0 (census geography; via project repo)"


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


def psql_copy(copy_sql, lines):
    p = subprocess.Popen(
        ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", "-q",
         "-c", copy_sql],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    n = 0
    try:
        for line in lines:
            p.stdin.write(line)
            n += 1
    except BrokenPipeError:
        pass
    try:
        p.stdin.close()
    except BrokenPipeError:
        pass
    err = p.stderr.read()
    rc = p.wait()
    if rc != 0:
        sys.exit(f"copy failed (psql exit {rc}):\n{err.strip()}")
    return n


def fetch_one(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        print(f"  already present, {os.path.getsize(path):,} bytes: "
              f"{os.path.basename(path)}", flush=True)
        return True
    tmp = path + ".part"
    r = subprocess.run(["curl", "-sS", "--fail", "-m", "600", "-A", UA,
                        "-o", tmp, url])
    if r.returncode != 0:
        print(f"  FAILED, curl exit {r.returncode}: {url}", flush=True)
        if os.path.exists(tmp):
            os.unlink(tmp)
        return False
    # VALIDATE IT IS A ZIP BEFORE RENAMING. An HTML error page saved under a
    # .zip name was reported as a successful download earlier in this
    # project and cost a day.
    try:
        with zipfile.ZipFile(tmp) as z:
            names = z.namelist()
    except zipfile.BadZipFile:
        print(f"  FAILED, not a zip. First bytes: "
              f"{open(tmp, 'rb').read(120)!r}", flush=True)
        os.unlink(tmp)
        return False
    os.rename(tmp, path)
    print(f"  ok, {os.path.getsize(path):,} bytes, contains {names}",
          flush=True)
    return True


def cmd_fetch(args):
    os.makedirs(args.dir, exist_ok=True)
    print("Fetching the Census 2024 national gazetteer.")
    print("Measured by HEAD request: counties 141,679 bytes, tracts "
          "2,420,663 bytes.\n")
    ok = True
    for f in (COUNTY_ZIP, TRACT_ZIP):
        ok = fetch_one(f"{GAZ_BASE}/{f}", os.path.join(args.dir, f)) and ok
    return 0 if ok else 1


def read_gazetteer(path):
    """Yield dicts from the gazetteer, keyed by its OWN header.

    The header is tab separated and its last column name carries a long run
    of trailing spaces in the published file, INTPTLONG among them, so every
    name and value is stripped. Reading by position would be shorter and
    would break the first time the Census reorders a column.
    """
    with zipfile.ZipFile(path) as z:
        inner = [n for n in z.namelist() if n.lower().endswith(".txt")]
        if not inner:
            raise ValueError(f"no .txt inside {path}: {z.namelist()}")
        raw = z.open(inner[0]).read().decode("latin-1")
    rdr = csv.reader(io.StringIO(raw), delimiter="\t")
    header = [h.strip() for h in next(rdr)]
    for row in rdr:
        if not row:
            continue
        yield {header[i]: row[i].strip()
               for i in range(min(len(header), len(row)))}


def pick(d, *names):
    """First present, non-empty value among these column names."""
    for n in names:
        if d.get(n):
            return d[n]
    return None


def cmd_load(args):
    cpath = os.path.join(args.dir, COUNTY_ZIP)
    tpath = os.path.join(args.dir, TRACT_ZIP)
    for p in (cpath, tpath):
        if not os.path.exists(p):
            sys.exit(f"missing {p}\nRun fetch first:\n"
                     f"  python3 -u geo/carrier_nodes/coverage_holes.py "
                     f"fetch --dir {args.dir}")

    psql("-qc", """
CREATE TABLE IF NOT EXISTS census_county_tbl (
    county_geoid text PRIMARY KEY,
    state_usps   text NOT NULL,
    name         text,
    aland_sqmi   double precision,
    lat          double precision,
    lon          double precision);
CREATE TABLE IF NOT EXISTS census_tract_tbl (
    tract_geoid  text PRIMARY KEY,
    county_geoid text NOT NULL,
    state_usps   text NOT NULL,
    aland_sqmi   double precision,
    lat          double precision,
    lon          double precision);
CREATE INDEX IF NOT EXISTS census_tract_county_ix
    ON census_tract_tbl (county_geoid);
COMMENT ON TABLE census_county_tbl IS
  'Census 2024 national county gazetteer: internal point and land area. Counties are the unit for the coverage-hole test because a tract is drawn to hold roughly equal population, so rural tracts are enormous and urban ones tiny, and a hole is a statement about square miles.'""")

    def county_lines():
        for d in read_gazetteer(cpath):
            geoid = pick(d, "GEOID")
            lat = pick(d, "INTPTLAT")
            lon = pick(d, "INTPTLONG", "INTPTLON", "INTPTLONG ")
            if not (geoid and lat and lon):
                continue
            yield "\t".join([
                geoid, pick(d, "USPS") or "", pick(d, "NAME") or "",
                pick(d, "ALAND_SQMI") or "0", lat, lon]) + "\n"

    def tract_lines():
        for d in read_gazetteer(tpath):
            geoid = pick(d, "GEOID")
            lat = pick(d, "INTPTLAT")
            lon = pick(d, "INTPTLONG", "INTPTLON")
            if not (geoid and lat and lon) or len(geoid) < 5:
                continue
            yield "\t".join([
                geoid, geoid[:5], pick(d, "USPS") or "",
                pick(d, "ALAND_SQMI") or "0", lat, lon]) + "\n"

    print("loading counties ...", flush=True)
    psql("-qc", "TRUNCATE census_county_tbl")
    n = psql_copy("\\copy census_county_tbl (county_geoid, state_usps, name, "
                  "aland_sqmi, lat, lon) FROM STDIN", county_lines())
    print(f"  {n:,} counties", flush=True)

    print("loading tracts ...", flush=True)
    psql("-qc", "TRUNCATE census_tract_tbl")
    n = psql_copy("\\copy census_tract_tbl (tract_geoid, county_geoid, "
                  "state_usps, aland_sqmi, lat, lon) FROM STDIN",
                  tract_lines())
    print(f"  {n:,} tracts", flush=True)

    print(psql("-c", """
SELECT (SELECT count(*) FROM census_county_tbl) AS counties,
       (SELECT count(*) FROM census_tract_tbl)  AS tracts,
       (SELECT round(sum(aland_sqmi)::numeric) FROM census_county_tbl)
         AS land_sqmi"""))
    return 0


def cmd_holes(args):
    """Distance to the nearest concentration, per county, per threshold."""
    for t in ("census_county_tbl", "itdk_concentration"):
        if psql_q(f"SELECT to_regclass({lit(t)}) IS NOT NULL") != "t":
            sys.exit(f"{t} does not exist.\n"
                     f"  counties: python3 -u "
                     f"geo/carrier_nodes/coverage_holes.py load\n"
                     f"  concentrations: python3 -u "
                     f"geo/carrier_nodes/itdk_geo_load.py concentration")

    where = ["1 = 1"]
    if args.state:
        where.append(f"c.state_usps = {lit(args.state.upper())}")
    # A PLAIN PREDICATE, composed once. The first version built this by
    # slicing a "WHERE ..." string and joining it with a conditional
    # separator, which was unreadable and I could not convince myself it was
    # correct. 'true' when unfiltered costs nothing and the two lateral
    # joins then read identically.
    carrier_pred = "true"
    if args.carrier_like:
        carrier_pred = (f"k.carrier_domain ILIKE "
                        f"{lit(args.carrier_like)}")
    wsql = " AND ".join(where)

    print("Distance from each county's internal point to the nearest "
          "concentration, at two thresholds.\n")
    print("The column that answers the question is rescued_by_singleton: "
          "the nearest two-node concentration is far away but a single-node "
          "one is close, so excluding singletons blinds us to that county.\n")
    if args.carrier_like:
        print(f"Restricted to carrier domains like "
              f"{args.carrier_like!r}.\n")

    # NEAREST NEIGHBOUR BY LATERAL, no index, measured rather than assumed.
    # Counties are about 3,200 and concentrations some thousands, so this is
    # a few million equirectangular evaluations. Equirectangular rather than
    # haversine because at these distances the difference is far below the
    # vendor divergence already being tolerated, and it is cheaper.
    psql("-qc", f"""
CREATE OR REPLACE VIEW county_nearest_site AS
WITH k AS (SELECT * FROM itdk_concentration)
SELECT c.county_geoid, c.state_usps, c.name, c.aland_sqmi,
       n1.km AS km_any, n1.carrier_domain AS carrier_any,
       n1.node_addresses AS nodes_any,
       n2.km AS km_multi, n2.carrier_domain AS carrier_multi,
       n2.node_addresses AS nodes_multi
FROM census_county_tbl c
LEFT JOIN LATERAL (
    SELECT k.carrier_domain, k.node_addresses,
           6371 * sqrt(pow(radians(k.lat - c.lat), 2) +
                       pow(radians(k.lon - c.lon) * cos(radians(c.lat)), 2))
             AS km
    FROM k WHERE {carrier_pred}
    ORDER BY pow(k.lat - c.lat, 2) +
             pow((k.lon - c.lon) * cos(radians(c.lat)), 2)
    LIMIT 1) n1 ON true
LEFT JOIN LATERAL (
    SELECT k.carrier_domain, k.node_addresses,
           6371 * sqrt(pow(radians(k.lat - c.lat), 2) +
                       pow(radians(k.lon - c.lon) * cos(radians(c.lat)), 2))
             AS km
    FROM k WHERE {carrier_pred} AND k.node_addresses >= 2
    ORDER BY pow(k.lat - c.lat, 2) +
             pow((k.lon - c.lon) * cos(radians(c.lat)), 2)
    LIMIT 1) n2 ON true""")

    t0 = time.monotonic()
    print("BY STATE, land area with no multi-node concentration nearby:\n")
    print(psql("-c", f"""
SELECT c.state_usps,
       count(*)                                              AS counties,
       round(sum(c.aland_sqmi)::numeric)                      AS land_sqmi,
       count(*) FILTER (WHERE c.km_multi IS NULL
                          OR c.km_multi > {float(args.far_km)})
                                                              AS counties_far,
       round(coalesce(sum(c.aland_sqmi) FILTER (
             WHERE c.km_multi IS NULL
               OR c.km_multi > {float(args.far_km)}), 0)::numeric)
                                                              AS land_sqmi_far,
       count(*) FILTER (WHERE (c.km_multi IS NULL
                               OR c.km_multi > {float(args.far_km)})
                          AND c.km_any IS NOT NULL
                          AND c.km_any <= {float(args.far_km)})
                                                     AS rescued_by_singleton,
       count(*) FILTER (WHERE c.km_any IS NULL
                          OR c.km_any > {float(args.far_km)})
                                                     AS no_site_at_all
FROM county_nearest_site c
WHERE {wsql}
GROUP BY 1
HAVING count(*) FILTER (WHERE c.km_multi IS NULL
                          OR c.km_multi > {float(args.far_km)}) > 0
ORDER BY land_sqmi_far DESC
LIMIT {int(args.limit)}"""))
    print(f"  ({time.monotonic() - t0:.1f}s)\n")

    print(f"COUNTIES RESCUED BY A SINGLETON, largest first. In these the "
          f"nearest multi-node concentration is beyond {args.far_km:g} km "
          f"but a single-node one is within it, so --min-nodes 2 loses "
          f"them:\n")
    print(psql("-c", f"""
SELECT state_usps, name, round(aland_sqmi::numeric) AS land_sqmi,
       round(km_any::numeric, 1) AS km_to_singleton, carrier_any,
       CASE WHEN km_multi IS NULL THEN NULL
            ELSE round(km_multi::numeric, 1) END AS km_to_multi,
       carrier_multi
FROM county_nearest_site c
WHERE {wsql}
  AND (km_multi IS NULL OR km_multi > {float(args.far_km)})
  AND km_any IS NOT NULL AND km_any <= {float(args.far_km)}
ORDER BY aland_sqmi DESC
LIMIT {int(args.limit)}"""))

    print(f"\nCOUNTIES WITH NO CONCENTRATION WITHIN {args.far_km:g} km AT "
          f"ALL, largest first. No threshold helps here: the ITDK has no "
          f"visibility of whatever serves them:\n")
    print(psql("-c", f"""
SELECT state_usps, name, round(aland_sqmi::numeric) AS land_sqmi,
       CASE WHEN km_any IS NULL THEN NULL
            ELSE round(km_any::numeric, 1) END AS km_to_nearest_any
FROM county_nearest_site c
WHERE {wsql}
  AND (km_any IS NULL OR km_any > {float(args.far_km)})
ORDER BY aland_sqmi DESC
LIMIT {int(args.limit)}"""))
    return 0


def cmd_selftest(args):
    """Parse the real published header, including its trailing whitespace."""
    header = ("USPS\tGEOID\tANSICODE\tNAME\tALAND\tAWATER\tALAND_SQMI\t"
              "AWATER_SQMI\tINTPTLAT\tINTPTLONG" + " " * 118)
    row = ("AL\t01001\t00161526\tAutauga County\t1539631459\t25677536\t"
           "594.455\t9.914\t32.532237\t-86.64644" + " " * 114)
    buf = io.StringIO(header + "\n" + row + "\n")
    rdr = csv.reader(buf, delimiter="\t")
    hdr = [h.strip() for h in next(rdr)]
    vals = next(rdr)
    d = {hdr[i]: vals[i].strip() for i in range(min(len(hdr), len(vals)))}

    bad = 0
    checks = [
        ("last header name stripped", "INTPTLONG" in d,
         "INTPTLONG with trailing spaces must become INTPTLONG"),
        ("geoid", d.get("GEOID") == "01001", d.get("GEOID")),
        ("name", d.get("NAME") == "Autauga County", d.get("NAME")),
        ("land area", d.get("ALAND_SQMI") == "594.455", d.get("ALAND_SQMI")),
        ("lat", d.get("INTPTLAT") == "32.532237", d.get("INTPTLAT")),
        ("lon stripped of trailing spaces",
         d.get("INTPTLONG") == "-86.64644", repr(d.get("INTPTLONG"))),
        ("pick finds the longitude under either spelling",
         pick(d, "INTPTLONG", "INTPTLON") == "-86.64644",
         pick(d, "INTPTLONG", "INTPTLON")),
    ]
    print("Gazetteer parsing, against the real published header and row.")
    print("The published file pads its last column with a long run of "
          "spaces, so an unstripped read puts whitespace inside the "
          "longitude and the column name.\n")
    for label, ok, detail in checks:
        if not ok:
            bad += 1
        print(f"  {'ok  ' if ok else 'FAIL'}  {label}"
              + ("" if ok else f"   got {detail!r}"))
    print()
    if bad:
        print(f"{bad} check(s) failed.")
        return 1
    print("All checks pass.")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download the Census gazetteer")
    f.add_argument("--dir", default="/home/boris/geo/census")
    f.set_defaults(func=cmd_fetch)

    l = sub.add_parser("load", help="load counties and tracts")
    l.add_argument("--dir", default="/home/boris/geo/census")
    l.set_defaults(func=cmd_load)

    h = sub.add_parser("holes",
                       help="large areas with no multi-node concentration")
    h.add_argument("--state", help="restrict to one state, e.g. AK")
    h.add_argument("--carrier-like",
                   help="restrict concentrations to carrier domains matching "
                        "this ILIKE pattern, e.g. '%%coop%%'")
    h.add_argument("--far-km", type=float, default=50.0,
                   help="a concentration beyond this is 'not nearby', "
                        "default 50")
    h.add_argument("--limit", type=int, default=30)
    h.set_defaults(func=cmd_holes)

    s = sub.add_parser("selftest", help="parse the real published header")
    s.set_defaults(func=cmd_selftest)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
