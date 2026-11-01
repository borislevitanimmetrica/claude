#!/usr/bin/env python3
"""Measure whether MX and NS records find on-premises addresses the website misses.

WHY THIS EXISTS
---------------
The landmark pipeline resolves a place's WEBSITE to an address and asks ARIN who
owns it. Measured over 12,775,630 rows, rule 2 of the onpremises step rejects
10,713,526 of them -- 83.8 per cent -- because that address belongs to a CDN,
cloud or web host. The organisation is real and its ZIP is known; only its
website is somewhere else. No additional list of organisations can fix this,
which is why adding five landmark sources (1,460,317 rows: national OSM,
Foursquare, Wikidata, dotgov, NCES IPEDS) produced 6 new ZIP codes.

A website is not the only hostname an organisation publishes. Mail exchangers
and authoritative nameservers are published at the zone apex, and an
organisation that outsources its website to Squarespace may still run its own
mail or DNS on the premises. That is a DIFFERENT KIND of evidence about the same
organisation, reached through the same machinery: hostname -> address -> ARIN
registrant -> ZIP comparison.

It may also yield nothing. A domain fronted by Cloudflare usually has Cloudflare
nameservers too, and small organisations increasingly use Google Workspace or
Microsoft 365 for mail, both of which are off-premises. So this script MEASURES
the yield on a sample and prints it. It writes nothing to landmarks_usa. Build
the full path only if the numbers here justify it; the 6-new-ZIP result is what
happens when that order is reversed.

WHAT IT MEASURES
----------------
For each sampled landmark whose website address was rejected:

  1. find the zone apex for the website host (DNS zone cut, not a suffix list)
  2. read MX and NS records at that apex
  3. resolve those hostnames to IPv4 addresses
  4. ask ARIN for each address, exactly as the website path does
  5. apply the onpremises rule unchanged and report which rule decides

The headline number is "would newly qualify": landmarks that are false today and
would be true on MX or NS evidence. Everything else is diagnosis of why not.

ZONE APEX, NOT PUBLIC SUFFIX LIST
---------------------------------
www.nwresd.k12.or.us has its apex at nwresd.k12.or.us, which no simple
"last two labels" rule finds and which needs a public suffix list to derive by
string surgery. dns.resolver.zone_for_name walks the delegation and returns the
apex directly, so the question is answered by the DNS itself. This matters for
public schools specifically, since .k12.<state>.us is exactly the case that
breaks naive domain extraction.
"""

import argparse
import collections
import csv
import os
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "overture_fetch"))

try:
    import ovt_resolve_hosts as ovt
except ImportError as exc:
    sys.exit(f"cannot import ovt_resolve_hosts.py from ../overture_fetch: {exc}")

try:
    import dns.resolver
    import dns.exception
except ImportError:
    sys.exit("This script needs dnspython. Install it with:\n"
             "    pip3 install --user dnspython\n"
             "It is used instead of one 'dig' process per lookup because the same "
             "per-call process and handshake overhead that made the RDAP step 32 times "
             "slower applies here, and this path has to scale to millions of domains.")


# --------------------------------------------------------------------------
# progress
# --------------------------------------------------------------------------
class Progress:
    """Counts finished work and prints a line every interval seconds.

    Every long step in this pipeline reports progress; a silent multi-minute
    phase is indistinguishable from a hang, and that has cost real time here.
    """

    def __init__(self, total, label, interval=15):
        self.total, self.label, self.interval = total, label, interval
        self.done = 0
        self.start = time.time()
        self.last = self.start
        self.lock = threading.Lock()

    def tick(self, n=1):
        with self.lock:
            self.done += n
            now = time.time()
            if now - self.last >= self.interval:
                self.last = now
                el = now - self.start
                rate = self.done / el if el else 0
                left = (self.total - self.done) / rate if rate else 0
                print(f"    {self.label}: {self.done:,}/{self.total:,}, "
                      f"{int(el)}s elapsed, about {int(left)}s left", flush=True)

    def finish(self):
        el = time.time() - self.start
        print(f"  {self.label}: {self.done:,}/{self.total:,} in {int(el)}s", flush=True)


# --------------------------------------------------------------------------
# the onpremises rule, mirrored from cmd_onpremises
# --------------------------------------------------------------------------
def zip5(value):
    """5-character ZIP, restoring leading zeros that numeric columns drop."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    return text.zfill(5)[:5]


class Rule:
    """The onpremises decision, evaluated in Python on freshly looked-up registrants.

    Kept in the same order as the SQL CASE in cmd_onpremises so that a result
    here means the same thing as a result there. If that CASE changes, this
    changes with it.
    """

    def __init__(self, isps, providers, adjacency):
        self.isps, self.providers, self.adjacency = isps, providers, adjacency

    @staticmethod
    def _norm(name):
        return (name or "").strip().lower()

    def decide(self, landmark_zip, regs):
        """-> (verdict, rule_label). verdict is True, False or None."""
        if not regs:
            return None, "0 no registrant data: NULL"
        if not landmark_zip:
            return None, "1 no landmark ZIP: NULL"

        names = [self._norm(r["name"]) for r in regs]
        if any(n in self.providers for n in names):
            return False, "2 CDN, cloud or web host registrant: false"

        is_isp = [n in self.isps for n in names]
        if all(is_isp):
            label = ("3a single ISP registrant: true" if len(regs) == 1
                     else "3b all ISP registrants: true")
            return True, label

        # An ISP's own ZIP is its corporate address, never the subscriber's.
        zips = [zip5(r["zip"]) for r, isp in zip(regs, is_isp) if not isp]
        zips = [z for z in zips if z]
        if landmark_zip in zips:
            return True, "4 non-ISP registrant ZIP matches: true"
        if any((landmark_zip, z) in self.adjacency for z in zips):
            return True, "5 non-ISP registrant ZIP adjacent: true"
        if not zips:
            return False, "6a no non-ISP registrant ZIP: false"
        return False, "6b ZIPs differ and are not adjacent: false"


def load_rule(args):
    print("Loading isp_names, provider_names and zip_adjacency ...", flush=True)
    isps = {r[0].strip().lower() for r in ovt.query_csv(
        f"SELECT name FROM {ovt.q(args.pg_schema)}.{ovt.q(args.isp_table)}",
        label="isp_names") if r and r[0].strip()}
    providers = set()
    has_prov = ovt.query_csv(
        f"SELECT to_regclass({ovt.lit(args.pg_schema + '.' + args.provider_table)}) IS NOT NULL"
    )[0][0] == "t"
    if has_prov:
        providers = {r[0].strip().lower() for r in ovt.query_csv(
            f"SELECT name FROM {ovt.q(args.pg_schema)}.{ovt.q(args.provider_table)}",
            label="provider_names") if r and r[0].strip()}
    else:
        print(f"WARNING: {args.provider_table} not found, so rule 2 cannot fire and "
              f"CDN addresses will be counted as on-premises.", file=sys.stderr)

    adjacency = set()
    for a, b in ovt.query_csv(
            f"""SELECT left(lpad(btrim(zip_a::text), 5, '0'), 5),
                       left(lpad(btrim(zip_b::text), 5, '0'), 5)
                FROM {ovt.q(args.pg_schema)}.{ovt.q(args.zip_table)}""",
            label="zip_adjacency"):
        if a and b:
            adjacency.add((a, b))
            adjacency.add((b, a))

    print(f"  {len(isps):,} ISP names, {len(providers):,} provider names, "
          f"{len(adjacency):,} directed ZIP adjacencies", flush=True)
    return Rule(isps, providers, adjacency)


# --------------------------------------------------------------------------
# DNS
# --------------------------------------------------------------------------
def make_resolver(args):
    res = dns.resolver.Resolver()
    if args.nameserver:
        res.nameservers = [n.strip() for n in args.nameserver.split(",") if n.strip()]
    res.timeout = args.dns_timeout
    res.lifetime = args.dns_timeout
    return res


def apex_and_records(res, host, kinds):
    """-> (apex, {kind: [hostname, ...]}, error).

    The apex comes from the delegation rather than from string surgery on the
    hostname, which is the only way .k12.or.us and similar come out right.
    """
    try:
        apex = str(dns.resolver.zone_for_name(host, resolver=res)).rstrip(".")
    except dns.exception.DNSException as exc:
        return None, {}, f"zone_for_name: {type(exc).__name__}"
    out = {}
    for kind in kinds:
        try:
            answer = res.resolve(apex, kind)
            if kind == "MX":
                out[kind] = [str(r.exchange).rstrip(".") for r in answer]
            else:
                out[kind] = [str(r.target).rstrip(".") for r in answer]
        except dns.exception.DNSException:
            out[kind] = []
    return apex, out, None


def a_records(res, host):
    try:
        return [r.address for r in res.resolve(host, "A")]
    except dns.exception.DNSException:
        return []


# --------------------------------------------------------------------------
# sampling
# --------------------------------------------------------------------------
def sample_landmarks(args):
    """Distinct (website host, landmark ZIP) pairs whose website address was rejected.

    One row per host: many places share a host, and the DNS answer is a property
    of the host, so sampling places instead would spend the budget re-asking the
    same question.
    """
    where = [f"t.lookup_status = {ovt.lit(ovt.STATUS_OK)}",
             "t.onpremises IS NOT TRUE",
             "t.overture_zip IS NOT NULL",
             "t.website IS NOT NULL"]
    if args.source:
        srcs = ",".join(ovt.lit(s.strip()) for s in args.source.split(",") if s.strip())
        where.append(f"t.source IN ({srcs})")
    if args.zip_prefix:
        where.append(f"left(lpad(btrim(t.overture_zip), 5, '0'), {len(args.zip_prefix)}) "
                     f"= {ovt.lit(args.zip_prefix)}")
    if args.rule2_only:
        where.append("t.url_location IS NOT NULL")

    sql = f"""SELECT d.host, d.zip FROM (
    SELECT DISTINCT
        lower(btrim(split_part(split_part(regexp_replace(t.website, '^[a-zA-Z]+://', ''), '/', 1), ':', 1))) AS host,
        left(lpad(btrim(t.overture_zip), 5, '0'), 5) AS zip
    FROM {ovt.q(args.pg_schema)}.{ovt.q(args.table)} t
    WHERE {' AND '.join(where)}
) d
WHERE d.host <> '' AND d.zip <> ''
ORDER BY random() LIMIT {int(args.sample)}"""

    print(f"Selecting up to {int(args.sample):,} distinct rejected website hosts "
          f"(scans {args.table}) ...", flush=True)
    rows = ovt.query_csv(sql, label="sample selection")
    print(f"  {len(rows):,} hosts sampled", flush=True)
    return [(h, z) for h, z in rows if h and z]


# --------------------------------------------------------------------------
# main measurement
# --------------------------------------------------------------------------
def run(args):
    rule = load_rule(args)
    res = make_resolver(args)
    kinds = [k.strip().upper() for k in args.kinds.split(",") if k.strip()]
    sample = sample_landmarks(args)
    if not sample:
        sys.exit("No hosts matched the sample filters.")

    # Phase 1: DNS. One resolver per thread; dnspython Resolver is not thread safe.
    local = threading.local()

    def dns_one(item):
        host, zp = item
        if not hasattr(local, "res"):
            local.res = make_resolver(args)
        apex, recs, err = apex_and_records(local.res, host, kinds)
        hosts = {}
        for kind, names in recs.items():
            ips = []
            for name in names[:args.max_names]:
                ips.extend(a_records(local.res, name))
            hosts[kind] = (names, sorted(set(ips))[:args.max_ips])
        return host, zp, apex, hosts, err

    print(f"\nPhase 1: DNS apex plus {', '.join(kinds)} for {len(sample):,} hosts "
          f"with {args.dns_threads} threads ...", flush=True)
    prog = Progress(len(sample), "DNS")
    dns_rows = []
    with ThreadPoolExecutor(max_workers=args.dns_threads) as ex:
        futs = [ex.submit(dns_one, it) for it in sample]
        try:
            for f in as_completed(futs):
                dns_rows.append(f.result())
                prog.tick()
        except KeyboardInterrupt:
            print("\nInterrupted during DNS; reporting on what finished.", flush=True)
            ex.shutdown(wait=False, cancel_futures=True)
    prog.finish()

    # Phase 2: RDAP, once per distinct address across the whole sample.
    want = set()
    for _, _, _, hosts, _ in dns_rows:
        for _, (_, ips) in hosts.items():
            want.update(ips)
    want = sorted(want)
    print(f"\nPhase 2: RDAP for {len(want):,} distinct addresses with "
          f"{args.rdap_threads} threads ...", flush=True)
    rdap = {}
    prog = Progress(len(want), "RDAP")
    with ThreadPoolExecutor(max_workers=args.rdap_threads) as ex:
        futs = {ex.submit(ovt.rdap_one, None, ip, args.rdap_timeout,
                          args.rdap_attempts, 0, False, True): ip for ip in want}
        try:
            for f in as_completed(futs):
                ip, result, err = f.result()
                rdap[ip] = result if not err else None
                prog.tick()
        except KeyboardInterrupt:
            print("\nInterrupted during RDAP; reporting on what finished.", flush=True)
            ex.shutdown(wait=False, cancel_futures=True)
    prog.finish()

    # Phase 3: apply the rule.
    stats = collections.Counter()
    by_rule = collections.defaultdict(collections.Counter)
    winners = []
    for host, zp, apex, hosts, err in dns_rows:
        stats["hosts"] += 1
        if err:
            stats["apex_failed"] += 1
            continue
        qualified_by = None
        for kind in kinds:
            names, ips = hosts.get(kind, ([], []))
            if names:
                stats[f"{kind}_present"] += 1
            if not ips:
                if names:
                    stats[f"{kind}_no_address"] += 1
                continue
            stats[f"{kind}_resolved"] += 1
            best, best_label = None, None
            for ip in ips:
                result = rdap.get(ip)
                if not result:
                    continue
                r1, z1, r2, z2 = ovt.registrant_fields(result)
                regs = [{"name": r1, "zip": z1}] if r1 else []
                if r2:
                    regs.append({"name": r2, "zip": z2})
                verdict, label = rule.decide(zp, regs)
                if verdict is True:
                    best, best_label = ip, label
                    break
                if best_label is None:
                    best_label = label
            by_rule[kind][best_label or "no RDAP answer"] += 1
            if best is not None:
                stats[f"{kind}_qualifies"] += 1
                qualified_by = qualified_by or (kind, best, best_label, apex)
        if qualified_by:
            stats["newly_qualifies"] += 1
            kind, ip, label, apex = qualified_by
            winners.append({"website_host": host, "apex": apex, "landmark_zip": zp,
                            "evidence": kind, "address": ip, "rule": label})

    report(args, stats, by_rule, kinds, winners)


def report(args, stats, by_rule, kinds, winners):
    n = stats["hosts"] or 1
    print("\n" + "=" * 74)
    print("MX / NS YIELD ON LANDMARKS THE WEBSITE PATH REJECTED")
    print("=" * 74)
    print(f"{'hosts sampled':<46}{stats['hosts']:>12,}")
    print(f"{'  zone apex not resolvable':<46}{stats['apex_failed']:>12,}")
    for kind in kinds:
        print(f"\n  {kind}")
        for key, label in ((f"{kind}_present", "records published"),
                           (f"{kind}_no_address", "published but no IPv4"),
                           (f"{kind}_resolved", "resolved to at least one address"),
                           (f"{kind}_qualifies", "would be on-premises")):
            print(f"{'    ' + label:<46}{stats[key]:>12,}")
        if by_rule[kind]:
            print(f"    which rule decided:")
            for label, count in sorted(by_rule[kind].items(), key=lambda kv: -kv[1]):
                print(f"      {label:<50}{count:>8,}")
    pct = 100.0 * stats["newly_qualifies"] / n
    print("\n" + "-" * 74)
    print(f"{'NEWLY QUALIFYING on MX or NS evidence':<46}"
          f"{stats['newly_qualifies']:>12,}  ({pct:.2f}% of sample)")
    print("-" * 74)
    print("\nThese hosts are on-premises=false today because their WEBSITE address\n"
          "belongs to a provider. The percentage above is what a full MX/NS pass\n"
          "would recover. Weigh it against the website path's own yield before\n"
          "building one: the last five landmark sources returned 6 new ZIP codes.")

    if args.out and winners:
        with open(args.out, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(winners[0].keys()))
            w.writeheader()
            w.writerows(winners)
        print(f"\n{len(winners):,} qualifying hosts written to {args.out}")


def main():
    p = argparse.ArgumentParser(
        description="Measure MX and NS yield on landmarks whose website address was rejected.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--table", default="landmarks_usa")
    p.add_argument("--pg-schema", default="public")
    p.add_argument("--isp-table", default="isp_names")
    p.add_argument("--provider-table", default="provider_names")
    p.add_argument("--zip-table", default="zip_adjacency")
    p.add_argument("--sample", type=int, default=2000,
                   help="distinct website hosts to test (default 2000)")
    p.add_argument("--source", help="comma-separated sources, e.g. overture,nces_ipeds")
    p.add_argument("--zip-prefix", help="restrict to ZIPs starting with this, e.g. 021")
    p.add_argument("--rule2-only", action="store_true",
                   help="only hosts that have a stored RDAP record")
    p.add_argument("--kinds", default="MX,NS", help="record types to try (default MX,NS)")
    p.add_argument("--max-names", type=int, default=4,
                   help="MX or NS hostnames to resolve per domain (default 4)")
    p.add_argument("--max-ips", type=int, default=4,
                   help="addresses to RDAP per record type per domain (default 4)")
    p.add_argument("--dns-threads", type=int, default=16)
    p.add_argument("--dns-timeout", type=float, default=5.0)
    p.add_argument("--nameserver", help="comma-separated resolver addresses; default is the system's")
    p.add_argument("--rdap-threads", type=int, default=4,
                   help="ARIN gives 1.7x throughput for 8x threads, so 4 is the sane default")
    p.add_argument("--rdap-timeout", type=float, default=30.0)
    p.add_argument("--rdap-attempts", type=int, default=3)
    p.add_argument("--out", help="CSV of qualifying hosts for inspection")
    args = p.parse_args()

    ovt.check_ident("--table", args.table)
    ovt.check_ident("--pg-schema", args.pg_schema)
    run(args)


if __name__ == "__main__":
    main()
