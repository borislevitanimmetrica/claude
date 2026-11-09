-- demand_hostname_backfill.sql
--
-- THE DEMAND SIDE HAS NO HOSTNAMES AT ALL, and that is the single most
-- actionable thing the Hoiho test found.
--
-- carrier_node_hoiho_test.sql, 2026-11-06:
--
--   supply, ovt_places_usa_ip_trace          30,226 rows, 28,180 with a
--                                            hostname, 7,592 distinct, and
--                                            74.8 pct of those are covered by
--                                            the CAIDA ruleset
--   demand, ip2city_dbiplite_traceroute_tbl  72,755 rows, ZERO with a hostname
--
-- The demand side is the bigger corpus and the one that matters more: it is
-- the node serving a probed customer range, which is exactly what Boris's
-- premise is about. It has no hostnames, so none of the hostname decoding can
-- touch it.
--
-- THIS IS NOT A LIMITATION OF THE APPROACH. geo/main.go writes both tables
-- from the same code path. reverseDNS at line 1310 does a LookupAddr with a
-- 3-second timeout, and writeResult at line 1325 inserts last_hop_hostname
-- into the demand table exactly as line 1377 does for the supply table. So the
-- capability is there and the column is simply empty.
--
-- I DO NOT KNOW WHY, and will not guess. The candidates I can see are that the
-- demand runs predate the hostname capture, that their last_hop_ip is NULL
-- because the traces never reached a node, or that an older binary wrote them.
-- Those call for completely different responses, and section 2 distinguishes
-- them in one query.
--
-- WHY IT MATTERS THAT last_hop_ip MIGHT BE POPULATED. If the addresses are
-- there and only the names are missing, this is a reverse-DNS backfill over
-- at most 72,755 addresses. That is free, unmetered, parallelisable and takes
-- minutes. If last_hop_ip is also NULL, the traces produced nothing to name
-- and the fix is re-running traceroute, which is a different order of cost.
--
-- READ-ONLY. Nothing is created, altered or dropped. The backfill itself is
-- NOT in this file: it needs a resolver, not SQL, and it should not be written
-- until section 2 says it is the right fix.

\timing on
\set ON_ERROR_STOP on

\echo ''
\echo '=== 1 of 3: the demand table, overall shape ==='
SELECT count(*)                                                 AS rows,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)           AS have_last_hop_ip,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)     AS have_hostname,
       count(DISTINCT last_hop_ip)                               AS distinct_node_ips,
       min(ran_at)                                               AS earliest_run,
       max(ran_at)                                               AS latest_run
FROM ip2city_dbiplite_traceroute_tbl;

\echo ''
\echo '=== 2 of 3: THE DECIDING QUERY. status against address and name ==='
\echo '    Read the reached row. If have_last_hop_ip is high and have_hostname'
\echo '    is zero, a reverse-DNS backfill is the whole fix and it is free.'
\echo '    If have_last_hop_ip is also low, the traces never reached a node and'
\echo '    the fix is re-running traceroute instead.'
SELECT coalesce(status, '(null)')                             AS status,
       count(*)                                               AS rows,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)         AS have_last_hop_ip,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)   AS have_hostname,
       count(DISTINCT last_hop_ip)                            AS distinct_node_ips,
       min(ran_at)::date                                      AS earliest,
       max(ran_at)::date                                      AS latest
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 3 of 3: how much Hoiho could reach if the names were there ==='
\echo '    The supply side matched 74.8 pct of its distinct hostnames. These'
\echo '    node addresses are the population a backfill would name, so this is'
\echo '    the ceiling on what the backfill is worth.'
SELECT count(DISTINCT last_hop_ip)                            AS distinct_node_ips_to_resolve,
       count(*)                                               AS rows_they_serve,
       count(DISTINCT network)                                AS distinct_ranges
FROM ip2city_dbiplite_traceroute_tbl
WHERE last_hop_ip IS NOT NULL
  AND last_hop_hostname IS NULL;

\echo ''
\echo '    For comparison, the supply side already has 8,539 distinct node IPs'
\echo '    and 7,592 distinct hostnames, of which 5,680 are Hoiho-covered and'
\echo '    3,169 fall under rules whose hints include CLLI.'
\echo ''
\echo '=== done ==='
\timing off
