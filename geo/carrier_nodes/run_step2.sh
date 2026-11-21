#!/bin/sh
# run_step2.sh - run the whole of step 2 in the right order, once.
#
# WHY THIS EXISTS
#
# The order matters and I got it wrong twice when handing Boris command
# blocks. geo/carrier_nodes/schema.sql DROPS and recreates carrier_node_tbl
# when it migrates the key, so the crosswalk run after it saw an empty table
# and produced a blank approval list. And resolve_asn.sql is driven by
# decisions that load after carrier_decisions.sql has run, so the ASN tables
# and carrier_resolved_tbl are empty until they are refilled.
#
# Neither is interesting to remember. This encodes it.
#
# WHAT IT DOES, in order:
#
#   1. rename bdc_provider_tbl to bdc_carrier_tbl if it is still named that
#   2. geo/carrier_nodes/schema.sql, which may drop carrier_node_tbl
#   3. hoiho_apply.py apply, which refills carrier_node_tbl
#   4. geo/carrier_nodes/carrier_crosswalk.sql
#   5. geo/carrier_nodes/carrier_decisions.sql
#   6. load_decisions.py, which also re-runs resolve_asn.sql
#
# It STOPS at the first failure and says which step failed, rather than
# carrying on and leaving a half-built result that looks finished.
#
# NOTHING HERE IS DESTRUCTIVE beyond what the individual files do, and each
# of those carries its own pre-mortem. The only data this chain can lose is
# carrier_node_tbl, which step 3 rebuilds from the trace corpus in seconds.
#
# USAGE
#
#   sh geo/carrier_nodes/run_step2.sh
#   sh geo/carrier_nodes/run_step2.sh --skip-apply
#
# Run from the repository root. --skip-apply leaves carrier_node_tbl alone,
# for when the decode has not changed and only the crosswalk is being redone.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

LOGDIR=${LOGDIR:-/home/boris/geo/logs}
DECISIONS=${DECISIONS:-geo/carrier_nodes/decisions_2026_11_17.tsv}
CAIDA=${CAIDA:-/home/boris/geo/caida}
SKIP_APPLY=0

while [ -n "${1-}" ]; do
    case "$1" in
        --skip-apply) SKIP_APPLY=1 ;;
        --decisions)  shift; DECISIONS=$1 ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOGDIR"

step=0
run() {
    step=$((step + 1))
    label=$1
    shift
    log="$LOGDIR/step2_${step}.log"
    printf 'STEP %s  %-44s' "$step" "$label"
    if "$@" > "$log" 2>&1; then
        echo "ok"
        return 0
    fi
    echo "FAILED"
    echo
    echo "Step $step failed. The chain stops here so a half-built result is"
    echo "not mistaken for a finished one. Last lines of $log:"
    echo
    sed -n '$!{h;d};x;G;p' "$log" 2>/dev/null | head -1 >/dev/null
    grep -iE 'error|exception|fatal' "$log" | head -5 | sed 's/^/    /'
    if ! grep -qiE 'error|exception|fatal' "$log"; then
        tail -8 "$log" | sed 's/^/    /'
    fi
    exit 1
}

psql_file() {
    psql -X -P pager=off -v ON_ERROR_STOP=1 -f "$1"
}

# A RUNNING BDC LOAD MAKES THIS BOTH SLOW AND WRONG.
#
# The crosswalk reads bdc_carrier_tbl. While bdc_load.py is filling it, any
# answer is partial, and the two jobs fight for the same disk. On 2026-11-17
# the proposal INSERT hit its ten minute timeout with a load running
# alongside it.
#
# Reported, not blocked: a partial crosswalk is still useful for the ITDK,
# ip-api and RDAP columns, which do not depend on BDC at all.
busy=$(psql -X -qtA -c "
SELECT count(*) FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid()
  AND state <> 'idle'
  AND (query ILIKE '%bdc_availability%' OR query ILIKE '%bdc_stage%')" 2>/dev/null)

if [ "${busy:-0}" -gt 0 ]; then
    echo "NOTE: a BDC load appears to be running ($busy active statement(s)"
    echo "touching the availability tables)."
    echo
    echo "The crosswalk reads bdc_carrier_tbl, so its BDC column will be"
    echo "PARTIAL until that load finishes, and the two jobs compete for the"
    echo "same disk. The ITDK, ip-api and RDAP columns are unaffected."
    echo
    echo "Continuing. Re-run this after the load finishes for the full"
    echo "picture."
    echo
fi

echo "Step 2 of the FCC plan, in dependency order."
echo "Logs under $LOGDIR, one per step."
echo

# PREREQUISITES NAMED UP FRONT, rather than failing five steps in. The chain
# needs the BDC carrier table and the trace corpus; neither is built by step
# 2 and both come from elsewhere in the project.
missing=$(psql -X -qtA -c "
SELECT string_agg(t, ', ')
FROM (SELECT 'bdc_carrier_tbl' AS t WHERE to_regclass('bdc_carrier_tbl') IS NULL
      UNION ALL
      SELECT 'ip2city_dbiplite_probe_tbl' WHERE to_regclass('ip2city_dbiplite_probe_tbl') IS NULL
      UNION ALL
      SELECT 'ovt_places_usa_ip_trace' WHERE to_regclass('ovt_places_usa_ip_trace') IS NULL) z" 2>/dev/null)

if [ -n "$missing" ]; then
    echo "MISSING PREREQUISITE TABLE(S): $missing"
    echo
    echo "Nothing has been run. These are not built by step 2:"
    echo "  bdc_carrier_tbl             from geo/fcc_bdc/schema_v2.sql, then"
    echo "                              loaded by geo/fcc_bdc/bdc_load.py"
    echo "  ip2city_dbiplite_probe_tbl  the ip-api probe estate"
    echo "  ovt_places_usa_ip_trace     the traceroute corpus"
    echo
    echo "schema_v2.sql TRUNCATES bdc_carrier_tbl when it recreates the"
    echo "availability table, so it is NOT run automatically here."
    exit 1
fi

# THE RENAME IS NOT A PREREQUISITE and must not stop the chain.
#
# It takes ACCESS EXCLUSIVE, so it cannot run while bdc_load.py is writing.
# On 2026-11-17 it queued behind that load and blocked it. The file now gives
# up after two seconds, and this step treats that as a SKIP rather than a
# failure, because every later step works against either table name: they
# read bdc_carrier_tbl if it exists and the crosswalk reports an absent BDC
# source rather than failing.
#
# So a running load defers the rename and costs nothing else.
if [ -f geo/fcc_bdc/rename_provider_to_carrier.sql ]; then
    step=$((step + 1))
    printf 'STEP %s  %-44s' "$step" "rename bdc_provider_tbl if free to do so"
    if psql_file geo/fcc_bdc/rename_provider_to_carrier.sql \
            > "$LOGDIR/step2_${step}.log" 2>&1; then
        echo "ok"
    else
        echo "deferred"
        echo "    The rename could not take its lock, so nothing was changed."
        echo "    Something else is using the table, almost certainly the BDC"
        echo "    load. This is NOT a failure and the chain continues."
        grep -iE 'pid|could not get the lock' "$LOGDIR/step2_${step}.log" \
            | head -4 | sed 's/^/    /'
    fi
fi

run "carrier_nodes schema, may drop carrier_node_tbl" \
    psql_file geo/carrier_nodes/schema.sql

if [ "$SKIP_APPLY" -eq 0 ]; then
    run "decode hostnames into carrier_node_tbl" \
        python3 geo/carrier_nodes/hoiho_apply.py --dir "$CAIDA" apply
else
    echo "STEP skipped  decode, by --skip-apply"
fi

run "crosswalk the four naming systems" \
    psql_file geo/carrier_nodes/carrier_crosswalk.sql

run "decision tables and views" \
    psql_file geo/carrier_nodes/carrier_decisions.sql

if [ -f "$DECISIONS" ]; then
    run "load the rulings and refill the resolved table" \
        python3 geo/carrier_nodes/load_decisions.py load --file "$DECISIONS"
else
    echo "STEP skipped  no decisions file at $DECISIONS"
fi

echo
echo "All steps completed. Where things stand:"
echo
psql -X -P pager=off -c "
SELECT (SELECT count(*) FROM carrier_node_tbl)                 AS node_rows,
       (SELECT count(DISTINCT hostname) FROM carrier_node_tbl) AS hostnames,
       (SELECT count(*) FROM carrier_node_tbl WHERE lat IS NOT NULL)
                                                               AS located,
       (SELECT count(*) FROM carrier_node_tbl
        WHERE hint_type = 'clli')                              AS clli_pending,
       (SELECT count(*) FROM carrier_crosswalk_tbl)            AS crosswalk_rows,
       (SELECT count(*) FROM carrier_decision_tbl)             AS decisions,
       (SELECT count(*) FROM carrier_resolved_tbl)             AS resolved_rows"

echo "The approval list is in $LOGDIR/step2_4.log, section 5."
echo "Decisions already recorded are in $LOGDIR/step2_6.log."
