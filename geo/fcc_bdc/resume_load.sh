#!/bin/sh
# resume_load.sh - resume the BDC availability load in the background.
#
# WHY THIS EXISTS
#
# The command it replaces was one long line:
#
#   nohup python3 geo/fcc_bdc/bdc_load.py load --files /home/boris/geo/bdc/*.zip > /home/boris/geo/logs/bdc_load_resume.log 2>&1 &
#
# That is 135 characters. Pasted into Boris's terminal it wrapped, part of it
# was consumed as a separate command, the redirect never took effect and the
# log file did not exist. Residue from the split was visible on his prompt
# line. Long single-line commands are a known hazard in his paste path and I
# should not be emitting them.
#
# So the long line lives here and he pastes one short one.
#
# WHAT IT DOES
#
# Resumes the load. bdc_load.py SKIPS any file already loaded, so this is
# safe to run repeatedly and picks up wherever the last run stopped. It
# writes nothing except availability rows and the per-file record of what was
# loaded.
#
# IT CHECKS THE SCHEMA FIRST. bdc_provider_tbl was renamed to
# bdc_carrier_tbl on 2026-11-17, and a load started before that rename kept
# writing the old name and failed. If the rename has not been applied this
# stops and says so rather than starting a job that will die partway.
#
# USAGE
#
#   sh geo/fcc_bdc/resume_load.sh
#   sh geo/fcc_bdc/resume_load.sh --foreground
#
# Background is the default because a full load takes hours. The script
# prints the log path and the command to follow it.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

BDCDIR=${BDCDIR:-/home/boris/geo/bdc}
LOGDIR=${LOGDIR:-/home/boris/geo/logs}
LOG="$LOGDIR/bdc_load_resume.log"
FOREGROUND=0

while [ -n "${1-}" ]; do
    case "$1" in
        --foreground) FOREGROUND=1 ;;
        --dir) shift; BDCDIR=$1 ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

if [ ! -d "$BDCDIR" ]; then
    echo "No such directory: $BDCDIR"
    exit 1
fi

mkdir -p "$LOGDIR" || exit 1

count=$(ls "$BDCDIR" 2>/dev/null | grep -c '\.zip$')
if [ "$count" -eq 0 ]; then
    echo "No .zip files in $BDCDIR. Nothing to load."
    exit 1
fi
echo "$count zip file(s) in $BDCDIR"

# The schema check, before starting anything long.
shape=$(psql -X -qtA -c "
SELECT CASE
  WHEN to_regclass('bdc_availability_tbl') IS NULL THEN 'no_table'
  WHEN EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='bdc_availability_tbl'
                 AND column_name='provider_key') THEN 'pre_rename'
  WHEN EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='bdc_availability_tbl'
                 AND column_name='carrier_key') THEN 'renamed'
  WHEN EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='bdc_availability_tbl'
                 AND column_name='source_file') THEN 'wide'
  ELSE 'unknown' END" 2>/dev/null)

case "$shape" in
    pre_rename)
        echo
        echo "STOPPED. bdc_availability_tbl still has the column provider_key,"
        echo "which this loader no longer writes. Nothing was started."
        echo "Apply the rename first, then run this again:"
        echo
        echo "  psql -X -P pager=off -f geo/fcc_bdc/rename_provider_to_carrier.sql"
        echo
        echo "It carries the data over and is idempotent. Files already"
        echo "loaded are skipped when you resume."
        exit 1
        ;;
    no_table|unknown)
        echo
        echo "STOPPED. bdc_availability_tbl is absent or has a shape I do not"
        echo "recognise, reported as: $shape. Nothing was started."
        exit 1
        ;;
    renamed)  echo "schema: normalised, post-rename" ;;
    wide)     echo "schema: original wide table" ;;
esac

loaded=$(psql -X -qtA -c "SELECT count(*) FROM bdc_source_file_tbl" 2>/dev/null)
echo "files already recorded as loaded: ${loaded:-unknown}"
echo "log: $LOG"
echo

# python3 -u, UNBUFFERED. Python block-buffers stdout when it is a file, so
# a redirected run writes nothing until several kilobytes have accumulated.
# MEASURED: without -u a script that prints and sleeps leaves the file at 0
# bytes after two seconds; with -u the bytes are there immediately.
#
# For a job that runs for hours that is the difference between watching
# progress and watching an empty file and concluding it has hung, which has
# already happened twice in this project for other reasons.
if [ "$FOREGROUND" -eq 1 ]; then
    exec python3 -u geo/fcc_bdc/bdc_load.py load --files "$BDCDIR"/*.zip
fi

nohup python3 -u geo/fcc_bdc/bdc_load.py load --files "$BDCDIR"/*.zip > "$LOG" 2>&1 &
pid=$!
# Long enough for the loader to print its first lines even while it is
# skipping a few hundred already-loaded files.
sleep 5

if [ ! -f "$LOG" ]; then
    echo "The log file was not created, which should be impossible."
    echo "Run with --foreground to see the output directly."
    exit 1
fi

echo "started, pid $pid"
echo
echo "Follow it with:"
echo "  tail -f $LOG"
echo
echo "First lines so far:"
head -6 "$LOG" | sed 's/^/    /'
