-- geo_exclusions_seed_dod_extra.sql
-- DoD ranges that sit INSIDE ARIN-administered /8s, so no /8 rule reaches them.
-- Every prefix below was verified by direct ip-api probe on 2026-09-01; the
-- org/isp field named DoD explicitly. Probe evidence in comments.
--
-- Run after geo_exclusions.sql and geo_exclusions_seed_dod.sql.
--
-- Contains NO backslashes so it survives copy/paste.

-- 7/8: IANA designates this to ARIN, but AS749 (DoD) originates it and the
-- probe confirms DoD. Your data overrides the registry designation.
INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('7.0.0.0/8', 'probed 7.1.1.1: AS749 DoD NIC (IANA says ARIN; data wins)')
ON CONFLICT DO NOTHING;

-- Verified DoD blocks inside non-DoD /8s.
INSERT INTO geo_exclusions (prefix, reason) VALUES
    ('132.80.0.0/12',  'probed 132.80.1.1: AS306 USAISC (DoD)'),
    ('132.128.0.0/12', 'probed 132.128.1.1: AS306 USAISC (DoD)'),
    ('205.0.0.0/11',   'probed 205.0.1.1: AS749 DoD NIC'),
    ('205.32.0.0/12',  'probed 205.32.1.1: AS749 DoD NIC'),
    ('134.233.0.0/16', 'probed 134.233.1.1: AS721 USAISC (DoD)'),
    ('158.14.0.0/16',  'probed 158.14.108.1: AS367 USAISC (DoD)'),
    ('164.236.0.0/14', 'probed 164.236.1.1: AS721 DoD NIC')
ON CONFLICT DO NOTHING;

-- Additional DoD origin ASNs observed in probes. ASN rules catch DoD space
-- wherever announced, including ranges not yet enumerated as prefixes.
-- AS306 and AS367 were confirmed by probe (USAISC).
INSERT INTO geo_exclusions (origin_asn, reason) VALUES
    (306, 'probed 132.80.1.1 / 132.128.1.1: USAISC (DoD)'),
    (367, 'probed 158.14.108.1: USAISC (DoD)')
ON CONFLICT DO NOTHING;

-- NOTE deliberately NOT added: AS347, AS370, AS331, AS335, AS365, AS27064,
-- AS571, AS1208, AS1540, AS1563, AS1567, AS1568, AS1602, AS6307, AS5972,
-- AS637, AS668, AS27047, AS27069, AS27086, AS325-AS353, AS4196, AS10837,
-- AS5852. Several appear in DoD-looking space but are UNVERIFIED. Some may be
-- commercial. Verify by probe before excluding -- do not exclude on a hunch.

SELECT 'active exclusions now in force' AS section;
SELECT id, prefix, origin_asn, reason FROM geo_exclusions
WHERE active ORDER BY prefix NULLS LAST, origin_asn;
