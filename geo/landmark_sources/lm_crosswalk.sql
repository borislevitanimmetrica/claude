-- lm_crosswalk.sql - what the additional sources actually ADD over Overture.
--
-- The measured shortage this is all aimed at: Overture gives 120,154
-- on-premises places over only 28,324 distinct ADDRESSES, covering 15,963 ZIPs
-- of roughly 44,000 inhabited ones.
--
-- The unit of value is the HOST, not the place. The chain resolves a host to an
-- IP, RDAPs the IP and decides onpremises from the registrant, so N places
-- sharing one host yield ONE landmark address. A source whose rows mostly share
-- a domain therefore adds almost nothing however many rows it has, which is the
-- whole reason the National Park Service feed is not worth running: every park
-- is an nps.gov URL.
--
-- Section 1 is consequently the first thing to read, and it is also a check on
-- the loaders: a source with low pct_unique_hosts is either a single-domain
-- feed or a parsing bug.
--
-- Deliberately written without backslashes so the file stays safe to paste.

SELECT '=== 1. HOST INDEPENDENCE PER SOURCE. Read first. ===' AS section;

SELECT source,
       count(*)                                                        AS rows,
       count(DISTINCT lower(btrim(website)))                           AS distinct_hosts,
       round(100.0 * count(DISTINCT lower(btrim(website)))
             / nullif(count(*), 0), 1)                                 AS pct_unique_hosts,
       count(DISTINCT postcode) FILTER (WHERE postcode ~ '^[0-9]{5}$')  AS distinct_zips
FROM lm_places_usa
GROUP BY 1
ORDER BY 2 DESC;


-- Host extraction matching how ovt_resolve_hosts.py reads a URL: lower-cased,
-- protocol stripped, path, port and credentials discarded.

DROP VIEW IF EXISTS lm_host_v CASCADE;
CREATE VIEW lm_host_v AS
SELECT source,
       lower(rtrim(split_part(split_part(regexp_replace(btrim(websites),
              '^[a-zA-Z][a-zA-Z0-9+.-]*://', '', 'g'), '/', 1), ':', 1), '.')) AS host,
       left(lpad(btrim(coalesce(overture_zip, postcode)), 5, '0'), 5)          AS zip,
       onpremises
FROM lm_places_usa
WHERE websites IS NOT NULL AND btrim(websites) <> '';

DROP VIEW IF EXISTS ovt_host_v CASCADE;
CREATE VIEW ovt_host_v AS
SELECT lower(rtrim(split_part(split_part(regexp_replace(
              btrim(coalesce(substring(websites from '"([^"]*)"'), websites)),
              '^[a-zA-Z][a-zA-Z0-9+.-]*://', '', 'g'), '/', 1), ':', 1), '.')) AS host,
       left(lpad(btrim(overture_zip), 5, '0'), 5)                              AS zip,
       onpremises
FROM ovt_places_usa
WHERE websites IS NOT NULL AND btrim(websites) <> '';


SELECT '=== 2. NEW HOSTS over Overture, per source. This is the new RDAP work. ===' AS section;

SELECT l.source,
       count(DISTINCT l.host)                                          AS hosts,
       count(DISTINCT l.host) FILTER (WHERE o.host IS NULL)            AS hosts_new,
       count(DISTINCT l.host) FILTER (WHERE o.host IS NOT NULL)        AS hosts_overture_already_has
FROM lm_host_v l
LEFT JOIN (SELECT DISTINCT host FROM ovt_host_v) o ON o.host = l.host
WHERE l.host <> ''
GROUP BY 1
ORDER BY 3 DESC;


SELECT '=== 3. ZIP COVERAGE. Upper bound: a ZIP is only usable once a host there is on premises. ===' AS section;

SELECT (SELECT count(DISTINCT zip) FROM ovt_host_v
        WHERE zip ~ '^[0-9]{5}$')                                      AS zips_overture,
       (SELECT count(DISTINCT zip) FROM lm_host_v
        WHERE zip ~ '^[0-9]{5}$')                                      AS zips_new_sources,
       (SELECT count(*) FROM (
            SELECT DISTINCT zip FROM lm_host_v WHERE zip ~ '^[0-9]{5}$'
            EXCEPT
            SELECT DISTINCT zip FROM ovt_host_v WHERE zip ~ '^[0-9]{5}$') x)
                                                                       AS zips_only_in_new;


SELECT '=== 4. THE NUMBER THAT DECIDES IT: ZIPs gaining an on-premises landmark. ===' AS section;
SELECT '    Needs onpremises to have been computed on lm_places_usa.' AS section;

SELECT count(*) AS zips_gained_onpremises
FROM (SELECT DISTINCT zip FROM lm_host_v
      WHERE onpremises IS TRUE AND zip ~ '^[0-9]{5}$'
      EXCEPT
      SELECT DISTINCT zip FROM ovt_host_v
      WHERE onpremises IS TRUE AND zip ~ '^[0-9]{5}$') x;


SELECT '=== 5. SHARED HOSTS WITHIN the new sources: chains and hosting, worst 20. ===' AS section;

SELECT host,
       count(*)                                                        AS places,
       count(DISTINCT zip)                                             AS zips,
       string_agg(DISTINCT source, ',')                                AS sources
FROM lm_host_v
WHERE host <> ''
GROUP BY host
HAVING count(DISTINCT zip) > 1
ORDER BY count(DISTINCT zip) DESC, count(*) DESC
LIMIT 20;


SELECT '=== 6. OVERLAP BETWEEN the new sources themselves (duplicate work). ===' AS section;

SELECT a.source AS source_a, b.source AS source_b,
       count(DISTINCT a.host)                                          AS shared_hosts
FROM (SELECT DISTINCT source, host FROM lm_host_v WHERE host <> '') a
JOIN (SELECT DISTINCT source, host FROM lm_host_v WHERE host <> '') b
     ON b.host = a.host AND b.source > a.source
GROUP BY 1, 2
ORDER BY 3 DESC;
