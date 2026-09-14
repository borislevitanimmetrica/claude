-- decomposition_exclusions.sql
-- Operators whose ranges must NOT be decomposed into narrower rows.
--
-- POLICY: DoD ONLY. NOTHING ELSE BELONGS IN THIS TABLE.
--
-- This file is idempotent and self-enforcing. Re-running it deactivates every
-- pattern that is not on the DoD list below, so the table always converges on
-- policy no matter what has been inserted by hand in the meantime.
--
-- WHY ONLY DoD, AND WHY THE EARLIER AMAZON ENTRIES WERE REMOVED
--
-- The earlier seed excluded Amazon on the reasoning that cloud space has no
-- consumer access product, so decomposing it spends probe budget on datacentre
-- answers. That reasoning was wrong, and the RDAP run that populated
-- rdap_registrant_tbl is what showed why.
--
-- RDAP returns the REGISTRANT of an allocation. It does not say, and cannot say,
-- whether a given range inside that allocation serves infrastructure or serves
-- end users. The 500-query run returned University of Michigan, Michigan State,
-- Stanford, MIT, Grand Valley State, Merit Network, Utah Education Network and the
-- Board of Regents of the University System of Georgia. Universities run student
-- housing. Those are residential eyeballs sitting inside a registrant name that
-- looks purely institutional.
--
-- The same argument applies to every corporate name in that run. People at work at
-- Ford, Prudential, Boeing, Procter and Gamble or Eli Lilly consume media, and
-- under the targeting rules for this project they are legitimate targets. A
-- registrant name gives no way to separate an office desk from a server rack.
--
-- So the test for belonging here is not "does this organisation sell broadband".
-- It is "can this space be ruled out as serving end users with certainty". Only
-- DoD passes it, and DoD passes for a reason that has nothing to do with what the
-- registrant does commercially: its space is not offered to the public at all, and
-- reallocation out of it is close to unimaginable, which is the standing
-- justification already used for the DoD prefixes in geo_exclusions.
--
-- WHAT THIS COSTS, STATED PLAINLY
--
-- Excluding only DoD means decomposition eventually generates roughly 3,368,502
-- sub-/24 rows. At the measured free-tier ceiling of 45 ip-api calls a minute,
-- which is 64,800 a day, that is about 52 days of probing for the new rows alone
-- and about 84 days including the existing backlog. Exclusions are therefore NOT
-- the lever that makes decomposition affordable. The paid batch endpoint is.
-- Choosing correctness here and paying for throughput is the coherent position;
-- choosing exclusions to save calls would trade real coverage for a discount.
--
-- HOW THIS TABLE DIFFERS FROM geo_exclusions
--
--   geo_exclusions            removes a range from PROBING and from OUTPUT. A
--                             wrong entry is a false negative: the range
--                             disappears from targeting and nobody notices.
--
--   decomposition_exclusions  removes a range from DECOMPOSITION only. The range
--                             stays in the probe table and stays targetable at its
--                             original width. A wrong entry costs granularity,
--                             never coverage.
--
-- WHY OPERATOR NAME AND NOT ASN
--
-- Matching on ASN oversweeps. An operator announces space it has bought, sold,
-- sub-allocated or repurposed, and an ASN rule captures all of it indiscriminately
-- and keeps capturing it after ownership changes. Matching the registrant name
-- means additions, drops and transfers are handled correctly as they happen,
-- because the name follows the range rather than the announcement.
--
-- WHERE THE NAME COMES FROM
--
-- RDAP, via rdap_registrant_tbl, which is RIR registration data keyed on the
-- prefix and therefore available for any range whether or not it has been probed.
-- ip-api's isp and org describe who appears to be OPERATING an address and exist
-- only as a side effect of probing, so a registrant taken from them is unavailable
-- for unprobed ranges. apply_splits -registrant-source ip-api still selects the
-- older behaviour, and the patterns below work under either source.
--
-- Contains NO backslashes so it survives copy/paste.


CREATE TABLE IF NOT EXISTS decomposition_exclusions (
    id               serial PRIMARY KEY,
    operator_pattern text        NOT NULL,
    reason           text        NOT NULL,
    active           boolean     NOT NULL DEFAULT true,
    added_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT decomposition_exclusions_pattern_uniq UNIQUE (operator_pattern)
);

COMMENT ON TABLE decomposition_exclusions IS
    'DoD registrants whose ranges are not decomposed. Matched with ILIKE against the registrant from rdap_registrant_tbl, or from the ip-api isp and org under -registrant-source ip-api. Policy is DoD only: a registrant name cannot distinguish infrastructure space from space serving end users, so nothing else qualifies. Does NOT remove anything from probing or output: see geo_exclusions for that.';
COMMENT ON COLUMN decomposition_exclusions.operator_pattern IS
    'ILIKE pattern matched against the registrant name. Include percent wildcards explicitly. A pattern with no wildcards matches the whole string exactly, which is required for short names such as DIA.';


-- ---------------------------------------------------------------------------
-- 1. SEED. DoD components, as their registrant names actually appear.
--
-- Every name here was OBSERVED in rdap_registrant_tbl during the 500-query run
-- on 2026-09-14. None is speculative. Note that three of them would be missed by
-- the obvious patterns: "Headquarters, USAISC" does not contain "army", "DIA"
-- does not contain "defense", and "Air Force Systems Networking" does not contain
-- "DoD".
--
-- DIA is matched EXACTLY, with no wildcards. A pattern of percent-dia-percent
-- would also match India, Media, Nvidia, Acadia and Arcadia, which is precisely
-- the oversweep this table exists to avoid.
-- ---------------------------------------------------------------------------

INSERT INTO decomposition_exclusions (operator_pattern, reason) VALUES
    ('%dod network information center%',      'DoD, observed registrant name'),
    ('%department of defense%',               'DoD, observed registrant name'),
    ('%air force systems networking%',        'DoD, US Air Force, observed registrant name'),
    ('%navy network information center%',     'DoD, US Navy, observed registrant name'),
    ('%usaisc%',                              'DoD, US Army Information Systems Command, observed as Headquarters, USAISC'),
    ('DIA',                                   'DoD, Defense Intelligence Agency. Matched exactly: a wildcard would hit India, Media, Nvidia')
ON CONFLICT (operator_pattern) DO UPDATE
    SET active = true,
        reason = EXCLUDED.reason;


-- ---------------------------------------------------------------------------
-- 2. ENFORCE THE POLICY. Deactivate everything that is not DoD.
--
-- This is what removes the earlier Amazon patterns, and what will remove any
-- future entry added on the reasoning that some company "does not serve
-- consumers". Rows are deactivated rather than deleted so the history of what was
-- once excluded, and when, remains readable.
-- ---------------------------------------------------------------------------

UPDATE decomposition_exclusions
   SET active = false
 WHERE active
   AND operator_pattern NOT IN (
        '%dod network information center%',
        '%department of defense%',
        '%air force systems networking%',
        '%navy network information center%',
        '%usaisc%',
        'DIA'
   );

SELECT 'active exclusions after enforcement' AS section;

SELECT operator_pattern, reason, active, added_at
FROM decomposition_exclusions
ORDER BY active DESC, operator_pattern;


-- ---------------------------------------------------------------------------
-- 3. DISCOVER DoD SPACE THE PATTERNS DO NOT YET COVER.
--
-- The list in section 1 covers the names seen in one 500-query sample of a
-- 371,289-range candidate set. More DoD registrant spellings certainly exist. This
-- lists every distinct registrant in the cache alongside whether the current
-- patterns match it, so new spellings can be found by reading rather than guessed.
--
-- Read the unmatched rows for anything military. Add only what is genuinely DoD.
-- ---------------------------------------------------------------------------

SELECT r.registrant,
       count(*)                                        AS allocations,
       sum((r.end_ip - r.start_ip) + 1)                 AS addresses,
       EXISTS (SELECT 1 FROM decomposition_exclusions d
                WHERE d.active AND r.registrant ILIKE d.operator_pattern)
                                                       AS matched_by_a_pattern
FROM rdap_registrant_tbl r
WHERE r.registrant IS NOT NULL
GROUP BY r.registrant
ORDER BY matched_by_a_pattern, addresses DESC
LIMIT 60;


-- ---------------------------------------------------------------------------
-- 4. DoD SPACE THAT geo_exclusions DOES NOT COVER.
--
-- decomposition_exclusions only stops a range being split. DoD space arguably
-- belongs in geo_exclusions instead, which removes it from probing and from output
-- altogether. The RDAP cache can now find DoD allocations whose prefixes were
-- never seeded there: 148.16.0.0/12, 140.56.0.0/13, 157.216.0.0/13 and many /15s
-- all resolved to DoD registrants while passing the prefix filter.
--
-- This is a REPORT, not an action. Adding to geo_exclusions removes coverage, so it
-- is a deliberate decision to take on the evidence rather than a cleanup to
-- automate.
-- ---------------------------------------------------------------------------

SELECT r.registrant,
       host(r.start_ip) || ' - ' || host(r.end_ip)      AS allocation,
       (r.end_ip - r.start_ip) + 1                      AS addresses
FROM rdap_registrant_tbl r
WHERE EXISTS (SELECT 1 FROM decomposition_exclusions d
               WHERE d.active AND r.registrant ILIKE d.operator_pattern)
  AND NOT EXISTS (
        SELECT 1 FROM geo_exclusions e
         WHERE e.active AND e.prefix IS NOT NULL
           AND host(r.start_ip)::inet >= host(network(e.prefix))::inet
           AND host(r.end_ip)::inet   <= host(broadcast(e.prefix))::inet
  )
ORDER BY addresses DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 5. AUDIT THE OTHER DIRECTION. Is anything NON-DoD being excluded?
--
-- The policy is that only DoD is excluded. geo_exclusions is the table that
-- actually removes coverage, so it is the one worth auditing against that policy.
-- This lists active prefix exclusions whose registrant, according to the cache,
-- is not matched by any DoD pattern.
--
-- A row here is either a legitimate non-DoD exclusion with a reason worth
-- re-reading, or a DoD spelling missing from section 1. Both are worth knowing.
-- ---------------------------------------------------------------------------

SELECT e.prefix::text                                  AS excluded_prefix,
       e.reason,
       cov.registrant                                  AS rdap_registrant
FROM geo_exclusions e
JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= host(network(e.prefix))::inet
      AND r.end_ip   >= host(broadcast(e.prefix))::inet
    ORDER BY (r.end_ip - r.start_ip)
    LIMIT 1
) cov ON true
WHERE e.active
  AND e.prefix IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM decomposition_exclusions d
                   WHERE d.active AND cov.registrant ILIKE d.operator_pattern)
ORDER BY e.prefix
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 6. WHAT THE POLICY COSTS. Decomposition workload by registrant.
--
-- Ranked by the sub-/24 rows each registrant would generate, with the probe days
-- that implies at the measured 64,800 calls a day. Under the DoD-only policy every
-- row here except the DoD ones is work that will actually be done.
-- ---------------------------------------------------------------------------

SELECT cov.registrant,
       count(*)                                                     AS wide_ranges,
       sum(2 ^ (24 - masklen(d.network)))::bigint                     AS sub24_rows,
       round(sum(2 ^ (24 - masklen(d.network))) / 64800.0, 2)          AS probe_days,
       min(masklen(d.network))                                        AS widest,
       EXISTS (SELECT 1 FROM decomposition_exclusions x
                WHERE x.active AND cov.registrant ILIKE x.operator_pattern)
                                                                     AS excluded
FROM ip2city_dbiplite_tbl d
JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= host(network(d.network))::inet
      AND r.end_ip   >= host(broadcast(d.network))::inet
    ORDER BY (r.end_ip - r.start_ip)
    LIMIT 1
) cov ON true
WHERE d.source = 'dbip'
  AND family(d.network) = 4
  AND masklen(d.network) < 24
GROUP BY cov.registrant
ORDER BY sub24_rows DESC
LIMIT 40;
