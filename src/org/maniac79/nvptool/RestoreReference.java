package org.maniac79.nvptool;

/**
 * ADVANCED: write the reference profile back.
 *
 * This is NOT a factory backup. The values below were observed on one EU ("CEW")
 * unit before modification, and are provided only so a device in the known
 * target state can be returned to that reference configuration when no verified
 * backup exists. Normal restores must use RestoreField with the host's
 * per-device backup.
 *
 * argv: [0] run id, [1] the literal token CONFIRM_REFERENCE_PROFILE
 *        (a deliberate speed bump: this path must never run implicitly).
 *
 * Same environment guard, same read-all-first ordering, same recognised-state
 * rule, same stop-on-first-failure behaviour as Apply.
 */
public final class RestoreReference {

    public static final String CONFIRM_TOKEN = "CONFIRM_REFERENCE_PROFILE";

    public static void main(String[] args) {
        String runId = args.length > 0 ? args[0] : "-";
        String token = args.length > 1 ? args[1] : null;
        Result r = new Result(runId, "restore_reference");

        if (!CONFIRM_TOKEN.equals(token)) {
            r.begin();
            r.summary(Result.REFUSED, "usage", 0, 0, Profile.COUNT, "confirmation_missing");
            System.exit(Result.EXIT_REFUSED);
            return;
        }

        r.begin();
        r.note("reference_profile_not_a_backup");

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
            if (!Profile.same(cur[i], Profile.target(i))
                    && !Profile.same(cur[i], Profile.reference(i))) {
                r.summary(Result.REFUSED, "read", 0, 0, Profile.COUNT, "unrecognized_value_" + i);
                System.exit(Result.EXIT_REFUSED);
                return;
            }
        }

        int written = 0;
        int verified = 0;
        String status = Result.OK;
        String reason = "-";

        for (int i = 0; i < Profile.COUNT; i++) {
            byte[] want = Profile.reference(i);
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
}
