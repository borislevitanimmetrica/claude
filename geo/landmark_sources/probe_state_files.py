#!/usr/bin/env python3
"""Probe a candidate state school-directory file and report whether it is usable.

WHY THIS EXISTS
---------------
California worked: the CDE export carries school name, street, city, ZIP and
website in one tab-delimited file, and it produced 8,816 usable schools, 280
candidate ZIPs and 94 ZIPs we did not already cover. Doing the other 49 states
needs the same question answered 49 times: does this state publish school, ZIP
and website together in one downloadable file, and under what column names?

Answering that by reading documentation does not work. The columns are named
differently everywhere, several states serve a captcha to anything that is not a
browser, and a captcha arrives as HTTP 200 with text/html so a naive fetch looks
like a success and yields nothing. California demonstrated both problems.

So this reads the actual bytes and reports what is there. It writes nothing to
any database and makes no claim it has not checked.

WHAT IT REPORTS, PER FILE
-------------------------
  the HTTP status, size and content type, or that the body is a captcha page
  the delimiter it detected and the number of data rows
  which columns look like a school name, street, city, ZIP, website and status
  how many rows actually carry both a ZIP and a website, which is the only
  number that decides whether the state is worth loading

A FILE THAT CANNOT BE FETCHED HERE IS NOT A DEAD END. Several state sites
answer a datacenter address with a captcha and a residential address with the
data, so --input accepts a file downloaded by hand. That is how California was
resolved after one successful fetch and then persistent captchas.

USAGE
  probe_state_files.py --url <url> --state CA
  probe_state_files.py --input /home/boris/geo/pubschls.txt --state CA
  probe_state_files.py --config states.json
"""

import argparse
import csv
import io
import json
import re
import sys
import urllib.error
import urllib.request

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/140.0 Safari/537.36")

# Header-name patterns, most specific first. These are matched against the
# lower-cased header, so 'SchoolWebsite' and 'WEB_ADDRESS' both land on website.
ROLE_PATTERNS = [
    ("zip",     [r"^zip", r"zip ?code", r"postal", r"^phys.*zip", r"^mail.*zip"]),
    ("website", [r"web ?site", r"^web$", r"^url$", r"web ?address", r"homepage",
                 r"^site$", r"school ?url"]),
    ("name",    [r"^school ?name$", r"^school$", r"^institution", r"^site ?name",
                 r"^facility", r"^name$"]),
    ("city",    [r"^city", r"^phys.*city", r"^town", r"locality"]),
    ("street",  [r"^street", r"^address", r"^addr", r"^phys.*address", r"^location ?address"]),
    ("status",  [r"^status", r"^active", r"open ?closed", r"^oper"]),
    ("district",[r"^district", r"^lea", r"^agency"]),
    ("ncesid",  [r"nces"]),
]

CAPTCHA_HINTS = ("captcha", "are you a human", "incapsula", "radware",
                 "cloudflare", "access denied", "bot detection")


def classify_headers(headers):
    """-> {role: header} using the first header that matches each role's patterns."""
    found = {}
    for role, pats in ROLE_PATTERNS:
        for h in headers:
            hl = (h or "").strip().lower()
            if not hl:
                continue
            if any(re.search(p, hl) for p in pats):
                found.setdefault(role, h)
                break
    return found


def sniff_delimiter(sample):
    """Pick the delimiter by counting candidates in the header line.

    csv.Sniffer guesses from a sample and gets confused by addresses containing
    commas inside an unquoted tab-delimited file, which is exactly the shape of
    the California export. Counting the header line is blunter and right more
    often for these files.
    """
    first = sample.splitlines()[0] if sample.splitlines() else ""
    counts = {d: first.count(d) for d in ["\t", ",", "|", ";"]}
    best = max(counts, key=counts.get)
    return best if counts[best] > 0 else ","


def looks_like_url(value):
    v = (value or "").strip().strip('"').lower()
    if not v or v in ("no data", "n/a", "none", "null", "-"):
        return False
    v = v.split("://")[-1].split("/")[0]
    return "." in v and " " not in v and not v.endswith(".")


def looks_like_zip(value):
    return bool(re.search(r"\b\d{5}\b", (value or "")))


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/plain,text/csv,application/octet-stream,text/html;q=0.8,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


def probe(state, raw, ctype, source):
    print(f"\n{'=' * 72}")
    print(f"{state}  from {source}")
    print(f"{'=' * 72}")
    print(f"  bytes          {len(raw):,}")
    print(f"  content-type   {ctype or '(none)'}")

    head = raw[:6000].decode("utf-8", errors="replace")
    low = head.lower()
    if "<html" in low or "<!doctype" in low:
        hint = next((h for h in CAPTCHA_HINTS if h in low), None)
        print(f"  VERDICT        HTML, not data"
              f"{' -- looks like a ' + hint + ' page' if hint else ''}")
        print(f"  Download it in a browser and re-run with --input.")
        return None

    text = raw.decode("utf-8-sig", errors="replace")
    delim = sniff_delimiter(text[:6000])
    # QUOTE_NONE because these files are frequently unquoted yet contain bare
    # double quotes in school names. With the default dialect, csv treats those
    # as quoting and swallows newlines; on the California file that turned 8.8MB
    # into 73 rows with no error.
    rows = list(csv.DictReader(io.StringIO(text), delimiter=delim,
                               quoting=csv.QUOTE_NONE))
    headers = rows[0].keys() if rows else []
    dname = {"\t": "tab", ",": "comma", "|": "pipe", ";": "semicolon"}[delim]
    print(f"  delimiter      {dname}")
    print(f"  columns        {len(list(headers))}")
    print(f"  data rows      {len(rows):,}")
    if not rows:
        print("  VERDICT        no data rows parsed")
        return None

    roles = classify_headers(list(headers))
    print("  column roles detected:")
    for role, _ in ROLE_PATTERNS:
        print(f"    {role:<10}{roles.get(role, '(none)')}")

    have_zip = roles.get("zip")
    have_web = roles.get("website")
    if not have_zip or not have_web:
        missing = [r for r in ("zip", "website") if not roles.get(r)]
        print(f"  VERDICT        UNUSABLE, no {' and no '.join(missing)} column")
        print(f"  headers: {', '.join(list(headers)[:24])}")
        return None

    # The decisive count. Everything above is structure; this is yield.
    both = sum(1 for r in rows
               if looks_like_url(r.get(have_web)) and looks_like_zip(r.get(have_zip)))
    zips = {re.search(r"\b(\d{5})\b", r.get(have_zip) or "").group(1)
            for r in rows if looks_like_zip(r.get(have_zip))}
    hosts = set()
    for r in rows:
        v = (r.get(have_web) or "").strip().strip('"').lower()
        if looks_like_url(v):
            hosts.add(v.split("://")[-1].split("/")[0].split(":")[0])
    print(f"  rows with ZIP and website   {both:>8,}")
    print(f"  distinct 5-digit ZIPs       {len(zips):>8,}")
    print(f"  distinct website hosts      {len(hosts):>8,}")
    print(f"  VERDICT        USABLE")
    return {"state": state, "rows": len(rows), "usable": both,
            "zips": len(zips), "hosts": len(hosts),
            "delimiter": dname, "roles": roles}


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", help="candidate download URL")
    p.add_argument("--input", help="local copy, for sites that serve a captcha to servers")
    p.add_argument("--state", default="??", help="two-letter state code, for the report")
    p.add_argument("--config", help="JSON list of objects with state and url or input")
    p.add_argument("--timeout", type=int, default=90)
    args = p.parse_args()

    jobs = []
    if args.config:
        with open(args.config, encoding="utf-8") as fh:
            jobs = json.load(fh)
    elif args.url or args.input:
        jobs = [{"state": args.state, "url": args.url, "input": args.input}]
    else:
        p.error("give --url, --input or --config")

    results = []
    for j in jobs:
        state = j.get("state", "??")
        try:
            if j.get("input"):
                with open(j["input"], "rb") as fh:
                    raw = fh.read()
                r = probe(state, raw, "(local file)", j["input"])
            else:
                status, ctype, raw = fetch(j["url"], args.timeout)
                r = probe(state, raw, ctype, j["url"])
        except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
            print(f"\n{state}: fetch failed: {exc}")
            r = None
        if r:
            results.append(r)

    if len(jobs) > 1:
        print(f"\n{'=' * 72}")
        print("SUMMARY, usable states only")
        print(f"{'=' * 72}")
        print(f"{'state':<8}{'rows':>10}{'zip+web':>10}{'zips':>8}{'hosts':>8}")
        for r in sorted(results, key=lambda x: -x["usable"]):
            print(f"{r['state']:<8}{r['rows']:>10,}{r['usable']:>10,}"
                  f"{r['zips']:>8,}{r['hosts']:>8,}")
        print(f"\n{len(results)} of {len(jobs)} candidates usable.")


if __name__ == "__main__":
    main()
