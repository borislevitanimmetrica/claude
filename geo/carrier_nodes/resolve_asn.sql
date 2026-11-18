-- geo/carrier_nodes/resolve_asn.sql
--
-- Fill asn_operator_tbl and asn_bdc_name_tbl for the ASNs named in
-- use_bdc_of_asn decisions. The tables themselves are declared in
-- geo/carrier_nodes/carrier_decisions.sql.
--
-- IN ITS OWN FILE because it must run BOTH from carrier_decisions.sql, which
-- declares the tables, AND again after load_decisions.py has put rulings in
-- carrier_decision_tbl. On the first pass there are no decisions, so these
-- come out empty and are refilled once the rulings land. One file rather
-- than two copies, because two copies drift.
--
-- TRUNCATE AND INSERT, NEVER DROP. carrier_resolved depends on
-- asn_bdc_name_tbl, and DROP TABLE ... CASCADE took the view with it, which
-- is how this file first failed. TRUNCATE touches no dependency.
--
-- PRE-MORTEM: both tables are derived entirely from
-- ip2city_dbiplite_probe_tbl, bdc_carrier_tbl and carrier_decision_tbl, so
-- emptying them loses nothing this file does not immediately regenerate.
--
-- WHY IT IS RESTRICTED. Unrestricted, the ASN-to-BDC join measured 195
-- SECONDS at Boris's row counts, because it compared every distinct ASN
-- against every BDC carrier calling carrier_name_norm inside LIKE patterns.
-- Only the ASNs under decision are needed, which on his rulings is THREE.

\set ON_ERROR_STOP on

TRUNCATE asn_bdc_name_tbl;
TRUNCATE asn_operator_tbl;

INSERT INTO asn_operator_tbl (asn, as_operator, ranges, as_operator_norm)
SELECT asn, as_operator, ranges, carrier_name_norm(as_operator)
FROM (
    SELECT nullif(regexp_replace("as", '^AS([0-9]+).*$', '\1'), "as")::integer
               AS asn,
           btrim(regexp_replace("as", '^AS[0-9]+\s*', '')) AS as_operator,
           count(*) AS ranges,
           row_number() OVER (
               PARTITION BY nullif(regexp_replace("as", '^AS([0-9]+).*$', '\1'),
                                   "as")::integer
               ORDER BY count(*) DESC) AS rn
    FROM ip2city_dbiplite_probe_tbl
    WHERE "as" IS NOT NULL AND "as" <> '' AND "as" ~ '^AS[0-9]+'
      AND nullif(regexp_replace("as", '^AS([0-9]+).*$', '\1'), "as")::integer
          IN (SELECT nullif(value, '')::integer
              FROM carrier_decision_tbl
              WHERE decision = 'use_bdc_of_asn'
                AND value ~ '^[0-9]+$')
    GROUP BY 1, 2
) z
WHERE rn = 1;

ANALYZE asn_operator_tbl;

INSERT INTO asn_bdc_name_tbl
       (asn, as_operator, ranges, bdc_provider_id, bdc_brand_name, match_basis)
WITH bdc AS (
    SELECT provider_id, brand_name,
           carrier_name_norm(brand_name) AS brand_norm
    FROM bdc_carrier_tbl
    WHERE brand_name IS NOT NULL AND brand_name <> ''
)
SELECT o.asn, o.as_operator, o.ranges,
       b.provider_id, b.brand_name,
       CASE WHEN b.brand_norm = o.as_operator_norm
                 THEN 'normalised name equal'
            WHEN b.provider_id IS NULL THEN NULL
            ELSE 'normalised name contained' END
FROM asn_operator_tbl o
LEFT JOIN bdc b
    ON b.brand_norm IS NOT NULL
   AND o.as_operator_norm IS NOT NULL
   AND (b.brand_norm = o.as_operator_norm
        OR b.brand_norm LIKE '%' || o.as_operator_norm || '%'
        OR o.as_operator_norm LIKE '%' || b.brand_norm || '%')
-- AN EXACT NORMALISED MATCH BEATS A SUBSTRING ONE. Without this, an
-- operator named 'Operator 7106' also matched 'Operator 7', 'Operator 71'
-- and 'Operator 710', because each is a substring of it, and one ASN
-- produced three different carrier labels. Containment is kept only where
-- no exact match exists for that ASN, which is the case it was added for.
WHERE b.provider_id IS NULL
   OR b.brand_norm = o.as_operator_norm
   OR NOT EXISTS (
        SELECT 1 FROM bdc e
        WHERE e.brand_norm = o.as_operator_norm);

ANALYZE asn_bdc_name_tbl;
