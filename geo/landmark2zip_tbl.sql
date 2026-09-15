-- landmark2zip_tbl.sql
-- Landmarks: domain-named servers known to sit on the premises of an institution
-- whose street address, and therefore ZIP code, is known. County and municipal
-- governments, schools, school districts, universities and similar.
--
-- WHY LANDMARKS ARE WORTH THE TROUBLE
--
-- ip-api's own zip field is not usable on its own for ZIP-level targeting. Measured
-- on AS21928, 13 of 40 probes returned a PO-Box, airport or unique ZIP, or no ZIP at
-- all: 60666 is O'Hare, 07175 and 75270 are PO-Box ranges, 30333 is a CDC unique
-- ZIP. No PRIZM or Census cohort contains those, so an address carrying one is
-- unbuyable at ZIP level however correct the measurement was.
--
-- A landmark inverts the problem. Instead of asking a geolocation vendor where an
-- address is, it starts from a street address that is known, resolves the
-- institution's own server, and reads the containing BGP range off that. The ZIP is
-- then a postal fact rather than an inference.
--
-- THREE CORRECTIONS TO THE DRAFT DDL, EACH VERIFIED
--
-- 1. CREATE INDEX ... USING ip is not valid SQL. USING names an access METHOD
--    (btree, gist, hash), not a column. It fails with "syntax error at end of
--    input", so the table would have been created with no index and the error might
--    have been read as harmless. Written below as a btree on (ip), which is what
--    equality lookups on a single address want.
--
-- 2. PRIMARY KEY (organization) is not unique in the United States. Lincoln County
--    exists in roughly two dozen states, and Washington Elementary School in more.
--    The key here is (organization, city, state_code).
--
-- 3. The table name was landmark2zip_tbl in the CREATE but landmarks2zip_tbl in the
--    index name and in prose. Singular throughout, matching dma2city_tbl and
--    city2zip_tbl.
--
-- ZIP IS text, NOT integer, and that is deliberate: 02301 Brockton and 07175 Newark
-- lose their leading zero as integers.
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
    -- and without it every re-run redoes the RDAP work to find out.
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
-- twelve street addresses has twelve ZIPs behind one domain and one address. That is
-- the common case, not an anomaly, and it is the origin of the many-ZIPs-per-range
-- problem handled below.
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
-- range2zip_tbl. THE COMPLETE RECORD OF WHICH ZIPS A RANGE TOUCHES.
--
-- This exists ALONGSIDE the single-valued zip_landmark column on the probe table,
-- and the division of labour matters:
--
--   range2zip_tbl                     EVERY landmark ZIP for a range. Many rows per
--                                     network. Nothing is lost here.
--
--   probe_tbl.zip_landmark            ONE ZIP, set only when the range resolves
--                                     unambiguously to a single ZIP. This is what
--                                     zip_definitive reads.
--
-- WHY THE PROBE ROW IS NOT DUPLICATED INSTEAD. The draft proposed duplicating the
-- ip2city_dbiplite_probe_tbl row per ZIP. That breaks the cycle rollover, provably:
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
-- Duplication would also inflate the cycle-gate row count and multiply the parent
-- rows apply_splits sees through its join on network. Keeping the many-valued data
-- in its own table keyed (network, zip) costs nothing and breaks nothing.
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
    'Every landmark-derived ZIP for a BGP range. Many ZIPs per range is normal, because an ISP headend commonly serves several. The multi-ZIP query path reads this; the single-ZIP convenience column on the probe table is derived from it.';


-- ---------------------------------------------------------------------------
-- PROBE TABLE COLUMNS, IN THREE GROUPS.
--
-- Group 1, the db-ip original. Today ip2city_dbiplite_probe_tbl.city is loaded from
-- db-ip at rebuild and then OVERWRITTEN in place by the probe:
--
--     city = coalesce($10, city)
--
-- so after probing there is no way to recover what db-ip said, nor to measure how
-- far the probe moved the answer. These two preserve it.
--
-- Group 2, the landmark values. zip is NOT touched: it belongs to the probe and
-- keeps holding ip-api's answer, so the measured and the postal values stay
-- comparable instead of one silently replacing the other.
--
-- Group 3, the definitive values, which are what the API should read.
-- ---------------------------------------------------------------------------

ALTER TABLE ip2city_dbiplite_probe_tbl
    ADD COLUMN IF NOT EXISTS city_dbip            text,
    ADD COLUMN IF NOT EXISTS state_code_dbip      text,
    ADD COLUMN IF NOT EXISTS city_landmark        text,
    ADD COLUMN IF NOT EXISTS state_code_landmark  text,
    ADD COLUMN IF NOT EXISTS zip_landmark         text,

    -- HOW MANY DISTINCT LANDMARK ZIPS THIS RANGE ACTUALLY TOUCHES.
    --
    -- Without this, zip_landmark IS NULL means two completely different things: no
    -- landmark was found, or several were found and disagreed. Conflating "unknown"
    -- with "ambiguous" is the specific mistake that has cost this project time
    -- before, so the two are kept distinguishable.
    --
    -- 0 means no landmark. 1 means zip_landmark is set and trustworthy. Above 1
    -- means the range spans several ZIPs, zip_landmark is deliberately NULL, and any
    -- single ZIP for the range would be wrong. Read range2zip_tbl for those.
    ADD COLUMN IF NOT EXISTS zip_landmark_count   integer;

COMMENT ON COLUMN ip2city_dbiplite_probe_tbl.city_dbip IS
    'The db-ip city as loaded at rebuild. Never overwritten by a probe, so the db-ip original stays recoverable and the probe delta is measurable.';
COMMENT ON COLUMN ip2city_dbiplite_probe_tbl.zip_landmark IS
    'Landmark-derived ZIP, set ONLY when the range resolves to exactly one. NULL when there is no landmark and also when there are several: read zip_landmark_count to tell those apart, and range2zip_tbl for the full set.';
COMMENT ON COLUMN ip2city_dbiplite_probe_tbl.zip_landmark_count IS
    'Count of distinct landmark ZIPs for this range. 0 none, 1 unambiguous, above 1 ambiguous and zip_landmark is NULL by design.';


-- The definitive columns are GENERATED, in a separate statement because a
-- generation expression can only reference columns that already exist.
--
-- STORED and generated rather than maintained by a job or a trigger, so they cannot
-- drift from their inputs. The probe's own UPDATE of city, state_code and zip
-- recomputes them automatically, as does any landmark write.
--
-- COST: adding a STORED generated column REWRITES the table and holds an ACCESS
-- EXCLUSIVE lock for the duration. On roughly 2.09 million rows that is tens of
-- seconds. Do not run it at five past the hour, when probe_batch starts.

ALTER TABLE ip2city_dbiplite_probe_tbl
    ADD COLUMN IF NOT EXISTS city_definitive text
        GENERATED ALWAYS AS (coalesce(city_landmark, city)) STORED,
    ADD COLUMN IF NOT EXISTS state_code_definitive text
        GENERATED ALWAYS AS (coalesce(state_code_landmark, state_code)) STORED,
    ADD COLUMN IF NOT EXISTS zip_definitive text
        GENERATED ALWAYS AS (coalesce(zip_landmark, zip)) STORED;

COMMENT ON COLUMN ip2city_dbiplite_probe_tbl.zip_definitive IS
    'The ZIP to target on. Landmark ZIP where one exists, otherwise the ip-api ZIP. Generated, so it cannot drift. NOTE: where zip_landmark_count is above 1 this falls back to the ip-api ZIP for a range known to span several ZIPs, so a consumer wanting only defensible ZIPs should require zip_landmark_count <= 1.';

CREATE INDEX IF NOT EXISTS ip2city_dbiplite_probe_tbl_zip_definitive_idx
    ON ip2city_dbiplite_probe_tbl (zip_definitive)
    WHERE zip_definitive IS NOT NULL;

CREATE INDEX IF NOT EXISTS ip2city_dbiplite_probe_tbl_city_definitive_idx
    ON ip2city_dbiplite_probe_tbl (city_definitive, state_code_definitive);


-- Backfill the db-ip originals from the current values, for rows not yet probed
-- where city still holds the db-ip value. A probed row has already been overwritten
-- and its db-ip original is unrecoverable until the next rebuild populates
-- city_dbip directly.
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
--     SELECT network FROM ip2city_dbiplite_probe_tbl WHERE network >>= $1
--
-- A btree index cannot serve that. Measured on 500,000 rows: Index Only Scan
-- 0.387 ms with this index, Parallel Seq Scan 12.077 ms without. At 2.09 million
-- rows the unindexed path is roughly 50 ms per landmark, which turns twenty
-- thousand landmarks into about seventeen minutes of scanning instead of eight
-- seconds. PostgreSQL commutes addr <<= network into network >>= addr, so either
-- spelling uses the index.
--
-- Run as boris. It takes minutes on the live table and holds a lock, so keep it
-- away from five past the hour.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ip2city_dbiplite_probe_tbl_network_gist
    ON ip2city_dbiplite_probe_tbl
    USING gist (network inet_ops);


-- ---------------------------------------------------------------------------
-- REFRESH THE LANDMARK COLUMNS FROM range2zip_tbl.
--
-- Idempotent. Run after every landmark resolution pass. Safe to run at any time: it
-- touches only the landmark columns, never the probe's own values, and the
-- definitive columns follow automatically because they are generated.
--
-- CITY AND ZIP ARE COUNTED SEPARATELY, and that is not fussiness. Measured on
-- 76.90.64.0/20, Charter returned ONE city (Hemet) and THREE ZIPs (92543, 92544,
-- 92545). Counting them together would discard a perfectly good city because the
-- ZIP was ambiguous. City survives, ZIP does not, which is also why the DMA tier is
-- unaffected by ZIP ambiguity: DMA resolves through city.
-- ---------------------------------------------------------------------------

UPDATE ip2city_dbiplite_probe_tbl p
   SET zip_landmark        = CASE WHEN agg.zip_n = 1  THEN agg.zip        ELSE NULL END,
       city_landmark       = CASE WHEN agg.city_n = 1 THEN agg.city       ELSE NULL END,
       state_code_landmark = CASE WHEN agg.city_n = 1 THEN agg.state_code ELSE NULL END,
       zip_landmark_count  = agg.zip_n
  FROM (
        SELECT network,
               count(DISTINCT zip)                                   AS zip_n,
               count(DISTINCT city || '|' || state_code)              AS city_n,
               min(zip)                                              AS zip,
               min(city)                                             AS city,
               min(state_code)                                       AS state_code
          FROM range2zip_tbl
         GROUP BY network
       ) agg
 WHERE p.network = agg.network;

-- Ranges with no landmark at all get a count of 0 rather than NULL, so that "never
-- looked at" and "looked at, found nothing" stay distinguishable.
UPDATE ip2city_dbiplite_probe_tbl p
   SET zip_landmark_count = 0
 WHERE p.zip_landmark_count IS NULL
   AND NOT EXISTS (SELECT 1 FROM range2zip_tbl z WHERE z.network = p.network);


-- ---------------------------------------------------------------------------
-- 1. WHAT THE LANDMARKS RESOLVE TO. Run after the resolver has populated ip.
--
-- Groups by the registrant owning the address, which is what decides whether a
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
-- 2. HOW MANY ZIPS PER RANGE. The number that decides how much of the ZIP tier is
-- defensible.
--
-- 1 is a clean assignment and populates zip_landmark. Several is the headend case,
-- leaves zip_landmark NULL, and is served only through range2zip_tbl. A range
-- carrying a dozen ZIPs is an argument for decomposing it further rather than for
-- trusting any ZIP on it.
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
-- 3. WHERE THE DEFINITIVE VALUES COME FROM.
--
-- The honest accounting of the ZIP tier: how much rests on a postal landmark and how
-- much falls back to an ip-api measurement, including the ambiguous ranges where
-- that fallback is knowingly wrong.
-- ---------------------------------------------------------------------------

SELECT CASE
         WHEN zip_landmark IS NOT NULL                       THEN 'landmark, unambiguous'
         WHEN coalesce(zip_landmark_count, 0) > 1            THEN 'ip-api fallback, range spans several ZIPs'
         WHEN zip IS NOT NULL                                THEN 'ip-api fallback, no landmark'
         ELSE                                                     'no ZIP at all'
       END                                                   AS zip_provenance,
       count(*)                                              AS ranges,
       round(100.0 * count(*) / greatest(sum(count(*)) OVER (), 1), 2) AS pct
FROM ip2city_dbiplite_probe_tbl
WHERE ran_at IS NOT NULL
  AND status = 'success'
GROUP BY 1
ORDER BY ranges DESC;


-- ---------------------------------------------------------------------------
-- 4. DOES THE LANDMARK DISAGREE WITH ip-api. Worth reading once populated.
--
-- A disagreement is not an error. The landmark is a postal fact and ip-api is a
-- measurement, so where they differ the landmark should win, which is what
-- zip_definitive does. A LARGE disagreement set, or one concentrated in a few
-- operators, is a finding about the operator rather than about the landmark.
-- ---------------------------------------------------------------------------

SELECT p.network,
       p.city_definitive,
       p.state_code_definitive,
       p.zip_landmark,
       p.zip                AS zip_ipapi,
       p.isp
FROM ip2city_dbiplite_probe_tbl p
WHERE p.zip_landmark IS NOT NULL
  AND p.zip IS NOT NULL
  AND p.zip_landmark <> p.zip
ORDER BY p.network
LIMIT 50;
