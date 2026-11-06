# Consumer map platforms and other landmark sources

Researched 2026-11-03, in answer to: Google Maps, Apple Maps, MapQuest,
HERE WeGo, Waze, Wikimapia, and any others.

## Bottom line

**None of the consumer map platforms can be used.** Every one of them either
forbids storing the place attributes in our own database, or is a paid licence
whose storage rights I could not verify from public documents, or resells data
we have already loaded.

**The useful finding is a different source entirely.** The USFA National Fire
Department Registry is open, keyed, carries both a website and a physical ZIP,
and reaches **2,277 ZIPs that the CCD school file does not**. It is now
implemented as `lm_fetch.py usfa-fire` and has been run in dry-run mode against
the live file.

There is also a prior recommendation in `sparse_zip_sources.md` that appears
never to have been executed and is still the largest untapped volume: the
national OpenStreetMap pass via a Geofabrik PBF. I need you to tell me whether
it has been run.

## Why this class of source was always going to be weak

This is the part that matters more than any individual licence.

`sparse_zip_sources.md` records a measurement from this project: adding 296,830
rows from Foursquare, OSM and IPEDS moved `onpremises = true` from 120,154 to
122,110. That is **+1,956 rows, a yield of 0.66 pct**.

The reason is structural, not a bug. `onpremises` requires the IP registrant's
ZIP to sit at or next to the landmark's ZIP. Most businesses in a POI feed are
on Squarespace, Wix, GoDaddy or Shopify, so the registrant ZIP belongs to the
host, not the premises, and the rule correctly rejects them.

Google Maps, Apple Maps, HERE and MapQuest are **the same kind of feed** as
Foursquare and Overture: commercial business POI. Even if the licences allowed
bulk storage, the expected yield is the 0.66 pct already measured, not something
better. The sources that work are registries of institutions that run a web
server at their own address.

## The platforms, one by one

| platform | may we store place attributes? | verdict |
|---|---|---|
| **Google Maps / Places** | **No.** Place IDs may be stored indefinitely; other content must not be pre-fetched, cached or stored, beyond narrow temporary exceptions | **disqualified** |
| **Apple Maps / MapKit** | **No.** Schedule 6 section 2.5 permits no caching or storing except temporarily; Place IDs may be persisted | **disqualified** |
| **Waze** | **No POI API exists.** Partners get a GeoRSS *traffic* feed on a 2-minute refresh; the Transport SDK loses support 2026-11-01. Waze shows place details sourced from Google Maps, so even indirectly it is Google's terms | **disqualified** |
| **Wikimapia** | Data is CC BY-SA, but the API is offered **free for non-commercial use** under their TOS, and the objects are traced from Google imagery, which raises a derivative-work question on top | **disqualified for commercial use** |
| **Esri ArcGIS Places** | Esri's own documentation states the US data is licensed from **SafeGraph, Foursquare and Data Axle**. Foursquare is already loaded here. Esri's data terms also restrict some layers to non-commercial or internal use | **redundant and restricted** |
| **Yelp Fusion** | **No.** Their terms cap retention at **24 hours**, forbid bulk download, and permit storing only Yelp business IDs for back-end matching | **disqualified** |
| **HERE** | **Unresolved.** See below | **unresolved** |
| **MapQuest** | **Unresolved.** See below | **unresolved** |

### What I could not verify, stated plainly

I could not establish HERE's or MapQuest's data-storage rights from public
documents, and I am not going to infer them.

- `https://legal.here.com/terms/general-service-terms` answered **HTTP 503**
  when fetched. The document that would settle it is HERE's Service Specific
  Terms together with the Supplier Terms linked from `here.com/en-us/terms`.
  A 2016 Stack Overflow revision quotes language forbidding "creating or
  contributing to a database", attributed to HERE, but I cannot confirm that is
  current text and will not treat a third-party quote of a 10-year-old term as
  the answer.
- MapQuest publishes Search Ahead and Place Search API documentation but no
  public data-storage clause that I could find. MapQuest's POI data has been
  sourced from TomTom; TomTom itself draws the API-versus-bulk-licence
  distinction explicitly in its own material, which is a strong hint that bulk
  storage needs a data licence rather than an API key, but a hint is not a term.

Both are moot unless the 0.66 pct yield argument above is wrong, because both
are commercial business POI feeds. I would only chase the contracts if you
decide that class of source is worth re-testing.

### The one open-licensed map source is already known here

OpenStreetMap is the exception in this whole category: ODbL, bulk download, no
per-request terms, and it carries `website` and `contact:website` tags next to
`addr:postcode`. It is already implemented (`lm_fetch.py osm-overpass` and
`osm-pbf`) and `sparse_zip_sources.md` lists the national PBF pass as
recommendation 2, measured at 15,238 features for Massachusetts alone and
52,269 for Texas, never run nationally. ODbL's share-alike obligation attaches
to a redistributed derived database, which is a question for how the ZIP
service is published rather than for loading it.

## New source, verified and implemented: USFA fire department registry

`https://apps.usfa.fema.gov/registry/api/download/national`
Open, no key, HTTP 200, 8,831,230 bytes, 26 columns, 27,117 rows.
sha256 `20c7871160688782103e8ef31e6bed826dadbebc62dc9f93174c3f27bb256d29`.

The download page is a Next.js app, so there is no link to the CSV. The three
API routes were read out of the page's own JS bundle, not guessed.

Measured by the loader against the live file:

| metric | value |
|---|---|
| departments read | 27,117 |
| with a 5-digit HQ ZIP | 27,117, all of them |
| with a non-empty Website | 8,721 |
| usable after `normalise_url` | **8,685** |
| distinct ZIPs | **7,418** |
| distinct hosts | 8,408 |
| hosts serving exactly one department | 8,344 = **99.2 pct** |
| hosts appearing in exactly one ZIP | 8,367 = **99.5 pct** |

`pct_unique_hosts` is the column the readme says to read, and 99.2 pct beats
every source already loaded: NCES IPEDS is 89.1 pct, OSM in Rhode Island
97.4 pct. A volunteer fire department is one building with one domain, so the
fan-out that ruins retail and bank-branch feeds does not occur.

### Where the rows are, which is the real argument

CCD 2023-24, open schools only, parsed through the same `normalise_url`:
67,417 usable rows, 16,768 ZIPs, 30,365 hosts.

| comparison | value |
|---|---|
| fire ZIPs not reached by CCD | **2,277** |
| fire hosts absent from CCD's hosts | 8,400 of 8,408 |
| union of the two ZIP sets | 19,045 |

Fire protection follows settlement, not commercial density and not
school-district geography. A town too small for a school still has a volunteer
department, which is exactly the sparse-ZIP case.

The other 5,141 ZIPs, the ones CCD already reaches, are not wasted.
`node_fanout.sql` classified **4,940 nodes as unmeasurable for having too few
landmarks**. A second, independent landmark inside an already-covered ZIP is
what moves a node from unmeasurable to measurable, so volume in covered ZIPs
counts here too.

### Two measured caveats, neither fatal

**Staleness.** Registration is voluntary and departments maintain their own
listing, so some entries are ancient: `www.geocities.com` appears 43 times and
GeoCities shut down in 2009. A 400-host DNS sample resolved 347, so about
**86.8 pct are live**. The resolve step already tolerates failures.

**Social and aggregator URLs.** 61 departments list a Facebook page, 65 list
`www.fire-ems.net`, several dozen list `firehouse.com`. **These are not
filtered.** The readme's position is that hosting has exactly one definition and
it lives in `node_fanout.sql`; a second, different filter at load time would
undermine that. The loader prints the counts instead, so the cost stays visible
rather than becoming invisible policy.

`HQ zip` is used, not `Mail zip`. Mail zip is frequently a PO box, which is a
mail-handling location and not where a server sits.

## Checked and rejected this session

| source | ZIP | website | verdict |
|---|---|---|---|
| **NCES PSS** (private schools) | yes, `PZIP` | **no** | **rejected.** Downloaded the 2023-24 public-use file: 359 columns, 22,510 rows, zero web or URL fields. The frame file has 4 columns (`PPIN`, `ISR`, `OOS`, `INACTIVE`). The private-school locator detail pages carry no website either, checked on three schools |
| **HIFLD Open** | yes | some layers | **not available.** DHS shut the public portal down in **August 2025**. An archive sits in the Homeland Security Digital Library and a third party republishes 400-plus layers as "HIFLD Next". Public-domain content, but now second-hand and of unknown currency |
| Esri ArcGIS Places | yes | yes | redundant: SafeGraph plus Foursquare plus Data Axle, and Foursquare is loaded |
| Yelp Fusion | yes | yes | 24-hour retention cap |

PSS is worth naming precisely because of what it is: 22,510 private schools
with a verified physical ZIP and no URL anywhere. That is the same shape as the
IMLS library rejection already in the readme. There is a real pattern here, and
it is the next structural question.

## The structural gap worth your decision

Several authoritative, public-domain, nationwide registries give an exact
institution name and physical ZIP and **no website**: PSS at 22,510 private
schools, IMLS public library outlets, and the 17,025-domain CISA `.gov` file
which has `City` and `State` but no ZIP at all. The landmark test needs both
halves, so each is currently rejected for the missing half.

A website-discovery step would convert all of them at once. The honest
measurement we already have is from the Idaho and Louisiana pilot: of 48 schools
searched by hand, **23 (47.9 pct) had their own host** and roughly half were
vendor-hosted. I have not tested whether Certificate Transparency can do the
same job in bulk, so I will not claim it can.

I am not proposing to build this now. I am flagging that it is one mechanism
standing between us and several complete national registries, and asking
whether you want it sized.

## Recommended order

1. **`lm_fetch.py usfa-fire`.** Implemented, dry-run verified against the live
   file. 8,685 landmarks, 2,277 ZIPs that no school reaches.
2. **Tell me whether the national OSM PBF pass has run.** It is recommendation 2
   in `sparse_zip_sources.md`, it is the largest untapped volume, and I cannot
   see your table contents from here.
3. **Tell me whether `lm_fetch.py dotgov` has run.** Re-verified live today:
   17,025 domains, up from the 16,980 recorded on 2026-10-26, of which 15,706
   are local government (City 9,599, County 3,061, State or territory 1,488,
   Special district 1,158, Tribal 294, School district 77, Interstate 29).
4. **Decide on website discovery for the address-only registries**, per above.
5. **Spend nothing further on consumer map POI platforms.** The licences forbid
   it and the measured yield for that class is 0.66 pct.

## Two corrections to existing documents

- `sparse_zip_sources.md` lists **NCES CCD as rejected for having no website**.
  That is wrong, and the correction is from this project's own Session 4 work:
  the 2023-24 directory file has a `WEBSITE` column, 67,417 open schools carry
  both it and a physical `LZIP`. The `cmd_ca_cde` docstring repeated the same
  claim and has been corrected in place.
- The readme's rejection of **IMLS** stands as written and was not re-tested.

## Attribution

- USFA National Fire Department Registry, US Fire Administration / FEMA, public
  domain
- NCES CCD and PSS, US Department of Education, public domain
- CISA `.gov` registry, Cybersecurity and Infrastructure Security Agency, public
  domain
- OpenStreetMap, (c) OpenStreetMap contributors, ODbL 1.0

Licensing positions for Google, Apple, Waze, Wikimapia, Yelp and Esri above are
summarised from each vendor's own published policy pages; content was rephrased
for compliance with licensing restrictions. Sources:
[Google Places policies](https://developers.google.com/maps/documentation/places/web-service/policies),
[Waze for Cities data feed](https://support.google.com/waze/partners/answer/10618035),
[Waze Transport SDK](https://developers.google.com/waze/intro-transport),
[Wikimapia API](https://ns2.wikimapia.org/),
[Yelp Fusion terms discussion](https://github.com/Yelp/yelp-fusion/issues/426),
[Esri ArcGIS Places suppliers](https://doc.arcgis.com/en/esri-demographics/latest/regional-data/places-pois.htm),
[Esri data attributions](https://www.esri.com/en-us/legal/terms/data-attributions),
[HIFLD Open shutdown](https://purl.fdlp.gov/GPO/gpo148999).
