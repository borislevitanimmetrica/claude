-- dia_carrier_check.sql - do the DIA carriers file with the FCC at all?
--
-- WHY THIS IS A QUERY AND NOT A DECISION
--
-- Boris, 2026-11-18: "alter.net belongs to Verizon. he.net, gtt.net and
-- twelve99-cust.net connect DIA customers directly."
--
-- The first is a mapping and is recorded in decisions_2026_11_18.tsv.
--
-- The second is a statement about what those three ARE, and it settles one
-- question while opening another. It settles that they are NOT to be
-- discarded as "not an ISP": they connect customers directly, so their nodes
-- are customer-connecting nodes and their sites are real serving sites.
--
-- What it does not settle is whether they appear in the FCC BDC. Step 4 asks
-- for "each census tract in which that carrier offers service", and the BDC
-- is the only source of that answer here. A carrier with no BDC filing has
-- no tract list, so step 4 cannot run for it however real its sites are.
--
-- I am not going to assume either way. Dedicated Internet Access is sold to
-- business premises, and the BDC does carry a business_residential_code, so
-- a DIA provider MIGHT file. Whether these three do is a fact in the data.
--
-- THE CONSEQUENCE EITHER WAY, so the answer is actionable when it arrives:
--
--   IF THEY FILE, they need a name mapping like any other carrier and step 4
--   runs for them normally. This query prints the candidate BDC names so a
--   ruling can be made from real strings rather than from guesses.
--
--   IF THEY DO NOT FILE, their 153 sites and 413 node addresses are still
--   valid for STEP 6, which ascribes IP addresses congregating at a site to
--   the tracts that site serves. Step 6 does not need a BDC filing from the
--   carrier whose node it is; it needs the site location and the tracts,
--   both of which come from elsewhere. So they would be excluded from step 4
--   and retained for step 6, which is a different thing from being
--   discarded.

\echo
\echo The four carriers in question, and their site counts.
\echo
SELECT s.carrier_domain,
       count(*)              AS sites,
       sum(s.node_addresses) AS node_addresses,
       count(DISTINCT s.city) AS cities,
       EXISTS (SELECT 1 FROM carrier_resolved_tbl r
               WHERE r.itdk_domain = s.carrier_domain
                 AND r.bdc_provider_id IS NOT NULL) AS resolves_to_bdc
FROM serving_site_tbl s
WHERE s.carrier_domain IN ('alter.net', 'he.net', 'gtt.net',
                           'twelve99-cust.net')
GROUP BY 1 ORDER BY count(*) DESC;

\echo
\echo CANDIDATE BDC NAMES. Searched by the operator names these domains are
\echo known by, taken from what the crosswalk already observed for them
\echo rather than from names I have supplied.
\echo
\echo What ip-api and RDAP call these carriers, which is measured from the
\echo node addresses themselves and is the only evidence here that does not
\echo come from me:
\echo
SELECT c.itdk_domain,
       left(c.ipapi_isp, 36)  AS ipapi_isp,
       left(c.ipapi_org, 36)  AS ipapi_org,
       left(c.rdap_name, 36)  AS rdap_name,
       c.asn
FROM carrier_crosswalk_tbl c
WHERE c.itdk_domain IN ('he.net', 'gtt.net', 'twelve99-cust.net')
ORDER BY c.itdk_domain, c.asn;

\echo
\echo BDC carriers whose brand name resembles those observed names. If a
\echo row appears here, the carrier files with the FCC and needs a mapping.
\echo If nothing appears, it does not file and step 4 cannot cover it.
\echo
WITH want AS (
    SELECT DISTINCT lower(trim(x)) AS term
    FROM (VALUES
      ('hurricane electric'), ('he.net'),
      ('gtt'), ('global telecom'),
      ('telia'), ('arelion'), ('twelve99')
    ) AS v(x)
)
SELECT b.provider_id,
       left(b.brand_name, 44) AS bdc_brand_name,
       w.term                 AS matched_on
FROM bdc_carrier_tbl b
JOIN want w ON lower(b.brand_name) LIKE '%' || w.term || '%'
GROUP BY 1, 2, 3
ORDER BY 3, 2;

\echo
\echo And whether any of those BDC providers actually have tracts, since a
\echo registered name with no availability rows is of no use to step 4.
\echo
WITH want AS (
    SELECT DISTINCT lower(trim(x)) AS term
    FROM (VALUES
      ('hurricane electric'), ('gtt'), ('telia'), ('arelion'), ('twelve99')
    ) AS v(x)
), prov AS (
    SELECT DISTINCT b.provider_id, b.brand_name
    FROM bdc_carrier_tbl b
    JOIN want w ON lower(b.brand_name) LIKE '%' || w.term || '%'
)
SELECT left(p.brand_name, 40) AS bdc_brand_name,
       p.provider_id,
       count(DISTINCT t.tract_geoid) AS tracts,
       count(DISTINCT t.technology)  AS technologies
FROM prov p
LEFT JOIN provider_tract_tech_tbl t ON t.provider_id = p.provider_id
GROUP BY 1, 2 ORDER BY count(DISTINCT t.tract_geoid) DESC;

\echo
\echo READ IT THIS WAY:
\echo   a BDC name with tracts     needs a ruling, then step 4 covers it
\echo   a BDC name with no tracts  files but serves nothing recorded
\echo   no BDC name at all         does not file; keep the sites for step 6
\echo                              and exclude from step 4
\echo
