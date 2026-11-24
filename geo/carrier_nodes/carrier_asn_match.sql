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
  -- connect, from Boris 2026-11-23: "Wave Rural Connect, LLC and Fuse Rural
  -- Connect, LLC are separate companies." Those two reached each other at
  -- tier 2 and the reason is worth recording. wave is already a stopword, on
  -- his earlier ruling that it does not indicate equality, so the
  -- DISTINCTIVE word of the first name was already gone and the pair was
  -- being compared on the generic remainder rural connect against fuse rural
  -- connect. Making connect noise as well leaves {rural} against
  -- {fuse,rural}, which is a single shared word, tier 3, and not offered.
  -- rural is deliberately NOT a stopword: he confirmed AS14155 Rural
  -- Telephone Service Co against RURAL TELEPHONE COMPANY, and stopping
  -- rural would reduce that name to nothing and lose the match.
  'connect','connects','connection','connections',
  -- geographic and patriotic filler
  'america','american','national','usa','us','the','of','and','a','an',
  -- modifiers Boris named on 2026-11-20, each having produced a wrong match
  'business','cablevision','one','united','wave',
  -- com, the top-level domain. My notes claimed this was already here and
  -- the code said otherwise, found 2026-11-22 by printing the tokens:
  -- carrier_name_tokens('Amazon.com, Inc.') returned {amazon,com}. It makes
  -- every .com name share a word with every other .com name, which is three
  -- of the reject cases in the gate and a large wasted cross product during
  -- candidate generation. No accept case depends on it.
  'com',
  -- Retail and administrative words Boris named on 2026-11-22, each from a
  -- wrong relation in the near-miss report:
  --   mart    Database Mart LLC was related to Wal-Mart Stores, Inc.
  --   stores  Winn-Dixie Stores, Inc. was related to Wal-Mart Stores, Inc.
  --   dept    several registrants were related to State of WI Dept. of
  --           Administration
  'mart','stores','store','dept','department','administration','division',
  'office','bureau','agency','authority','commission','county','city','town',
  -- state and states, for the same reason: on Boris's run a dozen "State of
  -- X" registrants were relating to each other on the shared word alone.
  'state','states'];
$fn$ LANGUAGE sql IMMUTABLE;

-- Two-letter US state and territory abbreviations, matched ONLY WHEN THE
-- ORIGINAL TEXT IS UPPERCASE. Boris 2026-11-22 named this: my first version
-- tested them against the lowercased word, which destroys the ordinary words
-- in, or, me, hi, de, la, ma, pa, ok, id and twenty more wherever they appear
-- inside a real carrier name. WI is a state; wi is not.
CREATE OR REPLACE FUNCTION carrier_name_state_abbrevs()
RETURNS text[] AS $fn$
SELECT ARRAY[
  'AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL',
  'IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE',
  'NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD',
  'TN','TX','UT','VT','VA','WA','WV','WI','WY','PR','VI','GU'];
$fn$ LANGUAGE sql IMMUTABLE;

-- US state and territory names, in full. Used ONLY by the state government
-- test below, never as stopwords: a state name is often the only
-- informative word a real carrier has, as in ALASKA COMMUNICATIONS, and
-- stopping it would reduce that brand to nothing.
CREATE OR REPLACE FUNCTION carrier_name_state_names()
RETURNS text[] AS $fn$
SELECT ARRAY[
  'alabama','alaska','arizona','arkansas','california','colorado',
  'connecticut','delaware','florida','georgia','hawaii','idaho','illinois',
  'indiana','iowa','kansas','kentucky','louisiana','maine','maryland',
  'massachusetts','michigan','minnesota','mississippi','missouri','montana',
  'nebraska','nevada','new hampshire','new jersey','new mexico','new york',
  'north carolina','north dakota','ohio','oklahoma','oregon',
  'pennsylvania','rhode island','south carolina','south dakota','tennessee',
  'texas','utah','vermont','virginia','washington','west virginia',
  'wisconsin','wyoming','district of columbia','puerto rico','guam',
  'virgin islands','american samoa','northern mariana islands'];
$fn$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------------------
-- IS THIS NAME A STATE GOVERNMENT? Boris 2026-11-23: "State of Alaska has no
-- relation to any of the three Alaska entities you paired with it."
--
-- Stopwords cannot fix this and in fact caused it. state and states are
-- already noise, on his 2026-11-22 ruling, so State of Alaska reduces to the
-- single token {alaska}, and every carrier named after the state reduces to
-- the same single token: ALASKA COMMUNICATIONS, Alaska Telephone Company and
-- Fibre Alaska all become {alaska}. Token equality then scores tier 1. The
-- more words I stopped, the MORE things these names matched.
--
-- The information that separates them is in the words the tokeniser threw
-- away. State of X is a state; X Communications is a company. So this tests
-- the shape of the whole name instead of its tokens.
--
-- Deliberately narrow. It does NOT catch City of X or County of X, because
-- municipal utilities are real carriers: AS397142 City of Fort Collins holds
-- Fort Collins Connexion, which is a genuine municipal ISP, and Carthage
-- Water and Electric is another. It does not catch U.S. Department of State,
-- which is a federal department and not a state. It does not catch
-- Washington State K-20 Telecommunications Network or Pennsylvania State
-- University, because the name continues past the word state.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION carrier_name_is_state_government(raw text)
RETURNS boolean AS $fn$
-- A CHEAP TEST FIRST, THEN THE SAME DETAILED ONE. Measured on Boris's run
-- 2026-11-24: the detailed form, which unnested 56 state names and ran LIKE
-- against each, cost 128 SECONDS per report over his 19,936 ASNs, and
-- several reports call it. That is most of the twelve minutes that run took.
-- Almost no name has the SHAPE of a state government, so one regular
-- expression rejects the overwhelming majority before a single state name is
-- looked at. The detailed test is unchanged, so the answer is identical.
WITH shape AS (
    SELECT s,
           s ~ '^(the )?(state|commonwealth|territory) of ' AS has_prefix,
           s ~ ' state( government)?$'                      AS has_suffix,
           s ~ ' state (government|department|office) '     AS has_middle
    FROM (SELECT btrim(regexp_replace(
                   regexp_replace(lower(coalesce(raw, '')), '[^a-z0-9]+', ' ', 'g'),
                   ' +', ' ', 'g')) AS s) n
)
SELECT CASE
  WHEN NOT (shape.has_prefix OR shape.has_suffix OR shape.has_middle) THEN false
  ELSE EXISTS (
        SELECT 1 FROM unnest(carrier_name_state_names()) AS t(st)
        WHERE shape.s = 'state of ' || t.st
           OR shape.s = 'the state of ' || t.st
           OR shape.s = 'commonwealth of ' || t.st
           OR shape.s = 'territory of ' || t.st
           OR shape.s = t.st || ' state'
           OR shape.s = t.st || ' state government'
           OR shape.s = 'state of ' || t.st || ' government'
           OR shape.s LIKE 'state of ' || t.st || ' %'
           OR shape.s LIKE 'commonwealth of ' || t.st || ' %'
           OR shape.s LIKE t.st || ' state government %'
           OR shape.s LIKE t.st || ' state department %'
           OR shape.s LIKE t.st || ' state office %')
    OR EXISTS (
        SELECT 1 FROM unnest(carrier_name_state_abbrevs()) AS t(ab)
        WHERE raw ~ ('^[Tt]he [Ss]tate of ' || t.ab || '([^A-Za-z]|$)')
           OR raw ~ ('^[Ss]tate of ' || t.ab || '([^A-Za-z]|$)')
           OR raw ~ ('^[Cc]ommonwealth of ' || t.ab || '([^A-Za-z]|$)'))
  END
FROM shape;
$fn$ LANGUAGE sql IMMUTABLE;

-- IT BLOCKS, AND IT TESTS BOTH DIRECTIONS. A false positive here silently
-- removes a real carrier from the universe, which is the same damage as the
-- compact-key defect that deleted 769 decisions, arriving by a new route.
-- Municipal broadband is the exposure: City of Fort Collins holds Fort
-- Collins Connexion, and Carthage Water and Electric holds its own plant.
-- The negative cases below are taken from Boris's own run, not invented.
DO $gov$
DECLARE failures text[] := ARRAY[]::text[];
        name      text;
BEGIN
    FOREACH name IN ARRAY ARRAY[
        'State of Alaska', 'state of alaska', 'STATE OF ALASKA',
        'The State of New Mexico', 'State of South Carolina',
        'State of North Dakota, ITD', 'New York State',
        'South Dakota State Government', 'Commonwealth of Pennsylvania',
        'State of WI Dept. of Administration']
    LOOP
        IF NOT carrier_name_is_state_government(name) THEN
            failures := failures || format('%L should be recognised as a state government and is not', name);
        END IF;
    END LOOP;

    FOREACH name IN ARRAY ARRAY[
        -- real carriers whose only informative token is a state name
        'Alaska Communications System', 'ALASKA COMMUNICATIONS',
        'Alaska Telephone Company', 'Fibre Alaska',
        'WESTERN NEW MEXICO TELEPHONE COMPANY', 'Windstream New York, Inc.',
        -- municipal and cooperative holders, which ARE carriers
        'City of Fort Collins', 'Fort Collins Connexion',
        'The City of New York', 'Carthage Water and Electric',
        -- a federal department, which is not a state
        'U.S. Department of State',
        -- and names that merely contain the word state
        'Washington State K-20 Telecommunications Network',
        'Pennsylvania State University', 'Penn State Telephone Co']
    LOOP
        IF carrier_name_is_state_government(name) THEN
            failures := failures || format('%L is NOT a state government and was classified as one, so it would be dropped from the carrier universe', name);
        END IF;
    END LOOP;

    IF cardinality(failures) > 0 THEN
        RAISE EXCEPTION E'THE STATE GOVERNMENT TEST IS WRONG:\n%', array_to_string(failures, E'\n');
    END IF;
    RAISE NOTICE 'state government test: 10 positive and 14 negative cases all correct';
END
$gov$;

CREATE OR REPLACE FUNCTION carrier_name_words(raw text)
RETURNS text[] AS $fn$
SELECT array_remove(
         regexp_split_to_array(
           btrim(regexp_replace(lower(coalesce(raw, '')), '[^a-z0-9]+', ' ', 'g')),
           ' '),
         '');
$fn$ LANGUAGE sql IMMUTABLE;

-- The words of a name with their ORIGINAL CASE preserved, which is what the
-- state-abbreviation test needs.
CREATE OR REPLACE FUNCTION carrier_name_words_cased(raw text)
RETURNS text[] AS $fn$
SELECT array_remove(
         regexp_split_to_array(
           btrim(regexp_replace(coalesce(raw, ''), '[^A-Za-z0-9]+', ' ', 'g')),
           ' '),
         '');
$fn$ LANGUAGE sql IMMUTABLE;

-- One predicate for "this word cannot identify a company", used by the token
-- builder and the generic-only test so they can never disagree. It takes the
-- word AS WRITTEN, because case carries meaning for the state abbreviations.
--
-- A BARE NUMBER is noise. Boris 2026-11-22: Colonial IU 20 was relating to
-- Washington State K-20 Telecommunications Network on the shared word 20.
CREATE OR REPLACE FUNCTION carrier_name_is_noise(w text)
RETURNS boolean AS $fn$
SELECT lower(w) = ANY (carrier_name_stopwords())
    OR w ~ '^[0-9]+$'
    OR (w = upper(w) AND w = ANY (carrier_name_state_abbrevs()));
$fn$ LANGUAGE sql IMMUTABLE;

-- STRICT tokens: the identifying words, and NOTHING when every word is
-- noise. Everything that JOINS on a shared token must use this, so that a
-- name carrying no information cannot reach anything through a generic word.
CREATE OR REPLACE FUNCTION carrier_name_tokens_strict(raw text)
RETURNS text[] AS $fn$
SELECT ARRAY(SELECT lower(w) FROM unnest(carrier_name_words_cased(raw)) AS w
             WHERE NOT carrier_name_is_noise(w));
$fn$ LANGUAGE sql IMMUTABLE;

-- The fallback form, for display and for the exact-match test only. Boris
-- 2026-11-22: "Fallback should be exact match." When every word is noise
-- this returns all of them, and carrier_name_tier then allows ONLY exact
-- agreement on such a name: no containment, no shared word. USA
-- COMMUNICATIONS to USA COMMUNICATIONS is the case that has to keep working,
-- and it does, through the compact key.
CREATE OR REPLACE FUNCTION carrier_name_tokens(raw text)
RETURNS text[] AS $fn$
SELECT CASE WHEN cardinality(k) > 0 THEN k ELSE carrier_name_words(raw) END
FROM (SELECT carrier_name_tokens_strict(raw) AS k) x;
$fn$ LANGUAGE sql IMMUTABLE;

-- TRUE when every word was noise, so the name identifies nothing on its own.
CREATE OR REPLACE FUNCTION carrier_name_generic_only(raw text)
RETURNS boolean AS $fn$
SELECT cardinality(carrier_name_tokens_strict(raw)) = 0;
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

-- The TOKEN KEY. The informative tokens, lowercased, de-duplicated and
-- sorted, joined with a bar. Two names with the same token key are tier 1 to
-- each other by the token-equality arm of carrier_name_tier, whatever their
-- word order and whatever non-informative words they carry. NULL when the
-- name has no informative token at all, so an empty key can never be used
-- as evidence of agreement.
--
-- It exists because the carrier universe was keyed on the compact key alone,
-- and the compact key is STRICTER than the matching rule. Measured
-- 2026-11-22: carrier_name_compact('AT&T Enterprises, LLC') is
-- attenterprises and carrier_name_compact('AT&T') is att, so they do not
-- agree, while both have token key at|t and carrier_name_tier scores them 1.
-- That gap excluded AS7018 from the universe and the cleanup then deleted
-- its correct decision along with 768 others.
CREATE OR REPLACE FUNCTION carrier_name_token_key(raw text)
RETURNS text AS $fn$
SELECT nullif(
  (SELECT coalesce(string_agg(DISTINCT t.tok, '|' ORDER BY t.tok), '')
   FROM unnest(carrier_name_tokens_strict(raw)) AS t(tok)),
  '');
$fn$ LANGUAGE sql IMMUTABLE;

-- How many DISTINCT informative tokens a name carries. Used to prefilter the
-- universe test: tier 1 and tier 2 both require that one name's token set is
-- contained in the other's, so the number of tokens the two share must equal
-- the smaller of the two counts. That is an exact precondition, not an
-- approximation, so prefiltering on it cannot drop a pair the tier rule
-- would have accepted.
CREATE OR REPLACE FUNCTION carrier_name_token_count(raw text)
RETURNS integer AS $fn$
SELECT count(DISTINCT t.tok)::integer
FROM unnest(carrier_name_tokens_strict(raw)) AS t(tok);
$fn$ LANGUAGE sql IMMUTABLE;

-- 1 exact, 2 strong containment, 3 a single shared word and therefore NOT
-- offered, 0 nothing.

-- =========================================================================
-- ORDER OF THIS FILE, 2026-11-23. Boris: "Insist on complete matches when
-- the exact pairing is not in your table." The match rule now READS his
-- tables, so every table it reads is built above it: the regression cases,
-- the entity seed, the unrelated rulings and the alias pairings come first,
-- then carrier_name_tier, then the gates that test it.
-- =========================================================================


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
 -- Boris 2026-11-23, from asn_brand_candidates.tsv. Every one of these was
 -- offered to him and is wrong.
 ('Wave Rural Connect, LLC','Fuse Rural Connect, LLC','reject','boris 2026-11-23: separate companies'),
 -- These three are must = 'ruled', a third category added 2026-11-23. The
 -- string rule scores them tier 1 and there is no honest way to make it
 -- score anything else: Peoples Telecommunications, Peoples Communications
 -- and Peoples Telephone Cooperative differ only in words that are noise in
 -- every other carrier name, so after the stopwords all three are {peoples}.
 -- Boris supplied knowledge the strings do not contain. A 'ruled' case
 -- therefore asserts the OPPOSITE of a reject case about the rule, that the
 -- rule DOES join them, and asserts that the recorded ruling suppresses
 -- them anyway. If one ever scored 0 the case would be silently vacuous.
 ('Peoples Telecommunications LLC','Peoples Telephone Cooperative','reject','boris 2026-11-23: not related'),
 ('Peoples Telecommunications LLC','Peoples Communications','reject','boris 2026-11-23: not related'),
 -- and the reverse orientation of the same ruling, because Peoples
 -- Telecommunications is both an ip-api operator name and a BDC brand, so
 -- the pair arrives both ways round. The symmetric test below covers this
 -- too; the cases are here so a regression in either is caught.
 ('Peoples Communications Inc.','Peoples Telecommunications','reject','boris 2026-11-23: not related, reverse orientation'),
 -- State of Alaska against the three Alaska brands his candidate file
 -- offered. All three brand strings are real: they are the candidates
 -- AS7782 Alaska Communications System received. I am INFERRING that these
 -- are the three he meant, because they are the three brands whose only
 -- informative token is alaska, which is also the only token State of
 -- Alaska has left after state and of are discarded.
 ('State of Alaska','ALASKA COMMUNICATIONS','reject','boris 2026-11-23: no relation to any Alaska carrier'),
 ('State of Alaska','Alaska Telephone Company','reject','boris 2026-11-23: no relation to any Alaska carrier'),
 ('State of Alaska','Fibre Alaska','reject','boris 2026-11-23: no relation to any Alaska carrier'),
 -- The control for that ruling. A real carrier named after the state must
 -- still reach its own brand, so the fix cannot be a stopword on alaska.
 ('Alaska Communications System','ALASKA COMMUNICATIONS','needs_pairing','same company, both reduce to the state name'),
 ('Wave Broadband','Wave 7 Communications','reject','boris: research case by case'),
 ('United States Department of Defense','United Communications','reject','boris: United is a modifier'),
 ('United States Department of Defense','United Fiber','reject','boris: United is a modifier'),
 ('United States Department of Defense','United Utilities, Inc.','reject','boris: out of scope anyway'),
 ('NTT America','NTT Fiber (North Texas Telephone)','reject','boris implied: unrelated'),
 ('University of California, San Diego','San Diego Broadband','reject','boris: not a carrier'),
 ('T-Mobile USA, Inc.','Limitless Mobile','reject','single shared word mobile'),
 ('Comcast Cable Communications, LLC','Xfinity','accept_recorded','no string method can join these'),
 ('Comcast Cable Communications, LLC','USA COMMUNICATIONS','reject','the original bug'),
 ('Comcast Cable Communications, LLC','Spectrum','reject','competitor'),
 ('Windstream Communications LLC','Georgia Windstream, LLC.','reject','subsidiary reached by one word'),
 -- These must keep working.
 ('Cox Communications Inc.','Cox Communications','accept_complete','same company'),
 ('Frontier Communications Solutions','Frontier','needs_pairing','same company'),
 ('AT&T Enterprises, LLC','AT&T','needs_pairing','same company'),
 ('123.Net, Inc.','123.NET Inc','accept_complete','same company'),
 ('Windstream Communications LLC','Windstream','needs_pairing','same company'),
 ('Verizon Business','Verizon','accept_recorded','same company'),
 ('CenturyLink Communications, LLC','CenturyLink','needs_pairing','same company'),
 ('Zayo Bandwidth','ZAYO GROUP LLC','needs_pairing','same company'),
 ('Cogent Communications','Cogent Communication','needs_pairing','same company'),
 ('Google LLC','Google Fiber','needs_pairing','same company'),
 ('USA COMMUNICATIONS','USA COMMUNICATIONS','accept_complete','identical'),
 ('CABLE ONE, INC.','Cable One','accept_complete','same company, suffix dropped'),
 ('T-Mobile USA, Inc.','T-Mobile','needs_pairing','same company'),
 ('TDS TELECOM','TDS Telecom','accept_complete','identical'),
 ('Breezeline','Breezeline','accept_complete','identical');


-- ---------------------------------------------------------------------------
-- THE ENTITY SEED. Boris's rulings about which names belong to which network.
--
-- This lives HERE, ahead of the carrier universe, because the universe is
-- built partly from it. Restricting the universe to BDC names alone cuts out
-- Comcast: its operator name, Comcast Cable Communications, LLC, is not a
-- BDC brand, which is the whole reason the entity layer exists. Verified on
-- the fixture, where a BDC-only universe reduced the candidates to three and
-- lost the Comcast to Xfinity match entirely.
--
-- carrier_entity.sql does the resolving and proposing and now requires these
-- tables to exist.
-- ---------------------------------------------------------------------------
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
-- THE UNRELATED LIST. Boris 2026-11-22: "Delete the records I marked as
-- unrelated and ensure they are not matched."
--
-- PERSISTENT. Created IF NOT EXISTS, never dropped, never truncated. Every
-- pair he has called unrelated goes in once and is suppressed everywhere
-- afterwards: candidate generation, the parent-on-subsidiary report, the
-- entity resolution and the near-miss report.
--
-- Why a table and not just a better rule. Most of these pairs already score
-- 0 because of the stopwords he supplied, so the rule handles them. But a
-- rule can regress, and the near-miss report does not use tiers at all, so
-- it can relate a pair the tier rule rejects. A recorded ruling is checked
-- by identity rather than by inference and cannot regress.
--
-- Matching is on the COMPACT KEY of both sides, so a ruling survives the
-- spelling variations of the same two companies.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS carrier_unrelated_tbl (
    ipapi_side   text NOT NULL,
    bdc_side     text NOT NULL,
    ipapi_key    text NOT NULL,
    bdc_key      text NOT NULL,
    note         text,
    ruled_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (ipapi_key, bdc_key));

COMMENT ON TABLE carrier_unrelated_tbl IS
'Pairs Boris has ruled unrelated. PERSISTENT: nothing in the pipeline drops or truncates it. Keyed on the compact form of both names so the ruling holds across spellings. Every matching step excludes these pairs by identity, which is why a stopword regression cannot resurrect them.';

-- Seeded from the reject cases in the gate, EXCEPT the ones that reject for
-- a different reason.
--
-- "reject" in the gate means "the string rule must not join these". That is
-- NOT the same as "these two companies are unrelated", and two of the thirty
-- cases are the second kind:
--
--   Comcast Cable Communications, LLC / Xfinity
--       the same company. The case exists to prove no string method can join
--       them, which is the entire reason the entity layer had to be built.
--   Windstream Communications LLC / Georgia Windstream, LLC.
--       a subsidiary. The case exists to stop it being reached by one shared
--       word, not to deny the relationship.
--
-- Seeding from all thirty put Comcast and Xfinity on the unrelated list and
-- silently deleted the most important match in the system. Caught by the
-- fixture, which asserts the Comcast proposal survives; the assertion is
-- there because this exact mistake happened.
INSERT INTO carrier_unrelated_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, note)
SELECT r.ipapi_side, r.bdc_side,
       carrier_name_compact(r.ipapi_side), carrier_name_compact(r.bdc_side),
       'from the regression gate: ' || r.source
FROM carrier_name_regression_tbl r
WHERE r.must = 'reject'
  AND carrier_name_compact(r.ipapi_side) IS NOT NULL
  AND carrier_name_compact(r.bdc_side) IS NOT NULL
  -- the two same-company cases, by compact key so spelling cannot slip past
  AND NOT (carrier_name_compact(r.ipapi_side), carrier_name_compact(r.bdc_side)) IN (
        (carrier_name_compact('Comcast Cable Communications, LLC'),
         carrier_name_compact('Xfinity')),
        (carrier_name_compact('Windstream Communications LLC'),
         carrier_name_compact('Georgia Windstream, LLC.')))
  AND NOT EXISTS (SELECT 1 FROM carrier_unrelated_tbl u
                  WHERE u.ipapi_key = carrier_name_compact(r.ipapi_side)
                    AND u.bdc_key   = carrier_name_compact(r.bdc_side));

INSERT INTO carrier_unrelated_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, note)
SELECT v.a, v.b, carrier_name_compact(v.a), carrier_name_compact(v.b), v.note
FROM (VALUES
 ('Database Mart LLC','Wal-Mart Stores, Inc.','boris 2026-11-22: unrelated, shared word mart'),
 ('Winn-Dixie Stores, Inc.','Wal-Mart Stores, Inc.','boris 2026-11-22: unrelated, shared words stores inc'),
 ('Spartan Stores, Inc.','Wal-Mart Stores, Inc.','boris 2026-11-22: unrelated, shared words stores inc'),
 ('Colonial IU 20','Washington State K-20 Telecommunications Network','boris 2026-11-22: unrelated, shared word 20'),
 ('State of WI Dept. of Administration','State of Washington','boris 2026-11-22: unrelated, shared words state wi dept'),
 ('State of WI Dept. of Administration','State of Wisconsin','boris 2026-11-22: these are the same body, but the pairing was reached by generic words and must come from a ruling not a match')
) AS v(a, b, note)
WHERE carrier_name_compact(v.a) IS NOT NULL
  AND carrier_name_compact(v.b) IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM carrier_unrelated_tbl u
                  WHERE u.ipapi_key = carrier_name_compact(v.a)
                    AND u.bdc_key   = carrier_name_compact(v.b));

-- SYMMETRIC. A ruling that two companies are unrelated is a fact about the
-- two companies, not about which side of the join they happened to appear
-- on. The first version tested one orientation only, and that is a hole:
-- Peoples Telecommunications LLC is an ip-api operator name on AS397298 AND
-- a BDC brand under provider 131030, so the same pair arrives both ways
-- round depending on which ASN is being matched, and a ruling recorded in
-- one direction silently failed in the other. Boris 2026-11-23 ruled that
-- pair unrelated, which is what exposed it.
-- KEY FORM, which is what carrier_name_tier calls. carrier_name_compact is
-- not free and the tier function has already computed both keys by the time
-- it needs these: six compact-key computations per evaluation became two.
CREATE OR REPLACE FUNCTION carrier_keys_are_unrelated(ka text, kb text)
RETURNS boolean AS $fn$
SELECT EXISTS (SELECT 1 FROM carrier_unrelated_tbl u
               WHERE (u.ipapi_key = ka AND u.bdc_key = kb)
                  OR (u.ipapi_key = kb AND u.bdc_key = ka));
$fn$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION carrier_pair_is_unrelated(a text, b text)
RETURNS boolean AS $fn$
SELECT carrier_keys_are_unrelated(carrier_name_compact(a),
                                  carrier_name_compact(b));
$fn$ LANGUAGE sql STABLE;

SELECT count(*) AS unrelated_pairs_held FROM carrier_unrelated_tbl;

-- ---------------------------------------------------------------------------
-- THE TABLE OF EXACT PAIRINGS. Boris 2026-11-23: "Insist on complete matches
-- when the exact pairing is not in your table."
--
-- This is that table. A row says: this ip-api name and this BDC name are the
-- same network, on his authority. It is the ONLY way two names that are not
-- character-for-character the same can be matched, now that token equality
-- and containment are gone.
--
-- PERSISTENT, like the unrelated list, and keyed on the compact form of both
-- names so a ruling survives a change of spelling or punctuation.
--
-- status matters and is not decoration:
--   confirmed  he said so. carrier_name_tier returns 2 and the pair matches.
--   proposed   I inferred it. It does NOT match. It is listed for his word.
-- The distinction exists because most of the accept cases in the gate carry
-- MY reasoning about corporate identity, not his: the source column says
-- "same company", which was me. Treating my inference as his ruling is how
-- 1-800-Flowers came to hold Comcast plant.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS carrier_alias_tbl (
    ipapi_side text NOT NULL,
    bdc_side   text NOT NULL,
    ipapi_key  text NOT NULL,
    bdc_key    text NOT NULL,
    status     text NOT NULL CHECK (status IN ('confirmed', 'proposed')),
    note       text,
    ruled_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (ipapi_key, bdc_key));

COMMENT ON TABLE carrier_alias_tbl IS
'Pairs of names that are the same network although the names differ. The only route to a match other than a complete name match, per Boris 2026-11-23. status confirmed means he ruled it and it matches; status proposed means I inferred it and it does NOT match until he says so. PERSISTENT: nothing in the pipeline drops or truncates it.';

-- SOURCE ONE, and the only one that produces confirmed rows: the entity
-- seed, where both sides already carry his status. Every ip-api name he
-- confirmed for an entity is paired with every BDC brand he confirmed for
-- the same entity, which is what the entity layer means.
-- DISTINCT ON, because two of his entity names can share a compact key:
-- Charter Communications Inc and Charter Communications, Inc differ only in
-- punctuation, so the cross product offers the same pair of keys twice. The
-- confirmed row wins, so a pair he confirmed under one spelling is never
-- downgraded by a proposed row carrying another spelling of the same name.
INSERT INTO carrier_alias_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, status, note)
SELECT DISTINCT ON (p.ipapi_key, p.bdc_key)
       p.ipapi_side, p.bdc_side, p.ipapi_key, p.bdc_key, p.status, p.note
FROM (
    SELECT i.name AS ipapi_side, b.name AS bdc_side,
           carrier_name_compact(i.name) AS ipapi_key,
           carrier_name_compact(b.name) AS bdc_key,
           CASE WHEN i.status = 'confirmed' AND b.status = 'confirmed'
                THEN 'confirmed' ELSE 'proposed' END AS status,
           'entity ' || e.entity_key || ': ' || e.display_name AS note
    FROM carrier_entity_tbl e
    JOIN carrier_entity_name_tbl i ON i.entity_key = e.entity_key AND i.side = 'ipapi'
    JOIN carrier_entity_name_tbl b ON b.entity_key = e.entity_key AND b.side = 'bdc'
    WHERE carrier_name_compact(i.name) IS NOT NULL
      AND carrier_name_compact(b.name) IS NOT NULL
      AND carrier_name_compact(i.name) <> carrier_name_compact(b.name)
      AND NOT carrier_pair_is_unrelated(i.name, b.name)
) p
ORDER BY p.ipapi_key, p.bdc_key, (p.status = 'confirmed') DESC, p.ipapi_side
ON CONFLICT (ipapi_key, bdc_key) DO NOTHING;

-- SOURCE TWO: the accept cases in the gate that are NOT complete matches.
-- These are the pairs the deleted arms used to join. They are inserted as
-- PROPOSED, so they no longer match, and they are listed below for his
-- ruling. Nine pairs, including AT&T Enterprises, LLC to AT&T, which covers
-- AS7018 and its 263,102 ZIP-capable ranges.
INSERT INTO carrier_alias_tbl (ipapi_side, bdc_side, ipapi_key, bdc_key, status, note)
SELECT DISTINCT ON (carrier_name_compact(r.ipapi_side), carrier_name_compact(r.bdc_side))
       r.ipapi_side, r.bdc_side,
       carrier_name_compact(r.ipapi_side), carrier_name_compact(r.bdc_side),
       'proposed',
       'was accepted by the deleted token rule, source: ' || r.source
FROM carrier_name_regression_tbl r
WHERE r.must IN ('needs_pairing', 'accept_recorded')
  AND carrier_name_compact(r.ipapi_side) IS NOT NULL
  AND carrier_name_compact(r.bdc_side) IS NOT NULL
  AND carrier_name_compact(r.ipapi_side) <> carrier_name_compact(r.bdc_side)
  -- AND NOT ALREADY RULED UNRELATED. Without this the seed RESURRECTS a
  -- pairing he has just rejected: load_alias_decisions.sql deletes the row
  -- and records the ruling, and the next run of this file puts the row back,
  -- so the same question is asked again for ever. Found 2026-11-24 by ruling
  -- the T-Mobile pairing no and watching it reappear in the proposal list.
  AND NOT carrier_keys_are_unrelated(carrier_name_compact(r.ipapi_side),
                                     carrier_name_compact(r.bdc_side))
ON CONFLICT (ipapi_key, bdc_key) DO NOTHING;

-- RECONCILE, rather than merely guard. The guards above stop a rejected
-- pairing being re-inserted, but a row resurrected by an earlier run is
-- already there, and a guard on insertion cannot remove it. So the invariant
-- is enforced here on every run: a pairing he has ruled unrelated is not a
-- pairing. Without this the row sits in both tables, the unrelated ruling
-- wins in carrier_name_tier, and the proposal list keeps asking a question
-- he has already answered.
DO $reconcile$
DECLARE removed bigint;
BEGIN
    DELETE FROM carrier_alias_tbl x
    WHERE carrier_keys_are_unrelated(x.ipapi_key, x.bdc_key);
    GET DIAGNOSTICS removed = ROW_COUNT;
    IF removed > 0 THEN
        RAISE NOTICE 'removed % pairing(s) that you have ruled unrelated', removed;
    END IF;
END
$reconcile$;

CREATE INDEX IF NOT EXISTS carrier_alias_ipapi_ix ON carrier_alias_tbl (ipapi_key);
CREATE INDEX IF NOT EXISTS carrier_alias_bdc_ix   ON carrier_alias_tbl (bdc_key);
ANALYZE carrier_alias_tbl;

-- SYMMETRIC, for the same reason the unrelated check is: the same pair
-- arrives either way round depending on which side is being matched.
-- CONFIRMED ONLY. A proposed row is my inference and must not match.
CREATE OR REPLACE FUNCTION carrier_keys_are_recorded(ka text, kb text)
RETURNS boolean AS $fn$
SELECT EXISTS (SELECT 1 FROM carrier_alias_tbl x
               WHERE x.status = 'confirmed'
                 AND ((x.ipapi_key = ka AND x.bdc_key = kb)
                   OR (x.ipapi_key = kb AND x.bdc_key = ka)));
$fn$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION carrier_pair_is_recorded(a text, b text)
RETURNS boolean AS $fn$
SELECT carrier_keys_are_recorded(carrier_name_compact(a),
                                 carrier_name_compact(b));
$fn$ LANGUAGE sql STABLE;

-- CREATED IN ITS MIGRATED SHAPE. One row per ASN PER BRAND, enforced by the
-- composite unique index below rather than by a primary key on asn, because
-- a carrier can own several brands. This file used to create it with
-- asn as the primary key, which meant a database built from scratch had to
-- run asn_map_multibrand_migration.sql before carrier_rulings.sql would do
-- anything; found 2026-11-23 on the test cluster, where carrier_rulings.sql
-- blocked on exactly that. The migration is still needed for Boris's
-- existing database and is a no-op against a table created here.
CREATE TABLE IF NOT EXISTS asn_bdc_brand_map_tbl (
    asn             bigint NOT NULL,
    decision        text NOT NULL
                    CHECK (decision IN ('brand', 'not_a_carrier', 'out_of_scope', 'unknown')),
    bdc_brand_name  text,
    bdc_provider_id integer,
    note            text,
    approved_at     timestamptz NOT NULL DEFAULT now());

-- Only on a table this file just created. Against Boris's database both
-- already exist, put there by asn_map_multibrand_migration.sql, and these
-- statements do nothing.
CREATE UNIQUE INDEX IF NOT EXISTS asn_bdc_brand_map_uq
    ON asn_bdc_brand_map_tbl (asn, coalesce(bdc_brand_name, ''),
                              coalesce(bdc_provider_id, 0));
CREATE INDEX IF NOT EXISTS asn_bdc_brand_map_asn_ix
    ON asn_bdc_brand_map_tbl (asn);

COMMENT ON TABLE asn_bdc_brand_map_tbl IS
'Boris-approved mapping from an AS number to a BDC brand. The ASN is the key because it is the only hard identifier on the ip-api side: one decision per operator rather than one per spelling of its name. PERSISTENT. carrier_asn_match.sql never drops or truncates it and proposes candidates only for ASNs absent from it, which is what makes new carriers integrate automatically as the remaining half of the decomposed ranges is probed. decision out_of_scope records Boris 2026-11-20: a non-carrier is localised by ip-api to its own premises, so it needs no headend inference at all.';

SELECT count(*) AS decisions_held,
       count(*) FILTER (WHERE decision = 'brand')        AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier') AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')  AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo The table of exact pairings. Only confirmed rows can produce a match.
\echo
SELECT status, count(*) AS pairs FROM carrier_alias_tbl GROUP BY status ORDER BY 1;

\echo
\echo PROPOSED PAIRINGS, WHICH DO NOT MATCH UNTIL YOU SAY SO. Each one is a
\echo pair the deleted token rule used to join by itself. One word on each.
\echo
SELECT a.ipapi_side, a.bdc_side, a.note
FROM carrier_alias_tbl a
WHERE a.status = 'proposed'
ORDER BY a.ipapi_side, a.bdc_side;

-- ---------------------------------------------------------------------------
-- THE SECOND GATE, for the cases the string rule cannot decide.
--
-- A 'ruled' case is one where the rule scores tier 1 or 2 and only Boris's
-- ruling separates the two companies. The first gate proved the rule joins
-- them. This proves the ruling suppresses them, in BOTH orientations,
-- because the same pair arrives either way round depending on which ASN is
-- being matched. It RAISES: an unenforced ruling is worse than no ruling,
-- ---------------------------------------------------------------------------
-- THE MATCH RULE. TWO WAYS TO BE A MATCH AND NO OTHERS.
--
-- Boris 2026-11-23: "Insist on complete matches when the exact pairing is not
-- in your table." And on the three pairs that prompted it: "Do not leave
-- Rural as the sole comparison word. There are many REI companies with Rural
-- in their names. Insist on a complete match after the AS number is
-- stripped." / "insist on full name match except Inc, LLC etc." / "State of
-- Alaska: insist on a full match."
--
--   1  COMPLETE MATCH. The whole name agrees once the AS number, the case,
--      the punctuation and the legal suffix are stripped. That is exactly
--      carrier_name_compact, so CABLE ONE, INC. still reaches Cable One and
--      Cox Communications Inc. still reaches Cox Communications.
--   2  RECORDED PAIRING. The exact pair is in his table and he confirmed it.
--      That is how a trade name reaches a legal name, Comcast Cable
--      Communications, LLC to Xfinity, which no string rule can do.
--   3  PARTIAL. The names share an informative word. NOT A MATCH. It is
--      computed and shown so that a pairing worth recording can be found,
--      and it is never written as a decision.
--   0  nothing, or a pair he ruled unrelated, or a state government.
--
-- WHAT THIS DELETES, AND WHY. The old rule had two further ways to be a
-- match: token-set equality after the stopwords, and containment with at
-- most one extra word. Between them they produced EVERY wrong relation he
-- has reported, because the stopwords strip the words that carry the
-- difference and the rule then compares what is left:
--
--   Rural Telephone Service Co / RURAL TELEPHONE COMPANY   both {rural}
--   Peoples Telecommunications / Peoples Communications    both {peoples}
--   State of Alaska / Fibre Alaska                         both {alaska}
--   Wave Rural Connect / Fuse Rural Connect                {rural} in both
--   Database Mart LLC / Wal-Mart Stores, Inc.              shared {mart}
--
-- Each time, I answered with another stopword, which made the surviving
-- names shorter and matched MORE things. Five reports of the same defect.
-- The rule above cannot produce any of them and needs no stopword at all to
-- decide a match. The stopwords now only find PARTIAL pairs for review.
--
-- STABLE rather than IMMUTABLE, because arms 0 and 2 read his tables. That
-- is the reason this function is defined below them rather than above.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION carrier_name_tier(a text, b text)
RETURNS integer AS $fn$
SELECT CASE
  WHEN t.ca IS NULL OR t.cb IS NULL                                 THEN 0
  -- A ruling that two companies are unrelated beats everything, including a
  -- complete match, because he has looked at that pair himself.
  WHEN carrier_keys_are_unrelated(t.ca, t.cb)                       THEN 0
  -- The ORDER of these two is deliberate and is not a performance choice.
  -- A state government is tested BEFORE the complete match, so that two
  -- identical government names cannot score 1 and become a match.
  WHEN carrier_name_is_state_government(a)
    OR carrier_name_is_state_government(b)                          THEN 0
  WHEN t.ca = t.cb                                                  THEN 1
  WHEN carrier_keys_are_recorded(t.ca, t.cb)                        THEN 2
  -- Nothing below this line is a match.
  WHEN cardinality(ARRAY(SELECT unnest(t.ta)
                         INTERSECT SELECT unnest(t.tb))) > 0        THEN 3
  ELSE 0 END
FROM (SELECT carrier_name_tokens_strict(a) AS ta,
             carrier_name_tokens_strict(b) AS tb,
             carrier_name_compact(a)       AS ca,
             carrier_name_compact(b)       AS cb) t;
$fn$ LANGUAGE sql STABLE;
\echo
\echo ================================================================
\echo THE REGRESSION GATE. tier 1 and 2 are offered to Boris; tier 3 and
\echo 0 are not. An accept case must reach 1 or 2; a reject case must not.
\echo ================================================================
\echo
SELECT must, count(*) AS cases,
       count(*) FILTER (WHERE carrier_name_tier(ipapi_side, bdc_side) = 1) AS complete_match,
       count(*) FILTER (WHERE carrier_name_tier(ipapi_side, bdc_side) = 2) AS your_pairing,
       count(*) FILTER (WHERE carrier_name_tier(ipapi_side, bdc_side) = 3) AS partial_not_a_match,
       count(*) FILTER (WHERE carrier_name_tier(ipapi_side, bdc_side) = 0) AS nothing
FROM carrier_name_regression_tbl
GROUP BY 1 ORDER BY 1;

\echo
\echo Every case. tier 1 is a complete name match, 2 is a pairing you have
\echo confirmed, 3 is a shared word and NOT a match, 0 is nothing.
\echo
SELECT must, ipapi_side, bdc_side,
       carrier_name_tier(ipapi_side, bdc_side) AS tier,
       CASE WHEN must = 'accept_complete'
                 AND carrier_name_tier(ipapi_side, bdc_side) = 1 THEN 'pass'
            WHEN must = 'accept_recorded'
                 AND carrier_name_tier(ipapi_side, bdc_side) = 2 THEN 'pass, by your pairing'
            WHEN must = 'reject'
                 AND carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2) THEN 'pass'
            WHEN must = 'needs_pairing'
                 AND carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2) THEN 'pass, awaiting your word'
            ELSE 'FAIL' END AS result,
       source
FROM carrier_name_regression_tbl
ORDER BY result, must, ipapi_side, bdc_side;

-- ---------------------------------------------------------------------------
-- THE GATE. Four categories, because there are now two ways to match and the
-- difference between them has to be asserted rather than blurred.
--
--   accept_complete  the names agree completely once the legal suffix goes.
--                    Must be tier 1. No table is involved.
--   accept_recorded  the names do NOT agree as strings and he has confirmed
--                    the pairing. Must be tier 2, and the complete-match
--                    test must FAIL, which is what used to be asserted by
--                    the Comcast to Xfinity reject case.
--   reject           must not match at all.
--   needs_pairing    the deleted token rule used to join these. They must
--                    NOT match now, and must appear in carrier_alias_tbl as
--                    proposed, waiting for one word from him.
-- ---------------------------------------------------------------------------
DO $gate$
DECLARE bad integer; detail text;
BEGIN
    SELECT count(*), string_agg(format('%s -> %s [%s, tier %s]',
                                  ipapi_side, bdc_side, must,
                                  carrier_name_tier(ipapi_side, bdc_side)), '; ')
      INTO bad, detail
    FROM carrier_name_regression_tbl
    WHERE NOT (
        (must = 'accept_complete' AND carrier_name_tier(ipapi_side, bdc_side) = 1)
     OR (must = 'accept_recorded' AND carrier_name_tier(ipapi_side, bdc_side) = 2
         AND carrier_name_compact(ipapi_side) IS DISTINCT FROM carrier_name_compact(bdc_side))
     OR (must = 'reject'          AND carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2))
     OR (must = 'needs_pairing'   AND carrier_name_tier(ipapi_side, bdc_side) NOT IN (1, 2)));
    IF bad > 0 THEN
        RAISE EXCEPTION
          'REGRESSION GATE FAILED on % case(s): %. Nothing was built and no file was written.',
          bad, left(detail, 500);
    END IF;
    RAISE NOTICE 'regression gate passed: all % cases', (SELECT count(*) FROM carrier_name_regression_tbl);
END
$gate$;

-- Every needs_pairing case must actually be in the proposal list, or it is
-- lost: it no longer matches and nobody is being asked about it.
DO $pairing$
DECLARE bad integer; detail text;
BEGIN
    SELECT count(*), string_agg(r.ipapi_side || ' -> ' || r.bdc_side, '; ')
      INTO bad, detail
    FROM carrier_name_regression_tbl r
    WHERE r.must = 'needs_pairing'
      AND NOT EXISTS (SELECT 1 FROM carrier_alias_tbl a
                      WHERE a.ipapi_key = carrier_name_compact(r.ipapi_side)
                        AND a.bdc_key   = carrier_name_compact(r.bdc_side))
      -- a pair he has RULED unrelated is resolved, not lost, so it does not
      -- need to be in the proposal list any more
      AND NOT carrier_keys_are_unrelated(carrier_name_compact(r.ipapi_side),
                                         carrier_name_compact(r.bdc_side));
    IF bad > 0 THEN
        RAISE EXCEPTION 'PAIRING GATE FAILED on % case(s): %. These pairs no longer match and are not in the proposal list either, so they have been silently dropped. Nothing was built.', bad, left(detail, 400);
    END IF;
    RAISE NOTICE 'pairing gate passed: all % pairs awaiting a ruling are in the proposal list', (SELECT count(*) FROM carrier_name_regression_tbl WHERE must = 'needs_pairing');
END
$pairing$;

-- ---------------------------------------------------------------------------
-- THE CARRIER UNIVERSE. Boris 2026-11-22: "You have a table with carrier
-- names. You have the FCC Form 499a list from me. Restrict carriers to the
-- superset of those sources and do not process the rest."
--
-- Built HERE rather than in its own file because it needs
-- carrier_name_compact(), which is defined above. carrier_universe.sql is
-- the report over what this builds.
--
-- Eligibility is tested on the AS OPERATOR NAME ONLY. Testing it on the
-- ip-api ISP name would admit every DIA customer of every carrier, which is
-- exactly how 1-800-Flowers came to be mapped to Comcast plant.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS carrier_universe_tbl;
CREATE TABLE carrier_universe_tbl (
    name_key  text NOT NULL,
    token_key text,
    name      text NOT NULL,
    source    text NOT NULL,
    PRIMARY KEY (name_key, source));

COMMENT ON TABLE carrier_universe_tbl IS
'The superset of names that are allowed to be carriers: every name column of bdc_carrier_tbl plus the FCC Form 499a filers when loaded. Boris 2026-11-22: restrict carriers to the superset of those sources and do not process the rest. Eligibility is tested on the AS OPERATOR name only; testing it on the ip-api ISP name would admit every DIA customer of every carrier, which is how 1-800-Flowers was mapped to Comcast.';

-- Build from every DISCOVERED name column of bdc_carrier_tbl. brand_name is
-- verified to exist by the matcher's own precheck; anything else is found
-- here and reported, so no column name is assumed.
DO $build$
DECLARE
    col     record;
    used    text[] := ARRAY[]::text[];
    added   bigint;
BEGIN
    FOR col IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_name = 'bdc_carrier_tbl'
          AND data_type IN ('text', 'character varying', 'character')
          AND (column_name = 'brand_name' OR column_name LIKE '%name%')
        ORDER BY column_name
    LOOP
        EXECUTE format($q$
            INSERT INTO carrier_universe_tbl (name_key, token_key, name, source)
            SELECT DISTINCT carrier_name_compact(c.%1$I),
                   carrier_name_token_key(c.%1$I), c.%1$I, 'bdc.%1$s'
            FROM bdc_carrier_tbl c
            WHERE c.%1$I IS NOT NULL AND btrim(c.%1$I) <> ''
              AND carrier_name_compact(c.%1$I) IS NOT NULL
            ON CONFLICT DO NOTHING $q$, col.column_name);
        GET DIAGNOSTICS added = ROW_COUNT;
        used := used || format('%s (%s names)', col.column_name, added);
    END LOOP;

    IF cardinality(used) = 0 THEN
        RAISE EXCEPTION 'no name columns found on bdc_carrier_tbl, so no universe could be built. Nothing else will run.';
    END IF;
    RAISE NOTICE 'built from bdc_carrier_tbl columns: %', array_to_string(used, ', ');
END
$build$;

-- And the Form 499a filers, if they are loaded. Column names are discovered
-- the same way rather than assumed, because I have not seen the file.
DO $f499$
DECLARE col record; used text[] := ARRAY[]::text[]; added bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'fcc499_filer_tbl') THEN
        RAISE NOTICE 'fcc499_filer_tbl absent: the universe is BDC names only. Every carrier that files with the FCC but does not appear in BDC is therefore OUT of the universe and will not be processed.';
        RETURN;
    END IF;
    -- The patterns are wider than %name% because the trade name is the most
    -- valuable column in the file and it is often not called a name. On the
    -- FCC form the legal name and the name the public sees are separate
    -- fields, and the second is usually headed Doing Business As or DBA.
    -- Xfinity, Sparklight, altafiber and WOW! are exactly the names the BDC
    -- side is missing, so dropping that column would waste the file.
    -- Identifier columns are left out deliberately: an FRN or filer number
    -- is not a name and would put number strings into the carrier universe.
    -- Every column used AND every text column skipped is reported below, so
    -- nothing about this file's shape is assumed or hidden.
    FOR col IN
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'fcc499_filer_tbl'
          AND data_type IN ('text', 'character varying', 'character')
          AND (column_name LIKE '%name%'
            OR column_name LIKE '%dba%'
            OR column_name LIKE '%business%'
            OR column_name LIKE '%brand%')
        ORDER BY column_name
    LOOP
        EXECUTE format($q$
            INSERT INTO carrier_universe_tbl (name_key, token_key, name, source)
            SELECT DISTINCT carrier_name_compact(f.%1$I),
                   carrier_name_token_key(f.%1$I), f.%1$I, 'fcc499.%1$s'
            FROM fcc499_filer_tbl f
            WHERE f.%1$I IS NOT NULL AND btrim(f.%1$I) <> ''
              AND carrier_name_compact(f.%1$I) IS NOT NULL
            ON CONFLICT DO NOTHING $q$, col.column_name);
        GET DIAGNOSTICS added = ROW_COUNT;
        used := used || format('%s (%s names)', col.column_name, added);
    END LOOP;
    IF cardinality(used) = 0 THEN
        RAISE EXCEPTION 'fcc499_filer_tbl exists but none of its text columns looked like a name, so loading it achieved nothing. Run: SELECT column_name FROM information_schema.columns WHERE table_name = ''fcc499_filer_tbl''; and tell me what the name column is called.';
    END IF;
    RAISE NOTICE 'built from fcc499_filer_tbl columns: %', array_to_string(used, ', ');
    RAISE NOTICE 'fcc499_filer_tbl text columns NOT used as names: %',
        coalesce((SELECT string_agg(c.column_name, ', ' ORDER BY c.column_name)
                  FROM information_schema.columns c
                  WHERE c.table_name = 'fcc499_filer_tbl'
                    AND c.data_type IN ('text','character varying','character')
                    AND NOT (c.column_name LIKE '%name%' OR c.column_name LIKE '%dba%'
                          OR c.column_name LIKE '%business%' OR c.column_name LIKE '%brand%')),
                 'none');
END
$f499$;

-- THIRD SOURCE, AND IT IS NOT ONE BORIS NAMED. The ip-api-side names he
-- confirmed for each entity. Without it the restriction removes Comcast,
-- Charter, Level 3, Cablevision, RCN, Wave, Grande, Cable One and
-- Midcontinent, because their operator names are not BDC brands; that is the
-- trade-name problem the entity layer was built for. These names are still
-- his rulings, just recorded in a different table, and they are reported
-- under their own source so the universe is auditable.
INSERT INTO carrier_universe_tbl (name_key, token_key, name, source)
SELECT DISTINCT carrier_name_compact(n.name),
       carrier_name_token_key(n.name), n.name,
       'entity.' || n.status
FROM carrier_entity_name_tbl n
WHERE n.side = 'ipapi'
  AND carrier_name_compact(n.name) IS NOT NULL
ON CONFLICT DO NOTHING;

CREATE INDEX carrier_universe_key_ix ON carrier_universe_tbl (name_key);
CREATE INDEX carrier_universe_token_key_ix ON carrier_universe_tbl (token_key);
ANALYZE carrier_universe_tbl;

-- ---------------------------------------------------------------------------
-- MEMBERSHIP, BY THE SAME TWO PATHS AS A MATCH. Boris 2026-11-23: "Insist on
-- complete matches when the exact pairing is not in your table."
--
--   1. the whole name agrees with a carrier name once the legal suffix goes;
--   2. the exact pairing is in carrier_alias_tbl, confirmed, and the other
--      side of it is a carrier name;
-- and that is all. I wrote a third path first, "the holder already has a
-- brand decision in the map", and then removed it: the map contains rows
-- MY code wrote without him, which is how 1-800-Flowers came to hold
-- Comcast plant, so that path would have used my own mistakes as evidence
-- that a holder is a carrier. The table cannot tell his approvals from my
-- writes, so it cannot be an authority on this question.
--
-- WHAT PROTECTS THE 769 DECISIONS INSTEAD. carrier_rulings.sql now REFUSES
-- to run its cleanup until fcc499_filer_tbl is loaded. AT&T Enterprises, LLC
-- is a Form 499a legal name, so once that file is in, the holder of AS7018
-- is a carrier by a COMPLETE match against his own data rather than by my
-- inference from a token. Until then nothing is deleted.
--
-- The token-key path and the tier path are GONE, with the token table and
-- the memo that existed to make them affordable. They cost 3.08 ms per name,
-- 61.5 s per call site over his 19,936 ASNs, and they existed to admit names
-- that the complete-match rule says are not the same name. Three index
-- probes replace them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION carrier_name_in_universe(raw text)
RETURNS boolean AS $fn$
SELECT carrier_name_compact(raw) IS NOT NULL
   AND NOT carrier_name_is_state_government(raw)
   AND (EXISTS (SELECT 1 FROM carrier_universe_tbl u
                WHERE u.name_key = carrier_name_compact(raw))
     OR EXISTS (SELECT 1 FROM carrier_alias_tbl x
                JOIN carrier_universe_tbl u
                  ON u.name_key IN (x.ipapi_key, x.bdc_key)
                WHERE x.status = 'confirmed'
                  AND carrier_name_compact(raw) IN (x.ipapi_key, x.bdc_key)
                  AND u.name_key <> carrier_name_compact(raw)));
$fn$ LANGUAGE sql STABLE;


-- ---------------------------------------------------------------------------
-- WHICH GATE CASES ARE HYPOTHETICAL.
--
-- The gate tests the FUNCTION, not the data. A passing accept case proves
-- only that the rule WOULD join those two strings if both existed. Boris's
-- 2026-11-22 run exposed the gap: CABLE ONE, INC. to Cable One passes at
-- tier 1, and AS11492 CABLE ONE, INC. still received no candidate at all,
-- with 4,612 ZIP-capable ranges behind it. The reason is that there is no
-- brand Cable One in his BDC data. Cable One has traded as Sparklight since
-- 2019, so the brand I was testing against does not exist.
--
-- This is the same mistake as my Comcast Business prediction, which came
-- from a fixture rather than from his data. So the gate now reports which
-- of its BDC-side strings are real. It does NOT raise: a hypothetical case
-- is still a valid statement about the rule, it just proves nothing about
-- coverage, and the distinction has to be on the screen.
-- ---------------------------------------------------------------------------
\echo
\echo Gate cases whose BDC-side string does NOT exist in bdc_carrier_tbl.
\echo These test the rule only. An accept case here means the rule would
\echo work IF the brand existed, and tells you nothing about whether that
\echo carrier can actually be reached.
\echo
SELECT r.must, r.ipapi_side, r.bdc_side, r.source
FROM carrier_name_regression_tbl r
WHERE NOT EXISTS (SELECT 1 FROM bdc_carrier_tbl c
                  WHERE lower(btrim(c.brand_name)) = lower(btrim(r.bdc_side)))
ORDER BY r.must, r.ipapi_side;

SELECT count(*) AS gate_cases,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM bdc_carrier_tbl c
                        WHERE lower(btrim(c.brand_name)) = lower(btrim(carrier_name_regression_tbl.bdc_side))))
                                                   AS bdc_side_is_a_real_brand,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM bdc_carrier_tbl c
                        WHERE lower(btrim(c.brand_name)) = lower(btrim(carrier_name_regression_tbl.bdc_side))))
                                                   AS hypothetical
FROM carrier_name_regression_tbl;

-- ---------------------------------------------------------------------------
-- The persistent decision map, keyed on the ASN.
-- ---------------------------------------------------------------------------

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
      -- And not an ASN whose every probed range is already known to be
      -- mobile CGNAT or transit. Boris 2026-11-22: wireless is out of scope
      -- for this subsystem, so such an ASN cannot carry a ZIP answer and
      -- does not belong in the approval queue. Unclassified ranges still
      -- count as possible, because mobile_transit NULL means not yet decided
      -- and deliberately is not folded into 'f'.
      AND (coalesce(a.zip_capable_ranges, 0) > 0
        OR coalesce(a.unclassified_ranges, 0) > 0)
      -- AND THE HOLDER OF THE ASN MUST BE A CARRIER. Boris 2026-11-22:
      -- restrict carriers to the superset of the BDC names and the Form 499a
      -- filers, and do not process the rest. Tested on the operator name,
      -- never the ISP name.
      AND carrier_name_in_universe(a.as_operator)
), brand AS (
    -- ONLY BRANDS WITH WIRELINE PLANT. Boris 2026-11-22: "Wireless is out of
    -- scope for the ITDK-BDC subsystem." A brand that appears only under
    -- technologies 70, 71 or 72 can never answer a ZIP-level question, so
    -- offering it is noise in the approval queue however good the name looks.
    -- His run offered forty such candidates, among them Buckeye Wireless,
    -- C Spire Wireless, Ziply Wireless, Unwired Ltd and Webpass. They are now
    -- excluded here rather than listed afterwards, and counted below.
    SELECT DISTINCT c.brand_name, c.provider_id
    FROM bdc_carrier_tbl c
    WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
      AND EXISTS (SELECT 1 FROM provider_brand_tract_tech_tbl f
                  WHERE f.provider_id = c.provider_id
                    AND f.brand_name = c.brand_name
                    AND f.technology IN (10, 40, 50))
), ntok AS (
    -- Only the AS operator name generates candidates. The ip-api ISP name
    -- is frequently the UPSTREAM carrier rather than the holder of the ASN:
    -- AS16509 is Amazon and ip-api reports its ISP as Windstream, which is
    -- how the previous version matched Amazon to Windstream's footprint.
    SELECT t.asn, w.tok
    FROM todo t, unnest(carrier_name_tokens_strict(t.as_operator)) AS w(tok)
    WHERE length(w.tok) >= 2
), btok AS (
    SELECT b.brand_name, b.provider_id, w.tok
    FROM brand b, unnest(carrier_name_tokens_strict(b.brand_name)) AS w(tok)
    WHERE length(w.tok) >= 2
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
    -- How big the candidate brand's footprint is, PER TECHNOLOGY and over
    -- the wireline technologies only.
    --
    -- The first version of this pooled all technologies, which made the
    -- number meaningless. Boris 2026-11-22: a carrier's technologies are
    -- separated because they are ROUTED DIFFERENTLY and the headends differ.
    -- His nearest Verizon central office, one mile away, carries xDSL but not
    -- FIOS; his FIOS is routed from four miles away. There is therefore no
    -- such thing as the footprint of a brand, only one footprint per
    -- technology, each with its own plant.
    --
    -- Pooling also let the out-of-scope wireless footprint dominate. On
    -- Boris's data AT&T reaches 97.4% of tracts pooled and 97.3% on
    -- technology 71 alone, against 44.3% on Copper and 36.4% on FTTP, and no
    -- brand exceeds 80% in ANY technology except 71. So a pooled share
    -- measures licensed fixed wireless, which cannot be targeted at ZIP
    -- level and which this pipeline never selects on.
    SELECT f.provider_id, f.brand_name, f.technology,
           count(DISTINCT f.tract_geoid) AS tracts
    FROM provider_brand_tract_tech_tbl f
    WHERE f.technology IN (10, 40, 50)
    GROUP BY 1, 2, 3
), fp_all AS (
    -- The denominator is the WIRELINE-SERVED universe, not every tract.
    -- Boris 2026-11-22: wireless is out of scope, so a tract reachable only
    -- by fixed wireless does not belong in the denominator either. This
    -- raises the percentages slightly against the all-technology denominator
    -- used on his 2026-11-22 run, where AT&T Copper read 44.5%.
    SELECT count(DISTINCT tract_geoid)::numeric AS tracts
    FROM provider_brand_tract_tech_tbl
    WHERE technology IN (10, 40, 50)
), fp_best AS (
    -- The widest single wireline technology, which is the only sense in
    -- which a footprint can be called large.
    SELECT DISTINCT ON (provider_id, brand_name)
           provider_id, brand_name, technology AS widest_technology, tracts
    FROM fp ORDER BY provider_id, brand_name, tracts DESC, technology
), scored AS (
    SELECT p.asn, p.brand_name, p.provider_id,
           t.as_operator, t.as_operator_pct,
           t.isp_commonest, t.isp_commonest_pct,
           t.zip_capable_ranges, t.dma_only_ranges,
           carrier_name_tier(t.as_operator,   p.brand_name)      AS tier,
           carrier_name_tier(t.isp_commonest, p.brand_name)      AS tier_isp_agrees,
           f.widest_technology,
           f.tracts                                              AS brand_tracts,
           round(100.0 * f.tracts / nullif(a.tracts, 0), 1)      AS brand_tract_pct,
           (SELECT count(*) FROM fp x
            WHERE x.provider_id = p.provider_id
              AND x.brand_name = p.brand_name)                   AS wireline_technologies
    FROM pair p
    JOIN todo t ON t.asn = p.asn
    LEFT JOIN fp_best f ON f.provider_id = p.provider_id AND f.brand_name = p.brand_name
    CROSS JOIN fp_all a
), kept AS (
    -- Boris's unrelated rulings are applied here by identity, not inference.
    SELECT * FROM scored
    WHERE tier IN (1, 2)
      AND NOT carrier_pair_is_unrelated(as_operator, brand_name)
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
       c.tier, c.widest_technology AS tech, c.brand_tract_pct AS pct_of_tracts,
       c.zip_capable_ranges
FROM asn_brand_candidate_tbl c
ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn, c.rank_for_asn
LIMIT 60;

\echo
\echo ----------------------------------------------------------------
\echo WHAT WIRELESS SCOPE REMOVED, so the exclusion is visible rather
\echo than silent. Boris 2026-11-22: wireless is out of scope for the
\echo ITDK-BDC subsystem. None of this reaches the approval queue.
\echo ----------------------------------------------------------------
\echo
SELECT count(*) FILTER (WHERE wireline = 0)            AS brands_wireless_only,
       count(*) FILTER (WHERE wireline > 0)            AS brands_with_wireline,
       count(*)                                        AS brands_in_bdc
FROM (SELECT c.provider_id, c.brand_name,
             count(*) FILTER (WHERE f.technology IN (10, 40, 50)) AS wireline
      FROM (SELECT DISTINCT provider_id, brand_name FROM bdc_carrier_tbl
            WHERE brand_name IS NOT NULL AND brand_name <> '') c
      LEFT JOIN provider_brand_tract_tech_tbl f
        ON f.provider_id = c.provider_id AND f.brand_name = c.brand_name
      GROUP BY 1, 2) x;

\echo
\echo The largest wireless-only brands, no longer offered. On the 2026-11-22
\echo run forty of these reached the queue and could not have been used,
\echo among them Buckeye Wireless, C Spire Wireless and Ziply Wireless.
\echo
SELECT c.provider_id, left(c.brand_name, 34) AS wireless_only_brand,
       count(DISTINCT f.tract_geoid) AS tracts,
       string_agg(DISTINCT f.technology::text, ',') AS technologies
FROM (SELECT DISTINCT provider_id, brand_name FROM bdc_carrier_tbl
      WHERE brand_name IS NOT NULL AND brand_name <> '') c
JOIN provider_brand_tract_tech_tbl f
  ON f.provider_id = c.provider_id AND f.brand_name = c.brand_name
WHERE NOT EXISTS (SELECT 1 FROM provider_brand_tract_tech_tbl g
                  WHERE g.provider_id = c.provider_id
                    AND g.brand_name = c.brand_name
                    AND g.technology IN (10, 40, 50))
GROUP BY 1, 2
ORDER BY count(DISTINCT f.tract_geoid) DESC
LIMIT 20;

\echo
\echo ----------------------------------------------------------------
\echo WHAT THE STATE GOVERNMENT RULE REMOVED, also visible rather than
\echo silent. Boris 2026-11-23: State of Alaska has no relation to any
\echo Alaska carrier. These holders can no longer reach any brand.
\echo A MUNICIPAL carrier is not caught by this: City of X and County
\echo of X are untouched, because Fort Collins Connexion and Carthage
\echo Water and Electric are real plant owned by real city governments.
\echo ----------------------------------------------------------------
\echo
SELECT a.asn, a.as_operator, a.zip_capable_ranges
FROM ipapi_asn_tbl a
WHERE carrier_name_is_state_government(a.as_operator)
ORDER BY a.zip_capable_ranges DESC NULLS LAST, a.asn
LIMIT 25;

SELECT count(*)                        AS state_government_asns,
       sum(a.zip_capable_ranges)       AS zip_capable_ranges_behind_them
FROM ipapi_asn_tbl a
WHERE carrier_name_is_state_government(a.as_operator);

\echo
\echo ASNs excluded because every probed range is already classified mobile
\echo CGNAT or transit, so none of them can carry a ZIP answer.
\echo
SELECT count(*) AS asns_all_dma,
       sum(dma_only_ranges) AS dma_only_ranges_behind_them
FROM ipapi_asn_tbl a
WHERE coalesce(a.zip_capable_ranges, 0) = 0
  AND coalesce(a.unclassified_ranges, 0) = 0;

-- ---------------------------------------------------------------------------
-- THE PARENT-ON-SUBSIDIARY INSTRUMENT.
--
-- The first version of this flagged candidates whose brand footprint exceeded
-- half the country. On Boris's 2026-11-22 run that produced 40 rows, every
-- one of them an AT&T or Verizon ASN matching its own correct brand, and the
-- one row that genuinely needed an eye, AS5650, was indistinguishable from
-- the other 39. Zero discriminating power.
--
-- What DOES discriminate is already in the data: the registry operator name
-- and the ip-api ISP name disagree, and the ISP name is itself a brand in
-- BDC. AS5650 and AS46690 both read operator Verizon Business, ISP Frontier
-- Communications. Those two rows, and no others among the forty, carry the
-- signal. So the report asks which OTHER brand the ISP name points at, and
-- names it, which turns the flag into a proposed answer.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS asn_isp_disagree_tbl;
CREATE TABLE asn_isp_disagree_tbl AS
WITH suspect AS (
    SELECT DISTINCT c.asn, c.as_operator, c.isp_commonest
    FROM asn_brand_candidate_tbl c
    WHERE c.tier_isp_agrees = 0
      AND c.isp_commonest IS NOT NULL
      AND NOT carrier_name_generic_only(c.isp_commonest)
), stok AS (
    SELECT s.asn, w.tok
    FROM suspect s, unnest(carrier_name_tokens_strict(s.isp_commonest)) AS w(tok)
    WHERE length(w.tok) >= 2
), brand AS (
    SELECT DISTINCT c.brand_name, c.provider_id
    FROM bdc_carrier_tbl c
    WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
), btok AS (
    SELECT b.brand_name, b.provider_id, w.tok
    FROM brand b, unnest(carrier_name_tokens_strict(b.brand_name)) AS w(tok)
    WHERE length(w.tok) >= 2
), hit AS (
    SELECT DISTINCT s.asn, b.brand_name, b.provider_id
    FROM stok s JOIN btok b ON b.tok = s.tok
    UNION
    SELECT DISTINCT s.asn, b.brand_name, b.provider_id
    FROM suspect s JOIN brand b
      ON carrier_name_compact(b.brand_name) = carrier_name_compact(s.isp_commonest)
)
SELECT s.asn, s.as_operator, s.isp_commonest,
       h.provider_id            AS isp_suggests_provider_id,
       h.brand_name             AS isp_suggests_brand,
       carrier_name_tier(s.isp_commonest, h.brand_name) AS isp_tier,
       a.zip_capable_ranges,
       -- TRANSIT, NOT OWNERSHIP. If the ISP name is the registry name of a
       -- DIFFERENT and much larger ASN, the relationship is upstream transit
       -- and the brand is the wrong answer. Boris's 2026-11-22 run showed
       -- five small carriers pointing at Cogent and two at AT&T this way.
       -- Frontier does not trip it, because no ASN carries Frontier as its
       -- operator name any more; that is the whole reason it needed finding.
       EXISTS (SELECT 1 FROM ipapi_asn_tbl o
               WHERE o.asn <> s.asn
                 AND carrier_name_compact(o.as_operator)
                     = carrier_name_compact(s.isp_commonest)
                 AND o.zip_capable_ranges > a.zip_capable_ranges)
                                AS isp_is_a_larger_asn_upstream
FROM suspect s
JOIN hit h ON h.asn = s.asn
JOIN ipapi_asn_tbl a ON a.asn = s.asn
-- 1, 2 AND 3. This is a REVIEW QUEUE, not a match: every row it produces is
-- held back by load_candidate_decisions.sql and reaches the decision map
-- only with his word on it. Boris 2026-11-23 required complete matches for
-- MATCHING, and a partial pair is exactly what he needs to see in order to
-- confirm or reject a pairing. Dropping tier 3 here cost the one case the
-- report exists for: ip-api reports Frontier Communications on the ranges of
-- ASNs whose registry name is now Verizon Business, and the brand is filed
-- as Frontier, which is a partial pair and not a complete one.
WHERE carrier_name_tier(s.isp_commonest, h.brand_name) IN (1, 2, 3)
  AND NOT carrier_pair_is_unrelated(s.isp_commonest, h.brand_name)
  AND NOT carrier_pair_is_unrelated(s.as_operator, h.brand_name)
  -- a partial pair needs at least one informative word in common, which
  -- tier 3 already means, and must not be two generic names meeting on a
  -- word that says nothing
  AND NOT carrier_name_generic_only(h.brand_name);

CREATE INDEX asn_isp_disagree_ix ON asn_isp_disagree_tbl (asn);
ANALYZE asn_isp_disagree_tbl;

\echo
\echo ----------------------------------------------------------------
\echo PARENT ON SUBSIDIARY. The registry operator name and the ip-api
\echo ISP name disagree, AND the ISP name is itself a BDC brand. The
\echo brand named in the last columns is what the ISP name points at,
\echo so each row is a proposed correction rather than a warning.
\echo Verizon owns Frontier, so AS5650 should take Frontier plant and
\echo not Verizon plant, because the merger EXTENDED the footprint
\echo into territory Verizon had divested rather than overlapping it.
\echo ----------------------------------------------------------------
\echo
-- The brand name is NOT truncated here. On Boris's 2026-11-23 run AS23404,
-- AS21725 and AS46986 each appeared twice with what looked like the same
-- provider_id and the same brand, which reads as a duplicate row. It cannot
-- be one: the hit set is built with DISTINCT and UNION, so two identical
-- triples cannot survive. The two rows therefore hold two DIFFERENT brand
-- strings under one provider_id, and left(brand, 22) was hiding the
-- difference. Showing the whole string is the fix; the report below names
-- every such pair in the BDC data.
SELECT d.asn, left(d.as_operator, 22) AS registry_says,
       left(d.isp_commonest, 22) AS ipapi_isp_says,
       d.isp_suggests_provider_id AS suggests_provider,
       d.isp_suggests_brand AS suggests_brand,
       d.isp_tier, d.zip_capable_ranges
FROM asn_isp_disagree_tbl d
WHERE NOT d.isp_is_a_larger_asn_upstream
ORDER BY d.zip_capable_ranges DESC NULLS LAST, d.asn
LIMIT 40;

\echo
\echo ----------------------------------------------------------------
\echo ONE PROVIDER, SEVERAL SPELLINGS OF ONE BRAND. These are the rows
\echo that look duplicated in the reports above and below. They are not
\echo duplicates: the provider files more than one brand string whose
\echo compact key is identical. Shown rather than merged, because two
\echo spellings can carry DIFFERENT footprints and silently keeping one
\echo would throw plant away.
\echo ----------------------------------------------------------------
\echo
SELECT c.provider_id,
       carrier_name_compact(c.brand_name)      AS shared_compact_key,
       count(DISTINCT c.brand_name)            AS spellings,
       string_agg(DISTINCT c.brand_name, ' | ' ORDER BY c.brand_name) AS as_filed
FROM bdc_carrier_tbl c
WHERE c.brand_name IS NOT NULL AND c.brand_name <> ''
GROUP BY c.provider_id, carrier_name_compact(c.brand_name)
HAVING count(DISTINCT c.brand_name) > 1
ORDER BY count(DISTINCT c.brand_name) DESC, c.provider_id
LIMIT 30;

\echo
\echo And the ones where the ISP name is the registry name of a LARGER ASN,
\echo which is transit rather than ownership. Shown separately because the
\echo suggested brand is the wrong answer for these.
\echo
SELECT d.asn, left(d.as_operator, 30) AS registry_says,
       left(d.isp_commonest, 24) AS ipapi_isp_says,
       left(d.isp_suggests_brand, 22) AS would_have_suggested,
       d.zip_capable_ranges
FROM asn_isp_disagree_tbl d
WHERE d.isp_is_a_larger_asn_upstream
ORDER BY d.zip_capable_ranges DESC NULLS LAST, d.asn
LIMIT 20;

SELECT count(DISTINCT asn)                                   AS asns_disagreeing,
       count(*)                                              AS rows_total,
       count(*) FILTER (WHERE NOT isp_is_a_larger_asn_upstream) AS proposed_corrections,
       count(*) FILTER (WHERE isp_is_a_larger_asn_upstream)     AS discarded_as_transit,
       (SELECT sum(z.zip_capable_ranges) FROM
          (SELECT DISTINCT asn, zip_capable_ranges FROM asn_isp_disagree_tbl
           WHERE NOT isp_is_a_larger_asn_upstream) z)        AS ranges_behind_corrections
FROM asn_isp_disagree_tbl;

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
