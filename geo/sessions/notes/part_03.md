# Part 03 (lines 9621-14430)

Session dates visible in command output: **2026-09-01**. Working branch throughout:
`geo-rdap-excluded-internal-fallback`. Boris's box: `boris@Immetrica-Mint30`, code under `~/geo/...`,
Postgres database `postgres` (psql prompt `postgres=#`).

## Narrative

The slice opens mid-dump of `~/geo/bgp_route_views/cmd/main.go`, the RouteViews MRT ingester
(commit `943797f`), and Boris immediately issues a one-line order: "Do not timeout the download at
all." The instance removes the `-download-timeout` flag and the per-download context deadline so
`downloadToTemp` runs on a plain background context with `http.Client{Timeout: 0}`, leaving only
dial (30s), TLS handshake (30s) and `ResponseHeaderTimeout` (`-http-timeout`, default 2m) as bounds;
it verifies `go vet` clean, a successful build, and that `-download-timeout` is gone from `-h`
(commit `21abaef`). Boris asks for the full heredoc and the whole file is reposted.

Boris then challenges the load result: "Only 1121547 rows. Are you sure this is correct? db-ip.com
had 5mln for USA and 14mln worldwide." The instance explains that `bgp_route_views` holds the global
BGP routing table (one row per announced prefix) while db-ip holds geolocation sub-ranges that
subdivide those prefixes per city, so ~1.12M vs ~14M is expected, and offers sanity queries. Boris
follows with the sharper question: can a single prefix cover multiple geographic areas? Yes — and
that opens the real line of inquiry for the rest of the slice.

Boris asks for an empirical test: take the first 100 `/24` ranges in `bgp_route_views` and run 45
ip-api.com queries against each, respecting the 45/min limit as the earlier `check_geo_ip-api` code
did. He states his skepticism that large aggregates are widely used, noting he does not see
Comcast's `/9` in the output. The instance cannot reach Boris's Postgres, so it samples the same
RouteViews RIB instead, runs 45 probes across the first five `/24`s (all single-city) and 45 across
three large blocks (`73.0.0.0/8`, `12.0.0.0/8`, `52.0.0.0/11` — all highly heterogeneous), then
asserts that Comcast and AT&T deaggregate so no `/8` route exists. Boris catches that those blocks
were never selected from his database. The instance admits it hardcoded them from IANA/ARIN
knowledge, checks RIPEstat, and retracts the deaggregation story: `73.0.0.0/8` is announced as an
exact single prefix by AS7922 with zero more-specifics.

Boris runs the mask-length histogram and the shortest-prefix list himself. The instance then
fabricates a per-`/8` operator breakdown without having run the query; Boris's next query errors
(`column "city" does not exist` — he had been given geo columns that live on a different table) and
the instance retracts the fabricated list. Boris supplies the real `masklen=8` output, and the
annotation is redone from his data.

Boris then reframes the whole RouteViews effort. db-ip (1 August edition) stays the authoritative
baseline in `ip2city_dbiplite_tbl`; he needs DMA- and ZIP-level accuracy only; ownership changes and
re-aggregation do not concern him. RouteViews' sole value is its ~2h cadence as a tripwire telling
him that a range in this month's db-ip set has been split into smaller units before next month's
db-ip drop. He asks for a program to answer: are any unitary db-ip ranges split in RouteViews? The
instance drops the previously proposed `check_routeviews_ip-api` patches as now irrelevant and writes
`check_range_splits`, which counts BGP prefixes strictly inside each db-ip range.

Delivering that program consumes a large part of the slice. Boris's copy/paste path repeatedly
corrupted the source: first the Go backtick raw-string SQL literals vanished, then the same compile
errors recurred at identical line numbers through a double-quoted rewrite, a raw base64 block, a
gzip+base64 block ("invalid compressed data"), and a plain quoted heredoc. Boris tells the instance
to stop using base64 and to apply "strict adversarial premortem." The instance examines the exact
error columns, determines that the two-character sequence backslash-n is being converted into a real
newline in transit (shredding every string literal containing it and shifting all later line
numbers), and rewrites the file to contain **zero backslashes** — newlines come from `fmt.Println`
and `fmt.Sprintf` instead. That version (commit `9d7c6f4`) built on Boris's machine. Along the way
Boris issued a standing order: never guess at all, and flag anything where guessing is the only
source of information.

The first real run produced the answer: **24,168** db-ip ranges contain ≥2 separately-routed BGP
sub-prefixes. Boris observes that many fractional BGP ranges are absent from db-ip and orders the
pipeline extended: import RouteViews daily, run split detection, add the BGP prefixes missing from
db-ip, then geolocate from `ip2city_dbiplite_tbl` via ip-api as now. For ranges wider than `/24` he
proposes 4 probes per `/24` (1,024 for a `/16`) and asks whether that is statistically sound. The
instance confirms the arithmetic, then runs 45 live ip-api probes from its own sandbox (which has
open internet) and measures that ip-api's answer is constant within a `/24` but varies between
`/24`s — so 3 of every 4 probes are pure waste. Boris accepts one probe per `/24`, aligned to the
start of the wider range; orders that inserting from BGP deletes the db-ip record; and asks for
government ranges to be excluded until the ip-api subscription is upgraded, while worrying about
losing on-base housing coverage.

The instance probes DoD space and finds all 12 probes return one of two whois registrant addresses,
so no subscription tier can geolocate it — excluding it costs nothing. Boris then asks for counts of
narrower-than-`/24` ranges in both tables, which the instance delivers as `sub24_analysis.sql`. The
result overturns an instance recommendation: db-ip has **603,354** sub-`/24` rows, all labeled with a
city, and **84,986 of 102,537** parent `/24`s contain sub-ranges that disagree on city. Boris had
already said he would not collapse narrower ranges on so little evidence; the instance retracts the
collapse idea and adopts the rule that sub-`/24` db-ip rows are authoritative and must never be
overwritten by a `/24`-level probe. Boris orders a permanent exclusion table, minimizing
computational impact; the instance builds `geo_exclusions` plus a DoD seed sourced from the IANA
IPv4 registry (12 DoD-affiliated `/8`s), and Boris adds a hard constraint: match DoD by range or ASN
only, never by ZIP, because Columbus OH must not be lost. The instance records the durable rules in
`.kiro/steering/geo-pipeline.md` and writes `probe_budget.sql`. The slice ends with the budget
numbers coming back: **986,450** probes ≈ **15.2 days** at 45/min for the 24,168 flagged ranges, with
the DoD-exclusion sections reporting zero savings because `geo_exclusions` had not yet been seeded on
Boris's database.

## Decisions and rationale

- **Remove the RIB download timeout entirely.** Boris: "Do not timeout the download at all." The
  instance deleted `-download-timeout` and the per-download context deadline; `http.Client.Timeout`
  was already 0; only dial/TLS/response-header bounds remain. Boris ordered it; implemented as
  ordered.
- **Keep the deduped (one row per prefix) default for `bgp_route_views`.** Rationale: geography does
  not depend on which peer observed a route; per-peer would be tens of millions of rows. Boris did
  not challenge this in this slice; he challenged the row count, and accepted the explanation.
- **Abandon `check_routeviews_ip-api` as a pipeline component.** It geolocates every BGP prefix,
  which is not what Boris wants. Boris confirmed he had never run it and did not think it had been
  sent; the instance left it aside (it had been committed earlier as `b75815a`). Boris's reframing
  overrode the earlier plan to patch it (skip `/0`, longest-prefix match, multi-sample).
- **db-ip remains the authoritative baseline; RouteViews is only a split tripwire.** Boris's stated
  reasoning: RouteViews refreshes every ~2h, db-ip only monthly; he needs DMA/ZIP accuracy; changes
  in ownership and any re-aggregation do not concern him. This overrode the instance's earlier
  framing of RouteViews as a geolocation range source.
- **Definition of "split":** a db-ip range R is split if ≥ `-min-children` BGP prefixes are
  *strictly* more specific than R (`b.cidr_block << d.network`). A db-ip `/24` sitting inside
  Comcast's `73.0.0.0/8` is explicitly **not** a split — R must contain the more-specifics. Boris
  accepted this definition by running the tool.
- **One probe per `/24`, not four.** Boris proposed `4 × 2^(24−masklen)` (1,024 for a `/16`) and
  asked whether it was statistically sound. The instance measured that ip-api returns a constant
  answer within a `/24`, making probes 2–4 guaranteed duplicates, and recommended a census of
  `2^(24−masklen)`. Boris accepted: "I agree with 1 probe per /24."
- **Probe `/24`s aligned to the start of the wider range.** Boris's instruction. The instance noted
  that because CIDR blocks are power-of-two aligned, this is simply the complete set of `/24`s in the
  range (`network + i*256`), so there is no ambiguity.
- **On insert from RouteViews, delete the db-ip record.** Boris's explicit instruction for parent
  handling (the instance had asked whether to replace or keep-and-add).
- **Do NOT collapse sub-`/24` ranges into `/24`s.** The instance proposed collapsing the probe set to
  distinct `/24`s and fanning results out. Boris rejected it before seeing the evidence ("I do not
  wish to collapse narrower ranges into /24s on the basis of so little evidence"), and Query 4 then
  proved him right (84,986 conflicting parent `/24`s, 603,354 fully-labeled sub-`/24` rows). The
  instance formally retracted the recommendation and distinguished two claims it had conflated:
  ip-api cannot see inside a `/24` (holds) vs. nothing can (false — db-ip can).
- **Exclude government/DoD ranges permanently via an exclusion table.** Boris: "Exclude the two giant
  DoD subnets permanently. Best to put them in an exclusion table to be referenced. Minimize the
  computational impact of the exclusion." He later clarified he meant the DoD ranges behind the
  two-registrant-address finding, not two specific CIDRs. The instance built `geo_exclusions` with
  both prefix and ASN rule kinds and seeded 12 IANA DoD `/8`s.
- **Match DoD by prefix or ASN only, never by ZIP.** Boris: "Do not match DoD on ZIP, only on ranges
  or ASNs. We cannot lose Columbus, OH." The instance had itself flagged the false-positive risk and
  agreed; it recorded the rule in steering.
- **Inline exclusions as literal predicates rather than joining/`EXISTS`.** Rationale: a 2–13 row
  rule list evaluated as a correlated subquery per candidate row is wasteful; read once at startup
  and inline. Boris asked for minimal computational impact; the instance proposed this. The instance
  also retracted its claim that filtering on AS749/AS721 would speed the 22-minute join, after
  measuring that those ASNs account for only 3,364 of 1,121,547 rows (0.3%).
- **Deliver all code as backslash-free, backtick-free heredocs.** Forced by the paste corruption.
  Boris: "Do not use base64. Issue a heredoc that is immune to damage from the shell."
- **Standing order recorded: never guess.** Boris: "You are under standing orders never to guess at
  all. Where guessing is the only source of information, you must flag it." The instance recorded it
  (the transcript shows a tool call creating a learning/standing order) and thereafter marked
  inferences explicitly.

## Measured facts and numbers

Row counts and table shape (all from queries Boris ran, unless noted):

- `bgp_route_views` full load: **1,121,547** rows (deduped, one row per prefix). Boris's figure.
- IPv4 mask-length histogram of `bgp_route_views` (first 16 rows): `/0`→1, `/8`→16, `/9`→14,
  `/10`→39, `/11`→97, `/12`→300, `/13`→594, `/14`→1205, `/15`→2173, `/16`→13887, `/17`→8529,
  `/18`→13648, `/19`→26277, `/20`→47835, `/21`→55758, `/22`→116334.
- Prefixes at `/12` or shorter: 1+16+14+39+97+300 = **467** rows out of ~1.12M (instance arithmetic
  on Boris's counts).
- The 16 IPv4 `/8`s present, with origin ASN (Boris's query output): 7→749, 11→749, 12→7018, 17→714,
  21→749, 22→749, 26→749, 28→749, 29→749, 30→749, 33→749, 38→174, 53→31399, 55→**721**, 73→7922,
  214→**721**.
- `SELECT count(*) FROM bgp_route_views WHERE origin_asn IN (749, 721)` → **3,364** (0.3% of
  1,121,547).
- Around `/24` in `bgp_route_views` (IPv4): wider than `/24` **404,724**; exactly `/24` **714,513**;
  narrower than `/24` **2,310**; total **1,121,547**.
- BGP prefixes narrower than `/24`: `/25`→361, `/26`→541, `/27`→989, `/28`→56, `/29`→85, `/30`→18,
  `/31`→5, `/32`→255.
- Around `/24` in `ip2city_dbiplite_tbl` (IPv4): wider **396,330**; exactly `/24` **734,334**;
  narrower **603,354**; total **1,734,018**. (This contradicts the "~14M rows" figure in the
  instance's index-build log message, which the instance acknowledged as cosmetically wrong; Boris's
  "5mln USA / 14mln worldwide" was presumably the full db-ip edition, not lite — the instance flagged
  that as a presumption.)
- db-ip ranges narrower than `/24`: `/25`→91,239, `/26`→110,021, `/27`→108,528, `/28`→106,887,
  `/29`→105,487, `/30`→65,641, `/31`→7,882, `/32`→7,669.
- Sub-`/24` db-ip rows: **603,354** total, **603,354** with a city label, **0** unlabeled.
- Parent `/24`s containing sub-`/24` db-ip rows: **102,537**; of those, **84,986** (≈83%) hold
  sub-ranges with *conflicting* cities, **17,551** agree on one city, **0** entirely unlabeled.
- Worst conflicting `/24`s: 25 blocks each with 16 rows and 3 distinct cities, e.g.
  `32.142.43.0/24` → Ashburn | New York | Reston; `64.210.14.0/24` → Monroe | New York |
  Washington D.C.; `64.55.18.0/24` → Boston | New York | Stoneham. Heavily `12.x` and `32.x` (AT&T).
  The instance's reading that these are enterprise/colo `/28` allocations was explicitly flagged as
  inference, not verified.

Split detection (`check_range_splits`), run 1 at 12:27:48, run 2 at 14:50:56, both 2026-09-01:

- GiST index `ip2city_network_gist` build: **1m53s** (run 1). Run 2: **0s** (index persisted).
- Containment scan: **22m26s** (run 1), **22m16s** (run 2 with `-write`).
- **24,168** db-ip ranges split into ≥2 BGP sub-prefixes (identical in both runs).
- Most-fragmented range: **530** sub-prefixes. **89,044** BGP prefixes fall inside split ranges.
- Child-count distribution: 2→**15,919**; 3→**1,577**; 4→**3,716**; 5–9→**2,017**; 10–99→**920**;
  100+→**19**.
- Top fragmented ranges (country US for all shown): `55.64.0.0/10` 530; `214.64.0.0/10` 465;
  `214.32.0.0/11` 371; `52.216.0.0/15` 357; `165.20.0.0/16` 256; `66.166.0.0/16` 256;
  `214.24.0.0/13` 243; `22.0.0.0/8` 227; `11.0.0.0/10` 203; `55.128.0.0/9` 152; `205.0.0.0/11` 150;
  `134.232.0.0/14` 134; `137.246.0.0/16` 132; `178.156.128.0/17` 128; `74.49.0.0/17` 128;
  `52.218.128.0/17` 127; `136.216.0.0/14` 126; `131.71.0.0/16` 114; `6.72.0.0/13` 103;
  `55.40.0.0/13` 96; `6.128.0.0/9` 94; `6.32.0.0/12` 92; `2.25.128.0/17` 86; `139.71.0.0/17` 83;
  `143.212.0.0/15` 81; `158.14.0.0/16` 76; `2.25.64.0/18` 75; `159.45.0.0/16` 73; `131.14.0.0/15` 72;
  `164.236.0.0/14` 72.

Live ip-api.com probe measurements (run from the instance's sandbox, which reported `OPEN_INTERNET`;
45 probes total in the granularity experiment):

- 8 hosts inside `66.166.1.0/24` (AS22773, Cox): **all 8 identical** — Alexandria, ZIP 22320.
- 12 `/24`s across `66.166.0.0/16`: **all 12 identical** — that `/16` is uniform.
- 12 `/24`s across `73.45.0.0/16` (Comcast): **10 different cities**, including `73.45.32.x` =
  Springfield IL 62704, a different DMA roughly 200 miles from the Chicago cluster.
- 8 hosts inside `73.45.96.0/24`: all identical — Chicago 60657.
- 5 hosts inside `73.45.32.0/24`: all identical — Springfield 62704.
- Summary: **21 intra-`/24` probes across 3 `/24`s in 2 ASNs, zero intra-`/24` variation.** The
  instance flagged that this is evidence from 3 `/24`s, not proof of universality.

Earlier reality-check probes (first `/24`s vs large aggregates), 45 + 45 probes:

- `1.0.0.0/24` → 1 location of 9 IPs (South Brisbane AU, Cloudflare); `1.0.4.0/24`, `1.0.5.0/24`,
  `1.0.6.0/24`, `1.0.7.0/24` → 1 location each of 9 IPs (Narre Warren AU, Gtelecom).
- `73.0.0.0/8` (Comcast) → **15 distinct locations of 15 IPs** (Pompano Beach FL, Haverhill MA,
  Parker CO, Chicago IL, Houston TX, Fremont CA, Redmond WA, …).
- `12.0.0.0/8` (AT&T) → **14** distinct locations of 15.
- `52.0.0.0/11` (AWS) → **6** distinct locations of 15, spanning Ashburn VA, Portland OR, San Jose,
  Dublin OH, Dublin IE, Frankfurt DE — three countries.
- Important caveat the instance itself surfaced: these three blocks were **hardcoded from
  IANA/ARIN knowledge, not selected from `bgp_route_views`**, so the probes sampled address space,
  not a query result.

RIPEstat verification of the aggregates (instance-run lookups):

- `73.0.0.0/8` announced as an exact single prefix by **AS7922**, visible to **325** RIS peers;
  Comcast announces **431** prefixes total; **zero** more-specifics inside `73/8`; ~**16.7M**
  addresses.
- `12.0.0.0/8` announced exactly by **AS7018**; **647** prefixes total; only **10** more-specifics
  inside the `/8`.
- `52.0.0.0/11` announced exactly by **AS16509**.

DoD probe measurement (12 probes, 2026-09-01):

- **10 of 12** → Columbus OH **43218** (DoD Network Information Center / DISA registrant address).
- **2 of 12** → Sierra Vista AZ **85613** (USAISC, Fort Huachuca registrant address).
- `22.1.1.1` and `22.162.5.1` — 162 `/16`s apart — returned the **identical ZIP**.
- Probes spanned at least nine different `/8`s: 6, 11, 22, 55, 134, 158, 164, 205, 214. The instance
  explicitly corrected its own earlier misreading that "two locations" meant "two subnets."

Probe-budget arithmetic and cost tables (arithmetic, not measurement, except where from SQL):

- Boris's proposal: `4 × 2^(24−masklen)`; `/16` → 4 × 256 = **1,024**. Arithmetic confirmed correct.
- Detection power of 4 random probes against a minority sub-block of fraction p = `1−(1−p)^4`:
  ≈**68%** for a `/26` minority (p=0.25), ≈**41%** for a `/27` (p=0.125). Model calculation.
- Free-tier rate: **45 probes/min = 64,800/day**.
- At 4×/24: `/16` 1,024 probes ≈ 23 min; `/12` 16,384 ≈ 6.1 h; `/8` 262,144 ≈ 97 h (~4 days).
- At 1×/24: `/24` 1 (1.3 s); `/20` 16 (21 s); `/16` 256 (5.7 min); `/12` 4,096 (1.5 h); `/10` 16,384
  (6.1 h); `/8` 65,536 (**24.3 h**).
- DoD prefix exclusion saving (arithmetic): 12 `/8`s × 65,536 = **786,432** probes ≈ **12.1 days**;
  including `7.0.0.0/8` → **13.1 days**.
- `probe_budget.sql` on 24,168 candidates (Boris's run, truncated at the end of this slice):
  - mask distribution → ranges/probes: `/8` 4/262,144; `/9` 3/98,304; `/10` 3/49,152; `/11` 4/32,768;
    `/12` 8/32,768; `/13` 19/38,912; `/14` 72/73,728; `/15` 194/99,328; `/16` 408/104,448;
    `/17` 363/46,464; `/18` 524/33,536; `/19` 824/26,368; `/20` 1,296/20,736; `/21` 2,610/20,880;
    `/22` 5,662/22,648; `/23` 12,092/24,184; `/24` 77/77; `/25` 4/4; `/29` 1/1.
  - Total, no exclusions: **24,168 ranges, 986,450 probes, 15.2 days** at 45/min.
  - Total "DoD prefixes excluded": **identical** (24,168 / 986,450 / 15.2) — because `geo_exclusions`
    was not seeded on Boris's DB.
  - "What the DoD exclusion removed": **0 ranges, NULL probes_avoided** — confirms the empty table.
  - Capped (`masklen >= 12` AND DoD excluded): **24,154 ranges, 544,082 probes, 8.4 days**.
  - Costliest surviving ranges (list truncated at end of slice): `22.0.0.0/8` 227 children / 65,536
    probes; `29.0.0.0/8` 24/65,536; `7.0.0.0/8` 11/65,536; `21.0.0.0/8` 4/65,536; `55.128.0.0/9`
    152/32,768; `6.128.0.0/9` 94/32,768; `11.128.0.0/9` 7/32,768.
- Estimates explicitly presented as such: "per-peer would have been ~30M (≈1.1M × ~28 peers)";
  "global BGP table today roughly ~950k–1M IPv4 + ~180k–220k IPv6"; db-ip full-edition row counts.

File hashes recorded during the paste-corruption fight:

- Instance's double-quoted `main.go`: `d74937733609561ccdee2ebe8b9887cfc07c130ceec17a775e37ede4770d2c83`.
- Boris's base64-decoded copy: `c239469beb262bc445345e436cd3c0870bbdbc95d5a897e906b8de369eabdcd5` (built
  with exactly one error).
- Boris's heredoc copy of the same file: `5f8c19f2001b574d281f120e3e796ffdced3707d0575aa643577f7e0992d15bf`
  (failed).
- `go.mod`: `9ec8ae464558d20cac08b401f010fbd709e6e5cbbe82017029867eae1dcb89be` — **matched exactly**
  on Boris's side (it contains no escapes).
- Final backslash-free `main.go`: `609904ce0c0a15fa0fa155240939875410a36381d47412e7483b69825138be3d`
  (this one built on Boris's machine).
- Prebuilt static linux/amd64 binary offered via raw.githubusercontent:
  `96b98faa230f9ee5d39dfec0f4e574577f13905cb17b19d007da39d0961cc0c2` (never used — repo private from
  Boris's side).

## Code, files, tables

**`~/geo/bgp_route_views/cmd/main.go`** (commits `943797f` → `21abaef`). RouteViews MRT ingester.
Modes: `-mode full` (download newest RIB to a temp file, `TRUNCATE bgp_route_views`, `COPY` in,
create index, set state, commit) and `-mode updates` (apply UPDATES files newer than stored state).
Flags: `-mode`, `-collector` (default `route-views2`), `-archive-url`
(`http://archive.routeviews.org/`), `-since`, `-peer`, `-per-peer`, `-dry-run`, `-limit`,
`-http-timeout` (default 2m, bounds connection + response headers only). Changes in this slice:
`-download-timeout` flag and the per-download `context.WithTimeout` deleted so the body transfer is
never bounded; `downloadToTemp(ctx, client, url)` lost its `timeout` parameter. Internals present in
the dump: `eachMRT` (normalizes `BGP4MP_ET` by stripping the leading 4-byte microsecond field and
rewriting the header type/len), `originAndPath` (handles `As4PathParam` and `AsPathParam`; origin =
last ASN), `ribIterator` implementing `pgx.CopyFromSource` with deduped and per-peer row builders,
`listArchive`/`latestRIB`/`updatesSince` (regex `(rib|updates)\.(\d{8}\.\d{4})\.bz2`, month dirs
`YYYY.MM/RIBS/` and `YYYY.MM/UPDATES/`), `prefixRange` (big.Int-based first/last host, IPv4+IPv6),
`nullASN`, `nullStr`.

**Table `bgp_route_views`** — columns used: `cidr_block`, `start_address`, `end_address`,
`origin_asn`, `peer_ip`, `as_path`, `updated_at` (set to the source file's UTC timestamp). In the
default deduped mode `peer_ip` and `as_path` are NULL. Index created by the full load:
`bgp_route_views_cidr_peer_idx ON bgp_route_views (cidr_block, peer_ip)`. **It has no geo columns** —
`city`/`regionname` live on `ip2city_dbiplite_traceroute_tbl` (that mistake cost a query error).

**Table `bgp_rv_ingest_state`** — `collector text PRIMARY KEY`, `last_file_ts timestamptz NOT NULL`,
`updated_at timestamptz NOT NULL DEFAULT now()`. Upserted inside the same transaction as the data.

**Table `ip2city_dbiplite_tbl`** (Boris's `\d` output, the db-ip baseline, 1 August edition):
`network cidr NOT NULL`, `continent_code text NOT NULL`, `continent_geoname_id bigint`,
`continent_names jsonb NOT NULL`, `country_geoname_id bigint`, `country_iso_code text`,
`country_is_in_eu boolean`, `country_names jsonb NOT NULL`, `city_names jsonb NOT NULL`,
`latitude double precision`, `longitude double precision`, `subdivisions_names jsonb NOT NULL`,
`start_ip inet`, `end_ip inet`, `city text`, `state text`. 1,734,018 IPv4 rows.

**`~/geo/check_range_splits/cmd/main.go`** + `go.mod` (commits `1c3f32c`, `2ea900d`, `9d7c6f4`).
Answers "which unitary db-ip ranges are now split into multiple separately-routed BGP sub-prefixes".
Flags: `-min-children` (2), `-top` (50), `-examples` (6), `-ipv4-only`, `-country`, `-create-index`
(true), `-write`. Behaviour: ensures the GiST index; builds `CREATE TEMP TABLE _splits AS SELECT
d.network, d.country_iso_code, count(*) ... FROM ip2city_dbiplite_tbl d JOIN bgp_route_views b ON
b.cidr_block << d.network GROUP BY ... HAVING count(*) >= $1`; prints the headline count, max/sum
children, a bucketed distribution, and the top-N ranges with example children + origin ASNs; with
`-write` truncates and repopulates `dbip_split_candidates`. Final version contains **no backticks and
no backslashes** (all SQL as concatenated double-quoted single-line strings; all newlines via
`fmt.Println`). `go.mod`: module `check_range_splits`, go 1.25.1, `github.com/jackc/pgx/v5 v5.10.0`
plus pgpassfile/pgservicefile/golang.org/x/text as indirect.

**Table `dbip_split_candidates`** (created by `check_range_splits -write`): `network cidr PRIMARY
KEY`, `country_iso_code text`, `bgp_children int NOT NULL`, `detected_at timestamptz NOT NULL
DEFAULT now()`. Populated with 24,168 rows at 15:13:12 on 2026-09-01.

**Index `ip2city_network_gist`** — `ON ip2city_dbiplite_tbl USING gist (network inet_ops)`. Built
once (1m53s); persists.

**`~/geo/sub24_analysis.sql`** (commit `6fbac45`). Seven labelled sections: BGP sub-`/24` mask
histogram; BGP split around `/24`; the same two for db-ip; whether sub-`/24` db-ip rows carry a city;
the decisive "do sub-`/24` ranges inside one `/24` disagree on city" aggregation using
`set_masklen(network, 24)`; worst conflicting `/24`s with `string_agg`; and exposure of sub-`/24` BGP
children inside flagged split ranges. Deliberately contains no psql meta-commands (`\echo` was
removed) and no backslashes.

**`~/geo/geo_exclusions.sql`** (commit `979c4c1`). Creates `geo_exclusions`: `id serial PRIMARY KEY`,
`prefix cidr`, `origin_asn bigint`, `reason text NOT NULL`, `active boolean NOT NULL DEFAULT true`,
`added_at timestamptz NOT NULL DEFAULT now()`, plus `CONSTRAINT geo_exclusions_one_kind CHECK` that
exactly one of `prefix`/`origin_asn` is set. Indexes: `geo_exclusions_prefix_gist` (GiST,
`prefix inet_ops`, partial on `prefix IS NOT NULL AND active`), `geo_exclusions_asn_idx` (partial),
and unique partial indexes `geo_exclusions_prefix_uniq`, `geo_exclusions_asn_uniq`. Seeds ASN rules
for 749 and 721; prefix seeds left commented pending Boris's clarification.

**`~/geo/geo_exclusions_seed_dod.sql`** (commit `68ba6d6`). Seeds the 12 IANA DoD-affiliated `/8`s
(6, 11, 21, 22, 26, 28, 29, 30, 33, 55, 214, 215) with IANA designations in `reason`, cites
`https://www.iana.org/assignments/ipv4-address-space/ipv4-address-space.txt`, leaves `7.0.0.0/8`
commented as a flagged discrepancy (IANA says ARIN-administered, Boris's BGP data shows AS749
originating it), leaves four observed sub-`/8` DoD blocks commented (`134.233.0.0/16`,
`158.14.0.0/16`, `164.236.0.0/14`, `205.0.0.0/11`), and ends with a query measuring probes avoided.

**`~/geo/probe_budget.sql`** (committed with `3a2c50b`). Seven sections sizing the probe job at one
probe per `/24` using `pow(2, greatest(0, 24 - masklen(network)))`: mask distribution, total with and
without DoD exclusion, what the exclusion removed, the capped (`masklen >= 12`) variant, the 20
costliest surviving ranges, and a count of flagged ranges that already hold finer db-ip rows
(the safety check for the delete-parent rule).

**`.kiro/steering/geo-pipeline.md`** (commit `3a2c50b`). Durable rules recorded so they survive
session boundaries: one probe per `/24`; sub-`/24` db-ip rows are authoritative and must never be
overwritten by a `/24` probe; DoD matching by prefix/ASN only, never ZIP, with the Columbus OH
reasoning; exclusions inlined rather than joined; backslash-free code delivery.

## Commands worth keeping

```
cd ~/geo/bgp_route_views/cmd
go build -o ../bin/bgp_route_views .
DATABASE_URL='postgres://…' ../bin/bgp_route_views -mode full
```

```
cd ~/geo/check_range_splits/cmd
go get github.com/jackc/pgx/v5
go mod tidy
go build -o ../bin/check_range_splits .
DATABASE_URL='postgres://…' ../bin/check_range_splits -min-children 2 -top 30
cd ~/geo/check_range_splits/cmd && ../bin/check_range_splits -min-children 2 -write -top 0
```

```
grep -c '`' main.go        # must print 0 (no Go backtick raw-strings)
grep -c '\\' main.go       # must print 0 (no backslash escapes)
sed -n '100p' ~/geo/check_range_splits/cmd/main.go | cat -A   # ground-truth bytes of a bad line
sha256sum main.go go.mod
gofmt -w main.go
```

```
psql -d postgres -f ~/geo/sub24_analysis.sql
psql -d postgres -f ~/geo/geo_exclusions.sql
psql -d postgres -f ~/geo/geo_exclusions_seed_dod.sql
psql -d postgres -f ~/geo/probe_budget.sql
```

Verified-useful SQL (all run by Boris):

```sql
SELECT masklen(cidr_block) AS len, count(*)
FROM bgp_route_views WHERE family(cidr_block)=4
GROUP BY 1 ORDER BY 1 LIMIT 16;

SELECT cidr_block, origin_asn
FROM bgp_route_views WHERE family(cidr_block)=4
ORDER BY masklen(cidr_block) ASC, cidr_block LIMIT 40;

SELECT cidr_block, origin_asn FROM bgp_route_views
WHERE family(cidr_block)=4 AND masklen(cidr_block)=8 ORDER BY cidr_block;

SELECT cidr_block, origin_asn FROM bgp_route_views
WHERE cidr_block = cidr '73.0.0.0/8'
   OR cidr_block = cidr '12.0.0.0/8'
   OR cidr_block = cidr '52.0.0.0/11';

SELECT count(*) FROM bgp_route_views WHERE origin_asn IN (749, 721);

CREATE INDEX IF NOT EXISTS ip2city_network_gist
  ON ip2city_dbiplite_tbl USING gist (network inet_ops);

-- the split test, standalone
SELECT count(*) AS split_ranges FROM (
  SELECT d.network
  FROM ip2city_dbiplite_tbl d
  JOIN bgp_route_views b ON b.cidr_block << d.network
  GROUP BY d.network
  HAVING count(*) >= 2
) s;
```

Rate-limited ip-api probe shape used for the granularity test (the instance ran the real variant from
its sandbox; this is the form given to Boris, with a real address substituted for the placeholder):

```
for h in 1 33 65 97 129 161 193 225; do
  curl -s "http://ip-api.com/json/66.166.1.$h?fields=query,city,zip,lat,lon"; echo
  sleep 2
done
```

## Traps and gotchas

- **The chat/paste path converts the two-character sequence `\n` into a real newline.** This is the
  single most expensive discovery in the slice. Symptoms: `newline in string` and `syntax error:
  unexpected : at end of statement` at the *same* line numbers (100, 101, 102, 107, 109, 132, 133)
  across four different delivery mechanisms. The diagnosis came from matching error columns to source
  bytes: column 14 of line 100 was exactly the backslash of a `\n` inside
  `fmt.Printf("\n=== ...")`, and the stray `:` on the next line was the colon from
  `sub-prefixes): %d`. **Fix: write Go source containing zero backslash escapes** — get newlines from
  `fmt.Println()` and format with `fmt.Println(fmt.Sprintf(...))`. Verify with `grep -c '\\' main.go`
  (expect 0). The resulting file built first try on Boris's machine.
- **Go backtick raw-strings are also destroyed in transit.** The first failure mode: all 15 backticks
  in the SQL literals disappeared, producing the same `newline in string` class of error. Fix: write
  every SQL statement as concatenated double-quoted single-line strings. Verify with
  ``grep -c '`' main.go`` (expect 0).
- **base64 is the wrong remedy and actively harmful here.** Raw base64 was silently corrupted in one
  spot — `top.Scan(&a.net, ...)` instead of `&r.net` — which compiled to exactly one error
  (`undefined: a`) and would have passed unnoticed had the instance not diffed against its sandbox
  bytes. gzip+base64 then failed outright with "invalid compressed data", because a single flipped
  character destroys the whole payload via the CRC. Boris's rule: plain heredoc with a quoted
  delimiter, which keeps corruption localized and compiler-pinpointed.
- **`<<'EOF'` (quoted delimiter) is required**, not `<<EOF`, so the shell does not expand `$1`/`$2`
  SQL placeholders or interpret backslashes.
- **psql meta-commands like `\echo` contain backslashes** and therefore cannot be used in any SQL
  file delivered through this channel. Replace with `SELECT 'section name' AS section;`.
- **The repo is private from Boris's machine**, so `curl` of `raw.githubusercontent.com` URLs fails
  unauthenticated — even though `gh api repos/borislevitanimmetrica/claude --jq .private` returned
  `false` from the instance's side. Do not route code delivery through raw URLs.
- **`go.sum`/deps may be missing for a freshly heredoc'd module**: Boris had to run
  `go get github.com/jackc/pgx/v5` before `go build` succeeded.
- **Asserting facts without running the query.** The instance twice stated things it had not
  verified: that Comcast/AT&T deaggregate so no `/8` route exists (false — `73.0.0.0/8` is announced
  whole by AS7922 with zero more-specifics), and a complete per-`/8` operator breakdown invented from
  memory. Both were retracted after Boris challenged them. The real `/8` list came from his own
  `masklen=8` query, which also corrected the instance's claim that all DoD `/8`s are AS749 —
  `55.0.0.0/8` and `214.0.0.0/8` are **AS721**.
- **Geo columns are not on `bgp_route_views`.** A proposed query selecting `city, regionname` from it
  errored with `column "city" does not exist`; those columns are on
  `ip2city_dbiplite_traceroute_tbl` and require a join.
- **`0.0.0.0/0` is present in `bgp_route_views`** (one row, origin AS174 — a default route).
  Geolocating it is meaningless, and any naive sampler would happily probe it. Suggested guard:
  `AND masklen(cidr_block) > 0`.
- **Overlapping prefixes exist** (`12.0.0.0/8`, `12.0.0.0/9`, `12.128.0.0/9` are all rows), so any
  address lookup must take the longest-prefix match, not an arbitrary covering row.
- **ip-api's resolution is coarser than db-ip's.** ip-api returns a constant answer within a `/24`
  (21 intra-`/24` probes, zero variation), but db-ip has 603,354 sub-`/24` rows and 84,986 parent
  `/24`s whose sub-ranges disagree on city. A `/24`-level probe writing over those rows is a silent
  data-loss mode. The rule adopted: sub-`/24` db-ip rows are authoritative; probes only fill or
  refresh where db-ip has nothing finer. The instance's original error was conflating "ip-api cannot
  see inside a `/24`" with "nothing can."
- **ip-api returns whois registrant addresses for DoD space, not subscriber locations.** 12 probes
  across 9 different `/8`s gave only Columbus OH 43218 and Sierra Vista AZ 85613; `22.1.1.1` and
  `22.162.5.1` returned the same ZIP. Consequence: upgrading the ip-api subscription will **not**
  fix DoD geolocation — the paid tier removes rate limits and adds batch queries, it does not add
  data that does not exist.
- **Never detect DoD by ZIP.** Columbus OH 43218 is the DoD NIC registrant ZIP *and* a real
  commercial location (DMA 535). ZIP matching would silently suppress legitimate ranges. Match on
  prefix or ASN only. The instance had flagged the false-positive risk; Boris made it a hard rule.
- **ASN-based DoD exclusion does not cover DoD space.** AS749+AS721 is only 3,364 of 1,121,547 BGP
  rows (0.3%), and the top-30 fragmented list shows DoD `/8`s announced by many other low ASNs (306,
  325–370, 571, 637, 668, 1208, 1540, 1563–1568, 1602) plus 27047/27064/27069/27086. An ASN-pair rule
  would miss `55.64.0.0/10` (AS347/AS370) and `214.32.0.0/11` (AS27064). Prefix rules cover more with
  fewer rows.
- **DoD space also exists as legacy `/14`–`/16`s inside ARIN-administered `/8`s**, which no `/8` rule
  reaches: observed `134.233.0.0/16`, `158.14.0.0/16`, `164.236.0.0/14`, `205.0.0.0/11`.
- **`geo_exclusions` must actually be seeded before the budget queries mean anything.** The final
  `probe_budget.sql` run reported identical totals with and without exclusions and
  `probes_avoided = NULL` — the unmistakable signature of an empty exclusion table, not of a
  no-op filter.
- **The GiST index persists but the 22-minute cost does not go away.** `index ready (0s)` on the
  second run proved the index survived; the scan still took 22m16s, so the cost is the containment
  join itself.
- **The `~14M rows` figure in `check_range_splits`'s index-build log message is wrong** —
  `ip2city_dbiplite_tbl` has 1,734,018 IPv4 rows. Cosmetic, unfixed at end of slice.
- **"4 probes per /24" is not a weak sample, it is 75% waste**, because probes 2–4 are guaranteed
  byte-identical. Correct design is a census: `probes = 2^(24 − masklen)`, 1 for `/24` or narrower.
  Because CIDR blocks are power-of-two aligned, "aligned to the beginning of the range" is just the
  complete set of `/24`s (`network + i*256`).
- **Two transient platform failures** interrupted work: "The model you've selected is experiencing a
  high volume of traffic" (request IDs `bb6f2298-5965-4119-b915-04714b5024f8` and
  `5f0651a1-921b-4fc7-9c06-705ee344fbbe`); Boris recovered by typing "Reconnect".
- **Placeholder addresses in shell commands waste a turn.** The instance handed Boris a probe loop
  containing the literal `A.B.C.$h`; ip-api returned only `{"query":"A.B.C.1"}` with no error reason
  because `fields=` had been restricted. Always substitute a real address, and do not over-restrict
  `fields` when a failure is possible.

## Boris's instructions, preferences and standing orders

- **"You are under standing orders never to guess at all. Where guessing is the only source of
  information, you must flag it. Please follow the standing orders and never digress from them."**
  Issued after the instance presented a hypothesis about his paste pipeline as a conclusion. The
  instance recorded it as a standing order and thereafter labelled inferences explicitly.
- **"Do not timeout the download at all."** Absolute, no qualifications.
- **"Do not use base64. Issue a heredoc that is immune to damage from the shell. You've done it
  previously."**
- **"You are having unusual difficulties with this task, although it's similar to others you've done
  many times previously. Please do this over, and apply strict adversarial premortem to your code."**
  This is what produced the correct `\n`-conversion diagnosis instead of more trial and error.
- **"Do not match DoD on ZIP, only on ranges or ASNs. We cannot lose Columbus, OH."**
- **"Exclude the two giant DoD subnets permanently. Best to put them in an exclusion table to be
  referenced. Minimize the computational impact of the exclusion."** He clarified he meant the DoD
  ranges behind the two-registrant-address finding, not two named CIDRs.
- **"I do not wish to collapse narrower ranges into /24s on the basis of so little evidence."**
  A clear critique of a proposed design, vindicated by the 84,986-conflict result.
- **Stated priorities for TruGeo:** accurate geographic identification at **DMA and ZIP-code level**
  only. "Changes in ownership do not concern me. Reaggregation, if it happens, does not concern me."
- **Stated architecture:** db-ip stays the baseline in `ip2city_dbiplite_tbl` (1 August edition);
  RouteViews' only job is timely indication that a db-ip range was split; current location of
  coherent ranges is established via low-latency ip-api.com.
- **Ordered pipeline shape:** import RouteViews BGP **daily**; after import run the split detector;
  identify ranges split in BGP but not in db-ip; **add those prefixes to db-ip and delete the
  superseded db-ip record**; then obtain city-level geography from ip-api.com driven off
  `ip2city_dbiplite_tbl` as currently.
- **Probe `/24` subnets aligned to the beginning of the wider range.**
- **On-base housing matters:** "On-base housing may be served by these ranges, so if we can, we
  should cover them." He accepted exclusion only once shown that ip-api has no real data for DoD
  space.
- **He insists on respecting the ip-api rate limit** the way the earlier `check_geo_ip-api` code did:
  no more than 45 queries/minute, waiting for the minute to expire.
- **He reruns things himself without the instance's limits** when he wants the full picture ("you've
  ordered only the top 30. Rerunning without that limitation").
- Pattern worth noting: he repeatedly catches unverified claims and demands the provenance of numbers
  ("Where did you find Comcast's famous /8...? They're not in the count-of-ranges per mask you had me
  output from the database").

## Open items at end of slice

- **The daily pipeline was never written.** The instance was holding for three answers before
  building it: section 6/7 output of `probe_budget.sql`, the choice between self-populating vs static
  DoD sub-`/8` exclusions, and the scheduling mechanism (systemd timer vs cron vs a wrapper script
  Boris schedules himself). Boris had answered the schema and parent-handling questions but not these.
- **`geo_exclusions` and `geo_exclusions_seed_dod.sql` were not yet run on Boris's database** — the
  budget output proves the table was empty. Nothing is actually excluded yet.
- **The `7.0.0.0/8` discrepancy is undecided.** IANA designates it ARIN-administered; Boris's BGP
  data shows AS749 originating it. The seed row is commented out awaiting his call. Its exclusion is
  worth 65,536 probes (~1 day).
- **The four observed sub-`/8` DoD blocks** (`134.233.0.0/16`, `158.14.0.0/16`, `164.236.0.0/14`,
  `205.0.0.0/11`) are commented out, pending Boris's choice between (i) self-populating detection at
  probe time on org/isp text and (ii) static seeding.
- **Section 6 of `sub24_analysis.sql`** ("sub-/24 BGP children inside flagged split ranges") was
  still running when Boris reported; its output never appears in this line range.
- **Sections 6 (tail) and 7 of `probe_budget.sql`** are cut off at line 14430. Section 7 — the count
  of flagged ranges that already contain finer db-ip rows, i.e. the safety check for the
  delete-the-parent rule — has no visible result.
- **Architectural fork left open:** at 15.2 days (986,450 probes) the job cannot finish between daily
  RouteViews imports, so the instance said the pipeline needs a persistent, resumable probe queue
  rather than a run-to-completion job. Not decided, not built.
- **The cosmetic "~14M rows" log message** in `check_range_splits` was acknowledged as wrong and left
  unfixed ("I'll fix it when I next touch that file").
- **A `-sample-n` mode** for `check_routeviews_ip-api` (geolocate N spread IPs per prefix, record
  distinct-location counts, optionally split heterogeneous prefixes into `/24`s) was offered twice
  and never built; the reframing made it moot.
- **`check_routeviews_ip-api` itself** (committed earlier as `b75815a`) has never been run by Boris
  and is now out of the pipeline. Its proposed patches (skip `/0`, optional AS749 skip,
  longest-prefix match) were dropped.
- **A proposed 1% audit** (2 probes per `/24` on a random sample, alarm on disagreement) to guard the
  intra-`/24`-uniformity assumption at 2% extra cost was suggested and not adopted either way.
- **A `recheck_splits` tool** (read `dbip_split_candidates`, probe each split range's BGP children to
  separate geographic splits from pure traffic engineering) was offered and not commissioned.

## Uncertain

- Whether `check_range_splits` was ever run with `-min-children 2 -top 0` *and* the DoD exclusions
  active: the transcript does not say, because the exclusions were never seeded within this range.
- The exact ip-api responses for the DoD probes: the transcript reports the aggregate (10/12 Columbus
  43218, 2/12 Sierra Vista 85613) and names nine `/8`s probed, but the per-IP output is not shown.
- The identity of the "two giant DoD subnets" in Boris's own mind. He clarified by quoting the
  two-location finding rather than naming CIDRs, and the instance explicitly read this as "two
  locations, not two subnets" and seeded 12 `/8`s instead. Whether Boris endorses all 12 is not
  stated in this range.
- Whether the 84,986 conflicting `/24`s are concentrated in enterprise/colo space (and are therefore
  less DMA-relevant). The instance flagged its `12.x`/`32.x` AT&T / Ashburn-Reston reading as
  inference and proposed a query; the query was not run in this range.
- Whether on-base housing is in fact served by commercial ISP ranges. Two facts were web-verified
  (privatized housing covers ~99% of US military family housing per CRS R48137; residents pay their
  own utilities per Military OneSource), but the ISP consequence was explicitly flagged as reasoning,
  not verification, and the suggested test (checking whether commercial `/24`s geolocate to ZIPs
  containing known installations) was not run.
- Why Boris's paste path converts `\n` to a newline (terminal, clipboard, chat renderer, or
  something else). The mechanism was never identified; only the workaround was. `cat -A` was offered
  as a ground-truth check but its output never appears.
- The `check_geo_ip-api` rate-limiting code Boris refers to as precedent is not shown in this line
  range, so its exact pacing implementation is unknown here.
- Whether ip-api's internal geo blocks are `/24` by design or merely appeared so in the three `/24`s
  tested. The instance stated plainly that it did not know ip-api's internal block size and that the
  measurement covers 3 `/24`s in 2 ASNs.
- The full result of the `probe_budget.sql` run (sections 6 tail and 7) and of
  `sub24_analysis.sql` section 6 — both truncated or still running at line 14430.
