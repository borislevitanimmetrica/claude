-- registrant_landmarks.sql
--
-- TWO QUESTIONS THE AUDIT RAISED, BOTH ABOUT DATA ALREADY IN THE DATABASE.
--
-- 1. Rule 6b discards landmarks that are real, at the wrong ZIP.
--
-- The audit sampled these, among many:
--
--   University of Hawaii Hilo        landmark 96720   registrant 96822
--   UConn School of Law              landmark 06105   registrant 06269
--   Texas A&M Kingsville Citrus Ctr  landmark 78599   registrant 77843
--   Mayo Clinic Springfield          landmark 56087   registrant 55905
--   Spaulding Rehabilitation         landmark 02537   registrant 02115
--
-- In each case registrant_1 is the institution itself, not a provider and not
-- an ISP, so the address IS on its own premises. Rule 6b rejects it because
-- those premises are not in the landmark's ZIP, and that rejection is CORRECT
-- for the landmark's ZIP. But the address is still a genuine landmark for the
-- REGISTRANT's ZIP, and it is currently thrown away completely.
--
-- Section 1 sizes that set. Section 2 shows what it would add in ZIPs.
--
-- THIS FILE CHANGES NOTHING. Whether a landmark should anchor to the
-- registrant's ZIP instead of being dropped is a design decision about the
-- meaning of the corpus, and it is Boris's to make. The numbers come first.
--
-- 2. rdap_registrant_tbl holds organisation allocations but NOT their ZIPs.
--
-- The appealing idea: every allocation whose registrant is neither a provider
-- nor an ISP is an organisation holding IP space at its own address, which is a
-- landmark with no website in the path and therefore no exposure to rule 2.
--
-- I checked the schema before building on it, having already shipped one
-- guessed column name this project. rdap_registrant_tbl.sql lines 47 to 72:
-- start_ip, end_ip, registrant, registrant_role, handle, network_name, rir,
-- queried_for, http_status, note, fetched_at. THERE IS NO ADDRESS OR ZIP
-- COLUMN. The registrant ZIP lives only in landmarks_usa.registrant_1_zip,
-- written per landmark address by the registrants step, not per allocation.
--
-- So the idea does not work off this table as it stands. It needs either a
-- schema addition and a re-fetch, or an external list that supplies the ZIP and
-- is joined on the registrant name. The second is cheaper and is exactly the
-- rural-ILEC route in audit_findings.md: the FCC Form 499 filer database
-- supplies name and address, this table supplies name and allocation, and they
-- join on name.
--
-- Sections 3 and 4 therefore size what this table CAN answer: how many
-- organisation allocations exist and how much space they hold. That bounds the
-- idea without pretending to a column that is not there.
--
-- READ-ONLY throughout. No table is created, altered or dropped.

\timing on
\set ON_ERROR_STOP on
SET work_mem = '512MB';

\echo ''
\echo '=== 1 of 4: landmarks rule 6b drops that have a usable registrant ZIP ==='
\echo '    Restricted to rows where registrant_1 is neither a provider nor an'
\echo '    ISP, so the registrant is the organisation itself. About a minute.'
SELECT t.source,
       count(*)                                          AS rows_6b_with_own_registrant,
       count(DISTINCT lower(btrim(t.registrant_1)))      AS distinct_registrants,
       count(DISTINCT left(lpad(btrim(t.registrant_1_zip), 5, '0'), 5))
                                                         AS distinct_registrant_zips,
       count(DISTINCT t.ip_address)                      AS distinct_addresses
FROM landmarks_usa t
WHERE t.lookup_status = 'true'
  AND t.onpremises IS NOT TRUE
  AND coalesce(t.onpremises_reason, '') NOT LIKE 'hosting:%'
  AND t.registrant_1 IS NOT NULL
  AND btrim(coalesce(t.registrant_1_zip, '')) <> ''
  AND NOT EXISTS (SELECT 1 FROM provider_names p
                  WHERE lower(btrim(p.name)) = lower(btrim(t.registrant_1)))
  AND NOT EXISTS (SELECT 1 FROM isp_names i
                  WHERE lower(btrim(i.name)) = lower(btrim(t.registrant_1)))
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '=== 2 of 4: how many of those registrant ZIPs are NEW coverage ==='
\echo '    A registrant ZIP already delivered by an on-premises landmark adds'
\echo '    density, which node_fanout wants. One not yet delivered is new'
\echo '    coverage. Both matter and they are different.'
WITH already AS (
    SELECT DISTINCT overture_zip AS zip
    FROM landmarks_usa
    WHERE onpremises AND overture_zip IS NOT NULL
), candidate AS (
    SELECT DISTINCT left(lpad(btrim(t.registrant_1_zip), 5, '0'), 5) AS zip
    FROM landmarks_usa t
    WHERE t.lookup_status = 'true'
      AND t.onpremises IS NOT TRUE
      AND coalesce(t.onpremises_reason, '') NOT LIKE 'hosting:%'
      AND t.registrant_1 IS NOT NULL
      AND btrim(coalesce(t.registrant_1_zip, '')) <> ''
      AND NOT EXISTS (SELECT 1 FROM provider_names p
                      WHERE lower(btrim(p.name)) = lower(btrim(t.registrant_1)))
      AND NOT EXISTS (SELECT 1 FROM isp_names i
                      WHERE lower(btrim(i.name)) = lower(btrim(t.registrant_1)))
)
SELECT count(*)                                                   AS registrant_zips,
       count(*) FILTER (WHERE a.zip IS NULL)                      AS zips_not_already_covered,
       count(*) FILTER (WHERE a.zip IS NOT NULL)                  AS zips_already_covered
FROM candidate c
LEFT JOIN already a ON a.zip = c.zip
WHERE c.zip ~ '^[0-9]{5}$';

\echo ''
\echo '=== 3 of 4: how many organisation allocations the cache holds (fast) ==='
\echo '    No ZIP column exists here, so this bounds the idea rather than'
\echo '    delivering it. Organisation allocations are the rows whose registrant'
\echo '    is in neither provider_names nor isp_names.'
SELECT CASE WHEN p.name IS NOT NULL THEN '3 hosting provider, never a landmark'
            WHEN i.name IS NOT NULL THEN '2 known ISP, landmark only via rule 3'
            ELSE                         '1 organisation, a landmark if we had its ZIP'
       END                                              AS kind,
       count(*)                                         AS allocations,
       count(DISTINCT lower(btrim(r.registrant)))       AS distinct_registrants,
       sum((r.end_ip - r.start_ip) + 1)::bigint         AS addresses
FROM rdap_registrant_tbl r
LEFT JOIN provider_names p ON lower(btrim(p.name)) = lower(btrim(r.registrant))
LEFT JOIN isp_names      i ON lower(btrim(i.name)) = lower(btrim(r.registrant))
WHERE family(r.start_ip) = 4
GROUP BY 1
ORDER BY 1;

\echo ''
\echo '--- the organisation registrants themselves, by space held ---'
\echo '    This is the candidate list for a name join against any external'
\echo '    directory that carries an address, the FCC Form 499 filer database'
\echo '    being the one proposed for rural carriers.'
SELECT left(coalesce(r.registrant, '(null)'), 48)        AS registrant,
       count(*)                                          AS allocations,
       sum((r.end_ip - r.start_ip) + 1)::bigint          AS addresses
FROM rdap_registrant_tbl r
LEFT JOIN provider_names p ON lower(btrim(p.name)) = lower(btrim(r.registrant))
LEFT JOIN isp_names      i ON lower(btrim(i.name)) = lower(btrim(r.registrant))
WHERE family(r.start_ip) = 4
  AND p.name IS NULL
  AND i.name IS NULL
GROUP BY 1
ORDER BY 3 DESC
LIMIT 40;

\echo ''
\echo '=== 4 of 4: how many of those registrants landmarks_usa already knows ==='
\echo '    Where a registrant already appears as registrant_1 on some landmark,'
\echo '    registrant_1_zip gives its ZIP for free and no external list or'
\echo '    re-fetch is needed. That is the cheapest version of the idea and it'
\echo '    needs no schema change at all.'
SELECT count(*)                                              AS organisation_registrants,
       count(*) FILTER (WHERE k.zip IS NOT NULL)             AS zip_already_known,
       count(DISTINCT k.zip)                                 AS distinct_zips_available
FROM (SELECT DISTINCT lower(btrim(r.registrant)) AS reg
      FROM rdap_registrant_tbl r
      LEFT JOIN provider_names p ON lower(btrim(p.name)) = lower(btrim(r.registrant))
      LEFT JOIN isp_names      i ON lower(btrim(i.name)) = lower(btrim(r.registrant))
      WHERE family(r.start_ip) = 4
        AND p.name IS NULL AND i.name IS NULL
        AND r.registrant IS NOT NULL) o
LEFT JOIN LATERAL (
    SELECT left(lpad(btrim(t.registrant_1_zip), 5, '0'), 5) AS zip
    FROM landmarks_usa t
    WHERE lower(btrim(t.registrant_1)) = o.reg
      AND btrim(coalesce(t.registrant_1_zip, '')) <> ''
    LIMIT 1
) k ON true;

\echo ''
\echo '=== done ==='
\timing off
