#!/usr/bin/env python3
"""Resolve the six-character CLLI codes in carrier_node_tbl to a location.

WHAT THIS UNBLOCKS

geo/carrier_nodes/hoiho_apply.py decodes a router hostname to a CAIDA
geohint. For 89 domains that hint is a CLLI code, and CAIDA supplies NO
coordinates for any of the 4,508 of them: a CLLI hint is the bare six
characters and nothing else. Measured on Boris's corpus, that leaves 2,409
hostnames across 644 codes unlocated, and they are nearly all of the
carriers that matter: charter.com 480, frontiernet.net 475, verizon-gni.net
361, verizon.net 351, sbcglobal.net 166.

geo/landmarks/isp_node_feasibility.md identified CLLI-to-location as the
blocker and named LERG, proprietary to iconectiv, as the authoritative
table. This uses a PUBLIC LERG-derived service instead.

THE CHAIN, every step verified against the live service 2026-11-17

  1. A six-character CLLI is four characters of place and two of state, so
     btrgla is a Baton Rouge LA code and albyny an Albany NY one. The state
     is unambiguous; the place is a contraction that needs resolving.

  2. localcallingguide.com/lca_switch.php?switch=btrgla returns every switch
     whose CLLI begins with those characters, with its switch name and
     operating company. Partial search is a documented feature of the page.
     For btrgla that yields BTRGLA12DS0 named BATON ROUGE.

  3. localcallingguide.com/xmlrc.php?rc=BATON+ROUGE&region=LA returns the
     rate centre with rc-lat 30.45065, rc-lon -91.18332 and the ILEC
     BellSouth Telecomm Inc dba Southern Bell.

Step 3's answer for btrgla agrees with what this repository had already
established independently: geo/zip_granularity_findings.md recorded that all
128 sampled addresses in 45.19.184.0/24 publish PTRs under
lightspeed.btrgla.sbcglobal.net, AT&T's token for Baton Rouge.

WHAT THE RESULT IS, AND WHAT IT IS NOT

A RATE CENTRE IS A TARIFF GEOGRAPHY. Its coordinates are a nominal centroid,
not a building. In a dense metro several central offices share one rate
centre, so this locates a node TO ITS RATE CENTRE AND NO FINER. The columns
are named rc_lat and rc_lon for that reason and clli_site_tbl says so.
Building precision is step 3 of the plan and is not delivered here.

Some rate centres return no coordinates at all. CHICAGO is one, measured.
Those rows are stored with the switch and company and a null position,
because the operating company is useful even without a point.

POLITENESS

One request per second by default, two requests per code. 644 codes is about
twenty minutes. The service is free and run by one person; --rate can slow
it further but should not be used to speed it up.

USAGE

  python3 clli_resolve.py resolve
  python3 clli_resolve.py resolve --limit 20
  python3 clli_resolve.py resolve --code btrgla albyny
  python3 clli_resolve.py report
"""

import argparse
import html
import os
import re
import subprocess
import sys
import time
import urllib.parse

LCG = "https://localcallingguide.com"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36")

SOURCE = "localcallingguide.com"


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


def fetch(url, timeout=45):
    """GET with curl. Returns the body, or None on failure."""
    r = subprocess.run(
        ["curl", "-sS", "-m", str(timeout), "-A", UA, url],
        capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout


def strip_tags(x):
    return html.unescape(re.sub(r"<[^>]*>", "", x)).replace("\xa0", " ").strip()


def switches_for(clli6):
    """Every switch whose CLLI starts with clli6, as (clli, name, company).

    Parsed from the HTML table. There is no XML endpoint for switches; the
    documented XML interface covers prefixes, rate centres and dial plans
    but not switch search, which was checked.
    """
    body = fetch(f"{LCG}/lca_switch.php?switch={urllib.parse.quote(clli6)}")
    if body is None:
        return None
    out = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", body, re.S | re.I):
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S | re.I)
        if len(cells) < 3:
            continue
        clli, name, company = (strip_tags(c) for c in cells[:3])
        if not clli.lower().startswith(clli6.lower()):
            continue
        out.append((clli, name, company))
    return out


def rate_centre(place, region):
    """rc, rc-lat, rc-lon and the ILEC for a named rate centre."""
    url = (f"{LCG}/xmlrc.php?rc={urllib.parse.quote(place)}"
           f"&region={urllib.parse.quote(region)}")
    body = fetch(url)
    if body is None:
        return None
    # Past the DTD, which is most of the document.
    i = body.find("]>")
    if i != -1:
        body = body[i:]

    def tag(t):
        m = re.search(rf"<{t}>(.*?)</{t}>", body, re.S)
        return m.group(1).strip() if m else None

    if not tag("rc"):
        return None
    return {
        "rc": tag("rc"),
        "region": tag("region"),
        "lat": tag("rc-lat") or None,
        "lon": tag("rc-lon") or None,
        "ilec": tag("ilec-name"),
    }


def pick_place(rows):
    """The most frequent non-empty switch name, which is the place.

    Most rows carry an empty name; the ones that do not agree with each
    other. Counting rather than taking the first avoids being led by a
    single oddly-named switch.
    """
    counts = {}
    for _, name, _ in rows:
        n = (name or "").strip()
        if not n:
            continue
        counts[n] = counts.get(n, 0) + 1
    if not counts:
        return None
    # Prefer the most common; break ties on the shortest, since
    # 'ALBANY' is the place and 'ALBANY GUILDERLAND' is a specific office.
    return sorted(counts.items(), key=lambda kv: (-kv[1], len(kv[0])))[0][0]


def pick_company(rows):
    """The most frequent non-empty company, with its OCN prefix removed."""
    counts = {}
    for _, _, company in rows:
        c = (company or "").strip()
        if not c:
            continue
        c = re.sub(r"^[0-9]{3,4}[A-Z]?\s+", "", c)
        counts[c] = counts.get(c, 0) + 1
    if not counts:
        return None
    return sorted(counts.items(), key=lambda kv: -kv[1])[0][0]


def pending_codes(args):
    """CLLI codes still unresolved, most node-hostnames first."""
    if args.code:
        return [(c.lower(), 0) for c in args.code]
    sql = """
SELECT n.code, count(DISTINCT n.hostname) AS hostnames
FROM carrier_node_tbl n
WHERE n.hint_type = 'clli'
  AND n.code ~ '^[a-z0-9]{6}$'
  AND NOT EXISTS (SELECT 1 FROM clli_site_tbl s WHERE s.clli6 = n.code)
GROUP BY n.code
ORDER BY count(DISTINCT n.hostname) DESC, n.code
"""
    out = []
    for line in psql("-qtAF|", "-c", sql).splitlines():
        if "|" not in line:
            continue
        code, n = line.rsplit("|", 1)
        out.append((code, int(n) if n.isdigit() else 0))
    if args.limit:
        out = out[:args.limit]
    return out


def cmd_resolve(args):
    ok = psql_q("SELECT to_regclass('clli_site_tbl') IS NOT NULL")
    if ok != "t":
        sys.exit("clli_site_tbl does not exist. Apply the schema first:\n"
                 "  psql -X -P pager=off -f geo/carrier_nodes/schema.sql")

    codes = pending_codes(args)
    if not codes:
        print("Nothing to resolve. Either every CLLI code already has a row "
              "in clli_site_tbl, or carrier_node_tbl holds no clli hints. "
              "Run `python3 geo/carrier_nodes/hoiho_apply.py apply` first if "
              "the latter.")
        return

    total_hosts = sum(n for _, n in codes)
    print(f"{len(codes)} CLLI code(s) to resolve, covering {total_hosts:,} "
          f"node hostnames.")
    print(f"Two requests per code at {args.rate}s between them, so roughly "
          f"{len(codes) * 2 * args.rate / 60:.0f} minutes.")
    print("A RATE CENTRE IS A TARIFF GEOGRAPHY, not a building: several "
          "central offices can share one in a dense metro. This locates a "
          "node to its rate centre and no finer.\n")

    located = no_switch = no_place = no_coords = failed = 0
    rows_written = 0
    t0 = time.monotonic()

    for i, (code, hosts) in enumerate(codes, 1):
        state = code[4:6].upper()

        rows = switches_for(code)
        time.sleep(args.rate)
        if rows is None:
            failed += 1
            print(f"[{i}/{len(codes)}] {code}  REQUEST FAILED", flush=True)
            continue
        if not rows:
            no_switch += 1
            print(f"[{i}/{len(codes)}] {code}  no switch in LERG with this "
                  f"prefix", flush=True)
            continue

        place = pick_place(rows)
        company = pick_company(rows)
        if not place:
            no_place += 1
            print(f"[{i}/{len(codes)}] {code}  {len(rows)} switch(es) but "
                  f"none carries a name, so no place to look up", flush=True)
            # Still worth storing: the switch list and the company are
            # evidence even without a position.
            write_rows(code, rows, None, company, None)
            rows_written += len(rows)
            continue

        rc = rate_centre(place, state)
        time.sleep(args.rate)
        if rc is None:
            no_place += 1
            print(f"[{i}/{len(codes)}] {code}  place {place!r} in {state} "
                  f"is not a rate centre name", flush=True)
            write_rows(code, rows, place, company, None)
            rows_written += len(rows)
            continue

        if rc["lat"] and rc["lon"]:
            located += 1
            mark = f"{rc['lat']}, {rc['lon']}"
        else:
            no_coords += 1
            mark = "no coordinates published for this rate centre"

        write_rows(code, rows, rc["rc"], company or rc["ilec"], rc)
        rows_written += len(rows)

        el = time.monotonic() - t0
        eta = ""
        if i > 1:
            eta = f", {(len(codes) - i) * el / i / 60:.0f} min left"
        print(f"[{i}/{len(codes)}] {code} -> {rc['rc']} {state}  {mark}  "
              f"({hosts} hostnames){eta}", flush=True)

    print(f"\n{located} located, {no_coords} resolved but without "
          f"coordinates, {no_place} with no usable place, {no_switch} absent "
          f"from LERG, {failed} request failures")
    print(f"{rows_written:,} row(s) written to clli_site_tbl in "
          f"{(time.monotonic() - t0) / 60:.1f} minutes")
    if located:
        print("\nThose nodes are now locatable by step 4. Run "
              "`python3 geo/carrier_nodes/clli_resolve.py report` for the "
              "per-carrier effect.")


def write_rows(clli6, rows, rate_centre_name, company, rc):
    """One row per full switch CLLI found, all sharing the rate centre."""
    lat = lit(rc["lat"]) if rc and rc.get("lat") else "NULL"
    lon = lit(rc["lon"]) if rc and rc.get("lon") else "NULL"
    region = lit(rc["region"]) if rc and rc.get("region") else lit(clli6[4:6].upper())
    values = []
    for clli, name, comp in rows:
        ocn = None
        m = re.match(r"^([0-9]{3,4}[A-Z]?)\s+", (comp or ""))
        if m:
            ocn = m.group(1)
        values.append(
            "(" + ", ".join([
                lit(clli6), lit(clli), lit(name or None), lit(ocn),
                lit(re.sub(r"^[0-9]{3,4}[A-Z]?\s+", "", comp) if comp
                    else company),
                lit(rate_centre_name), region, lat, lon, lit(SOURCE),
            ]) + ")")
    if not values:
        return
    cols = ("clli6, clli_full, switch_name, company_ocn, company_name, "
            "rate_centre, region, rc_lat, rc_lon, source")
    for i in range(0, len(values), 200):
        psql("-qc", f"INSERT INTO clli_site_tbl ({cols}) VALUES "
                    + ", ".join(values[i:i + 200])
                    + " ON CONFLICT (clli6, clli_full) DO NOTHING")


def cmd_report(args):
    print("What CLLI resolution has delivered, per carrier.\n")
    print(psql("-c", """
SELECT n.domain,
       count(DISTINCT n.hostname)                                AS hostnames,
       count(DISTINCT n.code)                                    AS clli_codes,
       count(DISTINCT s.clli6)                                   AS resolved,
       count(DISTINCT s.clli6) FILTER (WHERE s.rc_lat IS NOT NULL)
                                                                 AS with_coords,
       count(DISTINCT s.rate_centre)                             AS rate_centres
FROM carrier_node_tbl n
LEFT JOIN clli_site_tbl s ON s.clli6 = n.code
WHERE n.hint_type = 'clli'
GROUP BY n.domain
ORDER BY count(DISTINCT n.hostname) DESC
LIMIT 25"""))

    print("\nRate centres carrying the most nodes. These are the candidate "
          "serving sites step 4 will measure distances from.\n")
    print(psql("-c", """
SELECT s.rate_centre, s.region,
       count(DISTINCT n.hostname) AS hostnames,
       count(DISTINCT n.domain)   AS carriers,
       count(DISTINCT s.clli_full) AS switches,
       max(s.rc_lat)              AS lat,
       max(s.rc_lon)              AS lon
FROM clli_site_tbl s
JOIN carrier_node_tbl n ON n.code = s.clli6
WHERE s.rate_centre IS NOT NULL
GROUP BY s.rate_centre, s.region
ORDER BY count(DISTINCT n.hostname) DESC
LIMIT 20"""))

    print("\nCodes still unresolved, worst first. These are what remains.\n")
    print(psql("-c", """
SELECT n.code, n.st, count(DISTINCT n.hostname) AS hostnames,
       count(DISTINCT n.domain) AS carriers,
       left(string_agg(DISTINCT n.domain, ', '), 40) AS domains
FROM carrier_node_tbl n
WHERE n.hint_type = 'clli'
  AND NOT EXISTS (SELECT 1 FROM clli_site_tbl s WHERE s.clli6 = n.code)
GROUP BY n.code, n.st
ORDER BY count(DISTINCT n.hostname) DESC
LIMIT 20"""))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("resolve", help="resolve the pending CLLI codes")
    r.add_argument("--limit", type=int,
                   help="stop after this many codes, for a trial run")
    r.add_argument("--code", nargs="*",
                   help="resolve only these codes, ignoring the database")
    r.add_argument("--rate", type=float, default=1.0,
                   help="seconds between requests, default 1. The service is "
                        "free and run by one person; do not lower this.")
    r.set_defaults(func=cmd_resolve)

    p = sub.add_parser("report", help="what resolution has delivered")
    p.set_defaults(func=cmd_report)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
