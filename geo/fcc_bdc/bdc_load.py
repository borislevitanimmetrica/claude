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
    sent = 0
    t0 = time.monotonic()
    last = t0
    try:
        # COPIED IN CHUNKS WITH PROGRESS, not shutil.copyfileobj.
        #
        # Boris, 2026-11-17: "I asked you for frequent feedback in all
        # operations." He is right, and this was the worst offender in the
        # project: a five million row state file streams for minutes having
        # printed one line before it and one after. From outside that is
        # indistinguishable from a hang, and he has twice had to ask whether
        # a job was still alive.
        while True:
            block = stream.read(1 << 22)
            if not block:
                break
            p.stdin.write(block)
            sent += len(block)
            now = time.monotonic()
            if now - last >= 5:
                rate = sent / max(now - t0, 0.001)
                print(f"      {sent / 1e6:,.0f} MB streamed, "
                      f"{rate / 1e6:.1f} MB/s", flush=True)
                last = now
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
        sys.exit("bdc_availability_tbl does not exist. Apply a schema "
                 "first, one of:\n"
                 "  psql -X -P pager=off -f geo/fcc_bdc/schema.sql\n"
                 "  psql -X -P pager=off -f geo/fcc_bdc/schema_v2.sql")


def schema_is_lean():
    """True for schema_v2, false for the original wide table.

    Detected from the catalogue rather than configured, because getting this
    wrong means inserting into columns that do not exist, and the database
    already knows the answer.
    """
    cols = psql_q("SELECT string_agg(column_name, ',' ORDER BY column_name) "
                  "FROM information_schema.columns "
                  "WHERE table_name = 'bdc_availability_tbl' "
                  "AND column_name IN ('source_file', 'source_file_id', "
                  "'carrier_key', 'provider_key', 'brand_name')")
    present = set((cols or "").split(",")) - {""}
    lean = {"source_file_id", "carrier_key"} <= present
    wide = "source_file" in present and "brand_name" in present

    # THE PRE-RENAME SHAPE, named explicitly. bdc_provider_tbl was renamed to
    # bdc_carrier_tbl on 2026-11-17 and the column provider_key to
    # carrier_key. A loader built after that rename cannot write to a
    # database before it, and the first version of this check reported only
    # "matches neither", which is true but useless.
    #
    # This is exactly what broke Boris's load: the rename happened while a
    # load was running, the running process still wrote the old names, and
    # the next file failed. The message now says what to run.
    if {"source_file_id", "provider_key"} <= present:
        sys.exit("bdc_availability_tbl still has the PRE-RENAME column "
                 "provider_key, which this loader no longer writes. Nothing "
                 "was loaded and nothing was changed. Run the rename first, "
                 "then this command again:\n"
                 "  psql -X -P pager=off -f "
                 "geo/fcc_bdc/rename_provider_to_carrier.sql\n"
                 "It is idempotent, it carries the data over, and files "
                 "already loaded will be skipped when you resume.")

    if lean and not wide:
        return True
    if wide and not lean:
        return False
    sys.exit("bdc_availability_tbl matches neither schema.sql nor "
             f"schema_v2.sql. Columns found among the ones that distinguish "
             f"them: {sorted(present) or 'none'}. Nothing was loaded; "
             f"inserting against a shape I cannot identify is how data ends "
             f"up in the wrong columns.")


def rows_for_file(name, lean):
    if lean:
        return int(psql_q(
            "SELECT coalesce(count(*), 0) FROM bdc_availability_tbl a "
            "JOIN bdc_source_file_tbl f USING (source_file_id) "
            f"WHERE f.source_file = {lit(name)}") or 0)
    return int(psql_q("SELECT count(*) FROM bdc_availability_tbl "
                      f"WHERE source_file = {lit(name)}") or 0)


def delete_file_rows(name, lean):
    if lean:
        psql("-qc", "DELETE FROM bdc_availability_tbl a "
                    "USING bdc_source_file_tbl f "
                    "WHERE a.source_file_id = f.source_file_id "
                    f"AND f.source_file = {lit(name)}")
        psql("-qc", "DELETE FROM bdc_source_file_tbl "
                    f"WHERE source_file = {lit(name)}")
        return
    psql("-qc", "DELETE FROM bdc_availability_tbl "
                f"WHERE source_file = {lit(name)}")


def insert_lean(name):
    """Insert from staging into the normalised tables.

    Order matters: the file row and the provider rows must exist before the
    availability rows that reference them, and both are derived from the
    staging table rather than supplied, so a brand new carrier appearing in
    one state file is registered by loading that file.
    """
    psql("-qc", "INSERT INTO bdc_source_file_tbl (source_file) VALUES "
                f"({lit(name)}) ON CONFLICT (source_file) DO NOTHING")

    psql("-qc",
         "INSERT INTO bdc_carrier_tbl (frn, provider_id, brand_name) "
         "SELECT DISTINCT nullif(frn, ''), nullif(provider_id, '')::integer, "
         "nullif(brand_name, '') FROM bdc_stage_tbl "
         "WHERE block_geoid ~ '^[0-9]{15}$' "
         "ON CONFLICT (frn, provider_id, brand_name) DO NOTHING")

    psql("-qc",
         "INSERT INTO bdc_availability_tbl ("
         "source_file_id, carrier_key, location_id, technology, "
         "max_advertised_download_speed, max_advertised_upload_speed, "
         "low_latency, business_residential_code, state_usps, block_geoid, "
         "h3_res8_id) "
         "SELECT f.source_file_id, p.carrier_key, "
         "nullif(s.location_id, '')::bigint, "
         "nullif(s.technology, '')::smallint, "
         "nullif(s.max_advertised_download_speed, '')::integer, "
         "nullif(s.max_advertised_upload_speed, '')::integer, "
         "nullif(s.low_latency, '')::smallint, "
         "nullif(s.business_residential_code, ''), "
         "nullif(s.state_usps, ''), s.block_geoid, nullif(s.h3_res8_id, '') "
         "FROM bdc_stage_tbl s "
         "JOIN bdc_source_file_tbl f ON f.source_file = " + lit(name) + " "
         "JOIN bdc_carrier_tbl p "
         "  ON p.frn IS NOT DISTINCT FROM nullif(s.frn, '') "
         " AND p.provider_id IS NOT DISTINCT FROM "
         "     nullif(s.provider_id, '')::integer "
         " AND p.brand_name IS NOT DISTINCT FROM nullif(s.brand_name, '') "
         "WHERE s.block_geoid ~ '^[0-9]{15}$'")

    psql("-qc", "UPDATE bdc_source_file_tbl f SET row_count = ("
                "SELECT count(*) FROM bdc_availability_tbl a "
                "WHERE a.source_file_id = f.source_file_id) "
                f"WHERE f.source_file = {lit(name)}")


def insert_wide(name):
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


def loaded_counts(lean):
    """Rows per source_file, for every file, in ONE query.

    Was one query per file inside the loop. With 333 downloads and 241 of
    them already loaded, that is 333 psql SUBPROCESSES before the first new
    file is reached, and every one of them silent. Boris saw an empty log
    and had no way to tell the difference between progress and a hang.
    """
    if lean:
        sql = ("SELECT f.source_file, count(a.source_file_id) "
               "FROM bdc_source_file_tbl f "
               "LEFT JOIN bdc_availability_tbl a USING (source_file_id) "
               "GROUP BY f.source_file")
    else:
        sql = ("SELECT source_file, count(*) FROM bdc_availability_tbl "
               "GROUP BY source_file")
    out = {}
    for line in psql("-qtAF|", "-c", sql).splitlines():
        if "|" not in line:
            continue
        name, n = line.rsplit("|", 1)
        try:
            out[name] = int(n)
        except ValueError:
            continue
    return out


def cmd_load(args):
    require_schema()
    lean = schema_is_lean()
    print("schema: " + ("schema_v2, normalised" if lean
                        else "schema.sql, wide"), flush=True)
    for f in args.files:
        if not os.path.isfile(f):
            sys.exit(f"not a file: {f}")

    already = loaded_counts(lean)

    # LEFTOVER STAGING STATE, reported rather than silently dropped.
    #
    # bdc_stage_tbl is a real UNLOGGED table, not a TEMP one, so a load
    # killed mid-COPY leaves it behind holding part of a file. The code has
    # always dropped it before reusing it, but it did so silently, which
    # means a crashed previous run looked identical to a clean start.
    # TWO QUERIES, NOT ONE WITH A GUARD. A table named anywhere in a
    # statement is resolved when the statement is PARSED, so
    #   SELECT CASE WHEN to_regclass('bdc_stage_tbl') IS NULL THEN '-1'
    #          ELSE (SELECT count(*) FROM bdc_stage_tbl) END
    # fails with "relation bdc_stage_tbl does not exist" whenever it does
    # not exist, which is the normal case. The CASE never gets the chance to
    # short-circuit. That is the third time this class of mistake has
    # appeared in this project; the other two were a LEFT JOIN target and a
    # DROP CASCADE.
    exists = psql_q("SELECT to_regclass('bdc_stage_tbl') IS NOT NULL")
    leftover = psql_q("SELECT count(*) FROM bdc_stage_tbl") \
        if exists == "t" else "0"
    if leftover and leftover.isdigit() and int(leftover) > 0:
        print(f"NOTE: a staging table was left behind holding "
              f"{int(leftover):,} rows, which means the previous run was "
              f"interrupted mid-copy. It is dropped and the file it came "
              f"from will be loaded again from the start. No availability "
              f"rows were affected: the insert from staging is a single "
              f"statement and either completed or did not.", flush=True)
        psql("-qc", "DROP TABLE IF EXISTS bdc_stage_tbl")

    names = [os.path.basename(p) for p in args.files]
    todo = [n for n in names if not already.get(n)]
    print(f"{len(args.files)} file(s) to consider: "
          f"{len(names) - len(todo)} already loaded, {len(todo)} to do",
          flush=True)
    if todo:
        print(f"first to load: {todo[0]}", flush=True)

    # FILES RECORDED WITH SUSPICIOUSLY FEW ROWS. A file left short by an
    # interrupted load counts as loaded and is skipped forever, so it is
    # named here even though this cannot tell short from genuinely small
    # without reading the file. `verify` reads the files and can.
    thin = sorted((n for n in names
                   if 0 < (already.get(n) or 0) < 100),
                  key=lambda n: already.get(n) or 0)
    if thin:
        print(f"\n{len(thin)} loaded file(s) hold fewer than 100 rows. Some "
              f"are genuinely tiny, the Other technology files especially, "
              f"but a file left short by an interrupted load looks exactly "
              f"the same from here and WILL BE SKIPPED. Run `verify` to "
              f"tell them apart:", flush=True)
        for n in thin[:10]:
            print(f"    {already.get(n):>6,} rows  {n}", flush=True)

    total_loaded = 0
    failed = []
    done = 0
    run_start = time.monotonic()
    for path in args.files:
        name = os.path.basename(path)
        existing = already.get(name, 0)
        if existing and not args.replace:
            # Skipped quietly and counted, rather than a line each for
            # hundreds of files.
            continue
        done += 1
        elapsed = time.monotonic() - run_start
        eta = ""
        if done > 1 and elapsed > 0:
            per = elapsed / (done - 1)
            eta = (f", about {(len(todo) - done + 1) * per / 60:.0f} min "
                   f"left at the current rate")
        print(f"\n[{done} of {len(todo)}] {name}{eta}", flush=True)
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
            delete_file_rows(name, lean)

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
        if lean:
            insert_lean(name)
        else:
            insert_wide(name)
        psql("-qc", "DROP TABLE IF EXISTS bdc_stage_tbl")

        n = rows_for_file(name, lean)
        total_loaded += n
        print(f"  loaded {n:,} rows in {time.monotonic() - started:.0f}s")

    skipped = len(names) - len(todo)
    if skipped:
        print(f"\n{skipped} file(s) were already loaded and were skipped. "
              f"--replace reloads a named file.")
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


def report_relation():
    """The relation the reporting queries should read.

    Under schema_v2 the carrier columns live in bdc_carrier_tbl and the
    bdc_availability view puts them back under their original names, so one
    copy of each query serves both schemas.
    """
    return "bdc_availability" if schema_is_lean() else "bdc_availability_tbl"


def cmd_technologies(args):
    require_schema()
    rel = report_relation()
    print("Technology codes PRESENT IN THE LOADED DATA, with their brands.")
    print("This is the mapping step 2 needs. It is read from the data because")
    print("I have not verified the FCC code list and will not guess it.\n")
    print(psql("-c", f"""
SELECT technology,
       count(*)                          AS records,
       count(DISTINCT provider_id)       AS providers,
       count(DISTINCT tract_geoid)       AS tracts,
       left(string_agg(DISTINCT brand_name, ', '), 90) AS example_brands
FROM {rel}
GROUP BY technology
ORDER BY count(*) DESC"""))

    print("\nThe FIOS versus xDSL case: one carrier, several technologies.")
    print("Top 25 carrier and technology pairs by tract count.\n")
    print(psql("-c", f"""
SELECT provider_id, left(brand_name, 34) AS brand, technology,
       count(DISTINCT tract_geoid) AS tracts,
       count(*)                    AS records
FROM {rel}
GROUP BY provider_id, left(brand_name, 34), technology
ORDER BY count(DISTINCT tract_geoid) DESC
LIMIT 25"""))


def count_csv_rows(path):
    """Data lines in the CSV inside path, excluding the header.

    Reads the whole file. There is no shortcut: a ZIP records the
    uncompressed BYTE size of a member, not its line count.
    """
    stream = open_csv(path)
    try:
        n = -1
        for _ in stream:
            n += 1
        return max(n, 0)
    finally:
        stream.close()


def cmd_verify(args):
    """Compare what each download contains against what was loaded.

    WHY THIS IS NEEDED, and it is not a nicety.

    A load that fails partway can leave a file RECORDED as loaded with fewer
    rows than it holds, and the skip-if-already-loaded rule then skips it on
    every future run. The missing rows are invisible: no error, no warning,
    just a state that looks finished.

    DEMONSTRATED 2026-11-17. With 33,632 of 323,859 rows present for one
    file, `load` reported "2 already loaded, 0 to do" and did nothing. Only
    --replace repaired it.

    The occasion was real: a rename broke a running load, after which
    bdc_42_Other_fixed_broadband_J26_10nov2026.zip was recorded with exactly
    ONE row. One row may be correct, because the Other technology files are
    tiny, but NOTHING IN THE DATABASE COULD SAY WHICH. This can, by reading
    the file.
    """
    require_schema()
    lean = schema_is_lean()
    already = loaded_counts(lean)

    files = args.files
    print(f"reading {len(files)} file(s) and comparing with the database.")
    print("This decompresses every file, so it takes a while. Progress is "
          "reported every ten files.\n")
    print(f"{'file':<56} {'in_file':>10} {'loaded':>10} {'diff':>9}  state")

    ok = short = over = absent = 0
    problems = []
    t0 = time.monotonic()

    for i, path in enumerate(files, 1):
        name = os.path.basename(path)
        if i == 1 or i % 10 == 0:
            el = time.monotonic() - t0
            eta = ""
            if i > 1:
                eta = (f", about {(len(files) - i) * el / (i - 1) / 60:.0f} "
                       f"min left")
            print(f"  ... {i} of {len(files)}, {el / 60:.1f} min "
                  f"elapsed{eta}", flush=True)

        try:
            in_file = count_csv_rows(path)
        except (ValueError, zipfile.BadZipFile, OSError) as exc:
            print(f"{name[:56]:<56} {'unreadable':>10} "
                  f"{already.get(name, 0):>10,} {'':>9}  {exc}", flush=True)
            problems.append(f"{name}: unreadable, {exc}")
            continue

        loaded = already.get(name)
        if loaded is None:
            absent += 1
            state = "NOT LOADED"
        elif loaded == in_file:
            ok += 1
            state = "ok"
        elif loaded < in_file:
            short += 1
            state = "SHORT, rows missing"
            problems.append(f"{name}: {in_file - loaded:,} rows missing")
        else:
            over += 1
            state = "MORE than the file holds"
            problems.append(f"{name}: {loaded - in_file:,} rows too many")

        if loaded != in_file or args.all:
            print(f"{name[:56]:<56} {in_file:>10,} "
                  f"{(loaded or 0):>10,} {(loaded or 0) - in_file:>9,}  "
                  f"{state}", flush=True)

    print(f"\n{ok} match, {short} SHORT, {over} with too many, "
          f"{absent} not loaded, in {(time.monotonic() - t0) / 60:.1f} min")

    if short or over:
        print("\nA SHORT file is the dangerous case: it counts as loaded, so "
              "it is skipped on every future run and its missing rows never "
              "arrive. Reload exactly these:")
        for pr in problems[:25]:
            print(f"  {pr}")
        print("\n  python3 geo/fcc_bdc/bdc_load.py load --replace --files "
              "<the files named above>")
        print("\n--replace deletes only that file's rows and loads it again. "
              "Nothing else is touched.")
        sys.exit(1)

    if absent:
        print(f"\n{absent} file(s) not loaded yet. Run the load again; it "
              f"skips the complete ones.")
    if not problems:
        print("\nEvery loaded file matches its contents exactly.")


def cmd_status(args):
    require_schema()
    rel = report_relation()
    print(psql("-c", f"""
SELECT source_file,
       count(*)                    AS rows,
       count(DISTINCT state_usps)  AS states,
       count(DISTINCT tract_geoid) AS tracts,
       count(DISTINCT provider_id) AS providers,
       min(loaded_at)              AS loaded_at
FROM {rel}
GROUP BY source_file
ORDER BY source_file"""))
    print(psql("-c", f"""
SELECT count(*)                     AS rows_total,
       count(DISTINCT state_usps)   AS states,
       count(DISTINCT county_geoid) AS counties,
       count(DISTINCT tract_geoid)  AS tracts,
       count(DISTINCT block_geoid)  AS blocks,
       count(DISTINCT provider_id)  AS providers
FROM {rel}"""))

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
    print(psql("-c", f"""
SELECT count(*)            AS duplicated_record_keys,
       sum(files)          AS rows_involved,
       max(files)          AS most_files_one_record_is_in
FROM (SELECT count(DISTINCT source_file) AS files
      FROM {rel}
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

    ve = sub.add_parser("verify",
                        help="read every download and compare its row count "
                             "with what is loaded; the only way to detect a "
                             "file recorded as loaded but short")
    ve.add_argument("--files", nargs="+", required=True)
    ve.add_argument("--all", action="store_true",
                    help="list every file, not only the mismatches")
    ve.set_defaults(func=cmd_verify)

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
