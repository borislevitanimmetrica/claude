-- demand_trace_forensics.sql
--
-- The backfill question came back worse than either branch I offered. Now
-- establish what those 72,755 rows actually are before anyone spends a trace.
--
-- WHAT demand_hostname_backfill.sql FOUND, 2026-11-06:
--
--   rows                72,755
--   status success      72,748
--   status error             7
--   have_last_hop_ip         0
--   have_hostname            0
--   distinct_node_ips        0
--   runs                2026-08-30 to 2026-09-08
--
-- So it is not that the names are missing. THE LAST HOP ADDRESS IS MISSING
-- TOO, on every row, while the status says success on 72,748 of them. A
-- reverse-DNS backfill is therefore impossible: there is nothing to reverse.
--
-- AND THE STATUS VOCABULARY DIFFERS BETWEEN THE TWO TABLES, which is itself a
-- clue. ovt_places_usa_ip_trace uses 'reached', 21,314 of its 30,226 rows.
-- This table uses 'success'. Same writer, geo/main.go, so either the vocabulary
-- changed between the two runs or these rows were written by a different code
-- path that reused the table.
--
-- I DO NOT KNOW WHICH AND AM NOT GUESSING. The columns that distinguish them
-- are already there. hop_count separates the two cases cleanly:
--
--   hop_count POPULATED, last_hop_ip NULL   a traceroute ran and the
--                                           classifier found no usable carrier
--                                           hop. The fix is in the classifier
--                                           or the backtrack window, not in
--                                           re-probing
--   hop_count NULL                          no traceroute ran. These rows came
--                                           from something else that writes
--                                           this table, and the fix is to run
--                                           the traceroute for the first time
--
-- probe_method and classification_note name the writer directly, which is why
-- they are the first thing this file prints.
--
-- WHY THIS MATTERS BEFORE SPENDING ANYTHING. 72,755 traceroutes is not free,
-- and the supply side's 30,226 took whatever it took. Establishing that the
-- rows are empty for a fixable reason, rather than because nothing was ever
-- traced, decides whether this is a code change or a measurement campaign.
--
-- READ-ONLY. Nothing is created, altered or dropped.

\timing on
\set ON_ERROR_STOP on

\echo ''
\echo '=== 1 of 5: who wrote these rows? probe_method names the writer ==='
SELECT coalesce(probe_method, '(null)')                        AS probe_method,
       coalesce(status, '(null)')                              AS status,
       count(*)                                                AS rows,
       count(*) FILTER (WHERE hop_count IS NOT NULL)            AS have_hop_count,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)          AS have_last_hop_ip,
       count(*) FILTER (WHERE sampled_ip IS NOT NULL)           AS have_sampled_ip,
       min(ran_at)::date                                       AS earliest,
       max(ran_at)::date                                       AS latest
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1, 2
ORDER BY 3 DESC;

\echo ''
\echo '=== 2 of 5: THE DECIDING COLUMN. did a traceroute run at all? ==='
\echo '    hop_count populated means a trace ran and found no usable carrier'
\echo '    hop, which is a classifier problem. hop_count NULL means no trace'
\echo '    ran, which is a measurement problem. They cost very different things.'
SELECT count(*)                                                AS rows,
       count(*) FILTER (WHERE hop_count IS NOT NULL)            AS trace_ran,
       count(*) FILTER (WHERE hop_count IS NULL)                AS no_trace_ran,
       count(*) FILTER (WHERE last_hop_number IS NOT NULL)      AS have_last_hop_number,
       count(*) FILTER (WHERE attempts IS NOT NULL)             AS have_attempts,
       count(*) FILTER (WHERE rdap_lookup IS NOT NULL)          AS have_rdap_lookup,
       count(*) FILTER (WHERE mobile_transit IS NOT NULL)       AS have_mobile_transit
FROM ip2city_dbiplite_traceroute_tbl;

\echo ''
\echo '--- hop_count distribution, if any rows have one ---'
SELECT hop_count, count(*) AS rows
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1
ORDER BY 1 NULLS FIRST
LIMIT 20;

\echo ''
\echo '=== 3 of 5: what classification_note says, which is free prose ==='
SELECT coalesce(left(classification_note, 60), '(null)')  AS classification_note,
       count(*)                                           AS rows
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1
ORDER BY 2 DESC
LIMIT 15;

\echo ''
\echo '=== 4 of 5: the supply table for contrast, same columns ==='
\echo '    This one works, so its shape is the target.'
SELECT coalesce(probe_method, '(null)')                        AS probe_method,
       coalesce(status, '(null)')                              AS status,
       count(*)                                                AS rows,
       count(*) FILTER (WHERE hop_count IS NOT NULL)            AS have_hop_count,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)          AS have_last_hop_ip,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)    AS have_hostname,
       min(ran_at)::date                                       AS earliest,
       max(ran_at)::date                                       AS latest
FROM public.ovt_places_usa_ip_trace
GROUP BY 1, 2
ORDER BY 3 DESC;

\echo ''
\echo '=== 5 of 5: how many ranges would a real demand trace have to cover? ==='
\echo '    The 72,755 rows here against the full probe estate. If the demand'
\echo '    trace has to run from scratch, this is the size of the campaign.'
SELECT (SELECT count(*) FROM ip2city_dbiplite_traceroute_tbl)       AS rows_in_demand_trace_tbl,
       (SELECT count(DISTINCT network) FROM ip2city_dbiplite_traceroute_tbl)
                                                                     AS distinct_ranges_covered,
       (SELECT count(*) FROM ip2city_dbiplite_probe_tbl)             AS probe_estate_rows,
       (SELECT count(DISTINCT network) FROM ip2city_dbiplite_probe_tbl)
                                                                     AS probe_estate_ranges;

\echo ''
\echo '=== done ==='
\timing off
