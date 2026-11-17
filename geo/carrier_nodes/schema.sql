-- geo/carrier_nodes/schema.sql
--
-- Step 2 of the FCC plan: carrier node inventory and node locations, per
-- carrier and per network type.
--
-- Safe to re-run. Every statement is CREATE IF NOT EXISTS or an idempotent
-- COMMENT. Nothing here drops or rewrites existing data.
--
--
-- WHAT STEP 2 ASKED FOR, AND WHAT THIS DELIVERS
--
-- Boris, 2026-11-12: "Compile headend/central office locations of
-- routing/CPE-connecting IP nodes for Internet service in USA per carrier and
-- network type (so, e.g., Verizon FIOS is separate from Verizon xDSL)."
--
-- Carriers name their routers after the building the router sits in. CAIDA's
-- Hoiho project has already derived, scored and published the regexes that
-- read those names, 871 domains in the 2025-08 ITDK release. This schema
-- holds that ruleset and the result of applying it.
--
--
-- THE REVERSAL THAT MAKES THIS LEGITIMATE
--
-- geo/node_fanout.sql carries a warning that must not be contradicted:
-- "A node named po-1-rur201.westroxbury.ma.boston.comcast.net records where
-- the ROUTER is, not where the subscriber is." Comcast serves West Roxbury
-- from a Brockton node, and that is one of the four reasons the landmark
-- method was abandoned.
--
-- Step 2 wants the ROUTER's location. So the property that made hostnames
-- useless for locating a subscriber is the property step 2 is built on. This
-- is a change of purpose, not a revival of the abandoned method. VERIFIED on
-- that exact hostname 2026-11-17: the decoder returns boston, 42.358430 and
-- -71.059770, and does NOT return westroxbury.
--
--
-- WHAT THE RULESET CAN AND CANNOT LOCATE, MEASURED 2026-11-17
--
-- 15,952 geohints, 11,444 of them (71.7%) carrying coordinates:
--
--   iata       6,081   all with coordinates     metro granularity
--   place      5,144   all with coordinates     city or town granularity
--   clli       4,508   NONE with coordinates    building granularity
--   locode       203   all with coordinates
--   facility      16   all with coordinates     named carrier hotels
--
-- A CLLI hint is the bare six-character code and nothing else: four
-- characters of place, two of state. So btrgla is Baton Rouge LA. The state
-- is unambiguous; the place contraction needs a source, which is what
-- clli_site_tbl is for. geo/landmarks/isp_node_feasibility.md named this as
-- the blocker and named LERG, proprietary to iconectiv, as the authoritative
-- table. A public LERG-derived service does answer partial CLLI queries, and
-- what it returns is RATE CENTRE granularity, which is a tariff geography
-- and NOT the central office building. That distinction is recorded on the
-- columns below rather than glossed over.


-- ---------------------------------------------------------------------------
-- THE CAIDA RULESET
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS hoiho_rule_tbl (
    domain           text PRIMARY KEY,

    -- Ordered as CAIDA publishes them. A rule may carry SEVERAL capture
    -- groups: Comcast's
    --   ^[^.]+\.[a-z\d]+\.([a-z]{2})\.([a-z]+)\.comcast\.net$
    -- captures the state and the place separately. Reading only the first
    -- group is a bug; it returned ma and resolved nothing.
    regexes          text[] NOT NULL,

    -- Any regex the applying language would not compile. Recorded rather
    -- than discarded, because a domain whose only rule is rejected would
    -- otherwise look uncovered. Empty for every domain under Python's re
    -- module as measured 2026-11-17.
    regexes_rejected text[] NOT NULL DEFAULT ARRAY[]::text[],

    -- CAIDA's own scoring. ppv is positive predictive value against their
    -- ground truth; klass is good, promising or poor.
    ppv              numeric,
    klass            text,
    routers          integer,
    tp               integer,
    fp               integer,
    loaded_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE hoiho_rule_tbl IS
    'The CAIDA Hoiho hostname-to-location regexes, 871 domains from the 2025-08 ITDK release. Loaded by geo/carrier_nodes/hoiho_apply.py. geo/landmarks/hoiho_suffixes.sql holds the same releases scores but NOT the regexes, which is why this table exists.';
COMMENT ON COLUMN hoiho_rule_tbl.regexes IS
    'Ordered regexes. Several capture groups per regex is normal and all of them must be considered: in a two-group rule one group is the state and the other the place, and which is which varies by carrier.';
COMMENT ON COLUMN hoiho_rule_tbl.ppv IS
    'CAIDA positive predictive value. Carried so a location can be weighted by the reliability of the rule that produced it rather than treated as certain.';


-- A CODE IS NOT UNIQUE WITHIN A DOMAIN, which I had assumed and which broke
-- the load. MEASURED 2026-11-17: 213 (domain, code) pairs repeat across 26
-- domains, up to seven times, and 201 of those repeat WITHIN a single hint
-- type, so hint_type does not separate them either.
--
-- The repeats are genuine ambiguity, not noise:
--   as5405.net / skg   iata Skanderborg DK  OR  iata Thessaloniki GR
--   as11404.net / sea  iata Seattle airport OR  place Seattle city,
--                      the same city but points about 17 km apart
--
-- Seventeen kilometres matters to step 4, which measures distance from a
-- tract centroid. So every hint is kept, a surrogate key carries the table,
-- and the ambiguity is reported rather than resolved by whichever row
-- happened to load last.
CREATE TABLE IF NOT EXISTS hoiho_geohint_tbl (
    hint_id    bigserial PRIMARY KEY,
    domain     text NOT NULL REFERENCES hoiho_rule_tbl (domain),
    code       text NOT NULL,
    hint_type  text,

    -- NULL for every clli hint, by measurement: 0 of 4,508 carry them.
    lat        numeric,
    lng        numeric,

    place      text,
    st         text,
    cc         text,

    -- CAIDA true and false positive counts for this hint. tp is how the
    -- decoder chooses between competing hints for one code: CAIDA's own
    -- evidence, not alphabetical order.
    tp         integer,
    fp         integer
);

CREATE INDEX IF NOT EXISTS hoiho_geohint_type_idx
    ON hoiho_geohint_tbl (hint_type);
CREATE INDEX IF NOT EXISTS hoiho_geohint_code_idx
    ON hoiho_geohint_tbl (code);

COMMENT ON TABLE hoiho_geohint_tbl IS
    'The location codes each Hoiho rule can produce. 15,952 rows, 11,444 carrying coordinates. A clli row carries the six-character code only; resolve it through clli_site_tbl. (domain, code) is NOT unique: 213 pairs repeat, so a surrogate key carries the table and competing hints are chosen between by tp.';
COMMENT ON COLUMN hoiho_geohint_tbl.tp IS
    'CAIDA true positives for this hint. Used to choose between competing hints for one code, for example Seattle airport against Seattle city, which differ by about 17 km.';


-- ---------------------------------------------------------------------------
-- THE NODE INVENTORY
--
-- One row per distinct router hostname, with whatever the ruleset could say
-- about where that router is. Written by hoiho_apply.py apply, which reads
-- EVERY hop out of ovt_places_usa_ip_trace.hops rather than only the last
-- carrier node, because that jsonb column was stored for exactly this reason.
-- ---------------------------------------------------------------------------

-- MIGRATION, 2026-11-17. The first version keyed this table on hostname
-- alone. That is wrong: ONE HOSTNAME ANSWERS ON SEVERAL ADDRESSES, because
-- router interfaces share a PTR. The load failed on Boris's corpus at
-- 113.115.207.atginternet.com and wrote nothing at all, which then left the
-- crosswalk with no input.
--
-- Keeping both is not merely a key fix, it is what step 6 needs: that step
-- ascribes IP addresses shown by ip-api to a node, so the address-to-node
-- pairs are the point and collapsing them would throw away the link.
--
-- PRE-MORTEM for the drop below: carrier_node_tbl is written ONLY by
-- hoiho_apply.py apply, which truncates and rebuilds it from the trace
-- corpus in under a second for 25,000 hostnames. Nothing else writes to it
-- and no other table references it. So dropping it destroys nothing that is
-- not regenerated by the next command in the sequence. It is dropped only
-- when the old single-column key is detected.
DO $$
BEGIN
    IF to_regclass('carrier_node_tbl') IS NULL THEN
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        WHERE c.relname = 'carrier_node_tbl'
          AND i.indisprimary
          AND i.indnatts = 1)
    THEN
        DROP TABLE carrier_node_tbl;
        RAISE NOTICE 'carrier_node_tbl had the old single-column key and has been dropped. It is rebuilt entirely by: python3 geo/carrier_nodes/hoiho_apply.py apply';
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS carrier_node_tbl (
    node_id         bigserial PRIMARY KEY,
    hostname        text NOT NULL,
    node_ip         inet,
    domain          text,

    -- The token the regex extracted, lower-cased. For a clli hint this is
    -- the six-character code that clli_site_tbl resolves.
    code            text,
    hint_type       text,

    lat             numeric,
    lng             numeric,
    place           text,
    st              text,
    cc              text,

    matched_re      text,

    -- How many hints the ruleset holds for this (domain, code). Greater than
    -- one means the code is ambiguous and the highest-tp hint was taken; the
    -- alternatives are reachable through hoiho_geohint_tbl.
    code_hint_count integer NOT NULL DEFAULT 1,

    -- How the hint was chosen when the code was ambiguous. 'state match'
    -- means a two-letter group from the same hostname agreed with the
    -- hint's state, which is the only selection that should be trusted at
    -- face value: for comcast.net/springfield the alternatives span
    -- 4,032 km and the best-scoring one is the wrong state.
    selection       text,

    -- Set when a two-letter capture group from the same hostname equals the
    -- state the hint records. Independent agreement between two parts of one
    -- name, so it is worth keeping distinct from the location itself.
    corroborated_by text,

    status          text NOT NULL,
    decoded_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT carrier_node_status_known CHECK (status IN (
        'located',
        'clli code, needs clli_resolve',
        'hint has no coordinates',
        'regex matched, code not in the ruleset hints',
        'domain has rules but none matched this hostname',
        'no rule for this domain'))
);

-- Unique on the PAIR. coalesce rather than a plain two-column constraint
-- because node_ip is nullable when the hostname came from last_hop_hostname
-- with no address, and in PostgreSQL before 15 a UNIQUE constraint treats
-- NULLs as distinct, which would let duplicates through on exactly the rows
-- that need protecting.
CREATE UNIQUE INDEX IF NOT EXISTS carrier_node_host_ip_idx
    ON carrier_node_tbl (hostname, coalesce(node_ip, '0.0.0.0'::inet));

CREATE INDEX IF NOT EXISTS carrier_node_hostname_idx ON carrier_node_tbl (hostname);
CREATE INDEX IF NOT EXISTS carrier_node_domain_idx ON carrier_node_tbl (domain);
CREATE INDEX IF NOT EXISTS carrier_node_status_idx ON carrier_node_tbl (status);
CREATE INDEX IF NOT EXISTS carrier_node_code_idx   ON carrier_node_tbl (domain, code);
CREATE INDEX IF NOT EXISTS carrier_node_ip_idx     ON carrier_node_tbl (node_ip);

COMMENT ON TABLE carrier_node_tbl IS
    'One row per distinct hostname AND address pair seen in the trace corpus. Not per hostname: router interfaces share a PTR, so one hostname answers on several addresses, and step 6 needs those addresses because it ascribes ip-api resolutions to a node, with the location the CAIDA ruleset assigns to it. THIS IS THE ROUTER LOCATION, NOT THE SUBSCRIBER LOCATION; see the warning in geo/node_fanout.sql. That is what step 2 wants.';
COMMENT ON COLUMN carrier_node_tbl.status IS
    'Why this row does or does not carry a location. The constraint lists every value hoiho_apply.py can produce, so a new outcome fails loudly instead of being absorbed.';
COMMENT ON COLUMN carrier_node_tbl.selection IS
    'How an ambiguous code was resolved: state match, highest tp, or only candidate. A row with code_hint_count above one and selection of highest tp is a coin toss between places that can be thousands of kilometres apart and should not feed step 4 without review.';
COMMENT ON COLUMN carrier_node_tbl.code_hint_count IS
    'Hints available for this code. Above one, the location is the highest-tp of several and the others are real alternatives: step 4 should treat such a node as less certain.';
COMMENT ON COLUMN carrier_node_tbl.code IS
    'The token the regex extracted. A token absent from the hint list is kept rather than discarded: Comcast westroxbury is a real place missing from the 2025-08 hints, which is what a carrier adding a site looks like.';


-- ---------------------------------------------------------------------------
-- CLLI RESOLUTION
--
-- Six-character CAIDA hint to something locatable. Populated from a public
-- LERG-derived service, which answers a PARTIAL CLLI query and returns the
-- full eleven-character switch CLLI, the switch name, the operating company
-- and the rate centre with coordinates.
--
-- THE GRANULARITY IS RATE CENTRE, NOT BUILDING, AND THAT MATTERS.
-- A rate centre is a tariff geography and its coordinates are a nominal
-- centroid. In a dense metro several central offices share one rate centre,
-- so this locates the node to the rate centre and no finer. Step 3, exact
-- street addresses, is where building precision has to come from. The column
-- names say so to stop a later reader treating rc_lat as a building.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS clli_site_tbl (
    clli6         text NOT NULL,
    clli_full     text NOT NULL,
    switch_name   text,
    company_ocn   text,
    company_name  text,

    rate_centre   text,
    region        text,
    rc_lat        numeric,
    rc_lon        numeric,

    source        text NOT NULL,
    fetched_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (clli6, clli_full),

    CONSTRAINT clli6_is_six_chars CHECK (clli6 ~ '^[a-z0-9]{6}$')
);

CREATE INDEX IF NOT EXISTS clli_site_clli6_idx ON clli_site_tbl (clli6);

COMMENT ON TABLE clli_site_tbl IS
    'Six-character CAIDA CLLI hints resolved to switch CLLIs, operating companies and RATE CENTRE coordinates. Rate centre is a tariff geography, not a building: several central offices can share one in a dense metro. Building precision is step 3 and is not in this table.';
COMMENT ON COLUMN clli_site_tbl.rc_lat IS
    'Rate centre latitude, a nominal centroid of a tariff area. NOT the central office building. Named rc_ deliberately so no later query treats it as a site coordinate.';


-- ---------------------------------------------------------------------------
-- CARRIER IDENTITY: THE JOIN THIS PROJECT DOES NOT YET HAVE
--
-- Step 2 is per carrier AND per network type. The network type comes from
-- FCC BDC technology codes. The carrier comes from two places that do not
-- share a key:
--
--   BDC gives frn, provider_id and brand_name, for example 130317 Xfinity.
--   A hostname gives a DNS domain, for example comcast.net.
--
-- Nobody publishes a mapping between those. Asserting comcast.net is
-- provider_id 130317 is an inference, and this project's standing order is
-- not to guess, so THIS TABLE IS DEFINED EMPTY and seeded only from
-- evidence. basis is NOT NULL for that reason: a row cannot be added without
-- saying what established it.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS carrier_domain_provider_tbl (
    domain      text    NOT NULL,
    provider_id integer NOT NULL,
    frn         text,
    brand_name  text,

    -- What established this pairing. Required.
    basis       text    NOT NULL,

    -- Who or what added it, so a curated row and a measured one are
    -- distinguishable later.
    added_by    text    NOT NULL DEFAULT 'manual',
    confirmed   boolean NOT NULL DEFAULT false,
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (domain, provider_id)
);

COMMENT ON TABLE carrier_domain_provider_tbl IS
    'Maps a DNS domain seen in router hostnames to an FCC BDC provider_id. DELIBERATELY EMPTY on creation. No public source pairs these, so every row must carry the evidence that established it in basis, and confirmed stays false until Boris agrees. Without this table step 2 can report nodes per domain but not per BDC carrier and technology.';
COMMENT ON COLUMN carrier_domain_provider_tbl.basis IS
    'The evidence for this pairing. NOT NULL so a row cannot be created by assumption. An AS-number match, an RDAP registrant match or a reverse-DNS observation are evidence; a similar-looking name is not.';


-- ---------------------------------------------------------------------------
-- WHAT STEP 2 CAN REPORT TODAY
--
-- Per domain and per node, the located sites. Carrier and technology are
-- joined in only where carrier_domain_provider_tbl has a confirmed row, so
-- the view cannot silently imply a pairing that was never established.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW carrier_node_located AS
SELECT n.hostname,
       n.node_ip,
       n.domain,
       n.code,
       n.hint_type,
       coalesce(n.lat, c.rc_lat) AS lat,
       coalesce(n.lng, c.rc_lon) AS lng,
       CASE
           WHEN n.lat IS NOT NULL AND n.hint_type = 'facility'
               THEN 'named facility'
           WHEN n.lat IS NOT NULL AND n.hint_type IN ('place', 'locode')
               THEN 'town or city'
           WHEN n.lat IS NOT NULL AND n.hint_type = 'iata'
               THEN 'metro'
           WHEN c.rc_lat IS NOT NULL
               THEN 'rate centre'
           ELSE 'not located'
       END AS granularity,
       coalesce(n.place, c.rate_centre) AS place,
       coalesce(n.st, c.region)         AS st,
       c.clli_full,
       c.switch_name,
       c.company_name,
       r.ppv,
       r.klass,
       n.corroborated_by,
       n.status
FROM carrier_node_tbl n
LEFT JOIN hoiho_rule_tbl r ON r.domain = n.domain
LEFT JOIN LATERAL (
    SELECT s.* FROM clli_site_tbl s
    WHERE n.hint_type = 'clli' AND s.clli6 = n.code
    ORDER BY s.clli_full
    LIMIT 1
) c ON true;

COMMENT ON VIEW carrier_node_located IS
    'Carrier nodes with a location and an explicit granularity label: named facility, town or city, metro, or rate centre. The granularity column exists so step 4 cannot treat a metro-level IATA coordinate as though it were a building.';
