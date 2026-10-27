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

### Exact procedure, once

Steps 1 to 3 are browser actions. There is no API for creating an account or
accepting a licence, so they cannot be commands.

**1. Create the account.** Go to <https://huggingface.co/join>, enter an email
address and password, pick any username, and confirm the verification email. No
payment details, no organisation required.

**2. Accept the dataset terms.** Signed in, go to
<https://huggingface.co/datasets/foursquare/fsq-os-places>. A box appears
headed "You need to agree to share your contact information to access this
dataset". Tick the agreement checkbox and press **Agree and access repository**.
Gating is `"auto"`, so access is granted immediately rather than queued for
review. The agreement is that Foursquare may name your employer in its partner
material.

**3. Create a read token.** Go to
<https://huggingface.co/settings/tokens>, press **Create new token**, choose
type **Read**, name it anything (`trugeo`), and copy the `hf_...` value. It is
shown once.

**4. Put it in the environment.** Keep it out of shell history and out of git:

```
read -rsp 'HF token: ' HF_TOKEN && export HF_TOKEN && echo
printf 'export HF_TOKEN=%s\n' "$HF_TOKEN" >> ~/.hf_token && chmod 600 ~/.hf_token
```

Then make every future shell pick it up automatically, instead of sourcing it
by hand. Run this once:

```
grep -q hf_token ~/.bashrc || printf '\n[ -r ~/.hf_token ] && . ~/.hf_token\n' >> ~/.bashrc
```

The token lives in `~/.hf_token` at mode 600, and `.bashrc` only sources it.
Keeping it in a separate file means `.bashrc` stays safe to show or copy, and
the guard makes the line idempotent so repeated runs cannot append it twice.
Do not put the token in the repository or in a crontab.

**5. Verify the token actually works** before starting a 10 GB load. This asks
for one kilobyte of the first parquet file. Anonymous returns 401; a good token
returns 206:

```
curl -s -o /dev/null -w '%{http_code}\n' -r 0-1023 -L \
  -H "Authorization: Bearer $HF_TOKEN" \
  'https://huggingface.co/datasets/foursquare/fsq-os-places/resolve/main/release/dt=2026-10-15/places/parquet/places_000000.parquet'
```

| result | meaning |
|---|---|
| `206` | token works, partial content served. Proceed. |
| `401` | token not sent or invalid. Re-check step 4. |
| `403` | token valid but the terms in step 2 were not accepted. |
| `404` | that release no longer exists. Run `python3 fsq_fetch.py releases`. |

**6. Confirm the current release**, since the date in the URL above moves
monthly. This needs no token:

```
python3 fsq_fetch.py releases
```

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
