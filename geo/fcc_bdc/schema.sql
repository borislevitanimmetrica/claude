-- geo/fcc_bdc/schema.sql
--
-- Tables for the new plan: FCC Broadband Data Collection availability, and the
-- decision log Boris requires across all seven steps.
--
-- Safe to re-run. Every statement is CREATE IF NOT EXISTS or an idempotent
-- COMMENT, so this never drops or rewrites existing data.
--
--
-- WHY BDC AND NOT THE FABRIC
--
-- SETTLED 2026-11-12 by Boris reading the real header of a public download.
-- The free per-state availability file carries:
--
--   frn, provider_id, brand_name, location_id, technology,
--   max_advertised_download_speed, max_advertised_upload_speed, low_latency,
--   business_residential_code, state_usps, block_geoid, h3_res8_id
--
-- block_geoid is there, so the CostQuest Fabric licence is NOT on the critical
-- path. Everything steps 2, 4 and 7 need is in the free file: carrier from
-- frn, provider_id and brand_name; network type from technology, which is what
-- separates Verizon FIOS from Verizon xDSL; geography from block_geoid.
--
-- The Fabric would add per-location coordinates and street addresses. This
-- plan does not need them, because steps 4 and 5 measure from the TRACT
-- CENTROID, not from individual premises.
--
--
-- block_geoid IS TEXT AND MUST STAY TEXT
--
-- It is a fixed-width 15-character code: 2 state FIPS, 3 county, 6 tract,
-- 4 block. Roughly half the states begin with a zero, Alabama being 01, so
-- reading it as a number drops the leading zero, shortens the string, and
-- silently misfiles an entire state. The CHECK below makes that impossible to
-- do by accident rather than merely inadvisable.
--
-- Derived geographies are GENERATED columns rather than expressions repeated
-- at each call site, so the tract can only be computed one way.

CREATE TABLE IF NOT EXISTS bdc_availability_tbl (
    bdc_id        bigserial   PRIMARY KEY,

    -- Carrier. frn is the FCC Registration Number of the filer, provider_id
    -- is the FCC-assigned provider identifier, brand_name is the consumer
    -- brand. They are kept separately because one FRN can file under several
    -- brands, which is exactly the Verizon FIOS versus xDSL distinction when
    -- the brands differ, and technology covers it when they do not.
    frn           text,
    provider_id   integer,
    brand_name    text,

    -- The Fabric location this record is about. Retained even though the
    -- Fabric itself is unlicensed here: it is the join key if a licence is
    -- ever obtained, and it is the unit of duplication to watch for.
    location_id   bigint,

    -- Network type. The integer code list is NOT hardcoded anywhere in this
    -- project, because I have not verified it against the FCC specification.
    -- bdc_load.py reports the distinct codes with their brand names after
    -- every load, so the mapping is established from the data.
    technology    smallint,

    max_advertised_download_speed integer,
    max_advertised_upload_speed   integer,
    low_latency                   smallint,

    -- Reported as a code rather than two booleans in the source file.
    business_residential_code     text,

    state_usps    text,

    block_geoid   text NOT NULL,
    h3_res8_id    text,

    -- Which download this row came from, so a re-load of one file can replace
    -- exactly that file's rows and nothing else.
    source_file   text NOT NULL,
    loaded_at     timestamptz NOT NULL DEFAULT now(),

    state_fips    text GENERATED ALWAYS AS (left(block_geoid, 2))  STORED,
    county_geoid  text GENERATED ALWAYS AS (left(block_geoid, 5))  STORED,
    tract_geoid   text GENERATED ALWAYS AS (left(block_geoid, 11)) STORED,

    CONSTRAINT bdc_block_geoid_is_15_digits
        CHECK (block_geoid ~ '^[0-9]{15}$')
);

CREATE INDEX IF NOT EXISTS bdc_availability_tract_idx
    ON bdc_availability_tbl (tract_geoid);
CREATE INDEX IF NOT EXISTS bdc_availability_block_idx
    ON bdc_availability_tbl (block_geoid);
CREATE INDEX IF NOT EXISTS bdc_availability_provider_tech_idx
    ON bdc_availability_tbl (provider_id, technology);
CREATE INDEX IF NOT EXISTS bdc_availability_source_file_idx
    ON bdc_availability_tbl (source_file);
CREATE INDEX IF NOT EXISTS bdc_availability_h3_idx
    ON bdc_availability_tbl (h3_res8_id);

COMMENT ON TABLE bdc_availability_tbl IS
    'FCC Broadband Data Collection fixed availability, from the PUBLIC per-state downloads at broadbandmap.fcc.gov/data-download. No CostQuest Fabric licence is required because block_geoid is included, which yields the census tract as its first 11 characters. One row per filed availability record.';
COMMENT ON COLUMN bdc_availability_tbl.block_geoid IS
    'Census block GEOID, 15 characters, TEXT so leading zeros survive. State FIPS is characters 1-2, county 1-5, tract 1-11.';
COMMENT ON COLUMN bdc_availability_tbl.technology IS
    'FCC technology code. The code-to-name mapping is deliberately NOT hardcoded: bdc_load.py reports the distinct codes present with their brand names so it is read from data rather than from memory.';


-- ---------------------------------------------------------------------------
-- DECISION LOGGING
--
-- Boris, 2026-11-12: "Keep a log of all decisions in a table, with step
-- identifiers and geography identifiers."
--
-- Two tables rather than one, and the reason is the four-block gap parameter.
-- It is explicitly provisional and will be tuned, so a decision has to carry
-- the configuration that produced it. Putting the config on a RUN, and the
-- run on each decision, means a parameter change produces a new run that can
-- be compared against the old one instead of overwriting it.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS geo_decision_run (
    run_id      bigserial   PRIMARY KEY,
    step        text        NOT NULL,
    config      jsonb       NOT NULL,
    note        text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz
);

COMMENT ON TABLE geo_decision_run IS
    'One row per execution of a pipeline step, carrying the configuration in force. Exists so a tunable parameter such as the step-5 coverage gap, provisionally four blocks, can be changed and the two runs compared rather than one silently replacing the other.';

CREATE TABLE IF NOT EXISTS geo_decision_log (
    decision_id bigserial   PRIMARY KEY,
    run_id      bigint      NOT NULL REFERENCES geo_decision_run (run_id),

    -- Step identifier, as Boris asked for. Free text rather than an enum so a
    -- new step does not require a migration, but written as step1 to step7
    -- plus a short name, for example 'step5_select_headend'.
    step        text        NOT NULL,

    -- Geography identifier, as Boris asked for. geo_level says what geo_id
    -- means, because the plan decides at tract level in steps 4 to 6 and at
    -- ZIP level in step 7, and a bare GEOID is ambiguous between block,
    -- tract, county and ZIP.
    geo_level   text        NOT NULL,
    geo_id      text        NOT NULL,

    -- Carrier and network type, null where a decision is not carrier-specific.
    carrier_frn text,
    provider_id integer,
    technology  smallint,

    decision    text        NOT NULL,
    rationale   text,

    -- The values the decision rested on: distances, candidate headends, gap
    -- runs found. Kept as jsonb so a step can record what it actually used
    -- without a schema change per step.
    inputs      jsonb,

    decided_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT geo_decision_level_known
        CHECK (geo_level IN ('census_block', 'census_tract', 'county',
                             'state', 'zip', 'headend', 'ip_range'))
);

CREATE INDEX IF NOT EXISTS geo_decision_log_step_geo_idx
    ON geo_decision_log (step, geo_level, geo_id);
CREATE INDEX IF NOT EXISTS geo_decision_log_geo_idx
    ON geo_decision_log (geo_level, geo_id);
CREATE INDEX IF NOT EXISTS geo_decision_log_run_idx
    ON geo_decision_log (run_id);
CREATE INDEX IF NOT EXISTS geo_decision_log_carrier_idx
    ON geo_decision_log (provider_id, technology);

COMMENT ON TABLE geo_decision_log IS
    'One row per decision taken by any pipeline step, keyed on the step and the geography it concerns. Required by Boris 2026-11-12. The configuration that produced a decision is reachable through run_id, which is what makes a provisional parameter such as the four-block coverage gap auditable after it is changed.';
COMMENT ON COLUMN geo_decision_log.geo_level IS
    'What geo_id means. A bare GEOID is ambiguous between block, tract, county and ZIP, and steps 4 to 6 decide per tract while step 7 decides per ZIP.';
