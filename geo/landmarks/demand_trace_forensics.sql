-- demand_trace_forensics.sql
--
-- What are the 72,755 rows in ip2city_dbiplite_traceroute_tbl?
--
-- =========================================================================
-- THIS FILE WAS REWRITTEN AFTER FAILING, AND THE FAILURE IS THE FINDING
-- =========================================================================
--
-- The first version errored on line 64:
--
--     ERROR:  column "sampled_ip" does not exist
--
-- I took the column list from geo/main.go line 1325, which inserts
-- (network, sampled_ip, last_hop_ip, last_hop_hostname, last_hop_number,
-- hop_count, status, probe_method, mobile_transit, classification_note,
-- attempts, rdap_lookup, ran_at), and assumed the deployed table matched. It
-- does not. That is the third column I have referenced in this project without
-- checking the database first, after rdap_registrant vs rdap_registrant_tbl
-- and a registrant_zip column that has never existed.
--
-- IT ALSO ANSWERS THE QUESTION THE FILE WAS WRITTEN TO ASK. If the deployed
-- table has no sampled_ip, then the current main.go CANNOT have written these
-- rows: its INSERT names a column that is not there and would fail. So the
-- 72,755 rows came from an older build with a different schema, which is
-- consistent with every other oddity:
--
--   status says 'success' where the supply table says 'reached'
--   last_hop_ip is NULL on all 72,755 rows
--   last_hop_hostname is NULL on all 72,755 rows
--   the runs are dated 2026-08-30 to 2026-09-08, months before the current
--   supply-side traces
--
-- That is now a HYPOTHESIS with strong support, not a conclusion. Section 1
-- settles it by reading the actual schema of both tables rather than trusting
-- any source file, and that is what this version does FIRST.
--
-- EVERY OTHER SECTION USES ONLY COLUMNS ALREADY PROVEN TO EXIST, by having
-- been queried successfully in demand_hostname_backfill.sql on 2026-11-06:
-- network, last_hop_ip, last_hop_hostname, status, ran_at. Nothing else is
-- touched until section 1 has printed what is really there.
--
-- READ-ONLY. Nothing is created, altered or dropped.

\timing on
\set ON_ERROR_STOP on

\echo ''
\echo '=== 1 of 4: THE ACTUAL SCHEMA of both traceroute tables ==='
\echo '    Read this before anything else. The demand table is missing at'
\echo '    least sampled_ip, which main.go line 1325 inserts, so the current'
\echo '    build cannot be what wrote these rows.'
SELECT table_name,
       ordinal_position AS pos,
       column_name,
       data_type,
       is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('ip2city_dbiplite_traceroute_tbl', 'ovt_places_usa_ip_trace')
ORDER BY table_name, ordinal_position;

\echo ''
\echo '--- which columns one table has and the other does not ---'
\echo '    The supply table works and the demand table does not, so a column'
\echo '    present only on the supply side is a candidate explanation.'
WITH d AS (SELECT column_name FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'ip2city_dbiplite_traceroute_tbl'),
     s AS (SELECT column_name FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'ovt_places_usa_ip_trace')
SELECT coalesce(d.column_name, s.column_name)                      AS column_name,
       CASE WHEN d.column_name IS NULL THEN 'SUPPLY ONLY'
            WHEN s.column_name IS NULL THEN 'DEMAND ONLY'
            ELSE 'both' END                                        AS presence
FROM d FULL JOIN s ON d.column_name = s.column_name
WHERE d.column_name IS NULL OR s.column_name IS NULL
ORDER BY 2, 1;

\echo ''
\echo '=== 2 of 4: the demand rows, using only proven columns ==='
SELECT coalesce(status, '(null)')                              AS status,
       count(*)                                                AS rows,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)          AS have_last_hop_ip,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)    AS have_hostname,
       count(DISTINCT network)                                 AS distinct_ranges,
       min(ran_at)::date                                       AS earliest,
       max(ran_at)::date                                       AS latest
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 3 of 4: the supply rows for contrast, same proven columns ==='
\echo '    This table works, so its shape is the target. Note the status'
\echo '    vocabulary: reached here, success there, same writer.'
SELECT coalesce(status, '(null)')                              AS status,
       count(*)                                                AS rows,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)          AS have_last_hop_ip,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)    AS have_hostname,
       min(ran_at)::date                                       AS earliest,
       max(ran_at)::date                                       AS latest
FROM public.ovt_places_usa_ip_trace
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 4 of 4: how big a demand trace campaign would be ==='
\echo '    If the answer turns out to be that no trace ever ran, this is the'
\echo '    size of the job. The probe estate is the ceiling; the traceroute'
\echo '    table is what has rows today.'
SELECT (SELECT count(*) FROM ip2city_dbiplite_traceroute_tbl)       AS demand_trace_rows,
       (SELECT count(DISTINCT network) FROM ip2city_dbiplite_traceroute_tbl)
                                                                     AS demand_trace_ranges,
       (SELECT count(*) FROM ip2city_dbiplite_probe_tbl)             AS probe_estate_rows,
       (SELECT count(DISTINCT network) FROM ip2city_dbiplite_probe_tbl)
                                                                     AS probe_estate_ranges;

\echo ''
\echo '    After section 1 prints the real column list, the follow-up that'
\echo '    actually distinguishes a failed trace from no trace is whichever of'
\echo '    hop_count, last_hop_number or attempts turns out to exist. I will'
\echo '    write that query against the printed schema rather than guess at it'
\echo '    a second time.'
\echo ''
\echo '=== done ==='
\timing off
