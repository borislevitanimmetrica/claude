# Foursquare OS Places, United States

A second landmark source alongside `ovt_places_usa`, because Overture alone is
not enough: 120,154 on-premises places, but only **28,324 distinct addresses**,
covering **15,963 ZIPs** of roughly 44,000 inhabited ones. Nearly two thirds of
inhabited ZIPs have no landmark at all.

## Access is gated. Read this before planning the run.

The anonymous route is gone. Verified 2026-10-26:

| route | result |
|---|---|
| `s3://fsq-os-places-us-east-1/release/.../places/parquet` | **empty**. The bucket now holds only `LICENSE.txt` and `NOTICE.txt`. |
| Hugging Face file *listing* | works anonymously, HTTP 200 |
| Hugging Face file *download* | **HTTP 401**, token required |
| `datasets-server.huggingface.co/info` | **HTTP 401** |

So the DuckDB-over-anonymous-S3 pattern that `overture_fetch.py` uses cannot
work here. Foursquare moved distribution to a gated Hugging Face dataset.

**The licence did not change.** The data is still Apache 2.0 and still free for
commercial use. Only the download is behind a login.

### What is needed, once

1. A free Hugging Face account.
2. Accept the terms at <https://huggingface.co/datasets/foursquare/fsq-os-places>.
   Gating is `"auto"`, so approval is immediate, not a review queue.
3. A read token from <https://huggingface.co/settings/tokens>.
4. `export HF_TOKEN=hf_...`

Listing needs none of this, so the current release can be discovered first:

```
python3 fsq_fetch.py releases
```

As of 2026-10-26 the newest release is **2026-10-15**: 100 parquet files,
**10.79 GB** for the whole world. The US filter runs inside DuckDB, which reads
only the row groups it needs, so the transfer is well under the full 10.79 GB.

## Why there is no second copy of the enrichment logic

`ovt_resolve_hosts.py` is parameterised by `--table`, `--url-column` and
`--address-column`. So the entire chain, `resolve` → `rdap` → `registrants` →
`overture-zip` → `onpremises`, runs against `fsq_places_usa` **unchanged**.

That is the point. One definition of "on premises", one ISP list, one provider
list, one ZIP-adjacency rule, applied identically to both sources. A separate
Foursquare pipeline would eventually disagree with the Overture one about which
landmarks are usable, and the disagreement would be invisible.

Two columns are synthesised at load time to make this work:

- **`websites`** — Foursquare's flat `website` string, stored bare. The resolve
  step uses a text value not starting with `[` as-is, so no JSON wrapper is
  needed.
- **`addresses`** — Foursquare's address parts re-emitted in Overture's JSON
  shape, because `cmd_overture_zip` matches `"postcode":"12345"` and
  `"freeform":"..."` against the address text. DuckDB's `to_json` on a struct
  does the escaping, so a quote or apostrophe in a street name cannot produce
  malformed JSON.

Verified: the unmodified `overture-zip` step runs on `fsq_places_usa` and sets
`overture_zip_source = 'postcode'`, reducing ZIP+4 `01901-1234` to `01901`.

## Run order

```
psql -v ON_ERROR_STOP=1 -f create_table_fsq_places_usa.sql

# Scope it first. Massachusetts, to compare like with like against the
# Overture pass, before committing to the whole country.
python3 fsq_fetch.py load --release 2026-10-15 --states MA --require-website \
  --input 'hf://datasets/foursquare/fsq-os-places/release/dt=2026-10-15/places/parquet/*.parquet'

python3 fsq_fetch.py verify
psql -v ON_ERROR_STOP=1 -f fsq_crosswalk.sql
```

`--dry-run` counts the matching rows and prints the synthesised columns without
writing anything, and without needing a database.

Then the shared chain:

```
python3 ../overture_fetch/ovt_resolve_hosts.py resolve      --table fsq_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py rdap         --table fsq_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py registrants  --table fsq_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py overture-zip --table fsq_places_usa
python3 ../overture_fetch/ovt_resolve_hosts.py onpremises   --table fsq_places_usa
```

## Duplicates

Not deleted, by decision: they cost processing time, not correctness.

But the unit that matters is the **host**, not the place. The chain resolves a
host to an IP, RDAPs the IP, and decides `onpremises` from the registrant, so
two places sharing a host yield one landmark address and one RDAP call's worth
of information. A Foursquare row whose host Overture already has adds a name and
nothing else.

`fsq_crosswalk.sql` therefore reports new **hosts** and new **ZIPs**, not new
places, and section 3 is the number that decides whether the import paid off:
ZIPs that gain an on-premises landmark that Overture did not have.

## Scope filters

| flag | use |
|---|---|
| `--states MA,NH,VT` | region codes, for a regional pass |
| `--zip-prefix 021` | Boston area, matching `last_carrier_node -zip-prefix` |
| `--require-website` | skip rows that can never become landmarks |
| `--require-postcode` | skip rows with no ZIP |
| `--include-closed` | keep `date_closed` rows, excluded by default |

Closed places are excluded by default: a shut business keeps its DNS for a
while, so it still resolves, but it is no longer a place anyone is at, which is
the whole basis for treating its address as a geographic anchor.

## Attribution, required by the Apache 2.0 NOTICE shipped with the data

> Contains information from Foursquare OS Places, © 2025 Foursquare Labs, Inc.,
> licensed under the Apache License, Version 2.0.

The full `NOTICE.txt` must be preserved if the data is redistributed. It is
still served, unauthenticated, from
`https://fsq-os-places-us-east-1.s3.amazonaws.com/NOTICE.txt`.

## Published schema

24 columns. `fsq_category_ids` and `fsq_category_labels` are parquet LISTs and
are stored as JSON text, because a DuckDB list cannot go into a PostgreSQL text
column and flattening to a comma string would be lossy.

```
fsq_place_id  name  latitude  longitude  address  locality  region  postcode
admin_region  post_town  po_box  country  website  tel  email  facebook_id
instagram  twitter  fsq_category_ids  fsq_category_labels  date_created
date_refreshed  date_closed      (+ dt, the release date, recorded at load)
```

## Still to decide

- **Which credential path.** Hugging Face token is assumed here. Foursquare also
  publishes through a Places Portal access token against an Iceberg catalog,
  which ClickHouse's documentation now uses. The HF route is less work and needs
  no Foursquare account.
- **Whether to keep going down the memo's list.** OpenStreetMap, Wikidata, NPS,
  NRHP, IMLS and NCES are all ungated. If the Foursquare credential turns out to
  be unwelcome, OSM is the unblocked alternative with good US website and address
  coverage, and the same two synthesised columns would carry it into the same
  chain.
