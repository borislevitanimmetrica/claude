-- validation_schema.sql
--
-- A MINIMAL FIXTURE, NOT A SCHEMA REPLICA. Creates empty tables carrying only
-- the columns the analysis SQL in this repo actually references, so those
-- files can be EXECUTED before being sent to Boris.
--
-- WHY THIS EXISTS
--
-- On 2026-11-10 I shipped institution_reconciliation.sql with a plain SQL
-- error: a CASE referencing a bare category column while the GROUP BY used the
-- coalesced expression. PostgreSQL rejected the first statement outright,
-- tmp_recon was never created, and every one of the seven later sections then
-- failed on a missing relation. Boris ran it and got nothing but errors.
--
-- Reading carefully is not a sufficient control for that. Executing is. With
-- empty tables a query is still fully parsed, name-resolved and planned, so
-- this catches:
--
--   - GROUP BY and aggregate violations, which is what got through
--   - misspelled or nonexistent columns, the recurring failure the standing
--     orders were written about
--   - misspelled tables, bad casts, type mismatches, invalid psql
--     meta-commands
--
-- It does NOT catch: wrong results, wrong denominators, or slow plans. Row
-- counts are all zero, so EXPLAIN costs here mean nothing about production.
-- The four-hour section 3 of rdap_filler_allocations.sql would NOT have been
-- caught by this.
--
-- WHAT IS AND IS NOT FAITHFUL
--
-- landmarks_usa and rdap_registrant_tbl are created from the REAL DDL in this
-- repo by run_sql_validation.sh, which strips only the TABLESPACE clause. They
-- are faithful.
--
-- The tables below are STUBS. Column names and types are taken from
-- information_schema output Boris has actually run, where I have it:
--
--   zip_adjacency    VERIFIED 2026-11-10: zip_a and zip_b character varying,
--                    distance_km numeric, created_at timestamptz.
--   isp_names        VERIFIED: one column, name.
--   provider_names   VERIFIED: one column, name.
--
-- For these two I have only a column COUNT and the handful of names our SQL
-- touches, so the stub is deliberately incomplete and is NOT evidence about
-- the real table:
--
--   ip2city_dbiplite_tbl   17 columns in production. The 17 below are
--                          apply_splits insertColumns, which matches that
--                          count, but I have NOT seen information_schema for
--                          this table and the match could be coincidence.
--   geo_exclusions         6 columns in production. Only prefix and active are
--                          verified, from the SQL that reads them. The rest
--                          here are invented placeholders so the row is
--                          creatable and MUST NOT be cited as real.
--   rdap_fill_cand_tbl     8 columns in production. Only network,
--                          prefix_width, covered and covered_at are verified.

CREATE TABLE IF NOT EXISTS isp_names (name text NOT NULL);

CREATE TABLE IF NOT EXISTS provider_names (name text NOT NULL);

CREATE TABLE IF NOT EXISTS zip_adjacency (
    zip_a       character varying,
    zip_b       character varying,
    distance_km numeric,
    created_at  timestamptz
);

-- STUB. See the header: column list is apply_splits insertColumns, not
-- information_schema.
CREATE TABLE IF NOT EXISTS ip2city_dbiplite_tbl (
    network              cidr,
    continent_code       text,
    continent_geoname_id bigint,
    continent_names      jsonb,
    country_geoname_id   bigint,
    country_iso_code     text,
    country_is_in_eu     boolean,
    country_names        jsonb,
    city_names           jsonb,
    latitude             float8,
    longitude            float8,
    subdivisions_names   jsonb,
    start_ip             inet,
    end_ip               inet,
    city                 text,
    state                text,
    source               text
);

-- STUB with invented placeholder columns beyond prefix and active.
CREATE TABLE IF NOT EXISTS geo_exclusions (
    id       bigserial PRIMARY KEY,
    prefix   cidr,
    active   boolean NOT NULL DEFAULT true,
    reason   text,
    note     text,
    added_at timestamptz NOT NULL DEFAULT now()
);

-- STUB beyond the four verified columns.
CREATE TABLE IF NOT EXISTS rdap_fill_cand_tbl (
    network      cidr,
    prefix_width int,
    covered      boolean,
    covered_at   timestamptz
);

-- Built by node_fanout.sql as CREATE TABLE AS, so there is no declared DDL to
-- copy. Columns and types here are read off that SELECT list, verified
-- 2026-11-12: ip_address from cl.grp::inet, zips_at_address and
-- clusters_at_address from integer counts, too_wide boolean, places from
-- count(*), registrant from min(registrant_1), verdict from a CASE over text
-- literals.
CREATE TABLE IF NOT EXISTS address_hosting_tbl (
    ip_address          inet,
    zips_at_address     int,
    clusters_at_address int,
    too_wide            boolean,
    places              bigint,
    registrant          text,
    verdict             text
);

-- Referenced by apply_splits loadParents. Stub.
CREATE TABLE IF NOT EXISTS ip2city_dbiplite_probe_tbl (
    network cidr,
    ran_at  timestamptz,
    isp     text,
    org     text
);

-- Referenced by the demand-side forensics files. Stub, columns from the
-- section 1 information_schema dump those files printed.
CREATE TABLE IF NOT EXISTS ip2city_dbiplite_traceroute_tbl (
    network           cidr,
    probe_method      text,
    hop_count         int,
    last_hop_ip       inet,
    last_hop_hostname text,
    last_hop_number   int,
    city              text,
    zip               text,
    isp               text,
    ran_at            timestamptz
);
