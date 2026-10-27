-- landmarks_usa - every USA landmark source in ONE table.
--
-- Replaces the per-source tables as the operational surface. ovt_places_usa,
-- fsq_places_usa and lm_places_usa stay in place as the raw imports; this is
-- what the chain, the fan-out measurement and the DMA API read.
--
-- WHY ONE TABLE. Three tables meant three resolve passes, three RDAP passes and
-- three onpremises passes, and three chances for the definition of "on
-- premises" to drift apart. One table means one pass and one definition. The
-- loaders still differ, because Overture is nested parquet, Foursquare is flat
-- parquet, OSM is Overpass JSON or a PBF extract and IPEDS is a zipped CSV;
-- only the destination is shared.
--
-- COMMON CORE PLUS source_attrs. Every source has a name, an address, a ZIP and
-- a website, and those are real columns. Everything a source carries beyond
-- that goes into source_attrs as jsonb rather than becoming 40 mostly-null
-- columns: Overture's taxonomy and confidence, Foursquare's category ids and
-- date_closed, OSM's raw tags. Nothing is discarded, and adding a source does
-- not require a migration.
--
-- The chain runs against this table unchanged:
--     ovt_resolve_hosts.py <step> --table landmarks_usa

DROP TABLE IF EXISTS public.landmarks_usa CASCADE;

CREATE TABLE landmarks_usa
(
   landmark_id                 bigserial PRIMARY KEY,

   -- Provenance. (source, source_id) is the natural key.
   source                      text NOT NULL,
   source_id                   text,
   source_release              text,
   loaded_at                   timestamptz NOT NULL DEFAULT now(),

   -- Common core, present in every source.
   name                        text,
   address                     text,
   locality                    text,
   region                      text,
   postcode                    text,
   country                     text,
   website                     text,
   latitude                    float8,
   longitude                   float8,
   category                    text,

   -- Anything else the source carried. Never read by the chain.
   source_attrs                jsonb,

   -- Read by the chain. websites is the bare URL, because the resolve step
   -- uses a text value not starting with "[" as-is. addresses is Overture's
   -- JSON shape, because the ZIP step matches '"postcode":"12345"' and
   -- '"freeform":"..."' against the address text.
   websites                    text,
   addresses                   text,

   -- Written by the chain. Same meaning as in ovt_places_usa.
   ip_address                  inet,
   ip_last_carrier_node        inet,
   ip_address_range            inet,
   ip_last_carrier_node_range  inet,
   url_location                text,
   onpremises                  boolean,
   url_location_zip            text,
   lookup_status               text,
   registrant_1                text,
   registrant_1_zip            text,
   registrant_2                text,
   registrant_2_zip            text,
   overture_zip                text,
   overture_zip_source         text,

   -- Why onpremises holds its current value. Set by
   -- onpremises_hosting_rule.sql. Without this, a false written by the
   -- hosting rule is indistinguishable from a false written by the registrant
   -- rules, and the two are not the same claim.
   onpremises_reason           text
)
TABLESPACE ts_large_data;

ALTER TABLE landmarks_usa ALTER ip_address SET STORAGE MAIN;
ALTER TABLE landmarks_usa ALTER ip_last_carrier_node SET STORAGE MAIN;
ALTER TABLE landmarks_usa ALTER ip_address_range SET STORAGE MAIN;
ALTER TABLE landmarks_usa ALTER ip_last_carrier_node_range SET STORAGE MAIN;

-- A source must not be able to load the same place twice. Partial, because
-- some sources have rows with no usable id.
CREATE UNIQUE INDEX IF NOT EXISTS landmarks_usa_source_id_idx
    ON public.landmarks_usa (source, source_id)
    WHERE source_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS landmarks_usa_ip_address_idx
    ON public.landmarks_usa USING btree (ip_address);

CREATE INDEX IF NOT EXISTS landmarks_usa_onprem_zip_idx
    ON public.landmarks_usa USING btree (overture_zip)
    WHERE onpremises IS TRUE;

CREATE INDEX IF NOT EXISTS landmarks_usa_website_idx
    ON public.landmarks_usa USING btree (lower(btrim(website)));

CREATE INDEX IF NOT EXISTS landmarks_usa_registrant_idx
    ON public.landmarks_usa USING btree (lower(btrim(registrant_1)));

COMMENT ON TABLE landmarks_usa IS
    'Every USA landmark source in one table, keyed on (source, source_id). The per-source tables remain as raw imports. onpremises_reason records WHICH rule set onpremises, so a hosting-rule false is distinguishable from a registrant-rule false.';
