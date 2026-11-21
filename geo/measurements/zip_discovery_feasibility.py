#!/usr/bin/env python3
"""Measure where a missing landmark ZIP can actually be obtained.

WHY THIS EXISTS

Boris asked for landmark ZIPs from Google Search. Before building that, one
fact decides the shape of the problem, and it is verified rather than assumed:

  THE CISA .gov REGISTRY CARRIES NO STREET ADDRESS. Its columns are Domain
  name, Domain type, Agency, Organization name, City, State, Security contact
  email. lm_fetch.py cmd_dotgov records this and passes an empty address.

So address-to-ZIP geocoding is unavailable: there is no address to geocode.
Any path has to DISCOVER the address first. Google Search is one way. The
organisation's own website is another, and it is strictly better on three
counts that have nothing to do with policy:

  it is authoritative, being the entity's own published contact information
  it is not rate-limited or CAPTCHA-gated by a third party
  the URL is already in landmarks_usa for all 14,149 rows, so nothing has to
  be searched for in the first place

This script measures the second path so the choice is made on a number. It
does NOT scrape Google: comparing a measured yield against an unmeasured one
would be useless, and the measured one may simply be good enough.

WHAT IT MEASURES

For a random sample of local-government domains taken from the live CISA
registry, it fetches the home page and a few likely contact paths and looks
for a United States postal address. It reports:

  how many sites answered at all
  how many exposed a ZIP in a credible address context
  how many exposed a ZIP anywhere on the page
  which path yielded it, so a full build knows which to try first

WHAT IT DOES NOT MEASURE, and must not be read as measuring

Whether the ZIP found is the RIGHT one. A page footer can carry a mailing
address, a PO box, or a web vendor's own address. Verifying correctness needs
a second source, and the obvious one is the state-and-city agreement test
already built in locality_zip_recovery.sql: a discovered ZIP that is a known
ZIP of the entity's own city is corroborated, one that is not is suspect.
That check is NOT applied here because this database is not available to this
script.

CONSERVATIVE BY DESIGN. One request per host, 8-second timeout, 12 threads,
a declared User-Agent, and no retry storm. This reads public pages at the
volume a person browsing would generate.

USAGE

  python3 zip_discovery_feasibility.py
  python3 zip_discovery_feasibility.py -sample 60 -types City,County
"""

import argparse
import concurrent.futures
import csv
import io
import random
import re
import sys
import urllib.error
import urllib.request
from collections import Counter

REGISTRY = ("https://raw.githubusercontent.com/cisagov/dotgov-data/"
            "main/current-full.csv")

UA = "trugeo-zip-feasibility/1.0 (research; contact via repository)"

# Paths tried in order. Home page first because it is the one certain to
# exist; the contact paths are where a footer address is most often repeated
# in a fuller form.
PATHS = ["/", "/contact", "/contact-us", "/about"]

# A ZIP in a CREDIBLE ADDRESS CONTEXT: a two-letter state code immediately
# before it, optionally with a comma. This is the same shape as
# ZIP_AFTER_STATE_RE in ovt_resolve_hosts.py, deliberately, so a ZIP found
# here is found the same way the chain finds one in Overture address text.
ZIP_IN_CONTEXT = re.compile(r"\b([A-Z]{2})[,.]?\s+(\d{5})(?:-\d{4})?\b")

# Any five digits that could be a ZIP. Much weaker: matches years, phone
# fragments, parcel numbers. Reported separately and never conflated.
ZIP_LOOSE = re.compile(r"\b(\d{5})(?:-\d{4})?\b")

STREET_HINT = re.compile(
    r"\b\d{1,6}\s+[A-Za-z0-9.'\- ]{2,40}\s"
    r"(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Lane|Ln|Way|"
    r"Court|Ct|Place|Pl|Highway|Hwy|Square|Sq|Parkway|Pkwy|Terrace|Trail)\b",
    re.IGNORECASE)

TAG = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
ANYTAG = re.compile(r"<[^>]+>")


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        ctype = (r.headers.get("Content-Type") or "").lower()
        if "html" not in ctype and "text" not in ctype:
            return None
        raw = r.read(600_000)
    for enc in ("utf-8", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return None


def visible_text(html):
    html = TAG.sub(" ", html)
    html = ANYTAG.sub(" ", html)
    html = (html.replace("&nbsp;", " ").replace("&amp;", "&")
                .replace("&#39;", "'").replace("&quot;", '"'))
    return re.sub(r"\s+", " ", html)


def probe(entry, timeout):
    """Try each path for one domain. Returns a result dict."""
    domain, org, city, state, dtype = entry
    out = {"domain": domain, "org": org, "city": city, "state": state,
           "type": dtype, "answered": False, "path": "", "zip_in_context": "",
           "zip_state": "", "has_street": False, "loose_count": 0,
           "error": ""}
    for path in PATHS:
        for scheme in ("https://", "http://"):
            url = scheme + domain + path
            try:
                html = fetch(url, timeout)
            # Record an error ONLY while nothing has answered yet. The first
            # version recorded the last error from any path, so a site whose
            # home page answered fine but whose /contact returned 404 was
            # reported under 'HTTP 404'. In the 2026-11-12 run that made 5 of
            # the 7 answered-but-no-ZIP sites look like transport failures,
            # which understated how often a site answers and simply publishes
            # no address.
            except urllib.error.HTTPError as exc:
                if not out["answered"]:
                    out["error"] = f"HTTP {exc.code}"
                continue
            except Exception as exc:                  # noqa: BLE001
                if not out["answered"]:
                    out["error"] = type(exc).__name__
                continue
            if not html:
                if not out["answered"]:
                    out["error"] = "not html"
                continue
            out["answered"] = True
            out["error"] = ""
            text = visible_text(html)
            out["loose_count"] = len(set(ZIP_LOOSE.findall(text)))
            out["has_street"] = bool(STREET_HINT.search(text))
            m = ZIP_IN_CONTEXT.search(text)
            if m:
                out["zip_state"] = m.group(1)
                out["zip_in_context"] = m.group(2)
                out["path"] = path
                return out
            out["path"] = path
            break
        if out["answered"] and out["zip_in_context"]:
            return out
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Measure whether a landmark ZIP can be read off the "
                    "organisation's own website.")
    ap.add_argument("-sample", type=int, default=40)
    ap.add_argument("-types", default="City,County,Township,Village",
                    help="comma-separated CISA Domain type values")
    ap.add_argument("-timeout", type=int, default=8)
    ap.add_argument("-threads", type=int, default=12)
    ap.add_argument("-seed", type=int, default=42,
                    help="fixed so a rerun samples the same domains")
    args = ap.parse_args()

    print(f"Fetching {REGISTRY} ...", flush=True)
    try:
        raw = fetch(REGISTRY, 60)
    except Exception as exc:                          # noqa: BLE001
        sys.exit(f"could not fetch the registry: {exc}")
    if not raw:
        sys.exit("registry fetch returned nothing usable")

    wanted = {t.strip().lower() for t in args.types.split(",") if t.strip()}
    rows = []
    for d in csv.DictReader(io.StringIO(raw)):
        dtype = (d.get("Domain type") or "").strip()
        if dtype.lower() not in wanted:
            continue
        domain = (d.get("Domain name") or "").strip().lower()
        if not domain:
            continue
        rows.append((domain, (d.get("Organization name") or "").strip(),
                     (d.get("City") or "").strip(),
                     (d.get("State") or "").strip(), dtype))

    print(f"{len(rows):,} domains of type {sorted(wanted)} in the registry")
    print("CONFIRMED from the header: the registry has no street-address "
          "column. Columns are:")
    print("  " + ", ".join(csv.DictReader(io.StringIO(raw)).fieldnames or []))
    print("")

    random.seed(args.seed)
    sample = random.sample(rows, min(args.sample, len(rows)))
    print(f"Probing {len(sample)} of them, {len(PATHS)} paths each at most, "
          f"{args.timeout}s timeout, {args.threads} threads ...", flush=True)

    results = []
    with concurrent.futures.ThreadPoolExecutor(args.threads) as ex:
        futs = {ex.submit(probe, e, args.timeout): e for e in sample}
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            results.append(fut.result())
            done += 1
            if done % 10 == 0:
                print(f"  {done}/{len(sample)}", flush=True)

    answered = [r for r in results if r["answered"]]
    withzip = [r for r in answered if r["zip_in_context"]]
    withstreet = [r for r in answered if r["has_street"]]
    state_ok = [r for r in withzip
                if r["zip_state"].upper() == r["state"].upper()]

    print("")
    print("=" * 70)
    print("CAN A LANDMARK ZIP BE READ OFF THE ENTITY'S OWN WEBSITE")
    print("=" * 70)
    print(f"  domains probed                         {len(results):>6}")
    print(f"  site answered                          {len(answered):>6}")
    print(f"  ZIP found after a state code           {len(withzip):>6}")
    print(f"  of those, state code MATCHES CISA      {len(state_ok):>6}")
    print(f"  street-address pattern present         {len(withstreet):>6}")
    if answered:
        print(f"  ZIP yield over sites that answered     "
              f"{100.0 * len(withzip) / len(answered):>5.1f}%")
    if results:
        print(f"  ZIP yield over ALL domains probed      "
              f"{100.0 * len(withzip) / len(results):>5.1f}%")
    print("")
    print("  The state-code match is the cheap corroboration. A ZIP preceded")
    print("  by a state that disagrees with the registry is probably a web")
    print("  vendor's own address in a page footer, not the entity's.")
    print("")

    print("  which path produced the answer:")
    for p, n in Counter(r["path"] for r in withzip).most_common():
        print(f"    {p or '(none)':<14}{n:>5}")
    print("")
    print("  why the others failed:")
    for e, n in Counter(r["error"] or "answered, no ZIP in context"
                        for r in results if not r["zip_in_context"]).most_common(8):
        print(f"    {e:<30}{n:>5}")
    print("")

    print("  sample of what was found:")
    print(f"    {'domain':<30}{'city':<18}{'st':<4}{'zip':<8}{'zst':<4}street")
    for r in sorted(withzip, key=lambda x: x["domain"])[:25]:
        print(f"    {r['domain'][:29]:<30}{r['city'][:17]:<18}"
              f"{r['state']:<4}{r['zip_in_context']:<8}{r['zip_state']:<4}"
              f"{'yes' if r['has_street'] else 'no'}")
    print("")
    print("  NOT MEASURED HERE: whether each ZIP is the CORRECT one. That")
    print("  needs the city-agreement test from locality_zip_recovery.sql,")
    print("  which requires the database this script does not have.")


if __name__ == "__main__":
    main()
