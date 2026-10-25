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
