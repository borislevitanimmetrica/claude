# Part 06 (lines 24051-28860)

## Narrative

This slice opens mid-detour on the cron deployment of the TruGeo pipeline on Boris's Linux Mint box (`Immetrica-Mint30`, Postgres 18.6, Go 1.26.6). The instance had just diagnosed a `tee: Permission denied` failure as `/home/cronuser/geo-logs` not being writable by `cronuser`, treated the real problem as the scripts continuing to run with all logging silently discarded, added a fatal writability guard to `geo/pipeline/geo_common.sh`, and relocated logs to `/var/log/trugeo`. It also implemented three mail notifications (start / success / error) to `boris@immetrica.com`, Eastern-timestamped.

The instance then told Boris to run `sudo dpkg-reconfigure postfix` against a working Postfix config without first capturing `postconf -n`, which cleared `relayhost`. Boris: "I think you broke the already working postfix config." The instance first argued the mail log showed no evidence external delivery ever worked; Boris replied flatly "External delivery worked reliably," and the instance accepted the correction without qualification. Diagnosis from `postconf -n`: only `relayhost` had been cleared (SASL settings and `sender_canonical_maps` survived dpkg); mail was going out unauthenticated on port 25 and hitting a `451 4.7.1 greylist` deferral. Fix: restore `relayhost = [smtp.purelymail.com]:587` and `smtp_tls_security_level = encrypt`, add a `root:` alias to `/etc/aliases`, and add `smtp_generic_maps = hash:/etc/postfix/generic` so message headers match the envelope. Boris insisted mail must originate from `info@immetrica.com`, not `boris@immetrica.com`; the instance verified from the maillog that `sender_canonical` already rewrote the envelope correctly and that the header gap was the only real one.

Boris then pointed out that `/home/cronuser` had lost its only purpose once logs moved to `/var/log/trugeo` — `cronuser` has no login — and that he had deleted it. The instance removed every `$HOME` reference from the four pipeline scripts, moving `GEO_CONFIG` to `/etc/trugeo.env` and `LOG_DIR` to `/var/log/trugeo` (merged as `a2964f5`, PR #2), and verified the scripts source cleanly with `HOME` unset under `set -euo pipefail`.

With Boris about to leave for hours, the instance gave one fail-fast paste block that would install cron only if a 45-probe test exited 0. The test failed: `DATABASE_URL is not set`, exit 1. Root cause was that the deployed Go binaries under `/var/trugeo/*/bin/` were stale — rsynced from `~/geo` and never rebuilt — and predated the libpq-fallback fix. A second, more urgent finding: `/etc/cron.d/trugeo` was already installed from an earlier session and had been firing hourly and failing hourly since 2026-09-06. The rebuild attempt then failed too, because Boris's clone at `~/geo/src/claude` was missing the entire Go tool source tree (an anomaly never explained in this slice). The instance sidestepped it with a shallow clone to `/tmp/trugeo-src`, and later had Boris re-clone permanently to `/home/boris/geo/src/claude`.

Two silent bugs surfaced in the shell layer. `daily_pipeline.sh` hardcoded `DRY_RUN=0` and only accepted `--dry-run` as a flag, so the `env DRY_RUN=1` "dry run" the instance had told Boris to paste was in fact a real run that took the mutation lock — harmless only because `bgp_route_views` failed at step 1 on the stale-binary bug. Fixed in `15bfe21`. Second: `log()` in `geo_common.sh` used `tee -a`, which writes to stdout, and cron mails `MAILTO` on any output regardless of exit code — so Boris had been getting a duplicate of every log body on top of every script-sent mail. Fixed in `2217fb7` by appending `>/dev/null` to each cron job, deliberately leaving stderr alone so the unwritable-`LOG_DIR` guard can still reach him.

Database permissions took three rounds. `GRANT boris TO cronuser` was already in place but did not fix `ERROR: permission denied for schema public` — because `boris` is `rolsuper=t` and superuser status is not inherited through role membership. Explicit `GRANT USAGE, CREATE ON SCHEMA public` plus table/sequence grants and `ALTER DEFAULT PRIVILEGES` fixed it. The instance then flagged that its own earlier `GRANT boris TO cronuser` had given the unattended cron account a `SET ROLE` path to superuser, and replaced it with a dedicated `geo_owner NOLOGIN` role owning the five pipeline tables, with `REVOKE boris FROM cronuser`. Verified: `pg_has_role('cronuser','boris','member')` = `f`, `geo_owner` = `t`.

The longest thread was `bgp_route_views`. Boris asked for an immediate run to check for bugs. A `-dry-run -limit 20000` exercised fetch/decompress/MRT-parse cleanly. The real run then exposed that `-limit` truncation fell through to `setState` + `Commit`, advancing the ingest watermark past a partially-applied file — silent data loss of roughly 16,000 records per truncated file, twice. Fixed, and `-limit` declared unsafe for real runs. Boris then observed what looked like repeated reprocessing; the instance initially claimed from `strings` output that per-file commits were proven, retracted that (the deployed binary was built from a dirty tree, `vcs.modified=true`, revision `76a399f`, so its source was unrecoverable), and Boris chose option 2 — stop tracking binaries in git and build on deploy — leading to `geo/pipeline/deploy.sh` and `f528f1f`. The instance then twice diagnosed a performance pathology that did not exist: first merging an index fix (`01cec82`) against a missing-index hypothesis that Boris's `pg_indexes` output immediately refuted, then rewriting the per-prefix write path into a staged COPY + set-based DELETE/INSERT (`8093b2f`). The truth, established when the run finally reported `no new updates files after 2026-09-08T03:00:00Z`, was that the original path had processed all 721 files in about 2h20m (~12s/file, ~3,000 statements/sec) and the only real defect was missing progress output.

Once the pipeline was running, measured evidence confirmed everything worked: the bulk apply survived its first unattended 02:00 run, `daily_pipeline` completed end to end including `check_range_splits` and `apply_splits` (the two tools previously blocked by `postgres`-owned tables), and `probe_batch` drained at exactly the ip-api free ceiling, 2,400 ranges per 3,199s, exit 0. Boris reported "probe_batch dies"; the instance showed every `FATAL` in the log was historical (newest 26 hours old, from the stale-binary era) and that the probe was alive mid-batch. Boris challenged the claim of "only 4 fatal exits"; the instance corrected itself to 5 call sites and distinguished call sites from occurrences.

Boris then ordered four things: add newly-identified DoD ranges to the exclusion table, fix the latent defect where an empty backlog exits 1, keep emails as-is until commercial ip-api access is secured (with commented-out switches prepared), and provide recompile commands. Delivered as `73c91ee` with `NOTIFY_START` / `NOTIFY_SUCCESS` gates, a `notify_cycle` end-of-cycle signal, and `geo/geo_exclusions_seed_dod_probed.sql` built from probe evidence including ASN rules.

The second half of the slice is a substantial schema redesign Boris specified: a new `ip2city_dbiplite_probe_tbl` (seeded from the reconciled `ip2city_dbiplite_tbl`, probed, then archived into `ip2city_dbiplite_history_tbl` at cycle end), replacing `ip2city_dbiplite_traceroute_tbl` everywhere including the DMA export path. The instance identified a blocking conflict — a full probe cycle takes ~36 days at the free tier, so a daily truncate would discard 97% of each cycle's work — and Boris chose option (a): gate the rebuild on cycle completion. That gate created a deadlock class: any row probing can never select would hold `ran_at IS NULL` forever, so the populate had to mirror `sampleRanges` exactly. Boris then specified the filter set: DoD excluded, CGNAT *not* excluded (reversing an earlier decision he had forgotten to communicate), IPv6 out of scope but reversible via config, non-US not populated.

Implementation proceeded through `rebuild_probe_tbl.sql` (`a0c30a0`), filter alignment (`6a2b9a8`), an ASN-exclusion performance fix replacing a correlated `NOT EXISTS` with a materialised temp table (`445cd9d`), and two successive wrong progress metrics — `n_tup_ins` (backend-local until commit) and `pg_relation_size` (blocks on the `TRUNCATE`'s ACCESS EXCLUSIVE lock) — before settling on WAL LSN and `pg_database_size` (`19b82eb`, `fd4e863`). Boris caught that probing had never actually been retargeted (`select * from ip2city_dbiplite_probe_tbl where ran_at is not null` returned no rows); the instance admitted it had been asking for decisions its own spec already answered and implemented step 2 in `d0dbf61`, including replacing `city IS NOT NULL` with `ran_at IS NOT NULL` as the "measured" discriminator in the three `dma_export` queries. Boris added `start_ip`/`end_ip` columns and asked the instance to decide when `query` is chosen; it chose rebuild time, so probe targets are auditable in advance and reproducible (`b3800c7`). That retarget introduced a seven-minute hang in `sampleRanges` from another correlated subquery in `ORDER BY`; fixed in `42a7521` by dropping the RouteViews-first prioritisation.

The slice ends with a scratch test of the never-executed archive path. Boris: "Do the scratch test and if success, make rollover automatic. Do not harm existing data." The instance built `scratch_test_rollover.sh` using a `scratch` schema, and on Boris's safety instruction rewrote it to run with `search_path = scratch` alone — its first draft used `scratch, public`, which would have let the unqualified `TRUNCATE ip2city_dbiplite_probe_tbl` fall through to `public` and destroy 2,089,296 live rows. The first run FAILED one assertion, catching a real masklen bug: `network(s.network)` retains the prefix length, so every `query` sorted below its own `start_ip`. Fixed in `cf0bfc6`; the re-run passed all 30 assertions and appended `export PROBE_TBL_REBUILD=1` to `/etc/trugeo.env`, enabling automatic rollover. The instance also had to retract its earlier claim that production's `query_out_of_range = 0` verified the offset arithmetic — it was a false pass caused by `start_ip`/`end_ip` being NULL on all 2,089,296 live rows. Boris chose the in-place patch (`198fd1c`, written but not yet run at the end of the slice). His final instruction in range begins new work: a front end — API plus GUI — taking a single `dma_code` and returning the individual IPv4 addresses in that DMA.

## Decisions and rationale

- **Logs to `/var/log/trugeo`, declared in two places.** Rationale: `LOG_DIR` in the cron file does not apply to `sudo -u cronuser` manual tests, which is exactly why the earlier failure appeared. Boris accepted the directory but rejected the second declaration location: he had already deleted `/home/cronuser` since it lost its purpose once logs moved and `cronuser` has no login. **Modified** → `GEO_CONFIG` became `/etc/trugeo.env` and all `$HOME` references were removed from the scripts (`a2964f5`).
- **Fatal guard when `LOG_DIR` is unwritable.** Rationale given: "Every log line would be lost and the job would run blind, so this is fatal." Accepted. Verified as an unprivileged user after the instance noted its first test was invalid because root bypasses directory permissions.
- **`dpkg-reconfigure postfix` on a working config.** The instance's own decision, later retracted as an error: it should have captured `postconf -n > backup.txt` first. Boris rejected it loudly ("Fix it!!!"). Net damage was limited to `relayhost` being cleared plus cosmetic `mydestination`/`myorigin` changes.
- **Keep notifications verbose for the unattended run.** Rationale: "I'd rather not change notification behavior untested minutes before you leave." Accepted implicitly. Later Boris gave the standing decision: emails stay as now until commercial ip-api access is secured, then switch to start and end of the full probing cycle only.
- **Error-mail bodies include the diagnostic after the `Geo error` line**, because "a bare Geo error gives you nothing to act on at 02:00." Offered for reversal; Boris did not object.
- **Start mail fires only after locks are acquired**, so a lock-skipped run sends nothing rather than producing a "starting" with no matching "finished."
- **`geo_owner NOLOGIN` role instead of `GRANT boris TO cronuser`.** Rationale: `boris` is `rolsuper=t`, and any member of a superuser role can `SET ROLE` to it, giving the passwordless unattended account a superuser path. The instance named this as a security problem it had introduced. Accepted and executed by Boris. This **overrode** its own earlier grant recommendation.
- **Build-on-deploy instead of tracking binaries in git (option 2).** Offered as a choice: (1) rebuild all six tracked binaries and commit, adding ~100 MB of permanent git blobs on top of ~72 MB already there; (2) untrack binaries and build during deploy. Instance leaned to 2 because "every failure in this session traced back to a binary that didn't match its source." Boris: "Yes, 2." The argument was strengthened when the old binary turned out to be `vcs.modified=true` at revision `76a399f`, so its behaviour could not be diagnosed at all.
- **`-limit` must never be used in a real `bgp_route_views` run.** Rationale: its purpose is truncation, and truncation corrupted the watermark. Use `-dry-run -limit` for cheap checks instead.
- **Do not deliberately reprocess the ~2 files damaged by `-limit`.** Rationale: `bgp_route_views` holds current routing state, so any prefix re-announced later in the remaining files overwrites the gap; only prefixes announced exactly once in that window stay missing, and `-mode full` resyncs definitively. `-since 20260831.1200` would redo 706 files to fix a fraction of one. Boris did not object.
- **Option (a) for the probe-table rebuild gate** — rebuild only when the previous cycle has finished — rather than (b) implement the daily truncate as literally specified and not deploy until commercial access exists. Rationale: at 45 calls/min a daily truncate would discard 97% of each cycle's work, no cycle would ever complete, and step 3 would never fire. Boris: "option (a). Do not truncate, repopulate until next RouteViews BGP update has run following a full probing cycle." **Accepted as modified** — rollover deferred to the first BGP update after cycle completion.
- **Populate must mirror `sampleRanges` filters exactly.** Rationale: any row loaded but never selectable holds `ran_at IS NULL` permanently and freezes every future rebuild. Explicitly noted that the DoD exclusions Boris had just added would themselves have frozen the pipeline.
- **CGNAT filter removed from all three gate-relevant places simultaneously** (populate, `sampleRanges`, `remaining()`). Rationale: removing it from the populate alone would deadlock the gate. Boris's instruction was the reversal itself: "The decision to exclude them was reversed but I forgot to tell you."
- **IPv6 scope controlled by one switch in `geo_common.sh`, not per-script.** Rationale: it drives both the populate's `geo.family` GUC and the probe's `-ipv4-only` flag; setting family in one place only is what deadlocks the gate.
- **`query` (the probe address) chosen at rebuild time, not per probe.** Instance's own decision when Boris asked it to decide. Rationale: satisfies `NOT NULL` with a meaningful value instead of a base-address placeholder; probe targets become auditable before traffic is sent; retries hit the same address so results are reproducible; history records the address actually used. Consequence accepted: the Go code must stop generating its own random address, or the stored `query` would be a lie.
- **RouteViews-first probe ordering dropped rather than rewritten as a join.** Rationale: it existed because the backlog was never fully drained, so a fresh /24 could wait months at random; with the probe table rebuilt once per cycle and every row probed inside that cycle, ordering changes position only, never whether a range is reached. Flagged as not holding for rows that never entered a cycle (see Open items).
- **`ran_at` stamped on every probe outcome, including API errors and failures.** Rationale: a permanently failing range would otherwise never leave the backlog and would block the cycle forever.
- **`ran_at IS NOT NULL` replaces `city IS NOT NULL` as the "measured" test.** Rationale: step 1 seeds `city` from db-ip for every range, so `city IS NOT NULL` becomes true for unprobed rows and silently mislabels them as measured in the DMA output. Boris implicitly accepted by instructing the switch to the probe table everywhere.
- **Scratch-schema test rather than a scratch country.** Rationale: the gate blocks a rebuild while 2M+ rows are unprobed, so a country-scoped test would have required faking cycle completion on production data. Exercises the real rebuild SQL unchanged against real schemas, with zero ip-api spend.
- **`search_path = scratch` with no `public` fallback, and all six tables copied.** Direct response to Boris's "Do not harm existing data." Rationale: `rebuild_probe_tbl.sql` uses unqualified names, so with `public` in the path a missing scratch table would resolve the `TRUNCATE` to production. Copying read-only tables like `trugeo_states_tbl` is the price of keeping `public` out of the path.
- **In-place patch over forcing a rebuild** for the live rows missing `start_ip`/`end_ip`. Rationale: forcing a rebuild would discard ~7,000 completed probes (~2.5 hours of API budget); the in-place patch preserves them and re-randomises `query` only `WHERE ran_at IS NULL`. Boris: "In-place patch, if next rebuild these fields will be populated automatically." Already-probed rows deliberately keep their `.0` targets because `query` records what was actually sent to ip-api.
- **Reindex rather than drop the primary key** on `bgp_route_views`. Rationale: reindexing recovers the space without giving up the constraint. Status of execution unclear — see Uncertain.

## Measured facts and numbers

**Mail / Postfix (2026-09-06)**
- Queued test message `4193F1E1361`, size 393, deferred with `dsn=4.7.1, status=deferred (host mailserver.purelymail.com[18.204.123.63] said: 451 4.7.1 Try again later (greylist))`.
- After restoring `relayhost`: two successes `to=<boris@immetrica.com>, relay=smtp.purelymail.com[18.204.123.63]:587, dsn=2.6.0, status=sent (250 2.6.0 Message received)` at 12:05:17 and 12:08:52.
- The `cronuser` test was `uid=997 from=<cronuser@Immetrica-Mint30>` rewritten by `sender_canonical` to `from=<info@immetrica.com>`, sent.
- Postfix version 3.8.6. `relayhost` before damage and after restore: `[smtp.purelymail.com]:587`.
- `root: boris@immetrica.com` added at line 3 of `/etc/aliases`.
- Email volume: 25/day estimated at first (24 hourly probe batches × 2 plus the daily pair), revised to 48/day with daily+monthly, then revised to **~72/day** once the `tee`-to-stdout duplicate cron mail was discovered (three mails per probe_batch hour). All three figures are estimates of steady state, not measurements.

**Probe backlog (all measured from `probe_batch.log` / SQL)**
- `backlog before=2100444` — 2026-09-06T16:27 and still 2,100,444 on 2026-09-07T14:48 (nothing drained during the stale-binary period).
- `IPv4 ranges still awaiting an ip-api city=2072326` — 2026-09-08T06:17:44, end of the first successful daily_pipeline.
- Hourly progression 2026-09-08 (UTC): `2063312 → 2060912 → 2058512 → 2056112 → 2053712 → 2051312 → 2048912 → 2046512`, each batch `2400` ranges in `3199s`–`3200s`, exit 0. That is 45 calls/min exactly.
- After the probe-table rebuild the backlog read **2,089,296** (table total), then `2089251 → 2086851 → 2084448`.
- `probe table: probed=7053 awaiting a probe=2082243` — 2026-09-09T01:53:39.
- Probed-row counts observed at successive scratch-test fingerprints: `4848` (asserted in passing), `6243`, `6918`, `7053`.
- Drain estimate: 2,400/hour × 24 = **57,600/day**; against ~2,050,000 ranges ≈ **36 days** (also quoted as ~40 days net of the ~6,458/day added by `apply_splits`). Estimate, not measurement.

**bgp_route_views**
- Dry run `-mode updates -dry-run -limit 20000`: `3 files after 2026-09-07T18:24:51Z`, `announced=19115 withdrawn=885 over 3 files` — sums to exactly 20,000, i.e. `-limit` truncated inside the first file.
- Ingest watermark progression: `2026-08-31T12:00:00Z` → `12:15:00Z` → `12:30:00Z` (each a single 15-minute file advanced by a `-limit` run) → `2026-09-08T03:00:00Z` (fully caught up).
- File counts listed at successive runs: `707`, `706`, `720`, `721`, `705`. Each file holds roughly 19,000–20,000 records.
- Row counts: `select count(*) from bgp_route_views` = **1121587** (2026-09-07 20:5x); `n_live_tup` = **1139516** (2026-09-08 13:12); pipeline counters `bgp=1121547` (09-07 before) → `bgp=1138650` (09-08 after) → `bgp=1140132` (09-09 01:53).
- Full 721-file catch-up: started 21:07:34, finished before 23:29:37 → **roughly 2h20m, about 12s per file**, which the instance computed as ~3,000 statements/sec over the Unix socket for the old per-prefix path.
- Bulk-apply timings, first unattended run 2026-09-08 02:00 (measured, from `daily_pipeline.log`): `staged 8191 rows in 15ms / deleted 8178 superseded rows in 560ms / inserted 8191 rows in 353ms`; `staged 13965 in 54ms / deleted 13957 in 582ms / inserted 13965 in 540ms`; `staged 18152 in 39ms / deleted 18132 in 557ms / inserted 18152 in 675ms`; `staged 19327 in 50ms / deleted 19321 in 562ms / inserted 19327 in 799ms`; `staged 18818 in 53ms / deleted 18806 in 581ms / inserted 18818 in 726ms`. ≈1.6s DB work, 3–4s wall clock per file versus ~12s before.
- Table size: `total 744 MB`, `heap 183 MB` → 561 MB of indexes against a 183 MB heap.
- `n_live_tup 1139516, n_dead_tup 0, last_vacuum (null), last_autovacuum 2026-09-08 13:12:15.237011-04, last_analyze (null)`. Autovacuum kept up with the whole ~13.7M delete+insert churn unaided; the instance's bloat concern was resolved with no action.
- Index scan counts and sizes (measured): `bgp_route_views_pkey idx_scan 0, 212 MB`; `idx_bgp_range idx_scan 0, 72 MB`; `bgp_route_views_cidr_peer_idx idx_scan 416925, 72 MB`; `bgp_rv_cidr_gist idx_scan 6841880, 204 MB`. Instance's assessment (estimate): a btree on a single integer over 1.14M rows should be ~25 MB, so the pkey is bloated ~8×.
- Churn estimate: 721 files × ~19,000 announcements ≈ **13.7 million** delete+insert pairs; ~27 million round trips across the backlog under the old path, replaced by 3 statements per file instead of ~38,000.

**daily_pipeline, 2026-09-08 02:00 run (measured)**
- `check_range_splits` `DONE ... in 1000s`; wrote `679 candidates to dbip_split_candidates`.
- `apply_splits`: `loaded 960 active prefix exclusions`; `636 candidate ranges still present as db-ip rows`; `skipped: 82 already /24 or narrower, 253 excluded, 0 over -max-probes`; `to decompose: 301 parents into 6458 /24 rows`; completed in `6s` (step reported `DONE apply_splits in 8s`); `parents decomposed: 301, parents deleted: 301, /24 rows inserted: 6458`.
- Counters: `before: bgp=1121547 dbip_rows=5447694 routeviews_rows=489348`; `after: bgp=1138650 dbip_rows=5447393 routeviews_rows=495806`; `split candidates=679`.
- 2026-09-09 01:53 dry run: `before: bgp=1140132 dbip_rows=5447346 routeviews_rows=496332`, `split candidates=383`.

**Postgres roles and ownership (measured 2026-09-07)**
- `boris rolsuper=t rolinherit=t rolcreaterole=f`; `postgres t/t/t`; `cronuser f/t/f`.
- `public` schema: owner `pg_database_owner`, acl `{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner}`.
- 17 tables in `public` before the change; ownership split between `boris` (6) and `postgres` (11). After moving five to `geo_owner`: 18 tables listed, `bgp_route_views`, `bgp_rv_ingest_state`, `dbip_split_candidates`, `ip2city_dbiplite_tbl`, `range_classification` owned by `geo_owner`.
- Verification: `has_schema_privilege('cronuser','public','CREATE')|USAGE|pg_has_role(...,'boris')` → `t|t|t` before the revoke; after: `pg_has_role('cronuser','boris','member')|pg_has_role('cronuser','geo_owner','member')` → `f|t`.
- DDL inventory across the Go tools (counted by the instance from source): 5 `CREATE TABLE`, 6 `CREATE INDEX`, 2 `DROP TABLE`, 1 `ALTER TABLE ... RENAME`. The shell scripts issue only `SELECT`s — verified, making the Go tools the exhaustive set of ownership-requiring operations.

**Probe-table redesign (measured)**
- `ip2city_dbiplite_tbl`: 17 columns; has `city` and `state`; has **no** `zip`, `isp`, `org`, `as`, `region` or `timezone`. Row count `dbip_rows=5447694` → `5447346`.
- `trugeo_states_tbl`: 3 columns (`state`, `state_code`, `state_fp`), **57 rows**, PK on `state`, holds full state names ("Alabama", "District of Columbia", "Commonwealth of the Northern Mariana Islands").
- `ip2city_dbiplite_probe_tbl` and `ip2city_dbiplite_history_tbl` column sets are **byte-identical** — both `EXCEPT` queries returned 0 rows.
- History PK was `PRIMARY KEY (network)` (single column), confirmed by `pg_dump`; changed by Boris to `(network, ran_at)` — later verified in the scratch test as spanning 2 columns.
- Probe/history types confirmed: `start_ip inet YES`, `end_ip inet YES`, `query inet NO` (NOT NULL), in both tables.
- Live probe table after the first rebuild: `total 2089296, null_start 2089296, null_end 2089296, query_is_base 0, query_masked 0`. The earlier `query_out_of_range 0` on the same table was a **false pass** (comparisons against NULL yield NULL).
- `ip2city_dbiplite_traceroute_tbl`: **63,875 rows**; `ip2city_dbiplite_traceroute_tbl_pkey idx_scan 65206, 1848 kB`; `..._network_gist idx_scan 9688, 2104 kB`. Stops growing once probing retargets.
- IPv6 share of `ip2city_dbiplite_tbl`: "~3.7M of the 5.47M" — asserted by the instance, not shown as a query result.
- `sampleRanges` after the fix: `sampling returned 2400 ranges in 1.504s` and `1.488s`. Before the fix the same query ran **7 minutes without returning**.
- ASN exclusion expansion: `ASN exclusion rules expand to 8189 prefixes, resolved in 00:00:00.050033` (also 0.037776s, 0.050074s, 0.050847s, 0.056491s, 0.038084s across runs).
- DoD ASN breakdown (measured, 38 rows): AS749 **3132** prefixes, AS367 1075, AS56 935, AS27046 513, AS647 429, AS306 277, AS5371 234, AS721 232, AS1600 169, AS1501 167, AS27086 142, AS6035 102, AS745 79, AS6039 68, AS27065 60, AS6041 57, AS5180 56, AS27142 56, AS6040 55, AS665 41, AS391 41, AS4010 39, AS300 35, AS1590 34, AS1493 33, AS27087 31, AS138 18, AS129 16, AS2749 14, AS6042 14, AS627 6, AS289 6, AS5237 6, AS485 5, AS22 5, AS228 4, AS273 2, AS400 1. Every reason string names DoD, USAISC, Navy or Air Force; the instance concluded nothing was over-broad.
- DoD leakage in a visible 39-record log window: 3 DoD ranges ≈ **7.7%**, explicitly flagged as indicative, not measured. If genuinely near 5% that is ~100,000 wasted probes ≈ two days of API budget (estimate).
- Scratch test: 200 seeded rows, 2 cycles archived → `history holds both cycles (got 400)`. Populate of 200 rows took `00:00:00.016544`, `0.035993`, `0.024202`, `0.01728`, `0.03513`. First run: **1 failed assertion** of ~27; second run: all **30 assertions PASS**.
- Live-data fingerprint held at every scratch checkpoint: `2089296 rows, 6243 probed` (run 1) and `2089296 rows, 6918 probed` (run 2), unchanged start to finish.
- Rebuild populate estimate for the real ~2.05M rows: **1–3 minutes**, explicitly flagged as an extrapolation from the measured `19327 rows in 799ms` ≈ 24,000 rows/sec. Treat beyond ~10 minutes as pathological.
- History growth estimate: ~2M rows per cycle; ~750M rows/year with daily cycles under commercial access (earlier stated as ~5.9M/cycle and ~2.1 billion/year before the scope filters were applied). Estimates.
- Environment: `go version go1.26.6 linux/amd64`; Postgres `18.6 (Ubuntu 18.6-1.pgdg24.04+2)`.
- Git repo size noted when weighing option 1 vs 2: ~72 MB already in history, option 1 would add roughly 100 MB. Estimates.

**sha256 values recorded (verbatim)**
- `geo_common.sh` `4d19a3eeeb6c2ff1a133b966fe3620fe6beace5bf2f096e7decb1c373ed9a539`
- `daily_pipeline.sh` `cb4d7321cabfbbec57b08b575988b4675969e1d3c4b2b520ee02840c7ad048a0` (at `a2964f5`), later `c1c0d785bf30f6ef25b01dcfb68c8d0f52cc8e1023e623448b7929589088814c` (at `2217fb7`)
- `probe_batch.sh` `46a9bb29b533e4d76e4e5e480010bba28b7e83960f91ab2f97474ff06b51f9e5`
- `monthly_dbip.sh` `2532984038631d1e020fed86996c7819b89bdae4703af79cfa90b8b0a60d99cd`, later `9f604e30e64233c83b8b4ca80a701268a465a60dc4a2f808495a5aa37ed5c838`
- `trugeo.cron` `71bbb9c0cb1171fbeecf05a6f1a2fec1b2c935b18b57c8dcb7f205b41c4e0289` (pre-fix) → `9aa4faf67e034c07c63bdece3141aed82622831dbffea86b2a9b0ddeacf99286` (with `>/dev/null`)
- tracked `check_geo_ip-api` binary `0294e0da07b91b1f48092eb79dae3df68f48a16e3a0c3eef12309da012d6b20e`; later `bgp_route_views` binary `dbefa05f05d38b34c6a5a61cd8bee869344d00db212664dc26b46ea5285b987a`

## Code, files, tables

**Files created or changed (paths as given in the transcript)**
- `geo/pipeline/geo_common.sh` — shared shell library. Gained: a fatal guard that aborts if `LOG_DIR` exists but is not writable by the running user; `GEO_CONFIG` default moved from `$HOME/.geo-pipeline.env` to `/etc/trugeo.env`; `LOG_DIR` default moved from `$HOME/geo-logs` to `/var/log/trugeo`; all `$HOME` references removed; `notify_start` / `notify_success` / `notify_error` / `notify_cycle` mail functions; `NOTIFY_START` and `NOTIFY_SUCCESS` gates (default 1, `notify_error` and `notify_cycle` deliberately ignore them); `PROBE_IPV4_ONLY` (default 1, validated to 0 or 1, exits 2 otherwise) — **this is the single IPv6 switch**; `psql_file` fixed to emit one `-c` per `SET` because `SET a = 'x', b = 'y'` is not valid SQL. Installed mode 0644.
- `geo/pipeline/daily_pipeline.sh` — 02:00 job. `DRY_RUN`, `BGP_MODE` and `MONTH` now honour the environment (`${VAR:-default}` form); flags still override; a bad value exits 2 **before the lock is taken**. Gained the gated `rebuild_probe_tbl` step controlled by `PROBE_TBL_REBUILD` (line ~38, default 0). Logs `probe table: probed=N awaiting a probe=N`.
- `geo/pipeline/probe_batch.sh` — hourly job. `remaining()` retargeted from `ip2city_dbiplite_traceroute_tbl` + `country_iso_code` to `ip2city_dbiplite_probe_tbl` + `countrycode` with `ran_at IS NULL`; CGNAT filter removed; passes `-ipv4-only` derived from `PROBE_IPV4_ONLY`; logs `probe scope: country=US ipv4_only=1`; sends `cycle complete` via `notify_cycle` when the backlog reaches zero; the lock-contention exit path now names the holding pids and their elapsed time and states that no probe output follows.
- `geo/pipeline/monthly_dbip.sh` — monthly db-ip import (midnight on the 2nd). Does `DROP TABLE ip2city_dbiplite_tbl` then renames `ip2city_dbiplite_tbl_load` into place — the operation that required table ownership.
- `geo/pipeline/trugeo.cron` → installed to `/etc/cron.d/trugeo`, mode 0644, root:root. Contents: `PATH`, `SHELL=/bin/bash`, `HOME=/var/trugeo`, `MAILTO=root`, `CRON_TZ=America/New_York`, `PGDATABASE=postgres`, `LOG_DIR=/var/log/trugeo`; jobs `0 2 * * * cronuser /var/trugeo/pipeline/daily_pipeline.sh >/dev/null`, `5 * * * * cronuser /var/trugeo/pipeline/probe_batch.sh >/dev/null`, `0 0 2 * * cronuser /var/trugeo/pipeline/monthly_dbip.sh >/dev/null`. Commented-out switches below `LOG_DIR`: `# NOTIFY_START=0`, `# NOTIFY_SUCCESS=0`, and at line 49 `# PROBE_TBL_REBUILD=0`/`=1`, plus `# PROBE_IPV4_ONLY=0`.
- `geo/pipeline/deploy.sh` — **new**. Builds all eight Go tools from the checked-out commit into a temp dir and installs binaries, pipeline scripts, the SQL files and the cron file. Refuses to build from a modified tree; `ALLOW_DIRTY=1` overrides with a warning; re-checks each built artifact's `vcs.modified` (the initial awk field test was inert because `go version -m` emits `vcs.modified=false` as one tab-delimited token — fixed, now aborts). `--build-only` builds without installing and needs no sudo.
- `geo/pipeline/rebuild_probe_tbl.sql` — **new**. One `DO $rebuild$` block, one transaction, doing: gate check (`ran_at IS NULL` present → log `probing cycle still in progress, leaving the probe table intact and skipping the rebuild` and change nothing); archive every probe row into `ip2city_dbiplite_history_tbl`; `TRUNCATE`; repopulate from `ip2city_dbiplite_tbl` seeding `city`, `state`, `state_code` (via `trugeo_states_tbl`), `start_ip`, `end_ip`, a random `query` per range, `status='pending'`, `ran_at NULL`. Filters mirror `sampleRanges`: IPv4 only (via `geo.family` GUC), country match (`geo.country`), no `geo_exclusions` prefix or ASN match. ASN rules materialised once into an indexed, ANALYZEd temp table instead of a correlated `NOT EXISTS`. Emits per-phase NOTICEs with elapsed times and an explicit warning not to query the table for progress. Refuses to run while the history PK is single-column. Uses `host(...)::inet` so `query`/`start_ip`/`end_ip` are /32 host addresses, with a `least(..., 4294967296)` bound on the random offset.
- `geo/pipeline/patch_probe_tbl_range_fields.sql` — **new** (`198fd1c`), **not yet run**. One-off in-place patch: populates `start_ip`/`end_ip` for all live rows and re-randomises `query` only `WHERE ran_at IS NULL`; never clears `ran_at`; verification runs inside the transaction and raises (rolling back) if any row lacks bounds, any target falls outside its range or carries a prefix, or the probed count falls.
- `geo/pipeline/scratch_test_rollover.sh` — **new**. Nine-step test of the rollover in a `scratch` schema with `search_path = scratch` alone. Takes a live fingerprint (row count + probed count on `public.ip2city_dbiplite_probe_tbl`) up front and re-checks it after every rebuild, aborting on `LIVE DATA CHANGED`. Asserts all six table names resolve to `scratch` before any rebuild. Asserts `cronuser` has INSERT on the real history table and that the real history PK spans 2 columns. Simulates probing with an `UPDATE` rather than real ip-api calls. `ENABLE_ON_PASS=1` appends `export PROBE_TBL_REBUILD=1` to `/etc/trugeo.env` only on a full pass.
- `geo/geo_exclusions_seed_dod_probed.sql` — DoD exclusion seed built from probe evidence, deliberately staged in four steps: (1) review query showing `distinct_cities` per operator, (2) explicit /24 prefix rules, (3) `origin_asn` rules with `HAVING count(DISTINCT tr.city) <= 2` as the safety rail, (4) a report of ranges removed from the backlog. Later amended to read both the traceroute table and the probe table, since new probes no longer populate the former. Deliberately does **not** exclude `138.0.0.0/8` or `206.0.0.0/8`.
- `geo/bgp_route_views/cmd/main.go` — per-file progress logging every 2000 records with elapsed time and rec/s; a `fetching and applying (file N of M)` line before the work (previously nothing was logged between listing files and the first commit); `resuming from stored state for collector ...: last_file_ts=...` so a stored resume is distinguishable from an operator `-since`; `-limit` truncation no longer advances the watermark and logs `WATERMARK NOT ADVANCED`; `ensuring index bgp_route_views_cidr_peer_idx exists before applying updates` added at the start of an updates run (matching what `schema.sql` already documented); write path rewritten to stage rows during parse then apply per file as COPY into a temp table → `ANALYZE` → one set-based `DELETE ... USING` → one `INSERT ... SELECT`. Flags: `-mode updates|full`, `-collector`, `-since`, `-peer`, `-per-peer`, `-dry-run`, `-limit`, `-http-timeout`. State table `bgp_rv_ingest_state` (`collector`, `last_file_ts`, `updated_at`), upserted `ON CONFLICT (collector) DO UPDATE`, created unqualified at main.go:720 (hence the `public` CREATE requirement).
- `geo/check_geo_ip-api/cmd/main.go` — reads and writes `ip2city_dbiplite_probe_tbl`. `sampleRanges` selects `WHERE ran_at IS NULL` and deliberately repeats none of the family/country/CGNAT/exclusion filters (the rebuild already applied them); logs `sampling N ranges from ... (country="US" ipv4-only=true)` and `sampling returned N ranges in ...`. `writeGeo` is now an `UPDATE` of the seeded row: measured `city`/`state`/`zip`/`lat`/`lon`/`isp`/`org`/`as` overwrite the db-ip seed, `last_hop_ip` takes the probed address, `query` keeps the rebuild-time value, `ran_at` is stamped on every outcome including errors; a zero-row UPDATE is reported as an error. Probes the stored `query` verbatim instead of generating an address — `randomAddrInRange` survives only as a logged fallback. Empty sample no longer `log.Fatal`s: logs and returns 0. Fatal call sites (verified, 5): `-count must be > 0`, `-rate must be > 0`, `PostgreSQL connection failed`, `sampling ranges: %v`, and formerly `no eligible ranges found`.
- `geo/dma_export/dma_ip_table.sql` — `(tr.city IS NULL) AS dbip_only` → `(tr.ran_at IS NULL)`, retargeted to the probe table.
- `geo/dma_export/dma_ranges.sql` — `count(...) FILTER (WHERE tr.city IS NOT NULL) AS with_measured_city` → `FILTER (WHERE tr.ran_at IS NOT NULL)`.
- `geo/dma_export/dma_cidrs_measured.sql` — join switched from `city` to `ran_at`, `coalesce` switched from `regionname` to `state`. Was the one query that would have stayed correct unchanged.
- `.gitignore` — edited to untrack `geo/*/bin/` binaries (0 remained in the index afterwards).
- `/etc/trugeo.env` — root:root, 0644, 27 bytes initially. Contents at end of slice: `export PGDATABASE=postgres` and `export PROBE_TBL_REBUILD=1`.
- `/etc/postfix/generic` — created, mirroring `sender_canonical`: `@Immetrica-Mint30 info@immetrica.com`, `@mint30.immetrica.com info@immetrica.com`.

**Tables**
- `ip2city_dbiplite_probe_tbl` (new, created by Boris, owner `boris`, PK `(network)`, GiST index `ip2city_dbiplite_probe_tbl_network_gist` on `network inet_ops`). 27+ columns: `network cidr NOT NULL`, `query inet NOT NULL`, `last_hop_ip`, `last_hop_hostname`, `city`, `state_code`, `state`, `zip`, `lat`, `lon`, `country`, `countrycode`, `timezone`, `rdap_lookup`, `hop_count`, `probe_method`, `status NOT NULL`, `isp`, `org`, `"as"`, `likely_mobile_cgnat`, `last_hop_number`, `is_infrastructure`, `is_unreachable_local_carrier`, `classification_note`, `attempts`, `ran_at timestamptz` (nullable — this is the measured/unmeasured discriminator), plus `start_ip inet` and `end_ip inet` added by Boris mid-slice. Note the live table has **no** `region`/`regionName` column despite the DDL Boris pasted by hand; `pg_dump` showed `state`/`state_code` already present, so the instance discarded its planned rename migration.
- `ip2city_dbiplite_history_tbl` (new, same columns, `ran_at` NOT NULL). PK changed from `(network)` to `(network, ran_at)` by Boris — without this only one cycle could ever be archived.
- `trugeo_states_tbl` (new to the instance): `state text NOT NULL`, `state_code text NOT NULL`, `state_fp text NOT NULL`, PK `(state)`, 57 rows.
- `dma2city_tbl` — Boris supplied the DDL at the end of the slice as the `dma_code` translation table: `dma`, `dma_code integer`, `state`, `state_code`, `county`, `metro`, `census_placename`, `city`, `city_type`, PK `(state_code, county, dma, city, city_type)`. To be joined to `ip2city_dbiplite_probe_tbl` on `city` and `state_code`.
- `bgp_rv_ingest_state` — moved to `geo_owner`.
- Moved to `geo_owner`: `bgp_route_views`, `bgp_rv_ingest_state`, `dbip_split_candidates`, `ip2city_dbiplite_tbl`, `range_classification`.
- Left untouched: `geo_exclusions`, `ip2city_city_code_tbl`, `ip2city_dbiplite_probe_tbl`, `traceroute_hostname_rules` (owner `boris`); `city2county_tbl`, `city2zip_tbl`, `dma2city_tbl`, `dma2county_tbl`, `dma2zip_tbl`, `dma_ip_export`, `dma_names_tbl`, `ip2city_dbiplite_traceroute_backup_tbl`, `ip2city_dbiplite_traceroute_tbl` (owner `postgres`).
- `role geo_owner` — new, `NOLOGIN`, members `boris` and `cronuser`.

**Commits merged in this slice (in order)**: `a2964f5` (no-$HOME, PR #2), `15bfe21` (env-var handling in daily_pipeline), `2217fb7` (cron `>/dev/null`), `7aa1f55`/`cc93525`/`4319c78` (clean-provenance bgp binary + per-file state logging), `f528f1f` (build-on-deploy, untracked binaries, `-limit` watermark fix), `84443c0` (pre-loop progress line), `fee61ca` (fine-grained progress, rec/s), `01cec82` (updates-mode index creation — correct but **not** the cause of the slowness), `8093b2f` (bulk staged apply), `73c91ee` (DoD seed, empty-backlog exit 0, notification gating), `a0c30a0` (rebuild_probe_tbl.sql + deploy of SQL), `6a2b9a8` (filter alignment, CGNAT reversal, PROBE_IPV4_ONLY, psql_file SET fix), `445cd9d` (ASN temp table + phase notices), `19b82eb` and `fd4e863` (progress-metric guidance corrections), `d0dbf61` (probe retargeted to probe table, consumers moved to `ran_at`), `b3800c7` (`query`/`start_ip`/`end_ip`), `42a7521` (sampleRanges ORDER BY fix), `bb2e491` (lock-exit reporting), `e6db99b` (scratch test, PR #22), `cf0bfc6` (masklen fix, PR #23), `198fd1c` (in-place patch script). Earlier reference points: `757558d` (origin/main before this slice's work), `76a399f` (the dirty revision the stale binaries came from).

## Commands worth keeping

```
# Restore the Postfix relay after dpkg-reconfigure cleared it
sudo postconf -e 'relayhost = [smtp.purelymail.com]:587'
sudo postconf -e 'smtp_tls_security_level = encrypt'
sudo systemctl reload postfix
sudo postqueue -f

# Header rewriting so From: matches the envelope
sudo tee /etc/postfix/generic > /dev/null <<'GENEOF'
@Immetrica-Mint30 info@immetrica.com
@mint30.immetrica.com info@immetrica.com
GENEOF
sudo postmap /etc/postfix/generic
sudo postconf -e 'smtp_generic_maps = hash:/etc/postfix/generic'
sudo systemctl reload postfix

# root alias so MAILTO=root cron output reaches Boris
grep -n '^root' /etc/aliases || echo "root: boris@immetrica.com" | sudo tee -a /etc/aliases
sudo newaliases

# Exercise the exact mail command the scripts issue, as the account they run as
sudo -u cronuser bash -c 'echo "Geo start" | mail -s "Geo script probe_batch.sh starting at time $(TZ=America/New_York date +%Y-%m-%d" "%H:%M:%S) ETZ" boris@immetrica.com'

# System paths
sudo mkdir -p /var/log/trugeo
sudo chown cronuser:cronuser /var/log/trugeo
sudo chmod 755 /var/log/trugeo
echo 'export PGDATABASE=postgres' | sudo tee /etc/trugeo.env
sudo chown root:root /etc/trugeo.env
sudo chmod 644 /etc/trugeo.env
sudo usermod -d /var/trugeo cronuser

# The single gate that proves peer auth + config + role all line up
sudo -u cronuser psql -d postgres -tAc "select current_user, current_database(), pg_has_role(current_user,'boris','member')"
sudo -u cronuser bash -c 'set -a; . /etc/trugeo.env; set +a; psql -tAc "select current_user, current_database()"'

# Schema grants cronuser actually needs (boris being superuser conferred nothing)
sudo -u postgres psql -d postgres -c "GRANT USAGE, CREATE ON SCHEMA public TO cronuser"
sudo -u postgres psql -d postgres -c "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public TO cronuser"
sudo -u postgres psql -d postgres -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cronuser"

# Dedicated owner role, closing the cronuser -> superuser path
sudo -u postgres psql -d postgres -c "CREATE ROLE geo_owner NOLOGIN"
sudo -u postgres psql -d postgres -c "GRANT geo_owner TO boris"
sudo -u postgres psql -d postgres -c "GRANT geo_owner TO cronuser"
sudo -u postgres psql -d postgres -c "ALTER TABLE bgp_route_views OWNER TO geo_owner"
sudo -u postgres psql -d postgres -c "ALTER TABLE bgp_rv_ingest_state OWNER TO geo_owner"
sudo -u postgres psql -d postgres -c "ALTER TABLE dbip_split_candidates OWNER TO geo_owner"
sudo -u postgres psql -d postgres -c "ALTER TABLE ip2city_dbiplite_tbl OWNER TO geo_owner"
sudo -u postgres psql -d postgres -c "ALTER TABLE range_classification OWNER TO geo_owner"
sudo -u postgres psql -d postgres -c "REVOKE boris FROM cronuser"
sudo -u postgres psql -d postgres -tAc "select pg_has_role('cronuser','boris','member'), pg_has_role('cronuser','geo_owner','member')"

# History PK must span two columns or only one cycle can ever be archived
sudo -u boris psql -d postgres -c "ALTER TABLE ip2city_dbiplite_history_tbl DROP CONSTRAINT ip2city_dbiplite_history_tbl_pkey"
sudo -u boris psql -d postgres -c "ALTER TABLE ip2city_dbiplite_history_tbl ADD CONSTRAINT ip2city_dbiplite_history_tbl_pkey PRIMARY KEY (network, ran_at)"

# Permanent clone, full not shallow, plus the check that would have caught the broken clone
mkdir -p /home/boris/geo/src
git clone https://github.com/borislevitanimmetrica/claude.git /home/boris/geo/src/claude
cd /home/boris/geo/src/claude
ls geo/*/cmd/main.go geo/dma_export/expand_cidrs/cmd/main.go

# The whole update cycle, from this slice onward
cd /home/boris/geo/src/claude && git pull origin main && git log --oneline -1
./geo/pipeline/deploy.sh
./geo/pipeline/deploy.sh --build-only      # build, no install, no sudo

# Authoritative DDL without backslashes (no \d+ -- see Traps)
sudo -u postgres pg_dump -d postgres --schema-only --table=public.ip2city_dbiplite_probe_tbl --table=public.ip2city_dbiplite_history_tbl --table=public.trugeo_states_tbl

# Confirm two tables are column-identical before INSERT ... SELECT
sudo -u cronuser psql -d postgres -c "select column_name, data_type from information_schema.columns where table_name='ip2city_dbiplite_probe_tbl' except select column_name, data_type from information_schema.columns where table_name='ip2city_dbiplite_history_tbl' order by 1"

# BGP: safe smoke test (dry-run only -- never -limit in real mode)
sudo -u cronuser /var/trugeo/bgp_route_views/bin/bgp_route_views -mode updates -dry-run -limit 20000

# BGP: real ingestion under the same mutation lock the cron jobs use
sudo -v
sudo -u cronuser env PGDATABASE=postgres nohup flock /var/log/trugeo/dbmutate.lock /var/trugeo/bgp_route_views/bin/bgp_route_views -mode updates > /tmp/bgp_catchup.log 2>&1 &

# BGP: foreground, so output is visible (Ctrl-C is safe, the watermark does not move)
sudo -u cronuser env PGDATABASE=postgres flock /var/log/trugeo/dbmutate.lock /var/trugeo/bgp_route_views/bin/bgp_route_views -mode updates 2>&1 | tee /tmp/bgp_fg.log

sudo -u cronuser psql -d postgres -c "select collector, last_file_ts, updated_at from bgp_rv_ingest_state"

# Probe: direct invocation, bypassing the hourly lock, for immediate visible output
sudo -u cronuser env PGDATABASE=postgres /var/trugeo/check_geo_ip-api/bin/check_geo_ip-api -count 3 -country US -ipv4-only

# Pipeline runs
sudo -u cronuser env BATCH=45 /var/trugeo/pipeline/probe_batch.sh
sudo -u cronuser env DRY_RUN=1 /var/trugeo/pipeline/daily_pipeline.sh
sudo -u cronuser env PROBE_TBL_REBUILD=1 /var/trugeo/pipeline/daily_pipeline.sh

# Rebuild SQL in isolation, timed
time sudo -u cronuser psql -d postgres -v ON_ERROR_STOP=1 -c "SET geo.country = 'US'" -c "SET geo.family = '4'" -f /var/trugeo/pipeline/rebuild_probe_tbl.sql

# Scratch test, enabling automatic rollover only on a full pass
sudo -v
ENABLE_ON_PASS=1 /var/trugeo/pipeline/scratch_test_rollover.sh

# In-place patch of start_ip/end_ip/query on the live table (written, NOT yet run)
time sudo -u cronuser psql -d postgres -v ON_ERROR_STOP=1 -f /var/trugeo/pipeline/patch_probe_tbl_range_fields.sql

# Verification queries that mattered
sudo -u cronuser psql -d postgres -c "select count(*) as total, count(*) filter (where start_ip is null) as null_start, count(*) filter (where end_ip is null) as null_end, count(*) filter (where query = start_ip) as query_is_base, count(*) filter (where family(query)=4 and masklen(query) <> 32) as query_masked from ip2city_dbiplite_probe_tbl"
sudo -u cronuser psql -d postgres -c "select x.origin_asn, x.reason, count(*) as prefixes from geo_exclusions x join bgp_route_views b on b.origin_asn = x.origin_asn where x.active and x.origin_asn is not null group by 1,2 order by 3 desc"
sudo -u cronuser psql -d postgres -c "select indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) as size from pg_stat_user_indexes where relname='bgp_route_views' order by idx_scan"
sudo -u cronuser psql -d postgres -c "select n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze from pg_stat_user_tables where relname='bgp_route_views'"
sudo -u cronuser psql -d postgres -c "select pid, state, wait_event_type, wait_event, now()-xact_start as xact_age, now()-query_start as query_age, left(query,110) as query from pg_stat_activity where usename='cronuser'"
sudo -u cronuser psql -d postgres -c "select indexrelid::regclass as invalid_index, indisvalid from pg_index where not indisvalid"
sudo -u cronuser psql -d postgres -c "select pg_cancel_backend(PID)"

# Lock-free progress signals for a long single-transaction write (see Traps)
sudo -u cronuser psql -d postgres -tAc "select pg_current_wal_lsn()"
sudo -u cronuser psql -d postgres -tAc "select pg_size_pretty(pg_database_size('postgres'))"

# Progress reads on the pipeline
grep -c "ran correctly" /var/log/trugeo/probe_batch.log
sudo grep "backlog" /var/log/trugeo/probe_batch.log | tail -15
sudo grep -iE "FATAL|exited with error|WATERMARK NOT" /var/log/trugeo/*.log | tail -20
go version -m /var/trugeo/bgp_route_views/bin/bgp_route_views | grep vcs
```

## Traps and gotchas

- **`dpkg-reconfigure postfix` silently wipes `relayhost`.** Reconfiguring a working Postfix rewrites `myhostname`, `myorigin`, `mydestination` and `relayhost` from debconf answers; pressing Enter on the blank relayhost field cleared it, and mail then went out unauthenticated on port 25 and hit greylisting. Auxiliary files (`sasl_passwd`, `sender_canonical`, `generic`, `transport`) survive dpkg. Fix: `postconf -e 'relayhost = ...'`. Prevention: `postconf -n > backup.txt` before ever reconfiguring.
- **`tee -a` in a logging function causes duplicate cron mail.** `log()` wrote to stdout via `tee`, and cron mails `MAILTO` on *any* job output regardless of exit code — so every run mailed the entire log body on top of the script's own start/success/error mail (~72/day for probe_batch, not the 48 first stated). Fix: append `>/dev/null` to each cron job. Deliberately leave stderr alone: the unwritable-`LOG_DIR` guard writes to stderr *before* the mail path is usable, so cron mail is the only channel for that one failure mode. Note `die()` calls `log()`, so FATALs now go to stdout (suppressed from cron mail) but still send their own error mail.
- **`$HOME` dependency in unattended scripts.** `cronuser` has no login and `/home/cronuser` was deleted, but the scripts defaulted `LOG_DIR` and `GEO_CONFIG` to `$HOME`, so manual `sudo -u cronuser` runs and cron's chdir would break. Fix: hardcode system paths and set `HOME=/var/trugeo` in the cron file. Verified by sourcing with `HOME` unset under `set -euo pipefail`.
- **Stale binaries rsynced from an un-rebuilt tree.** Deploying scripts from a fresh clone but binaries from `~/geo` installed Go binaries that predated the libpq-fallback fix; the cron job had been firing and failing hourly since an earlier session on `DATABASE_URL is not set` (a string no longer in current source). This is the failure class that build-on-deploy (option 2) was adopted to eliminate. Lesson: a tracked binary built from a dirty tree (`vcs.modified=true`, revision `76a399f`) corresponds to no commit and cannot be diagnosed against source.
- **A loop skipping `check_geo_ip-api`.** The build loop iterated `*/cmd` dirs, but `check_geo_ip-api` has its `go.mod` at the tool root with `main` under `cmd/`, so it was silently skipped — the one tool that was actually failing. It must be built with `(cd check_geo_ip-api && go build -o ... ./cmd)`.
- **A broken clone missing the entire Go tool source.** Boris's `~/geo/src/claude` lacked all eight `cmd/main.go` files though `origin/main` contained them; never explained. Sidestepped with a shallow `/tmp/trugeo-src` clone, then a full re-clone. The catch that would have surfaced it immediately: `ls geo/*/cmd/main.go`.
- **A "dry run" that wasn't.** `daily_pipeline.sh` hardcoded `DRY_RUN=0` and only honoured the `--dry-run` flag, so `env DRY_RUN=1` was silently discarded and the command took the mutation lock and began a real run. Harmless only because `bgp_route_views` then failed on the stale-binary bug before mutating. `probe_batch.sh` used `${VAR:-default}`, which is why `BATCH=45` worked — the inconsistency hid the bug. Fix (`15bfe21`): env honoured, flags override, bad value exits 2 before the lock.
- **Superuser status is not inherited through role membership.** `GRANT boris TO cronuser` did not fix `permission denied for schema public`, because `boris` is a superuser and superuser-ness is a non-inherited role attribute. Membership only helped the ownership checks for DROP/RENAME. Worse, it opened a `SET ROLE boris` → superuser path for the unattended account. Fix: explicit schema grants + a `geo_owner NOLOGIN` role, and `REVOKE boris FROM cronuser`.
- **`-limit` on `bgp_route_views` advances the watermark past a partially-applied file.** `errStopEarly` fell through to `setState` + `Commit`, so a file truncated at 4,000 of ~20,000 records was marked done and the remaining ~16,000 were never revisited (`updatesSince` selects strictly after the watermark). Silent data loss, happened twice. Fix: truncation leaves the watermark where it was; already-written rows stay (DELETE-then-INSERT per prefix is idempotent). **Never use `-limit` in a real run** — use `-dry-run -limit`.
- **Timezone in `last_file_ts` masked that the watermark was advancing.** `2026-08-31 08:15:00-04` (EDT) equals `12:15:00Z`; the instance nearly read a correct one-file advance as "stuck." Always account for the `-04` offset when comparing to the UTC file names.
- **A documented invariant the code didn't implement.** `schema.sql` claimed the updates-mode index was created "at the start of an updates run," but only `runFull` created it. The instance patched this (`01cec82`) believing it was the cause of slowness — Boris's `pg_indexes` output then showed the index already existed, refuting the hypothesis. The patch is still correct (protects fresh installs) but was not the problem. Lesson Boris's output forced: check `pg_indexes` before theorising about a missing index.
- **The real "very broken" BGP problem was missing progress output, not slowness.** The old per-prefix path processed all 721 files in ~2h20m (~12s/file); because nothing logged between "fetching file 1 of 721" and the first commit, an immediate `&`-return plus silence looked identical to a hang, and `&` always returns immediately regardless of whether the child is alive. The instance escalated twice (index fix, bulk rewrite) before the progress logging it had already merged (`fee61ca`) revealed the truth. The bulk rewrite (`8093b2f`) is a genuine improvement (3 statements/file vs ~38,000) but was unnecessary to unblock.
- **`no eligible ranges found` as a fatal exit 1.** When the backlog finally drains, every hourly run would exit non-zero and email an error for what is actually success — 24 spurious alerts/day in ~40 days. Fix: log and exit 0.
- **The rebuild gate deadlock class.** Defining "cycle complete" as no `ran_at IS NULL` rows means any row that can never be probed (excluded ranges, CGNAT if filtered one-sidedly, IPv6, non-US) blocks every future rebuild permanently. The populate must apply *exactly* the same filters as `sampleRanges`; if the two filter sets ever drift apart, the pipeline deadlocks silently. The DoD exclusions Boris had just added would themselves have frozen it.
- **`PROBE_IPV4_ONLY` must drive both sides.** `probe_batch.sh` never passed `-ipv4-only` (which defaults to false), so `check_geo_ip-api` sampled both families while `remaining()` counted only family 4 — backlog and probe scope silently disagreed. Setting family in one place only re-creates the deadlock; hence the single switch in `geo_common.sh`.
- **`SET a = 'x', b = 'y'` is not valid SQL.** `psql_file` emitted it and would have failed on the first rebuild. `SET` takes one parameter per statement; fix emits one `-c` per setting.
- **Correlated subqueries that scan a big table per candidate row.** Twice: (1) the ASN exclusion's `NOT EXISTS` did `s.network <<= b.cidr_block` against 1.14M-row `bgp_route_views` for each of ~5.4M candidates — materialise the small expanded prefix set into an indexed temp table instead; (2) `sampleRanges`' `ORDER BY` looked `source` up in `ip2city_dbiplite_tbl` via correlated subquery, 2M+ lookups before `LIMIT`, turning a cheap top-N heapsort into a 7-minute hang. The original was fast only because `source` was a column on the same relation. Fix: drop the cross-table sort key (or denormalise `source` into the probe table).
- **Three successive progress metrics that could not work during a single long transaction.** (1) `n_tup_ins` is backend-local and flushed only at commit, so it reads 0 regardless of work done; (2) `pg_relation_size` opens the relation with AccessShareLock, which conflicts with the `TRUNCATE`'s ACCESS EXCLUSIVE — the query *blocks*, looking exactly like the hang it was meant to diagnose; (3) the only signals that work are `pg_current_wal_lsn()` (advancing = writing) and `pg_database_size()` (no relation lock). The structural point: an atomic single-transaction rebuild is unobservable from inside for its whole duration by design.
- **`network(inet)` retains the prefix length.** `network(s.network)` for `1.2.3.0/24` yields `1.2.3.0/24`, and Postgres compares `inet` by network, then masklen, then host bits — so `query = network(...) + offset` sorted *below* its own `start_ip` because 24 < 32. The address was right, the masklen wrong. Fix: `host(...)::inet` to force /32. Caught by the scratch test's `every target lies inside its range` assertion.
- **A false pass hiding a NULL column.** Production's `query_out_of_range = 0` was taken as verifying the offset arithmetic, but `start_ip`/`end_ip` were NULL on all 2,089,296 live rows, so every comparison yielded NULL and was never counted. `query_is_base = 0` was a second NULL artifact. Measure the NULL counts before trusting any predicate over those columns.
- **`\d+` and backslashes are a paste hazard on Boris's path.** A backslash in a pasted command becomes a real newline in his environment, breaking the command. The instance deliberately used `pg_dump`, `information_schema` queries and `awk '{print $1}'` instead of `\d+`, and avoided `${rest#*:}` (mid-line `#`) and `printf` escapes.
- **`PRIMARY KEY (network)` on the history table caps it at one cycle.** The second cycle's archive fails on the unique constraint. Must be `(network, ran_at)`. The rebuild SQL refuses to run until this is fixed, rather than dying on an opaque violation in October.
- **`kill`ing the outer `sudo` does not necessarily reach the real child.** An earlier `kill 736267` targeted the `sudo` wrapper, not the `bgp_route_views` binary (`736271`), which may have kept running. Kill the binary's pid.

## Boris's instructions, preferences and standing orders

- **Mail from Mint30 must originate as `info@immetrica.com`, never `boris@immetrica.com` or `cronuser@...`** — it won't authenticate otherwise. Both envelope (`sender_canonical`) and header (`smtp_generic_maps`) must say so.
- **"Fix it!!!" / "FIX!!!!" / "FIX!!!"** — when something he relies on breaks, he wants it restored, not litigated. He corrected the instance's "no evidence external delivery worked" with "External delivery worked reliably" and expected that taken as given.
- **Do not harm existing data in `ip2city_dbiplite_probe_tbl`** (stated twice, around the scratch test). This directly caused the `search_path = scratch`-only rewrite.
- **Emails stay as now until commercial ip-api access is secured; then switch to start and end of the full probing cycle only** (which will be daily or more frequent). Provide either code changes or commented-out entries and say where.
- **Use `dma_code` (integer) as the API input, not DMA names** — codes eliminate variance in DMA names. Join `dma2city_tbl` to `ip2city_dbiplite_probe_tbl` on `city` and `state_code`.
- **Do not exclude `.0` and `.255`** from returned IPs — in a range wider than /24 they are legal. Including a small number of never-matched addresses is acceptable: negligible cost, no adverse consequence.
- **Field rename he specified:** `ip2city_dbiplite_probe_tbl.regionName` becomes `.state`; populate `.state_code` from `trugeo_states_tbl` where `.state = trugeo_states_tbl.state`. `ran_at` is NULL at populate, `now()` at probe (a change from the traceroute table where it was NOT NULL DEFAULT now()). (The live `pg_dump` showed the rename was already done in the DB.)
- **CGNAT must NOT be excluded** — that earlier decision was reversed; he forgot to tell the instance.
- **IPv6 out of scope for now, but make it reversible in configuration and tell me where.** It may matter once adoption is higher.
- **Non-US not populated** — separate downstream arrangements will handle other countries for fast response.
- **Repeated critique: issue the actual commands, don't just describe what you need.** He steered the instance mid-task to "Revise to issue frequent progress messages" and "If you want the log output, instruct accordingly." He also called out "You didn't issue a git repo sync command" when the instance referenced a file not yet in the clone.
- **He runs the commands himself and reports output** — the instance proposes, he executes. He expects pre-mortems before destructive or privilege-changing actions and rollback instructions.
- **He verifies claims against his own output** and pushes back hard ("There are many more than 4 FATAL exits"; "Is the last_file_ts expected after the previous version ran without error?"). The instance's pattern of merging fixes against unverified hypotheses drew implicit and explicit criticism; he values measuring before changing.
- **Priorities he stated:** false negatives are the costly direction for his advertising workflow (why IPv6 absence is the dominant gap, and why he won't over-broadly exclude `/8`s). Fast response for the DMA lookup. He wants the never-executed archive path verified before it fires unattended in October.
- Delete the old clone to avoid confusion once working from the new one (the instance moved it to `/tmp/old-claude-clone` rather than deleting, pending the missing-source anomaly).

## Open items at end of slice

- **DMA front end — the active task at the end of the range.** Boris asked for an API + GUI taking one `dma_code` and returning the individual IPv4 addresses in that DMA, with the DB query from either. At the very end of the slice the instance was mid-implementation: it had checked `expand_cidrs` and the `dma_export` queries for reuse, written a Go streaming service (cursor-based, with a `flushWriter` for periodic flushing so clients see bytes without waiting minutes), and was writing the GUI (deliberately no hex colours or backslashes to survive Boris's paste path). None of this was shown completed or merged in range.
- **In-place patch `patch_probe_tbl_range_fields.sql` written (`198fd1c`) but not yet run.** Boris was told to run it in the gap between hourly batches (~minute 58 to minute 5). Expected result: `null_start`/`null_end` → 0, `out_of_range` → 0, `probed` unchanged at ~7,053+, `query_is_base` ~7,053 (already-probed rows keep their `.0` targets).
- **Automatic rollover (`PROBE_TBL_REBUILD=1`) is now enabled in `/etc/trugeo.env`**, but step 3 (archive) has still never executed on real data and won't for ~36 days until the first US cycle completes (~early October). The scratch test proved the path, but on 200 rows.
- **New RouteViews splits wait up to a full cycle (~36 days) to be probed.** `apply_splits` adds fresh /24 rows to `ip2city_dbiplite_tbl` daily, but the probe table is only rebuilt at cycle completion, and the RouteViews-first ordering that used to compensate was removed. Proposed fix (not implemented): have `daily_pipeline` insert new rows into the probe table mid-cycle with `ran_at NULL`. Awaiting Boris's say-so.
- **History retention / partitioning undecided.** ~2M rows per cycle, ~750M/year under daily cycles. The instance repeatedly flagged that retrofitting partitioning onto a billion-row table is painful; Boris had not answered how long history must be retained.
- **BGP index cleanup proposed, not confirmed executed.** `bgp_route_views_pkey` (212 MB, 0 scans, ~8× bloated) and `idx_bgp_range` (72 MB, 0 scans) are candidates for REINDEX / DROP; `REINDEX INDEX CONCURRENTLY bgp_rv_cidr_gist` and `..._pkey`, `DROP INDEX idx_bgp_range` were offered pending a `stats_reset` check. See Uncertain — a later "probe_batch dies" turn checked for an invalid index left by a REINDEX, which suggests Boris may have run it, but the transcript in range does not confirm he did.
- **Product decision the project turns on:** pay for ip-api (removes the 45/min cap), narrow the probe target to commercially-relevant DMAs, or accept ~40 days. Unresolved.
- **IPv6 entirely absent** (~57–68% of US mobile traffic, per the instance's repeated estimate). Reversible via `PROBE_IPV4_ONLY=0`; needs IPv6 exclusion data, of which none is probe-verified. Unresolved and flagged as the largest gap.
- **The `From:` header** (as opposed to envelope) was never confirmed by Boris inspecting his inbox — the maillog cannot show it.
- **The missing-Go-source anomaly** in the original `~/geo/src/claude` clone was never explained; the old clone was moved to `/tmp/old-claude-clone` pending investigation and would clear on reboot.
- **`check_routeviews_ip-api`, the root `main.go`, and `traceroute_hostname_rules.sql`** still filter CGNAT / reference the traceroute table; left alone because none writes to the probe table or runs from cron. Boris was offered consistency and did not request it.

## Uncertain

- Whether Boris actually ran the BGP index REINDEX/DROP commands. A later turn's diagnostic checked `pg_index where not indisvalid` for "an invalid index left by the REINDEX CONCURRENTLY I had recommended," implying he might have, but the transcript in this range does not show him running them or the result.
- Whether the `From:` header arrived as `info@immetrica.com` — depends on Boris inspecting his inbox, not recorded.
- The exact final state of the DMA front-end files (service Go file, GUI file) — the instance was writing them at the very end of the range; their paths, full contents and whether they compiled/were committed are not shown in range.
- The precise byte/line counts of the new SQL and shell scripts — described by behaviour, not measured, except where a commit's diffstat appeared (e.g. `scratch_test_rollover.sh` added 251 lines in `e6db99b`; `rebuild_probe_tbl.sql` +13/−2 and `scratch_test_rollover.sh` +12 in `cf0bfc6`).
- The cause of the original missing-Go-source clone anomaly — explicitly never determined.
- Whether `is_unreachable_local_carrier`'s oddly-named NOT NULL constraints (`ip2city_dbiplite_history_tb_is_unreachable_local_carri_not_null`) matter downstream — they appear only in the `pg_dump` output and were not discussed.
- The exact DMA address-expansion query the front end will run — the instance referenced reusing `expand_cidrs` and the `dma_export` queries but the final query was not shown in range.

[STEERING steer-2f50cbe5-e128-49ce-9189-007f86342098: The steering message confirmed there is no handoff FROM the blocked session, only TO it, which is why the whole transcript range had to be read. This matched what I was already doing — reading every line of 24051-28860 in full (the file has very long lines, so reads were character-capped and I issued successive offset reads to cover the entire range) rather than relying on any existing summary. No change of approach was needed; the message reinforced that my notes are the sole record of this slice, so I kept them dense, specific, and explicit about what was verified versus asserted.]
