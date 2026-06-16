# Plan D — Stock OxygenOS → EngineerMode → Static NV Restore → Re-flash Lineage

Restore NV-550 (IMEI 868957060298983) on the broken CPH2459 by booting OPlus's
own stock OxygenOS 11_C.26, using EngineerMode's static-NV-restore function,
then returning to LineageOS 23.2 without disturbing the restored value.

## Pre-conditions verified

| Item | Status |
|---|---|
| Bootloader unlocked | ✓ (`unlocked: yes`) |
| USB debugging | ✓ |
| Battery | ✓ (4423 mV, well above 3.5 V floor) |
| Slot A bootable | ✓ (`current-slot: a`, `slot-successful:a:yes`) |
| Slot B unbootable | ⚠ (`slot-unbootable:b:yes`) — flash to slot A only initially |
| OFP available | ✓ `/Users/boris/Downloads/CPH2459export_11_C.26_2025020813270000/CPH2459export_11_C.26_2025020813270000.zip` |
| OFP decryptor | ✓ `/Users/boris/Downloads/CPH2459export_11_C.26_2025020813270000/oppo_decrypt/oppo_decrypt.py` |
| Lineage zip | ✓ `/Users/boris/Downloads/flash_to_device_5/lineage-23.2-20260610-nightly-gunnar-signed/lineage-23.2-20260610-nightly-gunnar-signed.zip` |
| Lineage .img files | ✓ (boot, vendor_boot, dtbo, vbmeta, super_empty in same dir) |
| modem-related partitions in Lineage OTA | ✗ (Lineage zip does not write modem/modemst/persist — see SESSION_43 §6) |
| 3× successful prior downgrade history | ✓ (ARB not blocking) |

## Phase A — Decrypt OFP

```bash
cd /Users/boris/Downloads/CPH2459export_11_C.26_2025020813270000

# extract the wrapper zip if not done already
unzip -o CPH2459export_11_C.26_2025020813270000.zip

# locate the .ofp inside
find . -maxdepth 3 -name '*.ofp' -not -path '*oppo_decrypt*'

# decrypt — adjust path to the .ofp once located
python3 oppo_decrypt/oppo_decrypt.py \
    /Users/boris/Downloads/CPH2459export_11_C.26_2025020813270000/<filename>.ofp \
    ofp_decrypted/

# verify the .img set
ls -la ofp_decrypted/*.img | sort
```

You should see at minimum: `boot.img`, `dtbo.img`, `vendor_boot.img`,
`vbmeta.img`, `super.img`, `modem.img`, plus the Snapdragon firmware blobs
(`abl.img`, `aop.img`, `devcfg.img`, `hyp.img`, `keymaster.img`, `qupfw.img`,
`tz.img`, `uefi.img`, `xbl.img`, `xbl_config.img`).

### Partitions to flash and partitions to skip

**Flash (stock, slot A):**

| Partition | Why |
|---|---|
| `boot` | Stock kernel + ramdisk |
| `dtbo` | Device tree overlays for stock |
| `vendor_boot` | Vendor ramdisk for stock |
| `vbmeta` | Verified-boot metadata; required for stock to boot |
| `super` | Stock dynamic partition (system, vendor, product, system_ext, odm) |
| `modem` | Stock Q6 modem firmware — **important** so EngineerMode talks to a stock-vintage modem |
| (optionally) `abl`, `aop`, `devcfg`, `hyp`, `keymaster`, `qupfw`, `tz`, `uefi`, `xbl`, `xbl_config` | aboot-tier firmware. Skip unless boot fails — these are usually compatible across OS versions on the same SoC. |

**Do NOT flash:**

| Partition | Why not |
|---|---|
| `modemst1`, `modemst2` | They contain the device's existing 82%-populated encrypted EFS. EngineerMode will write NV-550 to whatever's there. Overwriting with OFP defaults loses the device's own state. |
| `persist` | Holds per-device keys (RPMB, Widevine cert, fingerprint cal). OFP's persist is a factory blank; flashing it would brick Widevine L1, fingerprint, etc. |
| `fsg`, `fsc`, `mdm1m9kefsc` | Currently zeroed on the device. Their OFP versions are factory shadows; flashing might or might not help. **Conservative choice: leave alone in this run.** If Phase C fails specifically because EngineerMode complains about missing factory state, we revisit and selectively flash `fsg.img` from OFP. |
| `userdata`, `metadata` | Would wipe the user's data. Not needed for Plan D. |

## Phase B — Flash stock partitions to slot A

```bash
adb -s 9385711f reboot bootloader

# sanity check
fastboot -s 9385711f getvar current-slot
# expect: current-slot: a

cd /Users/boris/Downloads/CPH2459export_11_C.26_2025020813270000/ofp_decrypted/

# core stock images, slot A only
fastboot -s 9385711f flash --slot=a boot         boot.img
fastboot -s 9385711f flash --slot=a dtbo         dtbo.img
fastboot -s 9385711f flash --slot=a vendor_boot  vendor_boot.img
fastboot -s 9385711f flash --slot=a vbmeta       vbmeta.img
fastboot -s 9385711f flash --slot=a modem        modem.img

# super is logical; flashing applies to current slot
fastboot -s 9385711f flash super super.img

# DO NOT touch modemst1, modemst2, persist, fsg, fsc, mdm1m9kefsc, userdata.

# boot stock
fastboot -s 9385711f reboot
```

If the device fails to boot stock after this (you see fastboot/recovery again
or a black screen for >2 min), come back and add the aboot-tier firmware:

```bash
for f in abl aop devcfg hyp keymaster qupfw tz uefi xbl xbl_config; do
  fastboot -s 9385711f flash --slot=a $f ${f}.img
done
fastboot -s 9385711f reboot
```

## Phase C — Boot stock and run EngineerMode

After reboot the device shows the stock OxygenOS setup wizard.

1. **Skip setup wizard.** Skip Wi-Fi, skip Google account, skip everything
   you can. Don't insert the SIM yet (we want to verify IMEI first, and
   stock IMS may try to register and fail loudly with no IMEI).

2. **Confirm starting state:** dial `*#06#`. Should show no IMEI / blank /
   placeholder. Confirms we're operating against the same broken modem state.

3. **Enable Developer Options:** Settings → About phone → tap "Build number"
   (or "Version" → tap a build-related field) seven times. Confirm with PIN
   if asked.

4. **Enable USB debugging:** Settings → System → Developer options → "USB
   debugging" → on. Authorize the Mac when the prompt appears.

5. **Launch EngineerMode.** You haven't entered EngineerMode on this build
   before, so try the entry methods in order until one works:

   **5a. Dialer codes** (try first; simplest):
   - Dial `*#800#`
   - If nothing: dial `*#36446337#` (`*#ENGINEER#`)
   - If nothing: dial `*#1234#` (sometimes opens a debug menu)
   - If nothing: dial `*#8011#` or `*#9090#`

   **5b. Direct activity launch via adb** (if dialer codes don't work):
   ```bash
   adb -s 9385711f shell am start -n com.oplus.engineermode/.EngineerModeMain
   adb -s 9385711f shell am start -n com.oplus.engineermode/.EngineerModeApplication
   adb -s 9385711f shell am start -n com.oplus.engineernetwork/.MainActivity
   ```

   **5c. Direct NV-Restore activity** (the most targeted, given what
   SESSION_43 §1 found):
   ```bash
   # primary target
   adb -s 9385711f shell am start -n com.oplus.engineernetwork/com.oplus.engineernetwork.rf.nvbackupui.upgrade.OplsNVBackupUIActivity

   # fallback if the above is not exported
   adb -s 9385711f shell am start -n com.oplus.engineernetwork/com.oplus.engineernetwork.rf.nvbackupui.NVBackupUIActivity
   ```

   If 5c throws `SecurityException: not exported`, fall back to launching
   the main EngineerMode and navigating from inside.

6. **Navigate to Static NV Restore.** Once in EngineerMode:
   - Look for a tab/section labeled **"Connectivity Test"**, **"RF
     Test/Calibrate"**, or just **"Network"**.
   - Inside, look for **"Sub board ID and IMEI"**, **"NV Backup"**,
     **"Static NV"**, **"Restore IMEI"**, or **"RF NV Backup"**.
   - The function we want is the one that ultimately calls
     `IOplusTelephonyExt.staticNvRestore("factorymode.nvcmd.staticNvRestore",…)`
     per SESSION_43 §1.
   - It may prompt for confirmation, an unlock code, or a device PIN.
     The unlock code on OnePlus engineering builds is sometimes `1357246` or
     `0000`; if it asks, try those first. If neither works, the function
     itself may simply require no unlock.

7. **Verify.** Dial `*#06#`. Should show **868957060298983**.

   Also cross-check via adb:
   ```bash
   adb -s 9385711f shell service call iphonesubinfo 1
   # decoded result should contain "868957060298983"
   ```

## Phase D — Re-flash Lineage 23.2 (preserves restored NV-550)

The Lineage OTA payload writes only super sub-partitions plus
boot/dtbo/vbmeta/vendor_boot. It does **not** touch modem, modemst1,
modemst2, persist, fsg, fsc, or userdata (per SESSION_43 §6). So a sideload
of the Lineage zip will leave the restored NV-550 intact.

```bash
adb -s 9385711f reboot bootloader

cd /Users/boris/Downloads/flash_to_device_5/lineage-23.2-20260610-nightly-gunnar-signed/

# Lineage core images, slot A
fastboot -s 9385711f flash --slot=a boot         boot.img
fastboot -s 9385711f flash --slot=a dtbo         dtbo.img
fastboot -s 9385711f flash --slot=a vendor_boot  vendor_boot.img

# vbmeta with verification disabled — Lineage's vbmeta won't pass stock signing
fastboot -s 9385711f --disable-verity --disable-verification \
    flash --slot=a vbmeta vbmeta.img

# Reset super partition layout to empty so update_engine can repopulate
fastboot -s 9385711f flash super super_empty.img

# Reboot to recovery for sideload
fastboot -s 9385711f reboot recovery
```

In recovery (Lineage Recovery should boot, since boot.img now contains
Lineage's recovery kernel):

- Navigate to **"Apply update" → "Apply from ADB"**.

Then on the Mac:

```bash
adb -s 9385711f sideload /Users/boris/Downloads/flash_to_device_5/lineage-23.2-20260610-nightly-gunnar-signed/lineage-23.2-20260610-nightly-gunnar-signed.zip
```

After sideload completes, in recovery: **"Reboot system now."**

## Phase E — Verification

1. Boot to LineageOS 23.2.
2. **`*#06#`** → should show **868957060298983**.
3. Insert T-Mobile SIM. Wait ~30 s. Settings → About phone → SIM status →
   confirm "T-Mobile" registered with signal strength.
4. **Power-cycle test:** full power off (long-press power, "power off"),
   wait 5 s, power on. Verify `*#06#` still shows IMEI.
5. **Functional test:** make a call to a known number; confirm mobile data
   reaches the internet.

## Phase F — Optional: rebuild slot B

Only after Phase E succeeds:

```bash
adb -s 9385711f reboot bootloader

cd /Users/boris/Downloads/flash_to_device_5/lineage-23.2-20260610-nightly-gunnar-signed/

fastboot -s 9385711f flash --slot=b boot         boot.img
fastboot -s 9385711f flash --slot=b dtbo         dtbo.img
fastboot -s 9385711f flash --slot=b vendor_boot  vendor_boot.img
fastboot -s 9385711f --disable-verity --disable-verification \
    flash --slot=b vbmeta vbmeta.img

fastboot -s 9385711f set_active a   # leave A as active
fastboot -s 9385711f reboot
```

Slot B is now restorable as a fallback.

## Failure modes and rollback

### Phase B fails (device unbootable after stock flash)

Re-run Phase B. The OFP gives us a complete partition set. If both slots end
up dead, fall through to MSM/EDL recovery via the Mac (the OFP includes the
unbrick image typically used by OnePlus's repair tool).

### Phase C fails: EngineerMode UI missing or won't open

Means the package isn't on the OFP image we flashed (unlikely — EngineerMode
ships with stock OxygenOS) or the entry point is different on this build.
Try `pm list packages | grep -iE 'engineer|factory'` from adb to confirm
which packages are installed, then `dumpsys package <pkg> | grep Activity`
to enumerate launchable activities.

### Phase C fails: EngineerMode opens but Static NV Restore button is missing or grayed-out

Indicates the modem-side gate is rejecting EngineerMode's request. This
would be the first time a pure-userspace path (running from stock OPlus
framework with full IEngineer + factory@1.0 backing) defeats the OEM's own
tool. Strongly suggests deeper factory-state corruption — likely the zeroed
`fsg`. Stop, take a `*#06#` screenshot, capture EngineerMode logs:

```bash
adb -s 9385711f logcat -d -b all -s EngineerMode:* IOplusTelephonyExt:* OplusTelephonyService:* IEngineer:* > engmode_failure.log
```

Then try with `fsg.img` from OFP added to the Phase B flash list and re-run
Phase C. If that *also* fails, all userspace paths are dead and we'd need to
look at the TZ-tier factory provisioning state — outside Plan D's scope.

### Phase C: Restore reports "success" but `*#06#` still empty

The modem accepted the call but did not write. Same rejection mode as
Remedy 1's qcrilhook attempt, just at a deeper layer. Same diagnosis as the
previous failure mode.

### Phase D: Lineage sideload wipes IMEI

Means our analysis of metadata.pb missed something — payload.bin's manifest
must list more partitions than metadata.pb tracks. Stop, capture the sideload
log, and run `payload_dumper.py` on payload.bin to enumerate the actual
partition list. We can then either (a) extract+reinject NV-550 between Phase
C and Phase D, or (b) stay on stock OxygenOS as the new baseline and skip
Phase D.

### Phase E: SIM doesn't register on Lineage even with restored IMEI

May indicate Lineage's modem init wipes some other NV at boot, or the
restored IMEI is in a format the modem rejects on the first registration
attempt. Capture `logcat -b radio` and `dmesg | grep -i modem` for diagnosis.

## What this Plan does **not** address

- Restoring `fsg`, `fsc`, `mdm1m9kefsc`. If those turn out to be required
  for downstream features (Widevine L1, secure storage, factory mode entry
  on demand), they need a separate fix.
- The "slot B unbootable" situation. Phase F provides a path to rebuild it
  but requires a known-good Phase E first.
- Anything carrier-side — if T-Mobile has the device's previous IMEI flagged
  for any reason, restoring NV-550 doesn't address that. Check
  https://www.t-mobile.com/support/devices/check-your-imei after Phase E.
