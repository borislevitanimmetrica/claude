-- domain_classify.sql - classify EVERY resolved domain, not the top twenty.
--
-- WHY, AND THE CORRECTION THAT PROMPTED IT
--
-- Boris, 2026-11-18: "None of the domains returned in the second run,
-- section 2, are carriers. All the domains returned in section 3 are
-- carriers except tunahelper.net. But in both sections, you've listed only a
-- fixed number of domains. There may be inappropriately classified domains
-- in the records you haven't listed."
--
-- He is right and it is a defect in the diagnostic, not a detail. Both
-- sections ended in LIMIT 20 and LIMIT 25. A sample can show that a problem
-- EXISTS; it cannot show its extent, and I presented the sample as though it
-- had. Every classification here covers all rows, and every display that is
-- truncated prints the full count beside it so nothing hides behind a LIMIT.
--
-- WHAT THE SANITY RUN ESTABLISHED, as fact rather than hypothesis
--
-- The rule that produced the bad links, from label_basis:
--
--   proposed pairing, normalised name contained   237 domains  137,640,993 triples
--   proposed pairing, normalised name equal        68 domains    5,047,667
--   proposed pairing, first word only, WEAK         2 domains      372,083
--
-- all with by_boris_decision = 0. These are the machine-generated proposals
-- that were reported as awaiting approval, and carrier_resolved_tbl has been
-- joining through them regardless. My earlier claim that step 4 was blocked
-- on approval was wrong in one direction and this is wrong in the other: the
-- proposals were never approved AND were being used.
--
-- WHY THE MATCHER FAILED, which is not a string-comparison bug
--
-- ip-api and RDAP name the UPSTREAM CARRIER for a customer's address space.
-- freeweld.com, galaxydoor.com, ctlogistics.com, dailyjournal.com and
-- hundreds like them all report ipapi_isp and rdap_name of
-- "AT&T Enterprises, LLC", because that is whose registration covers the
-- block. The matcher compared that name to BDC brands, found AT&T, and gave
-- each customer domain AT&T's entire national footprint of 155,648
-- tract-technology pairs against its ONE known site. Hence a 1,494 km
-- median.
--
-- So the input was wrong, not the comparison. The name attached to a
-- customer prefix is the carrier's name.
--
-- THE DISCRIMINATOR, and it is measurable
--
-- A carrier's own domain resembles its own name. A customer's domain does
-- not resemble its upstream's name.
--
--   verizon.net        against Verizon                 shares "verizon"
--   cox.net            against Cox Communications      shares "cox"
--   frontiernet.net    against Frontier                shares "frontier"
--   freeweld.com       against AT&T Enterprises, LLC   shares nothing
--   dailyjournal.com   against AT&T Enterprises, LLC   shares nothing
--
-- This is a test on the domain's own second-level label against the names
-- the measured sources report, and it needs no judgement from me about what
-- any company does.
--
-- TWO TESTS, BECAUSE ONE OF THEM FAILS ON AT&T
--
-- I first wrote this as a word test with a four-character floor, so that
-- "llc", "inc" and "net" could not match on their own. Checking the code
-- against the data before issuing it, that floor breaks the case the whole
-- diagnosis rests on: "AT&T Enterprises, LLC" splits into AT, T,
-- Enterprises, LLC, the floor throws away AT and T, and "att" matches
-- nothing. att.com would have been reported as a customer domain to strip.
-- An earlier draft of this comment asserted att.com shared a token. It does
-- not. I had not run it.
--
-- So both tests are recorded, separately, and either one passing counts:
--
--   token_match       a word of 4+ characters in the reported name sits
--                     inside the domain label, or the label inside it.
--                     frontiernet.net against Frontier matches this way;
--                     the compressed test alone would not catch it.
--   compressed_match  the domain label, 3+ characters, appears in the
--                     reported name with all punctuation removed.
--                     att.com against "attenterprisesllc" matches this way;
--                     the token test alone would not catch it.
--
-- WHAT THE TESTS GET WRONG, measured on a fixture before issuing this
--
-- Run against a fixture carrying att.com, freeweld.com, tunahelper.net and
-- a planted three-letter domain, with bdc_name_given corrected to the rule
-- resolve_asn.sql actually enforces:
--
--   att.com         token f, compressed t   carrier, rescued as intended
--   freeweld.com    token f, compressed f   customer, correctly rejected
--   tunahelper.net  token f, compressed f   correctly rejected
--   ent.net         token t, compressed t   FALSE POSITIVE, and it is the
--                                           TOKEN test that fires: "ent"
--                                           sits inside "enterprises".
--   he.net          token f, compressed f   FALSE NEGATIVE: a real carrier
--                                           whose label is two characters,
--                                           below the compressed floor.
--   twelve99-cust.net  f, f                 FALSE NEGATIVE: Arelion Sweden
--                                           AB shares nothing with the
--                                           domain a customer dials.
--
-- tunahelper.net is worth a correction. I previously reported it as the
-- test's known miss. That was an artefact of my own fixture, which gave it
-- bdc_name_given = 'Tuna' on a row with by_decision false. resolve_asn.sql
-- cannot produce that state, and with the fixture corrected the test
-- rejects tunahelper.net on the measured names alone.
--
-- So the loose direction of the token test, a short label inside a longer
-- word, is the weaker of the two, and the name test misses carriers whose
-- domain is unlike their registrant. Both columns are kept so which test
-- fired is visible rather than inferred.
--
-- A RULING OUTRANKS BOTH TESTS
--
-- alter.net is Verizon because Boris said so, and "alter" resembles
-- "Verizon" in no way, so the name test rejects it. any_by_decision is
-- therefore reported as a separate axis and decided domains are listed
-- apart from the candidates: no test here may overrule a ruling.
--
-- IT IS NOT APPLIED AS A FILTER HERE. It is recorded as columns, with the
-- footprint ratio and the label_basis beside them, so Boris can review the
-- whole population rather than a sample and rule on it. att.com is the case
-- that shows why a filter would be premature: it IS AT&T's own domain and it
-- still carries 155,648 triples on one site.

BEGIN;

DROP TABLE IF EXISTS domain_classification_tbl;

CREATE TABLE domain_classification_tbl AS
WITH site AS (
    SELECT carrier_domain AS itdk_domain,
           count(*)       AS sites,
           sum(node_addresses) AS node_addresses,
           count(DISTINCT city) AS cities
    FROM serving_site_tbl GROUP BY 1
), foot AS (
    SELECT itdk_domain,
           count(*)                    AS triples,
           count(DISTINCT tract_geoid) AS tracts,
           count(DISTINCT technology)  AS technologies,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY nearest_km) AS median_km
    FROM step4_tract_site_tbl GROUP BY 1
), res AS (
    SELECT itdk_domain,
           bool_or(by_decision)                              AS any_by_decision,
           string_agg(DISTINCT label_basis, '; ')             AS label_bases,
           count(DISTINCT bdc_provider_id)                   AS bdc_providers,
           max(bdc_name_given)                               AS bdc_name_given
    FROM carrier_resolved_tbl
    WHERE bdc_provider_id IS NOT NULL
    GROUP BY 1
), obs AS (
    SELECT itdk_domain,
           max(ipapi_isp) AS ipapi_isp,
           max(ipapi_org) AS ipapi_org,
           max(rdap_name) AS rdap_name
    FROM carrier_crosswalk_tbl GROUP BY 1
), base AS (
    SELECT s.itdk_domain,
           s.sites, s.node_addresses, s.cities,
           coalesce(f.triples, 0)      AS triples,
           coalesce(f.tracts, 0)       AS tracts,
           f.technologies,
           round(f.median_km::numeric, 1) AS median_km,
           coalesce(f.triples, 0)::numeric / greatest(s.sites, 1)
                                        AS triples_per_site,
           r.any_by_decision, r.label_bases, r.bdc_providers,
           r.bdc_name_given,
           o.ipapi_isp, o.ipapi_org, o.rdap_name,
           -- EVERY NAME ANY MEASURED SOURCE REPORTS for this domain, in one
           -- string, so the two tests below read the same input.
           --
           -- bdc_name_given is included and that is NOT circular. Checked in
           -- resolve_asn.sql rather than assumed: the column is populated
           -- from the decided CTE only, and by_decision is exactly
           -- "the decided CTE matched", so bdc_name_given is non-null only
           -- where Boris named the carrier or named an ASN whose operator
           -- the BDC knows. No machine proposal ever writes it, so it
           -- cannot feed a name derived from the domain back into a test on
           -- the domain.
           lower(coalesce(o.ipapi_isp, '') || ' ' ||
                 coalesce(o.ipapi_org, '') || ' ' ||
                 coalesce(o.rdap_name, '') || ' ' ||
                 coalesce(r.bdc_name_given, ''))  AS reported_names,
           -- THE DOMAIN'S OWN LABEL, lowercased, punctuation stripped.
           -- second-level label of the domain: the part before the final
           -- dot, with any earlier labels discarded.
           regexp_replace(
             lower(split_part(s.itdk_domain, '.',
                   greatest(array_length(string_to_array(s.itdk_domain, '.'), 1) - 1, 1))),
             '[^a-z0-9]', '', 'g')      AS domain_label
    FROM site s
    LEFT JOIN foot f ON f.itdk_domain = s.itdk_domain
    LEFT JOIN res  r ON r.itdk_domain = s.itdk_domain
    LEFT JOIN obs  o ON o.itdk_domain = s.itdk_domain
)
, tested AS (
SELECT b.*,
       -- TEST ONE. A whole word of the reported name, four characters or
       -- more so that "llc", "inc" and "net" cannot match on their own,
       -- overlapping the domain label in either direction.
       (b.domain_label <> '' AND EXISTS (
         SELECT 1
         FROM regexp_split_to_table(
                regexp_replace(b.reported_names,
                               '[^a-z0-9 ]', ' ', 'g'), ' +') AS tok
         WHERE length(tok) >= 4
           AND (b.domain_label LIKE '%' || tok || '%'
             OR tok LIKE '%' || b.domain_label || '%')
       ))                                   AS token_match,
       -- TEST TWO. The domain label inside the reported name with all
       -- punctuation and spacing removed, which is what recovers att.com
       -- against "AT&T Enterprises, LLC". Three characters or more; shorter
       -- than that would match almost anything.
       (length(b.domain_label) >= 3
        AND regexp_replace(b.reported_names, '[^a-z0-9]', '', 'g')
            LIKE '%' || b.domain_label || '%')
                                            AS compressed_match
FROM base b
)
SELECT t.*, (t.token_match OR t.compressed_match) AS name_matches_domain
FROM tested t;

ALTER TABLE domain_classification_tbl ADD PRIMARY KEY (itdk_domain);
CREATE INDEX domain_class_ratio_idx
    ON domain_classification_tbl (triples_per_site);

COMMENT ON TABLE domain_classification_tbl IS
'Every ITDK domain that has a serving site, classified over the WHOLE population rather than a sample. Carries the footprint, the site count, their ratio, the median step 4 distance, the label_basis that produced the BDC link, whether any link rests on a Boris decision, and the names ip-api, RDAP and the BDC report. name_matches_domain is the discriminator: ip-api and RDAP report the UPSTREAM carrier for a customer prefix, so a customer domain carries its carrier name while resembling it in no way. It is the OR of two tests, both kept as columns. token_match: a word of four or more characters shared in either direction, which catches frontiernet.net against Frontier. compressed_match: the domain label of three or more characters inside the reported name with all punctuation removed, which catches att.com against AT&T Enterprises LLC, where every word of the brand is shorter than the token floor. Measured false positives and negatives are in the header comment: the loose direction of the token test matched a three-letter label inside "enterprises", and the name test rejects he.net and twelve99-cust.net, which are carriers. A ruling outranks both tests, so any_by_decision is a separate axis and decided domains are listed apart from the candidates. Nothing is filtered here; this is for review.';

COMMIT;

\echo
\echo ================================================================
\echo EVERY DOMAIN, CLASSIFIED. Counts first, so nothing hides.
\echo ================================================================
\echo
SELECT count(*)                                              AS domains,
       sum(triples)                                          AS triples,
       count(*) FILTER (WHERE any_by_decision)               AS by_boris_decision,
       count(*) FILTER (WHERE name_matches_domain)           AS name_matches,
       count(*) FILTER (WHERE NOT name_matches_domain)       AS name_does_not_match,
       count(*) FILTER (WHERE triples_per_site >= 10000)     AS ratio_over_10000
FROM domain_classification_tbl;

\echo
\echo WHICH OF THE TWO NAME TESTS FIRED. The compressed-only row is what the
\echo four-character token floor was discarding; att.com sits in it. The
\echo token-only row is what the compressed test alone would discard.
\echo
SELECT CASE WHEN token_match AND compressed_match THEN 'a. both tests'
            WHEN token_match                      THEN 'b. token only'
            WHEN compressed_match                 THEN 'c. compressed only'
            ELSE                                       'd. neither' END
                                     AS which_test,
       count(*)                      AS domains,
       sum(triples)                  AS triples,
       count(*) FILTER (WHERE triples_per_site >= 1000) AS ratio_1000_plus
FROM domain_classification_tbl
GROUP BY 1 ORDER BY 1;

\echo
\echo ALL domains the compressed test rescued from the token floor, in full.
\echo Each would otherwise have been reported as a customer to strip.
\echo
SELECT count(*) AS rescued_by_the_compressed_test
FROM domain_classification_tbl
WHERE compressed_match AND NOT token_match;

SELECT itdk_domain, domain_label, triples, sites, median_km,
       left(coalesce(ipapi_isp, rdap_name, bdc_name_given, ''), 34)
                                     AS reported_as
FROM domain_classification_tbl
WHERE compressed_match AND NOT token_match
ORDER BY triples DESC;

\echo
\echo The two tests crossed. The cell that matters is a domain whose name
\echo shares nothing with its reported carrier AND which carries an
\echo implausible footprint: that is a customer inheriting a carrier.
\echo
SELECT CASE WHEN name_matches_domain THEN 'name matches'
            ELSE 'name does NOT match' END                  AS name_test,
       CASE WHEN triples_per_site >= 10000 THEN 'c. ratio 10,000+'
            WHEN triples_per_site >= 1000  THEN 'b. ratio 1,000 to 10,000'
            ELSE                                'a. ratio under 1,000' END
                                                            AS footprint_test,
       count(*)      AS domains,
       sum(triples)  AS triples,
       round(100.0 * sum(triples) / sum(sum(triples)) OVER (), 1) AS pct_of_step4,
       round(avg(median_km)::numeric, 0) AS mean_of_median_km,
       count(*) FILTER (WHERE any_by_decision) AS of_which_you_ruled
FROM domain_classification_tbl
GROUP BY 1, 2 ORDER BY 1, 2;

\echo
\echo EVERY DOMAIN BORIS HAS RULED ON, with what the tests say about it.
\echo A ruling outranks both tests. alter.net is the case: it is Verizon
\echo because Boris said so, and the name resembles Verizon in no way, so
\echo the tests reject it and the tests are what is wrong. These domains
\echo are excluded from the candidate list below.
\echo
SELECT count(*) AS domains_resting_on_a_ruling
FROM domain_classification_tbl WHERE any_by_decision;

SELECT itdk_domain, triples, sites, median_km,
       token_match, compressed_match, name_matches_domain,
       left(coalesce(bdc_name_given, ipapi_isp, ''), 26) AS name_given,
       left(coalesce(label_bases, ''), 34)               AS label_basis
FROM domain_classification_tbl
WHERE any_by_decision
ORDER BY triples DESC;

\echo
\echo CANDIDATES TO STRIP: name does not match, ratio 1,000 or more, and
\echo NO ruling of yours behind them. This is the full list, not a sample.
\echo Its length is printed first so a truncated view cannot mislead.
\echo
SELECT count(*) AS domains_in_the_full_list_below
FROM domain_classification_tbl
WHERE NOT name_matches_domain AND triples_per_site >= 1000
  AND any_by_decision IS NOT TRUE;

SELECT itdk_domain, domain_label, triples, sites, median_km,
       left(coalesce(ipapi_isp, rdap_name, ''), 28) AS reported_as,
       left(coalesce(label_bases, ''), 30)          AS label_basis
FROM domain_classification_tbl
WHERE NOT name_matches_domain AND triples_per_site >= 1000
  AND any_by_decision IS NOT TRUE
ORDER BY triples DESC;

\echo
\echo THE OTHER SIDE OF THE SAME LIST: name does not match but the
\echo footprint is PLAUSIBLE, under 1,000 triples per site, and no ruling
\echo behind it. he.net and twelve99-cust.net belong here, and both are
\echo carriers, so this list is where the name test loses carriers rather
\echo than customers. Full list, count first.
\echo
SELECT count(*) AS domains_in_the_full_list_below
FROM domain_classification_tbl
WHERE NOT name_matches_domain AND triples_per_site < 1000
  AND any_by_decision IS NOT TRUE;

SELECT itdk_domain, domain_label, triples, sites, cities, median_km,
       left(coalesce(ipapi_isp, rdap_name, ''), 28) AS reported_as
FROM domain_classification_tbl
WHERE NOT name_matches_domain AND triples_per_site < 1000
  AND any_by_decision IS NOT TRUE
ORDER BY triples DESC;

\echo
\echo DOMAINS WITH A MATCHING NAME AND A PLAUSIBLE FOOTPRINT, in full.
\echo These should all be carriers. Of an earlier list of twenty-five Boris
\echo confirmed they all were except tunahelper.net, and that list was cut
\echo at twenty-five, which is the defect this query exists to remove. Check
\echo that judgement against the whole population here. tst names which of
\echo the two tests fired, so a compressed-only match on a short label can
\echo be told apart from a whole-word match.
\echo
SELECT count(*) AS domains_name_matching_and_plausible
FROM domain_classification_tbl
WHERE name_matches_domain AND triples_per_site < 1000;

SELECT itdk_domain, triples, sites, cities, median_km,
       left(coalesce(ipapi_isp, rdap_name, ''), 26) AS reported_as,
       CASE WHEN token_match AND compressed_match THEN 'both'
            WHEN token_match                      THEN 'token'
            ELSE                                       'compressed' END
                                                    AS tst,
       any_by_decision
FROM domain_classification_tbl
WHERE name_matches_domain AND triples_per_site < 1000
ORDER BY triples DESC;

\echo
\echo THE AWKWARD CELL: name matches but the footprint is implausible.
\echo These are the carrier own domain with too few known sites for the
\echo footprint it is credited with, which is a DIFFERENT problem from a
\echo customer inheriting a carrier and must not be treated the same way.
\echo
SELECT itdk_domain, triples, sites, median_km,
       left(coalesce(ipapi_isp, rdap_name, ''), 28) AS reported_as,
       CASE WHEN token_match AND compressed_match THEN 'both'
            WHEN token_match                      THEN 'token'
            ELSE                                       'compressed' END
                                                    AS tst
FROM domain_classification_tbl
WHERE name_matches_domain AND triples_per_site >= 1000
ORDER BY triples DESC;

\echo
\echo THE TWO NAMED CASES, side by side, printed rather than asserted.
\echo att.com: an earlier draft of this file claimed it shared a whole word
\echo with AT and T. It does not, because every word of that brand is
\echo shorter than the four-character floor. The row below says which test
\echo caught it, or whether neither did.
\echo tunahelper.net: Boris identified it as not a carrier. On a fixture it
\echo appeared to pass, which turned out to be my fixture setting a given
\echo name that resolve_asn.sql cannot produce. The row below reports what
\echo the real data does rather than what I expect.
\echo
SELECT itdk_domain, domain_label, triples, sites, cities, median_km,
       token_match, compressed_match, name_matches_domain,
       ipapi_isp, ipapi_org, rdap_name, bdc_name_given, label_bases
FROM domain_classification_tbl
WHERE itdk_domain IN ('att.com', 'tunahelper.net')
ORDER BY itdk_domain;
