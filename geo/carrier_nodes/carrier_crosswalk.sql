-- geo/carrier_nodes/carrier_crosswalk.sql
--
-- Carrier identity across the four sources that name carriers differently.
-- Produces a list with one column per source FOR BORIS TO APPROVE.
--
-- Boris, 2026-11-17: "If it is a list of carriers, it should relate carriers
-- by name, and names differ in ITDK, Fabric, ip-api.com and RDAP (in case we
-- need it). Obtain the names from each source and submit a list with fields
-- per source for my approval."
--
-- This file REPLACES carrier_domain_provider_tbl from
-- geo/carrier_nodes/schema.sql, which paired a DNS domain to a single BDC
-- provider_id and was the wrong shape.
--
-- PRE-MORTEM for that replacement: carrier_domain_provider_tbl is created
-- empty by schema.sql and nothing writes to it, so dropping it destroys no
-- data and no evidence. It is dropped only after the count below confirms it
-- is empty; if anything has been put in it since, this file stops and
-- changes nothing.
--
--
-- THE SHAPE OF THE PROBLEM
--
-- Four sources, four naming systems, no shared key between all four:
--
--   ITDK / Hoiho   a DNS domain from a router hostname      comcast.net
--   ip-api.com     isp, org and an "as" string per range    AS7922 Comcast...
--   RDAP           the registrant of the address block      Comcast Cable...
--   FCC BDC        frn, provider_id and brand_name          130317 Xfinity
--
-- THREE OF THE FOUR CAN BE LINKED BY MEASUREMENT, not by name. A carrier node
-- has an IP address. That address falls inside a routed range. The range
-- carries ip-api's isp, org and AS, and it carries an RDAP registrant. So
-- domain, ip-api name and RDAP name are joined through the node's own
-- address, with a countable number of nodes supporting each pairing.
--
-- BDC IS THE ONE THAT CANNOT BE. A BDC filing has no IP address in it, so
-- there is nothing to join on and the only available link is the name itself.
-- Those rows are therefore PROPOSALS with a stated basis, not conclusions,
-- which is why the approval column exists and defaults to false.
--
-- Safe to re-run. Section 4 is the only one that writes, and it is an upsert
-- that never overwrites an approved row.

\pset pager off
\set ON_ERROR_STOP on

-- A STATEMENT TIMEOUT, so a slow statement ABORTS WITH A MESSAGE instead of
-- sitting there. Boris has twice been left watching a prompt that had
-- nothing to say: once for ten minutes on the proposal insert and once for
-- fourteen on a query in carrier_decisions.sql. An analysis file that can
-- be wrong about its own cost should fail loudly rather than appear to work.
--
-- Ten minutes is deliberately generous: every statement here is expected to
-- take seconds, so hitting this limit means something is wrong with the
-- query and not with the data volume. Raise it with -v on the command line
-- if a genuinely long statement is ever wanted.
SET statement_timeout = '10min';

-- A LOCK TIMEOUT alongside the statement timeout. A queued DDL request
-- blocks writers as well as itself; see the note in
-- geo/fcc_bdc/rename_provider_to_carrier.sql for what that cost on
-- 2026-11-17.
SET lock_timeout = '5s';

-- TIMING IS ON because its absence cost Boris ten minutes of not knowing
-- whether the file was working or hung. With it, the statement that is slow
-- names itself. This is cheap and should be the default in any analysis file
-- that can run for minutes.
\timing on

\echo
\echo ===========================================================
\echo SECTION 0. Which sources are actually populated right now
\echo ===========================================================
\echo
\echo A zero here is not a failure, it is a dependency not yet met, and it
\echo tells you which columns of the final list will be empty. The BDC load
\echo was still running when this file was written, so bdc_carrier_tbl may
\echo legitimately be short or absent.
\echo

SELECT 'carrier_node_tbl (ITDK domains)'  AS source,
       to_regclass('carrier_node_tbl') IS NOT NULL AS table_exists,
       (SELECT count(*) FROM carrier_node_tbl
        WHERE to_regclass('carrier_node_tbl') IS NOT NULL) AS rows
UNION ALL
SELECT 'ip2city_dbiplite_probe_tbl (ip-api)',
       to_regclass('ip2city_dbiplite_probe_tbl') IS NOT NULL,
       NULL
UNION ALL
SELECT 'rdap_registrant_tbl (RDAP)',
       to_regclass('rdap_registrant_tbl') IS NOT NULL,
       NULL
UNION ALL
SELECT 'bdc_carrier_tbl (FCC BDC)',
       to_regclass('bdc_carrier_tbl') IS NOT NULL,
       NULL;

\echo
\echo Row counts for the three large tables, queried separately so a missing
\echo table reports as a NOTICE rather than aborting the file.
\echo

DO $$
DECLARE n bigint; t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['ip2city_dbiplite_probe_tbl',
                             'rdap_registrant_tbl',
                             'bdc_carrier_tbl',
                             'carrier_node_tbl']
    LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE NOTICE '% does not exist in this database', t;
        ELSE
            EXECUTE format('SELECT count(*) FROM %I', t) INTO n;
            RAISE NOTICE '% holds % rows', t, n;
        END IF;
    END LOOP;
END
$$;


\echo
\echo ---- 0a. IS THERE ANYTHING TO CROSSWALK
\echo

DO $$
DECLARE n bigint;
BEGIN
    SELECT count(*) INTO n FROM carrier_node_tbl;
    IF n = 0 THEN
        -- AN EXCEPTION, NOT A WARNING. A warning let the file run to
        -- completion and hand Boris a blank approval list with no
        -- indication that anything was wrong, after geo/carrier_nodes/
        -- schema.sql had just dropped and recreated this table as part of
        -- its key migration. Twenty minutes went into looking at an empty
        -- result that was empty for a knowable reason.
        --
        -- Stopping here changes nothing: the statements above this point
        -- only create tables and read counts.
        RAISE EXCEPTION 'carrier_node_tbl IS EMPTY, so this file would produce zero rows everywhere and hand you a blank approval list. NOTHING HAS BEEN CHANGED. geo/carrier_nodes/schema.sql DROPS and recreates this table when it migrates the key, which is almost certainly what just happened. Run this, then re-run this file:  python3 geo/carrier_nodes/hoiho_apply.py apply';
    ELSE
        RAISE NOTICE 'carrier_node_tbl holds % hostname and address pairs', n;
    END IF;
END
$$;

\echo
\echo ---- 0b. The COLUMNS this file needs, verified not assumed
\echo
\echo Standing order: never take a column name from a source file. The
\echo ip-api column names below came from the UPDATE in
\echo geo/check_geo_ip-api/cmd/main.go, which states what the CURRENT build
\echo would write and not what the deployed table holds. This prints what is
\echo actually there, and stops the file if anything required is missing.
\echo

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'ip2city_dbiplite_probe_tbl'
  AND column_name IN ('network', 'isp', 'org', 'as')
ORDER BY column_name;

DO $$
DECLARE missing text[];
BEGIN
    IF to_regclass('ip2city_dbiplite_probe_tbl') IS NULL THEN
        RAISE EXCEPTION 'ip2city_dbiplite_probe_tbl does not exist. Nothing has been changed.';
    END IF;

    SELECT array_agg(c) INTO missing
    FROM unnest(ARRAY['network', 'isp', 'org', 'as']) AS c
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'ip2city_dbiplite_probe_tbl'
          AND column_name = c);

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION
            'ip2city_dbiplite_probe_tbl is missing column(s) %. Nothing has been changed. The ip-api column names were read from the UPDATE in geo/check_geo_ip-api/cmd/main.go and that is a statement about the current build, not the deployed table. Print the real columns from the query above and tell me the right names.', missing;
    END IF;
    RAISE NOTICE 'every ip-api column this file needs is present';
END
$$;


\echo
\echo ===========================================================
\echo SECTION 1. The observed-name store
\echo ===========================================================
\echo

-- One row per (source, name) actually seen, with how many carrier nodes
-- support it. Kept as its own table rather than recomputed, because the
-- expensive part is the range containment join and the result is the input to
-- every later judgement.
CREATE TABLE IF NOT EXISTS carrier_name_observed_tbl (
    source       text NOT NULL
                 CHECK (source IN ('itdk', 'ipapi_isp', 'ipapi_org',
                                   'ipapi_as', 'rdap', 'bdc')),
    name         text NOT NULL,

    -- Nullable. A name consisting only of punctuation normalises to nothing,
    -- and such a row is still worth keeping as an observation: it simply
    -- matches nothing. Making it NOT NULL turned one unusable name into an
    -- aborted run.
    -- A normalised form for comparison across sources. Lower-cased,
    -- punctuation stripped, and the corporate suffixes removed that differ
    -- between sources for the same company: LLC against L.L.C. against
    -- Inc against Incorporated.
    name_norm    text,

    -- The AS number where the source supplies one. This is the strongest
    -- join key available and it is why ipapi_as is kept as its own source
    -- rather than folded into ipapi_isp.
    asn          integer,

    -- Evidence. nodes is how many distinct carrier node addresses produced
    -- this name; domains is how many distinct DNS domains did.
    nodes        integer NOT NULL DEFAULT 0,
    domains      integer NOT NULL DEFAULT 0,
    observed_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, name)
);

-- MIGRATION: drop NOT NULL on name_norm for installs created before
-- 2026-11-17. CREATE TABLE IF NOT EXISTS leaves an existing table alone, so
-- the change above does not reach a database that already has this table.
DO $$
BEGIN
    IF to_regclass('carrier_name_observed_tbl') IS NOT NULL
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'carrier_name_observed_tbl'
                     AND column_name = 'name_norm'
                     AND is_nullable = 'NO')
    THEN
        ALTER TABLE carrier_name_observed_tbl
            ALTER COLUMN name_norm DROP NOT NULL;
        RAISE NOTICE 'name_norm on carrier_name_observed_tbl is now nullable; a name of only punctuation normalises to nothing and must not abort the run';
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS carrier_name_observed_norm_idx
    ON carrier_name_observed_tbl (name_norm);
CREATE INDEX IF NOT EXISTS carrier_name_observed_asn_idx
    ON carrier_name_observed_tbl (asn);

COMMENT ON TABLE carrier_name_observed_tbl IS
    'Every carrier name actually seen in each source, with the number of carrier nodes supporting it. Populated by section 3 of geo/carrier_nodes/carrier_crosswalk.sql. This is observation, not judgement: no row here asserts that two names are the same company.';


\echo
\echo ===========================================================
\echo SECTION 2. The crosswalk, for approval
\echo ===========================================================
\echo

CREATE TABLE IF NOT EXISTS carrier_crosswalk_tbl (
    carrier_id   bigserial PRIMARY KEY,

    -- A short label of Boris's choosing, for reading. Not a key.
    label        text,

    -- ITDK / Hoiho. The DNS domain in router hostnames.
    itdk_domain  text,

    -- ip-api.com, as recorded per range in ip2city_dbiplite_probe_tbl.
    ipapi_isp    text,
    ipapi_org    text,
    ipapi_as     text,
    asn          integer,

    -- RDAP registrant of the address blocks the nodes sit in.
    rdap_name    text,

    -- FCC BDC. The one source with no IP address to join on.
    bdc_provider_id integer,
    bdc_frn         text,
    bdc_brand_name  text,

    -- HOW each link was established, per source, so an approved row still
    -- says what it rests on. 'node address containment' is measured;
    -- 'name match' is proposed; 'manual' is Boris.
    itdk_basis   text,
    ipapi_basis  text,
    rdap_basis   text,
    bdc_basis    text,

    -- Evidence strength: distinct carrier node addresses behind the
    -- measured part of this row.
    nodes        integer NOT NULL DEFAULT 0,

    -- FALSE until Boris says otherwise. Nothing downstream should join
    -- through an unapproved row.
    approved     boolean NOT NULL DEFAULT false,
    approved_at  timestamptz,
    note         text,
    proposed_at  timestamptz NOT NULL DEFAULT now(),

    -- Several BDC candidates per domain is the normal case, not an error:
    -- a carrier files under several brands and only Boris can choose. So
    -- the uniqueness is on the full proposal, not on the domain.
    UNIQUE (itdk_domain, asn, bdc_provider_id)
);

CREATE INDEX IF NOT EXISTS carrier_crosswalk_domain_idx
    ON carrier_crosswalk_tbl (itdk_domain);
CREATE INDEX IF NOT EXISTS carrier_crosswalk_asn_idx
    ON carrier_crosswalk_tbl (asn);
CREATE INDEX IF NOT EXISTS carrier_crosswalk_bdc_idx
    ON carrier_crosswalk_tbl (bdc_provider_id);
CREATE INDEX IF NOT EXISTS carrier_crosswalk_approved_idx
    ON carrier_crosswalk_tbl (approved);

COMMENT ON TABLE carrier_crosswalk_tbl IS
    'One row per carrier, carrying its name in ITDK, ip-api, RDAP and FCC BDC. The ITDK, ip-api and RDAP columns are linked by measurement through a carrier node address; the BDC columns can only be linked by name and are proposals. approved is false until Boris agrees, and nothing downstream should join through an unapproved row.';
COMMENT ON COLUMN carrier_crosswalk_tbl.bdc_basis IS
    'How the BDC pairing was arrived at. A BDC filing contains no IP address, so there is nothing to join on and this is a name comparison. It is the weakest column in the table and is the reason approved exists.';
COMMENT ON COLUMN carrier_crosswalk_tbl.nodes IS
    'Distinct carrier node addresses supporting the measured part of this row. A row with a handful of nodes is a weaker observation than one with hundreds and should be read as such.';


-- MIGRATION for installs created before 2026-11-17, where CREATE TABLE IF
-- NOT EXISTS left the original UNIQUE (itdk_domain, asn) in place. Several
-- BDC candidates per domain is the normal case, so that constraint is wrong.
-- The file no longer depends on any constraint here, but leaving a wrong one
-- in place would reject legitimate rows.
DO $$
DECLARE cname text;
BEGIN
    IF to_regclass('carrier_crosswalk_tbl') IS NULL THEN
        RETURN;
    END IF;
    SELECT con.conname INTO cname
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    WHERE c.relname = 'carrier_crosswalk_tbl'
      AND con.contype = 'u'
      AND con.conkey = ARRAY[
          (SELECT attnum FROM pg_attribute
           WHERE attrelid = c.oid AND attname = 'itdk_domain'),
          (SELECT attnum FROM pg_attribute
           WHERE attrelid = c.oid AND attname = 'asn')]::smallint[];
    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE carrier_crosswalk_tbl DROP CONSTRAINT %I',
                       cname);
        RAISE NOTICE 'dropped the stale two-column unique constraint % on carrier_crosswalk_tbl; several BDC candidates per domain is normal', cname;
    END IF;
END
$$;


-- Drop the superseded stub, but only if it is empty.
DO $$
DECLARE n bigint;
BEGIN
    IF to_regclass('carrier_domain_provider_tbl') IS NULL THEN
        RAISE NOTICE 'carrier_domain_provider_tbl is already absent';
        RETURN;
    END IF;
    EXECUTE 'SELECT count(*) FROM carrier_domain_provider_tbl' INTO n;
    IF n > 0 THEN
        RAISE NOTICE 'carrier_domain_provider_tbl holds % rows, so it has NOT been dropped. Nothing was lost. Move those rows into carrier_crosswalk_tbl and drop it by hand.', n;
        RETURN;
    END IF;
    DROP TABLE carrier_domain_provider_tbl;
    RAISE NOTICE 'carrier_domain_provider_tbl was empty and has been dropped, superseded by carrier_crosswalk_tbl';
END
$$;


\echo
\echo ===========================================================
\echo SECTION 3. Collect the names from every source
\echo ===========================================================
\echo

-- Normalisation used on every source alike. Deliberately conservative: it
-- lower-cases, removes punctuation and drops only the corporate-form words
-- that genuinely differ between registries. It does NOT drop words like
-- cable, communications or broadband, because those distinguish real
-- companies and dropping them would merge distinct carriers.
-- THE FALLBACK IS NOT COSMETIC. Removing corporate-form words can empty a
-- name completely: ip-api carries an org of literally 'The', and 'US',
-- 'Inc' and 'The Group' do the same. The first version returned NULL for
-- those and the NOT NULL column rejected the row, which aborted the whole
-- file on Boris's data after 1,480 rows had already gone in.
--
-- So when stripping the corporate words leaves nothing, the punctuation-only
-- normalisation is returned instead. A name of 'The' then normalises to
-- 'the', which will not match anything useful, and that is the correct
-- outcome: it is not a carrier name. What matters is that it does not stop
-- the file or vanish from the observation table.
CREATE OR REPLACE FUNCTION carrier_name_norm(t text) RETURNS text AS $$
    WITH base AS (
        SELECT nullif(btrim(regexp_replace(
                   regexp_replace(lower(coalesce(t, '')),
                                  '[^a-z0-9 ]+', ' ', 'g'),
                   ' {2,}', ' ', 'g')), '') AS b
    ),
    stripped AS (
        SELECT nullif(btrim(regexp_replace(regexp_replace(b,
                   '\y(llc|l l c|inc|incorporated|corp|corporation|co|company|ltd|limited|lp|llp|plc|holdings|group|usa|us|the|dba|fka)\y',
                   ' ', 'g'), ' {2,}', ' ', 'g')), '') AS sv, b
        FROM base
    )
    SELECT coalesce(sv, b) FROM stripped;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION carrier_name_norm(text) IS
    'Conservative name normalisation for cross-source comparison. Removes punctuation and corporate-form words only, and KEEPS cable, communications, broadband and similar because those distinguish real companies. If removing the corporate words would empty the name, as it does for an org of The or US, the punctuation-only form is returned instead; returning NULL there once aborted a whole run.';

TRUNCATE carrier_name_observed_tbl;

\echo ---- 3a. ITDK: the DNS domains in router hostnames
\echo

INSERT INTO carrier_name_observed_tbl
       (source, name, name_norm, nodes, domains)
SELECT 'itdk', domain, carrier_name_norm(domain),
       count(DISTINCT node_ip), 1
FROM carrier_node_tbl
WHERE domain IS NOT NULL
GROUP BY domain;

SELECT count(*) AS itdk_domains,
       sum(nodes) AS node_addresses
FROM carrier_name_observed_tbl WHERE source = 'itdk';

\echo
\echo ---- 3b. ip-api: isp, org and AS for the range each node sits in
\echo
\echo The join is most-specific containment, ORDER BY masklen DESC LIMIT 1,
\echo the same convention as geo/landmark_carrier_node.sql section 2 and
\echo geo/apply_splits. A node address can sit inside several announced
\echo prefixes and the narrowest is the one that describes it.
\echo

CREATE TEMP TABLE node_range AS
SELECT n.hostname,
       n.node_ip,
       n.domain,
       p.network,
       p.isp,
       p.org,
       p."as" AS as_string
FROM carrier_node_tbl n
CROSS JOIN LATERAL (
    SELECT q.network, q.isp, q.org, q."as"
    FROM ip2city_dbiplite_probe_tbl q
    WHERE q.network >>= n.node_ip
    ORDER BY masklen(q.network) DESC
    LIMIT 1
) p
WHERE n.node_ip IS NOT NULL;

CREATE INDEX ON node_range (domain);

SELECT count(*)                       AS nodes_with_a_range,
       count(DISTINCT domain)         AS domains,
       count(*) FILTER (WHERE isp IS NOT NULL)        AS with_isp,
       count(*) FILTER (WHERE as_string IS NOT NULL)  AS with_as
FROM node_range;

INSERT INTO carrier_name_observed_tbl
       (source, name, name_norm, asn, nodes, domains)
SELECT 'ipapi_isp', isp, carrier_name_norm(isp), NULL,
       count(DISTINCT node_ip), count(DISTINCT domain)
FROM node_range WHERE isp IS NOT NULL AND isp <> ''
GROUP BY isp
ON CONFLICT (source, name) DO NOTHING;

INSERT INTO carrier_name_observed_tbl
       (source, name, name_norm, asn, nodes, domains)
SELECT 'ipapi_org', org, carrier_name_norm(org), NULL,
       count(DISTINCT node_ip), count(DISTINCT domain)
FROM node_range WHERE org IS NOT NULL AND org <> ''
GROUP BY org
ON CONFLICT (source, name) DO NOTHING;

-- The "as" string is of the form 'AS7922 Comcast Cable Communications, LLC'.
-- The number is extracted because it is the only hard key in this whole
-- exercise, and the remainder is normalised as a name.
INSERT INTO carrier_name_observed_tbl
       (source, name, name_norm, asn, nodes, domains)
SELECT 'ipapi_as', as_string,
       carrier_name_norm(regexp_replace(as_string, '^AS[0-9]+\s*', '')),
       nullif(regexp_replace(as_string, '^AS([0-9]+).*$', '\1'), as_string)::integer,
       count(DISTINCT node_ip), count(DISTINCT domain)
FROM node_range WHERE as_string IS NOT NULL AND as_string <> ''
GROUP BY as_string
ON CONFLICT (source, name) DO NOTHING;

\echo
\echo ---- 3c. RDAP: the registrant of the block each node sits in
\echo

-- node_rdap is created UNCONDITIONALLY, empty if there is no RDAP table.
-- Creating it inside the conditional was a bug: section 4 references it
-- whatever happens, so an absent rdap_registrant_tbl aborted the whole file
-- at the point it was supposed to degrade gracefully.
CREATE TEMP TABLE node_rdap (
    hostname   text,
    node_ip    inet,
    domain     text,
    registrant text
);

DO $$
BEGIN
    IF to_regclass('rdap_registrant_tbl') IS NULL THEN
        RAISE NOTICE 'rdap_registrant_tbl absent; the RDAP column will be empty and node_rdap stays empty';
        RETURN;
    END IF;

    INSERT INTO node_rdap (hostname, node_ip, domain, registrant)
    SELECT nr.hostname, nr.node_ip, nr.domain, r.registrant
    FROM node_range nr
    CROSS JOIN LATERAL (
        SELECT x.registrant
        FROM rdap_registrant_tbl x
        WHERE x.start_ip <= nr.node_ip AND x.end_ip >= nr.node_ip
        ORDER BY (x.end_ip - x.start_ip)
        LIMIT 1
    ) r
    WHERE r.registrant IS NOT NULL AND r.registrant <> '';

    INSERT INTO carrier_name_observed_tbl
           (source, name, name_norm, nodes, domains)
    SELECT 'rdap', registrant, carrier_name_norm(registrant),
           count(DISTINCT node_ip), count(DISTINCT domain)
    FROM node_rdap
    GROUP BY registrant
    ON CONFLICT (source, name) DO NOTHING;

    RAISE NOTICE 'RDAP names collected';
END
$$;

CREATE INDEX ON node_rdap (domain);

\echo
\echo ---- 3d. FCC BDC: frn, provider_id and brand_name
\echo

DO $$
BEGIN
    IF to_regclass('bdc_carrier_tbl') IS NULL THEN
        RAISE NOTICE 'bdc_carrier_tbl absent; apply geo/fcc_bdc/schema_v2.sql and load the downloads first. The BDC columns will be empty.';
        RETURN;
    END IF;

    INSERT INTO carrier_name_observed_tbl
           (source, name, name_norm, nodes, domains)
    SELECT 'bdc', brand_name, carrier_name_norm(brand_name), 0, 0
    FROM bdc_carrier_tbl
    WHERE brand_name IS NOT NULL AND brand_name <> ''
    GROUP BY brand_name
    ON CONFLICT (source, name) DO NOTHING;

    RAISE NOTICE 'BDC brand names collected';
END
$$;

\echo
\echo ---- 3e. What was collected, per source
\echo

SELECT source,
       count(*)                                  AS distinct_names,
       count(*) FILTER (WHERE asn IS NOT NULL)   AS with_asn,
       sum(nodes)                                AS node_evidence
FROM carrier_name_observed_tbl
GROUP BY source
ORDER BY source;


\echo
\echo ===========================================================
\echo SECTION 4. The proposal, one row per carrier
\echo ===========================================================
\echo
\echo ITDK, ip-api and RDAP are joined BY MEASUREMENT through the node
\echo address. BDC is joined by normalised name and is a PROPOSAL.
\echo Every row arrives with approved = false.
\echo

-- The measured core: per DNS domain, the dominant ip-api and RDAP identity,
-- chosen by how many distinct node addresses support it. Dominant rather than
-- any, because a domain's address space can contain a handful of ranges that
-- another party registered, and the majority identity is the carrier.
CREATE TEMP TABLE measured AS
WITH per_domain_as AS (
    SELECT domain, as_string,
           nullif(regexp_replace(as_string, '^AS([0-9]+).*$', '\1'),
                  as_string)::integer AS asn,
           count(DISTINCT node_ip) AS n,
           row_number() OVER (PARTITION BY domain
                              ORDER BY count(DISTINCT node_ip) DESC,
                                       as_string) AS rn
    FROM node_range
    WHERE as_string IS NOT NULL AND as_string <> ''
    GROUP BY domain, as_string
),
per_domain_isp AS (
    SELECT domain, isp, org,
           count(DISTINCT node_ip) AS n,
           row_number() OVER (PARTITION BY domain
                              ORDER BY count(DISTINCT node_ip) DESC,
                                       isp) AS rn
    FROM node_range
    WHERE isp IS NOT NULL AND isp <> ''
    GROUP BY domain, isp, org
),
totals AS (
    SELECT domain, count(DISTINCT node_ip) AS nodes FROM node_range
    GROUP BY domain
)
SELECT t.domain,
       t.nodes,
       a.as_string,
       a.asn,
       i.isp,
       i.org,
       -- Normalised ONCE per domain, for the same reason as the shim.
       carrier_name_norm(i.isp)                          AS isp_norm,
       split_part(carrier_name_norm(i.isp), ' ', 1)      AS isp_first
FROM totals t
LEFT JOIN per_domain_as  a ON a.domain = t.domain AND a.rn = 1
LEFT JOIN per_domain_isp i ON i.domain = t.domain AND i.rn = 1;

CREATE INDEX ON measured (domain);
CREATE INDEX ON measured (isp_norm);
CREATE INDEX ON measured (isp_first);
ANALYZE measured;

-- The dominant RDAP registrant per domain, materialised. It was a LATERAL
-- subquery correlated to each candidate row, so it re-aggregated node_rdap
-- once per proposal instead of once per domain.
CREATE TEMP TABLE domain_rdap AS
SELECT domain, registrant
FROM (SELECT domain, registrant,
             row_number() OVER (PARTITION BY domain
                                ORDER BY count(DISTINCT node_ip) DESC,
                                         registrant) AS rn
      FROM node_rdap
      GROUP BY domain, registrant) z
WHERE rn = 1;

CREATE INDEX ON domain_rdap (domain);
ANALYZE domain_rdap;

-- A shim over bdc_carrier_tbl, because a table named in a LEFT JOIN is
-- resolved by the planner whether or not a to_regclass guard in the ON
-- clause would be false. So the guard has to happen before the query is
-- parsed, which means building a table of the right shape either way.
DO $$
BEGIN
    DROP TABLE IF EXISTS bdc_carrier_shim;
    -- brand_norm and brand_first are MATERIALISED, not computed in the
    -- join. MEASURED 2026-11-17 at Boris's scale, 4,117 domains against 749
    -- providers: calling carrier_name_norm inside the ON clause took 169
    -- SECONDS, because the clause calls it 24 times per candidate pair and
    -- there are 3.08 million pairs, so about 74 million invocations of a
    -- function doing four regexp_replace passes each. Precomputed once per
    -- row it is 4,866 calls and the join runs in under a second. Both
    -- return the identical 442,326 pairs.
    CREATE TEMP TABLE bdc_carrier_shim (
        provider_id integer, frn text, brand_name text,
        brand_norm text, brand_first text);
    CREATE INDEX ON bdc_carrier_shim (brand_norm);
    CREATE INDEX ON bdc_carrier_shim (brand_first);
    IF to_regclass('bdc_carrier_tbl') IS NOT NULL THEN
        INSERT INTO bdc_carrier_shim
               (provider_id, frn, brand_name, brand_norm, brand_first)
        SELECT provider_id, frn, brand_name,
               carrier_name_norm(brand_name),
               split_part(carrier_name_norm(brand_name), ' ', 1)
        FROM bdc_carrier_tbl
        WHERE brand_name IS NOT NULL AND brand_name <> '';
        RAISE NOTICE 'bdc_carrier_shim filled from bdc_carrier_tbl';
    END IF;

    -- ANALYZE IS NOT OPTIONAL HERE, and omitting it was the whole problem.
    -- A temp table created inside a DO block has NO statistics, so the
    -- planner guesses its size and picks a plan for the proposal join
    -- accordingly. MEASURED 2026-11-17: with the shim unanalysed the
    -- proposal INSERT took 220 SECONDS; the identical join over the same
    -- data with both sides analysed took 639 MILLISECONDS. The join shape,
    -- the LIKE patterns and the NOT EXISTS were all innocent, which is why
    -- precomputing the normalisation alone did not fix it.
    ANALYZE bdc_carrier_shim;
    IF true THEN
    ELSE
        RAISE NOTICE 'bdc_carrier_tbl absent; BDC columns will be empty';
    END IF;
END
$$;

\echo The measured core, top 30 domains by node evidence:
\echo

SELECT domain, nodes, asn, left(isp, 34) AS ipapi_isp,
       left(org, 30) AS ipapi_org
FROM measured
ORDER BY nodes DESC
LIMIT 30;

-- UNAPPROVED PROPOSALS ARE CLEARED AND REGENERATED, approvals are kept.
--
-- This replaces an ON CONFLICT clause that failed on Boris's database with
-- "there is no unique or exclusion constraint matching the ON CONFLICT
-- specification". The cause was CREATE TABLE IF NOT EXISTS: his
-- carrier_crosswalk_tbl already existed carrying the earlier
-- UNIQUE (itdk_domain, asn), so widening the constraint in the CREATE had no
-- effect on his install. geo/traceroute_hostname_rules.sql documents this
-- precise trap and I walked into it anyway.
--
-- Rather than migrate a constraint, the insert no longer needs one. Deleting
-- the unapproved rows first makes a re-run regenerate proposals from current
-- data, which is the behaviour actually wanted: a better name matcher or
-- more loaded BDC providers should change the proposals.
--
-- PRE-MORTEM: this deletes ONLY rows with approved = false, which are
-- machine-generated proposals regenerated by the INSERT immediately below
-- from data still present. Rows Boris has approved are untouched, and the
-- INSERT additionally skips any pairing that duplicates an approved row.
DELETE FROM carrier_crosswalk_tbl WHERE NOT approved;

-- The approved pairings, as an indexable key set. Built before the DELETE's
-- effect matters because only approved rows survive it anyway.
DROP TABLE IF EXISTS approved_key;
CREATE TEMP TABLE approved_key AS
SELECT coalesce(itdk_domain, '')   AS itdk_domain,
       coalesce(asn, -1)           AS asn,
       coalesce(bdc_provider_id, -1) AS bdc_provider_id
FROM carrier_crosswalk_tbl
WHERE approved;

CREATE INDEX ON approved_key (itdk_domain, asn, bdc_provider_id);
ANALYZE approved_key;

\echo
\echo ---- 4a. HOW MANY proposals WOULD be made, counted before inserting
\echo
\echo Counted first because the insert is the expensive part and a runaway
\echo count is unusable as an approval list. MEASURED 2026-11-17 on a
\echo deliberately degenerate fixture: the join producing 177,577 candidate
\echo rows took 645 MILLISECONDS, and INSERTING them took 225 SECONDS. So
\echo the cost is the write volume, and the count is the thing to look at.
\echo

CREATE TEMP TABLE proposal_count AS
SELECT count(*) FILTER (WHERE tier = 'equal')     AS equal_rows,
       count(*) FILTER (WHERE tier = 'contained') AS contained_rows,
       count(*) FILTER (WHERE tier = 'firstword') AS firstword_rows,
       count(*)                                   AS total_rows
FROM (
    SELECT CASE
             WHEN b.brand_norm = m.isp_norm THEN 'equal'
             WHEN b.brand_norm LIKE '%' || m.isp_norm || '%'
               OR m.isp_norm LIKE '%' || b.brand_norm || '%' THEN 'contained'
             ELSE 'firstword'
           END AS tier
    FROM measured m
    JOIN bdc_carrier_shim b
      ON m.isp_norm IS NOT NULL AND b.brand_norm IS NOT NULL
     AND (b.brand_norm = m.isp_norm
          OR b.brand_norm LIKE '%' || m.isp_norm || '%'
          OR m.isp_norm LIKE '%' || b.brand_norm || '%'
          OR (b.brand_first = m.isp_first AND length(m.isp_first) >= 4))
) t;

SELECT equal_rows, contained_rows, firstword_rows, total_rows,
       CASE WHEN total_rows > 20000
            THEN 'TOO MANY: the weak first-word tier will be SKIPPED'
            ELSE 'within the limit, all tiers will be proposed'
       END AS verdict
FROM proposal_count;

DO $$
DECLARE n bigint; fw bigint; strong bigint;
BEGIN
    SELECT total_rows, firstword_rows, equal_rows + contained_rows
      INTO n, fw, strong FROM proposal_count;
    IF strong > 20000 THEN
        RAISE NOTICE 'STOP. Even the strong tiers alone would propose % rows, so NOTHING will be inserted. A list that size is not reviewable and the cause is name over-matching, not carrier count. Section 4b names the worst offenders.', strong;
    ELSIF n > 20000 THEN
        RAISE NOTICE 'Proposals would be %, of which % come from the weak first-word tier. Above 20,000 that tier is SKIPPED: a list that long cannot be reviewed and it is the tier most likely to be wrong. The % strong proposals will be inserted.', n, fw, strong;
    ELSE
        RAISE NOTICE 'Proposals: % rows, all tiers included', n;
    END IF;
END
$$;

\echo
\echo ---- 4b. WHICH names over-match, shown whenever the count is large
\echo
\echo A handful of generic names matching many providers is what makes a
\echo proposal list explode. These are the names to look at, not the
\echo carrier count.
\echo

SELECT left(m.isp_norm, 40) AS ipapi_name_normalised,
       count(DISTINCT b.provider_id) AS bdc_providers_matched,
       count(DISTINCT m.domain)      AS itdk_domains_with_this_name,
       left(string_agg(DISTINCT b.brand_name, ', '), 60) AS example_brands
FROM measured m
JOIN bdc_carrier_shim b
  ON m.isp_norm IS NOT NULL AND b.brand_norm IS NOT NULL
 AND (b.brand_norm = m.isp_norm
      OR b.brand_norm LIKE '%' || m.isp_norm || '%'
      OR m.isp_norm LIKE '%' || b.brand_norm || '%')
GROUP BY m.isp_norm
HAVING count(DISTINCT b.provider_id) > 3
ORDER BY count(DISTINCT b.provider_id) DESC
LIMIT 15;

\echo
\echo Proposed BDC pairings. A pairing is offered only when the normalised
\echo names are equal or one contains the other, and the basis records which.
\echo A name that matches several BDC providers yields several rows, all
\echo unapproved, because choosing between them is a decision for Boris.
\echo

INSERT INTO carrier_crosswalk_tbl
       (label, itdk_domain, ipapi_isp, ipapi_org, ipapi_as, asn,
        rdap_name, bdc_provider_id, bdc_frn, bdc_brand_name,
        itdk_basis, ipapi_basis, rdap_basis, bdc_basis, nodes)
SELECT coalesce(m.isp, m.domain),
       m.domain, m.isp, m.org, m.as_string, m.asn,
       rd.registrant,
       b.provider_id, b.frn, b.brand_name,
       'router hostname suffix',
       CASE WHEN m.isp IS NULL THEN NULL
            ELSE 'node address containment, dominant of ' || m.nodes
                 || ' node addresses' END,
       CASE WHEN rd.registrant IS NULL THEN NULL
            ELSE 'node address containment' END,
       CASE WHEN b.provider_id IS NULL THEN NULL
            WHEN b.brand_norm = m.isp_norm THEN 'normalised name equal'
            WHEN b.brand_norm LIKE '%' || m.isp_norm || '%'
              OR m.isp_norm LIKE '%' || b.brand_norm || '%'
                 THEN 'normalised name contained'
            ELSE 'first word only, WEAK' END,
       m.nodes
FROM measured m
LEFT JOIN domain_rdap rd ON rd.domain = m.domain
LEFT JOIN bdc_carrier_shim b
    ON m.isp_norm IS NOT NULL
   AND b.brand_norm IS NOT NULL
   AND (b.brand_norm = m.isp_norm
        OR b.brand_norm LIKE '%' || m.isp_norm || '%'
        OR m.isp_norm LIKE '%' || b.brand_norm || '%'
        -- THE FIRST-WORD TIER, and why it is here despite being weak.
        -- Equality and containment proposed Frontier Communications for
        -- frontiernet.net but MISSED Frontier Fiber, a second brand of the
        -- same carrier. Missing a brand defeats the purpose: separating
        -- FIOS from xDSL requires every brand a carrier files under.
        -- So a shared first significant word also proposes, labelled
        -- 'first word only, WEAK' so it is visibly the weakest basis.
        -- It will propose wrong pairs too, which is what approval is for.
        OR (b.brand_first = m.isp_first AND length(m.isp_first) >= 4))
  -- AN EQUALITY ANTI-JOIN against a materialised key set, not a correlated
  -- NOT EXISTS using IS NOT DISTINCT FROM.
  --
  -- IS NOT DISTINCT FROM cannot use an index, so that subquery became a
  -- sequential scan of carrier_crosswalk_tbl evaluated once per candidate
  -- row. On Boris's data this INSERT hit the ten minute statement timeout.
  --
  -- approved_key below is a tiny temp table with coalesced columns and a
  -- real index, so the same test is an index lookup. It is the third time
  -- in this file's history that a correlated subquery had to become a join;
  -- the pattern is now explicit.
  AND NOT EXISTS (
      SELECT 1 FROM approved_key k
      WHERE k.itdk_domain = coalesce(m.domain, '')
        AND k.asn = coalesce(m.asn, -1)
        AND k.bdc_provider_id = coalesce(b.provider_id, -1))
  -- THE GUARD. When the proposal count would exceed 20,000 the weak
  -- first-word tier is dropped, keeping only equality and containment. A
  -- list of 177,577 rows is not an approval list, and the first-word tier is
  -- both the largest contributor and the one most likely to be wrong.
  -- Section 4a printed the counts, so what was skipped is visible rather
  -- than silent.
  AND (b.provider_id IS NULL
       OR (SELECT total_rows FROM proposal_count) <= 20000
       OR b.brand_norm = m.isp_norm
       OR b.brand_norm LIKE '%' || m.isp_norm || '%'
       OR m.isp_norm LIKE '%' || b.brand_norm || '%')
  -- THE HARD STOP. If even equality and containment would propose more than
  -- 20,000 rows, no BDC pairing is inserted at all. The measured rows still
  -- go in, so the ITDK, ip-api and RDAP crosswalk is delivered and only the
  -- BDC column is left empty. Inserting an unreviewable list is worse than
  -- delivering the part that is sound.
  AND ((SELECT equal_rows + contained_rows FROM proposal_count) <= 20000
       OR b.provider_id IS NULL);


-- REFRESH THE MEASURED COLUMNS ON APPROVED ROWS.
--
-- An approved row is never deleted, so without this it keeps whatever
-- measured values it had when it was approved, while a newly measured
-- proposal for the same carrier appears beside it. Found by the upgrade-path
-- test, which approved a comcast.net row by hand and then saw the approval
-- carrying empty ip-api and RDAP columns next to a fresh row carrying them.
--
-- Only the MEASURED columns are touched. approved, approved_at, note, the
-- BDC columns and bdc_basis are left exactly as they are, because those are
-- Boris's decision and this is new evidence about the same carrier, not a
-- reason to revisit the decision.
UPDATE carrier_crosswalk_tbl c
SET ipapi_isp   = m.isp,
    ipapi_org   = m.org,
    ipapi_as    = m.as_string,
    rdap_name   = coalesce(rd.registrant, c.rdap_name),
    nodes       = m.nodes,
    ipapi_basis = CASE WHEN m.isp IS NULL THEN c.ipapi_basis
                       ELSE 'node address containment, dominant of '
                            || m.nodes || ' node addresses' END
FROM measured m
LEFT JOIN LATERAL (
    SELECT registrant FROM node_rdap nr
    WHERE nr.domain = m.domain
    GROUP BY registrant
    ORDER BY count(DISTINCT node_ip) DESC
    LIMIT 1
) rd ON true
WHERE c.approved
  AND c.itdk_domain = m.domain
  AND c.asn IS NOT DISTINCT FROM m.asn;

\echo
\echo Approved rows had their MEASURED columns refreshed from current data.
\echo The approval itself, the note and the BDC choice were not touched.
\echo

\echo
\echo ===========================================================
\echo SECTION 5. THE LIST FOR APPROVAL
\echo ===========================================================
\echo
\echo One row per carrier, one column per source. Ordered by node evidence so
\echo the carriers that matter most to step 2 come first.
\echo
\echo HOW TO APPROVE: edit and run, one carrier at a time or in bulk,
\echo   UPDATE carrier_crosswalk_tbl SET approved = true, approved_at = now()
\echo    WHERE carrier_id IN (...);
\echo Nothing downstream joins through an unapproved row.
\echo

SELECT carrier_id   AS id,
       itdk_domain  AS itdk,
       asn,
       left(ipapi_isp, 30)      AS ipapi_isp,
       left(rdap_name, 30)      AS rdap,
       bdc_provider_id          AS bdc_id,
       left(bdc_brand_name, 24) AS bdc_brand,
       nodes,
       bdc_basis,
       approved
FROM carrier_crosswalk_tbl
ORDER BY nodes DESC, itdk_domain,
         CASE bdc_basis
             WHEN 'normalised name equal'     THEN 1
             WHEN 'normalised name contained' THEN 2
             WHEN 'first word only, WEAK'     THEN 3
             ELSE 4
         END,
         bdc_brand_name
LIMIT 200;

\echo
\echo Proposals by strength of basis. Equal is strongest, first word is
\echo weakest and will contain wrong pairs.
\echo

SELECT coalesce(bdc_basis, 'no BDC candidate found') AS bdc_basis,
       count(*)                     AS rows,
       count(DISTINCT itdk_domain)  AS domains
FROM carrier_crosswalk_tbl
GROUP BY bdc_basis
ORDER BY count(*) DESC;

\echo
\echo Summary of what needs deciding:
\echo

SELECT count(*)                                              AS proposed_rows,
       count(DISTINCT itdk_domain)                           AS domains,
       count(*) FILTER (WHERE bdc_provider_id IS NOT NULL)   AS with_bdc,
       count(*) FILTER (WHERE bdc_provider_id IS NULL)       AS without_bdc,
       count(*) FILTER (WHERE approved)                      AS already_approved
FROM carrier_crosswalk_tbl;

\echo
\echo Domains carrying nodes but NO ip-api identity. These are the ones where
\echo the measured link failed, usually because the node address sits outside
\echo every probed range, and they cannot be crosswalked until that range is
\echo probed.
\echo

SELECT m.domain, m.nodes
FROM measured m
WHERE m.isp IS NULL
ORDER BY m.nodes DESC
LIMIT 25;

\echo
\echo Where one ITDK domain proposes SEVERAL BDC providers. Each needs one
\echo chosen, or all rejected.
\echo

SELECT itdk_domain,
       count(*)                                   AS bdc_candidates,
       string_agg(DISTINCT bdc_brand_name, ' | ' ORDER BY bdc_brand_name)
           AS candidates
FROM carrier_crosswalk_tbl
WHERE bdc_provider_id IS NOT NULL
GROUP BY itdk_domain
HAVING count(*) > 1
ORDER BY count(*) DESC
LIMIT 20;
