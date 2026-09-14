-- rdap_registrant_repair.sql
-- Removes cache rows written by two faults in the first fill runs, so they are
-- re-queried with the corrected entity selection.
--
-- FAULT 1: MAINTAINER OBJECTS RECORDED AS REGISTRANTS
--
-- Several entities can carry the RDAP registrant role, and the tool took the first
-- in document order. Measured against live RIPE for 51.180.0.0 - 51.181.255.255,
-- three carry it:
--
--   MNT-ADSI          fn "MNT-ADSI"          a maintainer object
--   ORG-ARI3-RIPE     fn "A100 ROW Inc"      the actual organisation
--   RIPE-NCC-HM-MNT   fn "RIPE-NCC-HM-MNT"   RIPE's hostmaster maintainer
--
-- Document order put the maintainer first, so 26 allocations were recorded as
-- MNT-ADSI when the holder is A100 ROW Inc. APPLE-MNT, MICROSOFT-MAINT, ORCL-MNT
-- and OPENDNS-MNT come from the same fault. A maintainer is an access-control
-- object, not a holder, and its name matches none of the ARIN-style names that any
-- exclusion pattern is written against.
--
-- FAULT 2: WHOLE /8 PLACEHOLDERS RECORDED AS ALLOCATIONS
--
-- ARIN answers 303 for early-registration space and redirects to the responsible
-- registry. For 151.220.0.1 that lands on RIPE, which returns the entire
-- 151.0.0.0/8 as RIPE-NCC-MANAGED-ADDRESS-BLOCK with no entities at all. The tool
-- fell back to the network name and stored a 16,777,216-address allocation whose
-- registrant is administrative filler.
--
-- That is worse than storing nothing, because the coverage test then treats every
-- candidate inside the block as already answered and never queries it again. Two
-- such rows, for 151.0.0.0/8 and 46.0.0.0/8, suppress roughly 33.5 million
-- addresses of candidates.
--
-- The corrected tool stores these with a NULL registrant and a note reading
-- placeholder:NAME, which apply_splits now treats as positive evidence that no DoD
-- registration exists rather than as an unknown registrant. Deleting the old rows
-- lets them be re-fetched in that form.
--
-- Contains NO backslashes so it survives copy/paste.


-- ---------------------------------------------------------------------------
-- 1. WHAT WILL BE DELETED. Read this before running section 2.
-- ---------------------------------------------------------------------------

SELECT 'maintainer objects mistaken for registrants' AS fault,
       registrant,
       count(*)                          AS allocations,
       sum((end_ip - start_ip) + 1)      AS addresses
FROM rdap_registrant_tbl
WHERE registrant IS NOT NULL
  AND (upper(registrant) LIKE 'MNT-%'
    OR upper(registrant) LIKE '%-MNT'
    OR upper(registrant) LIKE '%-MAINT')
GROUP BY registrant
ORDER BY addresses DESC;

SELECT 'administrative placeholders' AS fault,
       registrant,
       count(*)                          AS allocations,
       sum((end_ip - start_ip) + 1)      AS addresses
FROM rdap_registrant_tbl
WHERE registrant IS NOT NULL
  AND (upper(registrant) LIKE '%MANAGED-ADDRESS-BLOCK%'
    OR upper(registrant) LIKE '%NON-RIPE-NCC%'
    OR upper(registrant) LIKE '%AVAILABLE%'
    OR upper(registrant) LIKE '%IANA-BLK%'
    OR upper(registrant) LIKE '%RESERVED%')
GROUP BY registrant
ORDER BY addresses DESC;


-- ---------------------------------------------------------------------------
-- 2. DELETE THEM.
--
-- Safe to run: rdap_registrant_tbl is a cache, nothing else writes to it, and
-- every deleted row is re-fetchable by rdap_registrant -fill. No probe data, no
-- geolocation and no targeting row is touched. The only cost is the RDAP queries
-- needed to fetch them again.
-- ---------------------------------------------------------------------------

DELETE FROM rdap_registrant_tbl
WHERE registrant IS NOT NULL
  AND (upper(registrant) LIKE 'MNT-%'
    OR upper(registrant) LIKE '%-MNT'
    OR upper(registrant) LIKE '%-MAINT'
    OR upper(registrant) LIKE '%MANAGED-ADDRESS-BLOCK%'
    OR upper(registrant) LIKE '%NON-RIPE-NCC%'
    OR upper(registrant) LIKE '%AVAILABLE%'
    OR upper(registrant) LIKE '%IANA-BLK%'
    OR upper(registrant) LIKE '%RESERVED%');


-- ---------------------------------------------------------------------------
-- 3. WHAT REMAINS, and whether any DoD pattern now matches.
--
-- Ordered so MATCHED rows appear FIRST. The earlier version of this report sorted
-- unmatched first and capped at 60 rows, which meant the DoD matches were never
-- visible on a candidate set with more than 60 distinct registrants.
-- ---------------------------------------------------------------------------

SELECT EXISTS (SELECT 1 FROM decomposition_exclusions d
                WHERE d.active AND r.registrant ILIKE d.operator_pattern)
                                                       AS excluded,
       r.registrant,
       count(*)                                        AS allocations,
       sum((r.end_ip - r.start_ip) + 1)                 AS addresses
FROM rdap_registrant_tbl r
WHERE r.registrant IS NOT NULL
GROUP BY r.registrant
ORDER BY excluded DESC, addresses DESC
LIMIT 60;


-- ---------------------------------------------------------------------------
-- 4. PLACEHOLDER ROWS, once the corrected tool has re-fetched them.
--
-- These carry a NULL registrant and a note beginning placeholder. They are a
-- positive answer, not a gap: the registry holds no assignment for the range, so
-- no DoD registration exists and decomposition may proceed.
-- ---------------------------------------------------------------------------

SELECT note,
       count(*)                          AS allocations,
       sum((end_ip - start_ip) + 1)      AS addresses
FROM rdap_registrant_tbl
WHERE registrant IS NULL
GROUP BY note
ORDER BY addresses DESC;
