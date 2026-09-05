-- geo_exclusions_seed_all.sql
-- One file that seeds every DoD exclusion verified so far. Run this INSTEAD of
-- geo_exclusions_seed_dod.sql plus geo_exclusions_seed_dod_extra.sql.
-- Requires geo_exclusions.sql to have created the table.
--
-- WHY: probes into DoD space return the whois REGISTRANT address, not the
-- subscriber location. Observed registrant cities are Columbus OH, Whitehall OH
-- and Sierra Vista AZ; 22.1.1.1 and 22.162.5.1, 162 /16s apart, returned the
-- identical ZIP. No subscription tier adds geography that does not exist, so
-- excluding this space costs nothing and saves roughly 7 probe-days.
--
-- Matching is by PREFIX or ORIGIN ASN only, never by city or ZIP: those three
-- registrant cities are real metros holding legitimate commercial ranges, and
-- excluding on location would silently discard good data.
--
-- Contains NO backslashes so it survives copy/paste.

-- The 12 /8s IANA designates to DoD-affiliated organisations.
-- Source: IANA IPv4 Address Space Registry
-- https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.txt
INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('6.0.0.0/8',   'IANA: Army Information Systems Center'),
    ('11.0.0.0/8',  'IANA: DoD Intel Information Systems'),
    ('21.0.0.0/8',  'IANA: DDN-RVN'),
    ('22.0.0.0/8',  'IANA: Defense Information Systems Agency'),
    ('26.0.0.0/8',  'IANA: Defense Information Systems Agency'),
    ('28.0.0.0/8',  'IANA: DSI-North'),
    ('29.0.0.0/8',  'IANA: Defense Information Systems Agency'),
    ('30.0.0.0/8',  'IANA: Defense Information Systems Agency'),
    ('33.0.0.0/8',  'IANA: DLA Systems Automation Center'),
    ('55.0.0.0/8',  'IANA: DoD Network Information Center'),
    ('214.0.0.0/8', 'IANA: US-DOD'),
    ('215.0.0.0/8', 'IANA: US-DOD')
ON CONFLICT DO NOTHING;

-- 7/8: IANA designates this to ARIN, but AS749 (DoD) originates it in your
-- bgp_route_views and the probe confirmed DoD. Observed data overrides the
-- registry designation.
INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('7.0.0.0/8', 'probed 7.1.1.1: AS749 DoD NIC (IANA says ARIN; data wins)')
ON CONFLICT DO NOTHING;

-- DoD blocks inside ARIN-administered /8s, which no /8 rule can reach.
-- Every one of these was confirmed by a direct ip-api probe.
INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('132.80.0.0/12',  'probed 132.80.1.1: AS306 USAISC (DoD)'),
    ('132.128.0.0/12', 'probed 132.128.1.1: AS306 USAISC (DoD)'),
    ('205.0.0.0/11',   'probed 205.0.1.1: AS749 DoD NIC'),
    ('205.32.0.0/12',  'probed 205.32.1.1: AS749 DoD NIC'),
    ('134.233.0.0/16', 'probed 134.233.1.1: AS721 USAISC (DoD)'),
    ('158.14.0.0/16',  'probed 158.14.108.1: AS367 USAISC (DoD)'),
    ('164.236.0.0/14', 'probed 164.236.1.1: AS721 DoD NIC')
ON CONFLICT DO NOTHING;

-- DoD origin ASNs confirmed by probe. AS749 and AS721 may already be present.
INSERT INTO geo_exclusions (origin_asn, reason) VALUES
    (749, 'US DoD - registrant geo only'),
    (721, 'US DoD - registrant geo only'),
    (306, 'probed 132.80.1.1 and 132.128.1.1: USAISC (DoD)'),
    (367, 'probed 158.14.108.1: USAISC (DoD)')
ON CONFLICT DO NOTHING;

-- NOT added deliberately: AS347, AS370, AS331, AS335, AS365, AS27064, AS571,
-- AS1208, AS1540, AS1563, AS1567, AS1568, AS1602, AS6307, AS5972, AS637,
-- AS668, AS27047, AS27069, AS27086, AS325 through AS353, AS4196, AS10837,
-- AS5852. These appear in DoD-looking space but are UNVERIFIED and some may be
-- commercial. Let classify_ranges probe them rather than excluding on a hunch.

SELECT 'active exclusions now in force' AS section;
SELECT count(*) FILTER (WHERE prefix IS NOT NULL) AS prefix_rules,
       count(*) FILTER (WHERE origin_asn IS NOT NULL) AS asn_rules
FROM geo_exclusions WHERE active;

SELECT 'probe budget removed from dbip_split_candidates' AS section;
SELECT count(*) AS ranges_excluded,
       coalesce(sum(pow(2, greatest(0, 24 - masklen(c.network)))::bigint), 0) AS probes_avoided,
       round(coalesce(sum(pow(2, greatest(0, 24 - masklen(c.network)))::bigint), 0) / 64800.0, 1) AS days_saved
FROM dbip_split_candidates c
WHERE EXISTS (SELECT 1 FROM geo_exclusions x
              WHERE x.active AND x.prefix IS NOT NULL
                AND c.network <<= x.prefix);

SELECT 'probe budget remaining' AS section;
SELECT count(*) AS ranges,
       coalesce(sum(pow(2, greatest(0, 24 - masklen(c.network)))::bigint), 0) AS probes,
       round(coalesce(sum(pow(2, greatest(0, 24 - masklen(c.network)))::bigint), 0) / 64800.0, 1) AS days
FROM dbip_split_candidates c
WHERE NOT EXISTS (SELECT 1 FROM geo_exclusions x
                  WHERE x.active AND x.prefix IS NOT NULL
                    AND c.network <<= x.prefix);
