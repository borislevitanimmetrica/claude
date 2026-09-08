-- geo_exclusions_seed_dod_probed.sql
-- DoD exclusions discovered by probe AFTER the original /8 seeding.
--
-- Run geo_exclusions.sql and geo_exclusions_seed_dod.sql first.
--
-- WHY THESE ARE NEW: geo_exclusions_seed_dod.sql covers the 12 /8s that IANA
-- designates to DoD organisations. DoD also operates address space outside
-- those /8s, which the /8 rules cannot match. Three such ranges appeared in the
-- probe log on 2026-09-08 and were being probed at full cost:
--
--   206.37.215.0/24   isp "DoD Network Information Center"      -> Columbus OH
--   138.141.134.0/24  isp "DoD Network Information Center"      -> Columbus OH
--   138.167.154.0/24  isp "United States Department of Defense" -> Quantico VA
--
-- Columbus OH is the same registrant address that the original measurement
-- identified as the DISA whois location, which is the confirming evidence: these
-- return registrant geography, not subscriber geography, exactly like the /8s.
--
-- EVIDENCE STANDARD: geo_exclusions.sql requires "verify by probe before adding,
-- and never exclude on a guess". Every rule below is derived from an actual
-- probe result already stored in ip2city_dbiplite_traceroute_tbl. No rule here
-- is inferred from a name pattern alone, and no supernet is excluded on the
-- strength of a single member range.
--
-- WHY NOT EXCLUDE THE SUPERNETS: 138.0.0.0/8 and 206.0.0.0/8 are general
-- allocations holding a great deal of non-DoD space. Excluding them would create
-- false negatives across large numbers of legitimate commercial ranges. False
-- positives are tolerable in this workflow, false negatives are not, so
-- exclusion stays narrow and evidence-bound.
--
-- Contains NO backslashes so it survives copy/paste.


-- ---------------------------------------------------------------------------
-- STEP 1 of 4: REVIEW. Run this alone first and read the output.
-- It changes nothing. It shows exactly what steps 2 and 3 would exclude.
-- ---------------------------------------------------------------------------

SELECT tr.isp,
       tr."as",
       count(*)                        AS ranges_probed,
       count(DISTINCT tr.city)         AS distinct_cities,
       min(tr.city)                    AS example_city
FROM ip2city_dbiplite_traceroute_tbl tr
WHERE tr.isp ILIKE '%DoD Network Information Center%'
   OR tr.isp ILIKE '%United States Department of Defense%'
   OR tr.isp ILIKE '%Department of Defense (DoD)%'
   OR tr.org ILIKE '%DoD Network Information Center%'
   OR tr.org ILIKE '%United States Department of Defense%'
GROUP BY tr.isp, tr."as"
ORDER BY ranges_probed DESC;

-- Read distinct_cities in that output. A DoD operator returning ONE city across
-- many ranges is the registrant-address signature that justifies exclusion. An
-- operator returning many distinct cities would be giving real geography and
-- must NOT be excluded, however military its name looks.


-- ---------------------------------------------------------------------------
-- STEP 2 of 4: the three probe-verified prefixes, stated explicitly.
-- Narrow /24 rules, no supernets.
-- ---------------------------------------------------------------------------

INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('206.37.215.0/24',  'probe-verified 2026-09-08: DoD Network Information Center, returned Columbus OH registrant geo'),
    ('138.141.134.0/24', 'probe-verified 2026-09-08: DoD Network Information Center, returned Columbus OH registrant geo'),
    ('138.167.154.0/24', 'probe-verified 2026-09-08: United States Department of Defense (DoD), returned Quantico VA registrant geo')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- STEP 3 of 4: the rules that actually save probe budget.
--
-- Steps 1 and 2 only cover ranges already probed, so on their own they save
-- nothing: those ranges have a city and would not be selected again.
--
-- An origin_asn rule is different. It excludes EVERY BGP prefix originated by
-- that ASN, including the ones not yet probed, so it removes the whole
-- remaining tail of that operator's space from the backlog in one row.
--
-- The ASN is taken from the "as" column of probe results, whose format is
-- "AS27064 DoD Network Information Center", so the numeric part is the token
-- before the first space with the leading AS removed.
--
-- Only run this after reading the STEP 1 output and confirming that each ASN
-- listed there shows a single distinct city.
-- ---------------------------------------------------------------------------

INSERT INTO geo_exclusions (origin_asn, reason)
SELECT (substring(split_part(tr."as", ' ', 1) from 3))::bigint AS asn,
       'probe-verified DoD ASN, registrant geo only: ' || min(tr.isp)
FROM ip2city_dbiplite_traceroute_tbl tr
WHERE tr."as" LIKE 'AS%'
  AND (tr.isp ILIKE '%DoD Network Information Center%'
    OR tr.isp ILIKE '%United States Department of Defense%'
    OR tr.isp ILIKE '%Department of Defense (DoD)%'
    OR tr.org ILIKE '%DoD Network Information Center%'
    OR tr.org ILIKE '%United States Department of Defense%')
GROUP BY 1
HAVING count(DISTINCT tr.city) <= 2
ON CONFLICT DO NOTHING;

-- The HAVING clause is the safety rail. An ASN whose probes returned three or
-- more distinct cities is producing real geographic variation and is left alone,
-- so a mislabelled or shared ASN cannot silently remove usable ranges.


-- ---------------------------------------------------------------------------
-- STEP 4 of 4: verify what was added, and what it will remove from the backlog.
-- ---------------------------------------------------------------------------

SELECT id, prefix, origin_asn, reason, added_at
FROM geo_exclusions
WHERE reason LIKE 'probe-verified%'
ORDER BY added_at DESC, id DESC;

-- Ranges that the new ASN rules will remove from future probing. This is the
-- probe budget actually saved, and it should be run before and after to compare.
SELECT count(*) AS ranges_now_excluded_by_asn
FROM ip2city_dbiplite_tbl t
JOIN bgp_route_views b ON t.network <<= b.cidr_block
JOIN geo_exclusions x ON x.active
                     AND x.origin_asn IS NOT NULL
                     AND b.origin_asn = x.origin_asn
WHERE family(t.network) = 4
  AND NOT EXISTS (SELECT 1 FROM ip2city_dbiplite_traceroute_tbl tr
                  WHERE tr.network = t.network AND tr.city IS NOT NULL);
