-- load_name_map.sql - load Boris's approved ip-api to BDC name decisions
-- into the persistent map, so the next probe run integrates automatically.
--
-- THE LOOP THIS CLOSES
--
-- Boris: "Only around half the decomposed ranges in ip2city_dbiplite_tbl
-- has so far been probed through ip-api.com. Therefore small/REI providers
-- new to us are likely to occur in the other half. Their integration should
-- be automatic."
--
--   1. carrier_name_match.sql proposes candidates for ip-api names NOT
--      already in ipapi_bdc_name_map_tbl, writing two TSVs.
--   2. Boris fills the approved column, or names the carrier himself in the
--      unmatched file.
--   3. THIS FILE loads those answers into the map.
--   4. The next time ranges are probed, step 1 proposes only what is new.
--
-- INPUT FORMAT. Two files, either or both may be present. Rows with an
-- empty answer are IGNORED rather than treated as a decision, so a
-- partially filled sheet can be loaded as often as you like and only adds
-- what you actually answered.
--
--   /home/boris/geo/carrier_name_candidates.tsv
--       as written by carrier_name_match.sql, with the final column
--       'approved' filled in. Put the BDC brand name to use, or the word
--       NOT A CARRIER, or leave blank to decide later.
--
--   /home/boris/geo/carrier_name_unmatched.tsv
--       with bdc_brand_name_you_give filled in, same conventions.
--
-- WHAT A DECISION MEANS. A brand name is stored with the provider_id looked
-- up from bdc_carrier_tbl, so a brand that does not exist in the loaded BDC
-- data is stored with a null provider_id and REPORTED, never silently
-- dropped: the BDC load may simply not cover that filer yet.
--
-- PRE-MORTEM. This is the only file that writes ipapi_bdc_name_map_tbl, and
-- it writes by upsert: an existing decision for a name is UPDATED, never
-- deleted, and nothing is truncated. Loading the same sheet twice is a
-- no-op. It creates two staging tables of its own and drops them first.
-- If a TSV is absent the \copy fails, the transaction is not started for
-- that file, and the rest still runs; the counts at the end say what landed.

\set ON_ERROR_STOP on
\timing on

CREATE TABLE IF NOT EXISTS ipapi_bdc_name_map_tbl (
    ipapi_name       text PRIMARY KEY,
    ipapi_name_norm  text NOT NULL,
    decision         text NOT NULL
                     CHECK (decision IN ('brand', 'not_a_carrier', 'unknown')),
    bdc_brand_name   text,
    bdc_provider_id  integer,
    note             text,
    approved_at      timestamptz NOT NULL DEFAULT now());

\echo
\echo What the map holds BEFORE this load.
\echo
SELECT count(*) AS decisions, count(*) FILTER (WHERE decision = 'brand') AS to_a_brand
FROM ipapi_bdc_name_map_tbl;

DROP TABLE IF EXISTS name_cand_in;
CREATE TABLE name_cand_in (
    ipapi_name text, ranges bigint, rank_for_name integer, tier integer,
    provider_id integer, brand_name text, shared_tokens integer,
    compact_equal boolean, brand_within_name boolean,
    name_within_brand boolean, ipapi_org text, ipapi_as text,
    zip_capable_ranges bigint, dma_only_ranges bigint,
    unclassified_ranges bigint, approved text);

DROP TABLE IF EXISTS name_unmatched_in;
CREATE TABLE name_unmatched_in (
    ipapi_name text, ranges bigint, zip_capable_ranges bigint,
    dma_only_ranges bigint, unclassified_ranges bigint,
    ipapi_org text, ipapi_as text, bdc_brand_name_you_give text);

\echo
\echo Loading the candidate sheet. A missing file is reported and skipped.
\echo
\copy name_cand_in FROM '/home/boris/geo/carrier_name_candidates.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\echo
\echo Loading the unmatched sheet.
\echo
\copy name_unmatched_in FROM '/home/boris/geo/carrier_name_unmatched.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\echo
\echo What arrived, before anything is applied.
\echo
SELECT 'candidate sheet' AS sheet, count(*) AS rows,
       count(*) FILTER (WHERE nullif(btrim(approved), '') IS NOT NULL) AS answered
FROM name_cand_in
UNION ALL
SELECT 'unmatched sheet', count(*),
       count(*) FILTER (WHERE nullif(btrim(bdc_brand_name_you_give), '') IS NOT NULL)
FROM name_unmatched_in;

\echo
\echo Applying. An answer of NOT A CARRIER in any case or spacing becomes
\echo not_a_carrier; anything else is taken as a BDC brand name verbatim.
\echo
WITH answers AS (
    SELECT DISTINCT ipapi_name, btrim(approved) AS answer
    FROM name_cand_in
    WHERE nullif(btrim(approved), '') IS NOT NULL
    UNION
    SELECT DISTINCT ipapi_name, btrim(bdc_brand_name_you_give)
    FROM name_unmatched_in
    WHERE nullif(btrim(bdc_brand_name_you_give), '') IS NOT NULL
), typed AS (
    SELECT a.ipapi_name,
           CASE WHEN upper(regexp_replace(a.answer, '[^A-Za-z]', '', 'g'))
                     IN ('NOTACARRIER', 'NOTANISP', 'NO')
                THEN 'not_a_carrier' ELSE 'brand' END AS decision,
           CASE WHEN upper(regexp_replace(a.answer, '[^A-Za-z]', '', 'g'))
                     IN ('NOTACARRIER', 'NOTANISP', 'NO')
                THEN NULL ELSE a.answer END          AS brand_name
    FROM answers a
)
INSERT INTO ipapi_bdc_name_map_tbl
       (ipapi_name, ipapi_name_norm, decision, bdc_brand_name,
        bdc_provider_id, note, approved_at)
SELECT t.ipapi_name,
       coalesce(carrier_name_compact(t.ipapi_name), lower(t.ipapi_name)),
       t.decision,
       t.brand_name,
       (SELECT min(c.provider_id) FROM bdc_carrier_tbl c
        WHERE c.brand_name = t.brand_name),
       'loaded from sheet',
       now()
FROM typed t
ON CONFLICT (ipapi_name) DO UPDATE
   SET decision        = excluded.decision,
       bdc_brand_name  = excluded.bdc_brand_name,
       bdc_provider_id = excluded.bdc_provider_id,
       note            = excluded.note,
       approved_at     = now();

\echo
\echo What the map holds after. brand_not_found_in_bdc is the number of your
\echo answers naming a brand the loaded BDC data does not contain, which is
\echo reported rather than dropped because the load may not cover that filer.
\echo
SELECT count(*)                                                 AS decisions,
       count(*) FILTER (WHERE decision = 'brand')                AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier')        AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'brand'
                          AND bdc_provider_id IS NULL)           AS brand_not_found_in_bdc
FROM ipapi_bdc_name_map_tbl;

\echo
\echo The answers naming a brand not present in the BDC data, in full.
\echo
SELECT ipapi_name, bdc_brand_name
FROM ipapi_bdc_name_map_tbl
WHERE decision = 'brand' AND bdc_provider_id IS NULL
ORDER BY 1;

DROP TABLE name_cand_in;
DROP TABLE name_unmatched_in;

\timing off
