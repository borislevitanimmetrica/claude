# Session 43 — Reconnaissance summary (consolidated)

This document consolidates the static-analysis work done in session 43 to
identify what code path actually restores IMEI on stock OxygenOS, and to
characterize the unexplored HIDL surfaces on the broken LineageOS target.

## TL;DR

- The IMEI restore path on stock OxygenOS goes through a framework AIDL binder
  named `oplus_telephony_ext` (interface
  `com.android.internal.telephony.IOplusTelephonyExt`), invoked with the
  command tag `factorymode.nvcmd.staticNvRestore`. This binder is registered
  by OPlus framework patches in `system_server` and is **not** present on
  LineageOS 23.2.
- All six previously-unexplored HIDL surfaces have been characterized via
  symbol-table inspection of their `Bp/Bn` proxy/stub classes. **None expose
  an IMEI / NV write method.** The combined upside of further userspace HIDL
  experimentation is effectively zero.
- The previous session's claim that `modemst1`/`modemst2` are "zero-padded
  templates" was wrong. They're 82% non-zero with a valid `IMGEFS1` magic
  header — encrypted EFS with substantial populated content. Only NV-550 is
  specifically missing.
- Plan D (boot stock OxygenOS 11_C.26, run EngineerMode → static NV restore,
  re-flash Lineage 23.2) is the dominant move. The Lineage OTA does not write
  modem-related partitions, so a restored NV-550 survives the re-flash.
- Plan 1A's scope is much larger than originally estimated (system_server-tier
  framework porting). Plan 3 and Remedy 2 are dropped.

## 1. APK reverse-engineering — what calls what

Static analysis of `com.oplus.engineermode.apk.zip` and
`com.oplus.engineernetwork.apk` (both checked into this repo) using `unzip`
and `strings` only. No full decompiler available in the sandbox.

### Call chain on stock OxygenOS

```
EngineerMode (.apk)
   ├── binds to "oplus_telephony_ext" (ServiceManager binder)
   ├── interface: com.android.internal.telephony.IOplusTelephonyExt
   ├── method: staticNvRestore("factorymode.nvcmd.staticNvRestore", ...)
   ↓
[OPlus framework patches in system_server / framework.jar — not in this APK]
   ↓
[vendor backend HIDL — most likely vendor.oplus.hardware.engineer@1.0::IEngineer
 or vendor.qti.hardware.factory@1.0::IFactory; both are registered on stock
 (see §4) but absent on Lineage]
   ↓
QMI → modem → writes NV-550 in modemst
```

### Key string-evidence from `com.oplus.engineernetwork.apk`

Binder interfaces referenced (all in the engineernetwork dex):

- `com.android.internal.telephony.IOplusTelephonyExt` ← entry point
- `com.qti.extphone.IExtPhone` (separate vendor binder, not on Lineage)
- `com.qualcomm.qcrilhook.QcRilHook` (already-tested path)
- Activity that fires the restore: `com.oplus.engineernetwork.rf.nvbackupui.upgrade.OplsNVBackupUIActivity` (with helper class `QualCommNv2`)

Methods inferred to exist on `IOplusTelephonyExt`:

```
getNvBackupAllowed, getNvBackupStatus, getNvBackupStat, getNvBackupState
setNvBackupEnableOrDisable
backupNvBackup, restoreNvBackup, restoreNvBackupAllowed
dynamicNvBackup, dynamicNvRestore
staticNvBackup,  staticNvRestore             ← IMEI lives in static NV
```

Command tags (passed as method arguments, not properties):

```
factorymode.nvcmd.staticNvBackup
factorymode.nvcmd.staticNvRestore     ← what restores IMEI on stock
factorymode.nvcmd.staticNvCheck
factorymode.nvcmd.staticNvAutoCheck
factorymode.nvcmd.dynamicNvBackup
factorymode.nvcmd.dynamicNvRestore
factorymode.nvcmd.dynamicNvCheck
factorymode.nvcmd.dynamicNvAutoCheck
factorymode.nvcmd.lteNvChange
```

Log strings confirming the call shape:

```
mGetIOplusTelephonyExtRunnable OplusTelephonyService is null!
retryGetOplusTeleExtService mRetryCount: …
IOplusTelephonyExt DeathRecipient triggered!!!
oplusGetQcomLTECDMAImei is null!
doNvRead() Failed : %s
doNvWrite() Failed : %s
```

OPlus framework data classes referenced (all in `framework.jar`, not in the APK):

```
com.oplus.telephony.NvItems / NvItems$ImeiSvn
com.oplus.telephony.RadioManager
com.oplus.telephony.RadioNvBackupStat   (NvBackupFlag, NvBackupMiscinfo, NvBackupReport)
com.oplus.telephony.EfsItems$OemMcfgItem
```

### AT commands referenced

The only AT commands literally present in the dex are:

```
AT+EGMR=0,7        ← read IMEI slot 1
AT+EGMR=0,10       ← read IMEI slot 2
AT+CFUN, AT+CSRA, AT+ERAT, AT+EGMC, AT+EMCFC, AT+ERFTX, …  (RF/RAT test commands)
```

There is **no** `AT+EGMR=1,…` write form. EngineerMode reads IMEI via AT+EGMR
but does not write it via AT. Plan G (`IAtCmdFwd` + `AT+EGMR=1,7`) is dead
both because no one publishes `IAtCmdFwd` on Lineage and because OPlus's
own tooling on stock doesn't use that path either.

### com.oplus.engineermode.apk

Camera, sensor, pressure-sensor, audio test code. The IMEI handling here is
read/check only (`com.oplus.engineermode.IMeiAndPcbCheck`, with messages
`MSG_GET_IMEI`, `MSG_GET_IMEI{1,2}_DONE`). No write logic. The NV restore
logic is exclusively in `engineernetwork`.

## 2. Implication: Plan 1A scope is system_server-tier

Plan 1A as imagined in the original options doc was "drop a
`vendor.qti.hardware.factory@1.0-service` `.so` onto Lineage." That's
**necessary but not sufficient.** The actual call goes through a framework
AIDL service (`IOplusTelephonyExt`) registered by `system_server` from OPlus
framework patches. To make the chain work end-to-end on Lineage we'd need to:

1. Recover `IOplusTelephonyExt.aidl` (or reconstruct from the Stub/Proxy in
   stock's `framework.jar`).
2. Pull the class that registers it in stock's `system_server` (likely
   `OplusTelephonyService` in OPlus's framework patches).
3. Re-implement that registration on Lineage, or replace the framework call
   site with a direct vendor-tier client (which requires identifying which
   vendor service it ultimately binds to — TBD).
4. Pull/port the vendor backend (HIDL service or daemon).
5. Replicate SELinux contexts so all of the above can talk.

This is system_server-tier work. Materially bigger than originally
estimated — days, not hours.

## 3. modemst inspection — previous session was wrong

Previous session asserted "modemst1 and modemst2 contain only templates with
all payload zeroed out." Direct inspection contradicts this:

- `modemst1.img`: 3 MB, 82% non-zero. Header at offset 0x20 reads
  `IMGEFS1|` — the canonical Qualcomm IMGEFS magic, indicating a populated
  EFS image.
- Block density across the file: blocks 0–145 are 96–99% non-zero; blocks
  160–191 are 100% zero. Normal partial-fill pattern.
- Embedded ASCII pathnames: only ~9 path-shaped strings, all garbled.
  9-byte BCD-shaped pattern matches contain a-f nibbles in digit positions.
  Both consistent with **encrypted EFS at rest** — standard on bp4a-class
  Snapdragon firmware.

Interpretation: modemst1/2 contain substantial encrypted EFS data;
encryption key is in modem secure storage. The host-side dump cannot reveal
which NV items are populated — only the modem can answer that, and its
current answer is "NV-550 empty."

The fully-zeroed `fsg`/`fsc`/`mdm1m9kefsc` partitions remain the open risk for
Plan D (these are factory shadow / config partitions; their absence may or
may not block factory-attestation at the modem-side gate).

## 4. HIDL surfaces — full 6/6 characterization

All six previously-unexplored HIDL surfaces, characterized by extracting
`BpHw*::method(` symbols from their bindings `.so` files in this repo.

### `vendor.qti.data.factory@2.3::IFactory` — 0%

Cumulative methods (V2_0 … V2_3): all are `createXService(...)`. It's a
design-pattern factory — every method just hands out other interfaces
(QmiIAgent, RcsConfig, CneIService, CneIApiService, ILinkLatencyService,
DynamicddsISubscriptionManager, ISlmService, IMwqemService, ILceService).
Zero identifier semantics.

### `vendor.qti.ims.factory@2.2::IImsFactory` — 0%

Cumulative methods (V2_0 … V2_2): all are `createXService(...)` for IMS
domain (ConfigService, OptionsService, PresenceService, ConnectionService,
CallCapabilityService, RcsSipTransportService, plus 1.1/1.2 revisions).
Same factory pattern, zero IMEI relevance.

### `vendor.qti.hardware.radio.qtiradio@1.0..@2.7::IQtiRadio` — 0%

Full cumulative method set across all 8 versions:

```
@1.0   getAtr, setCallback
@2.0 + disable5g, enable5g, enable5gOnly, query5gStatus,
       queryNrBearerAllocation, queryNrDcParam,
       queryNrSignalStrength, sendCdmaSms
@2.1 + query5gConfigInfo, queryUpperLayerIndInfo
@2.2 + queryNrIconType
@2.3 + enableEndc, queryEndcStatus,
       getPropertyValueBool, getPropertyValueInt, getPropertyValueString
@2.4 + setCarrierInfoForImsiEncryption     ← closest to "identifier" but unrelated
@2.5 + queryNrConfig, setNrConfig
@2.6 + getQtiRadioCapability
@2.7 + getQosParameters
```

5G/NR feature-control extension to AOSP IRadio. The closest thing to
identifier-write is `setCarrierInfoForImsiEncryption`, which sets a
carrier-provided **public key for encrypting outbound IMSI** in 5G NAS
messages — not the IMSI itself, definitely not IMEI. No `setImei`, no
`nvWrite`, no `provision*`, no factory-write surface.

### `vendor.qti.hardware.radio.internal.deviceinfo@1.0::IDeviceInfo` — 0%

| Sub-interface | Methods (custom) |
|---|---|
| `IDeviceInfo` | `setCallbacks`, `sendDeviceInteractiveInfo`, `sendDevicePowerInfo`, `sendFeaturesSupported` |
| `IDeviceInfoIndication` | `onDeviceInfoReportingChanged`, `onPowerInfoReportingChanged` |
| `IDeviceInfoResponse` | `sendDeviceInteractiveInfoResponse`, `sendDevicePowerInfoResponse`, `sendFeaturesSupportedResponse` |

Despite the name, this is the *opposite* of what we'd want — it sends
device-state info **down to the modem** (screen on/off, power state, supported
features) for power optimization. No identifier read/write.

### `vendor.oplus.hardware.appradio@1.0::IOplusAppRadio` — 0%

```
IOplusAppRadio:
  setCallback, setNecConfigRequest, setNecReportPeriod
  getDmfNwDataRequest, getIcdDataRequest, getNecDataRequest
IOplusAppRadioIndication:
  onNecIndication, onNecIndicationFromQcril, onEventIndicationFromMtk
IOplusAppRadioResponse:
  getDmfNwDataResponse, getIcdDataResponse, getNecDataResponse,
  setNecConfigResponse, setNecReportPeriodResponse
```

OPlus's app-tier network event framework — DMF (Data Management Framework),
ICD (Intelligent Connection Dispatcher), NEC (Network Event Coordinator).
App-coordination only. No IMEI / NV write.

### `vendor.oplus.hardware.ims@1.0::IOplusImsRadio` — ~1%

```
IOplusImsRadio:
  setCallback, queryVopsStatus, sendOemCommand
IOplusImsRadioIndication:
  oemCommonInd
IOplusImsRadioResponse:
  queryVopsStatusResponse, sendOemCommandResponse
```

`sendOemCommand` is the only method with even theoretical IMEI-write potential
— it's a generic OEM command tunnel. But it lives on the IMS interface, so
its scope is IMS-related OEM commands (VoLTE/VoNR config, MMTel features),
not modem-NV operations. Even if it reaches the modem via QMI, the modem's
NV-550 gating is at the EFS layer and applies regardless of which QMI tunnel
arrives. No new path. ~1% prior, eliminated for practical purposes.

### Final surfaces table

| Surface | P(success) |
|---|---|
| `vendor.qti.data.factory@2.3::IFactory` | 0% |
| `vendor.qti.ims.factory@2.2::IImsFactory` | 0% |
| `vendor.qti.hardware.radio.qtiradio@1.0..@2.7::IQtiRadio` | 0% |
| `vendor.qti.hardware.radio.internal.deviceinfo@1.0::IDeviceInfo` | 0% |
| `vendor.oplus.hardware.appradio@1.0::IOplusAppRadio` | 0% |
| `vendor.oplus.hardware.ims@1.0::IOplusImsRadio` | ~1% |

**Aggregate upside of all six surfaces: <2%.** The HIDL surface-mining line
of inquiry is closed.

## 5. Stock-side findings (CPH2459 OxygenOS 11_C.26 reference, `fcbc948b`)

Confirmed registered as binder services (from `service list`):

- `oplus_telephony_ext` → `com.android.internal.telephony.IOplusTelephonyExt`
- `engineer` → `android.engineer.IOplusEngineerManager`
- `extphone` → `org.codeaurora.internal.IExtTelephony`
- `qti.radio.extphone` → `org.codeaurora.internal.IExtTelephony` (second registration, same interface)
- `ISubsysRadio` → `com.oplus.telephony.ISubsysRadio`

Confirmed registered as HIDL services (from `lshal list -i`):

- `vendor.oplus.hardware.engineer@1.0::IEngineer/default` ← OPlus engineer HIDL
- `vendor.oplus.hardware.handlefactory@1.0::IHandleFactory/default`
- `vendor.qti.hardware.radio.qcrilhook@1.0::IQtiOemHook/oemhook0` (also on Lineage)
- `vendor.qti.data.factory@2.0/2.1/2.2::IFactory/default`
- `vendor.qti.ims.factory@1.0/1.1::IImsFactory/default`

Init.rc files on stock that LineageOS lacks:

```
/odm/etc/init/vendor-oplus-hardware-engineer@1.0-service.rc
/odm/etc/init/vendor_engineermode.rc
/vendor/etc/init/vendor.qti.hardware.factory@1.0-service.rc
/vendor/etc/init/hw/init.at.qcom.rc
/vendor/etc/init/hw/init.at.target.rc
/vendor/etc/init/hw/init.oem_ftm.rc
/vendor/etc/init/hw/init.qcom.factory.rc
/vendor/etc/init/hw/vendor.oem_ftm.rc
/vendor/etc/init/hw/vendor.oem_ftm_svc_disable.rc
```

These are the candidate Plan-1A donors. None of `oplus_telephony_ext`,
`engineer`, `extphone`, or `ISubsysRadio` is registered on the broken LineageOS
target — confirmed by empty result of
`adb -s 9385711f shell 'service list | grep -iE "extphone|oplus|engineer|nv"'`.

## 6. Lineage 23.2 OTA inspection — Plan D's re-flash phase is safe

`META-INF/com/android/metadata.pb` of
`lineage-23.2-20260610-nightly-gunnar-signed.zip` lists post-build properties
for these partitions only:

```
product
system
system_ext
vendor
vendor_dlkm
```

These are all super sub-partitions (dynamic super on gunnar). `boot`, `dtbo`,
`vbmeta`, `vendor_boot` are written by the OTA payload but don't appear in
metadata.pb because they have no build.prop. `modem`, `modemst1`, `modemst2`,
`persist`, `fsg`, `fsc`, `userdata`, `metadata` are **not** referenced and
not written by the OTA.

OTA structure:

```
META-INF/com/android/metadata
META-INF/com/android/metadata.pb
META-INF/com/android/otacert
apex_info.pb
care_map.pb
payload.bin                  ← 1.5 GB; written via update_engine
payload_properties.txt
ota-type=AB
post-build=OnePlus/CPH2459/OP5159L1:12/RKQ1.211119.001/...
```

`updater-script` is empty (modern A/B OTAs don't use legacy edify scripting).

**Implication: a Lineage zip sideload preserves modemst1/2 and persist
intact.** Once we restore NV-550 via stock EngineerMode, re-flashing Lineage
via sideload will not touch the restored value.

## 7. Final ranking

| Rank | Plan | P(success) | Effort |
|---|---|---|---|
| **1** | **D** — boot stock 11_C.26 → EngineerMode → static NV restore → re-flash Lineage | 40–55% | low (2–4 hrs) |
| 2 | 1A++ — port `IOplusTelephonyExt` framework + backend HIDLs to Lineage | 20–30% | very high (days) |
| 3 | 3 — patch `libqcrilNr` for `DMS_SET_IMEI` | 5–10% | high |
| – | ~~G, Remedy 2, qti.data.factory, qti.ims.factory, IQtiRadio, IDeviceInfo, IOplusAppRadio, IOplusImsRadio~~ | 0–1% each | dead |

Plan D is the dominant move and dictates the next session. Its detailed
sequence is in [`PLAN_D.md`](./PLAN_D.md).
