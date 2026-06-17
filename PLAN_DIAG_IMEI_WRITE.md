# PLAN: Restore IMEI by writing it to the (healthy) modem over DIAG

Rethink as of 2026-06-17, given the key new lever: **we can disable SELinux**
(`adb root` works => userdebug => `setenforce 0` sticks). That removes the wall
that blocked diag exposure.

## State we are building on (facts established this session)
- Modem is UP and healthy: QMI services connected, rmt_storage serving, IPA init
  OK, RIL exchanging commands, SIM emergency codes read (src=sim). The ONLY
  blocker is the null IMEI -> OUT_OF_SERVICE. (see SESSION_43_modem_state.md)
- IMEI value is known: 868957060298983.
  NV-550 / ue_imei_i payload = bytes `08 8a 86 59 07 06 92 98 38` (file imei_nv550.bin).
- modemst-restore path is DEAD (the only backup, 2026-05-30, is post-wipe;
  restoring it left IMEI null).
- EDL works on LineageOS (`adb reboot edl` -> edl.py auto-loads the OnePlus loader).
  BUT firehose is VIP (signed-digest-only): can install signed STOCK, cannot
  write custom data (modemst backup write failed "signature failed with 3").
- qfenix (macOS) speaks DIAG: nvread/nvwrite + EFS2 efsls/efspush/efsstat/efsbackup.
  VIP does NOT affect DIAG (different channel). qfenix path = /Users/boris/Downloads/qfenix
- Blocker that stopped us last: no DIAG port in user mode; `setprop sys.usb.config`
  and `persist.sys.adddevdiag` were DENIED — almost certainly SELinux. With
  `setenforce 0` those denials go away.

## Why this is now the most promising position
Every userspace HIDL/qcril path is exhausted, but those all went through the
RIL/QMI layer the modem gates. DIAG is a *different* channel into the same
healthy modem, and qfenix gives us both legacy-NV and the never-tested EFS2
write — on macOS, no Windows. The job reduces to: (1) expose a DIAG channel,
(2) find which verb the modem honors, (3) write the IMEI, escalating to FTM only
if normal mode refuses.


## Escalation ladder (do in order; stop when *#06# shows the IMEI)

### Phase 1 — expose a DIAG channel (LineageOS, SELinux permissive)
```
adb root
adb shell setenforce 0            # the key enabler; resets on reboot
# 1a (simplest): let init build the gadget with diag
adb shell 'setprop sys.usb.config diag,adb'; sleep 2; adb shell getprop sys.usb.state
# 1b (vendor-controlled): 
adb shell 'setprop persist.vendor.usb.config diag,adb'; sleep 2; adb shell getprop sys.usb.state
# 1c (QTI full combo, if diag,adb alone doesn't enumerate):
adb shell 'setprop sys.usb.config diag,serial_cdev,rmnet,adb'; sleep 2
# 1d (manual configfs, if props won't take): run enable_diag.sh (in this repo)
adb push enable_diag.sh /data/local/tmp/; adb shell 'sh /data/local/tmp/enable_diag.sh'
```
Verify a DIAG port appeared (from the Mac):
```
/Users/boris/Downloads/qfenix list
ls /dev/cu.*
system_profiler SPUSBDataType | grep -iA3 -E 'diag|qualcomm|90[0-9a-f]{2}'
```

### Phase 2 — READ probe (decide which verb the modem honors, before writing)
```
Q=/Users/boris/Downloads/qfenix
$Q nvread 550                                   # legacy NV (handoff: maybe closed)
$Q efsls  /nv/item_files/modem/mmode            # EFS2 (UNTESTED — the key hope)
$Q efsstat /nv/item_files/modem/mmode/ue_imei_i
```
If EFS2 (efsls/efsstat) responds, that is the path. If only nvread responds, use NV.

### Phase 3 — WRITE the IMEI (normal mode)
```
printf '\x08\x8a\x86\x59\x07\x06\x92\x98\x38' > /tmp/imei_nv550.bin   # == imei_nv550.bin
$Q efspush /tmp/imei_nv550.bin /nv/item_files/modem/mmode/ue_imei_i
$Q nvwrite 550 088a86590706929838
$Q efsstat /nv/item_files/modem/mmode/ue_imei_i     # verify it took
$Q nvread  550
adb reboot     # then check *#06#
```

### Phase 4 — if normal-mode writes are refused: FTM (factory test mode)
The modem permits provisioning writes in FTM. On Lineage (abl/xbl are stock):
```
adb reboot ftm        # screen may stay black; modem enters factory mode
# re-run Phase 1 verify + Phase 2 probe + Phase 3 write under FTM
# (also try the engineer_vendor_shell.sh trigger: setprop vendor.oplus.eng.nonsignal 1)
# leave FTM: hold Power ~10s to reboot back to Lineage
```

### Phase 5 — if FTM unreachable on Lineage: EDL -> signed stock -> FTM -> write
EDL/firehose CAN install signed stock (VIP-OK using the OFP rawprogram + signed
digest tables). Boot stock, enter FTM, qfenix-write the IMEI, then re-flash
LineageOS (its OTA preserves modem/modemst/persist per SESSION_43 metadata
analysis, so the restored IMEI survives).

## Alternative if USB-diag exposure is stubborn: on-device qfenix
qfenix ships a Linux-arm64 static binary. With root + permissive we can push it
to the phone and run it locally against /dev/diag (no USB port needed):
```
adb push qfenix-linux-arm64 /data/local/tmp/qf; adb shell 'chmod 755 /data/local/tmp/qf'
adb shell '/data/local/tmp/qf list'            # see if it finds /dev/diag
adb shell '/data/local/tmp/qf efsls /nv/item_files/modem/mmode'
```
(Confirm qfenix supports the on-device /dev/diag char device; if it only speaks
a serial/USB port, stick with the USB-gadget method above.)

## Risk notes
- configfs unbind/rebind drops adb for a second; we keep the adb function and
  only ADD diag, so adb returns. Any USB breakage is undone by a reboot
  (configfs changes are not persistent).
- Writing one NV/EFS item to a healthy modem is low-risk and re-readable; keep
  live_modemst*.img backups for rollback. Do NOT erase/format EFS.
- persist.vendor.radio.imei is cosmetic only — ignore it; the real fix is the
  EFS/NV write landing and surviving a reboot (verify via *#06#, not that prop).
