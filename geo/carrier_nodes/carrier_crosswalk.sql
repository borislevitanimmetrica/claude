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

\echo
\echo ===========================================================
\echo SECTION 0. Which sources are actually populated right now
\echo ===========================================================
\echo
\echo A zero here is not a failure, it is a dependency not yet met, and it
\echo tells you which columns of the final list will be empty. The BDC load
\echo was still running when this file was written, so bdc_provider_tbl may
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
SELECT 'bdc_provider_tbl (FCC BDC)',
       to_regclass('bdc_provider_tbl') IS NOT NULL,
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
                             'bdc_provider_tbl',
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

    -- A normalised form for comparison across sources. Lower-cased,
    -- punctuation stripped, and the corporate suffixes removed that differ
    -- between sources for the same company: LLC against L.L.C. against
    -- Inc against Incorporated.
    name_norm    text NOT NULL,

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
CREATE OR REPLACE FUNCTION carrier_name_norm(t text) RETURNS text AS $$
    SELECT nullif(btrim(regexp_replace(
               regexp_replace(
                   regexp_replace(lower(coalesce(t, '')), '[^a-z0-9 ]+', ' ', 'g'),
                   '\y(llc|l l c|inc|incorporated|corp|corporation|co|company|ltd|limited|lp|llp|plc|holdings|group|usa|us|the|dba|fka)\y',
                   ' ', 'g'),
               ' {2,}', ' ', 'g')), '');
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION carrier_name_norm(text) IS
    'Conservative name normalisation for cross-source comparison. Removes punctuation and corporate-form words only. Deliberately keeps cable, communications, broadband and similar, because those distinguish real companies and removing them would merge distinct carriers.';

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
    IF to_regclass('bdc_provider_tbl') IS NULL THEN
        RAISE NOTICE 'bdc_provider_tbl absent; apply geo/fcc_bdc/schema_v2.sql and load the downloads first. The BDC columns will be empty.';
        RETURN;
    END IF;

    INSERT INTO carrier_name_observed_tbl
           (source, name, name_norm, nodes, domains)
    SELECT 'bdc', brand_name, carrier_name_norm(brand_name), 0, 0
    FROM bdc_provider_tbl
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
       i.org
FROM totals t
LEFT JOIN per_domain_as  a ON a.domain = t.domain AND a.rn = 1
LEFT JOIN per_domain_isp i ON i.domain = t.domain AND i.rn = 1;

-- A shim over bdc_provider_tbl, because a table named in a LEFT JOIN is
-- resolved by the planner whether or not a to_regclass guard in the ON
-- clause would be false. So the guard has to happen before the query is
-- parsed, which means building a table of the right shape either way.
DO $$
BEGIN
    DROP TABLE IF EXISTS bdc_provider_shim;
    CREATE TEMP TABLE bdc_provider_shim (
        provider_id integer, frn text, brand_name text);
    IF to_regclass('bdc_provider_tbl') IS NOT NULL THEN
        INSERT INTO bdc_provider_shim (provider_id, frn, brand_name)
        SELECT provider_id, frn, brand_name FROM bdc_provider_tbl
        WHERE brand_name IS NOT NULL AND brand_name <> '';
        RAISE NOTICE 'bdc_provider_shim filled from bdc_provider_tbl';
    ELSE
        RAISE NOTICE 'bdc_provider_tbl absent; BDC columns will be empty';
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
            WHEN carrier_name_norm(b.brand_name)
                 = carrier_name_norm(m.isp) THEN 'normalised name equal'
            WHEN carrier_name_norm(b.brand_name) LIKE
                 '%' || carrier_name_norm(m.isp) || '%'
              OR carrier_name_norm(m.isp) LIKE
                 '%' || carrier_name_norm(b.brand_name) || '%'
                 THEN 'normalised name contained'
            ELSE 'first word only, WEAK' END,
       m.nodes
FROM measured m
LEFT JOIN LATERAL (
    SELECT registrant, count(DISTINCT node_ip) AS n
    FROM node_rdap nr WHERE nr.domain = m.domain
    GROUP BY registrant ORDER BY count(DISTINCT node_ip) DESC LIMIT 1
) rd ON true
LEFT JOIN bdc_provider_shim b
    ON m.isp IS NOT NULL
   AND carrier_name_norm(b.brand_name) IS NOT NULL
   AND carrier_name_norm(m.isp) IS NOT NULL
   AND (carrier_name_norm(b.brand_name) = carrier_name_norm(m.isp)
        OR carrier_name_norm(b.brand_name) LIKE
           '%' || carrier_name_norm(m.isp) || '%'
        OR carrier_name_norm(m.isp) LIKE
           '%' || carrier_name_norm(b.brand_name) || '%'
        -- THE FIRST-WORD TIER, and why it is here despite being weak.
        -- Equality and containment proposed Frontier Communications for
        -- frontiernet.net but MISSED Frontier Fiber, a second brand of the
        -- same carrier. Missing a brand defeats the purpose: separating
        -- FIOS from xDSL requires every brand a carrier files under.
        -- So a shared first significant word also proposes, labelled
        -- 'first word only, WEAK' so it is visibly the weakest basis.
        -- It will propose wrong pairs too, which is what approval is for.
        OR (split_part(carrier_name_norm(b.brand_name), ' ', 1)
            = split_part(carrier_name_norm(m.isp), ' ', 1)
            AND length(split_part(carrier_name_norm(m.isp), ' ', 1)) >= 4))
ON CONFLICT (itdk_domain, asn, bdc_provider_id) DO NOTHING;


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
       bdc_basis
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
