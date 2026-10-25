package org.maniac79.nvptool;

/**
 * Structured, machine-readable completion records.
 *
 * One record per line, all sharing the same run id, so a host wrapper can prove
 * that a result belongs to the run it started and that it is complete:
 *
 *   ev=begin     always first
 *   ev=field     one per field (read/restore operations)
 *   ev=note      optional, informational only - never affects the verdict
 *   ev=summary   always last, carries the verdict
 *
 * The verdict is only ever taken from a summary line whose run id matches and
 * that appears after a matching begin line. Missing, truncated, duplicated or
 * stale records must be treated as failure by the caller.
 *
 * This exists because the device-side process is launched asynchronously: its
 * exit code is not observable on the host, so the exit code here is a secondary
 * signal for local/direct runs only.
 */
public final class Result {

    public static final int EXIT_OK = 0;
    public static final int EXIT_ABORT = 10;
    public static final int EXIT_REFUSED = 11;
    public static final int EXIT_INCOMPLETE = 12;
    public static final int EXIT_FATAL = 13;
    public static final int EXIT_USAGE = 14;

    public static final String OK = "OK";
    public static final String ABORT = "ABORT";
    public static final String REFUSED = "REFUSED";
    public static final String INCOMPLETE = "INCOMPLETE";
    public static final String FATAL = "FATAL";

    private static final String PREFIX = "NVPTOOL_RESULT";

    private final String run;
    private final String op;
    private final String head;

    public Result(String runId, String op) {
        this.run = safe(runId);
        this.op = safe(op);
        this.head = PREFIX
                + " v=1 schema=" + Profile.SCHEMA
                + " tool=" + Profile.TOOL_VERSION
                + " run=" + this.run
                + " op=" + this.op;
    }

    public void begin() {
        Nvp.log(head + " ev=begin");
    }

    public void field(int idx, String key, byte[] value) {
        Nvp.log(head + " ev=field idx=" + idx
                + " key=" + key
                + " len=" + (value == null ? -1 : value.length)
                + " val=" + (value == null ? "-" : Profile.hex(value)));
    }

    public void note(String slug) {
        Nvp.log(head + " ev=note msg=" + safe(slug));
    }

    /** Emits the final record. Call exactly once per run. */
    public void summary(String status, String phase, int written, int verified,
                        int total, String reason) {
        Nvp.log(head + " ev=summary status=" + status
                + " phase=" + safe(phase)
                + " written=" + written
                + " verified=" + verified
                + " total=" + total
                + " reason=" + safe(reason));
    }

    public static int exitFor(String status) {
        if (OK.equals(status)) return EXIT_OK;
        if (ABORT.equals(status)) return EXIT_ABORT;
        if (REFUSED.equals(status)) return EXIT_REFUSED;
        if (INCOMPLETE.equals(status)) return EXIT_INCOMPLETE;
        return EXIT_FATAL;
    }

    /** Keep values inside the single-line, space-free wire format. */
    private static String safe(String s) {
        if (s == null || s.length() == 0) return "-";
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
            sb.append(ok ? c : '_');
        }
        return sb.toString();
    }
}
