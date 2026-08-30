-- ipapi-geo schema additions.
--
-- Columns for the ip-api.com geolocation fields, added to
-- ip2city_dbiplite_traceroute_tbl. Names match the ip-api JSON keys
-- (Postgres folds unquoted identifiers to lower case; "as" is a reserved
-- word so it is double-quoted).
--
-- The JSON "status"/"query" map onto existing/added columns; the ip-api
-- "message" (only present on a fail) is recorded in the existing
-- classification_note column. probe_method is set to 'ip-api' by the writer.

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
-- (likely_mobile_cgnat, hop_count, attempts) on new rows. If those columns
-- do NOT already tolerate this (they should, since the mtr writer always set
-- them), give them defaults so ip-api-only inserts never fail:
--   ALTER TABLE ip2city_dbiplite_traceroute_tbl ALTER COLUMN hop_count          SET DEFAULT 0;
--   ALTER TABLE ip2city_dbiplite_traceroute_tbl ALTER COLUMN attempts           SET DEFAULT 0;
--   ALTER TABLE ip2city_dbiplite_traceroute_tbl ALTER COLUMN likely_mobile_cgnat SET DEFAULT false;
