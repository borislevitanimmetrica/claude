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
  bdc_carrier_tbl. Twenty-seven distinct providers across these two states.
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

## Step 2, started 2026-11-17: carrier nodes located from their own hostnames

### What step 2 needs from a hostname

A hostname gives the ROUTER's location. geo/node_fanout.sql says so, as a
warning against using it for the subscriber's location. Step 2 wants the
router's location, so it is simply the right field to read. Demonstrated
rather than argued: po-1-rur201.westroxbury.ma.boston.comcast.net decodes to
boston at 42.358430, -71.059770 and not to westroxbury.

### A COMPARISON I DREW THAT WAS WRONG, corrected by Boris 2026-11-17

An earlier version of this section framed step 2 as a "reversal" of the flaw
that killed the landmark method, as though step 2 had inherited a failure
mode and overcome it. Boris: "I do not see failure modes in the plan I wrote
... I don't understand your comparison of the two for failure modes."

He is right and the framing was wrong. The landmark method failed for three
reasons, all of them about LANDMARKS: too few of them per ZIP even for a
dominant carrier, sitting on IP ranges unrelated to subscribers, and behind
CPE-connecting nodes that traceroute often cannot see. None of the three
transfers to this plan, because this plan takes the ZIP from the FCC BDC
service footprint of a carrier and technology, which is a census of every
served block rather than a sparse sample, and uses the node only as the thing
ip-api resolutions congregate at. The node's own location is an intermediate
quantity, not the answer.

I was arguing against an objection nobody had raised, and in doing so implied
a weakness in his plan that is not there. Recorded because the error was
mine and the framing is now removed from the live text above.

### The asset that was already paid for and never used

geo/landmarks/hoiho_suffixes.sql loaded the CAIDA Hoiho ruleset's METADATA on
2026-11-06, 871 domains with their scores, and recorded that the regexes stay
in the CAIDA jsonl and would need applying. geo/carrier_nodes/hoiho_apply.py
applies them. The file is 212,714 bytes and the download is public and
unauthenticated.

MEASURED 2026-11-17 on the 2025-08 release: 871 domains, 1,045 regexes, every
one of which Python's re module compiles. 15,952 geohints, 11,444 with
coordinates:

    iata       6,081   all with coordinates    476 domains   metro
    place      5,144   all with coordinates    323 domains   town or city
    clli       4,508   NONE with coordinates     89 domains   building
    locode       203   all with coordinates      12 domains
    facility      16   all with coordinates       2 domains   carrier hotels

### A CLAIM I MADE AND RETRACTED WITHIN THE HOUR

I first reported that CAIDA had embedded coordinates for the CLLI hints,
which would have removed the LERG blocker isp_node_feasibility.md identified.
WRONG. Zero of the 4,508 CLLI hints carry coordinates and none carries a
location object; a CLLI hint is the bare six-character code. The blocker
stands exactly as that file described it.

### Three bugs found by running it, not by reading it

1. A Hoiho rule can have SEVERAL capture groups. Comcast's
   ^[^.]+\.[a-z\d]+\.([a-z]{2})\.([a-z]+)\.comcast\.net$
   captures the state and the place separately, and reading group 1 returned
   ma and resolved nothing. Every group is now a candidate.

2. A code is NOT unique within a domain. 213 (domain, code) pairs repeat
   across 26 domains, up to seven times, and 201 repeat WITHIN one hint type.
   The load failed on alter.net/dtm, which is Dortmund by IATA and Dortmund
   by place with coordinates 11 km apart. The primary key was wrong and the
   in-memory index silently kept whichever hint loaded last.

3. THE DANGEROUS ONE. comcast.net/springfield has SEVEN hints: IL, FL, MA,
   OR, GA, MI, TN, whose extremes are 4,032 KM APART. Choosing by CAIDA's
   true-positive count picks Springfield IL. But Comcast hostnames carry the
   state as a separate capture group, so a hint whose state matches a
   two-letter group from the same hostname now wins over a better-scoring
   one. 67 of the 213 ambiguous codes are fully separable this way.
   Verified: ...springfield.ma.boston.comcast.net resolves to Springfield MA.
   Without this, Massachusetts nodes would have been placed in Illinois and
   nothing would have complained.

   Widest alternatives for one code, measured: comcast.net springfield
   4,032 km, lebanon 3,975, hillsboro 3,907, salem 3,898, aberdeen 3,880.

carrier_node_tbl records code_hint_count and selection for every row, so a
location chosen by score rather than by state agreement is identifiable
instead of indistinguishable.

### CLLI resolution is unblocked, at rate centre granularity

localcallingguide.com publishes LERG-derived data and answers PARTIAL CLLI
queries: lca_switch.php?switch=albyny returns every switch whose CLLI begins
with those six characters, with switch name and operating company.
xmlprefix.php?npa=518&nxx=464 returns the full eleven-character switch CLLI
ALBYNYGDDS0, its name ALBANY GUILDERLAND, VERIZON NEW YORK INC, and rc-lat
and rc-lon.

So the chain is: hostname, CAIDA regex, six-character CLLI, partial CLLI
query, switch and company and rate centre coordinates. All public.

WHAT THIS IS NOT: a rate centre is a TARIFF GEOGRAPHY and its coordinates are
a nominal centroid. Several central offices share one rate centre in a dense
metro. This locates a node to its rate centre and no finer, which is why the
columns are named rc_lat and rc_lon and why clli_site_tbl's comment says so.
Building precision is step 3's job and is not delivered here.

### The join step 2 does not have

Step 2 is per carrier AND per network type. Network type comes from the BDC
technology code. Carrier comes from two things that share no key: BDC gives
frn, provider_id and brand_name, for example 130317 Xfinity; a hostname gives
a DNS domain, for example comcast.net. Nothing public pairs them.

carrier_domain_provider_tbl is therefore created EMPTY, with basis NOT NULL so
a row cannot be added without recording what established it, and confirmed
defaulting to false. Until it is seeded, step 2 reports nodes per DNS domain
and cannot report them per BDC carrier and technology. An AS-number match or
an RDAP registrant match is evidence; a similar-looking name is not.

### Sources checked and what they gave

- CAIDA publicdata: open, no credentials. The correct path is
  /datasets/topology/ark/ipv4/itdk/2025-08/, not the one in my first attempt.
- localcallingguide.com: open, LERG-derived, partial CLLI search works.
- data.fcc.gov and www.fcc.gov: HTTP 403 to this sandbox with every header
  combination tried, including the full browser set that works for
  broadbandmap.fcc.gov. So FCC ASR and ULS, which would give exact
  coordinates for licensed fixed wireless sites, are UNASSESSED rather than
  unavailable: Boris's machine may reach them. Worth one probe before
  concluding anything.
- Census TIGER and the tract gazetteer: open, 200, and the 2024 national
  tract gazetteer is a 2.4 MB download. That is step 4's centroid source.


## Step 2 continued, 2026-11-17: carrier identity across four sources

Boris: "If it is a list of carriers, it should relate carriers by name, and
names differ in ITDK, Fabric, ip-api.com and RDAP (in case we need it).
Obtain the names from each source and submit a list with fields per source
for my approval."

carrier_domain_provider_tbl was the wrong shape, pairing a DNS domain to a
single BDC provider_id. geo/carrier_nodes/carrier_crosswalk.sql replaces it
with carrier_crosswalk_tbl, one row per carrier and one column group per
source. The stub is dropped only after a count confirms it is empty, and it
was empty by construction.

### Three of the four sources link by MEASUREMENT

A carrier node has an IP address, that address sits inside a routed range,
and the range carries both ip-api's isp, org and AS string and an RDAP
registrant. So the DNS domain, the ip-api identity and the RDAP registrant
are joined through the node's own address with a countable number of nodes
behind each pairing. Containment is most-specific, ORDER BY masklen DESC
LIMIT 1, the same convention as landmark_carrier_node.sql section 2.

### BDC cannot, and that is the whole reason for the approval column

A BDC filing contains no IP address. The only available link is the name, and
the names do not match for the carriers that matter most. Verified on seeded
data that mirrors the real strings:

| ITDK domain | ip-api isp | RDAP registrant | BDC brand | proposed |
| --- | --- | --- | --- | --- |
| comcast.net | Comcast Cable Communications, LLC | Comcast Cable Communications, LLC | Xfinity | NO |
| charter.com | Charter Communications Inc | Charter Communications Inc | Spectrum | NO |
| cogentco.com | Cogent Communications | Cogent Communications | Cogent Communications | name equal |
| sbcglobal.net | AT&T Internet Services | AT&T Enterprises, LLC | AT&T Internet | name contained |

The two largest US residential carriers file under consumer brands that share
no words with their corporate names, so no name comparison can pair them and
asserting the pairing would be a guess. They need Boris's decision. That is
not a defect in the tool; it is the measurement telling us the link does not
exist in the data.

Normalisation is deliberately conservative: it strips punctuation and
corporate-form words only, and KEEPS cable, communications and broadband,
because those distinguish real companies and removing them would merge
distinct carriers.

### A bug that stopped Boris's run, and the fix

hoiho_apply.py apply died with OSError errno 7, Argument list too long, after
reading 22,790 hostnames from his trace corpus. I had built INSERT ... VALUES
statements 500 rows at a time into a psql -c argument, and the argument
vector has a size limit that SQL text built into it inherits. His coverage
figures from that run are therefore PARTIAL: 13,695 rows of 22,790.

Replaced with COPY FROM STDIN in CSV format, streamed. CSV rather than the
default text format because the values include regexes full of backslashes
and CSV quoting handles them without an escaping pass of my own invention.
Measured after the fix: 25,000 hostnames in 0.79 seconds.

Also fixed: node_rdap was created inside a conditional block but referenced
unconditionally later, so an absent rdap_registrant_tbl aborted the file at
the point it was meant to degrade. And a table named in a LEFT JOIN is
resolved by the planner whether or not a to_regclass guard in the ON clause
would be false, so bdc_carrier_tbl is reached through a temp shim built
before the query is parsed.

### A column set I have NOT verified

The ip-api column names isp, org and "as" come from the UPDATE in
geo/check_geo_ip-api/cmd/main.go. The standing order says never to take a
column name from a source file, because that states what the current build
would write and not what the deployed table holds. The crosswalk file
therefore prints the real columns from information_schema and RAISES rather
than proceeding if any are missing. The validation fixture was also missing
them, which is how this surfaced.

### What Boris's partial run already showed

From 13,695 decoded hostnames before the crash:

    located                                        3,395   83 domains, 538 sites
    clli code, needs clli_resolve                  1,358   35 domains, 444 codes
    regex matched, code not in the ruleset hints     793   64 domains, 342 codes
    domain has rules but none matched                3,544  117 domains
    no rule for this domain                         4,605  1,908 domains

Per carrier, the ones that matter for step 2: charter.com 1,720 hostnames
with 480 CLLI pending and 306 distinct sites; comcast.net 1,715 with 879
already located and 270 sites; frontiernet.net 457 hostnames and 146 sites
but ZERO located and ZERO clli pending, which needs explaining;
verizon-gni.net 329 with 327 CLLI pending and only 22 sites.

frontiernet.net having 146 distinct sites and no locations at all is the
first thing to look at after the re-run, because 324 CLLI hints exist for
that domain in the ruleset at ppv 0.990.

### data.fcc.gov is not blocked, the path is retired

Boris's probe returned HTTP 302 to www.fcc.gov/what-can-we-help-you-find,
not the 403 this sandbox gets. So the host is reachable from his machine and
the /download/pub-acc-sys/ path no longer exists. FCC ASR and ULS, which
would give exact coordinates for licensed fixed wireless sites, need their
CURRENT bulk-download URLs found. Still unassessed, now for a different
reason.

### The frontiernet.net anomaly explained, and it was a fourth bug of mine

Boris's partial run showed frontiernet.net with 457 hostnames, 146 distinct
codes and ZERO located, ZERO clli pending, while the ruleset holds 324 CLLI
hints for that domain at ppv 0.990. Diagnosed 2026-11-17 by reading the rules
rather than guessing:

    ^.+\.([a-z]{4})\.([a-z]{2})\.frontiernet\.net$

captures the place and the state as SEPARATE groups, from a hostname of the
form ...adln.ca.frontiernet.net. The hints are six-character CLLI codes,
adlnca being the first. So the code is the two groups JOINED, and trying adln
and ca individually resolves nothing.

Fixed: the concatenation of all capture groups is now a candidate code, tried
before the individual groups because six characters of CLLI is a more
specific reading than a bare four-character place token. Verified:
dynamic-acc-1-2-3.hsd1.adln.ca.frontiernet.net now returns adlnca.

33 domains have multi-group rules whose hints are longer than any single
group, so this was not one carrier's quirk. By router count the largest
affected are comcast.net 255,906, windstream.net 16,956 with 281 CLLI hints,
frontiernet.net 15,357 with 324, comcastbusiness.net 9,328, ntt.net 3,784,
rr.com 1,525 with 233, ziplyfiber.com 1,282.

Also confirmed from the ruleset, consistent with
geo/landmarks/isp_node_feasibility.md: uniti.net and twelve99-cust.net are
NOT in the ruleset at all, which is why they showed 143 and 111 hostnames
with zero sites. That is a gap in CAIDA's coverage, not a bug here.

### Running total of bugs in step 2, all found by running it

1. Read only capture group 1, so Comcast returned a bare state code.
2. Assumed a code was unique within a domain; 213 pairs repeat.
3. Chose between ambiguous codes by score, which put Springfield MA in
   Illinois, 4,032 km away.
4. Built INSERT text into a psql argument, which died at 22,790 hostnames.
5. Never tried the concatenation of capture groups, which cost
   frontiernet.net, windstream.net and 31 other domains entirely.

Not one of these was visible by reading the code.

### Bug six: the node table was keyed on hostname alone

The approval list came back empty because `apply` wrote NOTHING. It failed on
Boris's corpus with a duplicate key on hostname
113.115.207.atginternet.com, and since COPY is one transaction, nothing
landed at all.

Cause: the query selects DISTINCT on the PAIR (hostname, address) while the
table was keyed on hostname alone. ONE HOSTNAME ANSWERS ON SEVERAL
ADDRESSES, because router interfaces share a PTR.

The fix keeps every pair rather than collapsing to one row per hostname, and
that is not merely a key change. Step 6 ascribes IP addresses shown by ip-api
to a node, so the address-to-node pairs ARE the link that step needs.
carrier_node_tbl now has a surrogate key and a unique index on
(hostname, coalesce(node_ip, '0.0.0.0')), the coalesce because node_ip is
nullable for the lasthop source and PostgreSQL before 15 treats NULLs as
distinct in a UNIQUE constraint, which would admit duplicates on exactly the
rows needing protection.

schema.sql detects the old single-column key and drops the table, with the
pre-mortem that it is written only by `apply`, which rebuilds it in under a
second, and nothing references it. Verified: the migration fires, the exact
failing hostname loads as three rows for one hostname, and a second run does
not duplicate.

Coverage now counts DISTINCT hostname and reports addresses separately, so
the two are no longer conflated.

### The name matcher missed secondary brands, which defeats the purpose

Equality and containment proposed Frontier Communications for
frontiernet.net and MISSED Frontier Fiber, a second brand of the same
carrier. Separating FIOS from xDSL requires every brand a carrier files
under, so missing one defeats the purpose of the exercise.

Added a third tier: a shared first significant word of four characters or
more also proposes, labelled 'first word only, WEAK'. It will propose wrong
pairs, which is what approval is for. Proposals are now reported grouped by
strength of basis, strongest first, and the uniqueness moved from
(itdk_domain, asn) to (itdk_domain, asn, bdc_provider_id) because several
candidates per domain is the normal case rather than an error.

Verified: frontiernet.net now proposes both brands, Frontier Communications
as 'normalised name equal' and Frontier Fiber as 'first word only, WEAK'.

### What Boris's database holds, from his run

    ip2city_dbiplite_probe_tbl   2,097,870 rows
    rdap_registrant_tbl             30,501 rows
    bdc_carrier_tbl                   722 rows, 677 distinct brand names
    carrier_node_tbl                     0, because apply had failed

722 provider rows with the BDC load still in progress. All four ip-api
columns this file needs are present on the deployed table, verified by the
runtime check rather than assumed: network cidr, isp text, org text, as text.

### Bugs seven and eight: I tested fresh installs, not upgrades

Two failures on Boris's database, both of which my tests passed:

    ERROR: cannot drop table carrier_node_tbl because other objects depend
           on it, view carrier_node_located depends on it
    ERROR: there is no unique or exclusion constraint matching the ON
           CONFLICT specification

Both are upgrade-path failures and both have the same root: CREATE TABLE IF
NOT EXISTS does nothing to a table that already exists.

The first: the migration dropped carrier_node_tbl, but the view defined at
the foot of the same file depends on it. I HAD ALREADY HIT AND FIXED THIS
EXACT THING in geo/fcc_bdc/schema_v2.sql earlier the same day and failed to
generalise it. My test built the old-shape table WITHOUT the view, so the
real path was never exercised. Fixed with DROP TABLE ... CASCADE, the view
being recreated unconditionally at the end of the file.

The second: his carrier_crosswalk_tbl already carried the original
UNIQUE (itdk_domain, asn), so widening it inside CREATE TABLE IF NOT EXISTS
never reached his install and ON CONFLICT had no matching constraint.
geo/traceroute_hostname_rules.sql documents this precise trap, in a comment
recording that it once caused zero rules to load while the run looked
successful, and the context report put it in front of me. I walked into it
anyway.

Fixed by removing the dependency on any constraint: unapproved proposals are
DELETED and regenerated, and the insert skips anything duplicating an
approved row. That is better behaviour as well as more robust, because a
better name matcher or more loaded BDC providers should change the
proposals. The stale constraint is also dropped for tidiness.

### geo/carrier_nodes/test_upgrade_path.sh

Written because the failures above were not detectable by any test that
starts from an empty database. It builds the PREVIOUS schema including the
dependent view and the old constraint, inserts an APPROVED row, seeds all
four sources, then runs the current files over it and checks:

- the primary key of carrier_node_tbl became node_id
- carrier_node_located exists again
- the hostname that broke the load, 113.115.207.atginternet.com, loads as
  two address rows
- the approved row and its note survived
- a second crosswalk run changes nothing

All pass. Any future schema change to these files should be run through it
before being issued, because testing a fresh install only proves the easy
half.

### One refinement the upgrade test exposed

An approved row is never deleted, so it kept the measured values it had when
approved while a freshly measured proposal appeared beside it. Section 4 now
UPDATEs the measured columns on approved rows, touching only ip-api, RDAP and
the node count, and never approved, approved_at, note or the BDC choice. New
evidence about a carrier is not a reason to revisit a decision about it.

Known and harmless: a carrier with an approved BDC pairing can still show a
second unapproved row carrying no BDC candidate. It proposes nothing and can
be ignored or suppressed on request.

### Bug nine: a carrier name that normalises to nothing

The run reached section 3 and aborted:

    ERROR: null value in column "name_norm" of relation
           "carrier_name_observed_tbl" violates not-null constraint
    DETAIL: Failing row contains (ipapi_org, The, null, ...)

ip-api carries an org of literally "The". carrier_name_norm strips corporate
words, "the" is one of them, so the result was an empty string, nullif made
it NULL, and the NOT NULL column rejected it after 1,480 rows had already
been inserted. "US", "Inc" and "The Group" do the same.

Fixed in two places. The function now falls back to the punctuation-only
normalisation when stripping the corporate words would empty the name, so
"The" becomes "the" and matches nothing useful, which is the correct outcome
for a string that is not a carrier name. And name_norm is nullable, because a
name of pure punctuation normalises to nothing and such a row is still worth
holding as an observation. Measured after the fix: The, US and USA Inc
normalise to the, us and usa inc; "!!!" and "---" normalise to NULL and are
retained.

A migration drops the NOT NULL for installs that already have the table,
since CREATE TABLE IF NOT EXISTS would not have.

Both cases are now in test_upgrade_path.sh, which fails if a name that
strips to nothing is dropped.

### Step 2 is working. The first real numbers, from Boris's corpus

22,790 hostname and address pairs over 22,302 distinct hostnames, so 488
pairs are extra addresses on a hostname already counted.

    located                                       5,103 hostnames  102 domains  725 sites
    clli code, needs clli_resolve                 2,409 hostnames   53 domains  644 codes
    regex matched, code not in ruleset hints        629 hostnames   69 domains  285 codes
    domain has rules but none matched             3,867 hostnames  135 domains
    no rule for this domain                      10,294 hostnames 3,910 domains

Per carrier, the ones that matter:

    comcast.net        2,958 hostnames  2,014 located     464 sites
    charter.com        1,725 hostnames    480 clli        306 sites
    spectrum.com       1,589 hostnames      0             0 sites, NO RULES
    cogentco.com         963 hostnames    935 located     116 sites
    frontiernet.net      577 hostnames    475 clli        156 sites
    verizon-gni.net      384 hostnames    361 clli         59 sites
    verizon.net          355 hostnames    351 clli         18 sites
    cox.net              281 hostnames      0             0 sites, NO RULES
    twelve99-cust.net    222 hostnames      0             0 sites, NO RULES

The frontiernet fix worked: 475 CLLI codes and 156 sites where the previous
run had zero of both.

2,409 hostnames across 644 CLLI codes are waiting on clli_resolve, and they
include almost all of Charter, Frontier and both Verizon domains. That is now
the single highest-value remaining piece of step 2.

spectrum.com at 1,589 hostnames, cox.net at 281 and twelve99-cust.net at 222
have NO rules in the CAIDA ruleset at all, which matches what
geo/landmarks/isp_node_feasibility.md recorded as uncovered operators. Those
need rules written from observed hostnames or they contribute nothing.

ip-api identified a range for 21,060 of the 22,790 node addresses, 17,716
with an isp and 17,041 with an AS string, across 3,908 domains.

## 2026-11-17: the crosswalk hung, and two wrong diagnoses before the right one

Boris: "Proposed BDC pairings have not yet appeared in around 10 minutes. Is
this expected?" No. It was mine, and he could interrupt it safely because the
DELETE of unapproved rows had already committed and approved rows are never
touched.

### Two hypotheses I formed and had to discard

FIRST, WRONG: that carrier_name_norm being called inside the join was the
cost. The ON clause does call it 24 times per candidate pair across 3.08
million pairs, about 74 million invocations of a function doing four regex
passes. Measured on a count, that shape took 169 SECONDS against under a
second with the normalisation precomputed, both returning the identical
442,326 pairs. So the concern was real and the fix is kept. But it was NOT
the thing making the file hang: the whole file still took 225 seconds after
it.

SECOND, WRONG: that bdc_carrier_shim had no statistics, being built inside a
DO block, so the planner was choosing badly. ANALYZE was genuinely missing
and is now added. The file still took 230 seconds.

THIRD, MEASURED: the join is innocent. The full join including the
domain_rdap left join and the NOT EXISTS, producing the same 177,577 rows,
takes 645 MILLISECONDS. The 225 seconds is the INSERT WRITE: 177,577 rows of
367 bytes into a table with a bigserial and five indexes.

So the problem was never the query shape. It was the ROW COUNT.

### The row count, and how much of it is my fixture's fault

My scale fixture gave 749 BDC providers only 8 distinct brand names across
its first 400 rows, so every ip-api name matched about 50 providers. Boris's
real data has 677 distinct brand names in 749 rows. His proposal count will
therefore be far lower and I CANNOT predict it from this fixture, which is
exactly why the file now counts before it writes.

### What was added

- \timing on. Its absence is why ten minutes passed without knowing which
  statement was slow. Any analysis file that can run for minutes should have
  it.
- Section 4a counts the proposals per tier BEFORE inserting and prints a
  verdict. The count is sub-second; the insert is the expensive part.
- Above 20,000 total, the weak first-word tier is skipped.
- Above 20,000 from equality and containment ALONE, no BDC pairing is
  inserted at all. The measured ITDK, ip-api and RDAP crosswalk still goes
  in, so the sound part is delivered and only the BDC column is left empty.
  Inserting an unreviewable list is worse than delivering the part that
  holds.
- Section 4b names the over-matching names whenever the count is large,
  because a handful of generic names matching many providers is what makes
  the list explode, and the carrier count is not the cause.

Measured on the degenerate fixture: 225 seconds before, 110 with the weak
tier skipped, 6 SECONDS with the hard stop, and it names
'at t internet services' as matching 50 BDC providers. On the realistic
fixture nothing is suppressed and all tiers are proposed.

### The pattern across bugs four to ten

Four of the last seven were cases where I reasoned about what the code would
do instead of measuring what it did: the argument-list limit, the hostname
key, the two upgrade-path failures. This one is the clearest instance: I
formed two plausible mechanical explanations, implemented both, and neither
was the cause. Reading the plan took one command and settled it.

## 2026-11-17: Boris's rulings on the carrier crosswalk

He reviewed the list and returned it in three groups. The annotations first
arrived as an image truncated at the right edge; I reported what I could read
and what I could not rather than inferring, and he then sent the text. Three
of my readings from the image were WRONG and the text corrected them:

- avglens.com, which I had read as avgens.com
- hobbsnm.org, which I had missed entirely, so it is EIGHT not-an-ISP
  domains rather than seven
- AS397866, which I had read as AS39780

### The model error, which mattered more than the misreadings

I had built the Windstream group as alias_to: fold several domains into one
parent carrier label. WRONG. Each of the five domains maps to FIFTEEN named
Windstream subsidiaries, which are state-level legal entities filing
separately in BDC: Accucomm Telecom, Alabama, Arkansas, Communications,
Florida, Georgia Communications, Georgia, Georgia Telephone, Iowa
Communications, Kentucky East, Kentucky West, Lexcom Communications,
Missouri, Montezuma and Standard.

A single alias cannot express one domain to many providers, and shipping it
would have discarded fourteen fifteenths of the mapping. Replaced with
use_bdc_name, which permits many rows per domain, and carrier_resolved now
returns one row per domain AND provider. Verified: uniti.net yields 15 rows.

### The three decision types

    use_bdc_name     value is a BDC provider name, verbatim. Many per
                     domain is normal.
    use_bdc_of_asn   value is an ASN. Boris: "use the NAME IN BDC of the
                     operator of the shown ASN". The ASN is the lookup key,
                     not the answer, so my first attempt at this as
                     use_as_name was also wrong.
    not_an_isp       the domain leaves the crosswalk entirely.

### How an ASN becomes a BDC name

BDC filings carry no AS number, so there is no join. What exists is measured:
the ip-api "as" string per range is of the form
'AS7922 Comcast Cable Communications, LLC', so an ASN yields its operator
name from data already held. That name is then matched against BDC brand
names and the candidates reported.

Verified on seeded data mirroring the real strings:

| domain | ASN | operator observed | BDC name resolved |
| --- | --- | --- | --- |
| bright.net | 7106 | Windstream Communications LLC | Windstream Communications, LLC. |
| earthlinkbusiness.net | 397866 | EarthLink Holdings Corp | EarthLink Holdings Corp |
| lrmutual.com | n/a | named directly | Mutual Telephone Company |

A name Boris gave that is NOT found in bdc_carrier_tbl is kept with a null
provider_id and labelled 'named by Boris, NOT FOUND in bdc_carrier_tbl',
because the BDC load may simply not have reached that provider yet and
silently dropping a ruling would look like a decision never made. Measured on
the fixture: 11 of uniti.net's 15 names were not yet loaded and all 11 were
reported rather than lost.

### Files

- geo/carrier_nodes/decisions_2026_11_17.tsv, his rulings as data, committed
  so there is no transcription or paste risk.
- geo/carrier_nodes/carrier_decisions.sql, the decision table and the
  carrier_resolved view that steps 4 to 7 should join to.
- geo/carrier_nodes/load_decisions.py, which accepts either a per-row file or
  the GROUP form his sheet actually uses, where a decision name on its own
  line applies to every following row.

### Three more bugs, all caught by executing rather than reading

- PRIMARY KEY (itdk_domain, decision, coalesce(value, '')) is a SYNTAX ERROR:
  PostgreSQL does not allow an expression in a primary key. Replaced with a
  surrogate key and a unique index on the expression. I had run the
  text-level check_sql.sh on this file but NOT run_sql_validation.sh, which
  executes it and would have caught this in one second.
- carrier_decisions.sql depended on carrier_name_norm and
  carrier_crosswalk_tbl from carrier_crosswalk.sql, and failed 210 lines in
  with "function carrier_name_norm does not exist". Now a guard at the top
  names every missing prerequisite and the order to run them in.
- That guard was itself broken: array_var || 'text' makes PostgreSQL read the
  string as an array literal, giving "malformed array literal". Needs
  ::text. It only surfaced because I tested the FAILURE path, which the
  normal run never reaches.

## 2026-11-17: bdc_provider_tbl renamed, and why the loader appeared to hang

### The rename

Boris: "bdc_provider_tbl should be renamed bdc_carrier_tbl. We have
heretofore used carrier to denote ISPs and provider to denote hosting and
cloud services." The table lists ISPs, so it is carriers. I had used
provider because the FCC's own column is provider_id.

Renamed repo-wide: bdc_provider_tbl to bdc_carrier_tbl, bdc_provider_shim to
bdc_carrier_shim, and the surrogate key provider_key to carrier_key.
provider_id KEEPS ITS NAME, because it is the FCC's column in the BDC
download and renaming it would break the correspondence to the source file
that the loader and every comment depend on. Verified the rename did not
touch it: 9 occurrences in schema_v2.sql and 14 in bdc_load.py, before and
after.

geo/fcc_bdc/rename_provider_to_carrier.sql does the migration and NOTHING
ELSE: no DROP, no TRUNCATE, no DELETE. It is deliberately NOT inside
schema_v2.sql, which drops and truncates, because a rename should never
require running a file that can also empty a table. Verified: 1,804 rows
before, 1,804 after, and running it twice is a no-op.

While looking at that, found schema_v2.sql TRUNCATES bdc_carrier_tbl. It is
entitled to, being a schema replacement guarded on the availability table
being empty, but a silent truncate of a table holding 1,802 carriers is not
something to discover afterwards. It now reports the counts it will remove.

### Why load_decisions.py produced no output for minutes

MEASURED at Boris's row counts, 2,097,870 probe rows and 1,802 BDC carriers:

    asn_operator as a view        1.8 seconds
    asn_bdc_name as a view      195 seconds
    carrier_resolved              2.6 ms, ONLY because his decision table
                                  was still empty so nothing drove the join

asn_bdc_name compared every distinct ASN against every BDC carrier calling
carrier_name_norm inside LIKE patterns, 7.2 million pairs in the fixture. As
a VIEW it re-ran on every reference, and carrier_resolved references it, so
the moment decisions existed the loader drove straight into it.

THIS IS THE SAME MISTAKE measured and fixed in carrier_crosswalk.sql earlier
the same day, normalisation inside a join, which I did not generalise.

Fixed three ways: the normalisation is precomputed per row; the tables are
materialised rather than views; and only the ASNs that actually appear in a
use_bdc_of_asn decision are resolved, THREE on his rulings rather than
several thousand. Result: 10.2 seconds including the 2.1 million row scan,
against 195 seconds per reference.

### DROP TABLE CASCADE, for the third time in one session

resolve_asn.sql first dropped and recreated its two tables. carrier_resolved
depends on asn_bdc_name_tbl, so the CASCADE took the view with it and the
next query failed with "relation carrier_resolved does not exist". The same
mechanism had already bitten geo/fcc_bdc/schema_v2.sql and
geo/carrier_nodes/schema.sql earlier the same day.

The tables are now declared once in carrier_decisions.sql and only ever
TRUNCATEd and refilled. TRUNCATE touches no dependency. resolve_asn.sql
contains no DROP at all.

### Two ordering traps now signposted

carrier_nodes/schema.sql DROPS and recreates carrier_node_tbl when it
migrates the key, so the crosswalk afterwards sees an empty table and
produces a blank approval list. That is exactly what happened to Boris: his
crosswalk reported zero everything because the schema file had just emptied
that table. The crosswalk now RAISES A WARNING naming the command to run
first.

And resolve_asn.sql is driven by decisions loaded after carrier_decisions.sql
runs, so load_decisions.py re-runs that same file itself rather than leaving
the tables empty.

### An over-match the fixture exposed

An operator named 'Operator 7106' also matched 'Operator 7', 'Operator 71'
and 'Operator 710' by containment, giving one ASN three carrier labels.
Containment is now kept only where no exact normalised match exists for that
ASN. Verified both ways: with no exact name present, three containment
candidates; with 'Operator 7106' added to BDC, exactly one row at
'normalised name equal'.

### Correct order to run

    psql -f geo/fcc_bdc/rename_provider_to_carrier.sql
    psql -f geo/carrier_nodes/schema.sql
    python3 geo/carrier_nodes/hoiho_apply.py apply
    psql -f geo/carrier_nodes/carrier_crosswalk.sql
    psql -f geo/carrier_nodes/carrier_decisions.sql
    python3 geo/carrier_nodes/load_decisions.py load --file ...

## 2026-11-17: the fourteen-minute query, and the blank list

Boris, after fourteen minutes with nothing returned: "Instruct whether to
abort. Fix the problem in Your crosswalk reported zero everything."

### Abort: yes

carrier_decisions.sql ends in a SELECT. Everything it creates was already
committed by earlier statements, so interrupting the last query loses
nothing.

### The blank approval list, fixed properly

geo/carrier_nodes/schema.sql DROPS and recreates carrier_node_tbl when it
migrates the key. The crosswalk run immediately afterwards therefore saw an
empty table and reported zero of everything, and it did so as a WARNING, so
the file ran to completion and handed over a blank list that looked like a
result.

Now an EXCEPTION. Nothing before that point writes, so stopping costs
nothing, and the message names the command to run. Verified: the file aborts
with "carrier_node_tbl IS EMPTY ... Run this, then re-run this file: python3
geo/carrier_nodes/hoiho_apply.py apply".

A warning was the wrong instrument. The whole value of the check is to stop
a blank result being mistaken for a finding, and a warning does not stop
anything.

### carrier_resolved was a view, and that was the fourteen minutes

The final statement is count(DISTINCT carrier_label) FROM carrier_resolved.
Two faults, and the second is the one that keeps recurring:

  1. The view used NOT IN (SELECT itdk_domain FROM carrier_crosswalk_tbl)
     TWICE. NOT IN against a subquery on a nullable column cannot be planned
     as an anti-join and degrades to a subplan re-executed per row. Both are
     now NOT EXISTS, which can.

  2. It was a VIEW behind an aggregate, so the entire UNION ALL was
     recomputed for one number. I had materialised the ASN tables for
     exactly this reason minutes earlier and left this one a view.

carrier_resolved_tbl is now a table, filled by resolve_asn.sql, with
carrier_resolved kept as a thin compatibility view over it. No DROP
anywhere: TRUNCATE and INSERT, because carrier_resolved depends on the
table and CASCADE has already removed a dependent view three times in this
project.

### A statement timeout, so this cannot happen silently again

Both files now SET statement_timeout = '10min'. Every statement in them is
expected to take seconds, so reaching that limit means the query is wrong
rather than the data large, and it now says so instead of sitting there.
Boris has twice watched a prompt with nothing to say, for ten minutes and
then fourteen. That is a tooling failure, not a patience problem.

### geo/carrier_nodes/run_step2.sh

The ordering has two traps and I handed Boris the wrong order twice:

  schema.sql drops carrier_node_tbl, so the decode must run after it and
  before the crosswalk.

  resolve_asn.sql is driven by decisions loaded after carrier_decisions.sql
  has run, so the derived tables are empty until load_decisions.py refills
  them.

Neither is worth remembering, so the script encodes it. Six steps, stops at
the first failure, prints the failing step and the error lines from its log,
and ends with a count of what was built. Verified green end to end in one
second, and verified that it stops correctly when a step fails: a missing
CAIDA ruleset reported "Run hoiho_apply.py fetch first" and went no further.

Also found while testing it: the \i of resolve_asn.sql sat next to the ASN
table declarations, but that file now also fills carrier_resolved_tbl, which
is declared further down. Moved the include below all three declarations.

## 2026-11-17: the rename broke a running load. What went wrong and the fix

Boris: "The BDC load errored at bdc_42_Other_fixed_broadband_J26_10nov2026.zip
because the table into which it was loading had been renamed."

I caused that. I knew his BDC load was running, I had written comments in two
files saying so, and I still handed him a DDL rename that takes ACCESS
EXCLUSIVE on a table that load writes to. The rename waited, eventually got
the lock between the loader's per-file transactions, and committed. The
running Python process still held the old table and column names in memory,
so its next file failed.

Two separate faults:

  1. No lock_timeout, so the rename queued. A WAITING AccessExclusiveLock
     request sits at the head of the lock queue and blocks every later
     request on that table, so for the time it was queued it was also
     stalling the loader it was waiting for.

  2. Renaming a table out from under a live writer is wrong even when the
     lock is free, because a long-running process holds its SQL as strings.

### What was added

geo/fcc_bdc/rename_provider_to_carrier.sql now SETs lock_timeout to 2
seconds, prints the sessions holding a lock on the affected tables BEFORE
attempting anything, and on timeout raises a message saying nothing was
changed, naming bdc_load.py as the likely holder, and noting that the rest of
step 2 does not depend on the rename. VERIFIED by holding a ROW EXCLUSIVE
lock in another session: the rename gave up after 2 seconds, the table was
untouched at 1,802 rows, and the holder was never blocked longer than that.

run_step2.sh treats a deferred rename as a SKIP, not a failure, and says so,
because every later step works against either table name.

lock_timeout and statement_timeout are now set in all five SQL files that
issue DDL or long queries: carrier_nodes/schema.sql, fcc_bdc/schema_v2.sql,
rename_provider_to_carrier.sql, carrier_crosswalk.sql, carrier_decisions.sql.

bdc_load.py now recognises the PRE-RENAME shape specifically. Before, a
loader built after the rename met a database before it and reported only
"matches neither schema.sql nor schema_v2.sql", which is true and useless.
It now says the column is still provider_key, that nothing was changed, and
names the rename file to run, adding that completed files are skipped on
resume. VERIFIED both ways: refuses with that message before the rename,
loads 323,873 rows after it.

run_step2.sh also names its prerequisites up front, bdc_carrier_tbl,
ip2city_dbiplite_probe_tbl and ovt_places_usa_ip_trace, rather than failing
at step 5. It states that schema_v2.sql is NOT run automatically because it
truncates bdc_carrier_tbl.

### And a careless edit of my own

While adding the lock timeout I used a scripted replacement that matched the
words "CREATE IF NOT EXISTS" inside a COMMENT SENTENCE in
carrier_nodes/schema.sql and spliced the new header into the middle of it,
leaving fragments as live SQL and a syntax error at line 95. I had run the
text-level check_sql.sh, which passed, and not executed the file. Repaired,
and every file is now EXECUTED as part of verification rather than only
text-checked.

## 2026-11-17: a 135-character command line, and a log that never existed

Boris pasted the resume command. The job started, printing a pid, and then
tail reported the log file did not exist. Residue from the paste, the
fragment "ll.log 2>&1", was visible on his prompt line BEFORE the cd.

The command was one line of 135 characters:

    nohup python3 geo/fcc_bdc/bdc_load.py load --files /home/boris/geo/bdc/*.zip > /home/boris/geo/logs/bdc_load_resume.log 2>&1 &

It wrapped in his terminal, part of it was taken as a separate command, and
the redirect never attached. The background job started without it.

Long single-line commands are a known hazard in his paste path, alongside
the mid-line hash and the backslash conversion already recorded in my
standing orders. I had been keeping those two rules and ignoring line length.

### geo/fcc_bdc/resume_load.sh

The long line now lives in a file and he pastes one short one. The script
also does three things the raw command could not:

- It CHECKS THE SCHEMA before starting. If bdc_availability_tbl still has
  the pre-rename column provider_key it stops, says nothing was started, and
  names the rename file. That is the exact state that killed his load, and
  it is better caught in a second than four hours in.
- It refuses when the directory holds no zip files.
- After starting it CONFIRMS THE LOG FILE EXISTS and prints its first lines,
  so a redirect that did not attach is visible immediately rather than when
  tail fails.

Verified all three paths: refuses on the pre-rename shape with the rename
command named; refuses on an empty directory; and on the correct shape
starts, the log exists, and the load completes with 323,873 rows.

Also measured: the longest line in the script is 130 characters, but that
file is PULLED rather than pasted, so its line lengths do not matter. What
matters is that the line Boris pastes is now 28 characters.

## 2026-11-17: the load was invisible, which is not the same as stopped

Boris: "There is no evident BDC load running." The job had started with a
pid and its log was empty.

Two causes, both mine, and neither tells us yet why the process is gone.
That is in the log and is not something to infer.

### Buffering

Python BLOCK-BUFFERS stdout when it is a file, so a redirected run writes
nothing until kilobytes accumulate. MEASURED: a script that prints and
sleeps leaves its output file at 0 bytes after two seconds; with python3 -u
the bytes are there immediately. resume_load.sh now runs the loader with -u.

For a job that runs for hours this is the difference between watching
progress and watching an empty file. It has now been the proximate cause of
"nothing is happening" three times in this project, twice for genuinely slow
queries and once for this.

### 333 silent psql subprocesses

cmd_load called rows_for_file once PER FILE to decide whether to skip it.
With 333 downloads and 241 already loaded, that is 333 separate psql
subprocesses before the first new file is reached, every one of them
printing nothing.

Replaced with ONE query returning rows per source_file for every file at
once. The loader now prints, flushed, how many files are already loaded and
how many remain, and names the first file it will actually load, before
doing any work. Skipped files no longer print a line each; the count is
reported at the end.

Verified: first run reports "0 already loaded, 2 to do" and names the first
file; second run reports "2 already loaded, 0 to do" and that both were
skipped; and the log is non-empty within five seconds of starting.

## 2026-11-17: frequent feedback, and a silently short file

Boris: "I asked you for frequent feedback in all operations." He had asked
for that from the beginning and I had been ignoring it in the place it
mattered most.

### What was silent

The load printed one line before a COPY and one after. A five million row
state file streams for minutes in between. From outside, that is
indistinguishable from a hang, and he has now had to ask three times whether
a job was alive.

Fixed:

- psql_copy streams in 4 MB chunks and reports megabytes and MB/s every five
  seconds, instead of handing the whole thing to shutil.copyfileobj.
- Each file is announced as "[n of N] name" with an ETA from the observed
  rate, so position in the run is always visible.
- The skip decision is one query for all files rather than one per file, and
  the counts of already-loaded and remaining are printed, flushed, before
  any work starts. Previously 241 already-loaded files meant 241 silent psql
  subprocesses first.
- resume_load.sh runs the loader with python3 -u. Python block-buffers
  stdout to a file: measured 0 bytes after two seconds without it.
- verify reports progress every ten files with an ETA, since it decompresses
  everything.

### The silently short file, which is a correctness problem not a cosmetic one

The log showed bdc_42_Other_fixed_broadband_J26_10nov2026.zip holding
exactly ONE row. That is the file that errored when the rename broke the
load. One row may be correct, because the Other technology files are tiny,
but NOTHING IN THE DATABASE COULD DISTINGUISH a complete load from a
truncated one.

Worse, DEMONSTRATED by experiment: with 33,632 of 323,859 rows present,
`load` reported "2 already loaded, 0 to do" and did nothing at all. A file
left short by a failed load is skipped on every future run and its missing
rows never arrive. No error, no warning.

bdc_load.py verify reads each download, counts its data lines and compares
with what is loaded. Verified three ways: all-match reports ok; a file
missing 290,227 rows is reported SHORT by name with the --replace command to
repair it, and the subcommand exits nonzero; and a file not loaded at all is
counted separately.

The availability INSERT is a single statement and therefore atomic, so a
file should be all-or-nothing. verify checks that invariant rather than
trusting it, which is the right posture given it has already been violated
once by an external event.

### Run order after a load

    sh geo/fcc_bdc/resume_load.sh
    python3 geo/fcc_bdc/bdc_load.py verify --files /home/boris/geo/bdc/*.zip

The second is not optional after an interrupted load.

## 2026-11-17: a guard that cannot guard, for the third time

I added a check for a leftover staging table written as:

    SELECT CASE WHEN to_regclass('bdc_stage_tbl') IS NULL THEN '-1'
           ELSE (SELECT count(*) FROM bdc_stage_tbl) END

It fails with "relation bdc_stage_tbl does not exist" whenever the table is
absent, which is the normal case. A TABLE NAMED ANYWHERE IN A STATEMENT IS
RESOLVED WHEN THE STATEMENT IS PARSED. The CASE never gets the chance to
short-circuit.

THIS IS THE THIRD INSTANCE OF THE SAME CLASS in this project:

  1. bdc_carrier_shim in carrier_crosswalk.sql, where a to_regclass guard in
     a LEFT JOIN's ON clause could not stop the planner resolving the table.
  2. DROP TABLE ... CASCADE in resolve_asn.sql removing carrier_resolved,
     twice before that in schema_v2.sql and carrier_nodes/schema.sql.
  3. This.

The rule, stated so it generalises: a PostgreSQL guard expressed INSIDE a
statement cannot protect against the absence of an object that statement
names. The guard must be a separate statement, or a DO block, or a shim
table built beforehand.

Fixed as two queries: existence first, count only if it exists. Verified
with and without the table present, and verified that a second load of the
same file still skips rather than duplicating, 14 rows staying 14.

### What else that test run established

At a realistic shape, 4,117 ITDK domains against 1,802 BDC carriers:

    equal          3,921
    contained     22,603
    first word  7,392,310
    total       7,418,834

The hard stop fired correctly: the strong tiers alone are 26,524, above the
20,000 limit, so NO BDC pairings were inserted and the crosswalk delivered
only the 4,117 measured ITDK, ip-api and RDAP rows.

SO THE BDC COLUMN WILL BE EMPTY ON BORIS'S RUN, and for a reason worth his
attention rather than a bug: ip-api carrier names and BDC brand names
over-match each other badly at this scale. 7.4 million first-word pairs is
not a tuning problem, it is the matcher being wrong for this data.

That needs his decision, and the options are not equivalent:
  - raise the threshold and accept a long list
  - drop the first-word tier entirely and keep equality and containment
  - require the ASN to agree as well, which would make the match measured
    rather than nominal
The third is the only one that improves the evidence rather than the volume.

### Still unexplained

Boris: "No BDC load is running because your code errors on the partial
file." I CANNOT REPRODUCE IT. Both my working copy and the committed
a2eeb78 load, skip and resume cleanly against a partially-loaded directory
including a one-row file and a leftover staging table. The error text is
needed; guessing at it has already cost two round trips today.
