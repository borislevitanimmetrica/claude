#!/usr/bin/env bash
#
# monthly_dbip.sh - import the current month's free db-ip City Lite edition.
#
# Wraps dbip-mmdb-import so cron calls a script rather than a bare binary, and so
# the mandatory -preserve-routeviews setting cannot be forgotten.
#
# WHY -preserve-routeviews all IS MANDATORY HERE
# The importer's default is conditional, which keeps a RouteViews-derived /24 row
# only if the NEW db-ip edition still has a strictly wider row covering it.
# apply_splits DELETES those parent rows once it has decomposed them, so under the
# default nearly every /24 row would fail the test and be discarded, throwing away
# the entire ip-api probing investment. all keeps them unconditionally.
#
# The tool downloads the edition itself, records it in dbip_import_state, and
# exits without doing anything if that edition is already imported. So running on
# both the 1st and the 2nd is safe, and covers db-ip publishing late.
#
# After a successful import, dbip_split_candidates is stale; the next daily run
# rebuilds it. A fresh classify_ranges pass is also worthwhile but is deliberately
# not automated, because it spends from the same 45/min ip-api budget as probing.
#
# No credentials are taken from the command line or the crontab. DATABASE_URL
# comes from $HOME/.geo-pipeline.env (override with GEO_CONFIG).
#
# Usage:
#   monthly_dbip.sh                normal run, current month
#   monthly_dbip.sh --month 2026-08  a specific edition
#   monthly_dbip.sh --dry-run      report what would run, change nothing
#
# Contains no backslash escape sequences.

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=geo_common.sh
. "$_self_dir/geo_common.sh"

LOG_FILE="$LOG_DIR/monthly_dbip.log"
LOCK_FILE="${LOCK_FILE:-$LOG_DIR/monthly_dbip.lock}"

DRY_RUN=0
MONTH=""

usage() {
  echo "monthly_dbip.sh - import the current month's free db-ip City Lite edition"
  echo ""
  echo "  --dry-run        report what would run, change nothing"
  echo "  --month YYYY-MM  a specific edition instead of the current month"
  echo "  -h, --help       this text"
  echo ""
  echo "Always passes -preserve-routeviews all, which is mandatory because"
  echo "apply_splits deletes the parent rows that the default mode looks for."
}

while [ -n "${1-}" ]; do
  if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
  elif [ "$1" = "--month" ]; then
    shift
    MONTH="${1-}"
    if [ -z "$MONTH" ]; then
      echo "--month needs YYYY-MM" >&2
      exit 2
    fi
  elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
  else
    echo "unknown argument: $1" >&2
    exit 2
  fi
  shift
done

report_db_mode
require_database

IMPORT_BIN="$GEO_HOME/dbip-mmdb-import/bin/dbip-mmdb-import"
require_exec "$IMPORT_BIN"

take_lock "$LOCK_FILE"

log "=============================================================="
log "monthly db-ip import starting (GEO_HOME=$GEO_HOME month=${MONTH:-current} dry_run=$DRY_RUN)"

MUTATION_LOCK="${MUTATION_LOCK:-$LOG_DIR/dbmutate.lock}"
MUTATION_LOCK_WAIT="${MUTATION_LOCK_WAIT:-5400}"
PROBE_LOCK="${PROBE_LOCK:-$LOG_DIR/probe_batch.lock}"
PROBE_LOCK_WAIT="${PROBE_LOCK_WAIT:-4200}"
if [ "$DRY_RUN" -eq 0 ]; then
  take_mutation_lock "$MUTATION_LOCK" "$MUTATION_LOCK_WAIT"
  take_lock_blocking "$PROBE_LOCK" "$PROBE_LOCK_WAIT"
fi

BEFORE_DBIP=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'dbip'")
BEFORE_RV=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'routeviews'")
log "before: dbip_rows=$BEFORE_DBIP routeviews_rows=$BEFORE_RV"

# -preserve-routeviews all is not optional; see the header.
if [ -n "$MONTH" ]; then
  run_step "dbip-mmdb-import (month=$MONTH)" "$IMPORT_BIN" -preserve-routeviews all -month "$MONTH"
else
  run_step "dbip-mmdb-import" "$IMPORT_BIN" -preserve-routeviews all
fi

AFTER_DBIP=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'dbip'")
AFTER_RV=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'routeviews'")
EDITIONS=$(scalar "SELECT string_agg(edition, ', ' ORDER BY imported_at DESC)
                   FROM (SELECT edition, imported_at FROM dbip_import_state
                         ORDER BY imported_at DESC LIMIT 3) t")

log "after:  dbip_rows=$AFTER_DBIP routeviews_rows=$AFTER_RV"
log "recent editions: $EDITIONS"

if [ "$BEFORE_RV" != "?" ] && [ "$AFTER_RV" != "?" ] && [ "$BEFORE_RV" -gt 0 ] && [ "$AFTER_RV" -eq 0 ]; then
  log "WARNING: every routeviews row disappeared. That should be impossible with -preserve-routeviews all; investigate before the next probe batch."
fi

log "NOTE dbip_split_candidates is now stale; the next daily_pipeline run rebuilds it."
log "NOTE consider a manual classify_ranges pass, since a new edition can introduce untriaged wide ranges."
log "monthly db-ip import finished"
log "=============================================================="
