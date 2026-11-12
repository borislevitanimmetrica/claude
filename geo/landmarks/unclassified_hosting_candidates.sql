-- unclassified_hosting_candidates.sql
--
-- Find companies that behave like hosting providers or access carriers but
-- appear in neither isp_names nor provider_names, so they can be classified
-- before the next ingest rather than discovered after it.
--
-- WHY THIS IS A QUERY AND NOT NEW MACHINERY
--
-- node_fanout.sql already decides, per address, whether that address serves
-- disjoint ZIP clusters, and records it in address_hosting_tbl along with a
-- representative registrant. A hosting company that no name list knows about is
-- therefore already visible: it is a registrant whose addresses carry a
-- 'hosting:' verdict and whose name matches neither table. Nothing has to be
-- measured again; it only has to be asked for.
--
-- This is how the three names added on 2026-10-31 were found. Interactive
-- Educational Services, Inc. of Bakersfield serves 54 ZIPs and 125 schools from
-- the single address 104.232.38.112, which is a school-website vendor behaving
-- exactly like the CDNs beside it in the ranking.
--
-- WHY DETECTION AFTER THE FACT IS ACCEPTABLE
--
-- A vendor's first appearance always passes through unclassified. That is
-- tolerable because two independent mechanisms reject it: the name list, which
-- needs maintenance, and the per-address fan-out rule, which does not. The
-- fan-out rule caught Interactive Educational Services without help, at 54
-- disjoint clusters. Naming it only saves the RDAP and trace budget on the same
-- vendor in the other 49 states.
--
-- HOW TO CLASSIFY WHAT THIS RETURNS, which is a judgement and not a query:
--
--   routes retail or business access circuits  -> isp_names
--   hosts content for customers elsewhere      -> provider_names
--   demonstrably does BOTH                     -> neither table
--
-- The third case is the Southwest Cyberport and Synergy Networks precedent.
-- Southwest Cyberport looked like a host in this same ranking and is not one:
-- swcp.com describes a New Mexico ISP supplying DSL with CenturyLink, its own
-- fibre, fixed wireless, and dedicated circuits to apartment and office
-- complexes. Listing it wholesale would have destroyed real landmarks, so it is
-- left for the per-address rule to judge. Read what the company says it does
-- before adding a name.
--
-- ALWAYS TAKE THE NAME FROM RDAP, NOT FROM HERE. Both lists are matched by
-- exact string on lower(btrim(name)), and they work at that because they are
-- copies of what ARIN returns rather than independent renderings. A name
-- retyped by hand breaks that property silently. Run rdap-lookup.sh, or the
-- native client, on the address and paste the registrant string it prints.
--
-- Read only. Nothing here writes, locks or alters anything.

\timing on
SET lock_timeout = '30s';

\echo '=== 1. Unclassified registrants whose addresses behave like hosting ==='
\echo 'Ranked by ZIP spread. A single address serving many disjoint ZIPs is the signature.'

SELECT h.registrant,
       count(*)                                   AS hosting_addresses,
       max(h.zips_at_address)                     AS max_zips_on_one_address,
       max(h.clusters_at_address)                 AS max_disjoint_clusters,
       sum(h.places)                              AS places_affected,
       (SELECT min(host(a.ip_address)) FROM address_hosting_tbl a
        WHERE a.registrant = h.registrant
          AND a.verdict LIKE 'hosting:%')         AS example_address
FROM address_hosting_tbl h
WHERE h.verdict LIKE 'hosting:%'
  AND h.registrant IS NOT NULL
  AND lower(btrim(h.registrant)) NOT IN (SELECT lower(btrim(name)) FROM provider_names)
  AND lower(btrim(h.registrant)) NOT IN (SELECT lower(btrim(name)) FROM isp_names)
GROUP BY h.registrant
ORDER BY max_disjoint_clusters DESC, places_affected DESC
LIMIT 40;

\echo ''
\echo '=== 2. The same registrants, but showing how much they would COST to exclude ==='
\echo 'A registrant with many on-premises addresses as well is a mixed business.'
\echo 'Those belong in NEITHER table; let the per-address rule decide, as with'
\echo 'Southwest Cyberport and Synergy Networks.'

SELECT h.registrant,
       count(*) FILTER (WHERE h.verdict LIKE 'hosting:%')      AS hosting_addresses,
       count(*) FILTER (WHERE h.verdict LIKE 'on-premises:%')  AS onpremises_addresses,
       sum(h.places) FILTER (WHERE h.verdict LIKE 'hosting:%')     AS places_if_excluded,
       sum(h.places) FILTER (WHERE h.verdict LIKE 'on-premises:%') AS places_at_risk
FROM address_hosting_tbl h
WHERE h.registrant IS NOT NULL
  AND lower(btrim(h.registrant)) NOT IN (SELECT lower(btrim(name)) FROM provider_names)
  AND lower(btrim(h.registrant)) NOT IN (SELECT lower(btrim(name)) FROM isp_names)
GROUP BY h.registrant
HAVING count(*) FILTER (WHERE h.verdict LIKE 'hosting:%') > 0
ORDER BY places_if_excluded DESC NULLS LAST
LIMIT 40;

\echo ''
\echo '=== 3. Coverage of the two lists over the registrants that actually matter ==='

SELECT count(DISTINCT registrant)                                   AS registrants_with_addresses,
       count(DISTINCT registrant) FILTER (
           WHERE lower(btrim(registrant)) IN (SELECT lower(btrim(name)) FROM isp_names))
                                                                    AS known_isps,
       count(DISTINCT registrant) FILTER (
           WHERE lower(btrim(registrant)) IN (SELECT lower(btrim(name)) FROM provider_names))
                                                                    AS known_providers,
       count(DISTINCT registrant) FILTER (
           WHERE lower(btrim(registrant)) NOT IN (SELECT lower(btrim(name)) FROM isp_names)
             AND lower(btrim(registrant)) NOT IN (SELECT lower(btrim(name)) FROM provider_names))
                                                                    AS unclassified
FROM address_hosting_tbl
WHERE registrant IS NOT NULL;
