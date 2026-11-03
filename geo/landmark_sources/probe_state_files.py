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

# Header-name patterns, most specific first. They are matched against the
# NORMALISED header: lower-cased, with underscores, hyphens and dots turned into
# single spaces.

# WHY THE HEADER IS NORMALISED BEFORE MATCHING.
#
# A comment here used to claim that 'SchoolWebsite' and 'WEB_ADDRESS' both land
# on website. Florida disproves the second half. Its Master School ID export
# names every column with underscores -- WEB_ADDRESS, PHYSICAL_ZIP,
# PHYSICAL_CITY, SCHOOL_NAME_LONG -- and in a regular expression the underscore
# is a WORD character, so there is no \b boundary between 'web' and 'address'.
# Measured on the real 2,902,438-byte file: r"\bweb\b" missed WEB_ADDRESS,
# r"\bzips?\b" missed PHYSICAL_ZIP, r"\bcity\b" missed PHYSICAL_CITY, and the
# probe returned 'UNUSABLE, no zip and no website column' for a file that in
# fact carries 4,427 schools with both.
#
# That made the word-boundary patterns a REGRESSION for underscore-delimited
# files: the previous anchored version at least found PHYSICAL_ZIP through
# r"^phys.*zip". Rather than add a separator alternative to every pattern, the
# separator is removed from the header once, in one place, so that
# 'WEB_ADDRESS', 'Web Address', 'web-address' and 'web.address' are all the
# string 'web address' by the time any pattern sees them.

# WHY THESE ARE SUBSTRING PATTERNS AND WHY EVERY MATCH IS REPORTED.
#
# The first version anchored most patterns at the start of the header, which
# worked on California, whose columns are bare: Zip, WebSite, School, City.
# Texas publishes the same information as "School Zip", "School Web Page
# Address", "District Zip" and "District Web Page Address", none of which match
# an anchored pattern. The probe would have declared the larger and better of
# the two files unusable.
#
# Two consequences. The patterns match anywhere in the header, not just at the
# start. And every matching column is reported rather than only the first,
# because Texas carries BOTH a district level and a school level in one row:
# silently taking whichever appeared first would have read the district's ZIP
# against the school's website. A file with two candidates per role is a
# structural fact the loader config has to record, so the probe has to show it.
ROLE_PATTERNS = [
    ("zip",     [r"\bzips?\b", r"zip ?code", r"\bpostal", r"\bpostcode"]),
    ("website", [r"web ?site", r"\bweb\b", r"web ?page", r"\burl\b", r"homepage",
                 r"web ?address"]),
    ("name",    [r"school ?name", r"\bschool\b", r"institution", r"site ?name",
                 r"facility ?name", r"^name$"]),
    ("city",    [r"\bcity\b", r"\btown\b", r"locality"]),
    ("street",  [r"physical ?address", r"street ?address", r"\bstreet\b",
                 r"^address", r"\baddr\b", r"location ?address",
                 r"mailing ?address"]),
    ("status",  [r"school ?status", r"district ?status", r"\bstatus ?type",
                 r"activity ?code", r"\bstatus", r"open ?closed",
                 r"\boperational", r"\bactive\b"]),
    ("district",[r"district ?name", r"\bdistrict\b", r"\blea\b", r"\bagency\b"]),
    ("ncesid",  [r"\bnces", r"federal ?(dist|schl|school)"]),
]
# PATTERNS ARE TRIED IN ORDER AND THE FIRST PRODUCTIVE ONE WINS.
#
# Collecting every column that matched any pattern for a role treats a precise
# match and a loose one as equals. On the Texas file at district level that
# chose "Magnet Status" as the status column, because it matched the same loose
# r"\bstatus" as "School Status" did and happened to come first in the file.
#
# Trying patterns in specificity order instead means "School Status" is found by
# an earlier pattern and "Magnet Status" is never considered.
#
# The status patterns also had to lose their trailing word boundary. r"\bstatus\b"
# does not match California's "StatusType", because there is no boundary between
# the two words, so the column that distinguishes open from closed schools went
# undetected and the 124 closed-school rows came back.
#
# r"activity ?code" sits ahead of the loose r"\bstatus" for the same reason that
# r"school ?status" does. Florida has no status column at all: whether a school
# is open is carried by ACTIVITY_CODE, whose values are A, C and F. The only
# headers there that match r"\bstatus" are MAGNET_STATUS and
# SI_TURNAROUND_STATUS, neither of which says anything about whether the school
# exists. Without this pattern the probe reports a magnet breakdown and the
# operator chooses operating values from it, which is the Texas "Magnet Status"
# error in a form that looks like a sensible answer.
#
# r"physical ?address" leads the street list because Florida publishes
# PHYSICAL_ADDRESS and MAILING_ADDRESS1 side by side, and for a landmark the
# building is the physical one. See prefer() for the same distinction applied to
# ZIP, where it changes the result rather than only the label.
#
# r"\bnces" lost its trailing boundary for exactly the StatusType reason above.
# California names the columns NCESDist and NCESSchool, with no separator, so
# r"\bnces\b" matched neither and the probe reported no NCES id for the one file
# we have already loaded. The NCES ids are what make the federal CCD release
# usable as a key-join for coverage checking with no name matching, so losing
# them silently costs a cross-check rather than a landmark.
#
# r"federal ?(dist|schl|school)" is there for Florida, which carries the same
# ids under FEDERAL_DIST_NO and FEDERAL_SCHL_NO. Checked rather than assumed:
# FEDERAL_DIST_NO is 7 digits beginning 12, which is Florida's state FIPS code
# and the documented shape of an NCES LEA id. The pattern is kept narrow so it
# cannot reach California's unrelated FederalDODistrictID, where 'federal' is
# followed by 'do' rather than 'dist'.

CAPTCHA_HINTS = ("captcha", "are you a human", "incapsula", "radware",
                 "cloudflare", "access denied", "bot detection")


def norm_header(h):
    """Lower-case a header and turn separator punctuation into single spaces.

    Underscores, hyphens and dots all separate words in real state exports, and
    all three are invisible to a \\b word boundary or a ' ?' literal space. One
    normalisation here is what lets every pattern be written in the readable
    'web address' form. See the note above ROLE_PATTERNS for what Florida did
    without it.
    """
    s = (h or "").strip().lower()
    s = re.sub(r"[_\-.]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def classify_headers(headers):
    """-> {role: [header, ...]} with EVERY matching column, in file order.

    Returning all matches rather than the first is deliberate: see the note on
    ROLE_PATTERNS. A file offering both a district and a school column for the
    same role must not be reduced to one silently.

    Patterns match the NORMALISED header; the ORIGINAL header is returned, since
    that is the string a loader has to read the column by.
    """
    found = {}
    for role, pats in ROLE_PATTERNS:
        for pat in pats:
            hits = [h for h in headers
                    if norm_header(h) and re.search(pat, norm_header(h))]
            if hits:
                found[role] = hits
                break
    return found


def is_mailing(header):
    """True if the header names a mailing address rather than a physical one."""
    return bool(re.search(r"\bmail", norm_header(header)))


def prefer(cands, level):
    """Choose among several columns for one role, favouring the requested level.

    'school' prefers a school-scoped column, 'district' a district-scoped one.
    With no match on level, the first column in file order is used, which is
    what a single-level file like California's gives anyway.

    A MAILING COLUMN LOSES TO A PHYSICAL ONE, and this one changes an answer
    rather than a label. Florida carries PHYSICAL_ZIP and MAILING_ZIP, and both
    match the same r"\\bzips?\\b" once the header is normalised, so without this
    the choice would fall to file order. A landmark is a building: its physical
    ZIP is the claim we are making, while a mailing ZIP is frequently the
    district office or a post-office box in another ZIP entirely. Taking the
    mailing column would not look like an error -- it would produce a full set
    of plausible ZIPs that quietly point at the wrong places.

    Level scope still dominates: a school-scoped mailing column beats a
    district-scoped physical one, because reading the district's ZIP against the
    school's website is the worse of the two mistakes.
    """
    if not cands:
        return None
    # Stable, so this only breaks ties: with no mailing candidate the order and
    # therefore every existing result is unchanged.
    cands = sorted(cands, key=is_mailing)
    want = "school" if level == "school" else "district"
    other = "district" if level == "school" else "school"
    for c in cands:
        cl = norm_header(c)
        if want in cl and other not in cl:
            return c
    for c in cands:
        if other not in norm_header(c):
            return c
    return cands[0]


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


def probe(state, raw, ctype, source, level="school"):
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
    print(f"  column roles detected (level = {level}, chosen column marked ->):")
    for role, _ in ROLE_PATTERNS:
        cands = roles.get(role) or []
        if not cands:
            print(f"    {role:<10}(none)")
            continue
        chosen = prefer(cands, level)
        for c in cands:
            mark = "->" if c == chosen else "  "
            print(f"    {role if c == cands[0] else '':<10}{mark} {c}")

    have_zip = prefer(roles.get("zip"), level)
    have_web = prefer(roles.get("website"), level)
    if not have_zip or not have_web:
        missing = [r for r in ("zip", "website") if not roles.get(r)]
        print(f"  VERDICT        UNUSABLE, no {' and no '.join(missing)} column")
        print(f"  headers: {', '.join(list(headers)[:24])}")
        return None

    # ONE POPULATION FOR EVERY NUMBER BELOW.
    #
    # The first version of this counted each figure over a different set of
    # rows: rows-with-both over rows carrying a ZIP and a website, distinct ZIPs
    # over every row with a ZIP, and distinct hosts over every row with a
    # website. Nothing said so, and a reader would reasonably assume the three
    # described the same schools.
    #
    # On California that produced 8,940 / 1,673 / 5,237 against the loader's
    # 8,816 / 1,367 / 5,165. The 124-row gap was closed schools, which the
    # loader excludes and this did not. The 306-ZIP gap was the different
    # denominator. Both numbers were defensible in isolation and misleading
    # together, which is worse than being wrong, because it looks like
    # corroboration.
    usable = [r for r in rows
              if looks_like_url(r.get(have_web)) and looks_like_zip(r.get(have_zip))]

    def zip_of(r):
        m = re.search(r"\b(\d{5})\b", r.get(have_zip) or "")
        return m.group(1) if m else None

    def host_of(r):
        v = (r.get(have_web) or "").strip().strip('"').lower()
        return v.split("://")[-1].split("/")[0].split(":")[0]

    zips = {zip_of(r) for r in usable} - {None}
    hosts = {host_of(r) for r in usable}
    print(f"\n  rows with ZIP and website   {len(usable):>8,}")
    print(f"  distinct 5-digit ZIPs       {len(zips):>8,}")
    print(f"  distinct website hosts      {len(hosts):>8,}")

    # THE STATUS VOCABULARY, WHICH DIFFERS IN EVERY STATE.
    #
    # The probe detects a status column and then cannot know which of its values
    # means "in operation": California writes Active, others write Open, O, or 1.
    # Guessing would reintroduce the 124-row error in a less visible form. So the
    # values are printed with their usable counts and the operator decides, and
    # that decision is exactly what the per-state loader config has to record.
    status_col = prefer(roles.get("status"), level)
    status_breakdown = {}
    if status_col:
        for r in usable:
            v = (r.get(status_col) or "").strip() or "(blank)"
            status_breakdown[v] = status_breakdown.get(v, 0) + 1
        print(f"\n  usable rows by {status_col}, pick the operating values for the "
              f"loader config:")
        for v, n in sorted(status_breakdown.items(), key=lambda kv: -kv[1])[:12]:
            sub = {zip_of(r) for r in usable
                   if ((r.get(status_col) or "").strip() or "(blank)") == v} - {None}
            print(f"    {v[:24]:<26}{n:>8,} rows{len(sub):>8,} ZIPs")
    else:
        print("\n  no status column detected, so closed schools cannot be excluded "
              "here.")

    # ZIPs are the figure to judge a state on, not hosts. California resolved
    # 5,165 distinct hosts to 556 addresses, and only 379 of those served a
    # single ZIP, so a host count overstates landmark potential about ninefold.
    # The host number is kept only because a host-to-ZIP ratio near 1 is a hint
    # that schools publish their own sites rather than the district's.
    print(f"\n  VERDICT        USABLE")
    print(f"  Judge the state on ZIPs, not hosts. In California 5,165 hosts "
          f"resolved to 556\n  addresses, of which 379 served one ZIP, so a host "
          f"count overstates the\n  landmark yield by roughly nine times.")
    return {"state": state, "rows": len(rows), "usable": len(usable),
            "zips": len(zips), "hosts": len(hosts),
            "delimiter": dname, "roles": roles, "status": status_breakdown}


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", help="candidate download URL")
    p.add_argument("--input", help="local copy, for sites that serve a captcha to servers")
    p.add_argument("--state", default="??", help="two-letter state code, for the report")
    p.add_argument("--config", help="JSON list of objects with state and url or input")
    p.add_argument("--level", choices=["school", "district"], default="school",
                   help="which level to measure when a file carries both, as Texas does "
                        "(default school)")
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
                r = probe(state, raw, "(local file)", j["input"], args.level)
            else:
                status, ctype, raw = fetch(j["url"], args.timeout)
                r = probe(state, raw, ctype, j["url"], args.level)
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
