#!/usr/bin/env python3
"""Test Boris's two criticisms of CISA, and find what the Wikidata loader misses.

BORIS, 2026-11-12: "CISA is very outdated, so many domain names are no longer
used, and often uses officials' home addresses rather than town/village/township
halls (although probably not large cities). I would not rely on CISA and use
Wikipedia and Google Search instead."

Both halves are testable. The second is testable for free, because the CISA
registry carries both an Organization name and a City, and for a township those
two should name the same place. Where they do not, the City is something else:
the nearest post office, the county seat, or whoever registered the domain.

MY OWN EARLIER OUTPUT ALREADY SHOWED THIS and I did not notice. From the
40-domain probe on 2026-11-12:

  claytwpmi.gov            Organization Clay Township        City Algonac
  leontwpgoodhuecomn.gov   Leon Township, Goodhue County     City Cannon Falls
  leroytownship-mi.gov     Leroy Township                    City Webberville
  margaretal.gov           Margaret                          City Odenville
  poquoson-va.gov          Poquoson                          City Poquioson

The last one is a plain typo in the registry. The others are a different place
from the entity. I printed all five and drew no conclusion from them.

WHAT THIS SCRIPT ALSO FOUND, which matters more than the criticism

Wikidata holds US municipalities with an official website AND a postal code,
and the existing loader CANNOT SEE THEM. lm_fetch.py cmd_wikidata requires

    ?item wdt:P17 wd:Q30 ; wdt:P6375 ?addr ; wdt:P856 ?site .

P6375 is the street address. A city does not have a street address, it has a
postal code, so requiring P6375 excludes municipalities structurally rather
than incidentally.

MEASURED 2026-11-12 via QLever, US items with an official website:

  class                          website   P281 zip   P6375 street
  city in the United States        5,767      5,254              8
  town in the United States        2,255      1,833              1
  county seat                      1,595      1,584              1
  high school                     10,665      7,059            719
  public educational institution   1,611      1,587          1,582
  private nonprofit educational    1,418      1,382          1,383
  public school                    2,219      1,532            193
  school                           2,959      1,616            685
  university                       1,531        914            916
  historical society               1,680        977            800

Read the city row: 5,254 of 5,767 carry P281 and EIGHT carry P6375. The loader
asks for the one property these entities do not have.

WHY WDQS IS NOT USED HERE. query.wikidata.org answered HTTP 429 with
"Aggressively rate-limiting to 1 req / min - this rule was created during
active wdqs outage". lm_fetch.py already carries a QLever endpoint as an
alternative, which is why this script could run at all.

USAGE

  python3 wikidata_vs_cisa.py                 both measurements
  python3 wikidata_vs_cisa.py -skip-wikidata  CISA only, no network beyond it
"""

import argparse
import csv
import io
import json
import re
import sys
import urllib.parse
import urllib.request
from collections import Counter

REGISTRY = ("https://raw.githubusercontent.com/cisagov/dotgov-data/"
            "main/current-full.csv")
QLEVER = "https://qlever.dev/api/wikidata"
UA = "trugeo-research/1.0 (landmark ZIP feasibility)"

PRE = """PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
"""

LEAD = re.compile(r"^(?:the\s+)?(?:city|town|village|township|county|borough|"
                  r"charter township|municipality)\s+of\s+", re.IGNORECASE)
TRAIL_TYPE = re.compile(r"\s+(?:charter\s+)?(?:township|village|city|town|county|"
                        r"borough|twp\.?)$", re.IGNORECASE)
TRAIL_STATE = re.compile(r"[,\s]+(?:[A-Z]{2}|[A-Z][a-z]+)\s*(?:,\s*USA?)?$")
COUNTY_CLAUSE = re.compile(r",?\s+[A-Za-z .'\-]+\s+county\b.*$", re.IGNORECASE)


def http(url, timeout=90, data=None, ctype=None):
    headers = {"User-Agent": UA}
    if ctype:
        headers["Content-Type"] = ctype
        headers["Accept"] = "application/sparql-results+json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def normalise_place(name):
    s = (name or "").strip()
    s = COUNTY_CLAUSE.sub("", s)
    s = LEAD.sub("", s)
    s = TRAIL_STATE.sub("", s)
    s = TRAIL_TYPE.sub("", s)
    return re.sub(r"[^a-z0-9]", "", s.lower())


def cisa_measurement(args):
    print("=" * 72)
    print("1. DOES THE CISA City FIELD NAME THE SAME PLACE AS THE ENTITY?")
    print("=" * 72)
    try:
        raw = http(REGISTRY, 90)
    except Exception as exc:                          # noqa: BLE001
        print(f"  could not fetch the registry: {exc}")
        return
    rdr = csv.DictReader(io.StringIO(raw))
    by_type = {}
    examples = []
    for d in rdr:
        dtype = (d.get("Domain type") or "").strip()
        if dtype.lower() not in ("city", "county", "township", "village"):
            continue
        org = (d.get("Organization name") or "").strip()
        city = (d.get("City") or "").strip()
        if not org or not city:
            continue
        a, b = normalise_place(org), normalise_place(city)
        agree = bool(a) and bool(b) and (a == b or a in b or b in a)
        st = by_type.setdefault(dtype, {"n": 0, "agree": 0})
        st["n"] += 1
        st["agree"] += 1 if agree else 0
        if not agree and len(examples) < 18:
            examples.append((d.get("Domain name", "").strip(), org, city,
                             (d.get("State") or "").strip()))

    print("")
    print(f"  {'domain type':<14}{'rows':>8}{'city names the entity':>24}{'pct':>8}")
    tot = tota = 0
    for t, st in sorted(by_type.items(), key=lambda kv: -kv[1]["n"]):
        tot += st["n"]
        tota += st["agree"]
        pct = 100.0 * st["agree"] / st["n"] if st["n"] else 0.0
        print(f"  {t:<14}{st['n']:>8,}{st['agree']:>24,}{pct:>7.1f}%")
    if tot:
        print(f"  {'ALL':<14}{tot:>8,}{tota:>24,}"
              f"{100.0 * tota / tot:>7.1f}%")
    print("")
    print("  A disagreement is NOT proof of a home address. It proves the City")
    print("  field names somewhere other than the entity, which could be the")
    print("  nearest post office, the county seat, or a registrant's own town.")
    print("  Distinguishing those needs a second source, which is the point.")
    print("")
    print("  examples where they disagree:")
    print(f"    {'domain':<30}{'organization':<30}{'city':<18}st")
    for dom, org, city, state in examples:
        print(f"    {dom[:29]:<30}{org[:29]:<30}{city[:17]:<18}{state}")
    print("")


def wikidata_measurement(args):
    print("=" * 72)
    print("2. WHAT THE EXISTING WIKIDATA LOADER CANNOT SEE")
    print("=" * 72)
    print("")
    print("  cmd_wikidata requires P6375, the street address. Counting US")
    print("  municipalities that have an official website and a POSTAL CODE")
    print("  instead, which is the property a municipality actually carries.")
    print("")
    q = PRE + """
SELECT (COUNT(DISTINCT ?i) AS ?municipalities_with_site)
       (COUNT(DISTINCT ?iz) AS ?also_postal_code)
       (COUNT(DISTINCT ?ia) AS ?also_street_address)
WHERE {
  VALUES ?cls { wd:Q1093829 wd:Q2616791 wd:Q1115575 wd:Q3957 wd:Q532 }
  ?i wdt:P31 ?cls .
  ?i wdt:P17 wd:Q30 .
  ?i wdt:P856 ?site .
  OPTIONAL { ?i wdt:P281 ?z . BIND(?i AS ?iz) }
  OPTIONAL { ?i wdt:P6375 ?a . BIND(?i AS ?ia) }
}
"""
    try:
        body = http(QLEVER, 240, urllib.parse.urlencode({"query": q}).encode(),
                    "application/x-www-form-urlencoded")
        rows = json.loads(body)["results"]["bindings"]
    except Exception as exc:                          # noqa: BLE001
        print(f"  QLever query failed: {type(exc).__name__} {exc}")
        print("  Q-ids used: Q1093829 city in the US, Q2616791 village in the")
        print("  US, Q1115575 civil township, Q3957 town, Q532 village.")
        print("  If this failed, the class list is the thing to check first.")
        return
    for b in rows:
        for k, v in b.items():
            print(f"    {k:<28}{int(v['value']):>9,}")
    print("")
    print("  Compare against CISA, which holds 8,093 city, county, township")
    print("  and village domains and NO postal code column at all.")
    print("")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-skip-wikidata", action="store_true")
    ap.add_argument("-skip-cisa", action="store_true")
    args = ap.parse_args()
    if not getattr(args, "skip_cisa"):
        cisa_measurement(args)
    if not getattr(args, "skip_wikidata"):
        wikidata_measurement(args)


if __name__ == "__main__":
    main()
