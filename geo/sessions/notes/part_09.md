# Part 09 (lines 38481-43290)

Read in full via successive `read_file` calls (no grep-sampling). Roughly lines 38481–40330 are the tail of a single 2,000-address traceroute log; the substantive dialogue runs from ~40330 to the end of the range. The slice ends mid-way through the output of a `psql` verification table, so the last exchange is truncated.

## Narrative

The slice opens inside the tail of a `last_carrier_node` run over 2,000 sampled addresses (log timestamps 2026/10/25 04:24:26 → 04:31:08, ending `done: 2000 results written`), which the instance then analysed. It reported three defects. The decisive one: because a landmark is a web server that answers ICMP, the trace completes and the "last carrier node" recorded was the landmark's own address — the instance estimated by eye that a third to a half of the 2,000 rows were affected, and called this a defect that "breaks the method". The second defect was that `onpremises` had only ever been run with `--dry-run`, so the run was tracing Cloudflare, GoDaddy, CloudFront, DreamHost, HostGator, Weebly, Vultr, Linode and Contabo addresses. The third was that transit cores (Cogent, Lumen, Zayo, HE, Telia/twelve99) were being accepted as carrier nodes — wasteful rather than incorrect, since the fan-out guard would reject them. The instance also withdrew an earlier argument about deriving the node from BGP attributes, conceding Boris had always meant `mtr` on both sides. It corrected its own throughput projection from 29 hours to 7.5 hours for ~123k addresses (2,000 traces in 7m18s at `-concurrency 50` = 4.57/sec). It fixed the self-trace bug, added a `-zip-prefix` flag to restrict to Massachusetts, verified the fix by running old and new binaries side by side, and merged commit `04d89d0` (PR #47).

Boris then gave a dense set of corrections: exclude the landmark's IP but make node identification work whether or not the destination answers; business customers often have two or three CPE nodes, the one nearest the carrier usually carrying the customer's own domain; the last carrier node sometimes has no hostname at all (seen on business private-Internet-access links); retry up to 3 times if hop 2 from the Mint30 Verizon FIOS link does not answer, and report what fraction of `mtr` calls hit that and what fraction fail on all three attempts.

Boris applied `onpremises` for real (16,101 rows changed over 11,466,589 candidates in 36 chunks, 329s), deleted 416 self-traced rows, and found 312 Massachusetts (021xx) landmark addresses. The first 021xx run (301 addresses) showed the self-trace fix working — zero self-traces — but exposed exactly what Boris had described: the hop now chosen was the customer's own router (MIT `18.0.193.110`, Harvard `140.247.2.50`, Tufts `130.64.1.58`, `204.167.92.26 gatehouse.cambridgema.gov`), eight of ten sampled. The instance then derived the destination's registered domain from its own reverse DNS and skipped any hop sharing it, added a `reached-unnamed` status so unnamed carrier nodes are accepted but separable, started storing the whole hop list as `jsonb`, and added hop-2 instrumentation and retry. Merged as `85648a5`.

Boris next rejected a framing the instance had let stand: static landmark ranges and dynamic household ranges are deliberately kept separate so the dynamic range can be relocated, so a landmark's prefix tells you nothing about nearby households — matching by prefix is not available. He called the ASN question prescient but warned that carrier ASNs adjacent to CPE are far wider than one ZIP. He also instructed `sudo -v` before other commands.

The second 021xx run (312 addresses) produced the full diagnostic battery. Hop 2 was silent on 0 of 312 calls, so the retry never fired. The instance reported that 64.7% of reached landmarks sat on transit/backbone nodes, that two Cogent Boston aggregation routers carried 37% of the sample, and argued transit-reached landmarks should be disqualified because a transit circuit to a business carries no household traffic. It also found that its own section 4 had conflated two things — ZIP counts over *all* places behind a node, where one address serves many places — and rebuilt it to measure breadth only on addresses mapping to a single ZIP.

Boris overruled the disqualification on two counts: transit should be treated like CGNAT as a DMA-level accuracy tier rather than an exclusion, with `likely_mobile_cgnat` replaced by `mobile_transit varchar(1)` taking `m`/`t`/`f`; and business IPs *do* consume biddable media (at-work, campus housing) and must not be ruled out. The instance built the migration and a new `transit_domain` rule type, merged `aad657b`, and reported that the corrected section 4b reversed its earlier claim — Cogent routers looked nearly as ZIP-specific as Comcast's, 13 of 15 serving one ZIP.

Boris attacked that directly with field knowledge: Comcast in Boston serves West Roxbury through a Brockton node an hour away, and Lynn through a Woburn node, so "Comcast is nearly ZIP-specific" should be treated with extreme caution and tested. He proposed defining hosting as an address serving more than one non-bordering ZIP cluster rather than by registrant name, asked for an ip-api.com accuracy probe for Massachusetts and a parallel rural survey (Michigan's Upper Peninsula), asked for a critique of that plan, and pointed out he had asked for an end result on the column change — add, populate, verify, then drop — not a direct rename.

The instance's run of `aad657b` had in fact failed silently: `CREATE TABLE IF NOT EXISTS` skipped the existing `traceroute_hostname_rules`, so the `UNIQUE (rule_type, pattern)` never reached it, both `ON CONFLICT` inserts aborted with errors `psql` logs but survives, zero transit rules loaded, and the reported `f | 312 | 100.0` was wrong. The instance acknowledged that, acknowledged omitting `ip2city_dbiplite_traceroute_backup_tbl`, and acknowledged that the rename had permanently destroyed the ability to verify the value mapping row by row. It withdrew the Comcast claim (14 router IPs over 16 landmark addresses is 1.14 landmarks per router, so a node with one landmark cannot show more than one ZIP), withdrew its reading of hostname town names as geographic signal, built disjoint-ZIP-cluster fan-out over `zip_adjacency` with both of Boris's counterexamples as tests, made narrow transit nodes ZIP-eligible, and critiqued the Upper Peninsula choice as underpowered. Merged `896c874`.

Boris's final instructions in the range: run ip-api only for `onpremises=true` records and only after computing `onpremises`; the small count of `onpremises=true` Overture landmarks is obstructing work, so prioritise importing the other memo sources starting with Foursquare, watching for duplicates; and `ip2city_dbiplite_traceroute_backup_tbl.likely_mobile_cgnat` is still not renamed. His run of `896c874` shows the UNIQUE finally added and `INSERT 0 19` transit rules loading, with the backup table still `boolean`.

## Decisions and rationale

- **A hop whose address equals the traced address is never the carrier node.** Rationale: landmarks are web servers and answer ICMP, so the trace completes and the destination becomes the final responding hop; range targets hid this because a random address in a range rarely answers. When the destination answers, the carrier node is the hop before it, already present in the trace. Boris accepted and extended: exclude the landmark IP, and identification must work whether or not the destination responds.
- **Transit cores not excluded unilaterally.** The instance proposed excluding `lumen.tech`, `he.net`, `twelve99.net` by domain and handling Cogent and Zayo by router-role regex, because `ccr41`/`agr21`/`er1` forms are core while `nr61.b002250-1.bos01` (building number) and `.IDIA-403920-ZYO` (circuit ID) are customer edge. It explicitly deferred to Boris. Boris later **modified** the whole framing: transit is a DMA-level accuracy tier (`t`), not an exclusion.
- **`likely_mobile_cgnat` → `mobile_transit varchar(1)`, values `m`/`t`/`f`.** Boris's instruction, with the reason that CGNAT gives only DMA-level accuracy and transit providers should be treated the same but kept distinguishable for auditability. The instance implemented it as an in-place rename; Boris **rejected the method**: "Add the column, populate, verify, then drop the old one. I did not ask for a direct rename; I asked for an end result." The instance conceded the cost is concrete — row-by-row verification of the mapping on four tables is now impossible and unrecoverable.
- **Business IPs stay in.** Boris: they consume biddable media at work and in campus housing. This **overrode** the instance's proposal to disqualify the 64.7% of the sample reached via transit.
- **Narrow transit nodes become ZIP-eligible.** Boris's ruling: if a transit node maps to one ZIP or a cluster of adjacent ZIPs, make it available for ZIP-level targeting. Implemented: width is the test, not operator identity.
- **Hosting defined by disjoint ZIP clusters, not by N ZIPs and not by registrant list.** The instance proposed "more than N ZIPs = shared host, whatever the registrant" (suggesting N between 3 and 10 since the distribution is bimodal). Boris **modified** it: an address serving more than one ZIP cluster where the clusters do not border each other is hosting. The instance accepted this as better and implemented it, noting one limit: it needs ≥2 landmarks at an address to see any spread, so a CDN address with exactly one landmark still passes as on-premises, and `provider_names` still covers that case.
- **Prefix matching is off the table.** Boris: dynamic and static ranges for the same geographic area are typically separate, specifically so automation can relocate the dynamic range while the static range stays with the customer. The instance accepted, corrected the file header, and clarified that `ip_address_range` and the section-8 merge are provenance columns, not join keys.
- **Fan-out measured in connected components over `zip_adjacency`, not raw ZIP counts.** One contiguous cluster is one place however many ZIPs; two or more disjoint clusters is a reject. Driven by Boris's West Roxbury/Brockton and Lynn/Woburn cases.
- **Classification decoupled from probing.** The instance began storing the full hop list as `jsonb` (~1 KB per address) so the node can be re-chosen in SQL instead of re-probing, after two passes were spent discovering the choice rule was wrong. Stated lesson: "the trace is expensive and the classification is cheap, so the classification shouldn't be welded to the probe."
- **Instance argued against site selection as the next lever** — trace all 28,324 addresses (2.2 h) and slice analytically, rather than nominating sites in advance. Boris's response within this range does not accept or reject this directly; he instead redirected to importing Foursquare and other sources because landmark counts are too low.
- **`sudo -v` before other commands when sudo is needed.** Boris's standing order; the instance recorded it as a preference.

## Measured facts and numbers

All VERIFIED by running something unless marked otherwise.

Throughput and sizing
- 2,000 traces in **7m18s** at `-concurrency 50` = **4.57 traces/sec** (first run, ended 04:31:08).
- Projected full pass for ~123k addresses: **about 7.5 hours**, correcting an earlier **29 hour** figure. ESTIMATE.
- Later revised: **28,324** distinct on-premises addresses, at a stated "measured 3.5 traces/sec" → **2.2 hours** for the whole country. ESTIMATE derived from measured rate. Note the two rates quoted in this slice differ (4.57/sec earlier, 3.5/sec later); the transcript does not reconcile them.
- 312 addresses at 4.57/sec described as "about a minute". ESTIMATE.

`onpremises` apply (the real run, not dry-run)
- **1,100** ISP names in `public.isp_names`; **39** provider names in `public.provider_names` (CDN, cloud, web hosts; matched ignoring case).
- **11,466,589** candidate rows, in **36** chunks of about **300,000**.
- **16,101** rows changed, total elapsed **329s**. (Matched the earlier dry-run prediction of 16,101, ~12% of the pass.)
- Resulting distribution among rows with `lookup_status = 'true'`: `false` **11,161,108**, `NULL` **185,327**, `true` **120,154**.
- `delete from ovt_places_usa_ip_trace where last_hop_ip = ip` → **DELETE 416**.
- `ma_landmarks` (distinct `ip_address`, `onpremises`, zip3 = `021`) = **312**.

First 021xx run (04:59:39 → 05:00:58)
- **301** landmark addresses selected. Rule load: "1 tld, 10 domain, 8 customer-marker, 0 customer-marker-regex".
- Self-traces: **0** of 301 (fix confirmed).
- **15 of 301 (5.0%)** ended `unreachable` with "nearest resolved hop at position 2". The instance explicitly said this is NOT the hop-2-silent figure Boris asked for, since hop 2 did answer in those cases.
- Customer-own-router contamination: "**eight of ten sampled**". ESTIMATE from eyeballing.

Second 021xx run (05:11:50 → 05:13:19), 312 addresses — full diagnostics
- Landmark side: **312** rows traced, **235** reached, **235** with node IP, **235** with node hostname, **0** mobile-flagged. Range side (mtr only): all **0**.
- `distinct_onprem_addresses` **28,324**; `traced` **312**; `remaining` **28,012**; `places_behind_them` **120,154**.
- Status: `reached` **235 (75.3%)**, `excluded-internal` **63 (20.2%)**, `reached-unnamed` **12 (3.8%)**, `unreachable` **2 (0.6%)**.
- `self_trace` **0 (0.0%)**; `provider_hosted` **0**; `backbone_node` **144**; `usable_now` **95**.
- **Hop 2: `mtr_calls` 312, `calls_hop2_silent` 0 (0.00%), `addresses_silent_every_attempt` 0 (0.00%), `mean_attempts` 1.00.** The retry never fired; the instance concluded there is no need to raise the maximum.
- Attempts histogram: attempts `1` → 312 addresses, 247 reached, **79.2%**.
- `customer_hops_skipped`: 0 → 228 addresses (156 reached-named, 11 reached-unnamed); 1 → 27 (24, 1); 2 → 11 (10, 0); 3 → 45 (44, 0); 4 → 1 (1, 0).
- Node inside destination's own origin AS: `reached` 235 → **91 (38.7%)**, 0 unknown; `excluded-internal` 63 → **4 (6.3%)**, 2 unknown; `reached-unnamed` 12 → **7 (58.3%)**, 1 unknown; `unreachable` 2 → 0 (0.0%), 1 unknown. The instance said it had NOT established why this is so high, and offered landmarks on carrier-owned address space as a hypothesis, not a finding.
- `distinct_node_ips` **108**, `distinct_node_hostnames` **108**, `landmark_addresses` **235**, `addresses_per_node_ip` **2.18**, `node_ips_per_hostname` **1.00**.
- Node-domain counts (nodes / distinct node IPs): `cogentco.com` **118 / 23**; `comcast.net` **27 / 25**; `lumen.tech` **10 / 5**; `linknowmedia.cloud` **9 / 1**; `zayo.com` **6 / 5**; `he.net` **6 / 2**; `twdx.net` **6 / 4**; `twelve99-cust.net` **4 / 4**; `att.net` **3 / 1**; `daytonoffice.com` **3 / 1**; `verizon-gni.net` **3 / 3**; `lightower.net` **3 / 3**; `xcelx.net` **3 / 1**; `astound.net` **3 / 2**; `rcn.net` **2 / 2**; `hvdata.net` **2 / 1**; `ntt.net` **2 / 2**; `unitasglobal.net` **2 / 1**; `as3491.net` **2 / 1**; plus 21 singletons. 40 rows.
- Node class (`carrier_node_class`, `INSERT 0 24` rules): `transit` **152 addresses / 44 router IPs / 64.7%**; `retail` **38 / 35 / 16.2%**; `unclassified` **29 / 21 / 12.3%**; `hosting` **16 / 8 / 6.8%`.
- Two Cogent routers carried 37% of the sample: `be3664.agr22.bos01` **63 addresses / 7 ZIPs / 02110–02215**; `be3255.ccr32.bos01` **24 addresses / 11 ZIPs / 02114–02215**.
- ZIPs-at-node distribution (identical by node IP and by node hostname): 1 ZIP → 41 nodes / 47 addresses (20.0%); 2 → 12 / 16 (6.8%); 3 → 7 / 14 (6.0%); 4 → 4 / 4; 5 → 2 / 5; 6 → 5 / 7; 7 → 2 nodes / **64 addresses (27.2%)**; 8 → 2 / 3; 11 → 1 / **24 (10.2%)**; and a long tail to 924 → 1 / 9 (3.8%) and **1108 → 1 / 4 (1.7%)**. 37 rows.
- Worst nodes by ZIP span: `ae5.5.bear1.Boston1.net.lumen.tech` **1108 ZIPs / 4 addresses / 01002–99403**; `pf1.cologix.linknowmedia.cloud` **924 / 9 / 01440–99705**; `67.208.231.59.IDIA-413858-002-ZYO.zip.zayo.com` **903 / 1**; `be3951.rcr21.ind01.atlas.cogentco.com` **628 / 1**; `be8.cr02.900.bct.bboi.net` **520 / 1**; `ae1.11.bear1.Boston1.net.lumen.tech` **470 / 3**; `mail.nvideomc.com` **457 / 1**; `core1-tul1.aod.net` **408 / 1**.
- Coverage: `zips_with_onprem_landmarks` **15,963**; `zips_that_got_a_range` **0**; `zips_still_unrouted` **15,963**. Against Boris's stated target of **~44,000** inhabited ZIPs.
- Range-side sections all returned zero rows (no range-side traces exist yet).
- Recurring `SELECT 1192937` — a temp relation of 1,192,937 rows built for the origin-AS join (see Uncertain).
- One run printed `UPDATE 35438`; a later identical section printed `UPDATE 0`.

Corrected section 4b (breadth measured only on landmark addresses mapping to a single ZIP)
- `cogentco.com`: 15 router IPs, 89 landmark addresses, worst **6** ZIPs at one node, mean **1.53**, **13 of 15** routers serving one ZIP.
- `comcast.net`: 14 router IPs, 16 landmark addresses, worst **3**, mean **1.14**, **13 of 14** serving one ZIP.
- `twdx.net` 4/5/1/1.00/4; `att.net` 1/3/1/1.00/1; `he.net` 2/3/2/1.50/1; `lightower.net` 2/2/1/1.00/2; `as3491.net` 1/2/2/2.00/0; `lumen.tech` 2/2/1/1.00/2; `daytonoffice.com` 1/2/1/1.00/1; `hvdata.net` 1/2/1/1.00/1; `verizon-gni.net` 2/2/1/1.00/2; then singletons. 20 rows.
- **These figures were subsequently withdrawn by the instance as statistically meaningless**: 16 Comcast landmarks over 14 routers is 1.14 landmarks per router, so a node with one landmark cannot exhibit more than one ZIP. Cogent at 5.9 landmarks/router was called "only marginally better" and dominated by universities each in a single ZIP.

Section 4c — shared addresses with registrants (ZIPs / places / registrant), top of 40 rows
`24.38.41.117` 903/1065 Cablevision Lightpath LLC · `46.110.128.82` 628/676 Metronet · `64.135.100.26` 520/585 BroadbandONE, LLC · `207.120.44.73` 512/598 Level 3 Parent, LLC · `104.192.64.158` 457/483 America Internet & Communications · `38.109.143.104` 408/428 Cogent · `24.255.96.229` 344/411 Cox Communications · `208.94.107.65` 263/279 Videotron Ltee · `207.120.44.75` 262/300 Level 3 · `207.120.44.79` 259/300 · `207.120.44.69` 252/280 · `207.120.44.78` 251/281 · `207.120.44.70` 229/252 · `207.120.44.71` 226/255 · `207.120.44.74` 220/240 · `216.206.109.129` 206/255 CenturyLink · `65.116.218.50` 189/201 CenturyLink · `208.94.107.23` 186/204 Videotron · `216.21.239.197` 173/180 Boost Mobile · `208.94.107.20` 156/164 Videotron · `209.65.14.75` 154/171 AT&T Enterprises · `107.0.132.30` 139/160 Comcast Cable · `38.70.131.12` 122/129 Cogent · `74.220.140.253` 114/138 Rightfiber · `38.58.228.227` 108/119 Cogent · `38.129.98.70` 108/118 Cogent · `208.94.107.35` 105/112 Videotron · `38.27.0.4` 91/110 Cogent · `98.113.13.89` 91/99 Verizon Business · `209.157.71.176` 75/78 NTT America · `96.99.227.255` 75/83 Comcast · `38.58.229.6` 74/131 Cogent · `96.99.240.155` 67/68 Comcast · `208.94.107.41` 62/67 Videotron · `65.51.66.35` 60/62 Cablevision Systems · `208.94.107.115` 59/67 · `208.94.107.36` 58/61 · `38.46.220.132` 56/82 Cogent · `208.94.107.33` 55/58 · `216.164.45.51` 46/53 RCN.
- **Twelve addresses in the 312-address sample carried over 200 ZIPs each.**

`mobile_transit` migration counts (from the `aad657b` run, which was partly broken)
- `ip2city_dbiplite_probe_tbl`: `f` **2,082,217**, `m` **15,653**.
- `ovt_places_usa_ip_trace`: `f` **312**.
- `UPDATE 0` / `UPDATE 0` for the transit backfill, and tier `f | 312 | 100.0` — **both wrong**, because zero transit rules had loaded (see Traps).
- Rules load on the `896c874` run: `DELETE 1`, "added the missing UNIQUE (rule_type, pattern)", `DELETE 0`, `INSERT 0 5`, **`INSERT 0 19`** (19 transit domains).

Other
- `deploy.sh` builds and installs **13 tools** each time; revisions seen: `04d89d0`, `85648a5`, `ed1254e`, `aad657b`, `896c874`.
- Upper Peninsula of Michigan, cited by the instance as reason to reject it as a survey site: "roughly 300,000 people across 42,000 km²". Not measured in-session; presented as background fact.
- Example stored hop list, MIT destination `18.9.108.52` (hops 1, 4, 5 unanswered): 2 `96.230.114.1` `lo0-100.BSTNMA-VFTTP-301.verizon-gni.net` 6.212ms · 3 `100.41.25.202` (no PTR) 7.218 · 6 `154.54.87.106` `be3664.agr22.bos01.atlas.cogentco.com` 6.77 · 7 `38.104.186.186` (no PTR) 11.018 · 8 `18.0.161.13` `dmz-rtr-1-external-rtr-3.mit.edu` 42.169 · 9 `18.0.161.2` `backbone-rtr-1-dmz-rtr-1.mit.edu` 34.462 · 10 `18.0.193.110` `oc11-755-rtr-1-backbone-rtr-1.mit.edu` 8.006 · 11 `18.9.108.52` `engineering-prod-cms-7.mit.edu` 21.347.

## Code, files, tables

Paths as given in the transcript (repo working copy `/home/boris/geo/src/claude`, runtime copies under `/var/trugeo` and `~/geo`).

- `geo/main.go` — the `last_carrier_node` tool. Changed across `04d89d0`, `85648a5`, `aad657b`: self-hop exclusion; `-zip-prefix` flag; CPE skipping by comparing a hop's registered domain to the destination's own reverse-DNS registered domain; new `reached-unnamed` status added to `isTerminal` and `resultRank`; hop-2 silence instrumentation with up to 3 retries; storage of the full hop list as `jsonb`; reads the new `transit_domain` rule type.
- `geo/landmark_carrier_node.sql` — the diagnostic and assignment battery. Sections referenced by number: 1b (waste counts), 1c (hop-2 silence percentages), 1d (node-inside-customer-AS check over the stored hop list), 4 (fan-out histogram, later found to conflate node breadth with address sharing), 4b (breadth measured only on single-ZIP addresses), 4c (shared addresses with registrants — a candidate provider list), 4d (yield split by node class), 8 (range-side merge), 9 (noted).
- `geo/overture_fetch/create_table_ovt_places_usa_ip_trace.sql` — creates/alters `ovt_places_usa_ip_trace`; adds the hop-list and instrumentation columns; idempotent with `IF NOT EXISTS` notices; grants to `cronuser`.
- `geo/overture_fetch/ovt_resolve_hosts.py` — run as `python3 ovt_resolve_hosts.py onpremises`; chunked recompute of `ovt_places_usa.onpremises` with periodic `VACUUM`.
- `geo/traceroute_hostname_rules.sql` — `traceroute_hostname_rules` table; rule types `tld`, `domain`, `customer-marker`, `customer-marker-regex`, plus the new **`transit_domain`** (19 domains, including `lumen.tech`, `he.net`, `twelve99.net`, Cogent and Zayo by domain; `att.net` deliberately excluded). In `896c874` gained an explicit `ALTER` adding `UNIQUE (rule_type, pattern)` after de-duplication.
- `geo/mobile_transit_migration.sql` — new in `aad657b`. Replaces `likely_mobile_cgnat boolean` with `mobile_transit varchar(1)` (`m`/`t`/`f`/`NULL`, with a `CHECK`) on `ip2city_dbiplite_probe_tbl`, `ip2city_dbiplite_traceroute_tbl`, `ip2city_dbiplite_history_tbl`, `ovt_places_usa_ip_trace`. Section 6 added in `896c874` handles `ip2city_dbiplite_traceroute_backup_tbl` the add/populate/verify/drop way, with the `DROP` left commented. Backfill reads `transit_domain`, so the rules file must run first.
- `geo/node_fanout.sql` — new in `896c874`. Fan-out as connected components over `zip_adjacency`; a >15-mile distance screen using db-ip centroids; every query prints `landmarks_at_node` and labels under-3 as `unmeasured`; per-operator table with `mean_landmarks_per_node`.
- `geo/check_geo_ip-api/cmd/main.go`, `geo/check_geo_ip-api/schema.sql`, `geo/check_routeviews_ip-api/cmd/main.go`, `geo/probe_range_split/cmd/main.go`, `geo/pipeline/rebuild_probe_tbl.sql`, `geo/probe_stability_tbl.sql` — all updated for the `mobile_transit` column and its string values.
- `geo/rdap-lookup/cmd/rdap-lookup.sh`, `geo/rdap-lookup/cmd/rdap-lookup-follow.sh` — mode changed 644 → 755. (The tool logged `rdap script "./rdap-lookup.sh" not usable … excluded-internal RDAP fallback disabled` in every run in this slice.)
- `geo/pipeline/deploy.sh` — builds 13 tools, installs under `/var/trugeo/<tool>/bin/`, installs pipeline scripts, `dma_api` support files, and `/etc/cron.d/trugeo`, then verifies revision and `vcs.modified` per tool.
- Tables touched or read: `ovt_places_usa`, `ovt_places_usa_ip_trace`, `ip2city_dbiplite_probe_tbl`, `ip2city_dbiplite_traceroute_tbl`, `ip2city_dbiplite_history_tbl`, `ip2city_dbiplite_traceroute_backup_tbl`, `range2zip_carrier_node_tbl`, `carrier_node_class` (new, seeded with 24 rules), `isp_names`, `provider_names`, `zip_adjacency`, `traceroute_hostname_rules`.
- Runtime paths: `/var/trugeo/last_carrier_node/bin/last_carrier_node`, `/var/log/trugeo/probe.paused`, `/var/lock/trugeo.mutation`.
- Not built in this slice: the ip-api comparison tool. Proposed design only — read on-premises landmark addresses with `-zip-prefix`, call ip-api at the existing 45/min, write to `ovt_places_usa_ip_api`, compare grouped by `isp` against `overture_zip` as ground truth across exact ZIP / adjacent ZIP / same zip3 / same state / wrong state.

## Commands worth keeping

```
cd /home/boris/geo/src/claude && git pull origin main && ./geo/pipeline/deploy.sh
cp geo/overture_fetch/ovt_resolve_hosts.py ~/geo/overture_fetch/
cd ~/geo/overture_fetch && python3 ovt_resolve_hosts.py onpremises
psql -d postgres -c "delete from ovt_places_usa_ip_trace where last_hop_ip = ip"
psql -d postgres -c "select count(distinct ip_address) as ma_landmarks from ovt_places_usa where onpremises and ip_address is not null and left(lpad(btrim(overture_zip::text),5,'0'),3) = '021'"
```

```
psql -d postgres -f geo/overture_fetch/create_table_ovt_places_usa_ip_trace.sql
psql -d postgres -c "truncate ovt_places_usa_ip_trace"
/var/trugeo/last_carrier_node/bin/last_carrier_node -source landmarks -zip-prefix 021 -n 5000 -concurrency 50 -ipv4-only -pause-file /var/log/trugeo/probe.paused
psql -d postgres -f geo/landmark_carrier_node.sql
```

Atomic mutation sequence (rules file must precede the migration, because the migration's backfill reads `transit_domain`):

```
sudo -v
exec 9>/var/lock/trugeo.mutation && flock 9
cd /home/boris/geo/src/claude && git pull origin main
psql -d postgres -f geo/traceroute_hostname_rules.sql
psql -d postgres -f geo/mobile_transit_migration.sql
./geo/pipeline/deploy.sh
exec 9>&-
```

Proposed national pass (offered at the end of the range; the transcript does not show it being run):

```
/var/trugeo/last_carrier_node/bin/last_carrier_node -source landmarks -n 30000 -concurrency 50 -ipv4-only -pause-file /var/log/trugeo/probe.paused
psql -d postgres -f geo/node_fanout.sql
```

## Traps and gotchas

- **Destination answers ICMP, so the "last carrier node" is the landmark itself.** Examples from the 2,000-row run: `34.174.18.13 -> last_hop=34.174.18.13 13.18.174.34.bc.googleusercontent.com`; `162.241.224.125 -> box5184.bluehost.com`; `158.51.40.117 -> 158-51-40-117.brownrice.com`. Unusable for convergence — you cannot match a probe range's carrier node against a landmark's own web server. Hidden by range targets because a random range address rarely answers. Fix: never accept a hop equal to the traced address; the carrier node is the preceding hop, already in the trace. Verified old-vs-new side by side: before `63.75.167.10 → mega-dodo.synergy-networks.com`; after, hop 8 `dns.google`.
- **Fixing that exposes a second layer: the customer's own routers.** With the destination excluded, the chosen hop became the business's own equipment, sharing the destination's address space and domain — MIT `18.0.193.110` (same /8), Harvard `140.247.2.50` (same /16), Tufts `130.64.1.58` (same /16), `204.167.92.26 gatehouse.cambridgema.gov` (same /16). Fix: derive the destination's registered domain from its own reverse DNS and skip any hop sharing it. MIT then resolves to `lmagw1-te-7-3-core.nox.org`, its real upstream. A later run shows up to **4** customer hops skipped on one address.
- **The "nearest resolved hop is at position 2 or 3" rule preempted the unnamed-carrier case**, returning `unreachable` even when hops further out had responded without resolving. These are different conditions; conflating them hid exactly the case Boris asked about. Required restructuring the selection, not patching it.
- **`reached-unnamed` was missing from `isTerminal` and `resultRank`**, so that case retried 3 times pointlessly before being accepted.
- **An unnamed hop cannot be tested for customer ownership by domain.** If a business's own routers are unnamed, `reached-unnamed` may still be sitting on one. The test that settles it is origin AS (MIT is AS3 holding `18.0.0.0/8`), which is why the full hop list is now stored.
- **`CREATE TABLE IF NOT EXISTS` silently skips adding new constraints to an existing table.** `traceroute_hostname_rules` already existed, so `UNIQUE (rule_type, pattern)` never reached it, both `ON CONFLICT (rule_type, pattern)` inserts aborted with `ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification`, **zero transit rules loaded**, and the backfill reported `UPDATE 0 / UPDATE 0` with tier `f | 312 | 100.0` — a clean-looking but wrong result. `psql` logs the error and continues, so the overall run looked successful. The instance had anticipated the same hazard for the `CHECK` constraint and written an explicit `ALTER` for it, but not for the `UNIQUE`. Fix in `896c874`: de-duplicate, then `ALTER TABLE … ADD UNIQUE` explicitly.
- **An in-place column rename destroys the ability to verify the value mapping.** With `likely_mobile_cgnat` renamed away on four tables, no row-by-row check of the `m`/`t`/`f` mapping is possible, and that is unrecoverable. The counts (2,082,217 `f`, 15,653 `m`) are consistent but are not the requested check. Correct pattern, which Boris insisted on: add the new column, populate, verify, then drop the old one.
- **`ip2city_dbiplite_traceroute_backup_tbl` was omitted from the migration's table list** and still carried `likely_mobile_cgnat boolean` at the end of the range, after two attempts.
- **Measuring fan-out over all places behind a node conflates node breadth with address sharing.** One address serves many places, so section 4 reported `lumen.tech` at 1,108 ZIPs across four addresses — that measures the sharing, not the node. Fix: measure breadth only on addresses that map to a single ZIP (4b), and report the shared ones separately as a candidate provider list (4c).
- **Low landmarks-per-node makes fan-out figures meaningless, and this produced a false conclusion.** 16 Comcast landmark addresses over 14 router IPs = 1.14 per router; a node with one landmark behind it cannot show more than one ZIP whatever its real breadth. The instance's "13 of 14 Comcast routers serve one ZIP" was arithmetic, not measurement, and was withdrawn. Mitigation: every fan-out query now prints `landmarks_at_node` and labels under three as `unmeasured`; read `mean_landmarks_per_node` first.
- **Router hostnames record where the router is, not where the subscriber is.** Boris: Comcast serves West Roxbury through a Brockton node (an hour away, very different demographics) and Lynn through a Woburn node. So `po-1-rur201.westroxbury.ma.boston.comcast.net` is an identity for matching, not geographic signal. The assignment code already treated it as identity; the instance's commentary was wrong.
- **Rule 3a (`isp_names` → `onpremises = true`) is a hard true that bypasses every ZIP test**, and admits ISP shared web hosting at scale — one datacenter address serving hundreds of customer websites nationwide (Cablevision Lightpath 903 ZIPs, Metronet 628, BroadbandONE 520, Level 3 512, Cox 344, Comcast 139, Boost Mobile 173).
- **The cluster-based hosting test needs ≥2 landmarks at an address** to see any spread, so a CDN or hosting address carrying exactly one landmark still passes as on-premises. `provider_names` is still needed for that case; it cannot be retired yet.
- **`psql -f` with a relative path fails if you are not in the repo root**: `psql: error: geo/landmark_carrier_node.sql: No such file or directory` after `cd ~/geo/overture_fetch`.
- **Running `-source landmarks` before applying `onpremises` wastes most of the pass.** The run was full of Cloudflare (`104.21.x`, `172.67.x`, `104.16.x`, `104.26.x`), `googleusercontent.com`, `secureserver.net`, `cloudfront.net`, `unifiedlayer.com`, `dreamhost.com`, `hostgator.com`, `weebly.com`, `vultrusercontent.com`, `linodeusercontent.com`, `contaboserver.net`. The Cloudflare traces all terminate at `152.193.179.74 customer.alter.net`, one Verizon customer-edge router, which is why `excluded-internal` is so frequent.
- **Changing the CPE rule invalidates every previously chosen node**, not just the self-traced ones, so a full `truncate` of `ovt_places_usa_ip_trace` was required rather than a targeted delete.
- **A rename across three deployed binaries needs a lock.** `exec 9>/var/lock/trugeo.mutation && flock 9` makes cron wait rather than fail during the window where a running binary would reference a column that no longer exists.
- **One extreme latency outlier worth knowing about**: `204.107.223.44` showed `long-haul latency jump after hop 11: +2142.5ms to hop 12 (2186.9ms)` through `45.76.58.171.vultrusercontent.com`.
- Shell-safety notes from the instance's own edits: a `\1` would have put a backslash in a file and broken paste safety; a literal `b######` placeholder put a mid-line `#` into SQL; one edit broke `gofmt`. All caught and fixed before commit.

## Boris's instructions, preferences and standing orders

- **Always `sudo -v` before other commands** when sudo is needed.
- **Never match landmarks to dynamic/household addresses by range or prefix.** Static and dynamic ranges for the same area are deliberately separate so the dynamic range can be relocated while the static range stays with the customer.
- **Treat "Comcast is nearly ZIP-specific" with extreme caution and test it.** His evidence: West Roxbury served through a Brockton node, Lynn through a Woburn node. His words: "I wish it was correct, but the evidence just listed suggests we test."
- **Check every last carrier node for fan-out and report any case beyond one ZIP or a cluster of adjacent ZIPs.**
- **Narrow transit nodes are eligible for ZIP-level targeting** — they may carry institutional housing or at-work media use.
- **Do not rule out business IPs.** They consume biddable media, at work and in campus housing.
- **CGNAT gives only DMA-level accuracy; treat transit providers (Cogent, Lumen, Zayo) the same, but keep them distinguishable from mobile CGNAT for auditability.** Hence `mobile_transit varchar(1)` with `m` / `t` / `f` (fixed = coaxial, fibre, hybrid or DSL).
- **For column changes: add, populate, verify, then drop. "I did not ask for a direct rename; I asked for an end result."**
- **Prefer a measurable per-address rule over hardcoded registrant names.** Define hosting as an IP serving more than one ZIP cluster where the clusters do not border each other, rather than maintaining names in the providers table.
- **Run ip-api.com probing only for `onpremises=true` records, and only after computing `onpremises`.**
- **Priority shift at the end of the range: the small number of `onpremises=true` Overture landmarks is obstructing research and operations — import the other sources listed in the memo, starting with Foursquare.** Watch for duplicates, though he expects duplicates to cost processing time rather than break operations.
- Observed accuracy asymmetry he wants quantified: ip-api is miles-off for Verizon FIOS but ZIP-precise for RCN.
- Retry policy: if hop 2 from the Mint30 FIOS link does not respond, retry up to 3 times; report both percentages; the limit may need raising. Note that the whole system will eventually move to AWS, where first-carrier-node rate limits will not occur.
- Asked for a critique of his own plan (MA ip-api probe + Upper Peninsula rural survey) rather than compliance.

## Open items at end of slice

- `ip2city_dbiplite_traceroute_backup_tbl.likely_mobile_cgnat` still `boolean` and still not migrated. Section 6 of the migration exists with the `DROP` commented; Boris flagged it as outstanding for the second time, and his last run still shows it as `boolean`.
- The transit backfill had not yet been seen to actually move rows to `t`. On the `896c874` run the 19 rules finally loaded (`INSERT 0 19`) and the migration reported all four tables "already has mobile_transit, skipped"; the slice ends inside the verification output, so the post-fix tier distribution is not visible.
- The ip-api.com accuracy comparison is designed but **not built**. Boris has now constrained it: `onpremises=true` only, after `onpremises` is computed.
- Foursquare (and the other memo sources) import not started — newly made the top priority.
- The national pass (28,324 addresses, ~2.2 h) was proposed but is not shown as run. `geo/node_fanout.sql` exists and is untested against real data; the instance said it is "where the Comcast question gets answered properly".
- The Upper Peninsula survey remains Boris's request; the instance argued against it as underpowered but Boris had not responded to that critique within the range.
- Rule 2b (cluster-based hosting, ordered before rule 3a) was proposed and implemented as machinery, but whether it supersedes `provider_names` is unresolved — the single-landmark gap remains.
- `LinkNow Media` (a website builder, 924 ZIPs across 9 addresses) identified as missing from `provider_names`; no confirmation it was added.
- The 38.7% / 58.3% node-inside-customer-AS rate is unexplained. The instance explicitly refused to guess; a query to list examples is in the file.
- Backbone exclusion ruling for Cogent and Zayo by router-role regex rather than by domain was requested twice and never given; the `aad657b` rules include them by domain with the mislabelling cost written down, which section 4b made more consequential.
- Previously traced rows needed re-tracing after each classification change; the `DELETE`/`TRUNCATE` to re-queue them is written out and commented in the SQL.

## Uncertain

- The recurring `SELECT 1192937` / `CREATE INDEX` / `ANALYZE` / `COMMIT` block is a temp relation of 1,192,937 rows built for the origin-AS join in section 1d. The transcript never names it or says what it is built from (presumably the BGP/RouteViews data), so I cannot say more.
- `UPDATE 35438` appears once in the section that writes the chosen node back, and `UPDATE 0` in a later identical section. The transcript does not state which table or column, nor explain the difference between the two runs.
- The two throughput rates quoted — 4.57 traces/sec (measured, 2,000 in 7m18s) and "the measured 3.5 traces/sec" (used for the 2.2-hour estimate) — are not reconciled anywhere in the range.
- Whether the first 2,000-address run used `-source landmarks` or `-source ranges` is not stated in the visible log header; the analysis treats the targets as landmarks, and the instance notes range targets "hid this", implying landmarks.
- The contents of "the memo" listing the sources to import are not in this range; only Foursquare, OSM and Wikidata are named in passing, with "~44,000 inhabited ZIPs" as the coverage target.
- `carrier_node_class` was seeded with 24 rules, but the rule contents are not shown — only the resulting four classes and their counts.
- The 19 `transit_domain` patterns are not individually listed; only `lumen.tech`, `he.net`, `twelve99.net`, Cogent and Zayo (included) and `att.net` (excluded) are named.
- Whether Boris accepted the "trace everything nationally, then slice analytically" argument is not determinable: his next message redirected to Foursquare import without addressing it.
- The `>15 miles` distance screen threshold and the `zip_adjacency`/db-ip centroid data sources are described but their provenance and prior existence in the schema are not established in this range.
