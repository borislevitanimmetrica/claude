# CPH2459 AIDL↔HIDL Radio Bridge Shim Backup

Preservation of the LineageOS 23.2 (Android 14) `android.hardware.radio-library.compat` +
`android.hardware.radio-service.compat` binaries and sources produced on the EC2 build host
during Session 42 → Session 61 IMEI-restoration attempts. Kept so the EC2 volume can be torn
down without losing anything reproducible.

## TL;DR — what to do post-Acer

**After Acer restores NV-550, ship stock LineageOS 23.2 with no custom shim modification.**

Every modification captured here is IMEI-provisioning-experiment code. It doesn't fix any
independent bridge bug; it was an attempt to write NV-550 from userspace via the AIDL bridge's
`sendOemRilRequestRaw` path. That attempt is proven not to work: the modem's NV manager rejects
unsigned writes to NV-550 (`oem_pubkey_index = 0x01`, single OEM key enrolled — see
`SESSION73_findings.md`). Running these shims on a phone whose IMEI has been legitimately
restored by Acer would at best be a no-op and at worst re-write NV-550 with the same target
value at every boot via an unauthenticated OEM-hook that the modem will silently drop anyway.

## Directory contents

```
shim_backup/
├── README.md                                    ← this file
├── SHA256SUMS.txt                               ← integrity for the binary set
├── rebuild_of_AIDL-HIDL_integration_shim_42.txt ← original build recipe from Session 42
├── flash_to_device_5_subset/
│   └── android.hardware.radio-library.compat.so ← the .so actually deployed to the device
│                                                  (bit-identical to session61 base build)
├── session61_compat_deploy/                     ← final Session 61 build products
│   ├── android.hardware.radio-service.compat        service binary v1
│   ├── android.hardware.radio-service.compat.v2     service binary v2 (final)
│   ├── lib32_radio-library.compat.so → .v7.so       lib32 build iterations
│   ├── lib64_radio-library.compat.so → .v7.so       lib64 build iterations
│   ├── radio-compat.rc                              init script
│   └── radio-compat.xml                             VINTF manifest fragment
└── source_from_ec2/                             ← sources archived at EC2 teardown
    ├── libradiocompat_full.tar.gz                   full libradiocompat/ tree with all .bak files
    ├── gunnar_compat_artifacts.tar.gz               fresh built artifacts, tree-shaped
    └── ImeiProvisioning.java                        Java-side variant (device tree)
```

## The "final" build set (session61 v7 + service .v2)

The most recent EC2 build products, sha256-verified equal to the corresponding files in
`session61_compat_deploy/`:

| File | Bytes | sha256 | Deploy path on device |
|---|---|---|---|
| `lib64_radio-library.compat.v7.so` | 628976 | `9aee417439be55b4cfb7518f7b735536cb406eb31eff3069a15de9d620a45245` | `/vendor/lib64/android.hardware.radio-library.compat.so` (no `hw/`) |
| `lib32_radio-library.compat.v7.so` | 466328 | `103164f652551880cf22a6fd24584d6beef82288fdd9ae3f6855a4eea95bf398` | `/vendor/lib/android.hardware.radio-library.compat.so` (no `hw/`) |
| `android.hardware.radio-service.compat.v2` | 57192 | `baf02a71654cae99ff49dd957247360abf427bc1ae95bce4b052899b90ae2681` | `/vendor/bin/hw/android.hardware.radio-service.compat` |
| `radio-compat.rc` | 128 | `ab2f6e3fec43a5e356fdfd338864310938d7f3a8026784822151bc636984c5f9` | (init script — see below) |
| `radio-compat.xml` | 957 | `00d87415b7f8832ecae43d8857db3abe327168a169fd7b451282b324452d4561` | VINTF manifest fragment |

**Do not deploy these post-Acer** unless there is a specific reason (see "Deploy procedure" at
the bottom of this file for the historical procedure, kept for reference only).

## What each source-tree modification does (delta from pristine LineageOS 23.2)

Baseline for these diffs: `/phone/hardware/interfaces/radio/aidl/compat/libradiocompat/` on EC2,
which is bit-identical to the `.preimei.bak` snapshots (confirmed via `diff -q`). Every file below
lives at `hardware/interfaces/radio/aidl/compat/libradiocompat/` unless noted.

| File | Change kind | Purpose | Bug fix? |
|---|---|---|---|
| `Android.bp` | modified | Add `vendor.qti.hardware.radio.qcrilhook@1.0` shared_libs dep + `ImeiProvisioning.cpp` and `OemHookProbe.cpp` to srcs | No — enables the new IMEI-write code |
| `CallbackManager.cpp` | modified | In `delayedSetterThread`, after `setResponseFunctions(...).assertOk()` and before `mDelayedSetterDeadline = std::nullopt`: sleep 5s, then call `imei::provisionImeiAtBoot(mHidlHal, serial)`. Guarded by `mImeiProvisioned.exchange(true)` so it fires once per process lifetime | No — orchestrates the one-shot IMEI write |
| `include/libradiocompat/CallbackManager.h` | modified | Adds `#include <atomic>`; two new members: `std::atomic<bool> mImeiProvisioned{false}` and `std::atomic<int32_t> mImeiProvisionSerial{0x10000000}` | No — state for the one-shot |
| `modem/RadioResponse-modem.cpp` | modified | Two `LOG(INFO)` additions in `nvReadItemResponse` and `nvWriteItemResponse` recording `info.serial`, `info.error`, `result.size()`, and `result` (or `info.type`) | No — pure instrumentation to observe modem responses to the IMEI writes |
| `OemHookProbe.cpp` | NEW | Uses `IQtiOemHook::oemHookRawRequest` to (probe 1) HOOK_NV_READ NV-127 as a control, then (probe 2) HOOK_NV_WRITE NV-550 with the target IMEI in the canonical `[u32 hookId LE][u32 itemId LE][u8[128] data]` layout | No — the actual OEM-hook based write attempt |
| `include/libradiocompat/OemHookProbe.h` | NEW | Header for the above (declares `oemHookProbeAtBoot(...)`) | No |
| `ImeiProvisioning.cpp` | NEW | Higher-level `imei::provisionImeiAtBoot(hidlRadio, serial)` — currently uses `nvWriteItem` (this is the "Remedy 1" iteration; the pre-Remedy-1 version used `sendOemRilRequestRaw` and is saved as `ImeiProvisioning.cpp.preremedy1.bak`) | No |
| `include/libradiocompat/ImeiProvisioning.h` | NEW | Header for the above | No |
| `device/oneplus/sm6375-common/radio/ImeiProvisioning.java` | NEW (device tree, outside libradiocompat) | Java-layer variant of the same idea; reads `persist.vendor.radio.imei` sysprop, Luhn-checks it, builds the OEM-hook payload, calls `IRadio.sendOemRilRequestRaw`. Present in the source tree but not obviously wired into any active caller | No |

**Nothing else in the tree is modified.** Confirmed by:
- `diff -rq /phone/hardware/interfaces/radio/aidl/compat/libradiocompat /phone/lineage/hardware/interfaces/radio/aidl/compat/libradiocompat` → only the files listed above show as different, plus the .bak snapshots
- `find /phone/lineage/device/oneplus -name "*.te"` and `find ... -name "*.rc"` scoped to files touching the compat radio service → **no matches**, so no sepolicy or init.rc modifications
- The device-tree files under `/phone/lineage/device/oneplus/gunnar/` that have newer mtimes are the normal LineageOS device configuration (device.mk, BoardConfig.mk, manifest.xml, audio configs, overlays), not modifications on top of a pristine base

## Why we don't need any of this post-Acer

The IMEI write via `HOOK_NV_WRITE`/`sendOemRilRequestRaw`/`nvWriteItem` reaches the modem's OEM
QMI service (service id 228, QRTR node=0 port=56 — see `SESSION73_findings.md`) and is answered
with a protocol-level "success" that never actually mutates persistent NV. The gate is enforced
by the modem's NV manager against `oem_pubkey_index = 0x01`, which requires an OEM-signed payload
that only OnePlus's factory tooling can produce. Session 73 established this with three
independent probes:

1. QMI OEM `msg_id=5` write of NV-550 with our BCD-encoded IMEI → transport ACK, no state change (verified by direct DIAG readback).
2. DIAG `nvwrite 550` via QFenix → same pattern.
3. QMI OEM `msg_id=5` write of NV-6828 (subscription-2 IMEI, non-gated) with the same payload → succeeds and persists (verified by DIAG readback).

Post-Acer, NV-550 will contain a legitimate signed IMEI. The pristine LineageOS 23.2 shim will
attach normally. Adding these experimental shims on top just risks the delayed setter thread
dispatching HOOK_NV_WRITE at every boot for an already-populated slot.

## The build recipe (kept for reference, in case rebuild ever needed)

From the Session 42 rebuild note, verified consistent with the Session 61 build outputs:

```
# In the LineageOS build tree root (was /phone/lineage on EC2):
source build/envsetup.sh
lunch lineage_gunnar-bp4a-userdebug           # NOT the "-v-" variant
mma -j$(nproc) android.hardware.radio-library.compat android.hardware.radio-service.compat

# Artifacts land at:
out/target/product/gunnar/vendor/lib64/hw/android.hardware.radio-library.compat.so
out/target/product/gunnar/vendor/lib/hw/android.hardware.radio-library.compat.so
out/target/product/gunnar/vendor/bin/hw/android.hardware.radio-service.compat
```

To rebuild the *pristine* LineageOS 23.2 shim (i.e., strip the IMEI experiments):

```
cd hardware/interfaces/radio/aidl/compat/libradiocompat
# Revert the modified files:
cp Android.bp.preimei.bak Android.bp
cp CallbackManager.cpp.preimei.bak CallbackManager.cpp
cp include/libradiocompat/CallbackManager.h.preimei.bak include/libradiocompat/CallbackManager.h
cp modem/RadioResponse-modem.cpp.prephase1.bak modem/RadioResponse-modem.cpp
# Remove the new files:
rm -f ImeiProvisioning.cpp ImeiProvisioning.cpp.*.bak \
      OemHookProbe.cpp OemHookProbe.cpp.*.bak \
      include/libradiocompat/ImeiProvisioning.h \
      include/libradiocompat/OemHookProbe.h
# Then mma the two targets as above.
```

You will not need this. It's here in case a future maintainer wants a clean rebuild.

## Historical deploy procedure (kept for reference only — do not use post-Acer)

If you ever have a reason to deploy an experimental shim over a stock LineageOS 23.2 install
(e.g., to instrument the modem's response to an OEM-hook probe during a repair investigation):

```
# Push the artifacts
adb push lib64_radio-library.compat.v7.so   /sdcard/
adb push lib32_radio-library.compat.v7.so   /sdcard/
adb push android.hardware.radio-service.compat.v2 /sdcard/

# In a root shell on the device — /vendor is dm-verity-locked on this build,
# so use a Magisk module (create /data/adb/modules/radio-compat-shim/ with the
# usual module.prop + files under vendor/). See the QFenix session for the
# exact Magisk-overlay pattern used for the WLAN firmware fix.

# The service also needs the .rc registered — radio-compat.rc content:
#   service vendor.radio-compat /vendor/bin/hw/android.hardware.radio-service.compat
#       class hal
#       user radio
#       group radio
# The .xml is a VINTF fragment; drop it in /vendor/etc/vintf/manifest/.
```

Post-Acer we should not need any of this. Stock LineageOS 23.2 already ships an
`android.hardware.radio-service.compat` that will work with a properly-provisioned modem.

## References

- `SESSION73_findings.md` — the modem-side signature gate empirical evidence
- `HANDOFF_imei_session.md` — session-42-era findings that led to the shim experiments
- `HANDOFF_session72.md` — the direct-QMI OEM investigation
- `rebuild_of_AIDL-HIDL_integration_shim_42.txt` — the original build note from Session 42
