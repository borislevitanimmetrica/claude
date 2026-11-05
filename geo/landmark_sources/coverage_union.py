#!/usr/bin/env python3
"""What ZIP coverage do CCD and the state files give, separately and together?

The two sources are complementary and neither dominates. CCD's WEBSITE column
is empty for eleven jurisdictions that DO publish a website in their own file
(Indiana, South Carolina, West Virginia, Hawaii and Rhode Island among them),
and conversely CCD covers forty-three states in a single download including
several whose own file publishes nothing.

This reuses probe_state_files.py's own role detection rather than
reimplementing it, so the numbers here and the probe's agree by construction.

It reports, per jurisdiction: ZIPs from CCD, ZIPs from the state file, the
union, and which source wins. The union is the number that matters, because a
ZIP covered by either source is covered.

IT IS A CEILING, NOT A FORECAST. Every ZIP here is a ZIP where some school
publishes a website. It becomes a landmark only after the host resolves to an
address, the address survives node_fanout.sql, and the hosting rule and the
on-premises rules accept it. California measured 1,367 ZIPs at this stage and
94 genuinely new ones at the end, so the attrition is heavy and uneven.
"""
import collections
import csv
import importlib.util
import io
import os
import re
import sys
import zipfile

PROBE = "/projects/sandbox/claude/geo/landmark_sources/probe_state_files.py"
spec = importlib.util.spec_from_file_location("probe", PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

# state code -> file, for every file that probed USABLE with a real website
# column. Files whose website column the probe flagged as a placeholder (one
# host over half the rows) are deliberately excluded and listed at the end.
STATE_FILES = {
    "AL": "al.csv", "AR": "ar.xlsx", "AZ": "az.csv", "DC": "dc.csv",
    "FL": "fl.txt", "GA": "ga.csv", "HI": "hi.csv", "IA": "ia.xlsx",
    "IL": "il.xlsx", "IN": "in.xlsx", "KS": "ks.tsv", "MN": "mn.csv",
    "NC": "nc.csv", "ND": "nd.csv", "NV": "nv.xlsx", "OH": "oh.csv",
    "PA": "pa.csv", "RI": "ri.csv", "SC": "sc.csv", "TN": "tn.csv",
    "TX": "tx.csv", "UT": "ut.csv", "WI": "wi.csv", "WV": "wv.csv",
}
PLACEHOLDER_FILES = {"NJ": "nj.csv (facebook.com on every row)",
                     "VA": "va.csv (one VDOE directory URL on every row)",
                     "OR": "or.xlsx (one row only)"}
NO_WEBSITE_FILES = "AK CO CT DE ID KY LA MA MD ME MI MO MS MT NE SD VT WA"


def read_any(path):
    raw = open(path, "rb").read()
    if raw[:4] == probe.XLSX_MAGIC:
        _, _, grid = probe.read_xlsx(raw, None)
        grid, _ = probe.rectangularize(grid)
    else:
        text = raw.decode("utf-8-sig", errors="replace")
        low = text[:6000].lower()
        if "<html" in low or "<!doctype" in low:
            grid = probe.read_html_table(text)
            grid, _ = probe.rectangularize(grid)
        else:
            delim = probe.sniff_delimiter(text[:6000])
            grid, _, _, _ = probe.parse_delimited(text, delim)
    grid, _ = probe.strip_banner_rows(grid)
    if len(grid) < 2:
        return [], []
    return probe.rows_to_dicts(grid)


def pairs_from(path, level="school"):
    """-> set of (zip5, host) for rows carrying both."""
    headers, rows = read_any(path)
    if not rows:
        return set()
    roles = probe.classify_headers(list(headers))
    if roles.get("name") and roles.get("ncesid"):
        t = [h for h in roles["name"] if h not in set(roles["ncesid"])]
        if t:
            roles["name"] = t
    from_content = False
    zc = probe.winnow(roles.get("zip") or [], rows, probe.looks_like_zip)
    wc = probe.winnow(roles.get("website") or [], rows, probe.looks_like_url)
    zcol = probe.prefer(zc, level)
    wcol = probe.prefer(wc, level)
    if not zcol:
        best, bn = None, 0
        for h in headers:
            n = sum(1 for r in rows if probe.looks_like_zip(r.get(h)))
            if n > bn:
                best, bn = h, n
        zcol, from_content = best, True
    if not wcol:
        best, bn = None, 0
        for h in headers:
            n = sum(1 for r in rows if probe.looks_like_hostname(r.get(h)))
            if n > bn:
                best, bn = h, n
        wcol = best
    if not zcol or not wcol:
        return set()
    out = set()
    for r in rows:
        if not probe.looks_like_url(r.get(wcol)):
            continue
        v = r.get(zcol) or ""
        hits = re.findall(r"\b(\d{5})\b", v)
        if hits:
            z = hits[-1] if from_content else hits[0]
        else:
            nine = re.findall(r"\b(\d{9})\b", v)
            if not nine:
                continue
            z = (nine[-1] if from_content else nine[0])[:5]
        h = (r.get(wcol) or "").strip().strip('"').lower()
        h = h.split("://")[-1].split("/")[0].split(":")[0]
        if h:
            out.add((z, h))
    return out


# ---- CCD, per state, open schools only, physical ZIP ----
z = zipfile.ZipFile("ccd_sch_029_2324_national.zip")
nm = [x for x in z.namelist() if x.endswith(".csv")][0]
ccd = collections.defaultdict(set)
for r in csv.DictReader(io.StringIO(z.read(nm).decode("utf-8-sig", errors="replace"))):
    if not (r.get("SY_STATUS_TEXT") or "").strip().lower().startswith("open"):
        continue
    if not probe.looks_like_hostname(r.get("WEBSITE")):
        continue
    zp = probe.looks_like_zip(r.get("LZIP")) and re.search(
        r"\b(\d{5})\b|\b(\d{9})\b", (r.get("LZIP") or "").strip())
    if not zp:
        continue
    z5 = (zp.group(1) or zp.group(2)[:5])
    h = (r.get("WEBSITE") or "").strip().lower().split("://")[-1].split("/")[0]
    ccd[(r.get("ST") or "??").strip().upper()].add((z5, h))

# Drop the three jurisdictions whose CCD column is one repeated host.
for st in ("AS", "MP", "VI"):
    ccd.pop(st, None)

print(f"{'ST':<4}{'CCD ZIPs':>10}{'file ZIPs':>11}{'union':>8}{'gain':>7}  source")
print("-" * 62)
union_all, ccd_all, file_all = set(), set(), set()
rows_out = []
for st in sorted(set(ccd) | set(STATE_FILES)):
    c = {p[0] for p in ccd.get(st, set())}
    f = set()
    path = STATE_FILES.get(st)
    if path and os.path.exists(path):
        try:
            f = {p[0] for p in pairs_from(path)}
        except Exception as exc:
            print(f"{st:<4}  state file error: {exc}")
    u = c | f
    gain = len(u) - len(c)
    src = ("both" if c and f else "CCD only" if c else "state file only")
    rows_out.append((st, len(c), len(f), len(u), gain, src))
    union_all |= {(st, x) for x in u}
    ccd_all |= {(st, x) for x in c}
    file_all |= {(st, x) for x in f}

for st, nc, nf, nu, g, src in rows_out:
    print(f"{st:<4}{nc:>10,}{nf:>11,}{nu:>8,}{g:>7,}  {src}")

print("-" * 62)
print(f"{'US':<4}{len({x for _, x in ccd_all}):>10,}"
      f"{len({x for _, x in file_all}):>11,}"
      f"{len({x for _, x in union_all}):>8,}")
print()
print(f"distinct ZIPs, CCD alone                {len({x for _, x in ccd_all}):>7,}")
print(f"distinct ZIPs, state files alone         {len({x for _, x in file_all}):>7,}")
print(f"distinct ZIPs, union                     {len({x for _, x in union_all}):>7,}")
print(f"ZIPs the state files add over CCD        "
      f"{len({x for _, x in union_all}) - len({x for _, x in ccd_all}):>7,}")
print()
print("Jurisdictions where ONLY the state file has websites:")
only = [r for r in rows_out if r[1] == 0 and r[2] > 0]
for st, nc, nf, nu, g, src in only:
    print(f"  {st}  {nf:,} ZIPs")
print()
print(f"Excluded as placeholder columns: "
      f"{', '.join(f'{k} {v}' for k, v in PLACEHOLDER_FILES.items())}")
print(f"State files with no website anywhere: {NO_WEBSITE_FILES}")
print()
print("CEILING, NOT FORECAST. California showed 1,367 ZIPs at this stage and 94")
print("genuinely new ones after resolution, fan-out and the hosting rule.")
