package android.util;

/** Host stub so the real nvptool classes can run outside Android. */
public final class Log {
    public static int e(String tag, String msg) {
        System.out.println("[" + tag + "] " + msg);
        return 0;
    }
}
