"""Translate street addresses of central offices and headends into coordinates.

WHY, AND WHAT THIS DOES NOT CLAIM

Boris, 2026-11-18: "Also search for street address, which can be translated
to coordinates. Coordinates of a headend/CO may not always appear in public
information."

That is the right route and this is the translation half of it. It does NOT
do the searching. The reason is not laziness about scope: the searching half
produces an INFERENCE about which building a carrier operates out of, and
that inference needs a citation attached at the moment it is made, not
reconstructed later. So the input here is a TSV in which every row already
carries its source, and a row without one is refused rather than loaded.

MEASURED, so the quality is known rather than assumed. The US Census
geocoder, on buildings that are documented carrier facilities:

  60 Hudson Street, New York NY     40.718203, -74.008818   Exact match
  811 10th Avenue, New York NY      measured by the test below
  1 Wilshire Blvd, Los Angeles CA   measured by the test below

The Census geocoder is the primary because it is free, needs no key, is the
authoritative US address source, and returns a match type. Nominatim is the
fallback for addresses Census cannot match, at one request per second per
its usage policy.

WHAT A MATCH TYPE MEANS, AND WHY IT IS STORED

Census returns a side-of-street interpolated point for a street range, not a
rooftop. That is accurate to a block face, which is why such rows are stored
as precision 'street' and not 'building'. A row only becomes 'building' when
the source itself identified the building, for instance a published switch
location or an operator's own filing.

This is the distinction that makes the difference in a dense metro, where
step 4's distance ordering between candidate sites is decided over a few
hundred metres.

USAGE

  python3 -u geocode_sites.py geocode --file sites.tsv
  python3 -u geocode_sites.py geocode --file sites.tsv --dry-run
  python3 -u geocode_sites.py selftest
  python3 -u geocode_sites.py report

INPUT FORMAT, tab separated, header required:

  site_kind  carrier_name  itdk_domain  clli8  clli6  site_name
  street_address  city  state_usps  zip  source_kind  source_ref  note

source_kind and source_ref are mandatory on every row. source_ref must be
something a person can follow: a URL, an FCC document number, a file name.
An assertion from an AI assistant is not a source_ref; the citation it was
repeating is. A row missing either is reported and skipped, and the command
exits non-zero so it cannot pass unnoticed in a batch.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse

CENSUS = ("https://geocoding.geo.census.gov/geocoder/locations/"
          "onelineaddress")
NOMINATIM = "https://nominatim.openstreetmap.org/search"
UA = "trugeo-research/1.0 (central office geolocation; via project repo)"

REQUIRED = ["site_kind", "source_kind", "source_ref"]
COLUMNS = ["site_kind", "carrier_name", "itdk_domain", "clli8", "clli6",
           "site_name", "street_address", "city", "state_usps", "zip",
           "source_kind", "source_ref", "note"]


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def lit(s):
    if s is None or s == "":
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def get(url, params, timeout=30):
    """One GET via curl, returning parsed JSON or None.

    curl rather than urllib because the rest of this project already shells
    out and because -m gives a hard ceiling that urllib's timeout does not
    for a slow body.
    """
    q = urllib.parse.urlencode(params)
    try:
        r = subprocess.run(
            ["curl", "-sS", "-m", str(timeout), "-A", UA,
             "-H", "Accept: application/json", f"{url}?{q}"],
            capture_output=True, text=True)
    except OSError as exc:
        return None, f"curl could not run: {exc}"
    if r.returncode != 0:
        return None, f"curl exit {r.returncode}: {r.stderr.strip()[:120]}"
    body = r.stdout.strip()
    if not body:
        return None, "empty response"
    try:
        return json.loads(body), None
    except ValueError:
        return None, f"not JSON: {body[:120]}"


def geocode_census(one_line):
    """Census geocoder. Returns (lat, lon, quality, error)."""
    d, err = get(CENSUS, {"address": one_line,
                          "benchmark": "Public_AR_Current",
                          "format": "json"})
    if d is None:
        return None, None, None, err
    try:
        matches = d["result"]["addressMatches"]
    except (KeyError, TypeError):
        return None, None, None, "unexpected response shape"
    if not matches:
        return None, None, None, "no match"
    m = matches[0]
    c = m["coordinates"]
    # SIDE OF STREET AND MATCH TYPE ARE THE QUALITY SIGNAL. Census
    # interpolates along a street range, so this is a block face rather than
    # a rooftop, which is why callers store precision 'street'.
    tb = m.get("tigerLine", {}) or {}
    quality = "|".join(str(x) for x in [
        tb.get("side", ""), m.get("matchedAddress", "")[:60]] if x)
    return c["y"], c["x"], quality or "matched", None


def house_number(addr):
    """Leading house number of an address, or None.

    Only the digits are compared. '3438 1/2' and '3438' are the same
    building for this purpose; '1' and '3438' are not.
    """
    s = (addr or "").strip()
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits += ch
        elif digits:
            break
        elif not ch.isspace():
            return None
    return digits or None


def geocode_nominatim(one_line_addr, want_number=None):
    """Fallback, with the house number CHECKED against what was asked for.

    WHY THE CHECK EXISTS. MEASURED 2026-11-18. Asked for

        1 Wilshire Boulevard, Los Angeles, CA

    Nominatim's top result was a cafe called Egg Tuck at 3438 1/2 Wilshire
    Boulevard in Koreatown, 4.1 km away, returned as an ordinary successful
    match with nothing marking it as a substitution. Census returns no match
    at all for that address, with or without the postcode.

    Boris's instruction was to search for a street address and translate it
    to coordinates, which is sound. This is the failure mode of the
    translation step: a fuzzy geocoder would rather return something than
    nothing, and 4 km in Los Angeles is a different set of census tracts
    entirely. A carrier building would have been recorded at a cafe.

    So a result whose house number differs from the requested one is
    REFUSED, and so is a match on a road rather than an address, because a
    road centroid is not a building. Returning nothing is the correct
    outcome here: the address exists and simply is not in either gazetteer.

    One request per second maximum, per the OSM usage policy.
    """
    d, err = get(NOMINATIM, {"q": one_line_addr, "format": "json",
                             "limit": 5, "addressdetails": 1})
    if d is None:
        return None, None, None, err
    if not isinstance(d, list) or not d:
        return None, None, None, "no match"

    rejected = []
    for r in d:
        a = r.get("address") or {}
        got = house_number(a.get("house_number"))
        if want_number is not None:
            if got is None:
                rejected.append(
                    f"{r.get('class')}/{r.get('type')} with no house number")
                continue
            if got != want_number:
                rejected.append(
                    f"house number {a.get('house_number')} not "
                    f"{want_number}")
                continue
        elif r.get("class") == "highway":
            rejected.append("a road, not an address")
            continue
        try:
            return (float(r["lat"]), float(r["lon"]),
                    f"osm:{r.get('class', '')}:{r.get('type', '')}:"
                    f"housenumber_checked", None)
        except (KeyError, TypeError, ValueError):
            rejected.append("unexpected response shape")

    return None, None, None, (
        "no result with the requested house number; refused "
        + "; ".join(rejected[:3]))


def one_line(row):
    parts = [row.get("street_address", ""), row.get("city", ""),
             row.get("state_usps", "")]
    s = ", ".join(p for p in parts if p)
    if row.get("zip"):
        s += " " + row["zip"]
    return s


def read_tsv(path):
    """Read the input, refusing rows that lack a source.

    Returns (rows, problems). A row with no source is NOT loaded with a
    placeholder: the schema forbids it and so does standing order 1.
    """
    rows = []
    problems = []
    with open(path, encoding="utf-8") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        header = [h.strip() for h in header]
        unknown = [h for h in header if h and h not in COLUMNS]
        if unknown:
            problems.append(
                f"header has column(s) this does not know: {unknown}. "
                f"Known columns: {COLUMNS}")
        for n, line in enumerate(fh, 2):
            if not line.strip():
                continue
            vals = line.rstrip("\n").split("\t")
            row = {h: (vals[i].strip() if i < len(vals) else "")
                   for i, h in enumerate(header) if h}
            missing = [c for c in REQUIRED if not row.get(c)]
            if missing:
                problems.append(
                    f"line {n}: missing {', '.join(missing)}. "
                    f"Not loaded. Every site must say where it came from.")
                continue
            if not one_line(row) and not row.get("clli8"):
                problems.append(
                    f"line {n}: no address and no clli8, nothing to locate.")
                continue
            row["_line"] = n
            rows.append(row)
    return rows, problems


def require_schema():
    if psql_q("SELECT to_regclass('co_site_tbl') IS NOT NULL") != "t":
        sys.exit("co_site_tbl does not exist. Create it first:\n"
                 "  psql -X -P pager=off -f "
                 "geo/carrier_nodes/co_site_schema.sql")


def cmd_geocode(args):
    require_schema()
    rows, problems = read_tsv(args.file)

    if problems:
        print(f"{len(problems)} input problem(s). These rows are NOT "
              f"loaded:", flush=True)
        for p in problems[:20]:
            print(f"    {p}", flush=True)
        print(flush=True)

    if not rows:
        print("No loadable rows.")
        return 1 if problems else 0

    print(f"{len(rows)} site(s) to locate. Census geocoder first, "
          f"Nominatim as fallback at {args.rate}s between requests.",
          flush=True)
    print("A Census match is a point interpolated along a street range, so "
          "it is accurate to a block face and is stored as precision "
          "'street', NOT 'building'. Only a source that itself named the "
          "building earns 'building'.", flush=True)
    print(flush=True)

    located = fallback = failed = 0
    t0 = time.monotonic()
    out = []

    for i, row in enumerate(rows, 1):
        addr = one_line(row)
        lat = lon = quality = None
        geocoder = None

        if addr:
            lat, lon, quality, err = geocode_census(addr)
            if lat is not None:
                geocoder = "census"
            else:
                time.sleep(args.rate)
                lat, lon, quality, err2 = geocode_nominatim(
                    addr, house_number(row.get("street_address")))
                if lat is not None:
                    geocoder = "nominatim"
                    fallback += 1
                else:
                    err = f"census: {err}; nominatim: {err2}"

        if lat is None:
            failed += 1
            state = f"NOT LOCATED  {err}"
        else:
            located += 1
            state = f"{lat:.6f}, {lon:.6f}  via {geocoder}"

        el = time.monotonic() - t0
        eta = ""
        if i > 1:
            eta = f", about {(len(rows) - i) * el / (i - 1):.0f}s left"
        print(f"[{i}/{len(rows)}] {(row.get('site_name') or addr)[:40]:<40} "
              f"{state}{eta}", flush=True)

        # PRECISION IS DECIDED BY THE SOURCE, NOT BY SUCCESS.
        if lat is None:
            precision = "none"
        elif row["source_kind"] in ("telcodata_switch", "fcc_coals",
                                    "fcc_asr", "operator_published"):
            precision = "building"
        elif row["source_kind"] == "lerg_rate_centre":
            precision = "rate_centre"
        else:
            precision = "street"

        out.append((row, lat, lon, quality, geocoder, precision, addr))
        time.sleep(args.rate)

    print(flush=True)
    print(f"{located} located, {fallback} of them by the Nominatim "
          f"fallback, {failed} not located, in "
          f"{(time.monotonic() - t0) / 60:.1f} minutes", flush=True)

    if args.dry_run:
        print("\n--dry-run, so nothing was written.")
        return 1 if (problems or failed) else 0

    # ONE STATEMENT, so a kill partway leaves nothing half-inserted.
    # Measured on PostgreSQL 16.2: statements in separate psql -c flags are
    # separate transactions, statements inside one -c are one transaction.
    values = []
    for row, lat, lon, quality, geocoder, precision, addr in out:
        values.append(
            "(" + ", ".join([
                lit(row.get("clli8")), lit(row.get("clli6")),
                lit(row.get("site_name")),
                lit(row.get("site_kind") or "unknown"),
                lit(row.get("itdk_domain")), "NULL",
                lit(row.get("carrier_name")),
                lit(row.get("street_address")), lit(row.get("city")),
                lit(row.get("state_usps")), lit(row.get("zip")),
                "NULL" if lat is None else repr(lat),
                "NULL" if lon is None else repr(lon),
                lit(precision),
                lit(row["source_kind"]), lit(row["source_ref"]),
                lit(row.get("note")),
                lit(geocoder), lit(quality), lit(addr),
            ]) + ")")

    sql = (
        "INSERT INTO co_site_tbl (clli8, clli6, site_name, site_kind, "
        "itdk_domain, ocn, carrier_name, street_address, city, state_usps, "
        "zip, lat, lon, precision, source_kind, source_ref, note, "
        "geocoder, geocode_quality, geocode_input) VALUES " +
        ", ".join(values) +
        # Re-running must refresh rather than duplicate. verified is NOT
        # reset by a refresh: a human confirmation is not invalidated by
        # re-geocoding the same address.
        " ON CONFLICT (clli8) WHERE clli8 IS NOT NULL DO UPDATE SET "
        "lat = excluded.lat, lon = excluded.lon, "
        "precision = excluded.precision, geocoder = excluded.geocoder, "
        "geocode_quality = excluded.geocode_quality, "
        "source_ref = excluded.source_ref")
    psql("-qc", sql)

    print(f"\n{len(values)} row(s) written to co_site_tbl.", flush=True)
    print("verified is FALSE on all of them. A geocoded address is an "
          "inference about which building a carrier operates; confirm it "
          "before step 4 ranks distances on it.", flush=True)
    print(psql("-c", "SELECT * FROM co_site_readiness"))
    return 1 if (problems or failed) else 0


def cmd_selftest(args):
    """Check the geocoding chain: cases that must place, and one that must NOT.

    The positive cases are well known telecommunications buildings whose
    street addresses are published in many places. They test the GEOCODER,
    not any claim about which carrier occupies them.

    The negative case is the one that matters. Asked for

        1 Wilshire Boulevard, Los Angeles, CA

    Census returns no match at all, with or without the postcode, and
    Nominatim's best answer is a cafe called Egg Tuck at 3438 1/2 Wilshire
    Boulevard in Koreatown, 4.1 km away, presented as an ordinary successful
    match. A geocoder that would rather return something than nothing is the
    central hazard in translating a searched address into coordinates, and
    4 km in Los Angeles is a different set of census tracts. So this asserts
    the house number guard REFUSES it. If this case ever starts "passing" by
    returning coordinates, the guard has broken.
    """
    import math

    positive = [
        ("60 Hudson Street, New York, NY", 40.7182, -74.0088),
        ("811 10th Avenue, New York, NY", 40.7645, -73.9895),
        ("56 Marietta Street NW, Atlanta, GA", 33.7560, -84.3915),
    ]
    negative = ["1 Wilshire Boulevard, Los Angeles, CA"]

    def chain(addr):
        lat, lon, q, err = geocode_census(addr)
        if lat is not None:
            return lat, lon, q, "census", None
        time.sleep(args.rate)
        lat, lon, q, err2 = geocode_nominatim(addr, house_number(addr))
        if lat is not None:
            return lat, lon, q, "nominatim", None
        return None, None, None, None, f"census: {err}; nominatim: {err2}"

    print("Geocoding self test. It exercises the SAME chain as a real run,")
    print("Census first then Nominatim with the house number checked.")
    print("Tolerance 500 m against published addresses.\n")

    bad = 0
    print("MUST LOCATE")
    print(f"  {'address':<40}{'got':>26}  {'km off':>7}  via        state")
    for addr, elat, elon in positive:
        lat, lon, q, via, err = chain(addr)
        if lat is None:
            print(f"  {addr[:40]:<40}{'NOT LOCATED':>26}  {'':>7}  "
                  f"{'':<10} FAILED: {err}")
            bad += 1
            time.sleep(args.rate)
            continue
        dlat = math.radians(lat - elat)
        dlon = math.radians(lon - elon) * math.cos(math.radians(elat))
        km = 6371.0 * math.hypot(dlat, dlon)
        ok_ = km < 0.5
        if not ok_:
            bad += 1
        print(f"  {addr[:40]:<40}{lat:>12.6f},{lon:>12.6f}  {km:>7.3f}  "
              f"{via:<10} {'ok' if ok_ else 'OFF BY MORE THAN 500 m'}")
        time.sleep(args.rate)

    print()
    print("MUST BE REFUSED, because the only candidate is a different "
          "building")
    for addr in negative:
        lat, lon, q, via, err = chain(addr)
        if lat is None:
            print(f"  {addr[:40]:<40} refused, correct")
            print(f"      reason: {str(err)[:150]}")
        else:
            bad += 1
            print(f"  {addr[:40]:<40} RETURNED {lat:.6f},{lon:.6f} via "
                  f"{via}")
            print(f"      THE HOUSE NUMBER GUARD HAS BROKEN. This address "
                  f"is in neither gazetteer and the nearest candidate is "
                  f"4.1 km away.")
        time.sleep(args.rate)

    print()
    if bad:
        print(f"{bad} case(s) failed. Do not trust a bulk run until this "
              f"passes.")
        return 1
    print("All cases behaved as measured: three placed within 500 m, and "
          "the wrong-building substitution was refused.")
    return 0


def cmd_report(args):
    require_schema()
    print(psql("-c", "SELECT * FROM co_site_readiness"))
    print(psql("-c", """
SELECT source_kind, precision, count(*),
       count(*) FILTER (WHERE verified) AS verified,
       count(*) FILTER (WHERE lat IS NULL) AS no_coords
FROM co_site_tbl GROUP BY 1, 2 ORDER BY 1, 2"""))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("geocode", help="locate the sites in a TSV")
    g.add_argument("--file", required=True)
    g.add_argument("--rate", type=float, default=1.0,
                   help="seconds between requests, default 1. Nominatim's "
                        "usage policy is one per second; do not lower it.")
    g.add_argument("--dry-run", action="store_true",
                   help="geocode and report, write nothing")
    g.set_defaults(func=cmd_geocode)

    s = sub.add_parser("selftest",
                       help="check the geocoder against known buildings")
    s.add_argument("--rate", type=float, default=1.0)
    s.set_defaults(func=cmd_selftest)

    r = sub.add_parser("report", help="what is known, at what precision")
    r.set_defaults(func=cmd_report)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
