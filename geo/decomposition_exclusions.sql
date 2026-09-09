-- decomposition_exclusions.sql
-- Operators whose ranges must NOT be decomposed into narrower rows.
--
-- WHY THIS IS A SEPARATE TABLE FROM geo_exclusions
--
-- The two do different things and carry different risk, and conflating them would
-- eventually cause someone to apply one as the other.
--
--   geo_exclusions          removes a range from PROBING and from OUTPUT. A wrong
--                           entry is a false negative: the range disappears from
--                           targeting entirely and nobody notices.
--
--   decomposition_exclusions  removes a range from DECOMPOSITION only. The range
--                           stays in the probe table and stays targetable at its
--                           original width. A wrong entry costs granularity, never
--                           coverage.
--
-- That asymmetry is why this table can be populated far more freely than
-- geo_exclusions. It cannot produce a false negative.
--
-- WHY OPERATOR NAME AND NOT ASN
--
-- Matching on ASN oversweeps. An operator announces space it has bought, sold,
-- sub-allocated or repurposed, and an ASN rule captures all of it indiscriminately
-- and keeps capturing it after ownership changes. Matching the registrant name
-- returned for the specific range means additions, drops and transfers are handled
-- correctly as they happen, because the name follows the range rather than the
-- announcement.
--
-- WHERE THE NAME COMES FROM
--
-- ip-api, not RDAP. The isp and org fields of a probe of the range itself. Those
-- values are already stored on every probed row of ip2city_dbiplite_probe_tbl, so
-- for a range that has been probed the check costs nothing.
--
-- WHAT MUST NEVER GO IN HERE
--
-- Any company that serves end customers, directly or indirectly, from part of its
-- holdings. Google is the explicit example: Google Fiber subscribers occupy space
-- inside Google numberspace, so a Google pattern would stop that space being
-- decomposed and would coarsen real residential targeting.
--
-- Backbone and transit operators are also excluded from this list, for the same
-- reason. Cogent, Lumen and their peers carry customer assignments inside their
-- announcements. 4.0.0.0/8 resolving to Monroe LA is Lumen headquarters showing
-- through as a registrant address, which is a measurement problem, not grounds for
-- refusing to decompose the space.
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
    'Operators whose ranges are not decomposed. Matched with ILIKE against the ip-api isp and org of a probe of the range. Does NOT remove anything from probing or output: see geo_exclusions for that.';
COMMENT ON COLUMN decomposition_exclusions.operator_pattern IS
    'ILIKE pattern matched against ip-api isp and org. Include percent wildcards explicitly.';


-- ---------------------------------------------------------------------------
-- SEED. Amazon only, being the case named explicitly.
--
-- Amazon qualifies because no part of its numberspace serves eyeball subscribers:
-- it has no consumer access product. Its ranges geolocate to facility locations,
-- so decomposing them into /24s and probing each one returns the same datacentre
-- answer thousands of times over.
-- ---------------------------------------------------------------------------

INSERT INTO decomposition_exclusions (operator_pattern, reason) VALUES
    ('%amazon%',            'cloud and datacentre space, no consumer access product, ranges resolve to facility locations'),
    ('%aws%',               'Amazon Web Services, as above'),
    ('%amazon technologies%', 'Amazon registrant variant'),
    ('%amazon data services%', 'Amazon registrant variant')
ON CONFLICT (operator_pattern) DO NOTHING;


-- ---------------------------------------------------------------------------
-- CANDIDATES, DELIBERATELY NOT APPLIED.
--
-- Each of these is a datacentre or hosting operator with no consumer access
-- product as far as is known, which is the test for belonging here. None is
-- inserted, because none has been verified against this database, and the
-- standing rule in this project is never to exclude on a guess. Verify with
-- section 3 below, then uncomment individually.
--
-- INSERT INTO decomposition_exclusions (operator_pattern, reason) VALUES
--     ('%digitalocean%',   'hosting, no consumer access product'),
--     ('%linode%',         'hosting, no consumer access product'),
--     ('%hetzner%',        'hosting, no consumer access product'),
--     ('%ovh%',            'hosting, no consumer access product'),
--     ('%vultr%',          'hosting, no consumer access product'),
--     ('%equinix%',        'colocation'),
--     ('%digital realty%', 'colocation'),
--     ('%rackspace%',      'hosting')
-- ON CONFLICT (operator_pattern) DO NOTHING;
--
-- NOT CANDIDATES, and the reason matters more than the list:
--
--   Google, Alphabet        Google Fiber serves subscribers from Google space
--   Microsoft               excluded pending a decision; it has no consumer
--                           access product in the US, but it is large enough that
--                           a blanket name match is worth checking first
--   Cogent, Lumen, Level 3,
--   Zayo, Arelion, GTT      backbones carrying customer assignments
--   Comcast, Charter, Cox,
--   AT&T, Verizon, T-Mobile eyeball networks, the entire point of the exercise
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 3. VERIFY BEFORE AND AFTER. What does a pattern actually match?
--
-- Run this before adding a pattern. It reports how many probed ranges the
-- pattern would stop decomposing, and how many of those are wider than a /24 and
-- therefore actually candidates for decomposition.
--
-- Substitute the pattern being considered.
-- ---------------------------------------------------------------------------

SELECT count(*)                                                    AS probed_ranges_matched,
       count(*) FILTER (WHERE masklen(network) < 24)                AS decomposition_candidates,
       coalesce(sum(2 ^ (24 - masklen(network))) FILTER (WHERE masklen(network) < 24), 0)::bigint
                                                                   AS sub24_rows_avoided,
       min(masklen(network))                                        AS widest,
       count(DISTINCT isp)                                          AS distinct_isp_strings
FROM ip2city_dbiplite_probe_tbl
WHERE ran_at IS NOT NULL
  AND (isp ILIKE '%amazon%' OR org ILIKE '%amazon%');


-- ---------------------------------------------------------------------------
-- 4. The operative check, as the decomposer will use it.
--
-- A range is excluded from decomposition when its probed isp or org matches any
-- active pattern. A range that has NOT been probed has no registrant, so it
-- cannot be matched and must not be decomposed yet either: decomposing before the
-- registrant is known would defeat the rule entirely.
-- ---------------------------------------------------------------------------

SELECT p.network,
       masklen(p.network) AS len,
       p.isp,
       p.org,
       CASE
         WHEN p.ran_at IS NULL THEN 'defer, registrant unknown'
         WHEN EXISTS (
              SELECT 1 FROM decomposition_exclusions d
               WHERE d.active
                 AND (p.isp ILIKE d.operator_pattern OR p.org ILIKE d.operator_pattern)
         ) THEN 'excluded from decomposition'
         ELSE 'decompose'
       END AS decision
FROM ip2city_dbiplite_probe_tbl p
WHERE masklen(p.network) < 24
ORDER BY masklen(p.network), p.network
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 5. Which operators dominate the decomposition workload.
--
-- This is how to find the patterns worth adding: the operators whose wide ranges
-- would generate the most /24 rows. Only probed ranges appear, since an unprobed
-- range has no registrant.
-- ---------------------------------------------------------------------------

SELECT coalesce(isp, org, 'unknown')                          AS operator,
       count(*)                                               AS wide_ranges,
       sum(2 ^ (24 - masklen(network)))::bigint                AS sub24_rows_they_would_generate,
       min(masklen(network))                                   AS widest
FROM ip2city_dbiplite_probe_tbl
WHERE masklen(network) < 24
  AND ran_at IS NOT NULL
GROUP BY 1
ORDER BY sub24_rows_they_would_generate DESC
LIMIT 30;
