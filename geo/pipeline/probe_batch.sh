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
# comes from /etc/trugeo.env (override with GEO_CONFIG).
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
BATCH_WARN_SECS="${BATCH_WARN_SECS:-4200}"
REPORT_ONLY=0

usage() {
  echo "probe_batch.sh - one bounded batch of ip-api geolocation lookups"
  echo ""
  echo "  (no argument)  probe BATCH ranges, default 2400"
  echo "  N              probe N ranges"
  echo "  --remaining    report the backlog and exit without probing"
  echo "  -h, --help     this text"
  echo ""
  echo "2400 at 45 per minute takes about 53 minutes, leaving slack in an"
  echo "hourly schedule so consecutive runs never collide."
}

_arg="${1-}"
if [ "$_arg" = "--remaining" ]; then
  REPORT_ONLY=1
elif [ "$_arg" = "-h" ] || [ "$_arg" = "--help" ]; then
  usage
  exit 0
elif [ -n "$_arg" ]; then
  if [ "$_arg" -gt 0 ] 2>/dev/null; then
    BATCH="$_arg"
  else
    echo "unknown argument: $_arg" >&2
    exit 2
  fi
fi

report_db_mode
require_database

GEO_BIN="$GEO_HOME/check_geo_ip-api/bin/check_geo_ip-api"
require_exec "$GEO_BIN"

remaining() {
  local extra=""
  if [ -n "$COUNTRY" ]; then
    extra="AND t.country_iso_code = '$COUNTRY'"
  fi
  psql_q "
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

begin_notify

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

# A batch of 2400 should take about 53 minutes at 45 calls a minute. Much longer
# means ip-api is throttling or the network is degraded, and an hourly schedule
# will start overlapping. Alert but do not fail: the work itself succeeded.
if [ "$secs" -gt "$BATCH_WARN_SECS" ]; then
  alert "probe batch of $BATCH took ${secs}s, beyond the ${BATCH_WARN_SECS}s expectation. Successive hourly runs may now overlap and exit on the lock. Check for ip-api throttling or lower BATCH."
fi

if [ "$rc" -ne 0 ]; then
  die "check_geo_ip-api exited $rc (see $LOG_FILE)"
fi

if [ "$BEFORE" != "?" ] && [ "$AFTER" != "?" ]; then
  log "resolved $(( BEFORE - AFTER )) ranges this batch"
fi

# The end of a full probing cycle: nothing is left awaiting a city. This is the
# event worth an email once routine per-run mail is switched off, so it is sent
# regardless of NOTIFY_START and NOTIFY_SUCCESS.
#
# check_geo_ip-api exits 0 on an empty backlog rather than treating it as an
# error, so reaching this point with AFTER=0 is a normal, successful outcome.
if [ "$AFTER" = "0" ]; then
  notify_cycle "Probing cycle complete: no IPv4 ranges awaiting an ip-api city for country=${COUNTRY:-all}. Backlog was $BEFORE at the start of this batch."
fi
