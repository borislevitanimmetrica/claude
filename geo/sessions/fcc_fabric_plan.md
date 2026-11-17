# Plan change 2026-11-12: abandon landmarks, build from FCC Fabric and headends

Boris's decision, recorded at the moment it was made, with the measurement that
justifies it and the access facts that gate it. Read this before touching
anything in geo/landmarks.

## The landmark method is abandoned, and the final numbers

It was carried to completion rather than guessed at. Final measured state,
2026-11-12, after the hosting rule and a node_fanout rebuild:

    ZIPs with an on-premises landmark          9,783
    on-premises places                        67,639
    on-premises addresses                     24,228

Boris's four reasons for abandoning it, and what in the data supports each:

**1. Too few landmarks.** 9,783 ZIPs of roughly 40,859 the corpus has any
place in. Nine sources were added across two sessions, including CCD, twenty
state school directories, the USFA fire registry, the CISA .gov registry and
28,176 Wikidata items, and the full enrichment chain moved delivered ZIPs by
47. A later registrant-ZIP tier would have added 4.

**2. They match only on carrier CPE-connecting nodes.** node_fanout.sql over
6,250 traced nodes:

    unmeasured: too few landmarks   4,930 nodes   5,937 landmarks   35.7 pct
    reject: too wide to cluster        19         2,085            12.5
    zip-level: one contiguous area    308         1,897            11.4
    reject: 2 or more disjoint areas  ~980        the rest         ~40

308 usable nodes out of 6,250. The nodes that ARE visible are backbone:
154.54.42.102, a Cogent LAX router, holds ZIP pairs 9,042 miles apart, and
32.130.91.66 holds 61,425 ZIP pairs.

**3. The CPE-connecting nodes are often invisible to traceroute and mtr.** Not
separately measured here, but consistent with the per-carrier table: the
residential carriers have many traced nodes and almost no usable ones.

    cogentco.com    523 nodes    19 single-cluster
    comcast.net     886          19
    charter.com     721          10
    zayo.com        293          20
    verizon-gni.net 255           3

**4. On-premises equipment is on dedicated Internet access, while
residential and business carriers are rare even in ZIPs where they dominate.**
This is the decisive one and it explains point 3. The landmark anchors a
business-grade circuit; the subscribers to be geolocated are on a different
access network entirely, so the shared-node assumption the whole method rests
on does not hold.

DO NOT REVIVE THIS without new evidence against point 4. Everything in
geo/landmarks remains valid as measurement and should not be deleted.

## The new plan, as Boris specified it

1. Ingest the FCC Fabric database.
2. Compile headend and central-office locations of routing and
   CPE-connecting IP nodes for Internet service in the USA, per carrier AND
   per network type, so Verizon FIOS is separate from Verizon xDSL.
3. Compile exact street addresses of all headends and COs, including
   unattended network closets, from public sources.
4. Calculate the distance from the nearest headends and COs to the census
   tract centroid of each census tract in which that carrier offers service.
   Census tracts are in the Fabric.
5. Select the headend or CO nearest the centroid, UNLESS another headend less
   than twice the distance has uninterrupted coverage between it and the
   centroid and the nearest one does not.
6. Ascribe IP addresses that ip-api.com shows as located at or near the
   headend or CO to that census tract. Steps 4 to 6 are per census tract, so
   one headend usually serves several tracts.
7. Combine census tracts and their IP addresses into ZIP codes.

## ACCESS: SETTLED, no licence is needed. What was investigated, and why

VERIFIED by search 2026-11-12, from the FCC's own BDC help centre and
CostQuest:

- The Broadband Serviceable Location Fabric is NOT publicly downloadable. It
  is provided to licensees by CostQuest as a ZIP archive of CSV files, ONE
  FILE PER COUNTY.
- Access requires executing a limited end-user licence agreement. The route is
  register at the FCC via CORES to obtain an FRN, log into bdc.fcc.gov with
  those credentials, complete the Entity Information page, then execute the
  Fabric EULA.
- There are three licensee classes: broadband service providers, who get
  records for the counties they serve; state, local and Tribal governments;
  and, under a newer agreement, ENTITIES that are neither providers nor
  governments. The third is the relevant one.
- Availability data is keyed on the Fabric Location ID, which is the join key
  between availability and locations.

VERIFIED as publicly available WITHOUT a Fabric licence:

- broadbandmap.fcc.gov/data-download publishes broadband availability data by
  state and by provider, selectable by technology and as-of date, plus
  challenge data. There is a published public-data API specification.
- The summary geographies offered on that page are State, County,
  Congressional District, Tribal Areas and CBSA. CENSUS TRACT IS NOT AMONG
  THEM.

SETTLED 2026-11-12 by Boris reading the actual header. THE COSTQUEST LICENCE
IS NOT ON THE CRITICAL PATH. The public per-state availability file carries:

    frn
    provider_id
    brand_name
    location_id
    technology
    max_advertised_download_speed
    max_advertised_upload_speed
    low_latency
    business_residential_code
    state_usps
    block_geoid
    h3_res8_id

block_geoid is present, so the census tract is the first 11 characters of the
15-character block GEOID, the county is the first 5 and the state FIPS is the
first 2. h3_res8_id additionally gives a ready-made spatial index cell.

So every identifier steps 2, 4 and 7 need is in the free download: carrier by
frn, provider_id and brand_name; network type by technology, which is what
separates FIOS from xDSL; and geography by block_geoid. The Fabric would add
per-location coordinates and addresses, which this plan does not require,
because steps 4 and 5 work from the TRACT CENTROID rather than from
individual locations.

block_geoid MUST BE STORED AS TEXT. It is a fixed-width 15-character code and
half the states have a leading zero in the state FIPS; Alabama is 01. Reading
it as a number silently destroys those and misfiles an entire state.

## What is NOT yet established about the rest of the plan

- Step 2 needs technology separated per carrier. BDC does report a technology
  code per availability record, which is what makes FIOS separable from xDSL.
  The exact code list is NOT verified here and must be read from the FCC
  specification rather than assumed.
- Step 3, exact street addresses of headends, COs and unattended closets from
  public sources. Candidates not yet assessed: FCC Form 499 filer records,
  state PUC tariff filings, county assessor parcel data, and the CLLI-to-
  address mapping, which needs LERG and is proprietary from iconectiv. The
  earlier ITDK and Hoiho assessment in geo/landmarks/isp_node_feasibility.md
  established that OSM telecom tagging is useless for this: 61 objects tagged
  telecom=central_office and 1,275 carrying a clli tag, WORLDWIDE.
- Step 5's coverage continuity. SPECIFIED by Boris 2026-11-12: a gap, meaning
  an interruption in coverage, is configured at FOUR BLOCKS IN ANY DIRECTION
  for now, to be fine-tuned later. So the path from a candidate headend to the
  tract centroid counts as uninterrupted when no run of consecutive
  uncovered census blocks along it exceeds four in any direction.

  Because the figure is explicitly provisional, it must be STORED WITH EVERY
  DECISION rather than compiled in, so a change of parameter can be re-run and
  compared instead of silently invalidating earlier output. That is what the
  config column on the decision log is for.

- Step 6 and ip-api granularity. I WROTE SOMETHING FALSE HERE AND BORIS
  CORRECTED IT. The earlier text said ip-api "gives one point per range, not
  per address", generalised from a single probe of 65.218.12.0/23 where all
  512 addresses returned one identical answer.

  That range is Verizon Business dedicated access, which is the uniform case,
  and one range cannot establish a property of the service. Boris: ip-api
  localises MORE finely than the decomposed RouteViews and db-ip data
  combined, and 72.72.3.64/26 returns several distinct localities including
  one /28 and several /27. His assessment is that the ip-api data are
  consistent and he tends to trust them.

  Consequence for the probing strategy: once batch queries are enabled the
  project switches from one address per range to EVERY address. The batch
  path is already proven, measured 2026-10-26 and re-confirmed 2026-11-12:
  /batch accepts 100 addresses per call and refuses 101 with HTTP 422, the
  limit is 15 calls a minute from the X-Rl header, and /batch and /json have
  SEPARATE rate buckets. 100 times 15 is 1,500 addresses a minute, so 90,000
  an hour.

## Decision logging, required by Boris 2026-11-12

"Keep a log of all decisions in a table, with step identifiers and geography
identifiers."

Built in geo/fcc_bdc/schema.sql as TWO tables, and the reason for two rather
than one is the four-block gap parameter.

geo_decision_log holds one row per decision: the step that made it, the
geography it concerns with a geo_level saying what the identifier means,
because a bare GEOID is ambiguous between block, tract, county and ZIP; the
carrier and technology where those apply; the decision; the rationale; and the
inputs it rested on as jsonb, so a step can record the distances and candidate
headends it actually used without a schema change per step.

geo_decision_run holds the CONFIGURATION IN FORCE, one row per execution of a
step, referenced by every decision it produced. That is what makes the
four-block figure tunable: changing it starts a new run, and the old
decisions remain attributable to the parameter that produced them instead of
being silently invalidated. A single table carrying the config on each row
would repeat it millions of times and still not let two runs be compared.

## State of the code

Written and VALIDATED against a real PostgreSQL 16, not merely read:

- geo/fcc_bdc/schema.sql. Idempotent, re-runnable. Verified that the
  generated columns derive state FIPS, county and tract correctly and that
  the CHECK rejects a 14-digit block_geoid.
- geo/fcc_bdc/bdc_load.py. Loads the public per-state availability files from
  CSV, ZIP or GZ. Verified end to end against synthetic files with the real
  header: the leading zero survives, so 010010201001001 files under state
  FIPS 01, Alabama, and the 14-digit row that would have landed in Delaware
  is refused and reported rather than loaded; a file already present is
  skipped, and --replace reloads one file without changing the row count;
  a header whose columns are REORDERED is refused with the difference
  printed, because loading it positionally would put upload speeds into the
  download column; and `technologies` reports the codes present from the
  data, since the FCC code list is not verified here and so is hardcoded
  nowhere.

## Immediate next action

Download the public per-state availability files and load them. Then run
`bdc_load.py technologies`, which establishes the technology code to carrier
mapping from the data. That mapping is step 2's input, and it is the first
thing in the new plan that cannot be derived from anything already held.

## 2026-11-17: the downloads are scriptable, and what that measured

Boris asked for a block of curl commands on the assumption the download was
blocked. It is not blocked. I found the API the download page itself uses, and
geo/fcc_bdc/bdc_fetch.py drives it. VERIFIED against the live service, not
recalled:

    GET /nbm/map/api/published/filing
        the data vintages, no credentials at all
    GET /nbm/map/api/national_map_process/nbm_get_data_download/{uuid}
        the catalogue, 10,396 entries
    GET /nbm/map/api/getNBMDataDownloadFile/{id}/1
        the file, as a ZIP; the trailing 1 is required

RETRACTED, 2026-11-17, same day: I wrote here that browser headers were
mandatory, on the evidence of one bare curl returning 403 and one
header-carrying curl returning 200. That was the same mistake as the ip-api
over-generalisation. Re-tested an hour later from the same host, a request
with NO headers returned 200; and the script WITH the headers was refused
from Boris's machine with an Akamai Access Denied page, reference
18.9209c617.1794920849.54c297c1.

What is actually established: Akamai fronts these paths and decides per
client. I cannot predict from one host what another will be served. The
headers are kept because they match the download page and cost nothing, but
they are not the mechanism. curl is used rather than urllib because urllib
was refused where curl was not, on the one host where both were tried.

Three things exist because of this:

- geo/fcc_bdc/bdc_access_probe.sh reports what a given machine can reach,
  endpoint by endpoint, with and without a cookie warmup.
- geo/fcc_bdc/bdc_catalog_fixed.tsv is the 442-row catalogue, COMMITTED, so
  the downloader needs no catalogue API call. Used with --catalog-tsv.
- --warmup loads the HTML download page first and reuses its cookies.

The separately documented /api/public/map/downloads/ API wants credentials and
answers 401. It is NOT used and nothing here authenticates.

### The FCC technology codes, settled from the FCC's own catalogue

The catalogue carries technology_code with technology_code_desc beside it, so
this is now evidence rather than recollection:

     0  Other
    10  Copper
    40  Cable
    50  Fiber to the Premises
    60  GSO Satellite
    61  NGSO Satellite
    70  Unlicensed Fixed Wireless
    71  Licensed Fixed Wireless
    72  LBR Fixed Wireless

Verizon fibre is 50 and Verizon copper is 10, in separate files, which is the
separation step 2 requires.

### The files do not overlap, MEASURED

Fixed availability is published as one file per state per technology, 442
files over 56 jurisdictions. Every availability record therefore appears in
exactly one file. Confirmed by loading Rhode Island and Delaware entire,
2,757,622 real rows over 9 files, and running the overlap check:
duplicated_record_keys came back ZERO. The per-provider files are a different
cut of the same data and must not be loaded as well.

### Satellite is excluded by default

Reading content-length for 376 of the 442 files gives at least 7.38 GB zipped,
of which GSO and NGSO satellite are 3.31 GB, 45 percent. Satellite has no
headend or central office serving a census tract, so those rows cannot
contribute to steps 2 to 6. Non-satellite measured at 4.06 GB. Both figures
are LOWER BOUNDS: 66 of the 442 HEAD requests failed when run eight at a time
and their sizes are missing.

### THE SIZE PROBLEM, which needs a decision before a national load

MEASURED on the real Rhode Island and Delaware load: 2,757,622 rows occupy
746 MB, being 583 MB of heap and 163 MB of indexes. That is 283.8 bytes per
row. The measured zip-to-CSV ratio over those nine files is 17.5x.

ESTIMATE, and it is labelled as one because the arithmetic rests on two small
dense states extrapolating to the country: 4.06 GB of non-satellite zipped
data at the observed 200,000 rows per zipped megabyte is about 810 million
rows, which at 283.8 bytes per row is about 230 GB in PostgreSQL. The true
figure is higher, since 4.06 GB is a lower bound.

Most of that is avoidable and the table is still empty, so the cheap moment to
decide is now:

- source_file is a text column holding a 58-character file name on every row.
  Normalising it to a small integer key referencing a file table saves roughly
  57 bytes per row, on the order of 46 GB.
- state_fips and county_geoid are generated columns derivable from block_geoid
  at the two call sites that would want them, and state_usps already carries
  the state. tract_geoid earns its place as the constant join key; the other
  two cost about 10 bytes per row, on the order of 8 GB.
- bdc_id is a bigserial primary key that nothing references. Dropping it saves
  8 bytes per row plus its index.
- loaded_at belongs on the file table, not on every row.
- Five indexes are 22 percent of the total. The block and h3 indexes are not
  used by any step yet written.

Together those are roughly 100 GB of the 230 GB. NOT APPLIED: this is Boris's
call, and it is a schema change rather than a tuning knob.

### Open question for the national load

Rhode Island and Delaware contain only 19 Copper rows between them, while
Licensed Fixed Wireless alone is 1,358,214. If that holds nationally then the
FIOS-versus-xDSL distinction largely answers itself, because xDSL has nearly
vanished from these filings, and the dominant technology is served from cell
sites rather than from headends or central offices. Two small states cannot
establish either point. It needs re-measuring once more states are loaded.

## 2026-11-17, measured: which Akamai variant works, and a bug of mine

bdc_access_probe.sh run on Boris's machine settled it. Of six variants, FIVE
got HTTP 403: no headers; User-Agent plus Referer; the same forced to
HTTP/1.1; a cookie warmup, which could not even load the HTML page and
captured nothing usable; and a retry 60 seconds later. ONE returned 200: the
full browser header set, being Accept, Accept-Language, the three sec-ch-ua
headers, the three Sec-Fetch headers and Accept-Encoding via --compressed.

From the Kiro sandbox the same day every variant returned 200 including a bare
request. The refusal is per client, which is why the earlier claim about
headers was retracted. bdc_fetch.py now sends the full set on every request,
measured to be the only thing that works on a refused client and free on one
that is not.

His edge resolved to 184.28.163.133 and two IPv6 addresses in
2600:1401:d000::/48. Reference numbers all carried the prefix 18.4c7fd117.

### A BUG I SHIPPED, AND WHAT IT COST

The first fetch run reported "downloaded 4, skipped 0, failed 0" and had
downloaded nothing. All four files were 438-byte Akamai Access Denied HTML
pages, written out under .zip names and moved into place.

Why the checks missed it: curl without --fail writes a 403 body to the output
file and exits 0, so the exit status said success. The length check compared
against the content-length from a HEAD request, but the HEAD was refused too,
so remote_size returned None and the comparison was SKIPPED rather than
treated as unknown. The only remaining test was have == 0, and 438 is not 0.

Fixed, and the fix reads the bytes rather than counting them:

- curl --fail on every request, so a 403 is a nonzero exit.
- inspect_zip checks the PK magic number, that a .csv member exists, and that
  its header line is the twelve BDC columns. An Access Denied page is named as
  such in the failure message.
- A file that fails inspection is kept as .rejected, never moved into place.
- A file ALREADY on disk is inspected before being skipped, so one run's
  mistake is not inherited by the next.
- A new `verify` subcommand reads every file in the directory and reports
  good against bad; --remove-bad deletes exactly the bad ones, after printing
  the pre-mortem.
- fetch exits nonzero when anything failed.

Separately, the progress counter read [2/5] for the second of two files
because a local variable named `want` shadowed the list being iterated and
len("657 B") is 5. Renamed. Cosmetic, but it was mine and it was wrong.

THE GENERAL LESSON, worth keeping: a transfer that is checked only by exit
status and byte count cannot distinguish data from a refusal page. Anything
this project downloads should be validated by reading its structure.

## 2026-11-17: the storage question, answered by measurement

I asked three times whether the 230 GB was affordable. Rather than ask again I
built the alternative and measured both against THE SAME nine real files,
2,757,622 rows of Rhode Island and Delaware, in the same PostgreSQL 16.

| schema | total | bytes per row |
| --- | --- | --- |
| schema.sql, wide | 746 MB | 283.8 |
| schema_v2.sql, normalised | 341 MB | 129.5 |

A 54.4 percent reduction, better than the 43 percent I had estimated. At the
observed 200,000 rows per zipped megabyte and 4.06 GB of non-satellite data,
roughly 810 million rows, that is about 105 GB rather than about 230 GB.

PROVEN IDENTICAL, not assumed. Both schemas were loaded from the same files
in the same database and compared with EXCEPT ALL in BOTH directions over all
fourteen columns: 0 rows in the wide table only, 0 rows in the lean table
only, 2,757,622 each. Verizon still reads as 502,163 records on technology 50
across 422 tracts and 200,976 on 71 across 505 tracts, through the view.

### What schema_v2 changes

Three values were repeated on every row to say one of a few thousand things:

- source_file, a 58-character name, became a smallint referencing
  bdc_source_file_tbl. Nine files here; 333 nationally.
- frn, provider_id and brand_name became an integer referencing
  bdc_provider_tbl. Twenty-seven distinct providers across these two states.
  The three are kept together as the key because one provider_id files under
  several brands.
- state_fips and county_geoid were stored generated columns and are now
  computed in the view. tract_geoid is still STORED, because it is the join
  key for steps 4 to 7.

Also dropped: the unreferenced bdc_id bigserial and its index, loaded_at from
every row, and the indexes on block_geoid and h3_res8_id, which no step reads.
Adding an index later costs minutes; carrying one through a national load does
not.

block_geoid is STILL text under a 15-digit CHECK. That was never a size
decision.

### Safety

The file refuses to run when the table holds rows. Verified: against 2,757,622
rows it raised an exception and changed nothing. Against an empty table it
reports that replacing it loses nothing and proceeds. It is also re-runnable,
which took a fix: the view at the foot depends on the table, so a second run
failed with "cannot drop table because other objects depend on it" until the
view was dropped first. Found by running it three times, not by reading it.

bdc_load.py detects which schema is in place by reading
information_schema.columns, and refuses to load at all if the table matches
neither, rather than inserting into a shape it cannot identify. The reporting
subcommands read the bdc_availability view under schema_v2, so there is one
copy of each query.
