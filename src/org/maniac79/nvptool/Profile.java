package org.maniac79.nvptool;

import java.security.MessageDigest;

/**
 * Single source of truth for the supported profile, the field schema and the
 * guard checks. Every entry point (Read, Apply, RestoreField, RestoreReference)
 * calls the same {@link #checkEnvironment()} so they fail closed identically.
 *
 * Supported profile - the only one this tool has ever been run against:
 *   model        NW-WM1AM2
 *   android      11
 *   firmware     1.09.00
 *   fingerprint  SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys
 *
 * Unknown firmware is rejected rather than assumed compatible.
 */
public final class Profile {

    public static final String TOOL_VERSION = "1.1.0";
    public static final String SCHEMA = "1";

    public static final String EXPECTED_MODEL = "NW-WM1AM2";
    public static final String EXPECTED_FINGERPRINT =
            "SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys";
    public static final String HAL_APK =
            "/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk";

    public static final int COUNT = 8;

    /** Field order is part of the wire format: never reorder. */
    public static final String[] KEYS = {
            "ro.vendor.alc.voltbl_id.se_high",
            "ro.vendor.alc.voltbl_id.se_low",
            "ro.vendor.alc.voltbl_id.btl_high",
            "ro.vendor.alc.voltbl_id.btl_low",
            "ro.app.highgain.mode",
            "ro.volume.gain.se",
            "ro.volume.gain.btl",
            "ro.safe_volume.enabled"
    };

    /** "S" = fixed-length ASCII string field, "I" = 4-byte little-endian int. */
    public static final char[] KINDS =
            {'S', 'S', 'S', 'S', 'I', 'I', 'I', 'I'};

    /** Observed field lengths on the tested profile. Anything else is rejected. */
    public static final int[] LENS = {256, 256, 256, 256, 4, 4, 4, 4};

    /** Target state ("the change"). Indexes 4-7 are ints. */
    public static final String[] TARGET_STR = {
            "kVolTblIcx1298HpSeGainHigh",
            "kVolTblIcx1298HpSeGainLow",
            "kVolTblIcx1298HpBtlGainHigh",
            "kVolTblIcx1298HpBtlGainLow",
            null, null, null, null
    };
    public static final int[] TARGET_INT = {0, 0, 0, 0, 1, 1, 1, 0};

    /**
     * Reference profile observed on ONE EU ("CEW") unit before modification.
     * This is a reference, NOT a universal factory backup - see RestoreReference.
     */
    public static final String[] REF_STR = {
            "kVolTblIcx1298CewHpSe",
            "kVolTblIcx1298CewHpSe",
            "kVolTblIcx1298CewHpBtl",
            "kVolTblIcx1298CewHpBtl",
            null, null, null, null
    };
    public static final int[] REF_INT = {0, 0, 0, 0, 0, 0, 0, 1};

    private Profile() { }

    /** @return null when the environment is supported, otherwise a reason slug. */
    public static String checkEnvironment() {
        String model = android.os.Build.MODEL;
        String fp = android.os.Build.FINGERPRINT;
        if (model == null || !EXPECTED_MODEL.equals(model)) {
            return "unsupported_model";
        }
        if (fp == null || !EXPECTED_FINGERPRINT.equals(fp)) {
            return "unsupported_firmware";
        }
        return null;
    }

    public static byte[] target(int i) {
        return KINDS[i] == 'S'
                ? asciiPadded(TARGET_STR[i], LENS[i])
                : le32(TARGET_INT[i]);
    }

    public static byte[] reference(int i) {
        return KINDS[i] == 'S'
                ? asciiPadded(REF_STR[i], LENS[i])
                : le32(REF_INT[i]);
    }

    /** ASCII bytes of s followed by zero padding to len. */
    public static byte[] asciiPadded(String s, int len) {
        byte[] out = new byte[len];
        int n = Math.min(s.length(), len);
        for (int i = 0; i < n; i++) {
            out[i] = (byte) s.charAt(i);
        }
        return out;
    }

    public static byte[] le32(int v) {
        return new byte[]{
                (byte) (v & 0xff),
                (byte) ((v >> 8) & 0xff),
                (byte) ((v >> 16) & 0xff),
                (byte) ((v >> 24) & 0xff)
        };
    }

    public static int int32(byte[] b) {
        return (b[0] & 0xff) | ((b[1] & 0xff) << 8)
                | ((b[2] & 0xff) << 16) | ((b[3] & 0xff) << 24);
    }

    public static boolean same(byte[] a, byte[] b) {
        if (a == null || b == null || a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    public static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (int i = 0; i < b.length; i++) {
            sb.append(Character.forDigit((b[i] >> 4) & 0xf, 16));
            sb.append(Character.forDigit(b[i] & 0xf, 16));
        }
        return sb.toString();
    }

    /** Canonical digest over all eight raw values; used to prove host and device agree. */
    public static String digest(byte[][] values) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < values.length; i++) {
            sb.append(i).append('=').append(values[i] == null ? "-" : hex(values[i])).append('\n');
        }
        return sha256(sb.toString());
    }

    public static String sha256(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] d = md.digest(s.getBytes("UTF-8"));
            return hex(d);
        } catch (Exception e) {
            return "unavailable";
        }
    }
}
