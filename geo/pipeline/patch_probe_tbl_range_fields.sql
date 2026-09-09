-- patch_probe_tbl_range_fields.sql
-- One-off repair of ip2city_dbiplite_probe_tbl for rows that predate start_ip,
-- end_ip and randomised probe targets.
--
-- WHY THIS IS NEEDED ONCE, AND ONLY ONCE
--
-- The live probe table was populated before start_ip and end_ip existed as
-- columns and before query held a randomly chosen host address. Measured on
-- 2026-09-09: 2089296 rows, all with start_ip and end_ip NULL, and query holding
-- the network base address of each range.
--
-- The practical consequence is that every probe issued so far targeted the .0
-- address of its range. That is a systematically unrepresentative sample: the
-- network address is more likely than a random host to be unrouted, to be
-- assigned to infrastructure, or to be treated differently by a geolocation
-- provider.
--
-- WHAT THIS DOES
--
--   start_ip and end_ip are filled in for every row that lacks them. They
--   describe the range, not the probe, so populating them for already-probed rows
--   is correct and makes the history archive complete.
--
--   query is re-randomised ONLY where ran_at IS NULL. A probed row's query is the
--   record of what was actually sent to ip-api, so rewriting it would falsify
--   history. Those rows keep their base address and their results.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
--   It does not clear ran_at, so no completed probe is discarded and no API
--   budget is spent again. The 7053 probes already done stay done, with their .0
--   targets recorded honestly.
--
-- NO FOLLOW-UP IS REQUIRED. rebuild_probe_tbl.sql already populates all three
-- columns correctly, verified by scratch_test_rollover.sh, so the next cycle
-- rollover produces correct rows without this patch. This exists solely to repair
-- the current cycle in place rather than discard it.
--
-- CONCURRENCY: safe to run while probing. This takes row locks, so an in-flight
-- probe UPDATE waits for it rather than failing, and PostgreSQL re-evaluates the
-- CASE against the committed row version, so a row probed mid-patch keeps its
-- query. Running it in the gap between hourly batches, roughly minute 58 to
-- minute 5, avoids stalling a batch at all.
--
-- Contains NO backslashes so it survives copy/paste.

DO $patch$
DECLARE
    v_before_null   bigint;
    v_before_probed bigint;
    v_patched       bigint;
    v_t0            timestamptz := clock_timestamp();
    v_still_null    bigint;
    v_oor           bigint;
    v_masked        bigint;
    v_after_probed  bigint;
BEGIN
    SELECT count(*) FILTER (WHERE start_ip IS NULL OR end_ip IS NULL),
           count(*) FILTER (WHERE ran_at IS NOT NULL)
      INTO v_before_null, v_before_probed
      FROM ip2city_dbiplite_probe_tbl;

    RAISE NOTICE 'before: % rows missing start_ip or end_ip, % rows already probed', v_before_null, v_before_probed;

    IF v_before_null = 0 THEN
        RAISE NOTICE 'nothing to patch, start_ip and end_ip are already populated everywhere';
        RETURN;
    END IF;

    -- Single pass. Updating only non-indexed columns leaves network untouched, so
    -- these can be HOT updates and the two indexes on the table are not rewritten.
    --
    -- host(...)::inet on the query expression is required: network() returns an
    -- inet that keeps the prefix length, so an unwrapped sum yields 1.2.3.7/24
    -- rather than a host address, which sorts below its own /32 start_ip and
    -- breaks range comparisons.
    UPDATE ip2city_dbiplite_probe_tbl p SET
        start_ip = host(network(p.network))::inet,
        end_ip   = host(broadcast(p.network))::inet,
        query    = CASE
                     WHEN p.ran_at IS NULL THEN
                       host(network(p.network) + (floor(random() * least(
                           2::numeric ^ (CASE WHEN family(p.network) = 4
                                              THEN 32 - masklen(p.network)
                                              ELSE 128 - masklen(p.network) END),
                           4294967296::numeric)))::bigint)::inet
                     ELSE p.query
                   END
    WHERE p.start_ip IS NULL OR p.end_ip IS NULL;

    GET DIAGNOSTICS v_patched = ROW_COUNT;
    RAISE NOTICE 'patched % rows in %', v_patched, clock_timestamp() - v_t0;

    SELECT count(*) FILTER (WHERE start_ip IS NULL OR end_ip IS NULL),
           count(*) FILTER (WHERE query < start_ip OR query > end_ip),
           count(*) FILTER (WHERE family(query) = 4 AND masklen(query) <> 32),
           count(*) FILTER (WHERE ran_at IS NOT NULL)
      INTO v_still_null, v_oor, v_masked, v_after_probed
      FROM ip2city_dbiplite_probe_tbl;

    RAISE NOTICE 'after: % missing bounds, % targets out of range, % targets carrying a prefix, % rows probed',
                 v_still_null, v_oor, v_masked, v_after_probed;

    IF v_still_null <> 0 OR v_oor <> 0 OR v_masked <> 0 THEN
        RAISE EXCEPTION 'patch verification failed: missing_bounds=% out_of_range=% masked=%. Rolling back.',
                        v_still_null, v_oor, v_masked;
    END IF;

    IF v_after_probed < v_before_probed THEN
        RAISE EXCEPTION 'probed row count fell from % to %, which means completed work was destroyed. Rolling back.',
                        v_before_probed, v_after_probed;
    END IF;

    RAISE NOTICE 'patch verified: every row has range bounds, every target is an in-range host address, and no completed probe was lost';
END
$patch$;
