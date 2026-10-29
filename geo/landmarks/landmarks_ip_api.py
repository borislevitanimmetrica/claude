#!/usr/bin/env python3
"""
Probe landmark addresses against ip-api.com and compare its ZIP with ours.

This is the independent check on the whole pipeline. We derive a landmark's ZIP
from its Overture/Foursquare/OSM street address; ip-api derives a ZIP from its
own geolocation of the IP. Where they agree, two unrelated methods agree. Where
they disagree, at least one is wrong and the breakdown says which is likelier.

IT USES THE /batch ENDPOINT, AND THAT MATTERS FOR TWO REASONS.

1. Throughput. /batch takes 100 addresses per request at 15 requests a minute,
   so 1,500 addresses a minute against 45 for the single-IP endpoint, a 33-fold
   difference. Roughly 28,000 landmark addresses therefore take about 20
   minutes rather than 10 hours.

2. It does NOT contend with the production pipeline. check_geo_ip-api and
   probe_batch spend the single-endpoint budget, and that budget is nearly
   fully committed: 2,400 ranges an hour at 45 a minute occupies about 53
   minutes of every hour. Measured 2026-10-26, the two endpoints have SEPARATE
   buckets: one /batch call and one /json call made seconds apart reported
   X-Rl 12 and X-Rl 44 respectively. So this tool can run while probe_batch
   runs. Verify with -check-budget before a long run rather than trusting this
   paragraph.

   Note the source comment in check_geo_ip-api saying batch is paid-only is out
   of date. /batch answered HTTP 200 unauthenticated, with 100 addresses
   accepted and 101 refused as HTTP 422.

ip-api THROTTLES BY STALLING, not by answering 429, which check_geo_ip-api
documents from 60 observed calls. A timeout is therefore treated as a rate
signal and backs off, not as a transport error to retry immediately.

Only DISTINCT addresses are probed, not places. 122,110 on-premises places sit
on far fewer addresses, and probing a place rather than an address would pay for
the same answer repeatedly.

Database access is via psql only, standard library otherwise, so it uses the
same connection as your psql.

Usage:
    python3 landmarks_ip_api.py create                 create the result table
    python3 landmarks_ip_api.py check-budget           one call, report headers
    python3 landmarks_ip_api.py probe                  probe on-premises landmarks
    python3 landmarks_ip_api.py probe --zip-prefix 021 Boston only
    python3 landmarks_ip_api.py compare                agreement report

Attribution: ip-api.com free tier, non-commercial use. Check their terms before
using these results in a commercial product.
"""

import argparse
import csv
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BATCH_URL = ("http://ip-api.com/batch?fields=status,message,country,regionName,"
             "city,zip,isp,org,as,mobile,hosting,query")
SINGLE_URL = "http://ip-api.com/json/8.8.8.8?fields=status,zip"

# Measured, not assumed: 100 accepted, 101 refused with HTTP 422.
MAX_BATCH = 100
# X-Rl counted down from 15 on /batch, and X-Ttl was 60, so 15 requests a
# minute. 4.2s between requests leaves a small margin under 4.0s exactly.
REQUEST_GAP = 4.2

COLUMNS = ["ip", "status", "message", "country", "region_name", "city", "zip",
           "isp", "org", "as_name", "mobile", "hosting"]


def psql(*args, stdin=None):
    try:
        r = subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", *args],
                           input=stdin, capture_output=True, text=True, check=True)
        return r.stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or exc
        sys.exit(f"psql failed: {detail}")


def cmd_create(args):
    psql("-q", "-c", """
CREATE TABLE IF NOT EXISTS landmarks_usa_ip_api (
    ip           inet PRIMARY KEY,
    status       text,
    message      text,
    country      text,
    region_name  text,
    city         text,
    zip          text,
    isp          text,
    org          text,
    as_name      text,
    mobile       boolean,
    hosting      boolean,
    probed_at    timestamptz NOT NULL DEFAULT now()
)""")
    psql("-q", "-c", "CREATE INDEX IF NOT EXISTS landmarks_usa_ip_api_zip_idx "
                     "ON landmarks_usa_ip_api (zip)")
    print("landmarks_usa_ip_api ready.")


def targets(args):
    """Distinct on-premises landmark addresses not yet probed.

    Hosting addresses are excluded by default and the reason is not tidiness.
    An address serving disjoint ZIP clusters is a web host, so ip-api will
    report the HOST's location while our ZIP reports the TENANT's. Counting
    that as a disagreement would blame the pipeline for a mismatch that is
    actually correct on both sides, and would swamp the real signal.
    """
    where = ["l.onpremises IS TRUE", "l.overture_zip ~ '^[0-9]{5}$'",
             "l.ip_address IS NOT NULL"]
    if args.zip_prefix:
        where.append(f"l.overture_zip LIKE '{args.zip_prefix}%'")
    if args.source:
        srcs = ", ".join("'" + s.strip().replace("'", "''") + "'"
                         for s in args.source.split(","))
        where.append(f"l.source IN ({srcs})")

    exclude = ""
    if not args.include_hosting:
        exclude = """
  AND NOT EXISTS (SELECT 1 FROM address_hosting_tbl h
                  WHERE host(h.ip_address) = host(l.ip_address)
                    AND h.verdict LIKE 'hosting%')"""

    sql = f"""
SELECT DISTINCT host(l.ip_address)
FROM landmarks_usa l
WHERE {' AND '.join(where)}{exclude}
  AND NOT EXISTS (SELECT 1 FROM landmarks_usa_ip_api a
                  WHERE a.ip = l.ip_address)
ORDER BY 1"""
    out = psql("-qtA", "-c", sql)
    return [x for x in (line.strip() for line in out.splitlines()) if x]


def post_batch(ips, timeout, max_backoff):
    """One /batch call. Returns (results, headers) or ({"__error__":...}, None)."""
    body = json.dumps([{"query": ip} for ip in ips]).encode()
    req = urllib.request.Request(
        BATCH_URL, data=body,
        headers={"Content-Type": "application/json",
                 "User-Agent": "trugeo-landmark-verify/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace")), dict(r.headers)
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            ttl = exc.headers.get("X-Ttl") if exc.headers else None
            try:
                wait = min(int(ttl), max_backoff)
            except (TypeError, ValueError):
                wait = min(60, max_backoff)
            print(f"    HTTP 429, X-Ttl {ttl}, sleeping {wait}s", flush=True)
            time.sleep(wait)
            return {"__error__": "429"}, None
        return {"__error__": f"HTTP {exc.code} {exc.reason}"}, None
    except OSError as exc:
        # A stall IS the throttle. Back off rather than hammering.
        print(f"    stalled ({exc}); this is how ip-api throttles, "
              f"backing off {REQUEST_GAP * 4:.0f}s", flush=True)
        time.sleep(REQUEST_GAP * 4)
        return {"__error__": f"stalled: {exc}"}, None


def store(rows):
    if not rows:
        return
    buf = io.StringIO()
    w = csv.writer(buf, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
    for r in rows:
        w.writerow(r)
    cols = ", ".join(COLUMNS)
    updates = ", ".join(f"{c} = EXCLUDED.{c}" for c in COLUMNS if c != "ip")
    fd, path = tempfile.mkstemp(prefix="lm_ipapi_", suffix=".csv")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(buf.getvalue())
        psql("-q", "-f", "-", stdin=(
            "BEGIN;\n"
            # INCLUDING DEFAULTS is required, not cosmetic: plain LIKE copies
            # the NOT NULL on probed_at but NOT its DEFAULT now(), so the COPY
            # fails on a null probed_at that the real table would have filled.
            "CREATE TEMP TABLE s (LIKE landmarks_usa_ip_api INCLUDING DEFAULTS)"
            " ON COMMIT DROP;\n"
            f"\\copy s ({cols}) FROM '{path}' WITH (FORMAT csv)\n"
            f"INSERT INTO landmarks_usa_ip_api ({cols})\n"
            f"SELECT {cols} FROM s\n"
            f"ON CONFLICT (ip) DO UPDATE SET {updates}, probed_at = now();\n"
            "COMMIT;\n"))
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def cmd_check_budget(args):
    print("One /batch call and one /json call, to show the two buckets:")
    res, hdr = post_batch(["8.8.8.8"], args.timeout, args.max_backoff)
    if hdr:
        print(f"  /batch  X-Rl={hdr.get('X-Rl')}  X-Ttl={hdr.get('X-Ttl')}")
    else:
        print(f"  /batch  FAILED: {res.get('__error__')}")
    try:
        req = urllib.request.Request(
            SINGLE_URL, headers={"User-Agent": "trugeo-landmark-verify/1.0"})
        with urllib.request.urlopen(req, timeout=args.timeout) as r:
            print(f"  /json   X-Rl={r.headers.get('X-Rl')}  "
                  f"X-Ttl={r.headers.get('X-Ttl')}")
    except (urllib.error.HTTPError, OSError) as exc:
        print(f"  /json   FAILED: {exc}")
    print("\nIf the two X-Rl values are far apart the buckets are separate, and "
          "this tool\nwill not consume probe_batch's single-endpoint budget.")


def cmd_probe(args):
    todo = targets(args)
    if not todo:
        print("Nothing to probe. Every selected address already has a result.")
        return
    batches = (len(todo) + MAX_BATCH - 1) // MAX_BATCH
    eta = batches * REQUEST_GAP / 60.0
    print(f"{len(todo):,} addresses in {batches:,} batches of up to {MAX_BATCH}; "
          f"about {eta:.0f} min at {60 / REQUEST_GAP:.0f} requests a minute")
    if args.dry_run:
        return

    started = time.monotonic()
    done = ok = 0
    for i in range(0, len(todo), MAX_BATCH):
        if args.deadline_minutes and \
                (time.monotonic() - started) / 60.0 >= args.deadline_minutes:
            print(f"  deadline of {args.deadline_minutes} min reached; "
                  f"stopping with {done:,} probed. Re-run to continue.")
            break
        chunk = todo[i:i + MAX_BATCH]
        t0 = time.monotonic()
        res, hdr = post_batch(chunk, args.timeout, args.max_backoff)
        if isinstance(res, dict) and "__error__" in res:
            print(f"  batch at {i:,} failed ({res['__error__']}); retrying once")
            res, hdr = post_batch(chunk, args.timeout, args.max_backoff)
            if isinstance(res, dict) and "__error__" in res:
                print(f"  batch at {i:,} failed again; skipping it")
                continue
        rows = []
        for item in res:
            if not isinstance(item, dict):
                continue
            rows.append([
                item.get("query"), item.get("status"), item.get("message"),
                item.get("country"), item.get("regionName"), item.get("city"),
                item.get("zip"), item.get("isp"), item.get("org"),
                item.get("as"),
                "" if item.get("mobile") is None else ("t" if item["mobile"] else "f"),
                "" if item.get("hosting") is None else ("t" if item["hosting"] else "f"),
            ])
        store(rows)
        done += len(chunk)
        ok += sum(1 for r in rows if r[1] == "success")
        if (i // MAX_BATCH) % 10 == 0 or done >= len(todo):
            rl = hdr.get("X-Rl") if hdr else "?"
            print(f"  {done:,}/{len(todo):,} probed, {ok:,} success, "
                  f"X-Rl={rl}, {time.monotonic() - started:.0f}s", flush=True)
        gap = REQUEST_GAP - (time.monotonic() - t0)
        if gap > 0:
            time.sleep(gap)
    print(f"Probed {done:,} addresses, {ok:,} returned success.")


def cmd_compare(args):
    """Agreement between our ZIP and ip-api's, graded by distance.

    Graded rather than a single accuracy number because the failure modes are
    not equivalent: an adjacent ZIP is a near miss that still targets the right
    neighbourhood, while a different state is a real error.
    """
    print(psql("-c", """
SELECT CASE
         WHEN a.status <> 'success'              THEN '0 ip-api had no answer'
         WHEN a.zip IS NULL OR a.zip = ''        THEN '1 ip-api returned no ZIP'
         WHEN left(a.zip,5) = l.overture_zip     THEN '2 exact ZIP match'
         WHEN EXISTS (SELECT 1 FROM zip_adj_sym s
                      WHERE s.a = l.overture_zip AND s.b = left(a.zip,5))
                                                 THEN '3 adjacent ZIP'
         WHEN left(a.zip,3) = left(l.overture_zip,3)
                                                 THEN '4 same ZIP3'
         WHEN a.region_name IS NOT NULL AND l.region IS NOT NULL
              AND upper(left(a.region_name,2)) = upper(left(l.region,2))
                                                 THEN '5 same state (rough)'
         ELSE                                         '6 different place'
       END                                                        AS agreement,
       count(*)                                                   AS addresses,
       round(100.0 * count(*) / nullif(sum(count(*)) OVER (), 0), 1) AS pct
FROM landmarks_usa_ip_api a
JOIN (SELECT DISTINCT host(ip_address) AS ip, overture_zip, region
      FROM landmarks_usa
      WHERE onpremises IS TRUE AND overture_zip ~ '^[0-9]{5}$') l
  ON l.ip = host(a.ip)
GROUP BY 1
ORDER BY 1"""))

    print("Worst-disagreeing ISPs, which is where to look for a systematic cause:")
    print(psql("-c", """
SELECT coalesce(a.isp, '(none)')                                   AS isp,
       count(*)                                                    AS addresses,
       count(*) FILTER (WHERE left(a.zip,5) = l.overture_zip)       AS exact,
       count(*) FILTER (WHERE a.hosting)                           AS flagged_hosting,
       count(*) FILTER (WHERE a.mobile)                            AS flagged_mobile
FROM landmarks_usa_ip_api a
JOIN (SELECT DISTINCT host(ip_address) AS ip, overture_zip
      FROM landmarks_usa
      WHERE onpremises IS TRUE AND overture_zip ~ '^[0-9]{5}$') l
  ON l.ip = host(a.ip)
WHERE a.status = 'success'
GROUP BY 1
HAVING count(*) >= 20
ORDER BY count(*) FILTER (WHERE left(a.zip,5) = l.overture_zip)::numeric
         / nullif(count(*),0) ASC
LIMIT 15"""))


def main():
    p = argparse.ArgumentParser(
        description="Probe landmark addresses against ip-api.com /batch.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("create", help="create landmarks_usa_ip_api")

    def net(s):
        s.add_argument("--timeout", type=int, default=45)
        s.add_argument("--max-backoff", type=int, default=120,
                       help="longest sleep honoured from X-Ttl (default 120, "
                            "since X-Ttl is observed to be 60)")
        return s

    net(sub.add_parser("check-budget", help="one call per endpoint, show X-Rl"))

    pr = net(sub.add_parser("probe", help="probe on-premises landmark addresses"))
    pr.add_argument("--zip-prefix", help="only ZIPs starting with this, e.g. 021")
    pr.add_argument("--source", help="comma-separated sources, e.g. overture,foursquare")
    pr.add_argument("--include-hosting", action="store_true",
                    help="also probe addresses the cluster rule calls hosting; "
                         "excluded by default because ip-api reports the HOST's "
                         "location, not the tenant's, so they are not comparable")
    pr.add_argument("--deadline-minutes", type=int, default=0)
    pr.add_argument("--dry-run", action="store_true",
                    help="count the work and estimate the time, probe nothing")

    sub.add_parser("compare", help="agreement report")

    args = p.parse_args()
    {"create": cmd_create, "check-budget": cmd_check_budget,
     "probe": cmd_probe, "compare": cmd_compare}[args.cmd](args)


if __name__ == "__main__":
    main()
