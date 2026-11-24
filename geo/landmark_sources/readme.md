# Additional landmark sources

Overture is not enough: 120,154 on-premises places but only **28,324 distinct
addresses**, covering **15,963 ZIPs** of roughly 44,000 inhabited ones.

## The test every source must pass

A source is useful only if it has **both a ZIP and a website**. The website
resolves to an IP whose registrant decides `onpremises`; the ZIP is the
geographic anchor. One without the other is worthless here.

But row count is the wrong measure of value. **What matters is the number of
independent domains.** The chain resolves a website to an IP and decides
`onpremises` from that IP's registrant, so N places sharing one domain yield
**one** landmark address no matter how large N is — and `node_fanout.sql` will
then correctly classify that address as hosting, because it spans disjoint ZIP
clusters.

Measured, from the loads below:

| source | rows | distinct hosts | pct unique | distinct ZIPs |
|---|---|---|---|---|
| **USFA fire registry (national)** | 8,685 | 8,408 | **99.2%** | **7,418** |
| NCES IPEDS (national) | 6,075 | 5,411 | **89.1%** | 4,241 |
| OSM (Rhode Island only) | 1,958 | 1,908 | **97.4%** | 76 |

`pct_unique_hosts` is the column to read. A low value means either a
single-domain feed or a parsing bug.

## Verified access status, checked 2026-10-26

| source | ZIP | website | access | verdict |
|---|---|---|---|---|
| **USFA fire registry** | `HQ zip`, on every row | `Website` | **open** — no key | **best host quality, 99.2% unique.** Reaches 2,277 ZIPs no school reaches. Added 2026-11-03 |
| **NCES CCD** | `LZIP` | `WEBSITE` | **open** — direct zip | **largest.** 67,417 open schools, 16,768 ZIPs. The earlier "CCD has no website" finding was wrong |
| **OpenStreetMap** | `addr:postcode` | `website` | **open** — Overpass or Geofabrik | **best volume.** MA 15,132, TX 52,269 features with both tags |
| **NCES IPEDS** | `ZIP` | `WEBADDR` | **open** — direct zip, HTTP 200 | **best quality.** ~6,000 colleges, own domains, campuses self-host |
| **Wikidata** | inside `P6375` | `P856` | **open** — SPARQL | useful; ZIP is in the address text, which the chain already parses |
| **Foursquare** | `postcode` | `website` | **gated** — HF token | large; see `../foursquare_fetch/` |
| **NPS** | yes | yes | free API key | **not worth running.** Every park is an `nps.gov` URL → one host |
| **IMLS** | `ZIP` | **none** | open | **rejected.** `WEBVISIT` is a count of visits, not a URL |
| **NRHP** | yes | mostly none | open | **rejected.** Historic listings rarely carry a website |

### Rejected, with the reason

- **IMLS Public Libraries Survey.** Checked both files in `pls_fy2022_csv.zip`:
  the outlet file has 39 columns with `ZIP`/`ZIP4` and **no** web column; the
  administrative-entity file has 192 columns whose only web-ish field is
  `WEBVISIT`, a visit *count*. No URL anywhere, so no host, so no landmark.
- **NPS.** Good addresses, but every park URL is on `nps.gov`. ~470 parks
  collapse to one host and one IP, which the cluster rule then flags as hosting
  across disjoint ZIPs. Implemented as `lm_fetch.py nps` for completeness and
  documented as not worth the API key.
- **Bank branches (FDIC/NCUA) and chain retail.** Same single-domain argument:
  every branch points at the institution's one corporate domain.
- **Wikidata `P281` (postal code).** Looks right, is not: on US items it returns
  city-level *ranges* such as `10000–10499` for New York City. Unusable as a
  landmark ZIP. `P6375` (street address) is used instead, because it carries a
  specific ZIP inside the text.

## Why one table rather than one per source

`lm_places_usa` has a `source` column. Overture and Foursquare each get their
own table because each is a bulk parquet import of comparable size; these
sources are several smaller feeds needing identical enrichment, so one table
means **one** resolve pass, **one** RDAP pass and **one** `onpremises` pass
covers all of them.

As with `fsq_places_usa`, the column names are chosen so the shared chain runs
unchanged. Two columns are synthesised at load:

- **`websites`** — the bare URL. The resolve step uses a text value not starting
  with `[` as-is.
- **`addresses`** — Overture's JSON shape, built with `json.dumps` so a quote or
  backslash in a street name cannot produce malformed JSON and silently break
  the ZIP regexes.

## Run order

Measure before loading. `usfa-fire` has a `--dry-run` that opens no database
connection at all, so a connection problem can never be mistaken for a parsing
one.

```
python3 lm_fetch.py usfa-fire --dry-run
```

Then the load, in this order. Every comment is on its own line, because a
comment sitting after a command on the same line does not survive the paste
path.

```
psql -v ON_ERROR_STOP=1 -f create_table_lm_places_usa.sql
python3 lm_fetch.py usfa-fire
python3 lm_fetch.py nces-ipeds --year 2023
python3 lm_fetch.py osm-overpass --states MA
python3 lm_fetch.py wikidata --limit 50000
python3 lm_fetch.py status
psql -v ON_ERROR_STOP=1 -f lm_crosswalk.sql
```

- `usfa-fire` is roughly 8,685 fire departments in 7,418 ZIPs, under a minute.
- `nces-ipeds` is roughly 6,000 colleges, about a minute.
- `osm-overpass --states MA` starts with one state; see the PBF note below for
  a national pass.

Then the shared chain, no source-specific code:

```
python3 ../overture_fetch/ovt_resolve_hosts.py resolve      --table lm_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py rdap         --table lm_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py registrants  --table lm_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py overture-zip --table lm_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py onpremises   --table lm_places_usa
```

### OSM nationally needs PBF, not Overpass

Overpass serves small and medium states fine but **times out on California and
New York**, and a whole-country query is hopeless. `osm-overpass` reports which
states failed. For those, and for a national pass, use a Geofabrik extract.
Sizes confirmed: `us-latest.osm.pbf` is **11.39 GB**, California 1.24 GB,
Massachusetts 0.29 GB.

Install `osmium-tool` with whichever package manager this host uses, `dnf
install -y osmium-tool` or `apt install osmium-tool`. Then, one command per
line, no line continuations and no trailing comments, so the whole block
survives a paste:

```
sudo -v
curl -L -O https://download.geofabrik.de/north-america/us-latest.osm.pbf
osmium tags-filter us-latest.osm.pbf -o filtered.osm.pbf nwr/website nwr/contact:website
osmium export filtered.osm.pbf -f geojsonseq --add-unique-id=type_id -o filtered.geojsonseq
python3 lm_fetch.py osm-pbf --input filtered.geojsonseq
```

`geojsonseq` is one feature per line, so the loader streams it instead of
holding 11 GB in memory, and it COPYs in batches of 200,000.

### Wikidata: use QLever, and pull everything

**There is no row limit by default.** `--limit 0` means all matching items, which
is the default. Measured 2026-10-26: **29,858** US items carry both `P6375`
(street address) and `P856` (website), of which **26,088** have a 5-digit ZIP in
the address. `--limit` exists only to cap a deliberate smoke test, and it counts
rows fetched *by that run*, so it composes with `--resume`.

The default endpoint is **QLever** (`qlever.dev`), an independent index of the
same Wikidata dump. It answered a `COUNT` in under a second while the canonical
WDQS was returning `504` to the identical query, and it is unaffected by WDQS
outages. `--endpoint wdqs` switches back for a cross-check.

`ORDER BY ?item` is not decoration: without it SPARQL `OFFSET` has no defined
order, so pages can overlap or skip and pagination is not reproducible.

Three independent stopping mechanisms, none of which lose work:

| mechanism | effect |
|---|---|
| `--deadline-minutes N` | stops the whole pull after N minutes, keeping every page merged so far |
| `--max-backoff N` | refuses a `Retry-After` longer than N seconds rather than sleeping |
| page failure | stops, keeps everything already merged, names the other endpoint |

Every page is merged as it arrives, so an interrupted pull keeps its progress
and `--resume` continues from the rows already present. Resume is safe in one
direction only, deliberately: the stored row count is always at or below the
offset actually reached, because rows with no parseable ZIP are fetched and then
dropped, so resuming by count can re-fetch a little but can never skip an item.

A full pull in practice:

```
python3 lm_fetch.py wikidata
```

If it stops early for any reason:

```
python3 lm_fetch.py wikidata --resume
```

Measured: an unbounded run with a 1-minute deadline merged 21,692 rows, so the
whole 26,088 takes roughly two minutes.

## Chains are expected, and are handled

`lm_crosswalk.sql` section 5 lists hosts spanning several ZIPs. From the test
loads these were for-profit college groups sharing one domain across campuses
(`paulmitchell.edu` 96 ZIPs, `www.empire.edu` 72, `rosseducation.edu` 40) and
retail chains in OSM (`locations.dunkindonuts.com` 40,
`www.mcdonalds.com` 25, `www.cvs.com` 16).

These are not errors and are not filtered out here. They are exactly what the
disjoint-ZIP-cluster rule in `node_fanout.sql` and `address_hosting_tbl` exists
to catch, and catching them there keeps one definition of hosting rather than
adding a second, different one at load time.

## Attribution

- OpenStreetMap — © OpenStreetMap contributors, ODbL 1.0
- Wikidata — CC0 1.0
- NCES IPEDS, CCD and PSS — US Department of Education, public domain
- USFA National Fire Department Registry — US Fire Administration / FEMA, public
  domain
- CISA `.gov` registry — Cybersecurity and Infrastructure Security Agency,
  public domain
- NPS — US National Park Service, public domain

See `map_poi_source_research.md` for the consumer map platforms (Google, Apple,
Waze, Wikimapia, HERE, MapQuest, Yelp, Esri) and why none of them can be used.
