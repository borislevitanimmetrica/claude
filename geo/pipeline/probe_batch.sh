#!/usr/bin/env bash
#
# probe_batch.sh - run one bounded batch of ip-api geolocation lookups.
#
# Kept separate from daily_pipeline.sh because the two have incompatible
# rhythms. The free ip-api tier allows 45 calls a minute, so a backlog of a few
# hundred thousand ranges takes days. Running that inside a daily job would mean
# each run overlapping the next.
#
# Designed for an hourly cron entry. The default batch of 2700 is exactly one
# hour at 45 per minute, so consecutive hourly runs sustain the maximum free rate
# without ever exceeding it.
#
# check_geo_ip-api already skips ranges that are excluded in geo_exclusions and
# probes source='routeviews' rows before older db-ip rows, so no ordering logic
# is needed here.
#
# Environment:
#   DATABASE_URL   required
#   GEO_HOME       root holding the tool directories, default $HOME/geo
#   LOG_DIR        where to write logs, default $GEO_HOME/logs
#   BATCH          lookups this run, default 2700
#   COUNTRY        restrict to one ISO country code, default US; empty disables
#
# Usage:
#   probe_batch.sh              probe BATCH ranges
#   probe_batch.sh 500          probe 500 ranges
#   probe_batch.sh --remaining  report the backlog and exit without probing

set -euo pipefail

GEO_HOME="${GEO_HOME:-$HOME/geo}"
LOG_DIR="${LOG_DIR:-$GEO_HOME/logs}"
LOCK_FILE="${LOCK_FILE:-$GEO_HOME/.probe_batch.lock}"
BATCH="${BATCH:-2700}"
COUNTRY="${COUNTRY:-US}"

REPORT_ONLY=0
case "${1:-}" in
  --remaining) REPORT_ONLY=1 ;;
  --help|-h)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  ''|*[!0-9]*) : ;;
  *)           BATCH="$1" ;;
esac

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/probe_batch.log"

log() {
  printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"
}

die() { log "FATAL: $*"; exit 1; }

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set"

GEO_BIN="$GEO_HOME/check_geo_ip-api/bin/check_geo_ip-api"
[ -x "$GEO_BIN" ] || die "missing or non-executable: $GEO_BIN"

remaining() {
  psql "$DATABASE_URL" -tAc "
    SELECT count(*) FROM ip2city_dbiplite_tbl t
    WHERE NOT EXISTS (SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
                      WHERE tr.network = t.network AND tr.city IS NOT NULL)
      AND NOT (t.network <<= '100.64.0.0/10'::cidr)
      AND NOT EXISTS (SELECT 1 FROM geo_exclusions x
                      WHERE x.active AND x.prefix IS NOT NULL
                        AND t.network <<= x.prefix)
      AND family(t.network) = 4
      $( [ -n "$COUNTRY" ] && echo "AND t.country_iso_code = '$COUNTRY'" )
  " 2>/dev/null || echo "?"
}

if [ "$REPORT_ONLY" -eq 1 ]; then
  n=$(remaining)
  log "ranges awaiting a city: $n"
  if [ "$n" != "?" ] && [ "$n" -gt 0 ]; then
    log "at 45/min that is $(( n / 45 )) minutes, about $(( n / 64800 )) days of continuous probing"
  fi
  exit 0
fi

# Serialise: two concurrent batches would together exceed 45 calls a minute and
# risk an ip-api ban by WAN address.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another probe_batch run holds the lock; exiting so the rate limit is not exceeded"
  exit 0
fi

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

if [ $rc -ne 0 ]; then
  die "check_geo_ip-api exited $rc (see $LOG_FILE)"
fi

if [ "$BEFORE" != "?" ] && [ "$AFTER" != "?" ]; then
  log "resolved $(( BEFORE - AFTER )) ranges this batch"
fi
