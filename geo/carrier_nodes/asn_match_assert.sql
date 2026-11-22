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

    SELECT brand_tract_pct INTO x FROM asn_brand_candidate_tbl
    WHERE asn = 99003 AND brand_name = 'Verizon';
    IF x IS NULL OR x <= 50 THEN
        failures := failures || format('AS99003 Verizon candidate has brand_tract_pct %s, expected above 50 so the parent-footprint flag fires', x);
    END IF;

    -- Frontier is the right answer but no string reaches it. If this ever
    -- starts matching, the note in the plan has to be rewritten.
    SELECT count(*) INTO n FROM asn_brand_candidate_tbl
    WHERE asn = 99003 AND brand_name = 'Frontier';
    IF n <> 0 THEN
        failures := failures || format('AS99003 reached the brand Frontier by name, which no string method can do. Expected 0, found %s.', n);
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
        failures := failures || 'AS99005 has ran_at NULL and must not appear in ipapi_asn_tbl';
    END IF;

    -- The footprint denominator is the whole fixture universe.
    SELECT brand_tract_pct INTO x FROM asn_brand_candidate_tbl
    WHERE asn = 99004 AND brand_name = 'Cable One';
    IF x IS DISTINCT FROM 13.1 THEN
        failures := failures || format('Cable One brand_tract_pct is %s, expected 13.1 (131 of 1000 tracts)', x);
    END IF;

    IF cardinality(failures) > 0 THEN
        RAISE EXCEPTION E'ASN MATCHER ASSERTIONS FAILED:\n%',
            array_to_string(failures, E'\n');
    END IF;
    RAISE NOTICE 'all ASN matcher assertions passed';
END
$assert$;

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
