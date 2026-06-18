#!/usr/bin/env bash
# CPH2459 stock-flash recipe — Apple Silicon macOS, native, VIP-correct, IMEI-safe.
#
# What it does:
#   Step A — Sahara: upload the OnePlus signed firehose programmer ELF (qfenix).
#   Step B — VIP gate: submit the OFP's pre-signed digest table so the loader
#            accepts subsequent writes (--signeddigests + --testvipimpact).
#   Step C — Program LUN0..LUN4 from rawprogram0..4.xml with EnableVip="1".
#            DO NOT TOUCH LUN5 (rawprogram5.xml) — modemst1/2 + persistent NV
#            backups + oplusreserve* live there. We must not re-wipe IMEI storage.
#   Step D — Patch GPTs (patch0..4.xml). Skip patch5.xml for the same reason.
#   Step E — Reboot.
#
# Required env:
#   PORT=/dev/cu.usbmodemXXXX  - macOS serial node for the EDL 9008 device
#   OFP=/path/to/fw_11C26_extracted_5
#   QFENIX=/path/to/qfenix
# Optional:
#   FH_LOADER=/path/to/fh_loader  (default: ./fh_loader next to this script)
#
# Pre-flight in another terminal:
#   sudo -v                                    # cache sudo (qfenix may need it)
#   adb -s 9385711f reboot edl
#   ls /dev/cu.usbmodem*                       # capture the right one for $PORT

set -euo pipefail

: "${PORT:?Set PORT, e.g. PORT=/dev/cu.usbmodem1234}"
: "${OFP:?Set OFP, e.g. OFP=/Users/boris/Downloads/fw_11C26_extracted_5}"
: "${QFENIX:?Set QFENIX, e.g. QFENIX=/Users/boris/Downloads/qfenix}"
FH_LOADER="${FH_LOADER:-$(dirname "$0")/fh_loader}"

[ -x "$FH_LOADER" ] || { echo "fh_loader not built: run build_macos.sh first"; exit 1; }
[ -d "$OFP" ]       || { echo "OFP dir not found: $OFP"; exit 1; }

# Resolve the OnePlus loader + digest table from the OFP
PROG="$OFP/prog_firehose_ddr.elf"
# OFP ships several digest variants by storage size / partitions kept; the safest
# choice that keeps persist + userdata is "_persist_yes_userdata_yes" (we'll write
# stock persist now and restore the original via on-device dd after stock boots).
DIGEST="$OFP/DigestsToSign_20825_persist_yes_userdata_yes.bin.mbn"

[ -f "$PROG" ]   || { echo "Programmer ELF not found: $PROG"; exit 1; }
[ -f "$DIGEST" ] || { echo "Digest table not found: $DIGEST"; ls "$OFP" | grep -i digest; exit 1; }

# qfenix needs sudo for raw USB on macOS; pre-cache before the 20s PBL watchdog
sudo -v

echo
echo "=== Step A: Sahara -> upload firehose programmer (qfenix) ==="
# qfenix already does the Sahara handshake; we ride along for the loader upload only.
# Important: after this step the firehose loader runs and the watchdog is disarmed.
sudo "$QFENIX" printgpt "$PROG" || {
  echo "Sahara/programmer upload failed. Power-cycle the phone (Vol-Up + Vol-Down + Power, USB unplugged, ~20s) and retry."
  exit 1
}

echo
echo "=== Step B: VIP gate -> submit OFP signed digests ==="
"$FH_LOADER" --port="$PORT" \
  --signeddigests="$DIGEST" \
  --testvipimpact --noprompt --skip_configure \
  --mainoutputdir="$OFP" \
  --showpercentagecomplete

echo
echo "=== Step C: Program LUN0..LUN4 (EXPLICITLY SKIPPING LUN5) ==="
for i in 0 1 2 3 4; do
  echo "--- programming rawprogram${i}.xml ---"
  "$FH_LOADER" --port="$PORT" \
    --memoryname=ufs \
    --search_path="$OFP" \
    --sendxml="$OFP/rawprogram${i}.xml" \
    --skip_configure \
    --showpercentagecomplete \
    --mainoutputdir="$OFP" \
    --noprompt
done

echo
echo "=== Step D: Patch GPTs (LUN0..LUN4) ==="
for i in 0 1 2 3 4; do
  echo "--- patching patch${i}.xml ---"
  "$FH_LOADER" --port="$PORT" \
    --memoryname=ufs \
    --search_path="$OFP" \
    --sendxml="$OFP/patch${i}.xml" \
    --skip_configure \
    --noprompt
done

echo
echo "=== Step E: Reboot ==="
"$FH_LOADER" --port="$PORT" --reset || true

cat <<'POST'

DONE. Device should boot stock OxygenOS 11_C.26.

Post-boot checklist:
  1. Wait for stock to come up (first boot can take several minutes).
  2. *#06# is expected to still be empty -- we did not touch modemst1/2.
  3. Restore the ORIGINAL persist.img via on-device dd (rooted Lineage later)
     so calibration + IMEI provenance return.
  4. Then on stock: write IMEI via qfenix DIAG (nvwrite/efspush) -- stock exposes
     a real /dev/diag and FTM-grade provisioning surfaces.
  5. After *#06# shows 868957060298983 and SIM registers, re-flash LineageOS.

If any step C entry fails with 'signature failed with 3', the digest variant is
wrong for your provisioning. Try DIGEST=DigestsToSign_20825_all.bin.mbn or one of
the persist_no/userdata_no variants -- but verify on-device persist.img is backed
up before retrying any LUN.
POST
