# What the onpremises audit found

Run 2026-11-06. Answers Boris's challenge: "review the sources, review by
sampling the onpremises conclusions".

## 1. There is no bug. The chain does exactly what it documents.

The SQL mirror of the rule agreed with the stored column on every one of the
95,425 audited rows:

| stored | derived | rows | of which hosting rule |
|---|---|---|---|
| false | false | 83,219 | 240 |
| NULL | NULL | 9,465 | 0 |
| true | true | 2,418 | 699 |
| false | NULL | 323 | **323** |

The only divergence is 323 rows, and all 323 are the hosting rule correctly
overriding a NULL. So `onpremises` is a faithful implementation of the rule.
The low rates are not a defect in the code.

## 2. Rule 2 is doing it, and rule 2 is right

Share of each category rejected because a registrant is a CDN, cloud or web
host:

| category | rule 2 rejections | of rows | share |
|---|---|---|---|
| school | 39,574 | 46,668 | **85%** |
| hospital | 8,785 | 12,222 | 72% |
| police | 1,735 | 2,519 | 69% |
| library | 9,766 | 14,264 | 68% |
| government | 4,496 | 6,571 | 68% |
| telecommunication | 401 | 595 | 67% |
| university | 1,431 | 2,217 | 65% |

The sampled rows show the rejections are correct, not spurious. Universities:
Kennesaw State on Microsoft, Columbia SIPA on Cloudflare, Stephens College and
Saint Lawrence and Massachusetts Maritime on Pantheon, Central Washington and
University of the West on Amazon, SUNY Sullivan on Google. Hospitals: Cloudflare
2,683 rows, Microsoft 1,029, Amazon 1,249 across two entities, Akamai 606,
WPEngine 583, Vercel 494, Pantheon 398.

**Boris's expectation that universities should be near 100 per cent conflates two
different things, and the data separates them.** A university runs its own
campus network and usually holds its own allocation. It no longer serves its
public web site from that network. Those are independent facts and the landmark
method depends on the second one.

So the answer to "an 11.64 per cent onpremises rate sounds completely and
obviously false" is that the rate is true and the inference from it was mine to
make clearly and I did not: it measures where the WEBSITE is served from, not
whether the institution has a network.

## 3. telecommunication explained, and it hides a good source

Boris expected this category near 100 per cent. It is 12.44 per cent, and the
reason is what the rows are. Akamai is registrant for 199 of 595, and the
sampled names are `Spectrum`, `Xfinity`, `Xfinity Store`, `Astound Broadband`:
these are OSM-tagged RETAIL STOREFRONTS whose website tag is the national
corporate site, served from a CDN. The storefront is in the right ZIP and the
web site is in Massachusetts.

The rows that are genuinely local carriers pass, nearly all of them:

| name | registrant | rule |
|---|---|---|
| Endeavor Communications | Endeavor Communications | 3 every registrant is an ISP |
| West Central | West Central Telephone Assn | 3 |
| Vermont Telephone Company | Vermont Telephone Company | 3 |
| Ovation Networks Inc | Ovation Networks | 5 adjacent ZIP |
| AT&T | AT&T Services, Inc. | 3 |

**So rural telephone cooperatives and independent ILECs are a near-100 per cent
landmark class, and they sit in exactly the rural ZIPs the corpus is short of.**

And they do not need a website at all, which is the structural point. For an
ILEC the RDAP registrant IS the company and the allocation IS at its own
premises. So a list of rural carriers with their ZIPs can be joined to
`rdap_registrant_tbl` on the registrant NAME, skipping resolve, skipping the
website, and skipping any exposure to rule 2.

**The ZIP has to come from the external list, not from the RDAP table.** I
checked the schema rather than assuming it, having already shipped one guessed
column name in this project: `rdap_registrant_tbl.sql` lines 47 to 72 are
`start_ip`, `end_ip`, `registrant`, `registrant_role`, `handle`,
`network_name`, `rir`, `queried_for`, `http_status`, `note`, `fetched_at`. There
is no address or ZIP field. The registrant ZIP exists only in
`landmarks_usa.registrant_1_zip`, written per landmark address by the
`registrants` step.

Verified available: the **FCC Form 499 Filer Database** identifies every
interstate telecommunications carrier and interconnected VoIP provider, with
company business names and primary addresses, and has a documented API at
`apps.fcc.gov/cgb/form499`. Addresses, not websites, which for this route is
what is wanted. NOT yet verified: the row count, whether the ZIP is a separate
field, and whether the API still answers. That is the next check and I have not
done it.

A cheaper version needs no external list at all. Where an organisation
registrant already appears as `registrant_1` on any landmark,
`registrant_1_zip` gives its ZIP for free. Section 4 of
`registrant_landmarks.sql` counts how many of the cache's organisation
registrants are already known that way.

## 4. Rule 6b is not a near-miss problem. That hypothesis is dead.

I suggested `zip_adjacency` might be too narrow. Measured, on rows rejected by
6b, numeric ZIP distance between landmark and registrant:

| category | rejected 6b | within 5 | 6 to 20 | over 20 |
|---|---|---|---|---|
| library | 2,309 | 52 | 121 | **2,136** |
| hospital | 1,939 | 17 | 44 | **1,878** |
| school | 1,816 | 77 | 108 | **1,631** |
| university | 399 | 12 | 14 | **373** |

Widening adjacency would recover a few hundred rows across all categories.
Not worth doing. Numeric ZIP distance is a weak proxy and this is only strong
enough to kill the idea, which is all it was for.

### But 6b contains something that IS worth having

The sampled 6b rows are frequently the institution's OWN registrant at a
different campus or headquarters ZIP:

| landmark | landmark ZIP | registrant | registrant ZIP |
|---|---|---|---|
| University of Hawaii Hilo | 96720 | University of Hawaii | 96822 |
| University of Connecticut School of Law | 06105 | University of Connecticut | 06269 |
| Texas A&M Kingsville Citrus Center | 78599 | Texas A&M University | 77843 |
| Mayo Clinic Health System Springfield | 56087 | Mayo Foundation | 55905 |
| Spaulding Rehabilitation Hospital | 02537 | Mass General Brigham | 02115 |

These are genuinely on-premises addresses. They are at the WRONG premises for
the landmark's ZIP, which is why 6b rejects them, and that is correct. But the
address is still a real landmark FOR THE REGISTRANT'S OWN ZIP, and it is
currently discarded entirely.

Proposal, not a change: for 6b rows where the registrant is neither a provider
nor an ISP, emit the landmark at the REGISTRANT's ZIP rather than dropping it.
`registrant_landmarks.sql` sizes that set. This is a design decision about which
ZIP a landmark anchors to and it is Boris's to make, not mine.

## 5. RDAP: the marginal rate is 234 candidates per query, and I had it backwards

Measured by the /23 sample run plus a full recount:

| | before | after |
|---|---|---|
| cache allocations | 1,065 | 1,456 |
| candidates covered | 30,011 | **113,546** |
| still to resolve | 251,940 | **168,405** |
| per cent covered | 10.6 | **40.3** |

357 queries bought **83,535 newly covered candidates**, which is **234 per
query**.

My reasoning was wrong in a specific, checkable way. I argued that narrow
candidates buy less because "a /23 is narrow, so each query buys only itself".
The candidate's width does not bound the allocation's width. The run log shows
/23 queries returning `covers=262144 addresses` for Level 3 and CenturyLink, a
/14, which blankets thousands of narrower candidates at once.

**Projection, with the same caveat that the rate will decay:** at 234 per query
the remaining 168,405 needs about **720 queries, roughly twelve minutes** at one
per second. At a tenth of that rate it is about 7,300 queries and under two
hours. Either way the earlier spread of ten hours to seventy days was wrong at
both ends, and the fill is close to done rather than years away.

The next bounded batch settles it. Draw a fresh /23 sample, because the current
`rdap_fill_sample_tbl` has already been queried.

## 6. MX and NS: the denominator is 6.2 million, so build it

The 2026-11-06 run measured **2.80 per cent** newly qualifying, 56 of 2,000
distinct rejected hosts. NS contributed 45 of the 56, 42 of those by rule 3a.

The denominator, measured: **6,206,979 distinct rejected hosts.**

2.80 per cent of that is about **173,800 hosts** that would newly qualify. The
whole corpus holds **132,125** on-premises rows today. So the MX and NS path is
not a marginal addition, it is larger than everything currently in the table.

A 56-of-2,000 proportion has a 95 per cent interval of roughly 2.1 to 3.6 per
cent, so the range is about 130,000 to 223,000. It does not change the
conclusion.

**I was wrong to recommend against building this, twice.** First I predicted one
to two per cent from the fire corpus and called it dead; the real figure landed
at the top of my own band. Then I withdrew the recommendation but still framed
it as pending. It is not pending. 174,000 against 132,125 is the single
highest-value item on the list, ahead of CCD and USFA by two orders of
magnitude, and the instrument already exists: `mx_ns_yield.py` does the
measurement and the write path is the same chain.

## 7. Loading CCD and USFA needs no new code

Both are already implemented and neither had ever been run.

CCD is entry `CCD` in `states.json`, loaded by `state_loader.py`. Dry run
verified 2026-11-06 against the live file:

| | |
|---|---|
| fetched | 12,624,979 bytes, 65 columns, 102,274 data rows |
| name, ZIP, website, status columns | `SCH_NAME`, `LZIP`, `WEBSITE`, `SY_STATUS_TEXT` |
| skipped, no website | 32,003 |
| skipped, not operating | 2,643 |
| skipped, unusable website | 190 |
| **usable** | **67,438**, and the accounting balances |
| distinct ZIPs | 16,771 |
| distinct hosts | 29,935, of which 26,952 serve one ZIP |
| rows on a shared host | 28,393, 42.1 per cent, the expected waste |

USFA is `lm_fetch.py usfa-fire`, dry run still reporting 8,685 usable in 7,418
ZIPs on 8,408 hosts.

**Expected yield, stated before the load rather than after.** At the measured
OSM `school` rate of 1.07 per cent, CCD's 67,438 rows give roughly 720
on-premises landmarks. At the `fire_station` rate of 2.80 per cent, USFA's 8,685
give roughly 243. Both should beat those rates, because CCD and USFA are
authoritative single-row-per-institution files while the OSM rows include
buildings, campuses and duplicates, but I am not going to put a number on the
improvement. Together: of order a thousand landmarks, not tens of thousands.

Load them anyway. They are minutes of work, they are the authoritative sources,
and their ZIPs are rural where the corpus is thinnest. But the honest ranking
puts them well behind the MX and NS path.

## 8. Getting all the schools

Boris: 129,000 to 133,000 K-12 schools, of which almost 100,000 public.

| set | source | count | website? |
|---|---|---|---|
| public, all | NCES CCD 2023-24 | 102,274 rows, 99,596 open | 67,438 usable, so **68 per cent** |
| public, website gap | the 21 state directories in `states.json` | TX 7,307, PA 4,387, MN 4,152, AL 4,029, FL 3,700, IL 3,599, AZ 3,565 and 14 more | yes, and they often carry one where CCD does not |
| private | NCES PSS 2023-24 | 22,510 | **none**, verified in the file and on the locator pages |
| private, partial | OSM `amenity=school` | 46,668 rows already loaded | yes |

So public schools are essentially solved: CCD is the complete universe and the
state files close part of its 32,003-row website gap. Session 4 measured the
CCD-plus-state-files union at **19,411 ZIPs** against CCD's 16,771 alone.

Private schools are the real gap. PSS has every one of them with an
authoritative ZIP and no URL anywhere. The only website sources for them are OSM
and a name-plus-ZIP join from PSS to OSM, which is an option worth sizing and
has not been sized.
