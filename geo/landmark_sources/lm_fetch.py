#!/usr/bin/env python3
"""
Fetch additional landmark sources into lm_places_usa.

A landmark is only useful to this pipeline if it has BOTH a ZIP and a website:
the website resolves to an IP whose registrant decides `onpremises`, and the ZIP
is the geographic anchor. Every source here was checked against that pair before
being included. See readme.md for the ones that were rejected and why.

Database access is via the `psql` command only, standard library otherwise, so
it uses the same connection as your psql. Same approach as ovt_resolve_hosts.py.

Subcommands, in descending order of what they actually contribute:

  osm-overpass   OpenStreetMap via the Overpass API, per state. Features tagged
                 with both `website` (or `contact:website`) and `addr:postcode`.
                 Much the largest source: Massachusetts alone returns 15,132 and
                 Texas 52,269. Big states (CA, NY) time out on Overpass; use
                 osm-pbf for those and for a national pass.

  osm-pbf        OpenStreetMap from a Geofabrik extract already filtered by
                 `osmium tags-filter` and exported to GeoJSON. No rate limit and
                 no timeout, which is what a national pass needs.

  nces-ipeds     NCES IPEDS institutional characteristics (HD<year>). About
                 6,000 colleges with ZIP and WEBADDR. The best of the small
                 sources per row, because nearly every institution is on its own
                 domain and universities characteristically host on campus.

  wikidata       Wikidata items in the US with an official website (P856) and a
                 street address (P6375) containing a 5-digit ZIP. The ZIP is
                 inside the address text, which is exactly the `freeform` shape
                 the chain's ZIP step already handles.

  nps            National Park Service. Needs a free API key. Included for
                 completeness but it is NOT worth running: every park is an
                 nps.gov URL, so the whole feed collapses to one host and one
                 landmark address, which node_fanout.sql will then classify as
                 hosting because it spans disjoint ZIP clusters.

Run order:
  psql -v ON_ERROR_STOP=1 -f create_table_lm_places_usa.sql
  python3 lm_fetch.py nces-ipeds --year 2023
  python3 lm_fetch.py osm-overpass --states MA
  python3 lm_fetch.py wikidata --limit 50000
  psql -v ON_ERROR_STOP=1 -f lm_crosswalk.sql

Then the SHARED chain, with no source-specific code:
  python3 ../overture_fetch/ovt_resolve_hosts.py resolve      --table lm_places_usa
  python3 ../overture_fetch/ovt_resolve_hosts.py rdap         --table lm_places_usa
  python3 ../overture_fetch/ovt_resolve_hosts.py registrants  --table lm_places_usa
  python3 ../overture_fetch/ovt_resolve_hosts.py overture-zip --table lm_places_usa
  python3 ../overture_fetch/ovt_resolve_hosts.py onpremises   --table lm_places_usa

Attribution:
  OpenStreetMap  (c) OpenStreetMap contributors, ODbL 1.0
  Wikidata       CC0 1.0
  NCES IPEDS     US Department of Education, public domain
  NPS            US National Park Service, public domain
"""

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

UA = "trugeo-landmark-fetch/1.0 (geolocation research; contact via repository)"

OVERPASS = "https://overpass-api.de/api/interpreter"
WDQS = "https://query.wikidata.org/sparql"
IPEDS = "https://nces.ed.gov/ipeds/datacenter/data/HD{year}.zip"
NPS_API = "https://developer.nps.gov/api/v1/parks"

ZIP5_RE = re.compile(r"\b(\d{5})(?:-\d{4})?\b")

# The 50 states plus DC. Territories are omitted: Overpass ISO3166-2 coverage
# for them is uneven, and they are out of scope for US ZIP targeting anyway.
STATES = ("AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI "
          "MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT "
          "VA WA WV WI WY").split()

# Columns the loader writes, in COPY order. Must match build_row().
COLUMNS = ["source", "source_id", "source_release", "name", "address", "locality",
           "region", "postcode", "country", "website", "latitude", "longitude",
           "category", "websites", "addresses"]


# --------------------------------------------------------------------------
# database
# --------------------------------------------------------------------------

def psql(*args, stdin=None, check=True):
    cmd = ["psql", "-X", "-v", "ON_ERROR_STOP=1", *args]
    try:
        r = subprocess.run(cmd, input=stdin, capture_output=True, text=True,
                           check=check)
        return r.stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or exc
        sys.exit(f"psql failed: {detail}")


def require_table():
    out = psql("-qtA", "-c", "select count(*) from information_schema.tables "
               "where table_schema='public' and table_name='lm_places_usa'")
    if out.strip() != "1":
        sys.exit("Table public.lm_places_usa not found. Run "
                 "create_table_lm_places_usa.sql first.")


def read_csv_dicts(raw):
    """Parse CSV bytes into dicts, tolerating a BOM and either encoding.

    This exists because IPEDS ships a UTF-8 BOM. Read as latin-1 the first
    header becomes 'i>>?UNITID', so DictReader's "UNITID" key returns None,
    every row gets an empty id, and the load silently collapses to a single
    row. Strip the BOM from the bytes, try UTF-8, and fall back to latin-1 for
    the genuinely latin-1 files. Header names are stripped defensively too.
    """
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("latin-1")
    rdr = csv.reader(io.StringIO(text, newline=""))
    header = [h.strip().lstrip("\ufeff") for h in next(rdr)]
    for row in rdr:
        if row:
            yield dict(zip(header, row))


def load_rows(source, rows, replace=False):
    """Upsert rows into lm_places_usa. NEVER destroys progress.

    This used to DELETE every row for the source and then COPY, which quietly
    went backwards: a first run that fetched 30,000 rows followed by a second
    run that managed only 20,000 before the service failed left 20,000, losing
    10,000. Under a rate limit that is the normal case, not the edge case, so
    repeated partial runs could never accumulate.

    Now the batch is staged in a temp table and merged with ON CONFLICT, so a
    partial run adds what it got and leaves the rest alone. Only the 15 load
    columns are updated, so enrichment the chain has already written
    (ip_address, onpremises, registrants) survives a re-load of the same place.

    replace=True restores the old delete-first behaviour, for a deliberate full
    refresh. It is opt-in precisely because it can lose rows.
    """
    if not rows:
        print(f"{source}: nothing to load.")
        return

    # A source whose ids are mostly blank means the key column was not parsed,
    # not that the data is duplicated. That failure silently reduced an IPEDS
    # load to one row, so it is now an error rather than a surprising count.
    blank = sum(1 for r in rows if not str(r[1]).strip())
    if blank > len(rows) // 2:
        sys.exit(f"{source}: {blank:,} of {len(rows):,} rows have no source_id. "
                 f"The key column was almost certainly not parsed. Refusing to load.")
    buf = io.StringIO()
    # lineterminator is forced to "\n": the default "\r\n" leaves a stray
    # carriage return inside the last field of every row once PostgreSQL has
    # split on the newline.
    w = csv.writer(buf, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
    seen = set()
    written = 0
    for r in rows:
        key = r[1]
        if key in seen:        # same id twice in one batch; keep the first
            continue
        seen.add(key)
        w.writerow(r)
        written += 1
    if replace:
        psql("-q", "-c", f"DELETE FROM lm_places_usa WHERE source = '{source}'")

    cols = ", ".join(COLUMNS)
    updates = ", ".join(f"{c} = EXCLUDED.{c}"
                        for c in COLUMNS if c not in ("source", "source_id"))

    # The data goes through a temp FILE read by psql's client-side \copy, not
    # inline after a COPY FROM STDIN. Inline data is read line by line while
    # psql looks for the backslash-dot terminator, so a field containing a
    # newline, which Wikidata street addresses do contain, breaks the load with
    # "unquoted newline found in data" even though the CSV quoting is correct.
    # \copy hands the file to COPY as one stream and quoted newlines survive.
    #
    # A temp table plus ON CONFLICT does the merge. Both must be in the same
    # psql invocation because a temp table is session-scoped.
    fd, path = tempfile.mkstemp(prefix=f"lm_{source}_", suffix=".csv")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(buf.getvalue())
        script = (
            "BEGIN;\n"
            "CREATE TEMP TABLE lm_stage (LIKE lm_places_usa) ON COMMIT DROP;\n"
            f"\\copy lm_stage ({cols}) FROM '{path}' WITH (FORMAT csv)\n"
            f"INSERT INTO lm_places_usa ({cols})\n"
            f"SELECT {cols} FROM lm_stage\n"
            f"ON CONFLICT (source, source_id) DO UPDATE SET {updates};\n"
            "COMMIT;\n"
        )
        psql("-q", "-f", "-", stdin=script)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass

    total = psql("-qtA", "-c",
                 f"SELECT count(*) FROM lm_places_usa WHERE source = '{source}'").strip()
    print(f"{source}: merged {written:,} rows "
          f"({len(rows) - written:,} duplicate ids skipped); "
          f"{source} now holds {int(total):,}.")


def build_row(source, source_id, release, name, address, locality, region,
              postcode, website, lat=None, lon=None, category=None):
    """Normalise one place and synthesise the two columns the chain reads.

    addresses is built with json.dumps so a quote or backslash in a street name
    cannot produce malformed JSON, which would silently break the ZIP regexes.
    """
    postcode = (postcode or "").strip()
    m = ZIP5_RE.search(postcode)
    zip5 = m.group(1) if m else ""
    website = (website or "").strip()
    addresses = json.dumps({
        "freeform": (address or "").strip() or None,
        "locality": (locality or "").strip() or None,
        "postcode": zip5 or None,
        "region": (region or "").strip().upper() or None,
        "country": "US",
    }, ensure_ascii=False)
    return [source, source_id, release, (name or "").strip(),
            (address or "").strip(), (locality or "").strip(),
            (region or "").strip().upper(), zip5, "US", website,
            lat if lat is not None else "", lon if lon is not None else "",
            category or "", website, addresses]


def normalise_url(u):
    """Keep only things that can plausibly resolve to a host."""
    u = (u or "").strip()
    if not u or " " in u:
        return ""
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", u):
        u = "http://" + u
    host = urllib.parse.urlsplit(u).hostname or ""
    if "." not in host or host.endswith("."):
        return ""
    return u


# Longest we will ever sleep on a Retry-After.
#
# 60s, and the number is derived rather than chosen. The only rate-limit
# INTERVAL any of these services has actually stated is WDQS's "1 req / min",
# seen in its own 429 body. 60s is therefore the shortest cap that still lets
# every rate limit we have observed recover on the next attempt. The Overpass
# 502s carried no Retry-After at all and recovered at 15s and 30s, well inside
# this.
#
# An earlier 120s was a round number I picked, not a measurement, which is the
# kind of invented threshold that has no business being in here.
#
# Above the cap we do not sleep. WDQS answered one 429 with Retry-After: 1000,
# and honouring that parked the run for nearly 17 minutes with no output, which
# is indistinguishable from a hang. A demand that long means the service is
# down, not busy, and no tolerable sleep makes it succeed.
MAX_BACKOFF = 60


def http_json(url, data=None, headers=None, timeout=180, retries=3,
              max_backoff=MAX_BACKOFF):
    hdr = {"User-Agent": UA, "Accept": "application/json"}
    hdr.update(headers or {})
    body = data.encode() if isinstance(data, str) else data
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, data=body, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code} {exc.reason}"
            # 429 and 5xx are the Overpass/WDQS back-pressure signals. Honour
            # Retry-After when it is sent. For a bare 429, wait a full 65s:
            # WDQS states "1 req / min" during an outage, so a 15s retry just
            # burns the remaining attempts and reports a failure that was only
            # impatience.
            if exc.code in (429, 502, 503, 504) and attempt < retries:
                ra = exc.headers.get("Retry-After") if exc.headers else None
                try:
                    wait = int(ra)
                except (TypeError, ValueError):
                    wait = 65 if exc.code == 429 else 15 * attempt
                if wait > max_backoff:
                    return {"__error__":
                            f"{last}; the server asked for a {wait}s wait, which is "
                            f"longer than the {max_backoff}s limit. Not sleeping. "
                            f"The service is rate-limiting or down, so re-run this "
                            f"source later; nothing else is affected."}
                print(f"    {last}, retrying in {wait}s", flush=True)
                time.sleep(wait)
                continue
            return {"__error__": last}
        except OSError as exc:
            last = str(exc)
            if attempt < retries:
                time.sleep(10 * attempt)
                continue
            return {"__error__": last}
    return {"__error__": last}


# --------------------------------------------------------------------------
# OpenStreetMap, Overpass
# --------------------------------------------------------------------------

OVERPASS_Q = """[out:json][timeout:{t}];
area["ISO3166-2"="US-{st}"]->.a;
(
  nwr["website"]["addr:postcode"](area.a);
  nwr["contact:website"]["addr:postcode"](area.a);
);
out tags center;
"""


def osm_tags_to_row(el, state, release):
    tg = el.get("tags", {})
    url = normalise_url(tg.get("website") or tg.get("contact:website"))
    if not url:
        return None
    zipc = tg.get("addr:postcode", "")
    if not ZIP5_RE.search(zipc or ""):
        return None
    house = tg.get("addr:housenumber", "")
    street = tg.get("addr:street", "")
    street_full = " ".join(x for x in (house, street) if x).strip()
    c = el.get("center") or {}
    lat = el.get("lat", c.get("lat"))
    lon = el.get("lon", c.get("lon"))
    category = (tg.get("amenity") or tg.get("shop") or tg.get("office")
                or tg.get("tourism") or tg.get("healthcare") or tg.get("leisure"))
    return build_row(
        "osm", f"{el.get('type','?')}/{el.get('id','?')}", release,
        tg.get("name"), street_full, tg.get("addr:city"),
        tg.get("addr:state") or state, zipc, url, lat, lon, category)


def cmd_osm_overpass(args):
    require_table()
    states = [s.strip().upper() for s in args.states.split(",")] if args.states else list(STATES)
    release = args.release or time.strftime("%Y-%m-%d")
    allrows, failed = [], []
    for st in states:
        q = OVERPASS_Q.format(t=args.timeout, st=st)
        print(f"  {st} ...", end="", flush=True)
        d = http_json(OVERPASS, data=urllib.parse.urlencode({"data": q}),
                      headers={"Content-Type": "application/x-www-form-urlencoded"},
                      timeout=args.timeout + 30, max_backoff=args.max_backoff)
        if "__error__" in d:
            print(f" FAILED ({d['__error__']})")
            failed.append(st)
            continue
        rows = [r for r in (osm_tags_to_row(e, st, release)
                            for e in d.get("elements", [])) if r]
        print(f" {len(rows):,}")
        allrows.extend(rows)
        time.sleep(args.sleep)
    # Replace only on a full clean run; a partial run must not delete states it
    # did not re-fetch.
    full = not args.states and not failed
    load_rows("osm", allrows, replace=full or bool(args.replace))
    if failed:
        print(f"\n  FAILED states (too large for Overpass): {','.join(failed)}")
        print("  Use osm-pbf for these. Overpass cannot serve CA or NY in one query.")


# --------------------------------------------------------------------------
# OpenStreetMap, pre-filtered Geofabrik extract
# --------------------------------------------------------------------------

def cmd_osm_pbf(args):
    """Load a GeoJSON export produced by osmium from a Geofabrik .osm.pbf.

    Prepare it like this (osmium-tool, not this script):

      curl -L -O https://download.geofabrik.de/north-america/us-latest.osm.pbf
      osmium tags-filter us-latest.osm.pbf -o filtered.osm.pbf \\
          nwr/website nwr/contact:website
      osmium export filtered.osm.pbf -f geojsonseq --add-unique-id=type_id \\
          -o filtered.geojsonseq

    geojsonseq (one feature per line) is used rather than a single GeoJSON
    document so this streams instead of loading 11 GB into memory.
    """
    require_table()
    release = args.release or time.strftime("%Y-%m-%d")
    rows, seen_bad = [], 0
    with open(args.input, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip().lstrip("\x1e")   # RS, if geojson-seq used it
            if not line or line[0] != "{":
                continue
            try:
                feat = json.loads(line)
            except json.JSONDecodeError:
                seen_bad += 1
                continue
            tg = feat.get("properties") or {}
            geom = feat.get("geometry") or {}
            coords = geom.get("coordinates") or []
            lon = lat = None
            if geom.get("type") == "Point" and len(coords) == 2:
                lon, lat = coords[0], coords[1]
            el = {"type": "", "id": feat.get("id") or tg.get("@id") or "",
                  "tags": tg, "lat": lat, "lon": lon}
            r = osm_tags_to_row(el, tg.get("addr:state", ""), release)
            if r:
                r[1] = str(el["id"])
                rows.append(r)
            if len(rows) >= args.batch:
                load_rows("osm", rows, replace=False)
                rows = []
    load_rows("osm", rows, replace=False)
    if seen_bad:
        print(f"  {seen_bad:,} unparseable lines skipped.")


# --------------------------------------------------------------------------
# NCES IPEDS
# --------------------------------------------------------------------------

def cmd_nces_ipeds(args):
    require_table()
    url = IPEDS.format(year=args.year)
    print(f"Downloading {url} ...", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=240) as r:
            blob = r.read()
    except (urllib.error.HTTPError, OSError) as exc:
        sys.exit(f"IPEDS download failed: {exc}")
    z = zipfile.ZipFile(io.BytesIO(blob))
    member = next((n for n in z.namelist() if n.lower().endswith(".csv")), None)
    if not member:
        sys.exit(f"No CSV inside {url}")
    # A revised file may appear alongside the original; prefer it.
    rev = [n for n in z.namelist() if n.lower().endswith(".csv") and "_rv" in n.lower()]
    if rev:
        member = rev[0]
    print(f"  using {member}")
    rows = []
    for d in read_csv_dicts(z.open(member).read()):
        url_ = normalise_url(d.get("WEBADDR"))
        if not url_ or not ZIP5_RE.search(d.get("ZIP") or ""):
            continue
        rows.append(build_row(
            "nces_ipeds", d.get("UNITID"), str(args.year), d.get("INSTNM"),
            d.get("ADDR"), d.get("CITY"), d.get("STABBR"), d.get("ZIP"),
            url_, d.get("LATITUDE"), d.get("LONGITUD"), "college"))
    load_rows("nces_ipeds", rows)


# --------------------------------------------------------------------------
# Wikidata
# --------------------------------------------------------------------------

# Two endpoints for the same data.
#
# QLever is the default. It is an independent index of the same Wikidata dump,
# it answered a COUNT in under a second while WDQS was returning 504 to the
# identical query, and it is not affected by WDQS outages. Measured 2026-10-26:
# 29,858 US items with P6375 and P856, of which 26,088 carry a 5-digit ZIP.
#
# WDQS remains available with --endpoint wdqs. It is the canonical service, so
# it is worth keeping as a cross-check, but it is not what a bulk pull should
# depend on.
WD_ENDPOINTS = {
    "qlever": "https://qlever.dev/api/wikidata",
    "wdqs": "https://query.wikidata.org/sparql",
}

# ORDER BY ?item is not decoration. Without it, SPARQL OFFSET has no defined
# order, so two pages can overlap or skip rows and pagination is not
# reproducible. Ordering makes a given OFFSET mean the same thing on every run,
# which is what makes resuming correct rather than approximate.
#
# rdfs:label is used instead of the wikibase:label SERVICE because that service
# is a WDQS extension and QLever does not implement it.
WD_QUERY = """PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT ?item ?itemLabel ?addr ?site WHERE {{
  ?item wdt:P17 wd:Q30 ;
        wdt:P6375 ?addr ;
        wdt:P856 ?site ;
        rdfs:label ?itemLabel .
  FILTER(LANG(?itemLabel) = "en")
  FILTER(REGEX(STR(?addr), "[0-9]{{5}}"))
}}
ORDER BY ?item
LIMIT {limit} OFFSET {offset}
"""

WD_COUNT = """PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX wd: <http://www.wikidata.org/entity/>
SELECT (COUNT(*) AS ?n) WHERE {
  ?item wdt:P17 wd:Q30 ; wdt:P6375 ?addr ; wdt:P856 ?site .
  FILTER(REGEX(STR(?addr), "[0-9]{5}"))
}
"""

# The ZIP sits inside the address text. Prefer a ZIP that follows a 2-letter
# state code, which is the reliable form ("Nashville, TN, 37240"), and fall back
# to a trailing ZIP. Same precedence the chain's own freeform rule uses.
WD_ZIP_AFTER_STATE = re.compile(r"\b([A-Z]{2})[,\s]+(\d{5})(?:-\d{4})?\b")
WD_ZIP_AT_END = re.compile(r"(\d{5})(?:-\d{4})?\s*$")


def cmd_wikidata(args):
    """Pull every matching Wikidata item, resumably.

    Unbounded by default. --limit exists only to cap a deliberate smoke test;
    it is not a safety belt, and the earlier default of 50,000 was a number I
    picked without knowing the total. The total is 26,088, so that default
    happened not to truncate anything, which was luck rather than design.

    Three mechanisms stop a run, none of which lose work:
      --deadline-minutes  wall-clock budget for the whole pull
      --max-backoff       refuse a Retry-After longer than this
      page failure        stop, keep every page already merged

    Each page is merged as it arrives, so an interrupted pull keeps its
    progress and --resume continues from the rows already present.
    """
    require_table()
    endpoint = WD_ENDPOINTS[args.endpoint]
    release = args.release or time.strftime("%Y-%m-%d")
    started = time.monotonic()

    total = None
    d = http_json(endpoint + "?" + urllib.parse.urlencode(
        {"query": WD_COUNT, "format": "json"}),
        headers={"Accept": "application/sparql-results+json"},
        timeout=args.timeout, max_backoff=args.max_backoff)
    if "__error__" not in d:
        try:
            total = int(d["results"]["bindings"][0]["n"]["value"])
            print(f"  {endpoint} reports {total:,} matching items")
        except (KeyError, IndexError, ValueError):
            pass
    else:
        print(f"  count unavailable ({d['__error__']}); paging until a short page")

    # Resume from the number of rows already stored. That count is always LESS
    # than or equal to the offset actually reached, because rows whose address
    # has no parseable ZIP are fetched and then dropped. So resuming by count
    # can only re-fetch a little, never skip: the overlap is absorbed by the
    # ON CONFLICT merge, and no item can be missed. Resuming by a stored offset
    # would be tighter but would skip rows if the filter rate ever changed.
    offset = 0
    if args.resume:
        offset = int(psql("-qtA", "-c", "SELECT count(*) FROM lm_places_usa "
                                        "WHERE source = 'wikidata'").strip() or 0)
        print(f"  resuming from offset {offset:,}")

    # --limit counts rows fetched BY THIS RUN, not an absolute offset ceiling.
    # As a ceiling it combined with --resume to do nothing at all: resuming at
    # offset 961 with --limit 500 found 961 already past 500 and exited having
    # merged zero, which looks exactly like a failure.
    merged = 0
    stop_at = (offset + args.limit) if args.limit else 0
    while stop_at == 0 or offset < stop_at:
        if args.deadline_minutes and \
                (time.monotonic() - started) / 60.0 >= args.deadline_minutes:
            print(f"  deadline of {args.deadline_minutes} min reached; "
                  f"stopping with {merged:,} rows merged. Re-run with --resume.")
            break

        n = args.page if stop_at == 0 else min(args.page, stop_at - offset)
        q = WD_QUERY.format(limit=n, offset=offset)
        shown = f"/{total:,}" if total else ""
        print(f"  offset {offset:,}{shown} ...", end="", flush=True)
        d = http_json(endpoint + "?" + urllib.parse.urlencode(
            {"query": q, "format": "json"}),
            headers={"Accept": "application/sparql-results+json"},
            timeout=args.timeout, max_backoff=args.max_backoff)
        if "__error__" in d:
            print(f" FAILED ({d['__error__']})")
            print(f"  stopping with {merged:,} rows merged. Re-run with --resume, "
                  f"or try --endpoint "
                  f"{'wdqs' if args.endpoint == 'qlever' else 'qlever'}.")
            break

        binds = d.get("results", {}).get("bindings", [])
        print(f" {len(binds):,}")
        if not binds:
            break

        rows = []
        for b in binds:
            addr = b.get("addr", {}).get("value", "")
            site = normalise_url(b.get("site", {}).get("value"))
            if not site:
                continue
            m = WD_ZIP_AFTER_STATE.search(addr)
            if m:
                region, zipc = m.group(1), m.group(2)
            else:
                m2 = WD_ZIP_AT_END.search(addr)
                if not m2:
                    continue
                region, zipc = "", m2.group(1)
            qid = b.get("item", {}).get("value", "").rsplit("/", 1)[-1]
            rows.append(build_row(
                "wikidata", qid, release,
                b.get("itemLabel", {}).get("value"), addr, "", region, zipc,
                site, None, None, "wikidata"))

        # Merge per page, so an interrupted pull keeps what it already fetched.
        load_rows("wikidata", rows, replace=False)
        merged += len(rows)

        if len(binds) < n:
            break
        offset += n
        time.sleep(args.sleep)

    print(f"wikidata: {merged:,} rows merged this run.")


# --------------------------------------------------------------------------
# National Park Service
# --------------------------------------------------------------------------

def cmd_nps(args):
    require_table()
    key = args.api_key or os.environ.get("NPS_API_KEY")
    if not key:
        sys.exit("NPS needs a free key. Get one at\n"
                 "  https://www.nps.gov/subjects/developer/get-started.htm\n"
                 "then: export NPS_API_KEY=...\n\n"
                 "Note this source is near-worthless for our purpose: every park is\n"
                 "an nps.gov URL, so the whole feed collapses to a single host and a\n"
                 "single landmark address.")
    release = args.release or time.strftime("%Y-%m-%d")
    rows, start = [], 0
    while True:
        url = NPS_API + "?" + urllib.parse.urlencode(
            {"limit": 50, "start": start, "api_key": key})
        d = http_json(url, max_backoff=args.max_backoff)
        if "__error__" in d:
            sys.exit(f"NPS request failed: {d['__error__']}")
        data = d.get("data", [])
        if not data:
            break
        for p in data:
            site = normalise_url(p.get("url"))
            phys = next((a for a in p.get("addresses", [])
                         if a.get("type") == "Physical"), None)
            if not site or not phys:
                continue
            if not ZIP5_RE.search(phys.get("postalCode") or ""):
                continue
            rows.append(build_row(
                "nps", p.get("parkCode"), release, p.get("fullName"),
                phys.get("line1"), phys.get("city"), phys.get("stateCode"),
                phys.get("postalCode"), site,
                p.get("latitude") or None, p.get("longitude") or None, "park"))
        start += len(data)
        if start >= int(d.get("total", 0)):
            break
        time.sleep(args.sleep)
    load_rows("nps", rows)


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

def cmd_status(args):
    print(psql("-c", """
SELECT source,
       count(*)                                                   AS rows,
       count(DISTINCT lower(btrim(website)))                      AS distinct_websites,
       count(DISTINCT postcode)                                   AS distinct_zips,
       round(100.0 * count(DISTINCT lower(btrim(website)))
             / nullif(count(*),0), 1)                             AS pct_unique_hosts,
       count(*) FILTER (WHERE onpremises IS TRUE)                  AS onpremises_true
FROM lm_places_usa
GROUP BY 1
ORDER BY 2 DESC"""))
    print("pct_unique_hosts is the column that matters: a source where many rows "
          "share\none host contributes far fewer landmarks than its row count "
          "suggests.")


def main():
    p = argparse.ArgumentParser(
        description="Fetch additional landmark sources into lm_places_usa.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Every source here has BOTH a ZIP and a website. See readme.md "
               "for sources that were checked and rejected.")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(s):
        s.add_argument("--release", help="release tag recorded on each row "
                                         "(default: today)")
        s.add_argument("--sleep", type=float, default=2.0,
                       help="seconds between requests (default 2)")
        s.add_argument("--max-backoff", type=int, default=MAX_BACKOFF,
                       help=f"never sleep longer than this on a Retry-After "
                            f"(default {MAX_BACKOFF}, which is the only stated "
                            f"rate-limit interval observed: WDQS's 1 req/min)")
        return s

    o = common(sub.add_parser("osm-overpass", help="OSM via Overpass, per state"))
    o.add_argument("--states", help="comma-separated, e.g. MA,NH,VT "
                                    "(default: all 50 + DC)")
    o.add_argument("--timeout", type=int, default=180)
    o.add_argument("--replace", action="store_true",
                   help="delete existing osm rows first even on a partial run")

    b = common(sub.add_parser("osm-pbf", help="OSM from an osmium geojsonseq export"))
    b.add_argument("--input", required=True, help="path to the .geojsonseq file")
    b.add_argument("--batch", type=int, default=200000,
                   help="rows per COPY (default 200000)")

    n = common(sub.add_parser("nces-ipeds", help="NCES IPEDS colleges"))
    n.add_argument("--year", type=int, default=2023)

    w = common(sub.add_parser("wikidata", help="Wikidata items with P856 + P6375"))
    w.add_argument("--limit", type=int, default=0,
                   help="0 means ALL matching items, which is the default. Set a "
                        "number only to cap a deliberate smoke test")
    w.add_argument("--page", type=int, default=5000, help="rows per SPARQL page")
    w.add_argument("--endpoint", choices=sorted(WD_ENDPOINTS), default="qlever",
                   help="qlever (default, independent index, unaffected by WDQS "
                        "outages) or wdqs (canonical, useful as a cross-check)")
    w.add_argument("--resume", action="store_true",
                   help="continue from the wikidata rows already loaded instead "
                        "of starting at offset 0")
    w.add_argument("--deadline-minutes", type=int, default=0,
                   help="stop the whole pull after this many minutes, keeping "
                        "every page already merged (0 = no deadline)")
    w.add_argument("--timeout", type=int, default=180)

    s = common(sub.add_parser("nps", help="National Park Service (needs a key; low value)"))
    s.add_argument("--api-key")

    sub.add_parser("status", help="per-source row, host and ZIP counts")

    args = p.parse_args()
    {"osm-overpass": cmd_osm_overpass, "osm-pbf": cmd_osm_pbf,
     "nces-ipeds": cmd_nces_ipeds, "wikidata": cmd_wikidata,
     "nps": cmd_nps, "status": cmd_status}[args.cmd](args)


if __name__ == "__main__":
    main()
