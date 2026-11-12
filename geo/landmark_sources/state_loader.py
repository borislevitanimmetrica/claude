#!/usr/bin/env python3
"""Load any state or territory school directory from a measured config.

WHY THIS IS CONFIG-DRIVEN RATHER THAN ONE SUBCOMMAND PER STATE

California was done by hand as lm_fetch.py's ca-cde subcommand, and the
threshold set for generalising it was three confirmed states, so the design
would not be fitted to a sample of one. Fifty-six jurisdictions have now been
surveyed and the variation is wider than code branching would hold cleanly: the
column carrying the ZIP is named Zip, ZipCode, ZIP5, PHYSICAL_ZIP, Physical Zip,
phys_zip, zipcode, LZIP or address1_postalcode, or it does not exist at all and
the ZIP has to be pulled out of a free-text address.

So the variation lives in states.json, where every value is traceable to a probe
run recorded in state_file_survey.md, and the code here is the small part that
is genuinely common.

WHAT IT DELIBERATELY DOES NOT DO

It does not decide anything the survey measured. It will not guess which status
value means open, because that guess is how 124 closed California schools came
back into a count that looked right. If a config has no status_operating and the
file has a status column, every row is loaded and the loader says so loudly.

It does not read formats itself. probe_state_files is imported and its readers
are used, so there is one implementation of "what are these bytes" and the
loader cannot disagree with the probe about a row count. That matters because
the probe is the thing whose numbers were checked.

IT PRINTS THE EXPECTED WASTE BEFORE ANY BUDGET IS SPENT. Schools very often
publish their district's site, so fifty schools in fifty ZIPs resolve to one
address at the district office. node_fanout.sql rejects exactly that, and
correctly, so those rows cost RDAP and trace budget and are then discarded. The
share of rows on a shared host is reported up front rather than discovered
afterwards.
"""

import argparse
import collections
import importlib.util
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


probe = _load("probe_state_files", os.path.join(HERE, "probe_state_files.py"))
lm = _load("lm_fetch", os.path.join(HERE, "lm_fetch.py"))

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/156.0 Safari/537.36")


def fetch(url, timeout=300, body=None, content_type=None, referer=None):
    """GET, or POST when body is given.

    An EMPTY body still has to be sent explicitly, as the empty string rather
    than None, because several of these endpoints answer a bodyless POST with
    HTTP 411 Length Required. Florida's download is exactly that case.
    """
    headers = {
        "User-Agent": UA,
        "Accept": "text/csv,text/plain,application/json,application/octet-stream,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.9",
    }
    data = None
    if body is not None:
        data = body.encode("utf-8")
        headers["Content-Type"] = content_type or "application/x-www-form-urlencoded"
        headers["Content-Length"] = str(len(data))
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def _with_params(url, **params):
    parts = urllib.parse.urlsplit(url)
    q = dict(urllib.parse.parse_qsl(parts.query, keep_blank_values=True))
    q.update({k: str(v) for k, v in params.items()})
    return urllib.parse.urlunsplit(
        (parts.scheme, parts.netloc, parts.path,
         urllib.parse.urlencode(q), parts.fragment))


def fetch_arcgis_all(url, page_size):
    """Page an ArcGIS FeatureServer query to completion, or fail loudly.

    AN ARCGIS QUERY SILENTLY RETURNS A PAGE, NOT A LAYER. Arizona's layer holds
    5,559 schools and the unpaginated query returned exactly 2,000, which is the
    server's maxRecordCount. Nothing in the response says "truncated" unless you
    look for exceededTransferLimit, and the loader would have reported 1,697
    usable rows and 256 ZIPs as though that were Arizona. It is 36 percent of
    Arizona.

    So the authoritative count is asked for FIRST, with returnCountOnly, and the
    pages are then collected until that many features are in hand. Ending up
    with fewer is fatal rather than quietly short, because a partial state load
    is indistinguishable from a complete one once the rows are in the table.
    """
    total = None
    try:
        doc = json.loads(fetch(_with_params(
            url, returnCountOnly="true", returnGeometry="false",
            f="json")).decode("utf-8", errors="replace"))
        total = doc.get("count")
    except (ValueError, urllib.error.HTTPError, urllib.error.URLError,
            OSError) as exc:
        print(f"  WARNING: could not get an authoritative count ({exc}). "
              f"Pagination will stop on the server's own signal, which is "
              f"weaker evidence of completeness.")
    if total is not None:
        print(f"  layer count    {total:,} features, authoritative")

    feats, offset, pages = [], 0, 0
    while True:
        page = json.loads(fetch(_with_params(
            url, resultOffset=offset, resultRecordCount=page_size,
            returnGeometry="false", f="json")).decode("utf-8", errors="replace"))
        got = page.get("features") or []
        feats.extend(got)
        pages += 1
        print(f"  page {pages:<3}      offset {offset:>7,}  +{len(got):,} "
              f"features, {len(feats):,} so far")
        if not got:
            break
        offset += len(got)
        if total is not None and len(feats) >= total:
            break
        if total is None and not page.get("exceededTransferLimit"):
            break
        if pages > 200:
            sys.exit("more than 200 pages; refusing to loop further")

    if total is not None and len(feats) != total:
        sys.exit(f"TRUNCATED: the layer reports {total:,} features and "
                 f"pagination produced {len(feats):,}. Refusing to load a "
                 f"partial state, because once the rows are in the table a "
                 f"partial load is indistinguishable from a complete one.")
    return json.dumps({"features": feats}).encode("utf-8")


def _dx_serialize_args(args):
    """DevExpress SerializeCallbackArgs: each item becomes <len>|<item>.

    Read out of the page's own DXR.axd bundle rather than inferred. This is the
    function that makes an export argument the literal string 6|EXPORT3|Csv,
    which is the piece a long sequence of plausible guesses never produced.
    """
    out = []
    for a in args:
        s = "" if a is None else str(a)
        out += [str(len(s)), "|", s]
    return "".join(out)


def _dx_callback_param(params):
    """DevExpress FormatCallbackState: each pair becomes <KEY>|<len>;<value>;

    The grid's rows are fetched by a CLIENT CALLBACK, not by the page load, so
    a freshly loaded page has no rows on the server to export and the export
    succeeds with one header row. This builds the callback that populates it.
    """
    gb = _dx_serialize_args(["CUSTOMCALLBACK",
                             json.dumps(params, separators=(",", ":"))])
    return "c0:" + "".join(["GB", "|", str(len(gb)), ";", gb, ";"])


def fetch_viewstate_post(cfg):
    """GET an ASP.NET page, harvest its form, and post an event back to it.

    Two states export only this way, and both looked like they needed a human
    with a browser until the request was reproduced properly.

    Alabama's directory is a DevExpress grid. Its export runs through an
    ordinary __doPostBack, and the argument format comes from the DevExpress
    bundle: SerializeCallbackArgs emits a length-prefixed <len>|<item> per item,
    so an export is the literal string 6|EXPORT3|Csv. An earlier attempt had the
    right event target and got HTTP 411, which was a missing Content-Length
    header rather than a wrong target.

    EVERY field on the page is posted back, not just __VIEWSTATE. Alabama's page
    carries 73 of them and the server validates the set; sending a subset
    returns the page again, which parses as HTML rather than data and would be
    reported as a captcha.
    """
    from html.parser import HTMLParser
    import http.cookiejar

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("User-Agent", UA)]

    page_url = cfg["viewstate_post"]["page_url"]
    with opener.open(urllib.request.Request(page_url), timeout=180) as r:
        html_text = r.read().decode("utf-8", errors="replace")
    print(f"  page GET       {len(html_text):,} chars, {len(jar)} cookie(s)")

    class Fields(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.fields = []
            self._select = None

        def handle_starttag(self, tag, attrs):
            a = dict(attrs)
            if tag == "input":
                name = a.get("name")
                if not name:
                    return
                itype = (a.get("type") or "text").lower()
                if itype in ("submit", "button", "image", "reset"):
                    return
                if itype in ("checkbox", "radio") and "checked" not in a:
                    return
                self.fields.append((name, a.get("value") or ""))
            elif tag == "select":
                self._select = a.get("name")
            elif tag == "option" and self._select and "selected" in a:
                self.fields.append((self._select, a.get("value") or ""))
            elif tag == "textarea" and a.get("name"):
                self.fields.append((a["name"], ""))

        def handle_endtag(self, tag):
            if tag == "select":
                self._select = None

    def harvest(text):
        fp = Fields()
        fp.feed(text)
        return dict(fp.fields)

    def post(form, note, extra_headers=None):
        body = urllib.parse.urlencode(form).encode("utf-8")
        headers = {
            "User-Agent": UA,
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": str(len(body)),
            "Referer": page_url,
            "Origin": "{0.scheme}://{0.netloc}".format(
                urllib.parse.urlsplit(page_url)),
        }
        if extra_headers:
            headers.update(extra_headers)
        req = urllib.request.Request(
            cfg["viewstate_post"].get("post_url", page_url), data=body,
            headers=headers)
        with opener.open(req, timeout=300) as r:
            blob = r.read()
            disp = r.headers.get("Content-Disposition", "")
            ctype = r.headers.get("Content-Type", "")
        print(f"  {note:<14} {len(blob):,} bytes, {ctype}"
              + (f", {disp.split(';')[0]}" if disp else ""))
        return blob, ctype, disp

    form = harvest(html_text)
    print(f"  form fields    {len(form)} harvested")
    if "__VIEWSTATE" not in form:
        sys.exit("No __VIEWSTATE on the page, so this is not the ASP.NET form "
                 "the config expects. The page may have changed.")

    # PRIME STEPS. A DevExpress grid is EMPTY until something populates it, and
    # exporting an empty grid succeeds: Alabama returned text/csv with the right
    # attachment filename and 307 bytes, one header row and no data. That is the
    # worst kind of success, because the content type and filename both say the
    # export worked.
    #
    # So the config can name postbacks to run first, in order, each one's
    # response re-harvested for the fresh __VIEWSTATE the next needs. Alabama
    # needs one: the View Information button, ctl00$MainContent$btnViewSites.
    base = dict(form)
    for i, step in enumerate(cfg["viewstate_post"].get("prime") or [], start=1):
        pf = dict(form)
        pf["__EVENTTARGET"] = step.get("event_target", "")
        pf["__EVENTARGUMENT"] = step.get("event_argument", "")
        cb = step.get("devexpress_callback")
        hdrs = None
        if cb:
            pf["__CALLBACKID"] = cb["control"]
            pf["__CALLBACKPARAM"] = _dx_callback_param(cb["params"])
            hdrs = {"X-Requested-With": "XMLHttpRequest",
                    "X-MicrosoftAjax": "Delta=true"}
        pf.update(step.get("extra_fields") or {})
        blob, _, _ = post(pf, f"prime {i}", hdrs)
        text = blob.decode("utf-8", errors="replace")
        print(f"  prime {i} rows   {text.count('dxgvDataRow'):,} grid rows in the "
              f"response")
        # The form is NOT re-harvested unless asked. What populates the grid is
        # SERVER-SIDE state keyed by the session cookie, and the sequence that
        # works on Alabama posts the ORIGINAL form every time. Re-harvesting
        # replaced the grid's filter state and brought the export back to a
        # single header row.
        if step.get("reharvest"):
            fresh = harvest(text)
            if "__VIEWSTATE" in fresh:
                form = fresh
                print(f"  prime {i} fields {len(form)} re-harvested")
        else:
            form = dict(base)

    form["__EVENTTARGET"] = cfg["viewstate_post"]["event_target"]
    form["__EVENTARGUMENT"] = cfg["viewstate_post"].get("event_argument", "")
    form.update(cfg["viewstate_post"].get("extra_fields") or {})
    raw, ctype, disp = post(form, "export")

    if b"<html" in raw[:4000].lower() or b"<!doctype" in raw[:4000].lower():
        sys.exit("The postback returned the PAGE rather than a file. The event "
                 "target or argument is wrong for this build. states.json "
                 "records the verified values.")
    min_bytes = cfg["viewstate_post"].get("min_bytes")
    if min_bytes and len(raw) < min_bytes:
        sys.exit(f"The export returned only {len(raw):,} bytes against a "
                 f"configured minimum of {min_bytes:,}. An empty DevExpress "
                 f"grid exports successfully with the right content type and "
                 f"filename and no data, so a short file here means the grid "
                 f"was not populated, not that the state has no schools.")
    return raw


def fetch_pages(cfg, pages):
    """Page a URL carrying a literal PAGE token, for APIs with no offset.

    Tennessee's directory is a Dataverse portal whose FetchXML takes a page
    NUMBER rather than a row offset, so the ArcGIS count-then-offset approach
    does not apply. Paging stops early on an empty page, and the records are
    concatenated under the configured key so the reader sees one document.
    """
    rec_key = cfg.get("json_records_key", "value")
    out = []
    for page in range(1, pages + 1):
        url = cfg["url"].replace("PAGENUMBER", str(page))
        raw = fetch(url, body=cfg.get("post_body"),
                    content_type=cfg.get("post_content_type"),
                    referer=cfg.get("referer"))
        doc = json.loads(raw.decode("utf-8", errors="replace"))
        got = (doc.get(rec_key) if isinstance(doc, dict) else doc) or []
        out.extend(got)
        print(f"  page {page:<3}      +{len(got):,} records, {len(out):,} so far")
        if not got:
            break
    if not out:
        sys.exit("No records returned across any page.")
    return json.dumps({rec_key: out}).encode("utf-8")


def rows_from_bytes(raw, cfg):
    """-> (headers, rows) using the probe's own readers.

    A zip member is extracted first, and an ArcGIS JSON response is flattened,
    because several states publish only through a FeatureServer query.
    """
    member = cfg.get("member")
    if raw[:4] == b"PK\x03\x04" and member:
        zf = zipfile.ZipFile(io.BytesIO(raw))
        names = zf.namelist()
        if member not in names:
            cand = [n for n in names if n.endswith(".csv")]
            if not cand:
                sys.exit(f"member {member!r} not in the zip; it holds: "
                         + ", ".join(names))
            member = cand[0]
        raw = zf.read(member)

    if raw.lstrip()[:1] in (b"{", b"["):
        doc = json.loads(raw.decode("utf-8", errors="replace"))
        # ArcGIS nests each record's fields under "attributes" inside
        # "features"; Dataverse and OData put flat records under "value". The
        # config names both so a new shape needs no code.
        rec_key = cfg.get("json_records_key", "features")
        attr_key = cfg.get("json_attrs_key", "attributes")
        recs = doc.get(rec_key) if isinstance(doc, dict) else doc
        recs = recs or []
        if not recs:
            sys.exit(f"JSON parsed but carries no {rec_key!r}. For an ArcGIS "
                     f"endpoint check the where clause, returnGeometry=false "
                     f"and f=json.")
        def attrs(rec):
            return (rec.get(attr_key) or {}) if attr_key else rec
        keys = []
        for rec in recs:
            for k in attrs(rec):
                if k not in keys and not k.startswith("@"):
                    keys.append(k)
        grid = [keys]
        for rec in recs:
            a = attrs(rec)
            grid.append(["" if a.get(k) is None else str(a.get(k)) for k in keys])
        print(f"  format         JSON, {len(recs):,} records under {rec_key!r}")
        return probe.rows_to_dicts(grid)

    if raw[:4] == probe.XLSX_MAGIC:
        names, chosen, grid = probe.read_xlsx(raw, cfg.get("sheet"))
        if not grid:
            sys.exit("xlsx read but no rows. Sheets: " + ", ".join(names))
        print(f"  format         xlsx, sheet {chosen}")
        grid, _ = probe.rectangularize(grid)
        grid, dropped = probe.strip_banner_rows(grid)
        if dropped:
            print(f"  banner rows    {dropped} dropped before the header")
        return probe.rows_to_dicts(grid)

    if raw[:4] == probe.OLE2_MAGIC:
        sys.exit("This is a legacy OLE2 .xls. It is not read here by design, "
                 "rather than parsed badly. Convert the sheet to TSV and pass "
                 "it with --input. Kansas and Montana are the two that need it.")

    text = raw.decode("utf-8-sig", errors="replace")
    low = text[:6000].lower()
    if "<html" in low or "<!doctype" in low:
        hint = next((h for h in probe.CAPTCHA_HINTS if h in low), None)
        if hint:
            sys.exit(f"The body is HTML and looks like a {hint} page, not data. "
                     f"Download it in a browser and pass it with --input.")
        grid = probe.read_html_table(text)
        if len(grid) < 2:
            sys.exit("The body is HTML with no table in it.")
        print("  format         HTML table served under a non-HTML name")
        grid, _ = probe.rectangularize(grid)
        grid, dropped = probe.strip_banner_rows(grid)
        if dropped:
            print(f"  banner rows    {dropped} dropped before the header")
        return probe.rows_to_dicts(grid)

    delim = probe.sniff_delimiter(text[:6000])
    grid, dialect, ragged, _ = probe.parse_delimited(text, delim)
    if len(grid) < 2:
        sys.exit("No data rows parsed.")
    dname = {"\t": "tab", ",": "comma", "|": "pipe", ";": "semicolon"}[delim]
    print(f"  format         delimited text, {dname}-separated, {dialect} dialect")
    if ragged:
        print(f"  MISALIGNED     {ragged:,} rows disagree with the header width")
    return probe.rows_to_dicts(grid)


def resolve_columns(headers, cfg, rows):
    """Config names win; the probe's detection fills the rest.

    A config name that is not in the file is FATAL. Ignoring it silently would
    mean loading a different column than the survey measured, which is the
    failure this design exists to prevent.
    """
    roles = probe.classify_headers(list(headers))
    if roles.get("name") and roles.get("ncesid"):
        t = [h for h in roles["name"] if h not in set(roles["ncesid"])]
        if t:
            roles["name"] = t
    out = {}
    for role in ("name", "zip", "website", "city", "street", "status",
                 "district", "region", "id"):
        want = (cfg.get("columns") or {}).get(role)
        if want:
            if want not in headers:
                sys.exit(f"config names the {role} column {want!r}, which is "
                         f"not in this file. Headers are:\n  "
                         + "\n  ".join(str(h) for h in headers))
            out[role] = want
        else:
            cands = roles.get("ncesid" if role == "id" else role)
            if cands and role in ("zip", "website"):
                test = (probe.looks_like_zip if role == "zip"
                        else probe.looks_like_url)
                cands = probe.winnow(cands, rows, test)
            chosen = probe.prefer(cands, "school") if cands else None
            if role == "id" and chosen:
                chosen = verify_id_column(chosen, rows)
            out[role] = chosen
    return out


# An auto-detected id must be unique on at least this share of the rows that
# carry a value. 0.95 rather than 1.0 because a real per-school id file can
# still contain a handful of genuine duplicate rows: Florida has 7 virtual
# programmes sharing a name and ZIP, and Texas's configured NCES id repeats on
# 133 of 7,307.
ID_MIN_UNIQUE = 0.95


def report_id_collisions(out):
    """Say whether rows about to be collapsed by the upsert key are real losses.

    The loader reports "N duplicate ids skipped" at merge time, and that line
    reads like housekeeping whether it is harmless or catastrophic. Florida's
    "3,620 duplicate ids skipped" was 98 per cent data loss. Alabama's 2,238 is
    not, as far as this can tell, because the colliding rows carry the SAME
    website.

    That is the distinction this prints. Two rows sharing an id and a website
    are a duplicated entity in the source file, and collapsing them loses
    nothing a landmark needs: the landmark is the host, and the host is
    identical. Two rows sharing an id but carrying DIFFERENT websites are two
    different institutions being merged into one, and that is a real loss.

    Both numbers appear before the merge, so the "duplicate ids skipped" line
    can be read rather than guessed at.

    out rows are build_row output: index 1 is source_id, index 9 is website.
    """
    groups = collections.defaultdict(set)
    for row in out:
        groups[row[1]].add((row[9] or "").strip().lower())
    collapsing = {k: v for k, v in groups.items() if len(v) >= 1}
    dup_rows = len(out) - len(groups)
    if not dup_rows:
        print(f"    upsert key                 {len(groups):>8,} distinct, "
              f"no collisions")
        return
    conflicting = {k: v for k, v in collapsing.items() if len(v) > 1}
    lost = sum(len(v) - 1 for v in conflicting.values())
    print(f"\n  the upsert will collapse {dup_rows:,} of those {len(out):,} rows:")
    print(f"    distinct upsert keys       {len(groups):>8,}")
    print(f"    keys with ONE website      {len(groups) - len(conflicting):>8,}  "
          f"harmless, a duplicated entity in the source")
    print(f"    keys with SEVERAL websites {len(conflicting):>8,}  "
          f"REAL LOSS, different institutions merged")
    print(f"    distinct websites lost     {lost:>8,}")
    if conflicting:
        print(f"    worst, by distinct websites on one key:")
        for k, v in sorted(conflicting.items(), key=lambda kv: -len(kv[1]))[:5]:
            print(f"      {len(v):>3} sites  {k[:58]}")


def verify_id_column(col, rows):
    """Reject an auto-detected id column that is not unique per row.

    THIS EXISTS BECAUSE IT SILENTLY DESTROYED 98 PER CENT OF FLORIDA.
    Measured 2026-11-06: the Florida load reported "merged 80 rows (3,620
    duplicate ids skipped)" out of 3,700 usable schools. states.json names no
    id column for Florida, so resolve_columns fell back to the probe's ncesid
    detector, which matched FEDERAL_DIST_NO. That is the DISTRICT number, and
    Florida has about 80 districts, so every school in a district collapsed
    onto one row in the upsert and 3,620 real schools were dropped as
    duplicates. Reproduced exactly: name plus ZIP gives 3,693 distinct ids for
    the same 3,700 rows, so only 7 are true duplicates.

    A CONFIGURED id is trusted without this check, because a human read the
    file and the survey recorded it. An AUTO-DETECTED one is a guess about what
    a column name means, and a guess that becomes the upsert key can delete
    data. Texas and Illinois name theirs in states.json and are unaffected.

    The same failure was live on every jurisdiction with no configured id. From
    the 2026-11-06 load: FL 3,620 of 3,700 lost, AZ 2,402 of 3,565, AL 2,229 of
    4,026, OH 886 of 2,524, PA 221 of 4,387, SC 135 of 1,427, MN 126 of 4,152.
    """
    vals = [(r.get(col) or "").strip() for r in rows]
    present = [v for v in vals if v]
    if not present:
        print(f"  id column      {col} REJECTED: empty on every row; "
              f"using name plus ZIP")
        return None
    uniq = len(set(present))
    ratio = uniq / len(present)
    if ratio < ID_MIN_UNIQUE:
        print(f"  id column      {col} REJECTED: {uniq:,} distinct values over "
              f"{len(present):,} rows, {100.0 * ratio:.1f} pct unique")
        print(f"                 that is not a per-row id. Using name plus ZIP "
              f"instead, which is")
        print(f"                 deterministic and does not collapse rows onto "
              f"a shared key.")
        return None
    print(f"  id column      {col} auto-detected, {100.0 * ratio:.1f} pct "
          f"unique over {len(present):,} rows")
    return col


def content_fallback(headers, rows, role, out):
    """Find a column by CONTENT when no column is NAMED for the role.

    Alabama's export has a two-level header: row 2 names the groups and row 3
    names the sub-columns under 'Physical Address', so the ZIP column's own
    header cell is EMPTY and becomes col_13. No naming pattern can reach it,
    and the state is otherwise one of the better ones at 467 ZIPs.

    The chosen column and its hit rate are printed, because a content match is
    weaker evidence than a named one and the operator should see which column
    was taken. Ranking is by hit count alone, so a column of unrelated 5-digit
    codes can win: Minnesota's countycode does.
    """
    test = probe.looks_like_zip if role == "zip" else probe.looks_like_hostname
    scored = []
    for h in headers:
        if h in out.values():
            continue
        n = sum(1 for r in rows if test(r.get(h)))
        if n:
            scored.append((h, n))
    if not scored:
        return None
    scored.sort(key=lambda kv: -kv[1])
    best, n = scored[0]
    print(f"  {role:<14} {best} (BY CONTENT, {n:,} of {len(rows):,} rows; "
          f"no column is named for it)")
    if len(scored) > 1:
        print(f"                 runners up: "
              + ", ".join(f"{h} {c:,}" for h, c in scored[1:4]))
    return best


def zip_of(value, mode):
    """mode five, last or left5. See states.json for which state needs which."""
    v = (value or "").strip()
    if mode == "left5":
        digits = re.sub(r"\D", "", v)
        return digits[:5] if len(digits) >= 5 else None
    hits = re.findall(r"\b(\d{5})\b", v)
    if hits:
        return hits[-1] if mode == "last" else hits[0]
    nine = re.findall(r"\b(\d{9})\b", v)
    if nine:
        return (nine[-1] if mode == "last" else nine[0])[:5]
    return None


def validate_filters(headers, cfg):
    """A filter naming a column that is not in the file is FATAL.

    Silence here is worse than a crash. A row_filter that matches nothing
    leaves the file unfiltered and the loader reports a larger, wrong count
    that looks like success: on Georgia it would load eight stacked school
    years, and on West Virginia it would keep the 65 county board-of-education
    offices among the schools.
    """
    hs = set(headers)
    for f in cfg.get("row_filter") or []:
        col = f.get("column")
        if col not in hs:
            sys.exit(f"row_filter names the column {col!r}, which is not in "
                     f"this file. Headers are:\n  "
                     + "\n  ".join(str(h) for h in headers))


def passes_filters(row, cfg):
    for f in cfg.get("row_filter") or []:
        val = (row.get(f.get("column")) or "").strip()
        if "equals" in f and val != str(f["equals"]):
            return False
        if "in" in f and val not in [str(x) for x in f["in"]]:
            return False
        if "not_in" in f and val in [str(x) for x in f["not_in"]]:
            return False
    return True


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", default=os.path.join(HERE, "states.json"))
    p.add_argument("--state", required=True,
                   help="key in the config, e.g. FL or CCD")
    p.add_argument("--input", help="local copy, for the entries with no url")
    p.add_argument("--only-state",
                   help="for the CCD entry, load one state's rows only, by ST")
    p.add_argument("--list", action="store_true",
                   help="list the configured jurisdictions and exit")
    p.add_argument("--all", action="store_true",
                   help="run every jurisdiction that can be fetched without a "
                        "local file, continuing past failures and printing a "
                        "summary. The six needing --input are listed and "
                        "skipped")
    p.add_argument("--dry-run", action="store_true",
                   help="parse, count and report the expected waste without "
                        "touching the database at all. Run this first: it "
                        "separates a file problem from a database problem")
    p.add_argument("--replace", action="store_true",
                   help="delete this source's existing rows first")
    p.add_argument("--release", help="source_release stamp, default today")
    args = p.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        cfgs = json.load(fh)

    if args.list:
        for k, v in cfgs.items():
            if k.startswith("_"):
                continue
            if v.get("viewstate_post"):
                how = "ASP.NET postback"
            elif v.get("post_body") is not None:
                how = "POST"
            elif v.get("url"):
                how = "GET"
            else:
                how = "needs --input"
            print(f"  {k:<6}{v['source']:<16}{how}")
        return

    if args.all:
        # Each jurisdiction runs in its own process so that one failure cannot
        # take the rest down, and so a partial run leaves a readable record of
        # which states did load rather than an exception part way through.
        import subprocess
        def auto(v):
            return bool(v.get("url") or v.get("viewstate_post"))
        fetchable = [k for k, v in cfgs.items()
                     if not k.startswith("_") and auto(v)]
        needs_file = [k for k, v in cfgs.items()
                      if not k.startswith("_") and not auto(v)]
        print(f"Running {len(fetchable)} fetchable jurisdictions: "
              + " ".join(fetchable))
        print(f"Skipping {len(needs_file)} that need a local file: "
              + " ".join(needs_file))
        print("Their notes in states.json record how to obtain each one.\n")
        results = []
        for k in fetchable:
            cmd = [sys.executable, os.path.abspath(__file__),
                   "--config", args.config, "--state", k]
            if args.dry_run:
                cmd.append("--dry-run")
            if args.replace:
                cmd.append("--replace")
            if args.release:
                cmd += ["--release", args.release]
            r = subprocess.run(cmd, capture_output=True, text=True)
            sys.stdout.write(r.stdout)
            if r.returncode != 0:
                sys.stdout.write(r.stderr)
            usable = zips = "-"
            for line in r.stdout.splitlines():
                m = re.search(r"usable\s+([0-9,]+)\s*$", line)
                if m:
                    usable = m.group(1)
                m = re.search(r"distinct 5-digit ZIPs\s+([0-9,]+)", line)
                if m:
                    zips = m.group(1)
            results.append((k, "ok" if r.returncode == 0 else "FAILED",
                            usable, zips))
        print(f"\n{'=' * 72}")
        print(f"SUMMARY, {'dry run' if args.dry_run else 'loaded'}")
        print(f"{'=' * 72}")
        print(f"{'ST':<6}{'result':<10}{'usable':>10}{'ZIPs':>9}")
        for k, st, u, z in results:
            print(f"{k:<6}{st:<10}{u:>10}{z:>9}")
        bad = [k for k, st, _, _ in results if st != "ok"]
        if bad:
            print(f"\n{len(bad)} FAILED: " + " ".join(bad))
        print(f"\n{len(needs_file)} needing a local file: " + " ".join(needs_file))
        return

    key = args.state if args.state in cfgs else args.state.upper()
    if key not in cfgs or key.startswith("_"):
        avail = [k for k in cfgs if not k.startswith("_")]
        sys.exit(f"no config for {args.state!r}. Available: " + ", ".join(avail))
    cfg = cfgs[key]
    source = cfg["source"]
    if args.only_state:
        source = f"{source}_{args.only_state.lower()}"

    print(f"\n{'=' * 72}")
    print(f"{key}  ->  source {source}")
    print(f"{'=' * 72}")

    if args.input:
        raw = open(args.input, "rb").read()
        print(f"  input          {args.input}, {len(raw):,} bytes")
    elif cfg.get("viewstate_post"):
        print(f"  postback       {cfg['viewstate_post']['page_url'][:90]}")
        try:
            raw = fetch_viewstate_post(cfg)
        except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
            sys.exit(f"postback failed: {exc}\nPass a local copy with --input.")
    elif cfg.get("url"):
        print(f"  fetching       {cfg['url'][:96]}")
        try:
            page_size = (cfg.get("paginate") or {}).get("page_size")
            pages = (cfg.get("paginate") or {}).get("pages")
            if page_size:
                raw = fetch_arcgis_all(cfg["url"], page_size)
            elif pages:
                raw = fetch_pages(cfg, pages)
            else:
                raw = fetch(cfg["url"], body=cfg.get("post_body"),
                            content_type=cfg.get("post_content_type"),
                            referer=cfg.get("referer"))
        except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
            sys.exit(f"fetch failed: {exc}\nPass a local copy with --input.")
        print(f"  fetched        {len(raw):,} bytes")
    else:
        sys.exit(f"{key} has no url in the config, which means it cannot be "
                 f"fetched from a datacentre address. states.json records how "
                 f"to obtain it. Pass it with --input.")

    headers, rows = rows_from_bytes(raw, cfg)
    print(f"  columns        {len(headers)}")
    print(f"  data rows      {len(rows):,}")

    cols = resolve_columns(headers, cfg, rows)
    for role in ("name", "zip", "website", "status"):
        if cols.get(role):
            print(f"  {role:<14} {cols[role]}")
    for role in ("zip", "website"):
        if not cols.get(role):
            cols[role] = content_fallback(headers, rows, role, cols)
    if not cols.get("zip") or not cols.get("website"):
        sys.exit("No ZIP or no website column, so this jurisdiction is not "
                 "loadable from this file. See _EXCLUDED in states.json.")

    validate_filters(headers, cfg)
    before = len(rows)
    rows = [r for r in rows if passes_filters(r, cfg)]
    if len(rows) != before:
        print(f"  row_filter     {before:,} -> {len(rows):,} rows")
    if args.only_state:
        rc = cols.get("region") or "ST"
        rows = [r for r in rows
                if (r.get(rc) or "").strip().upper() == args.only_state.upper()]
        print(f"  --only-state   {args.only_state.upper()}: {len(rows):,} rows")

    operating = cfg.get("status_operating")
    zip_mode = cfg.get("zip_mode", "five")
    skip_hosts = {h.lower() for h in (cfg.get("skip_hosts") or [])}
    release = args.release or time.strftime("%Y-%m-%d")

    counts = {"not operating": 0, "no website": 0, "no zip": 0,
              "unusable website": 0, "sentinel host": 0, "no id": 0}
    out, hosts = [], []
    for r in rows:
        if operating and cols.get("status"):
            if (r.get(cols["status"]) or "").strip() not in operating:
                counts["not operating"] += 1
                continue
        site = (r.get(cols["website"]) or "").strip()
        if not site:
            counts["no website"] += 1
            continue
        url = lm.normalise_url(site)
        if not url:
            counts["unusable website"] += 1
            continue
        host = (urllib.parse.urlsplit(url).hostname or "").lower()
        if host in skip_hosts:
            counts["sentinel host"] += 1
            continue
        z5 = zip_of(r.get(cols["zip"]), zip_mode)
        if not z5:
            counts["no zip"] += 1
            continue
        name = (r.get(cols["name"]) or "").strip() if cols.get("name") else ""
        sid = (r.get(cols["id"]) or "").strip() if cols.get("id") else ""
        if not sid:
            # A stable per-row id is required for the upsert. Name plus ZIP is
            # deterministic, so a re-run updates the same row rather than
            # inserting a duplicate.
            #
            # WHEN THE NAME IS BLANK, FALL BACK TO THE HOST. Arizona's feature
            # service returns rows with an empty SchoolName, and "|85020" then
            # became the key for every one of them in that ZIP: 21 schools
            # collapsed onto one row, 354 distinct websites lost across the
            # state. The host is the thing a landmark actually is, it is never
            # blank here because unusable websites were already skipped, and it
            # is just as deterministic.
            #
            # Deliberately NOT adding the host to the key for named rows. That
            # would change every existing id, so the next load would insert a
            # second copy of every row beside the first. The residual cost of
            # leaving it is measured and small: Pennsylvania loses 19 websites
            # and Alabama 2, where two genuinely different institutions share a
            # name and a ZIP. report_id_collisions prints that figure on every
            # run so it stays visible rather than becoming invisible policy.
            sid = f"{name or host}|{z5}"
        if not sid.strip("|"):
            counts["no id"] += 1
            continue
        region = key
        if cols.get("region"):
            region = (r.get(cols["region"]) or key).strip() or key
        out.append(lm.build_row(
            source, sid, release, name,
            (r.get(cols["street"]) or "").strip() if cols.get("street") else "",
            (r.get(cols["city"]) or "").strip() if cols.get("city") else "",
            region, z5, url, None, None, "public school"))
        hosts.append(host)

    print(f"\n  row accounting, over the {len(rows):,} rows considered:")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        if v:
            print(f"    skipped, {k:<22}{v:>8,}")
    print(f"    usable                     {len(out):>8,}")
    total = len(out) + sum(counts.values())
    print(f"    sum                        {total:>8,}  "
          f"{'balances' if total == len(rows) else 'DOES NOT BALANCE'}")
    report_id_collisions(out)
    if not operating and cols.get("status"):
        print(f"\n  NO status_operating in the config, so every row was loaded "
              f"regardless of\n  {cols['status']}. Closed schools are INCLUDED. "
              f"Run the probe to see its values\n  and add status_operating "
              f"before trusting the count.")

    if not out:
        sys.exit("\nNothing usable to load.")

    by_host = {}
    for row, h in zip(out, hosts):
        by_host.setdefault(h, set()).add(row[7])
    one = sum(1 for z in by_host.values() if len(z) == 1)
    shared = sum(1 for h in hosts if len(by_host[h]) > 1)
    zips = {r[7] for r in out if r[7]}
    print(f"\n  distinct website hosts       {len(by_host):>8,}")
    print(f"    hosts serving ONE ZIP      {one:>8,}")
    print(f"    hosts serving many ZIPs    {len(by_host) - one:>8,}")
    print(f"  distinct 5-digit ZIPs        {len(zips):>8,}")
    print(f"  rows on a shared host        {shared:>8,}  "
          f"({100.0 * shared / len(out):.1f}% of usable)")
    top = sorted(by_host.items(), key=lambda kv: -len(kv[1]))[:5]
    if top and len(top[0][1]) > 1:
        print("  most fanned-out hosts, which node_fanout will reject:")
        for h, zs in top:
            print(f"    {h[:52]:<54}{len(zs):>6} ZIPs")

    if args.dry_run:
        print("\n  Dry run: nothing written, no database connection made.")
        print(f"  Re-run without --dry-run to load these {len(out):,} rows.")
        return

    lm.require_table()
    lm.load_rows(source, out, replace=args.replace)
    print("\n  Loaded. Run the enrichment chain ONCE after every jurisdiction "
          "is in, not per\n  state: each step costs a whole-table scan, so "
          "fifty separate passes is about\n  fifty-seven hours against about "
          "one.")


if __name__ == "__main__":
    main()
