-- create_table_ovt_places_usa_ip_trace.sql
--
-- The last carrier node adjacent to each landmark address, as measured by mtr.
-- Written by `geo/main.go -source landmarks`, which is deployed as
-- last_carrier_node.
--
-- KEYED ON THE ADDRESS, NOT ON A PREFIX
--
-- The existing traceroute table, ip2city_dbiplite_traceroute_tbl, is keyed on
-- `network` with one row per prefix, because a probe traces one random address
-- per range and the range is the unit of interest. Landmarks are the opposite
-- shape: the address is the datum, and many landmarks routinely share one
-- prefix. Writing them into a network-keyed table would make each landmark
-- overwrite the previous one, leaving one arbitrary survivor per prefix. That
-- would not raise an error; it would silently discard most of a multi-day pass.
--
-- ONE ROW PER ADDRESS, NOT PER PLACE
--
-- Many Overture places resolve to the same address, since a health system's
-- clinics all point at one server. The trace is a property of the address, so it
-- is stored once here and fanned out to places by join, exactly as
-- ovt_places_usa_ip_rdap does for RDAP results. Deduplicating this way is what
-- takes the landmark pass from roughly 1.2M traces down to about 123k.
--
-- WHY THIS FILE DOES NOT DROP THE TABLE
--
-- Its two sibling files, create_table_ovt_places_usa_host_ip.sql and
-- create_table_ovt_places_usa_ip_rdap.sql, both begin with DROP TABLE IF EXISTS
-- ... CASCADE. That is deliberately NOT copied here. DNS resolution and RDAP
-- lookups are cheap to repeat; a full landmark traceroute pass is on the order
-- of 29 hours of ICMP at 50 concurrent traces. Re-running this file must never
-- be able to destroy that. CREATE TABLE IF NOT EXISTS and ADD COLUMN IF NOT
-- EXISTS make it idempotent instead, so it is safe to apply to a populated
-- table when a column is added later.
--
-- To rebuild deliberately, drop it by hand first and say so out loud.
--
-- Contains NO backslashes so it survives copy/paste.

CREATE TABLE IF NOT EXISTS public.ovt_places_usa_ip_trace
(
   ip                   inet        NOT NULL,
   last_hop_ip          inet,
   last_hop_hostname    text,
   last_hop_number      integer,
   hop_count            integer,
   status               text,
   probe_method         text,
   likely_mobile_cgnat  boolean,
   classification_note  text,
   attempts             integer,
   traced_at            timestamptz DEFAULT now(),
   CONSTRAINT ovt_places_usa_ip_trace_pkey PRIMARY KEY (ip)
);

-- Added after the first two passes. ADD COLUMN IF NOT EXISTS rather than a
-- changed CREATE TABLE, so applying this file to a populated table is safe.
--
-- hops is the entire trace. Two passes were spent discovering that the rule for
-- choosing the carrier node was wrong, and each pass costs hours of ICMP, while
-- the hop list costs about a kilobyte per address. With it stored, the node can
-- be re-chosen by a SQL pass instead of by re-probing. It is also what makes
-- the BGP origin-AS test possible, which is the only robust way to recognise an
-- UNNAMED customer router: compare each hop's origin_asn to the destination's.
--
-- hop2_responded and hop2_miss_attempts measure silence at hop 2, the first
-- carrier node out of the probing host. That silence is ICMP rate limiting at
-- the local access router and says nothing about the destination, so it is
-- counted per attempt and triggers a retry. Expected to disappear on AWS.
--
-- cpe_skipped counts customer routers discarded before a carrier node was
-- accepted. A business commonly presents two or three, named in its own domain.

ALTER TABLE public.ovt_places_usa_ip_trace
    ADD COLUMN IF NOT EXISTS hops               jsonb,
    ADD COLUMN IF NOT EXISTS hop2_responded     boolean,
    ADD COLUMN IF NOT EXISTS hop2_miss_attempts integer,
    ADD COLUMN IF NOT EXISTS cpe_skipped        integer;

ALTER TABLE public.ovt_places_usa_ip_trace ALTER ip SET STORAGE MAIN;
ALTER TABLE public.ovt_places_usa_ip_trace ALTER last_hop_ip SET STORAGE MAIN;

COMMENT ON TABLE public.ovt_places_usa_ip_trace IS
    'Last carrier node adjacent to each landmark address, from mtr. One row per distinct ovt_places_usa.ip_address, fanned out to places by join. status=reached means last_hop_ip/last_hop_hostname are a usable carrier node; see geo/traceroute_hostname_rules.sql for the classification.';

COMMENT ON COLUMN public.ovt_places_usa_ip_trace.last_hop_hostname IS
    'Reverse DNS of the accepted carrier node. This is where the geography lives: forms like lightspeed.btrgla.sbcglobal.net encode a metro. Note it can be SHARED across many router interfaces in one metro, which is why matching is measured both by last_hop_ip and by this column: see geo/landmark_carrier_node.sql section 4.';


-- The convergence join reads this table by node identity, not by ip, so both
-- node columns need an index. Partial, because only `reached` rows carry a
-- usable node and they are a minority of the table.

CREATE INDEX IF NOT EXISTS ovt_places_usa_ip_trace_last_hop_ip_idx
    ON public.ovt_places_usa_ip_trace (last_hop_ip)
    WHERE last_hop_ip IS NOT NULL;

CREATE INDEX IF NOT EXISTS ovt_places_usa_ip_trace_last_hop_hostname_idx
    ON public.ovt_places_usa_ip_trace (last_hop_hostname)
    WHERE last_hop_hostname IS NOT NULL;

-- sampleLandmarks resumes with NOT EXISTS (SELECT 1 FROM this table WHERE
-- t.ip = p.ip_address), which the primary key already serves. status is indexed
-- separately so the progress and failure-mode reports do not scan the table.

CREATE INDEX IF NOT EXISTS ovt_places_usa_ip_trace_status_idx
    ON public.ovt_places_usa_ip_trace (status);


DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'boris') THEN
        ALTER TABLE public.ovt_places_usa_ip_trace OWNER TO boris;
        RAISE NOTICE 'ovt_places_usa_ip_trace owned by boris';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cronuser') THEN
        GRANT TRUNCATE, SELECT, UPDATE, DELETE, INSERT
            ON public.ovt_places_usa_ip_trace TO cronuser;
        RAISE NOTICE 'granted ovt_places_usa_ip_trace to cronuser';
    ELSE
        RAISE NOTICE 'role cronuser does not exist, so no grant was made';
    END IF;
END
$$;
