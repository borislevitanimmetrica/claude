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
-- the method wants. It belongs in isp_names, where it is currently MISSING from
-- the 1,100 names. See the final section.
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
-- 3. SOUTHWEST CYBERPORT BELONGS IN isp_names, NOT HERE.
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
-- SYNERGY NETWORKS IS THE GENUINELY AMBIGUOUS ONE, and it is left for a decision.
--
-- Fort Myers FL, 33901, 151 places. It is both: its own listings describe "one of
-- Florida's fastest-growing Internet Service Providers" selling "Broadband
-- Internet access" and "business class internet", AND "web hosting, web design"
-- with "data center and hosting solutions".
--
-- That makes it the same shape as Southwest Cyberport, which was resolved in
-- favour of isp_names. The argument for doing the same here is that a node selling
-- business-class access in Fort Myers routes retail business customers, which is
-- exactly what the method wants. The argument against is that the hosted sites sit
-- in its data centre rather than at the landmark.
--
-- Recommended: isp_names, on the Southwest Cyberport precedent. Not applied.
-- ---------------------------------------------------------------------------

-- INSERT INTO public.isp_names (name) VALUES ('Synergy Networks')
-- ON CONFLICT DO NOTHING;


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
