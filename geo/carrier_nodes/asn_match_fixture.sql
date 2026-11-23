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

-- ---------------------------------------------------------------------------
-- A BLOCKING GUARD, BECAUSE THIS FILE IS DESTRUCTIVE.
--
-- It replaces the probe table, the BDC tables and, below, the persistent
-- decision tables. Run against the production database it would destroy
-- every approval Boris has given. The header has always said throwaway
-- cluster only; a sentence in a header does not stop anything.
--
-- The test is evidence rather than a name: the production probe table holds
-- on the order of two million probed ranges, measured 2026-11-22 at
-- 1,880,420 ZIP-capable ranges across 19,909 ASNs. A fixture database holds
-- a few hundred rows. Anything above ten thousand is not a fixture database
-- and this file refuses to touch it.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE n bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_name = 'ip2city_dbiplite_probe_tbl') THEN
        EXECUTE 'SELECT count(*) FROM ip2city_dbiplite_probe_tbl' INTO n;
        IF n > 10000 THEN
            RAISE EXCEPTION 'ip2city_dbiplite_probe_tbl holds % rows, so this is not a fixture database. This file DROPS the probe table, the BDC tables and the decision tables. Nothing was changed.', n;
        END IF;
        RAISE NOTICE 'existing probe table has % rows, treating this as a fixture database', n;
    END IF;
END
$guard$;

-- The persistent tables, dropped so that each fixture run starts from
-- nothing. They survive by design in production: asn_bdc_brand_map_tbl holds
-- Boris's approvals and carrier_unrelated_tbl holds his rulings, and both are
-- created with IF NOT EXISTS so a rerun never loses them. In the fixture that
-- same persistence is a defect. Leftover rows from an earlier run suppressed
-- AS99001, AS99004 and AS99008 from the candidate queue, because an ASN that
-- is already decided is not offered again, and three assertions failed
-- against code that was correct. Found 2026-11-23.
DROP TABLE IF EXISTS asn_bdc_brand_map_tbl;
DROP TABLE IF EXISTS carrier_unrelated_tbl;

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
 (900008, 'Xfinity',                 '0001000008'),
 -- DEFECT 4, the carrier universe. These two brands exist so that the
 -- fixture can hold an ASN whose operator name DOES match a brand under the
 -- tier rule while its compact key does NOT agree with any brand's. That is
 -- the shape of AS7018 AT&T on Boris's database: the operator name is
 -- AT&T Enterprises, LLC, compacting to attenterprises, and the brand is
 -- AT&T, compacting to att.
 (900009, 'Osprey',                  '0001000009'),
 (900010, 'Blue Osprey',             '0001000010'),
 -- DEFECT 5. A real carrier whose only informative token is a state name,
 -- so that the state government rule can be shown NOT to break it.
 (900011, 'Montana Communications',  '0001000011');

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
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900009, 'Osprey', 10, lpad(g::text, 11, '0') FROM generate_series(600, 617) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900010, 'Blue Osprey', 40, lpad(g::text, 11, '0') FROM generate_series(700, 711) g;
INSERT INTO provider_brand_tract_tech_tbl (provider_id, brand_name, technology, tract_geoid)
SELECT 900011, 'Montana Communications', 10, lpad(g::text, 11, '0') FROM generate_series(740, 752) g;
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

-- THE DIA CUSTOMER. An enterprise that buys transit from Comcast, so ip-api
-- reports its ISP as Comcast while the ASN is held by the enterprise. It
-- must NOT inherit Comcast plant. Boris 2026-11-22 found this as
-- 1-800-Flowers at ASNs 20190 and 54986, mapped to Comcast and Verizon,
-- after I added the ISP arm to the entity layer and wrongly argued it was
-- safe. The guard is the carrier universe: this name is in no carrier list.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Comcast Cable Communications', 'Flowers Direct',
       'AS99009 Flowers Direct Retail, Inc.', 'f', now()
FROM generate_series(1, 350);

-- DEFECT 4. THE CARRIER WHOSE OPERATOR NAME CARRIES AN EXTRA NOISE WORD.
-- AS99010 holds the name Osprey Enterprises, LLC against the brand Osprey.
-- carrier_name_tier scores the pair 1, because enterprises and llc are both
-- noise, so the matcher offers the brand. The first carrier universe tested
-- compact-key equality instead, and ospreyenterprises does not equal osprey,
-- so the holder was ruled not a carrier and the match was deleted.
--
-- This is AS7018 AT&T on Boris's database at 263,102 ZIP-capable ranges, one
-- of 736 ASNs and 373,410 ranges his run destroyed. The same shape appeared
-- as Google LLC against Google Fiber, Cogent Communications, LLC against
-- Cogent Communication, Zayo Bandwidth against ZAYO GROUP LLC, LUMOS
-- Networks, Inc. against lumos, Cablevision Lightpath LLC against Lightpath
-- and Metronet against Metronet Holdings.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Osprey', 'Osprey', 'AS99010 Osprey Enterprises, LLC', 'f', now()
FROM generate_series(1, 260);

-- DEFECT 4b. The containment case, which the token key alone does NOT
-- catch. AS99011 holds Blue Osprey Worldnet against the brand Blue Osprey:
-- three informative tokens against two, so the token keys differ and the
-- compact keys differ, and only carrier_name_tier reaches it, at tier 2.
-- This is AT&T WorldNet against AT&T, 600 ranges on Boris's database. It is
-- the case that forces the universe test to call the tier rule rather than
-- compare one more key.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Blue Osprey', 'Blue Osprey', 'AS99011 Blue Osprey Worldnet', 'f', now()
FROM generate_series(1, 45);

-- DEFECT 5. THE STATE GOVERNMENT. Boris 2026-11-23: "State of Alaska has no
-- relation to any of the three Alaska entities you paired with it." The
-- fixture brand Osprey is preceded here by a state-named brand so the shape
-- is reproduced exactly: a government holder whose only informative token is
-- the state name, and a real carrier with the same single token. The first
-- must get no candidate; the second must keep its match, which is why the
-- fix cannot be a stopword on the state name.
INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'State of Montana', 'State of Montana',
       'AS99012 State of Montana', 'f', now()
FROM generate_series(1, 300);

INSERT INTO ip2city_dbiplite_probe_tbl (isp, org, "as", mobile_transit, ran_at)
SELECT 'Montana Telephone', 'Montana Telephone',
       'AS99013 Montana Telephone Company', 'f', now()
FROM generate_series(1, 90);

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
