# Session 73 — Static Findings (Task 3, Step A completed)

## Binary under analysis
`libqcrilNr.so.a12` (20,501,392 bytes, BuildID `5b3a4b6588e666d974690585bd379716`) — this is the 20 MB variant pulled from the target device (`/vendor/lib64/libqcrilNr.so`, Android 12 stock OOS build).

**Do not use `libqcrilNr.so` (18 MB) in this repo — its `.text` layout differs and the addresses cited in HANDOFF_session72 do not apply to it.** The 18 MB copy is LineageOS-side.

## Step A result: OEM NV WRITE msg_id

Disassembling `qcril_qmi_oem_write_nv_item` (thunk at `0x1052f28` → body at `0x5cff70`):

The only outbound call to `qmi_client_oem_send_sync@plt` (`0x105ca00`) is at **`0x5d0578`**, prepared with:

```
5d0564:   mov  w0, #5            ; msg_id = 5           <-- OEM NV WRITE opcode
5d0568:   add  x1, sp, #56       ; req buf on stack
5d056c:   mov  w2, #268          ; req_c_struct_len = 268 (0x10C)
5d0570:   add  x3, sp, #48       ; resp buf on stack
5d0574:   mov  w4, #8            ; resp_c_struct_len = 8
5d0578:   bl   qmi_client_oem_send_sync
```

Symmetric READ path (`qcril_qmi_oem_read_nv_item` body at `0x5d078c`, call site `0x5d09e8`):

```
5d09d4:   mov  w0, #4            ; msg_id = 4           <-- OEM NV READ opcode
5d09d8:   add  x1, sp, #48       ; req buf
5d09dc:   mov  w2, #8            ; req_c_struct_len = 8
5d09e0:   add  x3, sp, #56       ; resp buf
5d09e4:   mov  w4, #272          ; resp_c_struct_len = 272
5d09e8:   bl   qmi_client_oem_send_sync
```

| Path | msg_id | req C-struct sizeof | resp C-struct sizeof |
| --- | --- | --- | --- |
| OEM NV READ  | **0x04** | 8   | 272 |
| OEM NV WRITE | **0x05** | 268 | 8   |

## Correction to Session 72 assumption

Session 72 concluded the OEM NV path rides on the **DMS service (svc_id=2)** because the callee prologue used `w8 = 2` for QMI service ID.
**That was wrong.** Disassembling `qmi_client_oem_send_sync` (body at `0x5cee68`) shows it does **NOT** call `qmi_client_send_msg_sync@plt`. It dispatches through `ModemEndPoint::sendRawSync` with a `500 ms` timeout, and the modem endpoint it targets is `OemModemEndPoint` bound to `oem_qmi_idl_service_object_v01` — a **distinct QMI service, not DMS**. Registered strings for the abstraction:

```
[OemModemEndPoint]: constructor
OemModemEndPointModule::getServiceObject
oem_qmi_idl_service_object_v01
oem_get_service_object_internal_v01
```

Consequence: **sending msg_id=5 to QRTR (node=0, port=87) — the DMS port `qd.c` uses — will not reach the OEM handler.** (0, 87) is DMS only. We need the QRTR endpoint for the separate OEM service.

## Numeric OEM service_id — not yet pinned

The `oem_qmi_idl_service_object_v01` blob at VMA `0x1131010` (72 bytes) decodes as:

```
06 00 00 00  01 00 00 00  e4 00 00 00  05 b0 00 00  52 00 52 00  0c 00 00 00 ...
u32:  [ idl_ver=6 | major=1 | max_msg_id=228 | max_msg_size=45061? | ... ]
```

u32[2] appears to be `max_message_id`, not the service_id (verified by comparing to `embms_qmi_idl_service_object_v01` which shows `[6,1,2,2616,...]` — 2 as max_msg_id, not the real eMBMS service_id).

Service_id lives elsewhere in the IDL blob (Qualcomm's `qmi_idl_service_object` internal layout — pointer table offsets not straightforwardly decoded from static bytes without the header).

**Path forward: Step B (wildcard QRTR enumeration) will surface the OEM service's numeric `service_id` and `(node, port)` directly from the running modem, bypassing the need to reverse the IDL struct layout.**

## Next steps

1. Run Step B (wildcard `NEW_LOOKUP`, service=0 instance=0) — see `qp_wildcard.c` in this repo.
   Expected output: a table of every QMI service the modem exposes over QRTR, with `(service_id, instance, node, port)` for each. The OEM service will appear as a row whose `(node, port)` we can then target.
2. Once OEM endpoint is known, first do a **READ probe** with `msg_id=4`, `req_c_struct_len=8` payload for a **safe NV item** (e.g., NV-127 which is already known to be handled by the OEM READ dispatcher, per session 60 memo — expected to reply with `error=6 REQUEST_NOT_SUPPORTED` for the modem-firmware gate). This confirms our framing of the message before any write is attempted.
3. Only after (2) succeeds is a WRITE probe considered, and only after byte-level review. Per user instructions: `SET_IMEI is irreversible`. Never automate a write.

## Encryption concern (unchanged)

`DeCryptIMEI(uint32_t*, char*)` and `encrypt_imei_buf_ptr` (128 bytes at `.data 0x113b714`) still suggest that on-wire IMEI bytes may be XOR/scrambled between userspace and modem. This applies mostly to `dms_set_device_serial_numbers`-style paths. Whether the OEM NV-WRITE (msg_id=5) path expects plaintext or encrypted IMEI is still unknown — the encryption logic is inside `qcril_qmi_oem_request_imei` (the high-level IMEI request wrapper), which sits **above** `qcril_qmi_oem_write_nv_item`. If we invoke `qcril_qmi_oem_write_nv_item` directly at the QMI layer, we are below the encryption wrapper — meaning we need to send plaintext NV bytes and any modem-side plaintext-vs-crypto expectation is unknown until tested.

Do the READ probe first — it will tell us the modem's response format, which will indicate whether the data field is plaintext or scrambled on the wire.
