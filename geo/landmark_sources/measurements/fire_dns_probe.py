#!/usr/bin/env python3
"""DNS-only pre-measurement of the USFA fire corpus.

Answers two questions without needing Postgres, RDAP or provider_names:

  1. Where does each department's WEBSITE actually point? Grouped by the
     reverse-DNS parent of the address, which names the hosting provider
     without us having to guess a provider list up front.
  2. Does the same organisation publish MX or NS that are NOT under the same
     provider? That is the upper bound on what mx_ns_yield.py could recover.

Writes a JSON summary plus a CSV of per-host detail.
"""
import csv, json, re, sys, collections, socket, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed

import dns.resolver
import dns.exception
import dns.reversename

SRC = "/projects/sandbox/.kiro/landmark_research/usfa_fire_national.csv"
OUT_CSV = "/projects/sandbox/.kiro/landmark_research/fire_dns_detail.csv"
OUT_JSON = "/projects/sandbox/.kiro/landmark_research/fire_dns_summary.json"

ZIP5 = re.compile(r"\b(\d{5})(?:-\d{4})?\b")


def norm_host(u):
    u = (u or "").strip()
    if not u or " " in u:
        return ""
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", u):
        u = "http://" + u
    m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s:?]+)", u)
    h = (m.group(1).lower().rstrip(".") if m else "")
    return h if "." in h else ""


def load():
    raw = open(SRC, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("latin-1")
    rdr = csv.reader(text.splitlines())
    hdr = [h.strip() for h in next(rdr)]
    seen = {}
    for row in rdr:
        if not row:
            continue
        d = dict(zip(hdr, row))
        h = norm_host(d.get("Website"))
        z = ZIP5.search(d.get("HQ zip") or "")
        if h and z and h not in seen:
            seen[h] = (z.group(1), (d.get("HQ state") or "").strip())
    return seen


local = threading.local()


def res():
    if not hasattr(local, "r"):
        r = dns.resolver.Resolver()
        r.timeout = 5.0
        r.lifetime = 8.0
        local.r = r
    return local.r


def parent2(name):
    """Last two labels. Crude on purpose: only used to GROUP and then report."""
    parts = (name or "").rstrip(".").lower().split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else (name or "")


def probe(item):
    host, (zp, st) = item
    out = {"host": host, "zip": zp, "state": st, "a": "", "ptr_parent": "",
           "apex": "", "ns": "", "ns_parents": "", "mx": "", "mx_parents": "",
           "err": ""}
    r = res()
    try:
        out["a"] = sorted({x.address for x in r.resolve(host, "A")})[0]
    except dns.exception.DNSException as e:
        out["err"] = type(e).__name__
    if out["a"]:
        try:
            rev = dns.reversename.from_address(out["a"])
            ptr = str(r.resolve(rev, "PTR")[0]).rstrip(".")
            out["ptr_parent"] = parent2(ptr)
        except dns.exception.DNSException:
            out["ptr_parent"] = "(no PTR)"
    try:
        out["apex"] = str(dns.resolver.zone_for_name(host, resolver=r)).rstrip(".")
    except dns.exception.DNSException:
        return out
    for kind in ("NS", "MX"):
        try:
            ans = r.resolve(out["apex"], kind)
            names = sorted({(str(x.target) if kind == "NS" else str(x.exchange)).rstrip(".").lower()
                            for x in ans})
        except dns.exception.DNSException:
            names = []
        out[kind.lower()] = ";".join(names[:4])
        out[kind.lower() + "_parents"] = ";".join(sorted({parent2(n) for n in names}))
    return out


def main():
    hosts = load()
    print(f"{len(hosts):,} distinct fire-department website hosts", flush=True)
    rows = []
    done = 0
    t0 = time.time()
    ex = ThreadPoolExecutor(max_workers=48)
    futs = [ex.submit(probe, it) for it in hosts.items()]
    try:
        for f in as_completed(futs, timeout=240):
            try:
                rows.append(f.result(timeout=1))
            except Exception as e:
                print(f"  worker failed: {type(e).__name__}", flush=True)
            done += 1
            if done % 1000 == 0:
                el = time.time() - t0
                print(f"  {done:,}/{len(hosts):,} in {int(el)}s", flush=True)
    except Exception as e:
        print(f"  stopped waiting ({type(e).__name__}); "
              f"reporting on the {len(rows):,} that finished", flush=True)
    ex.shutdown(wait=False, cancel_futures=True)
    with open(OUT_CSV, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    live = [r for r in rows if r["a"]]
    apexed = [r for r in rows if r["apex"]]
    ptr = collections.Counter(r["ptr_parent"] for r in live if r["ptr_parent"])
    nsp = collections.Counter()
    mxp = collections.Counter()
    for r in apexed:
        for p in (r["ns_parents"] or "").split(";"):
            if p:
                nsp[p] += 1
        for p in (r["mx_parents"] or "").split(";"):
            if p:
                mxp[p] += 1

    # Self-hosted DNS or mail: the record's parent equals the org's own apex.
    self_ns = sum(1 for r in apexed
                  if r["ns_parents"] and parent2(r["apex"]) in r["ns_parents"].split(";"))
    self_mx = sum(1 for r in apexed
                  if r["mx_parents"] and parent2(r["apex"]) in r["mx_parents"].split(";"))
    no_mx = sum(1 for r in apexed if not r["mx"])

    summary = {
        "hosts": len(rows),
        "website_resolved": len(live),
        "apex_resolved": len(apexed),
        "no_mx_published": no_mx,
        "ns_under_own_apex": self_ns,
        "mx_under_own_apex": self_mx,
        "top_website_ptr_parents": ptr.most_common(25),
        "top_ns_parents": nsp.most_common(25),
        "top_mx_parents": mxp.most_common(25),
    }
    json.dump(summary, open(OUT_JSON, "w"), indent=1)
    print(json.dumps({k: v for k, v in summary.items() if not k.startswith("top")}, indent=1))
    print("\nTOP WEBSITE PTR PARENTS (who hosts the website)")
    for k, v in ptr.most_common(20):
        print(f"  {v:>5}  {k}")
    print("\nTOP NS PARENTS (who runs the DNS)")
    for k, v in nsp.most_common(20):
        print(f"  {v:>5}  {k}")
    print("\nTOP MX PARENTS (who runs the mail)")
    for k, v in mxp.most_common(20):
        print(f"  {v:>5}  {k}")


if __name__ == "__main__":
    main()
