"""Locate carrier nodes from ip-api.com, for the ones the ITDK cannot place.

WHY

Boris, 2026-11-18: "Do you have domain names for these nodes? If so, we could
use ip-api.com with their IP addresses as arguments to establish coordinates."

Yes: carrier_node_tbl holds a hostname and a node_ip for all 22,770
addresses, so the IP addresses needed as arguments are already here.

This matters because the ITDK could not place a large share of them. Of
13,774 node addresses the ITDK located, at least 2,597 sat on MaxMind's
documented "could not locate a US address" sentinel at 37.751, -97.822, and
a further 8,926 of the 22,770 never appeared in the ifaces file at all.

ASK THE DATABASE BEFORE ASKING THE NETWORK

Boris already has an ip-api estate. The catalogue shows lat and lon on
ip2city_dbiplite_probe_tbl, ip2city_dbiplite_history_tbl,
ip2city_dbiplite_traceroute_tbl and range_classification. So the first thing
to do is NOT to probe: it is to count how many node addresses those tables
already answer, by exact query match and then by most-specific network
containment. Probing addresses whose answer is already stored would be rude
to a free service and slower than a join.

THE RATE LIMIT IS NOT A GUESS

From ip-api's own documentation, read 2026-11-18:

  the batch endpoint accepts up to 100 IP addresses or objects per request
    https://ip-api.com/docs/api:batch
  endpoints are limited to 45 requests per minute for the normal endpoints
  and 15 per minute for the BATCH endpoint, per source IP address
    https://ip-api.com/docs/unban

Boris, 2026-11-18: "No need to stay conservative. Use 1500 IP/minute in
batches of 100. This will also test our batch support. A paid account will be
established before the service we are building is commercialized. Currently
it is nonrevenue feasibility research."

So the default is now the documented ceiling: 15 batches of 100 per minute,
one every 4 seconds, 1,500 addresses a minute. The non-commercial condition
on the free endpoint is met by that statement of use.

RUNNING AT THE CEILING NEEDS MORE CARE, NOT LESS. At 12 batches a minute an
occasional miscount cost nothing. At 15 it is the limit itself, so three
things govern the loop rather than one:

  the interval, 4 seconds, which paces it at the ceiling
  the X-Rl header, the allowance remaining in the current window, which is
    read after every request; when it reaches zero the loop waits X-Ttl
    seconds for the window to reset
  the HTTP STATUS, checked explicitly. 429 means the limit was exceeded, and
    ip-api's own unban page says repeated violation is what gets a source
    address blocked. On 429 the loop backs off for the full window and
    RETRIES THE SAME BATCH, so no address is silently skipped because of a
    throttle.

The free endpoint is HTTP only.

WHAT IT RECORDS

node_ipapi_tbl, one row per node address, carrying the coordinate, the isp,
org and as strings, and the sentinel check. An ip-api answer can be a
country centroid just as a MaxMind one can, so the same two exclusions apply:
a coordinate matching geo_sentinel_tbl, and an answer with no city.

USAGE

  python3 -u node_ipapi.py coverage
  python3 -u node_ipapi.py fill
  python3 -u node_ipapi.py probe --limit 500
  python3 -u node_ipapi.py probe
  python3 -u node_ipapi.py sites
"""

import argparse
import json
import os
import subprocess
import sys
import time

BATCH_URL = "http://ip-api.com/batch"
FIELDS = "status,message,country,regionName,city,zip,lat,lon,isp,org,as,query"
UA = "trugeo-research/1.0 (carrier node geolocation; via project repo)"

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


def quote_ident(name):
    """Quote an identifier. Needed because one real column is named "as",
    which is a reserved word, and the probe estate uses it."""
    return '"' + str(name).replace('"', '""') + '"' 


def num(v):
    if v is None:
        return "NULL"
    try:
        return repr(float(v))
    except (TypeError, ValueError):
        return "NULL"


def ensure_tables():
    psql("-qc", """
CREATE TABLE IF NOT EXISTS node_ipapi_tbl (
    node_ip     inet PRIMARY KEY,
    hostname    text,
    status      text NOT NULL,
    message     text,
    country     text,
    region_name text,
    city        text,
    zip         text,
    lat         double precision,
    lon         double precision,
    isp         text,
    org         text,
    as_text     text,
    asked_at    timestamptz NOT NULL DEFAULT now(),
    source      text NOT NULL DEFAULT 'ip-api.com/batch');
COMMENT ON TABLE node_ipapi_tbl IS
  'ip-api.com answers for carrier node addresses, one row per address. An ip-api answer can be a country centroid exactly as a MaxMind one can, so the same exclusions apply downstream: a coordinate in geo_sentinel_tbl, or an answer with no city, is not a place.';""")


def require(table, remedy):
    if psql_q(f"SELECT to_regclass({lit(table)}) IS NOT NULL") != "t":
        sys.exit(f"{table} does not exist.\n  {remedy}")


def cmd_coverage(args):
    """How many node addresses already have an ip-api answer stored.

    Read only. Nothing is probed and nothing is written.
    """
    require("carrier_node_tbl",
            "Run the carrier_nodes schema and hoiho_apply first.")

    print("Node addresses held, and how many already have an ip-api "
          "coordinate in a table you already have. NOTHING is probed by "
          "this command.\n")

    src = "ip2city_dbiplite_probe_tbl"
    have = columns_of(src)
    qry = pick_col(have, "query")
    net = pick_col(have, "network")
    exact_pred = ip_eq(src, qry) if qry else None
    if qry and exact_pred is None:
        print(f"NOTE: {src}.{qry} has type "
              f"{col_type(src, qry)!r}, which is neither an address type "
              f"nor text, so an exact match cannot be formed and only "
              f"network containment is counted.\n", flush=True)
    # node_ipapi_tbl MAY NOT EXIST YET. coverage is the FIRST command, run
    # before fill, so it must not require fill's output table. And a guard
    # INSIDE the statement cannot save it: a relation named anywhere in a
    # statement is resolved when the statement is PARSED, so
    #   CASE WHEN to_regclass('node_ipapi_tbl') IS NULL THEN 0 ELSE
    #        (SELECT count(*) FROM node_ipapi_tbl) END
    # fails with "relation does not exist" exactly when it does not. That is
    # the FOURTH time this class of mistake has appeared in this project;
    # the others were a LEFT JOIN target, a DROP CASCADE, and a staging-row
    # count. The SQL is therefore composed conditionally in Python.
    probed_sql = "NULL::bigint"
    if psql_q("SELECT to_regclass('node_ipapi_tbl') IS NOT NULL") == "t":
        probed_sql = ("(SELECT count(*) FROM n WHERE EXISTS ("
                      "SELECT 1 FROM node_ipapi_tbl q "
                      "WHERE q.node_ip = n.node_ip AND q.lat IS NOT NULL))")

    exact_sql = (f"(SELECT count(*) FROM n WHERE EXISTS ("
                 f"SELECT 1 FROM {src} p WHERE {exact_pred} "
                 f"AND p.lat IS NOT NULL))" if exact_pred else "NULL::bigint")
    net_sql = (f"(SELECT count(*) FROM n WHERE EXISTS ("
               f"SELECT 1 FROM {src} p WHERE p.{quote_ident(net)} >>= "
               f"n.node_ip AND p.lat IS NOT NULL))"
               if net else "NULL::bigint")

    # EXACT MATCH FIRST. ip-api returns the address it was asked about in
    # the field "query", so an exact match is an answer about THAT address
    # rather than about a range containing it.
    print(psql("-c", f"""
WITH n AS (SELECT DISTINCT node_ip FROM carrier_node_tbl
           WHERE node_ip IS NOT NULL)
SELECT
  (SELECT count(*) FROM n) AS node_addresses,
  {exact_sql} AS exact_in_probe,
  {net_sql} AS network_in_probe,
  {probed_sql} AS already_probed_here"""))

    if psql_q("SELECT to_regclass('itdk_node_placed') IS NOT NULL") != "t":
        print("itdk_node_placed does not exist yet, so the comparison "
              "against what the ITDK could place is skipped. Build it "
              "with:")
        print(f"  python3 -u {script('itdk_geo_load.py')} load "
              f"--dir /home/boris/geo/caida\n")
    else:
        print("Against what the ITDK could place. The gap is what probing "
              "would be for.\n")
        print(psql("-c", """
WITH n AS (SELECT DISTINCT node_ip FROM carrier_node_tbl
           WHERE node_ip IS NOT NULL)
SELECT count(*) AS node_addresses,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM itdk_node_placed p WHERE p.address = n.node_ip))
         AS itdk_placed,
       count(*) FILTER (WHERE NOT EXISTS (
         SELECT 1 FROM itdk_node_placed p WHERE p.address = n.node_ip))
         AS itdk_cannot_place
FROM n"""))

    print("The order this implies: fill from what you already hold, then "
          "probe only what is still missing.")
    print(f"  python3 -u {script('node_ipapi.py')} fill")
    print(f"  python3 -u {script('node_ipapi.py')} probe")
    return 0


def columns_of(table):
    """The column names a table actually has, as a set.

    NOT A GUESS. I wrote country, region_name and city into the fill query
    from assumption, having verified only lat, lon, isp, org and "as" on
    ip2city_dbiplite_probe_tbl. That is the precise error standing order 1
    exists to prevent and which has already cost this project four round
    trips. The fill below now uses only columns the catalogue confirms.
    """
    out = psql("-qtA", "-c",
               "SELECT column_name FROM information_schema.columns "
               f"WHERE table_name = {lit(table)}")
    return {c.strip() for c in out.splitlines() if c.strip()}


def col_type(table, column):
    """The declared data type of a column, from the catalogue."""
    return psql_q("SELECT data_type FROM information_schema.columns "
                  f"WHERE table_name = {lit(table)} "
                  f"AND column_name = {lit(column)}")


def ip_eq(table, column, node_expr="n.node_ip"):
    """An equality predicate against a node address, typed correctly.

    WHY THIS IS A FUNCTION AND NOT A LITERAL STRING. I wrote
    p.query = host(n.node_ip), which assumes the query column is text. On
    Boris's database it is inet, so postgres refused with "operator does not
    exist: inet = text". That is the SAME class of error as taking a column
    NAME on faith, one level deeper: I read the name from the catalogue and
    then assumed its type.

    inet = inet compares addresses. host() renders an inet as text and is
    right only when the stored column really is text. Asking the catalogue
    costs one query and removes the guess.
    """
    t = (col_type(table, column) or "").lower()
    if t in ("inet", "cidr"):
        return f"{column_ref(column)} = {node_expr}"
    if t in ("text", "character varying", "character", "citext"):
        return f"{column_ref(column)} = host({node_expr})"
    # An unexpected type is reported rather than papered over with a cast
    # that might compare the wrong things.
    return None


def column_ref(column):
    return "p." + quote_ident(column)


def pick_col(have, *candidates):
    """First candidate present, or None. Handles the lat/lon versus lat/lng
    split and the region_name versus region spelling, both of which exist in
    this database: carrier_node_tbl uses lng while the itdk tables use lon.
    """
    for c in candidates:
        if c in have:
            return c
    return None


def cmd_fill(args):
    """Copy answers already held into node_ipapi_tbl. No network at all.

    Exact query matches are taken first and are marked source
    'ip2city_dbiplite_probe_tbl exact'. Network containment is taken only
    for addresses with no exact answer, most specific first, and is marked
    differently because an answer about a /16 is weaker evidence about one
    address inside it than an answer about the address itself.
    """
    require("ip2city_dbiplite_probe_tbl", "It is the ip-api probe estate.")
    ensure_tables()

    src = args.table
    have = columns_of(src)
    if not have:
        sys.exit(f"{src} has no columns in information_schema, so it does "
                 f"not exist. Nothing was changed.")

    lat = pick_col(have, "lat", "latitude")
    lon = pick_col(have, "lon", "lng", "long", "longitude")
    if not (lat and lon):
        sys.exit(f"{src} does not carry both a latitude and a longitude "
                 f"column. Columns found: {sorted(have)}")
    net = pick_col(have, "network")
    qry = pick_col(have, "query")
    city = pick_col(have, "city")
    region = pick_col(have, "region_name", "region", "regionname")
    country = pick_col(have, "country", "country_name")
    isp = pick_col(have, "isp")
    org = pick_col(have, "org", "organization")
    asc_ = pick_col(have, "as", "as_text", "asn")

    print(f"source table: {src}")
    print(f"  coordinates: {lat}, {lon}")
    print(f"  keys:        "
          f"{', '.join(x for x in (qry, net) if x) or 'NONE'}")
    print(f"  attributes:  "
          f"{', '.join(x for x in (city, region, country, isp, org, asc_) if x) or 'none'}")
    missing = [n for n, c in (("city", city), ("region", region),
                              ("country", country)) if c is None]
    if missing:
        print(f"  NOT PRESENT and therefore left null: {', '.join(missing)}")
        if city is None:
            print(f"  WARNING: without a city column the "
                  f"'no city means a centroid, not a place' test cannot be "
                  f"applied to rows filled from this table. Those rows will "
                  f"NOT be treated as places by `sites`.")
    print(flush=True)

    def sel(col, alias):
        return (f"p.{quote_ident(col)}" if col else "NULL") + f" AS {alias}"

    before = int(psql_q("SELECT count(*) FROM node_ipapi_tbl") or 0)

    exact_pred = ip_eq(src, qry) if qry else None
    if qry and exact_pred is None:
        print(f"  {qry} has type {col_type(src, qry)!r}, which is neither "
              f"an address type nor text, so exact matching is SKIPPED "
              f"rather than forced with a cast that might compare the "
              f"wrong things.", flush=True)

    if exact_pred:
        print("1. exact matches on the address ip-api was asked about",
              flush=True)
        psql("-qc", f"""
INSERT INTO node_ipapi_tbl (node_ip, hostname, status, country,
    region_name, city, lat, lon, isp, org, as_text, source)
SELECT DISTINCT ON (n.node_ip)
       n.node_ip, n.hostname, 'success',
       {('p.' + quote_ident(country)) if country else 'NULL'},
       {('p.' + quote_ident(region)) if region else 'NULL'},
       {('p.' + quote_ident(city)) if city else 'NULL'},
       p.{quote_ident(lat)}, p.{quote_ident(lon)},
       {('p.' + quote_ident(isp)) if isp else 'NULL'},
       {('p.' + quote_ident(org)) if org else 'NULL'},
       {('p.' + quote_ident(asc_)) if asc_ else 'NULL'},
       {lit(src + ' exact')}
FROM (SELECT node_ip, min(hostname) AS hostname FROM carrier_node_tbl
      WHERE node_ip IS NOT NULL GROUP BY node_ip) n
JOIN {src} p ON {exact_pred}
WHERE p.{quote_ident(lat)} IS NOT NULL
ORDER BY n.node_ip
ON CONFLICT (node_ip) DO NOTHING""")
        mid = int(psql_q("SELECT count(*) FROM node_ipapi_tbl") or 0)
        print(f"   {mid - before:,} address(es) answered exactly",
              flush=True)
    else:
        mid = before
        print("1. skipped: no usable query column, so no exact match is "
              "possible", flush=True)

    if net:
        print("2. most-specific containing network, for the rest",
              flush=True)
        psql("-qc", f"""
INSERT INTO node_ipapi_tbl (node_ip, hostname, status, country,
    region_name, city, lat, lon, isp, org, as_text, source)
SELECT n.node_ip, n.hostname, 'success', v.country, v.region_name, v.city,
       v.lat, v.lon, v.isp, v.org, v.as_text,
       {lit(src + ' network/')} || v.masklen
FROM (SELECT node_ip, min(hostname) AS hostname FROM carrier_node_tbl
      WHERE node_ip IS NOT NULL GROUP BY node_ip) n
CROSS JOIN LATERAL (
    SELECT {('p.' + quote_ident(country)) if country else 'NULL'} AS country,
           {('p.' + quote_ident(region)) if region else 'NULL'} AS region_name,
           {('p.' + quote_ident(city)) if city else 'NULL'} AS city,
           p.{quote_ident(lat)} AS lat, p.{quote_ident(lon)} AS lon,
           {('p.' + quote_ident(isp)) if isp else 'NULL'} AS isp,
           {('p.' + quote_ident(org)) if org else 'NULL'} AS org,
           {('p.' + quote_ident(asc_)) if asc_ else 'NULL'} AS as_text,
           masklen(p.{quote_ident(net)}) AS masklen
    FROM {src} p
    WHERE p.{quote_ident(net)} >>= n.node_ip
      AND p.{quote_ident(lat)} IS NOT NULL
    ORDER BY masklen(p.{quote_ident(net)}) DESC
    LIMIT 1) v
ON CONFLICT (node_ip) DO NOTHING""")
        after = int(psql_q("SELECT count(*) FROM node_ipapi_tbl") or 0)
        print(f"   {after - mid:,} further address(es) answered by "
              f"containment", flush=True)
    else:
        print("2. skipped: no network column, so containment is impossible",
              flush=True)

    print()
    print(psql("-c", """
SELECT source, count(*) AS addresses,
       count(DISTINCT city) AS cities,
       count(*) FILTER (WHERE coalesce(city, '') = '') AS no_city
FROM node_ipapi_tbl GROUP BY 1 ORDER BY 2 DESC"""))
    remaining = psql_q("""
SELECT count(*) FROM (SELECT DISTINCT node_ip FROM carrier_node_tbl
                      WHERE node_ip IS NOT NULL) n
WHERE NOT EXISTS (SELECT 1 FROM node_ipapi_tbl q
                  WHERE q.node_ip = n.node_ip)""")
    print(f"{int(remaining or 0):,} address(es) still have no ip-api "
          f"answer. Those are what `probe` is for:")
    print(f"  python3 -u {script('node_ipapi.py')} probe")
    return 0


def read_headers(path):
    """X-Rl is requests left in the window, X-Ttl is seconds until reset."""
    rl = ttl = None
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            low = line.lower()
            if low.startswith("x-rl:"):
                try:
                    rl = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
            elif low.startswith("x-ttl:"):
                try:
                    ttl = int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
    except OSError:
        pass
    return rl, ttl


def post_batch(ips, hdr_path, timeout=60):
    """One batch request. Returns (list, http_status, error).

    The HTTP STATUS IS RETURNED SEPARATELY because at the documented ceiling
    429 is the response that matters and it must not be mistaken for a
    parse failure. ip-api's unban page states that repeatedly exceeding the
    limit is what gets a source address blocked, so the caller backs off for
    a full window and retries the same batch rather than dropping it.
    """
    payload = json.dumps([{"query": ip, "fields": FIELDS} for ip in ips])
    r = subprocess.run(
        ["curl", "-sS", "-m", str(timeout), "-A", UA,
         "-D", hdr_path, "-o", "-",
         "-w", "\n%{http_code}",
         "-H", "Content-Type: application/json",
         "--data-binary", payload, BATCH_URL],
        capture_output=True, text=True)
    if r.returncode != 0:
        return None, None, f"curl exit {r.returncode}: {r.stderr.strip()[:140]}"
    out = r.stdout
    body, _, code = out.rpartition("\n")
    try:
        status = int(code.strip())
    except ValueError:
        status = None
    body = body.strip()
    if status is not None and status != 200:
        return None, status, f"HTTP {status}: {body[:140]}"
    if not body:
        return None, status, "empty response"
    try:
        d = json.loads(body)
    except ValueError:
        return None, status, f"not JSON: {body[:140]}"
    if not isinstance(d, list):
        return None, status, (f"expected a list, got "
                              f"{type(d).__name__}: {body[:140]}")
    return d, status, None


def cmd_probe(args):
    """Batch-probe the addresses with no answer yet.

    RATE LIMITED TO ip-api's DOCUMENTED CEILING, with margin. Their unban
    page states 15 requests per minute for the batch endpoint per source IP;
    the default interval of 5 seconds is 12 per minute. The X-Rl header,
    which is the allowance remaining in the current window, is read after
    every request and the loop WAITS for X-Ttl seconds when it reaches zero.
    Pressing on would get the source address banned, and the estate Boris
    already has depends on that address staying unbanned.
    """
    require("carrier_node_tbl", "Run the carrier_nodes schema first.")
    ensure_tables()

    rows = [r for r in psql("-qtAF|", "-c", """
SELECT host(n.node_ip), coalesce(min(n.hostname), '')
FROM carrier_node_tbl n
WHERE n.node_ip IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM node_ipapi_tbl q
                  WHERE q.node_ip = n.node_ip)
GROUP BY n.node_ip
ORDER BY n.node_ip""").splitlines() if "|" in r]
    todo = []
    for r in rows:
        ip, host = r.rsplit("|", 1)
        todo.append((ip.strip(), host.strip()))

    if args.limit:
        todo = todo[:args.limit]

    if not todo:
        print("Every node address already has an ip-api answer. Nothing to "
              "probe.")
        return 0

    batches = (len(todo) + 99) // 100
    print(f"{len(todo):,} address(es) to probe, {batches} batch(es) of up "
          f"to 100.")
    print(f"One batch every {args.interval:g}s, which is "
          f"{60.0 / args.interval:.0f} batches and "
          f"{100 * 60.0 / args.interval:,.0f} addresses per minute. "
          f"ip-api's documented ceiling for the batch endpoint is 15 "
          f"requests per minute.")
    print(f"Estimated {batches * args.interval / 60.0:.1f} minutes at that "
          f"rate.")
    print("The X-Rl allowance header governs and the interval only paces. "
          "An HTTP 429 backs off for a full window and retries the SAME "
          "batch, so no address is dropped by a throttle.\n")

    hdr = "/tmp/ipapi_hdr.txt"
    ok = failed = throttled = 0
    t0 = time.monotonic()
    b = 0

    while b < batches:
        chunk = todo[b * 100:(b + 1) * 100]
        ips = [ip for ip, _ in chunk]
        hosts = dict(chunk)

        d, status, err = post_batch(ips, hdr)
        rl, ttl = read_headers(hdr)

        # 429 MEANS BACK OFF AND RETRY THE SAME BATCH, not skip it.
        if status == 429:
            throttled += 1
            wait = (ttl or 60) + 5
            print(f"[batch {b + 1}/{batches}] HTTP 429, the limit was "
                  f"exceeded. Waiting {wait}s for the window to reset and "
                  f"retrying the SAME batch, so no address is lost.",
                  flush=True)
            if throttled >= args.max_throttles:
                sys.exit(
                    f"STOPPED after {throttled} throttles. ip-api's unban "
                    f"page says repeated violation is what blocks a source "
                    f"address, and the estate already stored depends on "
                    f"this one staying usable.\n\n"
                    f"{ok:,} address(es) were located and are saved; "
                    f"nothing is lost. Re-run later and it continues from "
                    f"where it stopped, or lower the rate:\n"
                    f"  python3 -u {script('node_ipapi.py')} probe "
                    f"--interval 6")
            time.sleep(wait)
            continue

        if d is None:
            print(f"[batch {b + 1}/{batches}] FAILED: {err}", flush=True)
            failed += len(chunk)
            b += 1
            time.sleep(max(args.interval, 4.0))
            continue

        values = []
        good = 0
        for item in d:
            if not isinstance(item, dict):
                continue
            q = item.get("query")
            if not q:
                continue
            st = item.get("status") or "unknown"
            if st == "success":
                good += 1
            values.append("(" + ", ".join([
                lit(q) + "::inet", lit(hosts.get(q)), lit(st),
                lit(item.get("message")), lit(item.get("country")),
                lit(item.get("regionName")), lit(item.get("city")),
                lit(item.get("zip")), num(item.get("lat")),
                num(item.get("lon")), lit(item.get("isp")),
                lit(item.get("org")), lit(item.get("as")),
                lit("ip-api.com/batch")]) + ")")
        if values:
            psql("-qc",
                 "INSERT INTO node_ipapi_tbl (node_ip, hostname, status, "
                 "message, country, region_name, city, zip, lat, lon, isp, "
                 "org, as_text, source) VALUES " + ", ".join(values) +
                 " ON CONFLICT (node_ip) DO NOTHING")
        ok += good
        failed += len(chunk) - good

        el = time.monotonic() - t0
        done_ips = (b + 1) * 100
        eta = ""
        if b > 0:
            eta = (f", about {(batches - b - 1) * el / (b + 1) / 60:.0f} "
                   f"min left")
        print(f"[batch {b + 1}/{batches}] {good} of {len(chunk)} located, "
              f"{done_ips / max(el, 0.001) * 60:,.0f} IP/min"
              + (f", allowance left {rl}" if rl is not None else "")
              + eta, flush=True)

        b += 1

        # THE ALLOWANCE GOVERNS, the interval only paces. At the ceiling the
        # header is the authority: if it says nothing is left, waiting is
        # the only correct action.
        if rl is not None and rl <= 1 and ttl:
            print(f"    allowance spent, waiting {ttl + 2}s for the window "
                  f"to reset", flush=True)
            time.sleep(ttl + 2)
        elif b < batches:
            time.sleep(args.interval)

    print(f"\n{ok:,} located, {failed:,} not, in "
          f"{(time.monotonic() - t0) / 60:.1f} minutes")
    print(psql("-c", """
SELECT status, count(*) AS addresses,
       count(*) FILTER (WHERE coalesce(city, '') = '') AS no_city
FROM node_ipapi_tbl WHERE source = 'ip-api.com/batch'
GROUP BY 1 ORDER BY 2 DESC"""))
    return 0


def cmd_sites(args):
    """Candidate sites from ip-api, with the same exclusions as the ITDK.

    An ip-api answer is subject to exactly the hazard that MaxMind's
    37.751,-97.822 turned out to be, so the same two tests apply: a
    coordinate listed in geo_sentinel_tbl, and an answer with no city, which
    is a country or region centroid rather than a place.
    """
    require("node_ipapi_tbl", "Run fill or probe first.")
    has_sent = psql_q(
        "SELECT to_regclass('geo_sentinel_tbl') IS NOT NULL") == "t"
    sent = ("EXISTS (SELECT 1 FROM geo_sentinel_tbl s WHERE s.kind = "
            "'sentinel' AND round(s.lat::numeric,3) = round(q.lat::numeric,3)"
            " AND round(s.lon::numeric,3) = round(q.lon::numeric,3))"
            if has_sent else "false")

    psql("-qc", f"""
CREATE OR REPLACE VIEW node_ipapi_placed AS
SELECT q.node_ip, q.hostname, q.city, q.region_name, q.country,
       q.lat, q.lon, q.isp, q.org, q.as_text, q.source
FROM node_ipapi_tbl q
WHERE q.status = 'success' AND q.lat IS NOT NULL
  AND coalesce(q.city, '') <> ''
  AND NOT ({sent});

CREATE OR REPLACE VIEW ipapi_concentration AS
SELECT split_part(hostname, '.', -2) || '.' ||
       split_part(hostname, '.', -1)  AS carrier_domain,
       lat, lon, city, region_name,
       count(DISTINCT node_ip)        AS node_addresses,
       count(DISTINCT hostname)       AS hostnames
FROM node_ipapi_placed
WHERE hostname <> ''
GROUP BY 1, 2, 3, 4, 5;""")

    print("What ip-api gives, after the same exclusions the ITDK answers "
          "get:\n")
    print(psql("-c", """
SELECT CASE
         WHEN status <> 'success' THEN '0. ip-api returned no answer'
         WHEN lat IS NULL         THEN '1. no coordinate'
         WHEN coalesce(city,'') = '' THEN '2. no city, a centroid not a place'
         ELSE '3. a place'
       END AS verdict,
       count(*) AS addresses,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM node_ipapi_tbl GROUP BY 1 ORDER BY 1"""))

    print(f"Concentrations from ip-api, at least "
          f"{int(args.min_nodes)} node address(es):\n")
    print(psql("-c", f"""
SELECT carrier_domain, city, region_name, node_addresses, hostnames,
       round(lat::numeric, 4) AS lat, round(lon::numeric, 4) AS lon
FROM ipapi_concentration
WHERE node_addresses >= {int(args.min_nodes)}
ORDER BY node_addresses DESC, carrier_domain
LIMIT {int(args.limit)}"""))

    print("\nWHAT EACH THRESHOLD WOULD KEEP, from ip-api rather than the "
          "ITDK:\n")
    print(psql("-c", """
WITH c AS (SELECT node_addresses FROM ipapi_concentration)
SELECT t AS min_nodes,
       count(*) FILTER (WHERE c.node_addresses >= t) AS sites_kept,
       sum(c.node_addresses) FILTER (WHERE c.node_addresses >= t)
         AS node_addresses_kept,
       round(100.0 * coalesce(sum(c.node_addresses)
             FILTER (WHERE c.node_addresses >= t), 0)
             / nullif(sum(c.node_addresses), 0), 1) AS pct_of_nodes
FROM (VALUES (1), (2), (3), (5), (10)) AS v(t)
CROSS JOIN c GROUP BY t ORDER BY t"""))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("coverage",
                       help="how many node addresses already have an ip-api "
                            "answer. Read only, probes nothing")
    c.set_defaults(func=cmd_coverage)

    f = sub.add_parser("fill",
                       help="copy answers already in the probe estate. No "
                            "network access at all")
    f.add_argument("--table", default="ip2city_dbiplite_probe_tbl",
                   help="which stored ip-api table to fill from. Columns "
                        "are read from the catalogue, not assumed.")
    f.set_defaults(func=cmd_fill)

    p = sub.add_parser("probe",
                       help="batch-probe the addresses with no answer yet")
    p.add_argument("--limit", type=int,
                   help="stop after this many addresses, for a trial")
    p.add_argument("--interval", type=float, default=4.0,
                   help="seconds between batches, default 4, which is 15 "
                        "per minute and 1,500 addresses per minute, "
                        "ip-api's documented ceiling for the batch "
                        "endpoint. Raise it if you see HTTP 429.")
    p.add_argument("--max-throttles", type=int, default=5,
                   help="stop after this many HTTP 429 responses rather "
                        "than risk the source address being blocked")
    p.set_defaults(func=cmd_probe)

    s = sub.add_parser("sites",
                       help="candidate sites from ip-api, sentinels and "
                            "cityless answers excluded")
    s.add_argument("--min-nodes", type=int, default=1)
    s.add_argument("--limit", type=int, default=30)
    s.set_defaults(func=cmd_sites)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
