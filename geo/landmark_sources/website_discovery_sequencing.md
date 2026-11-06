# Website discovery: why it does not make sense to build

Decided 2026-11-03. The conclusion is not "we have enough landmarks" — we do
not, and that is the point. It is that discovery solves the wrong half of the
problem, and the half it solves was never the binding constraint.

## The argument in one paragraph

A landmark needs a hostname whose **address sits at the organisation's own
premises**. Finding an institution's website gets you a hostname. For the
registries that lack one — 22,510 private schools in NCES PSS, the IMLS library
outlets, every police agency in the FBI's file — a large majority of those
hostnames will resolve into one of exactly two places, and **both of them fail**:

- **A hosting provider.** Squarespace, Wix, GoDaddy, CivicPlus, AWS. Rule 2
  rejects these, and correctly: the registrant ZIP is the host's, not the
  institution's.
- **A higher level of government.** The school district's data centre, the
  county's web server, the state's. These *are* on premises, and that is why
  they are worse than useless: the premises belong to the county, so the
  landmark places fifty institutions in fifty ZIPs at one building.
  `node_fanout.sql` sees the disjoint ZIP clusters and throws the address away,
  after it has cost resolve, RDAP and trace budget.

Discovery cannot distinguish these in advance. It finds a URL; the chain then
discards most of what it finds, for structural reasons that no better search
would change.

## The measured basis, from this project's own numbers

**Rule 2's share.** Over 12,775,630 rows the on-premises step rejects
**10,713,526, which is 83.8 per cent**, because the address belongs to a CDN,
cloud or web host. That is recorded in `mx_ns_yield.py`.

**Diminishing returns on organisations.** Adding 1,460,317 rows across five
landmark sources produced **6 new ZIP codes**.

**The per-source rates, from `lm_fetch.py status` on 2026-11-03.** This is the
table that settles it:

| source | rows | onpremises true | rate | ZIPs delivered |
|---|---|---|---|---|
| nces_ipeds, colleges | 6,075 | 328 | **5.40%** | 312 |
| wikidata | 24,721 | 876 | 3.54% | 582 |
| overture | 13,797,786 | 119,890 | 0.87% | 15,962 |
| foursquare | 275,517 | 2,191 | 0.80% | 387 |
| osm | 1,139,855 | 8,735 | 0.77% | 2,755 |
| ca_cde, California schools | 8,816 | 54 | **0.61%** | 26 |
| dotgov, municipalities | 14,149 | 51 | **0.36%** | 44 |

### One defect visible in that table, worth fixing before judging dotgov

`dotgov` resolved 11,474 rows and got RDAP for 10,248, but **only 2,312 have a
ZIP**. The file carries no postcode by design and the `overture-zip` locality
fallback was supposed to supply one; it failed for roughly 80 per cent of the
rows. So `dotgov`'s 0.36 per cent is measured against 14,149 rows of which only
2,312 could ever have been decided, and 7,936 rows reached RDAP and were then
discarded for want of a ZIP, not for want of being on premises.

Against the 2,312 that had a ZIP the rate is 2.2 per cent, which is six times
the headline and middling rather than terrible. The locality fallback is worth
a look before anyone concludes municipalities are a dead end.

Read the bottom two rows against the top one. **Colleges deliver fifteen times
the rate of municipalities and nine times the rate of California schools.** The
reason is the argument above: a university runs its own campus network and often
its own allocation. A California school publishes its district's website, and a
small town publishes CivicPlus.

Private schools, public libraries and police stations are the same kind of
organisation as the bottom two rows, not the top one. `ca_cde` is the honest
prior: **8,816 schools whose websites we already had, delivering 54 landmarks
and 26 ZIPs.**

## What discovery would cost against that

PSS 22,510 plus the IMLS outlets plus the FBI's police agencies is roughly
56,000 institutions. On the `ca_cde` rate that is about **340 landmarks**. On
the `nces_ipeds` rate, which is the optimistic end and the wrong analogue, about
3,000.

And discovery is not free, which is the second finding.

## Discovery cannot be done cheaply either

I tested the cheapest possible mechanism against **ground truth**: the fire
registry gives 8,685 institutions whose real website we already know, so recall
is exact rather than estimated. From name, city and state, generate plausible
registrable domains (`fd`, `vfd`, `firedept`, `firerescue`, joined core words,
initials, across `.org .com .net .us`) and check for an A record. 300
institutions, 13,036 candidates, 43 per institution.

| result | count | share |
|---|---|---|
| true domain among the live candidates | 106 | **35.3%** |
| true domain was the **only** live candidate | 3 | **1.0%** |
| 6 or more live false candidates | 151 | 50.3% |

Parked and squatted domains resolve, so an A record is nearly useless as a
filter. The median institution returned five or six live candidates with no way
to choose.

The misses say why, and they say it better than the numbers:

| the real website | the institution |
|---|---|
| `www.storeycounty.org` | Storey County Fire Department |
| `www.gilbertaz.gov` | Gilbert Fire and Rescue Department |
| `www.cityofknoxville.org` | City of Knoxville Fire Department |
| `townofstratford.com` | Stratford Fire Department |
| `ci.orange.nj.us` | City of Orange Township Fire Department |

The institution has **no domain of its own**. It is a page on the
municipality's site — and `lm_fetch.py dotgov` already loads those 14,149
municipal domains, at a measured 0.36 per cent. Discovery would spend a search
API to rediscover the worst-performing source in the corpus.

So: discovery needs a paid search index, and what it would find is mostly
already loaded or structurally rejected. **Do not build it.**

## This is not an argument for fewer landmarks

We are short of landmarks and the shortage is the project's central problem.
`node_fanout.sql` calls **4,940 nodes unmeasurable for having too few**. The
conclusion here is narrow: stop trying to manufacture hostnames for institutions
that do not have their own, and spend the effort where the measured rate is
high.

**Chase the organisations that run their own network, not the ones that run
their own building.** That criterion is now measured rather than argued.
`category_yield.sql` ran on 2026-11-03 against the 1,037,757 OSM rows that
carry a category, across 2,452 distinct categories. The institution categories,
ranked by ZIPs actually delivered:

| category | rows | onpremises | rate | **ZIPs delivered** |
|---|---|---|---|---|
| **library** | 14,264 | 674 | 4.73% | **333** |
| school | 46,668 | 498 | 1.07% | 155 |
| university | 2,217 | 258 | **11.64%** | 131 |
| place_of_worship | 47,280 | 238 | 0.50% | 123 |
| government | 6,571 | 282 | 4.29% | 114 |
| museum | 8,232 | 180 | 2.19% | 99 |
| hospital | 12,222 | 177 | 1.45% | 84 |
| college | 2,496 | 131 | 5.25% | 64 |
| police | 2,519 | 126 | 5.00% | 64 |
| fire_station | 5,208 | 146 | 2.80% | 62 |
| telecommunication | 595 | 74 | **12.44%** | 47 |
| courthouse | 1,003 | 40 | 3.99% | 21 |
| research | 460 | 33 | 7.17% | 20 |
| prison | 1,487 | 39 | 2.62% | 18 |
| townhall | 2,665 | 52 | 1.95% | 28 |

`telecommunication` at 12.44 per cent and `university` at 11.64 per cent confirm
the criterion exactly: both are organisations whose business IS the network.
`place_of_worship` at 0.50 per cent across 47,280 rows confirms the converse.

**Libraries are the headline and they contradict an existing rejection.** 333
ZIPs delivered is more than any other category, at a 4.73 per cent rate, and
`readme.md` rejected the IMLS Public Libraries Survey because it carries no URL
column. That rejection is correct about IMLS and wrong as a conclusion about
libraries: the category is the best institutional performer measured, and IMLS
has an authoritative ZIP for every outlet. The missing half is the website.

LibDex is a verified-accessible lead for that half. `libdex.com` answered HTTP
200, its `robots.txt` disallows only `/admin`, `/search`, `/api/`,
`/edit_library/` and `/report`, so the listing pages are permitted, and it
publishes a sitemap. Minnesota alone lists **856 libraries**, organised
country then state then town. Two caveats before anyone builds it: the listing
pages are town-level with no ZIP, so it would need a name-and-town join to IMLS
to get one, and a town-level crawl is thousands of pages. Both are tractable and
neither is free. I have NOT verified that the town pages carry a website per
library; that is the next check.

## Police stations specifically

Asked for, and checked.

**There is no national police registry carrying a website.** The FBI Crime Data
Explorer agency API is the authoritative national list and is open with a demo
key. I pulled 2,285 agencies across seven states before the demo key rate
limited. The field list is complete and fixed, and it is exactly these ten:
`ori`, `agency_name`, `agency_type_name`, `counties`, `is_nibrs`, `latitude`,
`longitude`, `state_abbr`, `state_name`, `nibrs_start_date`.

No street address, no ZIP, **no website**. Latitude and longitude are present
for 1,886 of the 2,285, so a ZIP is derivable, but the website half is simply
absent — the same failure as NCES PSS and IMLS. Agency types in that sample:
City 1,404, County 278, State Police 158, Other State Agency 149, University or
College 146, Other 109, Tribal 41.

The BJS Law Enforcement Agency Identifiers Crosswalk carries mailing addresses
and no websites, and its public release is from 2000.

**And police stations are already loaded.** OSM tags them `amenity=police`, and
`lm_fetch.py`'s `osm_tags_to_row` writes `amenity` into `category`, so the
national OSM pass already carries every police station OSM knows with a website
and a postcode. Section 2 of `category_yield.sql` reports exactly how many and
what they delivered. Run that before considering a police source: if OSM's
police stations already deliver poorly, a registry that lacks websites
altogether will not do better.

### My prediction about police was wrong, and the measurement says so

I expected a city police department to publish the city's website and therefore
to behave like `dotgov` at 0.36 per cent. Measured, from `category_yield.sql`
on 2026-11-03:

| | rows | resolved | have_zip | onpremises | ZIPs | rate |
|---|---|---|---|---|---|---|
| `category = 'police'` | 2,519 | 2,301 | 2,231 | **126** | 64 | **5.00%** |

**Five per cent, which is `nces_ipeds` territory, not `dotgov` territory.** I
was wrong by a factor of fourteen. Of the 2,519, only 58 were rejected as
hosting; the rest failed on the ZIP rules.

Police stations are therefore a good category, and the reason is visible in the
agency type breakdown rather than in my reasoning: a police department runs a
dispatch and records network that cannot be outsourced to Squarespace. It is an
institution with its own network, which is the criterion that actually predicts
yield.

What does NOT follow is that a police registry is worth building. The 2,519 OSM
rows already deliver those 64 ZIPs, and the FBI file has no website to add to
them. The route to more police stations is more OSM coverage, not a new source.

## Correction to something I told you

I presented the fire registry as reaching "2,277 ZIPs that CCD does not". That
is true of the ZIPs **present in the source file** and it is not a prediction of
ZIPs **delivered**. The ratio between those two is brutal and measured:

| source | ZIPs in source | ZIPs delivered | ratio |
|---|---|---|---|
| ca_cde | 1,367 | 26 | 1.9% |
| nces_ipeds | 4,241 | 312 | 7.4% |
| osm | 25,626 | 2,755 | 10.8% |

That guess is now superseded by a direct measurement. OSM's `fire_station`
category went through the same chain: **5,208 rows, 4,773 resolved, 146
on-premises, 2.80 per cent, 62 ZIPs delivered.** Of the 5,208 only 69 were
rejected as hosting, so the losses are on the ZIP rules, not on rule 2.

Applied to the USFA registry's 8,685 usable rows, 2.80 per cent predicts about
**243 on-premises landmarks**. ZIPs delivered should track that closely rather
than fall far below it, because 99.5 per cent of USFA hosts appear in exactly
one ZIP, where OSM fire stations share hosts more often. So roughly **200
delivered ZIPs**, against the 2,277 I originally implied.

Load it: 243 landmarks and 200 ZIPs for one minute of fetching is a good trade,
and the rows that land in already-covered ZIPs still feed the 4,940
unmeasurable nodes. But the number I first gave was wrong by an order of
magnitude and it was optimistic.
