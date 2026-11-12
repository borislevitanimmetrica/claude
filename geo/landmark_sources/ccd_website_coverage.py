#!/usr/bin/env python3
"""Measure the federal CCD directory's WEBSITE column, per state.

WHY THIS MATTERS MORE THAN ANY STATE FILE.

The project's recorded belief, carried from Session 3, is that the federal CCD
release "publishes no website at all, so CCD cannot anchor a landmark by
itself". That is why fifty state directories were being collected one at a
time. The 2023-24 CCD directory file does carry a WEBSITE column, so the belief
is wrong, and the question becomes how much of it is populated and whether the
values are per-school or one district URL stamped on every row.

That second question is the one that decides everything. A WEBSITE column full
of district URLs is worth nothing to us, because node_fanout.sql rejects an
address whose landmark places occupy disjoint ZIP clusters -- correctly, since
one building cannot be on the premises of schools in forty ZIPs. So this counts
BOTH the fill rate AND the host concentration, per state.

It reads LZIP, the physical ZIP, not MZIP. Those are CCD's location and mailing
columns, and the mailing one is wrong for a landmark: on the Virgin Islands
extract the mailing column gives 2 distinct ZIPs where the physical gives 5.

Counts are taken over ONE population per figure and the populations are named,
because reporting three numbers over three different row sets is how an earlier
pass produced 8,940 / 1,673 / 5,237 against a true 8,816 / 1,367 / 5,165.
"""
import collections
import csv
import io
import re
import sys
import zipfile

ZIPFILE = sys.argv[1] if len(sys.argv) > 1 else "ccd_sch_029_2324_national.zip"

PLACEHOLDER_SHARE = 50.0


def looks_like_host(v):
    v = (v or "").strip().strip('"').lower()
    if not v or v in ("no data", "n/a", "none", "null", "-", "not applicable"):
        return False
    v = v.split("://")[-1].split("/")[0].split("?")[0].split(":")[0]
    return bool(re.match(r"^(?=.*\.)[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$", v))


def host_of(v):
    v = (v or "").strip().strip('"').lower()
    return v.split("://")[-1].split("/")[0].split(":")[0]


def zip5(v):
    v = (v or "").strip()
    m = re.search(r"\b(\d{5})\b", v)
    if m:
        return m.group(1)
    m = re.search(r"\b(\d{9})\b", v)
    return m.group(1)[:5] if m else None


z = zipfile.ZipFile(ZIPFILE)
name = [n for n in z.namelist() if n.endswith(".csv")][0]
text = z.read(name).decode("utf-8-sig", errors="replace")
rows = list(csv.DictReader(io.StringIO(text)))
print(f"{name}: {len(rows):,} rows")
hdr = rows[0].keys()
for c in ("ST", "SCH_NAME", "WEBSITE", "LZIP", "MZIP", "SY_STATUS_TEXT", "NCESSCH"):
    print(f"  {c:<16}{'present' if c in hdr else 'MISSING'}")
print()

# One population for the whole report: schools CCD itself calls operational.
OPEN_TEXT = ("open",)
by_state = collections.defaultdict(lambda: {
    "rows": 0, "open": 0, "web": 0, "zip": 0, "both": 0,
    "hosts": collections.Counter(), "zips": set()})

status_vocab = collections.Counter()
for r in rows:
    st = (r.get("ST") or "??").strip().upper()
    d = by_state[st]
    d["rows"] += 1
    stat = (r.get("SY_STATUS_TEXT") or "").strip().lower()
    status_vocab[stat] += 1
    if not any(stat.startswith(o) for o in OPEN_TEXT):
        continue
    d["open"] += 1
    w = looks_like_host(r.get("WEBSITE"))
    zp = zip5(r.get("LZIP"))
    if w:
        d["web"] += 1
    if zp:
        d["zip"] += 1
    if w and zp:
        d["both"] += 1
        d["hosts"][host_of(r.get("WEBSITE"))] += 1
        d["zips"].add(zp)

print("SY_STATUS_TEXT vocabulary over all rows:")
for v, n in status_vocab.most_common(10):
    print(f"  {v[:34]:<36}{n:>8,}")
print()
print("Population below: SY_STATUS_TEXT starting 'open'. ZIP is LZIP (physical).")
print()
print(f"{'ST':<4}{'open':>8}{'web':>8}{'both':>8}{'ZIPs':>7}{'hosts':>7}"
      f"{'1-row':>7}{'top host share':>15}  verdict")
print("-" * 86)

totals = collections.Counter()
usable_states, placeholder_states, empty_states = [], [], []
for st in sorted(by_state):
    d = by_state[st]
    if not d["open"]:
        continue
    hosts = d["hosts"]
    single = sum(1 for n in hosts.values() if n == 1)
    share = (100.0 * max(hosts.values()) / d["both"]) if d["both"] else 0.0
    if d["both"] == 0:
        verdict = "NO WEBSITE"
        empty_states.append(st)
    elif share >= PLACEHOLDER_SHARE:
        verdict = f"PLACEHOLDER {list(hosts.most_common(1))[0][0][:22]}"
        placeholder_states.append(st)
    else:
        verdict = "usable"
        usable_states.append(st)
    print(f"{st:<4}{d['open']:>8,}{d['web']:>8,}{d['both']:>8,}"
          f"{len(d['zips']):>7,}{len(hosts):>7,}{single:>7,}{share:>14.1f}%  {verdict}")
    totals["open"] += d["open"]
    totals["web"] += d["web"]
    totals["both"] += d["both"]

print("-" * 86)
print(f"{'US':<4}{totals['open']:>8,}{totals['web']:>8,}{totals['both']:>8,}")
print()
print(f"national fill rate, website on an open school   "
      f"{100.0 * totals['web'] / max(1, totals['open']):.1f}%")
print(f"national, website AND physical ZIP              "
      f"{100.0 * totals['both'] / max(1, totals['open']):.1f}%")
print()
print(f"states with a usable per-school website column   {len(usable_states):>3}  "
      f"{' '.join(usable_states)}")
print(f"states where one host dominates (placeholder)    {len(placeholder_states):>3}  "
      f"{' '.join(placeholder_states)}")
print(f"states with no website at all                    {len(empty_states):>3}  "
      f"{' '.join(empty_states)}")

all_zips = set()
for d in by_state.values():
    all_zips |= d["zips"]
print()
print(f"distinct physical ZIPs across all states whose column is not a "
      f"placeholder: {len({z for st in usable_states for z in by_state[st]['zips']}):,}")
print(f"distinct physical ZIPs across every state regardless: {len(all_zips):,}")
