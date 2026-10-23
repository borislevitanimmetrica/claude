DROP TABLE IF EXISTS public.ovt_places_usa_host_ip CASCADE;

CREATE TABLE ovt_places_usa_host_ip
(
   host         text          NOT NULL,
   ip           inet,
   error        text,
   resolved_at  timestamptz   DEFAULT now()
);

ALTER TABLE ovt_places_usa_host_ip ALTER ip SET STORAGE MAIN;

ALTER TABLE public.ovt_places_usa_host_ip OWNER TO boris;

ALTER TABLE ovt_places_usa_host_ip
   ADD CONSTRAINT ovt_places_usa_host_ip_pkey
   PRIMARY KEY (host);

GRANT TRUNCATE, SELECT, UPDATE, DELETE, INSERT ON ovt_places_usa_host_ip TO cronuser;
