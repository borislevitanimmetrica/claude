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
