package org.maniac79.nvptool;

import java.io.File;
import java.io.RandomAccessFile;
import java.nio.channels.FileLock;

/**
 * One request, one execution.
 *
 * The exemption in hidden_api_blacklist_exemptions is state: every Zygote fork
 * while it is armed executes this payload. ActivityManager retries a replaced
 * app start, so "one host request" can mean several executions. Duplicates are
 * harmless for a read but not for a write, so the payload must decide for
 * itself which process owns the request.
 *
 * Two mechanisms, in order:
 *   1. createNewFile() - O_CREAT|O_EXCL, atomic: exactly one process wins.
 *   2. FileLock on a host-prepared file - advisory, but the loser gets null.
 *
 * If neither is possible the caller must refuse to touch the HAL. Failing closed
 * is the point: a claim that cannot be taken means the single-execution property
 * cannot be guaranteed, not that it can be skipped.
 */
public final class Claim {

    /** Host-created, world-writable directory inside the shell tmp area. */
    public static final String DIR = "/data/local/tmp/nvptool-claims";

    /**
     * Directory actually used. The host test harness sets NVPTOOL_CLAIM_DIR to a
     * temporary directory; on device the constant above applies.
     */
    public static String dir() {
        String env = System.getenv("NVPTOOL_CLAIM_DIR");
        return (env != null && env.length() > 0) ? env : DIR;
    }

    /** "file" or "lock" when a mechanism was usable, null when neither was. */
    public final String mode;
    /** True for the one process that owns this request. */
    public final boolean won;

    private Claim(String mode, boolean won) {
        this.mode = mode;
        this.won = won;
    }

    public static Claim acquire(String runId, String op) {
        File dir = new File(dir());

        try {
            // Atomic: the name can be created exactly once.
            File claim = new File(dir, "claim-" + runId + "-" + op);
            return new Claim("file", claim.createNewFile());
        } catch (Throwable ignored) {
            // fall through to the lock mechanism
        }

        try {
            File lockFile = new File(dir, "lock-" + runId);
            RandomAccessFile raf = new RandomAccessFile(lockFile, "rw");
            FileLock lock = raf.getChannel().tryLock();
            // The lock is intentionally held for the life of the process.
            return new Claim("lock", lock != null);
        } catch (Throwable ignored) {
            return new Claim(null, false);
        }
    }
}
