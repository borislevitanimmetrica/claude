-- carrier_match_v2.sql - candidate matching at brand and TECHNOLOGY grain,
-- with three competing scores all measured against the truth set in the
-- same run, so the comparison is evidence rather than my preference.
--
-- WHAT THE BRAND RE-GRAIN SETTLED, 2026-11-20
--
-- Boris: "T-Mobile owns 50% of Lumos." That resolves provider 130403, and
-- not in the direction I was heading. It is not a corrupt id: it is a
-- parent filing alongside a joint venture, which is exactly what the FCC
-- scheme is for. Measured shares under that one id:
--
--      T-Mobile   84,569 pairs   84,474 tracts   98.6 pct of the provider
--      lumos         864            783           1.0
--      Lumos         368            315           0.4
--
-- So nothing is mislabelled. The difficulty is only that two footprints
-- two orders of magnitude apart share one label, and a domain belonging to
-- Lumos would inherit T-Mobile's national footprint. Brand grain fixes
-- that without anyone needing to know the corporate history.
--
-- Same for the other two I flagged. Quantum Fiber is 5,497 pairs, 3.5 pct
-- of AT&T's provider id, on one technology; I still do not know why Lumen's
-- brand sits on an AT&T FRN and I am not inventing a reason, because at
-- brand grain it separates cleanly and the question stops mattering. Zayo
-- at 73.1 pct beside Allstream at 37.3 pct under 130982 is one company
-- having owned the other.
--
-- Total cost of the re-grain: 794,708 rows against 785,168, so 1.2 pct
-- more. The brands of a provider barely overlap.
--
-- WHAT IT DID NOT FIX, AND THIS IS THE IMPORTANT PART
--
-- Three brands still cover more than 80 pct of all census tracts:
-- AT&T 97.4, Verizon 97.0, T-Mobile 98.9. So containment in a brand
-- footprint is just as uninformative as containment in a provider
-- footprint, and my explanation of the ranking failure survives on clean
-- numbers.
--
-- But those three are national because of FIXED WIRELESS, and the table
-- now carries the technology to prove or refute it. From the earlier
-- audit, the national tract-technology split:
--
--      71 Licensed Fixed Wireless    282,768 pairs
--      50 Fiber to the Premises      221,739
--      40 Cable                       99,151
--      10 Copper                      87,949
--      70 Unlicensed Fixed Wireless   71,322
--      72 LBR Fixed Wireless          22,011
--       0 Other                          228
--
-- Fixed wireless is 376,101 of 785,168, which is 47.9 pct. AND IT HAS NO
-- HEADEND. Boris wrote this into the plan on 2026-11-17 and I had not
-- carried it through: licensed fixed wireless is served from cell sites,
-- not from headends or central offices. Steps 4 to 6 measure the distance
-- to a headend or CO, so for roughly half the footprint the thing being
-- measured does not exist.
--
-- Section 1 tests that directly: tract coverage per brand PER TECHNOLOGY.
-- If AT&T is national on 71 and regional on 10 and 50, then the wireline
-- technologies are separable by geography and the matching has a real
-- signal for the half of the plan that headends apply to.
--
-- THE THREE SCORES COMPARED, and none is adopted here
--
--   containment  sites of the domain inside the footprint, as a share of
--                its sites. This is the measure that scored 7.3 pct.
--   lift         containment divided by the footprint's share of all
--                tracts, so a national brand stops winning by size alone.
--   blanket      the share of the BRAND's tracts that lie within 25 km of
--                one of the domain's sites. This is the reverse direction:
--                an owner's sites should cover its own footprint, and three
--                sites cannot cover three thousand tracts.
--
-- All three are scored against carrier_truth_set.tsv in section 4, by
-- basis, with the previous 7.3 pct beside them. I am not proposing a
-- winner; the output picks it.
--
-- PRE-MORTEM. Creates near_tract_tbl and carrier_match_v2_tbl, both NEW,
-- dropped first so the file re-runs. Reads site_tract_tbl,
-- provider_brand_tract_tech_tbl, census_tract_tbl and carrier_truth_tbl,
-- all of which must already exist; the precheck below names the one that
-- is missing rather than failing mid-file. Nothing existing is modified,
-- and carrier_resolved_tbl and step4 are untouched.

\timing on
\set ON_ERROR_STOP on

\echo
\echo Prerequisites, named individually so a missing one is obvious.
\echo
SELECT t.relname AS required_table,
       CASE WHEN c.oid IS NULL THEN 'MISSING - run the file that builds it'
            ELSE 'present' END AS state
FROM (VALUES ('site_tract_tbl'),
             ('provider_brand_tract_tech_tbl'),
             ('census_tract_tbl'),
             ('carrier_truth_tbl'),
             ('serving_site_tbl')) AS t(relname)
LEFT JOIN pg_class c ON c.relname = t.relname AND c.relkind = 'r'
ORDER BY 2, 1;

SET work_mem = '512MB';

\echo
\echo ================================================================
\echo SECTION 1. Tract coverage per brand PER TECHNOLOGY, for the brands
\echo with ten thousand pairs or more. The question is whether the three
\echo national brands are national on fixed wireless and regional on the
\echo wireline technologies that actually have headends.
\echo ================================================================
\echo
WITH big AS (
    SELECT brand_name FROM provider_brand_tract_tech_tbl
    GROUP BY 1 HAVING count(*) >= 10000
), tot AS (SELECT count(*) AS all_tracts FROM census_tract_tbl)
SELECT f.brand_name,
       f.technology,
       left(coalesce(t.code_desc, ''), 24)                  AS technology_name,
       count(DISTINCT f.tract_geoid)                        AS tracts,
       round(100.0 * count(DISTINCT f.tract_geoid)
             / (SELECT all_tracts FROM tot), 1)             AS pct_of_all_tracts
FROM provider_brand_tract_tech_tbl f
JOIN big b ON b.brand_name = f.brand_name
LEFT JOIN bdc_technology_tbl t ON t.technology = f.technology
GROUP BY 1, 2, 3
ORDER BY 1, 2;

\echo
\echo The same question as one number per technology: how many brands are
\echo national on it. A technology on which nothing is national is a
\echo technology geography can resolve.
\echo
WITH f AS (
    SELECT brand_name, technology, count(DISTINCT tract_geoid) AS tracts
    FROM provider_brand_tract_tech_tbl GROUP BY 1, 2
), tot AS (SELECT count(*) AS all_tracts FROM census_tract_tbl)
SELECT f.technology,
       left(coalesce(t.code_desc, ''), 24)                   AS technology_name,
       count(*)                                              AS brands,
       count(*) FILTER (WHERE 100.0 * f.tracts
                              / (SELECT all_tracts FROM tot) >= 80)
                                                            AS brands_over_80_pct,
       count(*) FILTER (WHERE 100.0 * f.tracts
                              / (SELECT all_tracts FROM tot) >= 40)
                                                            AS brands_over_40_pct,
       max(f.tracts)                                         AS largest_brand_tracts
FROM f
LEFT JOIN bdc_technology_tbl t ON t.technology = f.technology
GROUP BY 1, 2
ORDER BY 1;

\echo
\echo ================================================================
\echo SECTION 2. Tracts within 25 km of each serving site, which the
\echo blanket score needs. One pass with the centroid index; a minute or
\echo two. The count is the completion signal.
\echo ================================================================
\echo
DROP TABLE IF EXISTS near_tract_tbl;
CREATE TABLE near_tract_tbl AS
SELECT st.site_key,
       st.carrier_domain,
       c.tract_geoid
FROM site_tract_tbl st
JOIN census_tract_tbl c
  ON c.lat BETWEEN st.lat - 0.26 AND st.lat + 0.26
 -- THE LONGITUDE BOUND MUST SCALE WITH LATITUDE. A degree of longitude is
 -- 111.32 km at the equator and 47 km at 65 degrees north, so a fixed
 -- plus or minus 0.34 is 25 km in the lower 48 and only 19 km in Alaska,
 -- which would silently drop tracts there and understate the blanket score
 -- for exactly the carriers whose coverage is hardest to establish. The
 -- greatest() floor keeps it finite at the poles, where no US tract sits.
 AND c.lon BETWEEN st.lon - 0.26 / greatest(cos(radians(st.lat)), 0.05)
                AND st.lon + 0.26 / greatest(cos(radians(st.lat)), 0.05)
WHERE st.tract_geoid IS NOT NULL
  AND 2 * 6371.0088 * asin(sqrt(
        sin(radians(c.lat - st.lat) / 2) ^ 2
      + cos(radians(st.lat)) * cos(radians(c.lat))
      * sin(radians(c.lon - st.lon) / 2) ^ 2)) <= 25;

CREATE INDEX near_tract_domain_ix ON near_tract_tbl (carrier_domain);
CREATE INDEX near_tract_tract_ix  ON near_tract_tbl (tract_geoid);
ANALYZE near_tract_tbl;

COMMENT ON TABLE near_tract_tbl IS
'Census tracts whose centroid is within 25 km of a serving site, per site and carrier domain. The blanket score uses it to ask the reverse of containment: what share of a brand footprint lies near one of the domain sites. 25 km is a parameter, chosen because step 4 medians for undisputed pairings such as cox.net at 9.0 km and zayo.com at 12.2 km sit well inside it.';

SELECT count(*)                           AS site_tract_pairs,
       count(DISTINCT carrier_domain)      AS domains,
       count(DISTINCT tract_geoid)         AS tracts,
       round(count(*)::numeric
             / nullif(count(DISTINCT site_key), 0), 1) AS mean_tracts_per_site
FROM near_tract_tbl;

\echo
\echo ================================================================
\echo SECTION 3. Candidates at brand and technology grain, restricted to
\echo the WIRELINE technologies, with all three scores side by side.
\echo Copper, Cable and Fiber to the Premises are the ones served from a
\echo headend or central office.
\echo ================================================================
\echo
DROP TABLE IF EXISTS carrier_match_v2_tbl;
CREATE TABLE carrier_match_v2_tbl AS
WITH dom AS (
    SELECT carrier_domain,
           count(*)                   AS sites,
           count(DISTINCT city)       AS cities,
           sum(node_addresses)        AS node_addresses
    FROM serving_site_tbl GROUP BY 1
), placed AS (
    SELECT carrier_domain, count(*) AS sites_placed
    FROM site_tract_tbl WHERE tract_geoid IS NOT NULL GROUP BY 1
), bt AS (
    SELECT provider_id, brand_name, technology,
           count(*)                    AS brand_pairs,
           count(DISTINCT tract_geoid) AS brand_tracts
    FROM provider_brand_tract_tech_tbl
    WHERE technology IN (10, 40, 50)
    GROUP BY 1, 2, 3
), contain AS (
    SELECT st.carrier_domain, f.provider_id, f.brand_name, f.technology,
           count(DISTINCT st.site_key) AS sites_in_footprint
    FROM site_tract_tbl st
    JOIN provider_brand_tract_tech_tbl f ON f.tract_geoid = st.tract_geoid
    WHERE st.tract_geoid IS NOT NULL
      AND f.technology IN (10, 40, 50)
    GROUP BY 1, 2, 3, 4
), blanket AS (
    SELECT n.carrier_domain, f.provider_id, f.brand_name, f.technology,
           count(DISTINCT f.tract_geoid) AS brand_tracts_near_a_site
    FROM near_tract_tbl n
    JOIN provider_brand_tract_tech_tbl f ON f.tract_geoid = n.tract_geoid
    WHERE f.technology IN (10, 40, 50)
    GROUP BY 1, 2, 3, 4
), tot AS (SELECT count(*) AS all_tracts FROM census_tract_tbl)
SELECT c.carrier_domain,
       c.provider_id, c.brand_name, c.technology,
       d.sites, d.cities, d.node_addresses, p.sites_placed,
       bt.brand_pairs, bt.brand_tracts,
       c.sites_in_footprint,
       round(100.0 * c.sites_in_footprint
             / greatest(p.sites_placed, 1), 2)                AS score_containment,
       round((100.0 * c.sites_in_footprint / greatest(p.sites_placed, 1))
             / nullif(100.0 * bt.brand_tracts
                      / (SELECT all_tracts FROM tot), 0), 2)  AS score_lift,
       coalesce(b.brand_tracts_near_a_site, 0)                AS brand_tracts_near,
       round(100.0 * coalesce(b.brand_tracts_near_a_site, 0)
             / greatest(bt.brand_tracts, 1), 2)               AS score_blanket
FROM contain c
JOIN dom    d  ON d.carrier_domain = c.carrier_domain
JOIN placed p  ON p.carrier_domain = c.carrier_domain
JOIN bt        ON bt.provider_id = c.provider_id
               AND bt.brand_name = c.brand_name
               AND bt.technology = c.technology
LEFT JOIN blanket b ON b.carrier_domain = c.carrier_domain
                    AND b.provider_id = c.provider_id
                    AND b.brand_name = c.brand_name
                    AND b.technology = c.technology;

ALTER TABLE carrier_match_v2_tbl
    ADD PRIMARY KEY (carrier_domain, provider_id, brand_name, technology);
CREATE INDEX carrier_match_v2_dom_ix ON carrier_match_v2_tbl (carrier_domain);
CREATE INDEX carrier_match_v2_prov_ix ON carrier_match_v2_tbl (provider_id);
ANALYZE carrier_match_v2_tbl;

COMMENT ON TABLE carrier_match_v2_tbl IS
'Candidate pairings at (ITDK domain, provider_id, brand_name, technology) over the wireline technologies only, carrying three competing scores: containment, which is the measure that scored 7.3 percent precision at 1; lift, which divides containment by the footprint share of the country so size alone stops winning; and blanket, the share of the brand footprint lying within 25 km of a site of the domain, which is the reverse direction and asks whether an owner covers its own territory. No score is adopted; carrier_match_qa.sql ranks them.';

SELECT count(*)                                  AS candidate_rows,
       count(DISTINCT carrier_domain)            AS domains,
       count(DISTINCT provider_id)               AS providers,
       count(DISTINCT brand_name)                AS brands
FROM carrier_match_v2_tbl;

\echo
\echo ================================================================
\echo SECTION 4. THE SCORE OF ALL THREE, against the truth set. The
\echo previous measure scored 7.3 pct in the domain direction, so that is
\echo the number to beat. Aggregated to the provider so it is comparable.
\echo ================================================================
\echo
WITH best AS (
    SELECT carrier_domain, provider_id,
           max(score_containment) AS s_contain,
           max(score_lift)        AS s_lift,
           max(score_blanket)     AS s_blanket
    FROM carrier_match_v2_tbl
    GROUP BY 1, 2
), r AS (
    SELECT carrier_domain, provider_id,
           row_number() OVER (PARTITION BY carrier_domain
                              ORDER BY s_contain DESC) AS rank_contain,
           row_number() OVER (PARTITION BY carrier_domain
                              ORDER BY s_lift DESC)    AS rank_lift,
           row_number() OVER (PARTITION BY carrier_domain
                              ORDER BY s_blanket DESC) AS rank_blanket,
           count(*)    OVER (PARTITION BY carrier_domain) AS candidates
    FROM best
)
SELECT t.basis,
       count(*)                                                AS truth_pairings,
       count(*) FILTER (WHERE r.carrier_domain IS NULL)        AS not_proposed,
       count(*) FILTER (WHERE r.rank_contain = 1)              AS containment_first,
       count(*) FILTER (WHERE r.rank_lift = 1)                 AS lift_first,
       count(*) FILTER (WHERE r.rank_blanket = 1)              AS blanket_first,
       round(100.0 * count(*) FILTER (WHERE r.rank_contain = 1) / count(*), 1) AS pct_containment,
       round(100.0 * count(*) FILTER (WHERE r.rank_lift = 1) / count(*), 1)    AS pct_lift,
       round(100.0 * count(*) FILTER (WHERE r.rank_blanket = 1) / count(*), 1) AS pct_blanket
FROM carrier_truth_tbl t
LEFT JOIN r ON r.carrier_domain = t.itdk_domain
            AND r.provider_id = t.provider_id
GROUP BY 1
UNION ALL
SELECT 'ALL BASES',
       count(*),
       count(*) FILTER (WHERE r.carrier_domain IS NULL),
       count(*) FILTER (WHERE r.rank_contain = 1),
       count(*) FILTER (WHERE r.rank_lift = 1),
       count(*) FILTER (WHERE r.rank_blanket = 1),
       round(100.0 * count(*) FILTER (WHERE r.rank_contain = 1) / count(*), 1),
       round(100.0 * count(*) FILTER (WHERE r.rank_lift = 1) / count(*), 1),
       round(100.0 * count(*) FILTER (WHERE r.rank_blanket = 1) / count(*), 1)
FROM carrier_truth_tbl t
LEFT JOIN r ON r.carrier_domain = t.itdk_domain
            AND r.provider_id = t.provider_id
ORDER BY 1;

\echo
\echo Every truth pairing with its rank under each score, so a measure
\echo that wins on average but fails on the large carriers is visible.
\echo
WITH best AS (
    SELECT carrier_domain, provider_id,
           max(score_containment) AS s_contain,
           max(score_lift)        AS s_lift,
           max(score_blanket)     AS s_blanket
    FROM carrier_match_v2_tbl
    GROUP BY 1, 2
), r AS (
    SELECT carrier_domain, provider_id,
           row_number() OVER (PARTITION BY carrier_domain ORDER BY s_contain DESC) AS rank_contain,
           row_number() OVER (PARTITION BY carrier_domain ORDER BY s_lift DESC)    AS rank_lift,
           row_number() OVER (PARTITION BY carrier_domain ORDER BY s_blanket DESC) AS rank_blanket,
           count(*)    OVER (PARTITION BY carrier_domain) AS candidates
    FROM best
)
SELECT t.itdk_domain, t.provider_id, t.basis,
       r.candidates, r.rank_contain, r.rank_lift, r.rank_blanket
FROM carrier_truth_tbl t
LEFT JOIN r ON r.carrier_domain = t.itdk_domain
            AND r.provider_id = t.provider_id
ORDER BY t.basis, r.rank_blanket NULLS LAST, t.itdk_domain;

RESET work_mem;
\timing off
