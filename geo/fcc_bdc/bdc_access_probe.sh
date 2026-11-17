#!/bin/sh
# bdc_access_probe.sh - find out exactly what broadbandmap.fcc.gov will serve
# to THIS machine.
#
# WHY THIS EXISTS
#
# bdc_fetch.py worked from the Kiro sandbox and was refused from Boris's
# machine with an Akamai "Access Denied" page. I had claimed the browser
# User-Agent and Referer headers were what made the difference. THAT CLAIM
# WAS WRONG: re-testing from the sandbox later, a request with NO headers at
# all returned 200, where the same request had returned 403 an hour earlier.
# So the decision is not header-driven, it is per-client, and I cannot tell
# from one side of it which variant works from the other.
#
# This script collects the ground truth instead of guessing. It tries every
# endpoint class the downloader needs, with and without a cookie warmup, and
# prints the HTTP status of each. Nothing here is destructive: it writes only
# a cookie jar and a tiny test file, both under /tmp.
#
# USAGE
#
#   sh geo/fcc_bdc/bdc_access_probe.sh
#   sh geo/fcc_bdc/bdc_access_probe.sh 2>&1 | tee /home/boris/geo/logs/bdc_probe.log
#
# READING THE RESULT
#
# 200 means that endpoint is usable from here. 403 with an Access Denied body
# means Akamai refused this client. The reference number in a 403 body is what
# the FCC would need in order to look it up, so it is printed.
#
# The line that matters most is the FILE DOWNLOAD test. If that returns 200
# the project is fine even when the catalogue endpoint is refused, because
# geo/fcc_bdc/bdc_catalog_fixed.tsv is committed to the repository and carries
# every file id already.
#
# Contains no mid-line hash and no backslash escapes in emitted text.

set -u

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
PAGE="https://broadbandmap.fcc.gov/data-download"
API="https://broadbandmap.fcc.gov/nbm/map/api"
UUID="e9825f3a-c08d-4597-a9bf-657a19526ebd"
FILING="$API/published/filing"
CATALOG="$API/national_map_process/nbm_get_data_download/$UUID"
TINY="$API/getNBMDataDownloadFile/1885061/1"

JAR=/tmp/bdc_probe_cookies.txt
BODY=/tmp/bdc_probe_body
rm -f "$JAR" "$BODY"

echo "bdc_access_probe, $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo
echo "CLIENT"
curl --version | head -1
echo "resolved edge addresses for broadbandmap.fcc.gov:"
getent ahosts broadbandmap.fcc.gov 2>/dev/null | awk '{print "    "$1}' | sort -u
echo

probe() {
    label=$1
    shift
    out=$(curl -sS -o "$BODY" -w '%{http_code} %{size_download}' -m 60 "$@" 2>/dev/null)
    set -- $out
    echo "    $label"
    echo "        http=$1 bytes=$2"
    case "$1" in
        200) head -c 90 "$BODY" | tr -d '\n' | sed 's/^/        body: /' ; echo ;;
        *)   grep -o 'Reference[^<]*' "$BODY" 2>/dev/null | head -1 | sed 's/^/        /'
             head -c 90 "$BODY" | tr -d '\n' | sed 's/^/        body: /' ; echo ;;
    esac
}

echo "TEST 1, no headers at all"
probe "filing list" "$FILING"
echo

echo "TEST 2, browser User-Agent and Referer"
probe "filing list" -A "$UA" -e "$PAGE" "$FILING"
probe "catalogue" -A "$UA" -e "$PAGE" "$CATALOG"
probe "FILE DOWNLOAD, Rhode Island copper, 657 bytes" -A "$UA" -e "$PAGE" "$TINY"
echo

echo "TEST 3, forced HTTP/1.1"
probe "filing list" --http1.1 -A "$UA" -e "$PAGE" "$FILING"
echo

echo "TEST 4, warm up on the HTML page first, then reuse its cookies"
probe "the HTML download page itself" -c "$JAR" -A "$UA" \
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
      -H 'Accept-Language: en-US,en;q=0.9' "$PAGE"
if [ -s "$JAR" ]; then
    echo "        cookies captured:"
    awk '$6 != "" {print "            "$6}' "$JAR" | sort -u
else
    echo "        NO cookies captured, so the warmup gave nothing to reuse"
fi
probe "filing list with those cookies" -b "$JAR" -c "$JAR" -A "$UA" -e "$PAGE" \
      -H 'Accept: application/json, text/plain, */*' "$FILING"
probe "FILE DOWNLOAD with those cookies" -b "$JAR" -c "$JAR" -A "$UA" -e "$PAGE" "$TINY"
echo

echo "TEST 5, full browser header set with cookies"
probe "filing list" -b "$JAR" -c "$JAR" -A "$UA" -e "$PAGE" \
      -H 'Accept: application/json, text/plain, */*' \
      -H 'Accept-Language: en-US,en;q=0.9' \
      -H 'sec-ch-ua: "Chromium";v="131", "Not_A Brand";v="24"' \
      -H 'sec-ch-ua-mobile: ?0' \
      -H 'sec-ch-ua-platform: "Linux"' \
      -H 'Sec-Fetch-Dest: empty' \
      -H 'Sec-Fetch-Mode: cors' \
      -H 'Sec-Fetch-Site: same-origin' \
      --compressed "$FILING"
echo

echo "TEST 6, the same request 60 seconds later, in case the refusal expires"
sleep 60
probe "filing list" -A "$UA" -e "$PAGE" "$FILING"
echo

echo "WHAT THIS MEASURED ON BORIS'S MACHINE, 2026-11-17"
echo "    Tests 1, 2, 3, 4 and 6: all 403. Test 5, the FULL browser header"
echo "    set: 200. So the full set is what bdc_fetch.py now sends always,"
echo "    and the cookie warmup is not the fix: the page itself was refused"
echo "    and gave up no usable cookie."
echo
echo "    From the Kiro sandbox the same day every variant returned 200,"
echo "    including a bare request. The refusal is per client."
echo
echo "WHAT TO DO WITH THIS"
echo "    If TEST 5 is 200, bdc_fetch.py should work as it stands, because"
echo "    it sends those headers on every request."
echo
echo "    If the FILE DOWNLOAD lines are 403 while test 5 is 200, only the"
echo "    files are refused; the catalogue is committed as"
echo "    geo/fcc_bdc/bdc_catalog_fixed.tsv so no API call is needed, but"
echo "    the download itself has to come from elsewhere."
echo
echo "    If every line is 403, this machine is refused outright."
echo
echo "    ALWAYS run bdc_fetch.py verify before loading. A refusal arrives as"
echo "    a 438-byte HTML page, and on 2026-11-17 four of them were saved as"
echo "    .zip files and reported as successful downloads."
rm -f "$BODY"
