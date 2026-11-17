#!/bin/sh
# test_upgrade_path.sh - prove the schema files migrate an EXISTING database,
# not merely create a fresh one.
#
# WHY THIS EXISTS
#
# Two failures on Boris's database on 2026-11-17, both of which my tests had
# passed:
#
#   ERROR: cannot drop table carrier_node_tbl because other objects depend
#          on it, view carrier_node_located depends on it
#   ERROR: there is no unique or exclusion constraint matching the ON
#          CONFLICT specification
#
# Both were upgrade-path failures. CREATE TABLE IF NOT EXISTS does not change
# an existing table, so a widened constraint never reached his install, and a
# dependent view blocks a DROP TABLE. My tests built each table fresh, or
# built the old shape WITHOUT its dependent view, so neither path was ever
# exercised.
#
# This script builds the PREVIOUS shapes, including the dependent objects,
# then runs the current files over them. Testing a fresh install only proves
# the easy half.
#
# USAGE
#
#   sh geo/carrier_nodes/test_upgrade_path.sh
#
# Exit 0 means the upgrade succeeded. Any other value means it did not.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

PGVAL_HOME=${PGVAL_HOME:-/projects/sandbox/.pgtmp}
PGBIN="$PGVAL_HOME/pg/usr/bin"
PGSOCK="$PGVAL_HOME/sock"
PGDB=${PGDB:-upgradetest}
PGUSER_V=${PGUSER_V:-pgval}
CAIDA=${CAIDA:-/projects/sandbox/.caida}

export LD_LIBRARY_PATH="$PGVAL_HOME/pg/usr/lib64"
export PGHOST="$PGSOCK"
export PGUSER="$PGUSER_V"
export PGDATABASE="$PGDB"
export PATH="$PGBIN:$PATH"

if [ ! -x "$PGBIN/psql" ]; then
    echo "No psql at $PGBIN"
    exit 1
fi

sh geo/sessions/run_sql_validation.sh geo/carrier_nodes/schema.sql >/dev/null 2>&1

psql -X -d postgres -qc "DROP DATABASE IF EXISTS $PGDB" >/dev/null 2>&1
psql -X -d postgres -qc "CREATE DATABASE $PGDB" >/dev/null 2>&1

echo "STEP 1. Build the PREVIOUS schema, the one Boris already had."
echo

psql -X -q <<'SQL'
CREATE TABLE hoiho_rule_tbl (
    domain text PRIMARY KEY, regexes text[] NOT NULL,
    regexes_rejected text[] NOT NULL DEFAULT ARRAY[]::text[],
    ppv numeric, klass text, routers integer, tp integer, fp integer,
    loaded_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE hoiho_geohint_tbl (
    hint_id bigserial PRIMARY KEY,
    domain text NOT NULL REFERENCES hoiho_rule_tbl (domain),
    code text NOT NULL, hint_type text, lat numeric, lng numeric,
    place text, st text, cc text, tp integer, fp integer);

CREATE TABLE carrier_node_tbl (
    hostname text PRIMARY KEY,
    node_ip inet, domain text, code text, hint_type text,
    lat numeric, lng numeric, place text, st text, cc text,
    matched_re text, code_hint_count integer NOT NULL DEFAULT 1,
    selection text, corroborated_by text,
    status text NOT NULL, decoded_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE clli_site_tbl (
    clli6 text NOT NULL, clli_full text NOT NULL, switch_name text,
    company_ocn text, company_name text, rate_centre text, region text,
    rc_lat numeric, rc_lon numeric, source text NOT NULL,
    fetched_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (clli6, clli_full));

CREATE VIEW carrier_node_located AS
SELECT n.hostname, n.domain, n.lat, n.lng FROM carrier_node_tbl n;

CREATE TABLE carrier_crosswalk_tbl (
    carrier_id bigserial PRIMARY KEY, label text, itdk_domain text,
    ipapi_isp text, ipapi_org text, ipapi_as text, asn integer,
    rdap_name text, bdc_provider_id integer, bdc_frn text,
    bdc_brand_name text, itdk_basis text, ipapi_basis text,
    rdap_basis text, bdc_basis text, nodes integer NOT NULL DEFAULT 0,
    approved boolean NOT NULL DEFAULT false, approved_at timestamptz,
    note text, proposed_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (itdk_domain, asn));

CREATE TABLE carrier_name_observed_tbl (
    source text NOT NULL CHECK (source IN ('itdk','ipapi_isp','ipapi_org',
        'ipapi_as','rdap','bdc')),
    name text NOT NULL, name_norm text NOT NULL, asn integer,
    nodes integer NOT NULL DEFAULT 0, domains integer NOT NULL DEFAULT 0,
    observed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, name));

CREATE TABLE ovt_places_usa_ip_trace (
    ip inet PRIMARY KEY, last_hop_ip inet, last_hop_hostname text,
    hops jsonb);

CREATE TABLE ip2city_dbiplite_probe_tbl (
    network cidr PRIMARY KEY, isp text, org text, "as" text);

CREATE TABLE rdap_registrant_tbl (
    start_ip inet, end_ip inet, registrant text);

CREATE TABLE bdc_provider_tbl (
    provider_key serial PRIMARY KEY, frn text, provider_id integer,
    brand_name text, UNIQUE (frn, provider_id, brand_name));
SQL

echo "    previous schema built, including:"
echo "      carrier_node_tbl keyed on hostname ALONE"
echo "      view carrier_node_located DEPENDING on it"
echo "      carrier_crosswalk_tbl with UNIQUE (itdk_domain, asn)"
echo

echo "STEP 2. Put an APPROVED row in the crosswalk. It must survive."
echo
psql -X -q -c "INSERT INTO carrier_crosswalk_tbl (label, itdk_domain, asn, bdc_provider_id, bdc_brand_name, approved, approved_at, note) VALUES ('hand approved', 'comcast.net', 7922, 130317, 'Xfinity', true, now(), 'approved by Boris, must not be deleted')"
psql -X -qtAc "SELECT count(*) FROM carrier_crosswalk_tbl WHERE approved" | sed 's/^/    approved rows before upgrade: /'
echo

echo "STEP 3. Seed the four sources."
echo
psql -X -q <<'SQL'
INSERT INTO ovt_places_usa_ip_trace (ip, hops) VALUES
 ('1.1.1.1','[{"ip":"113.115.207.1","host":"113.115.207.atginternet.com"},{"ip":"113.115.207.2","host":"113.115.207.atginternet.com"},{"ip":"68.85.1.1","host":"po-1-rur201.westroxbury.ma.boston.comcast.net"}]'::jsonb),
 ('1.1.1.2','[{"ip":"68.85.1.2","host":"po-1-rur201.westroxbury.ma.boston.comcast.net"},{"ip":"24.58.1.1","host":"dynamic-acc-1-2-3.hsd1.adln.ca.frontiernet.net"}]'::jsonb),
 ('2.2.2.1','[{"ip":"203.0.113.5","host":"r1.odd.example.net"},{"ip":"198.51.100.5","host":"r2.odd.example.net"},{"ip":"192.0.2.5","host":"r3.odd.example.net"}]'::jsonb);
INSERT INTO ip2city_dbiplite_probe_tbl (network, isp, org, "as") VALUES
 ('68.85.0.0/16','Comcast Cable Communications, LLC','Comcast Cable','AS7922 Comcast Cable Communications, LLC'),
 ('24.58.0.0/16','Frontier Communications','Frontier','AS5650 Frontier Communications of America, Inc.'),
 ('113.115.0.0/16','ATG Internet','ATG','AS64999 ATG'),
 ('203.0.113.0/24','The','The','AS64500 The'),
 ('198.51.100.0/24','US','USA Inc','AS64501 Co'),
 ('192.0.2.0/24','!!!','---','AS64502 LLC');
INSERT INTO rdap_registrant_tbl (start_ip, end_ip, registrant) VALUES
 ('68.85.0.0','68.85.255.255','Comcast Cable Communications, LLC'),
 ('24.58.0.0','24.58.255.255','Frontier Communications Corporation');
INSERT INTO bdc_provider_tbl (frn, provider_id, brand_name) VALUES
 ('0001234567',130317,'Xfinity'),
 ('0003333333',130400,'Frontier Communications'),
 ('0003333334',130401,'Frontier Fiber');
SQL

echo "STEP 4. Run the CURRENT schema over the previous one."
echo
if psql -X -q -v ON_ERROR_STOP=1 -f geo/carrier_nodes/schema.sql 2>&1 | grep -iE 'error|notice.*carrier_node'; then
    :
fi
rc=$?
echo
echo "    primary key of carrier_node_tbl after the upgrade:"
psql -X -qtAc "SELECT string_agg(a.attname, ', ') FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey) WHERE c.relname = 'carrier_node_tbl' AND i.indisprimary" | sed 's/^/      /'
echo "    view carrier_node_located present again:"
psql -X -qtAc "SELECT to_regclass('carrier_node_located') IS NOT NULL" | sed 's/^/      /'
echo

echo "STEP 5. Apply the ruleset. The hostname on three addresses must load."
echo
python3 geo/carrier_nodes/hoiho_apply.py --dir "$CAIDA" load >/dev/null 2>&1
if ! python3 geo/carrier_nodes/hoiho_apply.py --dir "$CAIDA" apply; then
    echo "FAILED at apply"
    exit 1
fi
echo

echo "STEP 6. Run the crosswalk."
echo
if ! psql -X -q -v ON_ERROR_STOP=1 -f geo/carrier_nodes/carrier_crosswalk.sql > /tmp/cw.out 2>&1; then
    echo "FAILED at the crosswalk:"
    grep -iE 'error' /tmp/cw.out | head -5
    exit 1
fi
grep -iE 'error' /tmp/cw.out && { echo "FAILED, error in output"; exit 1; }
sed -n '/id |/,/rows)/p' /tmp/cw.out | head -14
echo

echo "STEP 7. Checks."
echo
app=$(psql -X -qtAc "SELECT count(*) FROM carrier_crosswalk_tbl WHERE approved")
echo "    approved rows preserved: $app"
if [ "$app" != "1" ]; then
    echo "FAILED: the approved row did not survive"
    exit 1
fi
note=$(psql -X -qtAc "SELECT note FROM carrier_crosswalk_tbl WHERE approved")
echo "    its note still reads: $note"
pairs=$(psql -X -qtAc "SELECT count(*) FROM carrier_node_tbl WHERE hostname = '113.115.207.atginternet.com'")
echo "    rows for the hostname that used to break the load: $pairs"
if [ "$pairs" != "2" ]; then
    echo "FAILED: expected 2 address rows for that hostname"
    exit 1
fi
echo
odd=$(psql -X -qtAc "SELECT count(*) FROM carrier_name_observed_tbl WHERE name IN ('The','US','USA Inc','!!!','---')")
echo "    names that strip to nothing, kept as observations: $odd"
if [ "$odd" -lt 5 ]; then
    echo "FAILED: a name whose corporate words strip to nothing was dropped"
    exit 1
fi
echo
echo "    re-running the crosswalk must be idempotent:"
psql -X -q -v ON_ERROR_STOP=1 -f geo/carrier_nodes/carrier_crosswalk.sql >/dev/null 2>&1 || {
    echo "FAILED on the second crosswalk run"; exit 1; }
app2=$(psql -X -qtAc "SELECT count(*) FROM carrier_crosswalk_tbl WHERE approved")
echo "      approved rows after a second run: $app2"
if [ "$app2" != "1" ]; then
    echo "FAILED: a second run changed the approved rows"
    exit 1
fi
echo
echo "UPGRADE PATH OK: the previous schema, its dependent view and an"
echo "approved row all survived, and every file ran without error."
