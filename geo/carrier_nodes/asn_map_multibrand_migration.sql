-- ===========================================================================
-- asn_map_multibrand_migration.sql
--
-- Lets one ASN hold SEVERAL BDC brands.
--
-- Boris 2026-11-22: "each side of the table can contain variations. For
-- example, Comcast might appear in BDC as Comcast rather than Xfinity.
-- Charter and Spectrum are both used on the ip-api.com side depending on
-- proximity to the customer."
--
-- asn_bdc_brand_map_tbl was created with asn as the PRIMARY KEY, which makes
-- one brand per ASN a hard constraint and silently blocks exactly that. His
-- own run already showed the shape: AS7029 Windstream drew two correct
-- candidates, brand Windstream and brand "Windstream Communications,", and
-- the map as built could only have accepted one of them.
--
-- NON-DESTRUCTIVE. No row is deleted or changed. The primary key is replaced
-- by a unique index over the whole decision, so a second brand for the same
-- ASN becomes insertable while a duplicate of the same decision still
-- cannot. Re-runnable: it checks the current shape and does nothing if the
-- migration has already been applied.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/asn_map_multibrand_migration.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'asn_bdc_brand_map_tbl') THEN
        RAISE EXCEPTION 'asn_bdc_brand_map_tbl does not exist. Run carrier_asn_match.sql first. Nothing was changed.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

\echo
\echo What is in the map before the change.
\echo
SELECT count(*)                                           AS rows_held,
       count(DISTINCT asn)                                AS distinct_asns,
       count(*) FILTER (WHERE decision = 'brand')         AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier')  AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')   AS out_of_scope
FROM asn_bdc_brand_map_tbl;

DO $migrate$
DECLARE
    before_rows  bigint;
    after_rows   bigint;
    pk_name      text;
BEGIN
    SELECT count(*) INTO before_rows FROM asn_bdc_brand_map_tbl;

    SELECT con.conname INTO pk_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    WHERE rel.relname = 'asn_bdc_brand_map_tbl'
      AND con.contype = 'p'
      AND con.conkey = ARRAY[(SELECT att.attnum FROM pg_attribute att
                              WHERE att.attrelid = rel.oid
                                AND att.attname = 'asn')];

    IF pk_name IS NULL THEN
        RAISE NOTICE 'already migrated: no single-column primary key on asn. Nothing to do.';
    ELSE
        EXECUTE format('ALTER TABLE asn_bdc_brand_map_tbl DROP CONSTRAINT %I', pk_name);
        RAISE NOTICE 'dropped the single-column primary key %', pk_name;
    END IF;

    -- One row per distinct decision. The coalesce is what lets a
    -- not_a_carrier row, which carries no brand, coexist with the unique
    -- index without needing a partial index.
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'asn_bdc_brand_map_uq') THEN
        CREATE UNIQUE INDEX asn_bdc_brand_map_uq ON asn_bdc_brand_map_tbl
            (asn, coalesce(bdc_brand_name, ''), coalesce(bdc_provider_id, 0));
        RAISE NOTICE 'created the composite unique index';
    ELSE
        RAISE NOTICE 'composite unique index already present';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'asn_bdc_brand_map_asn_ix') THEN
        CREATE INDEX asn_bdc_brand_map_asn_ix ON asn_bdc_brand_map_tbl (asn);
        RAISE NOTICE 'created the lookup index on asn';
    END IF;

    SELECT count(*) INTO after_rows FROM asn_bdc_brand_map_tbl;
    IF after_rows <> before_rows THEN
        RAISE EXCEPTION 'MIGRATION LOST ROWS: % before, % after. This should be impossible; nothing in this file deletes.', before_rows, after_rows;
    END IF;
    RAISE NOTICE 'all % rows preserved', after_rows;
END
$migrate$;

ANALYZE asn_bdc_brand_map_tbl;

COMMENT ON TABLE asn_bdc_brand_map_tbl IS
'Boris-approved mapping from an AS number to the BDC brands whose plant that address space serves. SEVERAL ROWS PER ASN ARE ALLOWED and are the normal case, because a carrier files under several brand spellings: Boris 2026-11-22, Comcast may appear in BDC as Comcast as well as Xfinity. The ASN is the key on the ip-api side because it is the only hard identifier there. PERSISTENT: carrier_asn_match.sql never drops or truncates it and proposes candidates only for ASNs absent from it, which is what makes a new carrier integrate automatically as the rest of the decomposed ranges are probed. decision out_of_scope records a real network whose customers are all institutions, which ip-api already places at the institution; not_a_carrier records an enterprise, cloud or host located at its own premises.';

-- ---------------------------------------------------------------------------
-- Contradictions. An ASN cannot be both a carrier and not one. This is a
-- report rather than a constraint, because the fix is a judgement.
-- ---------------------------------------------------------------------------
\echo
\echo ASNs holding contradictory decisions. Should be empty.
\echo
SELECT asn,
       string_agg(DISTINCT decision, ', ' ORDER BY decision) AS decisions,
       count(*) AS rows_held
FROM asn_bdc_brand_map_tbl
GROUP BY asn
HAVING count(DISTINCT decision) > 1
ORDER BY asn;

\echo
\echo ASNs now holding more than one brand, which the old primary key made
\echo impossible.
\echo
SELECT asn, count(*) AS brands,
       string_agg(bdc_brand_name, ' | ' ORDER BY bdc_brand_name) AS brand_names
FROM asn_bdc_brand_map_tbl
WHERE decision = 'brand'
GROUP BY asn
HAVING count(*) > 1
ORDER BY count(*) DESC, asn
LIMIT 30;

\echo
\echo Final shape.
\echo
SELECT count(*) AS rows_held, count(DISTINCT asn) AS distinct_asns
FROM asn_bdc_brand_map_tbl;

\timing off
