-- onpremises_audit.sql
--
-- WHY THIS EXISTS. Boris, 2026-11-06, on the category_yield numbers:
--
--   "There are 11,824 police departments in the USA, not 2,519 ... There are
--   29,452 fire departments, six times what's in your source ... an 11.64%
--   onpremises rate sounds completely and obviously false ... telecommunication:
--   if those are telecoms companies, they would be expected to have 100%
--   onpremises. Review the sources, review by sampling the onpremises
--   conclusions."
--
-- Both objections are correct, and the first one explains part of the second.
--
-- OBJECTION 1, THE DENOMINATOR. The category_yield row counts are NOT counts of
-- US institutions, and I presented them as though they were. lm_fetch.py's
-- Overpass query, which built the entire osm source, is:
--
--     nwr["website"]["addr:postcode"](area.a);
--     nwr["contact:website"]["addr:postcode"](area.a);
--
-- Every row therefore had to carry BOTH a website tag AND addr:postcode in
-- OpenStreetMap before it was fetched. So "police 2,519" means "OSM police
-- features that a contributor had tagged with both a website and a postcode",
-- which against Boris's 11,824 real departments is 21 per cent. Fire stations
-- 5,208 against 29,452 is 18 per cent. Municipalities and counties 22,573 real
-- against government 6,571 plus townhall 2,665 is 41 per cent.
--
-- The percentages in category_yield are therefore "share of a website-tagged
-- OSM subset that this chain judged on-premises". They are NOT "share of US
-- police departments that self-host", and that is how I wrote them up. That was
-- a straightforward misreading of my own query and the conclusions drawn from
-- it, including the police claim, should be treated as unsupported until this
-- file is run.
--
-- It also makes the rates MORE suspicious, not less, which is Boris's point. A
-- contributor who bothers to tag a website is likelier to have done so for a
-- large, urban, self-hosting institution. The sample is biased towards exactly
-- the organisations that should pass, and they are failing anyway.
--
-- OBJECTION 2, THE RATES. Universities and telecoms should be near the top.
-- They are not, and category_yield cannot say why because onpremises_reason is
-- written ONLY by onpremises_hosting_rule.sql. Every rejection by the registrant
-- rules carries a NULL reason, which is why police showed 2,461 rows with no
-- reason at all against 58 marked hosting. The rule that decided is not
-- recorded, so the chain is currently un-auditable at exactly the point where it
-- is being doubted.
--
-- Section 2 fixes that by RE-DERIVING the rule in SQL, mirroring the eight
-- outcomes documented in cmd_onpremises in ovt_resolve_hosts.py lines 1203 to
-- 1210. If this disagrees with the onpremises column, that disagreement is
-- itself a finding and section 2 reports it.
--
-- READ-ONLY. One TEMP table, dropped at the end, private to this session.
-- Safe to interrupt at any point.

\timing on
\set ON_ERROR_STOP on
SET work_mem = '512MB';

\echo ''
\echo 'Every section prints when it finishes. The slow ones are flagged with a'
\echo 'measured or estimated time BEFORE they run, because psql cannot report'
\echo 'progress inside a single statement.'

\echo ''
\echo '=== 1 of 6: the denominator, stated plainly (fast) ==='
\echo '    rows is OSM features with a website tag AND addr:postcode, not a'
\echo '    count of US institutions. distinct_hosts is the number that bounds'
\echo '    how many landmarks the category can ever yield.'
SELECT category,
       count(*)                                                AS rows,
       count(DISTINCT lower(btrim(website)))                   AS distinct_websites,
       count(DISTINCT overture_zip)                            AS zips_present,
       count(*) FILTER (WHERE lookup_status = 'true')           AS rdap_ok,
       count(*) FILTER (WHERE onpremises)                      AS onpremises_true
FROM landmarks_usa
WHERE source = 'osm'
  AND category IN ('university', 'college', 'school', 'hospital', 'clinic',
                   'police', 'fire_station', 'telecommunication', 'government',
                   'townhall', 'library', 'courthouse', 'prison', 'research',
                   'research_institute')
GROUP BY 1
ORDER BY rows DESC;

\echo ''
\echo '=== 2 of 6: re-derive WHICH RULE fired, which the table does not store ==='
\echo '    Mirrors cmd_onpremises lines 1203 to 1210 exactly. About a minute:'
\echo '    it joins isp_names, provider_names and zip_adjacency per row.'

CREATE TEMP TABLE audit AS
WITH base AS (
    SELECT t.landmark_id,
           t.category,
           t.name,
           t.locality,
           t.region,
           lower(btrim(t.website))                                   AS host_text,
           t.ip_address,
           t.lookup_status,
           t.onpremises,
           t.onpremises_reason,
           left(lpad(btrim(t.overture_zip), 5, '0'), 5)               AS zip,
           t.registrant_1,
           left(lpad(btrim(t.registrant_1_zip), 5, '0'), 5)           AS r1zip,
           t.registrant_2,
           left(lpad(btrim(t.registrant_2_zip), 5, '0'), 5)           AS r2zip
    FROM landmarks_usa t
    WHERE t.source = 'osm'
      AND t.category IN ('university', 'college', 'hospital', 'police',
                         'fire_station', 'telecommunication', 'government',
                         'library', 'school', 'townhall')
), flags AS (
    SELECT b.*,
           b.registrant_1 IS NOT NULL AND EXISTS (
               SELECT 1 FROM isp_names i
               WHERE lower(btrim(i.name)) = lower(btrim(b.registrant_1)))   AS r1_isp,
           b.registrant_2 IS NOT NULL AND EXISTS (
               SELECT 1 FROM isp_names i
               WHERE lower(btrim(i.name)) = lower(btrim(b.registrant_2)))   AS r2_isp,
           b.registrant_1 IS NOT NULL AND EXISTS (
               SELECT 1 FROM provider_names p
               WHERE lower(btrim(p.name)) = lower(btrim(b.registrant_1)))   AS r1_prov,
           b.registrant_2 IS NOT NULL AND EXISTS (
               SELECT 1 FROM provider_names p
               WHERE lower(btrim(p.name)) = lower(btrim(b.registrant_2)))   AS r2_prov
    FROM base b
)
SELECT f.*,
       CASE
         WHEN f.registrant_1 IS NULL AND f.registrant_2 IS NULL
              THEN '0 no registrant data -> NULL'
         WHEN f.zip IS NULL OR f.zip = ''
              THEN '1 no landmark ZIP -> NULL'
         WHEN f.r1_prov OR f.r2_prov
              THEN '2 a registrant is a CDN, cloud or web host -> false'
         WHEN (f.registrant_1 IS NULL OR f.r1_isp)
          AND (f.registrant_2 IS NULL OR f.r2_isp)
              THEN '3 every registrant is an ISP -> true'
         WHEN (NOT f.r1_isp AND f.r1zip = f.zip)
           OR (NOT f.r2_isp AND f.r2zip = f.zip)
              THEN '4 non-ISP registrant ZIP matches -> true'
         WHEN EXISTS (SELECT 1 FROM zip_adjacency z
                      WHERE (z.zip_a = f.zip AND z.zip_b IN (
                                CASE WHEN NOT f.r1_isp THEN f.r1zip END,
                                CASE WHEN NOT f.r2_isp THEN f.r2zip END))
                         OR (z.zip_b = f.zip AND z.zip_a IN (
                                CASE WHEN NOT f.r1_isp THEN f.r1zip END,
                                CASE WHEN NOT f.r2_isp THEN f.r2zip END)))
              THEN '5 non-ISP registrant ZIP adjacent -> true'
         WHEN coalesce(CASE WHEN NOT f.r1_isp THEN f.r1zip END, '') = ''
          AND coalesce(CASE WHEN NOT f.r2_isp THEN f.r2zip END, '') = ''
              THEN '6a no non-ISP registrant ZIP -> false'
         ELSE '6b ZIPs differ and are not adjacent -> false'
       END AS derived_rule
FROM flags f;

CREATE INDEX ON audit (category);
ANALYZE audit;

SELECT count(*) AS audited_rows FROM audit;

\echo ''
\echo '--- the rule that decided, per category. THIS is the diagnosis (fast) ---'
SELECT category, derived_rule, count(*) AS rows
FROM audit
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

\echo ''
\echo '--- does the re-derivation AGREE with the stored onpremises column? ---'
\echo '    A disagreement means either my mirror is wrong or the column is'
\echo '    stale. Either way it must be known before any of this is trusted.'
SELECT coalesce(onpremises::text, 'NULL')                         AS stored,
       CASE WHEN derived_rule LIKE '%-> true'  THEN 'true'
            WHEN derived_rule LIKE '%-> false' THEN 'false'
            ELSE 'NULL' END                                        AS derived,
       count(*)                                                    AS rows,
       count(*) FILTER (WHERE onpremises_reason LIKE 'hosting:%')  AS of_which_hosting_rule
FROM audit
GROUP BY 1, 2
ORDER BY 3 DESC;

\echo ''
\echo '=== 3 of 6: SAMPLE ROWS. Universities first, because 11.64 pct is the ==='
\echo '    claim Boris called obviously false. Read registrant_1 and r1zip'
\echo '    against zip: if the registrant IS the university and the ZIPs merely'
\echo '    differ, the rule is too strict. If the registrant is a cloud'
\echo '    provider, the university genuinely does not self-host its website.'
SELECT left(coalesce(name, ''), 34)          AS name,
       left(coalesce(host_text, ''), 30)     AS website,
       zip,
       left(coalesce(registrant_1, ''), 26)  AS registrant_1,
       r1zip,
       left(coalesce(registrant_2, ''), 18)  AS registrant_2,
       onpremises,
       left(derived_rule, 20)                AS rule
FROM audit
WHERE category = 'university'
ORDER BY random()
LIMIT 25;

\echo ''
\echo '--- telecommunication, which Boris expects at or near 100 pct ---'
SELECT left(coalesce(name, ''), 34)          AS name,
       left(coalesce(host_text, ''), 30)     AS website,
       zip,
       left(coalesce(registrant_1, ''), 26)  AS registrant_1,
       r1zip,
       onpremises,
       left(derived_rule, 20)                AS rule
FROM audit
WHERE category = 'telecommunication'
ORDER BY random()
LIMIT 25;

\echo ''
\echo '--- hospitals, where 177 of 12,222 was called mind-boggling ---'
SELECT left(coalesce(name, ''), 34)          AS name,
       left(coalesce(host_text, ''), 30)     AS website,
       zip,
       left(coalesce(registrant_1, ''), 26)  AS registrant_1,
       r1zip,
       onpremises,
       left(derived_rule, 20)                AS rule
FROM audit
WHERE category = 'hospital'
ORDER BY random()
LIMIT 25;

\echo ''
\echo '--- police ---'
SELECT left(coalesce(name, ''), 34)          AS name,
       left(coalesce(host_text, ''), 30)     AS website,
       zip,
       left(coalesce(registrant_1, ''), 26)  AS registrant_1,
       r1zip,
       onpremises,
       left(derived_rule, 20)                AS rule
FROM audit
WHERE category = 'police'
ORDER BY random()
LIMIT 25;

\echo ''
\echo '=== 4 of 6: WHO the registrants actually are, per category (fast) ==='
\echo '    If rule 2 dominates, these are the providers doing it. If rule 6b'
\echo '    dominates, these are organisations whose registered ZIP sits away'
\echo '    from the building, which is a different problem with a different fix.'
SELECT category,
       left(coalesce(registrant_1, '(none)'), 38) AS registrant_1,
       count(*)                                    AS rows,
       count(*) FILTER (WHERE onpremises)          AS onpremises_true
FROM audit
WHERE category IN ('university', 'telecommunication', 'hospital', 'police')
GROUP BY 1, 2
HAVING count(*) >= 5
ORDER BY 1, 3 DESC;

\echo ''
\echo '=== 5 of 6: are the ZIPs merely NEAR each other? (fast) ==='
\echo '    For every row rejected by 6b, how far apart are the two ZIPs as'
\echo '    integers. A difference under about 20 usually means the same metro,'
\echo '    which would say the adjacency table is too narrow rather than the'
\echo '    landmark being wrong. This is a WEAK proxy: numeric ZIP distance is'
\echo '    not geographic distance, and it is here to size the question, not to'
\echo '    answer it.'
SELECT category,
       count(*)                                                       AS rejected_6b,
       count(*) FILTER (WHERE abs(zip::int - r1zip::int) <= 5)         AS within_5,
       count(*) FILTER (WHERE abs(zip::int - r1zip::int) BETWEEN 6 AND 20)  AS within_6_to_20,
       count(*) FILTER (WHERE abs(zip::int - r1zip::int) > 20)         AS over_20
FROM audit
WHERE derived_rule LIKE '6b%'
  AND zip ~ '^[0-9]{5}$'
  AND r1zip ~ '^[0-9]{5}$'
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 6 of 6: the MX/NS denominator, which decides that question ==='
\echo '    The 2026-11-06 run measured 2.80 pct newly qualifying on a sample of'
\echo '    2,000 DISTINCT rejected hosts. 2.80 pct of what matters entirely:'
\echo '    the number below times 0.028 is what a full MX/NS pass would add.'
\echo '    SLOW: one aggregate with a regexp over the whole table. Expect'
\echo '    one to three minutes, and it is last so nothing else waits on it.'
SELECT count(DISTINCT lower(btrim(split_part(split_part(
           regexp_replace(website, '^[a-zA-Z]+://', ''), '/', 1), ':', 1))))
           AS distinct_rejected_hosts
FROM landmarks_usa
WHERE lookup_status = 'true'
  AND onpremises IS NOT TRUE
  AND overture_zip IS NOT NULL
  AND website IS NOT NULL;

DROP TABLE IF EXISTS audit;

\echo ''
\echo '=== done ==='
\timing off
