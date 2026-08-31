-- bgp_route_views schema.
--
-- The main table (as provided):
CREATE TABLE IF NOT EXISTS bgp_route_views (
    id            SERIAL PRIMARY KEY,
    cidr_block    INET NOT NULL,
    start_address INET NOT NULL,
    end_address   INET NOT NULL,
    origin_asn    BIGINT,
    peer_ip       INET,
    as_path       TEXT,
    updated_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Index that makes updates-mode (prefix, peer) replace/withdraw feasible on a
-- table with tens of millions of rows. The tool creates this automatically
-- (after the full COPY, and at the start of an updates run), but it is here for
-- reference / manual setup.
CREATE INDEX IF NOT EXISTS bgp_route_views_cidr_peer_idx
    ON bgp_route_views (cidr_block, peer_ip);

-- Incremental ingest bookkeeping: the timestamp of the last archive file
-- applied per collector. The tool creates and maintains this automatically.
CREATE TABLE IF NOT EXISTS bgp_rv_ingest_state (
    collector    text PRIMARY KEY,
    last_file_ts timestamptz NOT NULL,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
