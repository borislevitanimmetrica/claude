#!/usr/bin/env bash
set -euo pipefail

# Ensure argument verification
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <IP_ADDRESS>"
    exit 1
fi
TARGET_IP="$1"

# Basic sanity check on the argument (IPv4 or IPv6, loose match)
if ! [[ "$TARGET_IP" =~ ^[0-9a-fA-F:.]+$ ]]; then
    echo "Error: '${TARGET_IP}' does not look like a valid IP address."
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed."; exit 1; }

URL_PROTO="https://"
URL_HOST="rdap.arin.net"
URL_PATH="/registry/ip/"
EXEC_ENDPOINT="${URL_PROTO}${URL_HOST}${URL_PATH}${TARGET_IP}"

HTTP_STATUS=$(curl -s -o /tmp/arin_payload.$$.json -w "%{http_code}" --max-time 15 "${EXEC_ENDPOINT}") || {
    echo "Error: curl failed to reach ${URL_HOST} (network/DNS/timeout)."
    rm -f /tmp/arin_payload.$$.json
    exit 1
}
RAW_PAYLOAD=$(cat /tmp/arin_payload.$$.json)
rm -f /tmp/arin_payload.$$.json

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: ARIN RDAP returned HTTP ${HTTP_STATUS} for ${TARGET_IP}."
    if echo "${RAW_PAYLOAD}" | jq empty 2>/dev/null; then
        echo "${RAW_PAYLOAD}" | jq -r '.description[]? // .title? // empty'
    fi
    exit 1
fi

if ! echo "${RAW_PAYLOAD}" | jq empty 2>/dev/null; then
    echo "Error: Network execution target failed to return valid JSON from ${URL_HOST}"
    exit 1
fi

# jq program:
#  - walks the entities tree RECURSIVELY (registrant can be nested inside
#    an org entity, inside the network entity).
#  - each field uses [ ... ] | .[0] so a missing field yields null instead
#    of an empty jq stream (which would otherwise silently drop the whole
#    record via jq's cartesian-product object construction).
#  - adr_text tries the structured vcard value array FIRST, then falls
#    back to the adr property's "label" param. ARIN frequently leaves the
#    structured array as all-empty-strings and puts the real formatted
#    address (with embedded \n) only in label -- this is why the address
#    was coming back empty even after the name field was fixed.
JQ_PROGRAM='
def flatten_str:
  if type == "array" then map(flatten_str) | flatten
  elif type == "string" then [.]
  else [] end;

def all_entities:
  .. | objects | select(has("roles"));

def vcard_props:
  .vcardArray[1][]?;

def field(name):
  ( [ vcard_props | select(.[0]==name) | .[3] ] | .[0] );

def adr_text:
  ( [ vcard_props | select(.[0]=="adr") ] | .[0] ) as $adr
  | if $adr == null then null
    else
      ( $adr[3] | flatten_str | map(select(. != "" and . != null)) ) as $parts
      | if ($parts | length) > 0 then ($parts | join(", "))
        else ( ($adr[1].label? // null) | if . then gsub("\n"; ", ") else null end )
        end
    end;

[ all_entities
  | select(.roles[]? == "registrant")
  | {
      name:  field("fn"),
      org:   field("org"),
      adr:   adr_text,
      email: field("email"),
      tel:   field("tel")
    }
] | unique
'

RESULTS=$(echo "${RAW_PAYLOAD}" | jq -c "${JQ_PROGRAM}")
COUNT=$(echo "${RESULTS}" | jq 'length')
FALLBACK_COUNTRY=$(echo "${RAW_PAYLOAD}" | jq -r '.country // empty')

echo "=== ARIN VCARD GEOGRAPHIC RECORD ==="
echo "Query Target IP   : ${TARGET_IP}"

if [ "$COUNT" -eq 0 ]; then
    echo "Registrant Entity : NOT_FOUND"
    echo "Geographic Address: NOT_POPULATED"
    [ -n "$FALLBACK_COUNTRY" ] && echo "Network Country    : ${FALLBACK_COUNTRY}"
else
    echo "${RESULTS}" | jq -c '.[]' | while read -r ENTRY; do
        NAME=$(echo "$ENTRY" | jq -r '.name // empty')
        ORG=$(echo "$ENTRY" | jq -r '.org // empty')
        ADR=$(echo "$ENTRY" | jq -r '.adr // empty')
        EMAIL=$(echo "$ENTRY" | jq -r '.email // empty')
        TEL=$(echo "$ENTRY" | jq -r '.tel // empty')

        echo "------------------------------------"
        echo "Registrant Entity : ${NAME:-${ORG:-NOT_FOUND}}"
        [ -n "$ORG" ] && [ "$ORG" != "$NAME" ] && echo "Organization      : ${ORG}"
        echo "Geographic Address: ${ADR:-NOT_POPULATED}"
        [ -n "$EMAIL" ] && echo "Email             : ${EMAIL}"
        [ -n "$TEL" ] && echo "Phone             : ${TEL}"
    done
    [ -n "$FALLBACK_COUNTRY" ] && echo "Network Country    : ${FALLBACK_COUNTRY}"
fi
echo "===================================="
