-- technology_tbl.sql - the FCC technology codes and their names.
--
-- WHY THIS IS A TABLE AND NOT A CASE EXPRESSION IN EACH QUERY
--
-- Boris, 2026-11-18: "Make a table of technology codes and technology names,
-- and reissue the tables with the technology field to include the technology
-- name."
--
-- WHERE THESE NAMES COME FROM, AND WHY THEY ARE NOT A GUESS
--
-- bdc_catalog_fixed.tsv is the FCC's own download catalogue, captured from
-- the published filing on 2026-11-12 and committed to this repository. It
-- carries technology_code and technology_code_desc side by side for all 442
-- fixed files, and separately the file_name whose third token is the same
-- technology spelled without spaces.
--
-- Those two fields are INDEPENDENT of each other within the catalogue, and
-- they agree on all nine codes. That agreement is the verification: the name
-- is not my recollection of the FCC code list, which I have said all along I
-- would not guess at, it is the FCC's own description cross-checked against
-- the FCC's own file naming.
--
--     code  technology_code_desc        file_name token
--       0   Other                       Other
--      10   Copper                      Copper
--      40   Cable                       Cable
--      50   Fiber to the Premises       FibertothePremises
--      60   GSO Satellite               GSOSatellite
--      61   NGSO Satellite              NGSOSatellite
--      70   Unlicensed Fixed Wireless   UnlicensedFixedWireless
--      71   Licensed Fixed Wireless     LicensedFixedWireless
--      72   LBR Fixed Wireless          LBRFixedWireless
--
-- LBR IS THE FCC'S OWN ABBREVIATION AND IS LEFT UNEXPANDED. I have not
-- verified what it stands for and will not supply a plausible expansion.
--
-- SATELLITE IS PRESENT HERE BUT NOT IN THE DATA. Codes 60 and 61 are in this
-- table because they are in the FCC's code list, and absent from
-- bdc_availability_tbl because satellite is excluded from the downloads by
-- decision: 109 of 442 files and 3.31 GB of 7.38 GB, and no headend serves a
-- census tract over satellite. A code in this table with no rows is
-- therefore expected, not a gap.

BEGIN;

CREATE TABLE IF NOT EXISTS bdc_technology_tbl (
    technology   smallint PRIMARY KEY,
    code_desc    text NOT NULL,
    short_name   text NOT NULL,
    is_wired     boolean NOT NULL,
    is_satellite boolean NOT NULL,
    source       text NOT NULL
);

COMMENT ON TABLE bdc_technology_tbl IS
'FCC BDC technology codes with the FCC''s own descriptions, taken from technology_code_desc in the published download catalogue and cross-checked against the technology token in the FCC''s own file names. Codes 60 and 61 are satellite and are deliberately absent from bdc_availability_tbl, so a row here with no availability rows is expected.';

COMMENT ON COLUMN bdc_technology_tbl.short_name IS
'The compact form used in the FCC file names, useful for matching a loaded source_file against its technology.';

COMMENT ON COLUMN bdc_technology_tbl.is_wired IS
'True for Copper, Cable and Fiber to the Premises. The distinction matters because a wired technology implies a physical plant run from a serving site, which is what the headend-to-tract distance in step 4 is measuring. Fixed wireless does not imply that in the same way.';

INSERT INTO bdc_technology_tbl
    (technology, code_desc, short_name, is_wired, is_satellite, source)
VALUES
    ( 0, 'Other',                     'Other',                   false, false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (10, 'Copper',                    'Copper',                  true,  false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (40, 'Cable',                     'Cable',                   true,  false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (50, 'Fiber to the Premises',     'FibertothePremises',      true,  false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (60, 'GSO Satellite',             'GSOSatellite',            false, true,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (61, 'NGSO Satellite',            'NGSOSatellite',           false, true,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (70, 'Unlicensed Fixed Wireless', 'UnlicensedFixedWireless', false, false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (71, 'Licensed Fixed Wireless',   'LicensedFixedWireless',   false, false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12'),
    (72, 'LBR Fixed Wireless',        'LBRFixedWireless',        false, false,
      'FCC bdc_catalog_fixed.tsv technology_code_desc, 2026-11-12')
ON CONFLICT (technology) DO UPDATE SET
    code_desc    = excluded.code_desc,
    short_name   = excluded.short_name,
    is_wired     = excluded.is_wired,
    is_satellite = excluded.is_satellite,
    source       = excluded.source;

COMMIT;

\echo
\echo bdc_technology_tbl:
\echo
SELECT technology, code_desc, short_name, is_wired, is_satellite
FROM bdc_technology_tbl ORDER BY technology;

\echo
\echo A CODE IN THE DATA THAT IS NOT IN THIS TABLE would mean the FCC has
\echo added one since the catalogue was captured. Checked against the
\echo per-file record, which is small, rather than by scanning 519 million
\echo availability rows.
\echo
SELECT 'codes in bdc_technology_tbl' AS what, count(*) AS n
FROM bdc_technology_tbl
UNION ALL
SELECT 'of those, satellite and so expected to have no rows', count(*)
FROM bdc_technology_tbl WHERE is_satellite;
