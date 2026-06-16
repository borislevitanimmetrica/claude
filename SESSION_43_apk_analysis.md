# Session 43 — APK Reverse-Engineering Findings

Static analysis of `com.oplus.engineermode.apk` and `com.oplus.engineernetwork.apk`
(both checked into this repo) to determine what code path the OEM's own factory
tool uses to restore IMEI / NV-550. Done with `unzip` + `strings` only — no full
decompiler available in the working sandbox (jadx fetch blocked).

## TL;DR

The IMEI/NV-restore call chain in OPlus's stock stack is:

```
EngineerMode (.apk)
   ── binds to ──► IOplusTelephonyExt   (com.android.internal.telephony, AIDL)
                    [framework-level binder, only present in OPlus's framework]
                       ── invokes ──►  vendor backend
                                         (factorymode.nvcmd.staticNvRestore tag,
                                          unknown HIDL/QMI service on the other side)
                                            ── QMI ──►  modem
```

The **framework binder** `IOplusTelephonyExt` is the entry point. Without it
registered in `system_server`, *nothing* in the OPlus EngineerMode UI works for
NV operations.

This means **Plan 1A's scope is materially larger than estimated in the original
options-comparison doc**. It's not a single HAL `.so` port — it's framework
porting (OPlus's `com.android.internal.telephony.IOplusTelephonyExt` patches into
`framework.jar` / `services.jar`).

## Evidence — strings extracted from the APKs

### com.oplus.engineernetwork.apk (the relevant one for NV/IMEI work)

Binder interfaces referenced:

- `com.android.internal.telephony.IOplusTelephonyExt`  ← **OPlus framework AIDL, missing on LineageOS**
  - `IOplusTelephonyExt.Stub`, `Stub.Proxy`, `Default`
  - Companion: `IOplusTelephonyExtCallback`
  - Methods (inferred from string log messages):
    - `getNvBackupAllowed`, `getNvBackupStatus`, `getNvBackupStat`, `getNvBackupState`
    - `setNvBackupEnableOrDisable`
    - `backupNvBackup`, `restoreNvBackup`, `restoreNvBackupAllowed`
    - `dynamicNvBackup`, `dynamicNvRestore`
    - `staticNvBackup`,  `staticNvRestore`   ← **IMEI lives in static NV**
- `com.qti.extphone.IExtPhone` (QTI framework AIDL, separate vendor binder; status on Lineage TBD)
- `com.qualcomm.qcrilhook.QcRilHook` — the existing HIDL `IQtiOemHook` Java wrapper
  (this is the path the previous session already exhausted; it routes through
  OEM hook opcode 4 which the modem firmware allowlist rejects for NV-550)

Log-message strings that betray the call shape:

```
mGetIOplusTelephonyExtRunnable OplusTelephonyService is null!
retryGetOplusTeleExtService mRetryCount: …
IOplusTelephonyExt DeathRecipient triggered!!!
getRemoteMessenger OplusTelephonyService is null!
oplusGetQcomLTECDMAImei is null!
oplusGetQcomLTECDMAImei failed, …
doNvRead() Failed : %s
doNvWrite() Failed : %s
```

→ The APK retries fetching `OplusTelephonyService` via the binder; on Lineage
that service is never registered, so every retry returns null.

Command-tag strings used by the framework binder, presumably as arguments to
the static/dynamic methods above:

```
factorymode.nvcmd.staticNvBackup
factorymode.nvcmd.staticNvRestore     ← restore IMEI (and other static NVs) on stock
factorymode.nvcmd.staticNvCheck
factorymode.nvcmd.staticNvAutoCheck
factorymode.nvcmd.dynamicNvBackup
factorymode.nvcmd.dynamicNvRestore
factorymode.nvcmd.dynamicNvCheck
factorymode.nvcmd.dynamicNvAutoCheck
factorymode.nvcmd.lteNvChange
```

OPlus framework data classes referenced (also live in framework, missing on Lineage):

```
com.oplus.telephony.NvItems
com.oplus.telephony.NvItems$ImeiSvn
com.oplus.telephony.RadioManager
com.oplus.telephony.RadioNvBackupStat   (struct: NvBackupFlag, NvBackupMiscinfo, NvBackupReport)
com.oplus.telephony.EfsItems$OemMcfgItem
com.oplus.telephony.RadioConfig / RadioCellInfo / RadioNrCellInfo / …
```

AT commands referenced (all *read-only* in this APK; no `=1,…` write forms):

```
AT+EGMR=0,7        ← read IMEI slot 1
AT+EGMR=0,10       ← read IMEI slot 2 (or other identifier)
AT+CFUN, AT+CSRA, AT+ERAT, AT+EGMC, AT+EMCFC …  (RF/RAT test commands; not relevant)
```

→ This APK does **not** contain any IMEI-write AT command. EGMR is used for
read only. The write side is exclusively through `IOplusTelephonyExt`.

### com.oplus.engineermode.apk

Mostly camera, sensor, pressure-sensor, and audio test code. The IMEI handling
present here is read/check only:

- Class `com.oplus.engineermode.IMeiAndPcbCheck` (verifies IMEI vs PCB id)
- Methods: `MSG_GET_IMEI`, `MSG_GET_IMEI{1,2}_DONE`, `mImeiArray`, etc.
- Native libs (`libndt_native.so`, `libTransferAudioCommand.so`) are unrelated to IMEI

Conclusion: the *write* logic is in `engineernetwork`, not `engineermode`. The
"Sub board ID and IMEI" UI activity in stock OxygenOS lives behind one of:

```
com.oplus.engineernetwork.rf.nvbackupui.NVBackupUIActivity
com.oplus.engineernetwork.rf.nvbackupui.upgrade.OplsNVBackupUIActivity
com.oplus.engineernetwork.rf.nvbackupui.upgrade.QualCommNv2
com.oplus.engineernetwork.rf.nvbackupui.CalibrateStatusActivity
```

Of these, `OplsNVBackupUIActivity` + `QualCommNv2` is the call site that
produces `factorymode.nvcmd.staticNvRestore`.

## What changes about the plan

### Plan 1A scope is bigger than originally estimated

The previously imagined Plan 1A — "port the factory@1.0 HIDL `.so` and its
sepolicy/init bits to LineageOS" — is **necessary but not sufficient**. The
actual call goes through a framework AIDL service (`IOplusTelephonyExt`) that
has no LineageOS equivalent. To make the chain work end-to-end on Lineage we'd
need to:

1. Pull `IOplusTelephonyExt.aidl` (or reconstruct from the Stub/Proxy in stock's
   `framework.jar`).
2. Pull whatever class registers that binder in stock's `system_server` (likely
   in OPlus's framework patches; possibly an `OplusTelephonyService` class).
3. Re-implement that registration on Lineage *or* replace the framework call
   site with a direct vendor-tier client (which requires knowing what vendor
   service it ultimately binds to — TBD).
4. Pull/port the vendor backend (HIDL service or daemon) that
   `OplusTelephonyService` calls into.
5. Replicate the SELinux contexts so all of the above can talk.

This is system_server-tier work, not vendor-HAL-tier. Materially bigger than
the previous estimate.

### Plan D becomes more attractive in relative terms

Booting stock OxygenOS short-circuits the entire framework-port problem because
the whole chain is already built and functional. Plan D's primary risk
remains the modem-side gate: even with the right caller identity coming through
the OPlus chain, the modem firmware may still refuse if `fsg`/`fsc` corruption
is a hard prereq for the factory-trust check. We'll only know empirically.

### What we still want to learn before committing to Plan D

Useful no-cost diagnostics on the **stock reference device** (`fcbc948b`,
unrooted shell only, no data damage):

```bash
# Confirm IOplusTelephonyExt is registered as a binder service on stock
adb -s fcbc948b shell 'service list | grep -iE "telephony|engineer|nv|oplus|factory"'

# What process registered it (helps identify framework vs separate daemon)
adb -s fcbc948b shell 'dumpsys -l | grep -iE "telephony|engineer|nv|oplus|factory"'

# All HIDL services on stock - diff against Lineage's lshal dump to see what's missing
adb -s fcbc948b shell 'lshal list -i' > /tmp/stock_lshal.txt

# Is there a stock-side daemon binary that handles factorymode.nvcmd.*
adb -s fcbc948b shell 'ls -la /vendor/bin/ /vendor/bin/hw/ /system/bin/ 2>/dev/null' \
  | grep -iE 'factorymode|nvbackup|oem.*factory|engineer.*service|oplus.*tele'

# What init.rc files declare those daemons
adb -s fcbc948b shell 'find /vendor/etc/init /system/etc/init /odm/etc/init \
  -name "*.rc" 2>/dev/null -exec grep -l -iE "factorymode|nvbackup|oplus.*tele" {} +'

# IExtPhone presence on stock (and on the broken Lineage device for comparison)
adb -s fcbc948b shell 'service list | grep -i extphone'
adb -s 9385711f shell 'service list | grep -i extphone'

# Stock framework jars present? (we'd need these for any framework-level port)
adb -s fcbc948b shell 'ls -la /system/framework/ /system_ext/framework/ 2>/dev/null \
  | grep -iE "oplus|qti|qcom|tele"'
```

Outputs go into `SESSION_43_stock_recon.md` once collected.

## Updated ranking

| Rank | Plan | Probability | Effort | Recovery risk |
|---|---|---|---|---|
| 1 | **D** — downgrade to stock 11_C.26, EngineerMode → Static NV Restore, reflash Lineage | ~40–55% | low (1–3 hrs) | very low (re-flash) |
| 2 | **1A++** — framework-level port of IOplusTelephonyExt + vendor backend | ~20–30% if we can identify it; effort is *system_server-tier*, not HAL-tier | very high (days) | medium |
| 3 | **3** — patch `libqcrilNr` to issue `DMS_SET_IMEI` instead of OEM-hook | ~5–10% | high | medium (binary patching) |
| – | ~~G — `IAtCmdFwd` + AT+EGMR=1,7~~ | n/a — service unregistered on Lineage; would route through same modem gate anyway | — | — |
| – | ~~Remedy 2 (raw QRTR/QMI to OEM service)~~ | ~3% — same wire-level transaction qcrilhook already proved fails | high | low |

Plan D dwarfs the rest. Failure mode of D dictates the next move:

- **D fails with "service unavailable / signature mismatch / factory mode required"** → modem-firmware gate is checking caller signature; *all* userspace paths dead. Look at `fsg` / TZ-state restoration (Plan H).
- **D fails with "static NV restore complete" but `*#06#` still null** → write reported success but didn't persist; check persist partition state.
- **D succeeds but reverts on Lineage reflash** → Lineage's modem-side init wipes NV-550 again; isolate which service in Lineage's init chain does it.
- **D succeeds and survives** → done.
