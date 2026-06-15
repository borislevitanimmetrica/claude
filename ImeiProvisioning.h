/*
 * Copyright (C) 2026
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * One-shot OEM-hook NV write to seed modem NV item 550 (NV_UE_IMEI_I)
 * at radio bring-up.  Used because the legacy DIAG NV API (cmd 0x26
 * NV_READ_F and 0x27 NV_WRITE_F) is closed on this firmware - both
 * verbs return BAD_CMD 0x13.  The QMI OEM-hook path is OPlus's
 * supported channel for service-tool-style NV operations and is
 * reachable via IRadio::sendOemRilRequestRaw.
 *
 * Caller responsibilities:
 *   - Invoke once, AFTER the HIDL IRadio's setResponseFunctions has
 *     completed (so sendOemRilRequestRawResponse can be delivered to
 *     the existing IRadioResponse handler), and BEFORE forwarding
 *     RADIO_ON to the AIDL framework (so NV item 550 is populated
 *     before the modem reads it during the ATTACH REQUEST).
 *   - Not safe to call concurrently from multiple threads on the
 *     same proxy; current call site in CallbackManager is single
 *     -threaded (delayedSetterThread).
 */
#pragma once

#include <android/hardware/radio/1.5/IRadio.h>
#include <utils/StrongPointer.h>
#include <cstdint>

namespace android::hardware::radio::compat::imei {

/**
 * @return true if a HIDL request was dispatched (does NOT mean the
 *         modem accepted the write - that result arrives async on
 *         IRadioResponse::sendOemRilRequestRawResponse with the
 *         same serial); false if skipped because the property
 *         persist.vendor.radio.imei is missing or invalid.
 */
bool provisionImeiAtBoot(const ::android::sp<V1_5::IRadio>& hidlRadio,
                         int32_t serial);

}  // namespace android::hardware::radio::compat::imei
