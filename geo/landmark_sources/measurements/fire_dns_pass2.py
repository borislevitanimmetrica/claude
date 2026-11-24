#!/usr/bin/env python3
"""Narrow the MX/NS upper bound, and estimate the rule-2 survival rate.

Pass 1 found 656 hosts with MX under their own apex and 166 with NS under their
own apex. "Under its own apex" is only an UPPER BOUND on self-hosted: mail.x.org
can still be a CNAME into Microsoft or an A record inside a hosting provider's
allocation. This pass resolves those names and reads the PTR, which is the
cheapest available proxy for who owns the address.
"""
import csv, collections, json, re, threading
from concurrent.futures import ThreadPoolExecutor, as_completed

import dns.resolver, dns.exception, dns.reversename

DET = "/projects/sandbox/.kiro/landmark_research/fire_dns_detail.csv"

local = threading.local()


def res():
    if not hasattr(local, "r"):
        r = dns.resolver.Resolver()
        r.timeout = 4.0
        r.lifetime = 6.0
        local.r = r
    return local.r


def parent2(n):
    p = (n or "").rstrip(".").lower().split(".")
    return ".".join(p[-2:]) if len(p) >= 2 else (n or "")


def resolve_ptr(name):
    r = res()
    out = {"name": name, "ip": "", "ptr": "", "ptr_parent": ""}
    try:
        out["ip"] = sorted({x.address for x in r.resolve(name, "A")})[0]
    except dns.exception.DNSException:
        return out
    try:
        rev = dns.reversename.from_address(out["ip"])
        out["ptr"] = str(r.resolve(rev, "PTR")[0]).rstrip(".")
        out["ptr_parent"] = parent2(out["ptr"])
    except dns.exception.DNSException:
        out["ptr_parent"] = "(no PTR)"
    return out


def main():
    rows = list(csv.DictReader(open(DET)))
    print(f"{len(rows):,} rows from pass 1")

    jobs = []
    for r in rows:
        apex2 = parent2(r["apex"])
        if not apex2:
            continue
        for kind in ("mx", "ns"):
            parents = (r[kind + "_parents"] or "").split(";")
            if apex2 in parents:
                for n in (r[kind] or "").split(";"):
                    if n and parent2(n) == apex2:
                        jobs.append((r["host"], r["apex"], r["zip"], kind, n, r["a"]))

    names = sorted({j[4] for j in jobs})
    print(f"{len(jobs):,} self-apex records across {len(names):,} distinct names")

    got = {}
    with ThreadPoolExecutor(max_workers=48) as ex:
        futs = {ex.submit(resolve_ptr, n): n for n in names}
        for f in as_completed(futs, timeout=300):
            try:
                d = f.result(timeout=1)
                got[d["name"]] = d
            except Exception:
                pass
    print(f"resolved {len(got):,} of {len(names):,}")

    by_kind = collections.defaultdict(lambda: collections.Counter())
    hosts_with = collections.defaultdict(set)
    same_ip = collections.Counter()
    ptrp = collections.defaultdict(collections.Counter)
    for host, apex, zp, kind, name, web_ip in jobs:
        d = got.get(name)
        if not d or not d["ip"]:
            by_kind[kind]["no address"] += 1
            continue
        by_kind[kind]["resolved"] += 1
        hosts_with[kind].add(host)
        ptrp[kind][d["ptr_parent"] or "(no PTR)"] += 1
        if web_ip and d["ip"] == web_ip:
            same_ip[kind] += 1

    print()
    for kind in ("mx", "ns"):
        print(f"=== {kind.upper()} under the organisation's own apex ===")
        print(f"  hosts with at least one such record resolving: {len(hosts_with[kind]):,}")
        print(f"  of those, record address EQUALS the website address: {same_ip[kind]:,}")
        print(f"  top PTR parents of those addresses:")
        for k, v in ptrp[kind].most_common(12):
            print(f"    {v:>5}  {k}")
        print()

    # Rule-2 proxy on the website address itself.
    web = collections.Counter(r["ptr_parent"] for r in rows if r["a"])
    noptr = web.get("(no PTR)", 0)
    print("=== website address, PTR parent concentration ===")
    tot = sum(web.values())
    top = web.most_common(40)
    conc = sum(v for k, v in top if k != "(no PTR)")
    print(f"  {tot:,} resolved website addresses")
    print(f"  {noptr:,} have no PTR at all ({100.0*noptr/tot:.1f} pct)")
    print(f"  {conc:,} sit under the 40 most common PTR parents, which are")
    print(f"     overwhelmingly hosting providers ({100.0*conc/tot:.1f} pct)")
    distinct = len(web)
    singles = sum(1 for k, v in web.items() if v == 1)
    print(f"  {distinct:,} distinct PTR parents, {singles:,} of them appearing once")

    json.dump({"self_apex_jobs": len(jobs),
               "mx_hosts_resolving": len(hosts_with["mx"]),
               "ns_hosts_resolving": len(hosts_with["ns"]),
               "mx_same_ip_as_website": same_ip["mx"],
               "ns_same_ip_as_website": same_ip["ns"],
               "mx_ptr_parents": ptrp["mx"].most_common(30),
               "ns_ptr_parents": ptrp["ns"].most_common(30),
               "website_ptr_parents": web.most_common(60)},
              open("/projects/sandbox/.kiro/landmark_research/fire_dns_pass2.json", "w"),
              indent=1)


if __name__ == "__main__":
    main()
