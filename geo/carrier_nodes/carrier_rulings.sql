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
      -- 1, 2 AND 3. Tier 3 is included since 2026-11-23, when a match became
      -- a complete name match or a pairing he confirmed and nothing else.
      -- AT&T Enterprises, LLC against the brand AT&T is now tier 3, a shared
      -- word, and it is exactly the row this cleanup must not delete: 263,102
      -- ranges whose only defect is that nobody has ruled on the pairing yet.
      AND carrier_name_tier(d.as_operator, d.bdc_brand_name) IN (1, 2, 3);

    IF n > 0 THEN
        SELECT string_agg(format('AS%s %s mapped to %s at tier %s, %s ranges',
                                 d.asn, d.as_operator, d.bdc_brand_name,
                                 carrier_name_tier(d.as_operator, d.bdc_brand_name),
                                 coalesce(d.zip_capable_ranges, 0)),
                          E'\n' ORDER BY d.zip_capable_ranges DESC NULLS LAST)
          INTO worst
        FROM (SELECT * FROM carrier_map_doomed_tbl d2
              WHERE d2.bdc_brand_name IS NOT NULL
                AND carrier_name_tier(d2.as_operator, d2.bdc_brand_name) IN (1, 2, 3)
              ORDER BY d2.zip_capable_ranges DESC NULLS LAST
              LIMIT 10) d;

        RAISE EXCEPTION E'THE CLEANUP WOULD DELETE CORRECT MATCHES: % rows. NOTHING WAS DELETED.\nEach of these ASNs is mapped to a brand that its own operator name matches at tier 1 or 2, so the matcher agrees with the mapping while carrier_name_in_universe says the holder is not a carrier. The universe test is wrong, not the mapping. Largest:\n%', n, worst;
    END IF;
    RAISE NOTICE 'guard passed: no doomed row is a match the name rule would make again';
END
$guard$;

-- ---------------------------------------------------------------------------
-- THE CLEANUP WILL NOT RUN WHILE A PAIRING IS UNRULED. IT BLOCKS.
--
-- I GOT THE REASON WRONG YESTERDAY AND THE FILE REFUTED ME. I wrote that
-- this guard was needed until fcc499_filer_tbl was loaded, "because AT&T
-- Enterprises, LLC is a Form 499a legal name". Measured on the real file on
-- 2026-11-24: it is not. The file holds 4,061 filers in four sections and
-- exactly two AT&T legal names, AT&T Corp. and AT&T Broadband Phone of
-- Virginia, Inc. Neither is AT&T Enterprises, LLC, which is the registry
-- name on AS7018 and its 263,102 ZIP-capable ranges.
--
-- Boris then pointed at AT&T Corp., and that name does solve a different
-- half of the problem: Corp. is a legal suffix, so AT&T Corp. compacts to
-- att, which is a COMPLETE match to the BDC brand AT&T. The brand is in the
-- universe on his own data. The HOLDER of AS7018 still is not.
--
-- So the real exposure is not a missing file. It is a pairing nobody has
-- ruled: carrier_alias_tbl holds rows with status proposed, which do not
-- match, and an ASN whose only route to its brand was one of those rows now
-- looks like a non-carrier holding a brand decision. That is precisely the
-- row this cleanup deletes. Blocking on unruled pairings is therefore the
-- guard that protects the 769 decisions; the 499a check stays as well,
-- because the universe is only as complete as the name lists behind it.
-- ---------------------------------------------------------------------------
DO $needrulings$
DECLARE
    missing_499 boolean;
    unruled     bigint;
    at_risk     bigint;
    worst       text;
BEGIN
    missing_499 := NOT EXISTS (SELECT 1 FROM information_schema.tables
                               WHERE table_name = 'fcc499_filer_tbl');
    IF missing_499 THEN
        RAISE EXCEPTION 'fcc499_filer_tbl is not loaded, so the carrier universe holds BDC brand names and nothing else, and every carrier that files with the FCC under a name no BDC brand repeats is outside it. NOTHING WAS DELETED. Load it first with: python3 /home/boris/geo/src/claude/geo/carrier_nodes/xlsx_dump.py --table fcc499_filer_tbl --out /home/boris/geo/fcc499_filers.tsv --sql /home/boris/geo/load_fcc499.sql /home/boris/geo/src/claude/geo/FCC_Form_499a_filers.xlsx';
    END IF;

    SELECT count(*) INTO unruled FROM carrier_alias_tbl WHERE status = 'proposed';

    SELECT count(*), string_agg(format('AS%s %s was mapped to %s, %s ranges',
                                  d.asn, d.as_operator, d.bdc_brand_name,
                                  coalesce(d.zip_capable_ranges, 0)),
                                E'\n' ORDER BY d.zip_capable_ranges DESC NULLS LAST)
      INTO at_risk, worst
    FROM carrier_map_doomed_tbl d
    WHERE EXISTS (SELECT 1 FROM carrier_alias_tbl x
                  WHERE x.status = 'proposed'
                    AND (x.ipapi_key = carrier_name_compact(d.as_operator)
                      OR x.bdc_key   = carrier_name_compact(d.as_operator)));

    IF at_risk > 0 THEN
        RAISE EXCEPTION E'% of the rows about to be deleted belong to a pairing you have not ruled on yet, so they are not evidence that the holder is a non-carrier. NOTHING WAS DELETED.\n%\nRule the % proposed pairing(s) in carrier_alias_tbl first; the list is printed by carrier_universe.sql.', at_risk, worst, unruled;
    END IF;

    IF unruled > 0 THEN
        RAISE NOTICE 'carrier_alias_tbl still holds % proposed pairing(s), none of which affects a row in this cleanup', unruled;
    END IF;
    RAISE NOTICE 'Form 499a filer list is present and no doomed row depends on an unruled pairing';
END
$needrulings$;

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
