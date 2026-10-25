package org.maniac79.nvptool;

/**
 * Read all eight fields as raw bytes and emit them as structured records.
 *
 * This is the privileged full read: it needs the temporary privilege escalation
 * and the vendor HAL, but it performs no writes. It is deliberately separate
 * from the basic status check, which needs no privilege at all (see the README).
 *
 * argv: [0] run id
 */
public final class Read {

    public static void main(String[] args) {
        String runId = args.length > 0 ? args[0] : "-";
        Result r = new Result(runId, "read");
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

        for (int i = 0; i < Profile.COUNT; i++) {
            byte[] v;
            try {
                v = nvp.get(Profile.KEYS[i]);
            } catch (Throwable t) {
                v = null;
            }
            if (v == null) {
                r.summary(Result.FATAL, "read", 0, 0, Profile.COUNT, "read_failed_" + i);
                System.exit(Result.EXIT_FATAL);
                return;
            }
            if (v.length != Profile.LENS[i]) {
                r.summary(Result.REFUSED, "read", 0, 0, Profile.COUNT, "field_length_" + i);
                System.exit(Result.EXIT_REFUSED);
                return;
            }
            r.field(i, Profile.KEYS[i], v);
        }

        r.summary(Result.OK, "read", 0, Profile.COUNT, Profile.COUNT, "read_only");
        System.exit(Result.EXIT_OK);
    }
}
