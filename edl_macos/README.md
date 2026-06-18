# macOS-native VIP-capable EDL flashing for CPH2459

This directory holds everything to flash a **VIP-locked OnePlus** (CPH2459 / N20 5G)
from **Apple Silicon macOS, natively** — no Windows, no VM, no Docker, no Rosetta.

Background: `bkerler/edl` cannot satisfy OnePlus VIP (it doesn't submit the OFP's
signed digest tables). Qualcomm's official `fh_loader` does — its `--signeddigests`
flag uploads the `DigestsToSign_*.mbn` so the loader accepts subsequent writes.
Source for `fh_loader` is open (Qualcomm + LonelyFool) and **builds natively on
macOS** (POSIX termios, no Linux-specific code). For the Sahara hop (uploading the
firehose programmer ELF), we reuse the qfenix you already have on macOS.

## Pieces

- **fh_loader sources** (Qualcomm originals via LonelyFool/fh_loader): `fh_loader.cpp`,
  `fh_loader_sha.cpp`, `fh_loader_sha.h`, `fh_comdef.h`, `platform.h`, `stdafx.{h,cpp}`,
  `targetver.h`.
- **build_macos.sh** — one-line clang++ build (Apple Silicon arm64).
- **flash_cph2459.sh** — VIP-correct flash recipe targeting the SM6375 OFP. Reads
  the OFP's *already-signed* digest tables; explicitly **skips LUN5** (modemst1/2,
  fsg, fsc, mdm1m9kefs*, oplusreserve*) so the IMEI storage is untouched.

## Usage (after build)

```bash
# 0. Build (one-time)
./build_macos.sh

# 1. Phone in EDL: adb -s 9385711f reboot edl

# 2. Find the EDL serial node on macOS
ls /dev/cu.usbmodem*    # one entry will be QDLoader 9008

# 3. Flash
PORT=/dev/cu.usbmodemXXXX \
OFP=/Users/boris/Downloads/fw_11C26_extracted_5 \
QFENIX=/Users/boris/Downloads/qfenix \
./flash_cph2459.sh
```

## Why this avoids the failure modes of edl.py and qfenix

- edl.py's `w` got `signature failed with 3` because it never sent the digest table.
  fh_loader `--signeddigests=DigestsToSign_*.bin.mbn --testvipimpact` does, then
  programs with `EnableVip="1"`.
- qfenix is qdl-based (no VIP digest support), but it's *perfect* for the Sahara
  step — uploading the signed firehose programmer ELF — which is `printgpt`'s
  intended function. We use it only for that.
- We use the OFP's own signed digests; **no OnePlus key needed** — they're shipped
  with the firmware as `DigestsToSign_20825_*.bin.mbn` and `ChainedTableOfDigests_*`.

## Critical safety

Skip LUN5 (`rawprogram5.xml`) — that's where modemst1/2 + persistent NV backups
live. Our IMEI storage **must not be touched** by this flash. Restore the original
`persist.img` after stock boots via on-device `dd` (VIP only governs EDL).
