-- geo_exclusions.sql
-- Permanent exclusion list for geolocation work.
--
-- Rationale (measured 2026-09-01): 12 probes into DoD space returned only two
-- locations -- Columbus OH 43218 (DoD Network Information Center) and Sierra
-- Vista AZ 85613 (USAISC, Fort Huachuca). 22.1.1.1 and 22.162.5.1, 162 /16s
-- apart, returned the identical ZIP. These are whois REGISTRANT addresses, not
-- subscriber geolocation. Probing this space yields no DMA/ZIP information at
-- any subscription tier, so exclusion costs nothing.
--
-- Two rule kinds are supported; a row uses exactly one.
--   prefix     IS NOT NULL -> exclude any range contained in this CIDR
--   origin_asn IS NOT NULL -> exclude any BGP prefix originated by this ASN
--
-- Contains NO backslashes so it survives copy/paste.

CREATE TABLE IF NOT EXISTS geo_exclusions (
    id          serial PRIMARY KEY,
    prefix      cidr,
    origin_asn  bigint,
    reason      text NOT NULL,
    active      boolean NOT NULL DEFAULT true,
    added_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT geo_exclusions_one_kind CHECK (
        (prefix IS NOT NULL AND origin_asn IS NULL) OR
        (prefix IS NULL AND origin_asn IS NOT NULL)
    )
);

-- Containment lookups (prefix rules). Tiny table, but keeps planner honest.
CREATE INDEX IF NOT EXISTS geo_exclusions_prefix_gist
    ON geo_exclusions USING gist (prefix inet_ops)
    WHERE prefix IS NOT NULL AND active;

CREATE INDEX IF NOT EXISTS geo_exclusions_asn_idx
    ON geo_exclusions (origin_asn)
    WHERE origin_asn IS NOT NULL AND active;

-- Prevent duplicate rules.
CREATE UNIQUE INDEX IF NOT EXISTS geo_exclusions_prefix_uniq
    ON geo_exclusions (prefix) WHERE prefix IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS geo_exclusions_asn_uniq
    ON geo_exclusions (origin_asn) WHERE origin_asn IS NOT NULL;

-- ---------------------------------------------------------------------------
-- SEED: choose (a) and/or (b). Both are safe to apply; they overlap harmlessly.
-- ---------------------------------------------------------------------------

-- (a) Exclude by DoD origin ASN. Catches DoD space wherever it is announced,
--     including ranges outside the obvious legacy /8s.
INSERT INTO geo_exclusions (origin_asn, reason) VALUES
    (749, 'US DoD (AS749) - ip-api returns whois registrant address only'),
    (721, 'US DoD (AS721) - ip-api returns whois registrant address only')
ON CONFLICT DO NOTHING;

-- (b) Exclude by legacy DoD /8 prefix. Uncomment the ones you want.
-- INSERT INTO geo_exclusions (prefix, reason) VALUES
--     ('22.0.0.0/8',  'US DoD legacy /8 - no usable geo data'),
--     ('214.0.0.0/8', 'US DoD legacy /8 - no usable geo data'),
--     ('6.0.0.0/8',   'US Army legacy /8 - no usable geo data'),
--     ('11.0.0.0/8',  'US DoD legacy /8 - no usable geo data'),
--     ('55.0.0.0/8',  'US DoD legacy /8 - no usable geo data')
-- ON CONFLICT DO NOTHING;

SELECT id, prefix, origin_asn, reason, active FROM geo_exclusions ORDER BY id;
