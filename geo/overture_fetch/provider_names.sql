-- provider_names.sql
-- Registrants whose address space NEVER routes retail residential or business
-- customers: CDNs, clouds, website builders and web-hosting firms.
--
-- WHY THIS EXISTS, AND WHY IT IS NOT ABOUT MISLOCATION
--
-- The landmark method works by shared routing. A landmark's static on-premises
-- address and the dynamic addresses of nearby retail customers are routed
-- together, through the same carrier node adjacent to customer premises
-- equipment. Matching on that node is what transfers the landmark's postal ZIP to
-- the retail ranges.
--
-- When a landmark's website is fronted by a CDN or hosted on a cloud, the carrier
-- node adjacent to that address is the provider's own edge router. It routes
-- content, never subscribers. So routing to retail customers can never converge
-- through it, and the landmark cannot anchor anything however correct its ZIP is.
--
-- This is NOT a claim that the classification was geographically wrong. An Akamai
-- edge cluster may genuinely sit on a university campus, and Akamai's registered
-- ZIP 02142 is in the same city as MIT's 02139, so the adjacency rule may well be
-- reaching the right answer. The point is narrower: the answer is unusable.
--
-- The exclusion therefore runs BEFORE the ZIP tests, as a hard false, mirroring
-- the way isp_names acts as a hard true. Placing it after the ZIP tests would let
-- any landmark that happens to sit near a provider's registered office through:
-- Akamai in Cambridge, Cloudflare and Fastly in San Francisco, Amazon in Herndon.
--
-- It also replaces the `mark` subcommand, which was not durable. `mark` issued a
-- plain UPDATE setting onpremises = false, and the next `onpremises` run
-- recomputed the column for every row with lookup_status = 'true' with no
-- exemption, flipping marked rows back. A registrant-keyed table is a property of
-- the data rather than a one-shot correction, so it survives every rerun.
--
-- EVERY NAME HERE WAS CONFIRMED BY RDAP ON 2026-10-23, not assumed. Each was
-- resolved from the provider's own domain and the registrant string and ZIP
-- compared against what ovt_places_usa recorded. The two uncertain cases were
-- researched rather than guessed, and they went in opposite directions: see the
-- notes on EYEMG and Southwest Cyberport below.
--
-- WHAT IS DELIBERATELY NOT HERE
--
-- Universities and hospitals. Indiana, Purdue, Penn State, Kansas, Washington,
-- Hawaii, the University System of New Hampshire, Northwestern Memorial, Carilion,
-- Children's Medical Center of Dallas, UPMC and Baptist Health all appear in the
-- same report, and all are kept. They hold their own space and serve real people
-- from it.
--
-- Google Fiber Inc. The exclusion matches the registrant STRING, so excluding
-- 'Google LLC' (Mountain View 94043, the cloud) leaves 'Google Fiber Inc.'
-- untouched. That distinction is the whole reason this is a name list and not an
-- ASN list, and it honours the standing rule that no company serving customers
-- from part of its holdings may be excluded wholesale.
--
-- Southwest Cyberport, Inc. It appeared in the report and looked like a hosting
-- firm. It is not: swcp.com describes a New Mexico ISP founded in 1994 supplying
-- DSL in partnership with CenturyLink, its own LightSpeed fiber, SWCP DIRECT fixed
-- wireless, and dedicated connections to apartment and office complexes. It routes
-- retail residential and business customers, so its carrier node is exactly what
-- the method wants. It belongs in isp_names, where it was MISSING from the 1,100
-- names, and section 5 adds it. But see the caveat at the end of section 6: it
-- also sells hosting, which by the rule the Synergy case established may make
-- isp_names membership too strong. That is an open question, not a correction.
--
-- Contains NO backslashes so it survives copy/paste.


CREATE TABLE IF NOT EXISTS public.provider_names (name text NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS provider_names_name_lower_idx
    ON public.provider_names (lower(btrim(name)));

COMMENT ON TABLE public.provider_names IS
    'Registrants whose space never routes retail subscribers: CDNs, clouds, website builders, web hosts. Consulted by the onpremises step as a hard false BEFORE the ZIP tests, mirroring isp_names as a hard true. Matched ignoring case against registrant_1 and registrant_2.';


-- ---------------------------------------------------------------------------
-- SEED. Confirmed by RDAP, with the row counts each accounts for in the
-- onpremises = true population of 136,255 at the time of writing.
-- ---------------------------------------------------------------------------

INSERT INTO public.provider_names (name) VALUES
    ('Cloudflare, Inc.'),
    ('Squarespace, Inc.'),
    ('Amazon Technologies Inc.'),
    ('WPEngine, Inc.'),
    ('Amazon.com, Inc.'),
    ('Google LLC'),
    ('Akamai Technologies, Inc.'),
    ('GoDaddy.com, LLC'),
    ('Webflow, Inc'),
    ('Microsoft Corporation'),
    ('Fastly, Inc.'),
    ('Pantheon'),
    ('Amazon Data Services Northern Virginia'),
    ('Weebly, Inc.'),
    ('EYEMG - interactive media group')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- SECOND BATCH, from the review of the deepest 60 non-ISP on-premises
-- registrants. Each is a host, a CDN or a website platform. Universities,
-- hospitals, health systems and city and state governments in that same report
-- are landmarks and are deliberately absent.
--
-- Three were researched rather than classified by name, and they did not all go
-- the same way:
--
--   CarsForSale.com        A dealer website platform, not a car dealer. South
--                          Dakota court filings describe it supplying "website
--                          hosting ... and custom dealership websites" to 22,000
--                          auto dealers. Its 131 places are DEALERSHIPS whose
--                          sites it hosts, which is the direct answer to why a
--                          single registrant shows hundreds of places.
--   Brownrice Internet     Its own site calls it "a vps hosting, webcam
--                          streaming, and data center company based in Taos, NM",
--                          selling dedicated servers and colocation. A host.
--   Synergy Networks       NOT included. See the note below: it sells
--                          business-class broadband as well as hosting, so it
--                          plausibly belongs in isp_names instead.
--
-- HDC/HW Enterprise, LLC (60606, 116 places) is NOT included because it was not
-- researched. Do not add it on the strength of the name alone.
-- ---------------------------------------------------------------------------

INSERT INTO public.provider_names (name) VALUES
    ('Liquid Web, L.L.C'),
    ('InMotion Hosting, Inc.'),
    ('Springs Hosting'),
    ('Namecheap, Inc.'),
    ('Rackspace Hosting'),
    ('HostGator.com LLC'),
    ('New Dream Network, LLC'),
    ('Automattic, Inc'),
    ('OVH US LLC'),
    ('Incapsula Inc'),
    ('Brownrice Internet, Inc.'),
    ('Unified Layer'),
    ('Newfold Digital, Inc.'),
    ('CarsForSale.com')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- THIRD BATCH, from the spread detector in section 3 rather than from the
-- place-count ranking. Every one was surfaced by high distinct-zip3 spread, which
-- is the signature of a host: its clients are scattered nationally while a
-- genuine landmark's own places cluster around its own ZIP.
--
-- Reviewed and approved wholesale on the ground that retail traffic is improbable
-- to transit nodes near any of their facilities, which is the exclusion test
-- stated at the top of this file.
--
--   Vultr Holdings, LLC     221 places, 12 zip3 regions. Cloud compute.
--   Linode                  103 places. Cloud compute, now Akamai-owned, and a
--                           distinct registrant string from the Akamai entry.
--   Vercel, Inc             101 places. Front-end application hosting.
--   Expedient                75 places. Data centres and managed cloud.
--   Web.com Group, Inc.      70 places. Website builder and host.
--   CivicPlus, LLC           69 places. Hosted websites for municipalities, which
--                           is why its places look like city halls.
--   Tier.Net Technologies     50 places. Hosting and colocation.
--   OVH Hosting, Inc.        39 places, 8 zip3 regions. A DISTINCT registrant
--                           string from 'OVH US LLC' already seeded above. Both
--                           are needed because the match is on the exact name.
--   Otava, LLC               35 places. Managed cloud and colocation.
--   DFW Datacenter           26 places. Colocation, as the name states.
-- ---------------------------------------------------------------------------

INSERT INTO public.provider_names (name) VALUES
    ('Vultr Holdings, LLC'),
    ('Linode'),
    ('Vercel, Inc'),
    ('Expedient'),
    ('Web.com Group, Inc.'),
    ('CivicPlus, LLC'),
    ('Tier.Net Technologies LLC'),
    ('OVH Hosting, Inc.'),
    ('Otava, LLC'),
    ('DFW Datacenter')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- 1. WHAT THE SEED MATCHES, before changing anything.
--
-- Run this first. It reports how many currently-true rows each provider accounts
-- for, so the effect is visible before the onpremises step is rerun.
-- ---------------------------------------------------------------------------

SELECT t.registrant_1                                   AS registrant,
       t.registrant_1_zip                               AS zip,
       count(*)                                         AS places_now_true
FROM ovt_places_usa t
JOIN public.provider_names p
  ON lower(btrim(t.registrant_1)) = lower(btrim(p.name))
WHERE t.onpremises = true
GROUP BY 1, 2
ORDER BY 3 DESC;

SELECT count(*) AS total_rows_the_seed_will_flip_to_false
FROM ovt_places_usa t
WHERE t.onpremises = true
  AND (lower(btrim(t.registrant_1)) IN (SELECT lower(btrim(name)) FROM public.provider_names)
    OR lower(btrim(t.registrant_2)) IN (SELECT lower(btrim(name)) FROM public.provider_names));


-- ---------------------------------------------------------------------------
-- 2. WHAT THE SEED MISSES. The review query.
--
-- Non-ISP, non-provider registrants still judged on-premises, largest first.
-- Read it for anything that is plainly a host, a CDN or a website builder and add
-- it above. Anything that holds its own space and serves people from it, such as a
-- university or a hospital, stays out.
-- ---------------------------------------------------------------------------

SELECT t.registrant_1                                   AS registrant,
       t.registrant_1_zip                               AS zip,
       count(*)                                         AS places
FROM ovt_places_usa t
WHERE t.onpremises = true
  AND lower(btrim(t.registrant_1)) NOT IN (SELECT lower(btrim(name)) FROM isp_names)
  AND lower(btrim(t.registrant_1)) NOT IN (SELECT lower(btrim(name)) FROM public.provider_names)
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 60;


-- ---------------------------------------------------------------------------
-- 3. THE SELF-BUILDING DETECTOR. Ranking by place count alone cannot separate a
-- host from a landmark, because both produce large counts for different reasons.
--
-- A health system legitimately owns hundreds of Overture places: clinics,
-- departments, physician offices and laboratories are each a separate place, and
-- all of their websites point at the system's own server, so one address yields
-- one registrant and hundreds of rows. CarsForSale.com also yields hundreds, but
-- because it HOSTS hundreds of other companies' sites.
--
-- GEOGRAPHIC SPREAD separates them. A hospital's own places cluster around its
-- own ZIP. A host's clients are scattered nationally. Counting distinct 3-digit
-- ZIP prefixes and distinct states measures exactly that, and sorting by it
-- surfaces hosts without needing to recognise their names.
--
-- Read the top of this list: high spread with a high place count is a host.
-- ---------------------------------------------------------------------------

SELECT t.registrant_1                                            AS registrant,
       count(*)                                                  AS places,
       count(DISTINCT t.overture_zip)                            AS distinct_zips,
       count(DISTINCT left(t.overture_zip, 3))                   AS zip3_regions,
       count(DISTINCT t.ip_address)                              AS distinct_ips,
       count(*) FILTER (WHERE t.registrant_2 IS NOT NULL)        AS rows_with_second_registrant
FROM ovt_places_usa t
WHERE t.onpremises = true
  AND lower(btrim(t.registrant_1)) NOT IN (SELECT lower(btrim(name)) FROM isp_names)
  AND lower(btrim(t.registrant_1)) NOT IN (SELECT lower(btrim(name)) FROM public.provider_names)
GROUP BY 1
HAVING count(*) >= 25
ORDER BY count(DISTINCT left(t.overture_zip, 3)) DESC, count(*) DESC
LIMIT 60;


-- ---------------------------------------------------------------------------
-- 4. WHICH REGISTRANT ACTUALLY DECIDED THE ROW.
--
-- Section 2 groups by registrant_1, but the ZIP tests consider registrant_2 as
-- well, so a row can be true because the SECOND registrant's ZIP matched while the
-- first is a host. Any interpretation of section 2 that ignores this is unsound,
-- which is why this query exists rather than an assumption.
--
-- Substitute the registrant being examined.
-- ---------------------------------------------------------------------------

SELECT t.registrant_1,
       t.registrant_1_zip,
       t.registrant_2,
       t.registrant_2_zip,
       count(*)                                                  AS places,
       count(DISTINCT t.overture_zip)                            AS distinct_place_zips,
       min(t.overture_zip)                                       AS zip_lo,
       max(t.overture_zip)                                       AS zip_hi
FROM ovt_places_usa t
WHERE t.onpremises = true
  AND t.registrant_1 = 'CarsForSale.com'
GROUP BY 1, 2, 3, 4
ORDER BY 5 DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 5. SOUTHWEST CYBERPORT BELONGS IN isp_names, NOT HERE.
--
-- Confirmed from the operator's own site: a New Mexico ISP since 1994, selling DSL
-- through CenturyLink, its own LightSpeed fiber, fixed wireless, and building
-- connections. Its carrier node routes retail customers, which is what the method
-- needs, so classifying it as a provider would discard a useful anchor.
--
-- Not applied automatically: adding a name to isp_names turns rule 3 into a hard
-- true for every landmark behind it, which is a decision to take deliberately.
-- Uncomment to apply.
-- ---------------------------------------------------------------------------

INSERT INTO public.isp_names (name) VALUES ('Southwest Cyberport, Inc.')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- 6. SYNERGY NETWORKS: RESOLVED. IT BELONGS IN NEITHER LIST, and the earlier
-- recommendation in this file that it be added to isp_names was WRONG. It is
-- recorded here because the reasoning that overturned it is reusable.
--
-- Fort Myers FL, 33901. It is genuinely both businesses: its listings describe
-- "one of Florida's fastest-growing Internet Service Providers" selling
-- "business class internet", AND "web hosting, web design" with "data center and
-- hosting solutions".
--
-- FIRST QUESTION ASKED: do the two units register under different names, so that
-- the ISP role could set true and the hosting role false? Answer: NO. All of
-- Synergy's own space sits under ONE ARIN org handle, SYNN, fn exactly
-- 'Synergy Networks', at 2075 West First Street, Ft. Myers FL 33901. That single
-- org holds 12 networks, and both roles are inside it:
--
--     UU-63-75-167    63.75.167.0/24      contains 63.75.167.99, which serves
--                                         the HOSTED customer site snwebdm.com
--     SYNN-2075       65.87.192.0/22      2,048 addresses, named after their own
--                                         street number
--     plus 63.107.x, 63.109.x, 63.118.x, 63.126.x, 65.193.x, 65.202.x,
--     208.220.93.x, all legacy UUNET and MCI reassignments
--
-- RDAP on the hosting address returns registrant 'Synergy Networks', identical to
-- everything else. The NETNAME distinguishes the roles but the REGISTRANT does
-- not, and this pipeline keys on registrant_1 and registrant_2. A name-based split
-- is therefore impossible.
--
-- WORSE THAN AMBIGUOUS: the name is also used by Synergy's own CUSTOMERS. An ARIN
-- entity search for 'Synergy Networks*' returns eight orgs, and only SYNN is
-- Synergy's own:
--
--     C02229240, C02235678   Naples Beach Hotel & Golf Club, 851 Gulfshore Blvd N,
--                            Naples FL 34102
--     C02209929              'Synergy Networks - Brown and Brown', 3820 Colonial
--                            Blvd, Fort Myers 33966, the insurance broker
--     C01840002              2612 Edison Avenue, Ft Myers, a /29
--     SYNERG-53              2057 West First St, note 2057 not 2075, holding
--                            64.200.0.0/21 and /22 under Time Warner netnames
--     SYNERG-62              2075 West First Street, zero networks
--     C00921769              'Synergy Networks, Inc' in KANSAS CITY MO, an
--                            unrelated company on SBC space, and a distinct string
--
-- Three of those are downstream business customers SWIPed with the ISP's name in
-- the customer record. They are the most valuable landmarks available: real
-- premises, known ZIP, reached through Synergy's access network. They are
-- indistinguishable by name from the hosting block.
--
-- WHY NEITHER LIST IS THE RIGHT ANSWER. Synergy is absent from isp_names, so it is
-- adjudicated as a non-ISP registrant and rules 4 and 5 decide each place on its
-- own Overture ZIP against 33901. That is a PER-PLACE split, which is strictly
-- better than the per-company split originally sought. The measurement confirms it
-- separates cleanly:
--
--     onpremises = true    151 places, ALL in zip3 339, spread over eight ZIPs:
--                          33904 (45), 33907 (36), 33990 (20), 33901 (17),
--                          33919 (15), 33916 (9), 33903 (6), 33917 (3).
--                          Every one is Lee County FL.
--     onpremises = false   about 550 places across more than 60 zip3 regions,
--                          including 021 Boston, 100 New York, 112 Brooklyn,
--                          191 Philadelphia, 531 Milwaukee, 640 and 641 Kansas
--                          City, 750 Dallas, 900 and 902 Los Angeles, alongside
--                          147 that are in zip3 339 but more than one ZIP from
--                          33901.
--
-- The true set is the access network. The false set is the hosting business. The
-- ZIP rule drew the line by itself, with no name distinction.
--
-- ADDING IT TO isp_names WOULD BREAK THIS. Rule 3a makes a single ISP registrant a
-- hard true regardless of ZIP, so all ~550 nationally scattered hosted sites would
-- flip to true. Adding it to provider_names would discard 151 good Fort Myers
-- anchors. Doing nothing is correct.
--
-- THE GENERAL RULE THIS ESTABLISHES, which corrects the Southwest Cyberport
-- precedent rather than following it: a name belongs in isp_names only if it
-- routes retail AND does not host third parties, because membership is an
-- unconditional true that bypasses the ZIP test. A mixed ISP-and-host should be
-- left in NEITHER list so the ZIP test can adjudicate per place.
--
-- THIS PUTS SOUTHWEST CYBERPORT IN QUESTION, and the question is raised rather
-- than acted on, because adding it to isp_names was an explicit instruction and is
-- already applied live. swcp.com sells web hosting alongside its DSL, fiber and
-- fixed wireless, so by the rule above it is the same shape as Synergy and would
-- be better left out of isp_names. Its membership there now makes rule 3a a hard
-- true for every landmark behind it, including any site it merely hosts. The test
-- is the same measurement run for Synergy: if Southwest Cyberport's places cluster
-- in New Mexico it is harmless, and if they scatter nationally it is not. Awaiting
-- a decision, see section 5.
--
-- RESIDUAL ERROR, accepted. A Fort Myers business whose site Synergy hosts passes
-- the ZIP test while its adjacent node is Synergy's hosting edge, not its
-- subscriber edge. For an operator this small those are plausibly the same
-- aggregation, and even when they are not, the address is physically at 2075 West
-- First Street in 33901 while the business is in 33901 or a neighbour. The error
-- is bounded at one ZIP, inside the tolerance rule 5 already grants.
-- ---------------------------------------------------------------------------

-- DELIBERATELY NOT INSERTED ANYWHERE. Do not "fix" this by adding the name.


-- ---------------------------------------------------------------------------
-- 7. VERIFY THE ADJACENCY THAT CARRIED THE SYNERGY TRUE SET.
--
-- Only 17 of the 151 are in 33901 itself, so 134 passed on rule 5 as adjacent.
-- Three of the eight ZIPs are Cape Coral, across the Caloosahatchee from downtown
-- Fort Myers, and 33990 is mid-Cape rather than on the river. ZIP polygons often
-- extend across water, so adjacency is plausible, but 20 places rest on it and it
-- was asserted rather than checked. This query checks it.
--
-- Expect a row for each of the eight. A MISSING row means the place passed on
-- registrant_2's ZIP instead, which section 4 will show.
-- ---------------------------------------------------------------------------

-- zip_adjacency holds pairs in columns zip_a and zip_b, stored one way round only,
-- so the test must be symmetric. It is padded to five characters exactly as the
-- onpremises step does, because a numeric column loses leading zeros.

WITH adj AS (
    SELECT left(lpad(btrim(zip_a::text), 5, '0'), 5) AS a,
           left(lpad(btrim(zip_b::text), 5, '0'), 5) AS b FROM zip_adjacency
    UNION
    SELECT left(lpad(btrim(zip_b::text), 5, '0'), 5),
           left(lpad(btrim(zip_a::text), 5, '0'), 5) FROM zip_adjacency)
SELECT p.zip                                            AS place_zip,
       p.places,
       (p.zip = '33901')                                AS is_registrant_zip,
       EXISTS (SELECT 1 FROM adj WHERE adj.a = p.zip AND adj.b = '33901')
                                                        AS adjacent_to_33901,
       CASE WHEN p.zip = '33901' THEN 'rule 4, exact'
            WHEN EXISTS (SELECT 1 FROM adj WHERE adj.a = p.zip AND adj.b = '33901')
                 THEN 'rule 5, adjacent'
            ELSE 'NEITHER: passed on registrant_2, or a defect' END AS explains_the_true
FROM (VALUES ('33904', 45), ('33907', 36), ('33990', 20), ('33901', 17),
             ('33919', 15), ('33916',  9), ('33903',  6), ('33917',  3))
     AS p(zip, places)
ORDER BY 2 DESC;


-- ---------------------------------------------------------------------------
-- 8. TWO RDAP ADDRESS DEFECTS FOUND DURING THE SYNERGY LOOKUP, both of which
-- bear on the 367,334-row bucket '6a no non-ISP registrant ZIP: false'.
--
--   EMPTY ZIP FIELD, RECOVERABLE. SYNERG-62's address is
--   '2075 West First Street, , FL, ,'. Street and state are present, the ZIP is
--   blank. It is recoverable here: the sibling SYNN record at the same street
--   gives 33901. Some share of the 367k is likely this shape, which argues for
--   parsing the RDAP address text rather than only reading the ZIP field.
--
--   WRONG ZIP PRESENT, WORSE THAN ABSENT. C01840002 claims
--   '2612 Edison Avenue, Ft Myers, FL, 32204'. 32204 is JACKSONVILLE, about 300
--   miles away. A wrong-but-present ZIP is more damaging than a missing one
--   because it passes rules 4 and 5 against the wrong place rather than failing
--   safe. A street-and-city versus ZIP consistency check would catch it.
--
-- A THIRD CATEGORY, which is correctly false and must not be "recovered": ARIN is
-- the registry for Canada and much of the Caribbean as well as the United States.
-- A Canadian registrant's postal code is 'M5V 3A8', which cannot match the
-- five-digit heuristic in zip_from_address and could never equal a US Overture ZIP
-- anyway. Those rows belong in 6a permanently.
--
-- There is no registrant address COLUMN. The raw record is kept in url_location as
-- 'Registrant Entity : A | Geographic Address: ... | ...', and registrant_1_zip is
-- parsed out of it by zip_from_address, which takes a ZIP immediately after a
-- two-letter state code, else a ZIP at the end of the address. So the question
-- "is the ZIP recoverable" is a question about url_location, and this query
-- decomposes the bucket into the three cases before any parser work is attempted.
-- ---------------------------------------------------------------------------

SELECT count(*)                                                      AS rows_in_6a,
       count(DISTINCT t.registrant_1)                                AS distinct_registrants,
       count(*) FILTER (WHERE t.url_location LIKE '%Geographic Address%')
                                                                     AS have_address_text,
       count(*) FILTER (WHERE t.url_location ~ '[A-Z][0-9][A-Z][ ]?[0-9][A-Z][0-9]')
                                                                     AS looks_canadian,
       count(*) FILTER (WHERE t.url_location ~ '[0-9]{5}')
                                                                     AS has_five_digits_somewhere,
       count(*) FILTER (WHERE t.url_location LIKE '%Geographic Address%'
                          AND t.url_location !~ '[A-Z][0-9][A-Z][ ]?[0-9][A-Z][0-9]'
                          AND t.url_location ~ '[0-9]{5}')           AS candidate_recoverable
FROM ovt_places_usa t
WHERE t.lookup_status = 'true'
  AND t.onpremises IS NOT TRUE
  AND t.registrant_1 IS NOT NULL
  AND t.registrant_1_zip IS NULL
  AND t.registrant_2_zip IS NULL;


-- The registrants that would repay a parser fix, largest first. A handful of names
-- covering most of the bucket means a targeted fix is worthwhile; a long flat tail
-- means it is not. Read the address text to see WHY the heuristic missed.

SELECT t.registrant_1                                   AS registrant,
       count(*)                                         AS rows_in_6a,
       min(t.url_location)                              AS one_example_record
FROM ovt_places_usa t
WHERE t.lookup_status = 'true'
  AND t.onpremises IS NOT TRUE
  AND t.registrant_1 IS NOT NULL
  AND t.registrant_1_zip IS NULL
  AND t.registrant_2_zip IS NULL
  AND t.url_location LIKE '%Geographic Address%'
  AND t.url_location ~ '[0-9]{5}'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 40;


-- ---------------------------------------------------------------------------
-- ORG-NAME VARIANTS FOUND 2026-10-31
--
-- Matching is exact on lower(btrim(registrant)), so one organisation holding
-- several ARIN org records needs each string. Two slipped through.
--
-- HOW THEY WERE FOUND, AND WHAT THE RESIDUE ACTUALLY IS. After the onpremises
-- step was run to completion (an earlier run had stopped partway, leaving
-- 967,790 rows unevaluated), the only provider-like registrants remaining in
-- onpremises = true were:
--
--     Google Fiber Inc.             83 addresses
--     Microsoft Corp                 6 addresses
--     Amazon Data Services Italy     1 address
--
-- Google Fiber Inc. is CORRECT and stays out of this list. It is a retail ISP
-- serving several US regions, so its space does route subscribers, exactly as
-- the note on Google Fiber above says. Google's hosting is a separate ARIN org:
-- RDAP on 2026-10-31 returned 'Google LLC' for 8.8.8.8, for the GCP load
-- balancer 34.102.136.180, for the mail edge 172.253.157.27 and for the
-- googledomains nameserver 216.239.34.107, while 136.33.1.1 returned
-- 'Google Fiber Inc.'. Two orgs, one excluded, one not.
--
-- The other two are variants of names already listed above. RDAP on 2026-10-31
-- returned 'Microsoft Corporation' for both Azure (20.62.97.228) and Microsoft
-- 365 mail (52.101.11.17), so 'Microsoft Corp' is a separate, older org record
-- on other Microsoft space rather than a different company. Amazon Data
-- Services Italy is the non-US AWS entity; a landmark in a US ZIP whose website
-- resolves into it is not on premises by any reading.
--
-- KEEP THE SCALE IN VIEW. This is 7 addresses out of roughly 28,500. The 39
-- names in this list reject 10,713,526 of 12,775,630 rows, so exact matching is
-- not failing in any material way and does not need replacing with fuzzy
-- matching, which would risk excluding real ISPs. These are the residue, and
-- naming them is cheaper than changing how names are compared.
-- ---------------------------------------------------------------------------
INSERT INTO public.provider_names (name) VALUES
    ('Microsoft Corp'),
    ('Amazon Data Services Italy')
ON CONFLICT DO NOTHING;


DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cronuser') THEN
        GRANT SELECT ON public.provider_names TO cronuser;
        RAISE NOTICE 'granted provider_names to cronuser';
    ELSE
        RAISE NOTICE 'role cronuser does not exist, so no grant was made';
    END IF;
END
$$;
