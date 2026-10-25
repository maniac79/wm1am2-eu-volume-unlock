package android.os;

/** Host stub. */
public final class Process {
    public static int myUid() {
        return 1000;
    }

    /** Stable per-process identity for the test harness. */
    public static int myPid() {
        return 4242;
    }
}
