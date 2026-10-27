-- onpremises_hosting_rule.sql - rule 2b. Hosting addresses are not landmarks.
--
-- THE RULE IS PER ADDRESS, NOT PER REGISTRANT. That distinction is the whole
-- point and it is what the data forced.
--
-- Southwest Cyberport and Synergy Networks each sell retail ISP service AND web
-- hosting under one registrant name. Excluding either company by name would
-- throw away its genuine on-premises customer places; admitting either by name
-- would let its hosting farm in. Neither name belongs in isp_names or in
-- provider_names, which is why both have sat in neither list.
--
-- Judging each ADDRESS by its own ZIP-cluster fan-out resolves this without
-- naming anyone. An address serving disjoint ZIP clusters is a hosting farm
-- whoever owns it; an address serving one contiguous area is a premises
-- whoever owns it. A registrant that does both gets each of its addresses
-- judged separately, which is exactly the requested behaviour.
--
-- It also closes the rule 3a hole, measured at 4,605 hosting addresses holding
-- 61,653 places, of which 4,427 addresses and 60,903 places were admitted for
-- no reason other than their registrant appearing in isp_names.
--
-- WHAT THIS CHANGES AND WHAT IT PRESERVES.
--   onpremises goes false ONLY where the address's own verdict is hosting.
--   onpremises_reason records that, so a hosting-rule false stays
--   distinguishable from a registrant-rule false. Nothing is deleted, and
--   re-running after address_hosting_tbl is rebuilt re-decides cleanly.
--
-- PREREQUISITE: address_hosting_tbl, built by node_fanout.sql. Note that
-- node_fanout.sql currently builds it from ovt_places_usa; rebuild it from
-- landmarks_usa once the other sources have been through the chain, or the
-- rule will only cover Overture addresses.

-- ---------------------------------------------------------------------------
-- 1. BEFORE. What the rule is about to act on.
-- ---------------------------------------------------------------------------

SELECT '=== 1. BEFORE: current onpremises distribution ===' AS section;

SELECT coalesce(onpremises::text, 'NULL') AS onpremises,
       count(*)                            AS places,
       count(DISTINCT host(ip_address))    AS addresses
FROM landmarks_usa
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- 2. THE MIXED REGISTRANTS, from the data rather than from a list of names.
--
-- Any registrant with BOTH hosting and on-premises addresses is a company that
-- does both. These are the cases a per-registrant rule would get wrong, in
-- either direction. Southwest Cyberport and Synergy Networks are the known
-- examples; this finds the rest.
-- ---------------------------------------------------------------------------

SELECT '=== 2. REGISTRANTS WITH BOTH hosting and on-premises addresses ===' AS section;

SELECT coalesce(h.registrant, '(none)')                              AS registrant,
       count(*) FILTER (WHERE h.verdict LIKE 'hosting%')             AS hosting_addrs,
       count(*) FILTER (WHERE h.verdict LIKE 'on-premises%')         AS onprem_addrs,
       sum(h.places) FILTER (WHERE h.verdict LIKE 'hosting%')        AS hosting_places,
       sum(h.places) FILTER (WHERE h.verdict LIKE 'on-premises%')    AS onprem_places_kept,
       max(h.zips_at_address)                                        AS max_zips
FROM address_hosting_tbl h
GROUP BY 1
HAVING count(*) FILTER (WHERE h.verdict LIKE 'hosting%') > 0
   AND count(*) FILTER (WHERE h.verdict LIKE 'on-premises%') > 0
ORDER BY 5 DESC
LIMIT 25;


SELECT '=== 2b. The two named cases, in detail ===' AS section;

SELECT coalesce(h.registrant, '(none)')  AS registrant,
       h.verdict,
       count(*)                          AS addresses,
       sum(h.places)                     AS places
FROM address_hosting_tbl h
WHERE lower(btrim(coalesce(h.registrant, ''))) LIKE '%southwest cyberport%'
   OR lower(btrim(coalesce(h.registrant, ''))) LIKE '%synergy networks%'
GROUP BY 1, 2
ORDER BY 1, 2;


-- ---------------------------------------------------------------------------
-- 3. APPLY. Hosting addresses only.
-- ---------------------------------------------------------------------------

SELECT '=== 3. APPLYING the rule ===' AS section;

WITH hosting AS (
    SELECT DISTINCT host(ip_address) AS addr, verdict
    FROM address_hosting_tbl
    WHERE verdict LIKE 'hosting%'
),
upd AS (
    UPDATE landmarks_usa l
    SET onpremises        = false,
        onpremises_reason = 'hosting: address serves disjoint ZIP clusters ('
                            || h.verdict || ')'
    FROM hosting h
    WHERE host(l.ip_address) = h.addr
      AND (l.onpremises IS DISTINCT FROM false
           OR l.onpremises_reason IS NULL
           OR l.onpremises_reason NOT LIKE 'hosting:%')
    RETURNING 1
)
SELECT count(*) AS places_set_false FROM upd;


-- ---------------------------------------------------------------------------
-- 4. AFTER, and the proof that the mixed registrants kept their premises.
-- ---------------------------------------------------------------------------

SELECT '=== 4. AFTER: onpremises distribution ===' AS section;

SELECT coalesce(onpremises::text, 'NULL') AS onpremises,
       count(*)                            AS places,
       count(DISTINCT host(ip_address))    AS addresses
FROM landmarks_usa
GROUP BY 1
ORDER BY 1;


SELECT '=== 4b. Why onpremises is false, by reason ===' AS section;

SELECT coalesce(onpremises_reason, '(not recorded)') AS reason,
       count(*)                                      AS places
FROM landmarks_usa
WHERE onpremises IS FALSE
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10;


SELECT '=== 4c. The named cases kept their on-premises places ===' AS section;

SELECT coalesce(l.registrant_1, '(none)')                           AS registrant,
       count(*) FILTER (WHERE l.onpremises IS TRUE)                 AS still_onpremises,
       count(*) FILTER (WHERE l.onpremises IS FALSE
                          AND l.onpremises_reason LIKE 'hosting:%') AS excluded_as_hosting,
       count(DISTINCT l.overture_zip) FILTER (WHERE l.onpremises IS TRUE)
                                                                    AS zips_still_served
FROM landmarks_usa l
WHERE lower(btrim(coalesce(l.registrant_1, ''))) LIKE '%southwest cyberport%'
   OR lower(btrim(coalesce(l.registrant_1, ''))) LIKE '%synergy networks%'
GROUP BY 1
ORDER BY 2 DESC;


SELECT '=== 4d. ZIP coverage that survives, the number that matters ===' AS section;

SELECT count(DISTINCT overture_zip)                                 AS zips_with_onprem_landmark,
       count(*)                                                     AS onpremises_places,
       count(DISTINCT host(ip_address))                             AS onpremises_addresses
FROM landmarks_usa
WHERE onpremises IS TRUE
  AND overture_zip ~ '^[0-9]{5}$';
