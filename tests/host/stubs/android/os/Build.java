package android.os;

/** Host stub; values can be overridden with -Dnvptool.test.model / -Dnvptool.test.fingerprint. */
public final class Build {
    public static final String MODEL =
            System.getProperty("nvptool.test.model", "NW-WM1AM2");
    public static final String FINGERPRINT =
            System.getProperty("nvptool.test.fingerprint",
                    "SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys");
}
