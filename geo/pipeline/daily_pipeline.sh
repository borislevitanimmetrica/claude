#!/usr/bin/env bash
#
# daily_pipeline.sh - the daily RouteViews-driven half of the geo pipeline.
#
#   1. import the latest RouteViews BGP data
#   2. detect db-ip ranges that BGP has since split
#   3. decompose those ranges into aligned /24 rows for probing
#
# It deliberately does NOT probe ip-api. Probing is rate limited to 45 calls a
# minute, so working through a backlog takes days and would overlap the next
# daily run. Use probe_batch.sh on a separate, more frequent schedule for that.
#
# Safe to run from cron: flock prevents overlapping runs, every step is timed and
# logged, and a failure stops the run rather than letting a later step act on
# incomplete data.
#
# Environment:
#   DATABASE_URL   required, passed through to every tool
#   GEO_HOME       root holding the tool directories, default $HOME/geo
#   LOG_DIR        where to write logs, default $GEO_HOME/logs
#
# Usage:
#   daily_pipeline.sh              normal run
#   daily_pipeline.sh --dry-run    report what would run, change nothing
#   daily_pipeline.sh --full-bgp   full RIB load instead of incremental updates

set -euo pipefail

GEO_HOME="${GEO_HOME:-$HOME/geo}"
LOG_DIR="${LOG_DIR:-$GEO_HOME/logs}"
LOCK_FILE="${LOCK_FILE:-$GEO_HOME/.daily_pipeline.lock}"

DRY_RUN=0
BGP_MODE=updates

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --full-bgp)  BGP_MODE=full ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/daily_pipeline.log"

log() {
  printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

# Run a step, timing it and failing the whole pipeline if it fails. Tool output
# goes to the log only, so cron mail stays short.
run_step() {
  local name="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN would execute [$name]: $*"
    return 0
  fi
  log "START $name"
  local t0 rc
  t0=$(date +%s)
  set +e
  "$@" >> "$LOG_FILE" 2>&1
  rc=$?
  set -e
  local secs=$(( $(date +%s) - t0 ))
  if [ $rc -ne 0 ]; then
    die "$name failed with exit $rc after ${secs}s (see $LOG_FILE)"
  fi
  log "DONE  $name in ${secs}s"
}

# One-line SQL scalar, used for before/after counts.
scalar() {
  psql "$DATABASE_URL" -tAc "$1" 2>/dev/null || echo "?"
}

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set"

BGP_BIN="$GEO_HOME/bgp_route_views/bin/bgp_route_views"
SPLITS_BIN="$GEO_HOME/check_range_splits/bin/check_range_splits"
APPLY_BIN="$GEO_HOME/apply_splits/bin/apply_splits"

for b in "$BGP_BIN" "$SPLITS_BIN" "$APPLY_BIN"; do
  [ -x "$b" ] || die "missing or non-executable: $b"
done

# Serialise runs. A daily run can exceed 24h if the BGP archive is slow, and two
# concurrent apply_splits passes against the same candidate table would fight.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another daily_pipeline run holds the lock; exiting without doing anything"
  exit 0
fi

log "=============================================================="
log "daily pipeline starting (bgp mode=$BGP_MODE, dry-run=$DRY_RUN)"

BEFORE_BGP=$(scalar "SELECT count(*) FROM bgp_route_views")
BEFORE_DBIP=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'dbip'")
BEFORE_RV=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'routeviews'")
log "before: bgp_route_views=$BEFORE_BGP dbip_rows=$BEFORE_DBIP routeviews_rows=$BEFORE_RV"

# Step 1. RouteViews. Updates mode applies only what has appeared since the last
# ingested file, tracked in bgp_rv_ingest_state.
run_step "bgp_route_views (mode=$BGP_MODE)" "$BGP_BIN" -mode "$BGP_MODE"

# Step 2. Split detection. -create-index=false because the db-ip importer already
# builds the GiST index on ip2city_dbiplite_tbl(network); letting this tool build
# its own produced a second, redundant index. -top 0 suppresses the long listing,
# which is in the log from earlier runs anyway.
run_step "check_range_splits" "$SPLITS_BIN" \
    -min-children 2 -write -top 0 -create-index=false

# Step 3. Decompose newly split parents into aligned /24 rows. Idempotent:
# parents already decomposed are gone from ip2city_dbiplite_tbl as source='dbip'
# rows, so they are not reconsidered. Honours geo_exclusions, so DoD and other
# excluded space is skipped.
if [ "$DRY_RUN" -eq 1 ]; then
  run_step "apply_splits (dry run)" "$APPLY_BIN" -dry-run
else
  run_step "apply_splits" "$APPLY_BIN"
fi

AFTER_BGP=$(scalar "SELECT count(*) FROM bgp_route_views")
AFTER_DBIP=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'dbip'")
AFTER_RV=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'routeviews'")
CANDIDATES=$(scalar "SELECT count(*) FROM dbip_split_candidates")
UNPROBED=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl t
                   WHERE NOT EXISTS (SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
                                     WHERE tr.network = t.network AND tr.city IS NOT NULL)
                     AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                                     WHERE x.active AND x.prefix IS NOT NULL
                                       AND t.network <<= x.prefix)")

log "after:  bgp_route_views=$AFTER_BGP dbip_rows=$AFTER_DBIP routeviews_rows=$AFTER_RV"
log "split candidates=$CANDIDATES"
log "ranges still awaiting an ip-api city (exclusions applied)=$UNPROBED"
log "daily pipeline finished"
log "=============================================================="
