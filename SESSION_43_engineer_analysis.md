# Session 43 — IEngineer service binary analysis (Plan 1A result)

Disassembly/symbol analysis of the stock service binary
`vendor-oplus-hardware-engineer@1.0-service` (extracted from the 11_C.26 OFP
`odm_a` EROFS partition).

## Result: IEngineer is NOT the IMEI/NV-550 write path. Plan 1A-via-IEngineer is dead.

### Evidence — complete import set of the service binary

NEEDED libs: `vendor.oplus.hardware.engineer@1.0.so`, libbase, libcutils,
libdumpstateutil, libhidlbase, libhidltransport, libhwbinder, liblog, libutils,
**libcrypto**, **liboddi_vendor.so**, libem5g_jni_vendor, libc++/c/m/dl.

Undefined (imported) functions — the binary's entire external capability:
- libc file I/O: `fopen/fread/fwrite/open/read/write/lseek/stat/getmntent/...`
- `property_set`
- **`oddi_hal_wrapper_dci*`** (the ONLY modem-facing imports): `dciInit`,
  `dciCdmaGetTxAdc`, `dciGsmSetTxOn`, `dciLteGetTxAdc`, `dciNr5gSetTxOn`,
  `dciControlLteRxChains`, `dciDisplayAllRffeRegistValue`, `dciGetSupportBand`,
  `dciQueryAntNum`, `dciQlinkBlerTest`, `dciTriggerModemCrash`, etc.
- libcrypto: `RSA_verify`, `SHA256_*`, `PEM_read_bio_RSA_PUBKEY`, `BIO_*`

There is **no** QMI client, **no** qcril symbol, **no** `/dev/diag`, **no** EFS/RFS
client, **no** `nv_write`/`nv_read`, **no** `item_files` reference anywhere in the
binary (verified by both the dynamic symbol table and a full `strings` sweep).

### What the service actually does

- `readData(path,offset,size)` / `writeData(path,offset,trunc,size,data)`:
  file I/O against OPlus reserve/persist paths only. Strings confirm the roots:
  `/mnt/vendor/oplusreserve`, `/mnt/vendor/opporeserve`,
  `/mnt/vendor/persist/engineermode/`, `/dev/block/by-name/oplusreserve1`,
  `/dev/block/by-name/opporeserve1`. The binary has "invalid root path" guards,
  so callers cannot redirect it to arbitrary (e.g. modem EFS) paths.
- `saveEngineerData(category,data,size)` dispatches by `category` to either
  reserve-partition file writes or `oddi` RF-test calls.
- `get/setPartionWriteProtectState`: toggles HW write-protect on the *reserve
  block partitions* (oplusreserve1), not modem NV.
- `oddi_hal_wrapper_dci*`: RF calibration / factory test path into the modem via
  `liboddi_vendor.so` — Tx power, band, RFFE registers, modem crash. None of
  these write identifiers.
- libcrypto usage is for verifying RSA-signed config blobs
  (`getNVIDSignContent`/`saveNVIDSignData`/`secrecy.cfg`), not for NV write.

### Conclusion

The OPlus IMEI restore on stock does NOT go through IEngineer. It goes through
`IOplusTelephonyExt.staticNvRestore(...)` (a framework/system_server binder) →
qcril/RIL → modem QMI NV write. That is the **same** modem QMI path already
proven to reject NV-550 (qcrilhook OEM-hook rejected; HIDL nvWriteItem returned
RADIO_NOT_AVAILABLE; legacy DIAG 0x26/0x27 closed).

So every userspace mechanism reachable from LineageOS converges on the modem's
own NV write-protect/authentication gate, which rejects item 550. Deploying the
IEngineer service to Lineage would not help: it has no path to modem NV.

## Strategic implication

Userspace-from-Lineage is exhausted for NV-550:
- DIAG NV (0x26/0x27): closed
- qcrilhook OEM-hook NV write: modem rejects 550
- HIDL nvWriteItem: RADIO_NOT_AVAILABLE
- 6 vendor HIDL surfaces (qtiradio/deviceinfo/appradio/ims/data.factory/ims.factory): none write NV
- IEngineer factory HAL: no modem-NV path at all (file I/O + RF test only)

The remaining realistic path is to run the OEM's own signed IMEI-restore flow
under the full stock stack, i.e. boot stock OxygenOS and use EngineerMode. The
working hypothesis for why the OEM flow succeeds where our raw QMI failed is
that the modem only lifts its IMEI write-protect when booted with stock's
TZ/keymaster/FTM state (the OFP ships `init.oem_ftm.rc` = Factory Test Mode),
which Lineage's boot chain does not satisfy.

fastboot flashing of stock is blocked by the bootloader's "Critical Partitions"
lock (ABL/XBL/TZ/etc. refuse to flash even when unlocked). The remaining
mechanism to install stock is **EDL / firehose** (prog_firehose_ddr.elf +
rawprogram*.xml are present in the OFP; user has used this route before).

### Recommended next step

Plan D via EDL, selectively:
- Edit `rawprogram*.xml` to SKIP `modemst1`, `modemst2`, `persist`, `userdata`,
  `metadata` (preserve the device's own modem EFS + the user's data).
- Flash the rest of stock (boot chain, modem NON-HLOS, super) via firehose.
- Boot stock, run EngineerMode IMEI restore ("Sub board ID and IMEI"),
  verify `*#06#`.
- Re-flash LineageOS (OTA sideload preserves modem/modemst/persist per §6).

Caveat: success still depends on the device retaining an IMEI backup source
(sub-board record / factory QCN) for EngineerMode to restore from. That is
unknown until tried. If no backup source exists, even stock EngineerMode cannot
re-derive 868957060298983 and the path is OnePlus authorized service.
