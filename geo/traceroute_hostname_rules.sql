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
                                      'customer_marker','customer_marker_regex')),
    pattern      text NOT NULL,
    status_label text,
    UNIQUE (rule_type, pattern)
);

-- If the table ALREADY exists with a CHECK constraint on rule_type that does
-- not list 'customer_marker_regex', replace it (constraint name from
-- \d traceroute_hostname_rules):
--   ALTER TABLE traceroute_hostname_rules DROP CONSTRAINT traceroute_hostname_rules_rule_type_check;
--   ALTER TABLE traceroute_hostname_rules ADD  CONSTRAINT traceroute_hostname_rules_rule_type_check
--       CHECK (rule_type IN ('tld_exclude','domain_exclude','customer_marker','customer_marker_regex'));

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
