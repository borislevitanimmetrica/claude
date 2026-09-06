#!/usr/bin/env bash
#
# probe_batch.sh - run one bounded batch of ip-api geolocation lookups.
#
# Separate from daily_pipeline.sh because the rhythms are incompatible: the free
# ip-api tier allows 45 calls a minute, so a backlog of a few hundred thousand
# ranges takes days.
#
# Default batch is 2400, which at 45 per minute takes about 53 minutes. That
# leaves roughly 7 minutes of slack in an hourly schedule, so consecutive runs
# never collide. 2700 would fill the hour exactly and the next run would find the
# lock held and do nothing, halving throughput. 2400 per hour is 57,600 a day,
# about 89 percent of the theoretical maximum.
#
# check_geo_ip-api already skips ranges excluded in geo_exclusions and probes
# source='routeviews' rows ahead of older db-ip rows, so no ordering logic is
# needed here.
#
# No credentials are taken from the command line or the crontab. DATABASE_URL
# comes from $HOME/.geo-pipeline.env (override with GEO_CONFIG).
#
# Usage:
#   probe_batch.sh              probe BATCH ranges (default 2400)
#   probe_batch.sh 500          probe 500 ranges
#   probe_batch.sh --remaining  report the backlog and exit without probing
#
# Contains no backslash escape sequences.

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=geo_common.sh
. "$_self_dir/geo_common.sh"

LOG_FILE="$LOG_DIR/probe_batch.log"
LOCK_FILE="${LOCK_FILE:-$LOG_DIR/probe_batch.lock}"

BATCH="${BATCH:-2400}"
COUNTRY="${COUNTRY:-US}"
REPORT_ONLY=0

case "${1:-}" in
  --remaining) REPORT_ONLY=1 ;;
  -h|--help)   sed -n '2,28p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
  '')          : ;;
  *[!0-9]*)    echo "unknown argument: $1" >&2; exit 2 ;;
  *)           BATCH="$1" ;;
esac

require_database_url

GEO_BIN="$GEO_HOME/check_geo_ip-api/bin/check_geo_ip-api"
require_exec "$GEO_BIN"

remaining() {
  local extra=""
  if [ -n "$COUNTRY" ]; then
    extra="AND t.country_iso_code = '$COUNTRY'"
  fi
  psql "$DATABASE_URL" -tAc "
    SELECT count(*) FROM ip2city_dbiplite_tbl t
    WHERE family(t.network) = 4
      AND NOT EXISTS (SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
                      WHERE tr.network = t.network AND tr.city IS NOT NULL)
      AND NOT (t.network <<= '100.64.0.0/10'::cidr)
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                      WHERE x.active AND x.prefix IS NOT NULL
                        AND t.network <<= x.prefix)
      $extra
  " 2>/dev/null || echo "?"
}

if [ "$REPORT_ONLY" -eq 1 ]; then
  n=$(remaining)
  log "ranges awaiting a city (country=${COUNTRY:-all}): $n"
  if [ "$n" != "?" ] && [ "$n" -gt 0 ]; then
    log "at 45/min that is $(( n / 45 )) minutes; at ${BATCH}/hour that is $(( n / BATCH )) hours"
  fi
  exit 0
fi

# Serialise: two concurrent batches would together exceed 45 calls a minute and
# risk an ip-api ban by WAN address.
take_lock "$LOCK_FILE"

BEFORE=$(remaining)
log "starting batch of $BATCH (country=${COUNTRY:-all}); backlog before=$BEFORE"

t0=$(date +%s)
set +e
if [ -n "$COUNTRY" ]; then
  "$GEO_BIN" -count "$BATCH" -country "$COUNTRY" >> "$LOG_FILE" 2>&1
else
  "$GEO_BIN" -count "$BATCH" >> "$LOG_FILE" 2>&1
fi
rc=$?
set -e
secs=$(( $(date +%s) - t0 ))

AFTER=$(remaining)
log "batch finished in ${secs}s with exit $rc; backlog after=$AFTER"

if [ "$rc" -ne 0 ]; then
  die "check_geo_ip-api exited $rc (see $LOG_FILE)"
fi

if [ "$BEFORE" != "?" ] && [ "$AFTER" != "?" ]; then
  log "resolved $(( BEFORE - AFTER )) ranges this batch"
fi
