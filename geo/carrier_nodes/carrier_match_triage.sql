-- carrier_match_triage.sql - turn 23,126 candidate pairings into an
-- approval queue ordered by what it buys, plus the three things the first
-- run exposed.
--
-- WHY A QUEUE RATHER THAN A LIST
--
-- 23,126 pairings over 2,568 domains is not a thing anyone approves in
-- order. But step 4 does not need every domain resolved; it needs every
-- PROVIDER to have a site set, because the provider is what carries the
-- tract-technology footprint. So the queue is inverted: one block per
-- provider, largest footprint first, with its candidate domains ranked
-- beneath it. 905 providers have candidates, and section 3 says how far
-- down the list the coverage runs out, so the approving can stop at a
-- defensible point instead of an arbitrary one.
--
-- THE LIMITATION I AM NOT HIDING
--
-- Geography answers WHICH provider, given that the domain belongs to a
-- carrier. It cannot answer WHETHER the domain belongs to a carrier.
-- freeweld.com has one site, that site sits in a tract AT&T serves, and it
-- will therefore show pct_sites of 100 against AT&T and look perfect. It is
-- a welding business. The discriminator that remains is structural rather
-- than geographic: a carrier has sites in MANY cities, a customer has one.
-- sites and cities are carried on every row for exactly that reason, and no
-- threshold on them is applied here.
--
-- WHAT ELSE THE FIRST RUN SHOWED
--
-- 1. Two of Boris's own rulings, mcleodusa.net and netaxs.com against
--    provider 131413, appear among the 5,411 pairings with no site in the
--    provider footprint. A ruling outranks any test here, so this is
--    reported as a question about the geography, not about the ruling.
--    Section 1 lists all eight ruled pairings with their support.
--
-- 2. The largest orphan providers are Puerto Rico, the Virgin Islands and
--    the Pacific: Claro, Neptuno Media, Liberty and Broadband VI, Worldnet
--    Telecommunications, Docomo Pacific, GTA, WiFi Services Caribbean,
--    OSNET, COSOTNET. ITDK located no carrier nodes there. Section 4 counts
--    the orphan footprint by state and territory so the hole is sized
--    rather than guessed at.
--
-- 3. Every one of the 6,256 sites was placed in a tract and the MEAN
--    distance to the chosen centroid was 1.1 km. That is a mean, and a mean
--    hides the rural tail: a nearest centroid is NOT the containing tract,
--    and in a large rural tract the two can differ. Section 5 gives the
--    distribution, which says whether a point-in-polygon test is needed or
--    whether the question is academic.
--
-- Read-only except for one TSV written for the approval sheet.

\timing on

\echo
\echo SECTION 1. Every pairing that rests on a ruling of yours, with whether
\echo geography supports it. A ruling outranks the geography, so a row with
\echo no support is a question about my method rather than about your call.
\echo
SELECT r.itdk_domain,
       r.bdc_provider_id,
       left(coalesce(r.bdc_name_given, ''), 26)       AS name_you_gave,
       (SELECT count(*) FROM serving_site_tbl s
        WHERE s.carrier_domain = r.itdk_domain)        AS sites,
       coalesce(m.sites_in_footprint, 0)               AS sites_in_footprint,
       coalesce(m.pct_sites, 0)                        AS pct_sites,
       CASE WHEN (SELECT count(*) FROM serving_site_tbl s
                  WHERE s.carrier_domain = r.itdk_domain) = 0
            THEN 'UNSCOREABLE - this domain has no located site at all'
            WHEN m.carrier_domain IS NULL
            THEN 'NO SUPPORT - it has sites and none is in this footprint'
            ELSE 'supported' END                       AS geography
FROM carrier_resolved_tbl r
LEFT JOIN carrier_match_tbl m ON m.carrier_domain = r.itdk_domain
                             AND m.provider_id = r.bdc_provider_id
WHERE r.by_decision
  AND r.bdc_provider_id IS NOT NULL
GROUP BY 1, 2, 3, 5, 6, 7
ORDER BY 7, 1;

\echo
\echo SECTION 2. The approval queue. One block per provider, largest
\echo footprint first, candidate domains ranked by how many of their sites
\echo sit in that footprint and then by site count. cities is on every row
\echo because a carrier has sites in many cities and a customer has one.
\echo Printed to sixty rows; the whole thing goes to the TSV.
\echo
DROP TABLE IF EXISTS carrier_match_queue_tbl;
CREATE TABLE carrier_match_queue_tbl AS
WITH cities AS (
    SELECT carrier_domain, count(DISTINCT city) AS cities
    FROM serving_site_tbl GROUP BY 1
), ranked AS (
    SELECT m.provider_id, m.brand_names, m.provider_pairs, m.provider_tracts,
           m.carrier_domain, m.sites, c.cities, m.sites_in_footprint,
           m.pct_sites, m.pairs_per_site, m.name_link, m.by_decision,
           row_number() OVER (PARTITION BY m.provider_id
                              ORDER BY m.pct_sites DESC, m.sites DESC,
                                       c.cities DESC) AS rank_for_provider
    FROM carrier_match_tbl m
    LEFT JOIN cities c ON c.carrier_domain = m.carrier_domain
)
SELECT * FROM ranked;

CREATE INDEX carrier_match_queue_ix
    ON carrier_match_queue_tbl (provider_pairs DESC, provider_id,
                                rank_for_provider);
ANALYZE carrier_match_queue_tbl;

COMMENT ON TABLE carrier_match_queue_tbl IS
'The candidate pairings of carrier_match_tbl, ranked within each provider so the best-supported domain for that provider comes first. Ordered for approval by provider footprint, because step 4 needs every PROVIDER to have a site set and the provider is what carries the tract-technology footprint. Geography cannot distinguish a carrier from a customer sitting in that carrier footprint, which is why sites and cities travel on every row.';

SELECT provider_id, left(coalesce(brand_names, ''), 30) AS brand_names,
       provider_pairs, carrier_domain, sites, cities,
       sites_in_footprint, pct_sites, pairs_per_site, name_link, by_decision
FROM carrier_match_queue_tbl
WHERE rank_for_provider <= 3
ORDER BY provider_pairs DESC, provider_id, rank_for_provider
LIMIT 60;

\echo
\echo SECTION 3. How far down the queue to go. Cumulative share of the
\echo national tract-technology footprint as providers are approved in
\echo descending order of their own footprint, counting only providers that
\echo have a candidate with half their sites or more in the footprint.
\echo
WITH q AS (
    SELECT DISTINCT provider_id, provider_pairs
    FROM carrier_match_queue_tbl
    WHERE pct_sites >= 50
), c AS (
    SELECT provider_id, provider_pairs,
           row_number() OVER (ORDER BY provider_pairs DESC) AS n,
           sum(provider_pairs) OVER (ORDER BY provider_pairs DESC,
                                     provider_id) AS cum_pairs
    FROM q
)
SELECT n AS providers_approved, provider_pairs AS this_provider,
       cum_pairs,
       round(100.0 * cum_pairs / (SELECT count(*)
                                  FROM provider_tract_tech_tbl), 1) AS pct_of_national
FROM c
WHERE n IN (1, 5, 10, 20, 30, 50, 75, 100, 150, 200, 300, 400, 500)
ORDER BY n;

\echo
\echo SECTION 4. The orphan footprint by state and territory. A provider
\echo with no candidate domain cannot be placed, and this says where that
\echo loss falls.
\echo
SELECT t.state_usps,
       count(*)                           AS orphan_pairs,
       count(DISTINCT p.provider_id)      AS orphan_providers,
       count(DISTINCT p.tract_geoid)      AS tracts
FROM provider_tract_tech_tbl p
JOIN census_tract_tbl t ON t.tract_geoid = p.tract_geoid
WHERE NOT EXISTS (SELECT 1 FROM carrier_match_tbl m
                  WHERE m.provider_id = p.provider_id)
GROUP BY 1
ORDER BY 2 DESC
LIMIT 20;

\echo
\echo SECTION 5. Distance from each site to the tract centroid it was
\echo assigned. The nearest centroid is NOT the containing tract, so this
\echo decides whether a point-in-polygon test is needed or whether the
\echo question is academic.
\echo
SELECT CASE WHEN tract_km <= 1   THEN 'a. within 1 km'
            WHEN tract_km <= 2   THEN 'b. 1 to 2 km'
            WHEN tract_km <= 5   THEN 'c. 2 to 5 km'
            WHEN tract_km <= 10  THEN 'd. 5 to 10 km'
            WHEN tract_km <= 25  THEN 'e. 10 to 25 km'
            ELSE                      'f. over 25 km' END AS band,
       count(*)                                           AS sites,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct,
       count(DISTINCT carrier_domain)                     AS domains
FROM site_tract_tbl
GROUP BY 1 ORDER BY 1;

\echo
\echo The sites furthest from their assigned centroid, which are the ones a
\echo containing-tract test would be most likely to move.
\echo
SELECT carrier_domain, region, round(lat::numeric, 4) AS lat,
       round(lon::numeric, 4) AS lon, tract_geoid, state_usps, tract_km
FROM site_tract_tbl
ORDER BY tract_km DESC NULLS LAST
LIMIT 20;

\echo
\echo Writing the full approval queue.
\echo
\copy (SELECT provider_id, brand_names, provider_pairs, provider_tracts, carrier_domain, sites, cities, sites_in_footprint, pct_sites, pairs_per_site, name_link, by_decision, rank_for_provider FROM carrier_match_queue_tbl ORDER BY provider_pairs DESC, provider_id, rank_for_provider) TO '/home/boris/geo/carrier_match_queue.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
