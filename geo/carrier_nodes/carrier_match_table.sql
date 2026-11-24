-- ===========================================================================
-- carrier_match_table.sql
--
-- THE COMPLETE MATCHING TABLE. One table, one file, every ASN.
--
-- Boris 2026-11-22: "You haven't issued a complete matching table."
-- He is right. Until now the answer was spread over four tables and three
-- TSVs: asn_bdc_brand_map_tbl held the decisions, asn_brand_candidate_tbl the
-- string candidates, carrier_entity_proposal_tbl the trade-name matches and
-- asn_isp_disagree_tbl the corrections, and no single place showed an ASN
-- with its answer and the reason for it.
--
-- This builds carrier_match_tbl, which has a row for EVERY ASN including the
-- ones with no match at all, and writes the whole thing to one file.
--
-- COLUMNS THAT MATTER
--   source      where the match came from, and therefore how much to trust it
--                 decision        already approved and written to the map
--                 entity          a trade name, Comcast to Xfinity
--                 string          the name rule, tier 1 or 2
--                 isp_correction  the ip-api ISP name contradicts the
--                                 registry name and points at another brand
--                 none            no match from anything
--   status      approved, retired, proposed, unmatched
--   preferred   one row per ASN is marked true: the decision if there is
--               one, otherwise the strongest proposal. Filter on this to get
--               exactly one answer per ASN.
--   conflict    another source disagrees about this ASN
--
-- Run AFTER carrier_asn_match.sql and carrier_entity.sql.
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_match_table.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('ipapi_asn_tbl'), ('asn_brand_candidate_tbl'),
                 ('asn_bdc_brand_map_tbl'), ('asn_isp_disagree_tbl'),
                 ('carrier_entity_proposal_tbl'),
                 ('provider_brand_tract_tech_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_asn_match.sql then carrier_entity.sql first. Nothing was built.', missing;
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

DROP TABLE IF EXISTS carrier_match_tbl;

CREATE TABLE carrier_match_tbl AS
WITH
-- 1. Decisions already written. Authoritative.
decided AS (
    SELECT m.asn,
           m.bdc_provider_id                       AS provider_id,
           m.bdc_brand_name                        AS brand_name,
           'decision'::text                        AS source,
           CASE WHEN m.decision = 'brand' THEN 'approved' ELSE 'retired' END AS status,
           NULL::integer                           AS tier,
           m.decision                              AS decision,
           m.note                                  AS note
    FROM asn_bdc_brand_map_tbl m
),
-- 2. Trade-name matches through the entity layer.
entity AS (
    SELECT p.asn, p.provider_id, p.brand_name,
           'entity'::text AS source, 'proposed'::text AS status,
           NULL::integer AS tier, NULL::text AS decision,
           'entity ' || p.entity_key || ', reached from ' || p.ipapi_names
             || ' on ' || p.matched_on || ', ' || p.weakest_status AS note
    FROM carrier_entity_proposal_tbl p
    WHERE p.brand_name IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM decided d WHERE d.asn = p.asn)
),
-- 3. The name rule.
stringm AS (
    SELECT c.asn, c.provider_id, c.brand_name,
           'string'::text AS source, 'proposed'::text AS status,
           c.tier, NULL::text AS decision,
           'name rule tier ' || c.tier
             || ', ip-api ISP agrees at tier ' || c.tier_isp_agrees AS note
    FROM asn_brand_candidate_tbl c
    WHERE NOT EXISTS (SELECT 1 FROM decided d WHERE d.asn = c.asn)
),
-- 4. The ISP name contradicting the registry name. Transit excluded.
ispfix AS (
    SELECT DISTINCT d.asn, d.isp_suggests_provider_id AS provider_id,
           d.isp_suggests_brand AS brand_name,
           'isp_correction'::text AS source, 'proposed'::text AS status,
           d.isp_tier AS tier, NULL::text AS decision,
           'the registry says ' || d.as_operator || ' and ip-api says '
             || d.isp_commonest AS note
    FROM asn_isp_disagree_tbl d
    WHERE NOT d.isp_is_a_larger_asn_upstream
      AND NOT EXISTS (SELECT 1 FROM decided x WHERE x.asn = d.asn)
),
allrows AS (
    SELECT * FROM decided
    UNION ALL SELECT * FROM entity
    UNION ALL SELECT * FROM stringm
    UNION ALL SELECT * FROM ispfix
),
-- 5. Every ASN with nothing at all, so the table is COMPLETE.
nothing AS (
    SELECT a.asn, NULL::integer, NULL::text, 'none'::text, 'unmatched'::text,
           NULL::integer, NULL::text, NULL::text
    FROM ipapi_asn_tbl a
    WHERE NOT EXISTS (SELECT 1 FROM allrows r WHERE r.asn = a.asn)
),
combined AS (
    SELECT * FROM allrows UNION ALL SELECT * FROM nothing
),
-- The footprint of the matched brand, wireline only.
fp AS (
    SELECT f.provider_id, f.brand_name,
           count(DISTINCT f.tract_geoid) AS brand_wireline_tracts,
           min(f.technology)             AS lowest_technology,
           count(DISTINCT f.technology)  AS wireline_technologies
    FROM provider_brand_tract_tech_tbl f
    WHERE f.technology IN (10, 40, 50)
    GROUP BY 1, 2
)
SELECT c.asn,
       a.as_operator,
       a.as_operator_pct,
       a.isp_commonest,
       a.org_commonest,
       a.zip_capable_ranges,
       a.dma_only_ranges,
       a.unclassified_ranges,
       c.provider_id,
       c.brand_name,
       c.source,
       c.status,
       c.decision,
       c.tier,
       f.brand_wireline_tracts,
       f.wireline_technologies,
       -- The source order is the trust order: a written decision, then a
       -- trade name Boris confirmed, then the ISP correction, then the name
       -- rule. Within the name rule, tier 1 before tier 2.
       row_number() OVER (
         PARTITION BY c.asn
         ORDER BY CASE c.source WHEN 'decision' THEN 1 WHEN 'entity' THEN 2
                                WHEN 'isp_correction' THEN 3
                                WHEN 'string' THEN 4 ELSE 5 END,
                  coalesce(c.tier, 9),
                  f.brand_wireline_tracts DESC NULLS LAST,
                  c.brand_name) AS rank_in_asn,
       c.note
FROM combined c
JOIN ipapi_asn_tbl a ON a.asn = c.asn
LEFT JOIN fp f ON f.provider_id = c.provider_id AND f.brand_name = c.brand_name;

ALTER TABLE carrier_match_tbl ADD COLUMN preferred boolean;
ALTER TABLE carrier_match_tbl ADD COLUMN conflict  boolean;

-- conflict: two different sources name different brands for the same ASN.
UPDATE carrier_match_tbl t SET conflict = EXISTS (
    SELECT 1 FROM carrier_match_tbl o
    WHERE o.asn = t.asn
      AND o.source <> t.source
      AND o.brand_name IS DISTINCT FROM t.brand_name
      AND o.brand_name IS NOT NULL AND t.brand_name IS NOT NULL);

-- preferred: for an ASN with a written decision, every decision row is
-- preferred, because a carrier legitimately files under several brands and
-- all of them are the answer.
--
-- For an UNDECIDED ASN, the top-ranked proposal is preferred ONLY IF the
-- sources agree. Where they disagree, NO row is preferred.
--
-- I first ranked the sources and let the winner through, which made the
-- entity answer Verizon preferred for the Frontier ASNs over the ISP answer
-- Frontier. Reordering the two does not fix it either: for AS13977 the
-- string rule says Fidium Fiber and the ISP says Consolidated, both are the
-- same company and the specific brand is the better answer, the opposite of
-- the Frontier case. The precedence depends on the case, so there is no
-- ordering I can write that is right in general, and choosing one would be
-- guessing. A conflicted ASN therefore gets no preferred row and is counted
-- as needing a ruling.
UPDATE carrier_match_tbl t SET preferred =
  (t.source = 'decision')
  OR (t.rank_in_asn = 1
      AND NOT t.conflict
      AND NOT EXISTS (SELECT 1 FROM carrier_match_tbl d
                      WHERE d.asn = t.asn AND d.source = 'decision'));

CREATE INDEX carrier_match_asn_ix    ON carrier_match_tbl (asn);
CREATE INDEX carrier_match_status_ix ON carrier_match_tbl (status);
ANALYZE carrier_match_tbl;

COMMENT ON TABLE carrier_match_tbl IS
'The complete ASN to BDC brand matching table. One row per ASN and brand and source, including every ASN with no match at all. Filter preferred = true for exactly one answer per ASN. Rebuilt from scratch by carrier_match_table.sql; the persistent store of Boris-approved answers is asn_bdc_brand_map_tbl, not this.';

-- ---------------------------------------------------------------------------
-- The shape of it.
-- ---------------------------------------------------------------------------
\echo
\echo ================================================================
\echo THE COMPLETE MATCHING TABLE. Every ASN appears. Counts are over
\echo DISTINCT ASNs, and ranges are summed once per ASN.
\echo ================================================================
\echo
SELECT source, status,
       count(*)                                     AS rows,
       count(DISTINCT asn)                          AS asns,
       count(DISTINCT brand_name)                   AS brands,
       sum(zip_capable_ranges) FILTER (WHERE rank_in_asn = 1) AS zip_capable_ranges
FROM carrier_match_tbl
GROUP BY source, status
ORDER BY sum(zip_capable_ranges) FILTER (WHERE rank_in_asn = 1) DESC NULLS LAST;

\echo
\echo One answer per ASN. Every ASN is in exactly one line of this table.
\echo
WITH per_asn AS (
    SELECT a.asn, a.zip_capable_ranges,
           CASE
             WHEN EXISTS (SELECT 1 FROM carrier_match_tbl t
                          WHERE t.asn = a.asn AND t.source = 'decision'
                            AND t.status = 'approved')        THEN 'approved'
             WHEN EXISTS (SELECT 1 FROM carrier_match_tbl t
                          WHERE t.asn = a.asn AND t.status = 'retired') THEN 'retired'
             WHEN EXISTS (SELECT 1 FROM carrier_match_tbl t
                          WHERE t.asn = a.asn AND t.conflict) THEN 'conflict, needs a ruling'
             WHEN EXISTS (SELECT 1 FROM carrier_match_tbl t
                          WHERE t.asn = a.asn AND t.status = 'proposed') THEN 'proposed'
             ELSE 'no match from any source' END AS state
    FROM ipapi_asn_tbl a
)
SELECT state, count(*) AS asns, sum(zip_capable_ranges) AS zip_capable_ranges,
       round(100.0 * sum(zip_capable_ranges)
             / nullif((SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl), 0), 1) AS pct
FROM per_asn GROUP BY state ORDER BY sum(zip_capable_ranges) DESC NULLS LAST;

\echo
\echo Conflicts: one ASN, two sources, two different brands. Each needs a word.
\echo
SELECT t.asn, left(t.as_operator, 24) AS as_operator,
       left(coalesce(t.isp_commonest, ''), 22) AS ipapi_isp,
       t.source, t.provider_id, t.brand_name,
       t.tier, t.zip_capable_ranges
FROM carrier_match_tbl t
WHERE t.conflict
ORDER BY t.zip_capable_ranges DESC NULLS LAST, t.asn, t.rank_in_asn
LIMIT 40;

\echo
\echo The largest ASNs with NO match from any source. This is the real
\echo remaining work, and it is what the Form 499 legal names are for.
\echo
SELECT t.asn, left(t.as_operator, 40) AS as_operator,
       left(coalesce(t.isp_commonest, ''), 30) AS ipapi_isp,
       t.zip_capable_ranges
FROM carrier_match_tbl t
WHERE t.source = 'none'
ORDER BY t.zip_capable_ranges DESC NULLS LAST
LIMIT 40;

\echo
\echo The whole table, largest first, as one file.
\echo
\copy (SELECT asn, as_operator, as_operator_pct, isp_commonest, org_commonest, zip_capable_ranges, dma_only_ranges, unclassified_ranges, provider_id, brand_name, source, status, decision, tier, brand_wireline_tracts, wireline_technologies, rank_in_asn, preferred, conflict, note FROM carrier_match_tbl ORDER BY zip_capable_ranges DESC NULLS LAST, asn, rank_in_asn) TO '/home/boris/geo/carrier_match_table.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\echo
\echo And the one-answer-per-ASN view, which is the shorter file.
\echo
\copy (SELECT asn, as_operator, isp_commonest, zip_capable_ranges, dma_only_ranges, provider_id, brand_name, source, status, tier, brand_wireline_tracts, conflict, note FROM carrier_match_tbl WHERE preferred ORDER BY zip_capable_ranges DESC NULLS LAST, asn) TO '/home/boris/geo/carrier_match_preferred.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
