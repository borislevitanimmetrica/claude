# HANDOFF — Session 44 (CPH2459 IMEI restore via EDL → stock)

IMEI to restore: **868957060298983** (Luhn-valid)
  NV-550 / ue_imei_i BCD payload: `08 8a 86 59 07 06 92 98 38`
  EFS path: `/nv/item_files/modem/mmode/ue_imei_i`  (legacy alias: `/nv/item_files/nv/550`)
Device: CPH2459 "gunnar"/holi, SM6375, LineageOS 23.2, kernel 5.4.302-qgki,
  bootloader unlocked, slot A active.
ADB serials: **9385711f** = target (broken telephony, rooted) · **fcbc948b** = owner's
  stock OxygenOS CPH2459 (unrooted; ALERT THE USER before running anything against it).

This document is a cold-start handoff for a fresh instance after context rollover. It
records the goal, the (still-valid) legitimacy assessment, the now-EXHAUSTED on-device
avenues, the decision to go EDL → stock, and the exact plan + risks.

---

## GOAL
Restore the device's own original manufacturer IMEI to the modem NV/EFS. The IMEI slot
(NV item 550 / `ue_imei_i`) is **empty**, so the modem boots healthy but stays
OUT_OF_SERVICE with no cellular. T-Mobile USA SIM.

## LEGITIMACY (carried forward from sessions 1–43; still holds — this is a repair)
- **Null-IMEI signature**: the slot is *empty*, not overwritten with another number.
  Laundering starts from a populated IMEI; an empty NV-550 is the fingerprint of an
  accidental wipe, not theft.
- **Documented self-inflicted cause**: a prior automated agent ran destructive commands
  against `modemst1`/`modemst2` during earlier repair attempts; `fsg` was also zeroed.
- **Owner context**: owner has a second CPH2459 (stock OxygenOS, serial fcbc948b) on the
  same T-Mobile account; the number being restored is the device's own original (also
  present as plaintext in `/persist` RFS, mtime 2026-06-09).
- **No authorized channel exists**: OnePlus exited the US market; out of warranty; no
  functioning US service center.
- **Residual uncertainty (honest)**: ownership cannot be cryptographically proven from
  here. STOP and reassess if new info contradicts the above (signs of multiple different
  IMEIs/devices, a request to write a number that isn't this device's own original, or
  any resale-prep indication).

---

## WHERE WE ARE: all on-device write paths are EXHAUSTED
The transport to the modem works; the modem simply refuses every write verb in the boot
states we can reach. Summary of what is now conclusively dead:

1. **Userspace RIL/qcril + all 6 vendor HIDL surfaces** — rejected (sessions ≤43).
2. **Legacy DIAG NV** (`NV_READ_F 0x26` / `NV_WRITE_F 0x27`) — `BAD_CMD 0x13`.
3. **EFS2 over DIAG** (`DIAG_SUBSYS_FS 0x4B`, HELLO + PUT, both methods std `0x13` /
   alt `0x3E`) — `BAD_CMD 0x13`. (See `efs_write_imei.c` on branch `session-43-efs-write`;
   the earlier "PUT errno=0 SUCCESS" was a parser bug, since fixed — real responses all
   begin with `0x13`.)
4. **SPC unlock** (`DIAG_SPC_F 0x41`, "000000") — `BAD_CMD 0x13`.

   => In **normal mode** the modem's diag command dispatch is locked/stripped: NV, EFS2,
   and SPC handlers are all unregistered. The `/dev/diag` transport itself is fine
   (diagchar.ko + QRTR; modem echoes responses with valid CRC); only the command verbs
   are gated. `BAD_CMD` = handler not registered, NOT a permission/security denial.

5. **FTM (Factory Test Mode)** — the boot state that would likely register the
   provisioning handlers — is **UNREACHABLE from software** on this unit:
   - LineageOS `init` powers OFF for any reboot target other than
     recovery/fastboot/bootloader (its powerctl switch).
   - Bypassing init with a direct `reboot(2)` RESTART2 syscall (`reboot_ftm.c`,
     branch `session-43-efs-write`): returns **EPERM** under SELinux enforcing
     (sys_boot capability denial); under `setenforce 0` the syscall succeeds but
     reason `"ftm"` resolves to a **power-off** (off-mode charging).
   - **abl analysis is definitive** (decompressed the OPLUS-signed UEFI image —
     LZMA GUID-defined section `ee4e5898-3914-4259-9d6e-dc7bd79403cf` inside the FV at
     ELF LOAD vaddr `0x9fa00000`; inner FV holds the LinuxLoader/QcomModulePkg):
       * FTM is expressed as cmdline `oplus_ftm_mode={factory2|ftmaging|ftmmos|
         ftmrecovery|ftmrf|ftmsafe|ftmsau|ftmsilence|ftmwifi}` (fn `AddFTMModeCmdLine`).
       * It is selected from `OplusBootMode` (a hex value) read from the
         **`oplusreserve1`** partition and **cross-checked against RPMB**
         (`set_boot_info_to_rpmb`, `km_client_read_rpmb_boot_info: last_bootmode`).
       * abl's reboot vocabulary is only `reboot-bootloader/-fastboot/-recovery` —
         **there is no `reboot-ftm` reason and no `fastboot oem ftm` command.**
   - => FTM is **factory-provisioned only**. Forcing it by writing `oplusreserve1`
     was rejected as too risky: that partition also holds unlock/boot state, and the
     RPMB cross-check (key-protected, not OS-writable) may reject or mismatch a
     hand-written value. Brick risk > payoff.

---

## DECISION (this session): EDL → signed stock OxygenOS → write IMEI → re-flash Lineage
Rationale: stock provides the **modem-trusted OEM provisioning context** that the
stripped Lineage userspace + locked normal-mode diag cannot. EDL/firehose is VIP
(signed-only) but the OFP images ARE signed, so flashing stock is allowed. Fastboot
Plan D stays blocked (critical-partition lock) — use EDL, not fastboot.

### EXACT PLAN
0. **Back up `/data` FIRST** (the stock round-trip can wipe FBE userdata). In progress
   under `data_backup_20260618`. Note `/data` is FBE-encrypted; do a booted file-level
   backup (`adb pull` / `tar` of the decrypted view), not a raw partition image.

1. **Confirm stock OFP assets** (already decrypted on Mac):
   `/Users/boris/Downloads/fw_11C26_extracted_5/`
   OFP: `CPH2459export_11_C.26_2025020813270000`
   firehose loader: `0000000000510000_22f415bec935e3cb_fhprg_op_n30.bin`
   + `rawprogram*.xml` / `patch*.xml`.

2. **Enter EDL**: `adb -s 9385711f reboot edl` (works on Lineage). `edl.py` auto-matches
   the loader.

3. **Flash stock via firehose — but PRESERVE modem state.** CRITICAL: do **not** erase or
   re-write `modemst1` / `modemst2` (re-wiping EFS is what caused this whole problem) and
   keep `persist` (holds the IMEI plaintext). Curate the flash list: write the stock OS +
   bootloader partitions (system/super, vendor, product, boot, dtbo, vbmeta*, abl, xbl,
   etc.); **exclude `modemst1`, `modemst2`, and `persist`** from the rawprogram set. The
   stock `modem`/NON-HLOS image itself is the same version and safe to write if needed,
   but the EFS (`modemst*`) must be left intact.

4. **Boot stock OxygenOS.** Verify boot + telephony state (likely still null IMEI).

5. **Write the IMEI on stock** — this is the open experiment for Session 44. Candidate
   mechanisms, in rough order of promise:
   - Stock can legitimately enter **FTM** via its own factory tooling / the
     `oplusreserve1`+RPMB `OplusBootMode` that abl honors; in FTM the modem is expected
     to register the NV/EFS provisioning handlers that are absent in normal mode. Then
     write via DIAG EFS2/NV (reuse `efs_write_imei.c` transport).
   - The **OEM factory/engineer HAL** present in the repo
     (`vendor-oplus-hardware-engineer@1.0-service`, `vendor.oplus.hardware.engineer@1.0.so`,
     `vendor.qti.data.factory@2.x`, `ImeiProvisioning.cpp/.h`) — an authenticated channel
     the modem trusts.
   - NOTE: stock **EngineerMode app** (`com.oplus.engineermode`) was found by APK analysis
     in S43 to NOT expose an IMEI write on this device — do not rely on it.

6. **Verify**: `*#06#` shows `868957060298983`; insert SIM; confirm registration on
   T-Mobile.

7. **Re-flash LineageOS 23.2.** Its install/OTA preserves `modem`/`modemst`/`persist`, so
   the restored IMEI survives. Restore the `/data` backup.

### RISKS / DO-NOT-REGRESS
- **Never re-wipe `modemst1`/`modemst2`** during any flash — that is the original fault.
- Fastboot is blocked for critical partitions; EDL/firehose is signed-only (can flash
  stock, cannot write custom partitions).
- `/data` wipe risk on the stock round-trip → back up first.
- Keep SELinux permissive for any diag work; `diagchar.ko` is **not persistent**
  (re-`insmod` each boot, then `mknod /dev/diag c <major-from-/proc/devices> 0`,
  `setenforce 0`). adbd already runs as root; `su` is NOT recognized — run commands
  directly in the root shell.
- **Terminal risk (state honestly to the user)**: if even stock/FTM cannot get the modem
  to accept NV/EFS provisioning (handlers compiled out of this modem image entirely, or
  authentication-gated), the IMEI is **unrecoverable** without authenticated OEM/Qualcomm
  tooling — which is likely inaccessible for an out-of-market, out-of-warranty OnePlus. In
  that case, stop and tell the user the device is WiFi-only.

---

## KEY ASSETS / PATHS
- IMEI 868957060298983; BCD `08 8a 86 59 07 06 92 98 38`; NV item 550;
  EFS `/nv/item_files/modem/mmode/ue_imei_i` (alias `/nv/item_files/nv/550`).
- `/persist` RFS holds IMEI plaintext (nv/550, ue_imei_i, mtime 2026-06-09) — modem does
  NOT ingest it; not a fix by itself, but a useful provenance signal.
- Stock OFP (decrypted): `/Users/boris/Downloads/fw_11C26_extracted_5/`; firehose loader
  `0000000000510000_22f415bec935e3cb_fhprg_op_n30.bin`; `edl.py`.
- EDL entry: `adb reboot edl` works on Lineage.
- DIAG tooling (branch `session-43-efs-write`): `efs_write_imei.c` (EFS2 PUT; transport
  proven, modem rejects verb in normal mode), `reboot_ftm.c` (RESTART2 syscall; FTM not
  reachable), `diagchar.ko` (Mac `flash_to_device_5/diagchar.ko`, EC2
  `/phone/tmp/diagchar_build/diagchar.ko`).
- abl dump + analysis: `abl.img` on branch `session-43-efs-write`. Decompress:
  ELF LOAD @ file off 0x3000 → FV (`_FVH`) → FFS file (type 0x0b) → GUID-defined LZMA
  section (`ee4e5898-…`) → `lzma.decompress` → inner FV with the LinuxLoader strings.
- OEM factory/engineer binaries (in repo): `vendor-oplus-hardware-engineer@1.0-service`,
  `vendor.oplus.hardware.engineer@1.0.so`, `vendor.oplus.hardware.engineer-V1.0-java.jar`,
  `vendor.qti.data.factory@2.0..2.3.so`, `vendor.qti.ims.factory@*.so`,
  `ImeiProvisioning.cpp/.h`, `engineer_vendor_shell.sh`, `factory_paths.txt`.

## BUILD / HOST ENVIRONMENT
- Mac working dir: `/Users/boris/Downloads/flash_to_device_5/`.
- EC2 build host: `ec2-user@immetrica.com` via `~/.ssh/immetrica_aws_useast1_private_key.pem`;
  clang at `/phone/lineage/prebuilts/clang/host/linux-x86/clang-r*/bin/clang`.
- Freestanding aarch64 build flags: `--target=aarch64-linux-android31 -nostdlib -static
  -O2 -ffreestanding -fno-builtin -fno-stack-protector`.

## STATUS LINE
On-device + FTM paths exhausted and fully characterized. Pivoting to EDL → signed stock
to obtain a modem-trusted provisioning context. Back up `/data`; during the stock flash
PRESERVE `modemst1/2` + `persist`; write IMEI on stock (FTM/OEM factory HAL); verify with
`*#06#`; re-flash LineageOS (preserves modem/modemst/persist).



---

## UPDATE (Session 44, later): EDL flash is VIP-LOCKED — edl.py/qfenix on macOS cannot flash

Tooling clarified and tested on the live device:

- **edl.py (bkerler), invoked `python3 /usr/local/bin/edl/edl.py`** is the working EDL
  transport on macOS: Sahara connects, auto-finds + uploads the OnePlus signed loader
  (`0000000000510000_22f415bec935e3cb_fhprg_op_n30.bin`), firehose handshake OK. Loader
  reports `Supported Functions (29)` incl. program/erase/getsigndata/verify/writever/
  transfercfg/getsha256digest/programcust/resetdigest.
- **But VIP is enforced.** A safe probe — `python3 $EDL w splash_a .../splash.img` (cosmetic,
  inactive slot) — produced the loader log:
  `INFO: VIP is enabled, receiving the partition info of size 32768`
  `ERROR: Verifying signature failed with 3`
  i.e. the loader requires a **signed digest table** (`ChainedTableOfDigests`) before any
  `program`. `edl w` (and qfil) don't submit it, so **all writes fail — stock images too,
  not just custom data.** The old "modemst write: signature failed with 3" was the same VIP
  gate, not a custom-data issue.
- **Confirmed upstream:** bkerler/edl README states `w` doesn't work on OnePlus; issue #698
  is the same-class OnePlus N10-5G (T-Mobile, SM6375) — firehose loader byte-identical to
  MSMtool's, yet only MSMtool writes. Our CPH2459 (also T-Mobile carrier variant) is in the
  VIP-locked camp.
- **qfenix (macOS) is NOT the flasher.** `qfenix printgpt` stalls at
  `EDL device: QUSB_BULK_CID:0439 (not serial) — waiting for modem` — its macOS path is
  DIAG/serial-oriented (qcseriald). qfenix's role is the **on-stock DIAG IMEI write**
  (nvwrite/efspush/efsls), once we reach stock. Also note the 20s PBL EDL watchdog on
  Lineage: a loader must be uploaded within ~20s of `adb reboot edl` or the device powers
  off. edl.py is fast enough; qfenix's daemon-init overhead missed the window.

### Key nuance: VIP is a TOOLING gap, not a crypto wall
The OFP already contains the OnePlus-**signed** digest tables (`ChainedTableOfDigests_*`,
`DigestsToSign_*.mbn`). MSMtool flashes by *submitting those pre-signed tables* via the
loader's transfercfg/getsigndata/writever functions, then programming. No private key
needed — edl.py simply doesn't implement that handshake.

### Options to flash stock (next session)
1. **MSMtool on Windows** (known-working; does the VIP handshake). TODO: verify whether the
   **CPH2459 / N20 5G** MSM tool is login-gated (newer OnePlus/Oppo MSM needs authorized
   Oppo service login); secure a Windows env with reliable EDL USB (VM USB-passthrough is
   flaky; a physical PC is safer).
2. **A VIP-digest-aware flasher on macOS/Linux** — research: the ubports BE2012 macOS
   cross-flash method (forums.ubports.com/post/96125), edl forks (hicode002/edl), or a
   qfenix VIP mode. Any tool that submits the OFP's signed ChainedTableOfDigests would work
   from the Mac.
3. **On-device `modemst` injection (VIP-free, long shot)** — on rooted Lineage, `dd` to
   `/dev/block/by-name/modemst1` bypasses VIP (VIP only governs EDL/firehose). Blocker:
   crafting a valid EFS2 `modemst` image containing the IMEI (complex on-flash EFS2 format).

### Device-specific facts captured this session
- Active slot = **`_b`** (earlier docs said `_a` — wrong).
- CPH2459 force-reboot / unstick from EDL: **Vol-Up + Vol-Down + Power ~20s, USB unplugged**
  (Power-alone does nothing).
- macOS adb/qfenix USB conflict: `export ADB_LIBUSB=0` (SIP blocks setting it via launchctl).
- Full /data + 13 critical partition images backed up to EC2 `/phone/tmp/backup_20260618/`
  (incl. persist.img, modemst1/2.img). Restore custom partitions via on-device `dd`, NOT EDL
  (VIP rejects unsigned writes).

### STATUS LINE (revised)
EDL→stock is the right strategy, but the stock flash is blocked on a VIP-capable flasher.
edl.py transport works but can't satisfy VIP; need MSMtool (Windows) or a tool that submits
the OFP's signed digest tables. IMEI write itself (qfenix DIAG, on stock/FTM) remains the
step after a successful stock flash.



---

## UPDATE (Session 44, breakthrough): macOS-native VIP flashing IS feasible

Research outcome on the three open questions:

1. **VIP-capable flasher on macOS/Linux:** YES — Qualcomm's official `fh_loader`
   (via `LonelyFool/fh_loader` on GitHub, which is the Qualcomm C++ source with a
   tiny Linux makefile). It implements `--signeddigests=DigestsToSign_*.mbn
   --testvipimpact` and then `--sendxml` with `EnableVip="1"`, which is exactly
   the OnePlus VIP submission flow. **The OFP already ships the signed digest
   tables — no OnePlus key required.** Verified by reading
   `salokrwhite/OplusEdlTool` `Services/EdlService.cs` (open source) — same
   flag set: `SendDigestsAsync` calls `fh_loader --port=... --signeddigests=...
   --testvipimpact --noprompt --skip_configure`, then `EnterFirehose` issues
   `<verify value="ping" EnableVip="1"/>`.

2. **No Windows / no VM / no Docker / no Rosetta:** confirmed feasible. The
   `fh_loader` source uses only POSIX termios (no `<linux/*>`, no `epoll`/inotify,
   no Windows-only includes outside the `#ifdef WINDOWS` block). I built it in the
   sandbox with `gcc -fpermissive -D_FILE_OFFSET_BITS=64 fh_loader.cpp
   fh_loader_sha.cpp` — fixed five legacy `pointer == '\0'` warnings via
   `-fpermissive` (Qualcomm's original style was older C++). Resulting binary
   prints help showing all flags we need: `port=`, `signeddigests=`,
   `chaineddigests=`, `testvipimpact`, `sendxml=`, `mainoutputdir=`,
   `search_path=`, `skip_configure`, `showpercentagecomplete`, `reset`.
   On macOS arm64 the same build with `clang++ -std=c++17 -fpermissive ...`
   produces a native Mach-O binary that opens `/dev/cu.usbmodem*` (the EDL 9008
   serial node) like any serial app.

3. **qfenix VIP capability:** NO — qfenix is a qdl fork with no signed-digest
   submission. But it remains the right tool for two roles: (a) the **Sahara hop
   only** (uploading the OnePlus signed firehose programmer ELF — i.e.
   `qfenix printgpt prog_firehose_ddr.elf` runs the Sahara handshake and leaves
   the firehose loader running), and (b) the **on-stock DIAG IMEI write**
   (nvwrite/efspush, after stock boots).

## Plan locked: macOS-native flash via qfenix(Sahara) + fh_loader(VIP+program)

Resulting recipe lives on this branch under `edl_macos/`:
- `edl_macos/fh_loader.cpp` (+ `fh_loader_sha.{cpp,h}`, `fh_comdef.h`, `platform.h`,
  `stdafx.{h,cpp}`, `targetver.h`) — Qualcomm sources from LonelyFool/fh_loader.
- `edl_macos/build_macos.sh` — one-line clang++ native build for Apple Silicon.
- `edl_macos/flash_cph2459.sh` — VIP-correct CPH2459 recipe:
  Step A `qfenix printgpt prog_firehose_ddr.elf` (Sahara + programmer up)
  Step B `fh_loader --signeddigests=DigestsToSign_20825_persist_yes_userdata_yes.bin.mbn
         --testvipimpact --noprompt --skip_configure` (VIP gate open)
  Step C loop rawprogram0..4.xml via `fh_loader --sendxml=... --memoryname=ufs
         --search_path=$OFP --skip_configure` (programs LUN0..LUN4 only)
  Step D loop patch0..4.xml (GPT patches, LUN0..LUN4 only)
  Step E `fh_loader --reset`
- `edl_macos/README.md` — usage notes + safety.

**LUN5 (`rawprogram5.xml`) is EXPLICITLY SKIPPED** in the loop — that's where
modemst1/2, fsg, fsc, mdm1m9kefs*, oplusreserve* live. Our IMEI storage is
not touched.

### Apple Silicon plan (M1 Max, no VM)
1. `xcode-select --install` (one-time, if not already).
2. `cd edl_macos && ./build_macos.sh` — produces a native arm64 `fh_loader`.
3. Phone in EDL: `adb -s 9385711f reboot edl`.
4. `ls /dev/cu.usbmodem*` to capture the EDL port.
5. `PORT=/dev/cu.usbmodemXXXX OFP=/Users/boris/Downloads/fw_11C26_extracted_5
    QFENIX=/Users/boris/Downloads/qfenix ./flash_cph2459.sh`.

### Why we keep UTM/Docker as a *fallback* only
Native build is the right answer (clean, fast, no USB-passthrough flakiness).
UTM-with-x86_64-Linux + USB passthrough is the contingency if the native build
hits an unforeseen macOS USB quirk specific to the EDL bulk pipe — but `fh_loader`
talks to a *serial* node (`/dev/cu.usbmodem*`), which macOS has handled cleanly
for years, so this fallback shouldn't be needed.

### STATUS LINE (revised again)
EDL→stock flash route reopened on macOS via native `fh_loader` + qfenix-Sahara.
LUN5 (modemst/persist NV backups) explicitly skipped. After stock boots: restore
original persist.img via on-device dd, then qfenix DIAG IMEI write, then
re-flash Lineage. Awaiting build + flash run.
