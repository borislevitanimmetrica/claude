-- ===========================================================================
-- asn_match_fixture.sql
--
-- A fixture that REPRODUCES the three defects Boris found in the output of
-- carrier_asn_match.sql in the run he reported, so that the fix can be
-- shown to change the answer rather than asserted to.
--
--   DEFECT 1  The commonest name was not the commonest. The build grouped
--             the name combinations before taking mode(), which destroyed
--             the range counts, so the pick was arbitrary. Fixture: one ASN
--             carrying a rare name that sorts first and a common name that
--             sorts last. The old code picks the rare one.
--
--   DEFECT 2  Candidates were generated from the ip-api ISP name, which is
--             often the UPSTREAM carrier. Fixture: an enterprise ASN whose
--             ip-api ISP is a large carrier with a BDC brand. The old code
--             matched the enterprise to that carrier at tier 1.
--
--   DEFECT 3  A parent company name lands on the national brand of the
--             parent while the address space belongs to a subsidiary with a
--             small footprint. Boris 2026-11-22: Verizon owns Frontier.
--             The candidate is legitimate as a NAME match, so it must not be
--             silently dropped; it must be visibly flagged by footprint size.
--
-- Plus a control that must keep working: CABLE ONE, INC. to the brand
-- Cable One, which only survives because the compact key drops legal
-- suffixes and nothing else.
--
-- Run on the throwaway cluster, NOT on the production database:
--   sh /projects/sandbox/.pgtest/pgup.sh
--   . /projects/sandbox/.pgtest/pg.env
--   psql -f .../asn_match_fixture.sql
--   psql -f .../carrier_asn_match.sql
--   psql -f .../asn_match_assert.sql
-- ===========================================================================

\set ON_ERROR_STOP on

DROP TABLE IF EXISTS ip2city_dbiplite_probe_tbl;
CREATE TABLE ip2city_dbiplite_probe_tbl (
    range_id        bigserial PRIMARY KEY,
    isp             text,
    org             text,
    "as"            text,
    mobile_transit  varchar(1),
    ran_at          timestamptz);

DROP TABLE IF EXISTS bdc_carrier_tbl;
CREATE TABLE bdc_carrier_tbl (
    provider_id integer,
    brand_name  text,
    frn         text);

DROP TABLE IF EXISTS provider_brand_tract_tech_tbl;
CREATE TABLE provider_brand_tract_tech_tbl (
    provider_id integer,
    brand_name  text,
    technology  integer,
    tract_geoid text);

-- ---------------------------------------------------------------------------
-- BDC side. provider_id and brand are the real grain.
-- ---------------------------------------------------------------------------
INSERT INTO bdc_carrier_tbl (provider_id, brand_name, frn) VALUES
 (900001, 'Verizon',    '0001000001'),
 (900002, 'Frontier',   '0001000002'),
 (900003, 'Windstream', '0001000003'),
 (900004, 'Cable One',  '0001000004'),
 (900005, 'Zebra Telephone Company', '0001000005'),
 (900006, 'Aardvark Telephone Co',   '0001000006');

-- Footprints. Verizon is national, everyone else is small. 1000 tracts in
-- the fixture universe, so the shares are readable.
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900001, 'Verizon', 50, lpad(g::text, 11, '0') FROM generate_series(1, 900) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900002, 'Frontier', 50, lpad(g::text, 11, '0') FROM generate_series(1, 40) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900003, 'Windstream', 10, lpad(g::text, 11, '0') FROM generate_series(100, 160) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900004, 'Cable One', 40, lpad(g::text, 11, '0') FROM generate_series(200, 230) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900005, 'Zebra Telephone Company', 10, lpad(g::text, 11, '0') FROM generate_series(300, 312) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900006, 'Aardvark Telephone Co', 10, lpad(g::text, 11, '0') FROM generate_series(400, 407) g;
-- Tracts nobody serves, so the denominator is 1000 and not 900.
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900004, 'Cable One', 40, lpad(g::text, 11, '0') FROM generate_series(901, 1000) g;

-- ---------------------------------------------------------------------------
-- DEFECT 1. AS99001. One probed range says Aardvark, fifty say Zebra.
-- Aardvark sorts first, so mode() over the DISTINCT combinations returns it.
-- ---------------------------------------------------------------------------
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
VALUES ('Aardvark Telephone', 'Aardvark Telephone', 'AS99001 Aardvark Telephone Co', 'f', now());

INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Zebra Telephone', 'Zebra Telephone', 'AS99001 Zebra Telephone Company', 'f', now()
FROM generate_series(1, 50);

-- ---------------------------------------------------------------------------
-- DEFECT 2. AS99002 is an enterprise. Its registry name matches no brand.
-- ip-api reports its ISP as its upstream carrier, which does have a brand.
-- ---------------------------------------------------------------------------
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Windstream Communications', 'Amazon.com', 'AS99002 Amazon.com, Inc.', 'f', now()
FROM generate_series(1, 400);

-- ---------------------------------------------------------------------------
-- DEFECT 3. AS99003 is the former Frontier, now carrying the name of its
-- parent. Both Verizon and Frontier exist as brands. Verizon is national.
-- ---------------------------------------------------------------------------
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Frontier Communications', 'Frontier Communications', 'AS99003 Verizon Business', 'f', now()
FROM generate_series(1, 120);

-- ---------------------------------------------------------------------------
-- CONTROL. Must still match at tier 1.
-- ---------------------------------------------------------------------------
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Cable One', 'Cable One', 'AS99004 CABLE ONE, INC.', 'f', now()
FROM generate_series(1, 70);

-- A mobile ASN, to prove the ZIP-capable and DMA-only counts stay apart.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Cable One Mobile', 'Cable One', 'AS99004 CABLE ONE, INC.', 'm', now()
FROM generate_series(1, 30);

-- An unprobed row, which must be excluded everywhere.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
VALUES ('Never Probed', 'Never Probed', 'AS99005 Never Probed Inc', NULL, NULL);

ANALYZE ip2city_dbiplite_probe_tbl;
ANALYZE bdc_carrier_tbl;
ANALYZE provider_brand_tract_tech_tbl;

\echo
\echo Fixture loaded. Probed ranges by ASN:
\echo
SELECT "as", mobile_transit, count(*)
FROM ip2city_dbiplite_probe_tbl WHERE ran_at IS NOT NULL
GROUP BY 1, 2 ORDER BY 1, 2;
