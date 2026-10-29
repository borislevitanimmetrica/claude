# Sources for sparsely populated ZIPs

## The finding that reframes the problem

Adding 296,830 rows from Foursquare, OSM and IPEDS moved `onpremises = true`
from 120,154 to **122,110**. That is **+1,956**, a yield of 0.66%.

The chain is not at fault. `onpremises` requires the IP's registrant ZIP to be
at or adjacent to the landmark's ZIP, and most businesses in a POI feed sit on
shared hosting: Squarespace, Wix, GoDaddy, Shopify. The registrant ZIP is the
host's, not the premises'. The rule correctly rejects them.

So the useful question is not "which source has the most places" but **which
source lists organisations that run their own web server at their own
address**. Measured, from the loads already done:

| source | rows | contribution to onpremises |
|---|---|---|
| Overture | 13.8M | 120,154 (the existing corpus) |
| Foursquare + OSM + IPEDS | 296,830 | **+1,956 combined** |

Business POI feeds are structurally poor landmark sources. Institutions that
self-host are good ones. Everything below is judged on that basis.

## Verified, 2026-10-26

### 1. CISA .gov domain registry — the best new source for sparse ZIPs

`https://raw.githubusercontent.com/cisagov/dotgov-data/main/current-full.csv`
Open, no key, HTTP 200, 1.4 MB.

**16,980 domains**, of which **14,140 are local government**:

| type | domains |
|---|---|
| City | 9,256 |
| County | 2,724 |
| State or territory | 1,441 |
| Special district | 1,125 |
| Tribal | 289 |
| School district | 75 |

Why this fits the sparse-ZIP problem specifically: it is a registry of
*municipalities*, and small towns are municipalities. Coverage spans all 54
states and territories across **9,170 distinct (city, state) pairs**. Rural
reach, sampled:

```
MT: 114 domains / 80 towns      VT:  94 / 87      ME: 134 / 107
WY:  63 / 38                    ND:  51 / 31      SD:  60 / 50
AK:  55 / 38
```

Vermont has roughly 250 municipalities, so 87 towns is real penetration into
exactly the places Overture misses.

**Caveat, and it is the important one.** The file has `City` and `State` but
**no ZIP**. That is survivable because the chain's `overture-zip` step already
has a locality fallback: the one ZIP that every row with the same locality and
region carries, when unambiguous. Those rows get
`overture_zip_source = 'locality'`, which the chain labels an inference rather
than a postcode, so the weaker provenance stays visible.

Expected to perform well on `onpremises` for a second reason: for a town
government the RDAP registrant is usually the town itself, so the registrant
ZIP is the town hall's.

### 2. A national OpenStreetMap pass — the largest untapped source

Already built (`lm_fetch.py osm-pbf`) and never run nationally. Massachusetts
alone returned **15,238** features with both `website` and `addr:postcode`;
Texas 52,269. OSM also carries the schools, libraries and town halls that the
federal registries omit websites for, with real ZIPs rather than inferred ones.

The per-state Overpass route times out on California and New York, so this
needs the Geofabrik PBF path: `us-latest.osm.pbf` is 11.39 GB.

### 3. Rejected, each for a checked reason

| source | has ZIP | has website | verdict |
|---|---|---|---|
| **NCES CCD** (K-12 schools) | yes, `zip_location` | **no** — 52 fields, zero web/url/site fields | rejected |
| **IMLS PLS** (public libraries) | yes, `ZIP`/`ZIP4` | **no** — the only web-ish field among 192 is `WEBVISIT`, a visit *count* | rejected |
| **USAC E-Rate** (schools + libraries) | not in the funding dataset | no | rejected |
| **NPS** | yes | yes, but all `nps.gov` | rejected: ~470 parks collapse to one host |
| **NRHP** | yes | mostly none | rejected |

So there is **no national registry of K-12 school or public library websites**.
Both exist as authoritative address lists with no URL. The practical route to
schools and libraries is therefore OSM, not a federal file. Matching CCD or
IMLS *to* OSM by name and ZIP would add addresses we already have, not hosts.

## RIPE Atlas — the hardware-probe service

This is the one you were thinking of. I cannot find where I raised it earlier
in this work, so I am naming it as the most likely match rather than claiming
it was my suggestion.

Volunteers host small hardware probes; the metadata is public and users can
run their own traceroute measurements from them.

Verified:

- **2,376 connected US probes.**
- Of a 500-probe sample, **444 (89%) expose a public IPv4** and all 500 carry
  coordinates; 96% carry an ASN.
- The measurement API exists and requires a key (`POST /api/v2/measurements/`
  returns 401 unauthenticated). 25.2M public traceroute measurements on record.

**It will not fix landmark density, and the numbers say why.** 2,376 probes
against ~44,000 inhabited ZIPs is two orders of magnitude short, and they are
heavily metro-clustered: 500 sampled probes fell into only 149 one-degree
cells, led by the SF Bay Area (45), Washington DC (32), Seattle (25) and Los
Angeles (24). Volunteers who host network probes live in cities. For the sparse
ZIP problem this is close to the opposite of what is needed.

**What it is genuinely worth, and it is not small.** Atlas measures the thing we
currently infer. Our method traces *toward* a landmark and takes the last
carrier node as a proxy for the equipment a subscriber sits behind. An Atlas
probe *is* a subscriber connection at a known location, so a traceroute *from*
it reports that subscriber's real carrier node directly. That makes Atlas a
**validation instrument for the core inference**, independent of ip-api and
independent of RDAP:

- For each probe, trace outward and record the last carrier node.
- Check whether that node is one our landmark side already associates with the
  probe's ZIP.
- Where it is, the node-to-ZIP inference is confirmed from the subscriber side.
  Where it is not, we have a concrete counter-example of the West
  Roxbury-via-Brockton kind, with a known subscriber location.

2,376 vantage points is far too few to be a landmark corpus and far more than
enough to validate a method. It also costs nothing but credits.

## Recommended order

1. **.gov registry.** New, verified, aimed squarely at small towns.
2. **National OSM via PBF.** Largest untapped volume; the only practical route
   to schools and libraries.
3. **RIPE Atlas as validation**, after `range2zip_tbl` exists, so there is
   something to validate against.

Do not spend further effort on business POI feeds for landmark purposes. The
measured yield was 0.66%.
