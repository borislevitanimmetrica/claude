-- step4_sanity.sql - why step 4 returned continental distances.
--
-- THE SYMPTOM, from Boris's run of 2026-11-18
--
--   nearest site more than 50 km away      18,696,580 pairs    96.7 per cent
--   only one site for this carrier         17,664,012 pairs    91.4 per cent
--
--   mean nearest distance, by technology
--     Licensed Fixed Wireless    1,740.7 km   median 1,439.6
--     Copper                     1,585.5 km   median 1,296.0
--     Fiber to the Premises      1,447.1 km   median 1,135.1
--
-- No headend serves a census tract 1,400 km away. These are not distances
-- to serving sites; they are distances to the wrong sites.
--
-- WHAT THE CARRIER LIST SHOWS, which is where the answer starts
--
-- The domains with the LARGEST claimed footprints in that run were:
--
--   qis.net                 156,883 triples   2 sites
--   kmppi.com               156,524 triples   1 site
--   tasc.org                156,524 triples   1 site
--   sammusicbiz.com         156,524 triples   1 site
--   martinsprocket.com      156,524 triples   1 site
--   racingchannel.com       156,524 triples   1 site
--   peaceofmindplan.com     156,524 triples   1 site
--   rapidmfg.com            156,524 triples   1 site
--   zenithfuelsystems.com        22 triples   1 site
--
-- A sprocket manufacturer is not a carrier. Neither is a music business, a
-- racing channel, an insurance plan or a fuel systems company. These are END
-- CUSTOMER domains: the reverse DNS of customer premises equipment, or of
-- address space a carrier has assigned to a customer.
--
-- They are each credited with 156,524 carrier-technology-tract pairs, which
-- is a national footprint, while having ONE known site. Every tract in that
-- footprint is then measured to that single site, which is precisely how a
-- median of 1,296 km arises.
--
-- MY HYPOTHESIS, LABELLED AS ONE. I believe these domains inherited a real
-- carrier's entire service footprint through the domain-to-BDC-provider
-- link, most likely via the ASN: a customer sitting on a carrier's ASN
-- resolves to that carrier's BDC name, and therefore to all of its tracts.
--
-- I HAVE NOT VERIFIED THAT and this file does not assume it. label_basis in
-- carrier_resolved_tbl records which rule produced each link, so the
-- mechanism is a fact in the data. Section 1 asks for it. Nothing should be
-- filtered or discarded until that answer is in, because the remedy differs
-- entirely depending on the rule: a bad ASN inheritance is fixed by changing
-- how ASN links are formed, while a bad name match is fixed by raising the
-- matcher's standard.
--
-- WHAT IS NOT IN DOUBT: step 4's current output must not be used. 96.7 per
-- cent of it measures a tract against a site belonging to something that is
-- not its carrier.

\echo
\echo ================================================================
\echo 1. HOW DID THESE DOMAINS GET A BDC PROVIDER. The mechanism.
\echo ================================================================
\echo
\echo label_basis records which rule produced each link. If the large-footprint
\echo domains share one basis, that rule is the fault.
\echo

SELECT r.label_basis,
       count(*)                        AS resolved_rows,
       count(DISTINCT r.itdk_domain)   AS domains,
       count(*) FILTER (WHERE r.by_decision) AS by_boris_decision
FROM carrier_resolved_tbl r
WHERE r.bdc_provider_id IS NOT NULL
GROUP BY 1 ORDER BY count(*) DESC;

\echo
\echo The same, restricted to the domains carrying an implausible footprint:
\echo more than 10,000 tract-technology pairs on 2 sites or fewer.
\echo
WITH big AS (
    SELECT s.itdk_domain,
           count(*) AS triples,
           (SELECT count(*) FROM serving_site_tbl v
            WHERE v.carrier_domain = s.itdk_domain) AS sites
    FROM step4_tract_site_tbl s
    GROUP BY 1
    HAVING count(*) > 10000
)
SELECT r.label_basis,
       count(DISTINCT b.itdk_domain) AS domains,
       sum(b.triples)                AS triples_affected,
       count(*) FILTER (WHERE r.by_decision) AS by_boris_decision
FROM big b
JOIN carrier_resolved_tbl r ON r.itdk_domain = b.itdk_domain
WHERE b.sites <= 2
GROUP BY 1 ORDER BY sum(b.triples) DESC;

\echo
\echo ================================================================
\echo 2. THE INCOHERENCE, MEASURED. Footprint against site count.
\echo ================================================================
\echo
\echo A carrier serving tens of thousands of census tracts has many
\echo facilities. One that serves 156,524 tract-technology pairs from a
\echo single known site is not a carrier with an undiscovered network; the
\echo footprint does not belong to it.
\echo
\echo This is a RATIO, not a threshold on site count. A rural carrier with
\echo one site and forty tracts is entirely coherent and must not be caught
\echo by this.
\echo

SELECT CASE
         WHEN triples_per_site >= 50000 THEN 'a. 50,000+ tracts per site'
         WHEN triples_per_site >= 10000 THEN 'b. 10,000 to 50,000'
         WHEN triples_per_site >=  1000 THEN 'c. 1,000 to 10,000'
         WHEN triples_per_site >=   100 THEN 'd. 100 to 1,000'
         ELSE                                'e. under 100, coherent'
       END                              AS ratio_band,
       count(*)                         AS domains,
       sum(triples)                     AS triples,
       round(100.0 * sum(triples) / sum(sum(triples)) OVER (), 1) AS pct_of_step4,
       round(avg(median_km)::numeric, 0) AS mean_of_median_km
FROM (
    SELECT s.itdk_domain,
           count(*) AS triples,
           (SELECT count(*) FROM serving_site_tbl v
            WHERE v.carrier_domain = s.itdk_domain) AS sites,
           count(*)::numeric / greatest((SELECT count(*) FROM serving_site_tbl v
                                         WHERE v.carrier_domain = s.itdk_domain), 1)
             AS triples_per_site,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.nearest_km) AS median_km
    FROM step4_tract_site_tbl s
    GROUP BY 1
) z
GROUP BY 1 ORDER BY 1;

\echo
\echo The twenty worst, named, with what ip-api and RDAP call them. If those
\echo names are a manufacturer or a charity rather than a network, the domain
\echo is an end customer and its footprint is inherited.
\echo
WITH z AS (
    SELECT s.itdk_domain,
           count(*) AS triples,
           (SELECT count(*) FROM serving_site_tbl v
            WHERE v.carrier_domain = s.itdk_domain) AS sites,
           round(percentile_cont(0.5) WITHIN GROUP
                 (ORDER BY s.nearest_km)::numeric, 0) AS median_km
    FROM step4_tract_site_tbl s
    GROUP BY 1
)
SELECT z.itdk_domain, z.triples, z.sites, z.median_km,
       left(max(c.ipapi_isp), 26) AS ipapi_isp,
       left(max(c.rdap_name), 26) AS rdap_name,
       left(max(r.bdc_name_given), 24) AS bdc_name,
       max(r.label_basis) AS label_basis
FROM z
LEFT JOIN carrier_crosswalk_tbl c ON c.itdk_domain = z.itdk_domain
LEFT JOIN carrier_resolved_tbl r ON r.itdk_domain = z.itdk_domain
GROUP BY 1, 2, 3, 4
ORDER BY z.triples::numeric / greatest(z.sites, 1) DESC
LIMIT 20;

\echo
\echo ================================================================
\echo 3. WHAT SURVIVES. Step 4 restricted to coherent carriers.
\echo ================================================================
\echo
\echo The same distance bands, counting only domains whose footprint is
\echo plausible for their site count. NOT a recommendation to adopt this
\echo threshold: it is a measurement of how much of step 4 is salvageable
\echo once the incoherent attributions are set aside.
\echo

WITH z AS (
    SELECT s.itdk_domain,
           count(*)::numeric / greatest((SELECT count(*) FROM serving_site_tbl v
                                         WHERE v.carrier_domain = s.itdk_domain), 1)
             AS triples_per_site
    FROM step4_tract_site_tbl s GROUP BY 1
)
SELECT CASE WHEN s.nearest_km IS NULL THEN 'no site'
            WHEN s.nearest_km <= 2   THEN 'a. within 2 km'
            WHEN s.nearest_km <= 10  THEN 'b. 2 to 10 km'
            WHEN s.nearest_km <= 25  THEN 'c. 10 to 25 km'
            WHEN s.nearest_km <= 50  THEN 'd. 25 to 50 km'
            ELSE                          'e. more than 50 km' END AS band,
       count(*) AS carrier_tract_pairs,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM step4_tract_site_tbl s
JOIN z ON z.itdk_domain = s.itdk_domain
WHERE z.triples_per_site < 1000
GROUP BY 1 ORDER BY 1;

\echo
\echo And the carriers that remain, largest first. These should look like
\echo networks.
\echo
WITH z AS (
    SELECT s.itdk_domain, count(*) AS triples,
           (SELECT count(*) FROM serving_site_tbl v
            WHERE v.carrier_domain = s.itdk_domain) AS sites,
           count(*)::numeric / greatest((SELECT count(*) FROM serving_site_tbl v
                                         WHERE v.carrier_domain = s.itdk_domain), 1)
             AS triples_per_site,
           round(percentile_cont(0.5) WITHIN GROUP
                 (ORDER BY s.nearest_km)::numeric, 1) AS median_km
    FROM step4_tract_site_tbl s GROUP BY 1
)
SELECT itdk_domain, triples, sites, median_km
FROM z WHERE triples_per_site < 1000
ORDER BY triples DESC LIMIT 25;

\echo
\echo ================================================================
\echo READ IT THIS WAY
\echo ================================================================
\echo
\echo Section 1 names the RULE that produced the bad links. That decides the
\echo remedy and nothing should be changed before it is read.
\echo
\echo Section 2 measures the incoherence and names the worst domains with
\echo what ip-api and RDAP call them, which is independent evidence of
\echo whether a domain is a network or a customer.
\echo
\echo Section 3 shows how much of step 4 survives. If the distance bands
\echo there look like a real network, the geometry was never the problem and
\echo the attribution was.
\echo
