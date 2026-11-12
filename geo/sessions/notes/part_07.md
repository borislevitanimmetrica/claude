# Part 07 (lines 28861-33670)

## Narrative

The slice opens with the DMA API (`dma_api`, the 9th tool) already written and the instance reporting that it had installed PostgreSQL 15 in its own sandbox and run the service end-to-end against fixtures rather than merely compiling it — 268 addresses from a /30 + /24 + /29, `.0` and `.255` present, wrong-state and other-DMA rows excluded, zero duplicates despite a deliberately doubled `dma2city_tbl` row, gzip 605 vs 3,866 bytes, HTTP 413 on an oversized `?max=10`, HTTP 400 on a non-numeric code, and the embedded GUI served. Merged as 21e0253.

Boris's first intervention was to delete `AND family(p.network) = 4` from the query: unnecessary because there is no IPv6 in the table, and a trap because when IPv6 is switched on the qualifier would be forgotten and silently drop rows. He called it "Bad advice." The instance accepted and extended the principle, finding two more instances of the same trap it had written itself: `writeAddresses` returned `(0, nil)` for a non-IPv4 prefix (silent omission) and the summary hardcoded `2^(32 - masklen)` for every row (simply wrong for IPv6, not merely exclusionary). Families are now counted rather than filtered (`ranges`, `ipv4_ranges`, `ipv6_ranges`), `/addresses` refuses IPv6 with HTTP 409 and `?skip_ipv6=1` returns IPv4 with an `X-Incomplete` header, and a new section 7 of `query.sql` makes the one remaining — genuinely necessary — IPv6 exclusion visible. Merged cd5b1b6.

Boris then asked for precise deployment steps and for advice on IPv6. Checking the unit file first surfaced a real bug it had shipped: `geo_common.sh:47` sources `/etc/trugeo.env` with a plain `.` and no `set -a`, so the file needs `export` prefixes to reach child processes, but systemd's `EnvironmentFile=` cannot parse `export` — it would have read the variable name as `export PGDATABASE`, skipped the line, and left the service connecting to a database named `cronuser`. Fixed on both sides, merged 9e8e7ba, with the journal line `database reachable as cronuser@postgres` named as the diagnostic.

On IPv6 the instance argued Boris's premise (distinguish delegated from undelegated prefixes, or assume always-delegate) does not hold: prefix delegation happens over DHCPv6-PD driven by RADIUS and is not observable from public data. Boris countered with the ZIP-targeting arithmetic — 55,000+ assigned US ZIP codes, and more cable headends than the "few thousand prefixes" the instance had claimed. The instance withdrew that figure as fabricated, and conceded that IPv6's BGP-derived geographic resolution is structurally worse than IPv4's because aggregation was the design goal. Boris also set the priority: big screens primary, mobile nice-to-have, which the instance accepted as invalidating its repeated IPv6 urgency (it had been reasoning from a 57-68% US mobile-IPv6-traffic statistic that does not match the targeting priority).

The instance then measured `probe_tbl.zip` coverage, and Boris rejected the query as irrelevant: the architecture for ZIP -> city -> IP range already exists via `city2zip_tbl`, and he wants a landmark table (schools, universities, municipal governments with on-premises domain-carrying systems and known ZIPs) as the definitive source of truth for BGP range -> ZIP, ahead of ip-api. He specified that the ZIP service must accept multiple ZIP codes (file, JSON, or GUI) while the DMA service must default to `multiple_markets=off` with a toggle, so local advertisers cannot accidentally buy out-of-market.

Boris's split-range hypothesis drove the most productive work in the slice. He proposed that ranges wider than /24 which appear unitary in both db-ip and RouteViews may actually be split, and that this should be tested by probing /24s inside them. The instance's first candidate query returned the wrong population entirely — AWS /16s, a Level 3 /8 geolocated to its Monroe LA headquarters, and RIPE space asserted as US cities — and its first probe command was useless (`-count 1`, a single random range). Boris asked "You probed 1 address?" The instance then built `probe_range_split`, a disposable-turned-permanent 10th tool that enumerates the sub-blocks of a range or samples one /24 per prefix of an ASN, and writes nothing to the database.

Enumerating all 16 /24s of Charter's 76.90.64.0/20 confirmed Boris's hypothesis: one city (Hemet, CA) and three distinct ZIPs. It also refuted an argument the instance had built two messages earlier from an 8-sample run that returned a single ZIP — the tool now prints a sampling caveat whenever it has not enumerated every block, because only a SPLIT verdict is safe from a partial sample. Boris's framing of the result was that ZIP-boundary crossing within a range is an inherent inaccuracy of ZIP targeting that landmarks will not fix.

Carrier testing followed. T-Mobile (AS21928), Verizon (AS6167, AS22394), AT&T Mobility (AS20057) and Comcast as fixed-line control (AS7922) all came back RESOLVABLE, with T-Mobile showing more geographic dispersion than Comcast — so the instance's NAT64/464XLAT warning produced no case for excluding mobile carriers. The more consequential finding was in Comcast's ZIP column: 10123 sixteen times (Empire State Building), 07175 eight times (Newark PO Box), plus O'Hare's 60666 and other unique ZIPs. ip-api's ZIP quality is bimodal — genuinely per-block in some ranges, a city-centroid placeholder in others. Boris's response closed the question: PRIZM and Census products contain no PO Box or airport ZIPs, so a placeholder ZIP in the output can never match a buy; such viewers fall out of ZIP buys and remain available for DMA buys.

Boris then directed the decomposition-exclusion design: a separate table from `geo_exclusions` (name and separate handling approved), registrant obtained from ip-api rather than RDAP, matched by operator name with LIKE and explicitly never by ASN because ASN matching oversweeps and does not track ownership changes. The instance confirmed from the lock code that probing is NOT excluded during decomposition (`daily_pipeline.sh` takes its own and the mutation lock but never the probe lock, and the 02:05 probe batch starts inside the 02:00-02:17 window), and flagged that Boris had written 45/h where the project limit is 45/min. `decomposition_exclusions.sql` was created seeded with Amazon only, and `apply_splits` gained an operator check plus a defer-when-unprobed rule.

Boris's /28 test of T-Mobile ranges produced the slice's most alarming finding by accident. On 2026-09-09, 172.56.54.0/24 split three ways across /28 boundaries — Willowbrook 90061, Los Angeles 90099, West Rancho Dominguez 90247. On 2026-09-13 the identical command on the identical range returned Dallas TX 75237 on all sixteen /28s, twice. A mobile /24's city is not stable over time, and nothing in the pipeline would notice: `ran_at` records when a range was measured but there is no re-measurement and no drift detection. Boris asked for a `-repeat` mode and a comparison against Comcast and Charter.

The `apply_splits` dry run on Boris's real data was then shown to be vacuous: 82 already-/24-or-narrower plus 260 prefix-excluded equals the whole 342-row candidate set, so the registrant gate had never executed. Worse, `dbip_split_candidates` holds only 396 rows (`check_range_splits` flags only ranges with more specific BGP children) while 371,757 sub-/24 db-ip ranges are not candidates at all — decomposition as wired addressed roughly 0.1% of the problem, and nearly all of the 260 kills were DoD space.

Boris then reversed his own earlier instruction: "If RDAP is better, identify exclusion candidates using RDAP rather than ip-api." The instance built `rdap_registrant` and an allocation-keyed cache table, switched `apply_splits` to `-registrant-source rdap` by default, and verified against live ARIN that an unprobed Amazon /16 is excluded under RDAP but only silently deferred under ip-api — which is why decomposition was broken. It also built the `-repeat` mode with a fixed-address cohort design, measured ip-api's rate-limit headers, wired ip-api's own `mobile` field alongside the keyword classifier, and settled the Puerto Rico question by direct query (ip-api returns `countryCode: PR`, empty `region`, empty `zip`, and the pipeline's `-country US` filter means no PR rows exist at all).

The RDAP cache fill surfaced two more faults immediately: a per-row `permission denied for sequence rdap_registrant_tbl_id_seq` (bigserial needs USAGE on its sequence, which the grants omitted) and a wasted-budget design error where the widest-first candidate ordering spent the first 43 queries on DoD space that `apply_splits` discards before ever consulting the registrant. Both fixed. The coverage measurement then came back strongly in RDAP's favour: 25 queries covered ~109.8M addresses, and a 500-query run reported 632 candidates already answered from cache against 500 queried.

The registrant names were the real payload, and they changed the policy. The first 25 candidates alone — Ford, Prudential, JPMorgan, Bank of America, HP, Apple, Microsoft, CoreWeave, Texas DIR, USDA, Level 3 — would generate 182,272 /24 rows, 68.5% of them belonging to registrants with no consumer access product. The instance argued this dissolved Boris's earlier reluctance to exclude corporate ranges, because an RDAP name is self-healing on ownership change. Boris rejected the reasoning outright: the same run returned University of Michigan, Michigan State, Stanford, MIT, Grand Valley State, Merit Network, Utah Education Network and the Board of Regents of the University System of Georgia, universities run student housing, and people at work at Ford or Boeing consume media and are valid targets. RDAP cannot distinguish infrastructure from end-user space. Only DoD is to be excluded; remove Amazon. The instance confirmed the table was NOT in that state, rewrote the policy file to be DoD-only and self-enforcing, and seeded six DoD patterns all observed in the run.

Boris's next paste exposed three more bugs. Maintainer objects (MNT-ADSI, MICROSOFT-MAINT, APPLE-MNT, ORCL-MNT, OPENDNS-MNT) had been stored as registrants because the tool took the first entity in document order; `RIPE-NCC-MANAGED-ADDRESS-BLOCK` had been stored as a registrant for two /8s, which poisoned the cache's coverage test and would have permanently suppressed 33.5M addresses; and section 6 of the policy file had silently aborted with `function round(double precision, integer) does not exist`. All three fixed, plus `rdap_registrant_repair.sql`, which Boris ran: DELETE 39.

The slice closes with Boris asking whether the non-rate-limited ip-api burst ran without error, and restating his alarm at seeing telecom carriers in the instance's registrant output — "these ranges could be customer-connecting or could be reallocated to that role." Before that the instance had measured ip-api's throttling behaviour from its own sandbox IP across ~420 calls and found that ip-api throttles by stalling, never by returning 429, that offering more delivers less, and that the 429 handler in `check_geo_ip-api` had therefore been dead code while throughput degraded silently. There is also a session interruption mid-slice ("You appear stuck in Running command. abort, reconnect"), after which state was verified intact at 1e828f3 with 12 tools building.

## Decisions and rationale

- **Remove `AND family(p.network) = 4` from the DMA query.** Boris's decision, stated as an order. Rationale: no IPv6 in the table makes it unnecessary, and it is a landmine for the IPv6 switch-on. He called the instance's inclusion "Bad advice." Accepted; the instance extended the principle to two more sites it had written and changed family handling from filtering to counting.
- **Keep exactly one IPv6 filter, in `query.sql` section 3 (address expansion), and make its effect visible.** Instance's decision, accepted implicitly. Rationale: an IPv6 /64 has 18,446,744,073,709,551,616 addresses, so enumeration is undefined rather than merely expensive. New section 7 lists the IPv6 ranges the expansion skipped, returning nothing today and starting to return rows exactly when `PROBE_IPV4_ONLY=0`.
- **`/addresses` returns HTTP 409 for IPv6 rather than omitting it.** Instance's decision, prompted by Boris's objection. Rationale: silent omission is the exact failure mode Boris had described. `?skip_ipv6=1` is the explicit opt-out and carries `X-Incomplete`.
- **Address expansion happens in Go, not SQL, for the API.** Instance's decision, in answer to Boris's direct question. Rationale: expansion is pure arithmetic needing no database state; doing it with `generate_series` would push 3.4M rows through the wire protocol. Measured in the fixture test: PostgreSQL emitted 3 rows while the client received 268 lines. `query.sql` section 3 does expand in SQL, because a psql user has no application layer.
- **The API binds loopback only.** Instance's decision. Rationale: no authentication, and enumerating a large DMA is expensive, so exposure would let anyone force millions of rows of work.
- **DMA service accepts one DMA at a time; `multiple_markets` defaults off with a toggle.** Boris's decision, overriding nothing but refining the instance's multi-code proposal. Rationale: local advertisers would enter multiple markets in error and receive largely out-of-market lists. National backfill buying is the use case for the toggle, and he noted that practice has dwindled over the past decades. The instance added that the guard must be enforced server-side because a GUI-only guard is bypassed by direct API use; Boris did not object.
- **ZIP and DMA services share one multi-code plumbing mechanism.** Instance's proposal, accepted by Boris ("I agree that the architecture for the frontend should be the same"). Rationale: the multi-DMA upgrade becomes a route addition rather than a second implementation.
- **Build the ZIP API/GUI now vs landmarks first.** Boris stated he was going to build the landmark table before the user interface. The instance argued the interface does not depend on it (the resolution source sits behind the join), so sequencing is a preference not a dependency. The transcript does not record Boris resolving this either way within the slice.
- **Do not exclude datacentre, cloud or corporate ranges from targeting.** Boris's decision, rejecting the instance's spend argument twice. Rationale given: (1) if a device is not used to stream video its IPv4 will never come up for bid, so including it costs nothing; (2) reallocation from Amazon, datacentre operators, or smaller businesses is imaginable in a way it is not from DoD, and Google has a fiber operation it could conceivably reallocate numberspace to. Combined with his false-negatives-are-worse rule the asymmetry is decisive. The instance accepted and called its own spend argument "simply wrong."
- **Do not exclude Google or any company that directly or indirectly serves customers.** Boris's explicit instruction.
- **Decomposition exclusions live in their own table, not in `geo_exclusions`.** Instance's proposal, explicitly approved by Boris ("name and separate handling from geo_exclusions approved"). Rationale: a decomposition exclusion costs granularity but never coverage — the range stays in the probe table and stays targetable at its original width — whereas a `geo_exclusions` entry removes a range from probing and output, so a wrong entry there is an invisible false negative. Mixing them invites someone applying a decomposition rule as a targeting filter.
- **Match decomposition exclusions on operator name with LIKE, never on ASN.** Boris's decision, overriding the instance's ASN proposal. Rationale: ASN matching oversweeps, and it keeps oversweeping after additions, drops and ownership changes; the name follows the range. The instance accepted, called Boris's reasoning better than its own, and implemented ILIKE patterns with no ASN matching anywhere. It later confirmed the predicted cost of name matching: 167.20.43.0/24 inside AS21928 returns isp "Sprint Communications", which a `T-Mobile%` pattern would miss — a missed pattern you can add, versus ASN matching failing by oversweeping silently.
- **Serialise the registrant lookup against probing with the probe lock.** Boris: "I agree with the probing fix." Implemented but deliberately inert behind `DECOMPOSE_LOOKUP_REGISTRANT=0`, because taking the lock unconditionally would cost a skipped hourly batch (~2,400 probes) every night the pipeline is still running at 02:05, in exchange for nothing until the registrant lookup exists.
- **Use RDAP, not ip-api, for the registrant.** Boris's decision, reversing his own earlier "Use ip-api, not rdap-lookup" instruction, conditioned on the instance's answer that RDAP is better ("Since RDAP is better, identify exclusion candidates using RDAP rather than ip-api"). Rationale established by the instance: ip-api `isp`/`org` exist only as a side effect of probing one address, so an unprobed range has no registrant and must be deferred, which silently defeats the exclusion; RDAP is keyed on the prefix and answers for any range at any time. ip-api retained as a selectable option.
- **Only DoD is excluded from decomposition. Amazon removed.** Boris's decision, overriding the instance's recommendation to add Ford, Prudential, JPMorgan, Bank of America, HP, Apple, Texas DIR, USDA, CoreWeave and Microsoft. Rationale: large universities may use their ranges for student housing; people at work at the listed organisations consume media and are appropriate targets under his rules; RDAP data cannot distinguish purely-infrastructure ranges from ranges serving end users. The instance confirmed the table was not in that state, accepted the reasoning, and restated the test as "can this space be ruled out as serving end users with certainty" — which only DoD passes, for a reason unrelated to commerce.
- **The policy file is self-enforcing and deactivates rather than deletes.** Instance's decision. Re-running `decomposition_exclusions.sql` deactivates anything not on the DoD list, so the table converges on policy regardless of hand edits; rows are deactivated so the history of what was once excluded stays readable.
- **`DIA` is matched exactly, with no wildcards.** Instance's decision. Rationale: `%dia%` would also hit India, Media, Nvidia and Acadia. Verified against "Nvidia Corporation" and "India Internet Media".
- **RDAP administrative placeholders store a NULL registrant and are treated as *known*, not unknown.** Instance's decision. Rationale: the registry was asked and holds no assignment, which is positive evidence that no DoD registration exists; treating it as unknown would defer that space permanently because no later query can improve the answer.
- **Never probe the ip-api ceiling from the IP the pipeline runs on.** Instance's recommendation after measuring that the throttling penalty appears to persist. Presented as a hard rule but based on two samples, so an indication rather than a measurement.
- **Do not run `apply_splits` without `-dry-run` yet, and do not point it at the full 371,757 candidates.** Instance's recommendation. Rationale: turning it on multiplies the probe backlog against a limit now known to be 32 days deep, so it should be a deliberate act.
- **Exclusions were never the lever that makes decomposition affordable; the paid ip-api batch endpoint is.** Instance's conclusion after the DoD-only policy was set. The transcript does not record Boris responding to this within the slice.

## Measured facts and numbers

All figures below are measurements run during the slice unless marked as an estimate or a derivation.

**DMA API fixture test (instance's sandbox PostgreSQL 15, start of slice)**
- Address count 268 = 4 + 256 + 8 (a /30, a /24, a /29).
- Duplicates from a deliberately doubled `dma2city_tbl` row: 0 with DISTINCT; doubled output without it.
- gzip vs plain: 605 vs 3,866 bytes.
- `?max=10` returned HTTP 413 naming the real size; non-numeric code returned HTTP 400.
- `index.html` served at `/` returning 200 with 10,751 bytes.
- Mixed-family re-test: DMA 527 unchanged at 268 addresses; DMA 510 reported 1 IPv4 and 1 IPv6 range; `/addresses` returned 409; `?skip_ipv6=1` returned 4 addresses with header `X-Incomplete: 1 IPv6 ranges omitted at caller request`; section 7 named `2001:db8::/64`.
- PostgreSQL emitted 3 rows while the client received 268 lines (expansion in Go).

**Scale figures for the DMA API (derived, not measured)**
- Indianapolis: 3,444,280 addresses, ~50MB of text, from 5,654 database rows. Expansion multiplies the payload ~250x. "a large DMA is plausibly ten times that" is an estimate.

**ZIP coverage on `ip2city_dbiplite_probe_tbl` (Boris ran)**
- total 2089296, with_zip 12050, distinct_zips 4695. Boris declared this query irrelevant to his architecture.

**Range-split enumeration, 76.90.64.0/20, Charter Communications**
- Run 2026-09-09 01:25: 16 of 16 probes succeeded. Cities: Hemet, CA ×16. ZIPs: 92543 ×12, 92544 ×3, 92545 ×1. Verdict SPLIT BY ZIP ONLY.
- Run 2026-09-13 17:14: 16 of 16. ZIPs: 92543 ×13, 92544 ×2, 92545 ×1. Same verdict. (The two runs disagree on the 92543/92544 split by one block each way.)
- Earlier partial samples on the same range: 4 samples found 2 ZIPs; 8 samples found 1 ZIP and reported UNITARY; 16 found 3.
- Instance's characterisation: "ZIP targeting is wrong for 3 of 16 blocks — about 19% of that range."
- Cost: a /20 is 16 calls, roughly 21-22 seconds.

**T-Mobile /28 enumerations (`-block 28 -samples 16`)**
- 172.56.10.0/24: all 16 /28s Minneapolis MN 55467.
- 172.56.54.0/24 on 2026-09-09 02:33: 16 of 16. Willowbrook CA 90061 ×8, Los Angeles CA 90099 ×4, West Rancho Dominguez CA 90247 ×4. Verdict SPLIT BY CITY.
- 172.56.54.0/24 on 2026-09-13 17:15 and again 17:27: 16 of 16 both times, Dallas TX 75237 ×16. Verdict UNITARY. Roughly 1,400 miles from the earlier reading.
- 172.58.118.0/24: Santa Ana CA 92703 ×16. UNITARY.
- 172.56.166.0/24: Brooklyn NY 11208 ×16. UNITARY.

**Carrier resolvability (`-asn N -samples 40`, one /24 per prefix)**
| ASN | operator | prefixes originated | probes ok | cities | ZIPs | verdict |
|---|---|---|---|---|---|---|
| 21928 | T-Mobile US | 285 (286 on the later run) | 40/40 | 29 | 32 | RESOLVABLE |
| 21928 | T-Mobile US (2026-09-13 re-run) | 286 | 40/40 | 27 | 30 | RESOLVABLE |
| 6167 | Verizon | 2176 | 39/40 | 30 | 33 | RESOLVABLE |
| 22394 | Verizon (first, 429-spoiled) | 190 | 18/40 | 12 | 12 | RESOLVABLE |
| 22394 | Verizon (clean re-run) | 190 | 40/40 | 16 | 16 | RESOLVABLE |
| 20057 | AT&T Mobility (429-spoiled) | 1465 | 11/40 | 6 | 7 | RESOLVABLE |
| 7922 | Comcast (fixed-line control) | 426 | 40/40 | 11 | 12 | RESOLVABLE |

- Comcast's ZIP distribution: 10123 ×16 (Empire State Building), 07175 ×8 (Newark PO Box), 10013 ×4, 99209 ×3, 75225 ×2, and one each of 02148, 07305, 30302, 38119, 60164, 60628, 98160.
- Four Comcast-announced 48.4x blocks returned isp "AviationAI" with ZIP 10013; 48.0.0.0/8 is recently-allocated space and ip-api carries stale attribution for it.
- Instance's own ZIP-type classification of the AS21928 run: 12 of 40 on PO Box or unique ZIPs (60666 ×5 = O'Hare, 07175 ×2, 75270 ×2, 30333, 33102, 99260, 46255), plus 172.59.16.0/24 in Puerto Real returning no region and no ZIP — 13 of 40, about a third. This classification is the instance's own, from ZIP-type knowledge, and was explicitly flagged as needing verification against an authoritative USPS Standard/PO Box/Unique list that `city2zip_tbl` does not carry.

**Sub-/24 decomposition sizing (Boris ran)**
| masklen | ranges | would_become_24s |
|---|---|---|
| 9 | 2 | 65536 |
| 10 | 2 | 32768 |
| 11 | 5 | 40960 |
| 12 | 19 | 77824 |
| 13 | 42 | 86016 |
| 14 | 104 | 106496 |
| 15 | 349 | 178688 |
| 16 | 2648 | 677888 |
| 17 | 2181 | 279168 |
| 18 | 3849 | 246336 |
| 19 | 7367 | 235744 |
| 20 | 15902 | 254432 |
| 21 | 36358 | 290864 |
| 22 | 98199 | 392796 |
| 23 | 201493 | 402986 |

- Instance's sums: 368,520 ranges become 3,368,502 /24 rows, roughly 3.0M net new, taking the table from 2,089,296 to about 5.09M. The /16 row is the single largest contributor at 20% of the total. The /9-/12 rows are 28 ranges producing 216,000 /24s.
- Cycle arithmetic given at 57,600 probes/day: ~36 days becomes ~88 days. Later restated at the measured 64,800/day: ~52 days for the new rows, ~84 days including the existing backlog.

**BGP and exclusion audit (Boris ran)**
- `bgp_route_views` contained `0.0.0.0/0` with origin_asn 174, updated_at 2026-08-31 08:00:00-04. Deleted; `remaining_default_routes` then 0.
- AS174's next-widest announcements: 38.0.0.0/8, 208.0.0.0/11, 154.48.0.0/12, 63.160.0.0/12, 65.160.0.0/13, 205.240.0.0/13, 154.40.0.0/13, 154.24.0.0/13, 206.104.0.0/14.
- `geo_exclusions` ASN rules, widest prefix each ASN announces: AS749 /8 with 3132 prefixes; AS721 /8 with 232; AS665 /15 with 41; AS22 /16 with 5; AS56 /16 with 935; AS289 /16 with 6; AS306 /16 with 277; AS300 /16 with 35; AS367 /16 with 1075; AS138 /16 with 18. All safe.
- `bgp_route_views` totals from the dry-run log: bgp=1140791 (1140792 in an earlier entry), dbip_rows=5447333, routeviews_rows=496386. Earlier in the session the BGP prefix count was quoted as 1,140,132.
- `dma2city_tbl` with_dma_code = **31899** — settling the blocking question of whether `dma_code` is populated.
- `daily_pipeline.sh` DRY_RUN: split candidates=392; probe table probed=18334, awaiting a probe=2070962. An earlier entry recorded probed=17569, awaiting 2071727.

**`apply_splits` dry run on real data, 2026-09-13 17:13**
- 963 active prefix exclusions loaded; 342 candidate ranges still present as db-ip rows; skipped 82 already /24 or narrower, 260 excluded by prefix, 0 over `-max-probes`; registrant: 0 excluded by operator, 0 deferred; to decompose: 0 parents into 0 /24 rows.
- 82 + 260 = 342, the whole candidate set — the registrant gate was never reached. 260 of 342 is a 76% prefix-exclusion kill rate.

**`dbip_split_candidates` state (Boris ran)**
- cand_rows 396, min and max detected_at both 2026-09-13 02:22:00.87599-04 (a single pass).
- sub24_dbip_not_candidate = **371757**.
- Prefix exclusions doing the killing, all DoD: 214.0.0.0/8 killed 91 candidates / 29422 would-be-24s; 55.0.0.0/8 73 / 62132; 6.0.0.0/8 66 / 53866; 215.0.0.0/8 12 / 2748; 11.0.0.0/8 7 / 65024; then one each — 205.0.0.0/11 8192, 205.32.0.0/12 4096, 21.0.0.0/8 65536, 164.236.0.0/14 1024, 158.14.0.0/16 256, 22.0.0.0/8 65536, 28.0.0.0/8 256, 29.0.0.0/8 65536, 132.80.0.0/12 4096, 132.128.0.0/12 4096, 7.0.0.0/8 65536.

**`decomposition_exclusions.sql` first run diagnostics**
- probed_ranges_matched 940, decomposition_candidates 146, sub24_rows_avoided 2566, widest 16, distinct_isp_strings 7.
- Operator cost ranking (ip-api names, first run / second run where it changed): HP Inc. 1 range / 4096 rows (2 / 4224); Amazon.com, Inc. 128 / 2144 (129 / 2148); AT&T Enterprises, LLC 595 / 1980 (601 / 2004); Verizon Business 314 / 1916 (316 / 1920); Comcast Cable Communications, LLC 266 / 1662 (268 / 1668); Microsoft Corporation 43 / 1418 (45 / 1424); Comcast IP Services 1 / 1024; Charter Communications 157 / 842 (159 / 852); Cogent Communications 50 / 686 (53 / 724); AT&T Services 5 / 648; Level 3 Communications 55 / 576 (57 / 584); Utah Education Network 2 / 514; UC San Diego 10 / 452; CenturyLink 70 / 378 (71 / 380); Comcast Cable Communications 151 / 372 (152 / 374); Amazon Technologies Inc. 7 / 332; University of Michigan 3 / 328; Cox 73 / 316; Verizon Communications 58 / 306; DoD 5 / 294 (6 / 298); HPE 4 / 278; Sprint 3 / 264; UnitedHealth 2 / 260; NASA 2 / 258; Cogent-IPENG, MIT, Merit Network, UPMC, Willamette University 1 / 256 each; Google LLC 9 / 206.

**RDAP cache (`rdap_registrant_tbl`)**
- Baseline: candidates 372015, registrant_known 0, registrant_unknown 372015.
- After the geo_exclusions filter was added: **371289** candidate ranges wider than a /24 (371287 on the 2026-09-15 run).
- `-limit 25`: 25 queries returned allocations covering roughly 109.8 million addresses, average 4.4M per query; during a 35-candidate walk 10 were answered free from allocations fetched earlier in the same run — a 28.6% hit rate. Final line: "10 already covered by cache, 25 queried, 0 failed, 0 rate limited".
- `-limit 500`: final line "632 already covered by cache, 500 queried, 0 failed, 0 rate limited; cache now holds 525 allocations". Roughly 8.5 minutes at the 1/sec default.
- Instance explicitly refused to extrapolate a total from 25 queries at the widest end.
- Those first 25 candidates alone would generate **182,272** /24 rows = 2.8 probe-days, from 25 ranges out of 371,289. By registrant category: corp 81,920 /24s (44.9%, 1.3 probe-days); eyeball 45,056 (24.7%, 0.7); cloud 30,720 (16.9%, 0.5); backbone 12,288 (6.7%, 0.2); gov 8,192 (4.5%, 0.1); dod 4,096 (2.2%, 0.1). 68.5% of the cost goes to registrants with no consumer access product.
- Notable allocation widths returned: Ford Motor Company 19.0.0.0-19.255.255.255 (16,777,216); Apple Inc. 17.0.0.0-17.255.255.255 (16,777,216); Cogent 38.0.0.0-38.255.255.255 (16,777,216); Amateur Radio Digital Communications 44.0.0.0-44.191.255.255 (12,582,912); Amazon Technologies 18.32.0.0-18.255.255.255 (14,680,064); Level 3 Parent 8.8.9.0-8.127.255.255 (7,862,016 — starts mid-block because 8.8.8.0/24 is carved out for Google DNS); T-Mobile 100.128.0.0-100.255.255.255 (8,388,608); Charter 76.80.0.0-76.95.255.255 (a /12, from a /20 query).
- Cache contents at the 2026-09-15 run: 486 allocations (after the repair DELETE 39 from 525).

**Registrant cost report, 60 rows, final column `f` (not matched by any active exclusion pattern)**
Allocations / addresses: T-Mobile USA 6 / 13,762,560; Amateur Radio Digital Communications 1 / 12,582,912; AT&T Services 23 / 7,602,176; Prudential 3 / 7,077,888; HP Inc. 3 / 6,946,816; Bank of America 6 / 6,815,744; AT&T Enterprises 6 / 6,553,600; HPE 11 / 5,701,632; JPMorgan Chase 3 / 5,308,416; Eli Lilly 20 / 4,259,840; Amazon Data Services Northern Virginia 4 / 3,932,160; Procter and Gamble 7 / 3,604,480; MNT-ADSI 26 / 3,473,408; CoreWeave 2 / 3,145,728; Xerox 11 / 3,145,728; Merck 21 / 2,686,976; USDA 3 / 2,555,904; Citigroup 2 / 2,293,760; Texas DIR 2 / 2,162,688; MIT 1 / 2,097,152; Chevron 1 / 1,638,400; Internet Utilities NA 9 / 1,245,184; APPLE-MNT 2 / 1,179,648; USPS 5 / 1,179,648; Merit Network 3 / 892,928; NCR Voyix 3 / 851,968; Lockheed Martin 2 / 786,432; Charter Communications LLC 3 / 720,896; Google Fiber Inc. 1 / 720,896; Utah Education Network 1 / 655,360; Veterans Affairs 1 / 655,360; Oracle 8 / 655,360; IRS 1 / 655,360; IBM 1 / 592,128; Michigan State University 4 / 589,824; Georgia Technology Authority 1 / 589,824; NASA 1 / 524,288; Cox 4 / 524,288; Wells Fargo 2 / 524,288; ADP 1 / 524,288; ESnet 2 / 524,288; Board of Regents of the University System of Georgia 1 / 524,288; Avaya 2 / 458,752; Dept of State 1 / 458,752; RTX 2 / 458,752; Boeing 5 / 393,216; Charter Communications Inc 1 / 393,216; Shell IT International 1 / 393,216.

**DoD-registrant scan of the cache (Boris ran)**
- Only one row matched at that point: DoD Network Information Center, 1 allocation, 2,686,976 addresses (148.10.0.0-148.50.255.255, reached from candidate 148.16.0.0/12). It had survived the prefix filter, i.e. it is **not** in `geo_exclusions` — Boris's DoD seeding covered the /8s but not this.
- The 500-query run subsequently returned many more DoD allocations, including 140.56.0.0/13, 140.64.0.0/13, 157.216.0.0/13, 136.188.0.0/14, 138.172.0.0/14, 139.236.0.0/14, 140.8.0.0/14, 140.36.0.0/14, 140.52.0.0/14, 147.244.0.0/14, 128.50.0.0/15 "Department of Defense", 137.210.0.0/15, 138.142/15, 138.148/15, 138.164/15, 138.170/15, 138.176/15, 139.32/15, 139.42/15, 139.248/15, 140.72/15, 148.124/15, 150.218/15, 157.214/15, 199.54.0.0/15, 204.20.0.0/15, 207.84.0.0/15, plus Air Force Systems Networking (143.152/14, 164.208/14, 132.54/15, 140.28/15), DIA (164.184/14, 164.182/15, 164.188/15), Navy Network Information Center (NNIC) (164.192/15, 164.200/15, 205.62.0.0/15 covering 205.56.0.0-205.117.255.255 = 4,063,232), and Headquarters, USAISC (144.102/15, 146.14/15, 158.2/15, 160.148/15, 164.170/15).

**ip-api rate limit (measured from the instance's sandbox IP, not Boris's host)**
- A single live call returns `X-Rl: 44` and `X-Ttl: 60`. Resolves to 208.95.112.1, no CDN, no proxy, no `Server` header.
- 45 calls/min is the documented and practical limit = **64,800 calls/day**. Against the 2,070,962-range backlog that is 32 days. A one-day cycle would need 1,438/min, 32x the limit.
- Roughly 420 calls were made across the burst tests and **not one returned 429**:
| offered/min | ok | stalls | effective/min |
|---|---|---|---|
| ~2000 burst | 57/60 | 3, including 45s of total silence | 74, then stalled |
| 180 | 99/120 | 21 (18%) | 27.9 |
| 90 | 103/120 | 17 (14%) | 28.1 |
| 45 (contaminated, straight after abuse) | 54/60 | 6 (10%) | 26.2 |
| 45 (after 10 min idle) | 58/60 | 2 (3%) | 34.9 |
- Controls over the same window: example.com 40/40, rdap.arin.net 20/20, zero timeouts. So the stalls belong to ip-api, not to sandbox networking.
- `X-Rl` observed moving non-monotonically: 43, 44, 42, 43, 42, 41. `X-Ttl` appeared in at least three distinct phases inside one burst (44, 59/60, 14).
- `probe_batch` uses 2400 of the 2700 calls available per hour, leaving about 300. A 1000-call test needs 22 minutes of exclusive budget and cannot fit.
- The persistence of the throttling penalty (10% vs 3%) is **two samples**, explicitly flagged as an indication rather than a measurement.

**Repair run (Boris ran `rdap_registrant_repair.sql`)**
- Maintainer objects mistaken for registrants: MICROSOFT-MAINT 5 allocations / 14,942,208 addresses; MNT-ADSI 26 / 3,473,408; APPLE-MNT 2 / 1,179,648; ORCL-MNT 3 / 196,608; OPENDNS-MNT 1 / 131,072.
- Administrative placeholders: RIPE-NCC-MANAGED-ADDRESS-BLOCK 2 allocations / 33,554,432 addresses.
- **DELETE 39**. Post-delete verification returned 0 rows.

**Other**
- Candidate count moved from 371,757 to 372,015 between two sessions — 258 sub-/24 db-ip rows added. The instance stated it had not verified the cause and would not assume (probably the daily pipeline).
- `geo_exclusions` DoD prefix expansion was referenced as 8,189 prefixes (carried in from earlier in the session, not re-measured here).
- Repo-wide: 9 tools build at 21e0253, 10 at ca67339/837fc6b/48a5df2, 12 at 90c66c4 onward.
- Commits/PRs in this slice, in order: 21e0253, cd5b1b6, 9e8e7ba, ca67339, 38ab755, 837fc6b, 84d1503 (PR #32), 48a5df2 (PR #33), 90c66c4 (PR #34, 2018 insertions across 13 files), 9ff29ca, 8d59f4d (PR #36), ddd11ff (PR #37), 64c4e15 then 1e828f3 (PR #38).

## Code, files, tables

**`geo/dma_api/cmd/main.go`** — the DMA API service. Endpoints: `GET /api/v1/dmas` (every code and name), `/api/v1/dma/{code}/summary` (counts), `/cidrs` (matched ranges, family-agnostic), `/addresses` (every address, streamed from the cursor), `/cities` (join diagnostic — a city with `ranges: 0` identifies a spelling or case mismatch rather than absent address space), `/healthz`, and `/` (GUI). Changed in this slice: `family(p.network) = 4` removed from the core query; `writeAddresses` now returns an error for a non-IPv4 prefix instead of `(0, nil)`; summary counts families (`ranges`, `ipv4_ranges`, `ipv6_ranges`) instead of assuming IPv4 and no longer hardcodes `2^(32 - masklen)`; `/addresses` returns 409 for IPv6 naming the counts and pointing at `/cidrs`; `?skip_ipv6=1` returns IPv4 only with an `X-Incomplete` response header. Headers include `X-Address-Count`, `X-Range-Count`, `X-Measured`.

**`geo/dma_api/cmd/index.html`** — the DMA GUI, 10,751 bytes, compiled into the binary with `go:embed` and served at `/`. No separate deployment step. It states explicitly when `dma_code` is unpopulated rather than showing an empty result, and warns when `measured_ranges` is below half.

**`geo/dma_api/query.sql`** — seven sections (later referenced as having a section 7). Section 1 sets `geo.dma_code`, now defaulting only when absent and printing which value it used. Section 3 expands ranges to addresses with `generate_series` over the integer offset, guarded against IPv6 (the one justified family filter). Section 4 counts the same way. Section 5 creates the three join indexes. Section 7 (new) lists any IPv6 ranges the expansion skipped. Four redundant family filters were removed.

**`geo/dma_api/trugeo-dma-api.service`** — systemd unit. Fixed so `EnvironmentFile=` can parse the config.

**`geo/pipeline/geo_common.sh`** — fixed at line 47: the plain `. "$GEO_CONFIG"` with no `set -a` is why `/etc/trugeo.env` needed `export` prefixes, which systemd cannot parse.

**`geo/pipeline/daily_pipeline.sh`** — gained a `take_lock_blocking "$PROBE_LOCK"` around the registrant-lookup step only (not the whole pipeline, to avoid queueing behind a 53-minute probe batch), gated on `DECOMPOSE_LOOKUP_REGISTRANT`, default 0. An invalid value exits 2.

**`geo/pipeline/rebuild_probe_tbl.sql`** — now refuses to run if any ASN exclusion expands wider than /8.

**`geo/pipeline/deploy.sh`** — gained `probe_range_split`, then `rdap_registrant` and `ipapi_rate_test`. Installs binaries under `/var/trugeo/<tool>/bin/<tool>`, pipeline scripts, dma_api support files, and `/etc/cron.d/trugeo`; verifies `revision=` and `modified=false` per tool. Has a dirty-tree guard that fired correctly during this slice.

**`geo/bgp_route_views/cmd/main.go`** — `prefixRange` now rejects zero-length prefixes. Both ingest paths funnel through it, so it is the single enforcement point.

**`geo/probe_range_split/cmd/main.go`** (new tool, the 10th) — enumerates or samples sub-blocks of a range and reports what ip-api says about each. Flags seen: `-range CIDR`, `-block N` (default /24), `-samples N`, `-asn N` (samples one /24 from each of an ASN's prefixes), `-cohort LABEL`, `-rate N`. Verdicts: UNITARY, SPLIT BY ZIP ONLY, SPLIT BY CITY, RESOLVABLE, HIGHLY CONCENTRATED, NON GEOGRAPHIC. Prints a sampling caveat whenever it has not enumerated every block. Writes nothing to the database except in `-cohort` mode. Carries a caveat in its own output that it measures what ip-api asserts, not where subscribers are.

**`geo/rdap_registrant/cmd/main.go`** (new tool, 597 lines at creation) — queries RDAP for the registrant of an allocation and caches it. Flags: `-fill`, `-dry-run`, `-limit N`. Default rate 1/sec. Logs `registrant=`, `handle=`, `allocation=`, `covers=N addresses` per query. `loadCandidates` filters `geo_exclusions` in SQL (served by the existing gist index). Entity selection fixed to skip maintainer objects by the rule that a maintainer's formatted name equals its handle. Placeholder registries (`RIPE-NCC-MANAGED-ADDRESS-BLOCK`) stored with a NULL registrant and a `placeholder:` note.

**`geo/rdap_registrant_tbl.sql`** (new, 8,582 bytes) — the allocation-keyed cache. Columns referenced: `id` (bigserial), `registrant`, `registrant_role`, `handle`, `network_name`, `start_ip`, `end_ip`, `addresses_in_allocation`, `fetched_at`, plus a note column. Stores `start_ip`/`end_ip` rather than a `cidr` column — a decision that was speculative when made and became load-bearing when ARIN returned 8.8.9.0-8.127.255.255, which is not a CIDR. Two indexes. Ends with diagnostic SELECTs; section 2 reports candidates / registrant_known / registrant_unknown, section 3 ranks cost by registrant. Now grants the table and its sequence to cronuser inside a `DO` block that checks `pg_roles` first.

**`geo/probe_stability_tbl.sql`** (new, 8,509 bytes) — drift tracking. One row per (cohort, address, round): `network`, `probe_ip`, `round`, `observed_at`, `status`, `country_code`, `city`, `state_code`, `zip`, `isp`, `org`, `mobile_ipapi`, `err`. Addresses are fixed for the life of the cohort by design. Reports: addresses tracked, rounds per address, % whose city moved, % whose ZIP moved, fastest interval over which any change was observed, and an isp-level report of `ipapi_ever_says_mobile` / `ipapi_always_says_mobile` / `keyword_says_mobile`. Also grants to cronuser.

**`geo/rdap_registrant_repair.sql`** (new) — three sections: report the faults (maintainer objects, administrative placeholders), delete the poisoned cache rows, verify. Safe because the table is a pure cache and nothing else writes to it.

**`geo/decomposition_exclusions.sql`** — creates and seeds the `decomposition_exclusions` table. Columns: `id`, `operator_pattern`, `active`, `reason`, `added_at`. Initially seeded with four Amazon ILIKE patterns; rewritten in this slice to be DoD-only and self-enforcing, deactivating anything not on the DoD list on every run. Final active patterns: `%air force systems networking%`, `%department of defense%`, `DIA` (exact), `%dod network information center%`, `%navy network information center%`, `%usaisc%`. Deactivated: `%amazon%`, `%aws%`, `%amazon technologies%`, `%amazon data services%`. Sections: 1 seed + enforce, 3 every registrant in the cache with whether a pattern matches (reordered so matched rows come first, because the old ordering with LIMIT 60 hid every DoD match), 4 DoD space that `geo_exclusions` does not cover, 5 active `geo_exclusions` prefixes whose registrant is not DoD, 6 decomposition cost per registrant in probe days (fixed from `round(2 ^ int, 2)` to avoid the missing `round(double precision, integer)`).

**`geo/apply_splits/cmd/main.go`** — gained an operator check (ILIKE against active `decomposition_exclusions` patterns on the registrant, never on ASN) and a defer-when-no-registrant rule, both default on and independently disableable (`-operator-check=false`, `-defer-unprobed`). Gained `-registrant-source rdap|ipapi`, default `rdap`. A missing `decomposition_exclusions` table is fatal, naming both the file to run and the bypass flag. `loadParents` reworked for the RDAP path. Treats a `placeholder:` cache row as a known registrant. New log lines: `registrant: N excluded by operator, M deferred with no probe and therefore no known registrant`, followed by operators ranked by /24 rows avoided.

**`geo/check_geo_ip-api/cmd/main.go`** — now logs its `X-Rl` low-water mark; now sets `likely_mobile_cgnat` from the union of ip-api's `mobile` field and the keyword classifier, logging disagreements rather than resolving them silently; now treats a timeout or severed connection as a throttle signal and backs off 61s (new log line `ip-api stalled (...); this is how it throttles`). Required adding the `net` import and an `isTimeout` helper, both confirmed present in the merged commit 64c4e15. Still contains deliberately unimplemented paid-batch scaffolding: `readIPBatch` and `parseBatchResponse`.

**`geo/ipapi_rate_test/cmd/main.go`** (new tool, 374 lines) — measures the rate limit from response headers rather than by provoking it. `-headers-only` prints one call's headers. Built for a 1000-address run, defaults to stopping at the first 429, and draws only from already-probed ranges so it never touches the backlog.

**Tables referenced but not created here**: `ip2city_dbiplite_probe_tbl` (columns used: `network`, `city`, `state_code`, `countrycode`, `lat`, `lon`, `zip`, `isp`, `org`, `as`, `ran_at`, `likely_mobile_cgnat`, `rdap_lookup`), `ip2city_dbiplite_tbl` (`network`, `source`), `dma2city_tbl` (PK `state_code, county, dma, city, city_type`; nullable `dma_code`), `bgp_route_views` (`cidr_block`, `origin_asn`, `updated_at`), `geo_exclusions` (`prefix`, `origin_asn`, `active`), `dbip_split_candidates` (`network`, `detected_at`), `city2zip_tbl`, `dma2zip_tbl` (exist in the database, referenced nowhere in the repo).

**Indexes created in this slice** (must be run as `boris`, not `cronuser`):
- `ip2city_dbiplite_probe_tbl_city_state_idx` on `(city, state_code)`
- `dma2city_tbl_dma_code_idx` on `(dma_code) WHERE dma_code IS NOT NULL`
- `dma2city_tbl_city_state_idx` on `(city, state_code)`
All three confirmed present by `pg_indexes` query. Without them every API request sequentially scans 2,089,296 probe rows. `TRUNCATE` preserves indexes, so this is a one-time step surviving cycle rollover.

## Commands worth keeping

Deploy and verify:
```
cd /home/boris/geo/src/claude && git pull origin main && git log --oneline -1
./geo/pipeline/deploy.sh
sha256sum /var/trugeo/pipeline/daily_pipeline.sh /var/trugeo/pipeline/probe_batch.sh /var/trugeo/pipeline/geo_common.sh /var/trugeo/pipeline/rebuild_probe_tbl.sql /etc/cron.d/trugeo
```
Expected sha256 at 84d1503:
```
3b81639c094942dd596d40fb916dcd6c5194920d3d6cd0c8c4cfa804e5d8f032  daily_pipeline.sh
e4361626be27a2cb6ab0ba6478be30d94914ca32b00a88ae71a42d142ac1026d  probe_batch.sh
ee1c372349555961cf0b8f616eb3a68c513744c6fdd98bbdb0b0d9e8d30e4971  geo_common.sh
2774b2b1b590d4d30ac323ef00958aaa76946fa5a5141613225b9abae323ea92  rebuild_probe_tbl.sql
9f40a9841e64b478815266c1bf0381ba96ac1f2453421af821093d5eafa71791  trugeo.cron
```

Is `dma_code` populated (the blocking check for the DMA API)? Answer was 31899:
```
sudo -u cronuser psql -d postgres -c "select count(*) as rows, count(dma_code) as with_code, count(distinct dma_code) as distinct_codes from dma2city_tbl"
```

The three join indexes — **as boris, one `-c` each** so a failure on one does not abort the others:
```
psql -d postgres -c "CREATE INDEX IF NOT EXISTS ip2city_dbiplite_probe_tbl_city_state_idx ON ip2city_dbiplite_probe_tbl (city, state_code)"
psql -d postgres -c "CREATE INDEX IF NOT EXISTS dma2city_tbl_dma_code_idx ON dma2city_tbl (dma_code) WHERE dma_code IS NOT NULL"
psql -d postgres -c "CREATE INDEX IF NOT EXISTS dma2city_tbl_city_state_idx ON dma2city_tbl (city, state_code)"
psql -d postgres -c "select tablename, indexname from pg_indexes where indexname in ('ip2city_dbiplite_probe_tbl_city_state_idx','dma2city_tbl_dma_code_idx','dma2city_tbl_city_state_idx') order by 1,2"
```

Run the DMA API in the foreground and exercise it:
```
sudo -u cronuser env PGDATABASE=postgres /var/trugeo/dma_api/bin/dma_api -listen 127.0.0.1:8080
curl -s http://127.0.0.1:8080/healthz
curl -s http://127.0.0.1:8080/api/v1/dmas | head -20
curl -s http://127.0.0.1:8080/api/v1/dma/527/summary
curl -s http://127.0.0.1:8080/api/v1/dma/527/cities | head -30
curl -s http://127.0.0.1:8080/api/v1/dma/527/cidrs | head -5
curl -s "http://127.0.0.1:8080/api/v1/dma/527/addresses?gzip=1" -o /tmp/dma527.txt.gz -D /tmp/h.txt
grep -iE "x-range-count|x-address-count|x-measured|x-ipv" /tmp/h.txt
gunzip -c /tmp/dma527.txt.gz | wc -l
```
The line count must equal `X-Address-Count`. Then browse `http://127.0.0.1:8080/`.

Install as a service:
```
sudo install -o root -g root -m 0644 /var/trugeo/dma_api/trugeo-dma-api.service /etc/systemd/system/trugeo-dma-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now trugeo-dma-api
sudo systemctl status trugeo-dma-api --no-pager
sudo journalctl -u trugeo-dma-api -n 20 --no-pager
```

Find the default-route trap and remove it:
```
sudo -u cronuser psql -d postgres -c "select cidr_block, masklen(cidr_block) as len, origin_asn, updated_at from bgp_route_views where origin_asn = 174 order by masklen(cidr_block) limit 10"
sudo -u cronuser psql -d postgres -c "delete from bgp_route_views where masklen(cidr_block) = 0 returning cidr_block, origin_asn"
sudo -u cronuser psql -d postgres -c "select count(*) as remaining_default_routes from bgp_route_views where masklen(cidr_block) = 0"
```

Audit how wide each excluded ASN's announcements go (review anything smaller than about /12):
```
sudo -u cronuser psql -d postgres -c "select x.origin_asn, min(masklen(b.cidr_block)) as widest, count(*) as prefixes from geo_exclusions x join bgp_route_views b on b.origin_asn = x.origin_asn where x.active and x.origin_asn is not null group by 1 order by 2 limit 10"
```

Size the sub-/24 decomposition:
```
sudo -u cronuser psql -d postgres -c "select masklen(network) as len, count(*) as ranges, sum(2^(24-masklen(network)))::bigint as would_become_24s from ip2city_dbiplite_probe_tbl where masklen(network) < 24 group by 1 order by 1"
```

Find ranges wider than /24 that both sources treat as unitary (note: this population is dominated by cloud/backbone/misattributed space — see Traps):
```
sudo -u cronuser psql -d postgres -c "select p.network, masklen(p.network) as len, p.city, p.state_code, p.ran_at is not null as probed, (select count(*) from bgp_route_views b where b.cidr_block << p.network) as bgp_children from ip2city_dbiplite_probe_tbl p where masklen(p.network) between 16 and 22 and not exists (select 1 from bgp_route_views b where b.cidr_block << p.network) order by masklen(p.network), 1 limit 25"
```

Pick eyeball candidates by origin ASN rather than by width:
```
sudo -u cronuser psql -d postgres -c "select p.network, masklen(p.network) as len, p.city, p.state_code, (select string_agg(distinct b.origin_asn::text, ',') from bgp_route_views b where p.network <<= b.cidr_block) as origin_asns from ip2city_dbiplite_probe_tbl p where masklen(p.network) between 18 and 22 order by random() limit 30"
```

Range-split and carrier tests. **Space invocations at least 60 seconds apart** — the tool anchors its rate window on the first call of each run:
```
/var/trugeo/probe_range_split/bin/probe_range_split -range 76.90.64.0/20 -samples 16
/var/trugeo/probe_range_split/bin/probe_range_split -range 172.56.54.0/24 -block 28 -samples 16
/var/trugeo/probe_range_split/bin/probe_range_split -asn 21928 -samples 40
/var/trugeo/probe_range_split/bin/probe_range_split -asn 6167 -samples 40
/var/trugeo/probe_range_split/bin/probe_range_split -asn 22394 -samples 40
/var/trugeo/probe_range_split/bin/probe_range_split -asn 20057 -samples 40
/var/trugeo/probe_range_split/bin/probe_range_split -asn 7922 -samples 40
```
ASN map used: 21928 T-Mobile US, 6167 and 22394 Cellco/Verizon Wireless, 20057 AT&T Mobility, 7922 Comcast (fixed-line control), 20115 Charter.

Drift cohorts (`-rate 20` keeps three runs inside the ~300/hour headroom):
```
cd /var/trugeo/probe_range_split/bin
sudo -u cronuser env PGDATABASE=postgres ./probe_range_split -asn 21928 -samples 40 -cohort tmobile-as21928 -rate 20
sleep 120
sudo -u cronuser env PGDATABASE=postgres ./probe_range_split -asn 7922 -samples 40 -cohort comcast-as7922 -rate 20
sleep 120
sudo -u cronuser env PGDATABASE=postgres ./probe_range_split -asn 20115 -samples 40 -cohort charter-as20115 -rate 20
```
Re-run the identical three commands after the interval of interest; each resumes its cohort and prints churn. Round 1 alone prints "Only one round exists, so churn is not yet measurable."

Create the new tables **as boris** (cronuser is not the owner); both files are idempotent and end with diagnostic SELECTs:
```
psql -d postgres -f geo/rdap_registrant_tbl.sql
psql -d postgres -f geo/probe_stability_tbl.sql
psql -d postgres -f geo/decomposition_exclusions.sql
psql -d postgres -f geo/rdap_registrant_repair.sql
```

Warm the RDAP cache, smallest step first so the `covers=` ratio is visible before a long run:
```
sudo -u cronuser env PGDATABASE=postgres /var/trugeo/rdap_registrant/bin/rdap_registrant -fill -dry-run
sudo -u cronuser env PGDATABASE=postgres /var/trugeo/rdap_registrant/bin/rdap_registrant -fill -limit 25
sudo -u cronuser env PGDATABASE=postgres /var/trugeo/rdap_registrant/bin/rdap_registrant -fill -limit 500
```

Exercise the decomposition gates (writes nothing):
```
sudo -u cronuser env PGDATABASE=postgres /var/trugeo/apply_splits/bin/apply_splits -dry-run -ensure-source-column=false
```

Diagnose why a dry run found nothing:
```
psql -d postgres -c "select count(*) as cand_rows, min(detected_at), max(detected_at) from dbip_split_candidates"
psql -d postgres -c "select count(*) as sub24_dbip_not_candidate from ip2city_dbiplite_tbl d where d.source='dbip' and family(d.network)=4 and masklen(d.network)<24 and not exists (select 1 from dbip_split_candidates c where c.network=d.network)"
psql -d postgres -c "select e.prefix::text as exclusion, count(*) as candidates_killed, sum(2^(24-masklen(c.network)))::bigint as would_be_24s from dbip_split_candidates c join ip2city_dbiplite_tbl d on d.network=c.network and d.source='dbip' join geo_exclusions e on e.active and c.network <<= e.prefix where family(c.network)=4 and masklen(c.network)<24 group by 1 order by 2 desc limit 20"
```

Find DoD allocations in the RDAP cache:
```
sudo -u cronuser env PGDATABASE=postgres psql -d postgres -c "select r.registrant, count(*) as allocations, sum((r.end_ip - r.start_ip)+1) as addresses from rdap_registrant_tbl r where r.registrant ilike '%dod%' or r.registrant ilike '%defense%' or r.registrant ilike '%defence%' or r.registrant ilike '%army%' or r.registrant ilike '%navy%' or r.registrant ilike '%air force%' group by 1 order by 3 desc"
```

Rank decomposition cost in probe-days against the current RDAP cache (the lateral picks the *narrowest* covering allocation):
```
sudo -u cronuser env PGDATABASE=postgres psql -d postgres -c "select cov.registrant, count(*) as wide_ranges, sum(2 ^ (24 - masklen(d.network)))::bigint as sub24_rows, round(sum(2 ^ (24 - masklen(d.network)))/64800.0, 2) as probe_days, min(masklen(d.network)) as widest from ip2city_dbiplite_tbl d join lateral (select r.registrant from rdap_registrant_tbl r where r.start_ip <= host(network(d.network))::inet and r.end_ip >= host(broadcast(d.network))::inet order by (r.end_ip - r.start_ip) limit 1) cov on true where d.source = 'dbip' and family(d.network) = 4 and masklen(d.network) < 24 group by 1 order by sub24_rows desc limit 30"
```
Note: as written this calls `round(double precision, integer)` and will fail unless the `pow(...)::bigint` form is used — see Traps.

Read ip-api's rate-limit headers:
```
/var/trugeo/ipapi_rate_test/bin/ipapi_rate_test -headers-only
```

Dry-run the pipeline and read the log:
```
sudo -u cronuser env DRY_RUN=1 /var/trugeo/pipeline/daily_pipeline.sh
sudo tail -20 /var/log/trugeo/daily_pipeline.log
```

Merging a PR: `gh` is not usable on Boris's host (see Traps). The instance merged from its own side with:
```
gh api -X PUT repos/borislevitanimmetrica/claude/pulls/34/merge -f merge_method=merge
```
Pulling a branch directly also works and needs no merge decision:
```
git fetch origin geo-rdap-registrant-and-stability
git checkout geo-rdap-registrant-and-stability
```

## Traps and gotchas

1. **Redundant family filters are landmines, not harmless.** `AND family(p.network) = 4` where no IPv6 exists today is a filter that will be forgotten and will silently drop rows when IPv6 arrives. Boris's rule, and the instance found two more instances of its own making. Fix: count families rather than filter them, and keep only filters that are semantically necessary — then make their effect visible with a query that returns nothing today and starts returning rows exactly when the scope changes.

2. **`writeAddresses` returned `(0, nil)` for a non-IPv4 prefix** — silent omission in Go, the same failure mode as the SQL filter. Now returns an error.

3. **`2^(32 - masklen)` was hardcoded in the summary for every row** — not merely exclusionary for IPv6 but arithmetically wrong.

4. **`DISTINCT` in the DMA query is load-bearing.** `dma2city_tbl` has PK `(state_code, county, dma, city, city_type)`, so a city spanning counties appears on several rows and every matched range would return once per row. Proved with a fixture that deliberately duplicated Indianapolis: 0 duplicates with DISTINCT, doubled output without.

5. **`EnvironmentFile=` cannot parse `export`.** `geo_common.sh` sources `/etc/trugeo.env` with a plain `.` and no `set -a`, so the file needs `export` prefixes to reach child processes — which is exactly what systemd cannot read. systemd would have taken the variable name as `export PGDATABASE`, warned, skipped the line, and left the service connecting to a database named `cronuser`. The journal line `database reachable as cronuser@postgres` vs `cronuser@cronuser` is the diagnostic.

6. **A plain `SET` in `query.sql` section 1 silently overrode a value passed on the command line.** The instance ran `psql -c "SET geo.dma_code='510'"` and got 527's results. Fixed to default only when absent and to print which value it used. Caught by its own test.

7. **`0.0.0.0/0` in `bgp_route_views`, origin_asn 174, was one row away from silent catastrophe.** `rebuild_probe_tbl.sql` materialises every ASN-excluded operator's prefixes and removes any range contained in them. Had an ASN announcing a default route ever been added to `geo_exclusions`, that single row would have excluded the entire address space — emptying the probe table with no error and nothing pointing at the cause. Two-sided fix: `prefixRange` rejects zero-length prefixes at ingest, and the rebuild refuses to run if any ASN exclusion expands wider than /8.

8. **ASN-based exclusion oversweeps and does not self-heal.** Boris's reasoning: ownership changes, additions and drops are not reflected by an ASN rule, whereas the registrant name follows the range. The predicted cost of name matching also materialised: `167.20.43.0/24` inside AS21928 returns isp "Sprint Communications", which a `T-Mobile%` pattern would miss. That is a missed pattern you can add; ASN matching fails by oversweeping invisibly.

9. **Probing is NOT excluded during decomposition.** `daily_pipeline.sh` takes its own lock and the mutation lock (fd7) but never the probe lock (fd8); `monthly_dbip.sh` does take the probe lock, blocking. `daily_pipeline` runs 02:00-02:17 while the 02:05 probe batch starts inside that window, so a registrant lookup during decomposition would contend with `probe_batch` for the same 45/min budget.

10. **Running two ip-api tools back to back produces a 429 storm.** `probe_range_split` anchors its rate window on the first call of each run, so four invocations in sequence blew the shared 45/min ceiling. AS22394 (18/40) and AS20057 (11/40) results were spoiled this way and should not be relied on. Space runs at least 60 seconds apart.

11. **A partial sample can only prove SPLIT, never UNITARY.** The 8-sample run on 76.90.64.0/20 returned one ZIP and the instance built an argument on it ("ip-api answers at block granularity rather than per address") that full enumeration refuted. 4 samples found 2 ZIPs, 8 found 1 and reported UNITARY, 16 found 3. The tool now prints a sampling caveat whenever it has not enumerated every block.

12. **The widest unprobed ranges are the wrong population to test.** `2.0.0.0/16` -> Austin and `2.1.0.0/16` -> Washington DC are RIPE space asserted as US cities and passed the `country_iso_code = 'US'` filter; `3.x.0.0/16` -> Ashburn/Boardman/Dublin are AWS regions; `4.x.0.0/16` -> Monroe LA is Level 3/Lumen's headquarters geolocating an entire /8 to a corporate HQ. Eyeball candidates must be chosen by origin ASN, not by width.

13. **A mobile /24's geolocation is not stable.** 172.56.54.0/24 returned three Los Angeles-area cities across /28 boundaries on 2026-09-09 and Dallas TX on all sixteen /28s on 2026-09-13, twice. Either the carrier reassigned the /24 or ip-api revised its data; operationally the same problem. `ran_at` records when a range was measured but **there is no re-measurement and no drift detection in the pipeline at all**, so a published DMA or ZIP can silently become wrong. This threatens the DMA tier, not just ZIP. Partial fix: `-repeat` mode with fixed cohort addresses, built but not yet run beyond round 1.

14. **ip-api's ZIP column is bimodal.** Some ranges resolve genuinely per-block (Charter's Hemet 92543/92544/92545). Others return a city-centroid placeholder: 10123 is the Empire State Building, 60666 is O'Hare's mail facility, 07175 is a Newark PO Box, 98111 and 55467 and 99260 and 30333 and 33102 and 46255 and 75270 and 90099 are PO Box or unique ZIPs. A ZIP list built naively from this would target the Empire State Building for a large slice of Comcast's New York footprint. Boris's mitigating point: PRIZM and Census products contain no PO Box or airport ZIPs, so such a ZIP can never match a buy and is inert rather than harmful — but the affected ranges silently drop out of ZIP-tier reach.

15. **Newly-allocated space carries stale attribution.** Four Comcast-announced 48.4x blocks returned isp "AviationAI" with ZIP 10013. `48.0.0.0/8` is recently allocated.

16. **`CREATE INDEX` requires table ownership; `cronuser` has only DML plus TRUNCATE.** `ERROR: must be owner of table ip2city_dbiplite_probe_tbl`. Worse, `-v ON_ERROR_STOP=1` with three chained `-c` statements aborted on the first, so **none** of the three indexes were created and the failure looked partial. Run as `boris`, one `-c` per invocation.

17. **A `bigserial` needs USAGE on its sequence, not just a table grant.** `ERROR: permission denied for sequence rdap_registrant_tbl_id_seq (SQLSTATE 42501)` fired per row rather than at connect time, so it looked like a tool bug. Both SQL files now grant the table and its sequence inside a `DO` block that checks `pg_roles` first and emits a NOTICE.

18. **Sorting RDAP candidates widest-first spends the budget on space that cannot matter.** The first 43 queries went to 7.0.0.0/8, 21.0.0.0/8, 22.0.0.0/8, 29.0.0.0/8, 30.0.0.0/8, 214.128.0.0/9 and similar — DoD space, which `apply_splits` discards before it ever consults the registrant. Every one bought an unusable answer. `loadCandidates` now filters `geo_exclusions` in SQL.

19. **The `apply_splits` registrant line can read as 0/0 because the gate was never reached, not because it found nothing.** 82 already-/24-or-narrower + 260 prefix-excluded = 342, the entire candidate set, and both tests run before the registrant tests in the loop. "Do not read that line as validation."

20. **`dbip_split_candidates` reaches ~0.1% of the decomposition opportunity.** `check_range_splits` only flags ranges that have more specific BGP children, and only 396 currently qualify, nearly all of them already-excluded DoD space. The 371,757 sub-/24 db-ip ranges with no BGP children are invisible to it, yet a /16 attributed to one city is exactly the error decomposition exists to fix. The view over `ip2city_dbiplite_tbl` that the instance earlier called optional is the only route to the real opportunity.

21. **RDAP maintainer objects were stored as registrants.** For 51.180.0.0-51.181.255.255 three entities carry the registrant role: MNT-ADSI (a maintainer), ORG-ARI3-RIPE "A100 ROW Inc" (the actual holder), and RIPE-NCC-HM-MNT (RIPE's hostmaster maintainer). The tool took the first in document order. 37 allocations were poisoned this way — MNT-ADSI ×26, MICROSOFT-MAINT ×5, ORCL-MNT ×3, APPLE-MNT ×2, OPENDNS-MNT ×1. The discriminator that generalises: **a maintainer's formatted name equals its handle; a real organisation has a human name distinct from it.** After the fix MNT-ADSI resolves to A100 ROW Inc, APPLE-MNT to Apple Inc., MICROSOFT-MAINT to Microsoft Limited, OPENDNS-MNT to Cisco OpenDNS LLC.

22. **Storing an administrative placeholder is worse than storing nothing.** ARIN answers HTTP 303 for early-registration space and redirects to the responsible registry; RIPE then returns the entire `151.0.0.0/8` as `RIPE-NCC-MANAGED-ADDRESS-BLOCK` with no entities at all. Stored as a 16.7M-address allocation with administrative filler as the registrant, it made the coverage test treat every candidate inside the block as answered and never query it again. Two such rows (151.0.0.0/8 and 46.0.0.0/8) would have permanently suppressed **33,554,432 addresses**. Fix: store a NULL registrant with a `placeholder:` note, and have `apply_splits` treat that as *known* — the registry was asked and holds no assignment, which is positive evidence no DoD registration exists. Treating it as unknown would defer that space forever, since no later query can improve the answer.

23. **`2 ^ int` returns `double precision` in PostgreSQL, and `round(double precision, integer)` does not exist.** Section 6 of `decomposition_exclusions.sql` aborted silently with that error, which is why the probe-days table never appeared in Boris's output. Other files in the repo were safe because they use `pow(2,...)::bigint` inside the `sum`.

24. **`ORDER BY ... LIMIT 60` on the registrant report hid every DoD match.** Reordered so matched rows come first.

25. **ip-api throttles by stalling, never by returning 429 — and the 429 handler was therefore dead code.** Across ~420 calls at up to ~2000/min offered, not one 429 was returned. A stall arrives as a transport error, so a throttled `check_geo_ip-api` run recorded every affected range as `status='error'` and kept calling at full rate, deepening the throttling. No data was lost (those ranges stay `city IS NULL` and get retried) but throughput was degrading silently with no diagnostic. Fixed to treat a timeout or severed connection as a throttle signal and back off 61s.

26. **Offering more delivers less.** 180/min and 90/min both yielded about 28 effective calls/min; politely paced 45/min after an idle period yielded 34.9. Pushing 4x the documented rate bought nothing.

27. **`X-Rl` cannot be read as remaining quota.** It moves non-monotonically (43, 44, 42, 43, 42, 41) and `X-Ttl` appeared in at least three distinct phases inside one burst (44, 59/60, 14) — several independent backends behind one address, each with its own counter. The instance explicitly withdrew its earlier reading of `X-Rl: 44` as a single per-IP budget draining.

28. **The throttling penalty appears to persist after abuse.** 45/min immediately after a 180/min burst stalled 10% of the time; after ten minutes idle, 3%. Two samples only, so an indication — but reason enough never to probe the ceiling from the IP the pipeline runs on.

29. **`gh` is not installed and not authenticated on Boris's machine.** `gh api -X PUT .../pulls/34/merge` failed with "Command 'gh' not found"; after `sudo apt install gh` (2.45.0-1ubuntu0.3) it failed again with "please run: gh auth login". Standing arrangement from the instance: tell it when a PR should be merged and it will do it from its side rather than issuing a `gh` command Boris cannot run. Plain `git` commands are fine.

30. **Instructing a pull before the PR is merged leaves the files missing.** Boris pulled `main` at 837fc6b and then at 48a5df2 and got `No such file or directory` for `geo/rdap_registrant_tbl.sql` and `geo/probe_stability_tbl.sql`, because they were on branch `geo-rdap-registrant-and-stability` with PR #34 still open. Also worth noting: `deploy.sh` reported 10 tools on a tree whose source had 12, which is how the missing merge showed up.

31. **A tool added to the repo is not a binary on disk.** `/var/trugeo/probe_range_split/bin/probe_range_split: No such file or directory` simply meant `deploy.sh` had not been run since the tool was added.

32. **`bind: address already in use`** on port 8080 — an earlier foreground `dma_api` was still running. The second instance exited 1 while the curls succeeded against the first.

33. **`-count 1` cannot test a hypothesis about a specific range.** `check_geo_ip-api -count 1` picks one random unprobed range from the whole table. The instance wrote that the command "won't target a specific range" and then handed it to Boris anyway.

34. **Invalid fixture CIDRs.** `203.0.113.0/22` and `192.0.2.0/22` have bits set to the right of the mask and were rejected.

35. **`As4Slice` does not exist** — `netip.Addr.As4()` returns an array, not a slice.

36. **The repo has a no-backslash convention in format strings** that "has caused real damage when violated"; the instance ran an invariant check (`backslash=8` occurrences) rather than leave an exception.

37. **`expand_cidrs -skip-network-broadcast` is used nowhere.** `.0` and `.255` are included throughout, per Boris's instruction.

38. **IPv6 random target generation is biased to the low end.** `least(..., 4294967296)` caps the offset at 2^32, so for a /48 the probe only ever samples the first 4 billion of 2^80 addresses — effectively always `::0:0:0:x`, where routers and infrastructure live rather than subscribers. Same class of problem as the `.0` bias already fixed for IPv4.

39. **A git stash entry surfaced during the reconnect** containing a tracked-binary blob (`bgp_route_views/bin/bgp_route_views`) from an old `geo-rdap-excluded-internal-fallback` branch, pointing at a commit about `dma_ip_table.sql` that is not on `main`. The instance did not touch it and flagged it as possible earlier in-flight work needing separate reconciliation.

## Boris's instructions, preferences and standing orders

- **Never leave a redundant qualifier that will be forgotten.** On `family(p.network) = 4`: "It is not necessary: there is no IPv6 in the table. When we switch on IPv6, this qualifier would be forgotten and left for us to discover the hard way. Bad advice."
- **`.0` and `.255` are always included** in expanded address lists (carried-in standing order, reaffirmed by the instance noting it never uses `-skip-network-broadcast`).
- **Do not assert unquantified figures.** He challenged "a few thousand prefixes" directly; the instance withdrew it as fabricated and as "the kind of unquantified figure I'm supposed to flag rather than assert."
- **Priorities: big screens primarily, mobile devices nice to have.** This explicitly deprioritised IPv6 relative to ZIP work.
- **ZIP-code targeting is the main goal.** "The main goal is to target advertising by ZIP code, and there are more than 55,000 ZIP codes assigned in the US."
- **ZIP resolution goes ZIP -> city -> IP range through the existing architecture** (`city2zip_tbl`), not through `probe_tbl.zip`. He called the instance's `probe_tbl.zip` coverage query "irrelevant."
- **The ZIP-code service must accept multiple codes**: a file with one code per line, a JSON array, or a GUI with codes and "our versions" of the market names, returning a list of IP addresses.
- **The DMA service accepts one DMA at a time, defaulting to `multiple_markets=off` with a toggle.** "Otherwise local advertisers would enter multiple markets in error and receive IP-address lists largely out-of-market." Multi-DMA is for national advertisers doing impressions backfill, "a practice that has dwindled over the past decades."
- **Front-end architecture should be the same for DMA and ZIP services.**
- **He intends to build the landmark table before the user interface.** Landmarks = schools, universities, municipal governments with domain-name-carrying on-premises systems and known ZIP codes, as "the definitive source of truth for BGP range -> ZIP code resolution, even ahead of the travel-time-based ip-api." He notes authoritative databases exist for some landmark types.
- **ASN ownership is not a usable discriminator for landmarks.** "Universities may have their own ASNs but schools and most municipal governments don't." This killed the instance's `inference_scope` proposal.
- **Test the split-range hypothesis by probing.** "there may be ranges wider than /24 that appear unitary in both data sources and are actually split; we should test this hypothesis by probing /24s in a few such wider ranges."
- **ZIP boundary crossing within a range is an accepted inaccuracy.** "any address in the 16 can land in a different one of the 3 ZIP codes, and in some cases, a /24 probably can as well (example from other countries: Baarle Nassau and Baarle Hertog). It is just an inaccuracy that is part of ZIP-code targeting. Landmarks will not reduce these minor deviations into adjacent ZIP codes."
- **No spend-waste argument against including datacentre space.** "If those devices are not used to stream video, their IPv4 addresses will simply not come up for bid."
- **Reluctant to exclude commercial ranges at all, because reallocation is imaginable.** DoD reallocation is "almost unimaginable"; Amazon's is "more imaginable, if unlikely"; smaller datacentre operators' more so; "Google has a fiber operation to which it could conceivably reallocate some of its enormous numberspace holdings."
- **Never put Google, or any company that directly or indirectly serves customers with part of its range holdings, on the exclusion list.**
- **Only DoD ranges are excluded.** Final and explicit: "We cannot distinguish purely-infrastructure ranges from ranges serving end users from RDAP data. Therefore only DoD ranges should be excluded. Confirm that this is so. Remove Amazon from the exclusion list." He named universities possibly using ranges for student housing, and people at work at the listed organisations as appropriate advertising targets.
- **Telecom carriers in an exclusion-adjacent report are particularly alarming** "as these ranges could be customer-connecting or could be reallocated to that role."
- **Match decomposition exclusions by operator name with LIKE, never by ASN.** "We must not oversweep the exclusion. Doing so by operator name ... ensures that additions, drops and ownership changes from numberspace holdings are processed correctly. Doing it by ASNs doesn't."
- **Confirm, don't assume, that probing is not running during decomposition.** He asked for confirmation explicitly, and the answer was negative.
- **Run a counter against the ip-api rate limit.** (He wrote 45/h; the instance flagged that the project limit is 45/min and built to 45/min with a flag.)
- **Test every carrier in the CGNAT list.** "It would be best to maintain mobile devices in our reachable audience, but if it's impossible, we shouldn't pollute our output with advisedly incorrect IP addresses... Depending on the results, we may wish to exclude some or all after all."
- **Demand evidence, not recollection.** "I would like to query evidence on your description of T-Mobile's geographically detached IPv4." Also "Confirm, and confirm that the streaming platforms do not accept IPv6 calls..." — the instance confirmed the first claim and refuted the second with sources.
- **Cohort/demographic mapping is the agency's job, not ours.** "ZIP codes for geotargeting as a stand-in for socioeconomic/demographic/psychographic cohorts is the responsibility of the media buying agency. This is done using Claritas PRIZM, Census Bureau data, or similar. None of these sources would include ZIP codes of post-office box installations, airports, etc."
- **6G is the watch item.** T-Mobile on-network viewers becoming ZIP-unavailable is "Not a disaster, although it may become one if 6G is more competitive with wired Internet service."
- **Always issue the deployment code block.** "You have stopped issuing the deployment code block several updates ago. Resume. I am probably two behind."
- **Correct the error and reissue the whole sequence, don't just fix the one line.** "Correct the 'No such file' condition and reissue all subsequent commands." And later: "Issue the .sql files and resume from this call."
- **Puerto Rico**: "There is no DMA code defined for Puerto Rico. The state code should be 'PR' and there should be a ZIP. ip-api does not return them?" (The measurement showed ip-api returns neither.)
- **The probing cycle must not be stopped.** "Note that the full query cycle is running and should not be stopped."
- **Production target is a full probing cycle in a day or less**, with "less than one day of drift" expected to be acceptable. The instance showed this is 32x the free-tier limit.
- **He reported that another project of his exceeded 45/min on ip-api with no errors** and asked for a 1000-address test. The instance's subsequent measurement explains it: ip-api does not error, it stalls.
- **Abort and reconnect when stuck.** "You appear stuck in 'Running command'. abort, reconnect."
- Carried-in standing orders restated by the instance in this slice and not contradicted: false negatives are worse than false positives; never exclude on a guess (`geo_exclusions.sql`'s own rule); git is the route for this project.

## Open items at end of slice

- **Boris's two closing questions are unanswered inside the line range.** (a) "Did the non-rate-limited burst of ip-api.com requests run without error?" (b) His alarm that commercial companies and especially telecom carriers appear in the instance's last database output, with the restatement that only DoD should be excluded. The output he is reacting to is the registrant cost report whose final column reads `f` for every commercial name — i.e. not matched by any active pattern — but the transcript within this range contains no reply resolving that, and his line range ends mid-way through his own pasted `rdap_registrant -fill -limit 200` output at entry [86] 160.148.0.0/15.
- **`apply_splits` has never had its registrant gate execute on real data.** Every observed dry run reported 0 excluded by operator / 0 deferred because the candidate set was exhausted by earlier tests. Re-running after the RDAP cache fill was the next step.
- **Decomposing all sub-/24 ranges rather than only `dbip_split_candidates` is still not done.** No Go change is needed — `-candidates` accepts any table or view with a `network` column, and `rdap_registrant -fill` already defaults to the full set — but the view over `ip2city_dbiplite_tbl where masklen(network) < 24 and source = 'dbip'` was deliberately not created, because turning it on adds ~3,368,502 rows and ~52 probe-days.
- **The RDAP cache is only ~486 allocations deep against 371,287 candidates.** The post-repair re-fetch of the 39 deleted rows plus further warming was in progress at the end of the slice.
- **Section 4 of `decomposition_exclusions.sql` — DoD space not covered by `geo_exclusions` — is a report awaiting Boris's decision.** Known members: 148.16.0.0/12, 140.56.0.0/13, 157.216.0.0/13, 136.188.0.0/14 and many /15s. Adding them to `geo_exclusions` removes them from probing and output entirely, which removes coverage, so the instance explicitly declined to automate it.
- **Drift measurement has only round 1.** The three cohorts (`tmobile-as21928`, `comcast-as7922`, `charter-as20115`) need the identical commands re-run after the interval of interest before any churn number exists. `probe_range_split` records a 429 as an error rather than retrying, so the `err` column must be checked afterwards.
- **The 1000-address ip-api rate test has not been run.** `probe_batch` leaves only ~300 calls/hour spare and a 1000-call test needs 22 minutes of exclusive budget; the instance recommended running it from a different source IP because a block would halt the pipeline and cannot be lifted on demand.
- **The paid ip-api batch endpoint is the only remaining lever on throughput.** Scaffolding exists in `check_geo_ip-api` (`readIPBatch`, `parseBatchResponse`), deliberately unimplemented pending verified request and response formats; it needs the paid API documentation or a test key.
- **The mobile keyword list now lives in two tools and should move to a table.** Flagged, not done.
- **A third, narrower exclusion concept is needed**: neither `geo_exclusions` nor `decomposition_exclusions` can express "valid at DMA level, invalid at ZIP level," which is what placeholder-ZIP ranges require. The instance also proposed reporting ZIP-tier coverage as a measured percentage of DMA-tier reach so that erosion (the 6G risk) becomes visible.
- **PO-Box / unique ZIP detection is now a prerequisite for the ZIP service**, not a refinement. `city2zip_tbl` does not carry USPS ZIP type (Standard / PO Box / Unique); the instance's one-third-unusable estimate for AS21928 is its own classification and needs verification against an authoritative list.
- **The ZIP API and GUI are unbuilt.** Two design questions the instance refused to guess at: direct `probe_tbl.zip` versus going through `city2zip_tbl` (the latter gives far more coverage today but a city maps to many ZIPs, so every range in that city matches all of them — a large false-positive expansion), and whether ZIP results should default to `measured_only=1`.
- **The landmark table is unbuilt**, and Boris's stated sequencing puts it before the UI. The instance's proposed pre-investment test — sample a few hundred NCES district domains, resolve apex A, MX and common on-prem hostnames, count how many land in a non-cloud ASN — was offered but not run.
- **`probe_range_split -repeat` / wireline-control comparison was requested; only the single-round cohort commands were issued.**
- **The git stash entry from `geo-rdap-excluded-internal-fallback`** (a tracked binary, pointing at a `dma_ip_table.sql` commit not on main) needs separate reconciliation.
- **The 258-row growth in the candidate count (371,757 -> 372,015) was never attributed.** The instance said it was probably the daily pipeline but explicitly declined to assume.
- **`DECOMPOSE_LOOKUP_REGISTRANT` is still 0**, so the probe-lock serialisation is inert. Setting it to 1 serialises ip-api across the whole pipeline at the cost of a skipped hourly batch.
- **AWS/EC2 hosting of the front end is undecided.** Boris was "mulling" it; the instance's position was that running the API on EC2 against Postgres on Mint30 is viable because only prefix rows cross the connection, but that it should be treated as interim and that Postgres and the API should ultimately move together, with WireGuard or SSH tunnelling, authentication and rate limiting at the edge, and the probe pipeline staying with the database.

## Uncertain

- **Whether the "non-rate-limited burst" ran without error is not answered in this range.** The instance's own report says ~420 calls produced zero 429s but many stalls (3 in the ~2000/min burst, 21 of 120 at 180/min, 17 of 120 at 90/min). Whether that counts as "without error" by Boris's standard, and whether he was asking about that burst or about something else, is not resolved before line 33670.
- **Whether Boris's alarm rests on a misreading of the report.** The output he quotes has `f` in its final column for every commercial registrant, which in the instance's reports means not matched by an active exclusion pattern. But the transcript does not contain the instance's clarification within this range, so I cannot say whether the policy was in fact wrong again or whether the report was merely misleading.
- **The exact column semantics of the 60-row registrant report** are not shown in this range — the header was cut off in Boris's paste and only the trailing columns (registrant, allocations, addresses, and a boolean) are visible.
- **Whether Boris accepted the instance's position that the ZIP API/GUI can be built before the landmark table.** He stated a sequencing preference; no resolution appears.
- **Whether Boris decided to host the front end on EC2.** He said he was mulling it.
- **What `dma_code` values exist and whether `dma2city_tbl.dma_code` is complete.** 31,899 rows carry a value; the transcript does not say how many distinct codes or whether any market is missing.
- **Why the 76.90.64.0/20 ZIP split differed between the 2026-09-09 and 2026-09-13 runs** (92543 ×12/92544 ×3 versus 92543 ×13/92544 ×2). The transcript does not comment on it. It could be the random address within each /24 landing differently, or genuine drift — the text does not say.
- **Whether the 172.56.54.0/24 Los Angeles-to-Dallas change was carrier reassignment or an ip-api data revision.** The instance explicitly says it cannot distinguish them and that operationally they are the same problem.
- **Whether the `-repeat` / `probe_stability_tbl` path was ever exercised beyond table creation.** The creation output shows all five diagnostic SELECTs returning 0 rows; no cohort run appears in this range.
- **What caused the 258-row candidate growth.**
- **Whether anything other than Boris ran `decomposition_exclusions.sql` before the paste that reported `UPDATE 0`.** The instance verified the file reports `UPDATE 4` on a non-converged table and `UPDATE 0` on a second run, concluded Boris's output was an already-converged table consistent with the file having run twice, and said that if he did not run it twice then something else did and it would want to know what. Unresolved.
- **Whether the sandbox-measured ip-api behaviour applies to Boris's host.** The instance was explicit that all burst testing was done from the sandbox IP, and that the persistence of the penalty is two samples.
- **Several figures the instance cited as background were never measured**: tens of thousands of cable headends and hubs, ~20,000+ ILEC central offices, hundreds of thousands of fiber nodes, the global IPv6 BGP table being roughly a fifth the size of the IPv4 one (the instance called this "my recollection and I'd want it measured, not trusted" and supplied a query for it that does not appear to have been run), and the claim that a large DMA is "plausibly ten times" Indianapolis.
- **The db-ip IPv6 masklen distribution** — the measurement the instance said should decide whether IPv6 is worth switching on — was requested twice and does not appear to have been run in this range.
