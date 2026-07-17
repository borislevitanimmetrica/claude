/*
 * ImeiProvisioning - one-shot OEM-hook NV write for IMEI at radio bring-up.
 *
 * Why this exists: on CPH2459 (gunnar) the modem rejects legacy DIAG NV
 * verbs (cmd 0x26 NV_READ_F and 0x27 NV_WRITE_F both return BAD_CMD).
 * The QMI OEM-hook path (request id 524290 = QCRILHOOK_NV_WRITE) is
 * what OPlus's own service tools use post-factory and is reachable
 * from the radio uid via IRadio.sendOemRilRequestRaw().
 *
 * Call site: anywhere in the AIDL<->HIDL@1.5 bridge initialization
 * AFTER the HIDL IRadio proxy is bound but BEFORE the bridge propagates
 * RADIO_ON to the AIDL layer.  The reason for that ordering is that
 * the modem reads NV item 550 (NV_UE_IMEI_I) into the EquipmentIdentity IE
 * during the LTE Attach Request that fires shortly after RADIO_ON.
 */

package com.oneplus.gunnar.radio;

import android.hardware.radio.V1_5.IRadio;
import android.os.RemoteException;
import android.os.SystemProperties;
import android.util.Log;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;

public final class ImeiProvisioning {

    private static final String TAG                = "ImeiProvisioning";
    private static final String PROP_IMEI          = "persist.vendor.radio.imei";
    private static final int    QCRILHOOK_NV_WRITE = 524290;
    private static final int    NV_UE_IMEI_I       = 550;
    private static final int    NV_DATA_LEN        = 128;

    private ImeiProvisioning() { /* static */ }

    /**
     * Provision NV item 550 from persist.vendor.radio.imei via OEM-hook NV write.
     * Returns true if a request was dispatched, false if skipped (no valid IMEI).
     * Throws if the HIDL call itself raises RemoteException - caller decides
     * whether to abort radio bring-up or proceed (recommended: proceed and log).
     */
    public static boolean provisionAtBoot(IRadio hidlRadio, int serial)
            throws RemoteException {
        if (hidlRadio == null) {
            Log.w(TAG, "no HIDL IRadio proxy; skipping");
            return false;
        }
        String imei = SystemProperties.get(PROP_IMEI, "");
        if (imei == null || imei.length() != 15 || !isLuhnValid(imei)) {
            Log.w(TAG, "no valid IMEI in " + PROP_IMEI + " (got '" + imei + "'); skipping");
            return false;
        }

        byte[] payload = buildOemHookPayload(imei);
        ArrayList<Byte> data = new ArrayList<>(payload.length);
        for (byte b : payload) data.add(b);

        Log.i(TAG, "dispatching OEM-hook NV write: serial=" + serial
                  + " hookId=" + QCRILHOOK_NV_WRITE
                  + " item=" + NV_UE_IMEI_I
                  + " imei=" + imei);
        hidlRadio.sendOemRilRequestRaw(serial, data);
        return true;
    }

    /** Build the OEM-hook NV write payload:
     *  [u32 hookId LE][u32 itemId LE][u32 dataLen LE][u8[128] BCD-then-zero]. */
    static byte[] buildOemHookPayload(String imei) {
        ByteBuffer buf = ByteBuffer.allocate(12 + NV_DATA_LEN).order(ByteOrder.LITTLE_ENDIAN);
        buf.putInt(QCRILHOOK_NV_WRITE);
        buf.putInt(NV_UE_IMEI_I);
        buf.putInt(NV_DATA_LEN);
        byte[] bcd = imeiStringToNvBcd(imei);   // 9 bytes
        buf.put(bcd);
        // remaining (128 - 9) bytes are already zero from allocate()
        return buf.array();
    }

    /** Mirror of imei_to_nv.py.  Layout:
     *    byte 0     = 0x08 (length: 8 BCD bytes follow)
     *    byte 1     = (digit1 << 4) | 0xA  (TypeOfId nibble = 0xA for IMEI)
     *    bytes 2..8 = digits 2..15 packed low-nibble-first.
     */
    static byte[] imeiStringToNvBcd(String imei) {
        if (imei.length() != 15)
            throw new IllegalArgumentException("IMEI must be 15 digits, got " + imei.length());
        int[] n = new int[16];
        n[0] = 0xA;                                            // type-of-id
        for (int i = 0; i < 15; i++) n[1 + i] = imei.charAt(i) - '0';
        byte[] out = new byte[9];
        out[0] = 0x08;                                         // length byte
        for (int i = 0; i < 8; i++)
            out[1 + i] = (byte)((n[2 * i + 1] << 4) | (n[2 * i] & 0xf));
        return out;
    }

    /** Standard Luhn-mod-10 over a digit string. */
    static boolean isLuhnValid(String s) {
        int sum = 0; boolean dbl = false;
        for (int i = s.length() - 1; i >= 0; i--) {
            int d = s.charAt(i) - '0';
            if (d < 0 || d > 9) return false;
            if (dbl) { d *= 2; if (d > 9) d -= 9; }
            sum += d;
            dbl = !dbl;
        }
        return sum % 10 == 0;
    }
}
