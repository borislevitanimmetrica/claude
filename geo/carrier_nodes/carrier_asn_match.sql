-- carrier_asn_match.sql - match carriers to BDC brands with the ASN as the
-- primary key, and with Boris's counterexamples as a regression gate that
-- ABORTS the file rather than printing a warning.
--
-- WHY EVERY MATCH BORIS LISTED WAS WRONG, as one defect
--
-- Tier 2 was "one token set contained in the other". When the contained set
-- has ONE token, containment degenerates into "shares one word", which is
-- the original substring bug under a new name:
--
--   Spectrum {spectrum} inside Red Spectrum Communications {red,spectrum}
--   Cablevision Systems Corp {cablevision} inside Cherokee Cablevision
--   CABLE ONE {one} against One Communications {one}
--   United States Department of Defense against United Fiber {united}
--   Verizon Business against EarthLink Business, on 'business'
--   Amazon.com against Tech-Com, on 'com' after 'tech' was stopped
--
-- Boris's rule is sharper than mine and is now the rule: A SINGLE SHARED
-- WORD IS NEVER PROOF OF EQUALITY. Three consequences:
--
--   1. The words he named as modifiers join the stoplist: business,
--      cablevision, one, united, wave, com. So does bandwidth, because
--      without it 'Zayo Bandwidth' against 'ZAYO GROUP LLC' fails.
--   2. Containment counts only when the contained set has TWO or more
--      tokens AND the containing set has at most one token more. Without
--      the second half, {san,diego} sits inside {university,california,
--      san,diego}, which is the UCSD against San Diego Broadband match he
--      flagged.
--   3. A single shared word is tier 3 and TIER 3 IS NOT OFFERED. It is
--      counted and discarded. On the last run tier 3 was 32,050 of 46,030
--      rows, which is the noise he was sent.
--
-- And the compact key now drops legal suffixes before compacting, which is
-- what recovers CABLE ONE, INC. against the brand Cable One while still
-- refusing One Communications.
--
-- THE ASN IS THE PRIMARY KEY, as Boris instructed, and the research into
-- whether the FCC publishes one is in geo/carrier_nodes/asn_name_research.md.
-- Short answer: it does not. The BDC carries frn and provider_id and no AS
-- number; neither do Form 477, CORES or the Form 499 filer database. So the
-- ASN cannot be the join TO the BDC, but it is a hard key on the ip-api
-- side and that is where it is used: one decision per ASN instead of one
-- per spelling of a name. On the last run 'Comcast Cable Communications,
-- LLC' and 'Comcast Cable Communications' were two rows; by ASN they are
-- one.
--
-- It also removes a defect of mine that his output exposed. I aggregated
-- the org column with max(), which is why 'Charter Communications Inc'
-- appeared beside an unrelated Chinese company name: an arbitrary value
-- presented as though it belonged to that carrier. Names are now grouped
-- within the ASN and counted, so what is shown is the commonest value with
-- its frequency, not whatever sorted last.
--
-- ONE SOURCE OF TRUTH FOR THE RULE. carrier_name_tier() decides, and both
-- the regression gate and the matcher call it. A test that exercises a
-- reimplementation of the rule tests nothing.
--
-- PRE-MORTEM. Creates four functions and three working tables, dropping the
-- working tables first so the file re-runs. asn_bdc_brand_map_tbl holds
-- Boris's decisions and is created IF NOT EXISTS and NEVER dropped or
-- truncated here. Everything else is read-only.

\set ON_ERROR_STOP on
\timing on

-- ---------------------------------------------------------------------------
-- PRECHECK. Blocks, does not print.
-- ---------------------------------------------------------------------------
DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(c.needed, ', ') INTO missing
    FROM (VALUES ('isp'), ('org'), ('as'), ('ran_at')) AS c(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns i
                      WHERE i.table_name = 'ip2city_dbiplite_probe_tbl'
                        AND i.column_name = c.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'ip2city_dbiplite_probe_tbl is missing: %. Nothing was built.', missing;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'bdc_carrier_tbl' AND column_name = 'brand_name') THEN
        RAISE EXCEPTION 'bdc_carrier_tbl has no brand_name. Nothing was built.';
    END IF;
    SELECT string_agg(c.needed, ', ') INTO missing
    FROM (VALUES ('provider_id'), ('brand_name'), ('tract_geoid')) AS c(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns i
                      WHERE i.table_name = 'provider_brand_tract_tech_tbl'
                        AND i.column_name = c.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'provider_brand_tract_tech_tbl is missing: %. Run provider_brand_footprint.sql first. Nothing was built.', missing;
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- ---------------------------------------------------------------------------
-- The rule, in one place.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION carrier_name_stopwords()
RETURNS text[] AS $fn$
SELECT ARRAY[
  -- legal form
  'inc','llc','lllp','llp','lp','ltd','limited','corp','corporation','co',
  'company','plc','pllc','incorporated','holdings','holding','group',
  -- industry words, which nearly every carrier carries
  'communications','communication','comm','telecom','telecommunications',
  'telephone','tel','telephony','networks','network','broadband','bandwidth',
  'fiber','fibre','cable','internet','services','service','solutions',
  'solution','technologies','technology','tech','systems','system','digital',
  'online','media','enterprises','enterprise','partners','associates',
  'cooperative','coop','utilities','utility','wireless','data','access',
  'link','net','web','global',
  -- geographic and patriotic filler
  'america','american','national','usa','us','the','of','and','a','an',
  -- modifiers Boris named on 2026-11-20, each having produced a wrong match
  'business','cablevision','one','united','wave'];
$fn$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION carrier_name_words(raw text)
RETURNS text[] AS $fn$
SELECT array_remove(
         regexp_split_to_array(
           btrim(regexp_replace(lower(coalesce(raw, '')), '[^a-z0-9]+', ' ', 'g')),
           ' '),
         '');
$fn$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION carrier_name_tokens(raw text)
RETURNS text[] AS $fn$
SELECT CASE WHEN cardinality(k) > 0 THEN k ELSE carrier_name_words(raw) END
FROM (SELECT ARRAY(SELECT w FROM unnest(carrier_name_words(raw)) AS w
                   WHERE w <> ALL (carrier_name_stopwords())) AS k) x;
$fn$ LANGUAGE sql IMMUTABLE;

-- TRUE when every word was generic, so the token set is only a fallback and
-- must not be used for matching.
CREATE OR REPLACE FUNCTION carrier_name_generic_only(raw text)
RETURNS boolean AS $fn$
SELECT NOT EXISTS (SELECT 1 FROM unnest(carrier_name_words(raw)) AS w
                   WHERE w <> ALL (carrier_name_stopwords()));
$fn$ LANGUAGE sql IMMUTABLE;

-- The compact key drops LEGAL SUFFIXES ONLY before compacting, so
-- 'CABLE ONE, INC.' and the brand 'Cable One' agree while
-- 'One Communications' does not.
CREATE OR REPLACE FUNCTION carrier_name_compact(raw text)
RETURNS text AS $fn$
SELECT nullif(
  (SELECT coalesce(string_agg(w, '' ORDER BY ord), '')
   FROM unnest(carrier_name_words(raw)) WITH ORDINALITY AS t(w, ord)
   WHERE w <> ALL (ARRAY['inc','llc','lllp','llp','lp','ltd','limited',
                         'corp','corporation','co','company','plc','pllc',
                         'incorporated'])),
  '');
$fn$ LANGUAGE sql IMMUTABLE;

-- 1 exact, 2 strong containment, 3 a single shared word and therefore NOT
-- offered, 0 nothing.
CREATE OR REPLACE FUNCTION carrier_name_tier(a text, b text)
RETURNS integer AS $fn$
SELECT CASE
  WHEN t.ca IS NOT NULL AND t.ca = t.cb                             THEN 1
  WHEN t.generic                                                    THEN 0
  WHEN t.ta <@ t.tb AND t.tb <@ t.ta                                THEN 1
  WHEN (t.ta <@ t.tb OR t.tb <@ t.ta)
   AND least(cardinality(t.ta), cardinality(t.tb)) >= 2
   AND greatest(cardinality(t.ta), cardinality(t.tb))
       - least(cardinality(t.ta), cardinality(t.tb)) <= 1           THEN 2
  WHEN cardinality(ARRAY(SELECT unnest(t.ta)
                         INTERSECT SELECT unnest(t.tb))) > 0        THEN 3
  ELSE 0 END
FROM (SELECT carrier_name_tokens(a)  AS ta, carrier_name_tokens(b)  AS tb,
             carrier_name_compact(a) AS ca, carrier_name_compact(b) AS cb,
             (carrier_name_generic_only(a) OR carrier_name_generic_only(b))
                                     AS generic) t;
$fn$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------------------
-- THE REGRESSION GATE. Every pair Boris called wrong, plus the pairs that
-- must still work. This RAISES and builds nothing if any case fails.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS carrier_name_regression_tbl;
CREATE TABLE carrier_name_regression_tbl (
    ipapi_side text, bdc_side text, must text, source text);

INSERT INTO carrier_name_regression_tbl VALUES
 -- Boris 2026-11-20, every one of these was offered and is wrong.
 ('Verizon Business','EarthLink Business','reject','boris: unrelated competitors'),
 ('Verizon Business','Allstream Business US LLC','reject','boris: unrelated'),
 ('Verizon Business','Orange Business Services U.S.','reject','boris: unrelated'),
 ('Allstream Business US, LLC','EarthLink Business','reject','boris: unrelated'),
 ('Allstream Business US, LLC','Orange Business Services U.S.','reject','boris: unrelated'),
 ('Amazon.com, Inc.','Tech-Com, Inc.','reject','boris: Amazon is not an ISP'),
 ('Amazon.com, Inc.','EagleZip.com','reject','boris: Amazon is not an ISP'),
 ('GoDaddy.com, LLC','Com-Pair Services','reject','boris: not a carrier match'),
 ('Spectrum','Red Spectrum Communications LLC','reject','boris: unrelated'),
 ('Spectrum','Sonic Spectrum Inc','reject','boris: unrelated'),
 ('Cablevision Systems Corp.','Cherokee Cablevision','reject','boris: unrelated'),
 ('Cablevision Systems Corp.','Citizens Cablevision Inc','reject','boris: unrelated'),
 ('Cablevision Systems Corp.','Quality Cablevision','reject','boris: unrelated'),
 ('Cablevision Systems Corp.','Service Electric Cablevision, Inc','reject','boris: unrelated'),
 ('Cablevision Systems Corp.','Tel-Star Cablevision','reject','boris: unrelated'),
 ('CABLE ONE, INC.','One Communications','reject','boris: One is a modifier'),
 ('CABLE ONE, INC.','ONE Burbank','reject','boris: One is a modifier'),
 ('Wave Broadband','Fiber Wave','reject','boris: Wave does not indicate equality'),
 ('Wave Broadband','Wave Wireless','reject','boris: research case by case'),
 ('Wave Broadband','Wave 7 Communications','reject','boris: research case by case'),
 ('United States Department of Defense','United Communications','reject','boris: United is a modifier'),
 ('United States Department of Defense','United Fiber','reject','boris: United is a modifier'),
 ('United States Department of Defense','United Utilities, Inc.','reject','boris: out of scope anyway'),
 ('NTT America','NTT Fiber (North Texas Telephone)','reject','boris implied: unrelated'),
 ('University of California, San Diego','San Diego Broadband','reject','boris: not a carrier'),
 ('T-Mobile USA, Inc.','Limitless Mobile','reject','single shared word mobile'),
 ('Comcast Cable Communications, LLC','Xfinity','reject','no string method can join these'),
 ('Comcast Cable Communications, LLC','USA COMMUNICATIONS','reject','the original bug'),
 ('Comcast Cable Communications, LLC','Spectrum','reject','competitor'),
 ('Windstream Communications LLC','Georgia Windstream, LLC.','reject','subsidiary reached by one word'),
 -- These must keep working.
 ('Cox Communications Inc.','Cox Communications','accept','same company'),
 ('Frontier Communications Solutions','Frontier','accept','same company'),
 ('AT&T Enterprises, LLC','AT&T','accept','same company'),
 ('123.Net, Inc.','123.NET Inc','accept','same company'),
 ('Windstream Communications LLC','Windstream','accept','same company'),
 ('Verizon Business','Verizon','accept','same company'),
 ('CenturyLink Communications, LLC','CenturyLink','accept','same company'),
 ('Zayo Bandwidth','ZAYO GROUP LLC','accept','same company'),
 ('Cogent Communications','Cogent Communication','accept','same company'),
 ('Google LLC','Google Fiber','accept','same company'),
 ('USA COMMUNICATIONS','USA COMMUNICATIONS','accept','identical'),
 ('CABLE ONE, INC.','Cable One','accept','same company, suffix dropped'),
 ('T-Mobile USA, Inc.','T-Mobile','accept','same company'),
 ('TDS TELECOM','TDS Telecom','accept','identical'),
 ('Breezeline','Breezeline','accept','identical');

\echo
\echo ================================================================
\echo THE REGRESSION GATE. tier 1 and 2 are offered to Boris; tier 3 and
\echo 0 are not. An accept case must reach 1 or 2; a reject case must not.
\echo ================================================================
\echo
SELECT must,
       count(*)                                                 AS cases,
       count(*) FILTER (WHERE carrier_name_tier(ipapi_side, bdc_side) <= 2
                          AND carrier_name_tier(ipapi_side, bdc_side) >= 1
                          AND must = 'accept')                  AS accept_pass,
       count(*) FILTER (WHERE carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2)
                          AND must = 'reject')                   AS reject_pass
FROM carrier_name_regression_tbl
GROUP BY 1 ORDER BY 1;

\echo
\echo Every case with the tier it reaches. 3 means a single shared word,
\echo which is counted and discarded rather than offered.
\echo
SELECT must, ipapi_side, bdc_side,
       carrier_name_tier(ipapi_side, bdc_side) AS tier,
       CASE WHEN must = 'accept'
                 AND carrier_name_tier(ipapi_side, bdc_side) IN (1, 2) THEN 'pass'
            WHEN must = 'reject'
                 AND carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2) THEN 'pass'
            ELSE 'FAIL' END AS result,
       source
FROM carrier_name_regression_tbl
ORDER BY result, must, ipapi_side, bdc_side;

DO $gate$
DECLARE bad integer;
        detail text;
BEGIN
    SELECT count(*), string_agg(ipapi_side || ' -> ' || bdc_side, '; ')
      INTO bad, detail
    FROM carrier_name_regression_tbl
    WHERE (must = 'accept' AND carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2))
       OR (must = 'reject' AND carrier_name_tier(ipapi_side, bdc_side) IN (1, 2));
    IF bad > 0 THEN
        RAISE EXCEPTION
          'REGRESSION GATE FAILED on % case(s): %. Nothing was built and no file was written.',
          bad, left(detail, 400);
    END IF;
    RAISE NOTICE 'regression gate passed: all % cases', (SELECT count(*) FROM carrier_name_regression_tbl);
END
$gate$;

-- ---------------------------------------------------------------------------
-- The persistent decision map, keyed on the ASN.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asn_bdc_brand_map_tbl (
    asn             bigint PRIMARY KEY,
    decision        text NOT NULL
                    CHECK (decision IN ('brand', 'not_a_carrier', 'out_of_scope', 'unknown')),
    bdc_brand_name  text,
    bdc_provider_id integer,
    note            text,
    approved_at     timestamptz NOT NULL DEFAULT now());

COMMENT ON TABLE asn_bdc_brand_map_tbl IS
'Boris-approved mapping from an AS number to a BDC brand. The ASN is the key because it is the only hard identifier on the ip-api side: one decision per operator rather than one per spelling of its name. PERSISTENT. carrier_asn_match.sql never drops or truncates it and proposes candidates only for ASNs absent from it, which is what makes new carriers integrate automatically as the remaining half of the decomposed ranges is probed. decision out_of_scope records Boris 2026-11-20: a non-carrier is localised by ip-api to its own premises, so it needs no headend inference at all.';

SELECT count(*) AS decisions_held,
       count(*) FILTER (WHERE decision = 'brand')        AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier') AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')  AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo ================================================================
\echo SECTION 1. One row per ASN. Each name shown is the one carried by
\echo the MOST PROBED RANGES within that ASN, and its share of them is
\echo printed beside it. The previous version of this file grouped the
\echo name combinations before taking mode(), which threw the range
\echo counts away and left the pick arbitrary. That is fixed here.
\echo ================================================================
\echo
DROP TABLE IF EXISTS ipapi_asn_tbl;

DO $build$
DECLARE zip_expr text; dma_expr text; unk_expr text; tier_col text;
BEGIN
    SELECT i.column_name INTO tier_col
    FROM information_schema.columns i
    WHERE i.table_name = 'ip2city_dbiplite_probe_tbl'
      AND i.column_name IN ('mobile_transit', 'likely_mobile_cgnat')
    ORDER BY CASE i.column_name WHEN 'mobile_transit' THEN 1 ELSE 2 END LIMIT 1;

    IF tier_col = 'mobile_transit' THEN
        zip_expr := 'count(*) FILTER (WHERE p.mobile_transit = ''f'')';
        dma_expr := 'count(*) FILTER (WHERE p.mobile_transit IN (''m'',''t''))';
        unk_expr := 'count(*) FILTER (WHERE p.mobile_transit IS NULL)';
    ELSIF tier_col = 'likely_mobile_cgnat' THEN
        zip_expr := 'count(*) FILTER (WHERE p.likely_mobile_cgnat IS FALSE)';
        dma_expr := 'count(*) FILTER (WHERE p.likely_mobile_cgnat IS TRUE)';
        unk_expr := 'count(*) FILTER (WHERE p.likely_mobile_cgnat IS NULL)';
    ELSE
        zip_expr := 'NULL::bigint'; dma_expr := 'NULL::bigint'; unk_expr := 'count(*)';
        RAISE NOTICE 'no accuracy tier column present; all ranges reported unclassified';
    END IF;

    EXECUTE format($q$
      CREATE TABLE ipapi_asn_tbl AS
      WITH r AS (
          SELECT nullif(regexp_replace(p."as", '^AS([0-9]+).*$', '\1'), p."as")::bigint AS asn,
                 btrim(regexp_replace(p."as", '^AS[0-9]+[[:space:]]*', '')) AS as_operator,
                 p.isp, p.org,
                 %s AS zipc, %s AS dmao, %s AS unkn
          FROM ip2city_dbiplite_probe_tbl p
          WHERE p.ran_at IS NOT NULL
            AND p."as" IS NOT NULL AND p."as" <> ''
          GROUP BY 1,2,3,4
      ), tot AS (
          SELECT asn,
                 sum(zipc)                AS zip_capable_ranges,
                 sum(dmao)                AS dma_only_ranges,
                 sum(unkn)                AS unclassified_ranges,
                 sum(zipc + dmao + unkn)  AS ranges,
                 count(*)                 AS name_combinations,
                 count(DISTINCT isp)      AS isp_variants
          FROM r WHERE asn IS NOT NULL GROUP BY asn
      ), op AS (
          SELECT DISTINCT ON (asn) asn, as_operator, n AS as_operator_ranges
          FROM (SELECT asn, as_operator, sum(zipc + dmao + unkn) AS n
                FROM r WHERE asn IS NOT NULL GROUP BY 1, 2) s
          ORDER BY asn, n DESC, as_operator
      ), ispn AS (
          SELECT DISTINCT ON (asn) asn, isp, n AS isp_commonest_ranges
          FROM (SELECT asn, isp, sum(zipc + dmao + unkn) AS n
                FROM r WHERE asn IS NOT NULL AND isp IS NOT NULL AND isp <> ''
                GROUP BY 1, 2) s
          ORDER BY asn, n DESC, isp
      ), orgn AS (
          SELECT DISTINCT ON (asn) asn, org, n AS org_commonest_ranges
          FROM (SELECT asn, org, sum(zipc + dmao + unkn) AS n
                FROM r WHERE asn IS NOT NULL AND org IS NOT NULL AND org <> ''
                GROUP BY 1, 2) s
          ORDER BY asn, n DESC, org
      )
      SELECT t.asn,
             o.as_operator,
             o.as_operator_ranges,
             round(100.0 * o.as_operator_ranges / nullif(t.ranges, 0), 1)
                                                        AS as_operator_pct,
             i.isp                                      AS isp_commonest,
             i.isp_commonest_ranges,
             round(100.0 * i.isp_commonest_ranges / nullif(t.ranges, 0), 1)
                                                        AS isp_commonest_pct,
             g.org                                      AS org_commonest,
             t.isp_variants, t.name_combinations, t.ranges,
             t.zip_capable_ranges, t.dma_only_ranges, t.unclassified_ranges
      FROM tot t
      JOIN op         o ON o.asn = t.asn
      LEFT JOIN ispn  i ON i.asn = t.asn
      LEFT JOIN orgn  g ON g.asn = t.asn $q$, zip_expr, dma_expr, unk_expr);
END
$build$;

ALTER TABLE ipapi_asn_tbl ADD PRIMARY KEY (asn);
ANALYZE ipapi_asn_tbl;

SELECT count(*)                                            AS asns,
       sum(zip_capable_ranges)                             AS zip_capable_ranges,
       sum(dma_only_ranges)                                AS dma_only_ranges,
       count(*) FILTER (WHERE isp_variants > 1)            AS asns_with_several_isp_names,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                                      WHERE m.asn = ipapi_asn_tbl.asn)) AS already_decided
FROM ipapi_asn_tbl;

\echo
\echo ================================================================
\echo SECTION 2. Candidates. Tier 1 and 2 ONLY, five per ASN at most.
\echo Candidates come from the AS OPERATOR NAME ALONE. The ip-api ISP name
\echo no longer generates any, because it is often the upstream carrier
\echo rather than the holder of the ASN; it is still shown, and the tier it
\echo would have scored is reported as corroboration only.
\echo The footprint size of each candidate brand is printed so that a
\echo parent company name landing on a national brand is visible.
\echo ================================================================
\echo
DROP TABLE IF EXISTS asn_brand_candidate_tbl;
CREATE TABLE asn_brand_candidate_tbl AS
WITH todo AS (
    SELECT * FROM ipapi_asn_tbl a
    WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn)
), brand AS (
    SELECT DISTINCT c.brand_name, c.provider_id
    FROM bdc_carrier_tbl c
    WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
), ntok AS (
    -- Only the AS operator name generates candidates. The ip-api ISP name
    -- is frequently the UPSTREAM carrier rather than the holder of the ASN:
    -- AS16509 is Amazon and ip-api reports its ISP as Windstream, which is
    -- how the previous version matched Amazon to Windstream's footprint.
    SELECT t.asn, w.tok
    FROM todo t, unnest(carrier_name_tokens(t.as_operator)) AS w(tok)
    WHERE length(w.tok) >= 2 AND NOT carrier_name_generic_only(t.as_operator)
), btok AS (
    SELECT b.brand_name, b.provider_id, w.tok
    FROM brand b, unnest(carrier_name_tokens(b.brand_name)) AS w(tok)
    WHERE length(w.tok) >= 2 AND NOT carrier_name_generic_only(b.brand_name)
), pair AS (
    -- Pairs sharing an informative token, plus pairs agreeing on the
    -- compact key, which is the path that does not need a shared token.
    SELECT DISTINCT n.asn, b.brand_name, b.provider_id
    FROM ntok n JOIN btok b ON b.tok = n.tok
    UNION
    SELECT DISTINCT t.asn, b.brand_name, b.provider_id
    FROM todo t JOIN brand b
      ON carrier_name_compact(b.brand_name) = carrier_name_compact(t.as_operator)
), fp AS (
    -- How big the candidate brand's footprint is. A PARENT company name
    -- matching the parent's own nationwide brand is the failure mode Boris
    -- named on 2026-11-21: Verizon owns Frontier, so AS5650 now carries the
    -- operator name Verizon Business, but the address space behind it serves
    -- FRONTIER's footprint. Matching it to the brand Verizon, which reaches
    -- 97% of tracts, would silently hand it half the country. The share is
    -- printed, not filtered, because AT&T's own ASN legitimately matches a
    -- nationwide brand and only Boris can tell the two apart.
    SELECT f.provider_id, f.brand_name, count(DISTINCT f.tract_geoid) AS brand_tracts
    FROM provider_brand_tract_tech_tbl f
    GROUP BY 1, 2
), fp_all AS (
    SELECT count(DISTINCT tract_geoid)::numeric AS tracts
    FROM provider_brand_tract_tech_tbl
), scored AS (
    SELECT p.asn, p.brand_name, p.provider_id,
           t.as_operator, t.as_operator_pct,
           t.isp_commonest, t.isp_commonest_pct,
           t.zip_capable_ranges, t.dma_only_ranges,
           carrier_name_tier(t.as_operator,   p.brand_name)      AS tier,
           carrier_name_tier(t.isp_commonest, p.brand_name)      AS tier_isp_agrees,
           f.brand_tracts,
           round(100.0 * f.brand_tracts / nullif(a.tracts, 0), 1) AS brand_tract_pct
    FROM pair p
    JOIN todo t ON t.asn = p.asn
    LEFT JOIN fp f ON f.provider_id = p.provider_id AND f.brand_name = p.brand_name
    CROSS JOIN fp_all a
), kept AS (
    SELECT * FROM scored WHERE tier IN (1, 2)
), ranked AS (
    SELECT *, row_number() OVER (PARTITION BY asn
                                 ORDER BY tier, brand_name) AS rank_for_asn
    FROM kept
)
SELECT * FROM ranked WHERE rank_for_asn <= 5;

CREATE INDEX asn_brand_cand_ix ON asn_brand_candidate_tbl (asn);
ANALYZE asn_brand_candidate_tbl;

SELECT count(*)                                AS candidate_rows,
       count(DISTINCT asn)                      AS asns_with_a_candidate,
       max(rank_for_asn)                        AS most_candidates_for_one_asn,
       count(*) FILTER (WHERE tier = 1)         AS tier1_exact,
       count(*) FILTER (WHERE tier = 2)         AS tier2_strong_containment
FROM asn_brand_candidate_tbl;

DO $guard$
DECLARE worst integer;
BEGIN
    SELECT max(c) INTO worst
    FROM (SELECT count(*) AS c FROM asn_brand_candidate_tbl GROUP BY asn) x;
    IF coalesce(worst, 0) > 5 THEN
        RAISE EXCEPTION 'CANDIDATE EXPLOSION: % candidates for one ASN, cap is 5.', worst;
    END IF;
    RAISE NOTICE 'candidate cap respected: worst ASN has % candidates', coalesce(worst, 0);
END
$guard$;

\echo
\echo The candidates for the ASNs with the most ZIP-capable address space.
\echo
SELECT c.asn, left(c.as_operator, 28) AS as_operator,
       left(coalesce(c.isp_commonest, ''), 22) AS ipapi_isp,
       c.provider_id, left(c.brand_name, 26) AS bdc_brand,
       c.tier, c.brand_tract_pct AS brand_pct_of_usa, c.zip_capable_ranges
FROM asn_brand_candidate_tbl c
ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn, c.rank_for_asn
LIMIT 60;

\echo
\echo Candidates whose brand covers more than half the country. Each one
\echo needs your eye: it is either the national brand of that carrier or a
\echo PARENT name sitting on the address space of a subsidiary.
\echo
SELECT c.asn, left(c.as_operator, 30) AS as_operator,
       c.provider_id, left(c.brand_name, 26) AS bdc_brand,
       c.tier, c.brand_tract_pct AS brand_pct_of_usa, c.zip_capable_ranges
FROM asn_brand_candidate_tbl c
WHERE c.brand_tract_pct > 50
ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn
LIMIT 40;

\echo
\echo ================================================================
\echo SECTION 3. ASNs with no candidate, by ZIP-capable address space.
\echo THIS IS NOT A LIST OF FAILURES. It holds three different things:
\echo carriers whose BDC brand differs from their name, such as Comcast
\echo filing as Xfinity; non-carriers, which Boris has ruled out of scope
\echo because ip-api locates them at their own premises and no headend
\echo inference is needed; and operators that file nothing with the FCC.
\echo Marking one out_of_scope decides it permanently.
\echo ================================================================
\echo
SELECT count(*) AS asns_with_no_candidate,
       sum(zip_capable_ranges) AS zip_capable_ranges_behind_them
FROM ipapi_asn_tbl a
WHERE NOT EXISTS (SELECT 1 FROM asn_brand_candidate_tbl c WHERE c.asn = a.asn)
  AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn);

SELECT a.asn, left(a.as_operator, 38) AS as_operator,
       left(coalesce(a.isp_commonest, ''), 28) AS ipapi_isp,
       a.isp_variants, a.zip_capable_ranges, a.dma_only_ranges
FROM ipapi_asn_tbl a
WHERE NOT EXISTS (SELECT 1 FROM asn_brand_candidate_tbl c WHERE c.asn = a.asn)
  AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn)
ORDER BY a.zip_capable_ranges DESC NULLS LAST
LIMIT 60;

\echo
\echo Writing two files, every row, with an empty column for your answer.
\echo
\copy (SELECT c.asn, c.as_operator, c.as_operator_pct, c.isp_commonest, c.isp_commonest_pct, c.provider_id, c.brand_name, c.tier, c.tier_isp_agrees, c.brand_tracts, c.brand_tract_pct, c.rank_for_asn, c.zip_capable_ranges, c.dma_only_ranges, NULL::text AS approved FROM asn_brand_candidate_tbl c ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn, c.rank_for_asn) TO '/home/boris/geo/asn_brand_candidates.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\copy (SELECT a.asn, a.as_operator, a.as_operator_pct, a.isp_commonest, a.isp_commonest_pct, a.org_commonest, a.isp_variants, a.zip_capable_ranges, a.dma_only_ranges, a.unclassified_ranges, NULL::text AS bdc_brand_or_out_of_scope FROM ipapi_asn_tbl a WHERE NOT EXISTS (SELECT 1 FROM asn_brand_candidate_tbl c WHERE c.asn = a.asn) AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn) ORDER BY a.zip_capable_ranges DESC NULLS LAST) TO '/home/boris/geo/asn_unmatched.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
