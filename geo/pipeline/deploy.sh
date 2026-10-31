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
# last_carrier_node builds from geo/main.go, which is package main at the geo
# root rather than under a cmd/ directory, so its build_dir is "." and the
# package argument stays the default ".". It was previously not deployed at all
# and had to be run out of a working copy.
TOOLS="
apply_splits:apply_splits/cmd:apply_splits
bgp_route_views:bgp_route_views/cmd:bgp_route_views
last_carrier_node:.:last_carrier_node
check_geo_ip-api:check_geo_ip-api:check_geo_ip-api
check_range_splits:check_range_splits/cmd:check_range_splits
check_routeviews_ip-api:check_routeviews_ip-api/cmd:check_routeviews_ip-api
classify_ranges:classify_ranges/cmd:classify_ranges
dbip-mmdb-import:dbip-mmdb-import/cmd:dbip-mmdb-import
expand_cidrs:dma_export/expand_cidrs/cmd:dma_export/expand_cidrs
dma_api:dma_api/cmd:dma_api
probe_range_split:probe_range_split/cmd:probe_range_split
rdap_registrant:rdap_registrant/cmd:rdap_registrant
ipapi_rate_test:ipapi_rate_test/cmd:ipapi_rate_test
"

command -v go >/dev/null 2>&1 || fail "go is not on PATH"
say "go is $(go version)"

cd "$REPO_ROOT"
REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
# A build corresponds to a commit when every TRACKED file matches that commit.
# Untracked files are a different case: they cannot change what "go build"
# produces unless Go would compile them, so only untracked Go sources and
# module files are disqualifying. Blocking on any untracked file at all meant a
# data artifact dropped into the checkout aborted the deploy, which is what
# happened with the CSV the rdap step writes next to the scripts it runs from.
DIRTY_TRACKED=$(git status --porcelain --untracked-files=no 2>/dev/null)
UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
DIRTY_BUILDABLE=$(printf '%s\n' "$UNTRACKED" | grep -E '\.go$|go\.mod$|go\.sum$' || true)
DIRTY_HARMLESS=$(printf '%s\n' "$UNTRACKED" | grep -vE '\.go$|go\.mod$|go\.sum$' | grep -v '^$' || true)

if [ -n "$DIRTY_HARMLESS" ]; then
  say "untracked files that cannot affect the build, ignoring:"
  printf '%s\n' "$DIRTY_HARMLESS" | sed 's/^/deploy:   /'
fi

if [ -n "$DIRTY_TRACKED" ] || [ -n "$DIRTY_BUILDABLE" ]; then
  if [ "${ALLOW_DIRTY:-0}" = "1" ]; then
    say "WARNING: working tree is modified and ALLOW_DIRTY=1, binaries will report vcs.modified=true"
  else
    echo "deploy: FATAL: the source tree would not correspond to any commit." >&2
    echo "Commit or stash first, or set ALLOW_DIRTY=1 if you really mean it." >&2
    if [ -n "$DIRTY_TRACKED" ]; then
      echo "Modified tracked paths:" >&2
      printf '%s\n' "$DIRTY_TRACKED" >&2
    fi
    if [ -n "$DIRTY_BUILDABLE" ]; then
      echo "Untracked Go sources or module files, which the build would compile in:" >&2
      printf '%s\n' "$DIRTY_BUILDABLE" >&2
    fi
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
sudo install -o root -g root -m 0644 "$_self_dir/patch_probe_tbl_range_fields.sql" "$GEO_HOME/pipeline/"

# The DMA API ships its canonical query and its systemd unit beside the binary.
# query.sql is the same SQL the service runs, so a psql result and an API result
# cannot drift apart. The unit file is installed for reference, not enabled: it
# has to be copied into /etc/systemd/system deliberately.
say "installing dma_api support files"
sudo install -o root -g root -m 0644 "$REPO_ROOT/geo/dma_api/query.sql" "$GEO_HOME/dma_api/"
sudo install -o root -g root -m 0644 "$REPO_ROOT/geo/dma_api/trugeo-dma-api.service" "$GEO_HOME/dma_api/"
sudo install -o root -g root -m 0755 "$_self_dir/scratch_test_rollover.sh" "$GEO_HOME/pipeline/"

# rdap-lookup.sh is a RUNTIME DEPENDENCY of last_carrier_node, which shells out
# to it as the ownership fallback for excluded-internal traces. It was missing
# from this list, so the deployed tree never had it and the fallback silently
# disabled itself on every run.
#
# It is installed NEXT TO the last_carrier_node binary because that is the first
# place the tool's "auto" search looks, which keeps the resolution independent of
# the caller's working directory.
#
# The canonical copy is geo/rdap-lookup/cmd/rdap-lookup.sh, checksum
# "3459968002 4609", the copy recorded as identical on both workstations. Do not
# substitute rdap-lookup-follow.sh: redirect-following is out of scope, ARIN only.
say "installing rdap-lookup.sh beside last_carrier_node"
sudo mkdir -p "$GEO_HOME/last_carrier_node/bin"
sudo install -o root -g root -m 0755 \
  "$REPO_ROOT/geo/rdap-lookup/cmd/rdap-lookup.sh" \
  "$GEO_HOME/last_carrier_node/bin/rdap-lookup.sh"

# The script is bash + curl + jq. A missing jq fails only at the moment the
# fallback fires, which can be hours into a run, so say so now.
for _dep in curl jq; do
  if ! command -v "$_dep" >/dev/null 2>&1; then
    say "  WARNING: $_dep not on PATH; rdap-lookup.sh will fail when the RDAP fallback fires"
  fi
done

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

# Verify the runtime dependency actually landed and matches the source, rather
# than assuming the install succeeded. A silently absent script is the whole
# reason this check exists.
_rdap_installed="$GEO_HOME/last_carrier_node/bin/rdap-lookup.sh"
_rdap_source="$REPO_ROOT/geo/rdap-lookup/cmd/rdap-lookup.sh"
if [ ! -s "$_rdap_installed" ]; then
  fail "rdap-lookup.sh missing or empty at $_rdap_installed after install"
fi
if [ "$(cksum < "$_rdap_installed")" != "$(cksum < "$_rdap_source")" ]; then
  fail "rdap-lookup.sh at $_rdap_installed does not match $_rdap_source"
fi
say "  rdap-lookup.sh $_rdap_installed cksum=$(cksum < "$_rdap_installed")"

say "done, deployed from revision $REVISION"
say "cron jobs are defined in $CRON_TARGET and run as cronuser"
