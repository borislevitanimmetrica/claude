# Records with and without website and ZIP, per class

Measured 2026-11-06.

## The one column the database cannot produce

Every loader drops rows with no usable website **before** loading, because a row
with no hostname cannot anchor a landmark. So in `lm_places_usa` the count
"without a website" is zero for every source, and that zero is an artefact of
the loader rather than a fact about the world.

The OSM source is worse. Its Overpass query is

```
nwr["website"]["addr:postcode"](area.a);
```

so rows without a website were never **fetched**. No query against this database
can recover how many there are.

The real denominators therefore come from the source files' own row accounting.
`institution_ledger.sql` reports the database side; the tables below are the
file side, and together they are the answer.

## School files: full accounting, all 21 fetchable jurisdictions

Produced by `state_loader.py --all --dry-run`, which reads every live file and
balances its accounting without touching the database.

| key | source | rows read | usable | no website | no ZIP | not operating | other skips | ZIPs | hosts |
|---|---|---|---|---|---|---|---|---|---|
| CCD | ccd | 102,274 | **67,438** | **32,003** | 0 | 2,643 | 190 | 16,771 | 29,935 |
| GA | ga_gosa | 19,920 | 2,272 | 27 | 0 | 0 | 0 | 472 | 209 |
| IL | il_isbe | 9,999 | 3,599 | 5,545 | 0 | 0 | 4 | 879 | 1,107 |
| TX | tx_askted | 9,791 | 7,307 | 2,322 | 0 | 162 | 0 | 1,392 | 2,271 |
| FL | fl_msid | 7,212 | 3,700 | 1,058 | 15 | 2,427 | 12 | 757 | 2,253 |
| AL | al_alsde | 6,240 | 4,026 | 258 | 0 | 0 | 123 | 440 | 775 |
| MN | mn_mde | 5,904 | 4,152 | 0 | 0 | 0 | 1,164 | 544 | 1,240 |
| PA | pa_edna | 5,830 | 4,387 | 1 | 0 | 0 | 1,442 | 938 | 1,307 |
| AZ | az_azgeo | 5,559 | 3,565 | 704 | 9 | 1,274 | 7 | 365 | 1,366 |
| OH | oh_oeds | 5,322 | 2,524 | 0 | 6 | 0 | 2,792 | 509 | 1,172 |
| TN | tn_tnsd | 2,795 | 2,339 | 293 | 6 | 153 | 4 | 495 | 1,809 |
| NC | nc_dpi | 2,594 | 2,430 | 161 | 0 | 0 | 3 | 615 | 946 |
| WI | wi_dpi | 2,307 | 2,178 | 0 | 8 | 0 | 121 | 530 | 613 |
| IN | in_idoe | 1,987 | 1,789 | 197 | 0 | 0 | 1 | 498 | 856 |
| SC | sc_scde | 1,446 | 1,427 | 1 | 1 | 0 | 17 | 293 | 715 |
| IA | ia_educate | 1,324 | 1,085 | 239 | 0 | 0 | 0 | 410 | 400 |
| UT | ut_sgid | 1,241 | 952 | 112 | 0 | 0 | 0 | 184 | 595 |
| WV | wv_wveis | 906 | 575 | 220 | 46 | 0 | 0 | 235 | 400 |
| NV | nv_nde | 782 | 361 | 420 | 0 | 0 | 1 | 113 | 182 |
| ND | nd_insights | 515 | 504 | 11 | 0 | 0 | 0 | 187 | 205 |
| HI | hi_doe | 292 | 288 | 4 | 0 | 0 | 0 | 70 | 273 |
| **total** | | **194,240** | **116,898** | **43,576** | 91 | 6,659 | 5,881 | | |

The total double-counts: a school in Texas appears in both CCD and
`tx_askted`. De-duplication is by `NCESSCH`, which CCD carries and several state
files also carry, and it can only be measured after both are loaded.

Two files need a local copy and were skipped: **KS**, a legacy OLE2 `.xls`, and
**RI**, which has to be assembled from 1,203 pages. Their notes in
`states.json` record how to obtain each.

Georgia is worth a glance: 19,920 rows for 2,272 usable and only **209 distinct
hosts**, because the GOSA file is a grades extract with many rows per school and
nearly all of them point at one district site. High row count, low landmark
value, exactly what `pct_unique_hosts` exists to expose.

## Fire departments

| | rows | with website | without | with 5-digit ZIP | usable |
|---|---|---|---|---|---|
| USFA national registry | 27,117 | 8,721 | 18,396 | **27,117, all of them** | 8,685 |

Against roughly 29,452 US fire departments that is 92 per cent of the universe
present and 29 per cent of it carrying a website. USFA states its own coverage
at about 92 per cent, which agrees.

## Where the CCD school gap actually is

32,003 open schools have no website in CCD. The gap is concentrated, and the
column that matters is the last one.

| ST | open schools | with site and ZIP | gap | covered | state file built? |
|---|---|---|---|---|---|
| CA | 10,287 | 7,256 | 3,031 | 71% | **`ca_cde`, loaded** |
| OH | 3,548 | 872 | 2,676 | 25% | yes |
| TX | 9,078 | 6,840 | 2,238 | 75% | yes |
| IN | 1,893 | **0** | 1,893 | 0% | yes |
| PA | 2,914 | 1,212 | 1,702 | 42% | yes |
| WA | 2,530 | 855 | 1,675 | 34% | **no** |
| KY | 1,526 | **0** | 1,526 | 0% | **no** |
| GA | 2,308 | 1,004 | 1,304 | 44% | yes |
| LA | 1,301 | **0** | 1,301 | 0% | **no** |
| CO | 1,889 | 619 | 1,270 | 33% | **no** |
| SC | 1,254 | **0** | 1,254 | 0% | yes |
| VA | 2,116 | 881 | 1,235 | 42% | **no**, and excluded for cause |
| NE | 1,089 | **0** | 1,089 | 0% | **no** |
| FL | 4,189 | 3,272 | 917 | 78% | yes |
| PR | 856 | **0** | 856 | 0% | out of scope |
| ID | 792 | **0** | 792 | 0% | **no** |
| NY | 4,789 | 4,049 | 740 | 85% | **no** |
| WV | 681 | **0** | 681 | 0% | yes |
| IL | 4,378 | 3,723 | 655 | 85% | yes |
| MO | 2,457 | 1,859 | 598 | 76% | **no** |
| MN | 2,646 | 2,073 | 573 | 78% | yes |
| MI | 3,469 | 2,957 | 512 | 85% | **no** |
| AZ | 2,400 | 1,942 | 458 | 81% | yes |
| NV | 755 | 351 | 404 | 46% | yes |
| MD | 1,403 | 1,071 | 332 | 76% | **no** |
| TN | 1,880 | 1,562 | 318 | 83% | yes |
| RI | 310 | **0** | 310 | 0% | yes, needs a local file |
| **all 50 + DC + territories** | **99,631** | **67,628** | **32,003** | **68%** | |

**CCD carries zero websites for eleven jurisdictions:** GU, HI, ID, IN, KY, LA,
NE, PR, RI, SC, WV. Five of those already have a state file built: HI, IN, RI,
SC, WV. Six do not: GU, ID, KY, LA, NE, PR.

### So "get all the schools" splits into three pieces

**Piece one, already built, just unloaded.** Twenty state files fetch cleanly
today and together cover about **15,400** of the 32,003-school gap. That is one
command per jurisdiction and no new code. How much of the gap each file actually
closes can only be confirmed after loading, by joining on `NCESSCH`, because a
state file may supply a website for a school CCD already covers.

**Piece two, new config entries needed.** WA 1,675, KY 1,526, LA 1,301, CO
1,270, NE 1,089, ID 792, NY 740, MO 598, MI 512, MD 332. About **9,800
schools** across ten jurisdictions. Each needs a `states.json` entry derived
from a probe run, which is the pattern the other twenty already follow.
Kentucky's `openhouse.education.ky.gov` is named in `state_file_survey.md` as a
lead. Virginia is separately **excluded for cause**: its file carries one VDOE
directory URL on all 2,153 rows, populated and worthless.

**Piece three, private schools, unsolved.** NCES PSS has all 22,510 with an
authoritative ZIP and **no URL anywhere**, verified in the public-use file, in
the frame file and on three locator detail pages. Against Boris's 129,000 to
133,000 total K-12 and almost 100,000 public, private schools are roughly
30,000 of the universe. The only route that does not need website discovery is a
name-plus-ZIP join from PSS to the 46,668 OSM `amenity=school` rows already
loaded, which has not been sized.

## Current state of the two tables

CCD and USFA are loaded into `lm_places_usa` but **not yet enriched**, so their
`onpremises` is not yet decided. `lm_fetch.py status` shows them in the staging
table and absent from `landmarks_usa`. Section 3 of `institution_ledger.sql`
labels exactly that as `PENDING: loaded, not enriched`.

Expected yield, stated before the run rather than after: at the measured OSM
`school` rate of 1.07 per cent CCD's 67,438 rows give roughly **720**
on-premises landmarks, and at the `fire_station` rate of 2.80 per cent USFA's
8,685 give roughly **243**. Both should beat those rates because CCD and USFA
are authoritative one-row-per-institution files while the OSM rows include
buildings, campuses and duplicates, but I am not going to put a number on the
improvement.
