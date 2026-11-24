-- carrier_match_qa.sql - score the matching against cases whose answer is
-- already known, which is what I should have done before issuing any of it.
--
-- BORIS, 2026-11-20: "Section 2: Numerous matches are incorrect. Matching
-- algorithm is comprehensively broken. You are not performing QA per
-- standing orders."
--
-- Both parts are correct. His own output contains the refutation and I sent
-- it to him without looking: AT&T's top candidate is comcastbusiness.net,
-- Starry's is harvard.edu, GeoLinks' is ucla.edu, Google Fiber's is
-- uprr.com, which is the Union Pacific Railroad.
--
-- WHY IT IS BROKEN, as a measurement rather than an apology
--
-- The test asked: does this domain have a site inside this provider's
-- footprint. From his own section 2 output, the tract counts of the largest
-- providers against the 85,528 tracts in the country:
--
--      AT&T              83,148   97.2 pct of all tracts
--      Verizon           82,803   96.8
--      provider 130403   84,474   98.8
--      Xfinity           36,151   42.3
--
-- For the providers that carry most of the footprint the answer is YES for
-- essentially any site anywhere. So pct_sites is 100 for nearly every
-- pairing and carries almost no information, which is exactly what the
-- output shows. The direction of the test is wrong: containment of a few
-- sites in a near-national footprint is not evidence. Had I computed the
-- single column above before shipping, I would have seen it.
--
-- WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
--
-- It does NOT propose a new ranking. Shipping a second untested method
-- after the first failed is the mistake repeated, not corrected. It builds
-- the harness first:
--
--   Section 0  integrity of the grouping key. provider_id 130077 carries
--              the brands AT&T AND Quantum Fiber, which is Lumen's brand,
--              and 130403 carries lumos and T-Mobile. If one provider_id
--              spans unrelated companies then every footprint grouped by
--              provider_id is a union of unrelated companies, and that is
--              upstream of all the matching. This section reports it; it
--              does not conclude, because I do not yet know whether that is
--              in the FCC data or in my load.
--   Section 1  a truth set, carrier_truth_set.tsv, with the basis of every
--              row stated: boris_ruling, name_identity where the domain
--              label IS the brand, or my_assertion where I am using outside
--              knowledge and need Boris to confirm or reject it.
--   Section 2  the score of the shipped geographic ranking against that
--              truth set, in both directions, with every failure listed.
--   Section 3  the discriminating power of each column, so the next
--              proposal is chosen on evidence.
--
-- Read-only apart from two tables of its own.

\timing on

\echo
\echo ================================================================
\echo SECTION 0. Is provider_id a sound grouping key. The brands and FRNs
\echo that share one provider_id. bdc_load.py inserts DISTINCT triples of
\echo frn, provider_id and brand_name from the source files, so whatever is
\echo here came from the filings as loaded.
\echo ================================================================
\echo
SELECT count(DISTINCT provider_id)                            AS provider_ids,
       count(*)                                               AS frn_brand_rows,
       count(DISTINCT frn)                                    AS frns
FROM bdc_carrier_tbl;

\echo
\echo Provider ids carrying more than one FRN. An FRN is the FCC
\echo registration of the filer, so several FRNs under one provider_id is
\echo the case to understand before trusting any footprint.
\echo
SELECT count(*) AS provider_ids_with_more_than_one_frn
FROM (SELECT provider_id FROM bdc_carrier_tbl
      GROUP BY 1 HAVING count(DISTINCT frn) > 1) x;

\echo
\echo The twenty largest providers by footprint, with every FRN and brand
\echo they carry. This is where AT&T and Quantum Fiber under one id can be
\echo judged.
\echo
WITH f AS (
    SELECT provider_id, count(*) AS provider_pairs
    FROM provider_tract_tech_tbl GROUP BY 1
    ORDER BY 2 DESC LIMIT 20
)
SELECT c.provider_id, f.provider_pairs, c.frn, c.brand_name
FROM f JOIN bdc_carrier_tbl c ON c.provider_id = f.provider_id
ORDER BY f.provider_pairs DESC, c.provider_id, c.frn, c.brand_name;

\echo
\echo ================================================================
\echo SECTION 1. The truth set. basis says what each row rests on, and
\echo my_assertion rows are mine to be judged rather than relied upon.
\echo ================================================================
\echo
DROP TABLE IF EXISTS carrier_truth_tbl;
CREATE TABLE carrier_truth_tbl (
    itdk_domain text NOT NULL,
    provider_id integer NOT NULL,
    basis       text NOT NULL,
    note        text);

\copy carrier_truth_tbl FROM '/home/boris/geo/src/claude/geo/carrier_nodes/carrier_truth_set.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

SELECT basis, count(*) AS rows FROM carrier_truth_tbl GROUP BY 1 ORDER BY 1;

\echo
\echo Truth rows whose provider_id is not in the loaded BDC data, or whose
\echo domain has no serving site. Either makes the row unscoreable, and a
\echo silently unscoreable row would flatter the score.
\echo
SELECT t.itdk_domain, t.provider_id, t.basis,
       EXISTS (SELECT 1 FROM bdc_carrier_tbl c
               WHERE c.provider_id = t.provider_id)      AS provider_exists,
       (SELECT count(*) FROM serving_site_tbl s
        WHERE s.carrier_domain = t.itdk_domain)          AS sites
FROM carrier_truth_tbl t
WHERE NOT EXISTS (SELECT 1 FROM bdc_carrier_tbl c
                  WHERE c.provider_id = t.provider_id)
   OR NOT EXISTS (SELECT 1 FROM serving_site_tbl s
                  WHERE s.carrier_domain = t.itdk_domain)
ORDER BY 3, 1;

\echo
\echo ================================================================
\echo SECTION 2. The score of the shipped ranking. For each truth pairing,
\echo where the correct provider ranks among the candidates offered for
\echo that domain, and where the correct domain ranks among the candidates
\echo offered for that provider.
\echo ================================================================
\echo
DROP TABLE IF EXISTS carrier_match_score_tbl;
CREATE TABLE carrier_match_score_tbl AS
WITH by_domain AS (
    SELECT carrier_domain, provider_id,
           row_number() OVER (PARTITION BY carrier_domain
                              ORDER BY pct_sites DESC,
                                       provider_pairs DESC) AS rank_for_domain,
           count(*)    OVER (PARTITION BY carrier_domain)   AS candidates_for_domain
    FROM carrier_match_tbl
), by_provider AS (
    SELECT carrier_domain, provider_id,
           row_number() OVER (PARTITION BY provider_id
                              ORDER BY pct_sites DESC, sites DESC) AS rank_for_provider,
           count(*)    OVER (PARTITION BY provider_id)             AS candidates_for_provider
    FROM carrier_match_tbl
)
SELECT t.itdk_domain, t.provider_id, t.basis,
       d.rank_for_domain, d.candidates_for_domain,
       p.rank_for_provider, p.candidates_for_provider,
       (d.rank_for_domain = 1)   AS provider_ranked_first_for_domain,
       (p.rank_for_provider = 1) AS domain_ranked_first_for_provider,
       (d.carrier_domain IS NULL) AS pairing_absent_from_candidates
FROM carrier_truth_tbl t
LEFT JOIN by_domain   d ON d.carrier_domain = t.itdk_domain
                        AND d.provider_id = t.provider_id
LEFT JOIN by_provider p ON p.carrier_domain = t.itdk_domain
                        AND p.provider_id = t.provider_id;

\echo
\echo THE SCORE. precision at 1 in each direction, by basis.
\echo
SELECT basis,
       count(*)                                              AS truth_pairings,
       count(*) FILTER (WHERE pairing_absent_from_candidates) AS not_proposed_at_all,
       count(*) FILTER (WHERE provider_ranked_first_for_domain) AS correct_provider_first,
       round(100.0 * count(*) FILTER (WHERE provider_ranked_first_for_domain)
             / count(*), 1)                                   AS pct_domain_direction,
       count(*) FILTER (WHERE domain_ranked_first_for_provider) AS correct_domain_first,
       round(100.0 * count(*) FILTER (WHERE domain_ranked_first_for_provider)
             / count(*), 1)                                   AS pct_provider_direction
FROM carrier_match_score_tbl
GROUP BY 1
ORDER BY 1;

SELECT 'ALL BASES'                                            AS basis,
       count(*)                                               AS truth_pairings,
       count(*) FILTER (WHERE pairing_absent_from_candidates)  AS not_proposed_at_all,
       count(*) FILTER (WHERE provider_ranked_first_for_domain) AS correct_provider_first,
       round(100.0 * count(*) FILTER (WHERE provider_ranked_first_for_domain)
             / count(*), 1)                                   AS pct_domain_direction,
       count(*) FILTER (WHERE domain_ranked_first_for_provider) AS correct_domain_first,
       round(100.0 * count(*) FILTER (WHERE domain_ranked_first_for_provider)
             / count(*), 1)                                   AS pct_provider_direction
FROM carrier_match_score_tbl;

\echo
\echo EVERY TRUTH PAIRING with its ranks. Full list, no sample. A rank of
\echo 1 out of 40 candidates is not the same achievement as 1 out of 2, so
\echo the candidate counts are beside it.
\echo
SELECT itdk_domain, provider_id, basis,
       rank_for_domain, candidates_for_domain,
       rank_for_provider, candidates_for_provider,
       CASE WHEN pairing_absent_from_candidates
            THEN 'NOT PROPOSED'
            WHEN rank_for_domain = 1 AND rank_for_provider = 1
            THEN 'first in both'
            WHEN rank_for_domain = 1 THEN 'first for the domain only'
            WHEN rank_for_provider = 1 THEN 'first for the provider only'
            ELSE 'first in neither' END AS verdict
FROM carrier_match_score_tbl
ORDER BY basis, rank_for_domain NULLS LAST, itdk_domain;

\echo
\echo ================================================================
\echo SECTION 3. Why it failed, and which columns carry any signal at all.
\echo ================================================================
\echo
\echo Provider footprint as a share of all census tracts. A provider above
\echo roughly 80 pct cannot be told apart from any other by containment,
\echo because every site in the country is inside it.
\echo
WITH f AS (
    SELECT provider_id, count(DISTINCT tract_geoid) AS tracts
    FROM provider_tract_tech_tbl GROUP BY 1
), tot AS (SELECT count(*) AS all_tracts FROM census_tract_tbl)
SELECT CASE WHEN 100.0 * f.tracts / tot.all_tracts >= 80 THEN 'a. 80 pct or more of all tracts'
            WHEN 100.0 * f.tracts / tot.all_tracts >= 40 THEN 'b. 40 to 80 pct'
            WHEN 100.0 * f.tracts / tot.all_tracts >= 10 THEN 'c. 10 to 40 pct'
            WHEN 100.0 * f.tracts / tot.all_tracts >= 1  THEN 'd. 1 to 10 pct'
            ELSE                                              'e. under 1 pct' END AS footprint_band,
       count(*)                                               AS providers,
       sum(f.tracts)                                          AS tracts_summed
FROM f CROSS JOIN tot
GROUP BY 1 ORDER BY 1;

\echo
\echo How many candidate providers each domain was offered. A domain with
\echo forty candidates all scoring 100 has not been narrowed at all.
\echo
SELECT CASE WHEN n = 1 THEN 'a. 1 candidate'
            WHEN n <= 3 THEN 'b. 2 to 3'
            WHEN n <= 10 THEN 'c. 4 to 10'
            WHEN n <= 30 THEN 'd. 11 to 30'
            ELSE 'e. more than 30' END   AS candidates,
       count(*)                          AS domains
FROM (SELECT carrier_domain, count(*) AS n
      FROM carrier_match_tbl GROUP BY 1) x
GROUP BY 1 ORDER BY 1;

\echo
\echo And the same for pct_sites, which is the column the ranking used.
\echo If almost every pairing scores 100 then the column cannot rank.
\echo
SELECT CASE WHEN pct_sites = 100 THEN 'a. exactly 100'
            WHEN pct_sites >= 50 THEN 'b. 50 to 99'
            WHEN pct_sites >= 20 THEN 'c. 20 to 49'
            ELSE                      'd. under 20' END AS pct_sites_band,
       count(*)                                         AS pairings,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_pairings
FROM carrier_match_tbl
GROUP BY 1 ORDER BY 1;

\timing off
