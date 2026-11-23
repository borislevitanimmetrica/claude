-- ===========================================================================
-- asn_out_of_scope.sql
--
-- Records Boris's rulings that a named organisation is not a public carrier
-- whose headend has to be inferred, so every ASN it holds leaves the
-- ITDK-BDC crosswalk permanently.
--
-- Boris 2026-11-22: "Amazon.com, Inc. is not a public carrier and should not
-- be tracked. Its private network, currently by Windstream, is localized by
-- ip-api.com to each facility, so is out of scope." The same reasoning covers
-- the other organisations below: ip-api reports them at their own premises,
-- so there is nothing to infer.
--
-- Two kinds of ruling are held here and they are kept apart:
--   not_a_carrier  an enterprise, host or cloud. Located at its own sites.
--   out_of_scope   a real network that serves ONLY institutions, so ip-api
--                  localises it to the institution: OARnet, Merit, CENIC.
--
-- WHY THIS FILE MATCHES ON NAMES AND NOT ON ASN NUMBERS
-- Boris ruled on company names. I do not have a verified name-to-ASN table,
-- and inventing ASN numbers would be guessing. So the names are matched to
-- ipapi_asn_tbl.as_operator by the compact key, which is full-string equality
-- after legal suffixes are dropped. It is not token containment and will not
-- sweep up a neighbour. Every ASN about to be written is printed first, with
-- the address space behind it, and a name that matches nothing is reported
-- rather than passed over in silence.
--
-- Run AFTER carrier_asn_match.sql, which builds ipapi_asn_tbl and creates
-- asn_bdc_brand_map_tbl. This file only INSERTs into the decision map and
-- never deletes from it.
--
-- psql -f /home/boris/geo/src/claude/geo/carrier_nodes/asn_out_of_scope.sql
-- ===========================================================================

\set ON_ERROR_STOP on
\timing on

DO $precheck$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'ipapi_asn_tbl') THEN
        RAISE EXCEPTION 'ipapi_asn_tbl does not exist. Run carrier_asn_match.sql first. Nothing was written.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'asn_bdc_brand_map_tbl') THEN
        RAISE EXCEPTION 'asn_bdc_brand_map_tbl does not exist. Run carrier_asn_match.sql first. Nothing was written.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'carrier_name_compact') THEN
        RAISE EXCEPTION 'carrier_name_compact() is not defined. Run carrier_asn_match.sql first. Nothing was written.';
    END IF;
    RAISE NOTICE 'precheck passed';
END
$precheck$;

-- ---------------------------------------------------------------------------
-- The rulings.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS asn_scope_ruling_tbl;
CREATE TABLE asn_scope_ruling_tbl (
    ruled_name text PRIMARY KEY,
    decision   text NOT NULL CHECK (decision IN ('not_a_carrier', 'out_of_scope')),
    note       text NOT NULL);

INSERT INTO asn_scope_ruling_tbl VALUES
 ('Amazon.com, Inc.', 'not_a_carrier',
  'Boris 2026-11-22: not a public carrier. Private network, currently carried by Windstream, localised by ip-api to each facility.'),
 ('Apple Inc.',            'not_a_carrier', 'Boris: enterprise, located at its own premises.'),
 ('Microsoft Corporation', 'not_a_carrier', 'Boris: enterprise, located at its own premises.'),
 ('Akamai Technologies, Inc.', 'not_a_carrier', 'Boris: CDN, located at its own premises.'),
 ('Eli Lilly and Company', 'not_a_carrier', 'Boris: enterprise.'),
 ('3M Company',            'not_a_carrier', 'Boris: enterprise.'),
 ('Walmart Inc.',          'not_a_carrier', 'Boris: enterprise.'),
 ('National Aeronautics and Space Administration', 'not_a_carrier', 'Boris: government body.'),
 ('Massachusetts Institute of Technology', 'not_a_carrier', 'Boris: university.'),
 ('UBS AG',                'not_a_carrier', 'Boris: enterprise.'),
 ('Bloomberg LP',          'not_a_carrier', 'Boris: enterprise.'),
 ('FedEx Corporation',     'not_a_carrier', 'Boris: enterprise.'),
 ('Hewlett Packard Enterprise Company', 'not_a_carrier', 'Boris: enterprise.'),
 ('DXC Technology',        'not_a_carrier', 'Boris: enterprise.'),
 ('Oracle Corporation',    'not_a_carrier', 'Boris: cloud, located at its own premises.'),
 ('Alibaba Cloud',         'not_a_carrier', 'Boris: cloud.'),
 ('DigitalOcean, LLC',     'not_a_carrier', 'Boris: host.'),
 ('OVH SAS',               'not_a_carrier', 'Boris: host.'),
 ('Rackspace Hosting',     'not_a_carrier', 'Boris: host.'),
 ('GoDaddy.com, LLC',      'not_a_carrier', 'Boris: host.'),
 ('Liquid Web, L.L.C',     'not_a_carrier', 'Boris: host.'),
 ('HostPapa',              'not_a_carrier', 'Boris: host.'),
 ('Hostinger International Limited', 'not_a_carrier', 'Boris: host.'),
 ('Eonix Corporation',     'not_a_carrier', 'Boris: host.'),
 ('HIVELOCITY, Inc.',      'not_a_carrier', 'Boris: host.'),
 ('DataPipe, Inc.',        'not_a_carrier', 'Boris: host.'),
 ('Internap Corporation',  'not_a_carrier', 'Boris: host.'),
 ('SoftLayer Technologies Inc.', 'not_a_carrier', 'Boris: host, now IBM Cloud.'),
 ('IBM Cloud',             'not_a_carrier', 'Boris: host.'),
 ('The Constant Company, LLC', 'not_a_carrier', 'Boris: host.'),
 -- Real networks, but every customer is an institution that ip-api already
 -- places at its own campus. Boris 2026-11-22.
 ('OARnet',                'out_of_scope', 'Boris 2026-11-22: serves institutional customers exclusively; ip-api localises to the institution.'),
 ('Merit Network Inc.',     'out_of_scope', 'Boris 2026-11-22: institutional customers only.'),
 ('CENIC',                  'out_of_scope', 'Boris 2026-11-22: institutional customers only.'),
 ('MCNC',                   'out_of_scope', 'Boris 2026-11-22: institutional customers only.'),
 ('Washington State K-20 Telecommunications Network', 'out_of_scope', 'Boris 2026-11-22: institutional customers only.'),
 ('University of California San Diego', 'out_of_scope', 'Boris 2026-11-22: institution.'),
 ('Rice University',        'out_of_scope', 'Boris 2026-11-22: institution.'),
 ('State of Wisconsin',     'out_of_scope', 'Boris 2026-11-22: institutional customers only.'),
 ('U.S. Department of the Interior', 'out_of_scope', 'Boris 2026-11-22: government body.'),
 -- Alternate spellings of companies ALREADY ruled on above, surfaced by the
 -- near-miss report on Boris's 2026-11-22 run. These add no new judgement:
 -- each is the same company as a ruling and is listed so that the ruling
 -- reaches the ASN it actually holds. Six of the rulings above reached no
 -- ASN at all because ip-api spells the operator differently.
 ('Akamai International B.V.',  'not_a_carrier', 'Same company as the Akamai ruling. Spelling used by ip-api, 14,537 ZIP-capable ranges.'),
 ('Akamai Connected Cloud',     'not_a_carrier', 'Same company as the Akamai ruling.'),
 ('Alibaba (US) Technology Co., Ltd.', 'not_a_carrier', 'Same company as the Alibaba ruling.'),
 ('Amazon Technologies Inc.',   'not_a_carrier', 'Same company as the Amazon ruling.'),
 ('Amazon Data Services',       'not_a_carrier', 'Same company as the Amazon ruling.'),
 ('FedEx Internet Technologies Corporation', 'not_a_carrier', 'Same company as the FedEx ruling.'),
 ('Internap Holding LLC',       'not_a_carrier', 'Same company as the Internap ruling.'),
 ('DXC US Latin America Corporation', 'not_a_carrier', 'Same company as the DXC ruling.'),
 ('Wal-Mart Stores, Inc.',      'not_a_carrier', 'Same company as the Walmart ruling.'),
 ('HEWLETT PACKARD ENTERPRISE COMPANY', 'not_a_carrier', 'Same company as the Hewlett Packard ruling.'),
 ('Bloomberg, LP',              'not_a_carrier', 'Same company as the Bloomberg ruling.'),
 ('SoftLayer',                  'not_a_carrier', 'Same company as the SoftLayer ruling.'),
 ('State of WI Dept. of Administration', 'out_of_scope', 'The spelling Boris used was State of WI. 1,448 ZIP-capable ranges.');

\echo
\echo ================================================================
\echo The ASNs these rulings reach. Nothing is written until you have
\echo seen this list. Matching is full-string after legal suffixes are
\echo dropped, so no neighbouring name can be swept in.
\echo ================================================================
\echo
DROP TABLE IF EXISTS asn_scope_hit_tbl;
CREATE TABLE asn_scope_hit_tbl AS
SELECT a.asn, a.as_operator, r.ruled_name, r.decision, r.note,
       a.zip_capable_ranges, a.dma_only_ranges, a.unclassified_ranges
FROM ipapi_asn_tbl a
JOIN asn_scope_ruling_tbl r
  ON carrier_name_compact(r.ruled_name) = carrier_name_compact(a.as_operator)
WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn);

SELECT h.asn, left(h.as_operator, 44) AS as_operator, h.decision,
       h.zip_capable_ranges, h.dma_only_ranges
FROM asn_scope_hit_tbl h
ORDER BY h.zip_capable_ranges DESC NULLS LAST, h.asn;

\echo
\echo Rulings that reached NO ASN. Either the operator name in ip-api is
\echo spelled differently or that network has not been probed yet. These
\echo are not written, and this file can be re-run after more probing.
\echo
SELECT r.ruled_name, r.decision
FROM asn_scope_ruling_tbl r
WHERE NOT EXISTS (SELECT 1 FROM asn_scope_hit_tbl h WHERE h.ruled_name = r.ruled_name)
ORDER BY r.ruled_name;

-- ---------------------------------------------------------------------------
-- NEAR MISSES, filtered by how RARE the shared word is.
--
-- The first version matched on the first informative word and produced 40
-- rows on Boris's 2026-11-22 run of which about 30 were noise: "University
-- of Missouri" beside "University of California San Diego", and nine states
-- beside "State of Wisconsin", because university and state are not in the
-- stoplist and never could be without breaking real carrier names.
--
-- The fix is not a bigger stoplist, it is document frequency. A word shared
-- by hundreds of probed operator names carries no information; a word shared
-- by two or three identifies a company. akamai appears in a handful of names
-- and university in hundreds, and the corpus says so without my having to
-- decide which words are generic. The cutoff is printed with the results.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS asn_token_freq_tbl;
CREATE TABLE asn_token_freq_tbl AS
SELECT w.tok, count(DISTINCT a.as_operator) AS names_carrying_it
FROM ipapi_asn_tbl a, unnest(carrier_name_tokens_strict(a.as_operator)) AS w(tok)
WHERE length(w.tok) >= 2
GROUP BY w.tok;

CREATE INDEX asn_token_freq_ix ON asn_token_freq_tbl (tok);
ANALYZE asn_token_freq_tbl;

\echo
\echo How common the shared words are. A word in the top band is useless for
\echo identifying a company, which is why the near-miss report below ignores
\echo any word carried by more than 12 distinct operator names.
\echo
SELECT tok, names_carrying_it
FROM asn_token_freq_tbl ORDER BY names_carrying_it DESC LIMIT 12;

\echo
\echo Near misses: probed operator names sharing a RARE word with a ruling
\echo but not matching it. Check whether any is the same company under
\echo another spelling, then add that spelling to the rulings above.
\echo
SELECT DISTINCT left(a.as_operator, 44) AS probed_name,
       r.ruled_name, x.tok AS shared_word, f.names_carrying_it,
       a.zip_capable_ranges
FROM ipapi_asn_tbl a
CROSS JOIN asn_scope_ruling_tbl r
JOIN LATERAL (
    SELECT t.tok FROM unnest(carrier_name_tokens_strict(a.as_operator)) AS t(tok)
    INTERSECT
    SELECT t.tok FROM unnest(carrier_name_tokens_strict(r.ruled_name)) AS t(tok)
) x ON true
JOIN asn_token_freq_tbl f ON f.tok = x.tok
WHERE f.names_carrying_it <= 12
  AND carrier_name_compact(r.ruled_name) <> carrier_name_compact(a.as_operator)
  AND NOT carrier_name_generic_only(a.as_operator)
  AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn)
ORDER BY a.zip_capable_ranges DESC NULLS LAST
LIMIT 40;

-- ---------------------------------------------------------------------------
-- Write them.
-- ---------------------------------------------------------------------------
INSERT INTO asn_bdc_brand_map_tbl (asn, decision, bdc_brand_name, bdc_provider_id, note)
SELECT h.asn, h.decision, NULL, NULL,
       h.note || ' Ruled name: ' || h.ruled_name || '. ip-api operator name: ' || h.as_operator
FROM asn_scope_hit_tbl h
ON CONFLICT (asn) DO NOTHING;

\echo
\echo The decision map after writing.
\echo
SELECT count(*)                                             AS decisions_held,
       count(*) FILTER (WHERE decision = 'brand')           AS to_a_brand,
       count(*) FILTER (WHERE decision = 'not_a_carrier')   AS not_a_carrier,
       count(*) FILTER (WHERE decision = 'out_of_scope')    AS out_of_scope
FROM asn_bdc_brand_map_tbl;

\echo
\echo Address space these rulings remove from the matching problem.
\echo
SELECT sum(a.zip_capable_ranges) AS zip_capable_ranges_retired,
       sum(a.dma_only_ranges)    AS dma_only_ranges_retired,
       count(*)                  AS asns_retired
FROM ipapi_asn_tbl a
JOIN asn_bdc_brand_map_tbl m ON m.asn = a.asn
WHERE m.decision IN ('not_a_carrier', 'out_of_scope');

-- ---------------------------------------------------------------------------
-- Refresh the two review files. carrier_asn_match.sql writes them BEFORE
-- these rulings exist, and rebuilding ipapi_asn_tbl costs over an hour, so
-- the retired ASNs are dropped from the candidate table and both files are
-- written again here. Only rows now decided are removed; nothing else moves.
-- ---------------------------------------------------------------------------
DO $refresh$
DECLARE removed bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'asn_brand_candidate_tbl') THEN
        RAISE EXCEPTION 'asn_brand_candidate_tbl does not exist, so the review files cannot be refreshed. The rulings above ARE written and will take effect on the next run of carrier_asn_match.sql.';
    END IF;
    DELETE FROM asn_brand_candidate_tbl c
    WHERE EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m
                  WHERE m.asn = c.asn
                    AND m.decision IN ('not_a_carrier', 'out_of_scope'));
    GET DIAGNOSTICS removed = ROW_COUNT;
    RAISE NOTICE 'removed % candidate rows belonging to retired ASNs', removed;
END
$refresh$;

ANALYZE asn_brand_candidate_tbl;

\echo
\echo Rewriting the two review files so they reflect the rulings above.
\echo
\copy (SELECT c.asn, c.as_operator, c.as_operator_pct, c.isp_commonest, c.isp_commonest_pct, c.provider_id, c.brand_name, c.tier, c.tier_isp_agrees, c.brand_tracts, c.brand_tract_pct, c.rank_for_asn, c.zip_capable_ranges, c.dma_only_ranges, NULL::text AS approved FROM asn_brand_candidate_tbl c ORDER BY c.zip_capable_ranges DESC NULLS LAST, c.asn, c.rank_for_asn) TO '/home/boris/geo/asn_brand_candidates.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\copy (SELECT a.asn, a.as_operator, a.as_operator_pct, a.isp_commonest, a.isp_commonest_pct, a.org_commonest, a.isp_variants, a.zip_capable_ranges, a.dma_only_ranges, a.unclassified_ranges, NULL::text AS bdc_brand_or_out_of_scope FROM ipapi_asn_tbl a WHERE NOT EXISTS (SELECT 1 FROM asn_brand_candidate_tbl c WHERE c.asn = a.asn) AND NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn) ORDER BY a.zip_capable_ranges DESC NULLS LAST) TO '/home/boris/geo/asn_unmatched.tsv' WITH (FORMAT csv, DELIMITER E'\t', HEADER true)

\echo
\echo What is left to rule on, after the rulings above.
\echo
SELECT count(*) AS asns_still_undecided,
       sum(a.zip_capable_ranges) AS zip_capable_ranges_still_undecided
FROM ipapi_asn_tbl a
WHERE NOT EXISTS (SELECT 1 FROM asn_bdc_brand_map_tbl m WHERE m.asn = a.asn);

\timing off
