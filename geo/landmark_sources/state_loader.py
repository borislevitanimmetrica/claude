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


def fetch(url, timeout=300):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/csv,text/plain,application/json,application/octet-stream,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


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
        feats = doc.get("features") or []
        if not feats:
            sys.exit("JSON parsed but carries no features. For an ArcGIS "
                     "endpoint check the where clause, returnGeometry=false "
                     "and f=json.")
        keys = []
        for f in feats:
            for k in (f.get("attributes") or {}):
                if k not in keys:
                    keys.append(k)
        grid = [keys]
        for f in feats:
            a = f.get("attributes") or {}
            grid.append(["" if a.get(k) is None else str(a.get(k)) for k in keys])
        print("  format         ArcGIS FeatureServer JSON, attributes only")
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


def resolve_columns(headers, cfg):
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
            out[role] = probe.prefer(cands, "school") if cands else None
    return out


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
            how = "url" if v.get("url") else "needs --input"
            print(f"  {k:<6}{v['source']:<16}{how}")
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
    elif cfg.get("url"):
        print(f"  fetching       {cfg['url'][:96]}")
        try:
            raw = fetch(cfg["url"])
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

    cols = resolve_columns(headers, cfg)
    for role in ("name", "zip", "website", "status"):
        print(f"  {role:<14} {cols.get(role) or '(none)'}")
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
            sid = f"{name}|{z5}"
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
