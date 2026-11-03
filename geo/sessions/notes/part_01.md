# Part 01 (lines 1-4810)

> Format note about the source: the transcript is a UI export, not a raw tool log. Assistant tool
> calls appear collapsed as markers like `3 tools`, `Thought (24)`, `Ran command`, `Read main.go`,
> `Git clone`. The actual argv of most git/go/test invocations is therefore NOT in the text. Only
> commands that the assistant or Boris typed into prose/code blocks are recoverable verbatim. Each
> assistant turn ends with `Est. Credits Used:` and `Elapsed Time:` lines.

## Narrative

The slice opens with Boris asking the instance to fetch the `claude/geo` folder of the
`borislevitanimmetrica/claude` repo. He describes the existing program: `main.go` picks a random
address out of an IP range, runs an `mtr` scan toward it, and reads the **last domain-resolvable
carrier node before customer equipment** in order to infer the customer's city; under some
conditions it samples additional addresses when the first trace yields no last carrier node. His
first request (the instance later calls it "Case 0"): when a range's status comes out
`excluded-internal`, fall back to running the sampled IP through `rdap-lookup.sh` to get ownership
and location, because some customers are served directly off a wholesale/trunk operator with no
domain-resolvable routing equipment — but a domain-resolvable last-carrier-node must always take
precedence over RDAP, since for retail ISPs the ARIN address is the ISP's headquarters, not the
customer's city.

The instance searched and found nothing: no `geo/` folder on `main` (repo at `eeaa987`), none in any
of 13 remote branches (`session-43-*`, `session-44-*`, `session73-*`), nothing ever added per
`git log --all --diff-filter=A`, nothing in the working tree or `/projects/sandbox`, and no other
repo on the account. It refused to invent the algorithm and asked Boris to point it at real source.
Boris replied only "Fixed." — the `geo` folder was then present on `main` and work began.

For Case 0 the instance added a `-rdap-script` flag (default `./rdap-lookup.sh`) validated at
startup with `os.Stat` (missing script → warning and the fallback is disabled, the run still
proceeds, deliberately unlike the hard `log.Fatalf` on a missing `mtr`), a `runRDAP` helper that
shells `bash <script> <ip>` with a 30s timeout and captures combined stdout+stderr, an invocation in
`runRange` gated on `best.status == "excluded-internal"`, and persistence into a new `rdap_lookup`
column in `writeResult`. It verified `go build ./...` / `go vet ./...` using a throwaway module (not
committed, since the repo had no `go.mod`) and ran `rdap-lookup.sh 4.2.2.2` end to end. It opened
PR #1 on branch `geo-rdap-excluded-internal-fallback` and flagged two things: the required
`ALTER TABLE … ADD COLUMN rdap_lookup`, and that `excluded-internal` is produced in two distinct
ways (hostname exclusion rule vs. the latency override), the second of which does have a resolvable
carrier node and arguably should not be RDAP'd.

Boris then began feeding numbered misclassification cases from a real run log dated `2026/08/24`.
**Case 1** was `206.207.62.0/24` → sampled `206.207.62.12`, recorded as `excluded-internal` with
`last_hop=62.115.125.55(#13) hostname=phx-b6-link.ip.twelve99.net`, when the actual last resolved
node was `arizonastate-ic-373367.ip.twelve99-cust.net` (an ASU customer-serving interconnect, which
should have given `reached`). Mid-work Boris pasted the live 15-hop `mtr` run from his machine
`Immetrica-Mint30 (192.168.1.3)`, which the instance treated as ground truth. Tracing the code
against that data exposed two compounding bugs: `matchCustomerMarker` used a plain
`strings.Contains`, so the marker `cust.` matched *inside* the label `twelve99-cust` and the genuine
customer-edge hop was skipped as if it were CPE; and the "latency jump" override actually compared
the next hop's **absolute** average (`next.avgMs > 20.0`), which fires on essentially every
transcontinental trace. The instance fixed markers to require a DNS **label boundary** on the left,
changed the override to a true **delta** (`next.avgMs - c.avgMs > 20.0`), and refactored the
classification core out of `runOne` into a pure `classifyHops(hops, resolve, backtrackHops, rules)`
with an injected resolver so traces can be replayed without `mtr` or DNS. It replayed Boris's exact
trace as a temporary test, confirmed `reached` on hop #14, then deleted the test file (citing
Boris's no-unrequested-tests norm), built a static `linux/amd64` binary, and committed `5c8f423`
adding `geo/main.go`, `geo/geo` (13 MB), `geo/go.mod`, `geo/go.sum`.

Boris next gave the canonical heredoc path `~/geo/dbip-mmdb-import/traceroute-sample/main.go` and
two more cases. **Case 2** (`139.177.28.0/24`, `cspire-ic-308132.ip.twelve99-cust.net`) he correctly
predicted was the same shape as Case 1; the instance confirmed by replay that it now resolves to
`reached` on hop #11 with no new code. **Case 3** was `syn-070-116-145-242.biz.spectrum.com`, which
had been accepted as `reached` even though it is auto-generated Spectrum CPE whose hostname encodes
the customer's own IP (`070-116-145-242` = `70.116.145.242`); Boris stated the rule that carrier
equipment is `charter.com` while customer equipment is `spectrum.com`, and that
`syn-*.biz.spectrum.com` with `*` being digits/hyphens/colons must be treated as CPE. The instance
added a hardcoded `cpeHostnamePatterns` regex list plus `isCPEHostname`, wired into
`matchCustomerMarker` (commit `3c5bfca`), and offered two follow-ups: widen the character class to
include hex `a-f`, and move the regexes out of Go into the rules table.

Boris accepted both offers and added **Case 4** (`ip-*.static.fuse.net` / `ip-*.dynamic.fuse.net`
are CPE) and **Case 5** (`po-1-rur502.seattle.wa.seattle.comcast.net` wrongly `excluded-internal`,
which he himself diagnosed as the old absolute latency limit tripping on a Boston→Seattle path). The
instance introduced a new `customer_marker_regex` rule type in `traceroute_hostname_rules`, deleted
the hardcoded Go CPE list entirely, compiled DB patterns as-is (not lower-cased, so metacharacters
survive) while matching them against a lower-cased hostname, skipped invalid patterns with a warning
instead of aborting, and verified Case 5 by replay (delta ≈ 0 between the ~82 ms accepted node and
the ~83 ms same-metro next hop) — commit `1c96c13`. It also issued the first full
`traceroute_hostname_rules` table-creation migration.

The instance then dropped its reply ("Hi, you disconnected before posting or summarizing
anything"). On resume it checked git state first rather than assuming, confirmed the branch in sync
with origin at `1c96c13` with a clean tree, grep-confirmed the built-in CPE constants were gone and
the delta override present, and re-posted the whole answer. Boris next made the IP-token class rule
general (digits, hyphens, colons **and** `a-f` hex, for IPv4 and IPv6) and gave **Case 6**
(`h98.110.31.71.dynamic.ip.windstream.net`, "We will have many such"). The instance noted this was
now purely a data change, spotted that Windstream encodes the IP in **dot-separated** labels unlike
Spectrum/fuse's hyphens, wrote a dotted pattern, verified it with a temporary test through the real
`matchCustomerMarker`, and committed a canonical `geo/traceroute_hostname_rules.sql` at `1124743`
with an idempotent `DELETE` superseding the earlier IPv4-only fuse rows.

Boris then asked for the migration, asked to activate the Windstream **static** form too ("Most ISPs
offer static IPs to at least business customers"), and reported that his IPv6 now works and asked
how to exclude IPv6 from a traceroute-sample run. There was no way to do that before — IPv6
inclusion was driven solely by the `ipv6Available()` probe — so the instance added an `-ipv4-only`
flag that skips the probe and forces `family(t.network) = 4`, rebuilt, and committed `047b077`. The
slice ends with Boris reporting `flag provided but not defined: -ipv4-only` from
`./bin/traceroute-sample`; the instance noticed the printed usage also lacked `-rdap-script`,
concluded the binary was a stale build predating Case 0, verified the committed source and binary do
carry both flags, and started giving rebuild instructions. The line range cuts off mid-answer, in
the middle of "Option B — use the prebuilt binary from the repo".

## Decisions and rationale

- **Refuse to proceed with no source** (opening turn). The instance would not fabricate `main.go` /
  `rdap-lookup.sh` because it "would risk me 'fixing' code that doesn't match your real file."
  Boris accepted implicitly — he pushed the folder and said "Fixed."
- **RDAP fallback gated strictly on `excluded-internal`**, never on `reached`. Rationale: a
  resolvable customer-locating carrier node encodes the customer's city, whereas ARIN gives the
  retail ISP's HQ. This structurally implements Boris's precedence rule. Accepted.
- **Missing `rdap-lookup.sh` degrades, does not abort** (warning + fallback disabled), unlike the
  missing-`mtr` check which is fatal. Rationale: traceroute classification is still useful without
  RDAP. Accepted (not commented on).
- **Invoke the script as `bash <script> <ip>`** rather than executing it directly, so the
  executable bit doesn't matter. Accepted.
- **Capture `CombinedOutput`** so the script's own diagnostics (e.g. non-200 responses) survive into
  the stored note on failure. Accepted.
- **Fix both Case 1 bugs together, not just the marker bug.** Rationale given explicitly: with only
  the marker fix, hop 14 would be accepted but hop 15's ~80 ms absolute latency would re-trigger the
  override and the record would still be `excluded-internal`. Accepted.
- **Latency override redefined as a delta, keeping the 20 ms threshold.** Rationale: the original
  comment already said "jump", the code compared absolute; on a coast-to-coast path every terminal
  hop is ~80 ms so the absolute test buries legitimate edge nodes. Accepted; Boris independently
  arrived at the same diagnosis for Case 5.
- **Extract `classifyHops` as a pure function with injected `resolve`.** Rationale: makes
  classification replayable without `mtr` or live DNS. Accepted.
- **Write tests, run them, then delete them before committing.** Done repeatedly, each time
  justified as "per your no-unrequested-tests rule / norm". Boris never objected.
- **Add `geo/go.mod` + `geo/go.sum` to the repo** (there was previously no module) so the committed
  binary is reproducible. This overrode the earlier Case-0 decision to use a throwaway,
  uncommitted module. Accepted.
- **Case 3 regex implemented literally to Boris's spec** (`[0-9:-]`, no hex) even though the
  instance believed IPv6 PTRs need `a-f`; it flagged the gap and asked rather than silently widening.
  Boris then said "Yes, do this" — widened to `[0-9a-f:-]`, and later generalised the rule to all CPE
  patterns.
- **Move CPE regexes from Go constants into the DB as a new `customer_marker_regex` rule type.**
  Offered by the instance, Boris said "Yes, do this. Issue table creation SQL code." This overrode
  the Case-3 implementation (hardcoded Go list, deliberately mirroring the existing
  `isLikelyMobileCarrierHostname` style) one turn after it landed; the Go list was deleted.
- **Compile DB regex patterns as-is, never lower-cased**, while matching them against a lower-cased
  hostname. Rationale: lower-casing a regex corrupts metacharacters/classes. Accepted.
- **An invalid `customer_marker_regex` is skipped with a log warning, not fatal.** Accepted.
- **Regexes are checked before the plain label-prefix markers** in `matchCustomerMarker`. Accepted.
- **Windstream pattern uses literal dots between IP tokens** because its PTRs are
  `h<a>.<b>.<c>.<d>.dynamic.ip.windstream.net`, unlike the hyphen-joined Spectrum/fuse forms. The
  instance called this out as a wrinkle rather than reusing the hyphen pattern. Accepted.
- **Windstream `static` initially NOT activated**, only prepared as a commented line, because
  Boris's example said `dynamic`. Boris then explicitly asked for it ("Most ISPs offer static IPs to
  at least business customers") and it was activated. Modified by Boris.
- **`-ipv4-only` implemented as a flag that also skips the IPv6 connectivity probe**, rather than
  changing the probe's meaning. Default `false` preserves existing behaviour. Accepted.
- **Commit a canonical `geo/traceroute_hostname_rules.sql`** as the single versioned source of
  truth for DB rules, since rules are now data that the binary depends on. Accepted.
- **On reconnect after the dropped turn, verify actual git state before re-posting** rather than
  trusting memory of what landed. Accepted.
- **Diagnose the `-ipv4-only` failure as a stale binary, not a code bug**, keyed off the fact that
  the printed usage also lacked `-rdap-script` (so the binary predated Case 0). Outcome not visible
  in this range.

## Measured facts and numbers

All items below are quoted from the transcript. Where something is the assistant's reasoning rather
than an observation, it is marked.

- Repo `main` HEAD at session start: **`eeaa987`** ("up to date with origin").
- **13** remote branches searched (`session-43-*`, `session-44-*`, `session73-*`); none contained
  `geo/`, `main.go`, or any `rdap*` file.
- `borislevitanimmetrica/claude` is the **only** repository on the account.
- `rdap-lookup.sh 4.2.2.2` returned: **"Level 3 Parent, LLC — 100 CenturyLink Drive, Monroe, LA,
  71203, United States"** (verified by running it).
- Case 1 log line (from Boris's run): `2026/08/24 09:06:28 [23/30] 206.207.62.0/24 -> sampled
  206.207.62.12 (1 attempts) status=excluded-internal last_hop=62.115.125.55(#13)
  hostname=phx-b6-link.ip.twelve99.net note=long-haul latency jump at hop 14 (81.4ms)` — i.e.
  record 23 of a 30-range run, 1 attempt, offending next-hop latency **81.4 ms**.
- Case 1 live `mtr`, dated **`2026-08-25T05:43:37-0400`**, from `Immetrica-Mint30 (192.168.1.3)` to
  `206.207.62.12`, 15 hops, `Snt`=13 per hop. Avg ms per hop as printed:
  1 `router.asus.com` 1.7 (0.0% loss); 2 `lo0-100.BSTNMA-VFTTP-301.verizon-gni.net` 10.1 (0.0%);
  3 `100.41.25.202` 6.5 (0.0%); 4 `lag-14.BSTPMALL-PPR02-CC.ALTER.NET` 4.5 (**91.7% loss**);
  5 `customer.alter.net` 6.7 (**91.7% loss**); 6 `bost-b6-link.ip.twelve99.net` 9.4 (15.4% loss);
  7 `ewr-bb2-link` 13.5; 8 `ash-bb2-link` 18.9; 9 `atl-bb2-link` 29.7; 10 `hou-bb4-link` 52.2;
  11 `san-bb2-link` 83.0; 12 `dls-b23-link` 53.1; 13 `phx-b6-link` 79.9;
  14 `arizonastate-ic-373367.ip.twelve99-cust.net` 81.2; 15 `206.207.226.105` (no PTR, responded).
- Derived from that trace by the instance: hop **13→14 = +1.3 ms**, hop **14→15 ≈ 0 ms**; the real
  jumps were the cross-country backbone links at hops 9–13. (Arithmetic on measured values.)
- Case 2 log line: `2026/08/24 09:06:17 [18/30] 139.177.28.0/24 -> sampled 139.177.28.37 (1
  attempts) status=excluded-internal last_hop=62.115.134.247(#10)
  hostname=atl-b24-link.ip.twelve99.net note=long-haul latency jump at hop 11 (31.5ms)` — offending
  next-hop latency **31.5 ms**; correct node was `cspire-ic-308132.ip.twelve99-cust.net` at hop
  **#11**.
- Case 3 log line: `2026/08/24 09:06:04 [13/30] 154.94.135.32/27 -> sampled 154.94.135.58 (1
  attempts) status=reached last_hop=70.116.145.242(#15)
  hostname=syn-070-116-145-242.biz.spectrum.com note=<nil>`.
- Case 5 replay numbers (**synthetic test inputs**, not a live measurement): accepted node
  **~82 ms**, same-metro customer next hop **~83 ms**, delta **≈ 0** → `reached`.
- Case 1 regression check that the override still works: a **+45 ms** downstream jump still
  overrides to `excluded-internal` (synthetic test input).
- Latency override threshold: **20.0 ms** (now a delta; previously an absolute bound).
- Committed static binary `geo/geo`: **13 MB**, `linux/amd64`, `CGO_ENABLED=0 -trimpath`.
- Commits in this slice, in order: **`5c8f423`** (Case 1), **`3c5bfca`** (Cases 2–3),
  **`1c96c13`** (widened regex + DB-driven rules + Cases 4–5), **`1124743`** (IPv6-wide IP class,
  Case 6, canonical SQL file), **`047b077`** (Windstream static + `-ipv4-only`). Branch
  `geo-rdap-excluded-internal-fallback`; PR **#1**.
- Flag defaults in the program: `-n 200`, `-concurrency 5`, `-max-hops 15`, `-cycles 5`,
  `-interval 1.0`, `-max-attempts 3`, `-backtrack-hops 5`, `-udp false`,
  `-rdap-script ./rdap-lookup.sh`, `-ipv4-only false`, `-country ""`.
- Internal constants: `runRDAP` timeout **30 s**; `reverseDNS` timeout **3 s**;
  `ipv6Available()` UDP6 dial to `[2001:4860:4860::8888]:33434` with **2 s** timeout;
  `randomAddrInRangeExcluding` max **20** rerolls; `runOne` overall timeout =
  `cycles*interval + maxHops + 10` seconds; `resultRank` values **300** (reached) / **200**
  (unreachable or `excluded-*`) / **100** (incomplete) / **0** (errors).
- Boris's intended production run size: **`-n 10000 -country US -concurrency 5 -ipv4-only`**.
- Per-turn cost/time as printed: 1.17 credits / 1m 5s; 7.29 / 6m 33s; 12.20 / 12m 27s; 8.77 /
  6m 45s; 8.57 / 5m 8s; 3.50 / 2m 15s; 4.97 / 3m 24s; 5.78 / 2m 14s; 3.36 / 2m 30s.
- **Not measured anywhere in this slice:** row counts of `ip2city_dbiplite_tbl`,
  `ip2city_dbiplite_traceroute_tbl` or `traceroute_hostname_rules`; the actual loaded rule counts
  from the startup log; the resolution/`reached` rate of any full run; table sizes; any wall-clock
  timing of a traceroute run.

## Code, files, tables

Repo-relative paths (all on branch `geo-rdap-excluded-internal-fallback`):

- **`geo/main.go`** — the traceroute-sample program, modified in every case. Structure as of
  `047b077`:
  - `type target{network, start, end}`; `type result{network, sampledIP, lastHopIP, lastHopName,
    lastHopNumber, hopCount, status, probeMethod, attempts, likelyMobileCGN, classificationNote,
    rdapLookup}`.
  - `type classificationRules{tldExclusions map[string]string, domainExclusions map[string]string,
    customerMarkers []string, customerMarkerRegexes []*regexp.Regexp}` — loaded once at startup.
  - `loadClassificationRules` — `SELECT rule_type, pattern, status_label FROM
    traceroute_hostname_rules`; handles `tld_exclude`, `domain_exclude`, `customer_marker`
    (all lower-cased) and `customer_marker_regex` (**compiled verbatim**, invalid ones logged and
    skipped).
  - `matchExclusion` — suffix matching at a domain boundary (`== pattern` or ends with
    `"."+pattern`), not substring.
  - `matchCustomerMarker` — regexes first, then label-prefix markers requiring a left boundary
    (start of hostname or immediately after `.`).
  - `classifyHops(hops, resolve, backtrackHops, rules) result` — pure, extracted from `runOne` in
    Case 1. Pipeline: collect responding hops far-end-backward; cap the search at
    `backtrackHops+1`; find the nearest hop with any PTR; **if that hop number is 2 or 3 → status
    `unreachable`** (path died at the local ISP boundary), terminal; otherwise walk backward —
    exclusion-rule match is terminal with the rule's `status_label`, customer-marker match is
    skipped, first other hostname is accepted as the carrier hop → `reached`; then the delta
    latency override to `excluded-internal`.
  - `isLikelyMobileCarrierHostname` — substring keywords: `vzw, cellular, wireless, mobility,
    sprintpcs, sprint.net, tmobile, t-mobile, cingular, uscc, cricketwireless, boostmobile,
    metropcs`.
  - `runRange` — up to `maxAttempts` samples, keeps the best by `resultRank`, stops on a terminal
    status except a mobile-flagged `reached` (which keeps retrying); then the RDAP fallback.
  - `runRDAP`, `firstLine`, `randomAddrInRangeExcluding`, `randomAddrInRange` (big.Int, excludes
    the network and broadcast addresses when the range holds more than 2 addresses), `reverseDNS`
    (takes `names[0]`, strips the trailing dot), `writeResult`, `nullIfZero`, `derefAddr`,
    `derefStr`, `mtrTrace`, `flexFloat`, `ipv6Available`, `sampleTargets`.
  - `sampleTargets` — picks from `ip2city_dbiplite_tbl`, excludes `100.64.0.0/10` (RFC 6598
    CGNAT) outright and any network already terminal in the traceroute table (`reached` with a
    non-null hostname and `likely_mobile_cgnat = false`, or `unreachable`, or `status LIKE
    'excluded-%'`), optional `family(network)=4` and `country_iso_code` filters,
    `ORDER BY random() LIMIT $1`.
- **`geo/geo`** — committed static `linux/amd64` binary, rebuilt whenever `main.go` changed.
- **`geo/go.mod`, `geo/go.sum`** — added in `5c8f423`; dependency is `github.com/jackc/pgx/v5`.
- **`geo/traceroute_hostname_rules.sql`** — added in `1124743`, updated in `047b077`; the canonical
  idempotent migration (table + CHECK note + superseding DELETE + 5 CPE regex rows + the
  `rdap_lookup` column).
- **`rdap-lookup.sh`** — pre-existing, in `geo/`. Its contents are never shown in this slice.
- Boris's local layout (from his own commands): source at
  `~/geo/dbip-mmdb-import/traceroute-sample/main.go`, binary run as
  `~/geo/dbip-mmdb-import/bin/traceroute-sample`, logs written into `~/geo/dbip-mmdb-import/`.

Tables / columns:

- **`ip2city_dbiplite_tbl`** — read-only source of ranges. Columns used: `network` (cidr),
  `country_iso_code`.
- **`ip2city_dbiplite_traceroute_tbl`** — results, unique/conflict key `network`. Columns written:
  `network, sampled_ip, last_hop_ip, last_hop_hostname, last_hop_number, hop_count, status,
  probe_method, likely_mobile_cgnat, classification_note, attempts, rdap_lookup, ran_at`.
  **`rdap_lookup text` is NEW in this slice** and must be added by migration.
- **`traceroute_hostname_rules`** — `id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY`,
  `rule_type text NOT NULL CHECK (rule_type IN ('tld_exclude','domain_exclude','customer_marker',
  'customer_marker_regex'))`, `pattern text NOT NULL`, `status_label text`,
  `UNIQUE (rule_type, pattern)`. **`customer_marker_regex` is a NEW rule_type in this slice.**
- Status values in use: `reached`, `unreachable`, `incomplete`, `excluded-internal`, other dynamic
  `excluded-*` labels from rules (e.g. `excluded-mil`), `mtr_error: …`, `range_error: …`.

## Commands worth keeping

Migration, final consolidated form as handed over (also committed as
`geo/traceroute_hostname_rules.sql`):

```sql
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
-- not list 'customer_marker_regex', replace it (constraint name from \d traceroute_hostname_rules):
--   ALTER TABLE traceroute_hostname_rules DROP CONSTRAINT traceroute_hostname_rules_rule_type_check;
--   ALTER TABLE traceroute_hostname_rules ADD  CONSTRAINT traceroute_hostname_rules_rule_type_check
--       CHECK (rule_type IN ('tld_exclude','domain_exclude','customer_marker','customer_marker_regex'));

-- 2. Supersede the earlier IPv4-only fuse.net patterns (idempotent cleanup).
DELETE FROM traceroute_hostname_rules
 WHERE rule_type = 'customer_marker_regex'
   AND pattern IN ('^ip-[0-9-]+\.static\.fuse\.net$',
                   '^ip-[0-9-]+\.dynamic\.fuse\.net$');

-- 3. CPE regex rules. IP-token class [0-9a-f:-] covers IPv4 + IPv6.
INSERT INTO traceroute_hostname_rules (rule_type, pattern, status_label) VALUES
  ('customer_marker_regex', '^syn-[0-9a-f:-]+\.biz\.spectrum\.com$',                          NULL),
  ('customer_marker_regex', '^ip-[0-9a-f:-]+\.static\.fuse\.net$',                            NULL),
  ('customer_marker_regex', '^ip-[0-9a-f:-]+\.dynamic\.fuse\.net$',                           NULL),
  ('customer_marker_regex', '^h[0-9a-f:-]+(?:\.[0-9a-f:-]+)*\.dynamic\.ip\.windstream\.net$', NULL),
  ('customer_marker_regex', '^h[0-9a-f:-]+(?:\.[0-9a-f:-]+)*\.static\.ip\.windstream\.net$',  NULL)
ON CONFLICT (rule_type, pattern) DO NOTHING;

-- 4. Column for the RDAP ownership/location fallback (writeResult in main.go).
ALTER TABLE ip2city_dbiplite_traceroute_tbl ADD COLUMN IF NOT EXISTS rdap_lookup text;
```

Source delivery (the heredoc form Boris standardised on):

```bash
cat > ~/geo/dbip-mmdb-import/traceroute-sample/main.go <<'EOF'
…full main.go…
EOF
```

Boris's production invocation (the one that failed on the stale binary):

```bash
./bin/traceroute-sample -n 10000 -country US -concurrency 5 -ipv4-only 2>&1 | tee traceroute_us_$(date +%Y%m%d)_mtr_v7.log
```

Rebuild path recommended by the instance:

```bash
cd ~/geo/dbip-mmdb-import/traceroute-sample
go build -o ~/geo/dbip-mmdb-import/bin/traceroute-sample .
~/geo/dbip-mmdb-import/bin/traceroute-sample -h | grep ipv4-only   # sanity check
```

If that directory has no module yet:

```bash
cd ~/geo/dbip-mmdb-import/traceroute-sample
go mod init traceroute-sample
go mod tidy          # pulls github.com/jackc/pgx/v5
go build -o ~/geo/dbip-mmdb-import/bin/traceroute-sample .
```

Other commands named in prose: `go build ./...`, `go vet ./...`,
`git log --all --diff-filter=A` (used to prove `geo/` was never in history),
`./geo -n 30 -country US -ipv4-only` (example), `rdap-lookup.sh 4.2.2.2`.

## Traps and gotchas

1. **Substring matching of customer markers silently hid the correct answer.** `matchCustomerMarker`
   used `strings.Contains`, so the marker `cust.` matched inside the label `twelve99-cust` of
   `arizonastate-ic-373367.ip.twelve99-cust.net`. Telia's `*-ic-*.ip.twelve99-cust.net` nodes are
   **carrier interconnects that name the customer** — exactly the node we want — and they were being
   discarded as CPE, pushing the answer back to a backbone router in the wrong city. Fix: a marker
   only counts if it starts the hostname or immediately follows a `.`. This affected at minimum
   Cases 1 and 2, i.e. the whole `twelve99-cust.net` family.
2. **The "latency jump" check was not a jump.** `next.avgMs > 20.0` compared the next hop's
   *absolute* average while the comment claimed a delta. On any transcontinental path every terminal
   hop sits at 50–90 ms, so this fired on nearly everything and mass-produced bogus
   `excluded-internal`. Fix: `(next.avgMs - c.avgMs) > 20.0`. This single bug also explains Case 5
   (Comcast Seattle seen from Boston) and the note text changed from
   `long-haul latency jump at hop 14 (81.4ms)` to
   `long-haul latency jump after hop %d: +%.1fms to hop %d (%.1fms)`.
3. **Fixing only one of those two bugs would have looked like no fix at all.** With the marker fix
   alone, hop 14 gets accepted and then hop 15's ~80 ms absolute latency re-triggers the override,
   so the record stays `excluded-internal`. Verified by tracing the code against the real trace
   before changing anything.
4. **Stale binary silently lacking flags.** `./bin/traceroute-sample` rejected `-ipv4-only`; the
   giveaway was that its `-h` output also omitted `-rdap-script`, proving it predated Case 0. The
   repo source and the committed `geo/geo` both had the flags. There are now two binary locations in
   play (`~/geo/dbip-mmdb-import/bin/traceroute-sample` that Boris runs vs. `geo/geo` in the repo),
   and nothing keeps them in sync.
5. **Moving CPE rules into the DB turns a code fix into a data dependency.** After `1c96c13` the
   Case 3/4/6 fixes are *not* in the binary; if `traceroute_hostname_rules` lacks the
   `customer_marker_regex` rows, the classifier silently regresses to accepting CPE hostnames as
   carrier nodes. The instance flagged this twice.
6. **Do not lower-case a regex pattern on load.** `tld_exclude` / `domain_exclude` /
   `customer_marker` patterns are lower-cased, but `customer_marker_regex` must be compiled
   verbatim or metacharacters/classes get corrupted; the hostname is lower-cased instead before
   matching.
7. **An existing `CHECK` constraint blocks the new rule type.** `CREATE TABLE IF NOT EXISTS` will
   not alter an already-existing table, so if `traceroute_hostname_rules` predates this work its
   `rule_type` CHECK will reject `customer_marker_regex` inserts. The migration carries the
   commented `DROP CONSTRAINT` / `ADD CONSTRAINT` pair for that case; the constraint's real name
   must be read from `\d traceroute_hostname_rules`.
8. **The `rdap_lookup` column must exist before the new binary runs**, or every `writeResult`
   INSERT fails (the column is referenced unconditionally).
9. **Carriers encode customer IPs in PTRs two different ways.** Spectrum and fuse.net hyphenate
   (`syn-070-116-145-242.…`, `ip-…`), Windstream uses dot-separated labels
   (`h98.110.31.71.dynamic.ip.windstream.net`), so the Windstream pattern needs literal dots between
   tokens, not the hyphen class. Reusing the hyphen pattern would have silently failed to match.
10. **Spectrum vs Charter is the carrier/customer boundary** for that operator: `charter.com`
    hostnames are carrier equipment, `spectrum.com` ones of the `syn-<ip>.biz` form are the customer
    side.
11. **The instance's own first Case-3 test was wrong, not the code.** It asserted
    `syn-2607-fb90--1…` should match, but that string contains hex letters `f`/`b` which Boris's
    then-current spec (digits, hyphens, colons) excluded. The test was corrected to the spec rather
    than the regex widened silently — the widening happened only after Boris approved it.
12. **`CGO_ENABLED=0` changes DNS resolution semantics.** The committed static binary uses Go's
    pure-Go resolver, which reads `/etc/resolv.conf` and **ignores `/etc/nsswitch.conf`**. Rebuild
    with `CGO_ENABLED=1` if the libc resolver is needed. Asserted, not tested.
13. **`mtr` emits malformed JSON when the destination never responds at all**, and `mtrTrace`
    swallows that (`return nil, nil`), which lands as `incomplete` rather than an error. Described
    in a pre-existing code comment; not independently verified in this slice.
14. **`mtr` is run with `-n`**, so PTR lookups happen separately in Go. Hop 15 in the Case 1 trace
    (`206.207.226.105`) had no PTR even under Boris's DNS-enabled `mtr`, which is why hop 14 is
    genuinely the last resolved node.
15. **Hops 4 and 5 of the Case 1 trace showed 91.7% loss** (`…ALTER.NET`, `customer.alter.net`) yet
    the path continued fine — ICMP rate-limiting on intermediate routers, not a broken path. Nothing
    in the code keys off loss, but it is a reminder that per-hop loss is not evidence about the
    destination.
16. **Postgres string literals keep backslashes verbatim** with the default
    `standard_conforming_strings = on`, which is what makes the `\.` in the stored regexes correct.
    Called out explicitly in the migration comments.
17. **The nearest-resolved-hop-at-position-2-or-3 rule is terminal and ignores hostname content** —
    it returns `unreachable` regardless of what the hostname says. Pre-existing behaviour, not
    touched; worth knowing because it can pre-empt everything else.
18. **A chat reply was lost to a disconnect** with all the work already committed. The recovery
    pattern that worked: check `git status` / branch-vs-origin and grep the committed source for the
    expected changes before re-asserting anything.

## Boris's instructions, preferences and standing orders

- **Never fabricate source.** He supplied the real files rather than letting the instance guess
  (opening exchange), and the instance's refusal to invent `main.go` was the right call.
- **One issue at a time.** "We will consider errors in `ip2city_dbiplite_traceroute_tbl` one at a
  time to let you adjust the code for each one." He drives numbered Cases and expects a fix plus
  confirmation per case, then says "Ready for Case N".
- **Deliver source as a heredoc in chat, and post the binary to the repo.** "Post new source and
  binary of the Go code to the repository as main.go and here as a heredoc." The heredoc target path
  is **`~/geo/dbip-mmdb-import/traceroute-sample/main.go`** — he corrected the instance on this.
- **Issue the SQL too.** "Issue table creation SQL code"; later "Please hand me the migration";
  later "Post SQL code from the last two turns here, and the current Go code as a heredoc." He runs
  DDL himself; the instance never touches his database.
- **No unrequested tests committed.** The instance repeatedly wrote a temp test, ran it, then
  deleted it "per your no-unrequested-tests rule/norm". He never objected, so treat this as standing.
- **Domain-encoded location beats registry location.** For retail ISPs the ARIN/RDAP address is the
  ISP's headquarters, not the customer's city, so a resolvable last-carrier-node always wins and
  RDAP is strictly a last resort for `excluded-internal`.
- **Distinguish carrier-customer-edge nodes from CPE.** His recurring correction: a node that
  *names* a customer (`arizonastate-ic-…`, `cspire-ic-…`) is still carrier equipment and is the
  answer we want; a node whose hostname *encodes an IP address* is CPE and must be skipped.
- **CPE IP-address patterns must cover IPv4 and IPv6 generally:** "All IP address matches in CPE
  domain names should account for IPv4 and IPv6, so numerals, hyphens, colons and [a-f] hexadecimal
  digits should be allowed." Apply this to every new CPE pattern without being asked.
- **Expect static as well as dynamic CPE forms:** "Most ISPs offer static IPs to at least business
  customers" — add both variants.
- **Expect pattern families, not one-offs:** on Windstream, "We will have many such."
- He diagnoses causes himself and expects the instance to confirm or refute, not re-derive from
  scratch (Case 2 "I suspect it is the same pattern as Case 1 and fixed"; Case 5 "probably because
  the transcontinental trip from my location in Boston exceeded the former absolute latency limit").
  Both of his diagnoses were correct.
- Environment facts he stated: he is in **Boston**, on **Linux Mint** (`Immetrica-Mint30`,
  `192.168.1.3`), behind Verizon FiOS; **IPv6 now works** on his host, and he wants it excluded from
  traceroute-sample runs.

## Open items at end of slice

- **The `-ipv4-only` stale-binary problem is unresolved in-range.** The instance was mid-answer
  giving "Option A — rebuild from source" / "Option B — use the prebuilt binary from the repo" when
  line 4810 cuts it off. Whether Boris rebuilt, and whether the 10,000-range US run started, is not
  in this range.
- **The migration is handed over but never confirmed executed.** Nothing in this slice shows Boris
  running it. Until it runs: `rdap_lookup` may not exist (every write would fail), and the
  `customer_marker_regex` rows for Cases 3/4/6 may not exist (those fixes are inert).
- **PR #1 (`geo-rdap-excluded-internal-fallback`) is open and unmerged** as of the end of the range,
  carrying all five commits.
- **Case 7 and beyond not started.** The case stream was still running.
- **Known un-fixed design question raised in Case 0 and never resolved:** `excluded-internal` is
  produced both by an exclusion-rule hostname match and by the latency override. The override path
  *does* have a domain-resolvable carrier node, so under a strict reading of the precedence rule it
  arguably should not be RDAP'd — or should not be `excluded-internal` at all. The current gate
  RDAPs both. The instance flagged it and deliberately did not pre-fix it.
- **Offered but not acted on:** nothing else outstanding; both earlier offers (hex widening, DB-driven
  rules) were accepted and completed within the slice.
- **No `go.mod` in Boris's local `traceroute-sample` directory is suspected but unconfirmed** — the
  instance gave `go mod init` instructions conditionally ("If `go build` complains…").

## Uncertain

- **The contents of `rdap-lookup.sh` are never shown.** Only its output for `4.2.2.2` is quoted. Its
  output format (one line? several? what fields?) is therefore unknown beyond that one example, and
  `rdap_lookup` is stored as free text.
- **The pre-fix version of `main.go` is never printed in this range.** Everything about the original
  code is known only from the instance's descriptions of it and from the diffs implied by its
  edits — e.g. the original `next.avgMs > 20.0` line and the original substring
  `matchCustomerMarker`. Those two are stated plainly enough to trust; other pre-existing details
  are not independently visible.
- **The actual rows in Boris's `traceroute_hostname_rules`** (which `tld_exclude` /
  `domain_exclude` / `customer_marker` patterns exist, and how many) are never listed. `.mil →
  excluded-mil` and `alter.net → excluded-internal` appear only as code-comment examples; `res.`,
  `static.`, `cust.` appear only as marker examples. Do not assume the live rule set.
- **Whether `traceroute_hostname_rules` already existed in Boris's database** before this slice, and
  therefore whether the CHECK-constraint replacement is actually needed, is not stated. The
  migration was written to handle both.
- **The exact git/go/test command lines** the instance ran are not in the transcript (collapsed to
  `3 tools` / `Ran command` markers). Commit hashes and outcomes are stated in prose; the argv is
  not recoverable.
- **Whether the temporary test files were truly removed before each commit** is asserted by the
  instance each time but not shown as output.
- **The `[23/30]`, `[18/30]`, `[13/30]` log lines imply a 30-range run** on 2026/08/24, but the
  transcript never gives that run's command line or its aggregate results, so the overall error rate
  that motivated these cases is unknown.
- **The provenance of the `2026/08/24` vs `2026-08-25` dates** (log vs live mtr) is not explained;
  the dates are reproduced here exactly as printed and are a year ahead of a plausible real date,
  which the transcript does not comment on.
- **`geo/geo` vs `bin/traceroute-sample`**: whether the repo binary name `geo` and Boris's
  `traceroute-sample` are meant to converge is never stated.
