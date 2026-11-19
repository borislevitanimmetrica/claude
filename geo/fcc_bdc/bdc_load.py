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
import atexit
import csv
import gzip
import io
import os
import re
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


# ABSOLUTE PATHS IN EVERY COMMAND THIS PRINTS.
#
# Standing order 8, issued 2026-11-18. Boris: "Always issue absolute paths.
# What reason not to?" There is none. A relative path saves typing and costs
# a failed command whenever the working directory is not the one silently
# assumed. A message that names a remedy by a relative path hands the same
# failure back to the reader. Derived from __file__, so correct wherever the
# repository is checked out and from whatever directory it is run.
HERE = os.path.dirname(os.path.abspath(__file__))
SELF = os.path.join(HERE, "bdc_load.py")


def here(name):
    """Absolute path to a file beside this script."""
    return os.path.join(HERE, name)


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
                 f"  psql -X -P pager=off -f {here('schema.sql')}\n"
                 f"  psql -X -P pager=off -f {here('schema_v2.sql')}")


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


STAGE = "bdc_stage_tbl"
STAGE_META = "bdc_stage_meta_tbl"

# Returned when the staging table holds rows but nothing records which file
# they belong to. Distinct from (None, 0), which means genuinely nothing
# staged, because the two call for opposite actions: reuse versus stop.
UNKNOWN_STAGED = ("?", -1)


def ensure_stage_meta():
    """The one-row table that records which file the staging table holds.

    Needed because the staging table has no source_file column: the FCC CSV
    does not carry one, and adding it to staging would mean writing the same
    literal onto every one of several million rows during the copy.

    WHY NOT NAME THE STAGING TABLE AFTER THE PROCESS

    My previous attempt at the two-loaders bug used bdc_stage_<pid>_tbl.
    That does stop the collision, but it also makes resume IMPOSSIBLE: a new
    process has a new pid and can never find the table the dead one left.
    The two changes were in direct conflict and the per-pid naming was
    defeating the resume Boris asked for. The lock stops the collision; a
    fixed name keeps the resume. Per-pid naming is withdrawn.

    The `only_row` column with its CHECK is what keeps this to one row.
    """
    psql("-qc",
         f"CREATE TABLE IF NOT EXISTS {STAGE_META} ("
         "  only_row boolean PRIMARY KEY DEFAULT true CHECK (only_row), "
         "  source_file text NOT NULL, "
         "  staged_rows bigint NOT NULL, "
         "  csv_bytes bigint, "
         "  loader_pid integer, "
         "  staged_at timestamptz NOT NULL DEFAULT now())")


def staged_state():
    """Return (source_file, rows actually in staging) or (None, 0).

    The row count is read from the staging table itself, not from the meta
    row, so a mismatch is detectable rather than assumed away. An unlogged
    table is emptied by postgres after a crash, and the meta row would
    survive that and claim rows that are gone.
    """
    def stage_rows():
        if psql_q(f"SELECT to_regclass('{STAGE}') IS NOT NULL") != "t":
            return 0
        return int(psql_q(f"SELECT count(*) FROM {STAGE}") or 0)

    if psql_q(f"SELECT to_regclass('{STAGE_META}') IS NOT NULL") != "t":
        return UNKNOWN_STAGED if stage_rows() else (None, 0)
    row = psql_q(f"SELECT source_file || '|' || staged_rows FROM {STAGE_META}")
    if not row or "|" not in row:
        # STAGED ROWS WITH NOTHING SAYING WHICH FILE THEY CAME FROM.
        #
        # This is the state every machine is in the first time this version
        # runs: the staging table was left behind by the previous code,
        # which kept no record of what it held. Returning "nothing staged"
        # here would send the caller straight into DROP TABLE, which is the
        # destructive behaviour Boris objected to, on exactly the data he
        # objected to losing. So it is reported as unknown and the caller
        # stops instead.
        return UNKNOWN_STAGED if stage_rows() else (None, 0)
    name, claimed = row.rsplit("|", 1)
    if psql_q(f"SELECT to_regclass('{STAGE}') IS NOT NULL") != "t":
        print(f"NOTE: {STAGE_META} says {claimed} rows are staged for "
              f"{name} but {STAGE} does not exist. Treating it as nothing "
              f"staged.", flush=True)
        return None, 0
    actual = int(psql_q(f"SELECT count(*) FROM {STAGE}") or 0)
    if actual != int(claimed):
        print(f"NOTE: {STAGE_META} claims {int(claimed):,} staged rows for "
              f"{name} but {STAGE} holds {actual:,}. An unlogged table is "
              f"emptied by postgres after an unclean shutdown, which fits a "
              f"count of 0. Not resuming from a count I cannot trust; that "
              f"file will be copied again.", flush=True)
        return None, 0
    return name, actual


def insert_lean(name):
    """Insert from staging into the normalised tables, in ONE transaction.

    Order matters: the file row and the carrier rows must exist before the
    availability rows that reference them, and both are derived from the
    staging table rather than supplied, so a brand new carrier appearing in
    one state file is registered by loading that file.

    ATOMICITY, AND WHY IT IS NOT OPTIONAL

    This was four separate psql calls. MEASURED on PostgreSQL 16.2: two
    statements passed in separate -c flags are NOT one transaction, each
    commits on its own, while two statements inside a single -c ARE one
    transaction and a failure in the second rolls back the first.

    So the old shape had a window. The availability INSERT committed, then
    the process could die before the row_count UPDATE. row_count stayed 0,
    loaded_counts treats 0 as not loaded, and the next run would insert the
    same file's rows a SECOND time. Nothing would have reported it: the
    rows are legitimate-looking duplicates.

    One -c closes the window. A killed client rolls the whole thing back,
    also measured: 100,000 rows inserted inside a transaction whose client
    was SIGKILLed left exactly 0 rows behind.

    The leading DELETE makes it idempotent as well as atomic. Pre-mortem for
    that DELETE: it removes rows whose source_file_id is this one file's and
    nothing else, it runs in the same transaction as the INSERT that
    replaces them, and on the normal path it removes zero rows because this
    function is only reached for a file not already counted as loaded. If
    the transaction fails, the delete is undone with it.
    """
    psql("-qc",
         # One -c, therefore one transaction. Do not split these.
         "INSERT INTO bdc_source_file_tbl (source_file) VALUES "
         f"({lit(name)}) ON CONFLICT (source_file) DO NOTHING; "

         "DELETE FROM bdc_availability_tbl a USING bdc_source_file_tbl f "
         "WHERE a.source_file_id = f.source_file_id "
         f"AND f.source_file = {lit(name)}; "

         "INSERT INTO bdc_carrier_tbl (frn, provider_id, brand_name) "
         "SELECT DISTINCT nullif(frn, ''), nullif(provider_id, '')::integer, "
         f"nullif(brand_name, '') FROM {STAGE} "
         "WHERE block_geoid ~ '^[0-9]{15}$' "
         "ON CONFLICT (frn, provider_id, brand_name) DO NOTHING; "

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
         f"FROM {STAGE} s "
         "JOIN bdc_source_file_tbl f ON f.source_file = " + lit(name) + " "
         "JOIN bdc_carrier_tbl p "
         "  ON p.frn IS NOT DISTINCT FROM nullif(s.frn, '') "
         " AND p.provider_id IS NOT DISTINCT FROM "
         "     nullif(s.provider_id, '')::integer "
         " AND p.brand_name IS NOT DISTINCT FROM nullif(s.brand_name, '') "
         "WHERE s.block_geoid ~ '^[0-9]{15}$'; "

         "UPDATE bdc_source_file_tbl f SET row_count = ("
         "SELECT count(*) FROM bdc_availability_tbl a "
         "WHERE a.source_file_id = f.source_file_id) "
         f"WHERE f.source_file = {lit(name)}")


def insert_wide(name):
    """The wide-table equivalent, also one transaction for the same reason."""
    psql("-qc",
         "DELETE FROM bdc_availability_tbl "
         f"WHERE source_file = {lit(name)}; "

         "INSERT INTO bdc_availability_tbl (" + COLS + ", source_file) "
         "SELECT nullif(frn, ''), nullif(provider_id, '')::integer, "
         "nullif(brand_name, ''), nullif(location_id, '')::bigint, "
         "nullif(technology, '')::smallint, "
         "nullif(max_advertised_download_speed, '')::integer, "
         "nullif(max_advertised_upload_speed, '')::integer, "
         "nullif(low_latency, '')::smallint, "
         "nullif(business_residential_code, ''), nullif(state_usps, ''), "
         "block_geoid, nullif(h3_res8_id, ''), " + lit(name) + " "
         f"FROM {STAGE} "
         "WHERE block_geoid ~ '^[0-9]{15}$'")


def loaded_counts(lean):
    """Rows per source_file, for every file, in ONE query.

    Was one query per file inside the loop. With 333 downloads and 241 of
    them already loaded, that is 333 psql SUBPROCESSES before the first new
    file is reached, and every one of them silent. Boris saw an empty log
    and had no way to tell the difference between progress and a hang.
    """
    if lean:
        # READ row_count FROM THE SMALL TABLE, do not aggregate the big one.
        #
        # The first version of this joined bdc_source_file_tbl to
        # bdc_availability_tbl and grouped, which is a FULL SCAN of a table
        # holding tens of millions of rows. It replaced 333 cheap indexed
        # lookups with one very expensive query, so the loader sat silent for
        # over a minute before printing anything. row_count is written by
        # insert_lean at load time and the table has one row per file.
        #
        # coalesce to 0 rather than NULL so a file registered but with no
        # rows inserted, which is what an interrupted load leaves, counts as
        # NOT loaded and is retried.
        sql = ("SELECT source_file, coalesce(row_count, 0) "
               "FROM bdc_source_file_tbl")
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


LOAD_LOCK_KEY = 8412771  # arbitrary but fixed, for pg_try_advisory_lock

# The holder subprocess is kept in a module global. If it were a local it
# could be garbage collected, its pipe would close, and the lock would be
# released while the load was still running.
_LOCK_HOLDER = None


def release_load_lock():
    """Close the holder's pipe and reap it, so nothing outlives this run.

    Closing stdin gives the holder psql EOF, it exits, its session ends and
    the advisory lock goes with it. The wait is bounded: if it has not gone
    in two seconds it is terminated, and if it still has not gone it is
    killed. A lock holder that refuses to die would block every later
    loader, which is exactly the failure the pg_sleep version would have
    caused, so this does not leave it to chance.

    Safe to call more than once and safe when no lock was ever taken.
    """
    global _LOCK_HOLDER
    p = _LOCK_HOLDER
    _LOCK_HOLDER = None
    if p is None:
        return
    for closer in (p.stdin, p.stdout, p.stderr):
        try:
            if closer is not None:
                closer.close()
        except (OSError, ValueError):
            pass
    try:
        p.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        p.terminate()
        p.wait(timeout=2)
    except (subprocess.TimeoutExpired, OSError):
        try:
            p.kill()
            p.wait(timeout=2)
        except (subprocess.TimeoutExpired, OSError):
            pass


def take_load_lock():
    """Hold a lock for the life of this process. Returns True if we got it.

    WHY THIS IS NOT OPTIONAL. bdc_stage_tbl is one table, so two loaders
    running at once share it: one drops it while the other is counting it,
    which is what happened on 2026-11-17. The log read

        copying into staging ...
        psql failed: ERROR: relation "bdc_stage_tbl" does not exist
        LINE 1: SELECT count(*) FROM bdc_stage_tbl

    and the two processes disagreed about how many files were loaded, 247
    against 246, because each was committing while the other counted. I had
    written that hazard into a comment in this file and not guarded it.

    HOW THE LOCK IS HELD, AND THE VERSION I NEARLY SHIPPED

    An advisory lock lives as long as the SESSION that took it. psql exits
    after every call here, so taking it in a throwaway psql protects
    nothing. MEASURED: holders in pg_locks drops to 0 the moment that psql
    exits.

    My first fix held it in a background `psql -c 'SELECT pg_advisory_lock'
    -c 'SELECT pg_sleep(86400)'`. That is WRONG and I only found out by
    testing it. A backend sitting inside pg_sleep never touches its socket,
    so it does not notice its client was killed. MEASURED: after SIGKILLing
    the holder the lock was STILL HELD ten seconds later, and with a 86400
    second sleep it would have been held for a day. A loader that crashed
    would have locked out every later loader until Boris found and killed an
    orphaned psql. That is far worse than the bug it was fixing.

    So the holder is `psql -f -` reading a pipe this process keeps open.
    After taking the lock it blocks reading stdin, which leaves the backend
    IDLE and watching its socket. When this process dies, for any reason
    including SIGKILL, the pipe closes, psql sees EOF and exits, the session
    ends and the lock goes. MEASURED: cleared 498 ms after SIGKILL, and a
    fresh loader was then able to take it.

    Nothing here terminates anybody else's backend. A refused loader reports
    what it found and stops.
    """
    global _LOCK_HOLDER
    # RELEASED EXPLICITLY AT EXIT, not left to process teardown.
    #
    # Boris, 2026-11-18: the load printed its final summary "but has not
    # returned to the psql prompt."
    #
    # I have NOT established that this holder is the cause and I am not
    # going to assert it. What is true is that relying on interpreter
    # teardown to close the pipe, so that psql sees EOF and exits, leaves a
    # child process alive for an interval I never measured, and a shell that
    # waits on the process group would wait with it. Registering the release
    # makes the holder's exit something this program does rather than
    # something it hopes for, which is correct hygiene whatever the cause
    # turns out to be.
    atexit.register(release_load_lock)
    try:
        p = subprocess.Popen(
            ["psql", "-X", "-q", "-t", "-A", "-f", "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        p.stdin.write(f"SELECT pg_try_advisory_lock({LOAD_LOCK_KEY});\n")
        p.stdin.flush()
        got = p.stdout.readline().strip()
    except (OSError, ValueError) as exc:
        sys.exit(f"could not start the lock holder: {exc}\nNothing was "
                 f"loaded. This command will not run without the lock, "
                 f"because two loaders at once corrupt the load.")
    if got == "t":
        _LOCK_HOLDER = p
        return True
    if got != "f":
        # Did not even connect. Say what psql said rather than reporting a
        # busy lock that may not exist.
        try:
            p.stdin.close()
        except OSError:
            pass
        err = (p.stderr.read() or "").strip()
        sys.exit(f"the lock holder did not answer. psql said:\n{err}\n"
                 f"Nothing was loaded.")
    try:
        p.stdin.close()
    except OSError:
        pass
    return False


def report_other_loader():
    """Read-only report on who else is loading. Terminates nothing."""
    return psql("-c", f"""
SELECT l.pid,
       a.application_name,
       a.state,
       date_trunc('second', now() - a.backend_start) AS connected_for,
       left(coalesce(a.query, ''), 40) AS last_query
FROM pg_locks l
LEFT JOIN pg_stat_activity a USING (pid)
WHERE l.locktype = 'advisory' AND l.objid = {LOAD_LOCK_KEY}
ORDER BY a.backend_start""")


def cmd_load(args):
    require_schema()

    if not take_load_lock():
        sys.exit(
            "ANOTHER LOAD ALREADY HOLDS THE LOCK, so this one has stopped "
            "and changed nothing.\n\n"
            "Two loaders share one staging table: each recreates it while "
            "the other is reading it, which produces 'relation "
            "bdc_stage_tbl does not exist' and can load a file twice.\n\n"
            "The session holding it:\n" + report_other_loader() +
            "\nTo see the loader processes, SHORT OUTPUT, one line each:\n"
            "  pgrep -f bdc_load.py | xargs -r -n1 ps -o pid=,etime=,comm= "
            "-p | awk '$3 ~ /^python/'\n\n"
            "`ps -eo pid,etime,cmd | grep bdc_load` is the wrong tool here: "
            "the loader is invoked with every zip path on its command line, "
            "so ps prints all of them. MEASURED with 333 paths: 28,847 "
            "characters. The form above prints about 48 characters per "
            "loader because it asks for no args at all.\n\n"
            "Let the other one finish, then run this again. Files already "
            "loaded are skipped. Nothing here kills anything; if you decide "
            "to stop the other loader that is your call, and an interrupted "
            "load is safe to resume.")
    lean = schema_is_lean()
    print("schema: " + ("schema_v2, normalised" if lean
                        else "schema.sql, wide"), flush=True)
    for f in args.files:
        if not os.path.isfile(f):
            sys.exit(f"not a file: {f}")

    already = loaded_counts(lean)

    # A STAGED FILE FROM AN EARLIER RUN IS RESUMED, NOT DISCARDED.
    #
    # Boris, 2026-11-17: "Why are you dropping the staging table, forcing a
    # full day or more of reload, when you could just resume?" He is right
    # that it should resume, and the reason is better than I first gave.
    #
    # MEASURED on PostgreSQL 16.2, three ways of interrupting a \copy:
    #   psql SIGKILLed mid-copy                 0 rows left, full rollback
    #   parent killed, pipe broken mid-line     0 rows left, full rollback,
    #                                           ERROR missing data for column
    #   writer closed stdin at a line boundary  1,000,000 rows COMMITTED
    #
    # So an interrupted copy leaves NOTHING. Rows in the staging table can
    # therefore only mean the copy FINISHED. There is no partial state to
    # skip past and no CSV lines to count: the resume is to run the INSERT
    # from the rows that are already staged, and that is what happens below.
    # Re-copying them would be pure waste.
    #
    # UNLOGGED survives a clean restart, also measured: 1,000 rows were
    # still there after pg_ctl restart. It does NOT survive a crash, which
    # postgres handles by truncating unlogged tables; staged_rows below
    # catches that, because the count will no longer match.
    #
    # TWO QUERIES, NOT ONE WITH A GUARD. A table named anywhere in a
    # statement is resolved when the statement is PARSED, so
    #   SELECT CASE WHEN to_regclass('bdc_stage_tbl') IS NULL THEN '-1'
    #          ELSE (SELECT count(*) FROM bdc_stage_tbl) END
    # fails with "relation bdc_stage_tbl does not exist" whenever it does
    # not exist, which is the normal case. The CASE never gets the chance to
    # short-circuit. That is the third time this class of mistake has
    # appeared in this project; the other two were a LEFT JOIN target and a
    # DROP CASCADE.
    ensure_stage_meta()
    staged_file, staged_rows = staged_state()

    names = [os.path.basename(p) for p in args.files]
    todo = [n for n in names if not already.get(n)]

    resume = None
    if (staged_file, staged_rows) == UNKNOWN_STAGED:
        held = int(psql_q(f"SELECT count(*) FROM {STAGE}") or 0)
        sample = psql("-c", f"SELECT DISTINCT state_usps, brand_name "
                            f"FROM {STAGE} LIMIT 5")
        sys.exit(
            f"STOPPED, and nothing was changed.\n\n"
            f"{STAGE} holds {held:,} rows and there is no record of which "
            f"file they came from. The previous version of this loader kept "
            f"no such record, so this is the expected state the first time "
            f"this version runs after an interrupted load.\n\n"
            f"I will not guess which file they belong to and I will not "
            f"discard them. What they contain:\n{sample}\n"
            f"The row count usually identifies the file on its own. Compare "
            f"it against the files you were loading.\n\n"
            f"MEASURED, so that you can judge the cost: an interrupted "
            f"\\copy leaves NO rows at all, in every way I could interrupt "
            f"one. Rows being present means that copy FINISHED. If you "
            f"recognise the file, the cheapest thing is to let this loader "
            f"insert them rather than copy them again:\n"
            f"  psql -X -c \"INSERT INTO {STAGE_META} "
            f"(source_file, staged_rows) VALUES ('<the file name>', "
            f"{held})\"\n"
            f"then run the load again with that file in --files, and it "
            f"will insert without re-copying.\n\n"
            f"Or discard them. PRE-MORTEM for that: it throws away one "
            f"finished copy of one file, costs that file's copy time again "
            f"when you next load it, and touches no availability data at "
            f"all, because the insert from staging is atomic and either "
            f"committed or did not. No other file and no other table is "
            f"affected.\n"
            f"  psql -X -c 'TRUNCATE {STAGE}'")
    if staged_file and staged_rows > 0:
        if already.get(staged_file):
            # Its rows went in and were recorded. The staged copy is spent.
            print(f"NOTE: {staged_rows:,} rows are staged for "
                  f"{staged_file}, which is already loaded and recorded "
                  f"with {already[staged_file]:,} rows. The staged copy is "
                  f"spent and this run will reuse the table. Nothing to "
                  f"resume.", flush=True)
        elif staged_file in names:
            resume = staged_file
            # Put it first, so the work already done is banked before any
            # new copying starts.
            args.files = ([p for p in args.files
                           if os.path.basename(p) == staged_file] +
                          [p for p in args.files
                           if os.path.basename(p) != staged_file])
            todo = [n for n in names if not already.get(n)]
            todo = ([staged_file] +
                    [n for n in todo if n != staged_file])
            print(f"RESUMING: {staged_rows:,} rows are already staged for "
                  f"{staged_file} and that file is not yet loaded. The copy "
                  f"finished, so this run goes straight to the insert for "
                  f"it and does NOT copy it again.", flush=True)
            print(f"          It has been moved to the front of the queue.",
                  flush=True)
        else:
            # Changing nothing is the safe outcome here. Dropping the staged
            # rows would be a decision this command has no business making,
            # and silently copying over them would lose them.
            sys.exit(
                f"STOPPED, and nothing was changed.\n\n"
                f"{staged_rows:,} rows are staged for {staged_file}, that "
                f"file is not recorded as loaded, and it is NOT among the "
                f"files given to this command. Loading something else would "
                f"have to reuse the staging table and lose that work.\n\n"
                f"The copy for it finished, so finishing it is cheap, just "
                f"the insert. Either include it in --files, or run it alone:"
                f"\n  python3 -u {SELF} load --files "
                f"<the path to {staged_file}>\n\n"
                f"If you would rather discard those staged rows, that is "
                f"your call and the command is below. PRE-MORTEM: it "
                f"discards one finished copy of one file, costs that file's "
                f"copy time again, and touches no availability data, "
                f"because the insert from staging is atomic and either "
                f"committed or did not.\n"
                f"  psql -X -c 'TRUNCATE bdc_stage_tbl' "
                f"-c 'DELETE FROM bdc_stage_meta_tbl'")

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
        # invocation and a TEMP table would not survive to it. It has a
        # fixed name so that a later run can find and finish it, and the
        # advisory lock taken at startup is what stops two loaders sharing
        # it.
        started = time.monotonic()

        if name == resume:
            # THE RESUME PATH. The copy for this file already finished, so
            # the rows are complete and re-reading the zip would only burn
            # the time again. resume is set only when the staged row count
            # read from the table matches what the meta row recorded, and
            # only when this file is not already counted as loaded.
            stream.close()
            print(f"  copy already finished in an earlier run, "
                  f"{staged_rows:,} rows staged. Skipping the copy.",
                  flush=True)
            staged = staged_rows
            resume = None
        else:
            print("  copying into staging ...", flush=True)
            psql("-qc", f"DROP TABLE IF EXISTS {STAGE}")
            psql("-qc", f"CREATE UNLOGGED TABLE {STAGE} (" +
                 ", ".join(f"{c} text" for c in EXPECTED_HEADER) + ")")
            psql("-qc", f"DELETE FROM {STAGE_META}")
            copy_sql = f"\\copy {STAGE} ({COLS}) FROM STDIN WITH (FORMAT csv)"
            try:
                psql_copy(copy_sql, stream)
            finally:
                stream.close()
            staged = int(psql_q(f"SELECT count(*) FROM {STAGE}") or 0)
            # Recorded AFTER the copy, so the meta row exists only for a
            # copy that completed. That is what makes the resume above safe.
            psql("-qc",
                 f"INSERT INTO {STAGE_META} "
                 "(source_file, staged_rows, loader_pid) VALUES "
                 f"({lit(name)}, {staged}, {os.getpid()}) "
                 "ON CONFLICT (only_row) DO UPDATE SET "
                 "source_file = excluded.source_file, "
                 "staged_rows = excluded.staged_rows, "
                 "loader_pid = excluded.loader_pid, staged_at = now()")
            print(f"  staged {staged:,} rows in "
                  f"{time.monotonic() - started:.0f}s", flush=True)

        bad = int(psql_q(f"SELECT count(*) FROM {STAGE} "
                         f"WHERE block_geoid IS NULL "
                         f"OR block_geoid !~ '^[0-9]{{15}}$'") or 0)
        if bad:
            print(f"  {bad:,} staged row{'' if bad == 1 else 's'} ha"
                  f"{'s' if bad == 1 else 've'} a block_geoid that is not 15 "
                  f"digits and will NOT be loaded. Sample:")
            print(psql("-c", f"SELECT block_geoid, state_usps, brand_name "
                             f"FROM {STAGE} WHERE block_geoid IS NULL "
                             f"OR block_geoid !~ '^[0-9]{{15}}$' LIMIT 5"))

        print("  inserting ...", flush=True)
        if lean:
            insert_lean(name)
        else:
            insert_wide(name)

        # STAGING EMPTIED AND THE META ROW CLEARED, IN ONE TRANSACTION.
        #
        # Found by testing, not by reading: clearing only the meta row left
        # the last file's rows sitting in staging with nothing recording
        # what they were. The NEXT run then saw rows with no meta row, which
        # is the "I will not guess, stop" path above, and refused to start.
        # One successful load would have blocked every load after it.
        #
        # They must also go together. If the meta row were deleted and the
        # truncate lost, the same block appears; if the truncate happened
        # and the meta row survived, the resume path would try to insert
        # from an empty table. One -c is one transaction, measured.
        #
        # PRE-MORTEM for the TRUNCATE: the rows it discards were committed
        # into bdc_availability_tbl by the statement immediately before,
        # which is atomic and either did all of it or none of it, and
        # row_count has just been written from the rows actually present. It
        # discards a copy of data that is now stored, costs nothing to
        # reproduce, and touches no other table.
        psql("-qc", f"TRUNCATE {STAGE}; DELETE FROM {STAGE_META}")

        n = rows_for_file(name, lean)
        total_loaded += n
        print(f"  loaded {n:,} rows in {time.monotonic() - started:.0f}s",
              flush=True)

    skipped = len(names) - len(todo)
    if skipped:
        print(f"\n{skipped} file(s) were already loaded and were skipped. "
              f"--replace reloads a named file.")
    print(f"\n{total_loaded:,} rows loaded this run")

    if total_loaded:
        print(f"\nRun this next. It reports the technology codes actually "
              f"present, which is what step 2 needs to separate FIOS from "
              f"xDSL. The code list is deliberately not hardcoded anywhere "
              f"in this project.")
        print(f"  python3 -u {SELF} technologies")

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


def timed(label, sql):
    """Run a query, print it with how long it took.

    The elapsed time is printed because at 519 million rows the difference
    between formulations is minutes, and I want the real number recorded
    rather than my estimate of it.
    """
    t0 = time.monotonic()
    out = psql("-c", sql)
    print(out)
    print(f"  ({label}: {time.monotonic() - t0:.1f}s)\n", flush=True)


def cmd_technologies(args):
    """Technology codes present in the data.

    WHY THIS IS NOT ONE QUERY ANY MORE

    The first version asked for count(*), count(DISTINCT provider_id),
    count(DISTINCT tract_geoid) and string_agg(DISTINCT brand_name) in a
    single GROUP BY over the bdc_availability VIEW, which joins
    bdc_carrier_tbl.

    That was written when the table held two states. Boris's load finished
    2026-11-18 with 333 files and 519,469,683 rows. At that size the
    formulation is the problem, not the question: every count(DISTINCT)
    forces its own sort per group, they do not parallelise, and the join
    multiplies the work. I have NOT measured what it would have cost on his
    machine and I am not going to guess a number, but handing over a query
    whose cost I cannot predict is what standing order 9 is about.

    So the expensive parts are separated and each is reported with its own
    elapsed time:

      records per technology, a plain aggregate with no join and no
        DISTINCT, which is one scan

      carriers per technology, as a DISTINCT over the (carrier_key,
        technology) pairs rather than count(DISTINCT) per group. There are
        about 1,600 carriers and nine technologies, so a few tens of
        thousands of pairs, and bdc_availability_provider_tech_idx covers
        exactly those two columns so this can be an index-only scan with no
        heap access

      tracts per technology, which needs the heap because the tract index
        does not carry technology. Behind --full, with its cost stated
        rather than discovered.
    """
    require_schema()
    lean = schema_is_lean()

    # THE NAMES COME FROM A TABLE, and a LEFT JOIN so an unknown code still
    # appears rather than vanishing. A code present in the data but absent
    # from bdc_technology_tbl would mean the FCC added one since the
    # catalogue was captured, which is worth seeing, not hiding.
    if psql_q("SELECT to_regclass('bdc_technology_tbl') IS NOT NULL") != "t":
        sys.exit("bdc_technology_tbl does not exist, so the technology "
                 "names cannot be shown. It is seeded from the FCC's own "
                 "download catalogue and takes a moment:\n"
                 f"  psql -X -P pager=off -f {here('technology_tbl.sql')}")

    print("Technology codes PRESENT IN THE LOADED DATA, with the FCC's own")
    print("names from bdc_technology_tbl. The codes present are read from")
    print("the data; the names are the FCC's technology_code_desc, cross-")
    print("checked against the technology token in the FCC's file names.\n")

    n = psql_q("SELECT coalesce(sum(row_count), 0) FROM bdc_source_file_tbl")
    try:
        total = int(n)
    except ValueError:
        total = 0
    if total:
        print(f"{total:,} availability rows recorded across "
              f"{psql_q('SELECT count(*) FROM bdc_source_file_tbl')} "
              f"file(s).\n", flush=True)

    timed("records per technology, one scan", """
WITH r AS (
  SELECT technology, count(*) AS records
  FROM bdc_availability_tbl
  GROUP BY technology
)
SELECT r.technology,
       coalesce(t.code_desc, 'UNKNOWN CODE, not in bdc_technology_tbl')
         AS technology_name,
       r.records,
       round(100.0 * r.records / sum(r.records) OVER (), 2) AS pct
FROM r LEFT JOIN bdc_technology_tbl t USING (technology)
ORDER BY r.records DESC""")

    if lean:
        timed("carriers per technology, index-only over distinct pairs", """
SELECT d.technology,
       coalesce(t.code_desc, 'UNKNOWN CODE') AS technology_name,
       count(*) AS carriers,
       left(string_agg(c.brand_name, ', ' ORDER BY c.brand_name), 64)
         AS example_brands
FROM (SELECT DISTINCT technology, carrier_key
      FROM bdc_availability_tbl) d
JOIN bdc_carrier_tbl c USING (carrier_key)
LEFT JOIN bdc_technology_tbl t ON t.technology = d.technology
GROUP BY d.technology, t.code_desc
ORDER BY count(*) DESC""")
    else:
        timed("carriers per technology", """
SELECT d.technology,
       coalesce(t.code_desc, 'UNKNOWN CODE') AS technology_name,
       count(*) AS carriers
FROM (SELECT DISTINCT technology, provider_id
      FROM bdc_availability_tbl) d
LEFT JOIN bdc_technology_tbl t ON t.technology = d.technology
GROUP BY d.technology, t.code_desc ORDER BY count(*) DESC""")

    if args.full:
        print("--full: tracts per technology. This one needs the heap, "
              "because the tract index does not carry technology, so it is "
              "a scan of every row. On 519 million rows expect minutes, "
              "not seconds.\n", flush=True)
        timed("tracts per technology, full heap scan", """
SELECT d.technology,
       coalesce(t.code_desc, 'UNKNOWN CODE') AS technology_name,
       count(*) AS tracts
FROM (SELECT DISTINCT technology, left(block_geoid, 11) AS tract_geoid
      FROM bdc_availability_tbl) d
LEFT JOIN bdc_technology_tbl t ON t.technology = d.technology
GROUP BY d.technology, t.code_desc ORDER BY count(*) DESC""")
    else:
        print("Tracts per technology is NOT run by default: it cannot use "
              "an index and must read every row. Add --full when you want "
              "it.\n")

    # THE FIOS VERSUS xDSL CASE, RANKED BY RECORDS NOT BY DISTINCT TRACTS.
    #
    # This query is why the whole command needed rethinking. It asked for
    # count(DISTINCT tract_geoid) grouped by carrier AND technology, and
    # then ORDERED BY that same distinct count, over 519,469,683 rows. Every
    # group gets its own sort of its tract values and the ordering cannot
    # start until all of them are done. It also referenced a variable I had
    # removed, so it would have failed outright, which I found by running it
    # rather than by reading it.
    #
    # Ranking by record count answers the same question. The point is to
    # show one carrier appearing under several technology codes, so that
    # Verizon FIOS can be separated from Verizon xDSL; which of the two
    # carries more census tracts is not what that comparison needs, and
    # records are a plain aggregate.
    #
    # --full restores the tract counts for the carriers already selected,
    # which is a far smaller problem than computing them for all of them.
    print("\nThe FIOS versus xDSL case: one carrier, several technologies.")
    print("Top 25 carrier and technology pairs by RECORD count. Records "
          "rather than distinct tracts: the comparison is about one carrier "
          "appearing under several codes, and a distinct count per group "
          "sorts every group separately.\n")
    if lean:
        timed("carrier and technology pairs", """
SELECT c.provider_id, left(c.brand_name, 28) AS brand,
       a.technology,
       coalesce(t.code_desc, 'UNKNOWN CODE') AS technology_name,
       count(*) AS records
FROM bdc_availability_tbl a
JOIN bdc_carrier_tbl c USING (carrier_key)
LEFT JOIN bdc_technology_tbl t ON t.technology = a.technology
GROUP BY c.provider_id, left(c.brand_name, 28), a.technology, t.code_desc
ORDER BY count(*) DESC
LIMIT 25""")
    else:
        timed("carrier and technology pairs", """
SELECT a.provider_id, left(a.brand_name, 28) AS brand, a.technology,
       coalesce(t.code_desc, 'UNKNOWN CODE') AS technology_name,
       count(*) AS records
FROM bdc_availability_tbl a
LEFT JOIN bdc_technology_tbl t ON t.technology = a.technology
GROUP BY a.provider_id, left(a.brand_name, 28), a.technology, t.code_desc
ORDER BY count(*) DESC
LIMIT 25""")

    if args.full and lean:
        print("--full: distinct tracts for the 25 largest pairs only.\n",
              flush=True)
        timed("tracts for the largest pairs", """
WITH top AS (
  SELECT a.carrier_key, a.technology, count(*) AS records
  FROM bdc_availability_tbl a
  GROUP BY a.carrier_key, a.technology
  ORDER BY count(*) DESC
  LIMIT 25)
SELECT c.provider_id, left(c.brand_name, 28) AS brand, t.technology,
       coalesce(x.code_desc, 'UNKNOWN CODE') AS technology_name,
       t.records,
       (SELECT count(DISTINCT left(a2.block_geoid, 11))
        FROM bdc_availability_tbl a2
        WHERE a2.carrier_key = t.carrier_key
          AND a2.technology = t.technology) AS tracts
FROM top t JOIN bdc_carrier_tbl c USING (carrier_key)
LEFT JOIN bdc_technology_tbl x ON x.technology = t.technology
ORDER BY t.records DESC""")


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


STATE_FIPS_RE = re.compile(r"^bdc_(\d{2})_")


def fips_of(name):
    m = STATE_FIPS_RE.match(name)
    return m.group(1) if m else None


def cmd_states(args):
    """Per state FIPS: what is on disk against what the database records.

    READ ONLY, AND IT TAKES NO LOCK. Safe to run while a load is in
    progress, which is the situation it was written for. It does not
    decompress anything, so it returns in seconds; `verify` is the one that
    reads the files and it costs minutes.

    WHY THIS EXISTS

    Boris, 2026-11-18: "BDC load skipped territories 32-45. Territories
    starting with 45 (partial) are being loaded."

    A file is skipped when bdc_source_file_tbl.row_count is above zero for
    it, so a file can be skipped for two quite different reasons and the log
    looks the same either way: it genuinely loaded, or it was recorded with
    a count that does not match the file. This separates them as far as it
    can without decompressing, and it also names the files that are on disk
    and not recorded AT ALL, which is the case a skip count cannot show.

    I am not going to tell you WHY 32 to 45 were missed until the numbers
    say so. The two candidates I can think of are a file that was not yet
    downloaded when the running loader expanded its glob, and a file
    recorded with a row_count from a load that did not finish. They look
    different here: the first is "on disk, not recorded", the second is
    "recorded, count suspicious". The output distinguishes them.
    """
    require_schema()
    lean = schema_is_lean()
    already = loaded_counts(lean)

    names = [os.path.basename(p) for p in args.files]
    lo, hi = args.from_fips, args.to_fips

    rows = []
    for n in sorted(names):
        f = fips_of(n)
        if f is None:
            rows.append((None, n, already.get(n)))
            continue
        if lo and f < lo:
            continue
        if hi and f > hi:
            continue
        rows.append((f, n, already.get(n)))

    if not rows:
        print(f"No files given match FIPS {lo or '00'} to {hi or '99'}. "
              f"{len(names)} file(s) were supplied.")
        return

    by_fips = {}
    for f, n, cnt in rows:
        by_fips.setdefault(f, []).append((n, cnt))

    print(f"FIPS range {lo or '00'} to {hi or '99'}, "
          f"{len(rows)} file(s) on disk in range\n")
    print(f"{'fips':<6}{'on_disk':>8}{'recorded':>10}{'not_rec':>9}"
          f"{'zero':>7}{'thin':>7}  rows_recorded")

    missing = []
    thin_files = []
    zero_files = []
    for f in sorted(by_fips, key=lambda x: (x is None, x)):
        fl = by_fips[f]
        rec = [(n, c) for n, c in fl if c is not None]
        notrec = [n for n, c in fl if c is None]
        zero = [n for n, c in rec if c == 0]
        thin = [n for n, c in rec if 0 < c < 100]
        total = sum(c for _, c in rec)
        missing.extend(notrec)
        zero_files.extend(zero)
        thin_files.extend(thin)
        print(f"{f or '??':<6}{len(fl):>8}{len(rec):>10}{len(notrec):>9}"
              f"{len(zero):>7}{len(thin):>7}  {total:>14,}")

    print()
    if missing:
        print(f"{len(missing)} FILE(S) ON DISK WITH NO RECORD AT ALL. These "
              f"were never loaded, not even partly. A running loader expands "
              f"its --files glob ONCE at startup, so a file that finished "
              f"downloading after that is not in its list and will not be "
              f"picked up however long the load runs.")
        for n in missing[:40]:
            print(f"    {n}")
        if len(missing) > 40:
            print(f"    ... and {len(missing) - 40} more")
        print()
    if zero_files:
        print(f"{len(zero_files)} file(s) are recorded with ZERO rows, which "
              f"counts as not loaded and will be retried by a normal load:")
        for n in zero_files[:20]:
            print(f"    {n}")
        print()
    if thin_files:
        print(f"{len(thin_files)} file(s) are recorded with fewer than 100 "
              f"rows. The Other technology files are genuinely tiny, so this "
              f"is not by itself wrong, and only reading the file settles "
              f"it. `verify` on just these is cheap:")
        for n in thin_files[:20]:
            print(f"    {already.get(n):>6,} rows  {n}")
        print()

    if missing:
        print("TO LOAD THE UNRECORDED FILES, and nothing else. This adds "
              "rows for files that have none and does not touch any file "
              "already loaded, so there is nothing to undo:")
        print(f"    sh {here('reload_states.sh')} "
              f"--from {lo or '00'} --to {hi or '99'}")
        print()
        print("DO NOT RUN IT WHILE ANOTHER LOAD IS RUNNING. The loader "
              "currently on your machine predates the advisory lock, so it "
              "will not refuse a second one and the two would share one "
              "staging table. Wait for the running load to finish. Check "
              "with, one short line per loader:")
        print("    pgrep -f bdc_load.py | xargs -r -n1 ps -o pid=,etime=,"
              "comm= -p | awk '$3 ~ /^python/'")
    else:
        print("Every file in range is recorded. If rows are still missing "
              "the counts are wrong rather than absent, and `verify` on this "
              "range is what shows that, by reading the files:")
        print(f"    python3 -u {SELF} verify --files "
              f"$(ls /home/boris/geo/bdc/bdc_{lo or ''}*.zip)")


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
        print(f"\n  python3 -u {SELF} load --replace --files "
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
    te.add_argument("--full", action="store_true",
                    help="also count distinct tracts per technology, which "
                         "cannot use an index and reads every row")
    te.set_defaults(func=cmd_technologies)

    ve = sub.add_parser("verify",
                        help="read every download and compare its row count "
                             "with what is loaded; the only way to detect a "
                             "file recorded as loaded but short")
    ve.add_argument("--files", nargs="+", required=True)
    ve.add_argument("--all", action="store_true",
                    help="list every file, not only the mismatches")
    ve.set_defaults(func=cmd_verify)

    sa = sub.add_parser("states",
                        help="per state FIPS, what is on disk against what "
                             "is recorded. Read only, takes no lock, safe "
                             "to run during a load")
    sa.add_argument("--files", nargs="+", required=True)
    sa.add_argument("--from", dest="from_fips", default=None,
                    help="lowest two-digit state FIPS to report, e.g. 32")
    sa.add_argument("--to", dest="to_fips", default=None,
                    help="highest two-digit state FIPS to report, e.g. 45")
    sa.set_defaults(func=cmd_states)

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
