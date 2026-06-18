# HANDOFF — Session 43 (CPH2459 IMEI restore)

IMEI to restore: **868957060298983**  (NV-550 / ue_imei_i BCD: `08 8a 86 59 07 06 92 98 38`)
Device: CPH2459 "gunnar"/holi sm6375, LineageOS 23.2, kernel 5.4.302-qgki-gc704f110e1f9,
bootloader unlocked, slot A active. adb serial 9385711f (broken phone), fcbc948b (stock ref).

## WHERE WE ARE RIGHT NOW (the live plan)
The modem is healthy; the ONLY blocker is the empty IMEI in modem NV. We have a
working diag channel to the modem and are about to write the IMEI via EFS2.

Confirmed this session:
- modem boots fine (QMI, rmt_storage, IPA, RIL all up; SIM read) — only OUT_OF_SERVICE
  due to null IMEI. (SESSION_43_modem_state.md)
- All userspace HAL/qcril paths and all 6 vendor HIDL surfaces: dead (0% / rejected).
- **diagchar.ko** (prebuilt, vermagic matches running kernel) `insmod`s cleanly ->
  **/dev/diag live, major 474**, bridges to modem over QRTR. (SESSION_43_diag_live.md)
  REQUIRES SELinux permissive (`setenforce 0`) — the QRTR socket is denied under enforcing.
  NOT persistent: re-`insmod` after every reboot.
- Legacy DIAG NV (0x26/0x27) is REJECTED by the modem (BAD_CMD 0x13) — confirmed by
  running /phone/tmp/nv_read_imei on-device. Transport itself works (modem responds).
- qfenix can't drive /dev/diag (USB-only transport). So we wrote our own client.

## THE ACTION IN FLIGHT: efs_write_imei.c (EFS2 PUT)
Repo branch `session-43-efs-write`: `efs_write_imei.c` + `BUILD_efs_write_imei.md`.
- Reuses nv_write_imei v5's PROVEN /dev/diag transport (open -> SWITCH_LOGGING
  MEMORY_DEVICE_MODE APSS|MPSS -> [u32 USER_SPACE_DATA_TYPE=0x20]+HDLC; strip 12-byte
  MD envelope on read; CRC-16/SDLC).
- Payload = EFS2 PUT (opcode 38, the verb the modem has NOT rejected; layout from
  qfenix diag.c): hdr[4B,method,38,00] data_len(u16)@4 pad@6 flags(i32)@8 mode(i16)@12
  data@14 path@(14+9). flags=O_CREAT|O_WRONLY|O_TRUNC|O_ITEMFILE|O_AUTODIR=0xC0241,
  mode=0644. Target path `/nv/item_files/modem/mmode/ue_imei_i`, 9 data bytes.
  Response: errno(i16)@offset 6; 0 = success. HELLO tries method ALT 0x3E then STD 0x13.
- Just fixed a build error: at -O2 clang emitted memset/memcpy under -nostdlib; added
  memset/memcpy/memmove definitions and build with **-ffreestanding -fno-builtin**.

### EXACT NEXT STEPS
1. Mac->EC2: `scp -i ~/.ssh/immetrica_aws_useast1_private_key.pem \
   /Users/boris/Downloads/flash_to_device_5/efs_write/efs_write_imei.c \
   ec2-user@immetrica.com:/phone/tmp/efs_write_imei.c`  (re-pull repo first if updated)
2. EC2 build (clang-r*, freestanding, no-builtin):
   `CC=$(ls -d /phone/lineage/prebuilts/clang/host/linux-x86/clang-r*/bin/clang | tail -1)`
   `$CC --target=aarch64-linux-android31 -nostdlib -static -O2 -ffreestanding -fno-builtin \
    -fno-stack-protector -o /phone/tmp/efs_write_imei /phone/tmp/efs_write_imei.c`
   `file /phone/tmp/efs_write_imei`  (need: ELF aarch64, statically linked)
   (libtinfo.so.5 was symlinked from .6 to run the older clang; clang-r* shouldn't need it.)
3. EC2->Mac: scp the binary back to .../efs_write/efs_write_imei
4. Device (diag live, permissive): adb root; setenforce 0; ensure /dev/diag (re-insmod
   diagchar.ko if needed); push; chmod 755; run /data/local/tmp/efs_write_imei.
5. Read the `PUT errno=` line.

## OUTCOMES & OPTIONS IF IT FAILS
- **errno=0 / SUCCESS** -> `adb reboot`; re-insmod not needed for IMEI (persists in EFS);
  dial `*#06#`; insert SIM; confirm registration.
- **errno nonzero** (EACCES/EROFS/etc.) -> modem gates EFS writes in NORMAL mode.
  Next: enter **FTM (factory test mode)** where provisioning writes are allowed —
  `adb reboot ftm` (abl/xbl are stock so it should honor it), re-insmod diagchar if the
  node's gone, re-run efs_write_imei in FTM. Also try writing the legacy alias
  `/nv/item_files/nv/550` the same way.
- **framing oddity / unexpected cmd byte** -> the client prints verbose TX/RX hex;
  adjust the 12-byte envelope offset or HDLC handling (the BAD_CMD response earlier showed
  responses arrive as [20 00 00 00][01 00 00 00][len][HDLC]). Cross-check against
  nv_read_imei.c (435 lines, has richer envelope parsing) at /phone/tmp/nv_read_imei.c.
- **HELLO never acks AND PUT no response** -> EFS2 subsystem may be gated in normal mode;
  go to FTM (above). If FTM unreachable on Lineage -> Plan D fallback: EDL -> install
  SIGNED stock (firehose VIP-ok with OFP digests) -> stock has diag+FTM -> qfenix/efs write
  -> re-flash Lineage (its OTA preserves modem/modemst/persist per SESSION_43 §6, so the
  restored IMEI survives). Data-loss risk on the stock round-trip (FBE) -> back up /data first.
- **Plan D via fastboot is BLOCKED** (critical-partition lock); EDL/firehose works but is
  VIP (signed-only) — can install stock, cannot write custom partitions.

## KEY ASSETS / PATHS
- diagchar.ko: Mac /Users/boris/Downloads/flash_to_device_5/diagchar.ko ; EC2 /phone/tmp/diagchar_build/diagchar.ko
- diag source: /phone/tmp/diagchar_build, /phone/tmp/msm54_kamorta/drivers/char/diag
- prior clients: /phone/tmp/nv_read_imei(.c), /phone/tmp/nv_write_imei(.c)  (legacy NV; rejected)
- qfenix (ref for EFS2): /phone/tmp/qfenix (USB-only transport; not usable on-device)
- OFP (stock 11_C.26) decrypted: /Users/boris/Downloads/fw_11C26_extracted_5/ ; firehose
  loader + rawprogram in there. OFP: CPH2459export_11_C.26_2025020813270000.
- IMEI value also survives as plaintext in /persist RFS (nv/550, ue_imei_i, mtime 2026-06-09)
  but the modem does NOT ingest it (prior failed injection); not a fix by itself.
- EDL entry: `adb reboot edl` works on Lineage; edl.py auto-matches loader
  0000000000510000_22f415bec935e3cb_fhprg_op_n30.bin.

## DO-NOT-REGRESS NOTES
- Keep SELinux permissive for all diag work.
- modemst-restore path is DEAD (only backup is post-IMEI-wipe).
- Stock EngineerMode CANNOT write IMEI on this device (APK analysis); not an option.
- For the freestanding client: always build with -ffreestanding -fno-builtin (else memset
  link error or self-recursion).
