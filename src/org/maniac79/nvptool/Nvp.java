package org.maniac79.nvptool;

import java.lang.reflect.Method;
import java.util.ArrayList;

/**
 * Minimal client for the Sony "izm.android.properties" HAL.
 *
 * The HAL exposes:
 *     IProperties.get(String key, ArrayList buf)  -> ArrayList
 *     IProperties.set(String key, ArrayList value)
 * and set() ends up in nvp_write() on /dev/icx_nvp/NNN, i.e. factory NVRAM.
 * See docs/FINDINGS.md for how this was established.
 *
 * No Sony code is bundled: the Java stub is resolved at runtime from the HAL
 * APK that already ships on the device (inject.py puts it on CLASSPATH).
 *
 * IMPORTANT: NVP string fields are fixed length. Writing a value of the wrong
 * length is silently rejected by a length check inside the vendor library, so
 * setString() pads to the current field length and verifies the read-back.
 */
public final class Nvp {

    public static final String TAG = "NVPTOOL";

    private static final String IFACE = "izm.android.properties.V1_0.IProperties";
    private static final String SERVICE = "default";

    private final Object svc;
    private final Method get;
    private final Method set;

    private Nvp(Object svc, Method get, Method set) {
        this.svc = svc;
        this.get = get;
        this.set = set;
    }

    public static Nvp connect() throws Exception {
        Class<?> ip = Class.forName(IFACE);
        Object svc = ip.getMethod("getService", String.class).invoke(null, SERVICE);
        if (svc == null) {
            throw new IllegalStateException("HAL service izm.android.properties not found");
        }
        return new Nvp(svc,
                ip.getMethod("get", String.class, ArrayList.class),
                ip.getMethod("set", String.class, ArrayList.class));
    }

    /** Read a raw field. Returns null on failure. */
    public byte[] get(String key) throws Exception {
        Object r = get.invoke(svc, key, new ArrayList<Byte>());
        if (!(r instanceof ArrayList)) return null;
        ArrayList<?> l = (ArrayList<?>) r;
        byte[] out = new byte[l.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) (((Number) l.get(i)).intValue() & 0xff);
        }
        return out;
    }

    /** Write a raw field. Throws on rejection. */
    public void set(String key, byte[] value) throws Exception {
        ArrayList<Byte> a = new ArrayList<Byte>(value.length);
        for (int i = 0; i < value.length; i++) a.add(Byte.valueOf(value[i]));
        set.invoke(svc, key, a);
    }

    /** Write a 32-bit little-endian integer into an existing 4-byte field. */
    public boolean setInt(String key, int v) throws Exception {
        byte[] cur = get(key);
        if (cur == null || cur.length != 4) {
            log("SKIP " + key + " (unexpected length " + (cur == null ? -1 : cur.length) + ")");
            return false;
        }
        byte[] nv = new byte[] {
                (byte) (v & 0xff),
                (byte) ((v >> 8) & 0xff),
                (byte) ((v >> 16) & 0xff),
                (byte) ((v >> 24) & 0xff)
        };
        set(key, nv);
        return verify(key, nv);
    }

    /** Write an ASCII string into a fixed-length field, preserving its length. */
    public boolean setString(String key, String s) throws Exception {
        byte[] cur = get(key);
        if (cur == null) {
            log("SKIP " + key + " (cannot read)");
            return false;
        }
        if (s.length() > cur.length) {
            log("SKIP " + key + " (value longer than field: " + s.length() + " > " + cur.length + ")");
            return false;
        }
        byte[] nv = new byte[cur.length];
        for (int i = 0; i < nv.length; i++) {
            nv[i] = i < s.length() ? (byte) s.charAt(i) : 0;
        }
        set(key, nv);
        return verify(key, nv);
    }

    private boolean verify(String key, byte[] expect) throws Exception {
        byte[] now = get(key);
        if (now == null || now.length != expect.length) {
            log("FAIL " + key + " (read-back failed)");
            return false;
        }
        for (int i = 0; i < now.length; i++) {
            if (now[i] != expect[i]) {
                log("FAIL " + key + " (mismatch at byte " + i + ")");
                return false;
            }
        }
        log("OK   " + key + " = " + describe(expect));
        return true;
    }

    /** Dump a field as text if printable, otherwise as hex. */
    public void dump(String key) {
        try {
            byte[] b = get(key);
            log("GET  " + key + " = " + describe(b));
        } catch (Throwable t) {
            log("GET  " + key + " FAILED: " + t);
        }
    }

    public static String describe(byte[] b) {
        if (b == null) return "<null>";
        int n = 0;
        StringBuilder sb = new StringBuilder();
        while (n < b.length && b[n] != 0) {
            int c = b[n] & 0xff;
            if (c < 32 || c > 126) { sb.setLength(0); break; }
            sb.append((char) c);
            n++;
        }
        if (sb.length() > 2) return "\"" + sb + "\"";
        StringBuilder hx = new StringBuilder();
        for (int i = 0; i < b.length; i++) hx.append(String.format("%02x", b[i] & 0xff));
        return hx.toString();
    }

    public static void log(String s) {
        android.util.Log.e(TAG, s);
    }
}
