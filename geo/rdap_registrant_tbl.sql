-- rdap_registrant_tbl.sql
-- A cache of RIR registration data, used to identify the registrant of a range
-- before deciding whether to decompose it.
--
-- WHY RDAP RATHER THAN ip-api
--
-- These two sources do NOT contain the same field, and the difference decides
-- where in the workflow the check can run.
--
--   RDAP     returns REGISTRATION data held by the RIR: the organisation an
--            allocation is registered to, its handle, and for ARIN space the
--            reassignment and reallocation records beneath it. It answers "who
--            holds this numberspace", which is exactly the exclusion question.
--            It is keyed on the PREFIX, so it can be consulted for any range at
--            any time, whether or not that range has ever been probed.
--
--   ip-api   returns isp and org, which are DERIVED commercial descriptions of
--            who appears to be OPERATING an address. They are populated
--            inconsistently, which is why the earlier code had to coalesce isp
--            then org, and they describe the serving network rather than the
--            registrant. They exist only as a side effect of probing one address
--            inside the range.
--
-- The workflow consequence is the operative one. An ip-api registrant can only be
-- known for a range that has already been probed, so decomposition had to defer
-- every unprobed range or bypass the exclusion entirely. RDAP has no such
-- coupling: every candidate can be resolved at decomposition time. It also draws
-- on a different budget, so it does not compete with geolocation probing for the
-- 45 calls per minute the free ip-api tier allows.
--
-- WHY THE CACHE IS KEYED ON A RANGE AND NOT ON THE QUERIED PREFIX
--
-- An RDAP answer describes the ALLOCATION that contains the queried address, not
-- the queried prefix. Asking about 54.144.3.0/24 returns the boundaries of the
-- whole Amazon allocation that contains it. Storing the returned boundaries means
-- one lookup answers for every candidate inside that allocation, which turns
-- hundreds of thousands of candidate ranges into a few thousand queries.
--
-- Boundaries are stored as start_ip and end_ip rather than as a cidr because an
-- RDAP range is not required to be a single CIDR block. Containment is therefore
-- tested by address comparison, which is exact, rather than by CIDR masking,
-- which would need the range decomposed into a CIDR set first.
--
-- Contains NO backslashes so it survives copy/paste.


CREATE TABLE IF NOT EXISTS rdap_registrant_tbl (
    id              bigserial   PRIMARY KEY,

    -- The allocation boundaries as the RIR reported them. Containment against a
    -- candidate range is start_ip <= network(candidate) AND end_ip >= broadcast(candidate).
    start_ip        inet        NOT NULL,
    end_ip          inet        NOT NULL,

    -- The registrant name, chosen from the RDAP entity carrying the registrant
    -- role, falling back to the network name when no such entity is published.
    registrant      text,
    registrant_role text,

    -- RIR identifiers, kept for audit. handle is the RIR org or net handle,
    -- network_name is the ARIN NetName or its equivalent.
    handle          text,
    network_name    text,
    rir             text,

    -- What was actually asked, which is NOT the same as the range returned. Kept
    -- so a surprising answer can be traced back to the query that produced it.
    queried_for     cidr,

    http_status     int,
    note            text,
    fetched_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT rdap_registrant_tbl_range_ck CHECK (end_ip >= start_ip)
);

-- Containment lookups scan on start_ip and finish on end_ip.
CREATE INDEX IF NOT EXISTS rdap_registrant_tbl_range_idx
    ON rdap_registrant_tbl (start_ip, end_ip);

-- One row per allocation per query origin. A repeat query for the same
-- allocation updates in place rather than accumulating history, because the
-- registrant is the current fact being asserted, not a time series.
CREATE UNIQUE INDEX IF NOT EXISTS rdap_registrant_tbl_alloc_uniq
    ON rdap_registrant_tbl (start_ip, end_ip);

COMMENT ON TABLE rdap_registrant_tbl IS
    'Cache of RIR RDAP registration data, keyed on the allocation boundaries the RIR returned rather than on the prefix queried. Consulted by apply_splits to identify a registrant without needing the range to have been probed.';


-- ---------------------------------------------------------------------------
-- GRANTS.
--
-- This file has to be run by the table owner, but the pipeline runs as cronuser,
-- which then needs to write here. Without these grants rdap_registrant fails on
-- every single row with "permission denied for sequence
-- rdap_registrant_tbl_id_seq", which is how this omission was found: the table
-- grant alone is not enough, because a bigserial column needs USAGE on its
-- sequence as well.
--
-- The role is looked up rather than assumed, so this file still runs on a database
-- where cronuser does not exist.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cronuser') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON rdap_registrant_tbl TO cronuser;
        GRANT USAGE, SELECT ON SEQUENCE rdap_registrant_tbl_id_seq TO cronuser;
        RAISE NOTICE 'granted rdap_registrant_tbl and its sequence to cronuser';
    ELSE
        RAISE NOTICE 'role cronuser does not exist, so no grants were made';
    END IF;
END
$$;


-- ---------------------------------------------------------------------------
-- 1. THE OPERATIVE LOOKUP, as apply_splits performs it.
--
-- Most specific covering allocation wins, measured by span, so a reassignment
-- inside a larger allocation takes precedence over the parent.
-- ---------------------------------------------------------------------------

-- Substitute the range being tested.
SELECT r.registrant,
       r.registrant_role,
       r.handle,
       r.network_name,
       r.start_ip,
       r.end_ip,
       (r.end_ip - r.start_ip) + 1 AS addresses_in_allocation,
       r.fetched_at
FROM rdap_registrant_tbl r
WHERE r.start_ip <= host(network('54.144.0.0/16'::cidr))::inet
  AND r.end_ip   >= host(broadcast('54.144.0.0/16'::cidr))::inet
ORDER BY (r.end_ip - r.start_ip)
LIMIT 1;


-- ---------------------------------------------------------------------------
-- 2. COVERAGE. How much of the decomposition candidate set can be decided.
--
-- A candidate with no covering allocation cannot have its registrant determined
-- and is deferred rather than decomposed.
-- ---------------------------------------------------------------------------

SELECT count(*)                                                     AS candidates,
       count(*) FILTER (WHERE cov.registrant IS NOT NULL)            AS registrant_known,
       count(*) FILTER (WHERE cov.registrant IS NULL)                AS registrant_unknown
FROM ip2city_dbiplite_tbl d
LEFT JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= host(network(d.network))::inet
      AND r.end_ip   >= host(broadcast(d.network))::inet
    ORDER BY (r.end_ip - r.start_ip)
    LIMIT 1
) cov ON true
WHERE d.source = 'dbip'
  AND family(d.network) = 4
  AND masklen(d.network) < 24;


-- ---------------------------------------------------------------------------
-- 3. WHICH REGISTRANTS DOMINATE THE CANDIDATE SET.
--
-- This is how to find patterns worth adding to decomposition_exclusions. Unlike
-- the ip-api version of this query, it does not require the range to have been
-- probed, so it covers the whole candidate set rather than the probed fraction.
-- ---------------------------------------------------------------------------

SELECT cov.registrant,
       count(*)                                                     AS wide_ranges,
       sum(2 ^ (24 - masklen(d.network)))::bigint                     AS sub24_rows_they_would_generate,
       min(masklen(d.network))                                        AS widest
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
GROUP BY 1
ORDER BY sub24_rows_they_would_generate DESC
LIMIT 30;


-- ---------------------------------------------------------------------------
-- 4. DISAGREEMENT BETWEEN THE TWO SOURCES.
--
-- Worth running once the cache is warm. Where RDAP and ip-api disagree about who
-- holds a range, RDAP is the registration fact and ip-api is the operating
-- description. Both are useful, and a large disagreement set is a finding in
-- itself rather than an error.
-- ---------------------------------------------------------------------------

SELECT p.network,
       masklen(p.network) AS len,
       cov.registrant     AS rdap_registrant,
       p.isp              AS ipapi_isp,
       p.org              AS ipapi_org
FROM ip2city_dbiplite_probe_tbl p
JOIN LATERAL (
    SELECT r.registrant
    FROM rdap_registrant_tbl r
    WHERE r.start_ip <= host(network(p.network))::inet
      AND r.end_ip   >= host(broadcast(p.network))::inet
    ORDER BY (r.end_ip - r.start_ip)
    LIMIT 1
) cov ON true
WHERE p.ran_at IS NOT NULL
  AND cov.registrant IS NOT NULL
  AND coalesce(p.isp, p.org, '') <> ''
  AND position(lower(split_part(cov.registrant, ' ', 1)) in lower(coalesce(p.isp, '') || ' ' || coalesce(p.org, ''))) = 0
ORDER BY masklen(p.network)
LIMIT 50;
