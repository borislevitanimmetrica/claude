# Session 43 — modem state after 2026-05-30 modemst restore

Log: modem_after_restore.log (captured after restoring the 2026-05-30 modemst1/2
onto the device and rebooting).

## Headline: the modem is UP and healthy. The blocker is isolated to the null IMEI.

### Evidence the modem subsystem booted and is serving
- dmesg (subsys-pil-tz framework; this kernel does NOT use /sys/class/remoteproc,
  so that probe returned nothing — not a failure, wrong path):
  - `coresight-remote-etm soc:modem_etm0/1: Connection established between QMI
    handle and N service` -> modem serving QMI.
  - `rmt_storage: Received req_size: 2621440` -> modem accessing its EFS via
    rmt_storage (remote storage to modemst/persist) successfully.
  - `Sending QMI_IPA_INIT_MODEM_DRIVER_REQ_V01` + `response received` -> IPA
    modem data-path init handshake OK.
  - `service-notifier: ... msm/modem/wlan_pd, state: 0x1fffffff` -> modem
    protection domains up.
- RIL: many RILJ commands succeed (SEND_DEVICE_STATE, GSM_SET_BROADCAST_CONFIG,
  GSM_BROADCAST_ACTIVATION). `Radio Hal Version = 1.5`. RIL<->modem healthy.
- SIM/UICC: `EmergencyNumberTracker ... src=sim` for 112/911 -> the SIM's
  emergency call codes were READ from the card => UICC is powered and accessible.

### What is still wrong
- IMEI: still effectively null (service state below). `service call iphonesubinfo 1`
  returned a Parcel exception (-4) — that's a shell permission artifact, NOT a
  reliable IMEI read; authoritative check remains *#06#.
- Service: `mServiceState=OUT_OF_SERVICE (voice+data)`, `mNetworkRegistrationInfos
  =[]`, `mSignalStrength=null`, `PhoneSwitcher: No active subscriptions`.
  Consistent with: modem up, RIL talking, SIM read, but no valid IMEI => cannot
  register on network.

### Interpretation / corrections
- User hypothesis (modem bring-up fails BEFORE the IMEI stage) is NOT borne out:
  bring-up completes, RIL talks, SIM is read. The failure is isolated to the
  missing IMEI in the modem's active NV, which blocks registration.
- The 2026-05-30 modemst restore did NOT bring back the IMEI => that backup is
  POST-IMEI-wipe. So no on-device modemst backup contains the IMEI; the
  modemst-restore path is now confirmed dead. (The IMEI was wiped on/before
  2026-05-30, not later as hoped.)
- Possible side benefit: SIM is being read again (emergency numbers src=sim),
  where the user reported "no SIM for days" before. The older modemst may have
  restored healthier modem/SIM config. Recommend KEEPING the restored modemst
  (modem is healthy now); live backup retained for rollback if needed.

## Next step: write the known IMEI into the modem NV via qfenix DIAG
Modem is up and QMI-responsive, so the DIAG channel should respond.
- Authoritative read first: `*#06#`.
- Enable diag USB; `qfenix list`.
- Probe: `qfenix nvread 550` (legacy NV; may be closed per handoff) and
  `qfenix efsls /nv/item_files/modem/mmode` + `efsstat .../ue_imei_i` (EFS2 —
  the untested path).
- Write (9 bytes 08 8a 86 59 07 06 92 98 38, file imei_nv550.bin):
  `qfenix nvwrite 550 088a86590706929838` and/or
  `qfenix efspush imei_nv550.bin /nv/item_files/modem/mmode/ue_imei_i`
  (also nv/550). Reboot, check *#06#.
- VIP (firehose secure boot) does NOT affect DIAG — different channel — so this
  path is unobstructed by the earlier "signature failed with 3".
