State and territory school-directory survey
===========================================

2026-11-05. Every number here is `probe_state_files.py` output on bytes actually
fetched, or a script reusing that module's own role detection. Nothing is taken
from documentation.


The finding that changes the plan
--------------------------------

THE FEDERAL CCD DIRECTORY FILE CARRIES A WEBSITE COLUMN.

The belief carried into this work, recorded in the Session 3 notes and in the
`ca-cde` loader's own docstring, is that CCD "publishes no website at all, so
CCD cannot anchor a landmark by itself". That is why fifty state directories
were being collected one at a time. It is wrong for the 2023-24 release.

One download, 12,624,979 bytes:

    cd /home/boris/geo
    curl -sS -L -o ccd_sch_029_2324_national.zip "https://nces.ed.gov/ccd/Data/zip/ccd_sch_029_2324_w_1a_073124.zip"

Measured over the 102,274 rows, restricted to the 99,596 whose SY_STATUS_TEXT
begins "open", reading LZIP which is the physical ZIP:

    open schools                                     99,596
    carrying a url-shaped WEBSITE and a physical ZIP 67,363   67.6 percent
    distinct physical ZIPs                           16,752
    distinct website hosts                           30,403
    hosts serving exactly one school                 21,921 of 30,403

That last line is the one that matters. A website column full of district URLs
is worth nothing here, because `node_fanout.sql` rejects an address whose
landmark places sit in disjoint ZIP clusters, and it is right to: one building
cannot be on the premises of schools in forty ZIPs. 21,921 of 30,403 hosts
serving a single school means this is a genuine per-school column. The heaviest
reuse is what you would expect of large districts, and it is a small share:
www.cps.edu 499 rows, www.houstonisd.org 269, www.dallasisd.org 233.

CCD also carries NCESSCH, so it key-joins to any state file carrying an NCES id
with NO NAME MATCHING, which is the thing the adjacency work ruled out.


Why the state files are still needed
------------------------------------

The two sources are complementary and neither dominates. CCD's WEBSITE column is
EMPTY for eleven jurisdictions, five of which publish a website in their own
file. Union of distinct ZIPs where some school publishes a website:

    CCD alone                 16,752
    state files alone         10,966
    union                     19,411
    added by the state files   2,659

Jurisdictions where ONLY the state file has websites:

    IN   498 ZIPs      SC   293 ZIPs      WV   244 ZIPs
    HI    70 ZIPs      RI    62 ZIPs

Largest state-file gains where both sources have data:

    PA  +557    GA  +221    OH  +170    TN  +110    MN  +108    TX  +94

THIS IS A CEILING, NOT A FORECAST. Every ZIP counted is a ZIP where some school
publishes a website. It becomes a landmark only after the host resolves to an
address, the address survives `node_fanout.sql`, and the hosting and
on-premises rules accept it. California measured 1,367 ZIPs at this stage and
94 genuinely new ones at the end. The attrition is heavy and uneven, and the
host-to-address collapse was measured at roughly ninefold in California.


Per jurisdiction
----------------

Columns: ZIPs from CCD, ZIPs from the state's own file, the union.

    ST   CCD   file  union   note
    AK   193      0    193   state file has no URL anywhere
    AL   434    467    470   grid export solved, see below
    AR   281    283    299   one row per contact, dedupe on LEA
    AZ   306    372    375   ZIP5 is clean, ZIP4 is the add-on
    BI    73      0     73   Bureau of Indian Education
    CA 1,290      0  1,290   already loaded, 8,816 schools, 94 new ZIPs
    CO   179      0    179   state file has no URL anywhere
    CT   234      0    234   state file has no URL anywhere
    DC    25     20     25
    DE    46      0     46   state file is multi-year and has no URL
    FL   726    787    792   loaded from state file, A only
    GA   281    502    502   eight years stacked, filter YEAR and Level
    HI     0     70     70   STATE FILE ONLY, 269 hosts for 284 schools
    IA   411    410    419
    IL   883    889    895   filter RecType, Zip is ZIP+4 space separated
    IN     0    498    498   STATE FILE ONLY, separate CORP and SCHL sheets
    KS   415    454    459   legacy .xls, needs conversion; filter BOE rows
    MA   420      0    420   state file is an HTML table, no URL
    MD   218      0    218   state file has no URL anywhere
    ME   270      0    270   state file has no URL, and mailing ZIP only
    MI   675      0    675   state file has no URL anywhere
    MN   463    570    571   ZIP is inside a free-text address
    MO   568      0    568   state file has no URL at school level
    MS   240      0    240   state file has no URL anywhere
    MT   208      0    208   legacy .xls, no URL anyway
    NC   603    615    630
    ND   186    187    190   454 of 504 file rows are the district host
    NH   196      0    196   every nh.gov host returns 403 to this network
    NJ   525      0    525   state file URL columns are Facebook only
    NM   183      0    183   state school file has no URL
    NV   112    114    118   read Physical Zip, not Zip
    NY 1,066      0  1,066   Cognos RDS path works, school report has no URL
    OH   345    509    515   ZIP is inside ORG MAILING ADDRESS
    OK   482      0    482   school export has no URL, district export does
    OR   308      0    308   22,115 institutions, no URL; directory is a PDF
    PA   490  1,047  1,047   filter to school rows, 1,442 edna.pa.gov stubs
    RI     0     62     62   STATE FILE ONLY, assembled from 1,203 pages
    SC     0    293    293   STATE FILE ONLY, ZIP inside Address
    SD   186      0    186   state file has no URL at school level
    TN   390    495    500   Dataverse API exposes websiteurl
    TX 1,360  1,392  1,454   loaded from state file at school level
    UT   183    194    195   DateClosed works as the status column
    VA   295      0    295   state file carries ONE VDOE URL on every row
    VT   175      0    175   seven years stacked, no URL
    WA   240      0    240   ZIP inside PhysicalAddress, no URL
    WI   535    530    535   only 230 of 614 hosts serve one school
    WV     0    244    244   STATE FILE ONLY, 375 of 400 hosts serve one
    WY    98      0     98   TLS failure, JS-only app, stale PDF

Territories. CCD covers all five. PR 855 open schools and GU 295 have an EMPTY
WEBSITE column; AS, MP and VI each carry ONE URL repeated on every row
(www.doe.as, www.cnmipss.org, vide.vi), which the probe flags as a placeholder.

    PR  855 schools, 131 physical ZIPs, no website in four independent files
    GU   45 schools,   8 physical ZIPs, no website; GDOE's own pages are empty
    VI   20 schools,   5 physical ZIPs; vide.vi does publish 23 per-school
                       subdomains, but they are one platform and may resolve to
                       one address, which resolution will settle
    AS   29 schools,   1 ZIP for the whole territory, so at most one mapping
    MP   35 schools,   3 ZIPs, one district URL


Alabama, which needed a browser and did not
-------------------------------------------

`https://eddir.alsde.edu/siteinfo/` is a DevExpress grid. Its export is an
ordinary ASP.NET postback, and the argument format comes from the DevExpress
bundle: `SerializeCallbackArgs` emits a length-prefixed `<len>|<item>` per item,
so the export argument is the literal string `6|EXPORT3|Csv`. The earlier HTTP
411 was a missing Content-Length header, not a wrong target.

POST to the page with the session cookies and all 73 harvested form fields,
setting `__EVENTTARGET` to `ctl00$MainContent$pcResults$gridSiteInfo` and
`__EVENTARGUMENT` to `6|EXPORT3|Csv`, and it returns `text/csv`, 1,401,484
bytes. `6|EXPORT4|Xlsx` returns the xlsx.

Measured: 6,243 rows, 5,429 carrying a website and a ZIP, 467 distinct ZIPs,
1,047 hosts of which 788 serve exactly one row, no placeholder warning. Two
loader notes: `www.nonesupplied.com` on 135 rows is a sentinel, and the ZIP
column sits under a two-level header so its own header cell is blank.


What genuinely cannot be fetched from here
------------------------------------------

    NH   every nh.gov host returns HTTP 403 from Akamai to this network.
         Needs a residential address, exactly as California does.
    CA   Radware. Verified again: curl gets a 302 to an rdwr page, and a real
         headless Chrome is redirected to validate.perfdrive.com, which echoes
         HeadlessChrome back in the URL. Boris already has pubschls.txt.
    WY   fusion.edu.wyoming.gov presents a certificate for *.stage2.wyo.gov,
         which does not match the hostname. The portal app renders results in
         client-side Telerik script. The only file is a PDF whose page footers
         read 2017-2018.
    KS   exports only legacy OLE2 .xls, which the probe refuses rather than
         parse badly. A conversion step is needed.
    MT   same, and it has no website column anyway.

Two TLS cases are server misconfiguration rather than bot defence, and both are
fixable without weakening verification: Kentucky's `openhouse.education.ky.gov`
and Virginia's `schoolquality.virginia.gov` both omit the DigiCert Global G2
intermediate. Fetching that intermediate from the AIA URL in the leaf and
appending it to the system bundle works, with verification left on.


Defects this survey found in the probe, all now fixed
-----------------------------------------------------

Each was found by a real file, and each had produced a plausible wrong number
rather than an error, which is the dangerous shape.

    QUOTE_NONE on a quoted CSV      Arizona 205 usable against a true 3,970;
                                    Michigan reported no ZIP column for a file
                                    carrying EntityPhysicalZip4, because the
                                    HEADER had shifted
    raggedness measured before      Ohio's one-cell banner made both dialects
    banner rows were stripped       tie, the tie went to QUOTE_NONE, and the
                                    answer came out 2,035 instead of 2,522
    underscore separators           Florida's WEB_ADDRESS and PHYSICAL_ZIP are
                                    invisible to a \b boundary
    camel case with no separator    Michigan's EntityPhysicalZip4
    digits fused to a word          Arizona's ZIP5
    no separator at all             CCD's LZIP and MZIP; the mailing one was
                                    being chosen, costing real accuracy
    fused 9-digit ZIP+4             Puerto Rico's 006120000 and Louisiana's
                                    705784611 matched no 5-digit pattern
    ZIP from a free-text address    the first 5-digit group is the HOUSE
                                    NUMBER; Minnesota gave 848 distinct
                                    "ZIPs" of which only 557 were inside its
                                    real 55000-56999 range, against 581 of
                                    which 580 are, taking the last group
    blank and duplicate headers     Florida's 77th header is empty, which made
                                    printing the header list raise TypeError
                                    after the verdict; Arkansas repeats
                                    'Phone Number' and DictReader kept one
    name role taking a code column  Pennsylvania 'School Number', North Dakota
                                    'SchoolLevel', Kansas 'School Days Per
                                    Week', Nevada 'School Year', Louisiana
                                    'NcesSchoolIdCd', California 'NCESSchool'
    a populated but worthless       Virginia carries ONE VDOE directory URL on
    website column                  all 2,153 rows and the probe called it
                                    USABLE with 512 ZIPs
