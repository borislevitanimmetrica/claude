-- geo_exclusions_seed_dod.sql
-- Seed the permanent DoD exclusions. Run geo_exclusions.sql first.
--
-- WHY: measured 2026-09-01, 12 probes across 9 different /8s of DoD space
-- returned only TWO locations -- Columbus OH 43218 (DoD Network Information
-- Center / DISA) and Sierra Vista AZ 85613 (USAISC, Fort Huachuca). 22.1.1.1
-- and 22.162.5.1 (162 /16s apart) gave the identical ZIP. These are whois
-- REGISTRANT addresses, not subscriber locations. No subscription tier adds
-- geo data that does not exist, so excluding this space loses nothing.
--
-- SOURCE for the /8 list: IANA IPv4 Address Space Registry
-- https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.txt
--
-- Contains NO backslashes so it survives copy/paste.

-- The 12 /8s that IANA designates to DoD-affiliated organisations.
INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('6.0.0.0/8',   'IANA: Army Information Systems Center - registrant geo only'),
    ('11.0.0.0/8',  'IANA: DoD Intel Information Systems - registrant geo only'),
    ('21.0.0.0/8',  'IANA: DDN-RVN - registrant geo only'),
    ('22.0.0.0/8',  'IANA: Defense Information Systems Agency - registrant geo only'),
    ('26.0.0.0/8',  'IANA: Defense Information Systems Agency - registrant geo only'),
    ('28.0.0.0/8',  'IANA: DSI-North - registrant geo only'),
    ('29.0.0.0/8',  'IANA: Defense Information Systems Agency - registrant geo only'),
    ('30.0.0.0/8',  'IANA: Defense Information Systems Agency - registrant geo only'),
    ('33.0.0.0/8',  'IANA: DLA Systems Automation Center - registrant geo only'),
    ('55.0.0.0/8',  'IANA: DoD Network Information Center - registrant geo only'),
    ('214.0.0.0/8', 'IANA: US-DOD - registrant geo only'),
    ('215.0.0.0/8', 'IANA: US-DOD - registrant geo only')
ON CONFLICT DO NOTHING;

-- DISCREPANCY, your decision: IANA labels 7/8 "Administered by ARIN", but your
-- bgp_route_views shows AS749 (DoD) originating it. Uncomment to exclude.
-- INSERT INTO geo_exclusions (prefix, reason) VALUES
--     ('7.0.0.0/8', 'AS749 (DoD) originates this despite IANA ARIN designation')
-- ON CONFLICT DO NOTHING;

-- DoD space also exists as legacy /14-/16s inside ARIN-administered /8s, which
-- a /8 rule cannot reach. Observed examples (probed as DoD/USAISC):
--   134.233.0.0/16, 158.14.0.0/16, 164.236.0.0/14, 205.0.0.0/11
-- Rather than hand-maintain these, let the probe stage self-populate: when
-- ip-api returns a DoD signature, insert the range as an exclusion. See the
-- detection predicate below (org/isp match, or the two registrant ZIPs).
-- Uncomment the four observed ones now if you prefer immediate suppression.
-- INSERT INTO geo_exclusions (prefix, reason) VALUES
--     ('134.233.0.0/16', 'probed: USAISC Fort Huachuca registrant geo'),
--     ('158.14.0.0/16',  'probed: USAISC Fort Huachuca registrant geo'),
--     ('164.236.0.0/14', 'probed: DoD NIC registrant geo'),
--     ('205.0.0.0/11',   'probed: DoD NIC registrant geo')
-- ON CONFLICT DO NOTHING;

SELECT id, prefix, origin_asn, reason FROM geo_exclusions ORDER BY prefix, origin_asn;


-- ---------------------------------------------------------------------------
-- Measure what the exclusion actually saves in probe budget.
-- ---------------------------------------------------------------------------
SELECT 'probe budget saved by active prefix exclusions' AS section;
SELECT count(*) AS dbip_ranges_excluded,
       sum(pow(2, greatest(0, 24 - masklen(d.network)))::bigint) AS probes_avoided,
       round(sum(pow(2, greatest(0, 24 - masklen(d.network)))::bigint) / 64800.0, 1)
           AS days_saved_at_45_per_min
FROM ip2city_dbiplite_tbl d
WHERE family(d.network) = 4
  AND EXISTS (SELECT 1 FROM geo_exclusions x
              WHERE x.active AND x.prefix IS NOT NULL
                AND d.network <<= x.prefix);
