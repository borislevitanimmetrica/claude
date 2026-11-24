-- ===========================================================================
-- carrier_link_rederive.sql
--
-- Re-tests the MACHINE-MATCHED half of carrier_resolved_tbl against the
-- current matching rule, and reports what that would change. It writes a
-- NEW table and does not touch the existing one.
--
-- WHY. Measured on Boris's 2026-11-24 step 4 run:
--
--   provider 130485  USA COMMUNICATIONS   2,699 sites from 537 suffixes
--   provider 131425  Verizon                324 sites from  71 suffixes
--   provider 130077  AT&T                   168 sites from  56 suffixes
--   provider 130235  Spectrum                37 sites from  33 suffixes
--
-- USA COMMUNICATIONS is a small carrier holding 537 DNS suffixes. Its link
-- to comcast.net, comcastbusiness.net, spectrum.com and charter.com is the
-- pair the regression gate rejects as case 19, source "the original bug".
-- And AT&T's 56 suffixes include americanadoptions.com, a DIA customer whose
-- ip-api ISP name reads as AT&T. Each such domain contributes a SITE, so the
-- distance from a tract to its carrier is measured partly to customer
-- premises. 53 percent of carrier-tract pairs are now over 50 km from the
-- nearest site, and these links are a large part of why.
--
-- carrier_resolved_tbl holds 14,029 rows over 3,900 domains, of which 4,920
-- rest on a ruling of his and the rest on name matching done before the
-- current rule existed. The rule, from 2026-11-23, is: a match is a COMPLETE
-- name match once the legal suffix is stripped, or a pairing he has
-- confirmed, and nothing else.
--
-- WHAT IS TESTED. For a machine-matched row, the carrier name on the ITDK
-- side is taken from the row itself, in order: ipapi_isp, then rdap_name,
-- then carrier_label. That name is compared against every BDC brand of the
-- linked provider with carrier_name_tier. Tier 1 or 2 keeps the link; tier 0
-- or 3 drops it.
--
-- WHAT THIS DOES NOT DO. It does not delete anything. carrier_resolved_tbl
-- is the table holding his 4,920 rulings and the table step 4 reads; it is
-- not replaced here. The new table is carrier_resolved_v2_tbl, and the swap
-- is a separate deliberate act after he has read the report.
--
-- PRE-MORTEM for the eventual swap, stated now rather than later. Replacing
-- carrier_resolved_tbl would change which providers step 4 can place, so
-- step4_carrier_tract_site_tbl must be rebuilt afterwards, which is a 50
-- second run. Nothing else reads it. His rulings are carried across
-- unchanged and are also still in carrier_decision_tbl, so they cannot be
-- lost by this file even if the swap is wrong.
--
-- RUN TIME: seconds. It reads 14,029 rows and the brand list, nothing large.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_link_rederive.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('carrier_resolved_tbl'), ('bdc_carrier_tbl'),
                 ('provider_tract_tech_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Nothing was read.', missing;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'carrier_name_tier') THEN
        RAISE EXCEPTION 'carrier_name_tier does not exist. Run carrier_asn_match.sql first: the whole point of this file is to apply THAT rule to this link. Nothing was read.';
    END IF;

    SELECT string_agg(c.needed, ', ') INTO missing
    FROM (VALUES ('itdk_domain'), ('ipapi_isp'), ('rdap_name'),
                 ('carrier_label'), ('bdc_provider_id'), ('by_decision'))
         AS c(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns i
                      WHERE i.table_name = 'carrier_resolved_tbl'
                        AND i.column_name = c.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'carrier_resolved_tbl has no % column. Columns present: %',
            missing,
            (SELECT string_agg(column_name, ', ' ORDER BY column_name)
             FROM information_schema.columns
             WHERE table_name = 'carrier_resolved_tbl');
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- One row per existing link, carrying the verdict of the current rule.
DROP TABLE IF EXISTS carrier_link_verdict_tbl;
CREATE TABLE carrier_link_verdict_tbl AS
WITH link AS (
    SELECT r.itdk_domain,
           r.bdc_provider_id,
           coalesce(r.by_decision, false)                        AS by_decision,
           coalesce(r.nodes, 0)                                  AS nodes,
           coalesce(nullif(btrim(r.ipapi_isp), ''),
                    nullif(btrim(r.rdap_name), ''),
                    nullif(btrim(r.carrier_label), ''))          AS itdk_side_name
    FROM carrier_resolved_tbl r
    WHERE r.bdc_provider_id IS NOT NULL
), brand AS (
    -- DISTINCT brands per provider. bdc_carrier_tbl has one row per
    -- carrier_key, so a provider repeats its brand once per filing and the
    -- tier would otherwise be computed once per repeat.
    SELECT DISTINCT provider_id, brand_name
    FROM bdc_carrier_tbl
    WHERE brand_name IS NOT NULL AND brand_name <> ''
), scored AS (
    -- ONE tier evaluation per link and brand, not two. The first version
    -- computed it in max() and again in the ORDER BY of a second subquery,
    -- and carrier_name_tier is STABLE with three table lookups inside it, so
    -- the duplication cost real time: 169.8 s on Boris's data against my
    -- estimate of seconds. A lateral returns the tier AND the brand that
    -- earned it from a single pass.
    SELECT l.*, best.best_tier, best.best_brand
    FROM link l
    LEFT JOIN LATERAL (
        SELECT carrier_name_tier(l.itdk_side_name, b.brand_name) AS best_tier,
               b.brand_name                                      AS best_brand
        FROM brand b
        WHERE b.provider_id = l.bdc_provider_id
        ORDER BY carrier_name_tier(l.itdk_side_name, b.brand_name) DESC,
                 b.brand_name
        LIMIT 1) best ON true
)
SELECT s.itdk_domain, s.bdc_provider_id, s.by_decision, s.nodes,
       s.itdk_side_name, s.best_brand,
       -- COMPUTED ONCE, AS A COLUMN. The report at the end of this file used
       -- carrier_name_compact(v.itdk_side_name) inside a correlated
       -- subquery, so it was evaluated once per alias row per verdict row:
       -- 684 by 11,925, which is 8.2 million calls to a function that splits
       -- a string with a regular expression. That hung for over five minutes
       -- on Boris's data. Same class of defect as the doubled tier call in
       -- this very file an hour earlier: a function on a column inside a
       -- correlated subquery, where no index can help.
       carrier_name_compact(s.itdk_side_name) AS itdk_name_key,
       coalesce(s.best_tier, 0) AS best_tier,
       CASE WHEN s.by_decision                       THEN 'kept: your ruling'
            WHEN coalesce(s.best_tier, 0) = 1        THEN 'kept: complete name match'
            WHEN coalesce(s.best_tier, 0) = 2        THEN 'kept: pairing you confirmed'
            WHEN s.itdk_side_name IS NULL            THEN 'dropped: no carrier name on the ITDK side'
            WHEN coalesce(s.best_tier, 0) = 3        THEN 'dropped: shares a word only'
            ELSE                                          'dropped: no connection' END AS verdict
FROM scored s;

CREATE INDEX carrier_link_verdict_provider_ix ON carrier_link_verdict_tbl (bdc_provider_id);
CREATE INDEX carrier_link_verdict_domain_ix ON carrier_link_verdict_tbl (itdk_domain);
CREATE INDEX carrier_link_verdict_key_ix ON carrier_link_verdict_tbl (itdk_name_key);
ANALYZE carrier_link_verdict_tbl;

\echo
\echo ================================================================
\echo 1. WHAT THE CURRENT RULE SAYS ABOUT THE EXISTING LINKS.
\echo Your rulings are kept whatever the strings say.
\echo ================================================================
\echo
SELECT verdict, count(*) AS links, count(DISTINCT itdk_domain) AS domains,
       count(DISTINCT bdc_provider_id) AS providers
FROM carrier_link_verdict_tbl
GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo ================================================================
\echo 2. THE PROVIDERS THAT LOSE THE MOST LINKS. A domain count in the
\echo hundreds against one provider is not a carrier with hundreds of
\echo names, it is a name match that should never have been made.
\echo ================================================================
\echo
SELECT v.bdc_provider_id,
       left(coalesce((SELECT string_agg(DISTINCT b.brand_name, ' / ')
                      FROM bdc_carrier_tbl b
                      WHERE b.provider_id = v.bdc_provider_id), ''), 34) AS brand,
       count(*)                                        AS links_now,
       count(*) FILTER (WHERE verdict LIKE 'kept%')    AS kept,
       count(*) FILTER (WHERE verdict LIKE 'dropped%') AS dropped
FROM carrier_link_verdict_tbl v
GROUP BY v.bdc_provider_id
ORDER BY count(*) FILTER (WHERE verdict LIKE 'dropped%') DESC
LIMIT 25;

\echo
\echo ================================================================
\echo 3. THE COST, AND IT IS THE NUMBER TO JUDGE THIS BY. Providers
\echo that keep at least one link against providers that lose all of
\echo them, weighted by the WIRELINE footprint behind each.
\echo ================================================================
\echo
WITH per_provider AS (
    SELECT v.bdc_provider_id,
           count(*) FILTER (WHERE verdict LIKE 'kept%') AS kept
    FROM carrier_link_verdict_tbl v
    GROUP BY 1
), fp AS (
    SELECT p.provider_id, count(*) AS wireline_pairs
    FROM provider_tract_tech_tbl p
    WHERE p.technology IN (10, 40, 50)
    GROUP BY 1
)
SELECT CASE WHEN pp.kept > 0 THEN 'keeps a link' ELSE 'loses every link' END AS state,
       count(*)                          AS providers,
       sum(coalesce(fp.wireline_pairs, 0)) AS wireline_tract_tech_pairs
FROM per_provider pp
LEFT JOIN fp ON fp.provider_id = pp.bdc_provider_id
GROUP BY 1 ORDER BY 1;

\echo
\echo The largest providers that would lose every link, with the wireline
\echo footprint behind them. These become unplaceable until a pairing is
\echo confirmed, and several are already in your pairing queue.
\echo
WITH per_provider AS (
    SELECT v.bdc_provider_id,
           count(*) FILTER (WHERE verdict LIKE 'kept%') AS kept
    FROM carrier_link_verdict_tbl v
    GROUP BY 1
), fp AS (
    SELECT p.provider_id, count(*) AS wireline_pairs,
           count(DISTINCT p.tract_geoid) AS tracts
    FROM provider_tract_tech_tbl p
    WHERE p.technology IN (10, 40, 50)
    GROUP BY 1
)
SELECT pp.bdc_provider_id,
       left(coalesce((SELECT string_agg(DISTINCT b.brand_name, ' / ')
                      FROM bdc_carrier_tbl b
                      WHERE b.provider_id = pp.bdc_provider_id), ''), 30) AS brand,
       coalesce(fp.tracts, 0)         AS wireline_tracts,
       (SELECT string_agg(DISTINCT left(v2.itdk_side_name, 28), ' | ')
        FROM carrier_link_verdict_tbl v2
        WHERE v2.bdc_provider_id = pp.bdc_provider_id
          AND v2.itdk_side_name IS NOT NULL) AS itdk_names_that_failed
FROM per_provider pp
LEFT JOIN fp ON fp.provider_id = pp.bdc_provider_id
WHERE pp.kept = 0
ORDER BY coalesce(fp.tracts, 0) DESC
LIMIT 20;

\echo
\echo ================================================================
\echo 4. THE PROPOSED TABLE, written but NOT swapped in. Nothing that
\echo runs today reads it.
\echo ================================================================
\echo
DROP TABLE IF EXISTS carrier_resolved_v2_tbl;
CREATE TABLE carrier_resolved_v2_tbl AS
-- DISTINCT, because the table holds exact duplicate rows. Boris's query
-- 2026-11-24 settled the anomaly I could not explain: provider 131413 has
-- 2,775 by_decision rows over 5 domains, 1 ASN, 1 ip-api name and 1 RDAP
-- name, so at most five distinct combinations are represented by 2,775 rows.
-- 131469 and 540017 have 1,036 rows over 2 domains each. The rows are
-- repeats, carrying no information, and they inflate every count of links
-- and multiply every join that passes through this table.
SELECT DISTINCT r.*
FROM carrier_resolved_tbl r
WHERE r.bdc_provider_id IS NULL
   OR coalesce(r.by_decision, false)
   OR EXISTS (SELECT 1 FROM carrier_link_verdict_tbl v
              WHERE v.itdk_domain = r.itdk_domain
                AND v.bdc_provider_id = r.bdc_provider_id
                AND v.verdict LIKE 'kept%');

CREATE INDEX carrier_resolved_v2_domain_ix ON carrier_resolved_v2_tbl (itdk_domain);
CREATE INDEX carrier_resolved_v2_provider_ix ON carrier_resolved_v2_tbl (bdc_provider_id);
ANALYZE carrier_resolved_v2_tbl;

COMMENT ON TABLE carrier_resolved_v2_tbl IS
'carrier_resolved_tbl with the machine-matched links re-tested against the current rule: a complete name match or a pairing Boris confirmed. Every by_decision row is carried across untouched. NOT in use: nothing reads this table until it is deliberately swapped for carrier_resolved_tbl, and step4_tract_site.sql must be re-run after any swap.';

SELECT (SELECT count(*) FROM carrier_resolved_tbl)                  AS rows_now,
       (SELECT count(*) FROM (SELECT DISTINCT * FROM carrier_resolved_tbl) d)
                                                                    AS rows_now_deduplicated,
       (SELECT count(*) FROM carrier_resolved_v2_tbl)               AS rows_after,
       (SELECT count(*) FROM carrier_resolved_tbl
        WHERE coalesce(by_decision, false))                         AS your_rulings_now,
       (SELECT count(*) FROM carrier_resolved_v2_tbl
        WHERE coalesce(by_decision, false))                         AS your_rulings_after;

-- Losing one of his rulings would be the worst possible outcome of this
-- file, so it is asserted rather than reported.
DO $rulings$
DECLARE before_n bigint; after_n bigint;
BEGIN
    -- compared on DISTINCT rows, because v2 is de-duplicated and the
    -- original is not: counting repeats on one side and not the other would
    -- fail this assertion for the wrong reason.
    SELECT count(*) INTO before_n FROM (
        SELECT DISTINCT * FROM carrier_resolved_tbl
        WHERE coalesce(by_decision, false)) d;
    SELECT count(*) INTO after_n FROM carrier_resolved_v2_tbl
    WHERE coalesce(by_decision, false);
    IF after_n <> before_n THEN
        RAISE EXCEPTION 'the proposed table holds % of your % distinct rulings. It must hold all of them. Nothing was swapped and carrier_resolved_tbl is untouched.', after_n, before_n;
    END IF;
    RAISE NOTICE 'all % of your rulings are carried across', after_n;
END
$rulings$;

-- ---------------------------------------------------------------------------
-- 5. THE DROPS THAT ARE QUESTIONS, NOT ERRORS.
--
-- A link dropped at tier 3 shares an informative word with the brand, which
-- on his data is usually a real carrier under a longer legal name:
-- Frontier Communications Corp against the brand Frontier, LUMOS Networks
-- against lumos, Armstrong against Armstrong Telecommunications Inc. Those
-- are pairings waiting for one word, not mistakes.
--
-- A link dropped at tier 0 shares nothing, and those were always wrong:
-- comcast.net to USA COMMUNICATIONS, Ohio State University to Agile
-- Networks, US Internet Corp to WOW.
--
-- So the tier 3 drops are added to carrier_alias_tbl as PROPOSED pairings,
-- which is the same queue he already answers for the ASN side. Confirming
-- one there now restores the ITDK link AND the ASN match from one ruling.
-- Nothing is confirmed here; a proposed pairing matches nothing.
-- ---------------------------------------------------------------------------
INSERT INTO carrier_alias_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, status, note)
SELECT DISTINCT ON (carrier_name_compact(v.itdk_side_name),
                    carrier_name_compact(v.best_brand))
       v.itdk_side_name, v.best_brand,
       carrier_name_compact(v.itdk_side_name),
       carrier_name_compact(v.best_brand),
       'proposed',
       'from the ITDK link, provider ' || v.bdc_provider_id
FROM carrier_link_verdict_tbl v
WHERE v.verdict = 'dropped: shares a word only'
  AND v.itdk_side_name IS NOT NULL
  AND v.best_brand IS NOT NULL
  AND carrier_name_compact(v.itdk_side_name) IS NOT NULL
  AND carrier_name_compact(v.best_brand) IS NOT NULL
  AND carrier_name_compact(v.itdk_side_name) <> carrier_name_compact(v.best_brand)
  AND NOT carrier_keys_are_unrelated(carrier_name_compact(v.itdk_side_name),
                                     carrier_name_compact(v.best_brand))
ON CONFLICT (ipapi_key, bdc_key) DO NOTHING;

ANALYZE carrier_alias_tbl;

\echo
\echo Pairings now waiting on you, worth the most wireline tracts first.
\echo Confirming one restores the ITDK link and the ASN match together.
\echo
WITH fp AS (
    SELECT provider_id, count(DISTINCT tract_geoid) AS tracts
    FROM provider_tract_tech_tbl
    WHERE technology IN (10, 40, 50)
    GROUP BY 1
), vk AS (
    -- one row per ITDK name key, with the largest wireline footprint behind
    -- it. Aggregated FIRST, then hash-joined, instead of being recomputed
    -- per alias row.
    SELECT v.itdk_name_key, max(f.tracts) AS tracts
    FROM carrier_link_verdict_tbl v
    JOIN fp f ON f.provider_id = v.bdc_provider_id
    WHERE v.itdk_name_key IS NOT NULL
    GROUP BY 1
)
SELECT x.ipapi_side, x.bdc_side, vk.tracts AS wireline_tracts
FROM carrier_alias_tbl x
LEFT JOIN vk ON vk.itdk_name_key = x.ipapi_key
WHERE x.status = 'proposed'
ORDER BY vk.tracts DESC NULLS LAST, x.ipapi_side
LIMIT 30;

SELECT status, count(*) AS pairings FROM carrier_alias_tbl GROUP BY 1 ORDER BY 1;

\echo
\echo ================================================================
\echo NOTHING HAS CHANGED YET. carrier_resolved_tbl is untouched and
\echo step 4 still reads it.
\echo
\echo To adopt the re-derived link, after reading the report above:
\echo   psql -c "ALTER TABLE carrier_resolved_tbl RENAME TO carrier_resolved_v1_tbl"
\echo   psql -c "ALTER TABLE carrier_resolved_v2_tbl RENAME TO carrier_resolved_tbl"
\echo   psql -f /home/boris/geo/src/claude/geo/carrier_nodes/step4_tract_site.sql
\echo
\echo The old table is renamed rather than dropped, so the change is
\echo reversible by renaming it back. Step 4 takes about one minute.
\echo ================================================================
\echo

\timing off
