state_public_schools

This folder contains files with public school landmarks in various states.

Each file is named for what it ACTUALLY is, not for what the state server calls
it. That distinction is not pedantry: see the Florida note below.


Florida

Fetched from the sandbox on 2026-11-03. No browser and no manual download are
needed, which contradicts the earlier conclusion that the "Download Files"
button could not be reached. The button is an empty POST to a second form on
the page, and the files behind it are plain endpoints.

File in this folder: fl_msid_all_schools.txt
  2,902,438 bytes, sha256 7dcf9b1816ada0c0545568303bee177ab26fc624d5d5d93da291adabcf747bac
  tab-delimited text, 77 columns, 7,212 data rows, pure ASCII, no BOM

To refetch it. The first call only establishes the ColdFusion session; the
second is the download. An empty body must be sent explicitly, because the
endpoint answers a bodyless POST with HTTP 411 Length Required.

    cd /home/boris/geo
    curl -sS -c fl_cf.txt -o /dev/null "https://eds.fldoe.org/EDS/MasterSchoolID/index.cfm"
    curl -sS -b fl_cf.txt -e "https://eds.fldoe.org/EDS/MasterSchoolID/Downloads.cfm" --data-raw "" -o fl_msid_all_schools.txt "https://eds.fldoe.org/EDS/MasterSchoolID/Downloads/All_schools.cfm"
    sha256sum fl_msid_all_schools.txt


THE NAMING TRAP, WHICH IS THE WHOLE REASON THIS SECTION EXISTS

The server describes this file three times and is wrong all three times.

    the downloads page says    "They are in Excel format"
    content-type               application/msexcel;charset=UTF-8
    content-disposition        filename=MSID_all_schools.xls

The first sixteen bytes are 44 49 53 54 52 49 43 54 09 53 43 48 4f 4f 4c 09,
which is the ASCII text "DISTRICT<tab>SCHOOL<tab>". A real .xls begins
d0 cf 11 e0 a1 b1 1a e1 and a real .xlsx begins 50 4b 03 04. So the file is
tab-delimited text wearing an Excel name and an Excel MIME type.

Consequences, in order of how much they cost:

  Anything that validates a file's bytes against its extension rejects it.
  That is what blocked the project: the file was uploaded under its served
  .xls name, the receiving end saw text, and the mismatch produced an error.

  Excel opens it anyway, via its own text import, which is why the state has
  never had a complaint. Do not take "it opens in Excel" as evidence of format.

  A loader that branches on the extension would reach for an xls reader and
  fail on a file that csv.DictReader parses correctly with one argument.

Always determine the format from the bytes and rename to match:

    file fl_msid_all_schools.txt
    head -c 16 fl_msid_all_schools.txt | od -An -tx1

Both commands are safe to run on any downloaded state file, and either one
settles the question in a second.


The other four Florida endpoints

Same two-step session and the same empty POST. All five are tab-delimited text
served under .xls names. all_schools is the one to load; the others are listed
so that nobody re-derives them.

    Downloads/All_schools.cfm      all schools, all fields, 77 columns
    Downloads/Active_schools.cfm   active schools only
    Downloads/Mailing_list.cfm     active schools, mailing addresses
    Downloads/Verification.cfm     school verification, active and inactive
    Downloads/Future_school.cfm    schools not yet open

Why all_schools rather than Active_schools: it carries ACTIVITY_CODE, so the
same file supports a later decision to include or exclude closed and future
schools without a second download. See the measured breakdown below.


What is in the Florida file, measured

Counted over ONE population, rows carrying both a url-shaped WEB_ADDRESS and a
five-digit PHYSICAL_ZIP. Verified twice, by probe_state_files.py and by an
independent script, agreeing on every figure.

    rows with website and physical ZIP        4,427
    distinct five-digit ZIPs                    787
    distinct website hosts                    2,594

Split by ACTIVITY_CODE:

    A    3,707 rows    757 ZIPs
    C      710 rows    344 ZIPs
    F       10 rows      9 ZIPs

ACTIVITY_CODE is the status column. The reading A active, C closed, F future is
an INFERENCE from two things rather than documentation: the counts across all
7,212 rows are A 4,785, C 2,272, F 155, and the downloads page offers a separate
"Future Schools" file and describes the verification file as including active
and inactive schools. It is corroborated by DATE_CLOSED, an independent field:
restricting to rows where DATE_CLOSED is empty gives 3,719 rows and 758 ZIPs
against ACTIVITY_CODE = A giving 3,707 and 757. The two disagree by 12 rows and
one ZIP, so whichever is chosen the yield is the same. Picking the operating
values is the operator's call, which is why the probe prints them.

Florida has no column named anything like status. The only headers matching
"status" are MAGNET_STATUS and SI_TURNAROUND_STATUS, neither of which says
whether the school exists.

PHYSICAL_ZIP, not MAILING_ZIP. Both exist and both are five digits. A landmark
is a building, so the physical ZIP is the claim being made; a mailing ZIP is
often the district office or a post-office box in another ZIP.


The shared-host problem is worse in Florida than in California

    hosts serving one ZIP      2,432
    hosts serving many ZIPs      162
    rows on a shared host      1,739   39.3 percent of usable

California measured 32.9 percent. Florida's schools publish the district site
with a per-school path even more often, visible in the raw values:
"https://www.alachuaschools.net/o/duval" and "https://www.sbac.edu/foster" are
two schools in two ZIPs on one host.

The most fanned-out hosts, with the number of distinct ZIPs each serves:

    www.pcsb.org                     39
    www.duvalschools.org             32
    schools.polk-fl.net              26
    outreach.dadeschools.net         21
    www.pasco.k12.fl.us              20
    www.sarasotacountyschools.net    20
    www.collierschools.com           17
    www.escambiaschools.org          15
    www.manateeschools.net           14
    www.alachuaschools.net           13

Judge the state on ZIPs and expect the host count to overstate the yield badly.
In California 5,165 hosts collapsed to 556 addresses, of which only 379 served a
single ZIP, and 94 of the resulting ZIPs were new. Florida's 2,594 hosts should
be expected to collapse in the same proportion; the real number is not known
until the hosts are resolved. Nothing here predicts how many Florida ZIPs are
new, and the 787 figure must not be read as if it were.


Texas

Needs no manual download either, and no file is stored here because the
endpoint is stable and returns current data.

    curl -sS -L -o tx_askted.csv "https://data.texas.gov/api/views/hzek-udky/rows.csv?accessType=DOWNLOAD"

4,510,783 bytes, comma-delimited, 41 columns, 9,791 data rows. Carries district
and school ZIPs, district and school websites, and both NCES ids, so it must be
probed with --level school and --level district separately.

    school level      7,325 rows   1,392 ZIPs
    district level    9,785 rows   1,088 ZIPs

Dataset: AskTED Data, Texas Education Agency, published via the Texas Open Data
Portal at https://data.texas.gov/d/hzek-udky (content summarised here, not
reproduced).


California

Still needs a residential address. Verified again on 2026-11-03 from the
sandbox: plain curl to the export URL returns HTTP 302 to an "rdwr" page, and a
real headless Chrome is redirected to validate.perfdrive.com titled "Radware
Captcha Page", which names HeadlessChrome in the echoed user agent. The earlier
finding stands and the protection is not an artifact of using curl.

    curl -sS -L -o pubschls.txt "https://www.cde.ca.gov/schooldirectory/report?rid=dl1&tp=txt"

Already loaded: 8,816 usable schools, 1,367 ZIPs, 94 of them new.
