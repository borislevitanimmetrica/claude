#!/usr/bin/env bash
#
# geo_common.sh - shared setup for the cron scripts. Sourced, not executed.
#
# Provides: GEO_HOME, LOG_DIR, log(), alert(), die(), psql_q(),
#           require_database(), require_exec(), take_lock(),
#           take_lock_blocking(), take_mutation_lock(), scalar(), run_step().
#
# GEO_HOME is derived from this file's own location, so the scripts work from any
# install path and need no configuration to find the tool binaries.
#
# DATABASE_URL IS OPTIONAL. When empty, psql is called with no connection string
# and pgx is given an empty one; both then resolve the connection from the
# standard libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSFILE) and
# their built-in defaults. That is how a service account connects over a Unix
# socket with peer authentication, with no credentials in cron or on disk.
#
# LOCK POLICY
# A lock is held for the whole life of the job: flock keeps it until the file
# descriptor closes, which happens when the process exits, however it exits.
# There is no lease that can lapse mid-run.
#
# Waiting for a lock is NEVER abandoned. A job that finds a lock held waits
# indefinitely and starts as soon as it frees. Exceeding the expected wait raises
# an alert to the log and by email, repeated at each interval, so a long queue is
# visible without any work being silently dropped. This suits worldwide db-ip and
# RouteViews ingestion, where run times are long and variable.
#
# NOTHING here depends on a home directory. The service account deliberately has
# no login and no home: logs go to /var/log/trugeo and optional configuration to
# /etc/trugeo.env, both system paths. Defaulting either to a home directory would
# break the moment that directory is removed as unnecessary.
#
# Contains no backslash escape sequences and no mid-line hash characters, both of
# which are destroyed in transit. All parameter defaulting is confined to the
# block below, so every later reference is a plain expansion.

_geo_common_src="${BASH_SOURCE[0]}"
_geo_common_dir="$(cd "$(dirname "$_geo_common_src")" && pwd)"
_geo_home_default="$(dirname "$_geo_common_dir")"

GEO_HOME="${GEO_HOME:-$_geo_home_default}"
GEO_CONFIG="${GEO_CONFIG:-/etc/trugeo.env}"

GEO_CONFIG_USED="environment"
if [ -r "$GEO_CONFIG" ]; then
  . "$GEO_CONFIG"
  GEO_CONFIG_USED="$GEO_CONFIG"
fi

DATABASE_URL="${DATABASE_URL:-}"
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-}"
PGUSER="${PGUSER:-}"
PGDATABASE="${PGDATABASE:-}"
DRY_RUN="${DRY_RUN:-0}"

ALERT_EMAIL="${ALERT_EMAIL:-boris@immetrica.com}"

# Notification volume controls. Both default to 1, which is the current
# behaviour: mail on start and on success for every run.
#
# Error mail is NOT controllable and is always sent. Silencing failures is never
# a reasonable configuration.
#
# These exist so that switching to per-cycle notification, once commercial
# ip-api access removes the 45/min ceiling, is a configuration change in the
# cron file rather than a code change. See trugeo.cron for the exact lines to
# uncomment.
NOTIFY_START="${NOTIFY_START:-1}"
NOTIFY_SUCCESS="${NOTIFY_SUCCESS:-1}"

# Alert thresholds in seconds. These are NOT timeouts: nothing is abandoned when
# they pass, an alert is raised and the job carries on. Sized for worldwide
# ingestion, where a full db-ip edition is about 14.7M rows against 5.5M for the
# United States alone, and a worldwide split scan is correspondingly slower.
MUTATION_LOCK_WARN="${MUTATION_LOCK_WARN:-7200}"
PROBE_LOCK_WARN="${PROBE_LOCK_WARN:-5400}"
STEP_WARN_SECS="${STEP_WARN_SECS:-14400}"

LOG_DIR="${LOG_DIR:-/var/log/trugeo}"

if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
  echo "FATAL: cannot create LOG_DIR $LOG_DIR as user $(id -un)" >&2
  exit 1
fi

if ! touch "$LOG_DIR/.writetest.$$" 2>/dev/null; then
  echo "FATAL: LOG_DIR $LOG_DIR exists but is not writable by $(id -un)." >&2
  echo "Every log line would be lost and the job would run blind, so this is fatal." >&2
  echo "Fix ownership, for example:  sudo chown -R $(id -un) $LOG_DIR" >&2
  echo "Or point LOG_DIR elsewhere in the cron file or the config file." >&2
  exit 1
fi
rm -f "$LOG_DIR/.writetest.$$"

SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"

_notify_enabled=0
_died=0

log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')  $*" | tee -a "$LOG_FILE"
}

_shown() {
  if [ -n "$1" ]; then
    echo "$1"
  else
    echo "libpq-default"
  fi
}

# Send one message, preferring the mail client, falling back to a direct
# sendmail envelope. Never fatal: a missing MTA must not break a working job.
send_mail() {
  local subject="$1"
  local body="$2"
  if command -v mail >/dev/null 2>&1; then
    echo "$body" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
  elif command -v sendmail >/dev/null 2>&1; then
    {
      echo "To: $ALERT_EMAIL"
      echo "Subject: $subject"
      echo ""
      echo "$body"
    } | sendmail -t 2>/dev/null || true
  else
    log "no mail client found, so this alert was logged only"
  fi
}

alert() {
  log "ALERT: $*"
  send_mail "trugeo alert on $(hostname -s)" "$*"
}

_etz_now() {
  TZ=America/New_York date +%Y-%m-%d' '%H:%M:%S
}

notify_start() {
  send_mail "Geo script $SCRIPT_NAME starting at time $(_etz_now) ETZ" "Geo start"
}

notify_success() {
  send_mail "Geo script $SCRIPT_NAME ran correctly, finishing at time $(_etz_now) ETZ" "Geo success"
}

notify_error() {
  local code="$1"
  local detail="$2"
  local body
  if [ -n "$detail" ]; then
    body=$(echo "Geo error"; echo ""; echo "$detail")
  else
    body="Geo error"
  fi
  send_mail "Geo script $SCRIPT_NAME exited with error $code at time $(_etz_now) ETZ" "$body"
}

begin_notify() {
  _notify_enabled=1
  if [ "$NOTIFY_START" = "1" ]; then
    log "notifying start by email to $ALERT_EMAIL"
    notify_start
  else
    log "start mail suppressed by NOTIFY_START=$NOTIFY_START"
  fi
}

# Send a cycle-boundary message regardless of NOTIFY_START and NOTIFY_SUCCESS.
# Used for events that matter even when routine per-run mail is switched off,
# such as a probing backlog reaching zero.
notify_cycle() {
  log "CYCLE: $*"
  send_mail "Geo script $SCRIPT_NAME cycle complete at time $(_etz_now) ETZ" "$*"
}

_on_exit() {
  local code="$1"
  if [ "$_died" -eq 1 ]; then
    return
  fi
  if [ "$_notify_enabled" -eq 0 ]; then
    return
  fi
  if [ "$code" -eq 0 ]; then
    if [ "$NOTIFY_SUCCESS" = "1" ]; then
      notify_success
    else
      log "success mail suppressed by NOTIFY_SUCCESS=$NOTIFY_SUCCESS"
    fi
  else
    notify_error "$code" "Exited without a diagnostic. See $LOG_FILE"
  fi
}

trap '_on_exit $?' EXIT

die() {
  _died=1
  log "FATAL: $*"
  notify_error 1 "$*"
  exit 1
}

report_db_mode() {
  if [ -n "$DATABASE_URL" ]; then
    log "database: DATABASE_URL set, from $GEO_CONFIG_USED"
  else
    log "database: no DATABASE_URL, using libpq defaults; host=$(_shown "$PGHOST") port=$(_shown "$PGPORT") user=$(_shown "$PGUSER") db=$(_shown "$PGDATABASE")"
  fi
}

psql_q() {
  if [ -n "$DATABASE_URL" ]; then
    psql "$DATABASE_URL" -tAc "$1"
  else
    psql -tAc "$1"
  fi
}

require_database() {
  local who
  if ! who=$(psql_q "SELECT current_user || '@' || current_database()" 2>&1); then
    die "cannot connect to PostgreSQL. DATABASE_URL is $(_shown "$DATABASE_URL"); when unset, libpq defaults apply, so check PGHOST, PGUSER, PGDATABASE and pg_hba.conf. Error: $who"
  fi
  if [ -z "$who" ]; then
    die "connected but PostgreSQL returned no result; check the server logs"
  fi
  log "database reachable as $who"
}

require_exec() {
  [ -x "$1" ] || die "missing or non-executable: $1"
}

# Non-blocking lock on fd 9, guarding against two copies of the SAME job. Held
# until this process exits. If a previous run is still going, exit quietly: cron
# will try again on the next tick.
take_lock() {
  exec 9>"$1" || die "cannot open lock file $1"
  if ! flock -n 9; then
    log "another run holds $1; exiting without doing anything"
    exit 0
  fi
}

# Wait for a lock on an already-open descriptor, without any timeout. Raises an
# alert every warn_secs while still waiting, so a long queue is visible but no
# work is dropped. The lock is then held until the process exits.
_wait_for_lock_fd() {
  local fd="$1"
  local lock="$2"
  local warn_secs="$3"
  local what="$4"

  if flock -n "$fd"; then
    log "acquired $what immediately"
    return 0
  fi

  log "$what is held by another job; waiting with no timeout, alerting every ${warn_secs}s"

  local sentinel
  sentinel="$LOG_DIR/.waiting.$$.$fd"
  : > "$sentinel"

  (
    elapsed=0
    while [ -f "$sentinel" ]; do
      sleep "$warn_secs"
      if [ -f "$sentinel" ]; then
        elapsed=$((elapsed + warn_secs))
        alert "still waiting for the $what after ${elapsed}s (lock file $lock). The job has NOT been abandoned and will start as soon as the lock frees. Check for a long-running worldwide ingest."
      fi
    done
  ) &
  local watchdog=$!

  flock "$fd"

  rm -f "$sentinel"
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  log "acquired $what"
}

# The probe lock, fd 8. Taken by the monthly import so its DROP TABLE and RENAME,
# which need an ACCESS EXCLUSIVE lock, cannot collide with a probe batch reading
# the same table.
take_lock_blocking() {
  exec 8>"$1" || die "cannot open lock file $1"
  _wait_for_lock_fd 8 "$1" "$2" "probe lock"
}

# The shared mutation lock, fd 7. Held by BOTH daily_pipeline and monthly_dbip,
# because both mutate ip2city_dbiplite_tbl and must never do so at once. Whichever
# arrives second waits and then runs; neither is skipped.
take_mutation_lock() {
  exec 7>"$1" || die "cannot open lock file $1"
  _wait_for_lock_fd 7 "$1" "$2" "mutation lock"
}

scalar() {
  psql_q "$1" 2>/dev/null || echo "?"
}

# Run a step, timing it. A non-zero exit aborts the script, so no later step acts
# on incomplete data. A step slower than STEP_WARN_SECS raises an alert but is
# allowed to finish, since worldwide ingestion is legitimately slow.
run_step() {
  local name="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN would execute [$name]: $*"
    return 0
  fi
  log "START $name"
  local t0 rc secs
  t0=$(date +%s)
  set +e
  "$@" >> "$LOG_FILE" 2>&1
  rc=$?
  set -e
  secs=$(( $(date +%s) - t0 ))
  if [ "$rc" -ne 0 ]; then
    die "$name failed with exit $rc after ${secs}s (see $LOG_FILE)"
  fi
  if [ "$secs" -gt "$STEP_WARN_SECS" ]; then
    alert "step $name took ${secs}s, beyond the ${STEP_WARN_SECS}s expectation. It completed successfully. Raise STEP_WARN_SECS if this is the new normal for worldwide data."
  fi
  log "DONE  $name in ${secs}s"
}
