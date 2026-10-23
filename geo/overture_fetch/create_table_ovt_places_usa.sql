DROP TABLE IF EXISTS public.ovt_places_usa CASCADE;

CREATE UNLOGGED TABLE ovt_places_usa
(
   id                          text,
   geometry                    text,
   confidence                  float8,
   websites                    text,
   emails                      text,
   socials                     text,
   phones                      text,
   brand                       text,
   addresses                   text,
   names                       text,
   sources                     text,
   operating_status            text,
   basic_category              text,
   taxonomy                    text,
   version                     integer,
   bbox                        text,
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

ALTER TABLE ovt_places_usa ALTER ip_address SET STORAGE MAIN;
ALTER TABLE ovt_places_usa ALTER ip_last_carrier_node SET STORAGE MAIN;
ALTER TABLE ovt_places_usa ALTER ip_address_range SET STORAGE MAIN;
ALTER TABLE ovt_places_usa ALTER ip_last_carrier_node_range SET STORAGE MAIN;

CREATE INDEX IF NOT EXISTS ovt_places_usa_ip_address_idx ON public.ovt_places_usa USING btree (ip_address);
