-- rebuild_probe_tbl.sql
-- Archive, truncate and repopulate ip2city_dbiplite_probe_tbl, but ONLY when the
-- previous probing cycle has finished.
--
-- Called by daily_pipeline.sh after the RouteViews update and the db-ip
-- reconciliation, so a rebuild happens on the first BGP update following a
-- completed cycle, not on every BGP update.
--
-- WHY THE GATE: at the free ip-api tier a full cycle over roughly two million
-- ranges takes about 36 days. Rebuilding daily would discard 97 percent of each
-- cycle's work every 24 hours and no cycle would ever complete. The gate makes
-- the same code correct at both the free and the commercial tier.
--
-- CYCLE COMPLETE is defined as: no row in the probe table has ran_at IS NULL.
--
-- CRITICAL CONSEQUENCE OF THAT DEFINITION: any row that can never be probed
-- would block every future rebuild forever. The populate below therefore applies
-- exactly the same filters as sampleRanges in check_geo_ip-api. If those filters
-- ever diverge, the pipeline deadlocks silently: probing skips a row, the row
-- keeps ran_at NULL, and the gate never opens. The filters are:
--
--   family(network) = geo.family   IPv6 is out of scope for now, see below
--   country_iso_code = geo.country probe_batch passes the same -country
--   NOT IN geo_exclusions          DoD prefixes AND ASNs are never probed
--
-- The exclusion filter matters most: the DoD rules would otherwise freeze the
-- pipeline permanently the first time a cycle finished.
--
-- CGNAT (100.64.0.0/10) is deliberately NOT excluded. That exclusion was
-- reversed by decision on 2026-09-08, and the matching filter was removed from
-- sampleRanges in check_geo_ip-api and from probe_batch.sh at the same time.
-- Loading CGNAT here while probing still skipped it would leave those rows at
-- ran_at NULL forever and block every future rebuild.
--
-- IPv6 IS REVERSIBLE BY CONFIGURATION. Set PROBE_IPV4_ONLY=0 to include it.
-- That single variable drives both this populate and the probe, which is why it
-- lives in geo_common.sh rather than in either script: if the populate and the
-- probe disagreed about address family, the excluded family would sit at
-- ran_at NULL and deadlock the gate. See the commented block in trugeo.cron.
--
--   PROBE_IPV4_ONLY=1  geo.family = 4, IPv4 only, current default
--   PROBE_IPV4_ONLY=0  geo.family = 0, both families
--
-- ASN-based exclusions are also honoured, via bgp_route_views, because an
-- origin_asn rule suppresses probing just as a prefix rule does.
--
-- The whole operation is one transaction. Either history gains a complete
-- snapshot and the probe table is rebuilt, or nothing changes.
--
-- Parameter: geo.country, defaulting to US. Set with
--   psql -c "SET geo.country = 'US'" -f rebuild_probe_tbl.sql
-- or leave unset to take the default.
--
-- PREREQUISITE, verified against the live schema on 2026-09-08:
-- ip2city_dbiplite_history_tbl has PRIMARY KEY (network), which allows exactly
-- ONE cycle to be archived. The second archive fails on a unique violation. Run
-- this once, as boris, before enabling PROBE_TBL_REBUILD:
--
--   ALTER TABLE ip2city_dbiplite_history_tbl
--       DROP CONSTRAINT ip2city_dbiplite_history_tbl_pkey;
--   ALTER TABLE ip2city_dbiplite_history_tbl
--       ADD CONSTRAINT ip2city_dbiplite_history_tbl_pkey PRIMARY KEY (network, ran_at);
--
-- ran_at is NOT NULL in the history table, so it is valid in a primary key, and
-- the gate guarantees every archived row has been probed and therefore has a
-- ran_at value.
--
-- Contains NO backslashes so it survives copy/paste.

DO $rebuild$
DECLARE
    v_country   text := coalesce(nullif(current_setting('geo.country', true), ''), 'US');
    v_family    int  := coalesce(nullif(current_setting('geo.family', true), '')::int, 4);
    v_total     bigint;
    v_pending   bigint;
    v_loaded    bigint;
    v_archived  bigint;
    v_nostate   bigint;
    v_asnpfx    bigint;
    v_t0        timestamptz;
BEGIN
    -- Fail early and legibly if the history table can still hold only one cycle.
    -- Without this the second rebuild dies on a unique violation whose message
    -- says nothing about the cause. The transaction would roll back, so no data
    -- is lost either way, but the operator would be left guessing.
    PERFORM 1
       FROM pg_constraint
      WHERE conrelid = 'ip2city_dbiplite_history_tbl'::regclass
        AND contype = 'p'
        AND array_length(conkey, 1) = 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ip2city_dbiplite_history_tbl still has a single-column PRIMARY KEY (network), so only one probing cycle could ever be archived. Change it to PRIMARY KEY (network, ran_at) first. See the header of rebuild_probe_tbl.sql.';
    END IF;

    SELECT count(*), count(*) FILTER (WHERE ran_at IS NULL)
      INTO v_total, v_pending
      FROM ip2city_dbiplite_probe_tbl;

    RAISE NOTICE 'probe table holds % rows, % still unprobed', v_total, v_pending;

    IF v_total > 0 AND v_pending > 0 THEN
        RAISE NOTICE 'probing cycle still in progress, leaving the probe table intact and skipping the rebuild';
        RETURN;
    END IF;

    -- A completed cycle is archived before it is discarded. An empty table on
    -- first run has nothing to archive.
    IF v_total > 0 THEN
        INSERT INTO ip2city_dbiplite_history_tbl (
            network, query, last_hop_ip, last_hop_hostname, city, state, state_code,
            zip, lat, lon, country, countrycode, timezone, rdap_lookup, hop_count,
            probe_method, status, isp, org, "as", likely_mobile_cgnat,
            last_hop_number, is_infrastructure, is_unreachable_local_carrier,
            classification_note, attempts, ran_at
        )
        SELECT
            network, query, last_hop_ip, last_hop_hostname, city, state, state_code,
            zip, lat, lon, country, countrycode, timezone, rdap_lookup, hop_count,
            probe_method, status, isp, org, "as", likely_mobile_cgnat,
            last_hop_number, is_infrastructure, is_unreachable_local_carrier,
            classification_note, attempts, ran_at
        FROM ip2city_dbiplite_probe_tbl;

        v_archived := v_total;
        RAISE NOTICE 'archived % rows into ip2city_dbiplite_history_tbl', v_archived;
    END IF;

    -- Materialise the prefixes excluded by ASN rules ONCE.
    --
    -- Previously the populate carried a correlated NOT EXISTS that joined
    -- bgp_route_views for every candidate row, which is millions of containment
    -- probes into a 1.1 million row table. The set of ASN-excluded prefixes is
    -- small, so building it once and probing that instead is far cheaper, and it
    -- gives the operator a progress checkpoint in a statement sequence that was
    -- otherwise silent for its whole duration.
    v_t0 := clock_timestamp();
    CREATE TEMP TABLE excluded_asn_prefixes ON COMMIT DROP AS
    SELECT DISTINCT b.cidr_block
      FROM bgp_route_views b
      JOIN geo_exclusions x
        ON x.active
       AND x.origin_asn IS NOT NULL
       AND b.origin_asn = x.origin_asn;

    CREATE INDEX ON excluded_asn_prefixes USING gist (cidr_block inet_ops);
    ANALYZE excluded_asn_prefixes;
    SELECT count(*) INTO v_asnpfx FROM excluded_asn_prefixes;
    RAISE NOTICE 'ASN exclusion rules expand to % prefixes, resolved in %', v_asnpfx, clock_timestamp() - v_t0;

    RAISE NOTICE 'truncating the probe table';
    TRUNCATE ip2city_dbiplite_probe_tbl;

    -- To watch this from another session, sample the RELATION SIZE, not the
    -- tuple counters:
    --
    --   select pg_size_pretty(pg_relation_size('ip2city_dbiplite_probe_tbl'));
    --
    -- pg_stat_user_tables.n_tup_ins is useless here. A backend accumulates tuple
    -- counters locally and flushes them at transaction boundaries, so a single
    -- long INSERT reports zero until it commits however much work it has done.
    -- Relation size grows as pages are written, uncommitted, so it does track
    -- progress.
    RAISE NOTICE 'populating for country % family % (0 means both). This is one INSERT of roughly two million rows and emits no further output until it completes. To watch it, sample pg_relation_size on ip2city_dbiplite_probe_tbl from another session; n_tup_ins will read zero until commit.', v_country, v_family;
    v_t0 := clock_timestamp();

    -- query is NOT NULL in this table, but no address has been selected yet at
    -- populate time: the probe picks one at random and writes it to last_hop_ip.
    -- The network's base address is used as a deterministic placeholder so the
    -- constraint is satisfied without a DDL change. It is NOT the probed
    -- address; last_hop_ip is the probed address.
    INSERT INTO ip2city_dbiplite_probe_tbl (
        network, query, city, state, state_code, countrycode, lat, lon,
        status, probe_method, attempts, hop_count, ran_at
    )
    SELECT
        s.network,
        host(network(s.network))::inet,
        s.city,
        s.state,
        st.state_code,
        s.country_iso_code,
        s.latitude,
        s.longitude,
        'pending',
        'ip-api',
        0,
        0,
        NULL
    FROM ip2city_dbiplite_tbl s
    LEFT JOIN trugeo_states_tbl st
           ON st.state = s.state
    WHERE (v_family = 0 OR family(s.network) = v_family)
      AND s.country_iso_code = v_country
      AND NOT EXISTS (
            SELECT 1 FROM geo_exclusions x
             WHERE x.active
               AND x.prefix IS NOT NULL
               AND s.network <<= x.prefix
          )
      AND NOT EXISTS (
            SELECT 1 FROM excluded_asn_prefixes e
             WHERE s.network <<= e.cidr_block
          );

    SELECT count(*) INTO v_loaded FROM ip2city_dbiplite_probe_tbl;
    RAISE NOTICE 'repopulated probe table with % rows for country % family % (0 means both), in %', v_loaded, v_country, v_family, clock_timestamp() - v_t0;

    SELECT count(*) INTO v_nostate
      FROM ip2city_dbiplite_probe_tbl
     WHERE state_code IS NULL;
    IF v_nostate > 0 THEN
        RAISE WARNING 'state_code is NULL for % of % rows: trugeo_states_tbl.state did not match ip2city_dbiplite_tbl.state. Both should hold full names such as Alabama.', v_nostate, v_loaded;
    END IF;
END
$rebuild$;
