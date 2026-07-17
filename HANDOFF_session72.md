# Session 72 Handoff Summary — CPH2459 IMEI Restoration

## TASK 1: Chimera VIP + firehose read/write attempts (EDL path)

    STATUS: abandoned
    USER QUERIES: early session — 1 through ~30
    DETAILS: Extensive attempts to make Chimera V2.1 firehose VIP handshake accept arbitrary <read> commands. Confirmed: Sahara upload works with stty raw fix; VIP handshake succeeds when Sign.bin is sent via --signeddigests after verify EnableVip=1 (rasheed999's order — which our vip_handshake.sh had been missing). Discovered --special_rw_mode=oplus_gptmain/oplus_gptbackup requirement from salokrwhite/EdlService.cs analysis. All arbitrary <read> commands still returned TARGET SAID: 'ERROR: Failed to run the last command -1' from Chimera regardless of rwmode. Conclusion: Chimera's signed Digest.elf is a pre-baked script (54 hashes, slot-counter-checked), not a whitelist — arbitrary reads will never match. Chimera V2.1 binary has only programcust and writever as OEM verbs, no writeimei. Modemst is encrypted at rest with fused key so restoring it wouldn't help anyway. User confirmed babyskylar's imei-fix.md is aspirational, not a working documented procedure.
    FILEPATHS:
        /home/boris/phone/telephony_CPH2459/OplusEDLTool/z4g7298d6b-OP_Flash_Tool/extracted/OP_Flash_Tool_1.3/
        /home/boris/phone/telephony_CPH2459/OplusEDLTool/salokrwhite OplusEDLTool/OplusEdlTool-2.0_sources/Services/EdlService.cs
        /tmp/mv2.sh

## TASK 2: QMI DMS_GET_IDS probe over QRTR (Session 60 Path A, read side)

    STATUS: done
    USER QUERIES: middle session — ~30-60
    DETAILS: Fully proven end-to-end. Wrote aarch64 C client /tmp/qd.c (39 lines, sha256 2eab6832d63ad3bdbb9b30dc358cdad796113688459ef9c12b5b9dd60e8568de) that opens AF_QIPCRTR socket, sends DMS_GET_IDS (msg 0x0025) directly to (node=0, port=87). Response decoded cleanly:
        QMI header: 02 01 00 25 00 21 00 (flags=response, txn=1, msg_id=0x0025, len=33)
        TLV 0x02 Result: status=0 (SUCCESS), error=0
        TLV 0x10 ESN: "0"
        TLV 0x12 MEID: "00000000000000" (14 zeros)
        TLV 0x13 IMEISV: "1A"
        TLV 0x11 IMEI: absent — modem confirms no IMEI stored (matches AT+CGSN's +CME ERROR: memory failure and ATI's blank IMEI)
    Key discoveries during this work:
        QRTR command IDs on this kernel use newer numbering: NEW_LOOKUP=10 (not 9), NEW_SERVER=4 (not 2).
        Correct destination is sq_node=1, sq_port=0xfffffffe (AP-local qrtr-ns), NOT sq_node=0.
        DMS_GET_IDS response arrived during the NEW_LOOKUP poll loop and was misprinted as a QRTR ctrl packet — resolved by writing qd.c that bypasses lookup and talks directly to the known (0, 87) address.
    FILEPATHS:
        /tmp/qd.c
        /data/local/tmp/qd
        /home/boris/phone/telephony_CPH2459/session61/

## TASK 3: Find OEM DMS_SET_IMEI-equivalent message ID / path (write side of Path A)

    STATUS: in-progress

    USER QUERIES: last ~15 (from strings search onward)

    DETAILS: This is the actively-in-progress task.

    From on-device strings search:
        Standard dms_set_imei_req_v01 symbols are absent (either stripped or write path uses different naming)
        /vendor/lib64/libqcrilNr.so (20 MB, pulled to Mint) is the RIL implementation with heaviest IMEI mentions
        /vendor/bin/factory uses proprietary AT command AT^SECRECY_IMEI for reads
        No writeimei / set_imei verb symbols anywhere

    Symbols identified in libqcrilNr.so:
        DeCryptIMEI(uint32_t*, char*) — IMEI is encrypted on the QMI wire between RIL and modem
        encrypt_imei_buf_ptr — encryption buffer
        qcril_qmi_oem_write_nv_item at 0x1052f28 (thunk → real code at 0x5cff70)
        qcril_qmi_oem_read_nv_item at 0x1052f2c (thunk → real code at 0x5d078c)
        qcril_qmi_oem_op_read_nv_item(uint32_t nv_item, uint8_t, oem_common_nv_data*) at 0x1052f30 (thunk → real code at 0x5fc504)
        qcril_qmi_oem_request_imei() at 0x10597c8 (thunk → real code at 0x5fab9c, 968 bytes)
        qcril_qmi_oem_init at 0x5c81e0
        qcril_qmi_oem_op_init at 0x5faaf8
        Source paths referenced: vendor/oplus/qcom_proprietary/telephony/qcril-hal/qcril_qmi/oemril_decrypt.cc
        Only 3 QMI_OEM_* message names: ECCLIST_INITIAL_IND, LARGE_DATA_KEY_LOG_MSG_IND_V01, and QMI_OEM_FACTORY_MODE_NV_PROCESSOR_MSG_IND_V01 (indication only — its _REQ_V01 counterpart is what we need)

    HIDL interface discovered — IQtiOemHook:
        Library: /vendor/lib64/vendor.qti.hardware.radio.qcrilhook@1.0.so (218 KB, at bins/qcrilhook.so)
        Interface: vendor::qti::hardware::radio::qcrilhook::V1_0::IQtiOemHook::oemHookRawRequest(int, hidl_vec<uint8_t>)
        Companion: IQtiOemHookResponse::oemHookRawResponse(int, RadioError, hidl_vec<uint8_t>)
        This is a binderized HIDL service that accepts raw byte payload and forwards through qcrilNrd to modem QMI. Alternative path — bypasses need to know QRTR service IDs and encryption if we can construct the right byte format.

    Disassembly done, mostly prologue (logging setup) only:
        Both qcril_qmi_oem_request_imei and qcril_qmi_oem_op_read_nv_item allocate large stack frames (0x230 and 0x190 bytes) — building QMI request/response on stack
        op_read_nv_item specifically allocates 8-byte request area + 272-byte response area (matches Qualcomm's dms_nv_read_req_msg / dms_nv_read_resp_msg layout)
        Both set w8 = 2 early on and store it — value "2" is Qualcomm QMI service ID for DMS. So NV read/write goes through standard DMS service, NOT a separate OEM service. The "OEM" in function names refers to Qualcomm's proprietary NV-item extension messages, still on DMS.
        Actual qmi_client_send_msg_sync call sites (with immediate msg_ids) are further in the functions — not yet examined.

    Last message to user proposed two parallel steps (Steps A and B):
        Step A: Disassemble full qcril_qmi_oem_write_nv_item real body at 0x5cff70 with 1600-byte window (--start-address=0x5cff70 --stop-address=0x5d05b0). Grep for mov w1, #<msg_id> immediates near bl qmi_client_send_msg_sync@plt calls.
        Step B: Modify /tmp/qp.c (the NEW_LOOKUP probe) to use service=0 (wildcard) instead of service=2. Should enumerate ALL QRTR services registered — looking for anything separate from DMS that could be an OEM_HOOK service, particularly around svc=210 or similar.

    User has not yet run Step A or Step B. That's where the next agent picks up.

    NEXT STEPS:
        Execute Step A (disassembly of 0x5cff70 with wider window) and paste output
        Execute Step B (sed-modify /tmp/qp.c for wildcard NEW_LOOKUP, recompile, push, run) and paste output
        Based on Step A: identify the specific DMS msg_id used for OEM NV write. This message_id + service=2 (DMS at node=0 port=87) + payload with nv_item=550 (IMEI) + BCD-encoded IMEI value would be the SET path
        Based on Step B: confirm whether OEM ops truly live on DMS or if there's a separate OEM service we missed
        If Step A reveals the msg_id, next work is: write a /tmp/qw.c client that constructs the DMS OEM NV write message with:
            Message ID = discovered value
            TLV containing nv_item=550 (RF_NV_IMEI_0)
            Data = 9-byte BCD from Session 60 memo: 08 8A 86 59 07 06 92 98 38
            Send to (node=0, port=87)
        Handle the IMEI encryption concern (DeCryptIMEI symbol in libqcrilNr.so suggests wire encryption). Possible workarounds:
            The write path may use plaintext (only read decrypts what modem sends)
            OR we need to invoke via the HIDL IQtiOemHook::oemHookRawRequest where qcrilNrd handles encryption
        If Step A returns nothing usable, pivot to the HIDL approach — write a small aarch64 client that uses IServiceManager to get the IQtiOemHook HIDL service and calls oemHookRawRequest with a constructed byte payload.
        Every write attempt requires explicit go/no-go with byte-level review before firing — SET_IMEI is irreversible.

    FILEPATHS:
        /home/boris/phone/telephony_CPH2459/session61/bins/libqcrilNr.so (20 MB, pulled)
        /home/boris/phone/telephony_CPH2459/session61/bins/factory (355 KB, pulled)
        /home/boris/phone/telephony_CPH2459/session61/bins/qcrilhook.so (218 KB, pulled)
        /home/boris/phone/telephony_CPH2459/session61/bins/rmt_storage (55 KB, pulled)
        /home/boris/phone/telephony_CPH2459/session61/qcril_syms_imei.txt
        /home/boris/phone/telephony_CPH2459/session61/dis_request_imei_real.s — 140 lines, prologue only
        /home/boris/phone/telephony_CPH2459/session61/dis_op_read_nv_real.s — 140 lines, prologue only
        /home/boris/phone/telephony_CPH2459/session61/dis_oem_op_init.s
        /home/boris/phone/telephony_CPH2459/session61/dis_client_init.s
        /tmp/qp.c — NEW_LOOKUP probe (needs wildcard modification for Step B)
        /tmp/qd.c — direct DMS_GET_IDS probe (working, sha256 2eab6832d63ad3bdbb9b30dc358cdad796113688459ef9c12b5b9dd60e8568de)

## USER CORRECTIONS AND INSTRUCTIONS

    No base64 for script delivery. Use heredocs with rare delimiters, or in-place sed edits, or split code into small (<40-line) chunks with wc -l + tail -3 verification after each. For anything under ~30 lines, one heredoc works.
    sudo -v before any nohup'd/detached script that uses sudo. Pattern: sudo -v && nohup /path/script.sh > /path/log 2>&1 & tail -f /path/log.
    Don't use $'\x08...' ANSI-C quoting — Android's sh (mksh/ash) doesn't support it. Use printf '\010\212...' > /tmp/pat && grep -f /tmp/pat ... instead.
    Quote parentheses in echoes. echo === foo (bar) baz === breaks bash parsing. Use echo '=== foo (bar) baz ==='.
    SPC is vestigial CDMA on this LTE-only device. User rejected speculation about SPC being needed for DMS_SET_IMEI.
    Don't speculate. If no citation from user's probes, libqmi source, kernel source, or documented same-era OnePlus behavior, don't say it.
    User's SSH pipeline mangles long pastes. Pastes over ~60 lines can silently truncate. Small chunks with checksums only reliable approach.
    babyskylar's repo is not a working procedure. imei-fix.md is aspirational.
    su -c "..." works on OnePlus OOS 12 with Magisk root.
    Never write any IMEI other than 868957060298983 (target). BCD 08 8A 86 59 07 06 92 98 38.
    Twin phone fcbc948b MUST NOT be harmed.
    Device state: rooted CPH2459 (9385711f) on OOS 12 (Android 12, kernel 5.4.254). QRTR: qrtr-ns pid 1095, qmipriod pid 12798, qcrilNrd pid 1813, [modem] kthread live. Modem firmware MPSS.HI.4.3.1.c5-00105-MANNAR_GEN_PACK-1.9283.174 (April 2024).
    Phone should be in Android for Path A work.
