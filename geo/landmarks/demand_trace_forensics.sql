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
-- AND THEN THE SCHEMA DUMP REVERSED MY EXPLANATION, so both versions are
-- recorded here rather than the wrong one being quietly replaced.
--
-- What I said: the deployed table has no sampled_ip, so the current main.go
-- cannot have written these rows, so they came from an older build.
--
-- What the schema actually shows: ordinal_position on the demand table runs
-- 1, 3, 4, 5 ... 16, 18, 19 ... There are GAPS AT POSITIONS 2 AND 17.
-- PostgreSQL preserves the attnum of a dropped column, so a gap in
-- ordinal_position means a column was DROPPED, not that it never existed.
-- Position 2 is immediately after `network`, which is exactly where
-- `sampled_ip` sits in the INSERT at geo/main.go line 1325.
--
-- VERIFIED: two columns were dropped from the demand table, at positions 2
-- and 17. INFERENCE, and labelled as one: position 2 was `sampled_ip`, on the
-- strength of main.go's column order. I have not confirmed the dropped name,
-- and `information_schema` cannot tell me because it does not list dropped
-- columns; `pg_attribute` with `attisdropped` would.
--
-- So the direction is the opposite of what I claimed. The column existed when
-- the rows were written and was dropped afterwards, which means the writer may
-- have been perfectly compatible and the schema changed under it. That makes
-- the remaining oddities need a different explanation than "older build":
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
\echo '=== 3 of 4: the supply rows for contrast ==='
\echo '    CORRECTED. This section first used ran_at, which this table does'
\echo '    not have: it uses traced_at. Section 1 printed exactly that, as'
\echo '    "ran_at DEMAND ONLY" and "traced_at SUPPLY ONLY", two queries'
\echo '    earlier in this same file, and I still wrote ran_at. Columns proven'
\echo '    on one table are proven for THAT TABLE ONLY.'
SELECT coalesce(status, '(null)')                              AS status,
       count(*)                                                AS rows,
       count(*) FILTER (WHERE last_hop_ip IS NOT NULL)          AS have_last_hop_ip,
       count(*) FILTER (WHERE last_hop_hostname IS NOT NULL)    AS have_hostname,
       min(traced_at)::date                                    AS earliest,
       max(traced_at)::date                                    AS latest
FROM public.ovt_places_usa_ip_trace
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 3b of 4: WHAT IS ACTUALLY POPULATED on the 72,755 demand rows ==='
\echo '    Now written against the real column list from section 1 rather than'
\echo '    from main.go. The demand table carries ip-api response fields that'
\echo '    the supply table does not have at all: city, zip, lat, lon, isp,'
\echo '    org, as, query, plus city_target and state_target. If those are'
\echo '    populated while the traceroute columns are empty, these rows are'
\echo '    ip-api lookups and not traces, and status success means the ip-api'
\echo '    call succeeded.'
SELECT count(*)                                                     AS rows,
       count(*) FILTER (WHERE hop_count IS NOT NULL)                 AS have_hop_count,
       count(*) FILTER (WHERE last_hop_number IS NOT NULL)           AS have_last_hop_number,
       count(*) FILTER (WHERE attempts IS NOT NULL)                  AS have_attempts,
       count(*) FILTER (WHERE probe_method IS NOT NULL)              AS have_probe_method,
       count(*) FILTER (WHERE classification_note IS NOT NULL)       AS have_class_note,
       count(*) FILTER (WHERE rdap_lookup IS NOT NULL)               AS have_rdap_lookup
FROM ip2city_dbiplite_traceroute_tbl;

\echo ''
\echo '--- and the ip-api side of the same rows ---'
SELECT count(*)                                                     AS rows,
       count(*) FILTER (WHERE btrim(coalesce(zip, '')) <> '')        AS have_zip,
       count(*) FILTER (WHERE btrim(coalesce(city, '')) <> '')       AS have_city,
       count(*) FILTER (WHERE btrim(coalesce(isp, '')) <> '')        AS have_isp,
       count(*) FILTER (WHERE btrim(coalesce(org, '')) <> '')        AS have_org,
       count(*) FILTER (WHERE btrim(coalesce("as", '')) <> '')       AS have_as,
       count(*) FILTER (WHERE lat IS NOT NULL)                       AS have_lat,
       count(*) FILTER (WHERE btrim(coalesce(city_target, '')) <> '') AS have_city_target
FROM ip2city_dbiplite_traceroute_tbl;

\echo ''
\echo '--- probe_method, which names what ran ---'
SELECT coalesce(probe_method, '(null)')        AS probe_method,
       coalesce(status, '(null)')              AS status,
       count(*)                                AS rows,
       count(*) FILTER (WHERE is_infrastructure)              AS is_infrastructure,
       count(*) FILTER (WHERE is_unreachable_local_carrier)    AS unreachable_local_carrier
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1, 2
ORDER BY 3 DESC;

\echo ''
\echo '--- classification_note, free prose from the writer ---'
SELECT coalesce(left(classification_note, 64), '(null)')  AS classification_note,
       count(*)                                           AS rows
FROM ip2city_dbiplite_traceroute_tbl
GROUP BY 1
ORDER BY 2 DESC
LIMIT 15;

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
