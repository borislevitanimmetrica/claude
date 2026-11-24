-- ===========================================================================
-- load_suffix_groups.sql
--
-- Rules on the suffix groupings. Same shape as load_alias_decisions.sql,
-- because it is the same kind of question: are these two names one network.
--
-- WHAT A GROUPING IS, since Boris asked 2026-11-24 "I don't understand what
-- you mean by group". A router's location comes from its hostname, and a
-- carrier names its routers under several DNS suffixes. AT&T's are under
-- sbcglobal.net, bellsouth.net and att.com. The site list was keyed by that
-- suffix, so AT&T existed three times with 110, 2 and 1 sites, and the
-- distance from an AT&T tract to the nearest AT&T site was computed against
-- ONE of those lists. Grouping means putting the three lists together before
-- measuring, so AT&T is measured against all 113 of its sites. Nothing about
-- the coordinates changes; only which sites count as the same company's.
--
--   y, yes   the suffixes under that carrier_key are one carrier. Confirmed,
--            and step 4 then measures against the whole group.
--   n, no    not one carrier. The row is deleted from the grouping.
--   blank    left as proposed, which step 4 ignores.
--
-- Rule by SUFFIX, one row at a time, so that a group that is right except
-- for one suffix can be fixed by answering n on that row alone.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/load_suffix_groups.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'carrier_suffix_group_tbl') THEN
        RAISE EXCEPTION 'carrier_suffix_group_tbl does not exist. Run site_inventory_audit.sql first. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

DROP TABLE IF EXISTS suffix_group_stage_tbl;
CREATE TABLE suffix_group_stage_tbl (
    suffix      text,
    carrier_key text,
    sites       text,
    note        text,
    decision    text);

\copy suffix_group_stage_tbl FROM '/home/boris/geo/carrier_suffix_approval.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

ANALYZE suffix_group_stage_tbl;

DO $check$
DECLARE bad bigint; detail text;
BEGIN
    SELECT count(*), string_agg(format('%s had %L', suffix, decision), '; ')
      INTO bad, detail
    FROM suffix_group_stage_tbl
    WHERE btrim(coalesce(decision, '')) <> ''
      AND lower(btrim(decision)) NOT IN ('y', 'yes', 'n', 'no');
    IF bad > 0 THEN
        RAISE EXCEPTION 'the decision column holds % value(s) that are neither yes, no nor blank: %. Nothing was written.', bad, left(detail, 400);
    END IF;
END
$check$;

\echo
\echo What is about to change.
\echo
SELECT lower(btrim(coalesce(decision, ''))) AS decision, count(*) AS suffixes
FROM suffix_group_stage_tbl GROUP BY 1 ORDER BY 2 DESC;

UPDATE carrier_suffix_group_tbl g
SET status = 'confirmed', ruled_at = now(),
    note = coalesce(g.note, '') || ' | confirmed by boris'
FROM suffix_group_stage_tbl s
WHERE g.suffix = s.suffix
  AND lower(btrim(coalesce(s.decision, ''))) IN ('y', 'yes')
  AND g.status <> 'confirmed';

DELETE FROM carrier_suffix_group_tbl g
USING suffix_group_stage_tbl s
WHERE g.suffix = s.suffix
  AND lower(btrim(coalesce(s.decision, ''))) IN ('n', 'no');

ANALYZE carrier_suffix_group_tbl;

\echo
\echo The grouping now. Only confirmed rows reach step 4.
\echo
SELECT g.carrier_key, g.status,
       count(*)                                  AS suffixes,
       string_agg(g.suffix, ', ' ORDER BY g.suffix) AS suffixes_listed
FROM carrier_suffix_group_tbl g
GROUP BY 1, 2 ORDER BY 2, 1;

\echo
\echo A carrier_key with suffixes in BOTH states is half ruled, and step 4
\echo will measure it against the confirmed half only. Worth finishing.
\echo
SELECT carrier_key,
       count(*) FILTER (WHERE status = 'confirmed') AS confirmed,
       count(*) FILTER (WHERE status = 'proposed')  AS still_proposed
FROM carrier_suffix_group_tbl
GROUP BY 1
HAVING count(*) FILTER (WHERE status = 'confirmed') > 0
   AND count(*) FILTER (WHERE status = 'proposed')  > 0
ORDER BY 3 DESC;

\echo
\echo NOW RE-RUN step4_tract_site.sql, or nothing you just confirmed takes
\echo effect: the site scope is rebuilt there.
\echo   psql -f /home/boris/geo/src/claude/geo/carrier_nodes/step4_tract_site.sql
\echo

\timing off
