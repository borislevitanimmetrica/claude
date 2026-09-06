#!/usr/bin/env bash
#
# geo_common.sh - shared setup for the cron scripts. Sourced, not executed.
#
# Provides: GEO_HOME, LOG_DIR, log(), die(), psql_q(), require_database(),
#           require_exec(), take_lock(), scalar(), run_step().
#
# GEO_HOME is derived from this file's own location, so the scripts work from any
# checkout path and need no configuration to find the tool binaries.
#
# DATABASE_URL IS OPTIONAL. When it is empty, psql is called with no connection
# string and pgx is given an empty one; both then resolve the connection from the
# standard libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSFILE) and
# their built-in defaults. That is how a service account connects over a Unix
# socket with peer authentication, with no credentials in the crontab or on disk.
#
# An optional config file, by default $HOME/.geo-pipeline.env, may export
# DATABASE_URL or libpq variables. Its absence is not an error.
#
# Contains no backslash escape sequences. All parameter defaulting is confined to
# the single block below, so every later reference is a plain expansion.

# ---------------------------------------------------------------------------
# Resolve this file's own directory, even when sourced, then step up one level
# to get GEO_HOME.
# ---------------------------------------------------------------------------
_geo_common_src="${BASH_SOURCE[0]}"
_geo_common_dir="$(cd "$(dirname "$_geo_common_src")" && pwd)"
_geo_home_default="$(dirname "$_geo_common_dir")"

# ---------------------------------------------------------------------------
# Parameter defaulting, all in one place.
# ---------------------------------------------------------------------------
GEO_HOME="${GEO_HOME:-$_geo_home_default}"
GEO_CONFIG="${GEO_CONFIG:-$HOME/.geo-pipeline.env}"

GEO_CONFIG_USED="environment"
if [ -r "$GEO_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$GEO_CONFIG"
  GEO_CONFIG_USED="$GEO_CONFIG"
fi

# Normalise after sourcing, so the config file may set any of these.
DATABASE_URL="${DATABASE_URL:-}"
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-}"
PGUSER="${PGUSER:-}"
PGDATABASE="${PGDATABASE:-}"
DRY_RUN="${DRY_RUN:-0}"

# Logs and lock files live under the invoking account's home, so the cron account
# never needs write access to the tool tree.
LOG_DIR="${LOG_DIR:-$HOME/geo-logs}"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Helpers. From here on every expansion is plain.
# ---------------------------------------------------------------------------

# echo rather than printf with a newline escape, keeping this file free of
# backslashes so it survives copy/paste through any channel.
log() {
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')  $*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

_shown() {
  if [ -n "$1" ]; then
    echo "$1"
  else
    echo "libpq-default"
  fi
}

report_db_mode() {
  if [ -n "$DATABASE_URL" ]; then
    log "database: DATABASE_URL set, from $GEO_CONFIG_USED"
  else
    log "database: no DATABASE_URL, using libpq defaults; host=$(_shown "$PGHOST") port=$(_shown "$PGPORT") user=$(_shown "$PGUSER") db=$(_shown "$PGDATABASE")"
  fi
}

# Run one query. The connection string is passed only when there is one: giving
# psql an empty first argument would make it treat that as a database name.
psql_q() {
  if [ -n "$DATABASE_URL" ]; then
    psql "$DATABASE_URL" -tAc "$1"
  else
    psql -tAc "$1"
  fi
}

# Confirm the database is reachable by whichever path is in use, so a
# misconfigured account fails immediately with a clear message rather than at the
# first real query.
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

# Serialise runs, so a cron overlap is a no-op rather than a concurrent run.
# Uses fd 9. Non-blocking: if the lock is held, exit quietly.
take_lock() {
  exec 9>"$1" || die "cannot open lock file $1"
  if ! flock -n 9; then
    log "another run holds $1; exiting without doing anything"
    exit 0
  fi
}

# Acquire a SECOND lock, blocking up to a timeout in seconds. Uses fd 8, so it
# composes with take_lock rather than replacing it.
#
# This exists for the monthly import. That import ends with DROP TABLE plus
# RENAME on ip2city_dbiplite_tbl, which needs an ACCESS EXCLUSIVE lock, and it
# sets lock_timeout to a few seconds so a stuck reader cannot queue every other
# query behind it. Meanwhile probe_batch reads that same table for roughly 53
# minutes of every hour, so an unsynchronised import would nearly always fail on
# lock timeout. Taking the probe lock makes the import wait for the current batch
# to finish, and makes the next hourly batch exit quietly until the import is
# done.
take_lock_blocking() {
  local lock="$1"
  local wait_secs="$2"
  exec 8>"$lock" || die "cannot open lock file $lock"
  log "waiting up to ${wait_secs}s for $lock"
  if ! flock -w "$wait_secs" 8; then
    die "timed out after ${wait_secs}s waiting for $lock; something is holding it much longer than expected"
  fi
  log "acquired $lock"
}

# The shared mutation lock, on fd 7. Held by BOTH daily_pipeline and
# monthly_dbip, blocking, because both mutate ip2city_dbiplite_tbl and must never
# do so at the same time.
#
# Normally they are hours apart, but the monthly import can be delayed while it
# waits for the probe lock, and a schedule change or a timezone move could align
# them. Without this, apply_splits could be inserting rows while the import runs
# DROP TABLE, which would either abort the import on lock timeout or fail the
# daily run with a missing relation.
#
# Both wait rather than skip, so neither job is silently dropped: whichever
# arrives second simply starts when the first finishes.
take_mutation_lock() {
  local lock="$1"
  local wait_secs="$2"
  exec 7>"$lock" || die "cannot open lock file $lock"
  log "waiting up to ${wait_secs}s for the shared mutation lock $lock"
  if ! flock -w "$wait_secs" 7; then
    die "timed out after ${wait_secs}s waiting for $lock; another mutating job is still running"
  fi
  log "acquired mutation lock $lock"
}

# Scalar for reporting only. Yields ? on failure so a reporting query can never
# abort a run.
scalar() {
  psql_q "$1" 2>/dev/null || echo "?"
}

# Run a step, timing it. Any non-zero exit aborts the whole script, so a later
# step never acts on incomplete data. Tool output goes to the log, keeping cron
# mail short.
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
  log "DONE  $name in ${secs}s"
}
