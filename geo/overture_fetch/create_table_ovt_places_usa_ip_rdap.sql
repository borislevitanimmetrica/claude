DROP TABLE IF EXISTS public.ovt_places_usa_ip_rdap CASCADE;

CREATE TABLE ovt_places_usa_ip_rdap
(
   ip            inet          NOT NULL,
   result        text,
   error         text,
   looked_up_at  timestamptz   DEFAULT now(),
   zip           text
);

ALTER TABLE ovt_places_usa_ip_rdap ALTER ip SET STORAGE MAIN;

ALTER TABLE public.ovt_places_usa_ip_rdap OWNER TO boris;

ALTER TABLE ovt_places_usa_ip_rdap
   ADD CONSTRAINT ovt_places_usa_ip_rdap_pkey
   PRIMARY KEY (ip);

GRANT TRUNCATE, SELECT, UPDATE, DELETE, INSERT ON ovt_places_usa_ip_rdap TO cronuser;
