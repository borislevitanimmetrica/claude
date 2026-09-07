#!/usr/bin/env bash
#
# daily_pipeline.sh - the daily RouteViews-driven half of the geo pipeline.
#
#   1. import the latest RouteViews BGP data
#   2. detect db-ip ranges that BGP has since split
#   3. decompose those ranges into aligned /24 rows ready for probing
#
# It deliberately does NOT probe ip-api. Probing is capped at 45 calls a minute,
# so clearing a backlog takes days and would overlap the next daily run. Use
# probe_batch.sh on an hourly schedule for that.
#
# No credentials are taken from the command line or the crontab. DATABASE_URL
# comes from /etc/trugeo.env (override with GEO_CONFIG). GEO_HOME is
# derived from this script's own location.
#
# Usage:
#   daily_pipeline.sh              normal run
#   daily_pipeline.sh --dry-run    report what would run, change nothing
#   daily_pipeline.sh --full-bgp   full RIB load instead of incremental updates
#
# Contains no backslash escape sequences.

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=geo_common.sh
. "$_self_dir/geo_common.sh"

LOG_FILE="$LOG_DIR/daily_pipeline.log"
LOCK_FILE="${LOCK_FILE:-$LOG_DIR/daily_pipeline.lock}"

DRY_RUN="${DRY_RUN:-0}"
BGP_MODE="${BGP_MODE:-updates}"

if [ "$DRY_RUN" != "0" ] && [ "$DRY_RUN" != "1" ]; then
  echo "DRY_RUN must be 0 or 1, got: $DRY_RUN" >&2
  exit 2
fi
if [ "$BGP_MODE" != "updates" ] && [ "$BGP_MODE" != "full" ]; then
  echo "BGP_MODE must be updates or full, got: $BGP_MODE" >&2
  exit 2
fi

usage() {
  echo "daily_pipeline.sh - RouteViews import, split detection, /24 decomposition"
  echo ""
  echo "  --dry-run    report what would run, change nothing"
  echo "  --full-bgp   full RIB load instead of incremental updates"
  echo "  -h, --help   this text"
  echo ""
  echo "DATABASE_URL is optional. When unset, the connection comes from the"
  echo "libpq environment and defaults, so a service account can use peer"
  echo "authentication over a Unix socket with no credentials anywhere."
}

while [ -n "${1-}" ]; do
  if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
  elif [ "$1" = "--full-bgp" ]; then
    BGP_MODE=full
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

BGP_BIN="$GEO_HOME/bgp_route_views/bin/bgp_route_views"
SPLITS_BIN="$GEO_HOME/check_range_splits/bin/check_range_splits"
APPLY_BIN="$GEO_HOME/apply_splits/bin/apply_splits"
require_exec "$BGP_BIN"
require_exec "$SPLITS_BIN"
require_exec "$APPLY_BIN"

take_lock "$LOCK_FILE"

MUTATION_LOCK="${MUTATION_LOCK:-$LOG_DIR/dbmutate.lock}"
if [ "$DRY_RUN" -eq 0 ]; then
  take_mutation_lock "$MUTATION_LOCK" "$MUTATION_LOCK_WARN"
fi

begin_notify

log "=============================================================="
log "daily pipeline starting (GEO_HOME=$GEO_HOME bgp_mode=$BGP_MODE dry_run=$DRY_RUN)"

BEFORE_BGP=$(scalar "SELECT count(*) FROM bgp_route_views")
BEFORE_DBIP=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'dbip'")
BEFORE_RV=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'routeviews'")
log "before: bgp=$BEFORE_BGP dbip_rows=$BEFORE_DBIP routeviews_rows=$BEFORE_RV"

# Step 1. RouteViews. updates mode applies only files newer than the last one
# ingested, tracked in bgp_rv_ingest_state.
run_step "bgp_route_views (mode=$BGP_MODE)" "$BGP_BIN" -mode "$BGP_MODE"

# Step 2. Split detection. -create-index=false because the db-ip importer already
# builds the GiST index on ip2city_dbiplite_tbl(network); letting this tool build
# its own created a second, redundant index. -top 0 suppresses the long listing.
run_step "check_range_splits" "$SPLITS_BIN" -min-children 2 -write -top 0 -create-index=false

# Step 3. Decompose newly split parents into aligned /24 rows. Idempotent:
# already-decomposed parents no longer exist as source='dbip' rows so are not
# reconsidered. Honours geo_exclusions.
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
                   WHERE family(t.network) = 4
                     AND NOT EXISTS (SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
                                     WHERE tr.network = t.network AND tr.city IS NOT NULL)
                     AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                                     WHERE x.active AND x.prefix IS NOT NULL
                                       AND t.network <<= x.prefix)")

log "after:  bgp=$AFTER_BGP dbip_rows=$AFTER_DBIP routeviews_rows=$AFTER_RV"
log "split candidates=$CANDIDATES"
log "IPv4 ranges still awaiting an ip-api city=$UNPROBED"
log "daily pipeline finished"
log "=============================================================="
