package org.maniac79.nvptool;

/**
 * Write the eight target fields.
 *
 * argv: [0] run id, [1] optional expected state digest (the host passes the
 *       digest recorded in its verified backup; a mismatch means the device
 *       changed since that backup was taken, and nothing is written).
 *
 * Order of operations, all fail-closed:
 *   1. shared environment guard (model + firmware fingerprint)
 *   2. HAL reachable
 *   3. read ALL eight fields; any read failure or unexpected length aborts
 *   4. optional digest comparison against the host backup
 *   5. every starting value must be a recognised one (target or reference)
 *   6. if all eight already equal the target: no writes at all
 *   7. otherwise write one field at a time, stop at the first failure
 *
 * There is no atomicity across the eight independent HAL calls: a mid-way
 * failure leaves a partial state on purpose, and the summary reports exactly
 * how far it got so the host can journal and recover from a known state.
 */
public final class Apply {

    public static void main(String[] args) {
        String runId = args.length > 0 ? args[0] : "-";
        String expect = args.length > 1 ? args[1] : null;
        Result r = new Result(runId, "apply");
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

        // The host only computes this digest after it has written and verified a
        // backup. Requiring it means "no backup, no write" is structurally true,
        // not merely a convention the caller is trusted to follow.
        if (expect == null || expect.length() != 64 || !isHex(expect)) {
            r.note("state_digest_required");
            r.summary(Result.REFUSED, "preflight", 0, 0, Profile.COUNT, "missing_state_digest");
            System.exit(Result.EXIT_REFUSED);
            return;
        }

        byte[][] cur = new byte[Profile.COUNT][];
        for (int i = 0; i < Profile.COUNT; i++) {
            try {
                cur[i] = nvp.get(Profile.KEYS[i]);
            } catch (Throwable t) {
                cur[i] = null;
            }
            if (cur[i] == null) {
                r.summary(Result.FATAL, "read", 0, 0, Profile.COUNT, "read_failed_" + i);
                System.exit(Result.EXIT_FATAL);
                return;
            }
            if (cur[i].length != Profile.LENS[i]) {
                r.summary(Result.REFUSED, "read", 0, 0, Profile.COUNT, "field_length_" + i);
                System.exit(Result.EXIT_REFUSED);
                return;
            }
        }

        if (expect != null && !expect.equals(Profile.digest(cur))) {
            r.summary(Result.ABORT, "read", 0, 0, Profile.COUNT, "state_changed_since_backup");
            System.exit(Result.EXIT_ABORT);
            return;
        }

        for (int i = 0; i < Profile.COUNT; i++) {
            if (!Profile.same(cur[i], Profile.target(i))
                    && !Profile.same(cur[i], Profile.reference(i))) {
                r.summary(Result.REFUSED, "read", 0, 0, Profile.COUNT, "unrecognized_value_" + i);
                System.exit(Result.EXIT_REFUSED);
                return;
            }
        }

        boolean allTarget = true;
        for (int i = 0; i < Profile.COUNT; i++) {
            if (!Profile.same(cur[i], Profile.target(i))) {
                allTarget = false;
                break;
            }
        }
        if (allTarget) {
            r.note("no_write_needed");
            r.summary(Result.OK, "done", 0, Profile.COUNT, Profile.COUNT, "already_applied");
            System.exit(Result.EXIT_OK);
            return;
        }

        int written = 0;
        int verified = 0;
        String status = Result.OK;
        String reason = "-";

        for (int i = 0; i < Profile.COUNT; i++) {
            byte[] want = Profile.target(i);
            if (Profile.same(cur[i], want)) {
                verified++;
                continue;
            }
            try {
                nvp.set(Profile.KEYS[i], want);
            } catch (Throwable t) {
                status = Result.INCOMPLETE;
                reason = "write_failed_" + i;
                break;
            }
            written++;
            byte[] now = null;
            try {
                now = nvp.get(Profile.KEYS[i]);
            } catch (Throwable t) {
                now = null;
            }
            if (!Profile.same(now, want)) {
                status = Result.INCOMPLETE;
                reason = "verify_failed_" + i;
                break;
            }
            verified++;
        }

        if (Result.OK.equals(status) && verified != Profile.COUNT) {
            status = Result.INCOMPLETE;
            reason = "not_all_verified";
        }

        r.summary(status, "write", written, verified, Profile.COUNT, reason);
        System.exit(Result.exitFor(status));
    }

    private static boolean isHex(String s) {
        for (int i = 0; i < s.length(); i++) {
            if (Character.digit(s.charAt(i), 16) < 0) return false;
        }
        return true;
    }
}
