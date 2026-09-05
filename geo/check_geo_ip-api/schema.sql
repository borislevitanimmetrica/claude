-- check_geo_ip-api schema additions.
--
-- Columns for the ip-api.com geolocation fields, added to
-- ip2city_dbiplite_traceroute_tbl. Names match the ip-api JSON keys, lowercased
-- ("as" is a reserved word, so it is double-quoted).
--
-- The JSON "status"/"query" map onto existing/added columns; the ip-api
-- "message" (only on a fail) is recorded in the existing classification_note
-- column; probe_method is set to 'ip-api' by the writer; likely_mobile_cgnat is
-- set true when isp/org contains "wireless", "mobile", or "cellular".

ALTER TABLE ip2city_dbiplite_traceroute_tbl
    ADD COLUMN IF NOT EXISTS country     text,
    ADD COLUMN IF NOT EXISTS countrycode text,
    ADD COLUMN IF NOT EXISTS region      text,
    ADD COLUMN IF NOT EXISTS regionname  text,
    ADD COLUMN IF NOT EXISTS city        text,
    ADD COLUMN IF NOT EXISTS zip         text,
    ADD COLUMN IF NOT EXISTS lat         double precision,
    ADD COLUMN IF NOT EXISTS lon         double precision,
    ADD COLUMN IF NOT EXISTS timezone    text,
    ADD COLUMN IF NOT EXISTS isp         text,
    ADD COLUMN IF NOT EXISTS org         text,
    ADD COLUMN IF NOT EXISTS "as"        text,
    ADD COLUMN IF NOT EXISTS query       text;

-- The writer inserts zero-values for the mtr-only NOT-NULL-prone columns
-- (hop_count, attempts) on new rows. If those columns do NOT already tolerate
-- this, give them defaults so ip-api-only inserts never fail:
--   ALTER TABLE ip2city_dbiplite_traceroute_tbl ALTER COLUMN hop_count SET DEFAULT 0;
--   ALTER TABLE ip2city_dbiplite_traceroute_tbl ALTER COLUMN attempts  SET DEFAULT 0;
