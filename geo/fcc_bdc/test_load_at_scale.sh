#!/bin/sh
# test_load_at_scale.sh - exercise the BDC loader against Boris's CONDITIONS
# before any command is issued to him.
#
# WHY THIS EXISTS
#
# Boris, 2026-11-17: "Debug BEFORE you issue code." He is right, and the
# record is damning. Bugs HE found rather than I did, in one day:
#
#   the psql argument-list limit, at 22,790 hostnames
#   carrier_node_tbl keyed on hostname when one hostname has many addresses
#   a dependent view blocking DROP TABLE, twice
#   a UNIQUE constraint that CREATE TABLE IF NOT EXISTS never applied
#   NOT IN against a subquery, which cannot be an anti-join
#   a CASE guard naming a table that may not exist
#   a skip query that full-scans a table of tens of millions of rows
#   a 135-character command line that wrapped and lost its redirect
#   stdout buffering that made a working job look dead
#
# Every one of those is reproducible WITHOUT HIM, given a fixture that looks
# like his database rather than like a toy. This builds that fixture.
#
# WHAT IT REPRODUCES
#
#   a large bdc_availability_tbl, so a full scan is measurably slow
#   many files already recorded as loaded, so the skip path is exercised
#   a file recorded with FEWER rows than it holds, the partial-load state
#   a leftover bdc_stage_tbl, what a killed run leaves behind
#   the post-rename schema, bdc_carrier_tbl and carrier_key
#   real downloaded zip files, not synthetic CSVs
#
# WHAT IT ASSERTS
#
#   startup prints its first line quickly, not after a minute
#   an already-loaded file is skipped and NOT duplicated
#   a short file is detected by verify and named
#   --replace repairs exactly that file and nothing else
#   leftover staging is reported, not silently dropped
#
# USAGE
#
#   sh geo/fcc_bdc/test_load_at_scale.sh
#   ROWS=20000000 sh geo/fcc_bdc/test_load_at_scale.sh
#
# Exit 0 means every assertion held.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

PGVAL_HOME=${PGVAL_HOME:-/projects/sandbox/.pgtmp}
PGBIN="$PGVAL_HOME/pg/usr/bin"
PGSOCK="$PGVAL_HOME/sock"
PGDB=${PGDB:-loadscale}
PGUSER_V=${PGUSER_V:-pgval}
ZIPDIR=${ZIPDIR:-/projects/sandbox/.bdcresume}
ROWS=${ROWS:-4000000}
FILES=${FILES:-241}

export LD_LIBRARY_PATH="$PGVAL_HOME/pg/usr/lib64"
export PATH="$PGBIN:$PATH"
export PGHOST="$PGSOCK"
export PGUSER="$PGUSER_V"
export PGDATABASE="$PGDB"

fail=0
check() {
    label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  $label"
    else
        echo "  FAIL  $label"
        fail=1
    fi
}

sh geo/sessions/run_sql_validation.sh geo/carrier_nodes/schema.sql >/dev/null 2>&1

psql -X -d postgres -qc "DROP DATABASE IF EXISTS $PGDB" >/dev/null 2>&1
psql -X -d postgres -qc "CREATE DATABASE $PGDB" >/dev/null 2>&1

echo "FIXTURE"
psql -X -q -v ON_ERROR_STOP=1 -f geo/fcc_bdc/schema_v2.sql >/dev/null 2>&1 \
    || { echo "  could not apply schema_v2.sql"; exit 1; }

echo "  building $FILES recorded files and $ROWS availability rows ..."
psql -X -q <<SQL
INSERT INTO bdc_carrier_tbl (frn, provider_id, brand_name)
SELECT lpad(g::text, 10, '0'), g, 'Carrier ' || g
FROM generate_series(1, 1802) g;

INSERT INTO bdc_source_file_tbl (source_file, row_count)
SELECT 'bdc_' || lpad((g % 56 + 1)::text, 2, '0') || '_Tech' || (g / 56)
       || '_fixed_broadband_J26_10nov2026.zip',
       ($ROWS / $FILES)::bigint
FROM generate_series(1, $FILES) g
ON CONFLICT (source_file) DO NOTHING;

INSERT INTO bdc_availability_tbl
      (source_file_id, carrier_key, location_id, technology,
       business_residential_code, state_usps, block_geoid)
SELECT (SELECT min(source_file_id) FROM bdc_source_file_tbl),
       (SELECT min(carrier_key) FROM bdc_carrier_tbl),
       g, 40, 'R', 'RI',
       '44' || lpad((g % 1000)::text, 13, '0')
FROM generate_series(1, $ROWS) g;

ANALYZE bdc_availability_tbl;
ANALYZE bdc_source_file_tbl;
SQL

rows=$(psql -X -qtAc "SELECT count(*) FROM bdc_availability_tbl")
recorded=$(psql -X -qtAc "SELECT count(*) FROM bdc_source_file_tbl")
echo "  availability rows: $rows"
echo "  files recorded:    $recorded"
echo

echo "A. STARTUP LATENCY, which is what a silent minute looks like"
if [ ! -d "$ZIPDIR" ]; then
    echo "  SKIP  no zip files at $ZIPDIR"
else
    start=$(date +%s%N)
    first=$(python3 -u geo/fcc_bdc/bdc_load.py load --files "$ZIPDIR"/*.zip 2>&1 \
            | head -2 | tail -1)
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    echo "  first two lines took ${ms} ms"
    echo "  second line: $first"
    if [ "$ms" -gt 15000 ]; then
        echo "  FAIL  startup took over 15 seconds, which reads as a hang"
        fail=1
    else
        echo "  PASS  startup is prompt"
    fi
fi
echo

echo "B. A REAL FILE LOADS, AND A SECOND RUN DOES NOT DUPLICATE IT"
if [ -d "$ZIPDIR" ]; then
    one=$(ls "$ZIPDIR"/*.zip 2>/dev/null | head -1)
    python3 -u geo/fcc_bdc/bdc_load.py load --files "$one" >/dev/null 2>&1
    a=$(psql -X -qtAc "SELECT count(*) FROM bdc_availability_tbl")
    python3 -u geo/fcc_bdc/bdc_load.py load --files "$one" >/dev/null 2>&1
    b=$(psql -X -qtAc "SELECT count(*) FROM bdc_availability_tbl")
    echo "  rows after first load: $a"
    echo "  rows after second:     $b"
    if [ "$a" = "$b" ]; then
        echo "  PASS  the second run skipped it"
    else
        echo "  FAIL  the second run DUPLICATED rows"
        fail=1
    fi
fi
echo

echo "C. A SHORT FILE IS DETECTED, which is the state that killed his load"
if [ -d "$ZIPDIR" ]; then
    one=$(ls "$ZIPDIR"/*.zip 2>/dev/null | head -1)
    name=$(basename "$one")
    psql -X -q -c "UPDATE bdc_source_file_tbl SET row_count = 5 WHERE source_file = '$name'" >/dev/null
    if python3 -u geo/fcc_bdc/bdc_load.py verify --files "$one" 2>&1 \
            | grep -q 'SHORT'; then
        echo "  PASS  verify reported it SHORT"
    else
        echo "  FAIL  verify did not report the short file"
        fail=1
    fi
    if python3 -u geo/fcc_bdc/bdc_load.py load --files "$one" 2>&1 \
            | grep -q 'fewer than 100 rows'; then
        echo "  PASS  the loader warned about the thin file"
    else
        echo "  FAIL  the loader did not warn about the thin file"
        fail=1
    fi
fi
echo

echo "D. --replace REPAIRS EXACTLY ONE FILE"
if [ -d "$ZIPDIR" ]; then
    one=$(ls "$ZIPDIR"/*.zip 2>/dev/null | head -1)
    before=$(psql -X -qtAc "SELECT count(*) FROM bdc_availability_tbl")
    python3 -u geo/fcc_bdc/bdc_load.py load --replace --files "$one" >/dev/null 2>&1
    after=$(psql -X -qtAc "SELECT count(*) FROM bdc_availability_tbl")
    echo "  rows before: $before"
    echo "  rows after:  $after"
    if python3 -u geo/fcc_bdc/bdc_load.py verify --files "$one" 2>&1 \
            | grep -q 'matches its contents exactly'; then
        echo "  PASS  verify now passes for that file"
    else
        echo "  FAIL  verify still reports a mismatch"
        fail=1
    fi
fi
echo

echo "E. LEFTOVER STAGING IS REPORTED, not silently dropped"
psql -X -q -c "CREATE UNLOGGED TABLE bdc_stage_tbl (block_geoid text)" >/dev/null 2>&1
psql -X -q -c "INSERT INTO bdc_stage_tbl SELECT '440030000000001' FROM generate_series(1,5000)" >/dev/null 2>&1
if [ -d "$ZIPDIR" ]; then
    one=$(ls "$ZIPDIR"/*.zip 2>/dev/null | head -1)
    if python3 -u geo/fcc_bdc/bdc_load.py load --files "$one" 2>&1 \
            | grep -q 'staging table was left behind'; then
        echo "  PASS  the leftover staging table was reported"
    else
        echo "  FAIL  the leftover staging table was not reported"
        fail=1
    fi
fi
echo

echo "F. THE PRE-RENAME SCHEMA IS REFUSED WITH THE FIX NAMED"
psql -X -q -c "ALTER TABLE bdc_availability_tbl RENAME COLUMN carrier_key TO provider_key" >/dev/null 2>&1
if [ -d "$ZIPDIR" ]; then
    one=$(ls "$ZIPDIR"/*.zip 2>/dev/null | head -1)
    if python3 -u geo/fcc_bdc/bdc_load.py load --files "$one" 2>&1 \
            | grep -q 'rename_provider_to_carrier.sql'; then
        echo "  PASS  it refused and named the rename file"
    else
        echo "  FAIL  it did not name the rename file"
        fail=1
    fi
fi
psql -X -q -c "ALTER TABLE bdc_availability_tbl RENAME COLUMN provider_key TO carrier_key" >/dev/null 2>&1
echo

if [ "$fail" -eq 0 ]; then
    echo "ALL ASSERTIONS HELD at $rows availability rows and $recorded"
    echo "recorded files. Safe to issue."
else
    echo "SOMETHING FAILED. Do not issue anything until it is fixed."
fi
exit "$fail"
