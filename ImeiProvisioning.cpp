/*
 * Copyright (C) 2026
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * See ImeiProvisioning.h for context.
 */
#include <libradiocompat/ImeiProvisioning.h>

#include <android-base/logging.h>
#include <android-base/properties.h>
#include <hidl/HidlSupport.h>
#include <android/hardware/radio/1.0/types.h>

#include <cstdint>
#include <string>
#include <vector>

namespace android::hardware::radio::compat::imei {

namespace {

constexpr char    PROP_IMEI[]        = "persist.vendor.radio.imei";
constexpr int32_t QCRILHOOK_NV_WRITE = 524290;
constexpr int32_t NV_UE_IMEI_I       = 550;
constexpr size_t  NV_DATA_LEN        = 128;

bool isLuhnValid(const std::string& s) {
    int sum = 0;
    bool dbl = false;
    for (auto it = s.rbegin(); it != s.rend(); ++it) {
        if (*it < '0' || *it > '9') return false;
        int d = *it - '0';
        if (dbl) { d *= 2; if (d > 9) d -= 9; }
        sum += d;
        dbl = !dbl;
    }
    return (sum % 10) == 0;
}

std::vector<uint8_t> imeiStringToNvBcd(const std::string& imei) {
    if (imei.size() != 15) return {};
    int nibbles[16];
    nibbles[0] = 0xA;
    for (int i = 0; i < 15; ++i) nibbles[1 + i] = imei[i] - '0';
    std::vector<uint8_t> out(9);
    out[0] = 0x08;
    for (int i = 0; i < 8; ++i) {
        out[1 + i] = static_cast<uint8_t>(
            (nibbles[2 * i + 1] << 4) | (nibbles[2 * i] & 0xf));
    }
    return out;
}

inline void putU32LE(std::vector<uint8_t>& v, size_t off, uint32_t val) {
    v[off + 0] = static_cast<uint8_t>(val >>  0);
    v[off + 1] = static_cast<uint8_t>(val >>  8);
    v[off + 2] = static_cast<uint8_t>(val >> 16);
    v[off + 3] = static_cast<uint8_t>(val >> 24);
}

std::vector<uint8_t> buildOemHookPayload(const std::string& imei) {
    auto bcd = imeiStringToNvBcd(imei);
    if (bcd.size() != 9) return {};
    std::vector<uint8_t> p(12 + NV_DATA_LEN, 0);
    putU32LE(p,  0, QCRILHOOK_NV_WRITE);
    putU32LE(p,  4, NV_UE_IMEI_I);
    putU32LE(p,  8, static_cast<uint32_t>(NV_DATA_LEN));
    for (size_t i = 0; i < bcd.size(); ++i) p[12 + i] = bcd[i];
    return p;
}

}  // anonymous namespace

bool provisionImeiAtBoot(const sp<V1_5::IRadio>& hidlRadio, int32_t serial) {
    if (hidlRadio == nullptr) {
        LOG(WARNING) << "ImeiProvisioning: no HIDL IRadio proxy; skipping";
        return false;
    }
    const std::string imei = ::android::base::GetProperty(PROP_IMEI, "");
    if (imei.size() != 15 || !isLuhnValid(imei)) {
        LOG(WARNING) << "ImeiProvisioning: invalid/missing IMEI in "
                     << PROP_IMEI << " (got '" << imei << "'); skipping";
        return false;
    }
    auto payload = buildOemHookPayload(imei);
    if (payload.empty()) {
        LOG(ERROR) << "ImeiProvisioning: payload construction failed";
        return false;
    }
    LOG(INFO) << "ImeiProvisioning: dispatching OEM-hook NV write"
              << " serial=" << serial
              << " hookId=" << QCRILHOOK_NV_WRITE
              << " item=" << NV_UE_IMEI_I
              << " imei=" << imei;
    hidl_vec<uint8_t> data;
    data.setToExternal(payload.data(), payload.size());
    // Remedy 1: sendOemRilRequestRaw was removed from V1_0/V1_5 IRadio.hal
    // in this AOSP/LineageOS-trunk branch.  Fall back to nvWriteItem -
    // CDMA-named but its underlying QMI dispatch is generic; modems often
    // accept arbitrary NV item IDs cast into the NvItem enum.
    std::string valueStr;
    valueStr.reserve(payload.size() * 2);
    static const char kHex[] = "0123456789abcdef";
    for (uint8_t b : payload) {
        valueStr.push_back(kHex[b >> 4]);
        valueStr.push_back(kHex[b & 0xf]);
    }
    ::android::hardware::radio::V1_0::NvWriteItem item;
    item.itemId = static_cast<::android::hardware::radio::V1_0::NvItem>(NV_UE_IMEI_I);
    item.value  = valueStr;
    auto status = hidlRadio->nvWriteItem(serial, item);
    if (!status.isOk()) {
        LOG(ERROR) << "ImeiProvisioning: HIDL transport failure: "
                   << status.description();
        return false;
    }
    LOG(INFO) << "ImeiProvisioning: HIDL request dispatched (oneway). "
                 "Response will arrive via "
                 "IRadioResponse::sendOemRilRequestRawResponse with serial="
              << serial;
    return true;
}

}  // namespace android::hardware::radio::compat::imei
