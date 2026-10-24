package org.maniac79.nvptool;

/**
 * Apply the fix. Writes NVP fields and verifies every one by read-back.
 * Reboot afterwards: the DAC volume table is loaded at boot by init.
 *
 * Run:  python3 tools/inject.py 1000 'platform:targetSdkVersion=29:complete' \
 *           org.maniac79.nvptool.Apply org.maniac79.nvptool
 *
 * Only tested on NW-WM1AM2. Any other model aborts deliberately.
 */
public final class Apply {

    static final String EXPECTED_MODEL = "NW-WM1AM2";

    public static void main(String[] args) {
        Nvp.log("=== NVPTOOL apply ===");
        Nvp.log("model=" + android.os.Build.MODEL + " fingerprint=" + android.os.Build.FINGERPRINT);

        if (!EXPECTED_MODEL.equals(android.os.Build.MODEL)) {
            Nvp.log("ABORT: this tool is written for " + EXPECTED_MODEL
                    + " only. Edit EXPECTED_MODEL in Apply.java at your own risk.");
            return;
        }

        Nvp nvp;
        try {
            nvp = Nvp.connect();
        } catch (Throwable t) {
            Nvp.log("FATAL: cannot reach HAL: " + t);
            return;
        }

        int ok = 0;
        int total = 8;

        try {
            Nvp.log("--- volume table selectors (ALC) ---");
            if (nvp.setString("ro.vendor.alc.voltbl_id.se_high", "kVolTblIcx1298HpSeGainHigh")) ok++;
            if (nvp.setString("ro.vendor.alc.voltbl_id.se_low", "kVolTblIcx1298HpSeGainLow")) ok++;
            if (nvp.setString("ro.vendor.alc.voltbl_id.btl_high", "kVolTblIcx1298HpBtlGainHigh")) ok++;
            if (nvp.setString("ro.vendor.alc.voltbl_id.btl_low", "kVolTblIcx1298HpBtlGainLow")) ok++;

            Nvp.log("--- gain mode / safe volume ---");
            if (nvp.setInt("ro.app.highgain.mode", 1)) ok++;
            if (nvp.setInt("ro.volume.gain.se", 1)) ok++;
            if (nvp.setInt("ro.volume.gain.btl", 1)) ok++;

            // This is the field that actually feeds load_volume_table at boot.
            if (nvp.setInt("ro.safe_volume.enabled", 0)) ok++;

        } catch (Throwable t) {
            Nvp.log("ERROR during write: " + t);
        }

        Nvp.log("=== " + ok + "/" + total + " fields written and verified ===");
        if (ok == total) {
            Nvp.log("SUCCESS - now reboot. Verify after boot with:");
            Nvp.log("  adb shell getprop vendor.safe_volume.enabled   # expect 00000000");
        } else {
            Nvp.log("INCOMPLETE - do not reboot blindly, re-run or use Rollback.");
        }
        Nvp.log("=== done ===");
    }
}
