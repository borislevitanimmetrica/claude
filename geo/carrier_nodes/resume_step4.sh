#!/bin/sh
# resume_step4.sh - resume the ITDK chain at step 4 and run it to the end.
#
# WHY THIS EXISTS
#
# Boris, 2026-11-18: "Issue code to resume the ITDK work with step 4." Step 4
# of run_step2.sh is the crosswalk of the four naming systems. Steps 1 to 3
# are the rename, the carrier_nodes schema and the hoiho decode, and rerunning
# them is not merely wasted work: step 2 DROPS and recreates carrier_node_tbl
# when it migrates the key, which would discard the 22,790 decoded rows that
# step 3 produced and that step 4 reads.
#
# So this skips 1 to 3 and starts at 4.
#
#   4. geo/carrier_nodes/carrier_crosswalk.sql
#   5. geo/carrier_nodes/carrier_decisions.sql
#   6. load_decisions.py, which also re-runs resolve_asn.sql
#
# IT CHECKS THE INPUTS FIRST, AND REPORTS WHAT IS ABSENT
#
# Boris, 2026-11-17: "the table name you used does not exist." I did not
# identify which name he meant and I am not going to guess at it. Instead
# this names every relation the remaining steps read or write and says which
# of them exist, before running anything. That answers the question with the
# database rather than with my recollection, and it is read only.
#
# WHAT IT CAN LOSE
#
# PRE-MORTEM. carrier_crosswalk.sql deletes the UNAPPROVED rows of
# carrier_crosswalk_tbl so that a rerun regenerates proposals from the data
# as it now stands; rows Boris has approved are kept. carrier_decisions.sql
# rebuilds the ASN and resolved tables, which are derived in full from the
# decisions TSV in the repository and from the crosswalk, so they cost
# seconds to rebuild and hold no hand-entered state. carrier_node_tbl is NOT
# touched by any step here, and neither is any BDC table. Nothing in this
# chain writes to bdc_availability_tbl.
#
# USAGE
#
#   sh geo/carrier_nodes/resume_step4.sh
#   sh geo/carrier_nodes/resume_step4.sh --check-only
#
# Run from the repository root.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

LOGDIR=${LOGDIR:-/home/boris/geo/logs}
DECISIONS=${DECISIONS:-geo/carrier_nodes/decisions_2026_11_17.tsv}
CHECK_ONLY=0

while [ -n "${1-}" ]; do
    case "$1" in
        --check-only) CHECK_ONLY=1 ;;
        --decisions)  shift; DECISIONS=$1 ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOGDIR" || exit 1

echo "Resuming the ITDK chain at step 4, the four-source crosswalk."
echo "Logs under $LOGDIR"
echo

# IS A BDC LOAD RUNNING. The crosswalk reads bdc_carrier_tbl, and a load in
# progress is still inserting into it, so a crosswalk run now would propose
# against a table that is still growing. That is not a corruption risk, it
# just means the proposals are a snapshot of an incomplete BDC. Reported, not
# refused: the measured ITDK, ip-api and RDAP columns do not depend on BDC at
# all and are worth having either way.
#
# ps is asked for pid, elapsed and command NAME only, never the command line.
# The loader is invoked with every zip path as an argument, so the full line
# is enormous. MEASURED with 333 paths: ps -eo pid,etime,cmd through grep
# emitted 28,847 characters. This emits about 48 per loader.
loaders=$(pgrep -f bdc_load.py 2>/dev/null | while read -r p; do
    ps -o pid=,etime=,comm= -p "$p" 2>/dev/null
done | awk '$3 ~ /^python/')

if [ -n "$loaders" ]; then
    echo "NOTE: a BDC load is running:"
    echo "$loaders" | sed 's/^/    /'
    echo
    echo "The BDC name proposals will reflect only the carriers loaded so"
    echo "far. The ITDK, ip-api and RDAP columns are linked by measurement"
    echo "and do not depend on the BDC load at all, so they are complete"
    echo "either way. Rerun this after the load finishes to refresh the"
    echo "proposals; it deletes only unapproved rows, so approvals survive."
    echo
fi

echo "INPUT RELATIONS, before anything runs:"
echo
psql -X -P pager=off -c "
SELECT z.relname AS relation,
       CASE WHEN to_regclass(z.relname) IS NULL THEN 'ABSENT' ELSE 'present' END AS state,
       z.role
FROM (VALUES
  ('carrier_node_tbl',           'read: decoded hostnames, step 3 output'),
  ('hoiho_rule_tbl',             'read: CAIDA regexes'),
  ('hoiho_geohint_tbl',          'read: CAIDA place codes'),
  ('ip2city_dbiplite_probe_tbl', 'read: ip-api identities by range'),
  ('rdap_registrant_tbl',        'read: RDAP registrants'),
  ('ovt_places_usa_ip_trace',    'read: traceroute corpus'),
  ('bdc_carrier_tbl',            'read: FCC BDC carrier names'),
  ('carrier_crosswalk_tbl',      'WRITTEN by step 4'),
  ('carrier_name_observed_tbl',  'WRITTEN by step 4'),
  ('carrier_decision_tbl',       'WRITTEN by step 5'),
  ('asn_operator_tbl',           'WRITTEN by step 5'),
  ('asn_bdc_name_tbl',           'WRITTEN by step 5'),
  ('carrier_resolved_tbl',       'WRITTEN by step 5')
) AS z(relname, role)
ORDER BY (to_regclass(z.relname) IS NULL) DESC, z.relname"
echo

# THE ONES THAT MUST ALREADY EXIST. A relation written by step 4 or 5 being
# absent is normal, that is what this run creates. A relation step 4 READS
# being absent is not something this chain can fix.
missing=$(psql -X -qtA -c "
SELECT string_agg(relname, ', ' ORDER BY relname)
FROM (VALUES
  ('carrier_node_tbl'), ('ip2city_dbiplite_probe_tbl'), ('ovt_places_usa_ip_trace')
) AS z(relname)
WHERE to_regclass(relname) IS NULL" 2>/dev/null)

if [ -n "$missing" ]; then
    echo "STOPPED, and nothing was run."
    echo
    echo "Step 4 READS these and they are absent: $missing"
    echo
    echo "  carrier_node_tbl            built by steps 2 and 3. If this is"
    echo "                              the absent one, the chain has to"
    echo "                              start earlier:"
    echo "                                sh geo/carrier_nodes/run_step2.sh"
    echo "  ip2city_dbiplite_probe_tbl  the ip-api probe estate"
    echo "  ovt_places_usa_ip_trace     the traceroute corpus"
    echo
    echo "The last two are not built by this project's step 2 at all."
    exit 1
fi

nodes=$(psql -X -qtAc "SELECT count(*) FROM carrier_node_tbl" 2>/dev/null)
located=$(psql -X -qtAc "SELECT count(*) FROM carrier_node_tbl WHERE lat IS NOT NULL" 2>/dev/null)
echo "carrier_node_tbl holds ${nodes:-0} rows, ${located:-0} with coordinates."
if [ "${nodes:-0}" = "0" ]; then
    echo
    echo "STOPPED, and nothing was run."
    echo
    echo "carrier_node_tbl is EMPTY, so step 4 would produce a blank"
    echo "crosswalk and a blank approval list. That has happened before:"
    echo "schema.sql dropped the table and the crosswalk ran against"
    echo "nothing. Step 3 refills it:"
    echo "  python3 -u geo/carrier_nodes/hoiho_apply.py --dir /home/boris/geo/caida apply"
    exit 1
fi
echo

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "--check-only, so nothing was run."
    exit 0
fi

step=3

# A HEARTBEAT WHILE EACH STEP RUNS.
#
# Boris, repeatedly, most recently 2026-11-17: "I asked you for frequent
# feedback in all operations", and before that "sh does not return anything
# in one minute."
#
# The crosswalk step took FOURTEEN MINUTES on his corpus, and the version of
# this runner that printed only ok or FAILED showed nothing at all for the
# whole of it. From outside that is indistinguishable from a hang, and he has
# now had to ask whether a job was alive more than once.
#
# So each step runs in the background and this polls it: elapsed seconds, how
# many lines the step's log has reached, and the last line of it. The log is
# where the real detail goes; this is enough to tell progress from a hang.
HEARTBEAT=${HEARTBEAT:-15}

run() {
    step=$((step + 1))
    label=$1
    shift
    log="$LOGDIR/step2_${step}.log"
    printf 'STEP %s  %s\n' "$step" "$label"
    : > "$log"
    "$@" > "$log" 2>&1 &
    cmdpid=$!
    t0=$(date +%s)
    # POLLED EVERY SECOND, PRINTED EVERY HEARTBEAT SECONDS. Sleeping the
    # whole heartbeat between checks overstates the finish time by up to one
    # interval: a seven second step was reported as "ok in 10s" with a three
    # second heartbeat. The elapsed time printed here is read by me as
    # evidence about query cost, so it has to be the real one.
    next=$HEARTBEAT
    while kill -0 "$cmdpid" 2>/dev/null; do
        sleep 1
        el=$(($(date +%s) - t0))
        if [ "$el" -lt "$next" ]; then
            continue
        fi
        next=$((el + HEARTBEAT))
        kill -0 "$cmdpid" 2>/dev/null || break
        lines=$(wc -l < "$log" | tr -d ' ')
        last=$(tail -1 "$log" 2>/dev/null | cut -c1-58)
        if [ -n "$last" ]; then
            printf '    %ss, %s log lines. Last: %s\n' "$el" "$lines" "$last"
        else
            printf '    %ss, no output yet. Still running.\n' "$el"
        fi
    done
    wait "$cmdpid"
    rc=$?
    el=$(($(date +%s) - t0))
    if [ "$rc" -eq 0 ]; then
        printf '    ok in %ss\n' "$el"
        return 0
    fi
    printf '    FAILED after %ss\n' "$el"
    echo
    echo "Step $step failed. The chain stops here so a half-built result is"
    echo "not mistaken for a finished one. From $log:"
    echo
    grep -iE 'error|exception|fatal' "$log" | head -5 | sed 's/^/    /'
    if ! grep -qiE 'error|exception|fatal' "$log"; then
        tail -8 "$log" | sed 's/^/    /'
    fi
    exit 1
}

psql_file() {
    psql -X -P pager=off -v ON_ERROR_STOP=1 -f "$1"
}

run "crosswalk the four naming systems" \
    psql_file geo/carrier_nodes/carrier_crosswalk.sql

run "decision tables and views" \
    psql_file geo/carrier_nodes/carrier_decisions.sql

if [ -f "$DECISIONS" ]; then
    run "load the rulings and refill the resolved table" \
        python3 -u geo/carrier_nodes/load_decisions.py load --file "$DECISIONS"
else
    echo "STEP skipped  no decisions file at $DECISIONS"
fi

echo
echo "Steps 4 to 6 completed. Where the crosswalk stands:"
echo
psql -X -P pager=off -c "
SELECT count(*)                                        AS carriers,
       count(*) FILTER (WHERE approved)                AS approved,
       count(*) FILTER (WHERE bdc_brand_name IS NOT NULL) AS with_bdc_name,
       count(*) FILTER (WHERE itdk_domain IS NOT NULL) AS with_itdk_domain
FROM carrier_crosswalk_tbl" 2>&1

echo
echo "THE PROPOSAL COUNTS AND THE VERDICT:"
echo
# MATCH THE NOTICE, NOT THE HEADING.
#
# The first version of this grep looked for 'proposals would be', 'SKIPPED'
# and the column names. On Boris's 2026-11-18 run it printed the section
# heading and the column header and NOT ONE NUMBER, because the verdict
# arrives two ways and neither was matched: a result row that is bare
# numbers plus a verdict string, and a RAISE NOTICE whose wording differs
# per branch. The three branch wordings are 'STOP. Even the strong tiers',
# 'Proposals would be' and 'Proposals: N rows, all tiers included'. Only the
# second was in the pattern.
#
# Reporting a heading with no figures under it is worse than reporting
# nothing: it reads as though the figures were absent.
grep -iE 'NOTICE|^ *[0-9]+ *\| *[0-9]+|all tiers included|STOP\.' \
    "$LOGDIR/step2_4.log" 2>/dev/null | head -8 | sed 's/^/    /'
echo
echo "Read the verdict as follows."
echo "  all tiers included    the count was under 20,000 and every"
echo "                        proposal was inserted"
echo "  tier is SKIPPED       over 20,000, so the weak first-word tier was"
echo "                        dropped and only the strong tiers inserted"
echo "  STOP                  over 20,000 from the strong tiers alone, so"
echo "                        NO BDC pairing was inserted at all"
echo
echo "The measured ITDK, ip-api and RDAP columns are unaffected in every"
echo "case. The matcher policy is yours and is not changed by this script."
echo
approved=$(psql -X -qtAc "SELECT count(*) FROM carrier_crosswalk_tbl WHERE approved" 2>/dev/null)
proposals=$(psql -X -qtAc "SELECT count(*) FROM carrier_crosswalk_tbl WHERE bdc_brand_name IS NOT NULL AND NOT approved" 2>/dev/null)
if [ "${approved:-0}" = "0" ] && [ "${proposals:-0}" != "0" ]; then
    echo "NOTHING IS APPROVED YET, and that is by design rather than a fault."
    echo "${proposals} BDC name pairing(s) are proposals. approved is false"
    echo "until you say otherwise, and nothing downstream should join"
    echo "through an unapproved row, so the crosswalk is NOT yet usable as a"
    echo "carrier identity source."
    echo
    echo "Your 87 rulings are a different mechanism: they live in"
    echo "carrier_decision_tbl and drive carrier_resolved_tbl, which step 6"
    echo "has just refilled. They do not set approved on crosswalk rows."
    echo
    echo "The approval list is section 5 of $LOGDIR/step2_4.log"
fi
echo
echo "Full approval list: $LOGDIR/step2_4.log, section 5."
