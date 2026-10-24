package org.maniac79.nvptool;

/**
 * Restore the factory NVP values. Verifies every write by read-back.
 * Reboot afterwards so init reloads the original volume table.
 *
 * Run:  python3 tools/inject.py 1000 'platform:targetSdkVersion=29:complete' \
 *           org.maniac79.nvptool.Rollback org.maniac79.nvptool
 *
 * The values below are the factory state observed on a EU (CEW) NW-WM1AM2
 * before any modification. See docs/FINDINGS.md.
 */
public final class Rollback {

    public static void main(String[] args) {
        Nvp.log("=== NVPTOOL rollback ===");
        Nvp.log("model=" + android.os.Build.MODEL + " fingerprint=" + android.os.Build.FINGERPRINT);

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
            Nvp.log("--- restore EU volume table selectors (ALC) ---");
            if (nvp.setString("ro.vendor.alc.voltbl_id.se_high", "kVolTblIcx1298CewHpSe")) ok++;
            if (nvp.setString("ro.vendor.alc.voltbl_id.se_low", "kVolTblIcx1298CewHpSe")) ok++;
            if (nvp.setString("ro.vendor.alc.voltbl_id.btl_high", "kVolTblIcx1298CewHpBtl")) ok++;
            if (nvp.setString("ro.vendor.alc.voltbl_id.btl_low", "kVolTblIcx1298CewHpBtl")) ok++;

            Nvp.log("--- restore gain mode / safe volume ---");
            if (nvp.setInt("ro.app.highgain.mode", 0)) ok++;
            if (nvp.setInt("ro.volume.gain.se", 0)) ok++;
            if (nvp.setInt("ro.volume.gain.btl", 0)) ok++;
            if (nvp.setInt("ro.safe_volume.enabled", 1)) ok++;

        } catch (Throwable t) {
            Nvp.log("ERROR during write: " + t);
        }

        Nvp.log("=== " + ok + "/" + total + " fields restored and verified ===");
        if (ok == total) {
            Nvp.log("SUCCESS - now reboot. Verify after boot with:");
            Nvp.log("  adb shell getprop vendor.safe_volume.enabled   # expect 01000000");
        } else {
            Nvp.log("INCOMPLETE - re-run rollback before rebooting.");
        }
        Nvp.log("=== done ===");
    }
}
