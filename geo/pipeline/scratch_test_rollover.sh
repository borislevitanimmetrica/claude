#!/bin/bash
# scratch_test_rollover.sh - prove the probe table rollover works, before trusting
# it to fire unattended at 02:00.
#
# WHAT IS UNTESTED AND WHY THIS EXISTS
#
# rebuild_probe_tbl.sql does three things in one transaction: archive every row
# into ip2city_dbiplite_history_tbl, truncate the probe table, repopulate it from
# the reconciled data. Only the populate has ever run. The archive has not, and
# cannot until a probing cycle completes, which at 45 calls a minute is about 36
# days away. This exercises all of it now.
#
# PRODUCTION DATA IS NEVER TOUCHED, BY CONSTRUCTION
#
# rebuild_probe_tbl.sql refers to every table by unqualified name. It is run here
# with search_path set to "scratch" ALONE, with no public fallback, so every one
# of those names can only resolve inside the scratch schema. If a scratch table
# were missing, the statement errors and the transaction rolls back. It cannot
# reach public.ip2city_dbiplite_probe_tbl even if this script is wrong.
#
# That is why all six tables the SQL reads or writes are copied, including
# trugeo_states_tbl, geo_exclusions and a slice of bgp_route_views. Leaving any of
# them to fall through to public would mean reintroducing public into the search
# path, and with it the possibility of truncating the live probe table.
#
# Belt and braces on top of that: the live row count and the live probe high water
# mark are captured before anything runs and re-checked after every rebuild. Any
# change aborts the test.
#
# The real rebuild_probe_tbl.sql is run, not a copy, so what passes here is the
# artifact that will run in production.
#
# Probing is simulated with an UPDATE rather than by calling ip-api. The probe
# path is already proven in production at 2400 ranges an hour; the archive is what
# is unproven. Simulating costs no API budget and tests the right thing.
#
# Runs as boris because CREATE SCHEMA needs a privilege cronuser does not have.
# cronuser's ability to write the real history table is asserted separately.
#
# Usage:
#   ./scratch_test_rollover.sh
#   ENABLE_ON_PASS=1 ./scratch_test_rollover.sh   enable automatic rollover if all
#                                                 assertions pass
#   KEEP_SCRATCH=1 ./scratch_test_rollover.sh     leave the schema for inspection
#
# Contains NO backslashes so it survives copy/paste.

set -uo pipefail

_self_dir=$(cd "$(dirname "$0")" && pwd)
REBUILD_SQL="$_self_dir/rebuild_probe_tbl.sql"
SAMPLE_ROWS="${SAMPLE_ROWS:-200}"
GEO_CONFIG_FILE="${GEO_CONFIG_FILE:-/etc/trugeo.env}"
FAILURES=0

psqlb() {
  sudo -u boris psql -d postgres -v ON_ERROR_STOP=1 "$@"
}

q() {
  sudo -u boris psql -d postgres -tAqc "$1"
}

say() {
  echo "scratch: $*"
}

check() {
  local label="$1"
  local got="$2"
  local want="$3"
  if [ "$got" = "$want" ]; then
    echo "  PASS  $label (got $got)"
  else
    echo "  FAIL  $label (got $got, wanted $want)"
    FAILURES=$((FAILURES + 1))
  fi
}

check_gt() {
  local label="$1"
  local got="$2"
  if [ "$got" -gt 0 ] 2>/dev/null; then
    echo "  PASS  $label (got $got)"
  else
    echo "  FAIL  $label (got $got, wanted greater than zero)"
    FAILURES=$((FAILURES + 1))
  fi
}

cleanup() {
  if [ "${KEEP_SCRATCH:-0}" = "1" ]; then
    say "KEEP_SCRATCH=1, leaving schema scratch in place"
  else
    say "dropping schema scratch"
    psqlb -qc "DROP SCHEMA IF EXISTS scratch CASCADE" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

[ -f "$REBUILD_SQL" ] || { echo "scratch: FATAL: $REBUILD_SQL not found" >&2; exit 1; }

say "using $REBUILD_SQL"

# ---------------------------------------------------------------------------
# Live data fingerprint, taken before anything else happens. Re-checked after
# every rebuild. If either value ever moves, this script has touched production
# and the test aborts immediately.
# ---------------------------------------------------------------------------
LIVE_ROWS_BEFORE=$(q "select count(*) from public.ip2city_dbiplite_probe_tbl")
LIVE_PROBED_BEFORE=$(q "select count(*) from public.ip2city_dbiplite_probe_tbl where ran_at is not null")
say "live probe table fingerprint: $LIVE_ROWS_BEFORE rows, $LIVE_PROBED_BEFORE of them probed. This must not change."

assert_live_untouched() {
  local when="$1"
  local rows probed
  rows=$(q "select count(*) from public.ip2city_dbiplite_probe_tbl")
  probed=$(q "select count(*) from public.ip2city_dbiplite_probe_tbl where ran_at is not null")
  if [ "$rows" != "$LIVE_ROWS_BEFORE" ] || [ "$probed" != "$LIVE_PROBED_BEFORE" ]; then
    echo "  FAIL  LIVE DATA CHANGED $when: rows $LIVE_ROWS_BEFORE to $rows, probed $LIVE_PROBED_BEFORE to $probed" >&2
    echo "scratch: ABORTING. The scratch isolation did not hold." >&2
    FAILURES=$((FAILURES + 1))
    exit 1
  fi
  echo "  PASS  live probe table untouched $when ($rows rows, $probed probed)"
}

say "step 0: assert the archive can actually be written by the account that will write it"
CAN_INSERT=$(q "select has_table_privilege('cronuser','public.ip2city_dbiplite_history_tbl','INSERT')")
check "cronuser has INSERT on the real history table" "$CAN_INSERT" "t"
REAL_PK_COLS=$(q "select coalesce(max(array_length(conkey,1)),0) from pg_constraint where conrelid='public.ip2city_dbiplite_history_tbl'::regclass and contype='p'")
check "real history primary key spans 2 columns, so successive cycles can be archived" "$REAL_PK_COLS" "2"

say "step 1: build scratch copies of EVERY table the rebuild touches"
psqlb -q <<'SETUP'
DROP SCHEMA IF EXISTS scratch CASCADE;
CREATE SCHEMA scratch;
CREATE TABLE scratch.ip2city_dbiplite_probe_tbl   (LIKE public.ip2city_dbiplite_probe_tbl   INCLUDING ALL);
CREATE TABLE scratch.ip2city_dbiplite_history_tbl (LIKE public.ip2city_dbiplite_history_tbl INCLUDING ALL);
CREATE TABLE scratch.ip2city_dbiplite_tbl         (LIKE public.ip2city_dbiplite_tbl         INCLUDING ALL);
CREATE TABLE scratch.trugeo_states_tbl            (LIKE public.trugeo_states_tbl            INCLUDING ALL);
CREATE TABLE scratch.geo_exclusions               (LIKE public.geo_exclusions               INCLUDING ALL);
CREATE TABLE scratch.bgp_route_views              (LIKE public.bgp_route_views              INCLUDING ALL);
INSERT INTO scratch.trugeo_states_tbl SELECT * FROM public.trugeo_states_tbl;
INSERT INTO scratch.geo_exclusions    SELECT * FROM public.geo_exclusions;
SETUP

say "step 2: copy only the BGP rows an ASN exclusion could match, so the join is real but small"
psqlb -qc "INSERT INTO scratch.bgp_route_views SELECT b.* FROM public.bgp_route_views b JOIN public.geo_exclusions x ON x.active AND x.origin_asn IS NOT NULL AND b.origin_asn = x.origin_asn"

say "step 3: seed the scratch source with a small slice of real reconciled rows"
psqlb -qc "INSERT INTO scratch.ip2city_dbiplite_tbl SELECT * FROM public.ip2city_dbiplite_tbl WHERE country_iso_code = 'US' AND family(network) = 4 LIMIT $SAMPLE_ROWS"
SRC=$(q "select count(*) from scratch.ip2city_dbiplite_tbl")
check_gt "scratch source seeded" "$SRC"

say "step 4: prove that under the test search_path, every mutated name resolves to scratch and NOT to public"
for tbl in ip2city_dbiplite_probe_tbl ip2city_dbiplite_history_tbl ip2city_dbiplite_tbl trugeo_states_tbl geo_exclusions bgp_route_views; do
  RESOLVED=$(sudo -u boris psql -d postgres -tAqc "SET search_path = scratch; SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = '$tbl'::regclass")
  check "$tbl resolves to scratch" "$RESOLVED" "scratch"
done
if [ "$FAILURES" -ne 0 ]; then
  say "ABORTING before any rebuild: name resolution is not safely isolated."
  exit 1
fi

say "step 5: FIRST rebuild. Empty table, so nothing to archive"
psqlb -c "SET search_path = scratch" -c "SET geo.country = 'US'" -c "SET geo.family = '4'" -f "$REBUILD_SQL"
assert_live_untouched "after first rebuild"
P1=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl")
H1=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl")
NULLRAN=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where ran_at is null")
NOQ=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where query is null")
OOR=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where query < start_ip or query > end_ip")
SC=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where state_code is not null")
check_gt "probe table populated" "$P1"
check "history still empty" "$H1" "0"
check "every populated row awaits a probe" "$NULLRAN" "$P1"
check "every row has a probe target" "$NOQ" "0"
check "every target lies inside its range" "$OOR" "0"
check_gt "state_code resolved for at least some rows" "$SC"

# Asserted explicitly because the range comparison alone was not enough to catch
# it the first time round. network() preserves the prefix length, so an unwrapped
# "network(x) + offset" stored a /24 into query. inet ordering puts a /24 below
# its own /32 start_ip, which surfaced as every row being out of range without
# saying why. These three assertions name the cause directly.
MASKQ=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where family(query) = 4 and masklen(query) <> 32")
MASKS=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where family(start_ip) = 4 and masklen(start_ip) <> 32")
MASKE=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where family(end_ip) = 4 and masklen(end_ip) <> 32")
check "query is a host address, not a prefix" "$MASKQ" "0"
check "start_ip is a host address" "$MASKS" "0"
check "end_ip is a host address" "$MASKE" "0"

say "step 6: rebuild again while rows are unprobed. The gate must refuse"
psqlb -c "SET search_path = scratch" -c "SET geo.country = 'US'" -c "SET geo.family = '4'" -f "$REBUILD_SQL"
assert_live_untouched "after gated rebuild"
P2=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl")
H2=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl")
check "gate refused, probe row count unchanged" "$P2" "$P1"
check "gate refused, nothing archived" "$H2" "0"

say "step 7: simulate a completed probing cycle"
psqlb -qc "UPDATE scratch.ip2city_dbiplite_probe_tbl SET ran_at = now(), last_hop_ip = query, status = 'success', attempts = 1, isp = 'scratch cycle one'"
REMAIN=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where ran_at is null")
check "cycle complete, nothing awaiting a probe" "$REMAIN" "0"

say "step 8: THIRD rebuild. This is the archive path that has never run in production"
psqlb -c "SET search_path = scratch" -c "SET geo.country = 'US'" -c "SET geo.family = '4'" -f "$REBUILD_SQL"
assert_live_untouched "after archiving rebuild"
H3=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl")
P3=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl")
H3RAN=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl where ran_at is not null")
H3IP=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl where start_ip is not null and end_ip is not null and query is not null")
H3ISP=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl where isp = 'scratch cycle one'")
P3NULL=$(q "select count(*) from scratch.ip2city_dbiplite_probe_tbl where ran_at is null")
check "the finished cycle was archived in full" "$H3" "$P1"
check "archived rows carry ran_at" "$H3RAN" "$P1"
check "archived rows carry start_ip, end_ip and query" "$H3IP" "$P1"
check "archived rows carry the probe results" "$H3ISP" "$P1"
check "probe table repopulated to the same size" "$P3" "$P1"
check "repopulated rows await a probe again" "$P3NULL" "$P1"

say "step 9: a SECOND cycle must archive on top of the first, which the old single column primary key forbade"
psqlb -qc "UPDATE scratch.ip2city_dbiplite_probe_tbl SET ran_at = now(), last_hop_ip = query, status = 'success', isp = 'scratch cycle two'"
psqlb -c "SET search_path = scratch" -c "SET geo.country = 'US'" -c "SET geo.family = '4'" -f "$REBUILD_SQL"
assert_live_untouched "after second archiving rebuild"
H4=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl")
C1=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl where isp = 'scratch cycle one'")
C2=$(q "select count(*) from scratch.ip2city_dbiplite_history_tbl where isp = 'scratch cycle two'")
EXPECT_H4=$((P1 * 2))
check "history holds both cycles" "$H4" "$EXPECT_H4"
check "first cycle still present" "$C1" "$P1"
check "second cycle added" "$C2" "$P1"

echo
assert_live_untouched "at end of test"
echo

if [ "$FAILURES" -ne 0 ]; then
  say "RESULT: FAIL with $FAILURES failed assertions. Do NOT enable automatic rollover."
  exit 1
fi

say "RESULT: PASS. Archive, truncate, repopulate and the cycle gate all behave correctly, history accumulates across cycles, and the live probe table was untouched throughout."

if [ "${ENABLE_ON_PASS:-0}" != "1" ]; then
  echo
  say "Automatic rollover is NOT enabled. To enable it now that the test has passed:"
  say "  echo 'export PROBE_TBL_REBUILD=1' | sudo tee -a $GEO_CONFIG_FILE"
  say "Or re-run this script with ENABLE_ON_PASS=1."
  exit 0
fi

say "ENABLE_ON_PASS=1: enabling automatic rollover"
if sudo grep -q "PROBE_TBL_REBUILD=1" "$GEO_CONFIG_FILE" 2>/dev/null; then
  say "already enabled in $GEO_CONFIG_FILE, nothing to do"
else
  echo 'export PROBE_TBL_REBUILD=1' | sudo tee -a "$GEO_CONFIG_FILE" >/dev/null
  say "appended to $GEO_CONFIG_FILE"
fi
say "current contents of $GEO_CONFIG_FILE:"
sudo cat "$GEO_CONFIG_FILE" | sed 's/^/    /'
say "the 02:00 daily_pipeline will now check the cycle gate every night and roll over on the first night after a cycle completes"
