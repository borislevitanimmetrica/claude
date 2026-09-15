-- landmark2zip_tbl.sql
-- Landmarks: domain-named servers known to sit on the premises of an institution
-- whose street address, and therefore ZIP code, is known. County and municipal
-- governments, schools, school districts, universities and similar.
--
-- WHY LANDMARKS ARE WORTH THE TROUBLE
--
-- ip-api's own zip field is not usable for ZIP-level targeting. Measured on
-- AS21928, 13 of 40 probes returned a PO-Box, airport or unique ZIP, or no ZIP at
-- all: 60666 is O'Hare, 07175 and 75270 are PO-Box ranges, 30333 is a CDC unique
-- ZIP. No PRIZM or Census cohort contains those, so an address carrying one is
-- unbuyable at ZIP level however correct the measurement was.
--
-- A landmark inverts the problem. Instead of asking a geolocation vendor where an
-- address is, it starts from a street address that is known, resolves the
-- institution's own server, and reads the containing BGP range off that. The ZIP is
-- then a postal fact rather than an inference.
--
-- THREE CORRECTIONS TO THE DRAFT DDL, EACH OF WHICH WOULD HAVE BITTEN
--
-- 1. CREATE INDEX ... USING ip is not valid SQL. USING names an access METHOD
--    (btree, gist, hash), not a column. The statement fails with a syntax error at
--    or near "ip", so the table would have been created without the index and the
--    error might have been read as harmless. Written below as a btree on (ip),
--    which is what equality lookups on a single address want.
--
-- 2. PRIMARY KEY (organization) is not unique in the United States. Lincoln County
--    exists in roughly two dozen states, and Washington Elementary School in more.
--    The second insert of a same-named institution in another state is silently
--    rejected by ON CONFLICT DO NOTHING, or aborts a plain insert. The key here is
--    (organization, city, state_code), which is the natural key of "which
--    institution, where".
--
-- 3. The table name was landmark2zip_tbl in the CREATE but landmarks2zip_tbl in
--    the index name and in prose. Singular is used throughout here, matching
--    dma2city_tbl and city2zip_tbl.
--
-- ZIP IS text, NOT integer, and that is deliberate: 02301 Brockton and 07175
-- Newark lose their leading zero as integers.
--
-- Contains NO backslashes so it survives copy/paste.


CREATE TABLE IF NOT EXISTS landmark2zip_tbl (

    organization      text NOT NULL,
    street_address_1  text,
    street_address_2  text,
    city              text NOT NULL,
    state_code        text NOT NULL,
    zip               text NOT NULL,
    domain            text NOT NULL,
    ip                inet,

    -- RESOLUTION AND VERIFICATION STATE.
    --
    -- The draft said a record whose registrant is a cloud provider or another unit
    -- of government "will be ignored". Recording WHY it was ignored is better than
    -- ignoring it silently: a landmark rejected today may be on-premises next year,
    -- the rejection reason is the only way to audit the yield of the whole method,
    -- and without it every re-run has to redo the RDAP work to find out.
    resolved_at       timestamptz,
    rdap_registrant   text,
    on_prem           boolean,
    verdict           text,

    CONSTRAINT landmark2zip_tbl_zip_shape_ck
        CHECK (zip ~ '^[0-9]{5}$'),

    PRIMARY KEY (organization, city, state_code)
);

-- Equality lookups on a resolved address. Partial, because an unresolved landmark
-- has no address and there is no reason to index the NULLs.
CREATE INDEX IF NOT EXISTS landmark2zip_tbl_ip_idx
    ON landmark2zip_tbl (ip)
    WHERE ip IS NOT NULL;

-- One domain can legitimately serve many rows: a district with twelve schools at
-- twelve street addresses has twelve ZIPs behind one domain and one address. That
-- is the common case, not an anomaly, and it is the origin of the many-ZIPs-per-
-- range problem addressed below.
CREATE INDEX IF NOT EXISTS landmark2zip_tbl_domain_idx
    ON landmark2zip_tbl (domain);

CREATE INDEX IF NOT EXISTS landmark2zip_tbl_onprem_idx
    ON landmark2zip_tbl (on_prem)
    WHERE on_prem;

COMMENT ON TABLE landmark2zip_tbl IS
    'Institutions with a known street address and an on-premises server reachable by domain. Resolved to an address, verified by RDAP, and used to attach a postal ZIP to the containing BGP range. One row per institution per place; a domain may repeat across rows.';
COMMENT ON COLUMN landmark2zip_tbl.domain IS
    'Resolved on every run rather than trusted once, so an address change is picked up instead of silently invalidating the landmark.';
COMMENT ON COLUMN landmark2zip_tbl.on_prem IS
    'NULL until verified. True when RDAP indicates the address is at the institution or on an eyeball ISP serving it. False when it is cloud, CDN, or another unit of government.';


-- ---------------------------------------------------------------------------
-- range2zip_tbl. WHERE THE LANDMARK ZIP ACTUALLY LANDS.
--
-- THIS REPLACES DUPLICATING ROWS IN ip2city_dbiplite_probe_tbl, AND THE REASON IS
-- A HARD CONSTRAINT RATHER THAN A PREFERENCE.
--
-- The plan was to duplicate the probe row when several ZIPs resolve to one
-- decomposed range. That breaks the cycle rollover, provably:
--
--   1. ip2city_dbiplite_history_tbl requires PRIMARY KEY (network, ran_at). This is
--      enforced at runtime: rebuild_probe_tbl.sql raises an exception if it finds a
--      single-column key, because only one cycle could otherwise be archived.
--
--   2. check_geo_ip-api writes results with UPDATE ... WHERE network = $1, setting
--      ran_at = now(). With N duplicates of a network, one statement stamps all N
--      rows with an IDENTICAL ran_at, because now() is fixed within a statement.
--
--   3. The archive step then inserts N rows sharing (network, ran_at) into the
--      history table, violating its primary key. The transaction rolls back, the
--      probe table is never rebuilt, and the pipeline stops rolling over.
--
-- Duplication also inflates the cycle-gate row count and multiplies the parent
-- rows apply_splits sees through its join on network.
--
-- A separate table with PRIMARY KEY (network, zip) carries as many ZIPs per range
-- as reality requires, and leaves the probe table's identity, its write path, its
-- backlog arithmetic and its archive untouched. This is the same shape
-- dma2city_tbl already uses to hold many rows per city.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS range2zip_tbl (

    network       cidr        NOT NULL,
    zip           text        NOT NULL,
    city          text        NOT NULL,
    state_code    text        NOT NULL,

    -- Which landmark asserted this, so a wrong ZIP can be traced to its source and
    -- the source corrected rather than the symptom patched.
    organization  text,
    landmark_ip   inet,

    -- landmark now, leaving room for a later method without a schema change.
    source        text        NOT NULL DEFAULT 'landmark',
    assigned_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT range2zip_tbl_zip_shape_ck
        CHECK (zip ~ '^[0-9]{5}$'),

    PRIMARY KEY (network, zip)
);

CREATE INDEX IF NOT EXISTS range2zip_tbl_zip_idx
    ON range2zip_tbl (zip);

CREATE INDEX IF NOT EXISTS range2zip_tbl_city_state_idx
    ON range2zip_tbl (city, state_code);

COMMENT ON TABLE range2zip_tbl IS
    'Landmark-derived ZIP codes attached to BGP ranges. Many ZIPs per range is normal and expected, because an ISP headend commonly serves several ZIPs. Keyed (network, zip) so the probe table never has to carry duplicate rows.';


-- ---------------------------------------------------------------------------
-- PROBE TABLE ADDITIONS.
--
-- Only the two columns that preserve the db-ip original. These are safe because
-- they add no rows: one value per range, so nothing about the key, the write path
-- or the archive changes.
--
-- The landmark city, state_code and zip are deliberately NOT added here. They are
-- one-to-many against network and belong in range2zip_tbl for the reason set out
-- above.
--
-- WHY city_dbip IS NEEDED. Today ip2city_dbiplite_probe_tbl.city is populated from
-- db-ip at rebuild and then OVERWRITTEN in place by the ip-api probe:
--
--   city = coalesce($10, city)
--
-- So after probing there is no way to recover what db-ip said, and no way to
-- measure how far the probe moved the answer. Splitting them makes the comparison
-- possible and makes the provenance of every value explicit.
--
-- NOTE ON zip: the probe table ALREADY HAS a zip column, and check_geo_ip-api
-- writes ip-api's zip into it on every probe. It is therefore NOT free for landmark
-- use, and overloading it would mix a measured value with a postal one and lose the
-- ability to tell them apart. The landmark ZIP lives in range2zip_tbl. If a column
-- on the probe table is wanted later for convenience, it must be named zip_landmark
-- and left distinct from zip.
-- ---------------------------------------------------------------------------

ALTER TABLE ip2city_dbiplite_probe_tbl
    ADD COLUMN IF NOT EXISTS city_dbip       text,
    ADD COLUMN IF NOT EXISTS state_code_dbip text;

COMMENT ON COLUMN ip2city_dbiplite_probe_tbl.city_dbip IS
    'The db-ip city as loaded at rebuild. Never overwritten by a probe, so the db-ip original stays recoverable and the probe delta is measurable.';

-- Backfill from the current values for rows not yet probed, where city still holds
-- the db-ip original. A probed row has already been overwritten and its db-ip value
-- is unrecoverable until the next rebuild populates city_dbip directly.
UPDATE ip2city_dbiplite_probe_tbl
   SET city_dbip       = city,
       state_code_dbip = state_code
 WHERE ran_at IS NULL
   AND city_dbip IS NULL;


-- ---------------------------------------------------------------------------
-- CONTAINMENT INDEX, REQUIRED BEFORE ANY LANDMARK IS MATCHED TO A RANGE.
--
-- Finding the range containing a landmark address is a containment test:
--
--   SELECT network FROM ip2city_dbiplite_probe_tbl WHERE '8.8.8.8'::inet <<= network
--
-- A btree index cannot serve <<=. Without a gist index this is a sequential scan of
-- roughly 2.09 million rows for every landmark, which makes the resolver appear to
-- hang rather than to be slow.
--
-- Run as boris, not cronuser: it requires ownership. It takes minutes and holds a
-- lock, so do it outside the hourly probe window, meaning not near five past the
-- hour. CONCURRENTLY avoids blocking writes but cannot run inside a transaction, so
-- it must be issued on its own.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ip2city_dbiplite_probe_tbl_network_gist
    ON ip2city_dbiplite_probe_tbl
    USING gist (network inet_ops);


-- ---------------------------------------------------------------------------
-- 1. WHAT A LANDMARK RESOLVES TO. Run after the resolver has populated ip.
--
-- Groups by the registrant the address belongs to, which is what decides whether a
-- landmark is on-premises. Uses the RDAP cache already built for decomposition, so
-- it costs no new queries for space already covered.
-- ---------------------------------------------------------------------------

SELECT coalesce(cov.registrant, '(no RDAP row)')      AS registrant,
       count(*)                                       AS landmarks,
       count(DISTINCT l.zip)                          AS distinct_zips,
       count(DISTINCT l.state_code)                   AS states
FROM landmark2zip_tbl l
LEFT JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE l.ip IS NOT NULL
      AND r.start_ip <= l.ip
      AND r.end_ip   >= l.ip
    ORDER BY (r.end_ip - r.start_ip)
    LIMIT 1
) cov ON true
WHERE l.ip IS NOT NULL
GROUP BY 1
ORDER BY landmarks DESC;


-- ---------------------------------------------------------------------------
-- 2. HOW MANY ZIPs PER RANGE. The number that decides whether ZIP targeting is
-- worth doing at all.
--
-- One ZIP per range is a clean assignment. Several is the headend case and is
-- expected. A range carrying a dozen ZIPs is not usable for ZIP targeting and is
-- evidence that the range is too wide, which is an argument for decomposing it
-- further rather than for trusting the ZIP.
-- ---------------------------------------------------------------------------

SELECT zips_per_range,
       count(*) AS ranges
FROM (
    SELECT network, count(DISTINCT zip) AS zips_per_range
    FROM range2zip_tbl
    GROUP BY network
) t
GROUP BY zips_per_range
ORDER BY zips_per_range;


-- ---------------------------------------------------------------------------
-- 3. COVERAGE. How much of the probed, targetable estate carries a landmark ZIP.
--
-- This is the honest measure of the method's reach. A ZIP tier that covers a small
-- fraction of DMA-tier reach is still useful, but the fraction has to be visible
-- rather than assumed, and it has to be watched over time.
-- ---------------------------------------------------------------------------

SELECT count(*)                                                        AS probed_ranges,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM range2zip_tbl z WHERE z.network = p.network))  AS with_landmark_zip,
       round(100.0 * count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM range2zip_tbl z WHERE z.network = p.network))
             / greatest(count(*), 1), 2)                               AS pct_with_zip
FROM ip2city_dbiplite_probe_tbl p
WHERE p.ran_at IS NOT NULL
  AND p.status = 'success';
