#!/usr/bin/env python3
"""Load FCC Broadband Data Collection public availability downloads.

WHAT THIS LOADS, AND WHY NO LICENCE IS NEEDED

The per-state fixed availability files published at
broadbandmap.fcc.gov/data-download. Boris read the real header 2026-11-12:

  frn, provider_id, brand_name, location_id, technology,
  max_advertised_download_speed, max_advertised_upload_speed, low_latency,
  business_residential_code, state_usps, block_geoid, h3_res8_id

block_geoid is present, so the census tract is its first 11 characters and the
CostQuest Fabric licence is NOT on the critical path. The Fabric adds
per-location coordinates and addresses; this plan measures from tract
centroids and does not need them.

THE HEADER IS CHECKED, NOT ASSUMED

Every file's first line is compared against that list before anything is
loaded, and a mismatch stops that file with the difference printed. The FCC
changes these formats between vintages, and a silently shifted column would
load download speeds into upload speeds without erroring.

block_geoid IS LOADED AS TEXT. The table CHECKs it against 15 digits, so a
value that lost its leading zero is rejected rather than misfiled. Verified
against the real constraint: '10010201001001' would have been filed under
state_fips 10, Delaware, instead of 01, Alabama.

THE TECHNOLOGY CODE LIST IS NOT HARDCODED

I have not verified the FCC code list, so nothing here maps a code to a name.
The `technologies` subcommand reports the codes actually present with their
brand names and row counts, which establishes the mapping from data. That is
what step 2 needs in order to separate Verizon FIOS from Verizon xDSL.

IDEMPOTENCY, AND THE ONE DESTRUCTIVE PATH

A file already loaded is SKIPPED by default; nothing is deleted and nothing is
duplicated. --replace deletes exactly that source_file's rows and loads it
again. Pre-mortem for --replace: it removes only rows whose source_file equals
the file being loaded, every one of which is re-downloadable from the FCC, and
it touches no other table. It is reported before it runs.

USAGE

  python3 bdc_load.py load --files /home/boris/geo/bdc/RI_fixed.csv
  python3 bdc_load.py load --files /home/boris/geo/bdc/*.zip
  python3 bdc_load.py load --files /home/boris/geo/bdc/RI_fixed.csv --replace
  python3 bdc_load.py technologies
  python3 bdc_load.py status

Database access is via psql only, standard library otherwise, so it uses the
same connection as your psql.
"""

import argparse
import csv
import gzip
import io
import os
import shutil
import subprocess
import sys
import time
import zipfile

EXPECTED_HEADER = [
    "frn", "provider_id", "brand_name", "location_id", "technology",
    "max_advertised_download_speed", "max_advertised_upload_speed",
    "low_latency", "business_residential_code", "state_usps",
    "block_geoid", "h3_res8_id",
]

COLS = ", ".join(EXPECTED_HEADER)


def psql(*args):
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed:\n{r.stderr.strip()}")
    return r.stdout


def psql_q(sql):
    return psql("-qtA", "-c", sql).strip()


def psql_copy(copy_sql, stream):
    """Stream stream into psql for a \\copy ... FROM STDIN.

    Streamed a megabyte at a time rather than read into memory first. The
    larger state files are hundreds of megabytes, and California and Texas
    are the ones that matter most; reading one whole would be a needless
    several-hundred-megabyte resident buffer.
    """
    cmd = ["psql", "-X", "-P", "pager=off", "-v", "ON_ERROR_STOP=1",
           "-q", "-c", copy_sql]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True)
    broke = False
    try:
        shutil.copyfileobj(stream, p.stdin, 1 << 20)
    except BrokenPipeError:
        # psql died before consuming the input; its stderr says why.
        broke = True
    try:
        p.stdin.close()
    except BrokenPipeError:
        broke = True
    err = p.stderr.read()
    rc = p.wait()
    if rc != 0 or broke:
        sys.exit(f"copy failed (psql exit {rc}):\n{err.strip()}")
    if err.strip():
        print(f"    psql said: {err.strip()}")


def lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def open_csv(path):
    """Return a text stream over the CSV inside path, whatever the wrapper."""
    low = path.lower()
    if low.endswith(".zip"):
        z = zipfile.ZipFile(path)
        inner = [n for n in z.namelist() if n.lower().endswith(".csv")]
        if not inner:
            raise ValueError(f"no .csv inside {path}: {z.namelist()[:5]}")
        if len(inner) > 1:
            print(f"    note: {len(inner)} csv files inside, using {inner[0]}")
        return io.TextIOWrapper(z.open(inner[0]), encoding="utf-8",
                                errors="replace")
    if low.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "r", encoding="utf-8", errors="replace")


def check_header(stream, path):
    """Read the header line and compare it to EXPECTED_HEADER."""
    first = stream.readline()
    if not first:
        raise ValueError("file is empty")
    got = [h.strip().lstrip("\ufeff") for h in next(csv.reader([first]), [])]
    if got == EXPECTED_HEADER:
        return
    missing = [c for c in EXPECTED_HEADER if c not in got]
    extra = [c for c in got if c not in EXPECTED_HEADER]
    order = (got != EXPECTED_HEADER and not missing and not extra)
    msg = [f"HEADER MISMATCH in {os.path.basename(path)}, NOTHING LOADED."]
    if missing:
        msg.append(f"  columns expected but absent: {missing}")
    if extra:
        msg.append(f"  columns present but unexpected: {extra}")
    if order:
        msg.append("  same columns, DIFFERENT ORDER. Loading positionally "
                   "would put values in the wrong columns.")
        msg.append(f"  expected: {EXPECTED_HEADER}")
        msg.append(f"  got:      {got}")
    msg.append("  If the FCC has changed the format, update EXPECTED_HEADER "
               "and the staging INSERT together, after reading the new spec.")
    raise ValueError("\n".join(msg))


def require_schema():
    """Fail with the fix rather than with a psql error about a missing table."""
    ok = psql_q("SELECT to_regclass('bdc_availability_tbl') IS NOT NULL")
    if ok != "t":
        sys.exit("bdc_availability_tbl does not exist. Apply the schema "
                 "first:\n  psql -X -P pager=off -f geo/fcc_bdc/schema.sql")


def cmd_load(args):
    require_schema()
    for f in args.files:
        if not os.path.isfile(f):
            sys.exit(f"not a file: {f}")

    print(f"{len(args.files)} file(s) to consider")
    total_loaded = 0
    failed = []
    for path in args.files:
        name = os.path.basename(path)
        print(f"\n{name}")
        existing = int(psql_q("SELECT count(*) FROM bdc_availability_tbl "
                              f"WHERE source_file = {lit(name)}") or 0)
        if existing and not args.replace:
            print(f"  already holds {existing:,} rows; SKIPPED. "
                  f"Use --replace to reload it.")
            continue

        try:
            stream = open_csv(path)
            check_header(stream, path)
        except (ValueError, zipfile.BadZipFile, OSError) as exc:
            # Deliberately on stdout, under this file's own heading. Sent to
            # stderr it arrived out of order in a tee'd log, printed before
            # the heading of the file it was about.
            print(f"  {exc}", flush=True)
            failed.append(name)
            continue

        if existing:
            print(f"  --replace: deleting {existing:,} existing rows for this "
                  f"file only. They are re-downloadable from the FCC and no "
                  f"other table is touched.")
            psql("-qc", "DELETE FROM bdc_availability_tbl "
                        f"WHERE source_file = {lit(name)}")

        # Staging first, and every staging column is text. Two reasons: the
        # CHECK on block_geoid reports a bad row from a table I can query
        # rather than aborting a COPY partway through with a line number and
        # no row, and source_file is set in one INSERT instead of being a
        # column the FCC file does not have.
        #
        # The staging table is a real UNLOGGED table, not a TEMP one, because
        # psql cannot take \copy data on the same stdin that carries the rest
        # of a multi-statement script, so the copy has to be its own psql
        # invocation and a TEMP table would not survive to it. One consequence
        # worth knowing: two loads must not run at the same time against the
        # same database, since they would share bdc_stage_tbl.
        started = time.monotonic()
        print("  copying into staging ...", flush=True)
        psql("-qc", "DROP TABLE IF EXISTS bdc_stage_tbl")
        psql("-qc", "CREATE UNLOGGED TABLE bdc_stage_tbl (" +
             ", ".join(f"{c} text" for c in EXPECTED_HEADER) + ")")
        copy_sql = f"\\copy bdc_stage_tbl ({COLS}) FROM STDIN WITH (FORMAT csv)"
        try:
            psql_copy(copy_sql, stream)
        finally:
            stream.close()
        staged = int(psql_q("SELECT count(*) FROM bdc_stage_tbl") or 0)
        print(f"  staged {staged:,} rows in {time.monotonic() - started:.0f}s")

        bad = int(psql_q("SELECT count(*) FROM bdc_stage_tbl "
                         "WHERE block_geoid IS NULL "
                         "OR block_geoid !~ '^[0-9]{15}$'") or 0)
        if bad:
            print(f"  {bad:,} staged row{'' if bad == 1 else 's'} ha"
                  f"{'s' if bad == 1 else 've'} a block_geoid that is not 15 "
                  f"digits and will NOT be loaded. Sample:")
            print(psql("-c", "SELECT block_geoid, state_usps, brand_name "
                             "FROM bdc_stage_tbl WHERE block_geoid IS NULL "
                             "OR block_geoid !~ '^[0-9]{15}$' LIMIT 5"))

        print("  inserting ...", flush=True)
        psql("-qc",
             "INSERT INTO bdc_availability_tbl (" + COLS + ", source_file) "
             "SELECT nullif(frn, ''), nullif(provider_id, '')::integer, "
             "nullif(brand_name, ''), nullif(location_id, '')::bigint, "
             "nullif(technology, '')::smallint, "
             "nullif(max_advertised_download_speed, '')::integer, "
             "nullif(max_advertised_upload_speed, '')::integer, "
             "nullif(low_latency, '')::smallint, "
             "nullif(business_residential_code, ''), nullif(state_usps, ''), "
             "block_geoid, nullif(h3_res8_id, ''), " + lit(name) + " "
             "FROM bdc_stage_tbl "
             "WHERE block_geoid ~ '^[0-9]{15}$'")
        psql("-qc", "DROP TABLE IF EXISTS bdc_stage_tbl")

        n = int(psql_q("SELECT count(*) FROM bdc_availability_tbl "
                       f"WHERE source_file = {lit(name)}") or 0)
        total_loaded += n
        print(f"  loaded {n:,} rows in {time.monotonic() - started:.0f}s")

    print(f"\n{total_loaded:,} rows loaded this run")

    if total_loaded:
        print("\nRun `python3 bdc_load.py technologies` next: it reports the "
              "technology codes actually present, which is what step 2 needs "
              "to separate FIOS from xDSL. The code list is deliberately not "
              "hardcoded anywhere in this project.")

    if failed:
        # Nonzero exit, so this cannot be missed in a batched command block
        # where the next command would otherwise run as though all was well.
        print(f"\n{len(failed)} file(s) LOADED NOTHING: "
              f"{', '.join(failed)}")
        sys.exit(1)


def cmd_technologies(args):
    require_schema()
    print("Technology codes PRESENT IN THE LOADED DATA, with their brands.")
    print("This is the mapping step 2 needs. It is read from the data because")
    print("I have not verified the FCC code list and will not guess it.\n")
    print(psql("-c", """
SELECT technology,
       count(*)                          AS records,
       count(DISTINCT provider_id)       AS providers,
       count(DISTINCT tract_geoid)       AS tracts,
       left(string_agg(DISTINCT brand_name, ', '), 90) AS example_brands
FROM bdc_availability_tbl
GROUP BY technology
ORDER BY count(*) DESC"""))

    print("\nThe FIOS versus xDSL case: one carrier, several technologies.")
    print("Top 25 carrier and technology pairs by tract count.\n")
    print(psql("-c", """
SELECT provider_id, left(brand_name, 34) AS brand, technology,
       count(DISTINCT tract_geoid) AS tracts,
       count(*)                    AS records
FROM bdc_availability_tbl
GROUP BY provider_id, left(brand_name, 34), technology
ORDER BY count(DISTINCT tract_geoid) DESC
LIMIT 25"""))


def cmd_status(args):
    require_schema()
    print(psql("-c", """
SELECT source_file,
       count(*)                    AS rows,
       count(DISTINCT state_usps)  AS states,
       count(DISTINCT tract_geoid) AS tracts,
       count(DISTINCT provider_id) AS providers,
       min(loaded_at)              AS loaded_at
FROM bdc_availability_tbl
GROUP BY source_file
ORDER BY source_file"""))
    print(psql("-c", """
SELECT count(*)                     AS rows_total,
       count(DISTINCT state_usps)   AS states,
       count(DISTINCT county_geoid) AS counties,
       count(DISTINCT tract_geoid)  AS tracts,
       count(DISTINCT block_geoid)  AS blocks,
       count(DISTINCT provider_id)  AS providers
FROM bdc_availability_tbl"""))

    if not args.check_overlap:
        print("The same availability record can arrive twice when the files "
              "downloaded overlap, because the FCC publishes both per-state "
              "and per-technology extracts and the skip-if-already-loaded "
              "rule is per FILE, not per record. Nothing above would show "
              "that. `status --check-overlap` counts it, but it is a full "
              "aggregate over every row and is therefore not run by default.")
        return

    print("\nRecords present under more than one source_file. A nonzero count "
          "means two of the downloads cover the same availability record, "
          "which would double-weight a tract in later steps.\n")
    print(psql("-c", """
SELECT count(*)            AS duplicated_record_keys,
       sum(files)          AS rows_involved,
       max(files)          AS most_files_one_record_is_in
FROM (SELECT count(DISTINCT source_file) AS files
      FROM bdc_availability_tbl
      GROUP BY provider_id, technology, location_id,
               business_residential_code, block_geoid
      HAVING count(DISTINCT source_file) > 1) d"""))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    lo = sub.add_parser("load", help="load one or more public BDC CSV/ZIP/GZ files")
    lo.add_argument("--files", nargs="+", required=True)
    lo.add_argument("--replace", action="store_true",
                    help="reload a file already present, deleting only that "
                         "file's rows")
    lo.set_defaults(func=cmd_load)

    te = sub.add_parser("technologies",
                        help="report the technology codes present, from data")
    te.set_defaults(func=cmd_technologies)

    st = sub.add_parser("status", help="rows, states, tracts and providers held")
    st.add_argument("--check-overlap", action="store_true",
                    help="also count records present under more than one "
                         "source_file; a full aggregate over every row, so "
                         "it is off by default")
    st.set_defaults(func=cmd_status)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
