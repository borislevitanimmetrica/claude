-- landmark_carrier_node.sql
--
-- Turn measured last-carrier-node data into ZIP codes for IP ranges.
--
-- THE METHOD
--
-- A landmark has a postal address and a static IP. Retail subscribers near it
-- have no postal address we can see and dynamic IPs. What they share is the
-- access network: the landmark's traffic and the subscribers' traffic pass
-- through the same carrier equipment close to the premises. So:
--
--   1. mtr each on-premises landmark address, and keep the last carrier node
--      before the customer equipment.          -> ovt_places_usa_ip_trace
--   2. mtr an address in each candidate range, and keep the same thing.
--      -> ip2city_dbiplite_traceroute_tbl, which geo/main.go already does
--   3. Where a range's node is the SAME node as a landmark's, give the range
--      the landmark's Overture ZIP.            -> range2zip_carrier_node_tbl
--
-- Step 3 is only sound if a node is specific to a small area. A node serving
-- one ZIP transfers that ZIP unambiguously; a node serving forty transfers
-- nothing. Section 4 MEASURES that distribution instead of assuming it, and
-- section 5 will not assign a ZIP through a node that exceeds the measured
-- bound. Nothing here guesses a threshold.
--
-- ON DERIVING THIS FROM BGP INSTEAD, WHICH DOES NOT WORK
--
-- Taking "the db-ip | BGP RouteViews table" to mean ip2city_dbiplite_tbl, which
-- carries source = 'dbip' and source = 'routeviews' rows, step 2 above is
-- exactly that table and geo/main.go already traces it. That is the reading
-- this file implements.
--
-- If instead the intent was to read a carrier node out of BGP attributes, it
-- cannot be done, for two separate reasons:
--
--   The data is not there. bgp_route_views.as_path exists as a column but is
--   NULL for every row in production, because the ingester is run without
--   -per-peer and buildRows writes NULL for peer_ip and as_path in deduped
--   mode. Only origin_asn is populated. Recovering paths means re-ingesting
--   with -mode full -per-peer, which multiplies the table by the peer count.
--
--   Even with paths it would be the wrong granularity, and this is the real
--   objection. The second-to-last ASN in a path is the origin's transit
--   provider: a whole company. AS7018 is AT&T across fifty states. "Landmark
--   and subscriber share an upstream AS" is true for millions of addresses and
--   says nothing about a ZIP. The geography in the mtr result is in the node's
--   reverse DNS, where lightspeed.btrgla.sbcglobal.net names a metro. BGP has
--   no equivalent. An AS-level match is a necessary precondition, not evidence,
--   so section 6 reports it as an attribute and never as a reason to assign.
--
-- Prerequisites: geo/overture_fetch/create_table_ovt_places_usa_ip_trace.sql,
-- geo/traceroute_hostname_rules.sql, and a populated ip2city_dbiplite_tbl.
--
-- Contains NO backslashes so it survives copy/paste.


-- ---------------------------------------------------------------------------
-- 0. DESTINATION TABLE.
--
-- Deliberately NOT range2zip_tbl. That table is the landmark-containment
-- method's output, with source defaulting to 'landmark' and city and state_code
-- NOT NULL. Carrier-node assignments have different provenance, a different
-- confidence, and audit fields of their own that would have nowhere to live
-- there, and borrowing a city and state from the db-ip row just to satisfy a
-- NOT NULL would launder one method's data as another's. Kept separate and
-- merged deliberately; the merge is section 8, written out and commented.
--
-- No DROP: section 5 is cheap to re-run, but it depends on a trace table that
-- costs tens of hours, and a reflex DROP here next to that would be an
-- accident waiting to happen.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.range2zip_carrier_node_tbl
(
    network        cidr        NOT NULL,
    zip            text        NOT NULL,
    node_kind      text        NOT NULL,
    node_ip        inet,
    node_hostname  text,
    zips_at_node   integer     NOT NULL,
    landmarks      integer     NOT NULL,
    example_ip     inet,
    assigned_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT range2zip_carrier_node_zip_shape CHECK (zip ~ '^[0-9]{5}$'),
    CONSTRAINT range2zip_carrier_node_kind CHECK (node_kind IN ('ip', 'hostname')),
    CONSTRAINT range2zip_carrier_node_pkey PRIMARY KEY (network, zip, node_kind)
);

COMMENT ON TABLE public.range2zip_carrier_node_tbl IS
    'ZIP assigned to an IP range because the range and an on-premises landmark reach the network through the same last carrier node. node_kind records whether the nodes were matched by router IP or by reverse-DNS hostname, since those have different specificity. zips_at_node is the fan-out that was accepted: 1 means the node served exactly one ZIP.';

COMMENT ON COLUMN public.range2zip_carrier_node_tbl.zips_at_node IS
    'How many distinct Overture ZIPs the landmarks behind this node had. The fan-out guard in section 5 bounds this. Retained per row so an assignment can be re-judged later without re-deriving it.';

CREATE INDEX IF NOT EXISTS range2zip_carrier_node_tbl_network_gist
    ON public.range2zip_carrier_node_tbl USING gist (network inet_ops);

CREATE INDEX IF NOT EXISTS range2zip_carrier_node_tbl_zip_idx
    ON public.range2zip_carrier_node_tbl (zip);


-- ---------------------------------------------------------------------------
-- 1. PRECONDITIONS. Run this first and read it before anything else.
--
-- The convergence join needs mtr data on BOTH sides. The landmark side is new.
-- The range side is the long-standing ip2city_dbiplite_traceroute_tbl, but that
-- table is now written by two different tools: geo/main.go with probe_method
-- 'mtr-icmp' or 'mtr-udp', and check_geo_ip-api with probe_method 'ip-api'. Only
-- the mtr rows carry a real traceroute node. If the mtr count below is zero or
-- small, section 5 will return almost nothing, and the answer is to run the
-- range side first, not to loosen the guard.
-- ---------------------------------------------------------------------------

SELECT 'landmark side'                                               AS side,
       count(*)                                                      AS rows_traced,
       count(*) FILTER (WHERE status = 'reached')                     AS reached,
       count(*) FILTER (WHERE status = 'reached'
                          AND last_hop_ip IS NOT NULL)                AS with_node_ip,
       count(*) FILTER (WHERE status = 'reached'
                          AND last_hop_hostname IS NOT NULL)          AS with_node_hostname,
       count(*) FILTER (WHERE likely_mobile_cgnat)                    AS mobile_flagged
FROM public.ovt_places_usa_ip_trace
UNION ALL
SELECT 'range side (mtr only)',
       count(*),
       count(*) FILTER (WHERE status = 'reached'),
       count(*) FILTER (WHERE status = 'reached' AND last_hop_ip IS NOT NULL),
       count(*) FILTER (WHERE status = 'reached' AND last_hop_hostname IS NOT NULL),
       count(*) FILTER (WHERE likely_mobile_cgnat)
FROM ip2city_dbiplite_traceroute_tbl
WHERE probe_method LIKE 'mtr%';


-- How far through the landmark pass we are. The denominator is what
-- sampleLandmarks would still select, so remaining reaching zero means done.

SELECT count(DISTINCT p.ip_address)                                   AS distinct_onprem_addresses,
       count(DISTINCT p.ip_address) FILTER (WHERE t.ip IS NOT NULL)   AS traced,
       count(DISTINCT p.ip_address) FILTER (WHERE t.ip IS NULL)       AS remaining,
       count(*)                                                       AS places_behind_them
FROM ovt_places_usa p
LEFT JOIN public.ovt_places_usa_ip_trace t ON t.ip = p.ip_address
WHERE p.onpremises = true
  AND p.ip_address IS NOT NULL;


-- Why traces fail, which decides whether the pass is worth continuing.

SELECT status, count(*) AS addresses,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM public.ovt_places_usa_ip_trace
GROUP BY 1
ORDER BY 2 DESC;


-- ---------------------------------------------------------------------------
-- 1b. THE THREE DEFECTS FOUND ON THE FIRST 2,000-ADDRESS PASS. Measure them
-- before and after the fixes, because each one silently wastes traces rather
-- than raising an error, and a wasted trace in a multi-hour pass is expensive.
--
--   SELF-TRACE. last_hop_ip equals the address traced, so the recorded
--   "carrier node" is the landmark's own web server. Unusable: a probe range's
--   node can never match it. A landmark answers ICMP, so the trace completes
--   and the final responding hop IS the destination, which matched no
--   exclusion and no customer marker and was accepted. Range targets hid this
--   because a random address in a range almost never answers. Fixed in
--   classifyHops step 0, which discards any hop whose address is the address
--   being traced. After the fix this count must be ZERO. Rows traced before
--   the fix need re-tracing: delete them, which the statement below does not
--   do by itself.
--
--   PROVIDER-HOSTED. The address belongs to a CDN, cloud or web host, so rule
--   2 makes the landmark false and it should never have been traced. Cause is
--   not the tool: it is that `onpremises` has only ever been run with
--   --dry-run, so the stored column predates the provider table. Run
--   `ovt_resolve_hosts.py onpremises` for real BEFORE a long pass.
--
--   BACKBONE NODE. The accepted node is a transit core, which cannot anchor a
--   ZIP. The fan-out guard rejects these anyway so they are not a correctness
--   risk, only wasted traces. Not fixed by adding domain exclusions, because
--   Cogent and Zayo hostnames are ambiguous: the ccr, agr and er forms are
--   core routers, while a hostname carrying a b-prefixed building number or an
--   IDIA- circuit identifier is customer edge. Awaiting a decision.
-- ---------------------------------------------------------------------------

SELECT count(*)                                                       AS traced,
       count(*) FILTER (WHERE t.last_hop_ip = t.ip)                   AS self_trace,
       round(100.0 * count(*) FILTER (WHERE t.last_hop_ip = t.ip)
             / nullif(count(*), 0), 1)                                AS self_trace_pct,
       count(*) FILTER (WHERE lower(btrim(p.registrant_1)) IN (SELECT lower(btrim(name)) FROM provider_names)
                           OR lower(btrim(p.registrant_2)) IN (SELECT lower(btrim(name)) FROM provider_names))
                                                                      AS provider_hosted,
       count(*) FILTER (WHERE t.last_hop_hostname ~ '(cogentco|zayo|lumen[.]tech|he[.]net|twelve99[.]net)')
                                                                      AS backbone_node,
       count(*) FILTER (WHERE t.status = 'reached'
                          AND t.last_hop_ip IS DISTINCT FROM t.ip
                          AND t.last_hop_hostname !~ '(cogentco|zayo|lumen[.]tech|he[.]net|twelve99[.]net)')
                                                                      AS usable_now
FROM public.ovt_places_usa_ip_trace t
LEFT JOIN LATERAL (
    SELECT registrant_1, registrant_2 FROM ovt_places_usa
    WHERE ip_address = t.ip LIMIT 1) p ON true;


-- The self-traced rows must be re-traced once the fix is deployed, because the
-- useful hop was never recorded. Deleting them makes sampleLandmarks pick them
-- up again, since it resumes on NOT EXISTS against this table. Deliberately
-- left commented: it discards measured work, and it should be run knowingly,
-- after confirming the count above and that the deployed binary carries the
-- fix (go version -m on the installed binary should report the merge commit).

-- DELETE FROM public.ovt_places_usa_ip_trace WHERE last_hop_ip = ip;


-- Which carrier operators the usable nodes actually belong to, by the domain of
-- the node's reverse DNS. Read this to see whose hostnames carry a town name
-- and are therefore worth anything: Comcast's rur/ssag/soag forms encode one
-- (westroxbury, woburn, lynn, maynard, peabody), while a transit core does not.

-- The last two labels of the hostname are extracted with reverse and
-- split_part rather than regexp_replace with a backreference, because a
-- backreference needs a backslash and this file must contain none so that it
-- survives copy and paste.

SELECT reverse(split_part(reverse(t.last_hop_hostname), '.', 2)) || '.'
       || reverse(split_part(reverse(t.last_hop_hostname), '.', 1))  AS node_domain,
       count(*)                                                       AS nodes,
       count(DISTINCT t.last_hop_ip)                                  AS distinct_node_ips,
       min(t.last_hop_hostname)                                       AS example
FROM public.ovt_places_usa_ip_trace t
WHERE t.status = 'reached'
  AND t.last_hop_hostname IS NOT NULL
  AND t.last_hop_ip IS DISTINCT FROM t.ip
GROUP BY 1
ORDER BY 2 DESC
LIMIT 40;


-- ---------------------------------------------------------------------------
-- 2. FILL ip_address_range AND ip_last_carrier_node_range WITHOUT PROBING.
--
-- These two inet columns on ovt_places_usa have existed unpopulated since the
-- table was created. They are the enclosing routed prefix of the landmark
-- address and of its carrier node, and both come from containment against
-- ip2city_dbiplite_tbl, which has a GiST index on network. No traffic needed.
--
-- Done per DISTINCT address in a temp table and then joined out, because
-- ovt_places_usa has about 18M rows and a correlated subquery per row would be
-- 18M index descents instead of roughly 123k.
--
-- ORDER BY masklen DESC takes the most specific enclosing prefix, matching the
-- convention in rdap_registrant_tbl.sql, which orders by range size for the
-- same reason: the narrowest allocation is the one that describes the address.
-- ---------------------------------------------------------------------------

BEGIN;

CREATE TEMP TABLE lcn_addr_range ON COMMIT DROP AS
SELECT t.ip,
       r.network                                        AS addr_range,
       n.network                                        AS node_range
FROM public.ovt_places_usa_ip_trace t
LEFT JOIN LATERAL (
    SELECT d.network FROM ip2city_dbiplite_tbl d
    WHERE d.network >>= t.ip
    ORDER BY masklen(d.network) DESC
    LIMIT 1) r ON true
LEFT JOIN LATERAL (
    SELECT d.network FROM ip2city_dbiplite_tbl d
    WHERE t.last_hop_ip IS NOT NULL AND d.network >>= t.last_hop_ip
    ORDER BY masklen(d.network) DESC
    LIMIT 1) n ON true;

CREATE INDEX ON lcn_addr_range (ip);
ANALYZE lcn_addr_range;

UPDATE ovt_places_usa p
SET ip_address_range          = a.addr_range::inet,
    ip_last_carrier_node      = t.last_hop_ip,
    ip_last_carrier_node_range = a.node_range::inet
FROM public.ovt_places_usa_ip_trace t
JOIN lcn_addr_range a ON a.ip = t.ip
WHERE p.ip_address = t.ip
  AND (p.ip_address_range           IS DISTINCT FROM a.addr_range::inet
    OR p.ip_last_carrier_node       IS DISTINCT FROM t.last_hop_ip
    OR p.ip_last_carrier_node_range IS DISTINCT FROM a.node_range::inet);

COMMIT;


-- ---------------------------------------------------------------------------
-- 3. HOW MANY LANDMARKS SIT BEHIND ONE NODE, and how many ZIPs that spans.
--
-- This is the shape of the problem. Read it before section 4.
-- ---------------------------------------------------------------------------

SELECT count(DISTINCT t.last_hop_ip)                                  AS distinct_node_ips,
       count(DISTINCT t.last_hop_hostname)                            AS distinct_node_hostnames,
       count(DISTINCT t.ip)                                           AS landmark_addresses,
       round(count(DISTINCT t.ip)::numeric
             / nullif(count(DISTINCT t.last_hop_ip), 0), 2)           AS addresses_per_node_ip,
       round(count(DISTINCT t.last_hop_ip)::numeric
             / nullif(count(DISTINCT t.last_hop_hostname), 0), 2)     AS node_ips_per_hostname
FROM public.ovt_places_usa_ip_trace t
WHERE t.status = 'reached'
  AND t.last_hop_ip IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 4. THE FAN-OUT DISTRIBUTION. This is the measurement that sets the guard.
--
-- For each carrier node, how many distinct Overture ZIPs do the landmarks
-- behind it have? A node with 1 is a clean anchor. A node with 40 is a metro
-- aggregation point and anchors nothing.
--
-- Run BOTH. node_ips_per_hostname in section 3 already hints at the answer, but
-- these two histograms settle it, because the two identities are not
-- interchangeable:
--
--   by node IP        a specific router interface, the most specific identity
--                     available, and the tightest match
--   by node hostname  looser, because carriers commonly give one PTR to every
--                     router in a metro. If the hostname histogram is much
--                     wider than the IP histogram, PTRs are metro-wide and
--                     hostname matching must not be used for assignment.
--                     If they are similar, PTRs are per-router and hostname
--                     matching usefully recovers nodes whose interface IP
--                     differs between the landmark trace and the range trace,
--                     which is common with load balancing.
--
-- DO NOT pick a threshold before reading these. Section 5 defaults to 1, which
-- is not a measured value but the only choice that is unambiguous by
-- construction, and it should be revised from this output.
-- ---------------------------------------------------------------------------

SELECT 'by node ip'                                                   AS identity,
       x.zips_at_node,
       count(*)                                                       AS nodes,
       sum(x.landmark_addresses)                                      AS landmark_addresses,
       round(100.0 * sum(x.landmark_addresses)
             / sum(sum(x.landmark_addresses)) OVER (), 1)             AS pct_of_addresses
FROM (
    SELECT t.last_hop_ip,
           count(DISTINCT p.overture_zip)                             AS zips_at_node,
           count(DISTINCT t.ip)                                       AS landmark_addresses
    FROM public.ovt_places_usa_ip_trace t
    JOIN ovt_places_usa p ON p.ip_address = t.ip
    WHERE t.status = 'reached'
      AND t.last_hop_ip IS NOT NULL
      AND p.onpremises = true
      AND p.overture_zip IS NOT NULL
    GROUP BY 1) x
GROUP BY 1, 2
ORDER BY 2;

SELECT 'by node hostname'                                             AS identity,
       x.zips_at_node,
       count(*)                                                       AS nodes,
       sum(x.landmark_addresses)                                      AS landmark_addresses,
       round(100.0 * sum(x.landmark_addresses)
             / sum(sum(x.landmark_addresses)) OVER (), 1)             AS pct_of_addresses
FROM (
    SELECT t.last_hop_hostname,
           count(DISTINCT p.overture_zip)                             AS zips_at_node,
           count(DISTINCT t.ip)                                       AS landmark_addresses
    FROM public.ovt_places_usa_ip_trace t
    JOIN ovt_places_usa p ON p.ip_address = t.ip
    WHERE t.status = 'reached'
      AND t.last_hop_hostname IS NOT NULL
      AND p.onpremises = true
      AND p.overture_zip IS NOT NULL
    GROUP BY 1) x
GROUP BY 1, 2
ORDER BY 2;


-- The worst offenders by name. Carrier naming conventions are visible here, and
-- a node spanning many ZIPs usually announces itself in its hostname as an
-- aggregation or core router.

SELECT t.last_hop_hostname,
       count(DISTINCT p.overture_zip)                                 AS zips_at_node,
       count(DISTINCT t.ip)                                           AS landmark_addresses,
       min(p.overture_zip)                                            AS zip_lo,
       max(p.overture_zip)                                            AS zip_hi
FROM public.ovt_places_usa_ip_trace t
JOIN ovt_places_usa p ON p.ip_address = t.ip
WHERE t.status = 'reached'
  AND t.last_hop_hostname IS NOT NULL
  AND p.onpremises = true
  AND p.overture_zip IS NOT NULL
GROUP BY 1
HAVING count(DISTINCT p.overture_zip) > 1
ORDER BY 2 DESC
LIMIT 40;


-- ---------------------------------------------------------------------------
-- 5. THE ASSIGNMENT. Ranges get a ZIP from a landmark at the same node.
--
-- The guard is the `max_zips_per_node` value in the guard CTE. Change it in one
-- place. It is 1 here: a node whose landmarks all agree on one ZIP transfers
-- that ZIP with no interpretation required. Raising it means accepting that a
-- node spans more than one ZIP and then having to choose among them, which
-- needs a rule this file does not have, so raise it only after section 4 shows
-- the distribution supports it and after deciding how to break the tie.
--
-- A node still has to be matched to a RANGE, and the range side must itself
-- have been traced by mtr: probe_method LIKE 'mtr%' excludes the ip-api rows
-- that share this table and carry no traceroute node.
--
-- Mobile and CGNAT nodes are excluded on both sides. A mobile carrier's node
-- serves whoever is in range of it, so shared routing carries no postal
-- meaning, and the existing likely_mobile_cgnat flag already identifies them.
-- ---------------------------------------------------------------------------

INSERT INTO public.range2zip_carrier_node_tbl
    (network, zip, node_kind, node_ip, node_hostname, zips_at_node, landmarks, example_ip)
WITH guard AS (
    SELECT 1 AS max_zips_per_node
),
node_zip AS (
    SELECT t.last_hop_ip                                              AS node_ip,
           min(p.overture_zip)                                        AS zip,
           count(DISTINCT p.overture_zip)                             AS zips_at_node,
           count(DISTINCT t.ip)                                       AS landmarks,
           min(t.ip)                                                  AS example_ip
    FROM public.ovt_places_usa_ip_trace t
    JOIN ovt_places_usa p ON p.ip_address = t.ip
    WHERE t.status = 'reached'
      AND t.last_hop_ip IS NOT NULL
      AND NOT coalesce(t.likely_mobile_cgnat, false)
      AND p.onpremises = true
      AND p.overture_zip ~ '^[0-9]{5}$'
    GROUP BY 1
)
SELECT pr.network,
       nz.zip,
       'ip'                                                           AS node_kind,
       nz.node_ip,
       pr.last_hop_hostname,
       nz.zips_at_node,
       nz.landmarks,
       nz.example_ip
FROM ip2city_dbiplite_traceroute_tbl pr
JOIN node_zip nz ON nz.node_ip = pr.last_hop_ip
CROSS JOIN guard g
WHERE pr.probe_method LIKE 'mtr%'
  AND pr.status = 'reached'
  AND pr.last_hop_ip IS NOT NULL
  AND NOT coalesce(pr.likely_mobile_cgnat, false)
  AND nz.zips_at_node <= g.max_zips_per_node
ON CONFLICT (network, zip, node_kind) DO UPDATE SET
    node_ip       = EXCLUDED.node_ip,
    node_hostname = EXCLUDED.node_hostname,
    zips_at_node  = EXCLUDED.zips_at_node,
    landmarks     = EXCLUDED.landmarks,
    example_ip    = EXCLUDED.example_ip,
    assigned_at   = now();


-- The hostname-matched variant. Both are produced, deliberately, because having
-- them side by side is what makes the two identities comparable: the row counts
-- and the zips_at_node values can be read against each other directly.
--
-- They are tagged node_kind = 'ip' and node_kind = 'hostname' and are part of
-- the primary key, so they cannot be conflated downstream, double-counted, or
-- averaged together. Only ONE of them should ever be promoted into
-- range2zip_tbl, and section 8 filters node_kind = 'ip' for that reason.
--
-- Promote the hostname variant instead only if section 4 shows its histogram is
-- close to the node-IP histogram. If PTRs turn out to be metro-wide, hostname
-- matching yields metro-level ZIPs wearing the appearance of ZIP-level data,
-- which is worse than assigning nothing at all.

INSERT INTO public.range2zip_carrier_node_tbl
    (network, zip, node_kind, node_ip, node_hostname, zips_at_node, landmarks, example_ip)
WITH guard AS (
    SELECT 1 AS max_zips_per_node
),
node_zip AS (
    SELECT t.last_hop_hostname                                        AS node_hostname,
           min(p.overture_zip)                                        AS zip,
           count(DISTINCT p.overture_zip)                             AS zips_at_node,
           count(DISTINCT t.ip)                                       AS landmarks,
           min(t.ip)                                                  AS example_ip
    FROM public.ovt_places_usa_ip_trace t
    JOIN ovt_places_usa p ON p.ip_address = t.ip
    WHERE t.status = 'reached'
      AND t.last_hop_hostname IS NOT NULL
      AND NOT coalesce(t.likely_mobile_cgnat, false)
      AND p.onpremises = true
      AND p.overture_zip ~ '^[0-9]{5}$'
    GROUP BY 1
)
SELECT pr.network,
       nz.zip,
       'hostname'                                                     AS node_kind,
       pr.last_hop_ip,
       nz.node_hostname,
       nz.zips_at_node,
       nz.landmarks,
       nz.example_ip
FROM ip2city_dbiplite_traceroute_tbl pr
JOIN node_zip nz ON nz.node_hostname = pr.last_hop_hostname
CROSS JOIN guard g
WHERE pr.probe_method LIKE 'mtr%'
  AND pr.status = 'reached'
  AND pr.last_hop_hostname IS NOT NULL
  AND NOT coalesce(pr.likely_mobile_cgnat, false)
  AND nz.zips_at_node <= g.max_zips_per_node
ON CONFLICT (network, zip, node_kind) DO UPDATE SET
    node_ip       = EXCLUDED.node_ip,
    node_hostname = EXCLUDED.node_hostname,
    zips_at_node  = EXCLUDED.zips_at_node,
    landmarks     = EXCLUDED.landmarks,
    example_ip    = EXCLUDED.example_ip,
    assigned_at   = now();


-- ---------------------------------------------------------------------------
-- 6. DID THE TWO SIDES AGREE ABOUT THE CARRIER?
--
-- An AS-level match is a necessary precondition for node convergence, not
-- evidence of it, so it is reported rather than enforced. A disagreement is a
-- red flag worth reading: it means a landmark and a range share a router
-- interface while their prefixes are announced by different origin ASNs, which
-- can be legitimate (one carrier running separate business and consumer ASNs)
-- or can mean the node identity is not as specific as it looks.
--
-- bgp_route_views.cidr_block is inet with only a btree on (cidr_block, peer_ip)
-- and no GiST, so a containment query against all 1.1M rows would seq-scan.
-- The codebase's established workaround is used: materialise the small prefix
-- set first, GiST-index that, then join. Same pattern as excluded_asn_prefixes
-- in geo/pipeline/rebuild_probe_tbl.sql.
-- ---------------------------------------------------------------------------

BEGIN;

CREATE TEMP TABLE lcn_asn ON COMMIT DROP AS
SELECT DISTINCT b.cidr_block, b.origin_asn
FROM bgp_route_views b
WHERE b.origin_asn IS NOT NULL
  AND family(b.cidr_block) = 4
  AND masklen(b.cidr_block) >= 8;

CREATE INDEX ON lcn_asn USING gist (cidr_block inet_ops);
ANALYZE lcn_asn;

SELECT coalesce(la.origin_asn::text, 'unknown')                       AS landmark_asn,
       coalesce(ra.origin_asn::text, 'unknown')                       AS range_asn,
       (la.origin_asn IS NOT DISTINCT FROM ra.origin_asn)             AS same_origin_as,
       count(*)                                                      AS assignments
FROM public.range2zip_carrier_node_tbl c
LEFT JOIN LATERAL (
    SELECT a.origin_asn FROM lcn_asn a
    WHERE a.cidr_block >>= c.example_ip
    ORDER BY masklen(a.cidr_block) DESC LIMIT 1) la ON true
LEFT JOIN LATERAL (
    SELECT a.origin_asn FROM lcn_asn a
    WHERE a.cidr_block >>= host(network(c.network))::inet
    ORDER BY masklen(a.cidr_block) DESC LIMIT 1) ra ON true
GROUP BY 1, 2, 3
ORDER BY 4 DESC
LIMIT 40;

COMMIT;


-- ---------------------------------------------------------------------------
-- 7. COVERAGE ACCOUNTING. Ranges with and without a ZIP, ZIPs with and without
-- a range. This is the figure of merit for the whole method, and the number to
-- watch across runs.
-- ---------------------------------------------------------------------------

SELECT count(DISTINCT c.network)                                      AS ranges_with_a_zip,
       count(DISTINCT c.zip)                                          AS zips_reached,
       count(*)                                                       AS assignment_rows,
       count(*) FILTER (WHERE c.node_kind = 'ip')                     AS by_node_ip,
       count(*) FILTER (WHERE c.node_kind = 'hostname')               AS by_node_hostname
FROM public.range2zip_carrier_node_tbl c;


-- Ranges that were traced and reached a node, but whose node matched no
-- landmark. This is the headroom: it is what more landmark tracing would buy.

SELECT count(*)                                                       AS reached_ranges_total,
       count(*) FILTER (WHERE c.network IS NOT NULL)                  AS matched_a_landmark,
       count(*) FILTER (WHERE c.network IS NULL)                      AS no_landmark_at_node
FROM ip2city_dbiplite_traceroute_tbl pr
LEFT JOIN public.range2zip_carrier_node_tbl c ON c.network = pr.network
WHERE pr.probe_method LIKE 'mtr%'
  AND pr.status = 'reached'
  AND pr.last_hop_ip IS NOT NULL;


-- ZIPs that have landmarks but no range, which is the other side of the gap.

SELECT count(DISTINCT p.overture_zip)                                 AS zips_with_onprem_landmarks,
       count(DISTINCT p.overture_zip) FILTER (WHERE c.zip IS NOT NULL) AS zips_that_got_a_range,
       count(DISTINCT p.overture_zip) FILTER (WHERE c.zip IS NULL)    AS zips_still_unrouted
FROM ovt_places_usa p
LEFT JOIN public.range2zip_carrier_node_tbl c ON c.zip = p.overture_zip
WHERE p.onpremises = true
  AND p.overture_zip ~ '^[0-9]{5}$';


-- Where the carrier-node method and ip-api disagree. ip-api is the fallback and
-- is known to be ZIP-precise for some carriers and miles off for others, so a
-- disagreement is not automatically an error on either side. Worth reading for
-- the pattern, by carrier.

SELECT pr.isp,
       count(*)                                                       AS ranges,
       count(*) FILTER (WHERE pr.zip = c.zip)                         AS zip_agrees,
       count(*) FILTER (WHERE pr.zip IS DISTINCT FROM c.zip)          AS zip_differs
FROM public.range2zip_carrier_node_tbl c
JOIN ip2city_dbiplite_traceroute_tbl pr ON pr.network = c.network
WHERE pr.zip IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC
LIMIT 40;


-- ---------------------------------------------------------------------------
-- 8. MERGING INTO range2zip_tbl. Written out, NOT run.
--
-- range2zip_tbl is PRIMARY KEY (network, zip) with city and state_code NOT
-- NULL, and a source column that defaults to 'landmark'. Carrier-node rows can
-- go in with source = 'carrier_node', which keeps them distinguishable, but the
-- city and state have to come from somewhere, and the only available source is
-- the db-ip row for the range being assigned. That means the ZIP would be
-- landmark-derived while the city beside it is db-ip-derived, in one row, which
-- is exactly the kind of mixed provenance that makes a later audit impossible.
--
-- Two ways to resolve it, neither taken unilaterally:
--   Derive city and state from the landmark's own Overture address instead,
--   which is the consistent answer but needs the addresses field parsed.
--   Or relax the NOT NULL on city and state_code for non-landmark sources.
--
-- Uncomment only after choosing. zip_landmark_count on the probe table, and the
-- generated *_definitive columns, will then start reflecting these rows, which
-- is the point, so this is not a reversible step to take casually.
-- ---------------------------------------------------------------------------

-- INSERT INTO range2zip_tbl (network, zip, city, state_code, landmark_ip, source)
-- SELECT c.network, c.zip, d.city, st.state_code, c.example_ip, 'carrier_node'
-- FROM public.range2zip_carrier_node_tbl c
-- JOIN ip2city_dbiplite_tbl d ON d.network = c.network
-- LEFT JOIN trugeo_states_tbl st ON st.state = d.state
-- WHERE c.node_kind = 'ip'
--   AND d.city IS NOT NULL
--   AND st.state_code IS NOT NULL
-- ON CONFLICT (network, zip) DO NOTHING;


DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cronuser') THEN
        GRANT SELECT, INSERT, UPDATE, DELETE ON public.range2zip_carrier_node_tbl TO cronuser;
        RAISE NOTICE 'granted range2zip_carrier_node_tbl to cronuser';
    ELSE
        RAISE NOTICE 'role cronuser does not exist, so no grant was made';
    END IF;
END
$$;
