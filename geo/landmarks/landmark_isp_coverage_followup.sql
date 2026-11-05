-- landmark_isp_coverage_followup.sql
--
-- Four things the first coverage run turned up, and the one it got wrong.
--
-- READ ONLY. Every statement is a SELECT or a CREATE TEMP. Nothing writes to a
-- permanent table. Cheap by design: it does NOT repeat the two-million-lookup
-- city-level section.
--
-- WHAT THE FIRST RUN MEASURED
--
--   supply                 56,040 (ZIP, ISP) pairs, 16,114 ZIPs, 5,814 ISPs
--   demand                 10,212 pairs, 6,938 ZIPs, 89 ISPs
--   pairs covered          2,965 of 10,212, 29.03 percent
--   ZIPs covered           5,535 of 6,938, 79.78 percent
--
-- The pair figure is a THIRD of the ZIP figure, which is the overstatement
-- Boris predicted. But BOTH numbers are built on two populations that the run
-- itself showed are unsound, and sections 1 and 2 below quantify each.
--
-- 1. THE SUPPLY SET CONTRADICTS ITSELF.
--
-- onpremises_hosting_rule.sql sets onpremises = false AND writes
-- onpremises_reason = 'hosting: address serves disjoint ZIP clusters (...)' in
-- the SAME update statement, at its lines 97 to 99. So onpremises = true
-- together with a hosting reason cannot both be current. The first run showed
-- 132,125 onpremises rows of which 124,568 carry a reason, and the reason
-- breakdown is dominated by hosting verdicts: 34,774 "too wide to cluster",
-- 7,392 "2 disjoint areas", 3,624 "3 disjoint areas" and so on.
--
-- VERIFIED: those two facts are contradictory.
-- INFERRED, AND FLAGGED AS SUCH: something set onpremises back to true after
-- the hosting rule ran and left the reason behind. The Session 3 notes record
-- an "onpremises hosting-row preservation" fix being approved, so the probable
-- cause is that the deployed ovt_resolve_hosts.py either lacks that fix or it
-- does not cover this case. I have NOT read the deployed copy and am not
-- asserting which.
--
-- Why it matters for the headline: every one of those rows is counted as
-- supply, so 16,114 ZIPs and 29 percent pair coverage are BOTH too high.
-- Section 1 recomputes without them.
--
-- 2. THE DEMAND SET IS BUILT ON A 272 kB RDAP CACHE.
--
-- rdap_registrant_tbl is 272 kB against a 661 MB probe table and a 37 GB
-- landmarks table, and the demand side found only 89 distinct ISPs in the
-- whole country. The Session 3 notes record the cache as roughly 486
-- allocations deep against 371,287 candidates. So the denominator is not a
-- national ISP census, it is whatever the cache happens to hold, and the
-- uncovered list is therefore a floor rather than a measurement.
--
-- Section 3 gets a complete ISPs-per-ZIP distribution from the probe table's
-- own ip-api isp column, which needs no RDAP cache at all. It cannot be joined
-- to the supply side, because supply is in RDAP's vocabulary and this is in
-- ip-api's, so it answers the structural question only: how many carriers
-- really do serve a ZIP.

\timing on

-- ---------------------------------------------------------------------------
-- 0. EXISTENCE CHECK, so a missing relation is one line and not a cascade.
--
-- landmarks_usa, ip2city_dbiplite_probe_tbl and rdap_registrant_tbl were all
-- confirmed present by the first run. isp_names and provider_names are in the
-- repository DDL with a single name text column, and the Session 3 transcript
-- records them being built to 1,101 and 42 entries, but I have NOT confirmed
-- either exists in this database. If they report MISSING, section 3 is the only
-- part that fails and everything else still answers.
-- ---------------------------------------------------------------------------
SELECT r.needed,
       CASE WHEN c.oid IS NULL THEN 'MISSING' ELSE 'present' END AS status,
       CASE WHEN c.oid IS NULL THEN NULL
            ELSE pg_size_pretty(pg_total_relation_size(c.oid)) END AS size
FROM (VALUES ('landmarks_usa'),
             ('ip2city_dbiplite_probe_tbl'),
             ('rdap_registrant_tbl'),
             ('isp_names'),
             ('provider_names')) AS r(needed)
LEFT JOIN pg_class c
       ON c.relname = r.needed
      AND c.relnamespace = 'public'::regnamespace
ORDER BY 2, 1;

-- ---------------------------------------------------------------------------
-- 1. THE CONTRADICTION, EXACTLY, AND THE HONEST COVERAGE WITHOUT IT.
-- ---------------------------------------------------------------------------
SELECT count(*) FILTER (WHERE onpremises IS TRUE
                          AND onpremises_reason LIKE 'hosting:%')  AS true_but_hosting,
       count(*) FILTER (WHERE onpremises IS TRUE
                          AND coalesce(onpremises_reason, '') NOT LIKE 'hosting:%')
                                                                   AS true_and_consistent,
       count(*) FILTER (WHERE onpremises IS FALSE
                          AND onpremises_reason LIKE 'hosting:%')  AS false_and_hosting
FROM landmarks_usa;

-- Supply counted both ways. The second is the one to believe, because a
-- hosting verdict means the address serves disjoint ZIP clusters and one
-- building cannot be in disjoint ZIP clusters.
CREATE TEMP TABLE supply_all AS
SELECT DISTINCT left(lpad(btrim(overture_zip), 5, '0'), 5) AS zip,
       btrim(registrant_1)                                 AS isp
FROM landmarks_usa
WHERE onpremises
  AND overture_zip IS NOT NULL
  AND btrim(coalesce(registrant_1, '')) <> '';

CREATE TEMP TABLE supply_clean AS
SELECT DISTINCT left(lpad(btrim(overture_zip), 5, '0'), 5) AS zip,
       btrim(registrant_1)                                 AS isp
FROM landmarks_usa
WHERE onpremises
  AND coalesce(onpremises_reason, '') NOT LIKE 'hosting:%'
  AND overture_zip IS NOT NULL
  AND btrim(coalesce(registrant_1, '')) <> '';

CREATE INDEX ON supply_all (zip, isp);
CREATE INDEX ON supply_clean (zip, isp);
ANALYZE supply_all;
ANALYZE supply_clean;

SELECT 'as counted in the first run' AS basis,
       count(*)            AS pairs,
       count(DISTINCT zip) AS zips,
       count(DISTINCT isp) AS isps
FROM supply_all
UNION ALL
SELECT 'excluding hosting verdicts',
       count(*), count(DISTINCT zip), count(DISTINCT isp)
FROM supply_clean;

-- ---------------------------------------------------------------------------
-- 2. DEMAND, rebuilt once, and coverage on both supply sets.
--
-- Same LATERAL most-specific-allocation lookup as the first run. Expect about
-- a minute: the first run took 58.9 seconds for this.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE demand_pairs AS
SELECT left(lpad(btrim(p.zip), 5, '0'), 5)  AS zip,
       btrim(r.registrant)                  AS isp,
       count(*)                             AS ranges,
       sum((2::numeric) ^ (32 - masklen(p.network))) AS addresses
FROM ip2city_dbiplite_probe_tbl p
CROSS JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= (host(network(p.network)))::inet
      AND r.end_ip   >= (host(network(p.network)))::inet
    ORDER BY r.start_ip DESC
    LIMIT 1
) r
WHERE btrim(coalesce(p.zip, '')) <> ''
  AND btrim(coalesce(r.registrant, '')) <> ''
GROUP BY 1, 2;

CREATE INDEX ON demand_pairs (zip, isp);
ANALYZE demand_pairs;

SELECT 'all onpremises rows' AS supply_basis,
       count(*)                                       AS demand_pairs,
       count(*) FILTER (WHERE s.zip IS NOT NULL)      AS covered,
       round(100.0 * count(*) FILTER (WHERE s.zip IS NOT NULL)
             / greatest(count(*), 1), 2)              AS pct_covered
FROM demand_pairs d LEFT JOIN supply_all s ON s.zip = d.zip AND s.isp = d.isp
UNION ALL
SELECT 'excluding hosting verdicts',
       count(*), count(*) FILTER (WHERE s.zip IS NOT NULL),
       round(100.0 * count(*) FILTER (WHERE s.zip IS NOT NULL)
             / greatest(count(*), 1), 2)
FROM demand_pairs d LEFT JOIN supply_clean s ON s.zip = d.zip AND s.isp = d.isp;

-- ---------------------------------------------------------------------------
-- 3. THE WORK QUEUE, SPLIT BY WHAT THE REGISTRANT ACTUALLY IS.
--
-- The first run's top uncovered registrants by address count were Ford Motor
-- Company, Amazon, Microsoft, JPMorgan Chase, Eli Lilly, Merck, Procter and
-- Gamble, Xerox, Bank of America, the US Courts, the IRS and the Postal
-- Service. Those are enterprise allocations. No landmark will ever help them
-- and their addresses do not appear in a consumer bid request, which is
-- exactly the dedicated-and-private-access case Boris raised.
--
-- RDAP cannot tell them apart, but THIS PROJECT ALREADY HAS the lists that
-- can: isp_names, built to 1,101 entries, and provider_names, built to 42.
-- Membership is matched EXACTLY, which is how those lists are used elsewhere
-- and the reason they reject 10.7M rows with only 7 known leaks.
-- ---------------------------------------------------------------------------
SELECT CASE WHEN i.name IS NOT NULL THEN '1 known ISP'
            WHEN p.name IS NOT NULL THEN '2 known hosting provider'
            ELSE                         '3 unclassified' END       AS kind,
       count(*)                                                     AS uncovered_pairs,
       count(DISTINCT d.isp)                                        AS registrants,
       sum(d.ranges)                                                AS ranges,
       sum(d.addresses)::bigint                                     AS addresses
FROM demand_pairs d
LEFT JOIN supply_clean s ON s.zip = d.zip AND s.isp = d.isp
LEFT JOIN isp_names      i ON btrim(i.name) = d.isp
LEFT JOIN provider_names p ON btrim(p.name) = d.isp
WHERE s.zip IS NULL
GROUP BY 1
ORDER BY 1;

-- The queue that is actually worth working: uncovered pairs on a registrant
-- the project has already classified as an ISP.
SELECT d.isp,
       count(*)                 AS uncovered_zips,
       sum(d.ranges)            AS ranges,
       sum(d.addresses)::bigint AS addresses
FROM demand_pairs d
LEFT JOIN supply_clean s ON s.zip = d.zip AND s.isp = d.isp
JOIN isp_names i ON btrim(i.name) = d.isp
WHERE s.zip IS NULL
GROUP BY 1
ORDER BY addresses DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- 4. HOW MANY CARRIERS REALLY SERVE A ZIP.
--
-- From the probe table's own ip-api isp column, so it needs no RDAP cache and
-- covers every probed range rather than the 89 registrants the cache knows.
--
-- IT CANNOT BE JOINED TO SUPPLY. Supply is in RDAP's vocabulary and this is in
-- ip-api's, and the two spell the same company differently. This answers only
-- the structural question Boris raised: how many ISPs serve a ZIP, and so what
-- the real denominator is a multiple of.
--
-- ip-api populates isp inconsistently and org is the documented fallback, which
-- is why the existing tools coalesce them; the same is done here.
-- ---------------------------------------------------------------------------
SELECT count(*)                                                       AS probed_ranges_with_zip,
       count(*) FILTER (WHERE btrim(coalesce(isp, '')) <> '')         AS with_isp,
       count(*) FILTER (WHERE btrim(coalesce(isp, '')) =  ''
                          AND btrim(coalesce(org, '')) <> '')         AS org_only,
       count(*) FILTER (WHERE btrim(coalesce(isp, '')) =  ''
                          AND btrim(coalesce(org, '')) =  '')         AS neither
FROM ip2city_dbiplite_probe_tbl
WHERE btrim(coalesce(zip, '')) <> '';

CREATE TEMP TABLE zip_isp_ipapi AS
SELECT left(lpad(btrim(zip), 5, '0'), 5) AS zip,
       btrim(coalesce(nullif(btrim(isp), ''), org)) AS isp
FROM ip2city_dbiplite_probe_tbl
WHERE btrim(coalesce(zip, '')) <> ''
  AND btrim(coalesce(nullif(btrim(isp), ''), org)) IS NOT NULL
  AND btrim(coalesce(nullif(btrim(isp), ''), org)) <> ''
GROUP BY 1, 2;

SELECT count(*)            AS zip_isp_pairs,
       count(DISTINCT zip) AS zips,
       count(DISTINCT isp) AS distinct_isps,
       round(count(*)::numeric / greatest(count(DISTINCT zip), 1), 2)
                           AS mean_isps_per_zip
FROM zip_isp_ipapi;

SELECT isps_in_zip, count(*) AS zips, sum(isps_in_zip) AS pairs_needed
FROM (SELECT zip, count(DISTINCT isp) AS isps_in_zip
      FROM zip_isp_ipapi GROUP BY 1) z
GROUP BY 1
ORDER BY 1
LIMIT 30;

DROP TABLE IF EXISTS supply_all;
DROP TABLE IF EXISTS supply_clean;
DROP TABLE IF EXISTS demand_pairs;
DROP TABLE IF EXISTS zip_isp_ipapi;

\timing off
