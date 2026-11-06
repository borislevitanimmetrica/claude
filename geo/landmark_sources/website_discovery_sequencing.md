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
their own building.** `nces_ipeds` at 5.40 per cent is the shape to look for:
an institution large enough to hold an IP allocation in its own name at its own
address. Hospitals, health systems, large manufacturers, utilities, research
institutes and corporate campuses are that shape. Small municipal bodies are
not, however many of them there are.

`category_yield.sql` reads the per-category rate straight out of the 1,139,855
OSM rows already enriched, so the next source can be chosen from measurement
instead of from this reasoning.

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

My expectation, and I am flagging it as an expectation rather than a
measurement: a city police department publishes the city's website, which is the
`dotgov` case at 0.36 per cent. The exception in the type breakdown is
**University or College police, 146 of 2,285**, which sit on campus networks and
should behave like `nces_ipeds` at 5.40 per cent. That is a small, high-rate
subset, and `category_yield.sql` will show whether it is real.

## Correction to something I told you

I presented the fire registry as reaching "2,277 ZIPs that CCD does not". That
is true of the ZIPs **present in the source file** and it is not a prediction of
ZIPs **delivered**. The ratio between those two is brutal and measured:

| source | ZIPs in source | ZIPs delivered | ratio |
|---|---|---|---|
| ca_cde | 1,367 | 26 | 1.9% |
| nces_ipeds | 4,241 | 312 | 7.4% |
| osm | 25,626 | 2,755 | 10.8% |

On the `ca_cde` ratio the fire registry's 7,418 source ZIPs become about **140
delivered**; on the OSM ratio about 800. It has one real structural advantage
over `ca_cde` — 99.2 per cent unique hosts against 72.0, because fire
departments do not share a district website the way schools do — so I would
expect better than 1.9 per cent. I cannot say how much better, and the OSM
`fire_station` category in `category_yield.sql` section 3 is the measurement
that answers it from your own data rather than from my analogy.

Load it regardless: a few hundred ZIPs and several thousand landmarks in
already-covered ZIPs is worth one minute of fetching. But the number I gave was
the wrong number, and it was optimistic.
