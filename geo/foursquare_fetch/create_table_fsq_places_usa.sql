-- fsq_places_usa: Foursquare OS Places, United States.
--
-- A SECOND landmark source alongside ovt_places_usa. Overture yields only
-- 28,324 distinct on-premises addresses covering 15,963 ZIPs out of roughly
-- 44,000 inhabited ones, which is the constraint this table exists to relieve.
--
-- THE COLUMN NAMES ARE NOT ARBITRARY. ovt_resolve_hosts.py is parameterised by
-- --table, --url-column and --address-column, so the whole enrichment chain
-- (resolve -> rdap -> registrants -> overture-zip -> onpremises) runs against
-- this table unchanged. That is the entire integration: no second copy of the
-- resolve or onpremises logic, and therefore no risk of the two sources
-- drifting apart on what "on premises" means. The chain requires ip_address,
-- url_location and onpremises to exist before it starts, so they are declared
-- here rather than left to ensure_column.
--
-- The overture_zip / overture_zip_source names are kept even though nothing
-- here comes from Overture. Renaming them would fork the chain for no gain;
-- read them as "the landmark's established ZIP, and how it was established".
--
-- Two columns are SYNTHESISED by fsq_fetch.py rather than copied:
--
--   websites   Foursquare's flat "website" string. The resolve step uses a text
--              value that does not start with "[" as-is, so no JSON wrapper is
--              needed, and a bare URL is clearer than a one-element array.
--
--   addresses  Foursquare's address parts re-emitted in Overture's JSON shape,
--              because cmd_overture_zip matches '"postcode":"12345"' and
--              '"freeform":"..."' against the address TEXT. Synthesising the
--              shape is what lets the ZIP step work on this table untouched.
--
-- Everything from fsq_place_id down to dt is Foursquare's own, carried through
-- so a row can be traced back to its release.

DROP TABLE IF EXISTS public.fsq_places_usa CASCADE;

CREATE UNLOGGED TABLE fsq_places_usa
(
   -- Foursquare source columns, as published.
   fsq_place_id                text,
   name                        text,
   latitude                    float8,
   longitude                   float8,
   address                     text,
   locality                    text,
   region                      text,
   postcode                    text,
   admin_region                text,
   post_town                   text,
   po_box                      text,
   country                     text,
   website                     text,
   tel                         text,
   email                       text,
   facebook_id                 text,
   instagram                   text,
   twitter                     text,
   fsq_category_ids            text,
   fsq_category_labels         text,
   date_created                text,
   date_refreshed              text,
   date_closed                 text,
   dt                          text,

   -- Synthesised into the shape the shared chain expects.
   websites                    text,
   addresses                   text,

   -- Written by ovt_resolve_hosts.py, identical in meaning to ovt_places_usa.
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

ALTER TABLE fsq_places_usa ALTER ip_address SET STORAGE MAIN;
ALTER TABLE fsq_places_usa ALTER ip_last_carrier_node SET STORAGE MAIN;
ALTER TABLE fsq_places_usa ALTER ip_address_range SET STORAGE MAIN;
ALTER TABLE fsq_places_usa ALTER ip_last_carrier_node_range SET STORAGE MAIN;

CREATE INDEX IF NOT EXISTS fsq_places_usa_ip_address_idx
    ON public.fsq_places_usa USING btree (ip_address);

-- The dedupe and cross-source queries both join on the host, so index it the
-- way they read it: lower-cased and with the protocol stripped.
CREATE INDEX IF NOT EXISTS fsq_places_usa_website_idx
    ON public.fsq_places_usa USING btree (lower(btrim(website)));

CREATE INDEX IF NOT EXISTS fsq_places_usa_postcode_idx
    ON public.fsq_places_usa USING btree (postcode);
