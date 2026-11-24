-- carrier_name_match.sql - match ip-api carrier names to BDC brand names by
-- NAME, at most five candidates per name, with a persistent approved map so
-- new names integrate automatically as more ranges are probed.
--
-- WHAT WENT WRONG WITH carrier_name_approval.tsv, exactly
--
-- Boris: "Your file carrier_name_approval.tsv is completely wrong. It
-- doesn't match. Rows 1-205 match Comcast to 205 different, often competing
-- carriers. Your matching algorithm is completely useless; I thought you
-- debugged and tested it."
--
-- The cause is structural and was in my own design. Candidates for an
-- ip-api name were the UNION over every ITDK domain reporting that name of
-- every wireline brand filing service in that domain's site tracts.
-- comcast.net alone has 788 sites in 508 cities, and hundreds of customer
-- domains also report Comcast's name, so the union is every wireline brand
-- in 508 American cities. Of course it listed the competitors: I asked for
-- everyone who serves where Comcast has equipment.
--
-- And I told him it was tested. It was tested on a fixture with one domain
-- per ip-api name and a handful of brands, which cannot exhibit the fault.
-- A fixture that cannot produce the failure is not a test. Two guards now
-- exist so this class of error cannot ship again:
--
--   1. candidates are capped at five per name BY CONSTRUCTION, and
--   2. section 4 ABORTS the file if any name exceeds that cap, so the
--      explosion fails loudly here instead of arriving as a spreadsheet.
--
-- WHY GEOGRAPHY IS NOT THE GENERATOR ANY MORE
--
-- Boris asked, three times, for a match between the NAMES in ip-api.com and
-- the names in the BDC. A name match is what this does. Geography appears
-- only as a confirmation column on candidates that a name match already
-- proposed, which is bounded at five rows and cannot explode.
--
-- THE NORMALISATION, and how it fixes the original bug
--
-- The rule being replaced was substring containment between normalised
-- names, which is how a reported 'Comcast Cable Communications' reached a
-- brand ending in 'COMMUNICATIONS'. The reason it could is that
-- 'communications' carries no information: nearly every carrier has it.
--
-- So names are reduced to TOKEN SETS with the generic words removed:
-- communications, telecom, telephone, networks, broadband, fiber, cable,
-- internet, services, holdings, inc, llc, corp, company and so on. Then
-- 'Comcast Cable Communications LLC' is {comcast} and 'USA COMMUNICATIONS'
-- is {usa}: no overlap, no match, which is the correct answer and the one
-- the old rule got wrong.
--
-- Two safeguards in the reduction:
--
--   A name that is ENTIRELY generic keeps its words rather than becoming
--   empty, so 'USA Communications' stays {usa, communications} instead of
--   {} and remains matchable to itself. An empty token set never matches
--   anything.
--
--   A compact key, the name with every non-alphanumeric removed, is
--   compared as well, because AT&T tokenises to {at, t} and would otherwise
--   fail against the brand 'AT&T'. Compacted, both are 'att'.
--
-- WHAT THIS CANNOT DO, said plainly
--
-- Comcast's brand in the BDC is Xfinity. 'Comcast' and 'Xfinity' share
-- nothing, in any measure, and no string method will ever join them. Such
-- names come out in the NO CANDIDATE list, which is where they belong:
-- that list is Boris's to name, and it is short.
--
-- AUTOMATIC INTEGRATION, which is Boris's other requirement
--
-- "Only around half the decomposed ranges in ip2city_dbiplite_tbl has so
-- far been probed through ip-api.com. Therefore small/REI providers new to
-- us are likely to occur in the other half. Their integration should be
-- automatic."
--
-- ipapi_bdc_name_map_tbl is PERSISTENT and is never rebuilt by this file.
-- Each run reads every ip-api name present in the probe table, subtracts
-- the ones already decided, and proposes candidates for the remainder only.
-- So when the second half of the ranges is probed, re-running this asks
-- about the new names and nothing else. Approved decisions are matched on
-- the normalised name, so a trivially different spelling of an already
-- decided carrier does not come back.
--
-- PRE-MORTEM. Creates two functions and three tables. ipapi_bdc_name_map_tbl
-- is created IF NOT EXISTS and is NEVER dropped or truncated here, because
-- it holds Boris's decisions; the other two are working tables and are
-- dropped first. Nothing else is written. The probe table, the crosswalk,
-- the decision tables and the step 4 inputs are all read-only.

-- ON_ERROR_STOP IS NOT OPTIONAL. The previous run of this file hit one
-- missing column and then emitted fifteen further errors about tables that
-- were never created, burying the real cause. The first failure must be the
-- last line of output.
\set ON_ERROR_STOP on
\timing on

\echo
\echo ================================================================
\echo PRECHECK. This BLOCKS rather than prints.
\echo
\echo I guessed a column name yesterday and again today. Today it was
\echo likely_mobile_cgnat, which Boris named in prose and which
\echo geo/mobile_transit_migration.sql has since renamed to
\echo mobile_transit. Worse than the guess: this file already queried
\echo information_schema for that exact column, printed five rows where
\echo six were asked for, and then used the missing column anyway. A
\echo check that cannot stop the run is decoration.
\echo ================================================================
\echo
SELECT 'ip2city_dbiplite_probe_tbl' AS tbl, column_name, data_type
FROM information_schema.columns
WHERE table_name = 'ip2city_dbiplite_probe_tbl'
  AND column_name IN ('isp', 'org', 'as', 'ran_at', 'network',
                      'mobile_transit', 'likely_mobile_cgnat')
ORDER BY column_name;

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(c.needed, ', ')
      INTO missing
    FROM (VALUES ('isp'), ('org'), ('as'), ('ran_at')) AS c(needed)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns i
        WHERE i.table_name = 'ip2city_dbiplite_probe_tbl'
          AND i.column_name = c.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION
          'ip2city_dbiplite_probe_tbl is missing the column(s) %. Nothing was built.',
          missing;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'bdc_carrier_tbl'
                     AND column_name = 'brand_name') THEN
        RAISE EXCEPTION 'bdc_carrier_tbl has no brand_name column. Nothing was built.';
    END IF;

    RAISE NOTICE 'precheck passed: every column this file reads exists';
END
$precheck$;

-- ---------------------------------------------------------------------------
-- The two reductions, as functions so they are testable and reusable.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION carrier_name_tokens(raw text)
RETURNS text[] AS $fn$
WITH split AS (
    SELECT array_remove(
             regexp_split_to_array(
               lower(regexp_replace(coalesce(raw, ''), '[^a-zA-Z0-9]+', ' ', 'g')),
               ' +'),
             '') AS all_tok
), kept AS (
    SELECT all_tok,
           ARRAY(SELECT x FROM unnest(all_tok) AS x
                 WHERE x <> ALL (ARRAY[
                     'inc','llc','l','c','corp','corporation','company','co',
                     'communications','communication','comm','telecom',
                     'telecommunications','telephone','tel','networks',
                     'network','broadband','fiber','fibre','cable','internet',
                     'services','service','solutions','solution','holdings',
                     'holding','group','the','of','and','a','an','lp','llp',
                     'ltd','plc','technologies','technology','tech','systems',
                     'system','digital','online','media','enterprises',
                     'enterprise','partners','associates','cooperative',
                     'coop','utilities','utility','wireless','telephony',
                     'data','access','link','net','web','global','america',
                     'american','national','usa','us','incorporated'])) AS tok
    FROM split
)
-- A name that is ENTIRELY generic keeps its own words rather than reducing
-- to the empty set, which would otherwise make it match nothing at all.
SELECT CASE WHEN cardinality(tok) > 0 THEN tok ELSE all_tok END FROM kept;
$fn$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION carrier_name_compact(raw text)
RETURNS text AS $fn$
SELECT nullif(regexp_replace(lower(coalesce(raw, '')), '[^a-z0-9]', '', 'g'), '');
$fn$ LANGUAGE sql IMMUTABLE;

\echo
\echo ================================================================
\echo SECTION 0. THE SELF TEST, on cases whose answer we both know,
\echo printed BEFORE the output so the matcher can be judged on them
\echo rather than on twenty thousand rows. This is what I failed to do.
\echo ================================================================
\echo
SELECT raw,
       carrier_name_tokens(raw)  AS tokens,
       carrier_name_compact(raw) AS compact
FROM (VALUES ('Comcast Cable Communications, LLC'),
             ('Xfinity'),
             ('USA COMMUNICATIONS'),
             ('Cox Communications'),
             ('Cox Communications Inc.'),
             ('Frontier Communications Solutions'),
             ('Frontier'),
             ('AT&T Enterprises, LLC'),
             ('AT&T'),
             ('Quantum Fiber'),
             ('Hurricane Electric LLC'),
             ('123.Net, Inc.'),
             ('Windstream Standard, LLC'),
             ('T-Mobile'),
             ('lumos')) AS v(raw);

\echo
\echo The pairs that matter, with the verdict the rules below will reach.
\echo Comcast against Xfinity MUST NOT match: nothing can join those two
\echo strings and pretending otherwise is how the last file went wrong.
\echo Comcast against USA COMMUNICATIONS MUST NOT match: that is the
\echo original bug. The rest MUST match.
\echo
SELECT a, b,
       (carrier_name_compact(a) = carrier_name_compact(b))   AS compact_equal,
       (carrier_name_tokens(a) <@ carrier_name_tokens(b)
        OR carrier_name_tokens(b) <@ carrier_name_tokens(a)) AS token_subset,
       cardinality(ARRAY(SELECT unnest(carrier_name_tokens(a))
                         INTERSECT
                         SELECT unnest(carrier_name_tokens(b))))
                                                             AS shared_tokens,
       expected
FROM (VALUES
       ('Comcast Cable Communications, LLC', 'Xfinity',            'must NOT match'),
       ('Comcast Cable Communications, LLC', 'USA COMMUNICATIONS', 'must NOT match'),
       ('Comcast Cable Communications, LLC', 'Spectrum',           'must NOT match'),
       ('Cox Communications',                'Cox Communications', 'must match'),
       ('Frontier Communications Solutions', 'Frontier',           'must match'),
       ('AT&T Enterprises, LLC',             'AT&T',               'must match'),
       ('123.Net, Inc.',                     '123.NET Inc',        'must match'),
       ('Windstream Standard, LLC',          'Windstream',         'must match')
     ) AS v(a, b, expected);

-- ---------------------------------------------------------------------------
-- The persistent decision map. NEVER dropped by this file.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipapi_bdc_name_map_tbl (
    ipapi_name       text PRIMARY KEY,
    ipapi_name_norm  text NOT NULL,
    decision         text NOT NULL
                     CHECK (decision IN ('brand', 'not_a_carrier', 'unknown')),
    bdc_brand_name   text,
    bdc_provider_id  integer,
    note             text,
    approved_at      timestamptz NOT NULL DEFAULT now());

CREATE INDEX IF NOT EXISTS ipapi_bdc_name_map_norm_ix
    ON ipapi_bdc_name_map_tbl (ipapi_name_norm);

COMMENT ON TABLE ipapi_bdc_name_map_tbl IS
'Boris-approved mapping from an ip-api carrier name to a BDC brand. PERSISTENT: carrier_name_match.sql never drops or truncates it, and each run proposes candidates only for ip-api names absent from it. That is what makes integration of new carriers automatic as the remaining half of the decomposed ranges is probed. Matching on ipapi_name_norm as well as the raw name means a differently punctuated spelling of an already decided carrier does not come back for a second decision.';

SELECT count(*)                                        AS decisions_already_held,
       count(*) FILTER (WHERE decision = 'brand')      AS mapped_to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier') AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'unknown')    AS unknown
FROM ipapi_bdc_name_map_tbl;

\echo
\echo ================================================================
\echo SECTION 1. Every ip-api carrier name in the probe table, with the
\echo address space behind it. This is the whole population, including
\echo the names that have no ITDK node, so a carrier found only in the
\echo probed ranges is not lost.
\echo ================================================================
\echo
-- THE ACCURACY TIER IS DISCOVERED, NOT ASSUMED. Boris referred to
-- likely_mobile_cgnat, a boolean; geo/mobile_transit_migration.sql replaces
-- it on four tables with mobile_transit, a one-character code whose
-- meaning that file states: 'm' mobile CGNAT, 't' transit, both DMA
-- accuracy; 'f' fixed, the only tier that can carry a ZIP; NULL not yet
-- classified, deliberately not folded into 'f'. Whether a given database
-- is before or after that migration is not something I can know from here,
-- so the column is looked up and the query composed around whichever
-- exists. If neither does, the tier counts come back NULL and the run
-- continues, because name matching does not depend on them.
DROP TABLE IF EXISTS ipapi_name_tbl;

DO $build$
DECLARE tier_col text;
        zip_expr  text;
        dma_expr  text;
        unk_expr  text;
BEGIN
    SELECT i.column_name INTO tier_col
    FROM information_schema.columns i
    WHERE i.table_name = 'ip2city_dbiplite_probe_tbl'
      AND i.column_name IN ('mobile_transit', 'likely_mobile_cgnat')
    ORDER BY CASE i.column_name WHEN 'mobile_transit' THEN 1 ELSE 2 END
    LIMIT 1;

    IF tier_col = 'mobile_transit' THEN
        zip_expr := 'count(*) FILTER (WHERE p.mobile_transit = ''f'')';
        dma_expr := 'count(*) FILTER (WHERE p.mobile_transit IN (''m'', ''t''))';
        unk_expr := 'count(*) FILTER (WHERE p.mobile_transit IS NULL)';
        RAISE NOTICE 'accuracy tier read from mobile_transit: f is ZIP capable, m and t are DMA only';
    ELSIF tier_col = 'likely_mobile_cgnat' THEN
        zip_expr := 'count(*) FILTER (WHERE p.likely_mobile_cgnat IS FALSE)';
        dma_expr := 'count(*) FILTER (WHERE p.likely_mobile_cgnat IS TRUE)';
        unk_expr := 'count(*) FILTER (WHERE p.likely_mobile_cgnat IS NULL)';
        RAISE NOTICE 'accuracy tier read from the pre-migration boolean likely_mobile_cgnat';
    ELSE
        zip_expr := 'NULL::bigint';
        dma_expr := 'NULL::bigint';
        unk_expr := 'count(*)';
        RAISE NOTICE 'NEITHER mobile_transit NOR likely_mobile_cgnat exists on the probe table; every range is reported as unclassified and none is excluded on that basis';
    END IF;

    EXECUTE format($q$
        CREATE TABLE ipapi_name_tbl AS
        SELECT p.isp                       AS ipapi_name,
               carrier_name_compact(p.isp) AS name_compact,
               carrier_name_tokens(p.isp)  AS name_tokens,
               count(*)                    AS ranges,
               %s                          AS zip_capable_ranges,
               %s                          AS dma_only_ranges,
               %s                          AS unclassified_ranges,
               max(p.org)                  AS an_org,
               max(p."as")                 AS an_as
        FROM ip2city_dbiplite_probe_tbl p
        WHERE p.ran_at IS NOT NULL
          AND p.isp IS NOT NULL AND p.isp <> ''
        GROUP BY 1, 2, 3 $q$, zip_expr, dma_expr, unk_expr);
END
$build$;

ALTER TABLE ipapi_name_tbl ADD PRIMARY KEY (ipapi_name);
CREATE INDEX ipapi_name_compact_ix ON ipapi_name_tbl (name_compact);
ANALYZE ipapi_name_tbl;

SELECT count(*)                                              AS ipapi_names,
       sum(ranges)                                           AS probed_ranges,
       count(*) FILTER (WHERE zip_capable_ranges = 0
                          AND dma_only_ranges > 0)             AS names_wholly_dma_only,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM ipapi_bdc_name_map_tbl m
         WHERE m.ipapi_name = ipapi_name_tbl.ipapi_name))     AS already_decided
FROM ipapi_name_tbl;

\echo
\echo ================================================================
\echo SECTION 2. Candidates, by NAME, at most five per ip-api name.
\echo Ranked: compact-key equality first, then one token set contained in
\echo the other, then shared tokens.
\echo ================================================================
\echo
DROP TABLE IF EXISTS ipapi_name_candidate_tbl;
CREATE TABLE ipapi_name_candidate_tbl AS
WITH todo AS (
    SELECT n.*
    FROM ipapi_name_tbl n
    WHERE NOT EXISTS (SELECT 1 FROM ipapi_bdc_name_map_tbl m
                      WHERE m.ipapi_name = n.ipapi_name
                         OR m.ipapi_name_norm = n.name_compact)
), brand AS (
    SELECT DISTINCT c.brand_name,
           c.provider_id,
           carrier_name_compact(c.brand_name) AS brand_compact,
           carrier_name_tokens(c.brand_name)  AS brand_tokens
    FROM bdc_carrier_tbl c
    WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
), generic AS (
    -- DEFECT 3, found by the self test. A name whose every word is generic
    -- keeps its words rather than reducing to the empty set, which is
    -- necessary so that 'USA COMMUNICATIONS' remains matchable to itself.
    -- But it means such a name re-enters the shared-token path carrying
    -- 'communications', and on the fixture 'Fiber Internet Communications'
    -- duly matched 'USA COMMUNICATIONS' on that one word. That is the
    -- original bug returning through the back door. A generic-only name is
    -- therefore allowed to match ONLY by compact-key equality or by whole
    -- token-set containment, never by a single shared word.
    SELECT ipapi_name,
           (carrier_name_tokens(ipapi_name)
            && ARRAY['communications','communication','comm','telecom',
                     'telecommunications','telephone','networks','network',
                     'broadband','fiber','fibre','cable','internet',
                     'services','solutions','holdings','group','usa','us',
                     'america','american','national','data','access','link',
                     'net','web','global','wireless','technologies',
                     'systems','digital','media','enterprises','utilities',
                     'cooperative','partners','associates'])  AS is_generic_only
    FROM todo
), ntok AS (
    -- DEFECT 2, found by the self test. 'T-Mobile USA, Inc.' reduces to
    -- {t, mobile} and 'AT&T' to {at, t}, so they shared the single letter
    -- 't' and T-Mobile was offered AT&T as a candidate. One-character
    -- tokens carry no information. Excluding them costs nothing, because
    -- AT&T still reaches the brand AT&T through {at} and through the
    -- compact key 'att'.
    SELECT ipapi_name, tok FROM todo, unnest(name_tokens) AS tok
    WHERE length(tok) >= 2
), btok AS (
    SELECT brand_name, provider_id, tok
    FROM brand, unnest(brand_tokens) AS tok
    WHERE length(tok) >= 2
), shared AS (
    -- The inverted token index. Only names and brands sharing at least one
    -- INFORMATIVE token are ever compared, which is what keeps this cheap
    -- and is also what stops 'communications' pairing everything with
    -- everything: it is not in the token sets at all.
    SELECT n.ipapi_name, b.brand_name, b.provider_id, count(*) AS shared_tokens
    FROM ntok n JOIN btok b ON b.tok = n.tok
    GROUP BY 1, 2, 3
), scored AS (
    SELECT t.ipapi_name, t.ranges, t.name_tokens,
           br.brand_name, br.provider_id,
           coalesce(s.shared_tokens, 0)                       AS shared_tokens,
           (t.name_compact = br.brand_compact)                AS compact_equal,
           (t.name_tokens <@ br.brand_tokens)                 AS name_within_brand,
           (br.brand_tokens <@ t.name_tokens)                 AS brand_within_name,
           cardinality(t.name_tokens)                         AS name_token_count,
           cardinality(br.brand_tokens)                       AS brand_token_count
    FROM todo t
    JOIN shared s ON s.ipapi_name = t.ipapi_name
    JOIN brand br ON br.brand_name = s.brand_name
                  AND br.provider_id = s.provider_id
    UNION
    -- A compact-key match with no shared token, which is how AT&T reaches
    -- the brand AT&T: tokenised it is {at, t} against {at, t}, but the
    -- stoplist can empty one side in other cases, so this path is kept
    -- independent of the token index.
    SELECT t.ipapi_name, t.ranges, t.name_tokens,
           br.brand_name, br.provider_id,
           0, true,
           (t.name_tokens <@ br.brand_tokens),
           (br.brand_tokens <@ t.name_tokens),
           cardinality(t.name_tokens), cardinality(br.brand_tokens)
    FROM todo t
    JOIN brand br ON br.brand_compact = t.name_compact
), deduped AS (
    -- DEFECT 1, found by the self test. The UNION of the token path and
    -- the compact path produced TWO rows for Cox Communications against
    -- the same brand and provider, because the two paths disagreed on
    -- shared_tokens and UNION only removes rows identical in every column.
    -- Collapsing on the real key, which is the name and the brand and the
    -- provider, and keeping the strongest evidence from either path.
    SELECT ipapi_name, ranges, name_tokens, brand_name, provider_id,
           max(shared_tokens)          AS shared_tokens,
           bool_or(compact_equal)      AS compact_equal,
           bool_or(name_within_brand)  AS name_within_brand,
           bool_or(brand_within_name)  AS brand_within_name,
           max(name_token_count)       AS name_token_count,
           max(brand_token_count)      AS brand_token_count
    FROM scored
    GROUP BY 1, 2, 3, 4, 5
), tiered AS (
    SELECT d.*,
           CASE WHEN d.compact_equal                              THEN 1
                WHEN d.brand_within_name OR d.name_within_brand   THEN 2
                ELSE 3 END                                        AS tier,
           g.is_generic_only
    FROM deduped d
    JOIN generic g ON g.ipapi_name = d.ipapi_name
), kept AS (
    -- The generic-only restriction from defect 3 applied: such a name may
    -- keep tier 1 and tier 2 candidates but not tier 3.
    SELECT * FROM tiered
    WHERE NOT (is_generic_only AND tier = 3)
), ranked AS (
    SELECT *,
           row_number() OVER (
             PARTITION BY ipapi_name
             ORDER BY tier,
                      shared_tokens DESC,
                      abs(brand_token_count - name_token_count),
                      brand_name)                        AS rank_for_name
    FROM kept
)
SELECT * FROM ranked WHERE rank_for_name <= 5;

CREATE INDEX ipapi_name_cand_ix ON ipapi_name_candidate_tbl (ipapi_name);
ANALYZE ipapi_name_candidate_tbl;

SELECT count(*)                         AS candidate_rows,
       count(DISTINCT ipapi_name)        AS names_with_a_candidate,
       max(rank_for_name)                AS max_candidates_for_one_name,
       count(*) FILTER (WHERE tier = 1)  AS tier1_compact_equal,
       count(*) FILTER (WHERE tier = 2)  AS tier2_token_subset,
       count(*) FILTER (WHERE tier = 3)  AS tier3_shared_token_only
FROM ipapi_name_candidate_tbl;

\echo
\echo ================================================================
\echo SECTION 3. THE GUARD. The previous file gave Comcast 205
\echo candidates. If any name here exceeds five, this stops.
\echo ================================================================
\echo
DO $guard$
DECLARE worst integer;
        worst_name text;
BEGIN
    SELECT max(c), (SELECT ipapi_name FROM (
                      SELECT ipapi_name, count(*) AS c
                      FROM ipapi_name_candidate_tbl GROUP BY 1
                      ORDER BY 2 DESC LIMIT 1) x)
      INTO worst, worst_name
    FROM (SELECT count(*) AS c FROM ipapi_name_candidate_tbl
          GROUP BY ipapi_name) y;
    IF worst > 5 THEN
        RAISE EXCEPTION
          'CANDIDATE EXPLOSION: % has % candidates, cap is 5. Nothing was written for approval.',
          worst_name, worst;
    END IF;
    RAISE NOTICE 'candidate cap respected: the worst name has % candidates', coalesce(worst, 0);
END
$guard$;

\echo
\echo ================================================================
\echo SECTION 4. The names with NO name candidate at all, ordered by the
\echo address space behind them. Comcast belongs here, because its BDC
\echo brand is Xfinity and no string method can join those. This list is
\echo yours to name; it is the short one and it is the valuable one.
\echo ================================================================
\echo
SELECT count(*)                  AS names_with_no_candidate,
       sum(ranges)               AS ranges_behind_them
FROM ipapi_name_tbl n
WHERE NOT EXISTS (SELECT 1 FROM ipapi_name_candidate_tbl c
                  WHERE c.ipapi_name = n.ipapi_name)
  AND NOT EXISTS (SELECT 1 FROM ipapi_bdc_name_map_tbl m
                  WHERE m.ipapi_name = n.ipapi_name);

SELECT left(n.ipapi_name, 40) AS ipapi_name,
       left(coalesce(n.an_org, ''), 26) AS ipapi_org,
       left(coalesce(n.an_as, ''), 30)  AS ipapi_as,
       n.ranges, n.zip_capable_ranges, n.dma_only_ranges,
       n.unclassified_ranges
FROM ipapi_name_tbl n
WHERE NOT EXISTS (SELECT 1 FROM ipapi_name_candidate_tbl c
                  WHERE c.ipapi_name = n.ipapi_name)
  AND NOT EXISTS (SELECT 1 FROM ipapi_bdc_name_map_tbl m
                  WHERE m.ipapi_name = n.ipapi_name)
ORDER BY n.ranges DESC
LIMIT 60;

\echo
\echo ================================================================
\echo SECTION 5. The candidates, printed for the names with the most
\echo address space behind them. tier 1 is compact-key equality and
\echo should need no thought; tier 3 shares one token and needs yours.
\echo ================================================================
\echo
SELECT left(c.ipapi_name, 34) AS ipapi_name,
       c.ranges,
       c.rank_for_name AS rk,
       c.tier,
       c.provider_id,
       left(c.brand_name, 30) AS bdc_brand_name,
       c.shared_tokens AS shared,
       c.compact_equal, c.brand_within_name, c.name_within_brand
FROM ipapi_name_candidate_tbl c
ORDER BY c.ranges DESC, c.ipapi_name, c.rank_for_name
LIMIT 80;

\echo
\echo Writing two files. Both carry every row.
\echo   carrier_name_candidates.tsv  the candidates, with an empty
\echo                                approved column per ip-api name.
\echo   carrier_name_unmatched.tsv   the names no brand name resembles.
\echo
\copy (SELECT c.ipapi_name, c.ranges, c.rank_for_name, c.tier, c.provider_id, c.brand_name, c.shared_tokens, c.compact_equal, c.brand_within_name, c.name_within_brand, n.an_org AS ipapi_org, n.an_as AS ipapi_as, n.zip_capable_ranges, n.dma_only_ranges, n.unclassified_ranges, NULL::text AS approved FROM ipapi_name_candidate_tbl c JOIN ipapi_name_tbl n ON n.ipapi_name = c.ipapi_name ORDER BY c.ranges DESC, c.ipapi_name, c.rank_for_name) TO '/home/boris/geo/carrier_name_candidates.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\copy (SELECT n.ipapi_name, n.ranges, n.zip_capable_ranges, n.dma_only_ranges, n.unclassified_ranges, n.an_org AS ipapi_org, n.an_as AS ipapi_as, NULL::text AS bdc_brand_name_you_give FROM ipapi_name_tbl n WHERE NOT EXISTS (SELECT 1 FROM ipapi_name_candidate_tbl c WHERE c.ipapi_name = n.ipapi_name) AND NOT EXISTS (SELECT 1 FROM ipapi_bdc_name_map_tbl m WHERE m.ipapi_name = n.ipapi_name) ORDER BY n.ranges DESC) TO '/home/boris/geo/carrier_name_unmatched.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
