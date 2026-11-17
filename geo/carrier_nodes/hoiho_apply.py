#!/usr/bin/env python3
"""Apply the CAIDA Hoiho ruleset to router hostnames to locate carrier nodes.

STEP 2 OF THE FCC PLAN, AND WHY THIS IS THE RIGHT TOOL FOR IT

Step 2 is "compile headend/central office locations of routing/CPE-connecting
IP nodes for Internet service in USA per carrier and network type". A carrier
names its routers after the building they sit in, and CAIDA has already
published, scored and validated the regexes that read those names.

geo/landmarks/hoiho_suffixes.sql loaded the ruleset's METADATA on 2026-11-06,
871 domains with their precision scores, and recorded that the regexes
themselves stay in the CAIDA jsonl and would need applying. This applies them.

THE SAME HOSTNAME THAT KILLED THE LANDMARK METHOD IS WHAT MAKES THIS WORK

geo/node_fanout.sql warns: "A node named
po-1-rur201.westroxbury.ma.boston.comcast.net records where the ROUTER is,
not where the subscriber is." That warning retired the landmark method,
because Comcast serves West Roxbury from a Brockton node.

Step 2 wants the ROUTER's location. So the property that made hostnames
useless for locating a subscriber is exactly the property step 2 needs. This
is a reversal of use, not a contradiction of the finding.

WHAT THE RULESET CONTAINS, MEASURED 2026-11-17 from the 2025-08 release

871 domains. 15,952 geohints, of which 11,444 (71.7%) carry latitude and
longitude:

    iata      6,081   all with coordinates    city or metro granularity
    place     5,144   all with coordinates    city or town granularity
    clli      4,508   NONE with coordinates   building granularity, unresolved
    locode      203   all with coordinates
    facility     16   all with coordinates

A CORRECTION I OWE THE RECORD: I first claimed CAIDA had embedded coordinates
for the CLLI hints, which would have removed the LERG blocker that
isp_node_feasibility.md identified. That was wrong. ZERO of the 4,508 CLLI
hints carry coordinates, and none carries a location object; a CLLI hint is
the bare six-character code and nothing else. The blocker stands, and
clli_resolve.py addresses it separately through a public LERG-derived service.

A six-character CLLI is four characters of place plus two of state, so albyny
is Albany NY and btrgla is Baton Rouge LA. The state is unambiguous. The
place abbreviation is a contraction that needs resolving, which is what
clli_resolve.py is for.

89 domains carry CLLI hints. The ones that matter for US retail access, with
their CAIDA precision and router counts:

    charter.com       1,189 hints   ppv 0.998   10,997 routers
    verizon-gni.net     336 hints   ppv 0.977    4,172 routers
    windstream.net      333 hints   ppv 0.997   16,956 routers
    frontiernet.net     324 hints   ppv 0.990   15,357 routers
    rr.com              232 hints   ppv 0.961    1,525 routers
    sbcglobal.net       123 hints   ppv 0.965    5,624 routers

comcast.net is the largest domain in the ruleset at 255,906 routers, and it
is place-hinted rather than CLLI-hinted: 864 US place hints at ppv 0.999, all
with coordinates.

USAGE

  python3 hoiho_apply.py fetch
  python3 hoiho_apply.py load
  python3 hoiho_apply.py test
  python3 hoiho_apply.py decode --hostname po-1-rur201.westroxbury.ma.boston.comcast.net
  python3 hoiho_apply.py apply --source trace
  python3 hoiho_apply.py coverage

NOTHING HERE PROBES THE NETWORK. It reads hostnames the project already has.
"""

import argparse
import bz2
import csv
import io
import json
import os
import re
import subprocess
import sys
import urllib.request

ITDK_RELEASE = "2025-08"
ITDK_BASE = ("https://publicdata.caida.org/datasets/topology/ark/ipv4/itdk/"
             f"{ITDK_RELEASE}")
RULESET_NAME = "midar-iff-snmp-tnt.geo-re.jsonl"

# Measured 2026-11-17 on the 2025-08 release. Checked after every fetch so a
# changed upstream file is noticed rather than silently decoded by rules that
# no longer match what the comments here describe.
EXPECTED_DOMAINS = 871
EXPECTED_COMPRESSED_BYTES = 212714

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36")

DEFAULT_DIR = "/home/boris/geo/caida"


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def psql_copy_csv(table, cols, rows):
    """Load rows via COPY FROM STDIN, streamed.

    NOT as INSERT ... VALUES in a -c argument. That is what the first version
    did, 500 rows at a time, and it died on Boris's real corpus with
    OSError errno 7, Argument list too long, after 22,790 hostnames: the
    argument vector has a size limit and SQL text built into it inherits that
    limit. COPY carries the data on stdin, which has no such ceiling, and is
    faster besides.

    CSV rather than the default text format because the values include
    regexes full of backslashes, and CSV quoting handles them without an
    escaping pass of my own invention.
    """
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    for r in rows:
        w.writerow(["" if v is None else v for v in r])
    data = buf.getvalue()

    sql = (f"\\copy {table} ({cols}) FROM STDIN "
           f"WITH (FORMAT csv, NULL '')")
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1",
           "-q", "-c", sql]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    broke = False
    try:
        proc.stdin.write(data)
    except BrokenPipeError:
        broke = True
    try:
        proc.stdin.close()
    except BrokenPipeError:
        broke = True
    err = proc.stderr.read()
    rc = proc.wait()
    if rc != 0 or broke:
        sys.exit(f"copy into {table} failed (psql exit {rc}):\n"
                 f"{err.strip()}")
    if err.strip():
        print(f"  psql said: {err.strip()}")


def pg_array(items):
    """A PostgreSQL text[] literal, for COPY in CSV format.

    Each element is double-quoted and its backslashes and quotes escaped.
    The regexes are full of backslashes, so this is not optional.
    """
    if not items:
        return "{}"
    parts = []
    for it in items:
        e = str(it).replace("\\", "\\\\").replace('"', '\\"')
        parts.append('"' + e + '"')
    return "{" + ",".join(parts) + "}"


def lit(s):
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def ruleset_path(d):
    return os.path.join(d, RULESET_NAME)


def cmd_fetch(args):
    os.makedirs(args.dir, exist_ok=True)
    url = f"{ITDK_BASE}/{RULESET_NAME}.bz2"
    out = ruleset_path(args.dir)
    print(f"fetching {url}")
    rq = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(rq, timeout=300) as r:
        blob = r.read()
    print(f"  {len(blob):,} bytes compressed")
    if len(blob) != EXPECTED_COMPRESSED_BYTES:
        print(f"  NOTE: expected {EXPECTED_COMPRESSED_BYTES:,} bytes, the "
              f"size measured on 2026-11-17. CAIDA may have revised the "
              f"release. The domain count below is the check that matters.")
    text = bz2.decompress(blob).decode("utf-8")
    with open(out, "w") as f:
        f.write(text)
    n = sum(1 for line in text.splitlines() if line.strip())
    print(f"  wrote {out}, {len(text):,} bytes, {n} domains")
    if n != EXPECTED_DOMAINS:
        print(f"  WARNING: {n} domains, not the {EXPECTED_DOMAINS} this file "
              f"was written against. The counts in the docstring and in "
              f"geo/landmarks/hoiho_suffixes.sql describe a different "
              f"release. Re-measure before trusting any coverage figure.")


def read_ruleset(args):
    path = ruleset_path(args.dir)
    if not os.path.isfile(path):
        sys.exit(f"{path} not found. Run `hoiho_apply.py fetch` first.")
    recs = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except json.JSONDecodeError as exc:
                sys.exit(f"{path} line {n} is not JSON: {exc}")
    return recs


def compile_rules(recs):
    """Compile every regex, reporting any that Python will not accept.

    CAIDA generates these for its own Perl tooling. Nearly all are plain
    character classes and are accepted unchanged, but a regex Python rejects
    must be reported rather than skipped silently, because a silently skipped
    rule becomes a domain that looks uncovered.
    """
    compiled = {}
    rejected = []
    for r in recs:
        pats = []
        for rx in r.get("re") or []:
            try:
                pats.append((rx, re.compile(rx)))
            except re.error as exc:
                rejected.append((r["domain"], rx, str(exc)))
        compiled[r["domain"]] = pats
    return compiled, rejected


def hint_index(recs):
    """domain -> code -> list of hints, best first.

    A LIST, not a single hint. MEASURED 2026-11-17: 213 (domain, code) pairs
    carry more than one hint, up to seven, and 201 of those repeat within one
    hint type. as5405.net/skg is Skanderborg DK or Thessaloniki GR;
    as11404.net/sea is Seattle airport or Seattle city, 17 km apart. An
    earlier version of this function assigned d[code] = h and silently kept
    whichever appeared last in the file.

    Ordered by CAIDA's true-positive count descending, so the chosen hint is
    the one CAIDA saw most evidence for, and the count of alternatives is
    carried through to the caller.
    """
    idx = {}
    for r in recs:
        d = {}
        for h in r.get("geohints") or []:
            code = (h.get("code") or "").lower()
            if code:
                d.setdefault(code, []).append(h)
        for code in d:
            d[code].sort(key=lambda h: (-(h.get("tp") or 0),
                                        (h.get("fp") or 0)))
        idx[r["domain"]] = d
    return idx


def domain_of(hostname):
    """The registrable-looking suffix, last two labels.

    Matches the convention already used in geo/landmark_carrier_node.sql, so a
    node_domain computed there and one computed here are the same string.
    """
    parts = hostname.strip().strip(".").lower().split(".")
    if len(parts) < 2:
        return None
    return ".".join(parts[-2:])


def decode(hostname, compiled, hints):
    """Return a dict describing what the ruleset says about one hostname."""
    host = hostname.strip().strip(".").lower()
    out = {"hostname": host, "domain": None, "code": None, "hint_type": None,
           "lat": None, "lng": None, "place": None, "st": None, "cc": None,
           "matched_re": None, "corroborated_by": None,
           "code_hint_count": 1, "selection": None, "status": None}

    # Try the longest matching suffix first: a ruleset domain can itself have
    # three labels, as with state.mn.us, and taking only two would miss it.
    parts = host.split(".")
    dom = None
    for n in range(min(4, len(parts)), 1, -1):
        cand = ".".join(parts[-n:])
        if cand in compiled:
            dom = cand
            break
    if dom is None:
        out["status"] = "no rule for this domain"
        out["domain"] = domain_of(host)
        return out

    out["domain"] = dom
    dom_hints = hints.get(dom, {})

    # A HOIHO RULE CAN HAVE SEVERAL CAPTURE GROUPS, and reading only the first
    # is wrong. Comcast's rule
    #   ^[^.]+\.[a-z\d]+\.([a-z]{2})\.([a-z]+)\.comcast\.net$
    # captures ma and boston from
    #   po-1-rur201.westroxbury.ma.boston.comcast.net
    # and it is boston that is the hint, with the hint itself recording st=ma.
    # Taking group 1 returned ma and resolved nothing. So every group is a
    # candidate, the one that resolves to a hint wins, and a two-letter group
    # equal to that hint's state is recorded as corroboration.
    unresolved = None
    for rx, pat in compiled[dom]:
        m = pat.match(host)
        if not m or not m.groups():
            continue
        groups = [(g or "").lower() for g in m.groups()]

        # THE CONCATENATION IS A CANDIDATE TOO, and omitting it cost a whole
        # carrier. frontiernet.net's rules capture the place and the state
        # SEPARATELY:
        #   ^.+\.([a-z]{4})\.([a-z]{2})\.frontiernet\.net$
        # against a hostname like ...adln.ca.frontiernet.net. But its 324
        # hints are six-character CLLI codes, adlnca being the first, which
        # is the two groups joined. Trying only adln and ca resolved nothing,
        # which is why Boris's run showed frontiernet.net with 457 hostnames,
        # 146 distinct codes and ZERO locations.
        #
        # The joined form is tried FIRST when there are several groups,
        # because it is the more specific reading: six characters of CLLI
        # beat a bare four-character place token.
        candidates = list(groups)
        if len(groups) > 1:
            joined = "".join(groups)
            if joined and joined not in candidates:
                candidates.insert(0, joined)
        # STATE DISAMBIGUATION, AND WHY IT IS NOT OPTIONAL.
        #
        # MEASURED 2026-11-17: comcast.net/springfield has SEVEN hints, in
        # IL, FL, MA, OR, GA, MI and TN, whose extremes are 4,032 km apart.
        # Highest true-positive count picks Springfield IL. But a hostname
        # of the form ...springfield.ma.boston.comcast.net carries ma, and
        # Comcast rules capture that state as a separate group.
        #
        # So when a code is ambiguous, a hint whose state equals a two-letter
        # group from the SAME hostname wins over a hint with a better score.
        # 67 of the 213 ambiguous codes are fully separable this way.
        # Choosing on score alone would have silently placed Massachusetts
        # nodes in Illinois.
        two_letter = {g for g in groups if len(g) == 2}

        def pick(code):
            cands = dom_hints[code]
            if len(cands) > 1 and two_letter:
                byst = [h for h in cands
                        if (h.get("st") or
                            (h.get("location") or {}).get("st") or
                            "").lower() in two_letter]
                if len(byst) >= 1:
                    return byst[0], len(cands), "state match"
            return (cands[0], len(cands),
                    "only candidate" if len(cands) == 1 else "highest tp")

        resolved = [(g,) + pick(g) for g in candidates if g in dom_hints]

        if not resolved:
            if unresolved is None:
                # Keep the first non-resolving match as the fallback answer.
                # The token is still useful: Comcast's westroxbury is a real
                # place name absent from this release's hint list, and a
                # carrier adding a site is exactly what that looks like.
                unresolved = (rx, groups)
            continue

        if len(resolved) > 1:
            # Prefer the longest code: the joined six-character CLLI over a
            # bare four-character place token, and either over a two-letter
            # state code.
            resolved.sort(key=lambda gh: (len(gh[0]) == 2, -len(gh[0])))
        code, h, nhints, how = resolved[0]
        out["code_hint_count"] = nhints
        out["selection"] = how
        out["code"] = code
        out["matched_re"] = rx
        out["hint_type"] = h.get("type")
        out["lat"] = h.get("lat")
        out["lng"] = h.get("lng")
        loc = h.get("location") or {}
        out["place"] = loc.get("place")
        out["st"] = loc.get("st") or h.get("st")
        out["cc"] = loc.get("cc") or h.get("cc")

        others = [g for g in groups if g != code]
        if out["st"] and out["st"].lower() in others:
            out["corroborated_by"] = out["st"].lower()

        if out["lat"] and out["lng"]:
            out["status"] = "located"
        elif out["hint_type"] == "clli":
            out["status"] = "clli code, needs clli_resolve"
        else:
            out["status"] = "hint has no coordinates"
        return out

    if unresolved is not None:
        rx, groups = unresolved
        if len(groups) > 1:
            j = "".join(groups)
            if j:
                groups = [j] + list(groups)
        # Report the longest group: in a (state, place) pair the place is the
        # informative half and the state is two characters.
        cand = sorted(groups, key=lambda g: (len(g) == 2, -len(g)))
        out["code"] = cand[0] if cand else None
        out["matched_re"] = rx
        two = [g for g in groups if len(g) == 2 and g != out["code"]]
        if two:
            out["st"] = two[0].upper()
        out["status"] = "regex matched, code not in the ruleset hints"
        return out

    out["status"] = "domain has rules but none matched this hostname"
    return out


# Hostnames recorded in the repository with their geography already
# established by earlier work, used as the regression test. Each entry is
# (hostname, expected code, where the expectation comes from).
KNOWN = [
    ("99-39-184-45.lightspeed.btrgla.sbcglobal.net", "btrgla",
     "geo/zip_granularity_findings.md: all 128 sampled addresses in "
     "45.19.184.0/24 published this form; BTRG+LA is Baton Rouge LA"),
    ("po-1-rur201.westroxbury.ma.boston.comcast.net", "boston",
     "geo/node_fanout.sql header: the Comcast node naming example. The "
     "router is in Boston MA; the subscriber suburb westroxbury is also in "
     "the name and is NOT the router location"),
    ("be3664.agr22.bos01.atlas.cogentco.com", None,
     "geo/landmark_carrier_node.sql section 4d: carried 63 addresses"),
    ("be3255.ccr32.bos01.atlas.cogentco.com", None,
     "geo/landmark_carrier_node.sql section 4d: carried 24 addresses"),
    ("po-1-rur101.springfield.ma.boston.comcast.net", "springfield",
     "CONSTRUCTED from the Comcast naming pattern to test state "
     "disambiguation: springfield has seven hints 4,032 km apart and the "
     "correct answer for a hostname carrying ma is Springfield MA, not the "
     "higher-scoring Springfield IL"),
    ("dynamic-acc-1-2-3.hsd1.adln.ca.frontiernet.net", "adlnca",
     "frontiernet.net rules capture place and state as SEPARATE groups while "
     "its 324 hints are the six-character concatenation. Boris's run showed "
     "this domain with 457 hostnames, 146 codes and zero locations"),
    ("ggr2.n54ny.ip.att.net", None,
     "geo/traceroute_hostname_rules.sql: cited as transit-behaving att.net"),
]


def cmd_test(args):
    recs = read_ruleset(args)
    compiled, rejected = compile_rules(recs)
    hints = hint_index(recs)

    print(f"{len(recs)} domains in the ruleset, "
          f"{sum(len(v) for v in compiled.values())} regexes")
    if rejected:
        print(f"\n{len(rejected)} regex(es) Python would not compile. These "
              f"are NOT applied, and a domain whose only rule is rejected "
              f"will look uncovered:")
        for d, rx, why in rejected[:20]:
            print(f"  {d}: {why}\n    {rx}")
    else:
        print("every regex compiled under Python's re module")

    print("\nDecoding the hostnames this repository has already written down.")
    print("These are a regression test, not a sample: each one's geography "
          "was established by earlier work in the repo.\n")
    for host, expect, why in KNOWN:
        d = decode(host, compiled, hints)
        print(f"  {host}")
        print(f"    domain {d['domain']}  code {d['code']}  "
              f"type {d['hint_type']}  status: {d['status']}")
        if d["lat"]:
            print(f"    coordinates {d['lat']}, {d['lng']}  "
                  f"place {d['place']} {d['st'] or ''} {d['cc'] or ''}")
        if d["code_hint_count"] > 1:
            print(f"    code was AMBIGUOUS across {d['code_hint_count']} "
                  f"hints; chosen by {d['selection']}")
        if expect:
            ok = "PASS" if d["code"] == expect else "FAIL"
            print(f"    {ok}: expected code {expect}")
        print(f"    basis: {why}")
        print()


def cmd_decode(args):
    recs = read_ruleset(args)
    compiled, _ = compile_rules(recs)
    hints = hint_index(recs)
    hosts = args.hostname or [l.strip() for l in sys.stdin if l.strip()]
    for h in hosts:
        print(json.dumps(decode(h, compiled, hints)))


def cmd_load(args):
    """Put the ruleset into PostgreSQL so SQL can join to it."""
    recs = read_ruleset(args)
    compiled, rejected = compile_rules(recs)

    ok = psql_q("SELECT to_regclass('hoiho_rule_tbl') IS NOT NULL")
    if ok != "t":
        sys.exit("hoiho_rule_tbl does not exist. Apply the schema first:\n"
                 "  psql -X -P pager=off -f geo/carrier_nodes/schema.sql")

    print(f"loading {len(recs)} domains")
    psql("-qc", "TRUNCATE hoiho_geohint_tbl, hoiho_rule_tbl")

    rule_rows = []
    hint_rows = []
    for r in recs:
        sc = r.get("score") or {}
        pats = [rx for rx, _ in compiled.get(r["domain"], [])]
        bad = [rx for d, rx, _ in rejected if d == r["domain"]]
        rule_rows.append((
            r["domain"],
            pg_array(pats),
            pg_array(bad),
            sc.get("ppv"), sc.get("class"),
            int(sc.get("routers") or 0),
            int(sc.get("tp") or 0), int(sc.get("fp") or 0),
        ))
        for h in r.get("geohints") or []:
            loc = h.get("location") or {}
            hint_rows.append((
                r["domain"], (h.get("code") or "").lower(), h.get("type"),
                h.get("lat"), h.get("lng"),
                loc.get("place"), loc.get("st") or h.get("st"),
                loc.get("cc") or h.get("cc"),
                int(h.get("tp") or 0), int(h.get("fp") or 0),
            ))

    psql_copy_csv("hoiho_rule_tbl",
                  "domain, regexes, regexes_rejected, ppv, klass, routers, "
                  "tp, fp", rule_rows)
    print(f"  {len(rule_rows)} rules")
    psql_copy_csv("hoiho_geohint_tbl",
                  "domain, code, hint_type, lat, lng, place, st, cc, tp, fp",
                  hint_rows)
    print(f"  {len(hint_rows)} geohints")

    print(psql("-c", """
SELECT hint_type,
       count(*)                                       AS hints,
       count(*) FILTER (WHERE lat IS NOT NULL)        AS with_coordinates,
       count(DISTINCT domain)                          AS domains
FROM hoiho_geohint_tbl
GROUP BY hint_type
ORDER BY count(*) DESC"""))
    print("A CLLI hint is the bare six-character code: four of place and two "
          "of state, no coordinates. That is why with_coordinates is zero on "
          "that row, and it is what clli_resolve.py exists to fix.")


def cmd_apply(args):
    """Decode every hostname in the trace corpus and store the result."""
    recs = read_ruleset(args)
    compiled, _ = compile_rules(recs)
    hints = hint_index(recs)

    ok = psql_q("SELECT to_regclass('carrier_node_tbl') IS NOT NULL")
    if ok != "t":
        sys.exit("carrier_node_tbl does not exist. Apply the schema first:\n"
                 "  psql -X -P pager=off -f geo/carrier_nodes/schema.sql")

    # EVERY hop, not just the last one. ovt_places_usa_ip_trace.hops holds the
    # whole trace with a PTR per hop, stored for exactly this purpose, so the
    # node inventory is not limited to the last carrier node of each trace.
    sql = """
SELECT DISTINCT h.host, h.ip
FROM ovt_places_usa_ip_trace t
CROSS JOIN LATERAL jsonb_to_recordset(t.hops) AS h(ip text, host text)
WHERE h.host IS NOT NULL AND h.host <> ''
"""
    if args.source == "lasthop":
        sql = """
SELECT DISTINCT last_hop_hostname AS host, host(last_hop_ip) AS ip
FROM ovt_places_usa_ip_trace
WHERE last_hop_hostname IS NOT NULL AND last_hop_hostname <> ''
"""
    print(f"reading hostnames from ovt_places_usa_ip_trace, "
          f"source {args.source}")
    rows = [l.split("|") for l in psql("-qtAF|", "-c", sql).splitlines() if l]
    print(f"  {len(rows):,} distinct hostname and address pairs")
    if not rows:
        print("  Nothing to decode. On Boris's database this table holds "
              "30,226 traces with 28,180 hostnames; an empty result means "
              "the wrong database or an unpopulated hops column.")
        return

    psql("-qc", "TRUNCATE carrier_node_tbl")
    batch = []
    stats = {}
    for host, ip in rows:
        d = decode(host, compiled, hints)
        stats[d["status"]] = stats.get(d["status"], 0) + 1
        batch.append((
            d["hostname"], ip or None, d["domain"], d["code"], d["hint_type"],
            d["lat"], d["lng"], d["place"], d["st"], d["cc"],
            d["matched_re"], d["code_hint_count"], d["selection"],
            d["corroborated_by"], d["status"],
        ))

    cols = ("hostname, node_ip, domain, code, hint_type, lat, lng, "
            "place, st, cc, matched_re, code_hint_count, selection, "
            "corroborated_by, status")
    psql_copy_csv("carrier_node_tbl", cols, batch)

    print(f"\n{len(batch):,} rows written. Outcome by status:")
    for k, v in sorted(stats.items(), key=lambda x: -x[1]):
        print(f"  {v:>8,}  {k}")


def cmd_coverage(args):
    print("What the ruleset can say about the hostnames actually held.\n")
    print(psql("-c", """
SELECT status,
       count(*)                                  AS hostnames,
       count(DISTINCT domain)                    AS domains,
       count(DISTINCT code)                      AS codes
FROM carrier_node_tbl
GROUP BY status
ORDER BY count(*) DESC"""))
    print("\nBy carrier, the twenty with the most hostnames held.\n")
    print(psql("-c", """
SELECT coalesce(domain, 'no domain')      AS domain,
       count(*)                           AS hostnames,
       count(*) FILTER (WHERE lat IS NOT NULL)        AS located,
       count(*) FILTER (WHERE hint_type = 'clli')     AS clli_pending,
       count(DISTINCT code)                           AS distinct_sites
FROM carrier_node_tbl
GROUP BY domain
ORDER BY count(*) DESC
LIMIT 20"""))
    print("\nclli_pending is the count that clli_resolve.py would turn into "
          "a location. located is already usable by step 4.")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=DEFAULT_DIR,
                    help="where the CAIDA ruleset is kept")
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download the CAIDA ruleset, 212 KB")
    f.set_defaults(func=cmd_fetch)

    t = sub.add_parser("test", help="compile every regex and decode the "
                                    "hostnames the repo already documents")
    t.set_defaults(func=cmd_test)

    d = sub.add_parser("decode", help="decode hostnames given on the command "
                                      "line or on stdin")
    d.add_argument("--hostname", nargs="*")
    d.set_defaults(func=cmd_decode)

    lo = sub.add_parser("load", help="load the ruleset into PostgreSQL")
    lo.set_defaults(func=cmd_load)

    a = sub.add_parser("apply", help="decode the trace corpus into "
                                     "carrier_node_tbl")
    a.add_argument("--source", choices=["trace", "lasthop"], default="trace",
                   help="trace reads every hop from the hops jsonb; lasthop "
                        "reads only last_hop_hostname")
    a.set_defaults(func=cmd_apply)

    c = sub.add_parser("coverage", help="report what was decoded")
    c.set_defaults(func=cmd_coverage)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
