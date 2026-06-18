# Session 43 — MILESTONE: /dev/diag is live to the modem on LineageOS

The wall is breached. We have a working diag channel on the LineageOS device,
data-safe (no stock, no USB-gadget changes).

## How we got here
- Found a prebuilt `diagchar.ko` (Mac: /Users/boris/Downloads/flash_to_device_5/
  diagchar.ko; EC2: /phone/tmp/diagchar_build/diagchar.ko) + full source
  (/phone/tmp/msm54_kamorta/drivers/char/diag/, /phone/tmp/diag_build/).
- vermagic `5.4.302-qgki-gc704f110e1f9-dirty SMP preempt mod_unload modversions
  aarch64` matched the running kernel (`5.4.302-qgki-gc704f110e1f9`); modversions
  tolerated the `-dirty`. `insmod` rc=0.
- `/proc/devices` now shows `474 diag`; `/dev/diag` created (chmod 666),
  owner system:vendor_qti_diag.
- dmesg: `diagchar: loading out-of-tree module` + avc denial on `qipcrtr_socket`
  (permissive -> ALLOWED) = diag reaching the modem over QRTR.

## CRITICAL operating notes
- Keep **SELinux permissive** (`setenforce 0`) for all diag work — the modem
  path uses a `qipcrtr_socket` that is denied under enforcing.
- This is NOT persistent: a reboot unloads diagchar and reverts. Re-`insmod`
  after any reboot. (Could add to a boot script later if wanted.)
- diagchar.ko and diagchar.ko.stub.bak are identical size (2821424); confirm the
  loaded one is the real driver (it registered major 474 + qipcrtr, so it is).

## Next: diag client on /dev/diag, then write IMEI
1. Read-probe (find which verb the modem honors): efsls/efsstat on
   /nv/item_files/modem/mmode/ue_imei_i, and nvread 550 (legacy; may be closed).
2. Write: efspush imei_nv550.bin -> /nv/item_files/modem/mmode/ue_imei_i, and/or
   nvwrite 550 088a86590706929838. Verify read-back. Reboot. Check *#06#.

Tooling: qfenix on the Mac needs a USB diag PORT (blocked by configfs EPERM), so
run qfenix's Linux-arm64 build ON the device against /dev/diag, OR a small
diagchar EFS2 client. (If qfenix can't bind /dev/diag, write a minimal client:
open /dev/diag, DIAG_IOCTL_SWITCH_LOGGING, then EFS2 (0x4B) packets.)
