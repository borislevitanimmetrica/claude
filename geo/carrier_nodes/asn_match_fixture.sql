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
 (900006, 'Aardvark Telephone Co',   '0001000006'),
 (900007, 'Skyhook Wireless Co',     '0001000007'),
 -- The trade-name case. No string method can join the ip-api operator name
 -- Comcast Cable Communications, LLC to the brand Xfinity, which is why
 -- AS7922 sits at the head of Boris's no-candidate list with 187,553
 -- ZIP-capable ranges behind it. Only carrier_entity.sql can join them.
 (900008, 'Xfinity',                 '0001000008');

-- Footprints. 1000 tracts in the fixture universe, so shares are readable.
--
-- Verizon is modelled the way Boris's data actually behaves: a MODEST
-- wireline footprint and a near-total licensed fixed wireless one. That is
-- what makes a pooled, all-technology share meaningless, and it is the
-- arithmetic that refutes my claim of a 97% national wireline footprint.
-- Pooled, this brand reaches 100% of the fixture. On FTTP it reaches 30%.
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900001, 'Verizon', 50, lpad(g::text, 11, '0') FROM generate_series(1, 300) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900001, 'Verizon', 71, lpad(g::text, 11, '0') FROM generate_series(1, 1000) g;

-- Frontier is DISJOINT from Verizon on FTTP, which is the real geography:
-- Frontier's territory is ex-Verizon territory, divested by Verizon in 2010
-- (14 mostly rural states) and 2016 (the California, Florida and Texas GTE
-- properties). Verizon kept the northeast. The 2026 re-acquisition therefore
-- EXTENDS Verizon's footprint into counties where Verizon had no plant
-- rather than absorbing a competitor standing on the same streets.
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900002, 'Frontier', 50, lpad(g::text, 11, '0') FROM generate_series(501, 540) g;

-- A brand with licensed fixed wireless and NOTHING ELSE. Its name matches an
-- ASN perfectly and there is still nothing here to select on, because
-- technologies 70, 71 and 72 cannot be targeted at ZIP level.
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900007, 'Skyhook Wireless Co', 71, lpad(g::text, 11, '0') FROM generate_series(1, 800) g;

INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900008, 'Xfinity', 40, lpad(g::text, 11, '0') FROM generate_series(600, 820) g;
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

-- DEFECT 3b. A perfect name match to a brand that has licensed fixed
-- wireless and no wireline plant. Nothing to select on, and the old pooled
-- percentage made it look like an 80% national footprint.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Skyhook Wireless', 'Skyhook Wireless', 'AS99006 Skyhook Wireless Co', 'f', now()
FROM generate_series(1, 200);

-- TRANSIT, NOT OWNERSHIP. A small carrier whose ip-api ISP name is the
-- registry name of a LARGER ASN. The disagreement report must produce the
-- row and mark it transit, because the suggested brand is the wrong answer.
-- On Boris's 2026-11-22 run five small carriers pointed at Cogent this way
-- and two at AT&T. AS99001 Zebra carries 51 ranges against these 20, and its
-- operator name compacts to the same key as this ISP name.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Zebra Telephone', 'Aardvark Telephone',
       'AS99008 Aardvark Telephone Co', 'f', now()
FROM generate_series(1, 20);

-- THE TRADE NAME. Must produce no candidate from any string rule, and must
-- be reachable through the entity layer.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Comcast Cable Communications', 'Comcast',
       'AS99007 Comcast Cable Communications, LLC', 'f', now()
FROM generate_series(1, 900);

ANALYZE ip2city_dbiplite_probe_tbl;
ANALYZE bdc_carrier_tbl;
ANALYZE provider_brand_tract_tech_tbl;

\echo
\echo Fixture loaded. Probed ranges by ASN:
\echo
SELECT "as", mobile_transit, count(*)
FROM ip2city_dbiplite_probe_tbl WHERE ran_at IS NOT NULL
GROUP BY 1, 2 ORDER BY 1, 2;
