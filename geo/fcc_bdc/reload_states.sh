#!/bin/sh
# reload_states.sh - load the BDC files of a state FIPS range that the
# running load missed.
#
# WHY THIS EXISTS
#
# Boris, 2026-11-18: "BDC load skipped territories 32-45. Territories
# starting with 45 (partial) are being loaded. Issue corrective code to
# reload the missed files in 32-45."
#
# WHAT IT WILL AND WILL NOT DO
#
# It loads only files in the range that the database has NO record of. A
# file already recorded is skipped by the loader itself, so nothing already
# loaded is touched, nothing is deleted and there is nothing to undo. It
# does not pass --replace and it never will: replacing rows is a different
# decision and belongs in a different command.
#
# IT REFUSES TO RUN WHILE ANOTHER LOAD IS RUNNING, and that refusal is the
# main reason this script exists rather than a bare command line. The loader
# on the machine right now predates the advisory lock, so it will NOT refuse
# a second loader, and two loaders share one staging table. That is what
# produced "relation bdc_stage_tbl does not exist" in the middle of a
# working run on 2026-11-17.
#
# USAGE
#
#   sh geo/fcc_bdc/reload_states.sh --from 32 --to 45
#   sh geo/fcc_bdc/reload_states.sh --from 32 --to 45 --dry-run
#   sh geo/fcc_bdc/reload_states.sh --from 32 --to 45 --force
#
# --dry-run reports what it would load and loads nothing.
# --force skips the running-loader check. Do not use it unless you have
# confirmed yourself that no other loader is running.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

BDCDIR=${BDCDIR:-/home/boris/geo/bdc}
LOGDIR=${LOGDIR:-/home/boris/geo/logs}
FROM=""
TO=""
DRY=0
FORCE=0
FG=0

while [ -n "${1-}" ]; do
    case "$1" in
        --from) shift; FROM=$1 ;;
        --to) shift; TO=$1 ;;
        --dir) shift; BDCDIR=$1 ;;
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        --foreground) FG=1 ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

if [ -z "$FROM" ] || [ -z "$TO" ]; then
    echo "Both --from and --to are required, as two-digit state FIPS codes."
    echo "For the range Boris reported missing:"
    echo "  sh geo/fcc_bdc/reload_states.sh --from 32 --to 45"
    exit 2
fi

if [ ! -d "$BDCDIR" ]; then
    echo "No such directory: $BDCDIR"
    exit 1
fi
mkdir -p "$LOGDIR" || exit 1

LOG="$LOGDIR/bdc_reload_${FROM}_${TO}.log"

echo "BDC reload, state FIPS $FROM to $TO"
echo "downloads: $BDCDIR"
echo

# THE RUNNING-LOADER CHECK.
#
# pgrep gives the pids, then ps is asked for pid, elapsed time and command
# NAME only. It is deliberately not asked for the command line: the loader
# is invoked with every zip path as an argument, so the full command line is
# enormous. MEASURED with 333 paths: ps -eo pid,etime,cmd piped through grep
# emitted 28,847 characters. The form below emits about 48 per loader.
others=$(pgrep -f bdc_load.py 2>/dev/null | while read -r p; do
    ps -o pid=,etime=,comm= -p "$p" 2>/dev/null
done | awk '$3 ~ /^python/')

if [ -n "$others" ]; then
    echo "ANOTHER LOADER IS RUNNING:"
    echo "$others" | sed 's/^/    /'
    echo
    if [ "$FORCE" -eq 0 ]; then
        echo "STOPPED, and nothing was changed."
        echo
        echo "Two loaders share one staging table, and the loader running"
        echo "now predates the advisory lock so it will not refuse a second"
        echo "one. Running both can load a file twice and can abort the"
        echo "running load partway."
        echo
        echo "Wait for it to finish, then run this again. Nothing is lost by"
        echo "waiting: this script only loads files that have no rows at"
        echo "all, and the running loader cannot reach them, because a"
        echo "loader expands its file list once at startup."
        echo
        echo "To watch the running load:"
        echo "  tail -f $LOGDIR/bdc_load_resume.log"
        exit 1
    fi
    echo "--force was given, continuing anyway."
    echo
fi

# THE FILE LIST. Built by state FIPS from the file name, which is where the
# FCC puts it: bdc_<fips>_<technology>_fixed_broadband_<vintage>.zip
files=""
count=0
for p in "$BDCDIR"/bdc_*.zip; do
    [ -f "$p" ] || continue
    b=$(basename "$p")
    f=$(echo "$b" | sed 's/^bdc_//' | cut -c1-2)
    case "$f" in
        [0-9][0-9]) ;;
        *) continue ;;
    esac
    if [ "$f" \< "$FROM" ] || [ "$f" \> "$TO" ]; then
        continue
    fi
    files="$files $p"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "No files in $BDCDIR with a state FIPS between $FROM and $TO."
    echo "File names are expected to look like"
    echo "  bdc_44_Cable_fixed_broadband_J26_10nov2026.zip"
    echo "Present names, first five:"
    ls "$BDCDIR" 2>/dev/null | head -5 | sed 's/^/    /'
    exit 1
fi

echo "$count file(s) on disk in range $FROM to $TO"
echo

# THE AUDIT FIRST, ALWAYS. It is read only, it takes no lock and it returns
# in seconds because it decompresses nothing. It is what says which files
# have no record at all, as against which are recorded with a count that
# looks wrong.
echo "Audit of what the database already has:"
echo
python3 -u geo/fcc_bdc/bdc_load.py states --from "$FROM" --to "$TO" \
    --files $files
echo

if [ "$DRY" -eq 1 ]; then
    echo "--dry-run, so nothing was loaded."
    exit 0
fi

echo "Loading. Files already recorded are skipped by the loader itself."
echo "log: $LOG"
echo

if [ "$FG" -eq 1 ]; then
    exec python3 -u geo/fcc_bdc/bdc_load.py load --files $files
fi

# python3 -u, UNBUFFERED. Python block-buffers stdout when it is a file, so
# a redirected run writes nothing until several kilobytes accumulate.
# MEASURED: without -u the log is 0 bytes after two seconds.
nohup python3 -u geo/fcc_bdc/bdc_load.py load --files $files > "$LOG" 2>&1 &
pid=$!
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
head -12 "$LOG" | sed 's/^/    /'
