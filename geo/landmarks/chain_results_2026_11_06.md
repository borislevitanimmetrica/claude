# What the chain delivered, and the number that matters

Measured 2026-11-06 after loading CCD, USFA and 20 state school directories,
migrating 121,760 rows and running the full chain on `landmarks_usa`.

## The headline is coverage, not landmarks

| | before | after | change |
|---|---|---|---|
| on-premises landmarks | 132,125 | **134,292** | **+2,167** |
| **ZIPs delivered** | 16,114 | **16,161** | **+47** |
| `lookup_status = 'true'` | 12,799,143 | 12,897,538 | +98,395 |
| rows awaiting the chain | 121,760 | **0** | done |

**121,760 new rows bought 2,167 landmarks and 47 new ZIPs.**

That is the finding, and it is the same shape as the one already recorded in
`sparse_zip_sources.md`: adding 1,460,317 rows across five sources previously
produced **6 new ZIP codes**. 47 is eight times better and still almost nothing.

The landmarks are not wasted, and the distinction matters. `node_fanout.sql`
classified **4,940 nodes as unmeasurable for having too few landmarks**, so
density inside an already-covered ZIP is exactly what those nodes need. But
anyone hoping this load would widen ZIP coverage should read the 47 and stop
hoping. New coverage has to come from somewhere else.

## Per class, with my predictions scored

| class | accepted | rdap_ok | on-premises | pct | ZIPs |
|---|---|---|---|---|---|
| overture, mixed | 13,797,786 | 11,545,623 | 119,879 | 0.87% | 15,962 |
| osm, other | 983,355 | 848,832 | 5,808 | 0.59% | 2,031 |
| foursquare, mixed | 275,517 | 209,101 | 2,191 | 0.80% | 387 |
| **school, public** | **121,891** | 111,375 | **2,004** | **1.64%** | **529** |
| wikidata, mixed | 24,721 | 21,951 | 876 | 3.54% | 582 |
| college or university | 10,788 | 9,964 | 717 | 6.65% | 347 |
| library | 14,264 | 12,814 | 674 | 4.73% | 333 |
| school, OSM tagged | 46,668 | 41,983 | 498 | 1.07% | 155 |
| **fire station** | **13,893** | 11,573 | **374** | **2.69%** | **270** |
| government, OSM tagged | 9,236 | 8,175 | 334 | 3.62% | 138 |
| place of worship | 47,280 | 39,993 | 238 | 0.50% | 123 |
| hospital | 12,222 | 10,964 | 177 | 1.45% | 84 |
| clinic | 10,537 | 9,279 | 142 | 1.35% | 67 |
| police | 2,519 | 2,231 | 126 | 5.00% | 64 |
| courthouse or prison | 2,490 | 2,191 | 79 | 3.17% | 37 |
| telecommunication | 595 | 543 | 74 | **12.44%** | 47 |
| government, municipal domain | 14,149 | 10,248 | 51 | 0.36% | 44 |
| research | 768 | 698 | 50 | 6.51% | 30 |

### Schools: I was low by 2.7 times

`school, public` went from 8,816 accepted with 54 on-premises and 26 ZIPs, which
was California alone, to **121,891 accepted with 2,004 on-premises and 529
ZIPs**. CCD and the 20 state files therefore contributed about **1,950
landmarks and 503 ZIPs**.

I predicted roughly 720 landmarks, by applying the OSM `school` rate of 1.07 per
cent. The authoritative files came in at **1.64 per cent**, half again higher. I
had said they *should* beat the OSM rate because they are one row per
institution rather than per building, and then declined to put a number on the
improvement. The number was 1.5x on rate and 2.7x on the count.

### Fire: that prediction held

`fire station` went from 5,208 accepted with 146 on-premises and 62 ZIPs, which
was OSM alone, to **13,893 accepted with 374 and 270 ZIPs**. USFA contributed
about **228 landmarks and 208 ZIPs**.

I predicted 243 landmarks and roughly 200 ZIPs. Both within about 6 per cent.
Worth recording, since most of my predictions this session have not been.

### telecommunication is still the best rate in the corpus

12.44 per cent, on 595 rows. The `category_yield` finding stands: rural ILECs
and telephone cooperatives are the highest-yielding institution class measured,
and the FCC Form 499 filer database remains the unexplored route to a complete
list of them.

## Two side-effects of re-running the chain, both worth knowing

**The chain is not purely additive.** Overture's `rdap_ok` fell from 11,557,298
to 11,545,623, a loss of **11,675 rows**, and its on-premises count fell by 11.
The resolve step reported "does not resolve: 10,245 rows". Hosts that resolved
on an earlier run no longer do. At 0.1 per cent of the Overture corpus this is
not alarming, but a full chain run can take rows away as well as add them, and
nothing in the tooling says so.

**The locality fallback was never broken.** I flagged it as a defect when
`dotgov` showed only 2,312 of 11,474 resolved rows with a ZIP. After this run
`overture_zip_source = 'locality'` holds **13,286** rows. It had simply never
been re-run after more locality evidence accumulated. `dotgov` itself still sits
at 51 on-premises and 44 ZIPs, so the fallback working does not rescue
municipalities, but the diagnosis was wrong.

**And the two hosting-rule counts were never in conflict.** `migrate_new_sources`
reported 243,716 rows carrying a `hosting:` reason; the onpremises step reported
97,043. Reading `ovt_resolve_hosts.py` lines 1353 to 1356, the step counts only
rows that also have `lookup_status = 'true'`, which is the candidate set it
would otherwise touch. The other 146,673 are not candidates, so the guard is
sufficient. Both numbers are right and they measure different things.

**One small unexplained residual:** the ledger counts 134,292 on-premises and
the chain's own summary counted 134,243, a difference of 49. Those are rows with
`onpremises = true` and `lookup_status` something other than `'true'`. Harmless,
and noted so it is not rediscovered as a bug.

## RESOLVED: the demand table holds ip-api lookups, not traceroutes

`demand_trace_forensics.sql`, 2026-11-06. The hypothesis is confirmed and the
column that settles it is `probe_method`:

| probe_method | status | rows |
|---|---|---|
| **ip-api** | success | 72,748 |
| **ip-api** | error | 7 |

All 72,755 rows. The 7 errors carry a `classification_note` reading
`Get "http://ip-api.com/json/..." : context deadline exceeded`, which is an
HTTP timeout against ip-api, not a traceroute failure.

What is populated, and what is not:

| column | populated |
|---|---|
| `hop_count` | 72,755 |
| `attempts` | 72,755 |
| `probe_method` | 72,755 |
| `city` | 72,746 |
| `lat` | 72,748 |
| `isp` | 72,708 |
| `org` | 71,642 |
| `zip` | 65,621 |
| `as` | 63,510 |
| **`last_hop_ip`** | **0** |
| **`last_hop_hostname`** | **0** |
| **`last_hop_number`** | **0** |
| `city_target` | 0 |

So the ip-api side is nearly complete and the traceroute side is entirely
empty. `hop_count` being populated on all 72,755 is the one oddity left: an
ip-api lookup has no hops, so whatever value it holds is not a hop count.

**NO TRACEROUTE HAS EVER RUN ON THE DEMAND SIDE.** The table name says
traceroute and its contents are an ip-api cache. That is the whole explanation
for the status vocabulary differing, for the empty addresses, and for the
August-to-September dates.

For contrast, here is what a real trace looks like, from the supply table:

| status | rows | have_last_hop_ip | have_hostname |
|---|---|---|---|
| reached | 21,314 | 21,314 | 21,314 |
| excluded-internal | 6,058 | 6,058 | 6,030 |
| reached-unnamed | 1,959 | 1,959 | **0** |
| unreachable | 835 | 835 | 835 |
| incomplete | 59 | 0 | 0 |
| excluded-mil | 1 | 1 | 1 |

`reached-unnamed` having addresses and no hostnames is by design: it is the
classifier's fallback to the first hop with no reverse DNS at all.

### What that costs

The demand side is a measurement campaign, not a backfill. The floor is the
**72,755 ranges already probed**; the ceiling is the probe estate at
**2,097,870 ranges**. The supply side's 30,226 traces ran 2026-10-25 to
2026-10-31, so six days for 30,226 is the only throughput figure available, and
I have not confirmed what limited it.

Against that cost sits the Hoiho result: **74.8 per cent of supply-side
hostnames are already decodable**, and the demand side is the one that answers
where a customer range's serving node sits. Whether 72,755 traces are worth it
is Boris's call, and it is now a priced decision rather than an open question.

## What the demand side looked like before this was resolved

`demand_hostname_backfill.sql` was written to distinguish two cases. Neither
holds.

| | value |
|---|---|
| rows | 72,755 |
| status `success` | 72,748 |
| status `error` | 7 |
| **have_last_hop_ip** | **0** |
| have_hostname | 0 |
| distinct node addresses | 0 |
| runs | 2026-08-30 to 2026-09-08 |

It is not that the names are missing. **The last hop address is missing too, on
every row, while the status says `success` on 72,748 of them.** A reverse-DNS
backfill is impossible because there is nothing to reverse.

The status vocabulary differs between the two tables, which is itself evidence:
`ovt_places_usa_ip_trace` uses `reached` and this one uses `success`. Same
writer in `geo/main.go`, so either the vocabulary changed between runs or these
rows came from a different code path that reuses the table.

I do not know which, and `demand_trace_forensics.sql` settles it without
guessing. `hop_count` separates the cases cleanly: populated means a trace ran
and the classifier found no usable carrier hop, which is a code problem;
NULL means no trace ran, which is a measurement campaign over 72,755 ranges.
`probe_method` and `classification_note` name the writer directly.

That matters because the Hoiho result makes the demand side the prize:
**74.8 per cent of supply-side hostnames are already decodable**, and the demand
side is 2.4 times larger and is the one that actually answers where a customer
range's serving node sits.
