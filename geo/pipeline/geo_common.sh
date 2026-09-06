#!/usr/bin/env bash
#
# geo_common.sh - shared setup for the cron scripts. Sourced, not executed.
#
# Provides: GEO_HOME, LOG_DIR, log(), die(), run_step(), scalar(), take_lock().
#
# GEO_HOME is derived from this file's own location, so the scripts work from any
# checkout path and need no configuration to find the tool binaries.
#
# Credentials are NOT held in the crontab. Instead this sources a config file,
# by default $HOME/.geo-pipeline.env, which must export DATABASE_URL. Keep it
# mode 0600 and owned by the account cron runs as. Override the location with
# GEO_CONFIG.
#
# Contains no backslash escape sequences.

# Resolve this file's directory even when sourced, then step up one level.
_geo_common_src="${BASH_SOURCE[0]}"
_geo_common_dir="$(cd "$(dirname "$_geo_common_src")" && pwd)"
GEO_HOME="${GEO_HOME:-$(dirname "$_geo_common_dir")}"

GEO_CONFIG="${GEO_CONFIG:-$HOME/.geo-pipeline.env}"
if [ -r "$GEO_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$GEO_CONFIG"
fi

# Logs and lock files live under the invoking account's home by default, so the
# cron account never needs write access to the tool tree.
LOG_DIR="${LOG_DIR:-$HOME/geo-logs}"
mkdir -p "$LOG_DIR"

log() {
  # echo rather than printf with a newline escape, so this file stays free of
  # backslashes and survives copy/paste through any channel.
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')  $*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

require_database_url() {
  if [ -z "${DATABASE_URL:-}" ]; then
    die "DATABASE_URL is not set. Create $GEO_CONFIG containing a line that exports it, mode 0600."
  fi
}

require_exec() {
  local p="$1"
  [ -x "$p" ] || die "missing or non-executable: $p"
}

# Serialise runs. Returns non-zero to the caller's exit if the lock is held, so a
# cron overlap is a no-op rather than a concurrent run.
take_lock() {
  local lock="$1"
  exec 9>"$lock" || die "cannot open lock file $lock"
  if ! flock -n 9; then
    log "another run holds $lock; exiting without doing anything"
    exit 0
  fi
}

# One-line SQL scalar. Returns ? on any failure so reporting never aborts a run.
scalar() {
  psql "$DATABASE_URL" -tAc "$1" 2>/dev/null || echo "?"
}

# Run a step, timing it. Any non-zero exit aborts the whole script, so a later
# step never acts on incomplete data. Tool output goes to the log, keeping cron
# mail short.
run_step() {
  local name="$1"; shift
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
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
