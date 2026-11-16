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

## ACCESS: step 1 is gated on a licence, not on code

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

NOT VERIFIED, and this is the single question that decides whether step 1
needs the licence at all:

- Whether the PUBLIC per-state availability file carries a census block or
  tract GEOID alongside the Location ID. If it carries block_geoid, the tract
  is the first 11 digits of the 15-digit block GEOID and steps 4 to 7 need no
  Fabric licence. If it carries only Location ID, then tract assignment
  REQUIRES the Fabric, because only the Fabric maps a Location ID to a place.
- The two FCC documents that would settle it, Broadband Map Data Downloads and
  the BDC public data API specification, both returned HTTP 403 to automated
  fetching from this sandbox. They open in a browser.

HOW TO SETTLE IT CHEAPLY: download one small state from
broadbandmap.fcc.gov/data-download, one technology, and read the CSV header.
Rhode Island or Delaware. That is a two-minute job in a browser and it decides
whether the licence is on the critical path.

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
- Step 5's "uninterrupted coverage between it and the centroid" needs a
  definition of coverage continuity along a path. Not specified yet, and it is
  the only step with a genuinely novel algorithm in it.
- Step 6 rests on ip-api.com locating IPs at or near a headend. Measured
  2026-11-12 on 65.218.12.0/23: all 512 addresses returned a single identical
  answer, ZIP 02112, Boston, Verizon Business, with the district and reverse
  fields EMPTY. So ip-api gives one point per range, not per address, and that
  point is the registrant or aggregation location. Whether that point
  coincides with a headend is the hypothesis step 6 depends on and it is NOT
  yet tested.

## Immediate next action

Read the CSV header of one public state availability file. Everything else
waits on that, because it decides whether a CostQuest licence is on the
critical path or merely useful.
