-- hosting_rule_reconciliation.sql
--
-- READ-ONLY. Settles whether 16,161 ZIPs is a real figure or a pre-hosting-rule
-- one, which decides whether everything Session 4 concluded about coverage
-- needs restating.
--
--
-- THE CONTRADICTION
--
-- geo/sessions/TruGeo_Session_4_handoff.md states:
--
--     ZIPs with an on-premises landmark            9,728
--     on-premises places after hosting rule       65,148
--     The last stored on-premises count, 132,125 places, is a PRE-hosting-rule
--     figure, and address_hosting_tbl is stale, built when the count was
--     120,352.
--     Earlier figures of about 15,954 ZIPs and 36 percent were measured BEFORE
--     the hosting rule was applied and are too high. The hosting rule roughly
--     halved the landmark set.
--
-- Session 4 measured 134,292 places and 16,161 ZIPs on 2026-11-12 and used them
-- as current in every coverage conclusion, including the 48.99 per cent figure,
-- the 16,238-ZIP funnel bucket and the whole deduplication table. 134,292 is the
-- direct successor of the 132,125 that memo flags, and 16,161 is within rounding
-- of the 15,954 it calls too high. Nothing in Session 4 checked it, despite the
-- memo warning about this exact confusion in its own words.
--
--
-- HOW THE TWO PIECES FIT, VERIFIED FROM THE SOURCE
--
-- node_fanout.sql builds address_hosting_tbl with CREATE TABLE AS, selecting
-- FROM landmarks_usa WHERE onpremises = true. So the table only ever contains
-- addresses that were on-premises AT BUILD TIME. An address that became
-- on-premises afterwards is absent, and the rule cannot have judged it. That
-- is the precise mechanism of the staleness, not a vague freshness worry.
--
-- Its verdict column is 'hosting: too wide to cluster', 'hosting: N disjoint
-- areas', 'on-premises: single zip' or 'on-premises: one contiguous area'.
--
-- onpremises_hosting_rule.sql then sets onpremises = false and writes
-- onpremises_reason = 'hosting: address serves disjoint ZIP clusters (...)' for
-- every address whose verdict is LIKE 'hosting%'. Its guard is
--
--     AND (l.onpremises IS DISTINCT FROM false
--          OR l.onpremises_reason IS NULL
--          OR l.onpremises_reason NOT LIKE 'hosting:%')
--
-- so the rule is idempotent and a row already marked stays marked.
--
-- THEREFORE there are exactly three populations, and this file counts them:
--
--   DECIDED, HOSTING    already false with a 'hosting:' reason. The rule ran on
--                       these and they are correctly excluded.
--   PENDING             currently TRUE, on an address address_hosting_tbl marks
--                       'hosting%'. The rule would flip these. If this is large,
--                       the rule has not been re-run and Session 4 is overstated.
--   UNJUDGED            currently TRUE, on an address ABSENT from
--                       address_hosting_tbl. No verdict exists. node_fanout.sql
--                       has to be rebuilt before anything can decide these, and
--                       until then their contribution to coverage is UNKNOWN,
--                       not merely unverified.
--
-- The third is the one that cannot be resolved by arithmetic here, and I am not
-- going to estimate it.
--
--
-- HOW TO RUN, AND WHAT IT COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f hosting_rule_reconciliation.sql
--
-- ESTIMATE, labelled as one: one to three minutes. Basis, measured on this
-- data: the on-premises set is 134,292 rows and is served by
-- landmarks_usa_onprem_zip_idx, address_hosting_tbl is a few hundred thousand
-- rows at most, and both sides are reduced to indexed temp tables before any
-- join. No correlated subquery runs against an unindexed table.
--
-- Read-only. Temp tables only, dropped at the end. Ctrl-C costs nothing.

\timing on
\pset pager off
SET client_min_messages = warning;

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND ((table_name = 'landmarks_usa'
        AND column_name IN ('onpremises', 'onpremises_reason', 'ip_address',
                            'overture_zip', 'source'))
    OR table_name = 'address_hosting_tbl')
ORDER BY table_name, column_name;

\echo ''
\echo 'landmarks_usa must show 5 columns and address_hosting_tbl must show at'
\echo 'least ip_address and verdict. If address_hosting_tbl returns NOTHING it'
\echo 'has never been built on this database, and that alone resolves the'
\echo 'question: the hosting rule cannot have run at all.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. WHAT THE TWO TABLES HOLD NOW.'
\echo '================================================================'
\echo ''

SELECT count(*)                                                   AS onpremises_true,
       count(DISTINCT left(btrim(overture_zip), 5))                AS distinct_zips,
       count(*) FILTER (WHERE ip_address IS NULL)                  AS true_but_no_ip
FROM landmarks_usa
WHERE onpremises IS TRUE;

\echo ''
\echo 'Compare onpremises_true against 134,292 from 2026-11-12, against 132,125'
\echo 'which the memo calls pre-hosting-rule, and against 65,148 which it calls'
\echo 'post-rule. Compare distinct_zips against 16,161, 15,954 and 9,728.'
\echo ''

\echo 'Rows the hosting rule has already excluded:'
SELECT count(*) AS onpremises_false_by_hosting_rule
FROM landmarks_usa
WHERE onpremises IS FALSE
  AND onpremises_reason LIKE 'hosting:%';

\echo ''
\echo 'address_hosting_tbl by verdict. places is as recorded AT BUILD TIME and'
\echo 'is not a current count.'
SELECT verdict,
       count(*)      AS addresses,
       sum(places)   AS places_at_build_time
FROM address_hosting_tbl
GROUP BY verdict
ORDER BY count(*) DESC;


\echo ''
\echo '================================================================'
\echo ' 2. THE THREE POPULATIONS. THIS IS THE ANSWER.'
\echo '================================================================'
\echo ''

DROP TABLE IF EXISTS tmp_hosting_addr;
CREATE UNLOGGED TABLE tmp_hosting_addr AS
SELECT DISTINCT host(ip_address) AS addr
FROM address_hosting_tbl
WHERE verdict LIKE 'hosting%';
CREATE INDEX ON tmp_hosting_addr (addr);

DROP TABLE IF EXISTS tmp_judged_addr;
CREATE UNLOGGED TABLE tmp_judged_addr AS
SELECT DISTINCT host(ip_address) AS addr
FROM address_hosting_tbl;
CREATE INDEX ON tmp_judged_addr (addr);

DROP TABLE IF EXISTS tmp_onprem;
CREATE UNLOGGED TABLE tmp_onprem AS
SELECT host(l.ip_address)                AS addr,
       left(btrim(l.overture_zip), 5)    AS zip,
       l.source
FROM landmarks_usa l
WHERE l.onpremises IS TRUE
  AND l.ip_address IS NOT NULL;
CREATE INDEX ON tmp_onprem (addr);

ANALYZE tmp_hosting_addr;
ANALYZE tmp_judged_addr;
ANALYZE tmp_onprem;

SELECT (SELECT count(*) FROM tmp_hosting_addr) AS hosting_addresses_known,
       (SELECT count(*) FROM tmp_judged_addr)  AS addresses_with_any_verdict,
       (SELECT count(*) FROM tmp_onprem)       AS onpremises_rows_with_an_ip;

\echo ''
\echo 'Now the split:'

SELECT CASE
         WHEN h.addr IS NOT NULL THEN 'PENDING   would be flipped to false by the rule'
         WHEN j.addr IS NOT NULL THEN 'CLEARED   judged, and judged on-premises'
         ELSE                         'UNJUDGED  address absent from address_hosting_tbl'
       END AS population,
       count(*)                  AS places,
       count(DISTINCT o.zip)     AS distinct_zips,
       count(DISTINCT o.addr)    AS distinct_addresses
FROM tmp_onprem o
LEFT JOIN tmp_hosting_addr h ON h.addr = o.addr
LEFT JOIN tmp_judged_addr  j ON j.addr = o.addr
GROUP BY 1
ORDER BY 1;

\echo ''
\echo 'READ THIS FIRST. If PENDING is large, the hosting rule has NOT been'
\echo 'applied to the current set, 134,292 and 16,161 are pre-rule figures, and'
\echo 'every coverage number from Session 4 is overstated. If PENDING is zero or'
\echo 'tiny, the rule IS applied and the memo figures of 65,148 and 9,728 are'
\echo 'the stale ones.'
\echo ''
\echo 'UNJUDGED is the part arithmetic cannot settle. Those addresses have no'
\echo 'verdict because address_hosting_tbl was built from an older on-premises'
\echo 'set and they were not in it. Their true contribution to coverage is'
\echo 'UNKNOWN until node_fanout.sql is rebuilt. I am not estimating it.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. WHAT COVERAGE WOULD BE IF THE RULE WERE APPLIED AS IT STANDS.'
\echo '================================================================'
\echo ''
\echo 'Removing only the PENDING rows. This is a LOWER BOUND on the damage,'
\echo 'because the UNJUDGED addresses have not been tested at all and some of'
\echo 'them will also turn out to be hosting once node_fanout.sql is rebuilt.'
\echo ''

SELECT count(*)                                     AS places_after_rule,
       count(DISTINCT o.zip)                        AS zips_after_rule,
       (SELECT count(DISTINCT zip) FROM tmp_onprem) AS zips_now,
       (SELECT count(DISTINCT zip) FROM tmp_onprem)
         - count(DISTINCT o.zip)                    AS zips_that_would_be_lost
FROM tmp_onprem o
WHERE NOT EXISTS (SELECT 1 FROM tmp_hosting_addr h WHERE h.addr = o.addr);

\echo ''
\echo 'zips_after_rule is the number that should have been quoted all session'
\echo 'if PENDING is non-zero. Compare it against the 9,728 in the memo.'
\echo ''

\echo 'Which sources carry the PENDING rows, so the damage is attributable:'
SELECT o.source,
       count(*)              AS pending_places,
       count(DISTINCT o.zip) AS pending_zips
FROM tmp_onprem o
JOIN tmp_hosting_addr h ON h.addr = o.addr
GROUP BY o.source
ORDER BY count(*) DESC
LIMIT 15;


\echo ''
\echo '================================================================'
\echo ' 4. HOW STALE address_hosting_tbl IS, IN ADDRESSES NOT ROWS.'
\echo '================================================================'
\echo ''

SELECT (SELECT count(DISTINCT addr) FROM tmp_onprem)                       AS onprem_addresses_now,
       (SELECT count(*) FROM tmp_judged_addr)                              AS addresses_judged,
       (SELECT count(DISTINCT o.addr) FROM tmp_onprem o
         WHERE NOT EXISTS (SELECT 1 FROM tmp_judged_addr j WHERE j.addr = o.addr))
                                                                           AS onprem_addresses_NEVER_judged,
       (SELECT count(*) FROM tmp_judged_addr j
         WHERE NOT EXISTS (SELECT 1 FROM tmp_onprem o WHERE o.addr = j.addr))
                                                                           AS judged_but_no_longer_onprem;

\echo ''
\echo 'onprem_addresses_NEVER_judged is the size of the rebuild needed. The memo'
\echo 'records address_hosting_tbl as built when the on-premises count was'
\echo '120,352, so a non-trivial figure here is expected and confirms it rather'
\echo 'than contradicting it.'
\echo ''
\echo 'judged_but_no_longer_onprem is the opposite drift: addresses the table'
\echo 'still carries that have since stopped being on-premises. Harmless to'
\echo 'coverage, but it means the places column in section 1 overstates.'
\echo ''

DROP TABLE IF EXISTS tmp_onprem;
DROP TABLE IF EXISTS tmp_judged_addr;
DROP TABLE IF EXISTS tmp_hosting_addr;

\echo 'Done. Nothing was modified.'
\echo ''
