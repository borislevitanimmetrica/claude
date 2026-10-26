-- lm_places_usa - the additional landmark sources, in ONE table with a source column.
--
-- Overture gets its own table and Foursquare gets its own because each is a
-- bulk parquet import of comparable size. These sources are different: several
-- small-to-medium feeds, each needing the same enrichment. One table with a
-- source column means one resolve pass, one RDAP pass and one onpremises pass
-- covers all of them, instead of N runs of the chain.
--
-- The column names are chosen so ovt_resolve_hosts.py runs against this table
-- unchanged, exactly as for fsq_places_usa:
--     --table lm_places_usa     (url-column and address-column already default
--                                to websites and addresses)
--
-- WHAT MAKES A SOURCE WORTH IMPORTING is not its row count. It is the number of
-- INDEPENDENT DOMAINS it contributes. The chain resolves a website to an IP and
-- decides onpremises from the registrant of that IP, so a source where every
-- row points at one domain yields exactly one landmark address no matter how
-- many rows it has, and node_fanout.sql will then correctly classify that
-- address as hosting because it spans disjoint ZIP clusters.
--
-- That is why the National Park Service is near-worthless here despite good
-- addresses: every park is a nps.gov URL, so 400-odd parks collapse to one
-- host. The same argument rules out bank-branch and chain-retail feeds. It is
-- also why NCES IPEDS is the best of the small sources: roughly 6,000
-- institutions, nearly all on their own domain, and universities characteristically
-- host their own web server on campus.

DROP TABLE IF EXISTS public.lm_places_usa CASCADE;

CREATE UNLOGGED TABLE lm_places_usa
(
   -- Provenance. (source, source_id) is the natural key.
   source                      text NOT NULL,
   source_id                   text,
   source_release              text,

   -- As published by the source.
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

   -- Synthesised at load time into the shape the shared chain expects.
   -- websites is the bare URL: the resolve step uses a text value that does not
   -- start with "[" as-is. addresses is Overture's JSON shape, because
   -- cmd_overture_zip matches '"postcode":"12345"' and '"freeform":"..."'
   -- against the address text.
   websites                    text,
   addresses                   text,

   -- Written by ovt_resolve_hosts.py. Same meaning as in ovt_places_usa.
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
   overture_zip_source         text
)
TABLESPACE ts_large_data;

ALTER TABLE lm_places_usa ALTER ip_address SET STORAGE MAIN;
ALTER TABLE lm_places_usa ALTER ip_last_carrier_node SET STORAGE MAIN;
ALTER TABLE lm_places_usa ALTER ip_address_range SET STORAGE MAIN;
ALTER TABLE lm_places_usa ALTER ip_last_carrier_node_range SET STORAGE MAIN;

-- Re-running a source must not double-load it. The loader deletes its own
-- source rows before inserting, and this makes that cheap and also enforces
-- that a source cannot emit the same id twice.
CREATE UNIQUE INDEX IF NOT EXISTS lm_places_usa_source_id_idx
    ON public.lm_places_usa (source, source_id);

CREATE INDEX IF NOT EXISTS lm_places_usa_ip_address_idx
    ON public.lm_places_usa USING btree (ip_address);

CREATE INDEX IF NOT EXISTS lm_places_usa_postcode_idx
    ON public.lm_places_usa USING btree (postcode);

-- The crosswalk joins on host, so index it the way the crosswalk reads it.
CREATE INDEX IF NOT EXISTS lm_places_usa_website_idx
    ON public.lm_places_usa USING btree (lower(btrim(website)));
