-- landmark_gaps.sql - what is missing, at every stage.
--
-- Four questions, in the order they gate each other. Any row that fails an
-- earlier stage cannot reach a later one, so read top to bottom.
--
--   imported   is it in landmarks_usa at all
--   resolved   does its website have an IP
--   RDAP       has that IP been looked up
--   located    does it have a ZIP, and an onpremises verdict
--
-- Written to be re-run at any time. Nothing here mutates.

SELECT '=== 1. NOT IMPORTED: in a source table but not in landmarks_usa ===' AS section;

SELECT 'overture' AS source,
       (SELECT count(*) FROM ovt_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''
          AND btrim(coalesce(substring(websites from '"([^"]*)"'), websites)) <> '')
                                                                  AS eligible,
       (SELECT count(*) FROM landmarks_usa WHERE source = 'overture')
                                                                  AS imported
UNION ALL
SELECT 'foursquare',
       (SELECT count(*) FROM fsq_places_usa
        WHERE websites IS NOT NULL AND btrim(websites) <> ''),
       (SELECT count(*) FROM landmarks_usa WHERE source = 'foursquare')
UNION ALL
SELECT l.source,
       (SELECT count(*) FROM lm_places_usa x
        WHERE x.source = l.source AND x.websites IS NOT NULL
          AND btrim(x.websites) <> ''),
       (SELECT count(*) FROM landmarks_usa y WHERE y.source = l.source)
FROM (SELECT DISTINCT source FROM lm_places_usa) l
ORDER BY 1;


SELECT '=== 2. PER-STAGE GAPS inside landmarks_usa ===' AS section;

SELECT source,
       count(*)                                                        AS rows,
       count(*) FILTER (WHERE ip_address IS NULL
                          AND lookup_status IS DISTINCT FROM 'does not resolve'
                          AND lookup_status IS DISTINCT FROM 'no_website')
                                                                       AS awaiting_resolve,
       count(*) FILTER (WHERE ip_address IS NOT NULL
                          AND lookup_status IS NULL)                   AS awaiting_rdap,
       count(*) FILTER (WHERE lookup_status = 'true'
                          AND overture_zip IS NULL)                    AS awaiting_zip,
       count(*) FILTER (WHERE lookup_status = 'true'
                          AND onpremises IS NULL)                      AS awaiting_onpremises,
       count(*) FILTER (WHERE onpremises IS TRUE)                       AS onpremises_true
FROM landmarks_usa
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 3. WHY rows did not become landmarks, by lookup_status ===' AS section;

SELECT coalesce(lookup_status, '(not yet looked up)')                  AS lookup_status,
       count(*)                                                        AS rows,
       count(DISTINCT host(ip_address))                                AS distinct_ips,
       count(*) FILTER (WHERE onpremises IS TRUE)                       AS onpremises_true
FROM landmarks_usa
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 4. RETRYABLE RDAP failures. These are worth another pass. ===' AS section;
SELECT '    outside ARIN is NOT retryable: the IP belongs to another registry.' AS section;

SELECT lookup_status,
       count(*)                                                        AS rows,
       count(DISTINCT host(ip_address))                                AS distinct_ips,
       CASE WHEN lookup_status IN ('lookup error', 'registrant not found')
                 THEN 'retry: ovt_resolve_hosts.py rdap --retry-failed'
            WHEN lookup_status = 'outside ARIN'
                 THEN 'not retryable against ARIN; needs RIPE/APNIC/LACNIC/AFRINIC'
            WHEN lookup_status = 'does not resolve'
                 THEN 'website host has no public IPv4; nothing to retry'
            ELSE 'no action' END                                       AS action
FROM landmarks_usa
WHERE lookup_status IN ('lookup error', 'registrant not found',
                        'outside ARIN', 'does not resolve', 'placeholder IP')
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 5. THE LANDMARKS THEMSELVES: distinct addresses to probe ===' AS section;

SELECT count(*)                                                        AS onpremises_places,
       count(DISTINCT host(ip_address))                                AS distinct_addresses,
       count(DISTINCT overture_zip)                                    AS distinct_zips,
       round(count(*)::numeric
             / nullif(count(DISTINCT host(ip_address)), 0), 1)          AS places_per_address
FROM landmarks_usa
WHERE onpremises IS TRUE AND overture_zip ~ '^[0-9]{5}$';


SELECT '=== 6. ZIP COVERAGE, and what each source adds ===' AS section;

WITH z AS (
    SELECT DISTINCT source, overture_zip AS zip
    FROM landmarks_usa
    WHERE onpremises IS TRUE AND overture_zip ~ '^[0-9]{5}$'
)
SELECT a.source,
       count(*)                                                        AS zips,
       count(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM z b WHERE b.zip = a.zip AND b.source <> a.source))
                                                                       AS zips_unique_to_source
FROM z a
GROUP BY 1
ORDER BY 3 DESC;


SELECT '=== 7. TRACE COVERAGE: how many landmark addresses have a carrier node ===' AS section;

SELECT count(DISTINCT host(l.ip_address))                              AS onprem_addresses,
       count(DISTINCT host(l.ip_address)) FILTER (WHERE t.ip IS NOT NULL)
                                                                       AS traced,
       count(DISTINCT host(l.ip_address)) FILTER (WHERE t.ip IS NULL)   AS not_traced,
       count(DISTINCT host(l.ip_address)) FILTER (WHERE t.status LIKE 'reached%')
                                                                       AS reached_a_node
FROM landmarks_usa l
LEFT JOIN ovt_places_usa_ip_trace t ON t.ip = l.ip_address
WHERE l.onpremises IS TRUE AND l.overture_zip ~ '^[0-9]{5}$';
