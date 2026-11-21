# Part 10 (lines 43291-48100)

Read in full via successive `read_file` offset/limit calls across the whole range (no grep-sampling). Steering noted: there is no handoff out of the blocked session, so these notes are the only record of this slice.

Note on range shape: roughly the last 1,800 lines of this range (≈46,290 onward) are a single pasted terminal log — the per-2,000-host progress lines of `ovt_resolve_hosts.py resolve --table landmarks_usa`. It carries real measurements (see below) but no dialogue.

## Narrative

The slice opens at the tail of a `geo/mobile_transit_migration.sql` run: the `mobile_transit` column now exists on four tables, the backup table still carries the old `likely_mobile_cgnat` boolean, and the verification block reports 444 rows with zero mismatches. Boris then gave two defect reports in one line — "the configured psql default connection is not used correctly and rdap-lookup.sh is not usable" — plus the standing constraint that the `last_carrier_node` / `node_fanout` job was running and would take about five hours, so the instance should proceed with everything else meanwhile.

The instance investigated rather than guessed, and found the rdap problem had three independent causes: `deploy.sh` never installed the script into the deployed tree at all; the `-rdap-script` default was the cwd-relative `./rdap-lookup.sh`; and from the repo's `geo/` directory that relative path resolved to a stale duplicate copy which still carried a `set -e` landmine that the canonical copy documents as fixed. It compared checksums (canonical `3459968002 4609` at `geo/rdap-lookup/cmd/rdap-lookup.sh`, stale `1333865443 4301` at `geo/rdap-lookup.sh`), confirmed the canonical checksum matched the one recorded in the session notes for both workstations, verified nothing in the repo referenced the stale copy, wrote a pre-mortem, and deleted it. It changed the default to `auto` (search the binary's own directory first), made an explicit-but-failing `-rdap-script` fatal, and had `deploy.sh` install and checksum-verify the canonical copy and warn on missing `curl`/`jq`. It corrected one of its own mid-course claims: the stale copy's mode-644 bit was not fatal, because `runRDAP` invokes `bash <path>`.

On the connection defect it found a latent hazard rather than a reproduction of what Boris saw: libpq's default dbname is the user name, and pgx leaves `cfg.Database` empty when `PGDATABASE` is unset, so a hand-run `last_carrier_node` outside both `trugeo.cron` and `geo_common.sh` could connect to the wrong database while logging `database ""`. It made resolution observable (log resolved database/user/host/port before connecting, confirm `current_user@current_database()` from the server after, add a `-database` flag) and asked Boris what he had actually observed, noting his interactive run evidently connected correctly since it found all 312 landmarks.

It then made the `likely_mobile_cgnat` drop automatic but conditional, merging migration steps 2–4 into one PL/pgSQL guarded block, and in testing discovered the file had never been re-runnable as top-level SQL (step 2 referenced the dropped column on the second run). It verified three gate behaviours on a scratch Postgres: clean run drops, re-run no-ops, seeded mismatch raises and keeps the column. All 13 tools built; PR #52 was opened and merged to `745d2b3`. It warned Boris not to run `deploy.sh` while `last_carrier_node` was live, because GNU `install` overwrites in place and overwriting a running executable returns `ETXTBSY`.

Attention then turned to Foursquare. The instance probed the access path instead of assuming it, and established that the anonymous route is gone: the public bucket `fsq-os-places-us-east-1` now holds only `LICENSE.txt` and `NOTICE.txt` (`NOTICE.txt` updated 2025-10-03), Hugging Face file *listing* works anonymously (HTTP 200) but *download* returns HTTP 401, and the dataset-viewer API is also 401. The licence is unchanged (Apache 2.0, free commercially); only download is gated, with auto-approval. It built `fsq_fetch.py` plus table and crosswalk SQL, and — the design point it kept insisting on — proved the *unmodified* `ovt_resolve_hosts.py overture-zip` step works on the new table, because that script is already parameterised by `--table`, `--url-column` and `--address-column`. The only source-specific work is synthesising an Overture-shaped `addresses` JSON text column.

Boris then asked for precise commands (the full fan-out output being too large to paste), for exact Hugging Face account steps, and for landmark data from every other source in his memo plus any the instance could research, with the hard requirement of ZIP codes *and* websites. The instance wrote `node_fanout_report.sql` to read the two tables the 5-hour run had already built rather than recompute anything, and built `lm_fetch.py` covering NCES IPEDS, OSM via Overpass, OSM via Geofabrik PBF, and Wikidata — rejecting IMLS (no URL field at all; its only web-ish column among 192 is `WEBVISIT`, a visit count), NPS (every park is an `nps.gov` URL, so ~470 parks collapse to one host, which the cluster rule would then flag as hosting), and NRHP. It found that Wikidata's P281 gives city-level ZIP ranges on US items and used P6375 street address instead, where the ZIP sits in text in exactly the shape the existing chain already parses. Its own testing caught a UTF-8 BOM in the IPEDS CSV that silently collapsed a 6,075-row load to 1 row.

Boris ran the fan-out report and pasted the output. The instance reconciled it to the known corpus (28,324 addresses, 120,154 places), declared its own earlier Comcast claim affirmatively dead, flagged the honest caveat that mean landmarks per node is 2.66 against the threshold of 3 it had set in advance, and sized the rule 3a hole at 50.7% of the corpus. Boris pushed back that the Hugging Face token instructions were unclear — where the `hf_` value comes from, what to paste, what to name the token — and the instance checked the actual HF docs, admitted it had conflated a name you invent with a value HF generates, and reissued the whole sequence step by step. It also fixed a presentation defect it spotted in Boris's own output (`as3491.net` showing `mean_clusters 0.00` where the truth was "too wide to cluster"), merged as `44c59d6`.

Boris then gave three directives at once: put the HF token sourcing in `.bashrc`; confirm that hosting ⇒ `onpremises = false`, but with ISP-plus-hosting companies under one registrant judged by the agreed rules (naming Southwest Cyberport and Synergy Networks); and put landmarks from all sources for the USA in one table, loaders may differ. He also reported repeated 502s and blamed the mtr code. The instance showed the 502s came from the Overpass API inside `lm_fetch.py osm-overpass` — mtr is not involved in that tool — and that its retry had recovered them (15,238 rows loaded on the third attempt). But it found a real defect of its own in the same output: Wikidata answered 429 with `Retry-After: 1000` and the code honoured it literally, parking the run for 17 minutes indistinguishably from a hang. It built `landmarks_usa` keyed on `(source, source_id)` with a `source_attrs jsonb` tail, a migration that only carries rows with a website and carries completed RDAP over rather than recomputing it, and a per-address `onpremises_hosting_rule.sql` that uses Southwest Cyberport and Synergy Networks as fixtures. Merged `d2055f6`.

Boris challenged the 120s backoff cap: was 120 a known interval for any service, or invented? The instance conceded it was a round number it picked, established that the only stated interval any of these services gives is WDQS's own "1 req / min", and reduced the cap to 60s with a `--max-backoff` flag. It built `ingest_status.sql` (so status reporting is a query, not narration) and `range2zip.sql`, tested the latter on fixtures, merged `a15cdcb`.

Boris then challenged `--limit 50000` — don't we want all records? — and asked whether there is a separate abort mechanism if the Wikidata outage persists. Both questions found real defects. The instance measured the true total via QLever (29,858 US items with both P6375 and P856; 26,088 with a 5-digit ZIP), so 50,000 had never truncated anything but only by luck. Worse, `--limit` meant an absolute *offset* ceiling, so combined with `--resume` it did nothing at all. Worst of all, `load_rows` defaulted to `replace=True` — delete all rows for the source, then COPY — so a partial re-run went *backwards*, and since pagination always restarted at offset 0, repeated partial runs could never accumulate. It switched the default endpoint to QLever, added `ORDER BY ?item` for deterministic pagination, made batches stage in a temp table and merge with `ON CONFLICT` (updating only the 15 load columns so chain-written enrichment survives), added `--deadline-minutes`, and fixed an inline `COPY ... FROM STDIN` failure caused by a literal newline inside a Wikidata street address by routing batches through a temp file and client-side `\copy`. Merged `1481fc3`.

The slice ends with Boris saying "All done", instructing the instance to check for any landmarks not imported or not processed for RDAP, to ensure all `landmarks_usa` landmarks are probed in ip-api.com, and then to build range↔landmark matching on the mtr last carrier node to determine the ZIP(s) served by each range. He pasted the migration output (14,094,616 rows in `landmarks_usa`, `eligible_in_source` equal to `migrated` for all three sources), the `ingest_status.sql` output, the Foursquare and landmark-source load output, the zero-row `onpremises_hosting_rule.sql` run, and then the live `resolve --table landmarks_usa` progress log, which fills the rest of the range. The instance's reply to that message is beyond line 48100.

## Decisions and rationale

- **rdap-lookup.sh default changed from `./rdap-lookup.sh` to `auto`**, searching the binary's own directory first; an explicit `-rdap-script` that fails is now fatal. Rationale: a cwd-relative default silently resolved to a stale buggy copy. Boris did not comment further; accepted implicitly.
- **Delete the stale `geo/rdap-lookup.sh`.** Rationale given in a written pre-mortem: nothing references it, it is recoverable via `git show HEAD:geo/rdap-lookup.sh`, blast radius is the git repo only, and keeping it is the hazard because it still carries the `set -e` bug. Accepted (the deletion appears in the diffstat of Boris's own `git pull`).
- **Make the usability check not require the executable bit.** The instance explicitly reversed its own earlier reasoning here: `runRDAP` invokes `bash <path>`, so mode 644 is not fatal.
- **`likely_mobile_cgnat` dropped automatically but conditionally**, with steps 2–4 merged into one PL/pgSQL block so the drop is decided by the verification that just ran, not by a human reading output. Rationale for PL/pgSQL specifically: it plans statements lazily, so an early `RETURN` guard means statements naming the dropped column are never planned, which is what makes the file re-runnable.
- **Reuse the Overture enrichment chain unchanged for every new source** rather than writing per-source enrichment. Rationale: one definition of "on premises" for all sources. Verified by running the unmodified `overture-zip` step against the Foursquare table.
- **Only rows with a website migrate into `landmarks_usa`.** Rationale: a place with no website can never be a landmark, so ~11M permanently ineligible Overture rows stay in `ovt_places_usa` rather than costing scan time forever. The migration prints `eligible_in_source` beside `migrated` so nothing eligible can be silently dropped.
- **Completed RDAP is carried over by the migration, not recomputed**, to preserve 543,336 IPs and ~20 hours of lookups.
- **Hosting ⇒ `onpremises = false`, judged per address, not per registrant.** The instance proposed it but refused to apply it unilaterally because it removes 50.7% of places while removing only 16.3% of addresses. **Boris confirmed it**, and modified it: ISP services by companies that also offer hosting under the same registrant name must have `onpremises` set by the agreed rules — naming Southwest Cyberport and Synergy Networks as the two such companies. The instance had deliberately not named them; it used Boris's naming directly and made them test fixtures.
- **A new `onpremises_reason` column** records which rule decided, on the stated grounds that a hosting-rule `false` and a registrant-rule `false` are not the same claim.
- **One unified table, differing loaders** — Boris's instruction. Implemented as `landmarks_usa` keyed `(source, source_id)` with a common core plus `source_attrs jsonb`; the three import tables stay untouched as raw imports and the migration only reads them.
- **Backoff cap reduced from 120s to 60s with `--max-backoff`.** Boris challenged the 120 as possibly invented; the instance agreed it was, and justified 60 as the shortest cap that still lets every observed rate limit recover, since WDQS's own 429 body states 1 req/min and nothing observed demands between 60 and 120.
- **`--limit` default changed to 0 (all), and its meaning changed from an absolute offset ceiling to rows fetched this run.** Boris's challenge drove both.
- **Default Wikidata endpoint switched from WDQS to QLever (`qlever.dev`)**, with `--endpoint wdqs` kept for cross-checking. Rationale: WDQS was rate-limiting to 1 req/min and 504ing on even a COUNT, while QLever answered the same COUNT in under a second. The instance noted QLever also returned a transient 500 during testing, so neither endpoint is reliable — which is why resume and per-page merging matter more than the limit.
- **`ORDER BY ?item` added** because SPARQL `OFFSET` without an order has no defined order, so resuming would be approximate rather than correct.
- **Batch loads merge with `ON CONFLICT` instead of delete-then-COPY**, updating only the 15 load columns so enrichment already written by the chain survives.
- **Deliberately did NOT filter chain domains at load time** (for-profit colleges, retail chains). Rationale: they are exactly what the disjoint-cluster rule exists to catch, and filtering them at load would create a second, different definition of hosting.
- **Rejected IMLS, NPS and NRHP as sources**, each on checked grounds rather than guesses (see Narrative). NPS was implemented anyway but documented as not worth running.
- **Status reporting moved into `ingest_status.sql`** explicitly to replace the instance narrating status.
- **Two items deferred to Boris as design changes rather than acted on**: replacing the hand-curated 19-domain `transit_domain` list with a measured rule (high cluster count across many landmarks is transit behaviour), prompted by `sdnet.net` sitting at tier `f` while showing 33 disjoint clusters; and the Videotron rows, which point to a country-filtering gap upstream rather than a classification error. No decision from Boris on either within this slice.

## Measured facts and numbers

**mobile_transit migration (top of slice, verified run output)**
- `mobile_transit` column present on 5 table/column rows: `ip2city_dbiplite_history_tbl`, `ip2city_dbiplite_probe_tbl`, `ip2city_dbiplite_traceroute_tbl`, `ovt_places_usa_ip_trace` (all `character varying(1)`), plus `ip2city_dbiplite_traceroute_backup_tbl.likely_mobile_cgnat` (boolean).
- `ip2city_dbiplite_probe_tbl`: `f` = 2,081,355; `m` = 16,515. `ovt_places_usa_ip_trace`: `f` = 312.
- `UPDATE 215`; tier split `t` = 215 (68.9%), `f` = 97 (31.1%).
- Backup-table verification: `rows_total` 444, `mismatch_true_not_m` 0, `mismatch_false_not_f_or_t` 0, `mismatch_null_not_null` 0, `promoted_to_transit` 133, `agreed_mobile` 3, `agreed_fixed` 308.

**Checksums**
- `geo/rdap-lookup/cmd/rdap-lookup.sh` — `3459968002 4609` (canonical; matches the checksum the session notes record for both workstations).
- `geo/rdap-lookup.sh` — `1333865443 4301` (stale, mode 644, deleted).

**Foursquare / Hugging Face (all verified by probe)**
- `s3://fsq-os-places-us-east-1/release/...` — `KeyCount=0`; bucket readable (HTTP 200, not 403) but holds only `LICENSE.txt` and `NOTICE.txt`. `NOTICE.txt` last updated 2025-10-03.
- HF file listing: anonymous HTTP 200, gating mode "auto". HF file download: anonymous HTTP 401. Dataset-viewer API: 401.
- Newest release in the instance's own sandbox probe: 4 releases listed, newest 2026-10-15, **100 parquet files, 10.79 GB** worldwide.
- In Boris's run, `fsq_fetch.py releases` printed **23 releases**, 2024-12-03 through 2026-10-15; "Newest release 2026-10-15: 100 parquet files, 10.79 GB". (The 4-vs-23 difference is not explained in the transcript.)
- Token range check returned **206**, confirming the token worked before the large load.
- Boris's MA load: `fsq_fetch.py verify` printed `275517|275517|275517|274824|785`; the ZIP-regex check printed `275517|274641|271854|275344|275517`. The instance later characterised this as "99.7% ZIP-regex match".

**Landmark sources (measured on live loads)**
- NCES IPEDS 2023: **6,075 rows**, 0 duplicate ids skipped; 5,411 distinct hosts (**89.1% unique**), 4,241 distinct ZIPs, 59 states covered.
- OSM Overpass MA: **15,238 rows** loaded, 0 duplicates; 14,572 distinct hosts (**95.6%**), 561 distinct ZIPs, 8 states covered in the table. Two 502s before success (retried at 15s then 30s).
- Earlier Overpass count: Massachusetts has **15,132** OSM features carrying both `website` and `addr:postcode`, against **312** Overture on-premises addresses for MA.
- Earlier Overpass count: Texas = **52,269**. California and New York time out on Overpass.
- OSM Rhode Island (earlier test): 1,958 rows → 1,908 hosts (**97.4% unique**).
- Geofabrik: **11.39 GB** national `us-latest.osm.pbf`, **0.29 GB** for MA.
- Wikidata via QLever: **29,858** US items with both P6375 (street address) and P856 (website); **26,088** of those have a 5-digit ZIP. Full pull estimated at "about two minutes" (estimate).
- Wikidata resume tests (verified): run 1 `--limit 1000` → 961 rows; run 2 `--resume --limit 1000` → 1,839 rows; run 3 unbounded with `--deadline-minutes 1` → 22,741 fetched, 21,692 merged, stopped cleanly; re-run of overlapping offsets → 961 → 961 (idempotent).
- Boris's Wikidata run FAILED: `HTTP 429 Aggressively rate-limiting to 1 req / min - this rule was created during active wdqs outage (797a132), retrying in 1000s`, then `HTTP 504 Gateway Timeout, retrying in 30s`, then `FAILED (HTTP 504 Gateway Timeout); stopping and loading what we have` / `wikidata: nothing to load.`
- Chain-domain ZIP spread (measured in the crosswalk test): `paulmitchell.edu` 96 ZIPs, Empire 72, `locations.dunkindonuts.com` 40, McDonald's 25.

**node_fanout report, section 1 (statistical power)**
- nodes 6,169; landmarks 16,425; **mean_landmarks_per_node 2.66**; median 1; max 325; nodes_measurable (≥3 landmarks) 1,297; **pct_measurable 21.0**.
- Those 1,297 measurable nodes hold **10,554 of 16,425 landmarks = 64.3%** of all landmark mass.
- Of measured landmarks, only **1,883 of 10,554 = 17.8%** sit behind a node narrow enough for ZIP targeting.
- The pre-registered power threshold was 3 landmarks per node; the measured mean of 2.66 is below it.

**node_fanout section 2 (verdict summary, all nodes)** — selected rows, `nodes | landmarks | pct_landmarks`:
`unmeasured: too few landmarks` 4,872 | 5,871 | 35.7; `reject: too wide to cluster` 19 | 2,089 | 12.7; `zip-level: one contiguous area` 308 | 1,883 | 11.5; `reject: 3 disjoint` 305 | 1,247 | 7.6; `reject: 4 disjoint` 172 | 946 | 5.8; `reject: 2 disjoint` 201 | 858 | 5.2; `reject: 5 disjoint` 80 | 522 | 3.2; tail runs out to `reject: 36 disjoint areas` 1 | 46 | 0.3 (30 rows total).

**node_fanout section 3 (per operator, measurable nodes only, top 15)** — `domain | nodes | landmarks | mean_lm/node | mean_zips | mean_clusters | zip_level | rejected`:
cogentco.com 201 | 2,160 | 10.75 | 8.06 | 5.35 | 20 | 181; zayo.com 97 | 982 | 10.12 | 7.71 | 4.64 | 21 | 76; comcast.net 173 | 803 | 4.64 | 4.07 | 3.31 | 17 | 156; (unnamed) 43 | 729 | 16.95 | 14.16 | 4.77 | 11 | 32; charter.com 132 | 711 | 5.39 | 4.68 | 3.89 | 12 | 120; he.net 45 | 691 | 15.36 | 13.58 | 4.64 | 7 | 38; twelve99-cust.net 47 | 618 | 13.15 | 10.17 | 4.49 | 5 | 42; lumen.tech 75 | 512 | 6.83 | 6.16 | 4.48 | 6 | 69; as3491.net 1 | 172 | 172.00 | 171.00 | 0.00 | 0 | 1; hostasaurus.com 2 | 145 | 72.50 | 71.50 | 0.00 | 0 | 2; cenic.net 20 | 125 | 6.25 | 2.25 | 1.75 | 13 | 7; oar.net 13 | 97 | 7.46 | 1.92 | 1.31 | 10 | 3; ntt.net 10 | 96 | 9.60 | 9.10 | 8.30 | 2 | 8; lightower.net 12 | 94 | 7.83 | 6.33 | 4.83 | 3 | 9; cox.net 15 | 88 | 5.87 | 5.07 | 4.00 | 3 | 12.

**node_fanout section 4 (Brockton test, worst measurable rejects)** — top rows `node_hostname | tier | lm | zips | clusters`:
`be2763.ccr41.dfw03.atlas.cogentco.com` t 46/39/36; `128.177.44.131.zip.zayo.com` t 44/38/34; `100ge0-35.core11.fmt2.he.net` t 39/36/33; `lag-65.1357.bntpsdae52r.sxflsdch58r.sdnet.net` **f** 35/34/33; `be2411.rcr21.msp01.atlas.cogentco.com` t 41/35/27; `att-gw.dc.as701.net` t 28/27/27; `ae-20.a01.newthk04.hk.bb.gin.ntt.net` t 27/27/26; `lag-600.sxflsdch58r.omahne16s1r.sdnet.net` **f** 27/24/23; two rows with blank hostname (35/32/23 and 29/27/23).

**node_fanout section 5 (Comcast, the claim under test)**
- comcast_nodes 891; landmarks 1,693; mean_landmarks_per_node 1.90; measurable 174; measurable_zip_level 18; measurable_rejected 156 → **89.7% of measurable Comcast nodes reject**, at 4.64 landmarks/node and 3.31 mean clusters. The instance's conclusion: Comcast is definitively not ZIP-specific; West Roxbury-via-Brockton and Lynn-via-Woburn were the national pattern, and its own withdrawn claim is now affirmatively dead rather than merely unsupported.

**node_fanout section 6 (address-level hosting)** — `verdict | addresses | places`:
`on-premises: single zip` 21,218 | 30,331; `on-premises: one contiguous area` 2,501 | 28,170; `hosting: 2 disjoint` 2,240 | 6,739; `hosting: 3 disjoint` 724 | 3,329; `hosting: 4 disjoint` 390 | 2,521; `hosting: 5 disjoint` 239 | 1,972; **`hosting: too wide to cluster` 181 | 32,349** (27% of everything); down to `hosting: 38 disjoint areas` 1 | 40 (41 rows).

**node_fanout section 7 (rule 3a hole)**
- hosting_addresses 4,605; places_affected 61,653; registrant_is_isp 4,427; places_via_isp **60,903** — which the instance computed as **50.7% of the entire 120,154-place corpus**, admitted as landmarks solely because the registrant is in `isp_names`.
- Density signature: hosting addresses carry **13.4 places each** vs **2.5** for genuine on-premises.
- Applying the rule would remove **50.7% of places** while removing only **16.3% of addresses**.

**node_fanout section 8 (12 biggest hosting registrants)** — `registrant | addresses | places | max_zips | max_clusters`:
Cogent Communications, LLC 764 | 8,452 | 408 | 39; Sterling Communications, Inc. 2 | 8,257 | 1,625 | 2; Level 3 Parent, LLC 270 | 5,275 | 512 | 40; Comcast Cable Communications, LLC 375 | 3,170 | 227 | 32; AT&T Enterprises, LLC 328 | 2,876 | 154 | 33; Videotron Ltee 45 | 2,855 | 321 | 36; CenturyLink Communications, LLC 131 | 2,575 | 509 | 38; Verizon Business 323 | 2,062 | 119 | 21; Hurricane Electric LLC 173 | 1,808 | 404 | 36; Northern Valley Communications LLC 71 | 1,587 | 83 | 33; Cox Communications Inc. 123 | 1,314 | 344 | 21; BroadbandONE, LLC 36 | 1,095 | 520 | 26.
- Corpus reconciliation the instance ran against these numbers: **28,324 addresses and 120,154 places**.

**`onpremises_hosting_rule.sql` section 2 against real data (registrants with BOTH hosting and on-premises addresses, 25 rows)** — `registrant | hosting_addrs | onprem_addrs | hosting_places | onprem_places_kept | max_zips`:
Cogent 764 | 2,017 | 8,452 | 2,299 | 408; Comcast Cable 375 | 1,349 | 3,170 | 1,794 | 227; AT&T Enterprises 328 | 1,191 | 2,876 | 1,693 | 154; Verizon Business 323 | 1,154 | 2,062 | 1,390 | 119; Charter Communications Inc 137 | 711 | 790 | 864 | 171; Level 3 Parent 270 | 517 | 5,275 | 733 | 512; Hurricane Electric 173 | 531 | 1,808 | 605 | 404; Cox Communications Inc. 123 | 419 | 1,314 | 588 | 344; Charter Communications LLC 95 | 424 | 435 | 526 | 14; CenturyLink 131 | 311 | 2,575 | 404 | 509; NTT America 89 | 319 | 905 | 337 | 75; Zayo Bandwidth 20 | 113 | 123 | 291 | 25; **Southwest Cyberport, Inc. 1 | 18 | 3 | 183 | 8**; **University of Hawaii 2 | 33 | 5 | 179 | 4**; Simple Network Communications 37 | 153 | 184 | 176 | 56; Windstream 26 | 111 | 182 | 150 | 15; **Synergy Networks 1 | 23 | 2 | 149 | 7**; **University of Minnesota 2 | 14 | 7 | 140 | 6**; Cox Communications 30 | 119 | 150 | 134 | 32; Internet Utilities NA LLC 48 | 104 | 309 | 131 | 27; Ziply Fiber 11 | 73 | 48 | 125 | 17; Comcast IP Services 5 | 99 | 11 | 115 | 2; HDC/HW Enterprise 1 | 49 | 2 | 114 | 8; Metronet 17 | 82 | 842 | 111 | 628; Altafiber 43 | 95 | 670 | 108 | 117.
- Section 2b detail: Southwest Cyberport — `hosting: 2 disjoint areas` 1 addr/3 places, `on-premises: one contiguous area` 3/166, `on-premises: single zip` 15/17. Synergy Networks — `hosting: 2 disjoint areas` 1/2, `on-premises: one contiguous area` 4/130, `on-premises: single zip` 19/19.
- The instance's reading of this: naming four of those registrants as providers would have destroyed 651 genuine on-premises places to exclude 17 hosting ones. Universities run hosting alongside campus premises too (Hawaii, Minnesota).
- Sections 1, 3, 4, 4b, 4c returned **0 rows / 0 places / 0 zips** because `landmarks_usa` was still empty — Boris had run the rule without first running the migration.

**`migrate_into_landmarks_usa.sql` (Boris's verified run)**
- `INSERT 0 13797786` (overture), `INSERT 0 275517` (foursquare), `INSERT 0 21313` (lm).
- Per-source: overture 13,797,786 rows | 11,506,922 distinct hosts | 12,334,687 have_ip | 11,466,589 rdap_done | 120,154 onpremises_true | 11,281,262 have_zip. foursquare 275,517 | 216,187 | 0 | 0 | 0 | 0. osm 15,238 | 14,572 | 0 | 0 | 0 | 0. nces_ipeds 6,075 | 5,411 | 0 | 0 | 0 | 0.
- Nothing-lost check: overture 13,797,786 eligible / 13,797,786 migrated; foursquare 275,517 / 275,517; lm_places_usa (all) 21,313 / 21,313.

**`ingest_status.sql` (Boris's verified run)**
- Raw imports: overture 17,949,230 rows_total, 14,176,971 with_website, 120,154 onpremises_true; foursquare 275,517 / 275,517 / 0; lm_places_usa 21,313 / 21,313 / 0.
- `landmarks_usa_state` = populated, **14,094,616 rows**.
- Unified table per source: overture 13,797,786 | resolved 12,334,687 | rdap_done 11,466,589 | have_zip 11,281,262 | onpremises_true 120,154 | false 11,161,108 | null 2,516,524. The other three sources all 0 resolved / 0 rdap / all null.
- Next step per source: overture `chain complete`; foursquare, osm, nces_ipeds all `run: resolve`.
- ZIP coverage: **15,963** ZIPs with an on-premises landmark against `inhabited_zips_approx` **44,000** → **36.3%**. The 44,000 denominator is labelled "approx" in the report itself, so treat the percentage as approximate.
- Section 4b: overture 15,963 ZIPs, 15,963 unique to source — i.e. no other source contributed any ZIP yet, because none has been through the chain.

**`resolve --table landmarks_usa` (live run, pasted; still in flight at end of range)**
- "Resolving **7,994,314** hosts with **64 threads**".
- Last line inside the range: **4,762,000/7,994,314 done, 3,522,736 resolved, 10,849s**.
- Early rate: 2,000 done at 184s, 444,000 done / 377,182 resolved at 1,113s.
- **A long stall is visible in the log**: from 446,000 done (378,011 resolved, 1,118s) through 1,034,000 done (378,011 resolved, 1,237s) the resolved count does not move at all — roughly 588,000 hosts consumed with zero resolutions in ~119 seconds — then resolution resumes normally at 1,036,000 (379,710 resolved, 1,241s). The transcript does not diagnose this; see Traps.
- A second, milder slowdown appears around 1,204,000–1,230,000 done (per-2,000 step time rising from ~5s to ~18s) and again around 4,646,000–4,666,000.

**Git**
- PR #52 merged → `origin/main` at **745d2b3**. Subsequent merges: **52db6ed**, **974a1b8**, **44c59d6**, **d2055f6**, **a15cdcb**, **1481fc3**.
- `974a1b8` diffstat: 13 files, **2,111 insertions, 192 deletions** — `fsq_fetch.py` 344, `fsq_crosswalk.sql` 97, `create_table_fsq_places_usa.sql` 100, foursquare `readme.md` 203, `create_table_lm_places_usa.sql` 94, `lm_crosswalk.sql` 116, `lm_fetch.py` 583, landmark_sources `readme.md` 148, `main.go` 188 changed, `mobile_transit_migration.sql` 157, `node_fanout_report.sql` 112, `deploy.sh` 39, `rdap-lookup.sh` 122 deleted.
- `a15cdcb` diffstat: `lm_fetch.py` 32, `ingest_status.sql` 111, `range2zip.sql` 207 → 342 insertions, 8 deletions.
- RDAP work preserved by the migration: **543,336 IPs**, "~20 hours of lookups" (the hours figure is carried forward from earlier in the session, not re-measured here).

**`range2zip.sql` fixture result (verified on fixtures, not production)**
```
     network      |  zip  | match_method  | landmark_sources | zips | clusters | verdict
 203.0.113.0/25   | 02116 | node_ip       | overture         |    3 |        1 | zip: one contiguous area of 3
 203.0.113.0/25   | 02119 | node_ip       | foursquare       |    3 |        1 | zip: one contiguous area of 3
 203.0.113.128/25 | 02116 | node_hostname | overture         |    3 |        1 | zip: one contiguous area of 3
 198.51.100.0/24  | 01901 | node_ip       | osm              |    2 |        2 | disjoint: 2 areas
```
- Foursquare crosswalk fixture result: 3 of 4 hosts new (bpl.org shared), 4 new ZIPs, 3 ZIPs gaining an on-premises landmark, and a chain store's `/store2` path correctly stripped so both rows collapsed to one host.
- Foursquare ZIP-step integration test: ZIP+4 `01901-1234` correctly reduced to `01901`; `overture_zip_source='postcode'` set on every candidate.

## Code, files, tables

Paths are as given in the transcript, relative to the repo root (`/home/boris/geo/src/claude` on Boris's machine).

**Changed**
- `geo/main.go` — connection block rewritten: resolve and log database/user/host/port before connecting, confirm `current_user@current_database()` from the server after, new `-database` flag, client-side resolution of the empty-`Database` case so the log names the real target. `-rdap-script` default changed to `auto` with directory search; explicit-and-failing path now fatal. (188 lines changed.)
- `geo/pipeline/deploy.sh` — now installs `geo/rdap-lookup/cmd/rdap-lookup.sh` next to the binary, verifies its checksum, and warns if `curl` or `jq` is missing. Uses the house `fail()` helper (the instance first wrote `die()`, which does not exist there).
- `geo/mobile_transit_migration.sql` — steps 2–4 merged into one PL/pgSQL guarded block; conditional automatic `DROP` of `likely_mobile_cgnat` gated on the verification that just ran; file header corrected (it had claimed nothing is dropped). Confirmed paste-safe (0 mid-line `#`, 0 backslashes, 0 meta-commands).
- `geo/landmark_sources/lm_fetch.py` — backoff cap reduced to 60s and exposed as `--max-backoff`; Wikidata default endpoint switched to QLever with `--endpoint wdqs` retained; `--limit` default 0 and redefined as rows-this-run; `--deadline-minutes`; `ORDER BY ?item` for deterministic pagination; per-page `ON CONFLICT` merge via temp table instead of `replace=True` delete-then-COPY; batches written to a temp file and read with client-side `\copy`; UTF-8 BOM handling for the IPEDS CSV plus a guard that refuses a load when more than half the ids are blank.
- `geo/node_fanout_report.sql` — fixed so a "too wide to cluster" node shows blank with `too_wide=1` instead of a misleading `mean_clusters 0.00`.

**Deleted**
- `geo/rdap-lookup.sh` — stale duplicate, 122 lines, mode 644, cksum `1333865443 4301`.

**Created**
- `geo/node_fanout_report.sql` (112 lines) — 8 small sections (~70 lines of output) reading the two tables the 5-hour `node_fanout.sql` run already built; recomputes nothing. Section 1 is statistical power and is meant to be read first; 3–5 restrict to nodes with ≥3 landmarks; 5 tests Comcast; 7–8 size the rule 3a hole.
- `geo/foursquare_fetch/create_table_fsq_places_usa.sql` (100) — `fsq_places_usa`; synthesises an Overture-shaped `addresses` JSON text column (`postcode`, `freeform`, `locality`, `region`) and a bare-URL `websites` text column so the existing chain needs no changes.
- `geo/foursquare_fetch/fsq_fetch.py` (344) — subcommands `releases` (works with no credential), `load` (DuckDB over `hf://`, `--release`, `--states`, `--require-website`, `--input`, `--dry-run` with no DB needed), `verify`. Excludes non-US and closed rows; flattens `fsq_category_ids` / `fsq_category_labels` parquet lists before inserting into text columns; uses DuckDB `trim` (not `btrim`).
- `geo/foursquare_fetch/fsq_crosswalk.sql` (97) — how many *new* landmarks Foursquare buys over Overture (new hosts, new ZIPs, ZIPs gaining an on-premises landmark).
- `geo/foursquare_fetch/readme.md` (203).
- `geo/landmark_sources/create_table_lm_places_usa.sql` (94) — `lm_places_usa`, shared raw-import table for IPEDS / OSM / Wikidata.
- `geo/landmark_sources/lm_fetch.py` (583) — subcommands `nces-ipeds --year`, `osm-overpass --states`, `osm-pbf --input`, `wikidata`, `status`; also an NPS implementation documented as not worth running.
- `geo/landmark_sources/lm_crosswalk.sql` (116) — 5 sections; section 5 surfaces the domain-shared-across-many-ZIPs chains.
- `geo/landmark_sources/readme.md` (148) — includes the Geofabrik/osmium PBF route for states Overpass refuses.
- `geo/landmarks/create_table_landmarks_usa.sql` — `landmarks_usa`, the single unified USA landmark table, keyed `(source, source_id)`, common core columns plus `source_attrs jsonb`, plus the new `onpremises_reason` column. 5 indexes and a table COMMENT.
- `geo/landmarks/migrate_into_landmarks_usa.sql` — reads the three raw import tables, migrates only rows with a website, carries completed RDAP across, prints rows-per-source and an `eligible_in_source` vs `migrated` check.
- `geo/landmarks/onpremises_hosting_rule.sql` — per-address hosting rule; sections: 1 before, 2 registrants with both verdicts (found from data, not a list), 2b the two named cases, 3 apply, 4/4b/4c/4d after + reason breakdown + named-case survival + surviving ZIP coverage. Idempotent.
- `geo/landmarks/ingest_status.sql` (111) — 4+ sections: raw imports, `lm_places_usa` per source, unified-table state, next chain step per source, ZIP coverage and per-source unique ZIP contribution.
- `geo/landmarks/range2zip.sql` (207) — writes `range2zip_tbl` keyed `(network, zip)` so one range serving several ZIPs produces several rows with `zips_at_range` on each; `match_method` is `node_ip` (strong) or `node_hostname` (fallback, because two traces often end on different interfaces of the same router); disjoint matches are written and tagged rather than dropped, with view `range2zip_usable_v` filtering them out. Reads `onpremises IS TRUE`, so it must run after the chain.

**Tables referenced/consumed**: `address_hosting_tbl` (built by `node_fanout.sql` from `ovt_places_usa` only), `last_carrier_node` and `node_fanout` outputs, `isp_names`, `provider_names`, the 19-entry `transit_domain` list, `ovt_places_usa`, `ovt_places_usa_ip_trace`, `ip2city_dbiplite_*`.

## Commands worth keeping

Deploy after the long job finishes (note the lock and the ETXTBSY warning):
```
sudo -v
exec 9>/var/lock/trugeo.mutation && flock 9
cd /home/boris/geo/src/claude && git pull origin main
./geo/pipeline/deploy.sh
psql -d postgres -f geo/mobile_transit_migration.sql
exec 9>&-
```

Fan-out report (reads existing tables, recomputes nothing):
```
cd /home/boris/geo/src/claude && git pull origin main
psql -d postgres -f geo/node_fanout_report.sql
```

Hugging Face token into the environment, then verify before a 10 GB load:
```
read -rsp 'Paste HF token then press Enter: ' HF_TOKEN && export HF_TOKEN && echo
printf 'export HF_TOKEN=%s\n' "$HF_TOKEN" >> ~/.hf_token && chmod 600 ~/.hf_token

curl -s -o /dev/null -w '%{http_code}\n' -r 0-1023 -L -H "Authorization: Bearer $HF_TOKEN" 'https://huggingface.co/datasets/foursquare/fsq-os-places/resolve/main/release/dt=2026-10-15/places/parquet/places_000000.parquet'
```
206 = works, 401 = token not sent/invalid, 403 = licence not accepted, 404 = release rotated.

Make it permanent (idempotent guard; `.bashrc` only sources the file so it stays safe to show):
```
grep -q hf_token ~/.bashrc || printf '\n[ -r ~/.hf_token ] && . ~/.hf_token\n' >> ~/.bashrc
```

Foursquare load (MA first, to compare like with like against Overture):
```
cd /home/boris/geo/src/claude/geo/foursquare_fetch
psql -d postgres -v ON_ERROR_STOP=1 -f create_table_fsq_places_usa.sql
python3 fsq_fetch.py releases
python3 fsq_fetch.py load --release 2026-10-15 --states MA --require-website --input 'hf://datasets/foursquare/fsq-os-places/release/dt=2026-10-15/places/parquet/*.parquet'
python3 fsq_fetch.py verify
psql -d postgres -f fsq_crosswalk.sql
```

Ungated sources (do these first; no credential needed):
```
cd /home/boris/geo/src/claude/geo/landmark_sources
psql -d postgres -v ON_ERROR_STOP=1 -f create_table_lm_places_usa.sql
python3 lm_fetch.py nces-ipeds --year 2023
python3 lm_fetch.py osm-overpass --states MA
python3 lm_fetch.py wikidata
python3 lm_fetch.py status
psql -d postgres -f lm_crosswalk.sql
```
If Wikidata stops for any reason: `python3 lm_fetch.py wikidata --resume`.

National OSM via Geofabrik, because Overpass times out on CA and NY:
```
sudo -v
sudo dnf install -y osmium-tool
cd /home/boris/geo && curl -L -O https://download.geofabrik.de/north-america/us-latest.osm.pbf
osmium tags-filter us-latest.osm.pbf -o filtered.osm.pbf nwr/website nwr/contact:website
osmium export filtered.osm.pbf -f geojsonseq --add-unique-id=type_id -o filtered.geojsonseq
cd src/claude/geo/landmark_sources && python3 lm_fetch.py osm-pbf --input filtered.geojsonseq
```

Unified table migration, then status, then the chain:
```
cd /home/boris/geo/src/claude && git pull origin main
cd geo/landmarks
psql -d postgres -v ON_ERROR_STOP=1 -f create_table_landmarks_usa.sql
psql -d postgres -f migrate_into_landmarks_usa.sql
psql -d postgres -f ingest_status.sql
```
Check `eligible_in_source` equals `migrated` for all three rows before continuing.
```
cd /home/boris/geo/src/claude/geo
python3 overture_fetch/ovt_resolve_hosts.py resolve      --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py rdap         --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py registrants  --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py overture-zip --table landmarks_usa
python3 overture_fetch/ovt_resolve_hosts.py onpremises   --table landmarks_usa
```
Then, and only then:
```
cd /home/boris/geo/src/claude/geo/landmarks
psql -d postgres -f onpremises_hosting_rule.sql
psql -d postgres -f range2zip.sql
```

## Traps and gotchas

- **`rdap-lookup.sh` had three causes, not one.** `deploy.sh` never installed it (deployed tree had no copy); the `-rdap-script` default was cwd-relative `./rdap-lookup.sh`; and from `geo/` that relative path *did* resolve — to a stale duplicate. Fix: install via `deploy.sh` with checksum verification, default to `auto` searching the binary's own directory, make an explicit-but-failing path fatal, delete the duplicate.
- **The stale copy's actual bug**: a `[ test ] && echo` as the *last* command of a loop exits 1 under `set -e` whenever the optional field is absent, so it silently truncated output for any RDAP record with no phone or organization. Silent partial data, not a crash.
- **`os.Stat` is the wrong usability check** for a script invoked as `bash <path>`: it succeeds on a mode-644 file and then the failure surfaces at exec time. Conversely the executable bit is *not* required, because the invocation is `bash <path>` — the instance corrected its own earlier assertion here.
- **libpq's default dbname is the user name, not `postgres`**, and pgx leaves `cfg.Database` empty when `PGDATABASE` is unset — so the log line read `database ""`, hiding the very case worth seeing. Reproduced as `PGUSER=cronuser`, which previously logged `database ""` and now logs `connecting to database "cronuser"`. `trugeo.cron` sets it and every other tool goes through `geo_common.sh`, but `last_carrier_node` is run by hand outside both.
- **`mobile_transit_migration.sql` was not re-runnable as plain top-level SQL.** The second run failed with `column "likely_mobile_cgnat" does not exist` because step 2 still referenced the dropped column. Fix: wrap in PL/pgSQL with an early `RETURN` guard — PL/pgSQL plans statements on first execution, so the guarded statements are never planned. This class of bug is invisible on a first run.
- **Do not run `deploy.sh` while a tool is executing.** GNU `install` writes over the destination in place, and overwriting a running executable returns `ETXTBSY`, so the install fails partway.
- **The IPEDS CSV ships a UTF-8 BOM.** Read as latin-1 the first field becomes `ï»¿UNITID`, so `DictReader["UNITID"]` returns `None`, every row gets an empty id, and the load collapses from 6,075 rows to **1**. Silent data loss with a success message. Fix: decode the BOM, plus a durable guard that `load_rows` refuses the load outright when more than half the ids are blank.
- **`load_rows` defaulted to `replace=True`** — delete every row for the source, then COPY. A first run fetching 30,000 rows followed by a partial second run that managed 20,000 left you with 20,000, losing 10,000. Under a rate limit that is the *normal* case. Compounded because pagination always restarted at offset 0, so repeated partial runs could never accumulate past wherever the service cut out. Fix: stage each batch in a temp table and merge with `ON CONFLICT`, updating only the 15 load columns so enrichment already written by the chain survives.
- **SPARQL `OFFSET` without `ORDER BY` has no defined order**, so pages can overlap or skip and resuming is approximate rather than correct. Fix: `ORDER BY ?item`.
- **A Wikidata street address contains a literal newline**, and inline `COPY ... FROM STDIN` inside a psql script is read line by line while psql hunts for the `\.` terminator — so *correct* CSV quoting still failed with "unquoted newline found in data". Fix: write batches to a temp file and use client-side `\copy`.
- **Honouring `Retry-After` literally is a hang.** WDQS returned `Retry-After: 1000`, so the tool slept 17 minutes with no output, indistinguishable from a hang. Fix: cap the sleep (60s) and report that the service is rate-limiting instead.
- **`--limit` meant an absolute offset ceiling**, so `--resume --limit 500` at offset 961 saw 961 > 500 and exited having merged zero rows — indistinguishable from a failure, and the cause of a "FAIL" in the instance's own test output.
- **Wikidata P281 is the wrong property** for US ZIPs: it returns city-level ranges like `10000–10499`. P6375 (street address) carries the ZIP inline in exactly the freeform shape the existing chain parses.
- **The 502s were NOT mtr.** Boris reported "Something is wrong in your mtr code: so far, repeatedly hitting 502 Bad Gateway". They came from the Overpass API inside `lm_fetch.py osm-overpass`; mtr appears only in `last_carrier_node`. The retry recovered them (15s, 30s) and 15,238 rows loaded. Overpass also requires a `User-Agent`.
- **Overpass times out on California and New York** regardless of retry; those states need the Geofabrik PBF route.
- **Row count is the wrong measure of a landmark source.** The chain resolves website → IP → registrant, so N places sharing one domain yield one landmark address. That is why NPS (~470 parks, all `nps.gov`) is worthless and why "percent unique hosts" is the metric to quote.
- **Running `onpremises_hosting_rule.sql` before the migration silently returns zeros**, not an error — Boris did exactly this and got `(0 rows)` in sections 1, 3, 4, 4b, 4c. Same hazard applies to `range2zip.sql`, which reads `onpremises IS TRUE`.
- **`address_hosting_tbl` was built from `ovt_places_usa` only**, so applying the hosting rule now judges Overture addresses correctly but cannot judge the 275,517 Foursquare or 21,313 OSM/IPEDS places. Correct order: run the chain on `landmarks_usa`, rebuild `address_hosting_tbl` from it, then apply the rule. The rule is idempotent, so applying it twice is safe — it is just incomplete on the first pass.
- **`pip install duckdb` fails on Boris's machine** with `error: externally-managed-environment` (PEP 668). His Foursquare load proceeded anyway, so duckdb must already have been present; the transcript does not say how it got there.
- **`\echo` makes a SQL file non-paste-safe.** The instance replaced `\echo` lines with labelled `SELECT`s in two files specifically to keep them paste-safe.
- **`node_fanout_report.sql` misreported "too wide to cluster" nodes as `mean_clusters 0.00`**, which reads as "no fan-out" when the truth is the opposite. Spotted in Boris's own pasted output and fixed.
- **A visible DNS resolution stall in the live `resolve` run**: ~588,000 hosts consumed with the resolved count frozen at 378,011 for ~119 seconds (446,000 → 1,034,000 done). The transcript does not diagnose or comment on this; it is visible only in the pasted log. Flagging it because it is exactly the shape of a silent resolver failure that would be read as "those hosts don't resolve".
- **Two data defects flagged but not acted on**: `sdnet.net` is tier `f` (fixed) while showing 34 ZIPs across 33 clusters — South Dakota Network is an aggregator the 19-domain `transit_domain` list misses; and Videotron Ltée, a Quebec ISP, holds 45 addresses / 2,855 places in US landmark data, pointing to a country-filtering gap upstream.

## Boris's instructions, preferences and standing orders

- **"Issue precise commands to obtain the output you want; the entire output is too large."** Don't ask for a raw dump; write a query that produces a readable report.
- **"Your instructions on creating a hugging face token for foursquare are unclear. Where is the hf_ value? Where in the new-token dialogue is it supposed to be pasted or copied from? What is the name of the new token? Clarify and reissue all subsequent commands, CLEARLY."** Procedural instructions must distinguish a value you invent and type from a value the service generates and you copy, and must say exactly where on screen each appears. When corrected, reissue the whole downstream sequence, not just the fixed step.
- **"Is this necessary because you know for a fact that 120s is an interval for rate limitation used by any responding service, or for another reason? If not, reduce as much as possible."** Standing order: no invented thresholds. Every magic number must trace to something measured or stated by the service.
- **"Why are you using '--limit 50000'? We want all available records, do we not? Is there a separate abort mechanism if the Wikidata outage persists?"** Default to complete, and make the stop condition explicit and separate from the volume cap.
- **"I want landmarks from all sources for the usa to be in one table. The loaders may differ."** One destination, per-source loaders.
- **Confirmed hosting ⇒ `onpremises = false`, with the modification** that "ISP services by companies that offer hosting under the same registrant name should have onpremises set according to the agreed set of rules. You found two such companies." He named Southwest Cyberport and Synergy Networks, which the instance had deliberately left unnamed.
- **"Report where we are in ingesting all landmark sources in my memo and your additions."** This produced `ingest_status.sql` — he gets status as a query he can re-run, not as prose.
- Landmark sources **must have ZIP codes and websites** — stated as the acceptance criterion for researching new sources.
- **"The last code block (last_carrier_node, node_fanout) is running and will take around 5 hours. Proceed with as much as possible in the meantime."** Keep working on everything that doesn't touch the running job.
- **"Issue precise commands to perform the migration."** Exact command blocks, not descriptions.
- **"All done. Check for any landmarks not imported or processed for RDAP. Ensure all landmarks_usa landmarks are probed in ip-api.com. Then proceed to build matching of range and landmark data on mtr last carrier node to determine the ZIP(s) served by each range."**
- Earlier standing order honoured throughout this slice: the pre-registered power threshold of ~3 landmarks per node, below which fan-out columns are noise — "that is exactly what invalidated the earlier Comcast claim". The instance volunteered the 2.66 mean against its own threshold rather than burying it.
- Boris's design principle that the instance repeatedly cited: the ZIP-cluster rule exists **to replace hardcoded registrant names**, so nothing may reintroduce a second, name-based definition of hosting.

## Open items at end of slice

- **The `resolve --table landmarks_usa` run is still in flight** at line 48100: 4,762,000 of 7,994,314 hosts done, 3,522,736 resolved, 10,849s elapsed. The remaining chain steps (`rdap`, `registrants`, `overture-zip`, `onpremises`) have not run on the unified table.
- **Boris's final three instructions are unanswered within the range**: audit for landmarks not imported or not RDAP-processed; ensure all `landmarks_usa` landmarks are probed in ip-api.com; then build the range↔landmark match on the mtr last carrier node. The instance's reply is beyond line 48100.
- **ip-api.com probing of `landmarks_usa` is entirely untouched** in this slice — it appears only in Boris's instruction.
- **`range2zip.sql` has only been run against fixtures.** It must be re-run after the chain sets `onpremises`, and `address_hosting_tbl` must be rebuilt from `landmarks_usa` first.
- **`onpremises_hosting_rule.sql` has never been applied to real data** — Boris's run hit an empty table and set 0 places false.
- **Wikidata is still not loaded**: 0 rows, the run failed on 429-then-504. `python3 lm_fetch.py wikidata --resume` is the retry.
- **OSM is MA only** (15,238 rows, 8 states present in the table); 49 states + DC remain, with CA and NY requiring the Geofabrik PBF route.
- **Foursquare is MA only** (275,517 rows); national is 10.79 GB / 100 files.
- **Two flagged data defects await Boris's decision**: replacing the hand-curated 19-domain transit list with a measured rule (prompted by `sdnet.net`), and the upstream country-filtering gap (Videotron).
- **The instance's question about the connection defect was never answered**: "What did you actually observe going wrong?" Boris did not reply to it in this range.
- **`node_fanout.sql` / `last_carrier_node` 5-hour job**: completed before Boris ran the report, so this is closed, but the report itself was run only once.

## Uncertain

- The transcript does not say why `fsq_fetch.py releases` reported **4 releases** in the instance's own sandbox probe but **23 releases** in Boris's run. Both outputs agree the newest is 2026-10-15 with 100 files / 10.79 GB.
- Boris's Foursquare load used `--states MA` yet loaded **275,517** rows. The transcript neither comments on this count nor confirms it is MA-only, and I cannot tell from the text whether `--states` was applied as expected.
- The transcript does not explain the ~119-second stall in the `resolve` log where the resolved count froze at 378,011 across ~588,000 hosts. Neither party mentions it.
- The transcript does not say how `duckdb` came to be installed on Boris's machine, given that `pip install duckdb` failed with `externally-managed-environment` and the load then worked.
- The transcript does not state what Boris actually observed for the "configured psql default connection is not used correctly" defect. The instance reproduced a *different*, latent defect and explicitly said it was probably not what Boris saw.
- `onpremises_hosting_rule.sql` section 2 clearly reads `address_hosting_tbl` (it returned real registrant data while `landmarks_usa` was empty), but the transcript does not spell out the exact source of each section's input.
- The "~20 hours of RDAP lookups" figure is carried forward from earlier in the session; it is not re-measured in this range. The 543,336 IP count is stated repeatedly but I did not see it re-derived here either.
- The `44,000 inhabited_zips_approx` denominator behind the 36.3% coverage figure is labelled approximate in the report; the transcript does not say where the 44,000 comes from.
- The transcript does not say whether the `.bashrc` guard command or the 60s-cap change were actually run/pulled by Boris; they were merged but his next message does not show them executing.
