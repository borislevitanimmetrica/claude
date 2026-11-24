-- ===========================================================================
-- carrier_alias_review.sql
--
-- Writes the proposed pairings to a file for Boris to rule on, largest
-- first, and prints what each one is worth.
--
-- WHY THIS EXISTS. Since 2026-11-23 a match is a COMPLETE name match or a
-- pairing he has confirmed, and nothing else: "Insist on complete matches
-- when the exact pairing is not in your table." That left 37 pairings in
-- carrier_alias_tbl with status proposed, which do NOT match, and on his
-- 2026-11-24 run they stand between 376,492 ZIP-capable ranges and their
-- plant. The largest is AT&T Enterprises, LLC against the brand AT&T, worth
-- 283,233 ranges across 26 ASNs.
--
-- They are proposed rather than confirmed because they are MY inferences
-- about which companies are the same network. He has not ruled on them, and
-- treating my inference as his ruling is how 1-800-Flowers came to hold
-- Comcast plant.
--
-- His own refutation of the shortcut, 2026-11-24: "Your proposal to rely on
-- the legal name doesn't work because there are many subsidiaries, such as
-- AT&T Broadband, LLC of AT&T Enterprises, Inc." The Form 499a file cannot
-- settle these either, because it lists subsidiaries under their own legal
-- names; measured on the real file, it holds AT&T Corp. and AT&T Broadband
-- Phone of Virginia, Inc. and no AT&T Enterprises at all. So there is no
-- data source that decides this. It needs one word per row from him.
--
-- HOW TO ANSWER. Put y or n in the decision column of the TSV and run
-- load_alias_decisions.sql.
--   y  the two names are the same network. The pairing becomes confirmed and
--      matches from then on.
--   n  they are different companies. The pairing is deleted AND recorded in
--      carrier_unrelated_tbl, so no rule can ever offer it again.
--   blank, left alone. It stays proposed and matches nothing.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_alias_review.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('carrier_alias_tbl'), ('ipapi_asn_tbl'),
                 ('bdc_carrier_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_asn_match.sql first. Nothing was written.', missing;
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- One row per proposed pairing, with everything needed to judge it: how many
-- ASNs carry that ip-api name, how much probed ZIP-capable space sits behind
-- them, whether the BDC side is a real brand, and how much wireline plant
-- that brand has. A pairing whose BDC side is not a brand in the data can
-- never produce a match however true it is, and is marked so.
DROP TABLE IF EXISTS carrier_alias_review_tbl;
CREATE TABLE carrier_alias_review_tbl AS
WITH holder AS (
    SELECT carrier_name_compact(a.as_operator)  AS name_key,
           count(*)                             AS asns,
           sum(a.zip_capable_ranges)            AS zip_capable_ranges,
           count(*) FILTER (WHERE EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                                          WHERE m.asn = a.asn
                                            AND m.decision = 'brand')) AS asns_already_mapped
    FROM ipapi_asn_tbl a
    WHERE a.as_operator IS NOT NULL
    GROUP BY 1
), brand AS (
    SELECT carrier_name_compact(c.brand_name) AS name_key,
           count(DISTINCT c.provider_id)      AS providers,
           count(DISTINCT c.brand_name)        AS spellings
    FROM bdc_carrier_tbl c
    WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
    GROUP BY 1
), plant AS (
    SELECT carrier_name_compact(f.brand_name) AS name_key,
           count(DISTINCT f.tract_geoid)       AS wireline_tracts
    FROM provider_brand_tract_tech_tbl f
    WHERE f.technology IN (10, 40, 50)
    GROUP BY 1
)
SELECT x.ipapi_side,
       x.bdc_side,
       x.ipapi_key,
       x.bdc_key,
       coalesce(h.asns, 0)                       AS asns_with_that_name,
       coalesce(h.zip_capable_ranges, 0)         AS zip_capable_ranges,
       coalesce(h.asns_already_mapped, 0)        AS asns_already_mapped,
       coalesce(b.providers, 0)                  AS bdc_providers,
       coalesce(p.wireline_tracts, 0)            AS brand_wireline_tracts,
       CASE WHEN b.providers IS NULL
            THEN 'the BDC side is not a brand in your data, so this pairing cannot produce a match'
            WHEN coalesce(p.wireline_tracts, 0) = 0
            THEN 'the brand has no wireline plant, so it cannot answer a ZIP question'
            WHEN coalesce(h.asns, 0) = 0
            THEN 'no probed ASN carries that ip-api name'
            ELSE '' END                          AS caveat,
       x.note,
       ''::text                                  AS decision
FROM carrier_alias_tbl x
LEFT JOIN holder h ON h.name_key = x.ipapi_key
LEFT JOIN brand  b ON b.name_key = x.bdc_key
LEFT JOIN plant  p ON p.name_key = x.bdc_key
WHERE x.status = 'proposed';

ANALYZE carrier_alias_review_tbl;

\echo
\echo ================================================================
\echo PAIRINGS AWAITING ONE WORD FROM YOU, worth the most first.
\echo y means the two names are the same network and it will match.
\echo n means different companies, and it is recorded as unrelated.
\echo ================================================================
\echo
SELECT ipapi_side, bdc_side, asns_with_that_name AS asns,
       zip_capable_ranges, brand_wireline_tracts AS tracts, caveat
FROM carrier_alias_review_tbl
ORDER BY zip_capable_ranges DESC, ipapi_side, bdc_side;

\echo
\echo What the whole list is worth, counting each ASN once.
\echo
SELECT (SELECT count(*) FROM carrier_alias_review_tbl)            AS pairings,
       (SELECT count(*) FROM carrier_alias_review_tbl
        WHERE caveat = '')                                        AS could_match,
       (SELECT count(*) FROM carrier_alias_review_tbl
        WHERE caveat <> '')                                       AS cannot_match,
       -- ranges counted ONCE per ASN, because several pairings can share one
       -- ip-api name: CenturyLink Communications, LLC appears four times,
       -- once per Lumen brand, and its 91,251 ranges are not four times that
       (SELECT coalesce(sum(z.r), 0) FROM
          (SELECT DISTINCT a.asn, a.zip_capable_ranges AS r
           FROM ipapi_asn_tbl a
           WHERE EXISTS (SELECT 1 FROM carrier_alias_review_tbl v
                         WHERE v.caveat = ''
                           AND v.ipapi_key = carrier_name_compact(a.as_operator))) z)
                                                                  AS zip_capable_ranges_waiting;

\echo
\echo Writing the file. Put y or n in the last column and load it back with
\echo load_alias_decisions.sql. Rows left blank stay proposed.
\echo
\copy (SELECT ipapi_side, bdc_side, asns_with_that_name, zip_capable_ranges, brand_wireline_tracts, caveat, note, decision FROM carrier_alias_review_tbl ORDER BY zip_capable_ranges DESC, ipapi_side, bdc_side) TO '/home/boris/geo/carrier_alias_approval.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
