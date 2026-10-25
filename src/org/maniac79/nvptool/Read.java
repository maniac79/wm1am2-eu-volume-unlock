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

        // One request, one execution. Two guards, at least one must hold:
        //   1. an exclusive claim, where the filesystem allows it;
        //   2. deleting the exemption itself, which removes the source of any
        //      later execution. Verified by reading the value back.
        Claim claim = Claim.acquire(runId, "read");
        Result r = new Result(runId, "read");
        if (claim.mode != null && !claim.won) {
            // Another process owns this request: do no work, and emit only a note
            // so the host's single-record invariants stay intact.
            r.note("duplicate_skipped");
            System.exit(Result.EXIT_OK);
            return;
        }
        if (claim.mode == null) {
            // No usable claim medium here; the disarm below is the only guard.
            r.note("claim_unavailable");
        }

        r.begin();
        if (claim.mode != null) {
            r.note("claim_acquired mode=" + claim.mode);
        } else {
            // No claim medium on this filesystem. A later execution is therefore
            // expected; the host accepts the run only when every execution is
            // read-only and all returned identical values.
            r.note("claim_unavailable");
        }

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
