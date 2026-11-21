# Part 02 (lines 4811-9620)

## Narrative

The slice opens mid-debug on the mtr-based `traceroute-sample` tool: Boris ran `./bin/traceroute-sample -n 10000 -country US -concurrency 5 -ipv4-only` and got `flag provided but not defined: -ipv4-only`. The instance diagnosed that the binary on disk was stale — the `-h` output lacked both `-ipv4-only` and `-rdap-script` — and that the `go build -o ~/geo/dbip-mmdb-import/bin/traceroute-sample .` line in the previous paste had not actually executed, so the old binary stayed in place and the subsequent run used it. Boris replied that he *had* re-applied the heredoc (so the source was current), and the instance pivoted to a self-diagnosing source→build→binary check block plus a fallback: download the prebuilt static `linux/amd64` binary committed in the repo at `geo/geo` (verified public, HTTP 200, sha256 `8f1e5a0c...15038`).

Boris then said he would send a list of domains that are CPE but unrecognized by the Go code, plus domains that are internal (do not disclose destination geography) but are wrongly credited as valid last-carrier equipment. The instance explained the mapping it would use (`customer_marker` / `customer_marker_regex` rows for CPE, `domain_exclude` with `status_label = 'excluded-internal'` for internal, all as DB rule data in `traceroute_hostname_rules`, no rebuild needed) and asked for real PTR examples. **That list was never sent** — the next message changed direction entirely.

Boris set aside the mtr method altogether. New approach: `curl http://ip-api.com/json/<IP>` returns a JSON geolocation that should be written into the identically-named fields of `ip2city_dbiplite_traceroute_tbl`, using the randomly selected IP per range as the queried address. He specified the free-tier constraint (more than 45 calls/minute causes refusal and, if persistent, a WAN-IP ban), that the paid tier will later allow batches and remove the limit, that the batch read/parse routines should be *arranged but not coded* (no format confirmation), that the rate window must anchor on the first call of each set of 45, and that total call count must be a program parameter.

The instance first wrote the tool as `geo/ipapi-geo/` (commit `2482cb6`), verified the struct against a live ip-api call, and supplied the `ALTER TABLE` migration for the geo columns. Boris redirected the layout to `/home/boris/geo/check_geo_ip-api` with `cmd` and `bin` subfolders, confirmed lowercase column names, issued a standing order to deliver all code as heredocs, and added a rule: set `likely_mobile_cgnat = true` when "Wireless", "Mobile" or "Cellular" appears in `isp` or `org`. The instance restructured (commit `9870e8d`) and flagged that the literal token "Mobile" does not match "AT&T Mobility".

Boris approved adding "Mobility", asked two research questions (does T-Mobile use a different string for fixed wireless; does a mobile device's IP change when it moves cells), and reported a `missing go.sum entry` build error. The instance answered both research questions, supplied the go.sum, and committed `bcf756a`. It then noted the keyword set still missed Sprint/MetroPCS/Cricket/Cingular, and Boris ordered coverage of all US mobile carriers plus a full heredoc. The instance built a documented `mobileISPKeywords` slice, discovered during its own test that a `google fi` token wrongly matched "Google Fiber" and removed it, and deliberately excluded bare `verizon`, `at&t`, `metro`, `dish`, `ting` because each has a fixed-line or unrelated sibling (commit `afb5d13`). It flagged C Spire as ambiguous (sells both mobile and fiber under one name); Boris told it to drop C Spire (commit `996d65b`) and to issue the run command.

Boris then reported that `DATABASE_URL` was visible through `echo` but the binary still errored. The instance diagnosed the classic export bug: `echo` sees unexported shell variables, but a child process inherits only exported ones, so `os.Getenv` returns empty and the program hits `log.Fatal("DATABASE_URL is not set")`. It gave `env | grep DATABASE_URL` as the discriminating test. Next, Boris reported that the sampled-IP column had been renamed from `sampled_ip` to `query` to align with the JSON schema; the instance removed `sampled_ip` from the writer entirely, renumbered the placeholders to `$1..$17`, and reissued the full heredoc (commit `5d72fa2`).

The second half of the slice is a new subsystem. Boris posted the `bgp_route_views` DDL he had already created and asked for code to populate it from University of Oregon RouteViews data — find the correct file and acquisition method, full download the first time, changes only thereafter, with the selection as a runtime option. The instance did live research against `archive.routeviews.org`, confirmed the directory layout and cadence, then validated an MRT parser (gobgp) in a scratch module *before* writing the tool. During validation it hit the key technical obstacle: updates files are MRT type 17 (`BGP4MP_ET`), which gobgp's `ParseMRTBody` rejects; the fix was to strip the leading 4-byte microsecond field and re-tag the record as type 16 (`BGP4MP`). With both RIB and updates parsing verified against live data, it wrote `geo/bgp_route_views` (commit `101e485`) and flagged two caveats: the per-peer row explosion, and that all DB write paths were compile/vet-verified only because there was no Postgres in its environment.

Boris hit three build problems in sequence — `go mod tidy` "matched no packages" (module was rooted at `cmd/`, he was building from the parent), then `no required module provides package` (his `go.mod` was a bare `go mod init` file with no `require` block) — both of which the instance fixed with exact heredocs. He then confirmed "dry-run ran correctly". He next asked for the ip-api tool to be re-pointed at `bgp_route_views` as `check_routeviews_ip-api` (commit `b75815a`), asked how to inspect `bgp_rv_ingest_state`, and asked what "one-row-per-prefix (origin dedupe)" meant.

The slice ends with the most consequential bug of the segment. Boris reported that the real `-mode full` load died after ten minutes with `COPY from stdin failed: ... use of closed network connection (Client.Timeout or context cancellation while reading body) (SQLSTATE 57014)`, and said he could not get past the single test peer already loaded. The instance correctly identified this as its own design bug rather than RouteViews flakiness: `http.Client{Timeout: 10 * time.Minute}` bounds the *entire* request including body read, and because `CopyFrom` streamed the HTTP body through the whole multi-tens-of-millions-row ingest, Go closed the socket mid-COPY at exactly the 10-minute mark. It fixed this by setting `Timeout: 0` and bounding only dial/TLS/response-header via a custom transport, and by downloading the RIB to a temp file first and COPYing from local disk. In the same change it made per-prefix dedupe the default (Boris's reasoning: geography does not depend on routing), with `-per-peer` to restore the old behaviour. Both modes were re-verified by live dry-run (commit `943797f`). The transcript cuts off partway through the reissued `main.go` heredoc.

## Decisions and rationale

- **Abandon the mtr/traceroute geolocation method in favour of ip-api.com.** Boris's decision, stated flatly ("We are going to set aside the mtr method"). No rationale given beyond the new source returning geography directly. The instance accepted and built a separate program rather than modifying the mtr sampler; the mtr tool was left untouched.
- **The pending CPE / internal-domain rule list was dropped.** The instance had prepared the mapping scheme and asked for PTR examples; Boris never sent the list because the method change superseded it. Not explicitly cancelled in the text.
- **Tool layout: `/home/boris/geo/check_geo_ip-api` with `cmd` and `bin` subfolders.** Boris overrode the instance's initial `geo/ipapi-geo/` placement. Accepted and restructured; the module ended up rooted at the tool directory for `check_geo_ip-api` but at `cmd/` for the later tools (see Traps).
- **All code delivered as heredocs, from now on.** Boris: "Reissue this and issue future code as heredocs." Standing order; the instance complied for every subsequent file.
- **Lowercase, JSON-aligned column names confirmed** (`countrycode`, `regionname`, `"as"` quoted as a reserved word). Boris accepted the instance's proposal rather than `country_code` / `region_name` / `as_info`.
- **`likely_mobile_cgnat` derived from ip-api `isp`/`org` text.** Boris's rule, originally "Wireless", "Mobile" or "Cellular". The instance implemented it literally, then reported that "Mobile" misses "AT&T Mobility"; Boris modified the rule to include "Mobility", then expanded it again to "all US mobile carriers".
- **Keyword-matching (not an ASN list) as the mobile-detection mechanism.** The instance's approach; never challenged. It deliberately excluded bare `verizon`, `at&t`, `metro`, `dish`, `ting` because of fixed-line/unrelated siblings (Verizon FiOS, AT&T Fiber, MetroNet, Dish satellite TV, "hosTING"), and dropped `google fi` after its own test showed it matched "Google Fiber".
- **Drop C Spire tokens.** The instance raised the conflict (C Spire sells mobile and fiber under one ownership string); Boris decided: drop it.
- **Batch mode for the paid ip-api tier is scaffolded, not implemented.** Boris's explicit instruction ("do not write their code as we don't have format confirmation"). `readIPBatch` / `parseBatchResponse` return "not implemented" errors with comments saying do not implement until verified against the live paid endpoint.
- **`sampled_ip` column removed; the sampled IP lives in `query`.** Boris's schema decision, to align with the JSON. He asked for a sed command or corrected heredoc; the instance argued a sed was too fragile (dropping a column forces renumbering every `$N` placeholder and the arg list) and delivered a corrected full heredoc instead. Boris did not object.
- **RouteViews collector `route-views2` as the default**, described by the instance as the canonical UO collector. Accepted by default; `-collector` is a flag.
- **Dedupe `bgp_route_views` to one row per prefix, as the default.** Boris's reasoning, quoted: "My only interest is the geographic location of the range. It doesn't depend on routing. Therefore, if this is true, deduplicate." The instance agreed, made dedupe the default (`peer_ip`/`as_path` written NULL, a representative `origin_asn` kept), and added `-per-peer` to restore one row per (prefix, peer). It noted the cost: loss of multi-vantage detail useful for spotting hijacks / MOAS (multiple-origin-AS) conflicts. This overrode the original per-peer loader design from commit `101e485`.
- **In deduped updates mode, withdrawals are counted but not applied.** The instance's call: one peer withdrawing a prefix does not mean the prefix is globally gone, and geography is stable. Not explicitly ratified by Boris within this slice.
- **Download the RIB to a temp file, then COPY from local disk** rather than streaming HTTP straight into `CopyFrom`. The instance's fix, to decouple the slow DB ingest from the network so a long COPY can never stall or time out the download.
- **`http.Client.Timeout = 0`, with bounds moved to dial / TLS handshake / response headers.** The instance's fix for the mid-COPY disconnect; `-http-timeout` was redefined to mean connection + header timeout (default 2m) and a new `-download-timeout` (default 30m) added.
- **`check_routeviews_ip-api` drops the `-country` flag.** The instance's decision, because `bgp_route_views` has no country column. The destination table stays `ip2city_dbiplite_traceroute_tbl` keyed by `network` = the prefix.
- **Offered but not decided in this slice:** a built-in scheduler loop for `-mode updates` versus cron. The instance proposed cron every 15–30 min; Boris did not answer.

## Measured facts and numbers

- ip-api free-tier limit, as stated by Boris: more than **45 calls per minute** causes service refusal; persistent overage causes a ban by WAN IP address. Default `-rate` is `45`.
- Boris's sample ip-api response for `72.3.173.193` (verbatim values): country "United States", countryCode "US", region "GA", regionName "Georgia", city "Hiram", zip "30141", lat **33.8683**, lon **-84.7736**, timezone "America/New_York", isp "Rackspace Hosting", org "185Red, Inc", as "AS33070 Rackspace Hosting". The instance confirmed by live call that the struct parses this exactly.
- **Estimate** (not a measurement): 10000 ip-api calls at 45/min ≈ **222 min ≈ 3.7 hours** (`10000 ÷ 45`).
- Prebuilt `geo/geo` static `linux/amd64` traceroute-sample binary sha256: `8f1e5a0c88259fc9bfc6c1cd42bb3091cefa4d79604832d32ca2e6f789c15038`. Repo confirmed public, `geo/geo` reachable **HTTP 200**.
- `check_geo_ip-api` binary sha256 by commit: `bcf756a` → `6c130b69ce75e848983f409a601d17b1af95ee39495e895d797ea6e14e176b39`; `afb5d13` → `9122c9ec2a7343d1903a4218d5ad49410c51b48ba51210b04b1c0f72f8d6c561`; `996d65b` → `c483fece3438aaf26f074b39d7e7f065d6301305c1d8116301ca4ef3971246da`; `5d72fa2` → `18b353743602853d32709159a667b892d32749b81742a7e85369b14376604112`.
- `bgp_route_views` binary sha256 at commit `101e485`: `8c492a65f71412eafb9dd198b7433a0c1e77dd3660e5573a7ea6a4b09932a9be`. No sha256 was given for `943797f`.
- RouteViews cadence, verified live by the instance: RIB snapshots **every ~2 hours**, UPDATES files **every 15 minutes**. Filenames are UTC.
- **Estimate** of the per-peer full-load row count for route-views2: "~1M+ IPv4 + ~200k IPv6 prefixes × ~28 peers ≈ tens of millions of rows"; later restated as "~30M". Single-peer load estimated at **~1.2M rows**. Deduped load estimated at **~1M rows**. All of these are estimates; no actual loaded row count appears in this slice.
- Example given for the per-peer explosion: `8.8.8.0/24` yields ~28 rows, all with origin **15169**, differing only in `peer_ip`/`as_path`.
- The failed full load (measured from Boris's paste): started **2026/08/31 08:27:02**, failed **08:37:03** — exactly **10 minutes**, matching the `http.Client{Timeout: 10 * time.Minute}`. RIB being loaded: `rib.20260831.1200.bz2`, file timestamp `2026-08-31T12:00:00Z`. Error: `COPY: ERROR: COPY from stdin failed: read tcp [2600:4040:5790:7800:c6d1:509a:51b5:9d9c]:50876->[2001:468:d01:33::80df:3314]:80: use of closed network connection (Client.Timeout or context cancellation while reading body) (SQLSTATE 57014)`.
- Dependency versions pinned: `github.com/jackc/pgx/v5 v5.10.0`, `github.com/osrg/gobgp/v3 v3.37.0`, `go 1.25.1`, indirect `github.com/jackc/pgpassfile v1.0.0`, `github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761`, `golang.org/x/text v0.29.0`, `golang.org/x/sync v0.17.0`.
- Instance-reported cost per turn ("Est. Credits Used" / "Elapsed Time"), largest entries: RouteViews tool build **28.29 credits / 12m 41s**; `check_routeviews_ip-api` **12.20 / 5m 16s**; first ipapi tool **9.68 / 6m 28s**; all-US-carriers keyword expansion **9.11 / 4m 1s**; layout restructure **8.39 / 3m 47s**.
- T-Mobile fixed wireless rides **AS21928 T-Mobile USA, Inc.** — same AS/ownership string as phones, per the instance's web research (presented as research finding, not a measurement against Boris's data).

## Code, files, tables

Everything committed to branch **`geo-rdap-excluded-internal-fallback`** of `borislevitanimmetrica/claude`.

- `geo/ipapi-geo/` (commit `2482cb6`) — the first draft of the ip-api tool. Superseded by `check_geo_ip-api`; the transcript does not say it was deleted.
- `~/geo/check_geo_ip-api/cmd/main.go` (repo `geo/check_geo_ip-api/cmd/main.go`) — samples one random IP per range from `ip2city_dbiplite_tbl`, calls `http://ip-api.com/json/<IP>`, upserts into `ip2city_dbiplite_traceroute_tbl`. Key functions: `sampleRanges` (random order, `city IS NULL` not-exists check, excludes `100.64.0.0/10`, optional `family(network)=4` and `country_iso_code` filter), `lookupGeo` (single GET, honours HTTP 429 `X-Ttl` with one retry), `parseTTLSeconds`, `isMobileISP` + `mobileISPKeywords`, `writeGeo` (the upsert), `nullIfEmpty`, `randomAddrInRange` (crypto/rand big.Int walk, excludes the first and last address when the range has more than 2), plus the unimplemented `readIPBatch` / `parseBatchResponse` stubs. Flags: `-count` (required), `-rate` (45), `-country`, `-ipv4-only`, `-http-timeout` (10s), `-endpoint`.
- `~/geo/check_geo_ip-api/go.mod`, `~/geo/check_geo_ip-api/go.sum` — module `check_geo_ip-api`, pgx only. (For this tool the module root is the tool dir, not `cmd/`.)
- `~/geo/check_geo_ip-api/schema.sql` — `ALTER TABLE ip2city_dbiplite_traceroute_tbl ADD COLUMN IF NOT EXISTS` for `country`, `countrycode`, `region`, `regionname`, `city`, `zip` (text), `lat`, `lon` (double precision), `timezone`, `isp`, `org`, `"as"`, `query` (text).
- `ip2city_dbiplite_traceroute_tbl` — destination table, shared with the retired mtr tool. New ip-api columns above. `sampled_ip` was **renamed to `query`** by Boris; `probe_method` is written as `'ip-api'` for provenance; `status` holds `success` / `fail` / `error`; `classification_note` holds the ip-api `message` or the transport error; `hop_count` and `attempts` are written as 0 on INSERT only (to satisfy NOT NULL) and left untouched on UPDATE so existing mtr hop data is not clobbered; `likely_mobile_cgnat` is refreshed on every write; `ran_at` set to `now()`. Conflict target is `(network)`.
- `bgp_route_views` — table created by **Boris** before the code existed: `id SERIAL PRIMARY KEY, cidr_block INET NOT NULL, start_address INET NOT NULL, end_address INET NOT NULL, origin_asn BIGINT, peer_ip INET, as_path TEXT, updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP`.
- `bgp_rv_ingest_state` — created automatically by the loader: `collector text PRIMARY KEY, last_file_ts timestamptz NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()`. Tracks the newest RouteViews file applied per collector, so `-mode updates` resumes.
- `bgp_route_views_cidr_peer_idx` — `CREATE INDEX IF NOT EXISTS ... ON bgp_route_views (cidr_block, peer_ip)`, created inside the full-load transaction to make updates-mode per-(prefix,peer) deletes feasible.
- `~/geo/bgp_route_views/cmd/main.go` (+ `go.mod`, `go.sum`; binary at `~/geo/bgp_route_views/bin/bgp_route_views`) — RouteViews MRT ingester. Notable parts: `eachMRT` (12-byte header read, BGP4MP_ET→BGP4MP normalisation, skips undecodable record types rather than aborting), `ribIterator` implementing `pgx.CopyFromSource` for streaming COPY, `buildRows`, `originAndPath` (handles both `As4PathParam` 4-byte and `AsPathParam` 2-byte encodings; origin = last ASN in the path), `nlriPrefixes` (generic over anything with `String()`, because `upd.NLRI` is `[]*bgp.IPAddrPrefix` while MP-NLRI is `[]bgp.AddrPrefixInterface`), `prefixRange` (CIDR → first/last host address via big.Int, IPv4 and IPv6), `listArchive` (regex `(rib|updates)\.(\d{8}\.\d{4})\.bz2` against the autoindex HTML), `monthDir`, `latestRIB` (current month, falls back to previous), `updatesSince` (month-by-month walk from `since` to now), `ensureStateTable` / `setState` / `getState`, `parseSince` (accepts `20060102.1504` or RFC3339), `downloadToTemp`, `nullASN` (0 → NULL), `nullStr`. Flags after `943797f`: `-mode` (`full`|`updates`, default `updates`), `-collector` (`route-views2`), `-archive-url`, `-since`, `-peer`, `-per-peer`, `-dry-run`, `-limit`, `-http-timeout` (now connection+headers, 2m), `-download-timeout` (30m).
- `~/geo/bgp_route_views/schema.sql` — mentioned as added in commit `101e485`; its contents are not shown in this slice.
- `~/geo/check_routeviews_ip-api/cmd/{main.go,go.mod,go.sum}` + `bin/check_routeviews_ip-api` (commit `b75815a`) — `check_geo_ip-api` re-pointed at `bgp_route_views` as the source of ranges. `sampleRanges` becomes `SELECT DISTINCT cidr_block::text, start_address, end_address FROM bgp_route_views WHERE NOT (cidr_block <<= '100.64.0.0/10'::cidr)` (plus optional `family(cidr_block)=4`), wrapped in a `NOT EXISTS` check against `ip2city_dbiplite_traceroute_tbl` where `tr.network::text = d.cidr AND tr.city IS NOT NULL`, `ORDER BY random() LIMIT $1`. `-country` removed. Everything else identical.
- `rdap-lookup.sh` — referenced as the default of the mtr tool's `-rdap-script`; auto-disables with a warning if absent. Not touched in this slice.
- `geo/traceroute_hostname_rules.sql` and the `traceroute_hostname_rules` table (`customer_marker`, `customer_marker_regex`, `domain_exclude`, `status_label`, `rdap_lookup` column from an earlier migration) — described but **not modified** in this slice, since the rule list never arrived.

## Commands worth keeping

Build and run the ip-api tool (module root is the tool dir for this one):

```
cd ~/geo/check_geo_ip-api
go mod tidy
go build -o bin/check_geo_ip-api ./cmd
DATABASE_URL='postgres://USER:PASS@HOST:5432/DBNAME' ./bin/check_geo_ip-api -count 20 -country US -ipv4-only
```

Long ip-api run, backgrounded so it survives a disconnect:

```
cd ~/geo/check_geo_ip-api
DATABASE_URL='postgres://USER:PASS@HOST:5432/DBNAME' \
  nohup ./bin/check_geo_ip-api -count 10000 -country US -ipv4-only \
  > check_geo_us_$(date +%Y%m%d).log 2>&1 &
tail -f check_geo_us_$(date +%Y%m%d).log
```

Discriminating test for the exported-variable bug:

```
env | grep DATABASE_URL
```

Build the RouteViews loader (module root is `cmd/` for this tool):

```
cd ~/geo/bgp_route_views/cmd
go build -o ../bin/bgp_route_views .
ls ~/geo/bgp_route_views/cmd    # should show: go.mod  go.sum  main.go
```

RouteViews dry-run (no DB, no DATABASE_URL needed) — this is what Boris confirmed ran correctly:

```
~/geo/bgp_route_views/bin/bgp_route_views -mode full -dry-run -limit 8
```

RouteViews loads:

```
DATABASE_URL='postgres://…' ~/geo/bgp_route_views/bin/bgp_route_views -mode full
DATABASE_URL='postgres://…' ~/geo/bgp_route_views/bin/bgp_route_views -mode updates
```

Inspect ingest state (Boris asked for this explicitly):

```
psql "$DATABASE_URL" -c "TABLE bgp_rv_ingest_state;"
```

```sql
SELECT collector, last_file_ts, updated_at,
       now() - last_file_ts AS lag
FROM bgp_rv_ingest_state
ORDER BY collector;
```

Post-load checks suggested:

```sql
SELECT count(*) FROM bgp_route_views;
SELECT count(*), max(updated_at) FROM bgp_route_views;
```

Build and run the RouteViews-sourced ip-api tool:

```
cd ~/geo/check_routeviews_ip-api/cmd
go mod tidy
go build -o ../bin/check_routeviews_ip-api .
DATABASE_URL='postgres://…' ../bin/check_routeviews_ip-api -count 20 -ipv4-only
```

Fetch and verify the prebuilt mtr sampler binary (fallback path, not ultimately used):

```
cd ~/geo/dbip-mmdb-import
curl -fsSL -o bin/traceroute-sample \
  https://raw.githubusercontent.com/borislevitanimmetrica/claude/geo-rdap-excluded-internal-fallback/geo/geo
chmod +x bin/traceroute-sample
sha256sum bin/traceroute-sample
./bin/traceroute-sample -h 2>&1 | grep -E 'ipv4-only|rdap-script'
```

## Traps and gotchas

- **The 10-minute COPY death. This is the most important item in the slice.** `http.Client{Timeout: 10 * time.Minute}` bounds the *whole* request including reading the response body. The RouteViews full load streamed the HTTP body directly into `pgx.CopyFrom`, so the body read stayed open for the entire multi-tens-of-millions-row ingest, crossed the deadline, and Go closed the socket mid-COPY. The Postgres-side error (`use of closed network connection ... SQLSTATE 57014`) reads like a database or network fault and completely masks the real cause. Fix: `Timeout: 0` plus a `http.Transport` with `DialContext` timeout 30s, `TLSHandshakeTimeout` 30s, `ResponseHeaderTimeout` (`-http-timeout`, 2m) and `IdleConnTimeout` 90s — bounding only setup and time-to-first-byte, never the transfer — and download the RIB to a temp file first (`-download-timeout`, 30m), then COPY from local disk. Boris initially attributed the failure to "network failure or times out because of transient unavailability"; it was neither.
- **A failed `go build` leaves the old binary in place and the next run silently uses it.** This produced the opening `flag provided but not defined: -ipv4-only` confusion. Always verify the *built* binary's flags (`./bin/tool -h | grep <newflag>`) before trusting a run, and treat `&&`-chained build+run as mandatory.
- **MRT type 17 (`BGP4MP_ET`) is rejected by gobgp's `ParseMRTBody`.** RouteViews UPDATES files use it. `BGP4MP_ET` is just `BGP4MP` (type 16) with a 4-byte microsecond field prepended: strip 4 bytes from the body, set `h.Type = mrt.BGP4MP`, and `h.Len -= 4`. Without this, updates parsing fails outright while RIB parsing looks fine — so the bug only appears in incremental mode.
- **`go mod init` writes no `require` block.** Boris's `cmd/go.mod` was bare, so dropping in a correct `go.sum` was not enough — `go build` still reported `no required module provides package github.com/jackc/pgx/v5`. A `go.sum` alone never adds requirements.
- **`go mod tidy` "matched no packages"** means you ran it from a directory whose `go.mod` sees no `.go` files. In this repo the `bgp_route_views` and `check_routeviews_ip-api` modules are rooted at `cmd/`, not at the tool directory — a nonstandard layout. Related hazard: a stray second `go.mod` in the parent will confuse the build; there must be exactly one.
- **`echo $DATABASE_URL` proves nothing about whether a child process can see it.** `echo` prints unexported shell variables too; the binary inherits only exported ones. `DATABASE_URL=val ./binary` works; `DATABASE_URL=val` on its own line without `export`, followed by `./binary`, does not. Use `env | grep DATABASE_URL` to tell the two apart.
- **Substring keyword matching for mobile carriers has collisions in both directions.** Verified false positives the instance caught in its own test: `google fi` matches "Google Fiber" (token removed; Google Fi egresses via its host MNO anyway, so `mobile`/`cellular` already catch it); `ting` matches "hosTING". Deliberately excluded for the same reason: bare `verizon` (FiOS), `at&t` (Fiber), `metro` (MetroNet fiber), `dish` (satellite TV). Verified false negative: the literal token `Mobile` does **not** match "AT&T Mobility" — hence the separate `mobility` keyword. Unresolved residual risk: C Spire sells mobile and fiber under one ownership name, which is why its tokens were dropped — meaning C Spire mobile ranges now go unflagged.
- **A mobile IP does not identify a cell.** Per the instance's research: the public address is assigned by the carrier's packet-core gateway (GGSN / PGW / UPF), not per tower, and handovers between cells preserve it; it changes when crossing into a different gateway's region, or on reconnect / lease expiry / airplane-mode toggle / reboot from shared CGNAT pools. Consequence for TruGeo: a mobile IP geolocates to the carrier's gateway hub, not the subscriber's city, so `city`/`lat`/`lon` for those rows are unreliable. That is exactly what `likely_mobile_cgnat = true` is meant to warn about.
- **Dropping a column is not a safe `sed` target.** Removing `sampled_ip` forced renumbering of every `$N` placeholder and the positional arg list; a textual substitution would have produced a silently misaligned INSERT. The instance refused the sed and reissued the file.
- **Type note after the `sampled_ip` → `query` rename:** if done via `ALTER TABLE ... RENAME COLUMN`, `query` keeps the original type (likely `inet`). The writer sends the IP as a string, which Postgres assignment-casts to `inet` for valid addresses, so either `text` or `inet` works.
- **`SELECT DISTINCT ... ORDER BY random()` over `bgp_route_views` scans the whole table.** The instance flagged this as acceptable occasionally but not free on tens of millions of rows.
- **The instance hand-transcribed one `go.sum` hash line and warned it may have mangled it**, recommending `go mod tidy` instead of pasting, with `rm go.sum && go mod tidy` as the recovery. Treat all pasted `go.sum` blocks in this transcript as suspect.
- **`/tmp` is not persistent between the instance's tool calls** — only `/projects/sandbox` is. This broke its first scratch module for MRT-parser validation.
- **`%!q(<nil>)` in the dry-run log** is just `%q` formatting a Go nil; the value written to the DB is a proper NULL. Not a bug.
- **Even with a pinned `go.sum`, the first build needs network** to populate the module cache.
- **Boris's ip-api rate rule is anchored, not sliding:** the window starts at the first call of each set of 45, and the program sleeps the remainder of that minute. The implementation is deliberately sequential (not concurrent) so the window stays exact. HTTP 429 handling with `X-Ttl` backoff is extra insurance on top, not the primary mechanism.

## Boris's instructions, preferences and standing orders

- **Issue all code as heredocs**, now and in future ("Reissue this and issue future code as heredocs"). Also: "Full heredoc again" when a function-level patch was offered instead.
- **Place files where he specifies**, with `cmd` and `bin` subfolders (`/home/boris/geo/check_geo_ip-api`, `~/geo/check_routeviews_ip-api`). He overrode the instance's own directory choice.
- **Do not write code for unconfirmed formats.** On the paid ip-api batch mode: "Arrange routines to read a batch of IP addresses and parse a batch JSON response (do not write their code as we don't have format confirmation)."
- **Fix the blocker before moving on.** On the RouteViews load failure: "Resolve first, then continue."
- Column naming follows the upstream JSON schema, lowercased; he renamed `sampled_ip` to `query` specifically "to align with the JSON schema".
- He reasons from what the data is actually for and prunes accordingly: "My only interest is the geographic location of the range. It doesn't depend on routing. Therefore, if this is true, deduplicate." Note the conditional — he asked the instance to confirm the premise, not just obey.
- He asks for research rather than assumption: whether T-Mobile uses a different string for fixed wireless, and whether a mobile device's IP changes when it moves between cells.
- When the instance offered a partial carrier list, he demanded completeness: "Yes, all US mobile carriers."
- He wants explicit run commands, not just build instructions ("Issue command to run the binary").
- He asks for clarification when a proposal is stated in jargon ("Clarify what you mean by 'One-row-per-prefix (origin dedupe)…'") and for the means to inspect state he cannot see ("How to check `bgp_rv_ingest_state`?").
- He pre-creates schema himself and expects code to match it (he posted the `bgp_route_views` DDL as a fait accompli).
- He plans to upgrade to the paid ip-api tier, which removes the rate limit and allows batch queries; the free-tier limiter is an interim measure.

## Open items at end of slice

- The reissued `bgp_route_views/cmd/main.go` heredoc was **cut off mid-file** (inside the `applyUpdatesFile` doc comment, around the per-peer/dedupe branch description). The full post-`943797f` source was not delivered within this line range — it is in the repo at commit `943797f`.
- The deduped `-mode full` load had **not yet been run successfully** against the database. The fix was committed and dry-run-verified, but no real load, no row count, and no `bgp_rv_ingest_state` row are reported in this slice. Boris was still stuck at "the one peer already loaded as a test".
- `-mode updates` had never been exercised against the database at all.
- The CPE / internal-domain rule list Boris promised was never sent; `traceroute_hostname_rules` was not updated.
- The paid ip-api batch mode remains stubbed, awaiting the confirmed request/response format.
- The instance's offer of a built-in scheduler loop for `-mode updates` (versus cron every 15–30 min) was never answered.
- No evidence in this slice that `check_geo_ip-api` or `check_routeviews_ip-api` was ever run to completion against the DB. The longest confirmed ip-api exercise is the instance's own single live call plus unit tests; Boris's runs were all blocked on build or environment errors within this range.
- The instance's C Spire caveat stands open: C Spire mobile ranges will not be flagged as mobile.
- Whether `geo/ipapi-geo/` (the superseded first draft) was removed from the repo is not stated.

## Uncertain

- The transcript does not say whether the `ALTER TABLE ip2city_dbiplite_traceroute_tbl ADD COLUMN ...` migration was actually applied to Boris's database; it was supplied as a heredoc/`schema.sql` and described as "run before first use".
- The transcript does not say whether the `rdap_lookup` column migration or the Spectrum/fuse/Windstream CPE regex rules were ever applied — the instance repeatedly reminded Boris about them, with no confirmation either way.
- When Boris said the binary "errors" on `DATABASE_URL`, he pasted the `cat > main.go` heredoc instead of the error output. The actual error text is not in the transcript, so the export-vs-non-export diagnosis was never confirmed.
- The contents of `~/geo/bgp_route_views/schema.sql` are not shown.
- No actual row count for any `bgp_route_views` load appears. The "one peer already loaded as a test" is mentioned by Boris but its row count, peer IP, and whether it is still in the table after the `TRUNCATE`-on-full-load behaviour are not stated.
- The system clock in the transcript reads **2026** (`2026/08/31`, `rib.20260831.1200.bz2`, archive path `bgpdata/2026.08/`). I cannot tell whether that is the real date or a skewed clock on Boris's machine and in the sandbox.
- The instance's claim that `route-views2` is "the canonical UO collector" is asserted, not shown to be verified against a list of collectors.
- Whether the C Spire, Google Fi and `ting` exclusion reasoning matches Boris's real data is untested — those were reasoned from carrier naming, not measured against observed `isp`/`org` strings in his table.
- The instance stated the `bgp_route_views` DB write paths (COPY / INSERT / state SQL) were "compile- and vet-verified only" because no Postgres existed in its environment. After Boris's failed load, only the HTTP/timeout path was proven; the COPY path itself is still unverified end to end.
