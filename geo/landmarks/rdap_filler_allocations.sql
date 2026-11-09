-- rdap_filler_allocations.sql
--
-- READ-ONLY. REPORTS ONLY. Deletes nothing, and prints the DELETE it would
-- recommend rather than running it, because that DELETE has consequences that
-- must be decided and not stumbled into. See the pre-mortem in section 4.
--
--
-- WHAT THE SAMPLE FOUND
--
-- verify-sample, 200 candidates, measured 2026-11-09 07:20 to 07:24:
--
--     200 answered, 0 failed
--     153 identical to the cached allocation
--      47 NARROWER than the cached allocation   (23.50 per cent)
--       0 neither
--      39 of the 47 carried a different registrant
--       0 of the 153 identical ones had a changed registrant
--
-- Reading the 39 rather than just counting them, the worst cases are not
-- ordinary ISP sub-assignments. They are enormous registry-level rows that
-- retire vast numbers of candidates while naming nobody useful:
--
--     192.0.0.0-192.255.255.255  "Internet Assigned Numbers Authority"
--                                hid  "University of Texas System"  at 192.88.12.0/23
--     107.0.0.0-107.255.255.255  "American Registry for Internet Numbers"
--                                hid  "Verizon Business"            at 107.191.130.0/23
--     149.0.0.0-149.255.255.255  "Various Registries (Maintained by ARIN)"
--                                hid  "Alibaba Cloud (Singapore)"   at 149.129.176.0/20
--     151.0.0.0-151.255.255.255  ""  (an EMPTY registrant)
--                                hid  "Company 686e3fc0PcE0Mutj"    at 151.246.8.0/21
--
-- A /8 is 16,777,216 addresses. One such row retires every candidate in that
-- /8 and answers the exclusion question with the name of a registry.
--
-- THIS IS NOT CAUGHT TODAY. geo/rdap_registrant_repair.sql deletes filler by
-- name, but its pattern list is MNT-%, %-MNT, %-MAINT,
-- %MANAGED-ADDRESS-BLOCK%, %NON-RIPE-NCC%, %AVAILABLE%, %IANA-BLK%,
-- %RESERVED%. None of those match "Internet Assigned Numbers Authority",
-- "American Registry for Internet Numbers", "Various Registries (Maintained by
-- ARIN)", or an empty string. So these rows survive every repair run.
--
--
-- HOW TO RUN, AND WHAT IT ACTUALLY COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f rdap_filler_allocations.sql
--
-- I wrote "seconds, not minutes" here as though it were a fact. MEASURED
-- 2026-11-09 on the real data:
--
--   section 1    1 minute 36 seconds
--   section 2    0.3 seconds
--   section 3    4 HOURS 20 MINUTES
--
-- Section 3 is the offender and the cause is structural, not incidental: it
-- runs two correlated subqueries per candidate, each scanning the allocation
-- set, over 393,003 candidates against roughly 18,000 allocations. That is
-- some seven billion inet comparisons with no index serving them. Standing
-- order 3 requires a MEASURED time or an estimate labelled as an estimate,
-- and I gave neither.
--
-- DO NOT RE-RUN SECTION 3 AS WRITTEN. The result it produced is recorded
-- below so nobody pays four hours for it twice. If it has to be recomputed,
-- the allocation set should be reduced to int8range under a GiST index first,
-- as geo/landmarks/rdap_fill_coverage_now.sql does.
--
-- MEASURED RESULT, 2026-11-09:
--
--   candidates                      393,003
--   covered_by_something            342,180
--   covered_ONLY_by_filler            9,160
--   covered_by_a_real_registrant    333,020
--
-- Note 393,003 against the 281,935 the fill reports. The difference is real
-- and expected: this file counts every ip2city_dbiplite_tbl row with
-- source = 'dbip' and masklen < 24, whereas loadCandidates additionally joins
-- rdap_fill_cand_tbl and removes space covered by an active geo_exclusions
-- prefix. Neither number is wrong; they answer different questions.
--
--
-- WHY THE 9,160 ARE THE ONLY ONES THAT MATTER, which I had wrong
--
-- decomposition_exclusions is DoD ONLY. Its own table comment says so: "Policy
-- is DoD only: a registrant name cannot distinguish infrastructure space from
-- space serving end users, so nothing else qualifies." The active patterns are
-- %dod network information center%, %department of defense%, %air force
-- systems networking%, %navy network information center%, %usaisc% and the
-- exact string DIA.
--
-- So the registrant drives exactly one decision: is this DoD space. Against
-- that test, the 23.5 per cent precision loss verify-sample measured is almost
-- entirely harmless. Comcast Cable Communications, LLC and Comcast IP
-- Services, L.L.C. both answer "not DoD" identically, and so do HEALTHSOUTH
-- REHAB and University of Texas System. I previously called those "the ones
-- that matter". They are not. They would matter to a policy that tried to
-- distinguish datacentre space from end-user space, and that policy was
-- considered and REJECTED, for the reason written in the table comment.
--
-- A FILLER registrant is different in kind. An empty string, or Internet
-- Assigned Numbers Authority over the whole of 192/8, makes
-- registrantKnown = true while carrying no information about whether anything
-- inside it is DoD. That is the one case where retirement by containment
-- converts "we do not know" into "we checked, it is fine". 9,160 candidates
-- are in that state, which at one query per second is about two and a half
-- hours to resolve honestly.

\timing on
\pset pager off

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'rdap_registrant_tbl'
  AND column_name IN ('start_ip', 'end_ip', 'registrant', 'network_name',
                      'handle', 'rir', 'queried_for', 'fetched_at')
ORDER BY column_name;

\echo ''
\echo 'Expected: 8 rows.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. THE WIDEST CACHED ALLOCATIONS, AND WHAT THEY RETIRE.'
\echo '================================================================'
\echo ''
\echo 'Ordered by how many candidate ranges each single row retires. These are'
\echo 'the rows doing the most work, so they are also the rows whose registrant'
\echo 'quality matters most.'
\echo ''

WITH alloc AS (
    SELECT id, start_ip, end_ip, registrant, network_name, rir, fetched_at,
           (end_ip - start_ip) + 1 AS addresses
    FROM rdap_registrant_tbl
    WHERE family(start_ip) = 4 AND family(end_ip) = 4
)
SELECT host(a.start_ip) || '-' || host(a.end_ip)        AS allocation,
       a.addresses,
       coalesce(nullif(btrim(a.registrant), ''), '(EMPTY)') AS registrant,
       (SELECT count(*)
          FROM ip2city_dbiplite_tbl d
         WHERE d.source = 'dbip'
           AND family(d.network) = 4
           AND masklen(d.network) < 24
           AND host(d.network)::inet >= a.start_ip
           AND host(broadcast(d.network))::inet <= a.end_ip) AS candidates_retired
FROM alloc a
ORDER BY a.addresses DESC
LIMIT 25;

\echo ''
\echo 'candidates_retired is the blast radius of one row. A row with a registry'
\echo 'name and a six-figure blast radius is the problem this file is about.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 2. REGISTRY FILLER THE REPAIR SCRIPT DOES NOT MATCH.'
\echo '================================================================'
\echo ''

WITH alloc AS (
    SELECT id, start_ip, end_ip, registrant,
           (end_ip - start_ip) + 1 AS addresses
    FROM rdap_registrant_tbl
    WHERE family(start_ip) = 4 AND family(end_ip) = 4
), classified AS (
    SELECT a.*,
           CASE
             WHEN btrim(coalesce(a.registrant, '')) = ''                            THEN 'a empty registrant'
             WHEN a.registrant ILIKE '%Internet Assigned Numbers Authority%'        THEN 'b IANA by name'
             WHEN a.registrant ILIKE '%Registry for Internet Numbers%'              THEN 'c an RIR by name'
             WHEN a.registrant ILIKE '%Various Registries%'                         THEN 'd Various Registries'
             WHEN a.registrant ILIKE '%RIPE Network Coordination%'                  THEN 'e RIPE NCC by name'
             WHEN a.registrant ILIKE '%Asia Pacific Network Information%'           THEN 'f APNIC by name'
             WHEN a.registrant ILIKE '%Latin American and Caribbean%'               THEN 'g LACNIC by name'
             WHEN a.registrant ILIKE '%African Network Information%'                THEN 'h AFRINIC by name'
             ELSE                                                                        'z not filler by these tests'
           END AS filler_class,
           (upper(a.registrant) LIKE 'MNT-%'
             OR upper(a.registrant) LIKE '%-MNT'
             OR upper(a.registrant) LIKE '%-MAINT'
             OR upper(a.registrant) LIKE '%MANAGED-ADDRESS-BLOCK%'
             OR upper(a.registrant) LIKE '%NON-RIPE-NCC%'
             OR upper(a.registrant) LIKE '%AVAILABLE%'
             OR upper(a.registrant) LIKE '%IANA-BLK%'
             OR upper(a.registrant) LIKE '%RESERVED%') AS caught_by_repair_today
    FROM alloc a
)
SELECT filler_class,
       count(*)                                                   AS allocations,
       count(*) FILTER (WHERE coalesce(caught_by_repair_today, false))
                                                                  AS already_caught_by_repair,
       sum(addresses)                                             AS addresses_covered,
       max(addresses)                                             AS largest_allocation
FROM classified
GROUP BY filler_class
ORDER BY filler_class;

\echo ''
\echo 'The already_caught_by_repair column is the point. Any class with a count'
\echo 'well above its already_caught figure is filler that survives every run'
\echo 'of geo/rdap_registrant_repair.sql.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. HOW MANY CANDIDATES DEPEND ON FILLER ALONE.'
\echo '================================================================'
\echo ''
\echo 'A candidate whose ONLY covering allocation is filler has effectively no'
\echo 'registrant, but the fill counts it as covered and apply_splits counts it'
\echo 'as known. That combination is the one that bypasses the exclusions'
\echo 'without reporting anything.'
\echo ''

WITH alloc AS (
    SELECT start_ip, end_ip,
           (btrim(coalesce(registrant, '')) = ''
             OR registrant ILIKE '%Internet Assigned Numbers Authority%'
             OR registrant ILIKE '%Registry for Internet Numbers%'
             OR registrant ILIKE '%Various Registries%'
             OR registrant ILIKE '%RIPE Network Coordination%'
             OR registrant ILIKE '%Asia Pacific Network Information%'
             OR registrant ILIKE '%Latin American and Caribbean%'
             OR registrant ILIKE '%African Network Information%') AS is_filler
    FROM rdap_registrant_tbl
    WHERE family(start_ip) = 4 AND family(end_ip) = 4
), cand AS (
    SELECT d.network,
           host(d.network)::inet            AS lo,
           host(broadcast(d.network))::inet AS hi
    FROM ip2city_dbiplite_tbl d
    WHERE d.source = 'dbip' AND family(d.network) = 4 AND masklen(d.network) < 24
)
SELECT count(*)                                                  AS candidates,
       count(*) FILTER (WHERE n_any > 0)                         AS covered_by_something,
       count(*) FILTER (WHERE n_any > 0 AND n_real = 0)           AS covered_ONLY_by_filler,
       count(*) FILTER (WHERE n_real > 0)                        AS covered_by_a_real_registrant
FROM (
    SELECT c.network,
           (SELECT count(*) FROM alloc a
             WHERE a.start_ip <= c.lo AND a.end_ip >= c.hi)                      AS n_any,
           (SELECT count(*) FROM alloc a
             WHERE a.start_ip <= c.lo AND a.end_ip >= c.hi AND NOT a.is_filler)  AS n_real
    FROM cand c
) x;

\echo ''
\echo 'covered_ONLY_by_filler is the number to act on.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 4. THE REMEDY, AND ITS PRE-MORTEM. NOTHING BELOW RUNS.'
\echo '================================================================'
\echo ''
\echo 'There are two remedies and they are not alternatives; the second is'
\echo 'strictly better and the first is a one-off cleanup.'
\echo ''
\echo 'REMEDY 1, mechanical, no deletion: run the fill with'
\echo '  -min-cover-prefix 12'
\echo 'so an allocation spanning more than a /12 may not retire a candidate.'
\echo 'The candidate gets queried directly instead. This leaves every existing'
\echo 'row in place and destroys nothing, which is why it is preferred.'
\echo ''
\echo 'REMEDY 2, deletion of filler rows. PRE-MORTEM before anyone runs it:'
\echo ''
\echo '  WHAT IT DESTROYS: the cached allocation rows whose registrant is'
\echo '  registry filler. Each is re-fetchable by a later fill, so no'
\echo '  irreplaceable evidence is lost. No probe data, no geolocation, no'
\echo '  landmark row and no targeting row is touched.'
\echo ''
\echo '  WHAT IT COSTS: every candidate inside a deleted /8 becomes uncovered'
\echo '  and will be queried individually. Section 3 gives that number. At one'
\echo '  request per second it converts directly into seconds of runtime, and'
\echo '  if covered_ONLY_by_filler is in the tens of thousands this is days.'
\echo ''
\echo '  WHAT MAKES IT UNSAFE RIGHT NOW: a running fill loaded its covered set'
\echo '  into memory at startup and will not see the deletion. It would keep'
\echo '  skipping those candidates for the rest of its run, so the delete buys'
\echo '  nothing until the fill is restarted. Deleting mid-run also means the'
\echo '  next restart re-queries what the current run may already have'
\echo '  refined.'
\echo ''
\echo '  THEREFORE: do not run remedy 2 while a fill is in flight, and prefer'
\echo '  remedy 1, which needs no deletion at all.'
\echo ''
\echo 'If remedy 2 is chosen deliberately, the exact DELETE is written out in'
\echo 'the comment block at the END OF THIS FILE. It is not printed here and'
\echo 'not executed anywhere: a statement that deletes rows should be read in'
\echo 'the file, in context, with this pre-mortem above it, rather than'
\echo 'scraped off a terminal.'
\echo ''
\echo 'Done. Nothing was modified.'
\echo ''

-- ---------------------------------------------------------------------------
-- REMEDY 2, THE STATEMENT ITSELF. Commented out deliberately. Read section 3
-- and the pre-mortem in section 4 before uncommenting, and do not run it while
-- a fill is in flight.
--
-- DELETE FROM rdap_registrant_tbl
-- WHERE family(start_ip) = 4
--   AND (btrim(coalesce(registrant, '')) = ''
--     OR registrant ILIKE '%Internet Assigned Numbers Authority%'
--     OR registrant ILIKE '%Registry for Internet Numbers%'
--     OR registrant ILIKE '%Various Registries%'
--     OR registrant ILIKE '%RIPE Network Coordination%'
--     OR registrant ILIKE '%Asia Pacific Network Information%'
--     OR registrant ILIKE '%Latin American and Caribbean%'
--     OR registrant ILIKE '%African Network Information%');
--
-- The same patterns belong in geo/rdap_registrant_repair.sql, whose existing
-- list (MNT-%, %-MNT, %-MAINT, %MANAGED-ADDRESS-BLOCK%, %NON-RIPE-NCC%,
-- %AVAILABLE%, %IANA-BLK%, %RESERVED%) matches none of them.
-- ---------------------------------------------------------------------------
\echo ''
