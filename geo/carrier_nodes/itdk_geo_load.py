"""Load the ITDK's OWN node geolocation file, which we should have used first.

WHY THIS EXISTS, AND WHAT IT CORRECTS

Boris, 2026-11-18: "In ITDK, nodes have latitude/longitude; I don't
understand what problem you're trying to solve."

He is right and I had not checked. The ITDK 2025-08 directory contains
midar-iff-snmp-tnt.nodes.geo.bz2 alongside the geo-re.jsonl.bz2 we did
download. I took the Hoiho REGEX file, reimplemented the matching in
hoiho_apply.py, and then went looking for CLLI coordinates to fill the gaps,
while a finished node-geolocation file sat in the same directory listing.

MEASURED on the real file, 76,504,235 lines:

    maxmind   76,326,112    99.77 per cent
    hoiho        162,583     0.21
    ix            15,534     0.02

CAIDA's own application of the Hoiho rules located 162,583 nodes. Ours
located 5,109. The gap is not that our matching was worse; it is that we
only ever decoded the 22,790 hostnames in Boris's traceroute corpus, while
the ITDK file covers every node in the topology. Either way, the work was
already done and published.

ALL THREE METHODS ARE USED. MY CIRCULARITY OBJECTION WAS WRONG

I first marked the 99.77 per cent of rows whose method is maxmind as
unusable, on the grounds that ip-api.com and MaxMind are the same kind of
source, so locating a node by MaxMind and then observing ip-api resolutions
congregating there proves nothing.

Boris, 2026-11-18: "You've lost track of what we are doing. We are combining
ITDK and Fabric data to determine which census tracts, and therefore ZIP
codes, are served through which headends/COs... So long as MaxMind vaguely
correctly identifies the location of the headends/COs, which it apparently
does, the plan works even if MaxMind is slightly out of date (we are not
chasing individual nodes, only their places of concentration - headends/COs.
The constantly relocating IP ranges also don't bother us because this part of
the system is agnostic as to them."

He is right and the error was mine. I conflated two different uses of a
coordinate:

  AS A MEASUREMENT of where a building physically is. Here MaxMind's quality
  would matter, and my worry would be reasonable.

  AS A JOIN KEY associating customer IP addresses with the infrastructure
  they are served through. Here the two sources sharing a systematic bias is
  harmless and actually helps: if MaxMind places both the router and its
  customers' addresses at the same approximate spot, they still match each
  other, and the bias CANCELS in the join rather than compounding.

Step 6 of the plan uses the coordinate the second way. The geographic truth
is carried by the Fabric and BDC coverage data, which is authoritative and
address-level; the node coordinate only has to be good enough to identify a
concentration and to match ip-api clusters to it. Nothing in the chain uses
"ip-api congregates here" as evidence of where the headend is.

Concentration is also why individual node error is tolerable. One node's
coordinate is noisy; the centroid of many nodes at one facility is not, and
it is the facility we want.

So no method is excluded. Every row records which method produced it, and
method_agreement below MEASURES how far maxmind sits from hoiho and ix on
the nodes where more than one method has an answer, which is the way to
check "vaguely correctly" rather than assume it in either direction.

WHAT IT NEEDS, AND THE SIZES, MEASURED BY HEAD REQUEST

  midar-iff-snmp-tnt.nodes.geo.bz2    328,769,755 bytes   node_id to location
  midar-iff-snmp-tnt.ifaces.bz2     1,147.85 MB           address to node_id

The ifaces file is needed because nodes.geo is keyed by node_id and our
carrier_node_tbl is keyed by address. Neither file is loaded whole: both are
STREAMED and filtered against the addresses we actually hold, so nothing
like 76 million rows reaches the database.

USAGE

  python3 -u itdk_geo_load.py fetch --dir /home/boris/geo/caida
  python3 -u itdk_geo_load.py load  --dir /home/boris/geo/caida
  python3 -u itdk_geo_load.py compare
  python3 -u itdk_geo_load.py selftest
"""

import argparse
import bz2
import os
import subprocess
import sys
import time

BASE = ("https://publicdata.caida.org/datasets/topology/ark/ipv4/itdk/"
        "2025-08")
GEO_FILE = "midar-iff-snmp-tnt.nodes.geo.bz2"
IFACES_FILE = "midar-iff-snmp-tnt.ifaces.bz2"
UA = "trugeo-research/1.0 (topology research; via project repo)"

INDEPENDENT = ("hoiho", "ix")


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def psql_copy(copy_sql, line_iter):
    """Stream lines into psql for a \\copy FROM STDIN."""
    p = subprocess.Popen(
        ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", "-q",
         "-c", copy_sql],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    n = 0
    try:
        for line in line_iter:
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


def parse_geo(line):
    """Parse one nodes.geo line.

    Real format, confirmed against the file rather than assumed:

      node.geo N13:\\tEU\\tHU\\t\\tFuzesgyarmat\\t47.100000\\t21.216670\\t\\t\\thoiho

    The header declares the fields after the colon as

      continent country region city lat long pop IX source

    Region, pop and IX are frequently empty. The method is the LAST field,
    not a fixed index, because empty trailing fields make a positional read
    of it fragile.
    """
    if not line or line.startswith("#"):
        return None
    if not line.startswith("node.geo "):
        return None
    head, _, rest = line.partition(":")
    node_id = head[len("node.geo "):].strip()
    if not node_id.startswith("N"):
        return None
    f = rest.rstrip("\n").split("\t")
    # Leading empty element from the tab right after the colon.
    while f and f[0] == "":
        f.pop(0)
    if len(f) < 6:
        return None
    method = f[-1].strip()
    continent, country, region, city = f[0], f[1], f[2], f[3]
    try:
        lat = float(f[4])
        lon = float(f[5])
    except (ValueError, IndexError):
        return None
    return (node_id, continent, country, region, city, lat, lon, method)


def parse_iface(line):
    """Parse one ifaces line, returning (address, node_id) or None.

    Format from the README:  <address> [<node_id>] [<link_id>] [T] [D]
    Any bracketed field may be absent, so the node_id is found by its N
    prefix rather than by position.
    """
    if not line or line.startswith("#"):
        return None
    parts = line.split()
    if not parts:
        return None
    addr = parts[0]
    for p in parts[1:]:
        if p.startswith("N") and p[1:].isdigit():
            return addr, p
    return None


def fetch_one(url, path, timeout=3600):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        print(f"  already present, {os.path.getsize(path):,} bytes: "
              f"{os.path.basename(path)}", flush=True)
        return True
    tmp = path + ".part"
    print(f"  downloading {os.path.basename(path)} ...", flush=True)
    r = subprocess.run(
        ["curl", "-sS", "--fail", "-m", str(timeout), "-A", UA,
         "-o", tmp, url])
    if r.returncode != 0 or not os.path.exists(tmp):
        print(f"  FAILED, curl exit {r.returncode}. Nothing written.",
              flush=True)
        if os.path.exists(tmp):
            os.unlink(tmp)
        return False
    # VALIDATE IT IS REALLY BZIP2 BEFORE RENAMING. An error page saved under
    # a .bz2 name has already cost this project a day: four 438 byte Akamai
    # HTML pages were reported as successful downloads.
    try:
        with bz2.open(tmp, "rb") as fh:
            fh.read(4096)
    except (OSError, EOFError) as exc:
        print(f"  FAILED, downloaded file is not valid bzip2: {exc}",
              flush=True)
        print(f"  first bytes: {open(tmp, 'rb').read(120)!r}", flush=True)
        os.unlink(tmp)
        return False
    os.rename(tmp, path)
    print(f"  ok, {os.path.getsize(path):,} bytes", flush=True)
    return True


def cmd_fetch(args):
    os.makedirs(args.dir, exist_ok=True)
    print("Fetching the ITDK node geolocation and interface files.")
    print("Sizes measured by HEAD request: nodes.geo is about 329 MB and "
          "ifaces about 1.15 GB compressed. Neither is loaded whole.\n")
    ok = True
    for f in (GEO_FILE, IFACES_FILE):
        ok = fetch_one(f"{BASE}/{f}", os.path.join(args.dir, f)) and ok
    return 0 if ok else 1


def our_addresses():
    """The node addresses we actually hold, as a set."""
    out = set()
    for line in psql("-qtA", "-c",
                     "SELECT DISTINCT host(node_ip) FROM carrier_node_tbl "
                     "WHERE node_ip IS NOT NULL").splitlines():
        s = line.strip()
        if s:
            out.add(s)
    return out


def cmd_load(args):
    if psql_q("SELECT to_regclass('carrier_node_tbl') IS NOT NULL") != "t":
        sys.exit("carrier_node_tbl does not exist. Run the carrier_nodes "
                 "schema first.")

    geo_path = os.path.join(args.dir, GEO_FILE)
    if_path = os.path.join(args.dir, IFACES_FILE)
    for p in (geo_path, if_path):
        if not os.path.exists(p):
            sys.exit(f"missing {p}\nRun fetch first:\n"
                     f"  python3 -u geo/carrier_nodes/itdk_geo_load.py "
                     f"fetch --dir {args.dir}")

    addrs = our_addresses()
    print(f"carrier_node_tbl holds {len(addrs):,} distinct node "
          f"address(es). Both files are streamed and filtered to these, so "
          f"nothing like 76 million rows reaches the database.\n", flush=True)
    if not addrs:
        sys.exit("No node addresses to match. Nothing to do.")

    psql("-qc", """
CREATE TABLE IF NOT EXISTS itdk_node_geo_tbl (
    node_id     text PRIMARY KEY,
    continent   text,
    country     text,
    region      text,
    city        text,
    lat         double precision,
    lon         double precision,
    method      text NOT NULL,
    loaded_at   timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS itdk_iface_tbl (
    address     inet PRIMARY KEY,
    node_id     text NOT NULL);
CREATE INDEX IF NOT EXISTS itdk_iface_node_ix ON itdk_iface_tbl (node_id);
COMMENT ON COLUMN itdk_node_geo_tbl.method IS
  'hoiho reads the operator DNS naming, ix is a known exchange facility, maxmind is IP geolocation of the router address. ALL THREE ARE USED. The coordinate is a join key associating customer addresses with the infrastructure serving them, not a measurement of where a building is, so a bias shared with ip-api cancels in the join instead of compounding. Recorded so agreement between methods can be measured.'""")

    # PASS ONE: ifaces, keeping only our addresses, to learn their node_ids.
    print("pass 1 of 2: ifaces, finding the node_id of each of our "
          "addresses", flush=True)
    t0 = time.monotonic()
    want_nodes = set()
    kept = 0
    seen = 0

    def iface_lines():
        nonlocal kept, seen
        with bz2.open(if_path, "rt", encoding="utf-8",
                      errors="replace") as fh:
            for line in fh:
                seen += 1
                if seen % 20000000 == 0:
                    print(f"    {seen:,} interface lines read, {kept:,} "
                          f"matched, {time.monotonic() - t0:.0f}s",
                          flush=True)
                r = parse_iface(line)
                if r is None:
                    continue
                addr, node_id = r
                if addr in addrs:
                    want_nodes.add(node_id)
                    kept += 1
                    yield f"{addr}\t{node_id}\n"

    psql("-qc", "TRUNCATE itdk_iface_tbl")
    psql_copy("\\copy itdk_iface_tbl (address, node_id) FROM STDIN",
              iface_lines())
    print(f"  {seen:,} interface lines read, {kept:,} of our addresses "
          f"found, {len(want_nodes):,} distinct node(s), in "
          f"{(time.monotonic() - t0) / 60:.1f} min", flush=True)

    if not want_nodes:
        print("\nNONE of our addresses appear in the ITDK ifaces file. "
              "That is a real finding, not an error: it would mean the "
              "traceroute corpus and this ITDK vintage do not overlap. "
              "Nothing further loaded.")
        return 1

    # PASS TWO: nodes.geo, keeping only those node_ids.
    print("\npass 2 of 2: nodes.geo, taking the location of those nodes",
          flush=True)
    t1 = time.monotonic()
    gseen = 0
    gkept = 0
    by_method = {}

    def geo_lines():
        nonlocal gseen, gkept
        with bz2.open(geo_path, "rt", encoding="utf-8",
                      errors="replace") as fh:
            for line in fh:
                gseen += 1
                if gseen % 20000000 == 0:
                    print(f"    {gseen:,} geo lines read, {gkept:,} kept, "
                          f"{time.monotonic() - t1:.0f}s", flush=True)
                r = parse_geo(line)
                if r is None:
                    continue
                node_id, cont, country, region, city, lat, lon, method = r
                if node_id not in want_nodes:
                    continue
                gkept += 1
                by_method[method] = by_method.get(method, 0) + 1
                yield ("\t".join([node_id, cont, country, region, city,
                                  repr(lat), repr(lon), method])
                       + "\n")

    psql("-qc", "TRUNCATE itdk_node_geo_tbl")
    psql_copy("\\copy itdk_node_geo_tbl (node_id, continent, country, "
              "region, city, lat, lon, method) FROM STDIN",
              geo_lines())
    print(f"  {gseen:,} geo lines read, {gkept:,} kept, in "
          f"{(time.monotonic() - t1) / 60:.1f} min", flush=True)

    print("\nby method, for OUR nodes:", flush=True)
    for m in sorted(by_method, key=lambda k: -by_method[k]):
        print(f"    {m:<10} {by_method[m]:>8,}", flush=True)

    psql("-qc", """
CREATE OR REPLACE VIEW itdk_node_located AS
SELECT i.address, g.node_id, g.method, g.city, g.region, g.country,
       g.lat, g.lon
FROM itdk_iface_tbl i
JOIN itdk_node_geo_tbl g USING (node_id)
WHERE g.lat IS NOT NULL;
COMMENT ON VIEW itdk_node_located IS
  'Every node address with an ITDK location, from any method. The coordinate is used as a join key associating customer addresses with the infrastructure serving them, so a bias shared with ip-api cancels in the join; it is not used as a measurement of where a building physically is. method is carried through so any consumer can weigh it.'""")

    print()
    print(psql("-c", """
SELECT method, count(*) AS addresses,
       count(DISTINCT node_id) AS nodes,
       count(DISTINCT city) AS cities
FROM itdk_node_located GROUP BY 1 ORDER BY 2 DESC"""))
    return 0


def cmd_agreement(args):
    """How far apart the methods put the SAME node. Tests "vaguely correctly".

    Boris's premise is that MaxMind identifies headend and CO locations
    vaguely correctly, and that this is sufficient because the plan wants
    places of concentration rather than individual nodes. That premise is
    measurable rather than arguable, and this measures it.

    A node can appear with more than one method across the ITDK's three
    input files, and where it does, the separation between them is a direct
    read on how far MaxMind sits from a location derived independently, by
    the operator's own DNS naming or by a known exchange facility.

    What the number means: a separation of a few kilometres is consistent
    with MaxMind resolving to a city or facility centroid, which is fine for
    identifying a concentration. A separation of hundreds of kilometres
    would mean MaxMind is resolving to a registered head office or a
    national centroid, which would put a headend in the wrong metropolitan
    area and assign its tracts to the wrong facility. Those two cases need
    telling apart, and only the data can do it.
    """
    if psql_q("SELECT to_regclass('itdk_node_geo_tbl') IS NOT NULL") != "t":
        sys.exit("itdk_node_geo_tbl does not exist. Run load first.")

    print("Separation between methods on the same node, where the ITDK has "
          "more than one answer.\n")
    print(psql("-c", """
WITH mm AS (
  SELECT node_id, lat, lon FROM itdk_node_geo_tbl WHERE method = 'maxmind'
), ind AS (
  SELECT node_id, method, lat, lon FROM itdk_node_geo_tbl
  WHERE method IN ('hoiho', 'ix')
), d AS (
  SELECT i.method,
         6371 * sqrt(pow(radians(m.lat - i.lat), 2) +
                     pow(radians(m.lon - i.lon) * cos(radians(i.lat)), 2))
           AS km
  FROM ind i JOIN mm m USING (node_id)
)
SELECT method,
       count(*)                                        AS nodes_compared,
       round(avg(km)::numeric, 1)                      AS mean_km,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY km))::numeric, 1)
                                                       AS median_km,
       round((percentile_cont(0.9) WITHIN GROUP (ORDER BY km))::numeric, 1)
                                                       AS p90_km,
       round(max(km)::numeric, 1)                      AS worst_km,
       count(*) FILTER (WHERE km <= 10)                AS within_10km,
       count(*) FILTER (WHERE km > 100)                AS over_100km
FROM d GROUP BY 1 ORDER BY 2 DESC"""))

    print("If nodes_compared is 0, the ITDK merge kept ONE method per node "
          "and this cannot be measured from these files alone. That is "
          "itself worth knowing: it would mean there is no internal "
          "cross-check available and the premise has to be tested another "
          "way, for instance against the rate centres clli_resolve "
          "already located.\n")

    # A SECOND, INDEPENDENT CHECK that does not need two methods per node.
    # clli_resolve.py located rate centres from the Local Calling Guide,
    # which is neither MaxMind nor ip-api. Where a node has both, the
    # separation is a read on MaxMind against a published tariff geography.
    if psql_q("SELECT to_regclass('clli_site_tbl') IS NOT NULL") == "t":
        print("Against the rate centres located from the Local Calling "
              "Guide, which is independent of both MaxMind and ip-api:\n")
        print(psql("-c", """
WITH j AS (
  SELECT l.method,
         6371 * sqrt(pow(radians(s.rc_lat - l.lat), 2) +
                     pow(radians(s.rc_lon - l.lon) * cos(radians(l.lat)), 2))
           AS km
  FROM carrier_node_tbl n
  JOIN itdk_node_located l ON l.address = n.node_ip
  JOIN clli_site_tbl s ON s.clli6 = n.code
  WHERE n.hint_type = 'clli' AND s.rc_lat IS NOT NULL
)
SELECT method, count(*) AS nodes,
       round(avg(km)::numeric, 1) AS mean_km,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY km))::numeric, 1)
         AS median_km,
       round(max(km)::numeric, 1) AS worst_km,
       count(*) FILTER (WHERE km <= 25) AS within_25km
FROM j GROUP BY 1 ORDER BY 2 DESC"""))
        print("A rate centre is a tariff geography, so some separation is "
              "expected even when both are right. Tens of kilometres is "
              "unremarkable; hundreds is not.")
    return 0


def cmd_concentration(args):
    """Places of concentration: the candidate headends and COs.

    This is step 2 of the plan, "compile headend and central-office
    locations of routing and switching equipment", and Boris's point that
    the unit of interest is the CONCENTRATION rather than the node.

    Nodes are grouped by carrier and by exact coordinate. Exact grouping is
    the right first cut rather than a distance clustering, because
    geolocation sources resolve many addresses to one facility or city
    centroid, so the repeated coordinate IS the concentration. A coarser
    grouping is given as well for the cases where a facility is spread over
    several nearby points.
    """
    if psql_q("SELECT to_regclass('itdk_node_located') IS NOT NULL") != "t":
        sys.exit("itdk_node_located does not exist. Run load first.")

    psql("-qc", """
CREATE OR REPLACE VIEW itdk_concentration AS
SELECT split_part(n.hostname, '.', -2) || '.' ||
       split_part(n.hostname, '.', -1)        AS carrier_domain,
       l.lat, l.lon, l.city, l.region, l.country,
       string_agg(DISTINCT l.method, '+' ORDER BY l.method) AS methods,
       count(DISTINCT n.node_ip)              AS node_addresses,
       count(DISTINCT n.hostname)             AS hostnames,
       count(DISTINCT l.node_id)              AS nodes
FROM carrier_node_tbl n
JOIN itdk_node_located l ON l.address = n.node_ip
GROUP BY 1, 2, 3, 4, 5, 6;
COMMENT ON VIEW itdk_concentration IS
  'Candidate headend and central office sites: carrier plus a coordinate at which several of its nodes concentrate. The concentration is the unit of interest, not the individual node, because one node coordinate is noisy while a repeated coordinate identifies a facility. methods shows which ITDK geolocation methods contributed.'""")

    print("Concentrations carrying the most node addresses. These are the "
          "candidate serving sites step 4 measures distances from.\n")
    print(psql("-c", f"""
SELECT carrier_domain, city, region, methods, node_addresses, hostnames,
       round(lat::numeric, 4) AS lat, round(lon::numeric, 4) AS lon
FROM itdk_concentration
WHERE node_addresses >= {int(args.min_nodes)}
ORDER BY node_addresses DESC, carrier_domain
LIMIT {int(args.limit)}"""))

    print("\nPer carrier, how many distinct concentrations:\n")
    print(psql("-c", f"""
SELECT carrier_domain,
       count(*)                                       AS sites,
       sum(node_addresses)                            AS node_addresses,
       count(*) FILTER (WHERE node_addresses >= {int(args.min_nodes)})
                                                      AS sites_above_min,
       max(node_addresses)                            AS biggest_site
FROM itdk_concentration
GROUP BY 1 ORDER BY node_addresses DESC LIMIT {int(args.limit)}"""))
    return 0


def cmd_compare(args):
    """Our decode against the ITDK's own, on the same nodes.

    The CTE is named paired, not both: BOTH is a reserved word in
    PostgreSQL, from TRIM(BOTH ...), and the first version failed with
    "syntax error at or near both". Caught by running it.
    """
    if psql_q("SELECT to_regclass('itdk_node_located') IS NOT NULL") != "t":
        sys.exit("itdk_node_located does not exist. Run load first.")
    print("Our hoiho_apply decode against the ITDK's own geolocation, on "
          "the nodes where both have an answer.\n")
    print(psql("-c", """
WITH paired AS (
  SELECT n.hostname, n.node_ip, n.lat AS our_lat, n.lon AS our_lon,
         l.lat AS itdk_lat, l.lon AS itdk_lon, l.method, l.city
  FROM carrier_node_tbl n
  JOIN itdk_node_located l ON l.address = n.node_ip
  WHERE n.lat IS NOT NULL
)
SELECT method,
       count(*) AS compared,
       round(avg(6371 * sqrt(
         pow(radians(itdk_lat - our_lat), 2) +
         pow(radians(itdk_lon - our_lon) * cos(radians(our_lat)), 2)))::numeric, 1)
         AS mean_km_apart,
       round(max(6371 * sqrt(
         pow(radians(itdk_lat - our_lat), 2) +
         pow(radians(itdk_lon - our_lon) * cos(radians(our_lat)), 2)))::numeric, 1)
         AS worst_km
FROM paired GROUP BY 1 ORDER BY 2 DESC"""))
    print("A large mean separation on method hoiho would mean our "
          "reimplementation of the rules disagrees with CAIDA's own "
          "application of them, on the same rules. That is worth knowing "
          "before trusting either.\n")
    print(psql("-c", """
SELECT
  (SELECT count(*) FROM carrier_node_tbl WHERE lat IS NOT NULL)
    AS ours_located,
  (SELECT count(DISTINCT address) FROM itdk_node_located)
    AS itdk_located_usable,
  (SELECT count(*) FROM carrier_node_tbl n
    WHERE n.lat IS NULL
      AND EXISTS (SELECT 1 FROM itdk_node_located l
                  WHERE l.address = n.node_ip))
    AS ours_blank_itdk_has"""))
    return 0


def cmd_selftest(args):
    """Parse real lines taken from the published files."""
    geo_cases = [
        ("node.geo N13:\tEU\tHU\t\tFuzesgyarmat\t47.100000\t21.216670"
         "\t\t\thoiho",
         ("N13", "EU", "HU", "", "Fuzesgyarmat", 47.1, 21.21667, "hoiho")),
        ("node.geo N15:\tEU\tHU\tBK\tBaja\t46.182990\t18.953070\t\t\thoiho",
         ("N15", "EU", "HU", "BK", "Baja", 46.18299, 18.95307, "hoiho")),
        ("node.geo N100:\tAF\tZA\tGT\tJohannesburg\t-26.139200\t28.246000"
         "\t\t\thoiho",
         ("N100", "AF", "ZA", "GT", "Johannesburg", -26.1392, 28.246,
          "hoiho")),
        ("# format:node.geo N\\d+: continent country region city lat long "
         "pop IX source", None),
        ("# exe:merge-itdk.pl", None),
    ]
    iface_cases = [
        ("1.0.174.107 N34980480 D", ("1.0.174.107", "N34980480")),
        ("1.0.101.6 N18137917 L537067 T", ("1.0.101.6", "N18137917")),
        ("1.28.124.57 N45020", ("1.28.124.57", "N45020")),
        ("11.3.4.2 N18137965 L537125 T D", ("11.3.4.2", "N18137965")),
        ("1.0.175.90", None),
    ]

    bad = 0
    print("nodes.geo parsing, against lines taken from the published file")
    for line, want in geo_cases:
        got = parse_geo(line)
        ok = got == want
        if not ok:
            bad += 1
        print(f"  {'ok  ' if ok else 'FAIL'}  {line[:52]!r}")
        if not ok:
            print(f"        wanted {want}")
            print(f"        got    {got}")

    print("\nifaces parsing, against the README's own examples")
    for line, want in iface_cases:
        got = parse_iface(line)
        ok = got == want
        if not ok:
            bad += 1
        print(f"  {'ok  ' if ok else 'FAIL'}  {line!r} -> {got}")
        if not ok:
            print(f"        wanted {want}")

    print()
    if bad:
        print(f"{bad} case(s) failed.")
        return 1
    print("All parse cases pass. The method is read as the LAST field, not "
          "a fixed index, because empty trailing columns are common.")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download nodes.geo and ifaces")
    f.add_argument("--dir", default="/home/boris/geo/caida")
    f.set_defaults(func=cmd_fetch)

    l = sub.add_parser("load", help="stream both and keep only our nodes")
    l.add_argument("--dir", default="/home/boris/geo/caida")
    l.set_defaults(func=cmd_load)

    c = sub.add_parser("compare", help="our decode against the ITDK's own")
    c.set_defaults(func=cmd_compare)

    a = sub.add_parser("agreement",
                       help="how far apart the methods put the same node, "
                            "which is how to test 'vaguely correctly'")
    a.set_defaults(func=cmd_agreement)

    k = sub.add_parser("concentration",
                       help="places of concentration: candidate headends "
                            "and COs, which is step 2 of the plan")
    k.add_argument("--min-nodes", type=int, default=3,
                   help="a concentration must carry at least this many node "
                        "addresses, default 3")
    k.add_argument("--limit", type=int, default=30)
    k.set_defaults(func=cmd_concentration)

    s = sub.add_parser("selftest", help="parse real published lines")
    s.set_defaults(func=cmd_selftest)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
