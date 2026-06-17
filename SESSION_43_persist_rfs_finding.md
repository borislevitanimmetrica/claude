# Session 43 — Factory IMEI found in /persist RFS (NV-550 plaintext)

## Finding

A correct, plaintext copy of the factory IMEI exists on the live device in the
modem's own NV-item file format, in the `persist` partition (ext4):

```
/mnt/vendor/persist/rfs/msm/mpss/nv/item_files/nv/550              (9 bytes)
/mnt/vendor/persist/rfs/msm/mpss/nv/item_files/modem/mmode/ue_imei_i  (9 bytes)
```

Both contain exactly: `08 8a 86 59 07 06 92 98 38`
→ decodes (length 0x08, type nibble 0xA, nibble-swapped) to **868957060298983**.

- Owner/group: `vendor_rfs:vendor_rfs`
- mtime: **2026-06-09 02:08** (recent — within the repair window, NOT a years-old
  factory artifact)
- Total files under `persist/rfs`: **only 5** → this is a sparse/targeted set,
  NOT the modem's full live NV store (a live EFS holds hundreds of item files).

## Interpretation

- The modem's authoritative NV store is the (encrypted) EFS in modemst1/modemst2,
  where NV-550 is empty. These `/persist/rfs` plaintext files are a secondary
  RFS-backed location.
- Critically: the live LineageOS-booted modem HAS direct access to these exact
  files and STILL reports an empty IMEI (`*#06#` null). The device has rebooted
  many times since the 2026-06-09 mtime, so the modem has re-initialized with
  these files present and has not ingested NV-550 from them.
- Conclusion: merely having the IMEI in RFS plaintext is NOT sufficient on this
  device under Lineage. The modem does not commit NV-550 from this location in
  the current (non-stock) boot state. Consistent with the standing hypothesis
  that NV-550 commit is gated behind authenticated stock TZ/keymaster/FTM state.

## Open provenance question (asked of user)

The recent mtime (2026-06-09) strongly suggests these two RFS files may have been
*manually placed by an earlier repair session* as a restoration attempt, rather
than written organically by the modem. If so, that attempt already failed
(modem still empty across subsequent reboots), which would be a recorded
negative result: RFS-file injection does not restore NV-550 on this device under
Lineage.

## Bearing on the plan

- The IMEI value is confirmed recoverable (present on-device + on the box label).
- No Lineage-reachable mechanism gets it into the modem's active NV — including
  the modem's own plaintext RFS access. This strengthens the case that the
  authenticated stock state is required.
- Path remains: EDL/firehose -> stock OxygenOS -> EngineerMode "Sub board ID and
  IMEI" restore (which runs under the authenticated modem state that can commit
  NV-550) -> verify `*#06#` -> re-flash LineageOS (OTA preserves modem/persist).
- Residual risk: not proven that even stock EngineerMode will commit it; the 3
  prior stock downgrades did not fix it, but the explicit EngineerMode IMEI-
  restore action was never run during them.



---

## CORRECTION (user context) — the RFS files are a failed prior attempt, not a backup

User clarified two things that change the interpretation above:

1. `persist.vendor.radio.imei` is a settable property that mirrors a working IMEI
   for display; it does NOT set NV-550. (Separate from the files found here, but
   noted: on-device IMEI-shaped values can be cosmetic.)
2. **The `persist` partition was entirely erased** during earlier attempts (under
   a prior Sonnet-4.6 session) to boot a custom OS build from source for
   telephony repair. That build never booted fully.

Therefore the two RFS files (`nv/550`, `ue_imei_i`, mtime 2026-06-09) are NOT a
surviving organic factory backup. persist was wiped; the modem has no IMEI to
sync out; so these were almost certainly **hand-placed by the prior session as
an RFS-injection experiment** using the box-label value. That experiment
**failed** — the modem ignored them and `*#06#` stayed null across many reboots.

### Net: this is a recorded NEGATIVE result

Hand-injecting the correct IMEI into `/persist/rfs/.../nv/550` + `ue_imei_i`
does NOT restore NV-550 on this device. The modem's authoritative store is the
modemst EFS, and it does not ingest these RFS plaintext files in the current
boot state.

### Revised inventory of on-device IMEI sources

- modemst1/2 (authoritative EFS): NV-550 empty per modem (`*#06#` null).
- fsg (modem EFS backup): zeroed.
- persist: ERASED during custom-build attempts; current RFS IMEI files are a
  failed manual re-injection, not factory data.
- oplusreserve1: no IMEI.

Conclusion: there is no surviving *authenticated factory* IMEI source on the
device. The IMEI value itself is known (box label: 868957060298983). Restoration
therefore depends on writing that known value into NV-550 under an authenticated
modem state — i.e. a factory/FTM write path, not a "restore from on-device
backup" path.

### Open question that gates Plan D's value

Does stock OPlus EngineerMode (or the PC-side factory tool) support WRITING a
manually-entered IMEI (assembly-line capability), as opposed to only restoring
from an on-device backup? 
- If yes -> EDL -> stock -> EngineerMode manual IMEI write (box-label value) under
  FTM/authenticated state is the remaining viable path.
- If on-phone EngineerMode only restores-from-backup -> no backup exists -> would
  require the OEM PC factory tool (QFIL/QPST service programming or OPlus
  DownloadTool) in FTM with factory auth, which may not be obtainable.

Also possible: modemst EFS is itself damaged (not merely NV-550 empty), which
would both explain the empty IMEI and the modem rejecting writes, and would
require an EFS repair only doable under authenticated/factory state.



---

## modemst backup-vs-live comparison (user backup 2026-05-30, POST-loss)

User's earliest modemst backup is dated 2026-05-30 06:59 UTC — AFTER telephony
was lost (loss was triggered by the official LOS 23.2 AIDL<->HIDL bridge bug;
IMEI loss discovered later). So there is NO pre-loss modemst backup.

Diff (user backup 2026-05-30 vs live pull this session):
- modemst1: 2,610,817 / 3,145,728 bytes differ = **82.996%**, 10,075 ranges
- modemst2: 2,610,617 / 3,145,728 bytes differ = **82.989%**, 10,276 ranges

That is essentially the ENTIRE populated region (modemst is ~82% non-zero) — a
wholesale ciphertext change, not the small localized churn of a few counters.
Two readings:
1. modemst is a live, log-structured ENCRYPTED EFS; over ~18 days the modem's
   wear-leveling/GC rewrites most physical blocks even if logical NV content is
   stable, so wholesale ciphertext drift is plausible and means the EFS is
   alive and the modem is actively reading/writing modemst.
2. We cannot read NV-550 from the ciphertext either way; the authoritative read
   remains the modem's own `*#06#` = null.

Net: the EFS is healthy and mutating, the modem CAN read/write modemst, yet
NV-550 specifically stays empty and rejects writes. That points to a per-item
lock on 550 (IMEI write-protect at the modem), not a dead/corrupt EFS. The
2026-05-30 backup is post-loss, so restoring it would NOT bring the IMEI back.

## Consolidated state (end of investigation phase)

- IMEI value: KNOWN (box label 868957060298983); confirmed format
  08 8a 86 59 07 06 92 98 38.
- Surviving authenticated on-device factory source: NONE
  (persist wiped; fsg zeroed; modemst NV-550 empty; no pre-loss backup;
   the /persist/rfs files are a failed manual re-injection).
- All LineageOS-reachable write paths: gated/rejected at the modem.
- EFS: alive and mutating; item 550 specifically locked.

Remaining theoretical paths, all requiring authenticated/stock state and all
uncertain:
- (A) EDL -> stock OxygenOS -> on-phone EngineerMode IMEI write (IF it supports
  manual entry, not just restore-from-backup). Untested on this device.
- (B) EDL -> stock -> diag/FTM + Qualcomm PC tool (QPST EFS Explorer / QFIL
  service programming) writing ue_imei_i into modem EFS. The canonical factory
  method; needs Qualcomm tooling + modem permitting EFS write in FTM.
- (C) Commercial servicing box (Hydra/UMT/etc.) that performs authenticated
  IMEI repair. Paid, gray-market; many shops decline when no on-device copy
  remains (matches user's experience).
