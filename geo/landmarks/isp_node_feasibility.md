# ISP-named nodes with ZIP codes: feasibility

Assessed 2026-11-06 against the two sources named: CAIDA ITDK and OSM telecom
tagging. Everything below is measured from the live data, not from the catalogue
pages.

## Verdict

**The ITDK node files are not worth downloading. Its 212 KB ruleset is, and it
works on data this project already holds.**

**The premise cannot be tested as stated.** "The distribution node for a
customer /24 is usually in the same ZIP or an adjacent one" needs the node's
ZIP. CAIDA's geolocation is at city granularity, stated in the README and
confirmed by the data. A city spans many ZIPs, so the comparison cannot be made.

**One exception is worth chasing: CLLI.** 89 of the 871 suffixes encode a CLLI
code, which names a specific building rather than a city, and they are precisely
the big consumer ISPs where the uncovered demand sits. The step from a CLLI code
to a ZIP has no public source I could verify, and that is the blocker.

**OSM central offices are dead**, and worse than the caveat feared.

## ITDK, measured

Open HTTP at `publicdata.caida.org`, no gate, no request form. Latest release
**2025-08**. The inventory:

| size | file | relevance |
|---|---|---|
| 17 K | `README.txt` | formats and method |
| **212 K** | `midar-iff-snmp-tnt.geo-re.jsonl.bz2` | **the asset** |
| 314 M | `midar-iff-snmp-tnt.nodes.geo.bz2` | node locations, 96 pct MaxMind |
| 43 M | `v4-dns-names.txt.bz2` | PTR for every observed interface |
| 171 M | `midar-iff-snmp-tnt.nodes.as.bz2` | node to AS |
| 1.1 G | `midar-iff-snmp-tnt.ifaces.bz2` | interfaces |
| 1.4 G | `midar-iff-snmp-tnt.links.bz2` | links |

`.nodes.geo` format, from README line 276:

`node.geo <node_id>: <continent> <country> <region> <city> <lat> <lon> <method>`

README line 158 states the location is **"at city granularity"**.

### 96 per cent of it is MaxMind

I downloaded 60 MB of the 314 MB file and decompressed the prefix: 609 MB,
9,547,289 lines, of which **7,422,388 parsed `node.geo` rows**. That is roughly
a fifth of the file and a large enough sample to settle the question.

| method | rows | share |
|---|---|---|
| **maxmind** | 7,267,551 | **97.9%** |
| **hoiho** | 139,303 | **1.9%** |
| named exchange points | about 5,000 | 0.1% |

Restricted to the US, 1,728,359 rows or 23.3 per cent of the sample:

| method | rows | share of US |
|---|---|---|
| maxmind | 1,657,182 | **95.9%** |
| **hoiho** | **71,177** | **4.1%** |

Scaled to the whole file that is of order 350,000 US interfaces with a
hostname-derived location. The MaxMind signature is visible in the top US
cities: Boydton VA, Ashburn VA, Des Moines IA and Washington VA are datacentre
placements, not places where routers serving subscribers sit.

**So the node files mostly restate a commercial IP-geo estimate.** This project
already has db-ip and ip-api, which are the same class of product with the same
failure mode Boris described: the location is the aggregation node or the
datacentre, not the customer. Paying 314 MB and a decompression to acquire
another copy of that is not worth doing.

## The 212 KB ruleset is the real find

`midar-iff-snmp-tnt.geo-re.jsonl.bz2` decompresses to 2,306,906 bytes,
**871 lines, one per DNS suffix**. Each carries the learned regexes, a score
block and the geohints that map a token to a place. Scored by CAIDA as
**767 good and 104 promising**.

Hint types across the 871 suffixes:

| hint type | suffixes | granularity |
|---|---|---|
| `iata` | 476 | airport code, **city** |
| `place` | 323 | place name, **city** |
| **`clli`** | **89** | CLLI code, **building** |
| `locode` | 12 | UN/LOCODE, city |
| `facility` | 2 | facility |

### It covers the exact ISPs at the top of the uncovered queue

Session 4 measured the uncovered demand as Verizon Business 2,431 ZIPs,
Comcast 2,137, Cogent 1,545, Level 3 900. All four are in the ruleset:

| suffix | class | ppv | routers | hints |
|---|---|---|---|---|
| comcast.net | good | **0.999** | 255,906 | clli, facility, place |
| windstream.net | good | 0.997 | 16,956 | **clli** |
| frontiernet.net | good | 0.990 | 15,357 | **clli** |
| level3.net | good | 0.995 | 14,933 | place |
| charter.com | good | 0.998 | 10,997 | **clli**, iata |
| comcastbusiness.net | good | **1.000** | 9,328 | place |
| verizon.net | good | 0.999 | 7,985 | **clli** |
| alter.net (Verizon Business) | good | 0.991 | 7,303 | **clli**, iata, place |
| cogentco.com | good | 0.995 | 7,236 | iata |
| qwest.net | good | 0.957 | 5,642 | iata |
| sbcglobal.net | good | 0.965 | 5,624 | **clli** |
| zayo.com | good | 0.989 | 5,335 | iata |
| googlefiber.net | good | 0.968 | 28,374 | iata |

Not in the ruleset, of the 24 US suffixes I checked: `att.net`,
`spectrum.com`, `centurylink.net`, `cox.net`, `optonline.net`,
`sparklight.net`, `mediacomcc.com`. 17 of 24 covered.

### It independently confirms this project's own finding

`zip_granularity_findings.md` recorded, from a hand investigation, that AT&T
publishes `lightspeed.btrgla.sbcglobal.net` and that `btrgla` is AT&T's token
for Baton Rouge LA, and recommended "Evaluate reverse DNS as a third source. It
is free and unmetered, and it already caught an ip-api error spanning two
states."

`sbcglobal.net` appears above with **`clli` hints at ppv 0.965**. `BTRG` plus
`LA` is the place-and-state prefix of a CLLI code. The project measured one case
by hand; CAIDA has generalised the same thing to 89 suffixes with precision
scores attached. That recommendation has been sitting unexecuted and this is the
cheapest possible way to execute it.

## OSM telecom tagging: dead, and by a wide margin

Measured from the OSM taginfo API, worldwide counts:

| tag | objects **worldwide** |
|---|---|
| `telecom=central_office` | **61** |
| key `clli` | **1,275** |
| key `ref:clli` | 0 |
| `telecom=exchange` | 25,681 |
| `telecom=connection_point` | 26,200 |
| `telecom=distribution_point` | 1,170 |

Against roughly 20,000 to 25,000 US wire centres, **61 central offices
worldwide** is not a source. `clli` at 1,275 worldwide is not either. Boris's
caveat was that the tagging might cover telephony rather than internet; the
actual problem is that it barely exists.

`telecom=exchange` at 25,681 is the only count with any size, but OSM telecom
mapping is concentrated in Europe and **the US share is unmeasured**: Overpass
was unreachable from the sandbox that produced this assessment, over three
mirrors and both IP families. That number needs checking from your machine,
which reached Overpass successfully for the 1,139,855-row national load.

And one thing that is certain: **your existing OSM load cannot contain central
offices.** The Overpass query was

```
nwr["website"]["addr:postcode"](area.a);
```

A central office has neither a website nor a postcode tag, so none were ever
fetched. Any attempt at this needs a fresh fetch with different filters.

## You already have the input, which is the point

No ITDK node file is needed, because the hostnames are already here:

| table | column |
|---|---|
| `ovt_places_usa_ip_trace` | `last_hop_hostname`, and there is an index on it |
| `ip2city_dbiplite_traceroute_tbl` | `last_hop_hostname` |

So the ruleset applies to the supply side, the node adjacent to a landmark, and
to the demand side, the node adjacent to a probed range. `hoiho_suffixes.sql`
loads the 871 suffixes and `carrier_node_hoiho_test.sql` answers the prior
question: what share of our own hostnames the ruleset can speak to. If that
share is small, none of the rest matters.

## What this is good for even at city granularity

Two things, and neither needs the ZIP step to work.

**Catching ip-api's error mode.** Boris's own description is that ip-api reports
a location that is often the aggregation node several miles away, "frequently in
a completely different demographic and socioeconomic area". Where the Hoiho city
for the carrier node disagrees with ip-api's city for the range, that is a flag,
and in the one head-to-head the project has run, PTR won: AT&T said Baton Rouge
for every address ip-api placed in Jackson, Mississippi, 141 miles and two
states away.

**The DMA tier.** `zip_granularity_findings.md` says the DMA tier is "untouched,
because DMA resolves through city". City-accurate node location is therefore
directly usable for DMA even though it is too coarse for ZIP.

## What would make the ZIP step work, and what I could not verify

The chain is `hostname` to `CLLI code` to `street address` to `ZIP`. The first
step is solved for 89 suffixes with published precision. The second step is the
gap.

The authoritative CLLI-to-address table is the **LERG**, which is proprietary to
iconectiv. I have **not** verified any public substitute. Candidates I am naming
as unverified leads rather than recommendations: the NANPA central-office code
assignments, which give an operating company and a rate centre but at rate-centre
granularity rather than building; third-party sites that republish LERG-derived
switch data; and the 1,275 OSM `clli` objects, which are too few to matter.

If a CLLI-to-ZIP table were obtained, Boris's premise becomes testable directly,
and the test is cheap: for every probed /24 whose carrier node hostname decodes
to a CLLI, compare the CLLI's ZIP with the range's ip-api ZIP and count
same-ZIP, adjacent-ZIP and neither. That is the experiment this whole assessment
is a prerequisite for.

## RESULT: the test ran, 2026-11-06

**Supply side coverage is 74.8 per cent, which is far better than I would have
guessed, and the demand side has no hostnames at all.**

| | value |
|---|---|
| supply trace rows | 30,226, of which 21,314 reached |
| with a hostname | 28,180 |
| distinct hostnames | 7,592 |
| distinct node addresses | 8,539 |
| **Hoiho-covered hostnames** | **5,680 of 7,591, 74.8 pct** |
| of those, `good` class | 5,501 |
| **covered by rules whose hints include CLLI** | **3,169** |
| covered by city-only hints | 4,812 |

What explains our data, by traces:

| suffix | ppv | hints | distinct hostnames | traces |
|---|---|---|---|---|
| cogentco.com | 0.995 | iata | 614 | 3,881 |
| alter.net | 0.991 | clli, iata, place | 195 | 2,364 |
| comcast.net | 0.999 | clli, facility, place | 1,099 | 2,321 |
| charter.com | 0.998 | clli, iata | 870 | 1,896 |
| gtt.net | 0.985 | iata | 40 | 1,864 |
| zayo.com | 0.989 | iata | 341 | 1,783 |
| verizon-gni.net | 0.977 | clli | 349 | 1,305 |
| level3.net | 0.995 | place | 417 | 1,174 |
| he.net | 0.995 | iata | 137 | 1,096 |
| lumen.tech | 0.946 | place | 171 | 959 |

The gap is small and concentrated enough to close by hand. Uncovered, by
traces: `twelve99-cust.net` 1,027, `cox.net` 216, `hostasaurus.com` 193,
`uniti.net` 158, `twelve99.net` 116, `as701.net` 96, `att.net` 81,
`spectrum.com` 62. One rule for Arelion's customer-facing suffix is the single
biggest win available.

### The demand side has zero hostnames, and that is the actionable finding

`ip2city_dbiplite_traceroute_tbl`: **72,755 rows, 0 with a hostname.** It is
2.4 times the supply corpus and it is the side that matters more, because it is
the node serving a probed customer range, which is exactly what the premise is
about.

**This is not a limitation of the approach.** `geo/main.go` writes both tables
from the same code path: `reverseDNS` at line 1310 does a `LookupAddr` with a
3-second timeout, and `writeResult` at line 1325 inserts `last_hop_hostname`
into the demand table exactly as line 1377 does for the supply table. The
capability is there and the column is empty.

I do not know why and will not guess. `demand_hostname_backfill.sql` settles it
in one query, because the answer determines the response: if `last_hop_ip` is
populated and only the names are missing, this is a reverse-DNS backfill over at
most 72,755 addresses, which is free and takes minutes. If `last_hop_ip` is also
empty, the traces never reached a node and the fix is re-running traceroute,
which is a different order of cost.

## Recommended order, updated

1. ~~Run `hoiho_suffixes.sql` then `carrier_node_hoiho_test.sql`~~ **done.
   74.8 per cent supply coverage, 3,169 hostnames under CLLI-hint rules.**
2. **Run `demand_hostname_backfill.sql`.** One query, and it decides whether
   the demand side is a free backfill or a re-trace. This is now the top item.
3. **Write one rule for `twelve99-cust.net`**, 1,027 traces and the largest
   single uncovered operator.
4. **Apply the rules to the supply side**, where the answer is checkable: a
   landmark's ZIP is known, so a decoded node city can be compared against the
   landmark's own city. That measures the ruleset's real accuracy on our data
   rather than trusting CAIDA's ppv.
5. **Settle the OSM `telecom=exchange` US count from your machine**, since
   Overpass is reachable there and it is a two-minute query.
6. **Do not download the ITDK node files.** 96 per cent MaxMind.
7. **Treat CLLI-to-ZIP as a procurement question, not an engineering one**, and
   decide whether it is worth paying for LERG access. Everything upstream of it
   is free and now measured.
