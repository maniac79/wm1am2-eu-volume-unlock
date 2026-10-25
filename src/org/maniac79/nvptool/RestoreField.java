package org.maniac79.nvptool;

/**
 * Restore ONE field from the host's validated backup.
 *
 * One field per invocation on purpose:
 *   - each payload stays small, well inside any command-line limit;
 *   - each step is independently written, verified and journaled by the host;
 *   - a failure cannot leave more than one field touched.
 *
 * argv: [0] run id, [1] field index 0..7, [2] hex of the exact raw bytes.
 *
 * Fail-closed rule: the current value must be either the requested value
 * (already restored), the target state, or the reference profile. Anything else
 * means the device is in a state this tool does not recognise, and it refuses
 * rather than overwriting it.
 */
public final class RestoreField {

    public static void main(String[] args) {
        String runId = args.length > 0 ? args[0] : "-";
        Result r = new Result(runId, "restore");

        int idx;
        byte[] want;
        try {
            if (args.length < 3) {
                r.begin();
                r.summary(Result.FATAL, "usage", 0, 0, Profile.COUNT, "missing_arguments");
                System.exit(Result.EXIT_USAGE);
                return;
            }
            idx = Integer.parseInt(args[1]);
            want = fromHex(args[2]);
            if (idx < 0 || idx >= Profile.COUNT) {
                r.begin();
                r.summary(Result.FATAL, "usage", 0, 0, Profile.COUNT, "bad_index");
                System.exit(Result.EXIT_USAGE);
                return;
            }
            if (want == null || want.length != Profile.LENS[idx]) {
                r.begin();
                r.summary(Result.REFUSED, "usage", 0, 0, Profile.COUNT, "backup_length_mismatch");
                System.exit(Result.EXIT_REFUSED);
                return;
            }
        } catch (RuntimeException e) {
            r.begin();
            r.summary(Result.FATAL, "usage", 0, 0, Profile.COUNT, "bad_argument");
            System.exit(Result.EXIT_USAGE);
            return;
        }

        r.begin();

        String env = Profile.checkEnvironment();
        if (env != null) {
            r.note("guard=" + env);
            r.summary(Result.REFUSED, "preflight", 0, 0, Profile.COUNT, env);
            System.exit(Result.EXIT_REFUSED);
            return;
        }

        Nvp nvp;
        try {
            nvp = Nvp.connect();
        } catch (Throwable t) {
            r.summary(Result.FATAL, "preflight", 0, 0, Profile.COUNT, "hal_unavailable");
            System.exit(Result.EXIT_FATAL);
            return;
        }

        byte[] cur;
        try {
            cur = nvp.get(Profile.KEYS[idx]);
        } catch (Throwable t) {
            cur = null;
        }
        if (cur == null) {
            r.summary(Result.FATAL, "read", 0, 0, Profile.COUNT, "read_failed_" + idx);
            System.exit(Result.EXIT_FATAL);
            return;
        }
        if (cur.length != Profile.LENS[idx]) {
            r.summary(Result.REFUSED, "read", 0, 0, Profile.COUNT, "field_length_" + idx);
            System.exit(Result.EXIT_REFUSED);
            return;
        }

        r.field(idx, Profile.KEYS[idx], cur);

        if (Profile.same(cur, want)) {
            r.note("no_write_needed");
            r.summary(Result.OK, "done", 0, 1, Profile.COUNT, "already_restored");
            System.exit(Result.EXIT_OK);
            return;
        }

        if (!Profile.same(cur, Profile.target(idx))
                && !Profile.same(cur, Profile.reference(idx))) {
            r.summary(Result.REFUSED, "read", 0, 0, Profile.COUNT, "unrecognized_current_" + idx);
            System.exit(Result.EXIT_REFUSED);
            return;
        }

        try {
            nvp.set(Profile.KEYS[idx], want);
        } catch (Throwable t) {
            r.summary(Result.INCOMPLETE, "write", 1, 0, Profile.COUNT, "write_failed_" + idx);
            System.exit(Result.EXIT_INCOMPLETE);
            return;
        }

        byte[] now;
        try {
            now = nvp.get(Profile.KEYS[idx]);
        } catch (Throwable t) {
            now = null;
        }
        if (!Profile.same(now, want)) {
            r.summary(Result.INCOMPLETE, "write", 1, 0, Profile.COUNT, "verify_failed_" + idx);
            System.exit(Result.EXIT_INCOMPLETE);
            return;
        }

        r.summary(Result.OK, "write", 1, 1, Profile.COUNT, "restored_" + idx);
        System.exit(Result.EXIT_OK);
    }

    private static byte[] fromHex(String s) {
        if (s == null || s.length() % 2 != 0) return null;
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int hi = Character.digit(s.charAt(i * 2), 16);
            int lo = Character.digit(s.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) return null;
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }
}
