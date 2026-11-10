-- institution_reconciliation.sql
--
-- READ-ONLY. Two things in one pass:
--
--   1. The per-source table: records, records with ZIP and website, records
--      with onpremises = true.
--   2. The reconciliation Boris asked for several turns ago and has not yet
--      had a straight answer to: whether these counts are plausible against
--      the real number of institutions that exist in the United States.
--
--
-- THE ANSWER TO THE REALISM QUESTION, STATED BEFORE THE NUMBERS
--
-- Boris's objection was specific and correct. He gave real counts against
-- what the category tables were reporting:
--
--     police departments    11,824 real    vs   2,519 reported
--     fire departments      29,452 real    vs   ~4,900 reported
--     municipalities        19,429 real
--     counties               3,144 real
--
-- VERIFIED CAUSE, found 2026-11-06 and recorded in audit_findings.md: the
-- OpenStreetMap extraction ran an Overpass query requiring BOTH
-- ["website"] AND ["addr:postcode"] on every object. So every OSM-derived
-- figure was never a count of institutions. It was a count of
--
--     institutions that OSM happens to hold
--     AND that carry a website tag
--     AND that also carry a postcode tag
--
-- Three filters deep. For police stations that is 2,519 of 11,824, and the
-- missing 9,305 are not missing departments, they are departments whose OSM
-- record lacks one of two optional tags. I presented those numbers as
-- institution counts and they never were. That was the error.
--
-- The same caveat applies in different degrees to every source, and the whole
-- point of section 3 below is to make the applicable denominator explicit per
-- class rather than leaving it implied:
--
--   OSM, Overture, Foursquare, Wikidata   opportunistic. Coverage of any
--                                         institution class is incidental and
--                                         a low count means nothing about how
--                                         many exist.
--   USFA fire registry                    a real registry but VOLUNTARY, and
--                                         its website field is often blank.
--   CCD, state education directories,     administrative censuses. These SHOULD
--   NCES IPEDS, dotgov                    approach the real totals, so a large
--                                         shortfall here IS a finding.
--
-- So the honest framing, which section 3 measures rather than asserts: judge
-- the census sources against real counts, and do not judge the opportunistic
-- sources against them at all.
--
--
-- WHAT THE COUNTS CANNOT BE COMPARED TO
--
-- records_onpremises_true must NOT be read against the real institution
-- count. It is the count of institutions that host their own webserver on
-- their own premises, and measured 2026-11-09 by onpremises_rule_breakdown.sql
-- that is a minority of the modern web: of 825,065 places sitting in ZIPs that
-- deliver nothing, 700,745 are rejected because their site is on Cloudflare,
-- Amazon, Akamai, Google, Squarespace, Fastly, GoDaddy, WPEngine or similar.
-- An institution absent from the on-premises set usually exists, has a
-- website, and simply does not run it from its own building.
--
--
-- HOW TO RUN, AND WHAT IT COSTS
--
--   cd /home/boris/geo/src/claude/geo/landmarks
--   psql -X -f institution_reconciliation.sql
--
-- ESTIMATE, labelled as one: two to four minutes. Basis, measured on this
-- data: a single grouped pass over landmarks_usa ran 16 to 50 seconds in
-- zip_coverage_funnel.sql and onpremises_rule_breakdown.sql. This file makes
-- ONE such pass into a temp table and then aggregates that small table
-- repeatedly, specifically so the 15.1 million rows are read once.
--
-- Read-only. Temp tables only, dropped at the end. Ctrl-C costs nothing.

\timing on
\pset pager off
SET client_min_messages = warning;

\echo ''
\echo '================================================================'
\echo ' 0. SCHEMA VERIFICATION.'
\echo '================================================================'
\echo ''

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'landmarks_usa'
  AND column_name IN ('source', 'category', 'postcode', 'website',
                      'overture_zip', 'onpremises', 'lookup_status')
ORDER BY column_name;

\echo ''
\echo 'Expected: 7 rows. category is the one the class mapping depends on.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 1. ONE PASS OVER THE CORPUS. Everything else reads this.'
\echo '================================================================'
\echo ''
\echo 'with_zip_and_url counts a record that has a website AND a ZIP. The ZIP'
\echo 'may be the file postcode or the one the chain established, because for'
\echo 'this question either is sufficient: the record is usable.'
\echo ''

DROP TABLE IF EXISTS tmp_recon;

-- THE AGGREGATION AND THE CLASSIFICATION ARE IN SEPARATE STAGES, and they
-- have to be. My previous version put the class CASE in the same SELECT as
-- count(*) while grouping by the COALESCED category, so the CASE referenced a
-- bare category column that was not a grouping expression. PostgreSQL rejected
-- it outright:
--
--     ERROR: column "landmarks_usa.category" must appear in the GROUP BY
--     clause or be used in an aggregate function
--
-- and every later section then failed on a missing tmp_recon. Grouping first
-- and classifying the grouped value afterwards removes the whole class of
-- mistake: the outer query sees one row per (source, category) and nothing it
-- references is ambiguous.
CREATE UNLOGGED TABLE tmp_recon AS
WITH base AS (
    SELECT source,
           coalesce(nullif(btrim(category), ''), '(none)')           AS category,
           count(*)                                                 AS records,
           count(*) FILTER (WHERE btrim(coalesce(website, '')) <> ''
                              AND (btrim(coalesce(postcode, '')) ~ '^[0-9]{5}'
                                OR btrim(coalesce(overture_zip, '')) ~ '^[0-9]{5}'))
                                                                    AS with_zip_and_url,
           count(*) FILTER (WHERE lookup_status = 'true')            AS rdap_ok,
           count(*) FILTER (WHERE onpremises IS TRUE)                AS onpremises_true
    FROM landmarks_usa
    GROUP BY 1, 2
)
-- The class is assigned here, once, so section 3 can print exactly which raw
-- categories feed each class. Previously the mapping lived only inside section
-- 4 while section 3 printed the top categories by record count, which are all
-- generic Overture values. None of the matched categories appeared, so the
-- mapping could not be audited and its errors reached Boris as findings:
-- hospital read 857.9 per cent of the real count because '%hospital%' matches
-- animal_hospital.
-- THE MAPPING, REWRITTEN AS WHITELISTS AFTER THE FIRST AUDIT.
--
-- The first version blacklisted nothing and let ILIKE '%school%' sweep up
-- anything with the word in it. MEASURED damage, from the audit Boris ran
-- 2026-11-10:
--
--   specialty_school        67,462 rows   counted as K-12 and is a catch-all
--   preschool               36,980        counted as K-12 and is not K-12
--   school_district_office   1,510        an office, not a school
--   music, prep, dancing, driving, language, trade, flight, cooking, art,
--   beauty, vocational, surf, swim, coding, sailing, circus, acting,
--   cosmetology, golf, trapeze and baton schools, plus School Supply Store
--   and school_bus_service
--   Medical School 58 and Law School 15, both under Foursquare's College and
--   University branch, landed in K-12 purely because the school test ran
--   before the college test
--
-- A whitelist cannot fail that way: a category it does not recognise falls to
-- 'other education or training' where it is visible, instead of inflating a
-- class that is being compared to a real-world count.
--
-- RETRACTED: I told Boris the hospital figure of 857.9 per cent was probably
-- '%hospital%' catching animal_hospital. The audit shows the hospital class
-- contains only hospital, specialty_hospital, general_hospital,
-- psychiatric_hospital, hospital;clinic and Hospital Unit. There is no
-- animal_hospital in it. That explanation was wrong.
SELECT b.source,
       b.category,
       CASE
         WHEN b.source = 'usfa_fire'                                  THEN 'fire department'
         WHEN b.category ILIKE '%fire_station%' OR b.category ILIKE '%fire station%'
                                                                       THEN 'fire department'
         WHEN b.category ILIKE '%police%' AND b.category NOT ILIKE '%police_supply%'
                                                                       THEN 'police department'
         WHEN b.source = 'dotgov'                                      THEN 'government (dotgov registry)'

         -- College BEFORE school, so Medical School and Law School under
         -- Foursquare's College and University branch land here.
         WHEN b.source = 'nces_ipeds'                                  THEN 'college or university'
         WHEN b.category ILIKE '%college%' OR b.category ILIKE '%universit%'
                                                                       THEN 'college or university'

         -- K-12 by census source. ca_cde carries non-K-12 school types in the
         -- same column, so it is filtered rather than taken wholesale.
         WHEN b.source IN ('ccd','tx_askted','pa_edna','il_isbe','mn_mde','az_azgeo',
                           'wi_dpi','ia_educate','al_alsde','in_idoe','nc_dpi','ga_gosa',
                           'tn_tnsd','fl_msid','nd_insights','wv_wveis','oh_oeds','sc_scde',
                           'ut_sgid','nv_nde','hi_doe')                THEN 'K-12 school'
         WHEN b.source = 'ca_cde'
          AND b.category NOT ILIKE '%adult%'
          AND b.category NOT ILIKE '%preschool%'
          AND b.category NOT ILIKE '%ROC/ROP%'                         THEN 'K-12 school'

         -- K-12 by explicit category, whitelisted. Nothing else with the word
         -- school in it reaches this class.
         WHEN b.category ILIKE '%elementary%'
           OR b.category ILIKE '%middle school%'
           OR b.category ILIKE '%middle_school%'
           OR b.category ILIKE '%high school%'
           OR b.category ILIKE '%high_school%'
           OR b.category ILIKE '%junior high%'
           OR b.category ILIKE '%primary and secondary%'
           OR b.category ILIKE '%k-12%'
           OR b.category = 'school'                                    THEN 'K-12 school'

         WHEN b.category ILIKE '%hospital%'                            THEN 'hospital'
         WHEN b.category ILIKE '%librar%'
          AND b.category NOT ILIKE '%tool%'
          AND b.category NOT ILIKE '%toy%'                             THEN 'library'

         -- Everything else carrying the word school, so it is counted
         -- somewhere visible rather than silently inflating K-12.
         WHEN b.category ILIKE '%school%'                              THEN 'other education or training'
         ELSE                                                               'zz everything else'
       END AS institution_class,
       b.records,
       b.with_zip_and_url,
       b.rdap_ok,
       b.onpremises_true
FROM base b;

CREATE INDEX ON tmp_recon (source);
ANALYZE tmp_recon;

SELECT count(*) AS source_category_pairs, sum(records) AS records_total FROM tmp_recon;


\echo ''
\echo '================================================================'
\echo ' 2. THE TABLE REQUESTED: BY SOURCE.'
\echo '================================================================'
\echo ''

SELECT source,
       sum(records)           AS records,
       sum(with_zip_and_url)  AS records_with_zip_and_url,
       sum(onpremises_true)   AS records_onpremises_true,
       round(100.0 * sum(onpremises_true) / nullif(sum(with_zip_and_url), 0), 2)
                              AS onprem_pct_of_usable
FROM tmp_recon
GROUP BY source
ORDER BY sum(records) DESC;

\echo ''
\echo 'Totals:'
SELECT sum(records)           AS records,
       sum(with_zip_and_url)  AS records_with_zip_and_url,
       sum(onpremises_true)   AS records_onpremises_true,
       round(100.0 * sum(onpremises_true) / nullif(sum(with_zip_and_url), 0), 2)
                              AS onprem_pct_of_usable
FROM tmp_recon;

\echo ''
\echo 'onprem_pct_of_usable is the only rate worth comparing BETWEEN sources,'
\echo 'because it divides by usable records rather than by everything loaded.'
\echo ''


\echo ''
\echo '================================================================'
\echo ' 3. THE RAW CATEGORY VALUES, SO THE MAPPING CAN BE AUDITED.'
\echo '================================================================'
\echo ''
\echo 'The category column holds whatever each loader wrote: a raw OSM amenity,'
\echo 'the literal string "public school" from state_loader, a SOCType from'
\echo 'ca_cde, a Dept Type from usfa-fire. A class therefore has to be derived'
\echo 'from (source, category) and never from category alone. These are the'
\echo 'actual values, printed BEFORE any mapping, so section 4 can be checked'
\echo 'rather than believed.'
\echo ''

\echo 'EVERY raw category feeding a named class, largest first. This is the'
\echo 'audit. A category here that is not the institution the class claims is'
\echo 'a mapping error and the corresponding row of section 4 is wrong.'
\echo ''

SELECT institution_class, source, category, records, onpremises_true
FROM tmp_recon
WHERE institution_class <> 'zz everything else'
ORDER BY institution_class, records DESC;

\echo ''
\echo 'And the largest categories NOT claimed by any class, for contrast:'
SELECT source, category, records, with_zip_and_url, onpremises_true
FROM tmp_recon
WHERE institution_class = 'zz everything else'
  AND records >= 200
ORDER BY records DESC
LIMIT 25;


\echo ''
\echo '================================================================'
\echo ' 4. THE RECONCILIATION AGAINST REAL COUNTS.'
\echo '================================================================'
\echo ''
\echo 'Real counts are the figures Boris supplied. They are HIS numbers, not'
\echo 'mine, and I have not independently verified any of them.'
\echo ''

WITH agg AS (
    SELECT institution_class,
           sum(records)          AS records,
           sum(with_zip_and_url) AS with_zip_and_url,
           sum(onpremises_true)  AS onpremises_true,
           count(*)              AS raw_categories
    FROM tmp_recon GROUP BY 1
), real_counts AS (
    SELECT * FROM (VALUES
        ('fire department',              29452, 'census, Boris'),
        ('police department',            11824, 'census, Boris'),
        ('government (dotgov registry)', 22573, 'municipalities 19,429 plus counties 3,144, Boris'),
        ('K-12 school',                 131000, 'K-12 total 129,000 to 133,000, Boris'),
        ('college or university',         6000, 'IPEDS order of magnitude, NOT verified'),
        ('hospital',                      6120, 'order of magnitude, NOT verified'),
        ('library',                       9000, 'order of magnitude, NOT verified')
    ) AS t(institution_class, real_count, source_of_figure)
)
SELECT a.institution_class,
       a.raw_categories,
       a.records,
       a.with_zip_and_url,
       a.onpremises_true,
       r.real_count,
       round(100.0 * a.records / nullif(r.real_count, 0), 1)         AS pct_of_real_held,
       round(100.0 * a.onpremises_true / nullif(r.real_count, 0), 1) AS pct_of_real_onprem,
       r.source_of_figure
FROM agg a
LEFT JOIN real_counts r ON r.institution_class = a.institution_class
ORDER BY a.records DESC;

\echo ''
\echo 'ANY pct_of_real_held ABOVE 100 NEEDS EXPLAINING BEFORE IT IS BELIEVED,'
\echo 'and there are two quite different reasons it can happen.'
\echo ''
\echo '  LEGITIMATE: a count of FACILITIES exceeding a count of'
\echo '  ORGANISATIONS. There are 29,452 fire DEPARTMENTS but more fire'
\echo '  STATIONS, because one department runs several. Same for police'
\echo '  agencies against precincts, and school districts against schools.'
\echo '  The real_count column holds organisation counts, so a facility class'
\echo '  SHOULD exceed it.'
\echo ''
\echo '  A MAPPING ERROR: the ILIKE patterns are blunt. hospital catches'
\echo '  animal_hospital, school catches driving and beauty and pre schools,'
\echo '  college catches college counselling. Section 3 above now lists every'
\echo '  raw category feeding each class, so which of the two is happening can'
\echo '  be read off rather than argued about. Measured 2026-11-09 before this'
\echo '  fix: hospital read 857.9 per cent and college 1020.2 per cent, which'
\echo '  are too large to be the facilities effect alone.'
\echo ''

\echo ''
\echo 'READING THIS HONESTLY, three separate things not to confuse:'
\echo ''
\echo '  pct_of_real_held well below 100 for an OPPORTUNISTIC source class is'
\echo '  expected and says nothing about the real world. OSM, Overture,'
\echo '  Foursquare and Wikidata rows only exist where a volunteer or a vendor'
\echo '  happened to record the place, and the OSM extract additionally'
\echo '  demanded a website tag AND a postcode tag on every object.'
\echo ''
\echo '  pct_of_real_held well below 100 for a CENSUS source class IS a'
\echo '  finding and should be chased. CCD, the state directories, NCES IPEDS'
\echo '  and the dotgov registry are administrative lists that aim at'
\echo '  completeness.'
\echo ''
\echo '  pct_of_real_onprem is NOT a coverage failure at any value. Measured'
\echo '  2026-11-09: of 825,065 places in ZIPs delivering nothing, 700,745'
\echo '  were rejected because the site is hosted by Cloudflare, Amazon,'
\echo '  Akamai, Google, Squarespace, Fastly, GoDaddy or WPEngine. An'
\echo '  institution missing from the on-premises set generally exists and has'
\echo '  a website; it just does not run it from its own building. A low number'
\echo '  here is a fact about how institutions buy hosting in 2026, not a'
\echo '  defect in the corpus.'
\echo ''

\echo ''
\echo '================================================================'
\echo ' 5. THE REAL REASON THE PERCENTAGES EXCEED 100: NO DEDUPLICATION.'
\echo '================================================================'
\echo ''
\echo 'landmarks_usa is keyed on (source, source_id) and there is NO'
\echo 'cross-source deduplication anywhere. One physical school is a row in'
\echo 'Overture, another in OpenStreetMap, another in CCD and another in its'
\echo 'state directory. Four rows, one school. So records can never be'
\echo 'compared to a count of institutions, for any class, and my reconciling'
\echo 'them in section 4 was comparing incomparable things.'
\echo ''
\echo 'Foursquare makes the second cause visible. For one university it holds'
\echo 'College Library, College Gym, College Quad, Fraternity House, College'
\echo 'Cafeteria, College Track and twenty more as SEPARATE PLACES. Those are'
\echo 'facilities, not organisations.'
\echo ''
\echo 'Counting distinct WEBSITE HOSTS instead of rows addresses both at once,'
\echo 'and it is the right unit for this project anyway: the landmark method'
\echo 'anchors on a webserver, so one host is one anchor however many'
\echo 'buildings or catalogues it appears under. An institution with several'
\echo 'domains still counts several times, so this is an upper bound on'
\echo 'institutions and a far tighter one than rows.'
\echo ''
\echo 'The class mapping is JOINED from section 1 rather than restated, so the'
\echo 'two cannot drift apart. Named classes only, which is about 630,000 rows'
\echo 'rather than 15.4 million.'
\echo ''

CREATE INDEX ON tmp_recon (source, category);
ANALYZE tmp_recon;

WITH host AS (
    SELECT r.institution_class,
           substring(lower(btrim(l.website)) from '^https?://([^/:]+)') AS h,
           l.onpremises
    FROM landmarks_usa l
    JOIN tmp_recon r
      ON r.source = l.source
     AND r.category = coalesce(nullif(btrim(l.category), ''), '(none)')
    WHERE r.institution_class <> 'zz everything else'
      AND btrim(coalesce(l.website, '')) <> ''
), agg AS (
    SELECT institution_class,
           count(*)                                                       AS rows,
           count(DISTINCT h)                                              AS distinct_hosts,
           count(DISTINCT CASE WHEN onpremises IS TRUE THEN h END)        AS distinct_hosts_onprem
    FROM host GROUP BY 1
), real_counts AS (
    SELECT * FROM (VALUES
        ('fire department',              29452),
        ('police department',            11824),
        ('government (dotgov registry)', 22573),
        ('K-12 school',                 131000),
        ('college or university',         6000),
        ('hospital',                      6120),
        ('library',                       9000)
    ) AS t(institution_class, real_count)
)
SELECT a.institution_class,
       a.rows,
       a.distinct_hosts,
       round(a.rows::numeric / nullif(a.distinct_hosts, 0), 2) AS rows_per_host,
       a.distinct_hosts_onprem,
       r.real_count,
       round(100.0 * a.distinct_hosts / nullif(r.real_count, 0), 1) AS pct_of_real_by_host
FROM agg a
LEFT JOIN real_counts r ON r.institution_class = a.institution_class
ORDER BY a.rows DESC;

\echo ''
\echo 'rows_per_host is the duplication factor. A figure near 1 means rows and'
\echo 'institutions are nearly the same thing for that class. A figure of 4'
\echo 'means the average host is reached through four rows, from overlapping'
\echo 'catalogues or from separate buildings on one site.'
\echo ''
\echo 'pct_of_real_by_host replaces pct_of_real_held in section 4 as the only'
\echo 'one of the two worth reading. If it is still far above 100 for a class,'
\echo 'then either the real_count is an organisation count against a facility'
\echo 'corpus, which is the fire-department case, or the class mapping is'
\echo 'still wrong and section 3 will show which category is to blame.'
\echo ''
\echo 'distinct_hosts_onprem is the honest size of what this project actually'
\echo 'has for each class: separate webservers, on their own premises, with a'
\echo 'known ZIP.'
\echo ''

DROP TABLE IF EXISTS tmp_recon;

\echo 'Done. Nothing was modified.'
\echo ''
