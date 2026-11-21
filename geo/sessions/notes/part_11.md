# Part 11 (lines 48101-52910)

> Steering note: handoff flows only TO the blocked session, never out of it, so no summary exists. I read every line of the assigned range via successive read_file calls (no grep-sampling). The slice is dominated by three very long machine progress-logs (a 7.99M-host DNS resolve, two RDAP passes, and an mtr landmark trace); the human/assistant narrative turns interleaved between them are all captured below. Transcript line-offset order does NOT equal conversation order, because the giant logs are pasted mid-conversation. I reconstructed chronology from the monotonically growing `lookup_status = true` count (11,726,561 → 11,753,212 → 12,775,630) and the git commit chain. Where ordering is my inference I say so.

## Narrative
This slice is the middle of Session 3's "landmarks" effort: enrich a unified `landmarks_usa` table from multiple POI/registry sources, classify which rows are "on-premises" (organisation hosts its own website at its own address), trace those addresses to a carrier node, and build a range→ZIP matching — the goal being ZIP-code geotargeting coverage, especially for sparsely populated ZIPs.

The slice opens at the tail of **RDAP pass A** (a ~7.99M-host DNS resolve finishing at 6,205,977 resolved, then RDAP of 53,235 distinct IPs → 47,733 ok / 5,502 failed), after which the chain's `overture-zip` and `onpremises` steps ran and `onpremises = true` reached 122,110. Wikidata was fetched (24,721 rows). The assistant then built an ip-api verification prober (`landmarks_ip_api.py`) using the free `/batch` endpoint, verified it, merged it (f963e55), and flagged that the 296,830 newly ingested Foursquare/OSM/IPEDS rows moved `onpremises=true` by only +1,956 (120,154→122,110) — a very low yield.

Next the assistant ran `landmark_gaps.sql` (confirming Wikidata was loaded but not yet migrated), migrated Wikidata in, re-resolved 5,548 new hosts, and ran **RDAP pass B** (57,707 IPs → 52,022 ok / 5,685 failed), reaching `onpremises=true` = 123,037. Boris then said "evaluate and reissue all subsequent commands… ingest/load/RDAP-resolve/ip-api-probe any sources not already done, then build the matching on last carrier node." The assistant built a CISA `.gov` loader (`dotgov`, 14,149 domains), **fixed `node_fanout.sql` to read `landmarks_usa` instead of `ovt_places_usa`** (a silent bug that made the hosting rule and the ip-api exclusion ignore every non-Overture landmark), merged ddc43c5, and issued a 7-step plan including a national OSM import.

Running that plan, Boris hit a `FileNotFoundError` on `filtered.geojsonseq`: the assistant had told him to `cd` into `landmark_sources` then pass a relative `--input`. The assistant acknowledged the error was its own instruction, added a PBF read-heartbeat and fixed a misleading `onpremises_true` column in `status`, merged 2aaf770, and reissued every step with absolute paths. Boris then corrected a mis-statement ("probe only onpremises=true", reiterating the prior plan), asked for research into school/library/local-government data sources and the probe service he half-remembered (RIPE Atlas), and complained that `ovt_resolve_hosts.py` was running with no progress indication — a standing preference. The assistant researched the CISA `.gov` registry (16,980 domains, strongly municipal), established there is **no national registry of school/library websites** (NCES CCD and IMLS have addresses but no URLs), analysed RIPE Atlas (useful for validation, too metro-clustered to fix density), added a heartbeat to `run_script`/`run_sql`, wrote `sparse_zip_sources.md`, and merged 225ac9d.

A larger **RDAP pass C** (122,953 records, projected 10 hours) prompted Boris to ask whether a 16-core server could go faster with more threads. The assistant measured ARIN's concurrency scaling (4→6.31, 32→10.73 calls/sec — badly sublinear), showed CPU was not the bottleneck, identified the TLS handshake as the real cost, and built a **native in-process RDAP client with per-thread keep-alive connections** (15/15 byte-identical to the shell script, ~2.9× single-thread), merging e23934e; it explicitly **retracted** an earlier proposal to cache ARIN network ranges as unsafe because ARIN allocations nest. Boris Ctrl-C'd and restarted; the assistant analysed the interrupt handler, then (after Boris noted the restart path had no feedback) found `query_csv` lacked the heartbeat, fixed it and labelled the pre-flight phases, merging 57a705c (PR #64). Boris then pasted the assistant's *example output* into bash, producing harmless syntax errors; the assistant clarified and recorded a learning to only put runnable commands in code blocks. Pass C finished (`true` = 12,775,630; `lookup error` = 0). Boris asked "Proceed to Step 4?"; the assistant said not yet — `registrants`/`overture-zip`/`onpremises` must run on the new rows first. The slice ends with a deploy from 57a705c and `last_carrier_node -source landmarks` tracing the 1,016 remaining untraced on-premises addresses (live mtr log).

## Decisions and rationale
- **ip-api prober targets `onpremises IS TRUE` only** — Boris reiterated the earlier plan ("No… Probe only onpremises=true"). The assistant had written a prose line implying all of `landmarks_usa`; it confirmed the code's `targets()` already selected `onpremises IS TRUE`. Accepted (code unchanged).
- **Use ip-api free `/batch` endpoint** (100 IPs/request, 15 req/min = 1,500/min) instead of single `/json` calls. Rationale: ~33× faster, and `/batch` and `/json` were measured to have **separate rate buckets** (X-Rl 12 vs 44 at the same moment), so a landmark probe won't contend with the production `probe_batch` budget. The repo comment claiming batch is paid-only was found out of date. Accepted.
- **Exclude hosting addresses from the ip-api compare by default** — ip-api reports the host's location, our ZIP reports the tenant's; counting that as disagreement would blame the pipeline for a mismatch correct on both sides. This is why Step 5 (hosting rule) must precede Step 6. Accepted.
- **`node_fanout.sql` must read `landmarks_usa`, not `ovt_places_usa`** — otherwise `address_hosting_tbl` (read by both the hosting rule and the ip-api exclusion) covers Overture only. Fixed. Accepted.
- **Build a native RDAP client with connection reuse; keep `--rdap-threads` at 4; keep the shell script as reference** (`--rdap-use-script` restores it). Rationale: TLS handshake was 68% of each call; more threads scale badly (server shaping). Accepted.
- **Do NOT build ARIN network-range caching** — the assistant proposed it as a big lever, then retracted it the same slice: ARIN allocations nest (a customer /24 sits inside a provider's wide parent), so caching the wide range and skipping inner IPs would return the provider instead of the customer — destroying exactly the distinction `onpremises` depends on. Self-rejected, explicitly "Don't build it."
- **Add a CISA `.gov` loader** (`dotgov`), selecting non-federal/local-government domains. Rationale: it's a registry of municipalities and small towns are municipalities — aimed at the sparse-ZIP gap. Accepted; honest caveat that CivicPlus/Revize vendor-hosting will make `onpremises` reject many.
- **Do NOT pursue more business-POI sources** — the yield analysis showed POI feeds are structurally poor landmark sources (businesses sit on Squarespace/Wix/GoDaddy; the registrant ZIP is the host's). Assistant recommendation; Boris did not override it.
- **RIPE Atlas is for validation, not density** — 2,376 US probes, metro-clustered; too few and too urban to raise coverage, but each probe is a subscriber at a known location, giving an independent check of the trace-to-carrier-node inference. Presented as recommendation.
- **Only runnable commands go in code blocks; expected output in prose/tables** — adopted after Boris pasted example output into bash. Recorded as a learning.
- **Two code fixes approved by Boris**: (1) narrow `deploy.sh`'s dirty-tree check so it fails on `.go`/`go.mod`/`go.sum` but not on stray data files like the error CSV, plus add the CSV to `.gitignore`; (2) make the `onpremises` base step preserve rows whose `onpremises_reason` starts with `hosting:`. Boris: "Approved." (Implementation within this slice not fully shown.)

## Measured facts and numbers
VERIFIED (runs whose output appears in the transcript):
- **DNS resolve (pass A input):** "7,994,314 hosts, 6,205,977 resolved to a global IPv4." Rows with ip_address: 12,603,738. does-not-resolve: 55,926 (+22 malformed); stale does-not-resolve cleared: 28,169.
- **RDAP pass A:** 53,235 distinct IPs, 47,733 succeeded, 5,502 failed. `lookup_status`: true 11,726,561; does not resolve 1,490,868; outside ARIN 871,668; lookup error 5,317; registrant not found 179; placeholder IP 13; no_website 10. registrant_1 11,760,198; registrant_2 201,029; registrant_1_zip 11,331,028; registrant_2_zip 176,251.
- **overture-zip A:** 293,609 candidate rows, 293,609 changed, 153s. overture_zip_source: postcode 11,524,488; none 186,008; locality 10,959; freeform 5,106.
- `isp_names` = 1,100; `provider_names` = 39 (both matched case-insensitively).
- **onpremises A:** 11,726,561 candidate rows in 35 chunks, 294,106 changed. false 11,418,443; NULL 186,008; true 122,110. (Chunk 7→8 jumped from 95s to 1,456s due to an intervening VACUUM.)
- **Wikidata fetch:** qlever reported 26,088 matching items; table "now holds 24,721"; "25,545 rows merged this run" (duplicate ids skipped per batch).
- **landmark_gaps.sql** (run at onpremises=122,110 state):
  - §1 not-imported: wikidata eligible 24,721 / imported 0; foursquare/nces_ipeds/osm/overture fully imported.
  - §2 per-stage: overture 13,797,786 rows / awaiting_zip 185,355 / onprem 119,675; foursquare 275,517 / awaiting_zip 653 / onprem 2,186; osm 15,238 / onprem 134; nces_ipeds 6,075 / onprem 327.
  - §3 by lookup_status: true 11,726,561 (459,327 distinct ips, onprem 122,110); does not resolve 1,490,868; outside ARIN 871,668 (88,752 ips, onprem 187); lookup error 5,317 (88 ips, onprem 25); registrant not found 179 (49); placeholder IP 13 (2); no_website 10.
  - §5: onpremises_places 122,322; distinct_addresses 28,616; distinct_zips 16,009; places_per_address 4.3.
  - §6 ZIP coverage: overture zips 15,959 (unique 15,315); foursquare 386 (46); nces_ipeds 311 (2); osm 63 (0).
  - §7 trace coverage: onprem_addresses 28,616; traced 27,254; not_traced 1,362; reached_a_node 21,189.
- **Migrate (wikidata in):** DELETE 13,797,786 / INSERT 13,797,786; DELETE 275,517 / INSERT 275,517; DELETE 21,313 / INSERT 46,034. Per source after migrate: overture 13,797,786 (onprem 120,154, have_ip 12,334,687, rdap_done 11,466,589, have_zip 11,281,262); foursquare 275,517 (0); wikidata 24,721 (0); osm 15,238 (0); nces_ipeds 6,075 (0). lm_places_usa all = 46,034.
- **Resolve (post-wikidata):** 5,548 hosts, 4,922 resolved. Rows with ip_address 12,626,678. does not resolve 57,707 (+22 malformed); stale cleared 28,169.
- **RDAP pass B:** 57,707 IPs, 52,022 succeeded, 5,685 failed. `lookup_status`: true 11,753,212; does not resolve 1,492,649; outside ARIN 872,957; lookup error 317; registrant not found 179; placeholder IP 13; no_website 10. registrant_1 11,782,444; registrant_2 201,641; registrant_1_zip 11,352,117; registrant_2_zip 176,837.
- **overture-zip B:** 315,855 candidate rows, 2 chunks (299,815 in 123s; 315,855 in 140s). postcode 11,551,083; none 186,061; locality 10,962; freeform 5,106.
- **onpremises B:** 11,753,212 candidate rows, 35 chunks, 316,467 changed. false 11,444,114; NULL 186,061; true 123,037.
- **dotgov loader:** 14,149 domains selected, 2,831 skipped (local-government filter); merged 14,149 (0 duplicates). `status` table: wikidata 24,721 rows/22,937 websites/10,206 zips/92.8% unique/0 onprem; osm 15,238/14,572/561/95.6%/0; dotgov 14,149/14,149/0/100.0%/0; nces_ipeds 6,075/5,411/4,241/89.1%/0.
- **.gov/wikidata yield (asserted from the above):** 296,830 new rows bought 48 ZIPs; Wikidata added 927 places from 24,721 rows (3.7%); coverage 16,009 of ~44,000 = 36.4% (essentially unchanged from 15,963 prior). Marked by the assistant as "a measured failure."
- **National OSM download:** `us-latest.osm.pbf`, 11.3 GB (shown "11.39 GB" in prose), downloaded in 20:18 (speeds ~9,802k–14.6M).
- **RDAP pass C final:** header "RDAP lookups for 122,953 records"; projected 10 hours ("11,300 in 2868s"). Final `lookup_status`: true 12,775,630; does not resolve 1,563,444; outside ARIN 918,822; registrant not found 182; placeholder IP 15; no_website 10. **`lookup error` absent = 0.** Deltas vs pass B stated by assistant: true +1,022,418; does not resolve +70,795; outside ARIN +45,865; lookup error 317→0. National OSM pass added 1,138,766 rows, 89.8% RDAP success.
- **Diagnostics after pass C deploy issue (D1–D4):**
  - D1: onpremises false 11,493,246 (431,613 distinct ips); NULL 3,644,505 (212,381); true 120,352 (28,459).
  - D2: trace_rows 28,524; onprem_v4_distinct 28,459. 4a remaining-to-trace = 1,016 → ~27,443 already traced (95%).
  - D3 per source (rows / ips / zips / onprem_rows / onprem_ips / onprem_zips): overture 13,797,786 / 542,583 / 38,430 / 119,989 / 28,439 / 15,954; osm 1,139,855 / 88,845 / 23,925 / 258 / 83 / 98; foursquare 275,517 / 44,685 / 707 / 78 / 50 / 32; wikidata 24,721 / 8,735 / 9,545 / 14 / 13 / 14; dotgov 14,149 / 6,095 / 1,904 / 4 / 4 / 4; nces_ipeds 6,075 / 3,070 / 3,999 / 9 / 9 / 9.
  - D4 onpremises dry-run rule breakdown: rule1 no Overture ZIP NULL 194,242; rule2 CDN/cloud/web-host registrant false 10,713,526; rule3a single ISP true 77,109; rule3b two ISP true 5,180; rule4 non-ISP ZIP matches true 30,706; rule5 non-ISP ZIP adjacent true 18,606; rule6a no non-ISP ZIP false 441,275; rule6b ZIPs differ/not adjacent false 1,294,986.
  - D4 yield: Rule 2 kills 10,713,526 of ~12.78M = 83.8%. New sources: 1,460,317 rows → 159 on-premises addresses = 0.011%; Overture's own yield 0.206% (~19× better per row). National OSM's 11.3 GB bought 83 addresses.
- **ARIN concurrency (sandbox, assistant's IP):** 4 threads 6.31 calls/s; 8 → 7.09 (+12%); 16 → 8.83 (+40%); 32 → 10.73 (+70%). Single-thread `rdap-lookup.sh` 0.21s/call = 4.7/s. Boris's pipeline at 4 threads ≈ 4.25/s. CPU: 5 lookups = 0.247s user CPU (~3 ms per jq spawn, 15 spawns each).
- **TLS handshake measurement:** 20 separate curls 3.833s = 0.192s/call; 1 curl reusing socket 0.121s = 0.006s/call (~32×). Per call: dns 0.001 / tcp 0.061 / tls 0.066 / setup 0.127 = 68% of the 0.188s total.
- **Native RDAP client:** 15/15 byte-identical to script; single-thread 4.92 → 14.36 IPs/s (~2.9×); sandbox 20,000 IPs in 227s = 88 IPs/s at 4 threads; end-to-end 0 rows differed in url_location or lookup_status. Interrupt-handler test: 1,000 IPs in 9s ≈ 111 IPs/s.
- **query_csv heartbeat restart test:** 600 rows, 399 already complete, looked up only 201 outstanding, left 399 untouched.
- **deploy:** built 13 tools, installed under /var/trugeo, from revision 57a705c; rdap-lookup.sh cksum 3459968002 (4609 bytes).
- **last_carrier_node (final):** "selected 1016 landmark addresses (country filter: '', ipv6 included: true, method: mtr-icmp, cycles: 5, max-attempts: 3)"; IPv6 probe available=true; classification rules 1 tld/10 domain/8 customer-marker/5 customer-marker-regex.

ESTIMATES / ASSERTIONS (not measured in-session):
- "~28,000 on-premises addresses take about 20 minutes" via /batch (projection).
- D6 discrepancy: D4 computes 131,601 on-prem rows vs D1's stored 120,352 → gap 11,249 (the assistant offered two unresolved hypotheses; see Open items).
- CISA .gov figures (via web research, not a DB run): 16,980 domains; 14,140 local gov (9,256 City, 2,724 County, 1,125 Special district, 289 Tribal); 54 states/territories; 9,170 distinct city/state pairs; per-state examples VT 94/87, ME 134/107, MT 114/80, SD 60/50, WY 63/38.
- RIPE Atlas: 2,376 connected US probes; 25.2M public traceroutes; 500 sampled probes fell in 149 one-degree cells (SF Bay 45, DC 32, Seattle 25, LA 24); 444/500 expose public IPv4; measurement API returns 401 without a key.
- NCES CCD: 52 fields, zero web/url fields, has `zip_location`. IMLS: 192 fields, only `WEBVISIT` (a visit count). E-Rate carries neither URL nor usable site field.
- ARIN range-nesting sample: 40 IPs → 28 distinct networks (30% "avoidable" before retraction).

## Code, files, tables
- `geo/landmarks/landmarks_ip_api.py` — ip-api verification prober (subcommands `create`, `check-budget`, `probe`, `probe --dry-run`, `compare`). Targets `onpremises IS TRUE`, probes distinct addresses not places, excludes hosting addresses by default, uses free `/batch` (100 IPs/req). Fixed a `CREATE TEMP TABLE (LIKE …)` bug: `LIKE` copies NOT NULL but not the DEFAULT, so `probed_at` failed. Merged f963e55.
- `geo/landmarks/landmark_gaps.sql` — diagnostic report (sections 1–7) showing per-source not-imported, per-stage gaps, why rows did not become landmarks, retryable RDAP failures, the landmark addresses to probe, ZIP coverage per source, and trace coverage. Merged f963e55.
- `geo/landmark_sources/lm_fetch.py` — gained `dotgov` subcommand (CISA registry loader; downloads `current-full.csv`, selects local-government domains, assigns no postcode by design — relies on the overture-zip locality fallback). Also: PBF read-heartbeat every 500,000 features; `osm-pbf` now emits a usable error instead of a traceback when `--input` is missing; `status` no longer prints a structurally-zero `onpremises_true` from the staging table. Merged across ddc43c5 / 2aaf770.
- `geo/node_fanout.sql` — changed to read `landmarks_usa` instead of `ovt_places_usa`; builds `address_hosting_tbl` and defines `zip_clusters()`. Merged ddc43c5.
- `geo/overture_fetch/ovt_resolve_hosts.py` — RDAP step rewritten to use a native in-process client with per-thread keep-alive HTTPS connections (default), `--rdap-use-script` reverts to the shell script, `--rdap-threads` (keep at 4). Added heartbeat to `run_script`/`run_sql` AND to `query_csv` (the distinct-IP selection scan that runs before any lookup); pre-flight phases now labelled ("Creating an index on ip_address…", "Refreshing lookup_status…", "Selecting distinct IPs still needing RDAP…"). Merged e23934e and 57a705c (PR #64).
- `geo/landmark_sources/sparse_zip_sources.md` — writeup of sources for sparse ZIPs (CISA .gov, lack of school/library URL registries, RIPE Atlas). Created ddc43c5/225ac9d.
- `geo/overture_fetch/create_table_ovt_places_usa_ip_trace.sql` — idempotent; adds four columns (hops, hop2_responded, hop2_miss_attempts, cpe_skipped) postdating earlier passes; verified safe on the populated table (4b).
- Tables referenced: `landmarks_usa` (unified landmark table, columns incl. `source`, `ip_address`, `overture_zip`, `overture_zip_source`, `lookup_status`, `registrant_1/2`, `registrant_1/2_zip`, `onpremises`, `onpremises_reason`); `lm_places_usa` (staging for lm_fetch sources); `ovt_places_usa_ip_trace` (trace results); `address_hosting_tbl`, `node_fanout_tbl`, `range2zip_tbl`, view `range2zip_usable_v` (built by `node_fanout.sql` / `range2zip.sql`); `isp_names`, `provider_names`.
- `geo/rdap-lookup/cmd/rdap-lookup.sh` — reference RDAP shell script (installed beside last_carrier_node by deploy.sh); verified it removes `/tmp/arin_payload.$$.json` on both success and curl-failure paths (no /tmp leak over 76k calls).

## Commands worth keeping
```
# 4a — real remaining on-premises trace count (mirrors the binary's selection exactly)
psql -d postgres -c "SELECT count(*) FROM (SELECT DISTINCT p.ip_address FROM landmarks_usa p WHERE p.onpremises = true AND p.ip_address IS NOT NULL AND NOT (p.ip_address <<= '100.64.0.0/10'::cidr) AND family(p.ip_address) = 4 AND NOT EXISTS (SELECT 1 FROM ovt_places_usa_ip_trace t WHERE t.ip = p.ip_address)) d;"

# D3 — per-source coverage incl. the decisive onprem_zips (slow: distinct counts over 15.2M rows)
psql -d postgres -c "SELECT source, count(*) AS rows, count(DISTINCT ip_address) AS ips, count(DISTINCT left(lpad(btrim(overture_zip),5,'0'),5)) AS zips, count(*) FILTER (WHERE onpremises) AS onprem_rows, count(DISTINCT ip_address) FILTER (WHERE onpremises) AS onprem_ips, count(DISTINCT left(lpad(btrim(overture_zip),5,'0'),5)) FILTER (WHERE onpremises) AS onprem_zips FROM landmarks_usa GROUP BY 1 ORDER BY 2 DESC;"

# D4 — which onpremises rule decides each true-status row (read-only dry run)
cd /home/boris/geo/src/claude/geo && python3 overture_fetch/ovt_resolve_hosts.py onpremises --table landmarks_usa --dry-run

# National OSM ingest (absolute paths — the relative-path version failed)
sudo apt install -y osmium-tool
cd /home/boris/geo && curl -L -O https://download.geofabrik.de/north-america/us-latest.osm.pbf
osmium tags-filter us-latest.osm.pbf -o filtered.osm.pbf nwr/website nwr/contact:website
osmium export filtered.osm.pbf -f geojsonseq --add-unique-id=type_id -o filtered.geojsonseq
python3 /home/boris/geo/src/claude/geo/landmark_sources/lm_fetch.py osm-pbf --input /home/boris/geo/filtered.geojsonseq

# The enrichment chain (each step skips completed work)
cd /home/boris/geo/src/claude/geo
python3 overture_fetch/ovt_resolve_hosts.py resolve      --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py rdap         --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py registrants  --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py overture-zip --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py onpremises   --table landmarks_usa

# Fan-out + hosting rule (ORDER MATTERS: node_fanout defines zip_clusters() and address_hosting_tbl)
psql -d postgres -f /home/boris/geo/src/claude/geo/node_fanout.sql
psql -d postgres -f /home/boris/geo/src/claude/geo/node_fanout_report.sql
psql -d postgres -f /home/boris/geo/src/claude/geo/landmarks/onpremises_hosting_rule.sql

# Unblock a dirty-tree deploy by moving (not deleting) the untracked error CSV out of the tree
mv /home/boris/geo/src/claude/geo/landmarks_usa_rdap_errors.csv /home/boris/geo/landmarks_usa_rdap_errors.csv
cd /home/boris/geo/src/claude && ./geo/pipeline/deploy.sh

# National trace of on-premises landmarks (-n is only a LIMIT; resumable via NOT EXISTS; ORDER BY random())
/var/trugeo/last_carrier_node/bin/last_carrier_node -source landmarks -landmark-table landmarks_usa -n 100000000 -concurrency 50
```

## Traps and gotchas
- **`node_fanout.sql` read the wrong table.** It referenced `ovt_places_usa`, so `address_hosting_tbl` covered Overture only — and because both the hosting rule and the ip-api prober's exclusion read that table, every non-Overture landmark was being silently ignored. Fixed to read `landmarks_usa`.
- **The onpremises revert hazard (most dangerous finding).** The base `onpremises` UPDATE is `SET onpremises = {case} WHERE {cond} AND ({case}) IS DISTINCT FROM onpremises`, with no guard for hosting rows. Re-running the Step-3 `onpremises` step after the Step-5 hosting rule **silently reverts every hosting exclusion back to true**. The hosting rule protects itself on the way in but the base step does not protect it on the way back. Rule: never run Step-3 `onpremises` after Step-5 without re-running Step-5 after it. (One of the two approved code fixes addresses this by preserving `onpremises_reason LIKE 'hosting:%'` rows.)
- **`CREATE TEMP TABLE (LIKE …)` drops DEFAULTs.** It copies NOT NULL but not the column DEFAULT, so `probed_at` inserts failed in the ip-api prober. Fixed.
- **Relative `--input` after a `cd` caused a `FileNotFoundError`.** The osmium steps had succeeded (the 11.3 GB file existed in `/home/boris/geo/`), but the loader was told to `cd` into `landmark_sources` and then given `--input filtered.geojsonseq`. Always use absolute paths. The loader now gives a readable error instead of a traceback.
- **`deploy.sh` aborts on ANY untracked file, including data.** It failed on the untracked `landmarks_usa_rdap_errors.csv`. Fix is to move the file out of the tree (not delete — it's data). Approved code fix narrows the check to `.go`/`go.mod`/`go.sum` and `.gitignore`s the CSV.
- **Threads are the wrong lever for RDAP.** The TLS handshake is 68% of each call; ARIN shapes concurrency (8× threads → only ~1.7× throughput). The real fix was per-thread connection reuse. The 5,502→5,317→317 "lookup error" sequence across pass A (initially read as ARIN rate-limiting) is now better explained as **TCP/TLS connection-setup failures under concurrency** — the native client produced zero lookup errors across 1.1M new rows in pass C. Marked "well-supported rather than proven."
- **ARIN network-range caching is unsafe.** ARIN nests allocations (customer range inside provider parent). Caching a wide range and skipping inner IPs would return the provider instead of the customer, degrading landmark detection while appearing to work.
- **`query_csv` had no heartbeat.** The RDAP restart path builds its work list with a `SELECT DISTINCT ip_address` over all ~14M rows before the first lookup — the assistant had added heartbeats to `run_script`/`run_sql` but missed `query_csv`, so a restart sat silent for minutes exactly when feedback was needed. Fixed; pre-flight phases now labelled.
- **psql reports nothing until a statement completes.** A 1,456-second VACUUM was indistinguishable from a hang. The heartbeat prints elapsed time every 15s; a percentage would be fabricated since psql can't report intra-statement progress.
- **Example output pasted as commands.** Boris pasted an illustrative fenced block into bash, producing `syntax error near '('` and `command not found`. No harm (no redirects/creates/destructive commands). Learning recorded: only runnable commands in code blocks.
- **Interrupt is clean for RDAP.** `ex.shutdown(wait=False, cancel_futures=True)` cancels queued work rather than draining it; with `--batch 100` the save writes at most 99 buffered rows, so Ctrl-C finishes almost immediately. A restart must wait for the old process to exit, because two concurrent RDAP runs would double the request rate against ARIN.
- **`onpremises` builds three UNLOGGED scratch tables and drops them in a `finally` block** — Ctrl-C leaves no debris (unlike the rdap step), losing only the current chunk.
- **`nces_ipeds` row count is suspect** (Boris): ~6,075 rows is far below the tens of thousands of US higher-ed institutions expected.
- **`last_carrier_node -n` defaults to 200.** An earlier Step-4 command omitting `-n` would have traced only 200 addresses and exited 0, looking like a completed national pass. (Flagged and corrected before it ran.)

## Boris's instructions, preferences and standing orders
- **Always add progress indication where possible** — "ovt_resolve_hosts.py now running without progress indication (which you should always add where possible)." Standing order.
- **Label every command** (e.g. D1/D2/4c) — "It is very difficult to keep track of individual commands without labeling." "Issue precise command."
- **Only runnable commands in code blocks; expected output in prose/tables** (after the bash-paste incident).
- **Probe only `onpremises = true`**, not all of `landmarks_usa` — reiterated explicitly.
- **Research more complete school databases** — the `nces_ipeds` count is too low.
- **Consider an address-to-ZIP resolver** (Google Maps / Google Search) to backfill ZIPs for records lacking them.
- **Consider the hardware-probe panel service** he half-remembered (assistant identified it as RIPE Atlas) given the insufficient-landmark problem.
- **On "sparse ZIPs"** he asked the assistant to explain the phrase, and suggested also checking **MX records and DNS servers**, which are sometimes on-premises even when the website is hosted elsewhere.
- Approved the two code fixes (deploy.sh dirty-check narrowing; onpremises hosting-row preservation).
- Priorities: honest measured assessment over optimism ("I'd rather say that now than after you download 11 GB"); resumability and not killing long-running jobs; coverage of less densely populated ZIPs is the central unmet goal.

## Open items at end of slice
- **`registrants`, `overture-zip`, and `onpremises` had NOT been run on the pass-C data** when the slice ended — the assistant told Boris not to proceed to Step 4 until they had. These three plus `lm_fetch.py status` were the immediate next commands.
- **D5 (unique-ZIP question) and D6 (discrepancy) were requested but their output is not in this slice.** D5: do the new sources' on-premises ZIPs fall inside Overture's 15,954? D6: why does D4's computed 131,601 on-prem rows exceed D1's stored 120,352 (gap 11,249)? Two unresolved hypotheses offered (a prior hosting-rule run left rows false; or the chunked update skips NULL-ip rows the dry run counts).
- **The national OSM-plus-dotgov enrichment chain, the fan-out rebuild, the ip-api probe/compare, and `range2zip.sql`** were all issued but their final results are not shown in this slice; the slice ends mid-trace of the 1,016 remaining on-premises addresses.
- The assistant flagged (not folded into the chain) two items from an earlier message: `pipeline/patch_probe_tbl_range_fields.sql` had still never been run, and a second landmark-sources memo in docx it had not read.
- **Address-to-ZIP resolver and MX/DNS-server on-premises checks** (Boris's suggestions) were acknowledged but not implemented in this slice.
- `871,668`/`918,822` "outside ARIN" rows remain unresolvable against ARIN (need RIPE/APNIC/LACNIC/AFRINIC); the script deliberately doesn't query them.

## Uncertain
- **Conversation ordering** is my reconstruction from the growing `lookup_status=true` counts and git chain; the transcript interleaves three huge machine logs, so I cannot be fully certain every assistant turn is placed in the exact order it occurred. The numeric facts themselves are quoted verbatim from the logs.
- The exact full diffs of the approved `deploy.sh` and `onpremises` code fixes are not shown in this slice (only described and approved); I cannot confirm from the text that they were committed within this range.
- Whether `landmarks_usa_rdap_errors.csv` held 7,633 error rows cumulatively or per-run: the transcript says it is appended across runs and "spans the previous run's 5,502 plus this one so far" — I did not see a definitive single-run count.
- The precise PR numbers for most merges are not stated; only PR #64 (query_csv heartbeat, commit 57a705c) and references to "PR #52" (rdap-lookup.sh install) appear. Commit SHAs cited: f963e55, ddc43c5, 2aaf770, 225ac9d, e23934e, 57a705c (and pulls through a15cdcb→1481fc3→f963e55→ddc43c5).
- The D6 discrepancy (11,249) was never resolved within this slice; the transcript does not say which hypothesis held.
- The RIPE Atlas / CISA / NCES / IMLS figures come from the assistant's web research mid-session; the transcript presents them as findings but I cannot independently verify them beyond what is quoted.
