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
