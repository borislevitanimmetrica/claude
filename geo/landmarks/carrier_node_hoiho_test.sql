-- carrier_node_hoiho_test.sql
--
-- The feasibility test for using ISP-named nodes instead of landmarks, run
-- against data this project ALREADY holds. Needs hoiho_suffixes.sql loaded
-- first.
--
-- THE PRIOR QUESTION. Before anyone downloads 314 MB of ITDK node files, the
-- thing to establish is how many of OUR carrier-node hostnames the Hoiho
-- ruleset can even speak to. We have them on both sides:
--
--   ovt_places_usa_ip_trace.last_hop_hostname        the supply side, the node
--                                                    adjacent to a landmark
--   ip2city_dbiplite_traceroute_tbl.last_hop_hostname the demand side, the node
--                                                    adjacent to a probed range
--
-- If a large share of those hostnames end in one of the 871 covered suffixes,
-- the ruleset decodes the node location for free. If not, ITDK is irrelevant to
-- us whatever else it contains.
--
-- WHAT THIS CANNOT DO, AND IT MATTERS. CAIDA states the ITDK geolocation is at
-- CITY granularity, README line 158, and the hint types confirm it: 476
-- suffixes key on IATA airport codes and 323 on place names. Boris's premise
-- was that the distribution node for a customer /24 is usually in the same ZIP
-- or an adjacent one. That premise cannot be TESTED with a city-level location,
-- because a city spans many ZIPs. Section 4 therefore reports the one hint type
-- that is finer than a city, CLLI, which names a specific building.
--
-- READ-ONLY. No table is created, altered or dropped.

\timing on
\set ON_ERROR_STOP on
SET work_mem = '512MB';

\echo ''
\echo '=== 0 of 5: do the tables and the ruleset exist? ==='
SELECT r.needed,
       CASE WHEN c.oid IS NULL THEN 'MISSING' ELSE 'present' END AS status
FROM (VALUES ('hoiho_suffixes'),
             ('ovt_places_usa_ip_trace'),
             ('ip2city_dbiplite_traceroute_tbl'),
             ('landmarks_usa')) AS r(needed)
LEFT JOIN pg_class c ON c.relname = r.needed
                    AND c.relnamespace = 'public'::regnamespace
ORDER BY 2, 1;

\echo ''
\echo '=== 1 of 5: the supply side. How many landmark traces have a hostname? ==='
SELECT count(*)                                                  AS trace_rows,
       count(*) FILTER (WHERE status = 'reached')                 AS reached,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)      AS with_hostname,
       count(DISTINCT last_hop_hostname)                          AS distinct_hostnames,
       count(DISTINCT last_hop_ip)                                AS distinct_node_ips
FROM public.ovt_places_usa_ip_trace;

\echo ''
\echo '=== 2 of 5: THE ANSWER. supply-side hostnames by Hoiho coverage ==='
\echo '    A hostname is covered when it ends in .<domain> for one of the 871'
\echo '    suffixes, or equals it. Longest suffix wins, so comcastbusiness.net'
\echo '    does not get credited to comcast.net.'
WITH h AS (
    SELECT DISTINCT lower(btrim(last_hop_hostname)) AS hostname
    FROM public.ovt_places_usa_ip_trace
    WHERE last_hop_hostname IS NOT NULL
      AND btrim(last_hop_hostname) <> ''
), m AS (
    SELECT h.hostname, s.domain, s.klass, s.ppv, s.hint_types
    FROM h
    LEFT JOIN LATERAL (
        SELECT domain, klass, ppv, hint_types
        FROM hoiho_suffixes
        WHERE h.hostname = domain OR h.hostname LIKE '%.' || domain
        ORDER BY length(domain) DESC
        LIMIT 1
    ) s ON true
)
SELECT count(*)                                              AS distinct_hostnames,
       count(*) FILTER (WHERE domain IS NOT NULL)            AS hoiho_covered,
       round(100.0 * count(*) FILTER (WHERE domain IS NOT NULL)
             / greatest(count(*), 1), 1)                     AS pct_covered,
       count(*) FILTER (WHERE klass = 'good')                AS covered_good_class,
       count(*) FILTER (WHERE hint_types LIKE '%clli%')      AS covered_by_clli_rules,
       count(*) FILTER (WHERE hint_types LIKE '%iata%'
                           OR hint_types LIKE '%place%')     AS covered_city_only
FROM m;

\echo ''
\echo '--- which suffixes, and how much of our data each one explains ---'
WITH h AS (
    SELECT lower(btrim(last_hop_hostname)) AS hostname, count(*) AS traces
    FROM public.ovt_places_usa_ip_trace
    WHERE last_hop_hostname IS NOT NULL AND btrim(last_hop_hostname) <> ''
    GROUP BY 1
)
SELECT s.domain, s.klass, s.ppv, s.hint_types,
       count(*)       AS distinct_hostnames,
       sum(h.traces)  AS traces
FROM h
JOIN LATERAL (
    SELECT domain, klass, ppv, hint_types
    FROM hoiho_suffixes
    WHERE h.hostname = domain OR h.hostname LIKE '%.' || domain
    ORDER BY length(domain) DESC
    LIMIT 1
) s ON true
GROUP BY s.domain, s.klass, s.ppv, s.hint_types
ORDER BY traces DESC
LIMIT 30;

\echo ''
\echo '--- and the UNCOVERED suffixes, which is the gap to close by hand ---'
\echo '    Read the registrable part. A big uncovered operator here is a'
\echo '    candidate for writing one rule, not for abandoning the approach.'
WITH h AS (
    SELECT lower(btrim(last_hop_hostname)) AS hostname, count(*) AS traces
    FROM public.ovt_places_usa_ip_trace
    WHERE last_hop_hostname IS NOT NULL AND btrim(last_hop_hostname) <> ''
    GROUP BY 1
), u AS (
    SELECT h.hostname, h.traces
    FROM h
    WHERE NOT EXISTS (SELECT 1 FROM hoiho_suffixes s
                      WHERE h.hostname = s.domain
                         OR h.hostname LIKE '%.' || s.domain)
)
SELECT substring(hostname from '([^.]+\.[^.]+)$') AS registrable,
       count(*)                                   AS distinct_hostnames,
       sum(traces)                                AS traces
FROM u
GROUP BY 1
ORDER BY traces DESC
LIMIT 30;

\echo ''
\echo '=== 3 of 5: the demand side, the same question ==='
SELECT count(*)                                             AS trace_rows,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL) AS with_hostname,
       count(DISTINCT last_hop_hostname)                     AS distinct_hostnames
FROM ip2city_dbiplite_traceroute_tbl;

\echo ''
WITH h AS (
    SELECT DISTINCT lower(btrim(last_hop_hostname)) AS hostname
    FROM ip2city_dbiplite_traceroute_tbl
    WHERE last_hop_hostname IS NOT NULL AND btrim(last_hop_hostname) <> ''
)
SELECT count(*)                                        AS distinct_hostnames,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM hoiho_suffixes s
           WHERE h.hostname = s.domain
              OR h.hostname LIKE '%.' || s.domain))    AS hoiho_covered,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM hoiho_suffixes s
           WHERE s.hint_types LIKE '%clli%'
             AND (h.hostname = s.domain
               OR h.hostname LIKE '%.' || s.domain)))   AS covered_by_clli_rules
FROM h;

\echo ''
\echo '=== 4 of 5: the CLLI subset, the only path finer than a city ==='
\echo '    89 suffixes encode a CLLI code, which names a BUILDING: 4 characters'
\echo '    of place, 2 of state, 2 of building. These are the big consumer ISPs,'
\echo '    which is exactly where the uncovered demand sits.'
SELECT domain, klass, ppv, routers, hint_types
FROM hoiho_suffixes
WHERE hint_types LIKE '%clli%'
ORDER BY routers DESC
LIMIT 25;

\echo ''
\echo '=== 5 of 5: can a CLLI be turned into a ZIP? THAT IS THE OPEN QUESTION ==='
\echo ''
\echo '    A CLLI code identifies a building but says nothing about where the'
\echo '    building is. The place-and-state prefix gives a town, which is no'
\echo '    better than the city-level hints. Getting a ZIP needs a CLLI to'
\echo '    street-address table, and the authoritative one is the LERG, which'
\echo '    is proprietary to iconectiv.'
\echo ''
\echo '    MEASURED public alternatives, 2026-11-06:'
\echo '      OSM key clli                 1,275 objects WORLDWIDE'
\echo '      OSM telecom=central_office      61 objects WORLDWIDE'
\echo '      OSM telecom=exchange        25,681 objects worldwide, and OSM'
\echo '                                  telecom mapping is concentrated in'
\echo '                                  Europe. The US share is UNMEASURED,'
\echo '                                  because Overpass was unreachable from'
\echo '                                  the sandbox that produced this file'
\echo ''
\echo '    Against roughly 20,000 to 25,000 US wire centres, 61 central offices'
\echo '    and 1,275 CLLI tags worldwide is not a source. Boris own caveat was'
\echo '    right, and it is worse than feared: the tags barely exist at all.'
\echo ''
\echo '    So the honest position is that hostname decoding reaches CITY for'
\echo '    free and BUILDING IDENTITY for the big consumer ISPs, and the step'
\echo '    from building identity to ZIP has no public source I have verified.'
\echo '    Section 2 says whether that is worth pursuing, because if our'
\echo '    hostnames are not covered then none of it applies.'
\echo ''
\echo '=== done ==='
\timing off
