-- traceroute_hostname_rules.sql
--
-- Canonical schema + CPE (customer_marker_regex) rule set for the
-- traceroute-sample classifier (geo/main.go). Apply against the same
-- Postgres database the classifier reads via DATABASE_URL.
--
-- Rule types consumed by loadClassificationRules():
--   tld_exclude          - suffix match on a TLD          -> status_label (e.g. excluded-mil)
--   domain_exclude       - domain-boundary suffix match   -> status_label (e.g. excluded-internal)
--   customer_marker      - label-boundary substring (CPE marker, e.g. "res.")
--   customer_marker_regex- full-hostname regex (CPE forms a label marker can't express)
--
-- customer_marker_regex patterns are compiled with Go's RE2 (regexp.Compile)
-- and matched against the LOWER-CASED hostname, so write them lower-case.
-- Standard PostgreSQL string literals keep backslashes verbatim
-- (standard_conforming_strings = on, the default), so '\.' is a literal dot.
--
-- IP-address encodings in CPE hostnames must cover IPv4 AND IPv6, so the
-- per-token class is [0-9a-f:-] (digits, a-f hex, colon, hyphen). Where an
-- ISP separates the IP octets with dots (Windstream), the dots are literal
-- separators between [0-9a-f:-] tokens.

-- 1. Rules table (safe on fresh installs; skipped if it already exists).
CREATE TABLE IF NOT EXISTS traceroute_hostname_rules (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_type    text NOT NULL
                 CHECK (rule_type IN ('tld_exclude','domain_exclude',
                                      'customer_marker','customer_marker_regex',
                                      'transit_domain')),
    pattern      text NOT NULL,
    status_label text,
    UNIQUE (rule_type, pattern)
);

-- If the table ALREADY exists with a CHECK constraint on rule_type that does
-- not list every type above, replace it (constraint name from
-- \d traceroute_hostname_rules). Run this before the inserts below.
--   ALTER TABLE traceroute_hostname_rules DROP CONSTRAINT traceroute_hostname_rules_rule_type_check;
--   ALTER TABLE traceroute_hostname_rules ADD  CONSTRAINT traceroute_hostname_rules_rule_type_check
--       CHECK (rule_type IN ('tld_exclude','domain_exclude','customer_marker','customer_marker_regex','transit_domain'));

ALTER TABLE traceroute_hostname_rules DROP CONSTRAINT IF EXISTS traceroute_hostname_rules_rule_type_check;
ALTER TABLE traceroute_hostname_rules ADD  CONSTRAINT traceroute_hostname_rules_rule_type_check
    CHECK (rule_type IN ('tld_exclude','domain_exclude','customer_marker',
                         'customer_marker_regex','transit_domain'));

-- 2. Supersede the earlier IPv4-only fuse.net patterns (idempotent cleanup).
DELETE FROM traceroute_hostname_rules
 WHERE rule_type = 'customer_marker_regex'
   AND pattern IN ('^ip-[0-9-]+\.static\.fuse\.net$',
                   '^ip-[0-9-]+\.dynamic\.fuse\.net$');

-- 3. CPE regex rules (status_label NULL -> markers, not exclusions).
INSERT INTO traceroute_hostname_rules (rule_type, pattern, status_label) VALUES
  -- Charter/Spectrum static assignments: syn-<ip>.biz.spectrum.com
  ('customer_marker_regex', '^syn-[0-9a-f:-]+\.biz\.spectrum\.com$', NULL),
  -- Cincinnati Bell / fuse.net: ip-<ip>.static|dynamic.fuse.net  (IPv4+IPv6)
  ('customer_marker_regex', '^ip-[0-9a-f:-]+\.static\.fuse\.net$',  NULL),
  ('customer_marker_regex', '^ip-[0-9a-f:-]+\.dynamic\.fuse\.net$', NULL),
  -- Windstream, both dynamic and static assignments (most ISPs hand out
  -- static IPs to at least business customers). The IP octets are
  -- DOT-separated, e.g. h98.110.31.71.dynamic.ip.windstream.net and
  -- h98.110.31.71.static.ip.windstream.net -> literal dots between tokens.
  ('customer_marker_regex', '^h[0-9a-f:-]+(?:\.[0-9a-f:-]+)*\.dynamic\.ip\.windstream\.net$', NULL),
  ('customer_marker_regex', '^h[0-9a-f:-]+(?:\.[0-9a-f:-]+)*\.static\.ip\.windstream\.net$',  NULL)
ON CONFLICT (rule_type, pattern) DO NOTHING;

-- 4. Column for the RDAP ownership/location fallback (writeResult in main.go).
ALTER TABLE ip2city_dbiplite_traceroute_tbl ADD COLUMN IF NOT EXISTS rdap_lookup text;



-- ---------------------------------------------------------------------------
-- transit_domain: the node belongs to a TRANSIT operator rather than a retail
-- access network. These are NOT exclusions and status_label is therefore NULL.
-- A match sets mobile_transit = 't', which records DMA accuracy rather than
-- discarding the row, because a business address consumes biddable media in its
-- own right whether at work or in campus housing.
--
-- Why transit is DMA and not ZIP. A transit operator carries no retail
-- subscribers, so its node cannot converge with household routing at all, and
-- separately its aggregation routers serve a metro. Both point to DMA. The
-- distinction from 'm' is kept because the causes differ and the audit should
-- show which applied.
--
-- MEASURED FROM THE 312-ADDRESS MASSACHUSETTS PASS. Of 235 reached landmarks,
-- 152 had a transit node, 64.7%, on only 44 router IPs. Cogent alone accounted
-- for 118 of them across 23 routers.
--
-- Cogent and Zayo are the hard cases and are listed here by DOMAIN anyway, with
-- the reason recorded: their core forms ccr, agr, er and mpr are unambiguous
-- transit, but hostnames carrying a b-prefixed building number or an IDIA-
-- circuit identifier are customer edge and will be mislabelled 't' by a domain
-- match. That mislabelling costs accuracy, not correctness, since the row is
-- retained at DMA tier rather than dropped. Refining it to a router-role regex
-- is a separate decision, deliberately deferred rather than guessed.

INSERT INTO traceroute_hostname_rules (rule_type, pattern, status_label) VALUES
  ('transit_domain', 'cogentco.com',      NULL),
  ('transit_domain', 'lumen.tech',        NULL),
  ('transit_domain', 'zayo.com',          NULL),
  ('transit_domain', 'he.net',            NULL),
  ('transit_domain', 'twelve99.net',      NULL),
  ('transit_domain', 'twelve99-cust.net', NULL),
  ('transit_domain', 'gtt.net',           NULL),
  ('transit_domain', 'level3.net',        NULL),
  ('transit_domain', 'ntt.net',           NULL),
  ('transit_domain', 'as3491.net',        NULL),
  ('transit_domain', 'as6453.net',        NULL),
  ('transit_domain', 'qwest.net',         NULL),
  ('transit_domain', 'telia.net',         NULL),
  ('transit_domain', 'sprintlink.net',    NULL),
  ('transit_domain', 'alter.net',         NULL),
  ('transit_domain', 'above.net',         NULL),
  ('transit_domain', 'unitasglobal.net',  NULL),
  ('transit_domain', 'lightower.net',     NULL),
  ('transit_domain', 'as701.net',         NULL)
ON CONFLICT (rule_type, pattern) DO NOTHING;

-- NOT listed, deliberately, because these are retail access networks whose
-- nodes do carry households and can therefore carry a ZIP. The Massachusetts
-- pass showed Comcast naming them by town: westroxbury, cambridge, framingham,
-- norwood, peabody, plymouth, foxboro, exeter, derry, londonderry.
--
--   comcast.net  verizon-gni.net  rcn.net  astound.net  charter.com
--   atlanticbb.net  sbcglobal.net  cox.net
--
-- Also not listed: att.net. ggr2.n54ny.ip.att.net is a New York gateway and is
-- transit in behaviour, but att.net also carries retail DSL and fibre
-- hostnames, so a domain match would mislabel those. Needs a role regex, which
-- is the same open question as Cogent and Zayo.
