package izm.android.properties.V1_0;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Mock of the vendor HAL used only by the host test suite.
 *
 * The real tool locates this class with Class.forName("...IProperties"), so
 * putting it on the classpath lets the unmodified production classes run on a
 * desktop JVM. It records call counts and can inject faults.
 */
public class IProperties {

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

    public static final int[] LENS = {256, 256, 256, 256, 4, 4, 4, 4};

    private static final String[] REF = {
            "kVolTblIcx1298CewHpSe",
            "kVolTblIcx1298CewHpSe",
            "kVolTblIcx1298CewHpBtl",
            "kVolTblIcx1298CewHpBtl"
    };

    private static final String[] TGT = {
            "kVolTblIcx1298HpSeGainHigh",
            "kVolTblIcx1298HpSeGainLow",
            "kVolTblIcx1298HpBtlGainHigh",
            "kVolTblIcx1298HpBtlGainLow"
    };

    public static final Map<String, byte[]> STORE =
            new LinkedHashMap<String, byte[]>();

    public static final Set<String> FAIL_GET = new HashSet<String>();
    public static final Set<String> FAIL_SET = new HashSet<String>();
    /** set() accepted but silently ignored - makes read-back verification fail. */
    public static final Set<String> IGNORE_SET = new HashSet<String>();

    public static boolean HAL_UNAVAILABLE = false;

    public static int getCalls = 0;
    public static int setCalls = 0;
    /** Successful, effective writes only. */
    public static int writes = 0;

    static {
        resetFactory();
    }

    public static void resetCounters() {
        getCalls = 0;
        setCalls = 0;
        writes = 0;
        FAIL_GET.clear();
        FAIL_SET.clear();
        IGNORE_SET.clear();
        HAL_UNAVAILABLE = false;
    }

    public static void resetFactory() {
        STORE.clear();
        for (int i = 0; i < 4; i++) {
            STORE.put(KEYS[i], pad(REF[i], LENS[i]));
        }
        STORE.put(KEYS[4], le(0));
        STORE.put(KEYS[5], le(0));
        STORE.put(KEYS[6], le(0));
        STORE.put(KEYS[7], le(1));
        resetCounters();
    }

    public static void resetTarget() {
        STORE.clear();
        for (int i = 0; i < 4; i++) {
            STORE.put(KEYS[i], pad(TGT[i], LENS[i]));
        }
        STORE.put(KEYS[4], le(1));
        STORE.put(KEYS[5], le(1));
        STORE.put(KEYS[6], le(1));
        STORE.put(KEYS[7], le(0));
        resetCounters();
    }

    public static void putRaw(String key, byte[] value) {
        STORE.put(key, value);
    }

    public static byte[] getRaw(String key) {
        return STORE.get(key);
    }

    public static byte[] pad(String s, int len) {
        byte[] out = new byte[len];
        for (int i = 0; i < s.length() && i < len; i++) out[i] = (byte) s.charAt(i);
        return out;
    }

    public static byte[] le(int v) {
        return new byte[]{(byte) v, (byte) (v >> 8), (byte) (v >> 16), (byte) (v >> 24)};
    }

    public static Object getService(String name) {
        if (HAL_UNAVAILABLE) return null;
        return new IProperties();
    }

    public ArrayList get(String key, ArrayList buf) {
        getCalls++;
        if (FAIL_GET.contains(key)) throw new RuntimeException("inject: get failed");
        byte[] v = STORE.get(key);
        if (v == null) return null;
        ArrayList<Integer> out = new ArrayList<Integer>();
        for (int i = 0; i < v.length; i++) out.add(Integer.valueOf(v[i] & 0xff));
        return out;
    }

    public void set(String key, ArrayList value) {
        setCalls++;
        if (FAIL_SET.contains(key)) throw new RuntimeException("inject: set failed");
        if (IGNORE_SET.contains(key)) return;
        byte[] v = new byte[value.size()];
        for (int i = 0; i < v.length; i++) {
            v[i] = (byte) (((Number) value.get(i)).intValue() & 0xff);
        }
        STORE.put(key, v);
        writes++;
    }
}
