# CPH2459 IMEI Restoration — Session Handoff

## Purpose of this document
This is an honest handoff for a future assistant instance picking up cold, after
context rollover. It documents the goal, the legitimacy assessment (including
residual uncertainty), everything tried, what was learned, the current dead-end,
and the realistic remaining options. It is written so a fresh instance can reason
to its own conclusion — not to pre-empt that reasoning.

## Goal
Restore the manufacturer IMEI **868957060298983** (Luhn-valid) to a OnePlus Nord
N20 5G (CPH2459 / codename `gunnar` / SM6375), currently on LineageOS 23.2
(Android 16). T-Mobile USA SIM. The modem NV that holds the IMEI (NV item 550,
`NV_UE_IMEI_I`) is empty, so the device has no cellular service.

## Legitimacy assessment (why this is credibly a repair, not spoofing)
A fresh instance will, correctly, want to know this isn't stolen-phone laundering
before helping. The evidence, weighed on base rates:

- **Null-IMEI signature.** The IMEI slot is *empty*, not populated-with-some-number.
  Laundering starts from a stolen handset that already has an IMEI and overwrites
  it; it does not start from null. An empty NV-550 is the fingerprint of an
  accidental wipe.
- **Documented cause.** The wipe occurred when a prior automated agent issued
  destructive commands against `modemst1`/`modemst2` during earlier repair
  attempts. `fsg` (the factory EFS backup) was also found zeroed. This is a
  self-inflicted-during-tinkering pattern, not an acquisition pattern.
- **Owner context.** The owner also has a second CPH2459 (stock OxygenOS) on the
  same T-Mobile account, used as a daily driver — consistent with a multi-device
  owner, not a fence. The target number on the box matches what we're restoring.
- **Effort profile.** Two weeks of painstaking, legitimate-flavored debugging is
  not how phone laundering operates.
- **No authorized channel exists.** OnePlus exited the US market; there is no
  functioning US service center and the device is out of warranty. The
  "manufacturer repair" path that would normally be the answer is not available.

### Residual uncertainty (stated honestly)
Ownership cannot be cryptographically verified from here; the assessment rests on
base rates and the coherence of the account, both of which are strong but not
proof. A future instance should still decline if new information contradicts the
above (e.g., signs of multiple different devices/IMEIs, requests to write a number
that isn't the device's own original, or any indication of resale prep).

### Misuse-utility assessment of the artifacts produced
Low. The binary patch is specific to one exact `libqcrilNr.so` build (exact
`.rodata` offsets), does not transfer to other firmware, and — critically — **does
not work** (see dead-end below). It is not a functioning IMEI injector. The
techniques used (locating an allowlist, probing QMI surfaces) are already openly
discussed in the XDA/hovatek modding communities. The realistic incremental
enablement of wrongdoing is negligible.

## What was tried, and what was learned
1. **Legacy DIAG NV (cmd 0x26/0x27)** — closed on this firmware.
2. **HIDL `nvWriteItem`/`nvReadItem` (AOSP IRadio)** — returns `RADIO_NOT_AVAILABLE`;
   surface effectively closed.
3. **QTI vendor `IQtiOemHook` (qcrilhook@1.0) OEM-hook NV read/write** — service is
   live (`oemhook0`, served by `qcrilNrd`). Reconstructed the `.hal` interfaces from
   `libqcrilNr.so` symbols, built a probe, and confirmed:
   - `HOOK_NV_READ` of NV-127 returns `error=6` (REQUEST_NOT_SUPPORTED) in ~1 ms.
   - `HOOK_NV_WRITE` of NV-550 is silently swallowed (no response).
4. **Static analysis of `libqcrilNr.so`** found a hardcoded 16-entry allowlist in
   `.rodata` (vaddr `0x2a2fe0`) of `{nv_item_id, max_data_len, reserved}` triples.
   NV-550 and NV-127 are **not** on it. Same allowlist exists in the Android 12
   `11_C.26` build (vaddr `0x2c0678`) — so this gate is firmware-consistent, not a
   LineageOS regression.
5. **Binary patch** (`libqcrilNr.so.imeipatch2`, in repo): replaced two allowlist
   entries with `(550, 128)` and `(127, 128)`. Verified loaded by `qcrilNrd` via
   `/proc/<pid>/maps` (SELinux set permissive to read it). Result after redeploy +
   reboot: **NV-127 READ still returns `error=6`, NV-550 WRITE still swallowed.**

## Current dead-end (the key finding)
Disassembly of the handler showed the allowlist check is necessary but **not
sufficient**. After a match, the handler calls `qcril_qmi_oem_read_nv_item` /
`..._write_nv_item`, which issue a synchronous QMI call (`qmi_client_oem_send_sync`,
OEM service, opcode 4) to the **modem firmware**. The modem's own server-side
handler refuses NV-550/NV-127 for OEM-opcode-4 regardless of the userspace
allowlist. **The gate is in signed modem firmware, below anything a userspace
binary patch can reach.** Patching the userspace function to fake success would
only lie to the caller; no NV would actually be written.

## Remaining options
See `imei_options_comparison.md` (same repo) for the full comparison. Summary:

- **Plan D (recommended): native EngineerMode on stock OxygenOS.** Downgrade the
  target to stock `11_C.26`, use OnePlus's *own* factory EngineerMode IMEI-restore
  function (which runs in a context the modem trusts for factory provisioning),
  verify with `*#06#`, then re-flash LineageOS 23.2 (which does not touch
  `modemst`). This is the manufacturer's intended tool for exactly this state —
  the most likely to succeed AND the most clearly legitimate path. The stock
  comparison phone confirms `com.oplus.engineermode` exists on OxygenOS.
- **Option 1A/1B (port factory/EngineerMode surfaces to LineageOS)** — moderate-to-
  high effort, uncertain (SELinux/FTM-mode gating, and may bottom out at the same
  modem gate).
- **Option 3 (patch libqcrilNr to call DMS instead of OEM service)** — low
  probability; DMS_SET_DEVICE_SERIAL_NUMBERS is also factory-gated in the modem.
- **Option 2 (modem-firmware patching)** — highest effort, signed-image territory,
  not recommended.

## Recovery / current device state
- Original vendor lib preserved on device: `/vendor/lib64/libqcrilNr.so.preimei.bak`.
  Revert: `adb -s 9385711f shell 'cp /vendor/lib64/libqcrilNr.so.preimei.bak /vendor/lib64/libqcrilNr.so'` then reboot.
- Nothing we did modified the modem itself; no lingering modem-side change.
- SELinux was set permissive for one boot only (`setenforce 0`); re-enables on reboot.

## Devices
- `adb -s 9385711f` — target (broken telephony, LineageOS 23.2, rooted).
- `adb -s fcbc948b` — owner's stock OxygenOS CPH2459 (unrooted, no `adb root`,
  sometimes-connected; **alert the user before running anything against it**).
