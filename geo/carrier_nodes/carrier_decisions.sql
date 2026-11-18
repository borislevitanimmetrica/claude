-- geo/carrier_nodes/carrier_decisions.sql
--
-- Boris's rulings on the carrier crosswalk, recorded so they survive a
-- re-run and so every later query can see WHY a carrier is named as it is.
--
-- Safe to re-run. Creates tables and a view; writes nothing by itself.
--
--
-- WHERE THE DECISION TYPES COME FROM
--
-- Boris reviewed the crosswalk list on 2026-11-17 and annotated it in three
-- groups. The annotations arrived as an image, truncated at the right. He
-- then clarified two things that changed how it reads:
--
--   "bdc_name is the rightmost column"
--   "For the first group of domains, use the NAME IN BDC of the operator of
--    the shown ASN."
--
-- So the sheet is two columns, itdk_domain and bdc_name, and for the first
-- group the bdc_name cell holds an ASN RATHER THAN a name, because no BDC
-- name was matched. The instruction is to resolve that ASN to its operating
-- company and use THAT company's name as it appears in BDC. The ASN is a
-- pointer, not the answer, which is why the decision below is
-- use_bdc_of_asn and not the use_as_name I first wrote.
--
-- The three groups:
--
--   "For these domains, use the name shown in BDC for the corresponding
--    ASN:"                                          -> use_bdc_of_asn
--       bright.net AS7106, cniteam.com AS7106, earthlinkbusiness.net
--       AS397866. I had read the last as AS39780 from the image; it is
--       AS397866.
--
--   "These domains are associated with various Windstream subsidiaries:"
--                                                   -> use_bdc_name
--       uniti.net, netaxs.com, mcleodusa.net, cavtel.net and
--       broadviewnet.net, EACH against FIFTEEN named Windstream entities:
--       Accucomm Telecom, Alabama, Arkansas, Communications, Florida,
--       Georgia Communications, Georgia, Georgia Telephone, Iowa
--       Communications, Kentucky East, Kentucky West, Lexcom
--       Communications, Missouri, Montezuma and Standard.
--
--       THIS IS ONE DOMAIN TO MANY PROVIDERS. Windstream files in BDC under
--       separate state-level legal entities, so a node on any of those five
--       domains can serve any of the fifteen. My first reading treated this
--       as an alias onto a single parent carrier, which would have
--       discarded fourteen fifteenths of the mapping.
--
--   "These are not ISPs and should be deleted as carriers:"
--                                                   -> not_an_isp
--       musiciansgig.net, ppe.com, socialaw.com, daytonoffice.com,
--       hobbsnm.org, avglens.com, mepeng.net, frisolilaw.com
--
--       EIGHT domains. From the image I read seven and got one name wrong:
--       avglens.com as avgens.com, and hobbsnm.org I missed entirely.
--
-- lrmutual.com against Mutual Telephone Company sits above the first
-- instruction. Its cell holds a name rather than an ASN, so it is recorded
-- as a direct use_bdc_name pairing.
--
--
-- HOW AN ASN BECOMES A BDC NAME, AND WHY IT IS NOT AUTOMATIC
--
-- BDC filings contain no AS number, so there is no join. What exists is
-- measured: ip2city_dbiplite_probe_tbl carries an "as" string per range of
-- the form 'AS7922 Comcast Cable Communications, LLC', so an ASN resolves to
-- its operator NAME from data the project already holds. That operator name
-- is then matched against BDC brand names by the same tiered comparison the
-- crosswalk uses, and the candidates are offered for approval.
--
-- So use_bdc_of_asn records Boris's instruction and the ASN; section 4 below
-- resolves it as far as the evidence allows and names what is still missing.
-- It does not silently pick one.
--
--
-- WHAT THE WINDSTREAM GROUPING DOES AND DOES NOT IMPLY
--
--   CERTAIN: a node on any of those five domains is a candidate site for a
--   tract served by any of the fifteen entities, so steps 4 to 7 must see
--   all fifteen pairings.
--
--   NOT ESTABLISHED: whether windstream.net's hostname rules decode those
--   five domains' hostnames. A Hoiho regex is anchored on its own domain,
--   so windstream.net rules cannot match a uniti.net hostname as written.
--   What is worth MEASURING is whether the five use the same CLLI-style
--   token layout as windstream.net, in which case a rule can be derived
--   from evidence rather than invented. This matters because uniti.net
--   currently decodes NOTHING: 143 hostnames, zero sites, absent from the
--   CAIDA ruleset, while windstream.net has 281 CLLI hints at ppv 0.997.


\pset pager off
\set ON_ERROR_STOP on
\timing on

-- THIS FILE DEPENDS ON carrier_crosswalk.sql HAVING RUN, because the
-- carrier_name_norm function and carrier_crosswalk_tbl are both defined
-- there. Checked rather than assumed: running this first produced
-- "function carrier_name_norm(text) does not exist" at line 210, which is
-- an unhelpful place to discover a missing prerequisite.
DO $$
DECLARE missing text[] := ARRAY[]::text[];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'carrier_name_norm')
    THEN
        missing := missing || 'function carrier_name_norm'::text;
    END IF;
    IF to_regclass('carrier_crosswalk_tbl') IS NULL THEN
        missing := missing || 'table carrier_crosswalk_tbl'::text;
    END IF;
    IF to_regclass('bdc_carrier_tbl') IS NULL THEN
        missing := missing || 'table bdc_carrier_tbl'::text;
    END IF;
    IF array_length(missing, 1) > 0 THEN
        RAISE EXCEPTION
            'Missing prerequisite(s): %. Nothing has been changed. Run these first, in order: psql -f geo/carrier_nodes/schema.sql, psql -f geo/fcc_bdc/schema_v2.sql, psql -f geo/carrier_nodes/carrier_crosswalk.sql', missing;
    END IF;
    RAISE NOTICE 'prerequisites present';
END
$$;


-- ---------------------------------------------------------------------------
-- THE DECISIONS
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS carrier_decision_tbl (
    itdk_domain text NOT NULL,

    decision    text NOT NULL CHECK (decision IN (
        -- The carrier's BDC name is that of the operator of a given ASN.
        -- value holds the ASN. Boris 2026-11-17: "use the NAME IN BDC of
        -- the operator of the shown ASN". The ASN is the lookup key, not
        -- the answer.
        'use_bdc_of_asn',
        -- This domain maps to a named BDC provider. value holds the BDC
        -- name verbatim. A domain may carry MANY of these rows and that is
        -- the normal case, not an error: Boris 2026-11-17 mapped each of
        -- uniti.net, netaxs.com, mcleodusa.net, cavtel.net and
        -- broadviewnet.net onto FIFTEEN Windstream subsidiaries. A single
        -- alias to one parent label cannot express that, which is why the
        -- single-parent alias I first wrote was replaced by this.
        'use_bdc_name',
        -- Not an ISP. Excluded from the crosswalk and from step 2 entirely.
        'not_an_isp',
        -- An explicit BDC pairing Boris chose. value holds the provider_id.
        'use_bdc_provider',
        -- Explicitly rejected pairing, so it is not re-proposed each run.
        'reject_bdc_provider')),

    -- Meaning depends on decision: a BDC provider name for use_bdc_name,
    -- an ASN for use_bdc_of_asn, a provider_id for the two BDC decisions,
    -- and NULL for not_an_isp.
    value       text,

    -- Boris's own words where there were any. Kept verbatim because a
    -- paraphrase of an instruction is not the instruction.
    note        text,

    decided_by  text NOT NULL DEFAULT 'boris',
    decided_at  timestamptz NOT NULL DEFAULT now(),

    decision_id bigserial PRIMARY KEY
);

-- A surrogate key plus a unique INDEX, not a composite primary key.
-- PostgreSQL rejects an expression inside PRIMARY KEY, so
--   PRIMARY KEY (itdk_domain, decision, coalesce(value, ''))
-- is a syntax error, which is how this file first failed. coalesce is
-- needed because value is NULL for not_an_isp and a plain unique constraint
-- treats NULLs as distinct before PostgreSQL 15, which would let the same
-- ruling be stored twice.
CREATE UNIQUE INDEX IF NOT EXISTS carrier_decision_unique_idx
    ON carrier_decision_tbl (itdk_domain, decision, coalesce(value, ''));

CREATE INDEX IF NOT EXISTS carrier_decision_domain_idx
    ON carrier_decision_tbl (itdk_domain);
CREATE INDEX IF NOT EXISTS carrier_decision_kind_idx
    ON carrier_decision_tbl (decision);

COMMENT ON TABLE carrier_decision_tbl IS
    'Boris rulings on carrier identity, one row per domain and decision. Exists so a ruling survives a re-run of the crosswalk, which regenerates all unapproved proposals. Every row carries his wording in note where there was any.';
COMMENT ON COLUMN carrier_decision_tbl.value IS
    'Meaning depends on decision: a BDC provider NAME for use_bdc_name, an AS NUMBER for use_bdc_of_asn, a provider_id for the BDC decisions, NULL for not_an_isp.';


-- ---------------------------------------------------------------------------
-- ASN TO BDC OPERATOR NAME
--
-- For the use_bdc_of_asn decisions. Two steps, the first measured and the
-- second proposed:
--
--   1. The ASN's operator name, from the ip-api "as" strings the project
--      already holds. 'AS7922 Comcast Cable Communications, LLC' yields
--      7922 and the name after it. This is observation.
--
--   2. That name matched against BDC brand names. This is a name
--      comparison with no key behind it, exactly as in the crosswalk, so
--      the result is a candidate and the count of candidates is reported.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ASN TO BDC CARRIER NAME: the tables
--
-- Declared here and FILLED by geo/carrier_nodes/resolve_asn.sql, which
-- TRUNCATEs and re-inserts rather than dropping and recreating.
--
-- That distinction is the fix for a bug I have now made three times in one
-- session: DROP TABLE ... CASCADE silently removes dependent views.
-- carrier_resolved depends on asn_bdc_name_tbl, so dropping the table took
-- the view with it and the next query failed with "relation
-- carrier_resolved does not exist". TRUNCATE touches no dependency.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS asn_operator_tbl (
    asn              integer PRIMARY KEY,
    as_operator      text,
    ranges           bigint,
    as_operator_norm text
);

CREATE INDEX IF NOT EXISTS asn_operator_norm_idx
    ON asn_operator_tbl (as_operator_norm);

COMMENT ON TABLE asn_operator_tbl IS
    'AS number to operator name, read from the ip-api "as" strings already held per range, for the ASNs named in a use_bdc_of_asn decision ONLY. A table rather than a view because as an unrestricted view it cost 195 seconds per reference at 2,097,870 probe rows. Filled by geo/carrier_nodes/resolve_asn.sql.';

CREATE TABLE IF NOT EXISTS asn_bdc_name_tbl (
    asn              integer NOT NULL,
    as_operator      text,
    ranges           bigint,
    bdc_provider_id  integer,
    bdc_brand_name   text,
    match_basis      text
);

CREATE INDEX IF NOT EXISTS asn_bdc_name_asn_idx
    ON asn_bdc_name_tbl (asn);

COMMENT ON TABLE asn_bdc_name_tbl IS
    'For each ASN named in a use_bdc_of_asn decision, the operator observed in ip-api and the BDC brand names whose normalised form equals or contains it. The BDC half is a NAME COMPARISON with no key behind it, so several rows for one ASN means several candidates and none is chosen here.';

\echo
\echo ---- Filling them for the ASNs under decision
\echo
\echo On the FIRST run of this file carrier_decision_tbl is empty, so these
\echo come out empty. load_decisions.py re-runs the same file after loading,
\echo which is when they fill.
\echo

\i geo/carrier_nodes/resolve_asn.sql




-- ---------------------------------------------------------------------------
-- THE RESOLVED CARRIER
--
-- One row per ITDK domain after the decisions are applied, which is what
-- steps 4 to 7 should join to rather than to the raw crosswalk.
-- ---------------------------------------------------------------------------

-- ONE ROW PER DOMAIN AND BDC PROVIDER, because that is the shape of the
-- decisions. A use_bdc_name domain with fifteen Windstream entities yields
-- fifteen rows, and steps 4 to 7 need all fifteen: a tract served by any of
-- those entities should see that domain's nodes as candidate sites.
CREATE OR REPLACE VIEW carrier_resolved AS
WITH dropped AS (
    SELECT DISTINCT itdk_domain FROM carrier_decision_tbl
    WHERE decision = 'not_an_isp'
),
-- Names Boris gave, resolved against BDC. An unresolved name is KEPT with a
-- null provider_id and said so, because the BDC load may simply not have
-- reached that provider yet and silently dropping it would look like a
-- decision that was never made.
named AS (
    SELECT d.itdk_domain,
           d.value                      AS bdc_name_given,
           b.provider_id,
           b.frn,
           b.brand_name,
           CASE WHEN b.provider_id IS NULL
                THEN 'named by Boris, NOT FOUND in bdc_carrier_tbl'
                ELSE 'named by Boris, matched in BDC' END AS basis
    FROM carrier_decision_tbl d
    LEFT JOIN bdc_carrier_tbl b ON b.brand_name = d.value
    WHERE d.decision = 'use_bdc_name'
),
-- Domains whose BDC name comes from the operator of a stated ASN.
by_asn AS (
    SELECT d.itdk_domain,
           a.as_operator                AS bdc_name_given,
           a.bdc_provider_id            AS provider_id,
           NULL::text                   AS frn,
           a.bdc_brand_name             AS brand_name,
           CASE WHEN a.bdc_provider_id IS NULL
                THEN 'operator of AS' || d.value
                     || ', NO BDC name matched it'
                ELSE 'BDC name of the operator of AS' || d.value END AS basis
    FROM carrier_decision_tbl d
    LEFT JOIN asn_bdc_name_tbl a ON a.asn = nullif(d.value, '')::integer
    WHERE d.decision = 'use_bdc_of_asn'
),
decided AS (
    SELECT * FROM named
    UNION ALL
    SELECT * FROM by_asn
)
SELECT c.itdk_domain,
       coalesce(dd.brand_name, dd.bdc_name_given,
                c.bdc_brand_name, c.ipapi_isp, c.itdk_domain) AS carrier_label,
       coalesce(dd.basis,
                CASE WHEN c.bdc_provider_id IS NOT NULL
                     THEN 'proposed pairing, ' || coalesce(c.bdc_basis, '')
                     WHEN c.ipapi_isp IS NOT NULL
                     THEN 'ip-api isp, measured, no BDC pairing'
                     ELSE 'DNS domain, nothing better available' END)
                                                              AS label_basis,
       c.asn,
       c.ipapi_isp,
       c.rdap_name,
       coalesce(dd.provider_id, c.bdc_provider_id)            AS bdc_provider_id,
       dd.bdc_name_given,
       c.nodes,
       dd.itdk_domain IS NOT NULL                             AS by_decision,
       c.approved
FROM carrier_crosswalk_tbl c
LEFT JOIN decided dd ON dd.itdk_domain = c.itdk_domain
WHERE c.itdk_domain NOT IN (SELECT itdk_domain FROM dropped)

UNION ALL

-- Decisions for domains that are not in the crosswalk at all. Kept so a
-- ruling is never invisible just because the domain has no measured node.
SELECT dd.itdk_domain,
       coalesce(dd.brand_name, dd.bdc_name_given),
       dd.basis || ', domain not present in the crosswalk',
       NULL::integer, NULL::text, NULL::text,
       dd.provider_id, dd.bdc_name_given, 0, true, false
FROM decided dd
WHERE dd.itdk_domain NOT IN (SELECT itdk_domain FROM carrier_crosswalk_tbl)
  AND dd.itdk_domain NOT IN (SELECT itdk_domain FROM dropped);

COMMENT ON VIEW carrier_resolved IS
    'The crosswalk after Boris decisions are applied. ONE ROW PER DOMAIN AND BDC PROVIDER: a domain mapped to fifteen Windstream subsidiaries yields fifteen rows, because a tract served by any of them should see that domains nodes. Domains ruled not an ISP are absent. label_basis says which rule produced the name, including when a name Boris gave was not found in bdc_carrier_tbl. Steps 4 to 7 should join to this, not to carrier_crosswalk_tbl.';


\echo
\echo ===========================================================
\echo What has been decided so far
\echo ===========================================================
\echo

SELECT decision, count(*) AS domains,
       left(string_agg(itdk_domain, ', ' ORDER BY itdk_domain), 70) AS examples
FROM carrier_decision_tbl
GROUP BY decision
ORDER BY decision;

\echo
\echo Domains in the crosswalk with NO decision recorded, by node evidence.
\echo These are what still needs ruling on.
\echo

SELECT c.itdk_domain,
       c.asn,
       left(c.ipapi_isp, 34)      AS ipapi_isp,
       left(c.rdap_name, 30)      AS rdap,
       left(c.bdc_brand_name, 22) AS bdc_brand,
       c.nodes
FROM carrier_crosswalk_tbl c
WHERE NOT EXISTS (SELECT 1 FROM carrier_decision_tbl d
                  WHERE d.itdk_domain = c.itdk_domain)
ORDER BY c.nodes DESC, c.itdk_domain
LIMIT 60;

\echo
\echo ===========================================================
\echo use_bdc_of_asn: resolving each ASN to a BDC operator name
\echo ===========================================================
\echo
\echo Step one, the operator of the ASN, is MEASURED from the ip-api
\echo strings already held. Step two, that operator name against a BDC
\echo brand, is a name comparison and may yield none or several.
\echo

SELECT d.itdk_domain,
       d.value                       AS asn_given,
       left(a.as_operator, 36)       AS as_operator_observed,
       a.ranges                      AS ranges_supporting,
       a.bdc_provider_id,
       left(a.bdc_brand_name, 26)    AS bdc_brand_candidate,
       a.match_basis
FROM carrier_decision_tbl d
LEFT JOIN asn_bdc_name_tbl a ON a.asn = nullif(d.value, '')::integer
WHERE d.decision = 'use_bdc_of_asn'
ORDER BY d.itdk_domain, a.bdc_brand_name;

\echo
\echo Any use_bdc_of_asn decision with NO row above, or with several rows,
\echo needs attention: none means that ASN does not appear in the probe
\echo data or its operator name matches no BDC brand; several means the
\echo choice has not been made.
\echo

SELECT d.itdk_domain, d.value AS asn_given,
       count(a.bdc_provider_id) AS bdc_candidates,
       CASE WHEN count(a.bdc_provider_id) = 0
                 AND max(a.as_operator) IS NULL
                 THEN 'ASN not found in the probe data'
            WHEN count(a.bdc_provider_id) = 0
                 THEN 'operator known, no BDC brand matched its name'
            WHEN count(a.bdc_provider_id) = 1 THEN 'resolved'
            ELSE 'several candidates, needs a choice'
       END AS state
FROM carrier_decision_tbl d
LEFT JOIN asn_bdc_name_tbl a ON a.asn = nullif(d.value, '')::integer
WHERE d.decision = 'use_bdc_of_asn'
GROUP BY d.itdk_domain, d.value
ORDER BY d.itdk_domain;

\echo
\echo Effect of the decisions on the carrier count.
\echo

SELECT (SELECT count(DISTINCT itdk_domain) FROM carrier_crosswalk_tbl)
           AS domains_in_crosswalk,
       (SELECT count(*) FROM carrier_decision_tbl
        WHERE decision = 'not_an_isp')             AS ruled_not_an_isp,
       (SELECT count(*) FROM carrier_decision_tbl
        WHERE decision = 'use_bdc_name')           AS named_bdc_pairings,
       (SELECT count(DISTINCT carrier_label) FROM carrier_resolved)
           AS distinct_carriers_after_decisions;
