#!/usr/bin/env python3
"""
Post-population enrichment for ovt_places_usa (run after parquet_to_pg.py's
postload.sql). Uses the `psql` command for ALL database access, so it uses
the same connection as your psql. Standard library only.

Subcommands:
  resolve  hostnames (from the first entry of the websites column) -> IPv4
           -> ip_address. Every leading protocol prefix (even 'http://https://' or
           'http:://') is stripped first; a host without a period or with whitespace
           is never resolved and gets the status 'does not resolve'
  rdap     run rdap-lookup.sh <ip> for each distinct ip_address not yet looked up,
           and write the result straight into the rows with that ip_address:
           url_location, url_location_zip and lookup_status (no cache table)
  status   fill/refresh lookup_status from the data already in the table and print
           a summary (rdap and resolve also do this)
  space    show free disk space for the data directory (WAL, temp files), the table's tablespace
           and the temp tablespace, and how big a chunk is
  registrants  split the stored url_location records into registrant_1 / registrant_2 and
           their ZIP codes (registrant_1_zip, registrant_2_zip); the rdap step fills the same
           columns for new lookups
  load-isps    load a file of ISP registrant names into the ISP table (isp_names)
  overture-zip establish each place's ZIP (overture_zip, with overture_zip_source): the Overture
           postcode, else a ZIP in the address text, else the one ZIP of the same locality
           and region; --dry-run counts rows with a website but no postcode
  onpremises   set onpremises, reading ISPs from the ISP table and CDN/cloud/web-host names
           from the provider table (both matched ignoring case): NULL if the place has no
           Overture ZIP; false if ANY registrant is a provider, since a provider's edge
           router never routes retail subscribers and the anchor is therefore unusable;
           otherwise true if every registrant is an ISP, or a NON-ISP registrant's ZIP
           equals / is adjacent to the Overture ZIP; else false; --dry-run only counts,
           per deciding rule. Supersedes `mark`, which was not durable across reruns
  report   list distinct url_location values with row counts (CSV file + stdout);
           --by-name groups by registrant name instead
  mark     set onpremises = false for rows whose url_location (or, with
           --by-name, registrant name) is listed in a file, one value per line
  all      resolve + rdap + report
  apply    legacy: copy an existing <table>_ip_rdap cache table (left over from
           the earlier version of the rdap step) into the main table

lookup_status values:
  NULL                  not RDAP-looked-up yet
  no_website            the place has no website URL (NULL, empty list or empty string)
  true                  RDAP lookup succeeded (url_location / url_location_zip set)
  placeholder IP        host resolved to a placeholder address (--placeholder-ip); not looked up
  does not resolve      website host has no public IPv4 address; not looked up
  outside ARIN          ARIN answered HTTP 303 (another registry's space); --retry-failed retries
  registrant not found  ARIN has no record (HTTP 404) or the record has no registrant; --retry-failed retries
  lookup error          timeout, HTTP error or unusable output; retried on every rerun

State for `resolve` is kept in <table>_host_ip (host, ip, error), so every distinct
host is looked up once and the step is resumable.

Typical run:
  python3 ovt_resolve_hosts.py rdap --limit 30 --random   # smoke test
  python3 ovt_resolve_hosts.py rdap
  python3 ovt_resolve_hosts.py report --by-name
  python3 ovt_resolve_hosts.py mark --by-name --providers-file providers.txt
"""

import argparse
import csv
import io
import ipaddress
import os
import re
import shutil
import socket
import http.client
import json
import subprocess
import threading
import types
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# Hostname from a URL, in this order:
#  1. markdown-link remnants such as 'https://x.com/a](https://x.com/a' or '[x.com](https://x.com)':
#     everything up to and including '](' is dropped;
#  2. every leading protocol identifier is stripped up to and including its slashes, however many
#     and however malformed ('http://https://x.com', 'http:://x.com', 'https:/x.com',
#     'http:///x.com'), and so are bare leading slashes ('//x.com') and stray '(' / '[';
#  3. userinfo, port, path and query are dropped; the host stops at any of  / : ? # whitespace
#     and at ( ) [ ] , so a terminal ')' or ']' never ends up in the host.
MD_RE = r"\]\((.*)$"
PROTO_RE = r"^[(\[\s]*(?:(?:[A-Za-z]+:+/+|/+)[(\[\s]*)*"
HOST_RE = r"^\s*(?:[^/@?#]*@)?([^/:?#\s()\[\]]+)"
# A host is only looked up if it has at least one period and no whitespace.
NOT_DOTTED_RE = r"\."
HAS_SPACE_RE = r"\s"

# For a text column holding a JSON array like '["http://a.com", ...]':
IS_ARRAY_RE = r"^\s*\["
JSON_FIRST_RE = r'^\s*\[\s*"([^"]*)"'


def q(ident):
    return '"' + ident.replace('"', '""') + '"'


def lit(text):
    return "'" + text.replace("'", "''") + "'"


def check_ident(label, value):
    if not IDENT.match(value):
        sys.exit(f"{label} '{value}' must match [A-Za-z_][A-Za-z0-9_]*")


# --------------------------------------------------------------------------
# psql helpers
# --------------------------------------------------------------------------
PSQL_ENV = None   # environment for every psql call (carries work_mem etc.); set in main()


HEARTBEAT_SECONDS = 15


def _psql_with_heartbeat(cmd, stdin_text, label):
    """Run psql, printing an elapsed-time heartbeat while it works.

    psql emits nothing until a statement completes, so a single long statement
    looks exactly like a hang. The locality/ZIP scan crosses the whole table in
    one statement, an onpremises chunk can take minutes, and the periodic
    VACUUM took 1,456 seconds in one observed run with no output at all. During
    any of those there was no way to tell "still working" from "stuck", which is
    the difference between waiting and intervening.

    The heartbeat carries no information beyond elapsed time, deliberately:
    psql cannot report intra-statement progress, and inventing a percentage
    would be a fabrication. Elapsed time is what is actually known.
    """
    t0 = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if stdin_text is not None else None,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=PSQL_ENV)

    captured = {}

    def _communicate():
        captured["result"] = proc.communicate(input=stdin_text)

    worker = threading.Thread(target=_communicate, daemon=True)
    worker.start()

    next_beat = HEARTBEAT_SECONDS
    while worker.is_alive():
        worker.join(timeout=1.0)
        elapsed = time.monotonic() - t0
        if worker.is_alive() and elapsed >= next_beat:
            print(f"    {label}: still running, {elapsed:,.0f}s elapsed", flush=True)
            next_beat += HEARTBEAT_SECONDS

    out, err = captured.get("result", ("", ""))
    return proc.returncode, out or "", err or ""


def run_script(script, label="sql"):
    """Run a multi-statement script (may contain COPY ... FROM STDIN data) in one transaction."""
    code, out, err = _psql_with_heartbeat(
        ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1", "-f", "-"],
        script, label)
    if code != 0:
        sys.exit(f"psql failed:\n{err.strip()}")
    return out


def query_csv(select_sql, label=None):
    """Run a SELECT and return its rows as lists of strings (NULL -> '').

    Heartbeated like run_script and run_sql. This one was missed, and it is the
    worst place to miss it: the rdap step starts with a SELECT DISTINCT over
    every row of the target table, which on 14 million rows is a minutes-long
    silence before the first progress line. On a restart that is exactly the
    moment the operator is asking whether anything is happening.
    """
    if label is None:
        label = "query"
    code, out, err = _psql_with_heartbeat(
        ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c",
         f"COPY ({select_sql}) TO STDOUT WITH CSV"], None, label)
    if code != 0:
        sys.exit(f"psql failed:\n{err.strip()}")
    return list(csv.reader(io.StringIO(out)))


def csv_text(rows):
    buf = io.StringIO()
    csv.writer(buf, lineterminator="\n").writerows(rows)
    return buf.getvalue()


# --------------------------------------------------------------------------
# setup
# --------------------------------------------------------------------------
def use_temp_tablespace(ctx):
    """Send this script's temp files (sorts, hash-join spills, temp tables) to a roomy tablespace.
    'auto' = the main table's own tablespace when it is not the default one; a name = that
    tablespace; 'none' = leave PostgreSQL's setting alone. Needs CREATE on the tablespace."""
    want = ctx.args.temp_tablespace
    if want == "none":
        return
    if want == "auto":
        rows = query_csv(f"""SELECT t.spcname FROM pg_class c JOIN pg_tablespace t ON t.oid = c.reltablespace
                             WHERE c.oid = {lit(ctx.target)}::regclass""")
        want = rows[0][0] if rows and rows[0] else ""
        if not want:
            return
    ok = query_csv(f"SELECT has_tablespace_privilege({lit(want)}, 'CREATE')")
    if not ok or ok[0][0] != "t":
        print(f"NOTE: no CREATE privilege on tablespace {want}, so temp files stay where PostgreSQL puts "
              f"them (--temp-tablespace none silences this).", file=sys.stderr)
        return
    PSQL_ENV["PGOPTIONS"] = (PSQL_ENV.get("PGOPTIONS", "") + f" -c temp_tablespaces={want}").strip()


class Ctx:
    def __init__(self, args):
        check_ident("--table", args.table)
        check_ident("--pg-schema", args.pg_schema)
        check_ident("--url-column", args.url_column)
        self.args = args
        self.placeholders = []
        for ip in args.placeholder_ip.split(","):
            ip = ip.strip()
            if ip:
                try:
                    self.placeholders.append(str(ipaddress.ip_address(ip)))
                except ValueError:
                    sys.exit(f"--placeholder-ip: '{ip}' is not an IP address")
        if not self.placeholders:
            self.placeholders = ["0.0.0.0"]      # never stored, so matches nothing
        self.target = f"{q(args.pg_schema)}.{q(args.table)}"
        self.host_ip = f"{q(args.pg_schema)}.{q(args.table + '_host_ip')}"
        self.ip_rdap = f"{q(args.pg_schema)}.{q(args.table + '_ip_rdap')}"

        rows = query_csv(
            "SELECT column_name, data_type FROM information_schema.columns "
            f"WHERE table_schema = {lit(args.pg_schema)} AND table_name = {lit(args.table)}")
        self.cols = cols = {name: dtype for name, dtype in rows}
        if not cols:
            sys.exit(f"Table {args.pg_schema}.{args.table} not found.")
        missing = [c for c in ("ip_address", "url_location", "onpremises") if c not in cols]
        if missing:
            sys.exit(f"Missing column(s) {missing}. Run ovt_places_usa_add_url_columns.sql "
                     f"(and ovt_places_usa_add_ip_columns.sql) first.")
        if args.url_column not in cols:
            sys.exit(f"URL column '{args.url_column}' not found. Columns: {sorted(cols)}")
        kind = cols[args.url_column]
        if kind in ("jsonb", "json"):
            raw = f"(t.{q(args.url_column)}->>0)"      # first array element
        elif kind in ("text", "character varying"):
            # Column still holds the JSON array as text (e.g. '["http://a.com"]'):
            # take the first quoted string; a value not starting with '[' is used as-is.
            c = f"t.{q(args.url_column)}"
            raw = (f"(CASE WHEN {c} ~ {lit(IS_ARRAY_RE)} "
                   f"THEN substring({c} from {lit(JSON_FIRST_RE)}) ELSE {c} END)")
        else:
            sys.exit(f"Unsupported type for {args.url_column}: {kind}")
        url = (f"(CASE WHEN {raw} LIKE '%](%' THEN substring({raw} from {lit(MD_RE)}) "
               f"ELSE btrim({raw}) END)")
        self.host_sql = (f"lower(rtrim(substring(regexp_replace({url}, {lit(PROTO_RE)}, '') "
                         f"from {lit(HOST_RE)}), '.'))")
        use_temp_tablespace(self)

    def create_helpers(self):
        run_script(f"""
CREATE TABLE IF NOT EXISTS {self.host_ip} (
    host text PRIMARY KEY, ip inet, error text, resolved_at timestamptz DEFAULT now());
""")


# --------------------------------------------------------------------------
# resolve
# --------------------------------------------------------------------------
def resolve_one(host):
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror as exc:
        return host, None, f"dns: {exc.strerror or exc}"
    except (UnicodeError, OSError) as exc:
        return host, None, f"{type(exc).__name__}: {exc}"
    for info in infos:
        ip = info[4][0]
        if ipaddress.ip_address(ip).is_global:
            return host, ip, None
    return host, None, "no global IPv4 address"


def store_hosts(ctx, rows):
    if not rows:
        return
    run_script(f"""
CREATE TEMP TABLE stage (host text, ip inet, error text) ON COMMIT DROP;
COPY stage FROM STDIN WITH CSV;
{csv_text(rows)}\\.
INSERT INTO {ctx.host_ip} (host, ip, error)
SELECT host, ip, error FROM stage
ON CONFLICT (host) DO UPDATE
    SET ip = EXCLUDED.ip, error = EXCLUDED.error, resolved_at = now();
""")


def cmd_resolve(args):
    ctx = Ctx(args)
    ctx.create_helpers()
    retry = "true" if args.retry_failed else "false"
    hosts = [r[0] for r in query_csv(rf"""
SELECT host FROM (SELECT DISTINCT {ctx.host_sql} AS host FROM {ctx.target} t) d
WHERE host ~ '\.' AND host !~ '\s'
  AND NOT EXISTS (SELECT 1 FROM {ctx.host_ip} h
                  WHERE h.host = d.host AND (h.ip IS NOT NULL OR NOT {retry}))
ORDER BY host""")]
    if args.limit:
        hosts = hosts[:args.limit]
    print(f"Resolving {len(hosts):,} hosts with {args.dns_threads} threads", flush=True)

    t0, done, ok, pending = time.time(), 0, 0, []
    with ThreadPoolExecutor(max_workers=args.dns_threads) as ex:
        futs = [ex.submit(resolve_one, h) for h in hosts]
        try:
            for fut in as_completed(futs):
                host, ip, err = fut.result()
                pending.append([host, ip or "", err or ""])
                done += 1
                ok += ip is not None
                if len(pending) >= 2000:
                    store_hosts(ctx, pending)
                    pending = []
                    print(f"  {done:,}/{len(hosts):,} done, {ok:,} resolved, "
                          f"{time.time() - t0:,.0f}s", flush=True)
        except KeyboardInterrupt:
            for f in futs:
                f.cancel()
            print("Interrupted; saving finished lookups.", file=sys.stderr)
            store_hosts(ctx, pending)
            sys.exit(130)
    store_hosts(ctx, pending)
    print(f"Lookups finished: {done:,} hosts, {ok:,} resolved to a global IPv4.")

    print("Updating ip_address ...", flush=True)
    run_script(f"""
UPDATE {ctx.target} t SET ip_address = h.ip
FROM {ctx.host_ip} h
WHERE h.ip IS NOT NULL AND {ctx.host_sql} = h.host AND t.ip_address IS DISTINCT FROM h.ip;
ANALYZE {ctx.target};
""")
    n = query_csv(f"SELECT count(*) FROM {ctx.target} WHERE ip_address IS NOT NULL")[0][0]
    print(f"Rows with ip_address: {int(n):,}")
    refresh_statuses(ctx)


# --------------------------------------------------------------------------
# apply: copy RDAP results into the main table (url_location + url_location_zip)
# --------------------------------------------------------------------------
# The ZIP code is taken from the "Geographic Address" part of the stored result.
# Heuristic, tried in order: (1) a 5-digit ZIP right after a two-letter state code
# ("CA 94107" / "CA, 94107"); (2) a 5-digit ZIP at the end of the address, optionally
# followed by a country. ZIP+4 is reduced to 5 digits. Otherwise NULL.
ADDR_RE = r"Geographic Address: ([^|]*)"
ZIP_AFTER_STATE_RE = r"\y[A-Z]{2}[, ]+([0-9]{5})(?:-[0-9]{4})?\y"
ZIP_AT_END_RE = r",[ ]*([0-9]{5})(?:-[0-9]{4})?(?:,[ ]*(?:US|USA|United States))?[ ]*$"


def apply_results(ctx):
    ensure_column(ctx, "url_location_zip")
    run_script(f"""
ALTER TABLE {ctx.ip_rdap} ADD COLUMN IF NOT EXISTS zip text;

UPDATE {ctx.ip_rdap} r
SET zip = COALESCE(substring(a.addr from {lit(ZIP_AFTER_STATE_RE)}),
                   substring(a.addr from {lit(ZIP_AT_END_RE)}))
FROM (SELECT ip, substring(result from {lit(ADDR_RE)}) AS addr
      FROM {ctx.ip_rdap} WHERE result IS NOT NULL AND zip IS NULL) a
WHERE r.ip = a.ip;

UPDATE {ctx.target} t SET url_location = r.result, url_location_zip = r.zip
FROM {ctx.ip_rdap} r
WHERE r.result IS NOT NULL AND t.ip_address = r.ip
  AND (t.url_location IS DISTINCT FROM r.result OR t.url_location_zip IS DISTINCT FROM r.zip);
ANALYZE {ctx.target};
""")
    rows = query_csv(f"""SELECT count(*) FILTER (WHERE url_location IS NOT NULL),
                                count(*) FILTER (WHERE url_location_zip IS NOT NULL)
                         FROM {ctx.target}""")[0]
    print(f"Rows with url_location: {int(rows[0]):,}; with url_location_zip: {int(rows[1]):,}")


def cmd_apply(args):
    """Legacy: copy results from an existing <table>_ip_rdap cache table (from the earlier version
    of the rdap step) into the main table. The rdap step no longer uses that table."""
    ctx = Ctx(args)
    if query_csv(f"SELECT to_regclass({lit(ctx.ip_rdap)}) IS NOT NULL")[0][0] != "t":
        sys.exit(f"No cache table {ctx.ip_rdap}; nothing to apply (the rdap step now writes directly).")
    done, total = query_csv(f"""SELECT count(*) FILTER (WHERE result IS NOT NULL), count(*)
                                FROM {ctx.ip_rdap}""")[0]
    print(f"{ctx.ip_rdap}: {int(done):,} IPs with a result out of {int(total):,} looked up so far")
    print("Copying RDAP results into the main table ...", flush=True)
    apply_results(ctx)


# --------------------------------------------------------------------------
# rdap
# --------------------------------------------------------------------------
# Lines of rdap-lookup.sh output that vary per IP or are decoration; dropped so that
# every IP of the same registrant yields the same stored text.
RDAP_NOISE = re.compile(r"^\s*(=+.*=+|-{3,}|Query Target IP\b.*|Phone\b.*)\s*$", re.I)

# Failures that will not change on a retry: skip the retry delay.
RDAP_NO_RETRY = ("HTTP 303", "HTTP 404", "NOT_FOUND")


def clean_rdap(stdout, name_only):
    lines = [ln.strip() for ln in stdout.splitlines()
             if ln.strip() and not RDAP_NOISE.match(ln)]
    # The script exits 0 with "Registrant Entity : NOT_FOUND" when ARIN has no registrant.
    if any(ln.lower().startswith("registrant entity") and "NOT_FOUND" in ln for ln in lines):
        return ""
    if name_only:
        for ln in lines:
            if ln.lower().startswith("registrant entity"):
                return ln.split(":", 1)[1].strip() if ":" in ln else ln
        return ""
    return " | ".join(lines)


RDAP_HOST = "rdap.arin.net"

# One HTTPS connection per worker thread, reused across lookups.
#
# WHY THIS EXISTS. Each lookup used to spawn rdap-lookup.sh, which spawns curl,
# which opens a fresh TCP connection and performs a fresh TLS handshake. Measured
# against ARIN: 20 separate curl processes took 3.833s, while one curl process
# reusing the connection for the same 20 URLs took 0.121s. That is 32 times
# faster, because the per-call breakdown is dns 0.001s, tcp connect 0.061s, tls
# 0.066s, leaving only about 0.060s for the query itself. Setup was 68% of every
# call and was paid again on every IP.
_rdap_local = threading.local()


def _rdap_conn():
    conn = getattr(_rdap_local, "conn", None)
    if conn is None:
        conn = http.client.HTTPSConnection(RDAP_HOST, timeout=30)
        _rdap_local.conn = conn
    return conn


def _rdap_drop_conn():
    conn = getattr(_rdap_local, "conn", None)
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
    _rdap_local.conn = None


def _vcard_props(entity):
    arr = entity.get("vcardArray")
    if not isinstance(arr, list) or len(arr) < 2 or not isinstance(arr[1], list):
        return []
    return [p for p in arr[1] if isinstance(p, list) and len(p) >= 4]


def _vcard_field(entity, name):
    for p in _vcard_props(entity):
        if p[0] == name:
            return p[3] if isinstance(p[3], str) else None
    return None


def _flatten_str(v):
    if isinstance(v, list):
        out = []
        for x in v:
            out.extend(_flatten_str(x))
        return out
    if isinstance(v, str):
        return [v]
    return []


def _vcard_adr(entity):
    """Mirror of the script's adr_text: joined address parts, else the label."""
    adr = None
    for p in _vcard_props(entity):
        if p[0] == "adr":
            adr = p
            break
    if adr is None:
        return None
    parts = [x for x in _flatten_str(adr[3]) if x]
    if parts:
        return ", ".join(parts)
    label = adr[1].get("label") if isinstance(adr[1], dict) else None
    return label.replace("\n", ", ") if isinstance(label, str) else None


def _all_role_objects(node, acc):
    """Mirror of jq '.. | objects | select(has("roles"))', recursive descent."""
    if isinstance(node, dict):
        if "roles" in node:
            acc.append(node)
        for v in node.values():
            _all_role_objects(v, acc)
    elif isinstance(node, list):
        for v in node:
            _all_role_objects(v, acc)


def _jq_sort_key(rec):
    # jq's unique sorts objects by their key-value pairs in sorted key order,
    # which for these records is adr, email, name, org. jq orders null before
    # any string, so None maps to a lower bucket.
    out = []
    for k in ("adr", "email", "name", "org"):
        v = rec.get(k)
        out.append((0, "") if v is None else (1, v))
    return tuple(out)


def rdap_native(ip, timeout):
    """Fetch and format one ARIN RDAP record, byte-identical to rdap-lookup.sh.

    Returns (stdout_text, ok). ok is False for the cases where the script would
    have exited non-zero, and the text then carries the same "HTTP <code>"
    marker classify_error already looks for, so lookup_status is unchanged.
    """
    path = "/registry/ip/" + ip
    for attempt in (1, 2):
        try:
            conn = _rdap_conn()
            conn.timeout = timeout
            conn.request("GET", path, headers={
                "Accept": "application/rdap+json",
                "User-Agent": "trugeo-rdap/1.0",
                "Connection": "keep-alive"})
            resp = conn.getresponse()
            body = resp.read()
            status = resp.status
            break
        except Exception as exc:
            _rdap_drop_conn()
            if attempt == 2:
                return (f"Error: curl failed to reach {RDAP_HOST} "
                        f"(network/DNS/timeout). {exc}"), False
    if status != 200:
        return (f"Error: ARIN RDAP returned HTTP {status} for {ip}."), False
    try:
        doc = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return (f"Error: Network execution target failed to return valid JSON "
                f"from {RDAP_HOST}"), False

    ents = []
    _all_role_objects(doc, ents)
    recs = []
    for e in ents:
        roles = e.get("roles") or []
        if "registrant" not in roles:
            continue
        recs.append({"name": _vcard_field(e, "fn"),
                     "org": _vcard_field(e, "org"),
                     "adr": _vcard_adr(e),
                     "email": _vcard_field(e, "email")})
    seen, uniq = set(), []
    for r in sorted(recs, key=_jq_sort_key):
        k = (r["adr"], r["email"], r["name"], r["org"])
        if k not in seen:
            seen.add(k)
            uniq.append(r)

    country = doc.get("country") or ""
    out = ["=== ARIN VCARD GEOGRAPHIC RECORD ===",
           f"Query Target IP   : {ip}"]
    if not uniq:
        out.append("Registrant Entity : NOT_FOUND")
        out.append("Geographic Address: NOT_POPULATED")
        if country:
            out.append(f"Network Country    : {country}")
    else:
        for r in uniq:
            name, org = r["name"] or "", r["org"] or ""
            out.append("------------------------------------")
            out.append(f"Registrant Entity : {name or org or 'NOT_FOUND'}")
            if org and org != name:
                out.append(f"Organization      : {org}")
            out.append(f"Geographic Address: {r['adr'] or 'NOT_POPULATED'}")
            if r["email"]:
                out.append(f"Email             : {r['email']}")
        if country:
            out.append(f"Network Country    : {country}")
    out.append("====================================")
    return "\n".join(out) + "\n", True


def rdap_one(script, ip, timeout, attempts, delay, name_only=False, native=True):
    """One RDAP lookup, native by default.

    native=True does the HTTP in-process on a connection kept alive per thread,
    which avoids a TCP and TLS handshake per IP. Verified byte-identical to the
    script on 15 addresses, including the NOT_FOUND, outside-ARIN and
    multi-registrant cases, and 2.9 times faster on a single thread here.

    native=False keeps the original path, spawning the script. It stays because
    the script is the reference implementation: if the two ever disagree, the
    script is right by definition and this flag is how to fall back.
    """
    err = "unknown"
    for attempt in range(1, attempts + 1):
        try:
            if native:
                text, ok = rdap_native(ip, timeout)
                r = types.SimpleNamespace(
                    returncode=0 if ok else 1, stdout=text, stderr="")
            else:
                r = subprocess.run([script, ip], capture_output=True,
                                   text=True, timeout=timeout)
            if r.returncode == 0:
                result = clean_rdap(r.stdout, name_only)
                if result:
                    if delay:
                        time.sleep(delay)
                    return ip, result, None
                err = ("registrant NOT_FOUND" if "NOT_FOUND" in r.stdout
                       else "no usable output: " + " / ".join(r.stdout.split())[:200])
            else:
                err = f"exit {r.returncode}: {(r.stderr.strip() or r.stdout.strip())[:200]}"
        except subprocess.TimeoutExpired:
            err = f"timeout after {timeout}s"
        except OSError as exc:
            return ip, None, f"cannot run script: {exc}"
        if any(t in err for t in RDAP_NO_RETRY):
            break
        if attempt < attempts:
            time.sleep(2 * attempt)
    return ip, None, err


IP_INDEX_RE = r"\(ip_address\)"

# Values of the lookup_status column. NULL = not RDAP-looked-up yet.
STATUS_NO_WEBSITE = "no_website"            # the place has no (usable first) website URL
STATUS_OK = "true"                          # RDAP lookup succeeded
STATUS_PLACEHOLDER = "placeholder IP"       # host resolved to a placeholder address (--placeholder-ip)
STATUS_NO_RESOLVE = "does not resolve"      # website host has no public IPv4 address
STATUS_NOT_ARIN = "outside ARIN"            # ARIN answered HTTP 303 (address belongs to another registry)
STATUS_NO_REGISTRANT = "registrant not found"   # ARIN has no record (HTTP 404) or the record has no registrant
STATUS_ERROR = "lookup error"               # anything else (timeout, HTTP error, bad output); retried by default


def classify_error(err):
    if "HTTP 303" in err:
        return STATUS_NOT_ARIN
    if "NOT_FOUND" in err or "HTTP 404" in err:     # ARIN has no record, or no registrant in it
        return STATUS_NO_REGISTRANT
    return STATUS_ERROR


# --- registrants: a stored record can hold two registrant blocks; each is kept with its own ZIP
ZIP_AFTER_STATE_PY = re.compile(r"\b[A-Z]{2}[, ]+([0-9]{5})(?:-[0-9]{4})?\b")
ZIP_AT_END_PY = re.compile(r",[ ]*([0-9]{5})(?:-[0-9]{4})?(?:,[ ]*(?:US|USA|United States))?[ ]*$")
LABEL_PY = re.compile(r"^\s*([A-Za-z ]+?)\s*:\s*(.*)$")
KNOWN_LABELS = {"registrant entity", "organization", "geographic address", "email", "network country"}
REG_COLUMNS = ["registrant_1", "registrant_1_zip", "registrant_2", "registrant_2_zip"]


def zip_from_address(addr):
    """Same heuristic as the SQL ZIP_AFTER_STATE_RE / ZIP_AT_END_RE: a ZIP right after a state
    code, else a ZIP at the end of the address (optionally followed by the country)."""
    m = ZIP_AFTER_STATE_PY.search(addr) or ZIP_AT_END_PY.search(addr)
    return m.group(1) if m else None


def parse_registrants(result):
    """Split a stored cleaned record ('Registrant Entity : A | Geographic Address: ... | Registrant
    Entity : B | ...') into [{'name': ..., 'zip': ...}, ...], one per registrant block."""
    if not result:
        return []
    if not re.search(r"Registrant Entity\s*:", result):      # --name-only format: the bare name
        return [{"name": result.strip(), "zip": None}]
    regs = []
    for block in re.split(r" \| (?=Registrant Entity\s*:)", result):
        name = addr = None
        cur = None
        for part in block.split(" | "):
            m = LABEL_PY.match(part)
            label = m.group(1).strip().lower() if m else None
            if label in KNOWN_LABELS:
                cur, value = label, m.group(2).strip()
                if label == "registrant entity":
                    name = value
                elif label == "geographic address":
                    addr = value
            elif cur == "geographic address" and addr is not None:
                # a multi-line address: the later lines carry no label (', Suite E, Manhattan, KS, 66502')
                addr = f"{addr} {part.strip()}"
        if name and name != "NOT_FOUND":
            regs.append({"name": name, "zip": zip_from_address(addr) if addr else None})
    return regs


def registrant_fields(result):
    """[registrant_1, registrant_1_zip, registrant_2, registrant_2_zip]; '' (stored as NULL) if absent."""
    regs = parse_registrants(result)
    out = []
    for i in range(2):
        r = regs[i] if i < len(regs) else {"name": "", "zip": ""}
        out += [r["name"] or "", r["zip"] or ""]
    return out


def run_sql(sql, label=None):
    """Run one statement outside a transaction block (needed for CREATE INDEX CONCURRENTLY)."""
    if label is None:
        label = sql.strip().split(None, 2)[0].upper() if sql.strip() else "sql"
    code, _, err = _psql_with_heartbeat(
        ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql], None, label)
    if code != 0:
        sys.exit(f"psql failed:\n{err.strip()}")


def ensure_column(ctx, name):
    # Look in the catalog first: ALTER TABLE takes an ACCESS EXCLUSIVE lock even when
    # the column already exists, which would queue behind any long-running update.
    if name not in ctx.cols:
        print(f"Adding column {name} ...", flush=True)
        run_script(f"ALTER TABLE {ctx.target} ADD COLUMN {q(name)} text;")
        ctx.cols[name] = "text"


def ensure_ip_index(ctx):
    """Each RDAP result is written to the rows having that ip_address, which needs an index."""
    rows = query_csv(f"""
SELECT c.relname, i.indisvalid
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = {lit(ctx.args.pg_schema)} AND t.relname = {lit(ctx.args.table)}
  AND pg_get_indexdef(i.indexrelid) ~ {lit(IP_INDEX_RE)}""")
    if any(valid == "t" for _, valid in rows):
        return
    if rows:
        sys.exit(f"Index {rows[0][0]} on ip_address exists but is not valid (an interrupted build?). "
                 f"Drop it with: DROP INDEX {q(ctx.args.pg_schema)}.{q(rows[0][0])}; and rerun.")
    print("Creating an index on ip_address (a few minutes on a large table) ...", flush=True)
    run_sql(f"CREATE INDEX CONCURRENTLY IF NOT EXISTS {q(ctx.args.table + '_ip_address_idx')} "
            f"ON {ctx.target} (ip_address)")


def counted(sql):
    """Run an UPDATE as its own statement and return the number of rows it changed."""
    return int(query_csv(f"WITH u AS ({sql} RETURNING 1) SELECT count(*) FROM u")[0][0])


def refresh_statuses(ctx, verbose=True):
    """Derive lookup_status from what is already in the table (idempotent; each step touches only
    rows whose status would change)."""
    ensure_column(ctx, "lookup_status")
    ctx.create_helpers()          # the host cache must exist for the 'does not resolve' step
    t = ctx.target
    ph = ", ".join(lit(ip) for ip in ctx.placeholders)
    steps = [
        ("no_website", f"UPDATE {t} t SET lookup_status = {lit(STATUS_NO_WEBSITE)} "
                       f"WHERE coalesce({ctx.host_sql}, '') = '' "
                       f"AND t.lookup_status IS DISTINCT FROM {lit(STATUS_NO_WEBSITE)}"),
        ("stale no_website cleared", f"UPDATE {t} t SET lookup_status = NULL "
                                     f"WHERE t.lookup_status = {lit(STATUS_NO_WEBSITE)} "
                                     f"AND coalesce({ctx.host_sql}, '') <> ''"),
        ("placeholder IP", f"UPDATE {t} SET lookup_status = {lit(STATUS_PLACEHOLDER)} "
                           f"WHERE ip_address IN ({ph}) AND lookup_status IS DISTINCT FROM {lit(STATUS_PLACEHOLDER)}"),
        ("stale placeholder IP cleared", f"UPDATE {t} SET lookup_status = NULL "
                                         f"WHERE lookup_status = {lit(STATUS_PLACEHOLDER)} AND ip_address NOT IN ({ph})"),
        ("does not resolve", f"UPDATE {t} t SET lookup_status = {lit(STATUS_NO_RESOLVE)} FROM {ctx.host_ip} h "
                             f"WHERE h.ip IS NULL AND t.ip_address IS NULL AND {ctx.host_sql} = h.host "
                             f"AND t.lookup_status IS DISTINCT FROM {lit(STATUS_NO_RESOLVE)}"),
        ("does not resolve (host without a period, or with whitespace)",
         f"UPDATE {t} t SET lookup_status = {lit(STATUS_NO_RESOLVE)} "
         f"WHERE t.ip_address IS NULL AND coalesce({ctx.host_sql}, '') <> '' "
         f"AND ({ctx.host_sql} !~ {lit(NOT_DOTTED_RE)} OR {ctx.host_sql} ~ {lit(HAS_SPACE_RE)}) "
         f"AND t.lookup_status IS DISTINCT FROM {lit(STATUS_NO_RESOLVE)}"),
        ("stale does-not-resolve cleared", f"UPDATE {t} SET lookup_status = NULL "
                                           f"WHERE lookup_status = {lit(STATUS_NO_RESOLVE)} AND ip_address IS NOT NULL"),
        ("lookup succeeded", f"UPDATE {t} SET lookup_status = {lit(STATUS_OK)} "
                             f"WHERE url_location IS NOT NULL AND lookup_status IS DISTINCT FROM {lit(STATUS_OK)}"),
    ]
    if query_csv(f"SELECT to_regclass({lit(ctx.ip_rdap)}) IS NOT NULL")[0][0] == "t":
        steps.append(("failures from the old _ip_rdap cache", f"""UPDATE {t} t SET lookup_status = CASE
    WHEN r.error LIKE '%HTTP 303%' THEN {lit(STATUS_NOT_ARIN)}
    WHEN r.error LIKE '%NOT_FOUND%' OR r.error LIKE '%HTTP 404%' THEN {lit(STATUS_NO_REGISTRANT)}
    ELSE {lit(STATUS_ERROR)} END
FROM {ctx.ip_rdap} r WHERE r.result IS NULL AND t.ip_address = r.ip AND t.lookup_status IS NULL"""))
    for label, sql in steps:
        n = counted(sql)
        if verbose and n:
            print(f"  status: {label}: {n:,} rows", flush=True)


def print_status_summary(ctx):
    rows = query_csv(f"""SELECT coalesce(lookup_status, '(NULL)'), count(*) FROM {ctx.target}
                         GROUP BY lookup_status ORDER BY count(*) DESC""")
    print("lookup_status summary:")
    for status, n in rows:
        print(f"  {status:<24}{int(n):>12,}")


def cmd_status(args):
    ctx = Ctx(args)
    refresh_statuses(ctx)
    print_status_summary(ctx)


def store_direct(ctx, rows):
    """rows: [[ip, status, result, r1, r1_zip, r2, r2_zip], ...] ('' for absent values). Writes
    lookup_status, and for successes url_location and the two registrants with their ZIP codes, to
    every row with that ip_address."""
    if not rows:
        return
    run_script(f"""
CREATE TEMP TABLE stage (ip inet, status text, result text, r1 text, r1z text, r2 text, r2z text)
    ON COMMIT DROP;
COPY stage FROM STDIN WITH CSV;
{csv_text(rows)}\\.
UPDATE {ctx.target} t SET lookup_status = s.status,
       url_location = COALESCE(s.result, t.url_location),
       registrant_1 = CASE WHEN s.result IS NULL THEN t.registrant_1 ELSE s.r1 END,
       registrant_1_zip = CASE WHEN s.result IS NULL THEN t.registrant_1_zip ELSE s.r1z END,
       registrant_2 = CASE WHEN s.result IS NULL THEN t.registrant_2 ELSE s.r2 END,
       registrant_2_zip = CASE WHEN s.result IS NULL THEN t.registrant_2_zip ELSE s.r2z END
FROM stage s
WHERE t.ip_address = s.ip;
""")


def append_error_log(path, rows):
    if not rows:
        return
    p = Path(path)
    new = not p.exists()
    with p.open("a", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        if new:
            w.writerow(["ip", "error"])
        w.writerows(rows)


def disk_free(path):
    """(free, total) bytes of the filesystem holding path (or the nearest existing parent)."""
    while path:
        try:
            u = shutil.disk_usage(path)
            return u.free, u.total
        except OSError:
            parent = os.path.dirname(path)
            path = "" if parent == path else parent
    return None


def space_report(ctx):
    """Every location this script's updates write to: [(label, path, free, total)].
      WAL        pg_wal, in the data directory unless --wal-dir (or $OVT_WAL_DIR) says it was moved
      temp files the temp tablespace if one is in effect, else the data directory
      table      the tablespace of the main table, if it is not the default one
    Needs a role that can read the settings, and the script must run on the database host."""
    dd = query_csv("SELECT setting FROM pg_settings WHERE name = 'data_directory'")
    data_dir = dd[0][0] if dd and dd[0] else ""
    locs = []
    wal = ctx.args.wal_dir or data_dir
    if wal:
        locs.append(("WAL directory" if ctx.args.wal_dir else
                     "data directory (WAL, unless pg_wal is a symlink elsewhere: then set OVT_WAL_DIR)", wal))
    tt = query_csv("SELECT current_setting('temp_tablespaces')")
    first = tt[0][0].split(",")[0].strip() if tt and tt[0] else ""
    temp_path = ""
    if first:
        tl = query_csv(f"SELECT pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname = {lit(first)}")
        temp_path = tl[0][0] if tl and tl[0] else ""
        label = f"temp files (tablespace {first})"
    else:
        temp_path, label = data_dir, "temp files (data directory)"
    if temp_path:
        locs.append((label, temp_path))
    ts = query_csv(f"""SELECT coalesce(pg_tablespace_location(t.oid), '') FROM pg_class c
                       LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace AND c.reltablespace <> 0
                       WHERE c.oid = {lit(ctx.target)}::regclass""")
    if ts and ts[0] and ts[0][0]:
        locs.append((f"tablespace of {ctx.args.table}", ts[0][0]))
    out, seen = [], set()
    for label, path in locs:
        d = disk_free(path)
        if d and (path not in seen):
            seen.add(path)
            out.append((label, path, d[0], d[1]))
    return out


def cmd_space(args):
    ctx = Ctx(args)
    rows = space_report(ctx)
    if not rows:
        print("Cannot see the data directory from here (needs a superuser or pg_read_all_settings role, "
              "and this script must run on the database host).")
    for label, path, free, total in rows:
        print(f"{label}: {path}\n    {free / 2**30:,.1f} GiB free of {total / 2**30:,.1f} GiB "
              f"({100 * (1 - free / total):.0f}% used)")
    w = row_bytes(ctx)
    print(f"{args.table}: about {w:,.0f} bytes per row in the heap; "
          f"a {args.chunk_rows:,}-row chunk rewrites about {args.chunk_rows * w / 2**30:,.1f} GiB "
          f"(plus about the same in WAL)")


def row_bytes(ctx):
    """Average heap bytes per row of the main table (includes any bloat, so it is conservative)."""
    v = query_csv(f"""SELECT pg_relation_size({lit(ctx.target)}::regclass)::float8 / greatest(reltuples, 1)
                      FROM pg_class WHERE oid = {lit(ctx.target)}::regclass""")[0][0]
    return float(v or 0)


def guard_space(ctx, args, extra=0, where=""):
    """Stop (without losing finished work) if any location this step writes to is short of space."""
    if args.force or not args.min_free_gb:
        return
    need = args.min_free_gb * 2**30 + extra
    for label, path, free, total in space_report(ctx):
        if free < need:
            sys.exit(f"Only {free / 2**30:,.1f} GiB free on the filesystem of the {label} ({path}){where}; "
                     f"this step wants {need / 2**30:,.1f} GiB there ({args.min_free_gb} GiB reserve plus about "
                     f"twice the rows it is about to rewrite). Free some space and rerun: finished chunks are "
                     f"kept. If pg_wal was moved, tell me where with --wal-dir or $OVT_WAL_DIR. --min-free-gb 0 or --force "
                     f"skips this check; `space` shows all locations.")


def ip_chunks(ctx, base_cond, chunk_rows):
    """Split the rows matching base_cond into IP ranges of about chunk_rows rows (a /8 is the finest
    grain), so that a big update runs as many short transactions on the ip_address index.
    Returns [(condition, rows), ...]."""
    rows = query_csv(f"""SELECT o, count(*) FROM (
        SELECT nullif(split_part(host(t.ip_address), '.', 1), '')::int AS o
        FROM {ctx.target} t WHERE {base_cond}) x GROUP BY o ORDER BY o NULLS FIRST""")
    chunks, cur = [], None

    def close(c):
        hi = "t.ip_address <= '255.255.255.255'" if c["hi"] == 255 else f"t.ip_address < '{c['hi'] + 1}.0.0.0'"
        chunks.append((f"t.ip_address >= '{c['lo']}.0.0.0' AND {hi}", c["n"]))

    for octet, n in rows:
        n = int(n)
        if octet == "":
            chunks.append(("t.ip_address IS NULL", n))
        elif cur and cur["n"] + n <= chunk_rows:
            cur["hi"], cur["n"] = int(octet), cur["n"] + n
        else:
            if cur:
                close(cur)
            cur = {"lo": int(octet), "hi": int(octet), "n": n}
    if cur:
        close(cur)
    return chunks


def run_chunks(ctx, args, label, chunks, make_script):
    """Run make_script(condition) for every chunk as its own transaction. Each script must end with
    a query returning one number (rows changed). Checks free space before every chunk and runs
    VACUUM every --vacuum-every candidate rows so that dead row versions can be reused."""
    n_all = sum(n for _, n in chunks)
    print(f"{label}: {n_all:,} candidate rows in {len(chunks):,} chunk(s) of about {args.chunk_rows:,} rows",
          flush=True)
    width = row_bytes(ctx)
    done = since_vacuum = changed = 0
    t0 = time.time()
    for i, (cond, n) in enumerate(chunks, 1):
        guard_space(ctx, args, extra=int(2 * n * width), where=f" (chunk {i}/{len(chunks)})")
        out = run_script(make_script(cond),
                         label=f"{label} chunk {i}/{len(chunks)} ({n:,} rows)")
        nums = re.findall(r"^\s*(\d+)\s*$", out, re.M)
        changed += int(nums[-1]) if nums else 0
        done += n
        since_vacuum += n
        print(f"  chunk {i}/{len(chunks)}: {done:,}/{n_all:,} candidate rows, {changed:,} changed, "
              f"{time.time() - t0:,.0f}s", flush=True)
        if args.vacuum_every and since_vacuum >= args.vacuum_every and i < len(chunks):
            print("  VACUUM ...", flush=True)
            run_sql(f"VACUUM {ctx.target}", label=f"VACUUM {ctx.target}")
            since_vacuum = 0
    return changed


def cmd_registrants(args):
    """Split the stored url_location records into registrant_1/_2 and their ZIP codes. No new RDAP
    lookups: it parses the text already in the table (distinct records only), then updates the
    rows chunk by chunk."""
    ctx = Ctx(args)
    for c in REG_COLUMNS:
        ensure_column(ctx, c)
    todo = "" if args.reparse else " AND t.registrant_1 IS NULL"
    texts = [r[0] for r in query_csv(f"""SELECT DISTINCT t.url_location FROM {ctx.target} t
                                         WHERE t.url_location IS NOT NULL{todo}""")]
    print(f"{len(texts):,} distinct stored records to parse", flush=True)
    by_count, parsed = {}, []
    for tx in texts:
        n = len(parse_registrants(tx))
        by_count[n] = by_count.get(n, 0) + 1
        if n:
            parsed.append([tx] + registrant_fields(tx))
    print("records by number of registrant blocks (3 or more: only the first two are kept):",
          dict(sorted(by_count.items())), flush=True)
    if parsed:
        guard_space(ctx, args, where=" before starting")
        stage = f"{q(args.pg_schema)}.{q(args.table + '_tmp_registrants')}"
        run_script(f"""
DROP TABLE IF EXISTS {stage};
CREATE UNLOGGED TABLE {stage} (loc text, r1 text, r1z text, r2 text, r2z text);
COPY {stage} FROM STDIN WITH CSV;
{csv_text(parsed)}\\.
""")
        run_script(f"ANALYZE {stage};")
        chunks = ip_chunks(ctx, f"t.url_location IS NOT NULL{todo}", args.chunk_rows)
        try:
            run_chunks(ctx, args, "registrants", chunks, lambda cond: f"""
WITH u AS (UPDATE {ctx.target} t SET registrant_1 = s.r1, registrant_1_zip = s.r1z,
                                     registrant_2 = s.r2, registrant_2_zip = s.r2z
           FROM {stage} s
           WHERE t.url_location = s.loc AND {cond}{todo}
             AND (t.registrant_1 IS DISTINCT FROM s.r1 OR t.registrant_1_zip IS DISTINCT FROM s.r1z
                  OR t.registrant_2 IS DISTINCT FROM s.r2 OR t.registrant_2_zip IS DISTINCT FROM s.r2z)
           RETURNING 1)
SELECT count(*) AS rows_changed FROM u;""")
        finally:
            run_sql(f"DROP TABLE IF EXISTS {stage}")
    run_script(f"ANALYZE {ctx.target};")
    rows = query_csv(f"""SELECT count(*) FILTER (WHERE registrant_1 IS NOT NULL),
                                count(*) FILTER (WHERE registrant_2 IS NOT NULL),
                                count(*) FILTER (WHERE registrant_1_zip IS NOT NULL),
                                count(*) FILTER (WHERE registrant_2_zip IS NOT NULL)
                         FROM {ctx.target}""")[0]
    print("Rows with registrant_1: {:,}; registrant_2: {:,}; registrant_1_zip: {:,}; registrant_2_zip: {:,}"
          .format(*[int(x) for x in rows]))


OVERTURE_ZIP_RE = r'"postcode"\s*:\s*"([0-9]{5})'
OV_FREEFORM_RE = r'"freeform"\s*:\s*"([^"]*)"'
OV_LOCALITY_RE = r'"locality"\s*:\s*"([^"]*)"'
OV_REGION_RE = r'"region"\s*:\s*"([^"]*)"'


def cmd_overture_zip(args):
    """Establish each place's Overture ZIP (overture_zip, with overture_zip_source) for rows whose
    RDAP lookup succeeded (lookup_status = 'true'), in this order:
      postcode  the first 5-digit postcode in the Overture addresses
      freeform  a ZIP inside the free-form address text (a ZIP after a state code, or at the end)
      locality  the one ZIP that every Overture row with the same locality and region carries
                (only when that ZIP is unambiguous); an inference, so it is labelled as such
      none      nothing could be established; onpremises then stays NULL
    --dry-run only counts, for all rows with a website and for the rows that matter."""
    ctx = Ctx(args)
    if args.address_column not in ctx.cols:
        sys.exit(f"Address column '{args.address_column}' not found (use --address-column).")
    a = f"t.{q(args.address_column)}"
    pz = f"substring({a} from {lit(OVERTURE_ZIP_RE)})"
    ff = f"substring({a} from {lit(OV_FREEFORM_RE)})"
    fz = f"coalesce(substring({ff} from {lit(ZIP_AFTER_STATE_RE)}), substring({ff} from {lit(ZIP_AT_END_RE)}))"
    loc = f"lower(btrim(substring({a} from {lit(OV_LOCALITY_RE)})))"
    reg = f"upper(btrim(substring({a} from {lit(OV_REGION_RE)})))"
    loc_t = f"{q(args.pg_schema)}.{q(args.table + '_tmp_loc_zip')}"
    print("Collecting locality/ZIP evidence (scans the whole table) ...", flush=True)
    run_script(label="locality/ZIP evidence scan", script=f"""
DROP TABLE IF EXISTS {loc_t};
CREATE UNLOGGED TABLE {loc_t} AS
SELECT lk, rk, min(z) AS zip FROM (
    SELECT {loc} AS lk, {reg} AS rk, {pz} AS z
    FROM {ctx.target} t WHERE {a} IS NOT NULL) x
WHERE z IS NOT NULL AND lk <> '' AND rk <> ''
GROUP BY lk, rk HAVING count(DISTINCT z) = 1;
CREATE INDEX ON {loc_t} (lk, rk);
ANALYZE {loc_t};""")
    try:
        if args.dry_run:
            print("Dry run (counts only):")
            print(run_script(f"""
SELECT count(*) FILTER (WHERE t.lookup_status IS DISTINCT FROM {lit(STATUS_NO_WEBSITE)})
           AS rows_with_website,
       count(*) FILTER (WHERE t.lookup_status IS DISTINCT FROM {lit(STATUS_NO_WEBSITE)} AND {pz} IS NULL)
           AS website_without_postcode,
       count(*) FILTER (WHERE t.lookup_status = {lit(STATUS_OK)}) AS rdap_succeeded,
       count(*) FILTER (WHERE t.lookup_status = {lit(STATUS_OK)} AND {pz} IS NULL)
           AS succeeded_without_postcode,
       count(*) FILTER (WHERE t.lookup_status = {lit(STATUS_OK)} AND {pz} IS NULL AND {fz} IS NOT NULL)
           AS recoverable_from_address_text,
       count(*) FILTER (WHERE t.lookup_status = {lit(STATUS_OK)} AND {pz} IS NULL AND {fz} IS NULL
                        AND l.zip IS NOT NULL) AS recoverable_from_locality,
       count(*) FILTER (WHERE t.lookup_status = {lit(STATUS_OK)} AND {pz} IS NULL AND {fz} IS NULL
                        AND l.zip IS NULL) AS still_without_zip
FROM {ctx.target} t LEFT JOIN {loc_t} l ON l.lk = {loc} AND l.rk = {reg};"""))
            return
        for c in ("overture_zip", "overture_zip_source"):
            ensure_column(ctx, c)
        todo = "(t.overture_zip_source IS NULL" + (" OR t.overture_zip_source = 'none')" if args.retry_none else ")")
        base = f"t.lookup_status = {lit(STATUS_OK)} AND {todo}"
        chunks = ip_chunks(ctx, base, args.chunk_rows)
        run_chunks(ctx, args, "overture-zip", chunks, lambda cond: f"""
WITH u AS (UPDATE {ctx.target} t SET
    overture_zip = coalesce({pz}, {fz}, (SELECT l.zip FROM {loc_t} l WHERE l.lk = {loc} AND l.rk = {reg})),
    overture_zip_source = CASE WHEN {pz} IS NOT NULL THEN 'postcode'
                               WHEN {fz} IS NOT NULL THEN 'freeform'
                               WHEN EXISTS (SELECT 1 FROM {loc_t} l WHERE l.lk = {loc} AND l.rk = {reg})
                                    THEN 'locality'
                               ELSE 'none' END
    WHERE {cond} AND {base} RETURNING 1)
SELECT count(*) AS rows_changed FROM u;""")
    finally:
        run_sql(f"DROP TABLE IF EXISTS {loc_t}")
    run_script(f"ANALYZE {ctx.target};")
    print("overture_zip_source among rows with lookup_status = 'true':")
    for val, n in query_csv(f"""SELECT coalesce(overture_zip_source, '(not yet set)'), count(*) FROM {ctx.target}
                                WHERE lookup_status = {lit(STATUS_OK)} GROUP BY 1 ORDER BY 2 DESC"""):
        print(f"  {val:<14}{int(n):>12,}")


def cmd_load_isps(args):
    """Load ISP registrant names (one per line, '#' lines ignored) into the ISP table that the
    onpremises step reads. Names are unique ignoring case and surrounding spaces."""
    check_ident("--isp-table", args.isp_table)
    tbl = f"{q(args.pg_schema)}.{q(args.isp_table)}"
    seen, names = set(), []
    for ln in Path(args.file).read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#") and ln.lower() not in seen:
            seen.add(ln.lower())
            names.append([ln])
    if not names:
        sys.exit(f"No names found in {args.file}.")
    replace = f"TRUNCATE {tbl};" if args.replace else ""
    run_script(f"""
CREATE TABLE IF NOT EXISTS {tbl} (name text NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS {q(args.isp_table + '_name_lower_idx')} ON {tbl} (lower(btrim(name)));
{replace}
CREATE TEMP TABLE stage (name text) ON COMMIT DROP;
COPY stage FROM STDIN WITH CSV;
{csv_text(names)}\\.
INSERT INTO {tbl} (name) SELECT name FROM stage ON CONFLICT (lower(btrim(name))) DO NOTHING;
""")
    total = query_csv(f"SELECT count(*) FROM {tbl}")[0][0]
    print(f"{len(names):,} distinct names in {args.file}; {int(total):,} now in {args.pg_schema}.{args.isp_table}"
          f"{' (table replaced)' if args.replace else ''}")


def cmd_onpremises(args):
    """Set onpremises for rows whose RDAP lookup succeeded (lookup_status = 'true'). ISPs are read
    from the ISP table (--isp-table, matched ignoring case). An ISP's own ZIP is never used.
    The place's ZIP is the overture_zip column (see the overture-zip step).
      0. no registrant data                                                          -> NULL
      1. no Overture ZIP (we do not know where the landmark is)                      -> NULL
      2. ANY registrant is a CDN, cloud or web host (--provider-table)               -> false
      3. every registrant is an ISP (one ISP, or two)                                -> true
      4. a NON-ISP registrant's ZIP equals the Overture ZIP                          -> true
      5. a NON-ISP registrant's ZIP is adjacent to the Overture ZIP (zip_adjacency)  -> true
      6. otherwise (including non-ISP registrants without a ZIP, e.g. non-US)        -> false

    Rule 2 runs BEFORE the ZIP tests and that ordering is the point. The landmark method
    works by shared routing: a landmark's static address and nearby retail customers'
    dynamic addresses reach the network through the same carrier node, and matching on that
    node transfers the ZIP. For a CDN-fronted or cloud-hosted site the adjacent node is the
    provider's edge router, which routes content and never subscribers, so retail routing
    can never converge through it. The anchor is unusable regardless of whether its ZIP is
    right. Placed after the ZIP tests instead, any landmark near a provider's registered
    office would pass: Akamai in Cambridge 02142 against MIT's 02139, Cloudflare and Fastly
    in San Francisco, Amazon in Herndon.

    Rule 2 also replaces the `mark` subcommand, which was not durable: `mark` issued a plain
    UPDATE and this step then recomputed the column with no exemption, flipping marked rows
    back on the next run."""
    ctx = Ctx(args)
    missing = [c for c in REG_COLUMNS if c not in ctx.cols]
    if missing:
        sys.exit(f"Missing column(s) {missing}: run the `registrants` step first.")
    if "overture_zip" not in ctx.cols:
        sys.exit("Column overture_zip not found: run the `overture-zip` step first.")
    check_ident("--isp-table", args.isp_table)
    isp_tbl = f"{q(args.pg_schema)}.{q(args.isp_table)}"
    if query_csv(f"SELECT to_regclass({lit(isp_tbl)}) IS NOT NULL")[0][0] != "t":
        sys.exit(f"ISP table {args.pg_schema}.{args.isp_table} not found: load it with "
                 f"`load-isps --file definitive_isps.txt` (or the isp_names.sql file).")
    n_isps = int(query_csv(f"SELECT count(*) FROM {isp_tbl}")[0][0])
    if not n_isps:
        print(f"WARNING: {isp_tbl} is empty, so no registrant counts as an ISP.", file=sys.stderr)
    print(f"{n_isps:,} ISP names in {args.pg_schema}.{args.isp_table} (matched ignoring case)", flush=True)

    zt = f"{q(args.pg_schema)}.{q(args.zip_table)}"
    zcols = {n.lower(): n for n, _ in query_csv(f"""SELECT column_name, data_type FROM information_schema.columns
        WHERE table_schema = {lit(args.pg_schema)} AND table_name = {lit(args.zip_table)}""")}
    if "zip_a" not in zcols or "zip_b" not in zcols:
        sys.exit(f"Table {args.pg_schema}.{args.zip_table} needs columns zip_a and zip_b (any case); "
                 f"found: {sorted(zcols.values()) or 'no such table'}")

    def norm(col):          # 5-character text ZIP, restoring leading zeros lost in numeric columns
        return f"left(lpad(btrim({q(zcols[col])}::text), 5, '0'), 5)"

    # The provider table is optional, so an installation that has not created it keeps the
    # previous behaviour rather than failing. A missing table makes the provider test a
    # constant false, which is reported below so it cannot pass unnoticed.
    check_ident("--provider-table", args.provider_table)
    prov_tbl = f"{q(args.pg_schema)}.{q(args.provider_table)}"
    have_prov = query_csv(f"SELECT to_regclass({lit(prov_tbl)}) IS NOT NULL")[0][0] == "t"
    if have_prov:
        n_prov = int(query_csv(f"SELECT count(*) FROM {prov_tbl}")[0][0])
        print(f"{n_prov:,} provider names in {args.pg_schema}.{args.provider_table} "
              f"(CDN, cloud and web hosts; matched ignoring case)", flush=True)
        if not n_prov:
            print(f"WARNING: {prov_tbl} is empty, so no registrant counts as a provider.",
                  file=sys.stderr)
    else:
        print(f"WARNING: provider table {args.pg_schema}.{args.provider_table} not found, so rule 2 "
              f"is skipped and CDN-hosted landmarks can still pass the ZIP tests. "
              f"Create it with geo/overture_fetch/provider_names.sql.", file=sys.stderr)

    isps_t = f"{q(args.pg_schema)}.{q(args.table + '_tmp_isps')}"
    provs_t = f"{q(args.pg_schema)}.{q(args.table + '_tmp_provs')}"
    adj_t = f"{q(args.pg_schema)}.{q(args.table + '_tmp_adj')}"
    ovz = "t.overture_zip"
    isp1 = f"coalesce(lower(btrim(t.registrant_1)) IN (SELECT name FROM {isps_t}), false)"
    isp2 = f"coalesce(lower(btrim(t.registrant_2)) IN (SELECT name FROM {isps_t}), false)"
    if have_prov:
        prov_any = (f"(coalesce(lower(btrim(t.registrant_1)) IN (SELECT name FROM {provs_t}), false)"
                    f" OR coalesce(lower(btrim(t.registrant_2)) IN (SELECT name FROM {provs_t}), false))")
    else:
        prov_any = "false"
    z1 = f"(CASE WHEN {isp1} THEN NULL ELSE t.registrant_1_zip END)"    # an ISP's ZIP never counts
    z2 = f"(CASE WHEN {isp2} THEN NULL ELSE t.registrant_2_zip END)"
    all_isp = f"({isp1} AND (t.registrant_2 IS NULL OR {isp2}))"
    adj_test = f"EXISTS (SELECT 1 FROM {adj_t} adj WHERE adj.a = {ovz} AND adj.b IN ({z1}, {z2}))"
    case = f"""CASE
  WHEN t.registrant_1 IS NULL THEN NULL
  WHEN {ovz} IS NULL THEN NULL
  WHEN {prov_any} THEN false
  WHEN {all_isp} THEN true
  WHEN {ovz} IN ({z1}, {z2}) THEN true
  WHEN {adj_test} THEN true
  ELSE false END"""
    rule = f"""CASE
  WHEN t.registrant_1 IS NULL THEN '0 no registrant data: NULL'
  WHEN {ovz} IS NULL THEN '1 no Overture ZIP: NULL'
  WHEN {prov_any} THEN '2 CDN, cloud or web host registrant: false'
  WHEN {all_isp} AND t.registrant_2 IS NULL THEN '3a single ISP registrant: true'
  WHEN {all_isp} THEN '3b two ISP registrants: true'
  WHEN {ovz} IN ({z1}, {z2}) THEN '4 non-ISP registrant ZIP matches: true'
  WHEN {adj_test} THEN '5 non-ISP registrant ZIP adjacent: true'
  WHEN {z1} IS NULL AND {z2} IS NULL THEN '6a no non-ISP registrant ZIP: false'
  ELSE '6b ZIPs differ and are not adjacent: false' END"""
    mix = f"""CASE
  WHEN t.registrant_1 IS NULL THEN 'no registrant data'
  WHEN t.registrant_2 IS NULL AND {isp1} THEN 'single ISP'
  WHEN t.registrant_2 IS NULL THEN 'single non-ISP'
  WHEN {isp1} AND {isp2} THEN 'two ISPs'
  WHEN {isp1} OR {isp2} THEN 'ISP + other registrant'
  ELSE 'two non-ISP registrants' END"""
    prov_build = ""
    if have_prov:
        prov_build = (f"CREATE UNLOGGED TABLE {provs_t} AS "
                      f"SELECT DISTINCT lower(btrim(name)) AS name FROM {prov_tbl};\n"
                      f"CREATE INDEX ON {provs_t} (name);\nANALYZE {provs_t};")
    run_script(f"""
DROP TABLE IF EXISTS {isps_t}, {provs_t}, {adj_t};
CREATE UNLOGGED TABLE {isps_t} AS SELECT DISTINCT lower(btrim(name)) AS name FROM {isp_tbl};
CREATE INDEX ON {isps_t} (name);
{prov_build}
CREATE UNLOGGED TABLE {adj_t} (a text, b text, PRIMARY KEY (a, b));
INSERT INTO {adj_t} SELECT a, b FROM (
    SELECT {norm('zip_a')} AS a, {norm('zip_b')} AS b FROM {zt}
    UNION SELECT {norm('zip_b')}, {norm('zip_a')} FROM {zt}) x
WHERE a IS NOT NULL AND b IS NOT NULL;
ANALYZE {isps_t};
ANALYZE {adj_t};""")
    try:
        if args.dry_run:
            print("Dry run: which rule decides each row with lookup_status = 'true':")
            print(run_script(f"""SELECT {rule} AS rule, count(*) FROM {ctx.target} t
WHERE t.lookup_status = {lit(STATUS_OK)} GROUP BY 1 ORDER BY 1;
SELECT {mix} AS registrants, {case} AS onpremises, count(*) FROM {ctx.target} t
WHERE t.lookup_status = {lit(STATUS_OK)} GROUP BY 1, 2 ORDER BY 1, 2;"""))
            return
        base = f"t.lookup_status = {lit(STATUS_OK)}"
        chunks = ip_chunks(ctx, base, args.chunk_rows)
        changed = run_chunks(ctx, args, "onpremises", chunks, lambda cond: f"""
WITH u AS (UPDATE {ctx.target} t SET onpremises = {case}
           WHERE {cond} AND {base} AND ({case}) IS DISTINCT FROM t.onpremises
           RETURNING 1)
SELECT count(*) AS rows_changed FROM u;""")
        print(f"{changed:,} rows changed")
    finally:
        run_sql(f"DROP TABLE IF EXISTS {isps_t}, {provs_t}, {adj_t}")
    run_script(f"ANALYZE {ctx.target};")
    print("onpremises among rows with lookup_status = 'true' (NULL = cannot be evaluated):")
    for val, n in query_csv(f"""SELECT coalesce(onpremises::text, 'NULL'), count(*) FROM {ctx.target}
                                WHERE lookup_status = {lit(STATUS_OK)} GROUP BY onpremises ORDER BY 2 DESC"""):
        print(f"  {val:<8}{int(n):>12,}")


def cmd_rdap(args):
    script = os.path.expanduser(args.rdap_script)
    found = (os.access(script, os.X_OK) and os.path.isfile(script)) if "/" in script \
        else shutil.which(script)
    if not found:
        sys.exit(f"RDAP script '{script}' not found or not executable (use --rdap-script).")
    script = found if "/" not in script else script

    ctx = Ctx(args)
    for c in REG_COLUMNS:
        ensure_column(ctx, c)
    ensure_ip_index(ctx)
    # Each of these crosses the whole table, so on a restart against 14 million
    # rows they are minutes of silence before the first lookup. Name the phase
    # being entered; the heartbeat inside then reports elapsed time.
    print("Refreshing lookup_status from the data already stored ...", flush=True)
    refresh_statuses(ctx)

    # Work list: distinct IPs with status NULL (not looked up yet) or 'lookup error' (possibly
    # transient). With --retry-failed also 'outside ARIN' and 'registrant not found'.
    retry = [STATUS_ERROR] + ([STATUS_NOT_ARIN, STATUS_NO_REGISTRANT] if args.retry_failed else [])
    cond = "lookup_status IS NULL OR lookup_status IN (" + ", ".join(lit(x) for x in retry) + ")"
    order = "random()" if args.random else "ip"
    print(f"Selecting distinct IPs still needing RDAP from {args.table} "
          f"(scans the whole table) ...", flush=True)
    ips = [r[0] for r in query_csv(f"""
SELECT host(ip) FROM (SELECT DISTINCT ip_address AS ip FROM {ctx.target}
                      WHERE ip_address IS NOT NULL AND ({cond})) d
ORDER BY {order}""", label="distinct-IP selection")]
    if args.limit:
        ips = ips[:args.limit]
    log = args.error_log or f"{args.table}_rdap_errors.csv"
    print(f"RDAP lookups for {len(ips):,} distinct IPs with {args.rdap_threads} threads; "
          f"failure details are appended to {log}", flush=True)

    def flush(rows, err_rows):
        store_direct(ctx, rows)
        append_error_log(log, err_rows)

    t0, done, ok, rows, err_rows = time.time(), 0, 0, [], []
    ex = ThreadPoolExecutor(max_workers=args.rdap_threads)
    futs = [ex.submit(rdap_one, script, ip, args.rdap_timeout, args.rdap_attempts,
                      args.delay, args.name_only, not args.rdap_use_script)
            for ip in ips]
    try:
        for fut in as_completed(futs):
            ip, result, err = fut.result()
            if result is not None:
                rows.append([ip, STATUS_OK, result] + registrant_fields(result))
                ok += 1
            else:
                rows.append([ip, classify_error(err), "", "", "", "", ""])
                err_rows.append([ip, err])
            done += 1
            if len(rows) >= args.batch:
                flush(rows, err_rows)
                rows, err_rows = [], []
                print(f"  {done:,}/{len(ips):,} done, {ok:,} ok, {time.time() - t0:,.0f}s", flush=True)
    except KeyboardInterrupt:
        ex.shutdown(wait=False, cancel_futures=True)
        print("Interrupted; saving finished lookups.", file=sys.stderr)
        flush(rows, err_rows)
        sys.exit(130)
    ex.shutdown()
    flush(rows, err_rows)
    print(f"Lookups finished: {done:,} IPs, {ok:,} succeeded, {done - ok:,} failed.")
    run_script(f"ANALYZE {ctx.target};")
    print_status_summary(ctx)


# --------------------------------------------------------------------------
# report / mark / all
# --------------------------------------------------------------------------
BYNAME_RE = r"Registrant Entity : ([^|]*)"


def name_sql(col):
    """The registrant name inside a stored result (or the whole value if it is already a bare name)."""
    return f"COALESCE(btrim(substring({col} from {lit(BYNAME_RE)})), {col})"


def cmd_report(args):
    ctx = Ctx(args)
    if args.by_name:
        header = ["registrant", "rows", "variants"]
        rows = query_csv(f"""
SELECT {name_sql('url_location')} AS registrant, count(*), count(DISTINCT url_location)
FROM {ctx.target} WHERE url_location IS NOT NULL GROUP BY 1 ORDER BY 2 DESC, 1""")
        default_out = f"{args.table}_registrant_counts.csv"
    else:
        header = ["url_location", "rows"]
        rows = query_csv(f"""
SELECT url_location, count(*) FROM {ctx.target}
WHERE url_location IS NOT NULL GROUP BY url_location ORDER BY count(*) DESC, url_location""")
        default_out = f"{args.table}_url_location_counts.csv"
    out = Path(args.out or default_out)
    with out.open("w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)
    print(csv_text([header] + rows), end="")
    print(f"\n{len(rows):,} distinct values written to {out}", file=sys.stderr)


def cmd_mark(args):
    ctx = Ctx(args)
    values = []
    for line in Path(args.providers_file).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            values.append([line])
    if not values:
        sys.exit("No values in providers file.")
    key = name_sql("t.url_location") if args.by_name else "t.url_location"
    run_script(f"""
CREATE TEMP TABLE providers (value text) ON COMMIT DROP;
COPY providers FROM STDIN WITH CSV;
{csv_text(values)}\\.
UPDATE {ctx.target} t SET onpremises = false
WHERE {key} IN (SELECT value FROM providers)
  AND t.onpremises IS DISTINCT FROM false;
""")
    n = query_csv(f"SELECT count(*) FROM {ctx.target} WHERE onpremises = false")[0][0]
    print(f"Listed values: {len(values):,}. Rows with onpremises = false: {int(n):,}")
    unmatched = query_csv(f"""
SELECT p FROM unnest(ARRAY[{", ".join(lit(v[0]) for v in values)}]) AS p
WHERE NOT EXISTS (SELECT 1 FROM {ctx.target} t WHERE {key} = p)""")
    if unmatched:
        print("Listed values matching no row (check spelling):", file=sys.stderr)
        for (p,) in unmatched:
            print(f"  {p}", file=sys.stderr)


def cmd_all(args):
    cmd_resolve(args)
    cmd_rdap(args)
    cmd_report(args)


def main():
    parent = argparse.ArgumentParser(add_help=False)
    parent.add_argument("--table", default="ovt_places_usa")
    parent.add_argument("--pg-schema", default="public")
    parent.add_argument("--placeholder-ip", default="1.2.3.4,1.2.3.5",
                        help="Comma-separated placeholder addresses to ignore (default 1.2.3.4,1.2.3.5)")
    parent.add_argument("--chunk-rows", type=int, default=300_000,
                        help="Big updates run as many transactions of about this many rows (default 300000)")
    parent.add_argument("--vacuum-every", type=int, default=2_000_000,
                        help="VACUUM the main table after this many updated rows, so dead row versions "
                             "can be reused (default 2000000; 0 = never)")
    parent.add_argument("--min-free-gb", type=float, default=10,
                        help="Stop before a chunk if the PostgreSQL data filesystem would have less free "
                             "space than this plus twice the chunk's size (default 10; 0 = no check)")
    parent.add_argument("--force", action="store_true", help="Ignore the free-space check")
    parent.add_argument("--temp-tablespace", default="auto",
                        help="Tablespace for this script's temp files: auto (the main table's tablespace, if "
                             "not the default one), a tablespace name, or none")
    parent.add_argument("--wal-dir", default=os.environ.get("OVT_WAL_DIR"),
                        help="Where pg_wal really is, if it was moved off the data directory "
                             "(default: $OVT_WAL_DIR, else the data directory)")
    parent.add_argument("--work-mem", default="256MB",
                        help="work_mem for this script's database sessions, so hash joins do not spill to disk")
    parent.add_argument("--maintenance-work-mem", default="1GB",
                        help="maintenance_work_mem for this script's sessions (index builds, VACUUM)")
    parent.add_argument("--url-column", default="websites",
                        help="Column holding the URL(s); first array element is used (default websites)")

    dns = argparse.ArgumentParser(add_help=False)
    dns.add_argument("--dns-threads", type=int, default=64)

    retry = argparse.ArgumentParser(add_help=False)
    retry.add_argument("--retry-failed", action="store_true",
                       help="Retry earlier failures: hosts that did not resolve (resolve), and lookups "
                            "that were 'outside ARIN' or 'registrant not found' (rdap)")

    lim = argparse.ArgumentParser(add_help=False)
    lim.add_argument("--limit", type=int, help="Process at most N items (for testing)")

    rd = argparse.ArgumentParser(add_help=False)
    rd.add_argument("--rdap-script", default="~/geo/rdap-lookup/cmd/rdap-lookup.sh")
    rd.add_argument("--rdap-threads", type=int, default=4,
                    help="Parallel RDAP calls (default 4; RDAP servers rate-limit)")
    rd.add_argument("--random", action="store_true",
                    help="With --limit: take a random sample instead of the lowest IPs (for testing)")
    rd.add_argument("--rdap-timeout", type=int, default=60, help="Seconds per call")
    rd.add_argument("--rdap-attempts", type=int, default=3)
    rd.add_argument("--rdap-use-script", action="store_true",
                    help="spawn rdap-lookup.sh per IP instead of doing the HTTP "
                         "in-process. Slower, because every call then pays a "
                         "fresh TCP and TLS handshake, which measured as 68 "
                         "percent of a call. Kept because the script is the "
                         "reference implementation: if the two ever disagree, "
                         "the script is right and this is the way back")
    rd.add_argument("--delay", type=float, default=0.0,
                    help="Seconds each worker sleeps after a successful call")
    rd.add_argument("--name-only", action="store_true",
                    help="Store only the 'Registrant Entity' value instead of all result lines")
    rd.add_argument("--batch", type=int, default=100, help="Results saved per DB write")
    rd.add_argument("--error-log", help="CSV log of failure details (default <table>_rdap_errors.csv)")

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("resolve", parents=[parent, dns, lim, retry], help="Hostnames -> ip_address")
    s.set_defaults(func=cmd_resolve)

    s = sub.add_parser("rdap", parents=[parent, lim, retry, rd], help="RDAP lookup -> url_location, url_location_zip, lookup_status")
    s.set_defaults(func=cmd_rdap)

    s = sub.add_parser("status", parents=[parent],
                       help="Fill/refresh lookup_status from the data already in the table, and summarize it")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("space", parents=[parent],
                       help="Show free disk space where this script's updates write, and the size of a chunk")
    s.set_defaults(func=cmd_space)

    s = sub.add_parser("registrants", parents=[parent],
                       help="Split stored url_location records into registrant_1/_2 with their ZIP codes")
    s.add_argument("--reparse", action="store_true",
                   help="Recompute every row, not only rows without registrant_1 (after a parser change)")
    s.set_defaults(func=cmd_registrants)

    s = sub.add_parser("load-isps", parents=[parent],
                       help="Load a file of ISP registrant names into the ISP table")
    s.add_argument("--file", required=True, help="Text file, one registrant name per line")
    s.add_argument("--isp-table", default="isp_names", help="Target table (default isp_names)")
    s.add_argument("--replace", action="store_true", help="Empty the table first")
    s.set_defaults(func=cmd_load_isps)

    s = sub.add_parser("overture-zip", parents=[parent],
                       help="Establish each place's Overture ZIP (postcode, address text, or unambiguous locality)")
    s.add_argument("--address-column", default="addresses",
                   help="Overture addresses column (JSON text; the first address is used)")
    s.add_argument("--dry-run", action="store_true",
                   help="Only count: rows with a website, those lacking a postcode, and how many can be recovered")
    s.add_argument("--retry-none", action="store_true", help="Try again for rows marked 'none'")
    s.set_defaults(func=cmd_overture_zip)

    s = sub.add_parser("onpremises", parents=[parent],
                       help="Set onpremises from the registrant ISP / ZIP / adjacent-ZIP rule")
    s.add_argument("--isp-table", default="isp_names",
                   help="Table of ISP registrant names, column name (default isp_names; see load-isps)")
    s.add_argument("--zip-table", default="zip_adjacency", help="Adjacent ZIP pairs, columns zip_a and zip_b")
    s.add_argument("--provider-table", default="provider_names",
                   help="Table of CDN, cloud and web-host registrant names, column name "
                        "(default provider_names; create with provider_names.sql). Any registrant "
                        "matching makes onpremises false BEFORE the ZIP tests, because a provider's "
                        "edge router never routes retail subscribers")
    s.add_argument("--dry-run", action="store_true", help="Only show how many rows would get each value")
    s.set_defaults(func=cmd_onpremises)

    s = sub.add_parser("apply", parents=[parent],
                       help="Legacy: copy an existing _ip_rdap cache table into the main table")
    s.set_defaults(func=cmd_apply)

    s = sub.add_parser("report", parents=[parent], help="Distinct url_location with counts")
    s.add_argument("--out", help="CSV path (default <table>_url_location_counts.csv, or <table>_registrant_counts.csv with --by-name)")
    s.add_argument("--by-name", action="store_true",
                   help="Group by registrant name only (rows, and how many distinct stored variants)")
    s.set_defaults(func=cmd_report)

    s = sub.add_parser("mark", parents=[parent], help="Set onpremises=false for listed url_location values")
    s.add_argument("--providers-file", required=True)
    s.add_argument("--by-name", action="store_true",
                   help="Providers file lists registrant names (as shown by report --by-name), not whole url_location values")
    s.set_defaults(func=cmd_mark)

    s = sub.add_parser("all", parents=[parent, dns, lim, retry, rd], help="resolve + rdap + report")
    s.add_argument("--out", help="CSV path for the report")
    s.add_argument("--by-name", action="store_true", help="Report grouped by registrant name")
    s.set_defaults(func=cmd_all)

    args = ap.parse_args()
    global PSQL_ENV
    PSQL_ENV = os.environ.copy()
    PSQL_ENV["PGOPTIONS"] = (PSQL_ENV.get("PGOPTIONS", "") +
                             f" -c work_mem={args.work_mem} -c maintenance_work_mem={args.maintenance_work_mem}").strip()
    args.func(args)


if __name__ == "__main__":
    main()
