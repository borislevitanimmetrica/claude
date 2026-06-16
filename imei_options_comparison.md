# IMEI Restoration — Remaining Options Comparison

Context: the qcrilhook userspace path is exhausted (the modem firmware enforces a
server-side gate on NV-550 below any userspace binary patch — see
`HANDOFF_imei_session.md`). These are the paths that remain.

| | Plan D: native EngineerMode on stock | 1A: port factory@1.0 to LineageOS | 1B: port EngineerMode to LineageOS | 3: patch libqcrilNr → DMS |
|---|---|---|---|---|
| **What** | Downgrade target to stock 11_C.26, use OnePlus's own EngineerMode IMEI-restore, verify, re-flash LineageOS (modemst untouched) | Pull `vendor.qti.hardware.factory@1.0` service binary + deps + SELinux/init from stock, run on LineageOS | Install `com.oplus.engineermode` APK (+ maybe `IEngineer` HIDL) on LineageOS as priv-app | Patch `qcril_qmi_oem_*_nv_item` to call DMS service + reshape request to DMS_SET_DEVICE_SERIAL_NUMBERS |
| **Probability of success** | **Highest (~50-65%)** — manufacturer's intended factory provisioning tool, runs in a modem-trusted context | ~25-35% (may be FTM-gated; may hit same modem gate) | ~45-55% if underlying `IEngineer` HIDL present on LineageOS; the IMEI function may still reach the same modem gate | ~10-20% (DMS IMEI write is also factory-gated in modem firmware) |
| **Effort** | Medium (flash down, use UI, flash up; ~30 min reconfig) | High | Medium (if HIDL present) to High | High (DMS TLV reverse-engineering + buffer-resize binary surgery) |
| **Time** | 1-2 hours | 4-8 hours | 1-3 hours (HIDL present) / 4-8 (not) | 6-12 hours |
| **Recovery if it fails** | Clean (re-flash) | Clean (remove files) | Clean (uninstall) | Risky (malformed DMS could leave NV in mixed state) |
| **Legitimacy posture** | Strongest — OEM's own repair tool on OEM firmware | Neutral | Neutral | Weakest — fights modem hardening |

## Recommendation
**Plan D.** It is simultaneously the most likely to work and the most clearly
legitimate: it uses OnePlus's own EngineerMode IMEI-restoration function on
OnePlus's own stock firmware, which is exactly the factory-provisioning context
the modem's server-side gate is designed to *allow*. The userspace dead-end we hit
exists precisely because LineageOS lacks that trusted factory surface; booting
stock restores it.

### Note on Plan D as a free fallback
All EngineerMode/factory binaries needed for Options 1A/1B come pre-installed and
registered on stock 11_C.26. So if porting to LineageOS (1A/1B) is ever attempted
and fails, Plan D needs no porting at all — just flash stock, use the native tool.
The pulls already done feed both.
