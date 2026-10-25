import izm.android.properties.V1_0.IProperties;

import java.util.ArrayList;
import java.util.List;

/**
 * Test driver: configures the mock HAL, then calls a production entry point.
 *
 * Each scenario runs in its own JVM because the entry points call
 * System.exit(). Call counts are reported from a shutdown hook, which does run
 * on System.exit(), so a test can assert e.g. "wrong model => zero writes".
 *
 * Usage: Driver <setup[,setup...]> <op> [tool args...]
 *   setup: factory | target | partial:N | corrupt:N | short:N
 *          | failset:N | ignoreset:N | failget:N | nohal
 *   op:    apply | read | restore | restore_ref
 */
public final class Driver {

    public static void main(String[] args) {
        if (args.length < 2) {
            System.err.println("usage: Driver <setup> <op> [args...]");
            System.exit(64);
        }

        IProperties.resetFactory();
        String[] setups = args[0].split(",");
        for (int s = 0; s < setups.length; s++) {
            applySetup(setups[s].trim());
        }

        final String op = args[1];
        final String[] rest = new String[args.length - 2];
        System.arraycopy(args, 2, rest, 0, rest.length);

        Runtime.getRuntime().addShutdownHook(new Thread() {
            public void run() {
                System.out.println("DRIVER op=" + op
                        + " writes=" + IProperties.writes
                        + " setCalls=" + IProperties.setCalls
                        + " getCalls=" + IProperties.getCalls);
            }
        });

        if ("apply".equals(op)) {
            org.maniac79.nvptool.Apply.main(rest);
        } else if ("read".equals(op)) {
            org.maniac79.nvptool.Read.main(rest);
        } else if ("restore".equals(op)) {
            org.maniac79.nvptool.RestoreField.main(rest);
        } else if ("restore_ref".equals(op)) {
            org.maniac79.nvptool.RestoreReference.main(rest);
        } else {
            System.err.println("unknown op: " + op);
            System.exit(64);
        }
    }

    private static void applySetup(String token) {
        if (token.length() == 0 || "factory".equals(token)) {
            IProperties.resetFactory();
            return;
        }
        if ("target".equals(token)) {
            IProperties.resetTarget();
            return;
        }
        if ("nohal".equals(token)) {
            IProperties.HAL_UNAVAILABLE = true;
            return;
        }

        String[] kv = token.split(":");
        String what = kv[0];
        int idx = kv.length > 1 ? Integer.parseInt(kv[1]) : 0;
        String key = IProperties.KEYS[idx];
        int len = IProperties.LENS[idx];

        if ("failset".equals(what)) {
            IProperties.FAIL_SET.add(key);
        } else if ("ignoreset".equals(what)) {
            IProperties.IGNORE_SET.add(key);
        } else if ("failget".equals(what)) {
            IProperties.FAIL_GET.add(key);
        } else if ("short".equals(what)) {
            IProperties.putRaw(key, new byte[len - 1]);
        } else if ("corrupt".equals(what)) {
            byte[] b = new byte[len];
            for (int i = 0; i < len; i++) b[i] = (byte) 0x5a;
            IProperties.putRaw(key, b);
        } else if ("partial".equals(what)) {
            IProperties.resetFactory();
            for (int i = 0; i < idx; i++) {
                byte[] v = new byte[IProperties.LENS[i]];
                byte[] t = targetFor(i);
                System.arraycopy(t, 0, v, 0, Math.min(t.length, v.length));
                IProperties.putRaw(IProperties.KEYS[i], v);
            }
        }
    }

    private static byte[] targetFor(int i) {
        String[] names = {
                "kVolTblIcx1298HpSeGainHigh",
                "kVolTblIcx1298HpSeGainLow",
                "kVolTblIcx1298HpBtlGainHigh",
                "kVolTblIcx1298HpBtlGainLow"
        };
        if (i < 4) return IProperties.pad(names[i], IProperties.LENS[i]);
        int v = (i == 7) ? 0 : 1;
        return IProperties.le(v);
    }

    /** Unused helper kept for readability of assertions. */
    public static List<String> keys() {
        List<String> l = new ArrayList<String>();
        for (int i = 0; i < IProperties.KEYS.length; i++) l.add(IProperties.KEYS[i]);
        return l;
    }
}
