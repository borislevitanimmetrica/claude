-- carrier_name_approval.sql - the carrier names from every source, side by
-- side, one row per ip-api name against each candidate BDC brand, for
-- approval. No ranking, no filtering, no threshold.
--
-- WHAT BORIS ASKED FOR, AND WHEN
--
-- 2026-11-17: "If it is a list of carriers, it should relate carriers by
-- name, and names differ in ITDK, Fabric, ip-api.com and RDAP (in case we
-- need it). Obtain the names from each source and submit a list with fields
-- per source for my approval."
--
-- 2026-11-19: "I want approval of all matching tables."
--
-- 2026-11-20: "I have not received a table of carrier name matches between
-- ip-api.com and BDC Fabric for approval."
--
-- He is right and it is the third time. I answered the first two with
-- geographic candidate generators, scoring harnesses and precision figures,
-- none of which he asked for and none of which can settle a carrier's
-- identity, because identity is knowledge he has and I do not. This file is
-- the thing itself.
--
-- THE GRAIN, and why it is the ip-api NAME rather than the ITDK domain
--
-- He asked for matches between ip-api.com and the BDC. ip-api reports one
-- name for a block of address space, so many ITDK domains share one ip-api
-- name: that is exactly how freeweld.com and afes.com both came to read
-- 'AT&T Enterprises, LLC'. Grouping by the ip-api name therefore collapses
-- the duplication, and the domains that report each name travel with it so
-- the customer-versus-carrier question stays visible.
--
-- WHAT EACH CANDIDATE RESTS ON, stated per row rather than mixed
--
--   by_ruling     Boris has already ruled this pairing. Nothing overrides it.
--   by_name       the superseded substring rule proposed it. Retained ONLY
--                 as a column, because it is how a reported name ending in
--                 COMMUNICATIONS reached an unrelated brand, and he should
--                 see which rows depend on it.
--   by_geography  a brand that files wireline service in the census tracts
--                 where the domains reporting this name have their serving
--                 sites. Measured, immune to acquisitions and to legacy
--                 domains, and scored at 43.9 pct precision at 1 against
--                 the truth set, so it is useful evidence and not an answer.
--
-- A row may carry several at once, and a name with NO candidate at all is
-- still listed, because that is a carrier waiting to be named rather than a
-- row to hide.
--
-- WIRELINE ONLY on the geography side, and the reason is Boris's:
-- "Fixed and mobile wireless (CGNAT) cannot be targeted at ZIP code level
-- because the customer-proximate IP routing point is usually one per DMA."
-- The footprint columns therefore count Copper, Cable and Fiber to the
-- Premises. Fixed wireless is excluded from them, not forgotten: a name
-- whose carrier is a WISP will show zero wireline footprint, which is the
-- correct reading and not a missing value.
--
-- OUTPUT. Everything goes to a TSV with no LIMIT. The counts print first.
--
-- PRE-MORTEM. Creates carrier_name_match_tbl, which is NEW, and drops it
-- first so the file re-runs. Everything else is read-only; no decision
-- table, no crosswalk and no step 4 input is touched.

\timing on

\echo
\echo Prerequisites.
\echo
SELECT t.relname AS required_table,
       CASE WHEN c.oid IS NULL THEN 'MISSING' ELSE 'present' END AS state
FROM (VALUES ('carrier_crosswalk_tbl'),
             ('carrier_resolved_tbl'),
             ('provider_brand_tract_tech_tbl'),
             ('serving_site_tbl'),
             ('carrier_match_v2_tbl')) AS t(relname)
LEFT JOIN pg_class c ON c.relname = t.relname AND c.relkind = 'r'
ORDER BY 2, 1;

\echo
\echo The columns carrier_crosswalk_tbl ACTUALLY has. My first attempt at
\echo this file used ipapi_as, which the DDL in carrier_crosswalk.sql
\echo declares and the deployed table does not have, and it aborted. A
\echo source file states what the current build would write, not what the
\echo table holds. Every column used below comes from a query already
\echo proven against this database by a successful run.
\echo
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'carrier_crosswalk_tbl'
ORDER BY ordinal_position;

DROP TABLE IF EXISTS carrier_name_match_tbl;
CREATE TABLE carrier_name_match_tbl AS
WITH nm AS (
    -- The ip-api name as the unit of approval, with every other source's
    -- name for the same thing travelling beside it.
    SELECT c.ipapi_isp,
           string_agg(DISTINCT c.ipapi_org, ' | ')   AS ipapi_org,
           string_agg(DISTINCT c.asn::text, ' | ')   AS asns,
           string_agg(DISTINCT c.rdap_name, ' | ')   AS rdap_names,
           string_agg(DISTINCT c.itdk_domain, ' ')   AS itdk_domains,
           count(DISTINCT c.itdk_domain)             AS domains,
           sum(c.nodes)                              AS nodes
    FROM carrier_crosswalk_tbl c
    WHERE c.ipapi_isp IS NOT NULL
    GROUP BY 1
), site AS (
    SELECT c.ipapi_isp,
           count(*)                        AS sites,
           count(DISTINCT s.city)          AS cities,
           sum(s.node_addresses)           AS site_node_addresses
    FROM carrier_crosswalk_tbl c
    JOIN serving_site_tbl s ON s.carrier_domain = c.itdk_domain
    WHERE c.ipapi_isp IS NOT NULL
    GROUP BY 1
), wire AS (
    SELECT provider_id, brand_name,
           count(*)                     AS wireline_pairs,
           count(DISTINCT tract_geoid)  AS wireline_tracts,
           string_agg(DISTINCT technology::text, ',' ORDER BY technology::text)
                                        AS wireline_techs
    FROM provider_brand_tract_tech_tbl
    WHERE technology IN (10, 40, 50)
    GROUP BY 1, 2
), by_name AS (
    SELECT c.ipapi_isp, c.bdc_provider_id AS provider_id,
           c.bdc_brand_name AS brand_name,
           string_agg(DISTINCT c.bdc_basis, '; ') AS name_basis
    FROM carrier_crosswalk_tbl c
    WHERE c.ipapi_isp IS NOT NULL AND c.bdc_provider_id IS NOT NULL
    GROUP BY 1, 2, 3
), by_ruling AS (
    SELECT c.ipapi_isp, r.bdc_provider_id AS provider_id,
           r.bdc_name_given AS brand_name,
           string_agg(DISTINCT r.label_basis, '; ') AS ruling_basis
    FROM carrier_resolved_tbl r
    JOIN carrier_crosswalk_tbl c ON c.itdk_domain = r.itdk_domain
    WHERE r.by_decision AND r.bdc_provider_id IS NOT NULL
      AND c.ipapi_isp IS NOT NULL
    GROUP BY 1, 2, 3
), by_geo AS (
    SELECT c.ipapi_isp, v.provider_id, v.brand_name,
           max(v.score_containment)                 AS best_pct_sites,
           sum(v.sites_in_footprint)                AS sites_in_footprint_sum,
           count(DISTINCT v.technology)             AS techs_matched
    FROM carrier_match_v2_tbl v
    JOIN carrier_crosswalk_tbl c ON c.itdk_domain = v.carrier_domain
    WHERE c.ipapi_isp IS NOT NULL
    GROUP BY 1, 2, 3
), cand AS (
    SELECT ipapi_isp, provider_id, brand_name FROM by_name
    UNION
    SELECT ipapi_isp, provider_id, brand_name FROM by_ruling
    UNION
    SELECT ipapi_isp, provider_id, brand_name FROM by_geo
)
SELECT nm.ipapi_isp,
       nm.ipapi_org,
       nm.asns,
       nm.rdap_names,
       nm.itdk_domains,
       nm.domains,
       nm.nodes,
       coalesce(st.sites, 0)                 AS sites,
       coalesce(st.cities, 0)                AS cities,
       coalesce(st.site_node_addresses, 0)   AS site_node_addresses,
       cand.provider_id,
       cand.brand_name                       AS bdc_brand_name,
       coalesce(w.wireline_pairs, 0)         AS wireline_pairs,
       coalesce(w.wireline_tracts, 0)        AS wireline_tracts,
       w.wireline_techs,
       (r.ipapi_isp IS NOT NULL)             AS by_ruling,
       (n.ipapi_isp IS NOT NULL)             AS by_name,
       (g.ipapi_isp IS NOT NULL)             AS by_geography,
       g.best_pct_sites,
       g.techs_matched,
       r.ruling_basis,
       n.name_basis,
       NULL::text                            AS approved_brand_name
FROM nm
LEFT JOIN site st  ON st.ipapi_isp = nm.ipapi_isp
LEFT JOIN cand     ON cand.ipapi_isp = nm.ipapi_isp
LEFT JOIN wire w   ON w.provider_id = cand.provider_id
                  AND w.brand_name  = cand.brand_name
LEFT JOIN by_ruling r ON r.ipapi_isp = nm.ipapi_isp
                      AND r.provider_id = cand.provider_id
                      AND r.brand_name  = cand.brand_name
LEFT JOIN by_name n   ON n.ipapi_isp = nm.ipapi_isp
                      AND n.provider_id = cand.provider_id
                      AND n.brand_name  = cand.brand_name
LEFT JOIN by_geo g    ON g.ipapi_isp = nm.ipapi_isp
                      AND g.provider_id = cand.provider_id
                      AND g.brand_name  = cand.brand_name;

CREATE INDEX carrier_name_match_isp_ix ON carrier_name_match_tbl (ipapi_isp);
CREATE INDEX carrier_name_match_prov_ix ON carrier_name_match_tbl (provider_id);
ANALYZE carrier_name_match_tbl;

COMMENT ON TABLE carrier_name_match_tbl IS
'Carrier names from all four sources side by side, one row per ip-api name against each candidate BDC brand, built for Boris to approve. The ip-api name is the unit because ip-api reports one name per block of address space, so many ITDK domains share one: freeweld.com and afes.com both read AT&T Enterprises LLC. by_ruling, by_name and by_geography say what each candidate rests on, kept separate rather than blended, and a name with no candidate is still listed because that is a carrier waiting to be named. Footprint columns count Copper, Cable and FTTP only, because Boris established that fixed and mobile wireless cannot be ZIP targeted: the customer-proximate routing point is usually one CGNAT egress per DMA. approved_brand_name is the empty column for his answer.';

\echo
\echo ================================================================
\echo THE SIZE OF WHAT NEEDS APPROVING. Counts first.
\echo ================================================================
\echo
SELECT count(*)                                             AS rows_to_approve,
       count(DISTINCT ipapi_isp)                            AS distinct_ipapi_names,
       count(DISTINCT ipapi_isp) FILTER (WHERE sites > 0)   AS names_with_a_site,
       count(*) FILTER (WHERE provider_id IS NULL)          AS names_with_no_candidate,
       count(*) FILTER (WHERE by_ruling)                    AS candidates_you_ruled,
       count(*) FILTER (WHERE by_name AND NOT by_geography) AS name_only_candidates,
       count(*) FILTER (WHERE by_geography AND NOT by_name) AS geography_only_candidates,
       count(*) FILTER (WHERE by_name AND by_geography)     AS both_agree
FROM carrier_name_match_tbl;

\echo
\echo The names that matter most, by the node addresses behind them. This
\echo is a printed extract; the TSV carries every row.
\echo
SELECT left(ipapi_isp, 30)          AS ipapi_isp,
       left(coalesce(asns, ''), 12)  AS asns,
       left(coalesce(rdap_names, ''), 24) AS rdap,
       domains, nodes, sites, cities,
       provider_id,
       left(coalesce(bdc_brand_name, ''), 26) AS bdc_brand,
       wireline_tracts,
       best_pct_sites,
       by_ruling, by_name, by_geography
FROM carrier_name_match_tbl
ORDER BY nodes DESC NULLS LAST, ipapi_isp, wireline_pairs DESC
LIMIT 70;

\echo
\echo ip-api names with a serving site and NO candidate brand at all. These
\echo cannot be matched by any method currently in the project, so they are
\echo the ones that need your name rather than your approval. Count first.
\echo
SELECT count(*) AS names_with_sites_and_no_candidate
FROM carrier_name_match_tbl
WHERE provider_id IS NULL AND sites > 0;

SELECT left(ipapi_isp, 36) AS ipapi_isp,
       left(coalesce(rdap_names, ''), 28) AS rdap,
       left(itdk_domains, 44) AS itdk_domains,
       domains, nodes, sites, cities
FROM carrier_name_match_tbl
WHERE provider_id IS NULL AND sites > 0
ORDER BY nodes DESC NULLS LAST
LIMIT 60;

\echo
\echo Writing the full table. Every row, every column, nothing truncated.
\echo The last column, approved_brand_name, is empty for your answer: put
\echo the BDC brand you want used, or NOT A CARRIER, or leave it blank.
\echo
\copy (SELECT ipapi_isp, ipapi_org, asns, rdap_names, itdk_domains, domains, nodes, sites, cities, site_node_addresses, provider_id, bdc_brand_name, wireline_pairs, wireline_tracts, wireline_techs, by_ruling, by_name, by_geography, best_pct_sites, techs_matched, ruling_basis, name_basis, approved_brand_name FROM carrier_name_match_tbl ORDER BY nodes DESC NULLS LAST, ipapi_isp, wireline_pairs DESC) TO '/home/boris/geo/carrier_name_approval.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
