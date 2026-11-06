#!/usr/bin/env python3
"""Can a website be discovered from name plus place, with no search API?

Validated against ground truth rather than guessed at. The fire registry gives
8,685 institutions whose real website we already know, so generating candidate
domains and checking them against the known answer measures recall directly.

This is the test that has to pass before pointing any discovery mechanism at
NCES PSS or IMLS, where there is no ground truth to check against.
"""
import csv, re, random, collections, threading, sys
from concurrent.futures import ThreadPoolExecutor, as_completed

import dns.resolver, dns.exception

SRC = "/projects/sandbox/.kiro/landmark_research/usfa_fire_national.csv"
TLDS = ("org", "com", "net", "us")
STOP = {"fire", "department", "dept", "volunteer", "district", "protection",
        "company", "rescue", "ems", "and", "the", "of", "inc", "township",
        "city", "town", "village", "county", "area", "no", "number", "station"}

local = threading.local()


def res():
    if not hasattr(local, "r"):
        r = dns.resolver.Resolver()
        r.timeout = 3.0
        r.lifetime = 5.0
        local.r = r
    return local.r


def norm_host(u):
    u = (u or "").strip()
    if not u or " " in u:
        return ""
    m = re.match(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*://)?([^/\s:?]+)", u)
    h = (m.group(1).lower().rstrip(".") if m else "")
    return h if "." in h else ""


def reg_domain(h):
    """Last two labels, which is what the generator can plausibly produce."""
    p = h.split(".")
    return ".".join(p[-2:]) if len(p) >= 2 else h


def words(s):
    return [w for w in re.split(r"[^a-z0-9]+", (s or "").lower()) if w]


def candidates(name, city, state):
    nw = words(name)
    core = [w for w in nw if w not in STOP]
    cw = words(city)
    initials = "".join(w[0] for w in core)[:6]
    stems = set()
    joined = "".join(core)
    if joined:
        stems.add(joined)
        stems.add(joined + "fire")
        stems.add(joined + "fd")
        stems.add(joined + "vfd")
        stems.add(joined + "fire" + "dept")
    if core:
        stems.add(core[0] + "fire")
        stems.add(core[0] + "fd")
        stems.add(core[0] + "vfd")
        stems.add(core[0] + "firedept")
        stems.add(core[0] + "firedepartment")
        stems.add(core[0] + "firerescue")
    if cw:
        cj = "".join(cw)
        stems.add(cj + "fire")
        stems.add(cj + "fd")
        stems.add(cj + "vfd")
        stems.add(cj + "firedept")
        stems.add(cj + "firedepartment")
        stems.add(cj + "firerescue")
    if initials and len(initials) >= 2:
        stems.add(initials + "fd")
        stems.add(initials + "vfd")
    stems = {s for s in stems if 4 <= len(s) <= 40}
    return [f"{s}.{t}" for s in sorted(stems) for t in TLDS]


def has_a(d):
    try:
        res().resolve(d, "A")
        return d, True
    except dns.exception.DNSException:
        return d, False


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    raw = open(SRC, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    rdr = csv.reader(raw.decode("utf-8", "replace").splitlines())
    hdr = [h.strip() for h in next(rdr)]
    rows = []
    for r in rdr:
        if not r:
            continue
        d = dict(zip(hdr, r))
        h = norm_host(d.get("Website"))
        if h:
            rows.append((d.get("Fire dept name", ""), d.get("HQ city", ""),
                         d.get("HQ state", ""), h))
    random.seed(11)
    samp = random.sample(rows, min(n, len(rows)))
    print(f"{len(rows):,} departments with a known website; testing {len(samp):,}")

    gen = {}
    allc = set()
    for name, city, st, truth in samp:
        c = candidates(name, city, st)
        gen[(name, city, st, truth)] = c
        allc.update(c)
    print(f"{len(allc):,} distinct candidate domains generated, "
          f"{len(allc)/len(samp):.1f} per institution")

    live = {}
    with ThreadPoolExecutor(max_workers=64) as ex:
        futs = [ex.submit(has_a, d) for d in sorted(allc)]
        done = 0
        for f in as_completed(futs, timeout=900):
            try:
                d, ok = f.result(timeout=1)
                live[d] = ok
            except Exception:
                pass
            done += 1
            if done % 2000 == 0:
                print(f"  checked {done:,}/{len(allc):,}", flush=True)

    hit = exact = 0
    multi = collections.Counter()
    misses = []
    for (name, city, st, truth), c in gen.items():
        truth_reg = reg_domain(truth)
        up = [d for d in c if live.get(d)]
        multi[len(up)] += 1
        if truth_reg in up:
            hit += 1
            if len(up) == 1:
                exact += 1
        else:
            misses.append((name, city, st, truth, len(up)))

    t = len(gen)
    print()
    print("=" * 66)
    print(f"{'institutions tested':<44}{t:>8,}")
    print(f"{'true domain appeared among live candidates':<44}{hit:>8,}  "
          f"({100.0*hit/t:.1f}%)")
    print(f"{'  and was the ONLY live candidate':<44}{exact:>8,}  "
          f"({100.0*exact/t:.1f}%)")
    print("=" * 66)
    print("\nlive candidates per institution (ambiguity):")
    for k in sorted(multi):
        print(f"  {k:>3} live: {multi[k]:>5}")
    print("\nfirst 10 misses, with how many false candidates were live:")
    for m in misses[:10]:
        print(f"  {m[3]:<38} {m[0][:34]:<36} live={m[4]}")


if __name__ == "__main__":
    main()
