-- ===========================================================================
-- site_inventory_audit.sql
--
-- WHY THIS EXISTS. Boris 2026-11-24, on my reporting that att.com resolved
-- one site with a "1,412 km median error":
--
--   "What does this mean? AT&T operates conventional cable through headends,
--    xDSL through COs, and fiber through a subset of COs. No error of more
--    than several miles should occur. We are spending much time on step 2
--    because you don't think one step ahead and don't check your work."
--
-- He is right, and the number was not what I called it.
--
-- WHAT THAT NUMBER ACTUALLY WAS. step4_tract_site.sql measures, for each
-- census tract a carrier serves, the distance to the NEAREST SITE THAT
-- CARRIER HAS IN THE TABLE. 1,412 km is the median of that distance for
-- AT&T. It is not a geolocation error: no site was placed 1,412 km from
-- where it is. It is the distance from AT&T's tracts to the single site
-- AT&T had, which is a measure of a MISSING INVENTORY and says nothing
-- about accuracy. Calling it an error was my mistake and it hid the cause.
--
-- THE CAUSE, which is a bug and not a limit of the method.
-- step4_tract_site.sql line 240: WHERE s.carrier_domain = ct.itdk_domain.
-- serving_site_tbl groups sites by the LAST TWO LABELS OF THE HOSTNAME, so
-- carrier_domain is a DNS suffix, and the nearest-site search then treats
-- one suffix as one carrier. A carrier that names its routers under several
-- suffixes is split into several carriers, and each gets a fraction of its
-- own sites. Measured from this repository's own Hoiho suffix table:
--
--   suffix             routers   hints   ppv     whose
--   sbcglobal.net        5,624     123   0.965   AT&T
--   bellsouth.net           65      25   0.831   AT&T
--   alter.net            7,303     223   0.991   Verizon
--   verizon-gni.net      4,172     336   0.977   Verizon
--   verizon.net          7,985      29   0.999   Verizon
--   comcast.net        255,906   1,029   0.999   Comcast
--   charter.com         10,997   1,198   0.998   Charter
--   frontiernet.net     15,357     324   0.990   Frontier
--   windstream.net      16,956     333   0.990   Windstream
--   qwest.net            5,642      72   0.957   Lumen
--
-- AT&T was measured against the sites under att.com alone, and att.com is
-- not even in that table. Its 5,624 sbcglobal.net routers were attributed to
-- a separate "carrier" called sbcglobal.net. Verizon was measured against
-- verizon.net alone, 157 sites, while alter.net and verizon-gni.net hold
-- 11,475 more routers between them.
--
-- WHAT THIS FILE DOES. Nothing destructive, and it writes no decision.
--   1. Lists every suffix that HAS located sites, with its site count, so
--      the inventory is visible per suffix instead of per carrier.
--   2. Builds carrier_suffix_group_tbl, which says which suffixes belong to
--      one carrier. Every row is status proposed, because the grouping is MY
--      inference and he has not ruled on it.
--   3. Re-measures the median distance using the GROUPED site set, against
--      the single-suffix number, so the size of the bug is a measurement
--      rather than an argument. The re-measurement is on a SAMPLE of tracts
--      per carrier, stated as such, because the nearest-site search is a
--      cross product and AT&T alone serves 39,617 tracts.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/site_inventory_audit.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
DECLARE missing text;
BEGIN
    SELECT string_agg(t.needed, ', ') INTO missing
    FROM (VALUES ('serving_site_tbl'), ('census_tract_tbl'),
                 ('carrier_resolved_tbl'), ('provider_brand_tract_tech_tbl'))
         AS t(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables i
                      WHERE i.table_name = t.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing %. serving_site_tbl comes from step4_tract_site.sql section 1. Nothing was read.', missing;
    END IF;

    SELECT string_agg(c.needed, ', ') INTO missing
    FROM (VALUES ('lat'), ('lon')) AS c(needed)
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns i
                      WHERE i.table_name = 'census_tract_tbl'
                        AND i.column_name = c.needed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'census_tract_tbl has no % column, so no distance can be computed. Columns present: %', missing,
            (SELECT string_agg(column_name, ', ' ORDER BY column_name)
             FROM information_schema.columns WHERE table_name = 'census_tract_tbl');
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

\echo
\echo ================================================================
\echo 1. EVERY SUFFIX THAT HAS LOCATED SITES. carrier_domain is a DNS
\echo suffix, not a carrier, which is the whole defect: a carrier that
\echo names routers under several suffixes was split into several
\echo carriers and each got a fraction of its own sites.
\echo ================================================================
\echo
SELECT s.carrier_domain,
       count(*)                                        AS sites,
       sum(s.node_addresses)                           AS node_addresses,
       count(*) FILTER (WHERE s.grade = 'facility')    AS facility_grade,
       EXISTS (SELECT 1 FROM carrier_resolved_tbl r
               WHERE r.itdk_domain = s.carrier_domain
                 AND r.bdc_provider_id IS NOT NULL)    AS linked_to_a_bdc_provider
FROM serving_site_tbl s
GROUP BY s.carrier_domain
ORDER BY count(*) DESC
LIMIT 60;

SELECT count(DISTINCT carrier_domain) AS suffixes_with_sites,
       count(*)                       AS sites_total
FROM serving_site_tbl;

-- ---------------------------------------------------------------------------
-- 2. THE GROUPING, ALL OF IT PROPOSED.
--
-- One row per suffix saying which carrier it belongs to. This is the same
-- shape as carrier_alias_tbl and for the same reason: it is a statement
-- about which names are one network, it cannot be derived from the strings,
-- and it is MY inference until he rules on it. Nothing in the pipeline reads
-- it yet; this file only measures what it would do.
--
-- The suffixes below are the ones I can name. Section 1 lists every suffix
-- that has sites, so any carrier I have missed is visible there rather than
-- silently absent.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS carrier_suffix_group_tbl (
    suffix      text PRIMARY KEY,
    carrier_key text NOT NULL,
    status      text NOT NULL CHECK (status IN ('confirmed', 'proposed')),
    note        text,
    ruled_at    timestamptz NOT NULL DEFAULT now());

COMMENT ON TABLE carrier_suffix_group_tbl IS
'Which DNS suffixes belong to one carrier, so that the nearest-site search in step 4 measures against all of that carrier''s sites instead of the sites under one suffix. status proposed means I inferred the grouping and it must not be used for a decision; confirmed means Boris ruled it.';

INSERT INTO carrier_suffix_group_tbl (suffix, carrier_key, status, note)
SELECT v.suffix, v.carrier_key, 'proposed', v.note
FROM (VALUES
 ('att.com',          'att',        'AT&T corporate domain'),
 ('att.net',          'att',        'AT&T consumer domain'),
 ('sbcglobal.net',    'att',        'former SBC, AT&T lightspeed hostnames encode a wire centre'),
 ('ameritech.net',    'att',        'former Ameritech, AT&T Midwest'),
 ('pacbell.net',      'att',        'former Pacific Bell, AT&T California'),
 ('swbell.net',       'att',        'former Southwestern Bell'),
 ('bellsouth.net',    'att',        'former BellSouth, AT&T Southeast'),
 ('prodigy.net',      'att',        'former Prodigy, AT&T'),
 ('alter.net',        'verizon',    'former UUNET, Verizon Business backbone'),
 ('verizon.net',      'verizon',    'Verizon consumer'),
 ('verizon-gni.net',  'verizon',    'Verizon GNI access network'),
 ('gnilink.net',      'verizon',    'Verizon GNI, older naming'),
 ('comcast.net',      'comcast',    'Comcast consumer'),
 ('comcastbusiness.net','comcast',  'Comcast business'),
 ('charter.com',      'charter',    'Charter corporate'),
 ('spectrum.com',     'charter',    'Charter trading as Spectrum'),
 ('rr.com',           'charter',    'former Time Warner Road Runner, now Charter'),
 ('qwest.net',        'lumen',      'former Qwest, CenturyLink and Lumen'),
 ('centurylink.net',  'lumen',      'CenturyLink'),
 ('level3.net',       'lumen',      'Level 3, now Lumen'),
 ('frontiernet.net',  'frontier',   'Frontier'),
 ('windstream.net',   'windstream', 'Windstream'),
 ('cox.net',          'cox',        'Cox'),
 ('zayo.com',         'zayo',       'Zayo'),
 ('cogentco.com',     'cogent',     'Cogent'),
 -- added 2026-11-24 from his own run: suffixes that HAVE sites and were
 -- outside the grouping. Transit, hosting and research networks are left
 -- out deliberately, being out of scope: he.net, gtt.net, twelve99,
 -- above.net, tierpoint, flexential, unitasglobal, cenic, oar, wiscnet.
 ('lumen.tech',       'lumen',      'Lumen corporate'),
 ('ctl.one',          'lumen',      'CenturyLink'),
 ('savvis.net',       'lumen',      'former Savvis, now Lumen'),
 ('unitifiber.com',   'uniti',      'Uniti Fiber'),
 ('uniti.net',        'uniti',      'Uniti'),
 ('lightower.net',    'firstlight', 'Lightower, merged into FirstLight'),
 ('firstlight.net',   'firstlight', 'FirstLight'),
 ('rcn.com',          'astound',    'RCN, now Astound'),
 ('rcn.net',          'astound',    'RCN, now Astound'),
 ('sparklight.net',   'cableone',   'Cable One trading as Sparklight'),
 ('knology.net',      'wow',        'former Knology, now WOW'),
 ('wideopenwest.com', 'wow',        'WOW'),
 ('ziplyfiber.com',   'ziply',      'Ziply Fiber'),
 ('gobrightspeed.net','brightspeed','Brightspeed'),
 ('fuse.net',         'altafiber',  'Cincinnati Bell trading as altafiber'),
 ('acsalaska.net',    'alaskacomm', 'Alaska Communications'),
 ('googlefiber.net',  'googlefiber','Google Fiber'),
 ('lightpath.net',    'lightpath',  'Cablevision Lightpath'),
 ('tds.net',          'tds',        'TDS Telecom'),
 ('123.net',          '123net',     '123.Net'),
 ('netins.net',       'netins',     'Netins'),
 ('ena.net',          'ena',        'Education Networks of America'),
 ('ussignalcom.net',  'ussignal',   'US Signal'),
 ('atlanticmetro.net','atlanticmetro','Atlantic Metro'),
 ('usinternet.com',   'usinternet', 'US Internet')
) AS v(suffix, carrier_key, note)
WHERE NOT EXISTS (SELECT 1 FROM carrier_suffix_group_tbl g
                  WHERE g.suffix = v.suffix);

ANALYZE carrier_suffix_group_tbl;

\echo
\echo ================================================================
\echo 2. THE PROPOSED GROUPING, and what it gathers. sites_now is what
\echo step 4 measured against: the sites of ONE suffix. sites_grouped
\echo is every site of every suffix I am proposing is the same carrier.
\echo ================================================================
\echo
SELECT g.carrier_key,
       count(DISTINCT g.suffix)                                AS suffixes_proposed,
       count(DISTINCT g.suffix) FILTER (
           WHERE EXISTS (SELECT 1 FROM serving_site_tbl s
                         WHERE s.carrier_domain = g.suffix))    AS suffixes_with_sites,
       (SELECT count(*) FROM serving_site_tbl s
        WHERE s.carrier_domain IN (SELECT suffix FROM carrier_suffix_group_tbl g2
                                   WHERE g2.carrier_key = g.carrier_key))
                                                               AS sites_grouped,
       (SELECT string_agg(x.suffix || ' ' || x.n, ', ' ORDER BY x.n DESC)
        FROM (SELECT s.carrier_domain AS suffix, count(*) AS n
              FROM serving_site_tbl s
              WHERE s.carrier_domain IN (SELECT suffix FROM carrier_suffix_group_tbl g3
                                         WHERE g3.carrier_key = g.carrier_key)
              GROUP BY 1) x)                                   AS sites_by_suffix
FROM carrier_suffix_group_tbl g
GROUP BY g.carrier_key
ORDER BY 4 DESC;

-- ---------------------------------------------------------------------------
-- 3. THE RE-MEASUREMENT.
--
-- For each proposed carrier group, the median distance from a served tract
-- to the nearest site, computed BOTH ways: over the sites of the single
-- suffix that step 4 used, and over the grouped site set.
--
-- ON A SAMPLE, and the sample size is printed. The nearest-site search is a
-- cross product of tracts and sites with no spatial index, and AT&T alone
-- serves 39,617 tracts; the full computation is a step 4 re-run, not an
-- audit. A sample settles the question this file was written to answer,
-- which is whether the grouped inventory brings the distance down to the
-- several miles Boris expects.
--
-- The tracts come from the BDC side, per technology, so a cable tract and a
-- copper tract are counted separately. The SITES are not separated by
-- technology, because ITDK cannot say which plant a router serves. That is
-- step 2's unmet half and it is recorded as such; this measurement cannot
-- settle it and does not claim to.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS site_audit_sample_tbl;
CREATE TABLE site_audit_sample_tbl AS
WITH provider AS (
    -- the BDC providers reached from any suffix of the group, through the
    -- decisions already recorded in carrier_resolved_tbl
    SELECT DISTINCT g.carrier_key, r.bdc_provider_id
    FROM carrier_suffix_group_tbl g
    JOIN carrier_resolved_tbl r ON r.itdk_domain = g.suffix
    WHERE r.bdc_provider_id IS NOT NULL
), tract AS (
    SELECT DISTINCT p.carrier_key, f.technology, f.tract_geoid
    FROM provider p
    JOIN provider_brand_tract_tech_tbl f ON f.provider_id = p.bdc_provider_id
    WHERE f.technology IN (10, 40, 50)
), sampled AS (
    SELECT carrier_key, technology, tract_geoid
    FROM (SELECT t.*, row_number() OVER (PARTITION BY t.carrier_key, t.technology
                                         ORDER BY md5(t.tract_geoid)) AS rn
          FROM tract t) x
    WHERE rn <= 400
)
-- ONE ROW PER SAMPLED TRACT AND SUFFIX. The per-suffix distance is exactly
-- what step4_tract_site.sql measures, because its nearest-site search is
-- restricted to one suffix, so this column reproduces the numbers I reported
-- including att.com 1,412 km. The grouped distance is then the minimum of
-- this column over the suffixes of one carrier, so both numbers come from
-- the same computation and cannot disagree through a second code path.
SELECT s.carrier_key, s.technology, s.tract_geoid, g.suffix,
       near.km AS km_this_suffix
FROM sampled s
JOIN census_tract_tbl c ON c.tract_geoid = s.tract_geoid
JOIN carrier_suffix_group_tbl g ON g.carrier_key = s.carrier_key
CROSS JOIN LATERAL (
    SELECT min(6371 * sqrt(
             pow(radians(v.lat - c.lat), 2) +
             pow(radians(((v.lon - c.lon + 540)
                  - floor((v.lon - c.lon + 540) / 360) * 360) - 180)
                 * cos(radians(c.lat)), 2))) AS km
    FROM serving_site_tbl v
    WHERE v.carrier_domain = g.suffix
) near
WHERE c.lat IS NOT NULL AND c.lon IS NOT NULL
  AND EXISTS (SELECT 1 FROM serving_site_tbl v2 WHERE v2.carrier_domain = g.suffix);

CREATE INDEX site_audit_sample_ix ON site_audit_sample_tbl (carrier_key, technology, tract_geoid);
ANALYZE site_audit_sample_tbl;

\echo
\echo ================================================================
\echo 3a. WHAT STEP 4 MEASURED, reproduced per suffix. These are the
\echo numbers I reported as if they described the method: cox.net 9.0,
\echo verizon.net 718.2, att.com 1,412.0.
\echo ================================================================
\echo
SELECT carrier_key, suffix,
       count(DISTINCT tract_geoid)                                        AS tracts_sampled,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY km_this_suffix)::numeric, 1) AS median_km,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY km_this_suffix)::numeric, 1) AS p90_km
FROM site_audit_sample_tbl
GROUP BY 1, 2
ORDER BY 1, 4 DESC NULLS LAST;

\echo
\echo ================================================================
\echo 3b. THE GROUPED SITE SET, per carrier and technology. 10 is
\echo Copper, 40 is Cable, 50 is Fibre to the Premises.
\echo If the grouped median is still hundreds of km the inventory is
\echo genuinely missing. If it falls to single digits, the 1,412 km was
\echo the suffix split and nothing else.
\echo ================================================================
\echo
WITH per_tract AS (
    SELECT carrier_key, technology, tract_geoid, min(km_this_suffix) AS km
    FROM site_audit_sample_tbl
    GROUP BY 1, 2, 3
)
SELECT carrier_key, technology, count(*) AS tracts_sampled,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY km)::numeric, 1) AS median_km_grouped,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY km)::numeric, 1) AS p90_km_grouped,
       count(*) FILTER (WHERE km <= 16)                                   AS within_10_miles,
       round(100.0 * count(*) FILTER (WHERE km <= 16) / nullif(count(*), 0), 1) AS pct_within_10_miles
FROM per_tract
GROUP BY 1, 2
ORDER BY 1, 2;

\echo
\echo Pooled over technologies, which is the number to set beside the
\echo per-suffix medians in 3a.
\echo
WITH per_tract AS (
    SELECT carrier_key, tract_geoid, min(km_this_suffix) AS km
    FROM site_audit_sample_tbl
    GROUP BY 1, 2
)
SELECT carrier_key, count(*) AS tracts_sampled,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY km)::numeric, 1) AS median_km_grouped,
       round(100.0 * count(*) FILTER (WHERE km <= 16) / nullif(count(*), 0), 1) AS pct_within_10_miles
FROM per_tract
GROUP BY 1
ORDER BY 3 DESC NULLS LAST;

\echo
\echo Suffixes WITH sites that my grouping does not mention. Each is a
\echo carrier I have not accounted for, visible rather than missing.
\echo
SELECT s.carrier_domain, count(*) AS sites, sum(s.node_addresses) AS node_addresses
FROM serving_site_tbl s
WHERE NOT EXISTS (SELECT 1 FROM carrier_suffix_group_tbl g
                  WHERE g.suffix = s.carrier_domain)
GROUP BY 1
ORDER BY 2 DESC
LIMIT 40;

\echo
\echo ================================================================
\echo WHY NO SITE IS AT FACILITY GRADE. Not a bug. node_location.sql
\echo assigns facility ONLY from the ITDK 'ix' method, which locates a
\echo router inside an internet exchange. Access routers are not in
\echo exchanges, so the serving sites of a carrier never carry that
\echo grade. Every site here is operator_named or site_subcity, which
\echo means the coordinate came from DNS naming by the operator.
\echo ================================================================
\echo
SELECT grade, count(*) AS sites, sum(node_addresses) AS node_addresses
FROM serving_site_tbl GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo Writing the grouping for your ruling. Put y or n in the last column
\echo and load it back with load_suffix_groups.sql. y means those suffixes
\echo are one carrier and step 4 should measure against all their sites.
\echo
\copy (SELECT g.suffix, g.carrier_key, coalesce((SELECT count(*) FROM serving_site_tbl s WHERE s.carrier_domain = g.suffix), 0) AS sites, g.note, ''::text AS decision FROM carrier_suffix_group_tbl g WHERE g.status = 'proposed' ORDER BY g.carrier_key, 3 DESC, g.suffix) TO '/home/boris/geo/carrier_suffix_approval.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\timing off
