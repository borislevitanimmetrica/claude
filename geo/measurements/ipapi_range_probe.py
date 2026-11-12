#!/usr/bin/env python3
"""Probe EVERY address in a CIDR against ip-api.com and report what varies.

WHY THIS EXISTS

Boris reported finding ZIP-level location data buried in ip-api output and
asked for all of 65.218.12.0/23 probed. Nothing in the repo could do it:

  check_geo_ip-api  samples ONE RANDOM IP PER RANGE. That is the opposite of
                    what is wanted here, which is every address in one range.
  landmarks_ip_api  probes addresses taken from the database, not an arbitrary
                    CIDR, and requests a fixed 12-field subset.

The second limitation matters most. The project has only ever asked ip-api for
status, message, country, regionName, city, zip, isp, org, as, mobile, hosting
and query. ip-api also returns DISTRICT, REVERSE, lat, lon, asname, proxy,
continent and currency, and none of those have ever been looked at here. If
there is finer-grained location in the response, district and reverse are the
candidates. So this asks for EVERYTHING.

WHAT IS VERIFIED, AND BY WHOM

Taken from geo/landmarks/landmarks_ip_api.py, which measured it rather than
assuming it:

  /batch accepts 100 addresses. 101 is refused with HTTP 422.
  /batch rate is 15 requests a minute: X-Rl counted down from 15 with X-Ttl
  60. A 4.2 second gap sits just under that.
  /batch and /json have SEPARATE rate buckets. Measured 2026-10-26, one call
  to each seconds apart reported X-Rl 12 and X-Rl 44. So this does NOT spend
  the budget that probe_batch and check_geo_ip-api consume.
  ip-api throttles by STALLING rather than answering 429, documented there
  from 60 observed calls, so a timeout is treated as a rate signal.

NOT VERIFIED BY ME: whether asking for the full field set changes the rate
limit or the response time. ip-api's own documentation warns that the reverse
field slows a request down. Use -no-reverse if a run stalls, and the per-call
X-Rl is printed on every call so throttling is visible rather than inferred.

COST. A /23 is 512 addresses, so 6 batch calls, about 25 seconds at a 4.2
second gap. A /16 would be 656 calls and about 46 minutes.

USAGE

  python3 ipapi_range_probe.py 65.218.12.0/23
  python3 ipapi_range_probe.py 65.218.12.0/23 -out /home/boris/geo/logs/r.csv
  python3 ipapi_range_probe.py 65.218.12.0/23 -no-reverse

Writes a CSV of every answer and prints, for each field, how many DISTINCT
values the range holds. That summary is the actual diagnostic: a field with
one value across 512 addresses carries no per-address information, and a field
with many is worth pursuing.

Attribution: ip-api.com free tier, non-commercial use. Check their terms
before any commercial use of the output.
"""

import argparse
import csv
import ipaddress
import json
import sys
import time
import urllib.error
import urllib.request
from collections import Counter

# Every documented ip-api field. The project has historically asked for twelve
# of these; the ones never requested before are district, reverse, lat, lon,
# asname, proxy, continent, continentCode, countryCode, region, timezone,
# offset and currency.
ALL_FIELDS = ("status,message,continent,continentCode,country,countryCode,"
              "region,regionName,city,district,zip,lat,lon,timezone,offset,"
              "currency,isp,org,as,asname,reverse,mobile,proxy,hosting,query")

FIELDS_NO_REVERSE = ALL_FIELDS.replace(",reverse", "")

MAX_BATCH = 100          # measured: 101 is refused with HTTP 422
REQUEST_GAP = 4.2        # measured: X-Rl starts at 15 per 60 seconds
TIMEOUT = 60             # a stall IS the rate signal, so this must be generous

CSV_COLUMNS = ["query", "status", "message", "continent", "continentCode",
               "country", "countryCode", "region", "regionName", "city",
               "district", "zip", "lat", "lon", "timezone", "offset",
               "currency", "isp", "org", "as", "asname", "reverse", "mobile",
               "proxy", "hosting"]


def post_batch(addresses, fields, max_ttl):
    """One /batch call. Returns (list_of_results, X-Rl) or (None, None)."""
    url = "http://ip-api.com/batch?fields=" + fields
    body = json.dumps([str(a) for a in addresses]).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json",
                 "User-Agent": "trugeo-range-probe/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode()), r.headers.get("X-Rl")
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            ttl = exc.headers.get("X-Ttl") or "60"
            wait = min(int(ttl) + 1, max_ttl)
            print(f"    HTTP 429, X-Ttl {ttl}, sleeping {wait}s", flush=True)
            time.sleep(wait)
            return None, None
        if exc.code == 422:
            print(f"    HTTP 422: the server refused a batch of "
                  f"{len(addresses)}. The measured maximum is {MAX_BATCH}.",
                  file=sys.stderr)
            return None, None
        print(f"    HTTP {exc.code}: {exc.reason}", file=sys.stderr)
        return None, None
    except TimeoutError:
        # Documented behaviour: ip-api throttles by stalling. Back off rather
        # than retry immediately, and say so rather than reporting a network
        # fault that did not happen.
        print(f"    timed out after {TIMEOUT}s, which is how ip-api signals "
              f"throttling. Backing off {REQUEST_GAP * 4:.0f}s", flush=True)
        time.sleep(REQUEST_GAP * 4)
        return None, None
    except OSError as exc:
        print(f"    transport error: {exc}", file=sys.stderr)
        time.sleep(REQUEST_GAP * 4)
        return None, None


def main():
    ap = argparse.ArgumentParser(
        description="Probe every address in a CIDR against ip-api.com.")
    ap.add_argument("cidr", help="network to probe, for example 65.218.12.0/23")
    ap.add_argument("-out", default=None,
                    help="CSV output path; default is derived from the CIDR")
    ap.add_argument("-no-reverse", action="store_true",
                    help="omit the reverse field, which ip-api warns is slow")
    ap.add_argument("-max-ttl", type=int, default=120,
                    help="longest sleep honoured from X-Ttl (default 120)")
    ap.add_argument("-retries", type=int, default=3,
                    help="attempts per batch before giving up (default 3)")
    args = ap.parse_args()

    try:
        net = ipaddress.ip_network(args.cidr, strict=False)
    except ValueError as exc:
        sys.exit(f"bad CIDR: {exc}")
    if net.version != 4:
        sys.exit("only IPv4 is supported")

    # Every address INCLUDING the network and broadcast addresses. ip-api will
    # answer for them, and excluding them would leave a gap in a study whose
    # whole point is per-address variation.
    addresses = list(net)
    fields = FIELDS_NO_REVERSE if getattr(args, "no_reverse") else ALL_FIELDS
    out_path = args.out or ("ipapi_" + args.cidr.replace("/", "_").replace(".", "_")
                            + ".csv")

    chunks = [addresses[i:i + MAX_BATCH]
              for i in range(0, len(addresses), MAX_BATCH)]
    print(f"{net} holds {len(addresses)} addresses, so {len(chunks)} batch "
          f"calls at a {REQUEST_GAP}s gap, about "
          f"{len(chunks) * REQUEST_GAP:.0f}s")
    print(f"fields requested: {fields}")
    print(f"writing {out_path}")
    print("")

    rows = []
    started = time.monotonic()
    for i, chunk in enumerate(chunks, 1):
        results = None
        for attempt in range(1, args.retries + 1):
            if i > 1 or attempt > 1:
                time.sleep(REQUEST_GAP)
            results, rl = post_batch(chunk, fields, args.max_ttl)
            if results is not None:
                print(f"  [{i}/{len(chunks)}] {len(results)} answers, "
                      f"X-Rl={rl}, {time.monotonic() - started:.0f}s elapsed",
                      flush=True)
                break
            print(f"  [{i}/{len(chunks)}] attempt {attempt} failed", flush=True)
        if results is None:
            print(f"  [{i}/{len(chunks)}] GIVING UP on this batch after "
                  f"{args.retries} attempts; those addresses are absent from "
                  f"the CSV", file=sys.stderr)
            continue
        for addr, res in zip(chunk, results):
            if not isinstance(res, dict):
                continue
            res.setdefault("query", str(addr))
            rows.append(res)

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)

    print("")
    print(f"{len(rows)} of {len(addresses)} addresses answered. "
          f"Wrote {out_path}")
    print("")
    print("DISTINCT VALUES PER FIELD. This is the diagnostic: a field with one")
    print("value across the whole range carries no per-address information,")
    print("and a field with many does.")
    print("")
    print(f"  {'field':<16}{'distinct':>9}  most common values")
    for col in CSV_COLUMNS:
        if col == "query":
            continue
        vals = Counter((r.get(col) if r.get(col) not in (None, "") else "(empty)")
                       for r in rows)
        top = ", ".join(f"{k}={v}" for k, v in vals.most_common(4))
        print(f"  {col:<16}{len(vals):>9}  {top}")

    print("")
    zips = Counter((r.get("zip") or "(empty)") for r in rows)
    print(f"ZIP values in this range: {len(zips)} distinct")
    for z, n in zips.most_common(40):
        print(f"  {z:<12}{n:>6} addresses")
    if len(zips) > 40:
        print(f"  ... and {len(zips) - 40} more")
    print("")
    print("If that list holds more than one real ZIP, ip-api is returning")
    print("sub-range location for this space and the range should be split on")
    print("it. If it holds exactly one, the earlier conclusion stands: the ZIP")
    print("describes the aggregation node, not the subscriber.")


if __name__ == "__main__":
    main()
