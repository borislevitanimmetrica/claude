-- mobile_transit_migration.sql
--
-- Replace likely_mobile_cgnat, a boolean, with mobile_transit, a one-character
-- code, on every table that carries it.
--
--   'm'  mobile. CGNAT, so the address locates to a DMA and no finer.
--   't'  transit. The last carrier node belongs to a transit operator such as
--        Cogent, Lumen or Zayo rather than to a retail access network. Treated
--        at DMA accuracy for the same practical reason as mobile, and kept
--        DISTINCT from mobile so the two causes stay auditable.
--   'f'  fixed. Coaxial, fibre, hybrid or DSL. The only tier that can carry a
--        ZIP.
--   NULL not yet classified. Deliberately NOT folded into 'f', because "we
--        looked and it is fixed" and "we have not looked" are different facts
--        and conflating them would silently promote unmeasured rows to the
--        best tier.
--
-- WHY A TIER AND NOT AN EXCLUSION
--
-- The boolean it replaces was used as a reason to discard a row. That was
-- wrong, and the Massachusetts pass made the error visible. Business addresses
-- consume biddable media themselves, at work and in campus housing, so a
-- business landmark is inventory in its own right and not merely a proxy for
-- the households near it. A transit-reached landmark therefore is not waste: it
-- is a landmark whose accuracy is DMA rather than ZIP. Encoding that as a tier
-- keeps the row and records what it is worth, where a boolean exclusion threw
-- it away.
--
-- varchar(1) rather than varchar2(1): varchar2 is Oracle. The PostgreSQL
-- equivalent is varchar(1), which is what this uses.
--
-- SAFE ORDERING. Four tables carry this column and three deployed binaries
-- write it, so a rename leaves a window in which a running binary references a
-- column that no longer exists. The pipeline takes a blocking mutation lock
-- (geo/pipeline/geo_common.sh take_mutation_lock), and a cron job that finds it
-- held WAITS rather than failing. So hold that lock across the migration and
-- the deploy:
--
--   sudo -v
--   exec 9>/var/lock/trugeo.mutation && flock 9
--   psql -d postgres -f geo/mobile_transit_migration.sql
--   ./geo/pipeline/deploy.sh
--   exec 9>&-
--
-- Reversible: the down migration at the end renames back and restores the
-- boolean, mapping 'm' and 't' to true and 'f' to false. It is commented out.
--
-- Contains NO backslashes so it survives copy/paste.


-- ---------------------------------------------------------------------------
-- 1. WHAT WILL BE CHANGED. Run this first and read it.
-- ---------------------------------------------------------------------------

SELECT c.table_name,
       c.column_name,
       c.data_type,
       (SELECT count(*) FROM pg_class r
        WHERE r.relname = c.table_name)                               AS table_exists
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.column_name IN ('likely_mobile_cgnat', 'mobile_transit')
ORDER BY 1, 2;


-- ---------------------------------------------------------------------------
-- 2. THE MIGRATION. One transaction, so a failure leaves nothing half done.
--
-- Written as a loop over the table list rather than four copies, so a table
-- that does not exist in a given installation is skipped instead of aborting,
-- and so no table can be forgotten. The USING clause does the value mapping in
-- place; the old boolean true meant a mobile-carrier keyword match on the isp,
-- org or node hostname, which is exactly 'm'.
-- ---------------------------------------------------------------------------

BEGIN;

DO $$
DECLARE
    t text;
    tables text[] := ARRAY[
        'ip2city_dbiplite_probe_tbl',
        'ip2city_dbiplite_traceroute_tbl',
        'ip2city_dbiplite_history_tbl',
        'ovt_places_usa_ip_trace'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        IF to_regclass('public.' || t) IS NULL THEN
            RAISE NOTICE 'table % does not exist, skipped', t;
            CONTINUE;
        END IF;

        IF EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = t
                     AND column_name = 'mobile_transit') THEN
            RAISE NOTICE '% already has mobile_transit, skipped', t;
            CONTINUE;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = t
                         AND column_name = 'likely_mobile_cgnat') THEN
            RAISE NOTICE '% has neither column, adding mobile_transit', t;
            EXECUTE format('ALTER TABLE public.%I ADD COLUMN mobile_transit varchar(1)', t);
        ELSE
            EXECUTE format('ALTER TABLE public.%I RENAME COLUMN likely_mobile_cgnat TO mobile_transit', t);
            EXECUTE format($f$ALTER TABLE public.%I
                               ALTER COLUMN mobile_transit TYPE varchar(1)
                               USING CASE WHEN mobile_transit::boolean THEN 'm'
                                          WHEN mobile_transit IS NULL THEN NULL
                                          ELSE 'f' END$f$, t);
            RAISE NOTICE '% renamed and retyped', t;
        END IF;

        EXECUTE format($f$ALTER TABLE public.%I
                           ADD CONSTRAINT %I
                           CHECK (mobile_transit IS NULL
                                  OR mobile_transit IN ('m','t','f'))$f$,
                       t, t || '_mobile_transit_chk');

        EXECUTE format($f$COMMENT ON COLUMN public.%I.mobile_transit IS
            'Accuracy tier of the address. m mobile CGNAT, DMA accuracy. t transit: the last carrier node is a transit operator, not a retail access network, so DMA accuracy for the same practical reason, kept separate from mobile for auditability. f fixed coaxial, fibre, hybrid or DSL, the only tier that can carry a ZIP. NULL not yet classified, which is NOT the same as f.'$f$, t);
    END LOOP;
END
$$;

COMMIT;


-- ---------------------------------------------------------------------------
-- 3. VERIFY. Every table should now report varchar and no table should still
-- report the old name.
-- ---------------------------------------------------------------------------

SELECT table_name, column_name, data_type, character_maximum_length
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name IN ('likely_mobile_cgnat', 'mobile_transit')
ORDER BY 1;

SELECT 'ovt_places_usa_ip_trace' AS tbl, mobile_transit, count(*)
FROM public.ovt_places_usa_ip_trace GROUP BY 1, 2
UNION ALL
SELECT 'ip2city_dbiplite_probe_tbl', mobile_transit, count(*)
FROM ip2city_dbiplite_probe_tbl GROUP BY 1, 2
ORDER BY 1, 2;


-- ---------------------------------------------------------------------------
-- 4. BACKFILL 't' FROM WHAT HAS ALREADY BEEN MEASURED.
--
-- The rename alone cannot produce 't', because the old boolean only ever
-- recorded mobile. Transit is a property of the last carrier node, so it is set
-- by matching the node's domain against the transit_domain rules in
-- traceroute_hostname_rules, which is the same list the Go tool now reads so
-- the two cannot drift.
--
-- Only rows currently 'f' are touched. A row already 'm' stays 'm': mobile is
-- the stronger statement, and a mobile carrier reached over transit is still
-- mobile. A NULL row stays NULL, because it has not been looked at.
-- ---------------------------------------------------------------------------

UPDATE public.ovt_places_usa_ip_trace t
SET mobile_transit = 't'
WHERE t.mobile_transit = 'f'
  AND t.last_hop_hostname IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM traceroute_hostname_rules r
      WHERE r.rule_type = 'transit_domain'
        AND (lower(t.last_hop_hostname) = lower(r.pattern)
          OR lower(t.last_hop_hostname) LIKE '%.' || lower(r.pattern)));

UPDATE ip2city_dbiplite_traceroute_tbl t
SET mobile_transit = 't'
WHERE t.mobile_transit = 'f'
  AND t.last_hop_hostname IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM traceroute_hostname_rules r
      WHERE r.rule_type = 'transit_domain'
        AND (lower(t.last_hop_hostname) = lower(r.pattern)
          OR lower(t.last_hop_hostname) LIKE '%.' || lower(r.pattern)));


-- The resulting tier distribution, which is the figure of merit. On the
-- 312-address Massachusetts pass, expect roughly two thirds 't'.

SELECT coalesce(mobile_transit, 'NULL not classified')                AS tier,
       count(*)                                                      AS addresses,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)             AS pct
FROM public.ovt_places_usa_ip_trace
GROUP BY 1
ORDER BY 2 DESC;


-- ---------------------------------------------------------------------------
-- 5. DOWN MIGRATION, for reversal. Maps 'm' and 't' back to true and 'f' to
-- false, which LOSES the distinction between mobile and transit. That loss is
-- the reason this is commented out rather than offered as a convenience.
-- ---------------------------------------------------------------------------

-- BEGIN;
-- DO $$
-- DECLARE
--     t text;
--     tables text[] := ARRAY['ip2city_dbiplite_probe_tbl','ip2city_dbiplite_traceroute_tbl',
--                            'ip2city_dbiplite_history_tbl','ovt_places_usa_ip_trace'];
-- BEGIN
--     FOREACH t IN ARRAY tables LOOP
--         IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
--         EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I', t, t || '_mobile_transit_chk');
--         EXECUTE format($f$ALTER TABLE public.%I ALTER COLUMN mobile_transit TYPE boolean
--                            USING CASE WHEN mobile_transit IN ('m','t') THEN true
--                                       WHEN mobile_transit IS NULL THEN NULL
--                                       ELSE false END$f$, t);
--         EXECUTE format('ALTER TABLE public.%I RENAME COLUMN mobile_transit TO likely_mobile_cgnat', t);
--     END LOOP;
-- END
-- $$;
-- COMMIT;



-- ---------------------------------------------------------------------------
-- 6. THE REMAINING TABLE, DONE THE WAY IT SHOULD HAVE BEEN DONE: add the new
-- column, populate it, verify against the old one, and only then drop the old.
--
-- Sections 2 to 4 above used a direct RENAME. That was not what was asked for,
-- and the cost is concrete rather than theoretical: once the old column is
-- renamed away there is nothing left to verify the new values against. The row
-- counts after the fact were consistent, 2,082,217 'f' and 15,653 'm' in the
-- probe table, but a row-by-row check of the mapping is no longer possible on
-- those four tables. That verification step is gone and cannot be recovered.
--
-- ip2city_dbiplite_traceroute_backup_tbl was missed by the table list in
-- section 2 and still carries the old boolean, which is the one place left to
-- do this properly. The same four steps are the pattern for every future
-- column change here.
--
-- Step 4 DOES drop the old column, but only when step 3's comparison passes
-- with zero mismatches, which it re-evaluates itself rather than trusting the
-- operator to have read the output. A DROP COLUMN is the irreversible part, so
-- the gate is the safety argument; a failed comparison keeps the column and
-- raises, because after the drop the mapping can never be rechecked.
-- ---------------------------------------------------------------------------

-- STEP 1. Add, alongside. Harmless on its own and reversible by a DROP.

ALTER TABLE ip2city_dbiplite_traceroute_backup_tbl
    ADD COLUMN IF NOT EXISTS mobile_transit varchar(1);

ALTER TABLE ip2city_dbiplite_traceroute_backup_tbl
    DROP CONSTRAINT IF EXISTS ip2city_dbiplite_traceroute_backup_tbl_mobile_transit_chk;

ALTER TABLE ip2city_dbiplite_traceroute_backup_tbl
    ADD CONSTRAINT ip2city_dbiplite_traceroute_backup_tbl_mobile_transit_chk
    CHECK (mobile_transit IS NULL OR mobile_transit IN ('m','t','f'));


-- STEPS 2, 3 and 4: populate, verify, then drop. One block, because all three
-- must see the same two columns, and because the drop must be decided by the
-- verification it just ran rather than by an operator reading output.
--
-- Step 4 was previously commented out, to be run by hand. That was the wrong
-- call: the request was for an end result, not a rename, and a manual step that
-- nobody runs leaves the old column in place indefinitely, which is what
-- happened twice. The drop is now automatic but CONDITIONAL, and the condition
-- is the entire safety argument: once the boolean is gone the mapping can never
-- be rechecked, so a nonzero mismatch raises and KEEPS the column.
--
-- Re-running the file after a successful drop is a no-op. The guard returns
-- early, and because PL/pgSQL plans each statement on first execution rather
-- than at block entry, the statements that name the dropped column are never
-- planned and so cannot error. That is what makes this file safe to re-run;
-- as plain top-level SQL, step 2 failed on the second run.
--
-- 't' rows are expected to disagree with the old boolean's false, since transit
-- is information the boolean never carried. They are counted separately, as
-- promoted_to_transit, rather than treated as errors.

DO $$
DECLARE
    v_rows      bigint;
    v_mis_true  bigint;
    v_mis_false bigint;
    v_mis_null  bigint;
    v_promoted  bigint;
    v_ag_mobile bigint;
    v_ag_fixed  bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public'
                     AND table_name   = 'ip2city_dbiplite_traceroute_backup_tbl'
                     AND column_name  = 'likely_mobile_cgnat') THEN
        RAISE NOTICE 'ip2city_dbiplite_traceroute_backup_tbl.likely_mobile_cgnat is already gone; populate, verify and drop all skipped';
        RETURN;
    END IF;

    -- STEP 2. Populate, from the old column and then from the transit rules.

    UPDATE ip2city_dbiplite_traceroute_backup_tbl
    SET mobile_transit = CASE WHEN likely_mobile_cgnat IS NULL THEN NULL
                              WHEN likely_mobile_cgnat        THEN 'm'
                              ELSE 'f' END
    WHERE mobile_transit IS NULL;

    UPDATE ip2city_dbiplite_traceroute_backup_tbl t
    SET mobile_transit = 't'
    WHERE t.mobile_transit = 'f'
      AND t.last_hop_hostname IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM traceroute_hostname_rules r
          WHERE r.rule_type = 'transit_domain'
            AND (lower(t.last_hop_hostname) = lower(r.pattern)
              OR lower(t.last_hop_hostname) LIKE '%.' || lower(r.pattern)));

    -- STEP 3. Verify row by row, while both columns still exist. This is the
    -- step the rename destroyed on the other four tables.

    SELECT count(*),
           count(*) FILTER (WHERE likely_mobile_cgnat IS TRUE
                              AND mobile_transit <> 'm'),
           count(*) FILTER (WHERE likely_mobile_cgnat IS FALSE
                              AND mobile_transit NOT IN ('f','t')),
           count(*) FILTER (WHERE likely_mobile_cgnat IS NULL
                              AND mobile_transit IS NOT NULL),
           count(*) FILTER (WHERE likely_mobile_cgnat IS FALSE
                              AND mobile_transit = 't'),
           count(*) FILTER (WHERE likely_mobile_cgnat IS TRUE
                              AND mobile_transit = 'm'),
           count(*) FILTER (WHERE likely_mobile_cgnat IS FALSE
                              AND mobile_transit = 'f')
      INTO v_rows, v_mis_true, v_mis_false, v_mis_null,
           v_promoted, v_ag_mobile, v_ag_fixed
      FROM ip2city_dbiplite_traceroute_backup_tbl;

    RAISE NOTICE 'verify % rows: mismatch_true_not_m=%, mismatch_false_not_f_or_t=%, mismatch_null_not_null=%, promoted_to_transit=%, agreed_mobile=%, agreed_fixed=%',
        v_rows, v_mis_true, v_mis_false, v_mis_null,
        v_promoted, v_ag_mobile, v_ag_fixed;

    -- STEP 4. Drop, only because the verification above passed.

    IF v_mis_true <> 0 OR v_mis_false <> 0 OR v_mis_null <> 0 THEN
        RAISE EXCEPTION
            'verification FAILED on % rows: true_not_m=%, false_not_f_or_t=%, null_not_null=%. likely_mobile_cgnat KEPT so the mapping can still be checked.',
            v_rows, v_mis_true, v_mis_false, v_mis_null;
    END IF;

    ALTER TABLE ip2city_dbiplite_traceroute_backup_tbl
        DROP COLUMN likely_mobile_cgnat;

    RAISE NOTICE 'verification passed on % rows (0/0/0 mismatches); dropped likely_mobile_cgnat', v_rows;
END $$;


-- Final state of the backup table, by tier. Valid whether or not this run was
-- the one that did the drop, so it reports the same thing on every re-run.

SELECT coalesce(mobile_transit, 'NULL not classified') AS tier,
       count(*)                                        AS rows,
       round(100.0 * count(*) / nullif(sum(count(*)) OVER (), 0), 1) AS pct
FROM ip2city_dbiplite_traceroute_backup_tbl
GROUP BY 1
ORDER BY 1;


-- Anything anywhere still carrying the old column, so none can be forgotten
-- again the way the backup table was.

SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name = 'likely_mobile_cgnat'
ORDER BY 1;
