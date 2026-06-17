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
