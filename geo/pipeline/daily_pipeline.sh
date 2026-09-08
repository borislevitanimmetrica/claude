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

# Probe table rebuild. Off by default: it changes what feeds the DMA export, so
# it must be enabled deliberately after a verified first run.
PROBE_TBL_REBUILD="${PROBE_TBL_REBUILD:-0}"

# Must match the -country that probe_batch.sh passes to check_geo_ip-api. If
# these disagree, the populate loads ranges that probing will never select, their
# ran_at stays NULL, and the cycle-complete gate never opens again.
PROBE_COUNTRY="${PROBE_COUNTRY:-US}"

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

# Step 4. Rebuild the probe table, but only when the previous probing cycle has
# finished. See rebuild_probe_tbl.sql for the gate and for why the populate must
# apply exactly the same filters as check_geo_ip-api's sampleRanges.
#
# DEFAULT OFF. The probe table redesign changes what feeds the DMA export, so it
# is opt-in until you have verified a rebuild on this database. Enable with
# PROBE_TBL_REBUILD=1, either in the cron file or for a single manual run.
if [ "$PROBE_TBL_REBUILD" = "1" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    log "SKIP rebuild_probe_tbl: dry run"
  else
    REBUILD_SQL="$_self_dir/rebuild_probe_tbl.sql"
    if [ ! -f "$REBUILD_SQL" ]; then
      die "PROBE_TBL_REBUILD=1 but $REBUILD_SQL is missing"
    fi
    # geo.family must agree with the -ipv4-only that probe_batch.sh passes, which
    # is why both derive from the single PROBE_IPV4_ONLY in geo_common.sh. 0 means
    # both families.
    REBUILD_FAMILY=0
    if [ "$PROBE_IPV4_ONLY" = "1" ]; then
      REBUILD_FAMILY=4
    fi
    log "probe table scope: country=$PROBE_COUNTRY family=$REBUILD_FAMILY ipv4_only=$PROBE_IPV4_ONLY"
    run_step "rebuild_probe_tbl (country=$PROBE_COUNTRY family=$REBUILD_FAMILY)" psql_file "$REBUILD_SQL" "geo.country = '$PROBE_COUNTRY'" "geo.family = '$REBUILD_FAMILY'"
  fi
else
  log "rebuild_probe_tbl not run: PROBE_TBL_REBUILD is $PROBE_TBL_REBUILD"
fi

AFTER_BGP=$(scalar "SELECT count(*) FROM bgp_route_views")
AFTER_DBIP=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'dbip'")
AFTER_RV=$(scalar "SELECT count(*) FROM ip2city_dbiplite_tbl WHERE source = 'routeviews'")
CANDIDATES=$(scalar "SELECT count(*) FROM dbip_split_candidates")
UNPROBED=$(scalar "SELECT count(*) FROM ip2city_dbiplite_probe_tbl WHERE ran_at IS NULL")
PROBED=$(scalar "SELECT count(*) FROM ip2city_dbiplite_probe_tbl WHERE ran_at IS NOT NULL")

log "after:  bgp=$AFTER_BGP dbip_rows=$AFTER_DBIP routeviews_rows=$AFTER_RV"
log "split candidates=$CANDIDATES"
log "probe table: probed=$PROBED awaiting a probe=$UNPROBED"
log "daily pipeline finished"
log "=============================================================="
