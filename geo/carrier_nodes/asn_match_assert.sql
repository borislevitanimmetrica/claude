-- ===========================================================================
-- asn_match_assert.sql
--
-- Checks the output of carrier_asn_match.sql against asn_match_fixture.sql.
-- Every check RAISES, so a failure stops the file instead of printing a line
-- that could be scrolled past.
--
-- Run after the fixture and the matcher, on the throwaway cluster only.
-- ===========================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- First prove the fixture DISCRIMINATES. This reproduces the old expression
-- on the same rows. If it returns the right answer the fixture is worthless
-- and the check below says so.
-- ---------------------------------------------------------------------------
\echo
\echo What the OLD build returned for AS99001, recomputed on the same rows:
\echo
WITH r AS (
    SELECT nullif(regexp_replace(p."as", '^AS([0-9]+).*$', '\1'), p."as")::bigint AS asn,
           btrim(regexp_replace(p."as", '^AS[0-9]+[[:space:]]*', '')) AS as_operator,
           p.isp, p.org, p."as" AS as_raw
    FROM ip2city_dbiplite_probe_tbl p
    WHERE p.ran_at IS NOT NULL AND p."as" IS NOT NULL AND p."as" <> ''
    GROUP BY 1, 2, 3, 4, 5
)
SELECT asn, mode() WITHIN GROUP (ORDER BY as_operator) AS old_as_operator
FROM r WHERE asn = 99001 GROUP BY asn;

DO $discriminates$
DECLARE old_name text; new_name text;
BEGIN
    SELECT mode() WITHIN GROUP (ORDER BY as_operator) INTO old_name
    FROM (SELECT btrim(regexp_replace(p."as", '^AS[0-9]+[[:space:]]*', '')) AS as_operator,
                 p.isp, p.org, p."as" AS as_raw
          FROM ip2city_dbiplite_probe_tbl p
          WHERE p.ran_at IS NOT NULL
            AND p."as" LIKE 'AS99001 %'
          GROUP BY 1, 2, 3, 4) r;

    SELECT as_operator INTO new_name FROM ipapi_asn_tbl WHERE asn = 99001;

    IF old_name IS NULL OR new_name IS NULL THEN
        RAISE EXCEPTION 'FIXTURE BROKEN: AS99001 missing. old=%, new=%', old_name, new_name;
    END IF;
    IF old_name = new_name THEN
        RAISE EXCEPTION 'FIXTURE DOES NOT DISCRIMINATE: the old expression also returns %. This fixture cannot prove defect 1 was fixed.', old_name;
    END IF;
    RAISE NOTICE 'fixture discriminates: old picked %, new picked %', old_name, new_name;
END
$discriminates$;

-- ---------------------------------------------------------------------------
-- The checks.
-- ---------------------------------------------------------------------------
DO $assert$
DECLARE
    failures text[] := ARRAY[]::text[];
    t   text;
    n   bigint;
    x   numeric;
BEGIN
    -- DEFECT 1. The commonest name is the one with the most ranges.
    SELECT as_operator INTO t FROM ipapi_asn_tbl WHERE asn = 99001;
    IF t IS DISTINCT FROM 'Zebra Telephone Company' THEN
        failures := failures || format('AS99001 as_operator is %L, expected Zebra Telephone Company (50 ranges beat 1)', t);
    END IF;

    SELECT as_operator_ranges INTO n FROM ipapi_asn_tbl WHERE asn = 99001;
    IF n IS DISTINCT FROM 50 THEN
        failures := failures || format('AS99001 as_operator_ranges is %s, expected 50', n);
    END IF;

    SELECT ranges INTO n FROM ipapi_asn_tbl WHERE asn = 99001;
    IF n IS DISTINCT FROM 51 THEN
        failures := failures || format('AS99001 ranges is %s, expected 51', n);
    END IF;

    -- and the candidate follows the corrected name, not the rare one.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99001 AND brand_name = 'Zebra Telephone Company' AND tier = 1;
    IF n <> 1 THEN
        failures := failures || format('AS99001 should have exactly one tier 1 candidate Zebra Telephone Company, found %s', n);
    END IF;

    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99001 AND brand_name = 'Aardvark Telephone Co';
    IF n <> 0 THEN
        failures := failures || format('AS99001 was offered Aardvark Telephone Co %s times. That is the old defect.', n);
    END IF;

    -- DEFECT 2. The upstream ISP name must not generate a candidate.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl WHERE asn = 99002;
    IF n <> 0 THEN
        failures := failures || format('AS99002 (enterprise, upstream Windstream) has %s candidates, expected 0', n);
    END IF;

    -- but the upstream name is still reported, because it is the evidence.
    SELECT isp_commonest INTO t FROM ipapi_asn_tbl WHERE asn = 99002;
    IF t IS DISTINCT FROM 'Windstream Communications' THEN
        failures := failures || format('AS99002 isp_commonest is %L, expected Windstream Communications to remain visible', t);
    END IF;

    -- DEFECT 3. The parent name match is OFFERED and FLAGGED, not dropped.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99003 AND brand_name = 'Verizon';
    IF n <> 1 THEN
        failures := failures || format('AS99003 should still be offered the brand Verizon once for Boris to rule on, found %s', n);
    END IF;

    -- The footprint-size flag that used to be asserted here is GONE. Boris
    -- 2026-11-22: on his data it produced 40 rows, all AT&T and Verizon
    -- matching their own correct brands, and the one row that mattered was
    -- indistinguishable among them. Size is not the signal. The signal is
    -- the two names disagreeing, asserted further down.

    -- Frontier is the right answer and the OPERATOR name cannot reach it.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99003 AND brand_name = 'Frontier';
    IF n <> 0 THEN
        failures := failures || format('AS99003 reached the brand Frontier from the operator name, which no string method can do. Expected 0, found %s.', n);
    END IF;

    -- But the ip-api ISP name DOES reach it, and that is the instrument
    -- that replaced the footprint-size flag. One row, naming Frontier.
    SELECT count(*) INTO n FROM asn_isp_disagree_tbl WHERE asn = 99003;
    IF n <> 1 THEN
        failures := failures || format('AS99003 should produce exactly one parent-on-subsidiary row, found %s', n);
    END IF;

    SELECT isp_suggests_brand INTO t FROM asn_isp_disagree_tbl WHERE asn = 99003;
    IF t IS DISTINCT FROM 'Frontier' THEN
        failures := failures || format('AS99003 parent-on-subsidiary row suggests %L, expected Frontier', t);
    END IF;

    -- The brands that agree on both names must NOT appear there, or the
    -- instrument is as useless as the footprint flag it replaced.
    SELECT count(*) INTO n FROM asn_isp_disagree_tbl WHERE asn IN (99001, 99004);
    IF n <> 0 THEN
        failures := failures || format('AS99001 and AS99004 agree on both names and must not be flagged as parent-on-subsidiary. Found %s rows.', n);
    END IF;

    -- The Frontier case is ownership, so it must NOT be marked transit.
    SELECT count(*) INTO n FROM asn_isp_disagree_tbl
    WHERE asn = 99003 AND isp_is_a_larger_asn_upstream;
    IF n <> 0 THEN
        failures := failures || 'AS99003 was marked transit. No ASN carries Frontier as its operator name, which is exactly why it needed finding.'::text;
    END IF;

    -- And the transit case MUST be marked, or the Cogent rows return.
    SELECT count(*) INTO n FROM asn_isp_disagree_tbl WHERE asn = 99008;
    IF n <> 1 THEN
        failures := failures || format('AS99008 should produce one disagreement row, found %s. Without it the transit flag is untested.', n);
    END IF;

    SELECT count(*) INTO n FROM asn_isp_disagree_tbl
    WHERE asn = 99008 AND isp_is_a_larger_asn_upstream;
    IF n <> 1 THEN
        failures := failures || format('AS99008 has an ISP name that is the operator name of a larger ASN and must be marked transit. Found %s.', n);
    END IF;

    -- The footprint share is now per technology over wireline only.
    -- 300 FTTP tracts over the 681 tracts that have ANY wireline plant in
    -- the fixture. The denominator excludes wireless-only tracts because
    -- Boris ruled wireless out of scope on 2026-11-22; against the old
    -- all-technology denominator of 1000 the same brand read 30.0.
    SELECT brand_tract_pct INTO x FROM asn_brand_candidate_tbl
    WHERE asn = 99003 AND brand_name = 'Verizon';
    IF x IS DISTINCT FROM 44.1 THEN
        failures := failures || format('Verizon brand_tract_pct is %s, expected 44.1, being 300 FTTP tracts over 681 wireline-served tracts. Pooled with its wireless rows it would be 100.0, which is the defect.', x);
    END IF;

    SELECT widest_technology INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99003 AND brand_name = 'Verizon';
    IF n IS DISTINCT FROM 50 THEN
        failures := failures || format('Verizon widest wireline technology is %s, expected 50', n);
    END IF;

    -- A WIRELESS-ONLY BRAND IS NOT OFFERED AT ALL. Boris 2026-11-22:
    -- wireless is out of scope for the ITDK-BDC subsystem. The name match is
    -- perfect and still useless, so it must not reach the approval queue.
    -- An earlier version of this file asserted the opposite, that the
    -- candidate appears with wireline_technologies = 0, which put forty
    -- unusable rows in front of him.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl WHERE asn = 99006;
    IF n <> 0 THEN
        failures := failures || format('AS99006 Skyhook matches a wireless-only brand exactly and must get 0 candidates. Found %s.', n);
    END IF;

    IF carrier_name_tier('Skyhook Wireless Co', 'Skyhook Wireless Co') <> 1 THEN
        failures := failures || 'the Skyhook names no longer agree, so this case stopped testing the wireless exclusion and started testing the name rule'::text;
    END IF;

    -- Every candidate that IS offered must have wireline plant.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE coalesce(wireline_technologies, 0) = 0;
    IF n <> 0 THEN
        failures := failures || format('%s candidates have no wireline footprint and cannot be used', n);
    END IF;

    -- And no wireless-only brand may become an entity proposal either.
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_name = 'carrier_entity_proposal_tbl') THEN
        SELECT count(*) INTO n FROM carrier_entity_proposal_tbl p
        WHERE NOT EXISTS (SELECT 1 FROM provider_brand_tract_tech_tbl f
                          WHERE f.provider_id = p.provider_id
                            AND f.brand_name = p.brand_name
                            AND f.technology IN (10, 40, 50));
        IF n <> 0 THEN
            failures := failures || format('%s entity proposals point at a brand with no wireline plant', n);
        END IF;
    END IF;

    -- CONTROL. Legal suffix only, so CABLE ONE, INC. still lands.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99004 AND brand_name = 'Cable One' AND tier = 1;
    IF n <> 1 THEN
        failures := failures || format('AS99004 CABLE ONE, INC. lost its tier 1 match to Cable One. Found %s.', n);
    END IF;

    -- ZIP-capable and DMA-only stay apart.
    SELECT zip_capable_ranges INTO n FROM ipapi_asn_tbl WHERE asn = 99004;
    IF n IS DISTINCT FROM 70 THEN
        failures := failures || format('AS99004 zip_capable_ranges is %s, expected 70', n);
    END IF;
    SELECT dma_only_ranges INTO n FROM ipapi_asn_tbl WHERE asn = 99004;
    IF n IS DISTINCT FROM 30 THEN
        failures := failures || format('AS99004 dma_only_ranges is %s, expected 30', n);
    END IF;

    -- Unprobed rows never enter.
    SELECT count(*) INTO n FROM ipapi_asn_tbl WHERE asn = 99005;
    IF n <> 0 THEN
        failures := failures || 'AS99005 has ran_at NULL and must not appear in ipapi_asn_tbl'::text;
    END IF;

    -- The footprint denominator is the whole fixture universe.
    SELECT brand_tract_pct INTO x FROM asn_brand_candidate_tbl
    WHERE asn = 99004 AND brand_name = 'Cable One';
    IF x IS DISTINCT FROM 19.2 THEN
        failures := failures || format('Cable One brand_tract_pct is %s, expected 19.2, being 131 cable tracts over 681 wireline-served tracts', x);
    END IF;

    -- And the pooled calculation, which is what shipped, would have called
    -- the Verizon brand national. Proven here so the fix is not merely
    -- asserted.
    SELECT round(100.0 * count(DISTINCT tract_geoid)
                 / (SELECT count(DISTINCT tract_geoid)
                    FROM provider_brand_tract_tech_tbl), 1) INTO x
    FROM provider_brand_tract_tech_tbl
    WHERE provider_id = 900001 AND brand_name = 'Verizon';
    IF x <= 50 THEN
        failures := failures || format('FIXTURE DOES NOT DISCRIMINATE: the pooled share for Verizon is %s, so it would not have tripped the old 50%% flag and this fixture cannot show the difference.', x);
    END IF;
    RAISE NOTICE 'pooled share for the Verizon brand is %, per-technology wireline share is %',
        x, (SELECT brand_tract_pct FROM asn_brand_candidate_tbl
            WHERE asn = 99003 AND brand_name = 'Verizon');

    IF cardinality(failures) > 0 THEN
        RAISE EXCEPTION E'ASN MATCHER ASSERTIONS FAILED:\n%',
            array_to_string(failures, E'\n');
    END IF;
    RAISE NOTICE 'all ASN matcher assertions passed';
END
$assert$;

-- ---------------------------------------------------------------------------
-- The entity layer, if carrier_entity.sql has been run. Run order for the
-- full check is fixture, matcher, carrier_entity.sql, then this file.
-- ---------------------------------------------------------------------------
DO $entity$
DECLARE failures text[] := ARRAY[]::text[]; n bigint; t text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'carrier_entity_proposal_tbl') THEN
        RAISE NOTICE 'carrier_entity.sql has not been run; entity assertions skipped';
        RETURN;
    END IF;

    -- No string rule may reach Xfinity from the Comcast operator name.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl WHERE asn = 99007;
    IF n <> 0 THEN
        failures := failures || format('AS99007 Comcast should get 0 string candidates, found %s. If this ever passes, the trade-name problem was never real.', n);
    END IF;

    IF carrier_name_tier('Comcast Cable Communications, LLC', 'Xfinity') <> 0 THEN
        failures := failures || 'carrier_name_tier joined Comcast to Xfinity, which no string method can legitimately do'::text;
    END IF;

    -- The entity layer must reach it.
    SELECT count(*) INTO n FROM carrier_entity_proposal_tbl
    WHERE asn = 99007 AND brand_name = 'Xfinity';
    IF n <> 1 THEN
        failures := failures || format('the entity layer should propose AS99007 to Xfinity exactly once, found %s', n);
    END IF;

    SELECT entity_key INTO t FROM carrier_entity_proposal_tbl WHERE asn = 99007;
    IF t IS DISTINCT FROM 'comcast' THEN
        failures := failures || format('AS99007 resolved to entity %L, expected comcast', t);
    END IF;

    -- THE UNRELATED LIST MUST NOT CONTAIN COMCAST AND XFINITY. The gate
    -- rejects that pair to prove no string method joins them, which is why
    -- the entity layer exists. Seeding the unrelated list from every reject
    -- case put it there and silently deleted the Comcast match. This
    -- assertion is the only reason that was caught.
    SELECT count(*) INTO n FROM carrier_unrelated_tbl
    WHERE ipapi_key = carrier_name_compact('Comcast Cable Communications, LLC')
      AND bdc_key   = carrier_name_compact('Xfinity');
    IF n <> 0 THEN
        failures := failures || 'Comcast and Xfinity are on the unrelated list. They are the same company; the gate rejects the pair only to prove the string rule cannot join them.'::text;
    END IF;

    SELECT count(*) INTO n FROM carrier_unrelated_tbl
    WHERE ipapi_key = carrier_name_compact('Windstream Communications LLC')
      AND bdc_key   = carrier_name_compact('Georgia Windstream, LLC.');
    IF n <> 0 THEN
        failures := failures || 'Georgia Windstream is on the unrelated list. It is a subsidiary; the gate case exists to stop it being reached by one shared word.'::text;
    END IF;

    -- A pair he DID rule unrelated must be there and must not be matched.
    SELECT count(*) INTO n FROM carrier_unrelated_tbl
    WHERE ipapi_key = carrier_name_compact('Database Mart LLC')
      AND bdc_key   = carrier_name_compact('Wal-Mart Stores, Inc.');
    IF n <> 1 THEN
        failures := failures || format('the Database Mart to Wal-Mart ruling is not on the unrelated list, found %s rows', n);
    END IF;

    IF NOT carrier_pair_is_unrelated('Database Mart LLC', 'Wal-Mart Stores, Inc.') THEN
        failures := failures || 'carrier_pair_is_unrelated does not recognise a pair that is in the table'::text;
    END IF;

    -- A DIA CUSTOMER MUST NOT INHERIT ITS UPSTREAM CARRIER'S PLANT.
    -- AS99009 is an enterprise whose ip-api ISP is Comcast. The entity ISP
    -- arm would reach the comcast entity through that name; the carrier
    -- universe is what stops it, because the holder of the ASN is in no
    -- carrier list. This is the 1-800-Flowers case.
    IF carrier_name_in_universe('Flowers Direct Retail, Inc.') THEN
        failures := failures || 'the fixture DIA customer is in the carrier universe, so this case cannot test the guard'::text;
    END IF;

    SELECT count(*) INTO n FROM carrier_entity_proposal_tbl WHERE asn = 99009;
    IF n <> 0 THEN
        failures := failures || format('AS99009 is a DIA customer of Comcast and got %s entity proposals. It must get none; its ISP name is its upstream carrier.', n);
    END IF;

    SELECT count(*) INTO n FROM asn_brand_candidate_tbl WHERE asn = 99009;
    IF n <> 0 THEN
        failures := failures || format('AS99009 got %s string candidates despite being outside the carrier universe', n);
    END IF;

    -- and the carrier whose name IS in the universe still gets through.
    IF NOT carrier_name_in_universe('Comcast Cable Communications, LLC')
       AND NOT carrier_name_in_universe('Xfinity') THEN
        failures := failures || 'neither Comcast name is in the universe, so the restriction has cut out a real carrier'::text;
    END IF;

    -- Verizon and Frontier must stay SEPARATE entities, or a Frontier ASN
    -- gains the right to select Verizon plant.
    SELECT count(*) INTO n FROM carrier_entity_name_tbl
    WHERE entity_key = 'verizon' AND side = 'bdc' AND name = 'Frontier';
    IF n <> 0 THEN
        failures := failures || 'the brand Frontier is attached to the verizon entity. They are one owner and two networks in complementary territory; merging them is the error Boris refuted.'::text;
    END IF;

    -- And the conflict between the entity proposal and the ISP evidence
    -- must be detected rather than silently resolved.
    SELECT count(*) INTO n
    FROM carrier_entity_proposal_tbl p
    JOIN asn_isp_disagree_tbl d ON d.asn = p.asn
    WHERE d.isp_suggests_brand IS DISTINCT FROM p.brand_name AND p.asn = 99003;
    IF n <> 1 THEN
        failures := failures || format('the Verizon-against-Frontier conflict on AS99003 should be reported once, found %s', n);
    END IF;

    IF cardinality(failures) > 0 THEN
        RAISE EXCEPTION E'ENTITY LAYER ASSERTIONS FAILED:\n%', array_to_string(failures, E'\n');
    END IF;
    RAISE NOTICE 'all entity layer assertions passed';
END
$entity$;

\echo
\echo Every ASN, as the matcher now sees it.
\echo
SELECT asn, as_operator, as_operator_pct, isp_commonest, isp_commonest_pct,
       ranges, zip_capable_ranges, dma_only_ranges
FROM ipapi_asn_tbl ORDER BY asn;

\echo
\echo Every candidate, with the footprint flag.
\echo
SELECT asn, as_operator, provider_id, brand_name, tier, tier_isp_agrees,
       brand_tracts, brand_tract_pct, zip_capable_ranges
FROM asn_brand_candidate_tbl ORDER BY asn, rank_for_asn;
