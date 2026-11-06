Handoff out of Session 3, written at the start of Session 4
===========================================================

2026-11-03

Session 3 produced no handoff of its own. It became unusable before one could be
written, so this memo is reconstructed by reading all 57,712 lines of
geo/sessions/TruGeo_Session_3_transcript.txt. The per-slice reading notes are in
geo/sessions/notes/part_01.md through part_12.md and carry the detail, the exact
numbers and the traps; this file is the summary and the state of play.

Treat the Oct 23 memo (Overture-RDAP-2) as superseded in several places.
Session 3 overturned parts of it with measurement. Those reversals are listed
below under "What Session 3 changed about the plan", because acting on the Oct 23
text alone would now repeat work that has already been done and rejected.


Where the project actually stands
---------------------------------

The pipeline works end to end. The problem is coverage, and coverage is the only
thing worth spending on.

  ZIPs with an on-premises landmark          9,728
  inhabited ZIPs, approximate target        41,700
  so coverage is about                         23 percent

That 9,728 is the number to quote. Earlier figures of about 15,954 ZIPs and 36
percent were measured BEFORE the hosting rule was applied and are too high. The
hosting rule roughly halved the landmark set.

  landmarks_usa rows                    14,094,616
  on-premises places after hosting rule     65,148
  on-premises addresses after hosting       24,152

One qualification that matters for any number you compute next. The hosting rule
has NOT been re-run since California was loaded. The last stored on-premises
count, 132,125 places, is a pre-hosting-rule figure, and address_hosting_tbl is
stale, built when the count was 120,352. Any comparison between 132,125 and
65,148 is comparing two different rules, not two different datasets.


What Session 3 changed about the plan
-------------------------------------

Landmark sources other than schools are finished, on measurement. Five sources
were ingested at a cost of 1,460,317 rows, an 11.3 GB OSM download and about 1.1
million RDAP lookups, and they produced six new ZIPs between them: dotgov 2,
foursquare 2, osm 2. No further general POI source should be ingested on that
evidence.

Public schools replaced them as the priority, and the state directories beat the
federal CCD because states fund their own schools and the federal release lags a
year. The decisive practical difference is that state files publish a website
column beside the address and CCD publishes no website at all, so CCD cannot
anchor a landmark by itself and is useful only as a key-join for coverage
checking.

California proved the approach: 8,816 usable schools, 1,367 ZIPs, which collapsed
to 556 addresses and then to 379 single-ZIP addresses, of which 94 ZIPs were
genuinely new. That is 0.97 percent added to the 9,728 base from one state, and
sixteen times what the previous five sources produced in total.

Name matching for the adjacency ownership test was dropped, on your argument
rather than a measurement. Weighted rare tokens fail exactly on multi-ZIP
institutions, where a sub-unit shares no rare token with the registrant, and
those false negatives are invisible because a rejected landmark leaves no trace.
The agreed gate is elimination plus the fan-out rule plus provider_names, and it
is to be tested after the national ingest, not before.

Adjacency applies WITHIN a registrant and never BETWEEN registrants. A provider's
own office counts as on-premises only when the ZIP is identical; adjacency must
never promote a provider.

mtr-based last-carrier-node work is built and ran, but the fan-out measurement
came in below the threshold set in advance: 2.66 landmarks per node against a
pre-registered 3, with only 21 percent of nodes measurable. The earlier claim
that Comcast is nearly ZIP-specific is dead, killed by your West Roxbury and
Lynn counterexamples and then by measurement showing 89.7 percent of measurable
Comcast nodes reject.


The blocker, diagnosed
----------------------

The file was the Florida Master School ID export, and it is misnamed by the
state, not by you.

  the FLDOE downloads page says   "They are in Excel format"
  content-type                    application/msexcel;charset=UTF-8
  content-disposition             filename=MSID_all_schools.xls
  the actual first sixteen bytes  44 49 53 54 52 49 43 54 09 53 43 48 4f 4f 4c 09

Those bytes are the ASCII text "DISTRICT<tab>SCHOOL<tab>". A real .xls begins
d0 cf 11 e0 a1 b1 1a e1; a real .xlsx begins 50 4b 03 04. The file is
tab-delimited text served under an Excel name with an Excel MIME type, so
anything that checks bytes against extension rejects it. Excel itself opens it
through its text importer, which is why Florida has presumably never had a
complaint.

The Florida file no longer needs to be sent at all. The "Download Files" button
is an empty POST to a second form on the page, and the endpoints behind it are
reachable from a datacentre address with no browser and no captcha. The file is
now committed at state_public_schools/fl_msid_all_schools.txt and the refetch
recipe, the other four endpoints and the measured contents are documented in
state_public_schools/readme.md.

This also corrects a Session 3 conclusion. Florida was recorded as requiring a
manual browser download. It does not.


Florida, measured
-----------------

Counted over one population, rows with a url-shaped WEB_ADDRESS and a five-digit
PHYSICAL_ZIP. Verified twice, by the probe and by an independent script, agreeing
on every figure.

  rows with website and physical ZIP        4,427
  distinct five-digit ZIPs                    787
  distinct website hosts                    2,594
  of those, ACTIVITY_CODE = A               3,707 rows, 757 ZIPs

Do not read 787 or 757 as a ZIP gain. California's 1,367 ZIPs became 94 new ones
after hosts collapsed to addresses and the hosting rule ran. Florida shares 39.3
percent of its rows on a host serving several ZIPs, against California's 32.9
percent, because Florida schools publish the district site with a per-school
path even more often. www.pcsb.org alone covers 39 ZIPs.


Defects found and fixed in this session
---------------------------------------

probe_state_files.py could not read Florida at all, and the cause was general
rather than Florida-specific. In a regular expression the underscore is a word
character, so the \b patterns introduced for Texas cannot see a boundary in
WEB_ADDRESS, PHYSICAL_ZIP or PHYSICAL_CITY. The probe reported "UNUSABLE, no zip
and no website column" for a file carrying 4,427 usable schools.

That made the Texas fix a regression for underscore-delimited files: the earlier
anchored version at least found PHYSICAL_ZIP through "^phys.*zip". The fix
normalises the header once, turning underscores, hyphens and dots into spaces,
rather than adding a separator alternative to every pattern.

Four further header-shape defects came out of the same file:

  Florida has no status column. ACTIVITY_CODE carries it, and the only headers
  matching "status" are MAGNET_STATUS and SI_TURNAROUND_STATUS. Left alone the
  probe would have printed a magnet breakdown for the operator to choose
  operating values from, which is the Texas "Magnet Status" error in a form that
  looks like a sensible answer.

  PHYSICAL_ZIP and MAILING_ZIP both match once the header is normalised, so the
  choice fell to file order. A mailing ZIP is frequently the district office or
  a post-office box in another ZIP, so a mailing column now loses to a physical
  one. This changes an answer, not a label.

  The name and district columns were resolving to SCHOOL and DISTRICT, which in
  Florida are numeric codes, not names. Specificity ordering now selects
  SCHOOL_NAME_LONG and DISTRICT_NAME.

  NCES ids were undetected in California too, because "\bnces\b" does not match
  NCESDist, for precisely the StatusType reason already documented in that file.

Regression checked rather than assumed. Texas output is byte-identical to PR 72
at both --level school and --level district, reproducing 7,325 rows and 1,392
ZIPs at school level and 9,785 and 1,088 at district level. California, tested
as a header fixture built from the merged ca-cde loader's own column names, is
identical except that ncesid now resolves instead of reporting none.


One defect found and NOT fixed, because it is your call
-------------------------------------------------------

At --level district the Texas file still reports name as "School Name". The
district role correctly gives "District Name", but the name role's first
productive pattern is "school ?name", whose only hit is the school column, so
prefer() never sees a district candidate to choose. A district-level load would
therefore carry the school's name against the district's ZIP and website, which
is the same class of error as reading the district's ZIP against the school's
website, the thing prefer() was written to stop.

The fix is to add a district-name alternative to the name role so that both
levels produce candidates. I have not made the change because it alters which
column a loader reads at district level, and the per-state loader config is yours
to settle. Say the word and it is a two-line change.


Open items, in the order they block things
------------------------------------------

PR 72 is still open and now carries this work as well. Nothing downstream is on
main until it merges. It contains unclassified_hosting_candidates.sql, the Texas
probe fixes from Session 3, and the Florida work from this session.

The hosting rule has not been re-applied since California loaded, so the current
stored on-premises count is pre-hosting-rule and address_hosting_tbl is stale.

Texas was fetched and probed in Session 3 but never loaded into lm_places_usa and
never run through the chain. Florida is now fetched and probed and likewise not
loaded. Neither should be loaded one state at a time: a per-state chain run pays
the fixed whole-table-scan cost of about four minutes per step four times over,
so fifty states run separately is roughly fifty-seven hours against about one
hour for a single pass. Ingest all states, migrate once with a scoped insert,
then run the chain once, then node_fanout and the hosting rule once.

The generic per-state loader is unwritten. California exists as the hand-built
ca-cde subcommand and should become one config row: state, delimiter, the column
names for school, address, city, ZIP, website and status, and which status values
mean operating. Three confirmed states was the threshold Session 3 set for
writing it, to avoid designing against a sample of one. With Texas and Florida
confirmed, California makes three.

The state open-data portal survey was promised and not done. Texas needed no
human at all, and Florida turns out not to have either, so the survey should
precede any further request for manual downloads. New York is the one state still
believed to need a browser, and that belief is now worth re-testing given Florida.

lm_fetch.py discards the district name. COLUMNS has no district field and
cmd_ca_cde uses District only as a fallback when School is blank. This was
flagged as a prerequisite for name matching, which has since been dropped, so it
may no longer be needed. It is still the only thing that would let the fan-out
rule distinguish a school on its district's host from a school on its own.

The z1/z2 defect, where an unmatched provider name variant leaves the provider's
registered ZIP available to the adjacency test, was promised and not confirmed
implemented. This is how Redmond 98052 landmarks appeared at 98005, 98008, 98033
and 98034.

The MX and NS yield test exists as mx_ns_yield.py but the 2,000-host random
sample was never run, so whether MX has value for schools is still unmeasured. A
four-district sample was not enough to conclude anything, as you said at the time.

From the Oct 23 memo and still open: the DMA API and GUI are built but not
deployed; the Overture delta procedure for daily additions, deletions and changes
is unwritten, as is the timestamped archival clone; ip_last_carrier_node,
ip_address_range and ip_last_carrier_node_range exist as columns that nothing
populates.


Standing orders carried forward
-------------------------------

These were established across Session 3 and are not restated in the Oct 23 memo.

  Never guess. Where guessing is the only source, flag it and offer a test.
  Label every command, and put only runnable commands in code blocks. Expected
  output goes in prose or a table, because a fenced block gets pasted and run.
  No placeholder values in anything runnable. A placeholder DATABASE_URL once
  overwrote a working one.
  Put sudo -v on its own line first in any block containing sudo.
  Add progress indication to anything long-running.
  Pre-mortem before anything destructive, and give rollback instructions.
  Add, populate, verify, then drop. Never rename a column in place: it destroys
  the ability to verify the value mapping, which already happened once.
  Only DoD ranges are excluded. Never Google, never a CDN, never any company
  that might reallocate numberspace to serving customers.
  False positives are acceptable, false negatives are not. An extra IP in a
  DMA list is harmless; a missing one loses a bid.
  Match exclusions by operator name, never by ASN.
  Probe only onpremises = true records, and only after computing onpremises.
  Do not conclude from tiny samples.
