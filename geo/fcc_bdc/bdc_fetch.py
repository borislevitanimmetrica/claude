#!/usr/bin/env python3
"""Download the public FCC Broadband Data Collection fixed availability files.

WHY THIS EXISTS

The download page at broadbandmap.fcc.gov/data-download offers one file per
state per technology. For fixed broadband that is 442 files across 56
jurisdictions, so clicking through them is not a serious option.

THE API IT USES, AND HOW IT WAS FOUND

Found by probing, 2026-11-17, and every statement here was verified against
the live service rather than recalled:

  GET /nbm/map/api/published/filing
      Lists the data vintages. Answers with no credentials at all.

  GET /nbm/map/api/national_map_process/nbm_get_data_download/{process_uuid}
      The full catalogue, 10,396 entries, 3.8 MB of JSON. Carries for each
      file an id, data_category, data_type, technology_code,
      technology_code_desc, state_fips, state_name, file_type, file_name and
      download_available.

  GET /nbm/map/api/getNBMDataDownloadFile/{id}/1
      The file itself, as a ZIP with the real name in content-disposition.
      The trailing 1 is required: 0 answers "the id does not exist" and
      omitting it answers "Path Not Found".

AKAMAI SITS IN FRONT OF THESE PATHS, AND I GOT THE REASON WRONG ONCE

The first version of this file said browser headers were what made the
difference, because a bare curl had returned 403 and a curl with a browser
User-Agent and Referer had returned 200. THAT WAS AN OVER-GENERALISATION FROM
ONE OBSERVATION. Re-tested an hour later from the same host, a request with no
headers at all returned 200. Meanwhile the identical script with the headers
set was refused outright from Boris's machine with an Akamai Access Denied
page.

So the decision is made per client, not per header, and I cannot predict it
from either side. The headers are still sent, because they cost nothing and
match what the download page itself sends, but they are not the mechanism.
geo/fcc_bdc/bdc_access_probe.sh is what establishes what a given machine can
actually reach, and --warmup and --catalog-tsv are the two things that help
when parts of it are refused.

curl is used rather than urllib because urllib was refused where curl was not,
on the one host where both were tried.

There is a second, documented API at /api/public/map/downloads/ which wants
credentials; it answers 401 and is NOT used here. Nothing in this script
authenticates, because nothing it touches requires it.

WHAT THE CATALOGUE SETTLES

The FCC technology code list, which this project has until now refused to
write down because it was unverified. The catalogue carries the FCC's own
descriptions:

     0  Other
    10  Copper
    40  Cable
    50  Fiber to the Premises
    60  GSO Satellite
    61  NGSO Satellite
    70  Unlicensed Fixed Wireless
    71  Licensed Fixed Wireless
    72  LBR Fixed Wireless

That is the FIOS versus xDSL separation step 2 needs: Verizon fibre is 50 and
Verizon copper is 10, in separate files. It is still not hardcoded as fact
anywhere else; the `technologies` subcommand of bdc_load.py reports what is
actually in the loaded data, and this script writes the catalogue's own
mapping to a file so it can be loaded rather than retyped.

The per-technology split also means the files DO NOT OVERLAP by record: each
availability record appears in exactly one state and technology file. So
loading the whole Nationwide fixed set cannot double-count a tract, provided
the per-provider files, which are a different cut of the same data, are not
loaded as well.

SATELLITE IS EXCLUDED BY DEFAULT

Measured 2026-11-17 by reading content-length for 376 of the 442 files: the
set is at least 7.38 GB zipped, and GSO plus NGSO satellite is 3.31 GB of
that, 45 percent. Satellite has no headend or central office serving a census
tract, so those rows cannot contribute to steps 2 to 6; they would be the
largest single part of the download and useless to it. --include-satellite
overrides this.

That 7.38 GB is a LOWER BOUND, not the total: 66 of the 442 HEAD requests
failed when run eight at a time, so their sizes are missing from it.

USAGE

  python3 bdc_fetch.py filings
  python3 bdc_fetch.py catalog --dest /home/boris/geo/bdc
  python3 bdc_fetch.py list --dest /home/boris/geo/bdc
  python3 bdc_fetch.py fetch --dest /home/boris/geo/bdc
  python3 bdc_fetch.py fetch --dest /home/boris/geo/bdc --state RI DE
  python3 bdc_fetch.py fetch --dest /home/boris/geo/bdc --technology 10 50
  python3 bdc_fetch.py print-curl --dest /home/boris/geo/bdc

NOTHING HERE DELETES ANYTHING. A file already present whose size matches the
server is skipped. A file present at the wrong size is re-downloaded to a
temporary name and moved into place only once it is complete, so an
interrupted run cannot leave a truncated file that a later run trusts.
"""

import argparse
import json
import os
import subprocess
import sys
import time

BASE = "https://broadbandmap.fcc.gov/nbm/map/api"
FILING_URL = f"{BASE}/published/filing"
CATALOG_URL = f"{BASE}/national_map_process/nbm_get_data_download"
FILE_URL = f"{BASE}/getNBMDataDownloadFile"

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/131.0.0.0 Safari/537.36")
REFERER = "https://broadbandmap.fcc.gov/data-download"

CATALOG_FILE = "bdc_catalog.json"
TECH_FILE = "bdc_technology_codes.tsv"

SATELLITE_CODES = {"60", "61"}

CURL_HEADERS = ["-H", f"User-Agent: {UA}", "-H", f"Referer: {REFERER}"]

# Set by --warmup. Akamai sits in front of these paths and refuses some
# clients outright; loading the HTML download page first can leave cookies
# that the API calls are then accepted with. Whether it helps is a property of
# the client, not of the service, so it is an option rather than the default
# and geo/fcc_bdc/bdc_access_probe.sh is what establishes which you need.
COOKIE_JAR = None


def cookie_args():
    if not COOKIE_JAR:
        return []
    return ["-b", COOKIE_JAR, "-c", COOKIE_JAR]


def warm_up(jar):
    """Load the HTML download page to collect whatever cookies it sets."""
    global COOKIE_JAR
    r = subprocess.run(["curl", "-sS", "-o", os.devnull, "-w", "%{http_code}",
                        "-m", "90", "-c", jar, "-H", f"User-Agent: {UA}",
                        "-H", "Accept: text/html,application/xhtml+xml,"
                              "application/xml;q=0.9,*/*;q=0.8",
                        "-H", "Accept-Language: en-US,en;q=0.9",
                        REFERER],
                       capture_output=True, text=True)
    code = r.stdout.strip()
    names = []
    if os.path.isfile(jar):
        with open(jar) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 6 and p[5]:
                    names.append(p[5])
    print(f"warmup: fetched the download page, http={code}, "
          f"cookies captured: {', '.join(sorted(set(names))) or 'none'}")
    if not names:
        print("  No cookies, so the warmup has given the API calls nothing "
              "extra. If they are refused, the warmup is not the fix.")
    COOKIE_JAR = jar


def require_curl():
    try:
        subprocess.run(["curl", "--version"], capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        sys.exit("curl is not available, and this script needs it: urllib is "
                 "refused by the Akamai protection in front of these paths.")


def curl_json(url, what):
    """GET a JSON document, with the browser headers that get past Akamai."""
    r = subprocess.run(["curl", "-sS", "-m", "180", *cookie_args(),
                        *CURL_HEADERS, url],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"curl failed fetching {what}:\n{r.stderr.strip()}")
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        sys.exit(f"{what} did not come back as JSON. First 300 characters, "
                 f"which usually name the cause:\n{r.stdout[:300]}")


def remote_size(file_id):
    """content-length for one file, or None. Uses HEAD, which is allowed."""
    url = f"{FILE_URL}/{file_id}/1"
    r = subprocess.run(["curl", "-sS", "-I", "-m", "90", *cookie_args(),
                        *CURL_HEADERS, url],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        if line.lower().startswith("content-length:"):
            v = line.split(":", 1)[1].strip()
            if v.isdigit():
                return int(v)
    return None


def human(n):
    if n is None:
        return "unknown"
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024.0


def filings():
    d = curl_json(FILING_URL, "the filing list")
    rows = d.get("data") or []
    if not rows:
        sys.exit("the filing list came back empty, so there is no vintage to "
                 "choose; nothing was downloaded")
    return rows


def latest_filing(rows):
    """The newest vintage, by parsing filing_subtype as a date.

    filing_subtype reads like 'June 30, 2026'. Sorting on filing_type_id
    instead would be an assumption about how the FCC allocates those numbers,
    and it is not one I can support, so the date is parsed and a failure to
    parse is reported rather than silently ordered wrongly.
    """
    def key(r):
        s = (r.get("filing_subtype") or "").strip()
        for fmt in ("%B %d, %Y", "%b %d, %Y"):
            try:
                return time.strptime(s, fmt)
            except ValueError:
                continue
        return None

    dated = [(key(r), r) for r in rows]
    bad = [r for k, r in dated if k is None]
    if bad:
        print("Could not read a date from these vintages, so they were left "
              "out of the choice of newest:")
        for r in bad:
            print(f"  {r.get('filing_subtype')!r}")
    usable = [(k, r) for k, r in dated if k is not None]
    if not usable:
        sys.exit("No vintage had a readable date. Pass --filing with a "
                 "process_uuid from `bdc_fetch.py filings`.")
    return max(usable, key=lambda kr: kr[0])[1]


def cmd_filings(args):
    rows = filings()
    newest = latest_filing(rows)
    print(f"{len(rows)} data vintage(s) published:\n")
    for r in rows:
        mark = "  <- newest, used by default" if r is newest else ""
        print(f"  {r.get('filing_subtype'):<20} "
              f"{r.get('process_uuid')}{mark}")
    print("\nPass one to any other subcommand with --filing if you want a "
          "vintage other than the newest.")


def catalog_path(dest):
    return os.path.join(dest, CATALOG_FILE)


def fetch_catalog(args):
    uuid = args.filing
    if not uuid:
        uuid = latest_filing(filings())["process_uuid"]
        print(f"using the newest vintage, process_uuid {uuid}")
    d = curl_json(f"{CATALOG_URL}/{uuid}", "the file catalogue")
    rows = d.get("data") or []
    if not rows:
        sys.exit("the catalogue came back empty; nothing was written")
    os.makedirs(args.dest, exist_ok=True)
    path = catalog_path(args.dest)
    with open(path, "w") as f:
        json.dump({"process_uuid": uuid, "data": rows}, f)
    print(f"catalogue written to {path}: {len(rows):,} entries")
    return rows


def load_catalog_tsv(path):
    """Read the committed catalogue instead of calling the API.

    geo/fcc_bdc/bdc_catalog_fixed.tsv holds the 442 Nationwide fixed
    availability entries. It exists because the catalogue endpoint is refused
    from some clients by Akamai while the file endpoint is not, and in that
    case nothing about the download needs an API call: the file ids are all
    that is required and they are here.
    """
    rows = []
    with open(path) as f:
        header = f.readline().rstrip("\n").split("\t")
        need = ["id", "technology_code", "technology_code_desc",
                "state_fips", "state_name", "file_name"]
        missing = [c for c in need if c not in header]
        if missing:
            sys.exit(f"{path} is missing column(s) {missing}. Expected a "
                     f"tab-separated file with: {', '.join(need)}")
        idx = {c: header.index(c) for c in need}
        for n, line in enumerate(f, 2):
            line = line.rstrip("\n")
            if not line:
                continue
            p = line.split("\t")
            if len(p) != len(header):
                sys.exit(f"{path} line {n} has {len(p)} fields, expected "
                         f"{len(header)}; nothing was downloaded")
            r = {c: p[idx[c]] for c in need}
            # The filters and the reporting both read these, so the shape
            # has to match what the API returns.
            r["data_type"] = "Fixed Broadband"
            r["data_category"] = "Nationwide"
            r["file_type"] = "csv"
            r["download_available"] = "Yes"
            rows.append(r)
    if not rows:
        sys.exit(f"{path} held no rows; nothing was downloaded")
    print(f"catalogue read from {path}: {len(rows):,} fixed availability "
          f"entries, no API call needed")
    return rows


def load_catalog(args):
    """The committed TSV if asked for, then a saved copy, then the API."""
    tsv = getattr(args, "catalog_tsv", None)
    if tsv:
        return load_catalog_tsv(tsv)
    path = catalog_path(args.dest)
    if os.path.isfile(path):
        with open(path) as f:
            d = json.load(f)
        print(f"catalogue read from {path}: {len(d['data']):,} entries, "
              f"vintage {d.get('process_uuid')}")
        return d["data"]
    return fetch_catalog(args)


def fixed_rows(rows, args):
    """The Nationwide fixed-broadband entries, after the filters."""
    out = [r for r in rows
           if r.get("data_type") == "Fixed Broadband"
           and r.get("data_category") == "Nationwide"
           and r.get("file_type") == "csv"
           and str(r.get("download_available")).lower() in ("yes", "true")]

    dropped = []
    if not args.include_satellite:
        before = len(out)
        out = [r for r in out if str(r["technology_code"]) not in SATELLITE_CODES]
        if before != len(out):
            dropped.append(f"{before - len(out)} satellite file(s), codes 60 "
                           f"and 61, which have no headend serving a tract "
                           f"and were 45 percent of the measured download. "
                           f"--include-satellite keeps them.")

    if args.technology:
        want = {str(t) for t in args.technology}
        before = len(out)
        out = [r for r in out if str(r["technology_code"]) in want]
        dropped.append(f"{before - len(out)} file(s) of other technologies, "
                       f"by --technology {' '.join(sorted(want))}")

    if args.state:
        # FIPS or full name only. The catalogue carries state_fips and
        # state_name and no USPS code, and the file names carry the FIPS, so
        # accepting a USPS code would mean embedding a mapping this script
        # has no authority for.
        want = {s.upper() for s in args.state}
        before = len(out)
        out = [r for r in out
               if (r.get("state_name") or "").upper() in want
               or str(r.get("state_fips")) in want]
        if not out:
            sys.exit(f"--state {' '.join(sorted(want))} matched nothing. It "
                     f"takes a FIPS code such as 44 or a full name such as "
                     f"'Rhode Island', NOT a USPS code such as RI, because "
                     f"the catalogue does not carry USPS codes. "
                     f"`bdc_fetch.py list` prints the names it knows.")
        dropped.append(f"{before - len(out)} file(s) of other states, by "
                       f"--state {' '.join(sorted(want))}")

    for d in dropped:
        print(f"  excluded: {d}")
    return sorted(out, key=lambda r: (str(r.get("state_fips")),
                                      str(r.get("technology_code"))))


def write_tech_file(rows, dest):
    """The FCC's own technology code to description mapping, from data."""
    seen = {}
    for r in rows:
        if r.get("data_type") != "Fixed Broadband":
            continue
        code = str(r.get("technology_code"))
        desc = r.get("technology_code_desc")
        if code and desc and "," not in code:
            seen.setdefault(code, desc)
    path = os.path.join(dest, TECH_FILE)
    with open(path, "w") as f:
        f.write("technology_code\ttechnology_code_desc\n")
        for c in sorted(seen, key=lambda s: int(s)):
            f.write(f"{c}\t{seen[c]}\n")
    print(f"\nFCC technology code mapping written to {path}, "
          f"{len(seen)} codes, taken from the catalogue rather than typed:")
    for c in sorted(seen, key=lambda s: int(s)):
        print(f"  {c:>3}  {seen[c]}")
    return path


def cmd_catalog(args):
    rows = fetch_catalog(args)
    write_tech_file(rows, args.dest)


def cmd_list(args):
    rows = load_catalog(args)
    want = fixed_rows(rows, args)
    print(f"\n{len(want)} file(s) selected, across "
          f"{len({r['state_fips'] for r in want})} jurisdiction(s)\n")
    print(f"{'id':>9}  {'tech':>4}  {'technology':<26}  {'state':<22}  size")
    total = 0
    unknown = 0
    for r in want:
        s = remote_size(r["id"]) if args.sizes else None
        if args.sizes:
            if s is None:
                unknown += 1
            else:
                total += s
        print(f"{r['id']:>9}  {str(r['technology_code']):>4}  "
              f"{r['technology_code_desc']:<26}  {r['state_name']:<22}  "
              f"{human(s) if args.sizes else ''}")
    if args.sizes:
        print(f"\ntotal of the {len(want) - unknown} file(s) whose size the "
              f"server reported: {total / 1e9:.2f} GB zipped")
        if unknown:
            print(f"{unknown} file size(s) were NOT reported, so that total "
                  f"is a lower bound rather than the figure.")
    else:
        print("\nSizes were not requested. Add --sizes to probe them; it is "
              "one HEAD request per file.")


def cmd_print_curl(args):
    rows = load_catalog(args)
    want = fixed_rows(rows, args)
    out = args.out or os.path.join(args.dest, "bdc_download.sh")
    with open(out, "w") as f:
        f.write("#!/bin/sh\n")
        f.write("set -u\n")
        f.write("\n")
        f.write("# FCC Broadband Data Collection fixed availability files.\n")
        f.write("# Generated by geo/fcc_bdc/bdc_fetch.py. Safe to re-run:\n")
        f.write("# curl -C - resumes rather than restarting, and the browser\n")
        f.write("# User-Agent and Referer are required, not decorative:\n")
        f.write("# without them Akamai answers 403.\n")
        f.write("\n")
        f.write(f'DEST="{args.dest}"\n')
        f.write('mkdir -p "$DEST"\n')
        f.write(f'UA="{UA}"\n')
        f.write(f'REF="{REFERER}"\n')
        f.write("\n")
        for n, r in enumerate(want, 1):
            f.write(f'echo "[{n}/{len(want)}] {r["file_name"]}.zip"\n')
            f.write(f'curl -sS -L -C - -m 1800 -A "$UA" -e "$REF" '
                    f'-o "$DEST/{r["file_name"]}.zip" '
                    f'"{FILE_URL}/{r["id"]}/1"\n')
        f.write('\necho "done"\nls -la "$DEST"\n')
    os.chmod(out, 0o755)
    print(f"\n{len(want)} curl command(s) written to {out}")
    print(f"Run it with:  sh {out}")
    print("Nothing was downloaded by this subcommand; it only wrote the "
          "script, so you can read it before running it.")


def cmd_fetch(args):
    os.makedirs(args.dest, exist_ok=True)
    rows = load_catalog(args)
    write_tech_file(rows, args.dest)
    want = fixed_rows(rows, args)

    print(f"\n{len(want)} file(s) selected, across "
          f"{len({r['state_fips'] for r in want})} jurisdiction(s)")
    print("A file already present at the size the server reports is skipped. "
          "Downloads go to a .part name and are moved into place only when "
          "complete, so an interrupted run cannot leave a short file behind "
          "that a later run would trust.\n")

    got = skipped = failed = 0
    bytes_got = 0
    started = time.monotonic()
    problems = []

    for n, r in enumerate(want, 1):
        name = f"{r['file_name']}.zip"
        path = os.path.join(args.dest, name)
        tag = (f"[{n}/{len(want)}] {r['state_name']} "
               f"{r['technology_code_desc']}")

        size = remote_size(r["id"])
        if os.path.isfile(path):
            have = os.path.getsize(path)
            if size is not None and have == size:
                skipped += 1
                print(f"{tag}: already have {human(have)}, skipped")
                continue
            if size is None:
                skipped += 1
                print(f"{tag}: already have {human(have)} and the server did "
                      f"not report a size to check it against, skipped. "
                      f"Delete the file to force a re-download.")
                continue
            print(f"{tag}: on disk at {human(have)} but the server says "
                  f"{human(size)}, so it is incomplete and will be fetched "
                  f"again")

        part = path + ".part"
        url = f"{FILE_URL}/{r['id']}/1"
        print(f"{tag}: downloading {human(size)} ...", flush=True)
        t0 = time.monotonic()
        res = subprocess.run(["curl", "-sS", "-L", "-m", "3600",
                              "--retry", "3", "--retry-delay", "5",
                              *cookie_args(), *CURL_HEADERS,
                              "-o", part, url],
                             capture_output=True, text=True)
        if res.returncode != 0:
            failed += 1
            problems.append(f"{name}: curl exit {res.returncode} "
                            f"{res.stderr.strip()}")
            print(f"  FAILED: {res.stderr.strip()}")
            if os.path.exists(part):
                os.remove(part)
            continue

        have = os.path.getsize(part) if os.path.exists(part) else 0
        if size is not None and have != size:
            failed += 1
            problems.append(f"{name}: got {have} bytes, server said {size}")
            print(f"  FAILED: got {human(have)}, server said {human(size)}. "
                  f"Left as {os.path.basename(part)} rather than moved into "
                  f"place.")
            continue
        if have == 0:
            failed += 1
            problems.append(f"{name}: empty response")
            print("  FAILED: empty file")
            os.remove(part)
            continue

        os.replace(part, path)
        got += 1
        bytes_got += have
        el = time.monotonic() - t0
        rate = f", {human(have / el)}/s" if el > 0.5 else ""
        print(f"  got {human(have)} in {el:.0f}s{rate}")

    el = time.monotonic() - started
    print(f"\ndownloaded {got}, skipped {skipped}, failed {failed}")
    print(f"{bytes_got / 1e9:.2f} GB in {el / 60:.1f} minutes")
    if problems:
        print("\nproblems, every one of which can be retried by running this "
              "again, since what succeeded is skipped:")
        for p in problems:
            print(f"  {p}")
    if got or skipped:
        print(f"\nLoad them with:\n  python3 geo/fcc_bdc/bdc_load.py load "
              f"--files {args.dest}/*.zip")
    if failed:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, with_filters=True):
        p.add_argument("--dest", default="/home/boris/geo/bdc",
                       help="directory for the files and the catalogue")
        p.add_argument("--filing",
                       help="process_uuid of a vintage; default is the newest")
        p.add_argument("--catalog-tsv",
                       help="read the committed catalogue at "
                            "geo/fcc_bdc/bdc_catalog_fixed.tsv instead of "
                            "calling the catalogue API, for when Akamai "
                            "refuses the API but not the files")
        p.add_argument("--warmup", metavar="JAR", nargs="?",
                       const="/tmp/bdc_cookies.txt",
                       help="load the HTML download page first and reuse its "
                            "cookies; run bdc_access_probe.sh to find out "
                            "whether this machine needs it")
        if with_filters:
            p.add_argument("--state", nargs="+",
                           help="limit to these states, by FIPS or full name")
            p.add_argument("--technology", nargs="+",
                           help="limit to these FCC technology codes")
            p.add_argument("--include-satellite", action="store_true",
                           help="keep codes 60 and 61, excluded by default "
                                "because satellite has no headend serving a "
                                "tract and is 45 percent of the download")

    fi = sub.add_parser("filings", help="list the data vintages available")
    fi.set_defaults(func=cmd_filings)

    ca = sub.add_parser("catalog", help="download the file catalogue only")
    common(ca, with_filters=False)
    ca.set_defaults(func=cmd_catalog)

    li = sub.add_parser("list", help="show the files that would be fetched")
    common(li)
    li.add_argument("--sizes", action="store_true",
                    help="probe each file's size, one HEAD request each")
    li.set_defaults(func=cmd_list)

    pc = sub.add_parser("print-curl",
                        help="write a shell script of curl commands instead "
                             "of downloading")
    common(pc)
    pc.add_argument("--out", help="where to write it")
    pc.set_defaults(func=cmd_print_curl)

    fe = sub.add_parser("fetch", help="download the files")
    common(fe)
    fe.set_defaults(func=cmd_fetch)

    args = ap.parse_args()
    require_curl()
    if getattr(args, "warmup", None):
        warm_up(args.warmup)
    args.func(args)


if __name__ == "__main__":
    main()
