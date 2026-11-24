-- carrier_link_audit.sql - audit the ITDK-domain to BDC-provider link from
-- BOTH ends, because the step 4 output says it is wrong in both directions.
--
-- WHAT THE CLASSIFICATION RUN SHOWED THAT I DID NOT EXPECT
--
-- The contamination was the known fault: customer domains inheriting a
-- carrier's national footprint. The run exposed a second fault that is its
-- mirror image, and it is visible in Boris's own output:
--
--   domain          sites   triples
--   comcast.net       788        19
--   spectrum.com      453        19
--   charter.com        98        19
--   level3.net         71        19
--   sbcglobal.net     110   155,648
--   verizon.net       157    93,768
--
-- triples is the number of (technology, tract) pairs the linked BDC provider
-- serves. Comcast files for a large part of the country, so 19 cannot be its
-- footprint. And domains whose ip-api name reads 'Spectrum' were credited
-- with 60,089 pairs while spectrum.com itself got 19, so the same brand
-- resolved to DIFFERENT providers depending on the domain.
--
-- That is an inference from two numbers, not yet a diagnosis. The two
-- candidate explanations are distinguishable by query, which is what this
-- file does rather than argue:
--
--   (a) the name rule picked a small provider whose brand_name happens to
--       contain the string, leaving the real provider unlinked; or
--   (b) the real provider carries few rows in provider_tract_tech_tbl,
--       which would mean a load or aggregation fault upstream of step 4.
--
-- Section 2 settles it: it lists the largest providers by footprint and
-- says which ITDK domain, if any, points at each. If Comcast's real
-- provider is large and unlinked, it is (a). If no provider has a large
-- footprint, it is (b).
--
-- Section 3 is the number that matters for the plan: how much of the BDC
-- footprint step 4 can reach at all, being the providers that are linked to
-- a domain that has at least one located site.
--
-- Read-only throughout. Creates nothing, changes nothing.

\echo
\echo ================================================================
\echo SECTION 1. The domains that carry the coverage, and the providers
\echo they resolved to. A domain with many sites and a tiny provider
\echo footprint is a mis-link; a domain with one site and a national
\echo footprint is the contamination already known.
\echo ================================================================
\echo

SELECT count(*) AS domains_with_5_or_more_sites
FROM (SELECT carrier_domain FROM serving_site_tbl
      GROUP BY 1 HAVING count(*) >= 5) x;

WITH f AS (
    SELECT provider_id, count(*) AS provider_pairs
    FROM provider_tract_tech_tbl GROUP BY 1
), site AS (
    SELECT carrier_domain, count(*) AS sites, count(DISTINCT city) AS cities
    FROM serving_site_tbl GROUP BY 1 HAVING count(*) >= 5
), brand AS (
    SELECT provider_id, min(brand_name) AS brand_name
    FROM bdc_carrier_tbl GROUP BY 1
)
SELECT s.carrier_domain, s.sites, s.cities,
       r.bdc_provider_id,
       left(coalesce(b.brand_name, ''), 30) AS bdc_brand,
       coalesce(f.provider_pairs, 0)        AS provider_pairs,
       r.by_decision,
       left(coalesce(r.label_basis, ''), 34) AS label_basis
FROM site s
LEFT JOIN carrier_resolved_tbl r ON r.itdk_domain = s.carrier_domain
                                AND r.bdc_provider_id IS NOT NULL
LEFT JOIN brand b ON b.provider_id = r.bdc_provider_id
LEFT JOIN f     ON f.provider_id = r.bdc_provider_id
ORDER BY s.sites DESC, s.carrier_domain, coalesce(f.provider_pairs, 0) DESC;

\echo
\echo ================================================================
\echo SECTION 2. The other end. The forty largest BDC providers by
\echo footprint, and which ITDK domains point at each. A large provider
\echo with no domain is a carrier step 4 cannot place at all, however
\echo correct the rest of the pipeline is.
\echo ================================================================
\echo

WITH f AS (
    SELECT provider_id,
           count(*)                    AS provider_pairs,
           count(DISTINCT tract_geoid) AS tracts
    FROM provider_tract_tech_tbl GROUP BY 1
), brand AS (
    SELECT provider_id, min(brand_name) AS brand_name
    FROM bdc_carrier_tbl GROUP BY 1
), linked AS (
    SELECT r.bdc_provider_id,
           count(DISTINCT r.itdk_domain) AS domains,
           count(DISTINCT r.itdk_domain) FILTER (
             WHERE EXISTS (SELECT 1 FROM serving_site_tbl s
                           WHERE s.carrier_domain = r.itdk_domain))
                                         AS domains_with_sites,
           left(string_agg(DISTINCT r.itdk_domain, ', '), 60) AS some_domains
    FROM carrier_resolved_tbl r
    WHERE r.bdc_provider_id IS NOT NULL
    GROUP BY 1
)
SELECT f.provider_id,
       left(coalesce(b.brand_name, ''), 34) AS bdc_brand,
       f.provider_pairs, f.tracts,
       coalesce(l.domains, 0)            AS itdk_domains,
       coalesce(l.domains_with_sites, 0) AS of_which_have_sites,
       coalesce(l.some_domains, 'NONE - this carrier cannot be placed')
                                         AS domains
FROM f
LEFT JOIN brand  b ON b.provider_id = f.provider_id
LEFT JOIN linked l ON l.bdc_provider_id = f.provider_id
ORDER BY f.provider_pairs DESC
LIMIT 40;

\echo
\echo ================================================================
\echo SECTION 3. How much of the WIRELINE BDC footprint step 4 can
\echo reach. Wireless is excluded from the denominator: it cannot carry
\echo a ZIP answer, and including it made this figure meaningless.
\echo ================================================================
\echo

-- WIRELINE ONLY. Added 2026-11-24. Without this the headline coverage is
-- dominated by licensed fixed wireless: on Boris's run technology 71 alone
-- holds 282,768 of the 785,168 tract-technology pairs, more than Copper,
-- Cable and FTTP together, and AT&T, Verizon and lumos each read about
-- 83,000 tracts, which is 97 percent of the country and is their wireless
-- licence area rather than their plant. Wireless cannot answer a ZIP
-- question and he ruled it out of scope on 2026-11-22, so it does not belong
-- in the denominator of a coverage figure. The full split by technology is
-- still printed below, unfiltered, so nothing is hidden.
WITH f AS (
    SELECT provider_id, count(*) AS provider_pairs
    FROM provider_tract_tech_tbl
    WHERE technology IN (10, 40, 50)
    GROUP BY 1
), reach AS (
    SELECT f.provider_id, f.provider_pairs,
           EXISTS (SELECT 1 FROM carrier_resolved_tbl r
                   WHERE r.bdc_provider_id = f.provider_id
                     AND EXISTS (SELECT 1 FROM serving_site_tbl s
                                 WHERE s.carrier_domain = r.itdk_domain))
                                                    AS has_a_site,
           EXISTS (SELECT 1 FROM carrier_resolved_tbl r
                   WHERE r.bdc_provider_id = f.provider_id
                     AND r.by_decision
                     AND EXISTS (SELECT 1 FROM serving_site_tbl s
                                 WHERE s.carrier_domain = r.itdk_domain))
                                                    AS has_a_site_by_ruling
    FROM f
)
SELECT count(*)                                         AS providers,
       sum(provider_pairs)                              AS tract_tech_pairs,
       count(*) FILTER (WHERE has_a_site)               AS providers_placeable,
       sum(provider_pairs) FILTER (WHERE has_a_site)    AS pairs_placeable,
       round(100.0 * sum(provider_pairs) FILTER (WHERE has_a_site)
             / nullif(sum(provider_pairs), 0), 1)       AS pct_placeable,
       count(*) FILTER (WHERE has_a_site_by_ruling)     AS providers_by_ruling,
       sum(provider_pairs) FILTER (WHERE has_a_site_by_ruling)
                                                        AS pairs_by_ruling,
       round(100.0 * sum(provider_pairs) FILTER (WHERE has_a_site_by_ruling)
             / nullif(sum(provider_pairs), 0), 1)       AS pct_by_ruling
FROM reach;

\echo
\echo The same split by technology, since the plan is per technology and a
\echo technology with no placeable provider is a hole in the result rather
\echo than a smaller number.
\echo
SELECT p.technology,
       left(coalesce(t.code_desc, ''), 26) AS technology_name,
       count(*)                                  AS tract_tech_pairs,
       count(*) FILTER (
         WHERE EXISTS (SELECT 1 FROM carrier_resolved_tbl r
                       WHERE r.bdc_provider_id = p.provider_id
                         AND EXISTS (SELECT 1 FROM serving_site_tbl s
                                     WHERE s.carrier_domain = r.itdk_domain)))
                                                 AS placeable
FROM provider_tract_tech_tbl p
LEFT JOIN bdc_technology_tbl t ON t.technology = p.technology
GROUP BY 1, 2 ORDER BY 1;
