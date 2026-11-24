-- carrier_match_approval.sql - the complete matching table, for approval.
--
-- WHAT BORIS ASKED FOR, 2026-11-19
--
-- "I want approval of all matching tables. There are numerous small carriers
-- in the USA, some serving only a small rural town. Also, carriers commonly
-- acquire other carriers; the name of the FCC BDC filer may change to the
-- acquirer but not immediately, and the domain name often remains that of
-- the acquired company for years or indefinitely. The networks of Alternet
-- and Metronet retain their domain names decades after these carriers were
-- integrated into Verizon after it acquired them."
--
-- That is a specification, and it rules out the method in use. Three things
-- follow from it, each of which the old rule violates:
--
--   1. A domain may legitimately resemble its provider's name in no way.
--      alter.net is Verizon. No string test can find that.
--   2. The provider name may lag the acquisition, so even a CORRECT name
--      comparison can be comparing against a name that is out of date.
--   3. Small carriers are numerous, so the candidate list cannot be
--      restricted to large providers either.
--
-- THE RULE BEING REPLACED, read rather than recalled. carrier_crosswalk.sql
-- line 845:
--
--      WHEN b.brand_norm LIKE '%' || m.isp_norm || '%'
--        OR m.isp_norm LIKE '%' || b.brand_norm || '%'
--           THEN 'normalised name contained'
--
-- Substring containment in either direction between normalised names. That
-- is how a reported 'Comcast Cable Communications' reached a brand ending in
-- 'COMMUNICATIONS' belonging to a provider with 19 tract-technology pairs,
-- while Xfinity, 57,577 pairs over 36,151 tracts, was left with no domain
-- at all and Comcast therefore cannot be placed.
--
-- WHAT GENERATES THE CANDIDATES HERE
--
-- Geography. A carrier with a headend or central office in a census tract
-- files service in that tract. So for each ITDK domain, the candidates are
-- the providers that actually file service in the tracts where that domain's
-- own sites sit. This rests on where the equipment is, which no acquisition
-- or legacy domain name can falsify.
--
-- The evidence per candidate pairing, all of it measured:
--
--   sites_in_footprint    how many of the domain's sites sit in a tract this
--                         provider serves. A real owner should cover most.
--   pct_sites            that as a share of the domain's located sites.
--   provider_pairs       the provider's own tract-technology total, so a
--                        one-site domain against a national footprint is
--                        visible as the absurdity it is.
--   pairs_per_site       provider_pairs divided by the domain's sites.
--   states_in_common     site states against provider states.
--   name_link            whether the OLD name rule proposed this pairing,
--                        kept as a column so the two methods can be
--                        compared rather than one silently replacing the
--                        other.
--   by_decision          whether this pairing already rests on your ruling.
--
-- NOTHING IS FILTERED AND NOTHING IS APPLIED. This builds a table and
-- writes three TSVs. carrier_resolved_tbl is not touched, so step 4's input
-- is unchanged until you rule.
--
-- PRE-MORTEM, because this creates and drops. It drops and recreates
-- carrier_match_tbl and site_tract_tbl, both NEW in this file, and creates
-- one index on census_tract_tbl (lat, lon), which is additive. No existing
-- table is read-modified and no existing table is dropped. If this file is
-- interrupted the only loss is the two new tables, rebuilt by re-running it.

\timing on

\echo
\echo Indexing tract centroids for the nearest-tract lookup. Additive.
\echo
CREATE INDEX IF NOT EXISTS census_tract_latlon_ix
    ON census_tract_tbl (lat, lon);

\echo
\echo STEP 1 of 4. Placing every serving site in a census tract, by nearest
\echo centroid within roughly 80 km. A site outside the United States gets
\echo no tract and is reported separately rather than dropped.
\echo
DROP TABLE IF EXISTS site_tract_tbl;
CREATE TABLE site_tract_tbl AS
SELECT s.site_key,
       s.carrier_domain,
       s.lat, s.lon, s.region,
       s.node_addresses,
       t.tract_geoid,
       t.state_usps,
       round(t.km::numeric, 1) AS tract_km
FROM serving_site_tbl s
LEFT JOIN LATERAL (
    SELECT c.tract_geoid, c.state_usps,
           2 * 6371.0088 * asin(sqrt(
               sin(radians(c.lat - s.lat) / 2) ^ 2
             + cos(radians(s.lat)) * cos(radians(c.lat))
             * sin(radians(c.lon - s.lon) / 2) ^ 2)) AS km
    FROM census_tract_tbl c
    WHERE c.lat BETWEEN s.lat - 0.75 AND s.lat + 0.75
      -- Scaled with latitude for the same reason as in
      -- carrier_match_v2.sql: a fixed longitude window is a smaller
      -- distance the further north it is applied, and a plus or minus 1.00
      -- degree box is 80 km in the lower 48 but only 47 km at 65 north.
      AND c.lon BETWEEN s.lon - 0.75 / greatest(cos(radians(s.lat)), 0.05)
                    AND s.lon + 0.75 / greatest(cos(radians(s.lat)), 0.05)
    ORDER BY (c.lat - s.lat) * (c.lat - s.lat)
           + (c.lon - s.lon) * (c.lon - s.lon)
    LIMIT 1
) t ON true;

CREATE INDEX site_tract_domain_ix ON site_tract_tbl (carrier_domain);
CREATE INDEX site_tract_tract_ix  ON site_tract_tbl (tract_geoid);
ANALYZE site_tract_tbl;

SELECT count(*)                                        AS sites,
       count(tract_geoid)                              AS placed_in_a_tract,
       count(*) FILTER (WHERE tract_geoid IS NULL)     AS outside_the_usa,
       count(DISTINCT carrier_domain)                  AS domains,
       round(avg(tract_km)::numeric, 1)                AS mean_km_to_centroid
FROM site_tract_tbl;

\echo
\echo STEP 2 of 4. The candidate pairings. For each domain, every provider
\echo that files service in a tract where that domain has a site.
\echo
DROP TABLE IF EXISTS carrier_match_tbl;
CREATE TABLE carrier_match_tbl AS
WITH dom AS (
    SELECT carrier_domain,
           count(*)                       AS sites,
           count(tract_geoid)             AS sites_placed,
           sum(node_addresses)            AS node_addresses,
           count(DISTINCT state_usps)     AS site_states,
           string_agg(DISTINCT state_usps, ',') AS site_state_list
    FROM site_tract_tbl GROUP BY 1
), prov AS (
    SELECT provider_id,
           count(*)                                      AS provider_pairs,
           count(DISTINCT tract_geoid)                    AS provider_tracts,
           count(DISTINCT technology)                     AS provider_techs,
           count(DISTINCT left(tract_geoid, 2))           AS provider_states
    FROM provider_tract_tech_tbl GROUP BY 1
), brands AS (
    SELECT provider_id,
           count(DISTINCT brand_name)                     AS brand_count,
           string_agg(DISTINCT brand_name, ' | ')         AS brand_names,
           string_agg(DISTINCT frn, ' ')                  AS frns
    FROM bdc_carrier_tbl GROUP BY 1
), hit AS (
    SELECT st.carrier_domain,
           p.provider_id,
           count(DISTINCT st.site_key)                    AS sites_in_footprint,
           count(DISTINCT st.state_usps)                  AS states_in_common,
           count(DISTINCT p.technology)                   AS techs_at_those_sites
    FROM site_tract_tbl st
    JOIN provider_tract_tech_tbl p ON p.tract_geoid = st.tract_geoid
    WHERE st.tract_geoid IS NOT NULL
    GROUP BY 1, 2
), named AS (
    SELECT itdk_domain, bdc_provider_id,
           bool_or(by_decision)                           AS by_decision,
           string_agg(DISTINCT label_basis, '; ')         AS label_bases
    FROM carrier_resolved_tbl
    WHERE bdc_provider_id IS NOT NULL
    GROUP BY 1, 2
)
SELECT h.carrier_domain,
       d.sites, d.sites_placed, d.node_addresses, d.site_state_list,
       h.provider_id,
       b.brand_count,
       b.brand_names,
       b.frns,
       pr.provider_pairs, pr.provider_tracts, pr.provider_techs,
       h.sites_in_footprint,
       round(100.0 * h.sites_in_footprint
             / greatest(d.sites_placed, 1), 1)            AS pct_sites,
       h.states_in_common,
       h.techs_at_those_sites,
       round(pr.provider_pairs::numeric
             / greatest(d.sites, 1), 1)                   AS pairs_per_site,
       (n.itdk_domain IS NOT NULL)                        AS name_link,
       coalesce(n.by_decision, false)                     AS by_decision,
       n.label_bases
FROM hit h
JOIN dom    d  ON d.carrier_domain = h.carrier_domain
JOIN prov   pr ON pr.provider_id   = h.provider_id
LEFT JOIN brands b ON b.provider_id = h.provider_id
LEFT JOIN named  n ON n.itdk_domain = h.carrier_domain
                  AND n.bdc_provider_id = h.provider_id;

ALTER TABLE carrier_match_tbl
    ADD PRIMARY KEY (carrier_domain, provider_id);
CREATE INDEX carrier_match_domain_ix ON carrier_match_tbl (carrier_domain);
CREATE INDEX carrier_match_prov_ix   ON carrier_match_tbl (provider_id);
ANALYZE carrier_match_tbl;

COMMENT ON TABLE carrier_match_tbl IS
'Candidate ITDK-domain to BDC-provider pairings generated by GEOGRAPHY rather than by name: for each domain, the providers that file service in the tracts where that domain has a located serving site. Boris 2026-11-19 ruled out name matching, because a domain may resemble its provider in no way (alter.net is Verizon), the BDC filer name can lag an acquisition, and small carriers are too numerous to restrict the candidate list by size. sites_in_footprint and pct_sites are the positive evidence; pairs_per_site exposes a one-site domain credited with a national footprint. name_link records whether the superseded name rule also proposed the pairing, so the two can be compared. Nothing is filtered and nothing is applied: carrier_resolved_tbl is untouched until Boris rules.';

SELECT count(*)                                           AS candidate_pairings,
       count(DISTINCT carrier_domain)                      AS domains,
       count(DISTINCT provider_id)                         AS providers,
       count(*) FILTER (WHERE name_link)                   AS also_proposed_by_name,
       count(*) FILTER (WHERE by_decision)                 AS already_ruled,
       count(*) FILTER (WHERE pct_sites >= 50)             AS half_the_sites_or_more
FROM carrier_match_tbl;

\echo
\echo STEP 3 of 4. What the two methods disagree about, which is the
\echo argument for the change stated as a number.
\echo
SELECT 'geography and name agree'                   AS verdict,
       count(*) AS pairings
FROM carrier_match_tbl WHERE name_link
UNION ALL
SELECT 'geography only, the name rule missed it',
       count(*) FROM carrier_match_tbl WHERE NOT name_link
UNION ALL
SELECT 'name only, no site in the footprint at all',
       count(*)
FROM carrier_resolved_tbl r
WHERE r.bdc_provider_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM serving_site_tbl s
              WHERE s.carrier_domain = r.itdk_domain)
  AND NOT EXISTS (SELECT 1 FROM carrier_match_tbl m
                  WHERE m.carrier_domain = r.itdk_domain
                    AND m.provider_id = r.bdc_provider_id);

\echo
\echo The pairings the name rule asserts where NOT ONE of the sites of that
\echo domain lies in the footprint of that provider. Full count first, then
\echo the fifty carrying the most footprint.
\echo
SELECT count(*) AS name_only_pairings_with_no_geographic_support
FROM carrier_resolved_tbl r
WHERE r.bdc_provider_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM serving_site_tbl s
              WHERE s.carrier_domain = r.itdk_domain)
  AND NOT EXISTS (SELECT 1 FROM carrier_match_tbl m
                  WHERE m.carrier_domain = r.itdk_domain
                    AND m.provider_id = r.bdc_provider_id);

WITH prov AS (
    SELECT provider_id, count(*) AS provider_pairs
    FROM provider_tract_tech_tbl GROUP BY 1
)
SELECT r.itdk_domain, r.bdc_provider_id, p.provider_pairs,
       left(coalesce(r.label_basis, ''), 34) AS label_basis
FROM carrier_resolved_tbl r
JOIN prov p ON p.provider_id = r.bdc_provider_id
WHERE EXISTS (SELECT 1 FROM serving_site_tbl s
              WHERE s.carrier_domain = r.itdk_domain)
  AND NOT EXISTS (SELECT 1 FROM carrier_match_tbl m
                  WHERE m.carrier_domain = r.itdk_domain
                    AND m.provider_id = r.bdc_provider_id)
GROUP BY 1, 2, 3, 4
ORDER BY p.provider_pairs DESC
LIMIT 50;

\echo
\echo STEP 4 of 4. Three files for your approval. All rows, no sample.
\echo
\echo   carrier_match_approval.tsv   every candidate pairing, ordered so
\echo                                the domains with the most sites come
\echo                                first and the best-supported candidate
\echo                                for each domain comes first within it.
\echo   carrier_match_orphans.tsv    providers with a footprint and NO
\echo                                candidate domain. Comcast is here until
\echo                                a pairing is approved.
\echo   carrier_match_nosite.tsv     domains with sites that no provider
\echo                                serves, including sites outside the USA.
\echo

\copy (SELECT carrier_domain, sites, sites_placed, node_addresses, site_state_list, provider_id, brand_count, brand_names, frns, provider_pairs, provider_tracts, provider_techs, sites_in_footprint, pct_sites, states_in_common, pairs_per_site, name_link, by_decision, label_bases FROM carrier_match_tbl ORDER BY sites DESC, carrier_domain, sites_in_footprint DESC, provider_pairs DESC) TO '/home/boris/geo/carrier_match_approval.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\copy (WITH prov AS (SELECT provider_id, count(*) AS provider_pairs, count(DISTINCT tract_geoid) AS provider_tracts FROM provider_tract_tech_tbl GROUP BY 1), brands AS (SELECT provider_id, string_agg(DISTINCT brand_name, ' | ') AS brand_names, string_agg(DISTINCT frn, ' ') AS frns FROM bdc_carrier_tbl GROUP BY 1) SELECT p.provider_id, b.brand_names, b.frns, p.provider_pairs, p.provider_tracts FROM prov p LEFT JOIN brands b ON b.provider_id = p.provider_id WHERE NOT EXISTS (SELECT 1 FROM carrier_match_tbl m WHERE m.provider_id = p.provider_id) ORDER BY p.provider_pairs DESC) TO '/home/boris/geo/carrier_match_orphans.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\copy (SELECT st.carrier_domain, count(*) AS sites, count(st.tract_geoid) AS sites_placed, sum(st.node_addresses) AS node_addresses, string_agg(DISTINCT coalesce(st.region, 'no state'), ',') AS regions FROM site_tract_tbl st WHERE NOT EXISTS (SELECT 1 FROM carrier_match_tbl m WHERE m.carrier_domain = st.carrier_domain) GROUP BY 1 ORDER BY 2 DESC) TO '/home/boris/geo/carrier_match_nosite.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\echo
\echo The orphan providers that matter most, printed here as well as written,
\echo because a carrier with no candidate is a hole in step 4 whatever else
\echo is approved.
\echo
WITH prov AS (
    SELECT provider_id, count(*) AS provider_pairs,
           count(DISTINCT tract_geoid) AS provider_tracts
    FROM provider_tract_tech_tbl GROUP BY 1
), brands AS (
    SELECT provider_id, string_agg(DISTINCT brand_name, ' | ') AS brand_names
    FROM bdc_carrier_tbl GROUP BY 1
)
SELECT count(*) AS orphan_providers,
       sum(p.provider_pairs) AS their_tract_technology_pairs
FROM prov p
WHERE NOT EXISTS (SELECT 1 FROM carrier_match_tbl m
                  WHERE m.provider_id = p.provider_id);

WITH prov AS (
    SELECT provider_id, count(*) AS provider_pairs,
           count(DISTINCT tract_geoid) AS provider_tracts
    FROM provider_tract_tech_tbl GROUP BY 1
), brands AS (
    SELECT provider_id, string_agg(DISTINCT brand_name, ' | ') AS brand_names
    FROM bdc_carrier_tbl GROUP BY 1
)
SELECT p.provider_id, left(coalesce(b.brand_names, ''), 44) AS brand_names,
       p.provider_pairs, p.provider_tracts
FROM prov p
LEFT JOIN brands b ON b.provider_id = p.provider_id
WHERE NOT EXISTS (SELECT 1 FROM carrier_match_tbl m
                  WHERE m.provider_id = p.provider_id)
ORDER BY p.provider_pairs DESC
LIMIT 30;

\echo
\echo The coverage this would reach if every candidate with half or more of
\echo the sites of a domain in the footprint were approved. NOT applied, so
\echo this is the size of the prize before you rule on anything.
\echo
WITH prov AS (
    SELECT provider_id, count(*) AS provider_pairs
    FROM provider_tract_tech_tbl GROUP BY 1
)
SELECT sum(p.provider_pairs)                               AS total_pairs,
       sum(p.provider_pairs) FILTER (
         WHERE EXISTS (SELECT 1 FROM carrier_match_tbl m
                       WHERE m.provider_id = p.provider_id
                         AND m.pct_sites >= 50))           AS pairs_reachable,
       round(100.0 * sum(p.provider_pairs) FILTER (
         WHERE EXISTS (SELECT 1 FROM carrier_match_tbl m
                       WHERE m.provider_id = p.provider_id
                         AND m.pct_sites >= 50))
             / nullif(sum(p.provider_pairs), 0), 1)        AS pct_reachable
FROM prov p;

\timing off
