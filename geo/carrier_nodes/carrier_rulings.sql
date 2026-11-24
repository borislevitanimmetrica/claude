-- ===========================================================================
-- carrier_rulings.sql
--
-- Boris's one-off per-ASN rulings, and the removal of decisions that the
-- carrier-universe restriction invalidates.
--
-- THIS FILE DELETES ROWS FROM asn_bdc_brand_map_tbl. Read the pre-mortem.
--
-- WHAT IT DELETES
--   Rows with decision = 'brand' whose ASN is held by a party that is NOT in
--   carrier_universe_tbl. Boris 2026-11-22: "Restrict carriers to the
--   superset of those sources and do not process the rest." Those rows were
--   written by load_entity_decisions.sql and load_candidate_decisions.sql on
--   2026-11-22 and are wrong: 1-800-Flowers at ASNs 20190 and 54986 was
--   mapped to Comcast and Verizon plant because ip-api reports its upstream
--   carrier as its ISP.
--
-- WHAT IT CANNOT DELETE, AND THIS IS ENFORCED
--   Any row with decision in ('not_a_carrier', 'out_of_scope'). Those are
--   Boris's own 151 rulings and no automatic process may touch them. The
--   DELETE is restricted to decision = 'brand' and the count of the other
--   two is asserted unchanged afterwards, aborting if it moved.
--
-- WHAT IS LOST IF THIS IS WRONG
--   Only machine-written brand decisions, all of which are reproducible by
--   re-running the two loaders. Nothing hand-entered is reachable. Every row
--   is nevertheless written to a file BEFORE deletion so it can be inspected
--   or reloaded:  /home/boris/geo/carrier_map_removed.tsv
--
-- RULINGS WRITTEN
--   AS5650, 46690, 3593, 26127, 32587, 7011 -> Verizon.
--     Boris 2026-11-22: "Verizon rather than Frontier, although Frontier
--     wouldn't disrupt the plan." These are the former Frontier ASNs whose
--     registry name followed the 20 January 2026 acquisition.
--   AS20190, AS54986 -> not_a_carrier.
--     Boris 2026-11-22: 1-800-Flowers is not a carrier and is out of scope.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_rulings.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('asn_bdc_brand_map_tbl'), ('carrier_universe_tbl'),
                 ('ipapi_asn_tbl'), ('bdc_carrier_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_asn_match.sql first. Nothing was changed.', missing;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint con
               JOIN pg_class rel ON rel.oid = con.conrelid
               WHERE rel.relname = 'asn_bdc_brand_map_tbl' AND con.contype = 'p') THEN
        RAISE EXCEPTION 'asn_bdc_brand_map_tbl still has a primary key on asn. Run asn_map_multibrand_migration.sql first. Nothing was changed.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- ---------------------------------------------------------------------------
-- 1. The rulings. Written before the cleanup so the Verizon decisions are in
--    place and the six ASNs are not then examined by it.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS carrier_ruling_seed_tbl;
CREATE TABLE carrier_ruling_seed_tbl (
    asn        bigint NOT NULL,
    decision   text   NOT NULL,
    brand_name text,
    note       text   NOT NULL);

INSERT INTO carrier_ruling_seed_tbl VALUES
 (5650,  'brand', 'Verizon', 'Boris 2026-11-22: Verizon rather than Frontier, although Frontier would not disrupt the plan. Former Frontier ASN; the registry name followed the 20 January 2026 acquisition.'),
 (46690, 'brand', 'Verizon', 'Boris 2026-11-22: Verizon rather than Frontier. Former Frontier ASN.'),
 (3593,  'brand', 'Verizon', 'Boris 2026-11-22: Verizon rather than Frontier. Former Frontier ASN.'),
 (26127, 'brand', 'Verizon', 'Boris 2026-11-22: Verizon rather than Frontier. Former Frontier ASN.'),
 (32587, 'brand', 'Verizon', 'Boris 2026-11-22: Verizon rather than Frontier. Former Frontier ASN.'),
 (7011,  'brand', 'Verizon', 'Boris 2026-11-22: Verizon rather than Frontier. Former Frontier ASN.'),
 (20190, 'not_a_carrier', NULL, 'Boris 2026-11-22: 1-800-Flowers is not a carrier and is out of scope. It reached Comcast because ip-api reports its upstream carrier as its ISP.'),
 (54986, 'not_a_carrier', NULL, 'Boris 2026-11-22: 1-800-Flowers is not a carrier and is out of scope. It reached Verizon the same way.');

\echo
\echo The ASNs these rulings name, as they stand now.
\echo
SELECT s.asn, left(a.as_operator, 34) AS as_operator,
       left(coalesce(a.isp_commonest, ''), 28) AS ipapi_isp,
       s.decision, s.brand_name AS ruled_brand,
       a.zip_capable_ranges,
       (SELECT string_agg(DISTINCT coalesce(m.bdc_brand_name, m.decision), ' | ')
        FROM asn_bdc_brand_map_tbl m WHERE m.asn = s.asn) AS currently_mapped_to
FROM carrier_ruling_seed_tbl s
LEFT JOIN ipapi_asn_tbl a ON a.asn = s.asn
ORDER BY a.zip_capable_ranges DESC NULLS LAST, s.asn;

-- The Verizon rulings replace whatever brand those six ASNs hold.
DELETE FROM asn_bdc_brand_map_tbl m
WHERE m.decision = 'brand'
  AND EXISTS (SELECT 1 FROM carrier_ruling_seed_tbl s
              WHERE s.asn = m.asn AND s.decision = 'brand');

-- A not_a_carrier ruling removes any brand the ASN held.
DELETE FROM asn_bdc_brand_map_tbl m
WHERE m.decision = 'brand'
  AND EXISTS (SELECT 1 FROM carrier_ruling_seed_tbl s
              WHERE s.asn = m.asn AND s.decision = 'not_a_carrier');

INSERT INTO asn_bdc_brand_map_tbl
       (asn, decision, bdc_brand_name, bdc_provider_id, note)
SELECT s.asn, s.decision, s.brand_name, b.provider_id, s.note
FROM carrier_ruling_seed_tbl s
LEFT JOIN (SELECT DISTINCT brand_name, provider_id FROM bdc_carrier_tbl
           WHERE brand_name IS NOT NULL) b
  ON s.brand_name IS NOT NULL
 AND carrier_name_compact(b.brand_name) = carrier_name_compact(s.brand_name)
WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                  WHERE m.asn = s.asn
                    AND coalesce(m.bdc_brand_name, '') = coalesce(s.brand_name, '')
                    AND m.decision = s.decision);

\echo
\echo The rulings as written.
\echo
SELECT m.asn, m.decision, m.bdc_brand_name, m.bdc_provider_id
FROM asn_bdc_brand_map_tbl m
WHERE m.asn IN (SELECT asn FROM carrier_ruling_seed_tbl)
ORDER BY m.asn, m.bdc_brand_name;

-- ---------------------------------------------------------------------------
-- 2. The cleanup. Backed up to a file first, then deleted, then verified.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- THE CLEANUP WILL NOT RUN WITHOUT THE FORM 499a LIST. IT BLOCKS.
--
-- The cleanup deletes brand decisions for holders that are not in the carrier
-- universe. Since 2026-11-23 the universe admits a name only on a COMPLETE
-- match or a pairing Boris has confirmed, which is what he asked for, and
-- that makes the universe only as complete as the name lists behind it.
--
-- BDC brand names alone are not enough. AT&T Enterprises, LLC is the holder
-- of AS7018 and 263,102 ZIP-capable ranges, and it is not a BDC brand; it is
-- a Form 499a FILER, which is a different list and the reason he supplied the
-- file. Running the cleanup without that list would delete AS7018 again,
-- along with the 768 others it took on 2026-11-22.
--
-- So this refuses to delete anything until the list is loaded. The rulings
-- above this point are unaffected: they are explicit and are already written.
-- ---------------------------------------------------------------------------
DO $need499$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'fcc499_filer_tbl') THEN
        RAISE EXCEPTION 'fcc499_filer_tbl is not loaded, so the carrier universe holds BDC brand names only and does not know the legal names of carriers such as AT&T Enterprises, LLC. The cleanup would delete AS7018 and its 263,102 ranges exactly as it did on 2026-11-22. NOTHING WAS DELETED. Load the filer list first: python3 /home/boris/geo/src/claude/geo/carrier_nodes/xlsx_dump.py --table fcc499_filer_tbl --out /home/boris/geo/fcc499_filers.tsv --sql /home/boris/geo/load_fcc499.sql /home/boris/geo/FCC_Form_499a_filers.xlsx';
    END IF;
    RAISE NOTICE 'Form 499a filer list is present, so the universe knows legal names as well as brand names';
END
$need499$;

DROP TABLE IF EXISTS carrier_map_doomed_tbl;
CREATE TABLE carrier_map_doomed_tbl AS
SELECT m.asn, a.as_operator, a.isp_commonest, m.decision,
       m.bdc_brand_name, m.bdc_provider_id, a.zip_capable_ranges, m.note
FROM asn_bdc_brand_map_tbl m
JOIN ipapi_asn_tbl a ON a.asn = m.asn
WHERE m.decision = 'brand'
  AND NOT carrier_name_in_universe(a.as_operator);

ANALYZE carrier_map_doomed_tbl;

-- ---------------------------------------------------------------------------
-- THE GUARD THAT SHOULD HAVE BEEN HERE THE FIRST TIME. IT BLOCKS.
--
-- A brand decision is only safe to delete if the holder of the ASN really is
-- not a carrier. If the operator name SCORES TIER 1 OR 2 against the very
-- brand it is mapped to, then the matcher would make that match again, and
-- the only way both facts can hold is that the universe test is stricter
-- than the matcher. That is not a reason to delete the row; it is a defect
-- in the universe test.
--
-- This is not hypothetical. The 2026-11-22 run deleted 769 brand decisions
-- covering 736 ASNs and 373,410 ZIP-capable ranges, among them AS7018
-- AT&T Enterprises, LLC mapped to the brand AT&T at 263,102 ranges, because
-- the universe test compared compact keys: attenterprises against att. Every
-- one of those rows would have tripped this guard.
--
-- It raises rather than reporting, because by the time a report is read the
-- rows are gone. The deleted rows of that run are in
-- /home/boris/geo/carrier_map_removed.tsv and are recreated by rerunning
-- carrier_asn_match.sql and the two loaders.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
    n       bigint;
    worst   text;
BEGIN
    SELECT count(*) INTO n FROM carrier_map_doomed_tbl d
    WHERE d.bdc_brand_name IS NOT NULL
      AND carrier_name_tier(d.as_operator, d.bdc_brand_name) IN (1, 2);

    IF n > 0 THEN
        SELECT string_agg(format('AS%s %s mapped to %s at tier %s, %s ranges',
                                 d.asn, d.as_operator, d.bdc_brand_name,
                                 carrier_name_tier(d.as_operator, d.bdc_brand_name),
                                 coalesce(d.zip_capable_ranges, 0)),
                          E'\n' ORDER BY d.zip_capable_ranges DESC NULLS LAST)
          INTO worst
        FROM (SELECT * FROM carrier_map_doomed_tbl d2
              WHERE d2.bdc_brand_name IS NOT NULL
                AND carrier_name_tier(d2.as_operator, d2.bdc_brand_name) IN (1, 2)
              ORDER BY d2.zip_capable_ranges DESC NULLS LAST
              LIMIT 10) d;

        RAISE EXCEPTION E'THE CLEANUP WOULD DELETE CORRECT MATCHES: % rows. NOTHING WAS DELETED.\nEach of these ASNs is mapped to a brand that its own operator name matches at tier 1 or 2, so the matcher agrees with the mapping while carrier_name_in_universe says the holder is not a carrier. The universe test is wrong, not the mapping. Largest:\n%', n, worst;
    END IF;
    RAISE NOTICE 'guard passed: no doomed row is a match the name rule would make again';
END
$guard$;

\echo
\echo ABOUT TO DELETE. Every one of these is a brand decision for an ASN whose
\echo holder is not in the carrier universe. Hand-entered not_a_carrier and
\echo out_of_scope rulings are unreachable from this statement.
\echo
SELECT count(*)                            AS rows_to_delete,
       count(DISTINCT asn)                 AS asns,
       sum(zip_capable_ranges)             AS zip_capable_ranges_affected
FROM carrier_map_doomed_tbl;

SELECT asn, left(as_operator, 36) AS as_operator,
       left(coalesce(isp_commonest, ''), 26) AS ipapi_isp,
       left(coalesce(bdc_brand_name, ''), 22) AS was_mapped_to,
       zip_capable_ranges
FROM carrier_map_doomed_tbl
ORDER BY zip_capable_ranges DESC NULLS LAST, asn
LIMIT 40;

\echo
\echo Backing them up before deleting.
\echo
\copy (SELECT asn, as_operator, isp_commonest, decision, bdc_brand_name, bdc_provider_id, zip_capable_ranges, note FROM carrier_map_doomed_tbl ORDER BY zip_capable_ranges DESC NULLS LAST, asn) TO '/home/boris/geo/carrier_map_removed.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

DO $cleanup$
DECLARE
    rulings_before bigint;
    rulings_after  bigint;
    removed        bigint;
BEGIN
    SELECT count(*) INTO rulings_before FROM asn_bdc_brand_map_tbl
    WHERE decision IN ('not_a_carrier', 'out_of_scope');

    DELETE FROM asn_bdc_brand_map_tbl m
    WHERE m.decision = 'brand'
      AND EXISTS (SELECT 1 FROM carrier_map_doomed_tbl d
                  WHERE d.asn = m.asn
                    AND coalesce(d.bdc_brand_name, '') = coalesce(m.bdc_brand_name, '')
                    AND coalesce(d.bdc_provider_id, 0) = coalesce(m.bdc_provider_id, 0));
    GET DIAGNOSTICS removed = ROW_COUNT;

    SELECT count(*) INTO rulings_after FROM asn_bdc_brand_map_tbl
    WHERE decision IN ('not_a_carrier', 'out_of_scope');

    IF rulings_after <> rulings_before THEN
        RAISE EXCEPTION 'THE CLEANUP TOUCHED YOUR OWN RULINGS: % before, % after. Rolled back.', rulings_before, rulings_after;
    END IF;
    RAISE NOTICE 'removed % brand decisions; your % not_a_carrier and out_of_scope rulings are untouched', removed, rulings_after;
END
$cleanup$;

ANALYZE asn_bdc_brand_map_tbl;

\echo
\echo The decision map after the rulings and the cleanup.
\echo
SELECT count(*)                                           AS rows_held,
       count(DISTINCT asn)                                AS distinct_asns,
       count(*) FILTER (WHERE decision = 'brand')         AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier')  AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')   AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo Every remaining brand decision is for an ASN in the universe. Zero.
\echo
SELECT count(*) AS brand_decisions_outside_the_universe
FROM asn_bdc_brand_map_tbl m
JOIN ipapi_asn_tbl a ON a.asn = m.asn
WHERE m.decision = 'brand' AND NOT carrier_name_in_universe(a.as_operator);

\echo
\echo Probed ZIP-capable address space, by what is known about it.
\echo
SELECT (SELECT sum(z.r) FROM (SELECT DISTINCT a.asn, a.zip_capable_ranges AS r
          FROM ipapi_asn_tbl a JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
          WHERE m.decision = 'brand') z)                   AS mapped_to_a_brand,
       (SELECT sum(z.r) FROM (SELECT DISTINCT a.asn, a.zip_capable_ranges AS r
          FROM ipapi_asn_tbl a JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
          WHERE m.decision IN ('not_a_carrier','out_of_scope')) z) AS retired,
       (SELECT sum(a.zip_capable_ranges) FROM ipapi_asn_tbl a
        WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                          WHERE m.asn = a.asn)
          AND carrier_name_in_universe(a.as_operator))      AS undecided_carriers,
       (SELECT sum(a.zip_capable_ranges) FROM ipapi_asn_tbl a
        WHERE NOT carrier_name_in_universe(a.as_operator))  AS not_carriers,
       (SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl)   AS all_probed;

\timing off
