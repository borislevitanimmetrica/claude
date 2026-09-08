#!/bin/bash
# deploy.sh - build every Go tool from this checkout and install the pipeline.
#
# Binaries are NOT tracked in git. They are built here, from the commit you have
# checked out, so a deployed binary always corresponds to known source. Every
# failure worth remembering in this project traced back to a binary that did not
# match its source, so the build refuses to proceed from a dirty tree unless you
# override it deliberately.
#
# Usage:
#   ./deploy.sh                 build, verify, install to /var/trugeo and /etc/cron.d
#   ./deploy.sh --build-only    build and verify, install nothing, no sudo needed
#   ALLOW_DIRTY=1 ./deploy.sh   permit a build from a modified working tree
#
# Install steps use sudo. Run it from an interactive shell so sudo can prompt.

set -euo pipefail

_self_dir=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)
GEO_SRC="$REPO_ROOT/geo"

GEO_HOME="${GEO_HOME:-/var/trugeo}"
CRON_TARGET="${CRON_TARGET:-/etc/cron.d/trugeo}"
BUILD_ONLY=0

while [ -n "${1-}" ]; do
  if [ "$1" = "--build-only" ]; then
    BUILD_ONLY=1
  elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "deploy.sh - build every Go tool and install the pipeline"
    echo ""
    echo "  --build-only   build and verify only, install nothing"
    echo "  -h, --help     this text"
    echo ""
    echo "Environment:"
    echo "  GEO_HOME       install prefix for binaries and scripts, default /var/trugeo"
    echo "  CRON_TARGET    cron file destination, default /etc/cron.d/trugeo"
    echo "  ALLOW_DIRTY    set to 1 to build from a modified working tree"
    exit 0
  else
    echo "unknown argument: $1" >&2
    exit 2
  fi
  shift
done

say() {
  echo "deploy: $*"
}

fail() {
  echo "deploy: FATAL: $*" >&2
  exit 1
}

# Every tool, as "name:build_dir:install_subpath". build_dir is relative to
# geo/ and is where "go build" runs. install_subpath is relative to GEO_HOME
# and mirrors the layout the pipeline scripts expect, which is
# GEO_HOME/<subpath>/bin/<name> as used by require_exec.
TOOLS="
apply_splits:apply_splits/cmd:apply_splits
bgp_route_views:bgp_route_views/cmd:bgp_route_views
check_geo_ip-api:check_geo_ip-api:check_geo_ip-api
check_range_splits:check_range_splits/cmd:check_range_splits
check_routeviews_ip-api:check_routeviews_ip-api/cmd:check_routeviews_ip-api
classify_ranges:classify_ranges/cmd:classify_ranges
dbip-mmdb-import:dbip-mmdb-import/cmd:dbip-mmdb-import
expand_cidrs:dma_export/expand_cidrs/cmd:dma_export/expand_cidrs
"

command -v go >/dev/null 2>&1 || fail "go is not on PATH"
say "go is $(go version)"

cd "$REPO_ROOT"
REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  if [ "${ALLOW_DIRTY:-0}" = "1" ]; then
    say "WARNING: working tree is modified and ALLOW_DIRTY=1, binaries will report vcs.modified=true"
  else
    echo "deploy: FATAL: working tree is modified, so the build would not correspond to any commit." >&2
    echo "Commit or stash first, or set ALLOW_DIRTY=1 if you really mean it." >&2
    echo "Modified paths:" >&2
    git status --porcelain >&2
    exit 1
  fi
fi
say "building from revision $REVISION"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

BUILT=0
for entry in $TOOLS; do
  name=$(echo "$entry" | cut -d: -f1)
  builddir=$(echo "$entry" | cut -d: -f2)
  subpath=$(echo "$entry" | cut -d: -f3)

  target="$GEO_SRC/$builddir"
  [ -d "$target" ] || fail "missing source directory $target, is this a complete checkout?"

  # check_geo_ip-api keeps its go.mod at the tool root with package main under
  # cmd, so the package argument differs from the others.
  pkg="."
  if [ "$name" = "check_geo_ip-api" ]; then
    pkg="./cmd"
  fi

  printf 'deploy:   %-26s ' "$name"
  ( cd "$target" && go build -o "$STAGE/$name" "$pkg" ) || fail "build failed for $name"

  modified=$(go version -m "$STAGE/$name" | grep vcs.modified | cut -d= -f2)
  if [ -z "$modified" ]; then
    modified="absent"
  fi
  echo "ok  vcs.modified=$modified"

  # The artifact itself is the authority, not the earlier tree check, because
  # only the binary records what it was actually built from.
  if [ "$modified" != "false" ] && [ "${ALLOW_DIRTY:-0}" != "1" ]; then
    fail "$name reports vcs.modified=$modified, so it matches no commit. Refusing to deploy it."
  fi
  BUILT=$((BUILT + 1))
done
say "built $BUILT tools"

if [ "$BUILD_ONLY" = "1" ]; then
  say "build-only, nothing installed. Binaries are in $STAGE, which is removed on exit."
  say "sha256 of what was built:"
  ( cd "$STAGE" && sha256sum ./* )
  exit 0
fi

say "installing binaries under $GEO_HOME"
for entry in $TOOLS; do
  name=$(echo "$entry" | cut -d: -f1)
  subpath=$(echo "$entry" | cut -d: -f3)
  sudo mkdir -p "$GEO_HOME/$subpath/bin"
  sudo install -o root -g root -m 0755 "$STAGE/$name" "$GEO_HOME/$subpath/bin/$name"
  say "  installed $name to $GEO_HOME/$subpath/bin/$name"
done

say "installing pipeline scripts"
sudo mkdir -p "$GEO_HOME/pipeline"
sudo install -o root -g root -m 0755 "$_self_dir/daily_pipeline.sh" "$_self_dir/probe_batch.sh" "$_self_dir/monthly_dbip.sh" "$GEO_HOME/pipeline/"
sudo install -o root -g root -m 0644 "$_self_dir/geo_common.sh" "$GEO_HOME/pipeline/"
sudo install -o root -g root -m 0755 "$_self_dir/deploy.sh" "$GEO_HOME/pipeline/"

# SQL run by the pipeline at runtime. daily_pipeline.sh resolves this relative to
# its own directory, so it must be installed next to the scripts or the
# probe-table rebuild fails with a missing-file error.
sudo install -o root -g root -m 0644 "$_self_dir/rebuild_probe_tbl.sql" "$GEO_HOME/pipeline/"

say "installing cron file to $CRON_TARGET"
sudo install -o root -g root -m 0644 "$_self_dir/trugeo.cron" "$CRON_TARGET"

say "verifying installed tree"
for entry in $TOOLS; do
  name=$(echo "$entry" | cut -d: -f1)
  subpath=$(echo "$entry" | cut -d: -f3)
  installed="$GEO_HOME/$subpath/bin/$name"
  rev=$(go version -m "$installed" | grep vcs.revision | cut -d= -f2 | cut -c1-7)
  mod=$(go version -m "$installed" | grep vcs.modified | cut -d= -f2)
  say "  $name revision=$rev modified=$mod"
done

say "done, deployed from revision $REVISION"
say "cron jobs are defined in $CRON_TARGET and run as cronuser"
