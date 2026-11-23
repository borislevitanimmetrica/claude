-- ===========================================================================
-- carrier_universe.sql
--
-- THE SET OF THINGS THAT ARE ALLOWED TO BE CARRIERS.
--
-- Boris 2026-11-22: "1-800-Flowers, ASNs 20190 and 54986, are related to
-- Comcast and Verizon, respectively, probably an error. But 1-800-Flowers is
-- NOT a carrier and is out of scope. You have a table with carrier names.
-- You have the FCC Form 499a list from me. Restrict carriers to the superset
-- of those sources and do not process the rest."
--
-- WHY 1-800-FLOWERS HAPPENED, AND IT IS MY ERROR
--
-- When I made the entity layer resolve the ip-api side on the ISP name as
-- well as the operator name, I wrote that it was safe because the ISP name
-- is checked against a name Boris had already confirmed for that entity.
-- That reasoning was wrong. 1-800-Flowers is a Comcast business customer, so
-- ip-api reports its ISP as Comcast, the name matched the comcast entity, and
-- its ASN was mapped to Xfinity plant. This is the Amazon-to-Windstream
-- failure again, through a door I opened after closing the first one.
--
-- The fix Boris names is better than patching that door. An ASN is eligible
-- only if the party that HOLDS it is a carrier, and whether it is a carrier
-- is settled by a list rather than inferred from a name. The ISP name can
-- still say Comcast; 1-800-Flowers is simply not in the universe, so nothing
-- about it is processed.
--
-- THE SUPERSET
--   1. every name in bdc_carrier_tbl. Columns are DISCOVERED from
--      information_schema and reported, not assumed.
--   2. the FCC Form 499a filers, if fcc499_filer_tbl exists.
--
-- Eligibility is tested against the AS OPERATOR NAME ONLY, never the ISP
-- name, because the ISP name is the upstream carrier for every DIA customer.
--
-- The table itself is BUILT by carrier_asn_match.sql, which defines the
-- name functions it needs. This file reports on it and must be run after.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_universe.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'bdc_carrier_tbl') THEN
        RAISE EXCEPTION 'bdc_carrier_tbl does not exist. Nothing was built.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'carrier_universe_tbl') THEN
        RAISE EXCEPTION 'carrier_universe_tbl does not exist. Run carrier_asn_match.sql first, which builds it. Nothing was reported.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

\echo
\echo Every column of bdc_carrier_tbl, so you can see what I had to work with.
\echo
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'bdc_carrier_tbl'
ORDER BY ordinal_position;

\echo
\echo Whether the FCC Form 499a filer list is loaded.
\echo
SELECT CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables
                         WHERE table_name = 'fcc499_filer_tbl')
            THEN 'fcc499_filer_tbl is present'
            ELSE 'fcc499_filer_tbl is NOT present, so the universe is BDC names only' END
       AS form_499a;

\echo
\echo The universe, by source.
\echo
SELECT source, count(*) AS names, count(DISTINCT name_key) AS distinct_keys
FROM carrier_universe_tbl GROUP BY source ORDER BY count(*) DESC;

SELECT count(DISTINCT name_key) AS distinct_names_in_universe
FROM carrier_universe_tbl;

-- ---------------------------------------------------------------------------
-- What the restriction does to the problem.
-- ---------------------------------------------------------------------------
\echo
\echo How the probed ASNs divide. Only in_universe is processed from now on.
\echo
SELECT CASE WHEN carrier_name_in_universe(a.as_operator) THEN 'in_universe'
            ELSE 'not a carrier, will not be processed' END AS eligibility,
       count(*)                     AS asns,
       sum(a.zip_capable_ranges)    AS zip_capable_ranges,
       round(100.0 * sum(a.zip_capable_ranges)
             / nullif((SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl), 0), 1) AS pct
FROM ipapi_asn_tbl a
GROUP BY 1 ORDER BY 3 DESC;

-- ---------------------------------------------------------------------------
-- WHICH PATH ADMITTED EACH NAME.
--
-- Membership holds on compact-key agreement, token-key agreement or a tier 1
-- or 2 score against a universe name. The first version tested the compact
-- key alone and that is stricter than the matcher, so it excluded holders
-- the matcher matches; on 2026-11-22 the cleanup then deleted 769 of their
-- decisions, 373,410 ZIP-capable ranges, AS7018 AT&T included. The rows
-- counted under tier_rule below are exactly the ones that version lost.
-- ---------------------------------------------------------------------------
\echo
\echo Which path admits each eligible ASN. tier_rule counts the ASNs that a
\echo compact-key-only test would have thrown away.
\echo
WITH p AS (
    SELECT a.asn, a.zip_capable_ranges,
           EXISTS (SELECT 1 FROM carrier_universe_tbl u
                   WHERE u.name_key = carrier_name_compact(a.as_operator)) AS by_compact,
           EXISTS (SELECT 1 FROM carrier_universe_tbl u
                   WHERE u.token_key = carrier_name_token_key(a.as_operator)
                     AND carrier_name_token_key(a.as_operator) IS NOT NULL) AS by_token,
           carrier_name_in_universe(a.as_operator) AS eligible
    FROM ipapi_asn_tbl a
)
SELECT CASE WHEN NOT eligible          THEN 'not in the universe'
            WHEN by_compact            THEN 'compact key'
            WHEN by_token              THEN 'token key'
            ELSE                            'tier rule' END AS admitted_by,
       count(*) AS asns, sum(zip_capable_ranges) AS zip_capable_ranges
FROM p GROUP BY 1 ORDER BY 3 DESC NULLS LAST;

\echo
\echo The ASNs admitted ONLY by the tier rule, largest first. Each is a
\echo holder whose name matches a carrier name without the two keys agreeing.
\echo
SELECT a.asn, left(a.as_operator, 40) AS as_operator,
       left((SELECT u.name FROM carrier_universe_token_tbl ut
             JOIN carrier_universe_tbl u ON u.name = ut.name
             WHERE ut.tok = ANY (carrier_name_tokens_strict(a.as_operator))
               AND carrier_name_tier(a.as_operator, ut.name) IN (1, 2)
             ORDER BY carrier_name_tier(a.as_operator, ut.name), u.name
             LIMIT 1), 34) AS matched_universe_name,
       a.zip_capable_ranges
FROM ipapi_asn_tbl a
WHERE carrier_name_in_universe(a.as_operator)
  AND NOT EXISTS (SELECT 1 FROM carrier_universe_tbl u
                  WHERE u.name_key = carrier_name_compact(a.as_operator))
  AND NOT EXISTS (SELECT 1 FROM carrier_universe_tbl u
                  WHERE u.token_key = carrier_name_token_key(a.as_operator)
                    AND carrier_name_token_key(a.as_operator) IS NOT NULL)
ORDER BY a.zip_capable_ranges DESC NULLS LAST
LIMIT 40;

\echo
\echo The largest ASNs the restriction EXCLUDES. Check that none of these is
\echo a carrier you expect to target. Anything here that is a carrier means
\echo its name is missing from both sources.
\echo
SELECT a.asn, left(a.as_operator, 44) AS as_operator,
       left(coalesce(a.isp_commonest, ''), 30) AS ipapi_isp,
       a.zip_capable_ranges
FROM ipapi_asn_tbl a
WHERE NOT carrier_name_in_universe(a.as_operator)
ORDER BY a.zip_capable_ranges DESC NULLS LAST
LIMIT 50;

\echo
\echo The two 1-800-Flowers ASNs Boris named, as a direct check.
\echo
SELECT a.asn, a.as_operator, a.isp_commonest,
       carrier_name_in_universe(a.as_operator) AS in_universe,
       a.zip_capable_ranges
FROM ipapi_asn_tbl a
WHERE a.asn IN (20190, 54986);

\timing off
