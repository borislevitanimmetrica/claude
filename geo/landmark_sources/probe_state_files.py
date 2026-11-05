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
  the format as determined FROM THE BYTES, never from the name or content type
  for delimited text, both quoting dialects with their misaligned-row counts,
    so the parse that was chosen is auditable rather than asserted
  for an xlsx, the sheet list and which sheet was read
  which columns look like a school name, street, city, ZIP, website and status
  a full row accounting that must balance against the parsed row count
  how many rows actually carry both a ZIP and a website, which is the only
  number that decides whether the state is worth loading
  and, when no column is NAMED for the ZIP or the website, whether any column
    CONTAINS that data anyway -- because "no column called website" and "no
    websites in this file" are different claims, and only the second one
    justifies going to look for the domains somewhere else

FORMATS IT READS
----------------
Delimited text, real xlsx (through zipfile and ElementTree, so no third-party
dependency), and HTML tables, which several states serve under an Excel content
type and an .xls filename. Legacy OLE2/BIFF .xls is detected and refused with a
clear message rather than parsed badly; Kansas and Montana are the two states
that need a manual conversion for that reason.

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
    # The last two entries exist for the federal CCD directory, which names its
    # columns LZIP (location, i.e. physical) and MZIP (mailing). Neither has a
    # word boundary before 'zip' and camel-case splitting does not help, so
    # every bounded pattern missed both and the ZIP arrived only through the
    # content scan, which ranked them by hit count and picked the MAILING one.
    # ^lzip$ is tried first so the physical column wins by name; the bare 'zip'
    # catch-all then covers mzip and any other fused spelling.
    ("zip",     [r"\bzips?\b", r"zip ?code", r"\bzip ?5\b", r"^lzip$",
                 r"\bpostal", r"\bpostcode", r"\bzip", r"zip"]),
    ("website", [r"web ?site", r"\bweb\b", r"web ?page", r"\burl\b", r"homepage",
                 r"web ?address", r"\bweb"]),
    # Specificity order matters more here than anywhere else, because a file
    # typically has MANY headers containing the word 'school'. Nevada picked
    # 'School Year' and Louisiana picked 'NcesSchoolIdCd' when the loose
    # r"\bschool\b" came early; both have a perfectly good name column ('Name'
    # and 'SiteName'). So every qualified '<something> name' form is tried
    # before the bare word.
    # r"lea ?name" sits AFTER r"\bschool\b" because the same header means
    # opposite things in two states. Arkansas's school name column IS 'LEA Name'
    # and that file contains no header with the word school in it at all.
    # Washington's 'LEAName' is the DISTRICT, and its school name column is
    # plainly 'School'. Trying the school word first resolves both: Washington
    # finds School, and Arkansas falls through to LEA Name because it has no
    # school candidate.
    #
    # r"\bname\b" is the last resort, for a file whose only name column is
    # qualified by something we have never seen. Virginia's is 'LandmkName'.
    ("name",    [r"school ?name", r"sch ?name", r"institution ?name",
                 r"name ?of ?institution", r"building ?name",
                 r"facility ?name", r"site ?name", r"^name$",
                 r"\borganization\b", r"\bschool\b", r"lea ?name",
                 r"institution", r"\bname\b"]),
    ("city",    [r"\bcity\b", r"\btown\b", r"locality", r"city\b"]),
    ("street",  [r"physical ?address", r"street ?address", r"\bstreet\b",
                 r"^address", r"\baddr\b", r"location ?address",
                 r"mailing ?address"]),
    # r"\boperational" moved ahead of the loose r"\bstatus" for the Magnet
    # Status reason again: Nevada carries both 'Charter Status' and 'Operational
    # Status', both match r"\bstatus", and file order handed back the charter
    # flag -- which says nothing about whether the school is open.
    ("status",  [r"school ?status", r"district ?status", r"\bstatus ?type",
                 r"activity ?code", r"\boperational", r"open ?closed",
                 r"\bstatus", r"\bactive\b"]),
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

# A NAME COLUMN IS NEVER A CODE COLUMN.
#
# The loose r"\bschool\b" at the end of the name list is there for California,
# whose column is simply 'School'. Everywhere else it fires on the first header
# that happens to contain the word, and files are full of them. Measured picks
# before this filter: Pennsylvania 'School Number', North Dakota 'SchoolLevel',
# Michigan 'SchoolEmphasis', Kansas 'School Days Per Week', Nevada 'School
# Year', Louisiana 'NcesSchoolIdCd'. Every one of those files has a real name
# column.
#
# None of these words can appear in a column that holds a school's name, so a
# candidate containing one is rejected for the name role only.
NAME_REJECT = re.compile(
    r"\b(number|code|codes|id|ids|identifier|type|types|level|levels|year|"
    r"years|status|count|emphasis|days|week|flag|phone|fax|email|date|"
    r"enrollment|grade|grades|category|emphasis)\b")

CAPTCHA_HINTS = ("captcha", "are you a human", "incapsula", "radware",
                 "cloudflare", "access denied", "bot detection")


def norm_header(h):
    """Lower-case a header and reduce every word separator to a single space.

    Three separator conventions appear in real state exports and ALL THREE are
    invisible to a \\b word boundary or a ' ?' literal space:

      underscores and hyphens   WEB_ADDRESS, PHYSICAL_ZIP      (Florida)
      no separator at all       EntityPhysicalZip4, NCESDist   (Michigan, California)
      a digit fused to a word   ZIP5, ZIP4                     (Arizona)

    Michigan is the clearest case. Its header is EntityPhysicalZip4, which holds
    the ZIP, and r"\\bzip" cannot match it because the character before 'zip' is
    'l', a word character, so there is no boundary. The probe reported "no zip
    and no website column" for a file that has the ZIP.

    So camel case is split where an upper-case letter follows a lower-case one,
    and also at an acronym-to-word boundary so NCESDist becomes 'nces dist'
    rather than 'ncesdis t'. A digit run after a letter is separated too, which
    is what turns ZIP5 into 'zip 5'.

    Doing it once here is what lets every pattern stay in the readable
    'web address' form instead of growing a separator alternative each time a
    new state is added.
    """
    s = (h or "").strip()
    s = re.sub(r"[_\-.]+", " ", s)
    # fooBar -> foo Bar
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s)
    # NCESDist -> NCES Dist, i.e. keep the acronym whole
    s = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", s)
    # zip5 -> zip 5
    s = re.sub(r"(?<=[A-Za-z])(?=\d)", " ", s)
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s


def winnow(cands, rows, test):
    """Drop candidate columns in which NOT ONE value passes the role's test.

    Naming alone cannot separate Arizona's ZIP5 from its ZIP4: both normalise to
    something containing 'zip', and ZIP4 is the four-digit add-on while ZIP5 is
    the real ZIP. Michigan muddies it further by calling its genuine ZIP column
    EntityPhysicalZip4. So the name does not decide -- the contents do.

    A column in which no value anywhere looks like a ZIP is not the ZIP column,
    and that is a measurement rather than a guess. If no candidate passes,
    everything is kept so the report still shows what was considered instead of
    silently reporting none.
    """
    if not cands or not rows:
        return cands
    kept = [c for c in cands if any(test(r.get(c)) for r in rows)]
    return kept or cands


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
            if role == "name":
                keep = [h for h in hits if not NAME_REJECT.search(norm_header(h))]
                # If every candidate is a code column, keep them: reporting a
                # wrong name is better than reporting none, because the operator
                # can see it is wrong and the name decides nothing on its own.
                hits = keep or hits
            if hits:
                found[role] = hits
                break
    return found


def is_mailing(header):
    """True if the header names a mailing address rather than a physical one.

    The second pattern is for the federal CCD, which abbreviates the pair to
    MZIP/MCITY/MSTREET against LZIP/LCITY/LSTREET. Nothing in 'mzip' says
    mailing to a reader or to a word-boundary pattern, and on the territory
    extracts that silence cost real accuracy: the mailing column gave the Virgin
    Islands 2 distinct ZIPs where the physical column gives 5, and Guam 10 where
    the physical gives 8.
    """
    h = norm_header(header)
    return bool(re.search(r"\bmail", h) or re.match(r"^m(zip|city|street|state)", h))


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


# WHY THE QUOTING DIALECT IS MEASURED RATHER THAN FIXED.
#
# This used to parse every file with QUOTE_NONE. That is correct for California,
# whose export is tab-delimited and NOT quoted yet contains bare double quotes
# inside school names: the default dialect treats those as field quoting,
# swallows the following newlines, and silently turned an 8.8 MB file into 73
# rows. So QUOTE_NONE was not an arbitrary choice.
#
# But it is catastrophically wrong for a properly quoted CSV whose values
# contain the delimiter, which is most ArcGIS and Socrata exports. Measured
# counts of rows whose field count disagrees with the header:
#
#     file        QUOTE_NONE              default dialect
#     az.csv      4,775 of 5,559 ragged   0 ragged
#     ga.csv      18,089 of 19,920        0
#     ct.csv      2,487                   0
#     tx.csv      0                       0
#
# Arizona reported 205 usable rows against a true 3,970, and Michigan reported
# "no zip and no website column" for a file carrying EntityPhysicalZip4, because
# the HEADER itself had gone out of alignment. Both look like a state publishing
# bad data and are in fact this parser destroying good data.
#
# Neither dialect is right in general, so the file decides. Both are tried, the
# rows whose field count disagrees with the header are counted, and the dialect
# with fewer wins. A tie goes to QUOTE_NONE, which keeps California and Texas on
# exactly the parse that produced their verified numbers.
#
# Note that the correct dialect sometimes yields FEWER rows, not more: on
# Connecticut, QUOTE_NONE reports 3,678 rows and the default reports 1,232. The
# extra 2,446 were never rows. QUOTE_NONE was splitting single records on
# newlines held inside quoted fields, so the old count was inventing records.
DIALECTS = (("unquoted", csv.QUOTE_NONE), ("quoted", csv.QUOTE_MINIMAL))


def parse_delimited(text, delim):
    """-> (rows_as_lists, dialect_name, ragged, tried) choosing the dialect by measurement.

    'ragged' is the number of data rows whose field count differs from the
    header's. It is reported, not silently discarded: a nonzero value on the
    winning dialect means the file is genuinely irregular and the operator needs
    to know before a loader reads it.
    """
    tried = {}
    for name, quoting in DIALECTS:
        try:
            rows = list(csv.reader(io.StringIO(text), delimiter=delim,
                                   quoting=quoting))
        except csv.Error as exc:
            tried[name] = (None, None, f"csv error: {exc}")
            continue
        rows = [r for r in rows if r and any((c or "").strip() for c in r)]
        if not rows:
            tried[name] = (None, None, "no rows")
            continue
        # BANNER ROWS MUST GO BEFORE THE WIDTH IS MEASURED, or the comparison
        # between dialects is decided by the banner instead of by the data.
        #
        # Ohio's OEDS extract begins with a single one-cell line reading
        # 'Generated on 11/4/2026 5:44:59 PM'. Measuring width from that row
        # made BOTH dialects score 5,323 misaligned, the tie went to QUOTE_NONE
        # per the documented tie-break, and the commas inside ORG MAILING
        # ADDRESS then shifted every column: the probe reported the ZIP living
        # in the SUPERINTENDENT column and 2,035 usable rows against a true
        # 2,522 over 509 ZIPs. New Jersey has the same three-banner-row shape.
        #
        # So each candidate parse is stripped of its own banner first and the
        # raggedness is measured against the real header.
        rows, _ = strip_banner_rows(rows)
        if not rows:
            tried[name] = (None, None, "nothing left after banner rows")
            continue
        width = len(rows[0])
        ragged = sum(1 for r in rows[1:] if len(r) != width)
        tried[name] = (rows, ragged, None)

    usable = {k: v for k, v in tried.items() if v[0] is not None}
    if not usable:
        return [], "none", 0, tried
    # Fewest ragged rows wins; a tie goes to the first dialect in DIALECTS,
    # which is QUOTE_NONE, preserving California's and Texas's verified parse.
    best = min(usable.items(), key=lambda kv: (kv[1][1], [n for n, _ in DIALECTS].index(kv[0])))
    return best[1][0], best[0], best[1][1], tried


def dedupe_headers(raw_headers):
    """Give every column a usable, unique key WITHOUT discarding any.

    csv.DictReader keyed rows by the header text, which loses data two ways that
    both occurred in real state files. Florida's 77th column header is EMPTY, so
    it keyed on '' and printing the header list raised TypeError, which killed
    the probe immediately after the verdict on Maryland and Massachusetts.
    Arkansas carries 'Phone Number' and 'Fax Number' TWICE each, and DictReader
    keeps only the last of a repeated key, so a column silently vanished.

    Blank headers become col_<n> and repeats get a __<n> suffix, so the column
    count out always equals the column count in.
    """
    out, seen = [], {}
    for i, h in enumerate(raw_headers, start=1):
        name = (h or "").strip() or f"col_{i}"
        if name in seen:
            seen[name] += 1
            name = f"{name}__{seen[name]}"
        else:
            seen[name] = 1
        out.append(name)
    return out


def rows_to_dicts(rows):
    """-> (headers, list_of_dicts) padding short rows and keeping long ones.

    A short row is padded with empty strings rather than dropped, and a row
    longer than the header keeps its overflow under col_<n> keys, so no cell in
    the file is thrown away without being counted.
    """
    headers = dedupe_headers(rows[0])
    out = []
    for r in rows[1:]:
        if len(r) < len(headers):
            r = list(r) + [""] * (len(headers) - len(r))
        d = dict(zip(headers, r))
        for j, extra in enumerate(r[len(headers):], start=len(headers) + 1):
            d[f"col_{j}"] = extra
        out.append(d)
    return headers, out


XLSX_MAGIC = b"PK\x03\x04"
OLE2_MAGIC = b"\xd0\xcf\x11\xe0"
_NS_MAIN = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
_NS_REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
_NS_PKGREL = "{http://schemas.openxmlformats.org/package/2006/relationships}"


def _col_index(ref):
    """'BC12' -> 54, the zero-based column number. Blank cells have no element,
    so the reference is the only way to keep columns aligned."""
    n = 0
    for ch in ref:
        if ch.isalpha():
            n = n * 26 + (ord(ch.upper()) - 64)
        else:
            break
    return n - 1


def read_xlsx(raw, want_sheet=None):
    """-> (sheet_names, chosen_name, rows_as_lists) using only the standard library.

    Five of the states that DO publish a website column publish it only as a
    real xlsx: Arkansas, Illinois, Indiana, Nevada and Mississippi. Requiring a
    manual conversion step for those invites exactly the kind of undocumented
    hand-editing that makes a number impossible to reproduce, so the probe reads
    the format directly. An xlsx is a zip of XML, and zipfile plus ElementTree
    are enough; this module has no third-party dependency and openpyxl is not
    installed here anyway.
    """
    import zipfile
    import xml.etree.ElementTree as ET

    zf = zipfile.ZipFile(io.BytesIO(raw))

    rels = {}
    try:
        for rel in ET.fromstring(zf.read("xl/_rels/workbook.xml.rels")):
            rels[rel.get("Id")] = rel.get("Target")
    except KeyError:
        pass

    sheets = []
    for sh in ET.fromstring(zf.read("xl/workbook.xml")).iter(f"{_NS_MAIN}sheet"):
        target = rels.get(sh.get(f"{_NS_REL}id"), "")
        if target and not target.startswith("/"):
            target = "xl/" + target.lstrip("/")
        sheets.append((sh.get("name"), target.lstrip("/")))
    if not sheets:
        return [], None, []

    shared = []
    try:
        for si in ET.fromstring(zf.read("xl/sharedStrings.xml")).iter(f"{_NS_MAIN}si"):
            shared.append("".join(t.text or "" for t in si.iter(f"{_NS_MAIN}t")))
    except KeyError:
        pass

    names = [n for n, _ in sheets]
    chosen = None
    if want_sheet:
        for n, t in sheets:
            if n == want_sheet or n.lower() == want_sheet.lower():
                chosen = (n, t)
                break
        if chosen is None:
            raise SystemExit(f"no sheet named {want_sheet!r}; sheets are: "
                             + ", ".join(names))
    else:
        # Default to the sheet with the most rows rather than the first. Several
        # of these workbooks open on a title or legend sheet: Nevada's first
        # sheet is a 21-row banner and the data is on the second.
        best, best_rows = None, -1
        for n, t in sheets:
            try:
                blob = zf.read(t)
            except KeyError:
                continue
            count = blob.count(b"<row ")
            if count > best_rows:
                best, best_rows = (n, t), count
        chosen = best
    if chosen is None:
        return names, None, []

    rows = []
    for row in ET.fromstring(zf.read(chosen[1])).iter(f"{_NS_MAIN}row"):
        cells = {}
        for c in row.iter(f"{_NS_MAIN}c"):
            ref = c.get("r") or ""
            idx = _col_index(ref) if ref and ref[0].isalpha() else len(cells)
            ctype = c.get("t")
            if ctype == "inlineStr":
                val = "".join(t.text or "" for t in c.iter(f"{_NS_MAIN}t"))
            else:
                v = c.find(f"{_NS_MAIN}v")
                val = v.text if v is not None and v.text is not None else ""
                if ctype == "s":
                    try:
                        val = shared[int(val)]
                    except (ValueError, IndexError):
                        val = ""
            cells[idx] = (val or "").strip()
        if cells:
            width = max(cells) + 1
            rows.append([cells.get(i, "") for i in range(width)])
        else:
            rows.append([])
    return names, chosen[0], rows


def read_html_table(text):
    """-> rows_as_lists from the largest <table> in an HTML document.

    Massachusetts and Maine both serve their directory as content-type
    application/excel with a .xls filename, and the bytes are an HTML table.
    This is the same class of mislabelling as Florida's tab-delimited .xls, and
    it is common enough to handle rather than refuse.
    """
    from html.parser import HTMLParser
    from html import unescape

    class Tables(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.tables, self.cur, self.row, self.cell = [], None, None, None

        def handle_starttag(self, tag, attrs):
            if tag == "table":
                self.cur = []
            elif tag == "tr" and self.cur is not None:
                self.row = []
            elif tag in ("td", "th") and self.row is not None:
                self.cell = []

        def handle_endtag(self, tag):
            if tag == "table" and self.cur is not None:
                self.tables.append(self.cur)
                self.cur = None
            elif tag == "tr" and self.row is not None:
                if self.cur is not None:
                    self.cur.append(self.row)
                self.row = None
            elif tag in ("td", "th") and self.cell is not None:
                if self.row is not None:
                    self.row.append(unescape("".join(self.cell)).strip())
                self.cell = None

        def handle_data(self, data):
            if self.cell is not None:
                self.cell.append(data)

    p = Tables()
    p.feed(text)
    if not p.tables:
        return []
    best = max(p.tables, key=len)
    return [r for r in best if any((c or "").strip() for c in r)]


def rectangularize(rows):
    """Pad every row to the widest row. For xlsx only.

    A spreadsheet omits trailing empty cells entirely, so a row whose last
    column is blank is physically shorter. Measuring raggedness against that is
    meaningless -- Indiana showed 147 'misaligned' rows that were simply schools
    with no homepage in the last column. Padding first makes the width uniform
    so that the misalignment count means what it says for delimited text, where
    it is a real signal.
    """
    if not rows:
        return rows, 0
    width = max(len(r) for r in rows)
    return [list(r) + [""] * (width - len(r)) for r in rows], width


def strip_banner_rows(rows):
    """-> (rows, dropped) discarding leading title rows that precede the header.

    Colorado prefixes SIX title rows, Iowa three, Nevada and Mississippi and
    Kansas one each. The header is not row 0 in any of them.

    The rule is relative to the body of the file rather than to the next row.
    An earlier version compared each row only with its successor and required
    two or fewer populated cells, which stripped Nevada's one-cell banner but
    left Colorado reporting 3 columns and 1,885 misaligned rows, and Iowa
    reporting its own title as the school-name column.

    So the modal populated-cell count over the first 50 rows is taken as what a
    real row looks like, and leading rows carrying fewer than half that many are
    dropped. A banner is short by nature and a header is not, which makes this
    the one measurable difference between them. Florida's header is 76 populated
    cells of 77 and California's is 44 of 44, so both are comfortably kept.

    Dropped rows are COUNTED and reported, never silently removed.
    """
    if len(rows) < 2:
        return rows, 0
    counts = [sum(1 for c in r if (c or "").strip()) for r in rows[:50]]
    if not counts:
        return rows, 0
    mode = max(set(counts), key=counts.count)
    floor = max(2, mode // 2)
    dropped = 0
    while len(rows) > 1 and sum(1 for c in rows[0] if (c or "").strip()) < floor:
        rows = rows[1:]
        dropped += 1
    return rows, dropped


def looks_like_url(value):
    v = (value or "").strip().strip('"').lower()
    if not v or v in ("no data", "n/a", "none", "null", "-"):
        return False
    v = v.split("://")[-1].split("/")[0]
    return "." in v and " " not in v and not v.endswith(".")


def looks_like_hostname(value):
    """Stricter than looks_like_url: the host must end in an alphabetic TLD.

    Used ONLY by the blind content scan, never for the usable-row count.
    looks_like_url asks for a dot and no spaces, which is right for a column
    already identified as the website by name, and far too loose for a scan of
    every column in the file: it accepted a latitude of '30.123456' and so
    reported Louisiana's Latitude column as containing url-shaped values, and
    Missouri's Teachers count likewise.

    Deliberately NOT substituted for looks_like_url in the main test. Doing that
    would alter the usable counts for California, Texas and Florida, which are
    the numbers every other state is being judged against, and it would do so to
    fix a problem those files do not have.
    """
    v = (value or "").strip().strip('"').lower()
    if not v or v in ("no data", "n/a", "none", "null", "-"):
        return False
    v = v.split("://")[-1].split("/")[0].split("?")[0].split(":")[0]
    return bool(re.match(r"^(?=.*\.)[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$", v))


def looks_like_zip(value):
    """A bounded 5-digit group, or a fused 9-digit ZIP+4 with no separator.

    Puerto Rico writes 006120000 and Louisiana writes 705784611: a ZIP+4 run
    together. There is no 5-digit group with a word boundary on both sides
    inside a 9-digit run, so the bounded pattern matched neither, and the probe
    honestly reported 18 of 859 Puerto Rico rows as carrying a ZIP. The left
    five digits are the ZIP; see zip_of for the extraction.
    """
    v = value or ""
    return bool(re.search(r"\b\d{5}\b", v) or re.search(r"\b\d{9}\b", v))


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/plain,text/csv,application/octet-stream,text/html;q=0.8,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


def probe(state, raw, ctype, source, level="school", sheet=None):
    print(f"\n{'=' * 72}")
    print(f"{state}  from {source}")
    print(f"{'=' * 72}")
    print(f"  bytes          {len(raw):,}")
    print(f"  content-type   {ctype or '(none)'}")

    # FORMAT IS DECIDED BY THE BYTES, NEVER BY THE NAME OR THE CONTENT TYPE.
    #
    # Florida serves tab-delimited text as filename=MSID_all_schools.xls with
    # content-type application/msexcel. Massachusetts and Maine serve an HTML
    # table as application/excel. Montana serves a legacy OLE2 workbook under an
    # xlsx content type. Of the formats encountered across the states, the only
    # reliable discriminator is the leading magic number.
    dname = "n/a"
    ragged = 0
    tried = {}
    banner = 0
    if raw[:4] == XLSX_MAGIC:
        names, chosen_sheet, grid = read_xlsx(raw, sheet)
        if not grid:
            print(f"  format         xlsx, sheets: {', '.join(names) or '(none)'}")
            print("  VERDICT        xlsx read but the chosen sheet has no rows")
            return None
        print(f"  format         xlsx, {len(names)} sheet(s): {', '.join(names)}")
        print(f"  sheet read     {chosen_sheet}")
        sheet_rows = len(grid)
        grid, _ = rectangularize(grid)
        grid, banner = strip_banner_rows(grid)
        headers, rows = rows_to_dicts(grid)
        print(f"  sheet rows     {sheet_rows:,} read from the sheet")
    elif raw[:4] == OLE2_MAGIC:
        print("  format         legacy OLE2/BIFF .xls, which this does not read")
        print("  VERDICT        UNREADABLE HERE, convert the sheet to CSV or TSV "
              "and re-run")
        return None
    else:
        text = raw.decode("utf-8-sig", errors="replace")
        low = text[:6000].lower()
        if "<html" in low or "<!doctype" in low:
            hint = next((h for h in CAPTCHA_HINTS if h in low), None)
            if hint:
                print(f"  VERDICT        HTML -- looks like a {hint} page")
                print("  Download it in a browser and re-run with --input.")
                return None
            grid = read_html_table(text)
            if len(grid) < 2:
                print("  VERDICT        HTML, and no table in it to read")
                print("  Download it in a browser and re-run with --input.")
                return None
            print(f"  format         HTML table served under a non-HTML name")
            table_rows = len(grid)
            grid, _ = rectangularize(grid)
            grid, banner = strip_banner_rows(grid)
            headers, rows = rows_to_dicts(grid)
            print(f"  table rows     {table_rows:,} read from the largest table")
        else:
            delim = sniff_delimiter(text[:6000])
            dname = {"\t": "tab", ",": "comma", "|": "pipe",
                     ";": "semicolon"}[delim]
            grid, chosen_dialect, ragged, tried = parse_delimited(text, delim)
            if len(grid) < 2:
                print(f"  delimiter      {dname}")
                print("  VERDICT        no data rows parsed")
                return None
            print(f"  format         delimited text, {dname}-separated, "
                  f"{chosen_dialect} dialect")
            # Show the losing dialect so the choice is auditable rather than
            # asserted. This is the number that would have been wrong before.
            for name, (r, rg, err) in sorted(tried.items()):
                if err:
                    print(f"    dialect {name:<9} rejected: {err}")
                else:
                    mark = "chosen" if name == chosen_dialect else "      "
                    print(f"    dialect {name:<9} {len(r) - 1:>8,} rows, "
                          f"{rg:>8,} misaligned  {mark}")
            grid, banner = strip_banner_rows(grid)
            headers, rows = rows_to_dicts(grid)

    # ROW ACCOUNTING. Every physical record is placed somewhere and the total is
    # shown, so a silent loss of the ArcGIS or Connecticut kind cannot recur
    # without the arithmetic visibly failing to add up.
    print(f"  columns        {len(headers)}")
    print(f"  data rows      {len(rows):,}")
    if banner:
        print(f"  banner rows    {banner} leading title row(s) dropped before the header")
    if ragged:
        print(f"  MISALIGNED     {ragged:,} row(s) whose field count differs from "
              f"the header")
        print(f"                 these are padded or kept, not dropped, but the "
              f"file is irregular")
    if not rows:
        print("  VERDICT        no data rows parsed")
        return None

    roles = classify_headers(list(headers))

    # AN NCES ID COLUMN IS NOT A NAME COLUMN. Splitting camel case makes
    # California's 'NCESSchool' read as 'nces school', which matches the bare
    # school word and, being earlier in the file than the real 'School' column,
    # won the name role. The two roles are decided independently, so the overlap
    # has to be removed explicitly.
    if roles.get("name") and roles.get("ncesid"):
        trimmed = [h for h in roles["name"] if h not in set(roles["ncesid"])]
        if trimmed:
            roles["name"] = trimmed

    # Only the two roles that decide usability are winnowed by content. Doing it
    # to name or city would be pointless, since any non-empty string passes.
    if roles.get("zip"):
        roles["zip"] = winnow(roles["zip"], rows, looks_like_zip)
    if roles.get("website"):
        roles["website"] = winnow(roles["website"], rows, looks_like_url)
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

    # CONTENT FALLBACK: when no column is NAMED for a role, look for one that
    # CONTAINS the role's data anyway.
    #
    # This exists because a name-only verdict was wrong twice in opposite
    # directions. Iowa was written off as having no website column; its
    # directory carries a 'Website' header and 538 www values, and the earlier
    # reading simply missed it. Minnesota genuinely has no ZIP column, and also
    # has every ZIP, sitting inside a free-text address field
    # ('19455 Kenwood Tr, Lakeville, MN 55044') -- 4,152 usable rows that a
    # name-only probe discards.
    #
    # So "no column called website" and "no websites in this file" are different
    # claims, and only the second one justifies going to look for the data
    # somewhere else. The scan makes the probe able to assert the second.
    #
    # A content match is reported as such and never silently promoted to the
    # same standing as a named column, because the hit rate is what tells the
    # operator whether it is the real thing or a coincidence.
    def content_scan(test, exclude):
        found = []
        for h in headers:
            if h in exclude:
                continue
            hits = sum(1 for r in rows if test(r.get(h)))
            if hits:
                found.append((h, hits))
        return sorted(found, key=lambda kv: -kv[1])

    have_zip = prefer(roles.get("zip"), level)
    have_web = prefer(roles.get("website"), level)
    zip_from_content = False

    if not have_zip or not have_web:
        if not have_zip:
            cz = content_scan(looks_like_zip, set())
            if cz:
                print(f"\n  no column is NAMED for a ZIP, but these CONTAIN "
                      f"5-digit ZIPs:")
                for h, n in cz[:5]:
                    print(f"    {h:<34}{n:>8,} of {len(rows):,} rows")
                print(f"    Reading the ZIP out of {cz[0][0]!r} needs a regex in "
                      f"the loader config,")
                print(f"    so this is a usable state but not a drop-in one.")
                print(f"    Note the ranking is by hit count alone, so a column "
                      f"of 5-digit codes can")
                print(f"    appear here innocently. Minnesota's 'countycode' "
                      f"does. Check the choice.")
                have_zip = cz[0][0]
                zip_from_content = True
        if not have_web:
            cw = content_scan(looks_like_hostname, set())
            if cw:
                print(f"\n  no column is NAMED for a website, but these CONTAIN "
                      f"url-shaped values:")
                for h, n in cw[:5]:
                    print(f"    {h:<34}{n:>8,} of {len(rows):,} rows")
                have_web = cw[0][0]
            else:
                print(f"\n  NO url-shaped value appears in ANY of the "
                      f"{len(headers)} columns, over all {len(rows):,} rows.")
                print(f"  This state does not publish school websites in this "
                      f"file at all, so the")
                print(f"  domains have to come from somewhere else.")

    if not have_zip or not have_web:
        missing = [r for r in ("zip", "website")
                   if not (have_zip if r == "zip" else have_web)]
        print(f"  VERDICT        UNUSABLE, no {' and no '.join(missing)} column")
        # str() on each header because a blank or duplicate column used to leave
        # a None in this list, and join() then raised TypeError AFTER the verdict
        # had printed, which read as a crash rather than a result. dedupe_headers
        # removes the cause; this keeps it impossible.
        print(f"  headers: {', '.join(str(h) for h in list(headers)[:24])}")
        if len(headers) > 24:
            print(f"  ... and {len(headers) - 24} more: "
                  f"{', '.join(str(h) for h in list(headers)[24:48])}")
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
        # FIRST match for a named ZIP column, LAST match for one found by
        # content. In a dedicated ZIP column the first five-digit group is the
        # ZIP, and '94501-3634' and '62360 1041' both give 94501 and 62360
        # correctly. In a free-text address the first group is the STREET
        # NUMBER: '19455 Kenwood Tr, Lakeville, MN 55044' yields 19455, which is
        # not a ZIP and is not even in the right range. Minnesota is entirely
        # this shape, and taking the first match there reported 793 distinct
        # ZIPs that were mostly house numbers.
        v = r.get(have_zip) or ""
        hits = re.findall(r"\b(\d{5})\b", v)
        if hits:
            return hits[-1] if zip_from_content else hits[0]
        # A fused 9-digit ZIP+4: the ZIP is the LEFT five, never the right.
        nine = re.findall(r"\b(\d{9})\b", v)
        if nine:
            return (nine[-1] if zip_from_content else nine[0])[:5]
        return None

    def host_of(r):
        v = (r.get(have_web) or "").strip().strip('"').lower()
        return v.split("://")[-1].split("/")[0].split(":")[0]

    zips = {zip_of(r) for r in usable} - {None}
    hosts = {host_of(r) for r in usable}

    # EVERY ROW IS ACCOUNTED FOR. The four reject reasons plus the usable count
    # must sum to the parsed row count. Printing the sum is the cheap check that
    # no population has quietly changed under one of these figures, which is the
    # error that produced 8,940 / 1,673 / 5,237 against a true 8,816 / 1,367 /
    # 5,165 on California.
    no_web = sum(1 for r in rows if not looks_like_url(r.get(have_web))
                 and looks_like_zip(r.get(have_zip)))
    no_zip = sum(1 for r in rows if looks_like_url(r.get(have_web))
                 and not looks_like_zip(r.get(have_zip)))
    neither = sum(1 for r in rows if not looks_like_url(r.get(have_web))
                  and not looks_like_zip(r.get(have_zip)))
    print(f"\n  row accounting, over the {len(rows):,} parsed rows:")
    print(f"    usable, ZIP and website   {len(usable):>8,}")
    print(f"    rejected, no website      {no_web:>8,}")
    print(f"    rejected, no ZIP          {no_zip:>8,}")
    print(f"    rejected, neither         {neither:>8,}")
    total = len(usable) + no_web + no_zip + neither
    print(f"    sum                       {total:>8,}  "
          f"{'balances' if total == len(rows) else 'DOES NOT BALANCE'}")

    print(f"\n  rows with ZIP and website   {len(usable):>8,}")
    print(f"  distinct 5-digit ZIPs       {len(zips):>8,}")
    print(f"  distinct website hosts      {len(hosts):>8,}")

    # A WEBSITE COLUMN CAN BE POPULATED AND STILL BE WORTHLESS.
    #
    # Virginia's landmark layer carries a URL on all 2,153 of its school rows,
    # and every one of them is the same string: the state education
    # department's own directory landing page. The probe called that USABLE
    # with 512 ZIPs, which is a number that would have survived into a loader
    # config and produced 512 ZIPs pointing at one web server in Richmond.
    # Pennsylvania does a milder version, with 1,442 rows carrying its EdNA
    # directory app as a placeholder.
    #
    # One host covering most of a state is never a real answer, so the share
    # held by the most common host is printed and called out past half. The
    # threshold is a reporting trigger, not a rejection: the operator decides.
    host_rows = {}
    for r in usable:
        host_rows[host_of(r)] = host_rows.get(host_of(r), 0) + 1
    if host_rows:
        top = sorted(host_rows.items(), key=lambda kv: -kv[1])
        share = 100.0 * top[0][1] / len(usable)
        if share >= 50.0 or len(hosts) == 1:
            print(f"\n  SUSPECT WEBSITE COLUMN. The single most common host "
                  f"covers {share:.1f}% of the")
            print(f"  usable rows, which no genuine per-school website column "
                  f"does. This is the")
            print(f"  shape of a placeholder, usually the state's own directory "
                  f"page:")
            for h, n in top[:3]:
                print(f"    {h[:52]:<54}{n:>8,} rows")
            print(f"  Treat the ZIP count above as unearned until the column is "
                  f"checked by eye.")
        else:
            print(f"\n  most common hosts, as a district-reuse check:")
            for h, n in top[:5]:
                print(f"    {h[:52]:<54}{n:>8,} rows")
            single = sum(1 for n in host_rows.values() if n == 1)
            print(f"    hosts serving exactly one row             "
                  f"{single:>8,} of {len(hosts):,}")

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
    p.add_argument("--sheet", help="for an xlsx, the sheet to read; default is the "
                                   "sheet with the most rows, since several of these "
                                   "workbooks open on a title page")
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
                r = probe(state, raw, "(local file)", j["input"], args.level,
                          j.get("sheet") or args.sheet)
            else:
                status, ctype, raw = fetch(j["url"], args.timeout)
                r = probe(state, raw, ctype, j["url"], args.level,
                          j.get("sheet") or args.sheet)
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
