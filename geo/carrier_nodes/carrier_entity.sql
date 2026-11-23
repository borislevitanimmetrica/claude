-- ===========================================================================
-- carrier_entity.sql
--
-- A network identity that can carry SEVERAL NAMES ON EACH SIDE.
--
-- Boris 2026-11-22, confirming the trade-name table with a correction:
-- "each side of the table can contain variations. For example, Comcast might
-- appear in BDC as Comcast rather than Xfinity. Charter and Spectrum are both
-- used on the ip-api.com side depending on proximity to the customer."
--
-- That breaks the one-to-one shape everything so far assumed. A single ASN
-- may need several BDC brands, and a single BDC brand may be reached from
-- several ip-api names. So names are attributes of an entity, not keys.
--
-- WHAT AN ENTITY IS, AND WHAT IT IS NOT
--
-- An entity is ONE NETWORK wearing several labels. It is NOT a corporate
-- parent. The distinction comes straight from Boris's own argument about
-- mergers: an acquisition extends the footprint into territory the acquirer
-- did not serve rather than absorbing a competitor on the same streets.
--
--   Comcast and Xfinity        ONE entity. Same plant, two labels.
--   Charter and Spectrum       ONE entity. Same plant, two labels.
--   Verizon and Frontier       TWO entities. One owner since 20 January
--                              2026, but two separate networks in
--                              complementary territory, because Frontier's
--                              territory IS the territory Verizon divested
--                              in 2010 and 2016. Merging them would hand a
--                              Frontier ASN the right to select Verizon
--                              plant, which is the error Boris refuted.
--
-- Ownership is recorded in carrier_ownership.md and deliberately does NOT
-- merge entities.
--
-- NOTHING HERE IS WRITTEN TO THE DECISION MAP. This file proposes, reports
-- what it can and cannot verify against the database, and writes a file for
-- approval. Names I have not seen in Boris's own data are labelled as such,
-- because asserting a brand string I had not seen is the mistake I made with
-- "Comcast Business".
--
-- Run AFTER carrier_asn_match.sql.
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/carrier_entity.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('ipapi_asn_tbl'), ('bdc_carrier_tbl')) AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. Run carrier_asn_match.sql first. Nothing was built.', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'carrier_name_compact') THEN
        RAISE EXCEPTION 'carrier_name_compact() is not defined. Run carrier_asn_match.sql first. Nothing was built.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

DROP TABLE IF EXISTS carrier_entity_name_tbl;
DROP TABLE IF EXISTS carrier_entity_tbl;

CREATE TABLE carrier_entity_tbl (
    entity_key   text PRIMARY KEY,
    display_name text NOT NULL,
    note         text);

CREATE TABLE carrier_entity_name_tbl (
    entity_key text NOT NULL REFERENCES carrier_entity_tbl(entity_key),
    side       text NOT NULL CHECK (side IN ('ipapi', 'bdc')),
    name       text NOT NULL,
    status     text NOT NULL CHECK (status IN ('confirmed', 'proposed')),
    PRIMARY KEY (side, name));

COMMENT ON TABLE carrier_entity_name_tbl IS
'Names belonging to a network entity, several per side. The primary key is (side, name) rather than (entity_key, side, name) on purpose: one name must not belong to two entities, and the database should refuse that rather than let it be reported later. status confirmed means Boris confirmed the trade name; proposed means I supplied the spelling and it needs his eye.';

INSERT INTO carrier_entity_tbl VALUES
 ('comcast',       'Comcast',            'Boris confirmed the trade name. BDC may hold either label.'),
 ('charter',       'Charter / Spectrum', 'Boris: both names appear on the ip-api side depending on proximity to the customer.'),
 ('lumen',         'Lumen',              'Level 3 and CenturyLink are the same network under the Lumen name.'),
 ('astound',       'Astound Broadband',  'RCN, Grande, Wave, enTouch and Digital West were unified under this brand in January 2022.'),
 ('cableone',      'Cable One',          'Trading as Sparklight since 2019.'),
 ('altice',        'Optimum',            'Cablevision and Suddenlink both became Optimum. Lightpath is deliberately NOT included: it was separated from Altice and I have not verified its current footprint ownership.'),
 ('wow',           'WideOpenWest',       'Trades as WOW!.'),
 ('cincinnatibell','Cincinnati Bell',    'Trading as altafiber since 2022.'),
 ('midco',         'Midco',              'Midcontinent Communications trades as Midco.'),
 ('mediacom',      'Mediacom',           'Xtream is a Mediacom product name; included as proposed only.'),
 ('frontier',      'Frontier',           'Owned by Verizon since 20 January 2026 and kept SEPARATE from the verizon entity on purpose. Its plant is the plant Verizon divested in 2010 and 2016, so the two footprints are complementary, not interchangeable.'),
 ('verizon',       'Verizon',            'Kept separate from frontier. See carrier_ownership.md.');

-- ip-api side. Spellings taken from Boris's own 2026-11-22 run, so these are
-- observed rather than guessed.
INSERT INTO carrier_entity_name_tbl (entity_key, side, name, status) VALUES
 ('comcast','ipapi','Comcast Cable Communications, LLC','confirmed'),
 ('charter','ipapi','Charter Communications LLC','confirmed'),
 ('charter','ipapi','Charter Communications Inc','confirmed'),
 ('charter','ipapi','Charter Communications, Inc','confirmed'),
 ('charter','ipapi','Spectrum','confirmed'),
 ('lumen','ipapi','Level 3 Parent, LLC','confirmed'),
 ('lumen','ipapi','Level 3 Communications, Inc.','confirmed'),
 ('lumen','ipapi','CenturyLink Communications, LLC','proposed'),
 ('astound','ipapi','RCN','confirmed'),
 ('astound','ipapi','Wave Broadband','confirmed'),
 ('astound','ipapi','Grande Communications Networks, LLC','confirmed'),
 ('cableone','ipapi','CABLE ONE, INC.','confirmed'),
 ('altice','ipapi','Cablevision Systems Corp.','confirmed'),
 ('altice','ipapi','Optimum','confirmed'),
 ('altice','ipapi','Suddenlink Communications','proposed'),
 ('wow','ipapi','WideOpenWest Finance LLC','confirmed'),
 ('cincinnatibell','ipapi','Cincinnati Bell Telephone Company LLC','confirmed'),
 ('midco','ipapi','Midcontinent Communications','confirmed'),
 ('mediacom','ipapi','Mediacom Communications Corp','confirmed'),
 ('frontier','ipapi','Frontier Communications','proposed'),
 ('verizon','ipapi','Verizon Business','confirmed');

-- BDC side. Boris 2026-11-22: BDC may hold the legal label as well as the
-- trade name, so BOTH are listed for every entity and the report below says
-- which of them actually exist in bdc_carrier_tbl.
INSERT INTO carrier_entity_name_tbl (entity_key, side, name, status) VALUES
 ('comcast','bdc','Xfinity','confirmed'),
 ('comcast','bdc','Comcast','proposed'),
 ('charter','bdc','Spectrum','confirmed'),
 ('charter','bdc','Charter Communications','proposed'),
 ('lumen','bdc','Lumen','confirmed'),
 ('lumen','bdc','CenturyLink','confirmed'),
 ('lumen','bdc','Quantum Fiber','proposed'),
 ('lumen','bdc','Level 3','proposed'),
 ('astound','bdc','Astound Broadband','confirmed'),
 ('astound','bdc','RCN','proposed'),
 ('astound','bdc','Wave','proposed'),
 ('astound','bdc','Grande','proposed'),
 ('astound','bdc','Digital West','proposed'),
 ('cableone','bdc','Sparklight','confirmed'),
 ('cableone','bdc','Cable One','proposed'),
 ('altice','bdc','Optimum','confirmed'),
 ('altice','bdc','Suddenlink','proposed'),
 ('wow','bdc','WOW!','confirmed'),
 ('wow','bdc','WideOpenWest','proposed'),
 ('cincinnatibell','bdc','altafiber','confirmed'),
 ('cincinnatibell','bdc','Cincinnati Bell','proposed'),
 ('midco','bdc','Midco','confirmed'),
 ('midco','bdc','Midcontinent Communications','proposed'),
 ('mediacom','bdc','Mediacom','confirmed'),
 ('mediacom','bdc','Xtream','proposed'),
 ('frontier','bdc','Frontier','confirmed'),
 ('verizon','bdc','Verizon','confirmed');

ANALYZE carrier_entity_tbl;
ANALYZE carrier_entity_name_tbl;

-- ---------------------------------------------------------------------------
-- Does each name exist in the data? Matching on the compact key, which is
-- full-string equality after legal suffixes drop, so nothing is swept in.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS carrier_entity_resolved_tbl;
CREATE TABLE carrier_entity_resolved_tbl AS
SELECT n.entity_key, n.side, n.name, n.status,
       b.brand_name  AS found_bdc_brand,
       b.provider_id AS found_provider_id,
       NULL::bigint  AS found_asn,
       NULL::bigint  AS zip_capable_ranges,
       NULL::text    AS matched_field
FROM carrier_entity_name_tbl n
-- Only brands with WIRELINE plant. Boris 2026-11-22: wireless is out of
-- scope for the ITDK-BDC subsystem, so a brand carrying only technologies
-- 70, 71 or 72 cannot answer a ZIP question and must not become a proposal.
JOIN (SELECT DISTINCT c.brand_name, c.provider_id FROM bdc_carrier_tbl c
      WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
        AND EXISTS (SELECT 1 FROM provider_brand_tract_tech_tbl f
                    WHERE f.provider_id = c.provider_id
                      AND f.brand_name = c.brand_name
                      AND f.technology IN (10, 40, 50))) b
  ON carrier_name_compact(b.brand_name) = carrier_name_compact(n.name)
WHERE n.side = 'bdc'
UNION ALL
-- The ip-api side is matched against the AS OPERATOR NAME AND THE ISP NAME.
-- Boris 2026-11-22: "Charter and Spectrum are both used on the ip-api.com
-- side depending on proximity to the customer." The customer-proximate field
-- is the ISP name, and his run proved the point: the name Spectrum came back
-- "not in your data" when I was only looking at as_operator, while thirty-one
-- Charter ASNs were sitting there. Frontier failed the same way.
--
-- This is NOT the upstream-carrier hazard that made me stop generating
-- CANDIDATES from the ISP name. There the ISP name was used to guess an
-- unknown identity; here it is checked against a name Boris has already
-- ruled belongs to this entity, so a Windstream ISP name on an Amazon ASN
-- cannot match anything unless Windstream is listed under that entity.
SELECT n.entity_key, n.side, n.name, n.status,
       NULL, NULL, a.asn, a.zip_capable_ranges, 'as_operator'
FROM carrier_entity_name_tbl n
JOIN ipapi_asn_tbl a
  ON carrier_name_compact(a.as_operator) = carrier_name_compact(n.name)
WHERE n.side = 'ipapi'
UNION ALL
SELECT n.entity_key, n.side, n.name, n.status,
       NULL, NULL, a.asn, a.zip_capable_ranges, 'isp'
FROM carrier_entity_name_tbl n
JOIN ipapi_asn_tbl a
  ON carrier_name_compact(a.isp_commonest) = carrier_name_compact(n.name)
WHERE n.side = 'ipapi'
  AND NOT EXISTS (SELECT 1 FROM carrier_entity_name_tbl n2
                  WHERE n2.side = 'ipapi'
                    AND carrier_name_compact(n2.name) = carrier_name_compact(a.as_operator));

CREATE INDEX carrier_entity_resolved_ix ON carrier_entity_resolved_tbl (entity_key);
ANALYZE carrier_entity_resolved_tbl;

\echo
\echo ================================================================
\echo Which seeded names exist in your data. A name with nothing beside
\echo it is a spelling I supplied that your database does not use, and
\echo proves nothing either way about the carrier.
\echo ================================================================
\echo
SELECT n.entity_key, n.side, left(n.name, 34) AS name, n.status,
       CASE WHEN EXISTS (SELECT 1 FROM carrier_entity_resolved_tbl r
                         WHERE r.side = n.side AND r.name = n.name)
            THEN 'found' ELSE 'not in your data' END AS in_database
FROM carrier_entity_name_tbl n
ORDER BY n.entity_key, n.side, n.name;

\echo
\echo ================================================================
\echo The payload. For each entity, the ASNs it holds on the ip-api side
\echo and the BDC brands it holds on the other, so the major carriers
\echo that no string method could join are joined through the entity.
\echo ================================================================
\echo
-- The range total is summed over DISTINCT ASNs. An entity resolves through
-- several of its own names, so Charter reached thirty-one ASNs through three
-- spellings and a naive sum counted each ASN three times, which is how my
-- first version of this report claimed 1,330,456 ranges. Boris has not been
-- given that number and must not be.
SELECT e.entity_key, e.display_name,
       (SELECT count(DISTINCT r.found_asn) FROM carrier_entity_resolved_tbl r
        WHERE r.entity_key = e.entity_key AND r.side = 'ipapi')     AS asns,
       (SELECT sum(z.zip_capable_ranges) FROM
          (SELECT DISTINCT r.found_asn, r.zip_capable_ranges
           FROM carrier_entity_resolved_tbl r
           WHERE r.entity_key = e.entity_key AND r.side = 'ipapi') z) AS zip_capable_ranges,
       (SELECT count(DISTINCT r.found_bdc_brand) FROM carrier_entity_resolved_tbl r
        WHERE r.entity_key = e.entity_key AND r.side = 'bdc')       AS bdc_brands,
       (SELECT string_agg(DISTINCT r.found_bdc_brand, ' | ')
        FROM carrier_entity_resolved_tbl r
        WHERE r.entity_key = e.entity_key AND r.side = 'bdc')       AS brands_found
FROM carrier_entity_tbl e
ORDER BY zip_capable_ranges DESC NULLS LAST;

\echo
\echo Entities that cannot yet produce a mapping, and WHY. one_side_only
\echo means I have the wrong spelling on the empty side; neither_side means
\echo your database uses different names on both and the entity needs your
\echo eye or the Form 499 legal name.
\echo
SELECT e.entity_key, e.display_name, x.ipapi_hits, x.bdc_hits,
       CASE WHEN x.ipapi_hits = 0 AND x.bdc_hits = 0 THEN 'neither_side'
            ELSE 'one_side_only' END AS why,
       left(e.note, 70) AS note
FROM carrier_entity_tbl e
CROSS JOIN LATERAL (
    SELECT count(*) FILTER (WHERE r.side = 'ipapi') AS ipapi_hits,
           count(*) FILTER (WHERE r.side = 'bdc')   AS bdc_hits
    FROM carrier_entity_resolved_tbl r WHERE r.entity_key = e.entity_key
) x
WHERE x.ipapi_hits = 0 OR x.bdc_hits = 0
ORDER BY why, e.entity_key;

-- ---------------------------------------------------------------------------
-- The proposals, as a file for approval. One row per ASN and brand, which is
-- the shape the migrated decision map now accepts.
-- ---------------------------------------------------------------------------
-- ONE ROW PER ASN AND BRAND, which is the grain the migrated decision map
-- stores. The names that reached it are aggregated into a column rather than
-- multiplying the rows: Charter resolves through three spellings, and the
-- first version of this emitted three identical proposals per ASN.
DROP TABLE IF EXISTS carrier_entity_proposal_tbl;
CREATE TABLE carrier_entity_proposal_tbl AS
SELECT i.found_asn                          AS asn,
       e.entity_key,
       e.display_name,
       b.found_provider_id                  AS provider_id,
       b.found_bdc_brand                    AS brand_name,
       max(i.zip_capable_ranges)            AS zip_capable_ranges,
       string_agg(DISTINCT i.name, ' / ')    AS ipapi_names,
       string_agg(DISTINCT i.matched_field, '+') AS matched_on,
       greatest(max(i.status), max(b.status)) AS weakest_status
FROM carrier_entity_tbl e
JOIN carrier_entity_resolved_tbl i
  ON i.entity_key = e.entity_key AND i.side = 'ipapi'
JOIN carrier_entity_resolved_tbl b
  ON b.entity_key = e.entity_key AND b.side = 'bdc'
WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = i.found_asn)
  AND NOT carrier_pair_is_unrelated(i.name, b.found_bdc_brand)
GROUP BY 1, 2, 3, 4, 5;

ANALYZE carrier_entity_proposal_tbl;

\echo
\echo Proposed ASN to brand decisions, the largest first. NOT WRITTEN.
\echo
SELECT p.asn, left(p.ipapi_names, 28) AS ipapi_names, p.matched_on,
       p.entity_key, p.provider_id, left(p.brand_name, 22) AS brand_name,
       p.weakest_status, p.zip_capable_ranges
FROM carrier_entity_proposal_tbl p
ORDER BY p.zip_capable_ranges DESC NULLS LAST, p.asn, p.brand_name
LIMIT 60;

\echo
\echo The honest totals. Ranges are summed over DISTINCT ASNs, because one
\echo ASN can carry several brands and must not be counted once per brand.
\echo
SELECT count(*)                                    AS proposal_rows,
       count(DISTINCT asn)                         AS asns_covered,
       (SELECT sum(z.zip_capable_ranges) FROM
          (SELECT DISTINCT asn, zip_capable_ranges
           FROM carrier_entity_proposal_tbl) z)    AS zip_capable_ranges,
       count(*) FILTER (WHERE weakest_status = 'confirmed') AS rows_fully_confirmed,
       count(*) FILTER (WHERE weakest_status = 'proposed')  AS rows_needing_your_eye
FROM carrier_entity_proposal_tbl;

\echo
\echo Share of all probed ZIP-capable address space these proposals settle.
\echo
SELECT (SELECT sum(z.zip_capable_ranges) FROM
          (SELECT DISTINCT asn, zip_capable_ranges
           FROM carrier_entity_proposal_tbl) z)      AS proposed,
       (SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl) AS all_probed,
       round(100.0 * (SELECT sum(z.zip_capable_ranges) FROM
          (SELECT DISTINCT asn, zip_capable_ranges
           FROM carrier_entity_proposal_tbl) z)
           / nullif((SELECT sum(zip_capable_ranges) FROM ipapi_asn_tbl), 0), 1) AS pct;

\echo
\echo CONFLICTS. Proposals for an ASN that the parent-on-subsidiary report
\echo disagrees with. This is the Verizon and Frontier case: the entity
\echo layer resolves the operator name Verizon Business to the verizon
\echo entity, while the ip-api ISP name on those same ranges says Frontier.
\echo Where this fires, the ISP name is the better evidence, because the
\echo operator name followed the ownership and the plant did not.
\echo
SELECT p.asn, left(p.ipapi_names, 24) AS entity_says,
       left(p.brand_name, 20) AS entity_brand,
       left(d.isp_commonest, 24) AS isp_says,
       left(d.isp_suggests_brand, 20) AS isp_brand,
       p.zip_capable_ranges
FROM carrier_entity_proposal_tbl p
JOIN asn_isp_disagree_tbl d ON d.asn = p.asn
WHERE d.isp_suggests_brand IS DISTINCT FROM p.brand_name
ORDER BY p.zip_capable_ranges DESC NULLS LAST, p.asn
LIMIT 30;

\echo
\echo Writing the proposals for your approval column.
\echo
\copy (SELECT p.asn, p.ipapi_names, p.matched_on, p.entity_key, p.display_name, p.provider_id, p.brand_name, p.weakest_status, p.zip_capable_ranges, NULL::text AS approved FROM carrier_entity_proposal_tbl p ORDER BY p.zip_capable_ranges DESC NULLS LAST, p.asn, p.brand_name) TO '/home/boris/geo/carrier_entity_proposals.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
