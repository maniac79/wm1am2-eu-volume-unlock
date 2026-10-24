package org.maniac79.nvptool;

/**
 * READ-ONLY. Dumps the NVP fields that matter for the EU loudness limit.
 * Safe to run at any time; changes nothing.
 *
 * Run:  python3 tools/inject.py 1000 'platform:targetSdkVersion=29:complete' \
 *           org.maniac79.nvptool.Read org.maniac79.nvptool
 */
public final class Read {

    private static final String[] STRING_FIELDS = {
            "ro.vendor.alc.voltbl_id.se_high",
            "ro.vendor.alc.voltbl_id.se_low",
            "ro.vendor.alc.voltbl_id.se_high_amb",
            "ro.vendor.alc.voltbl_id.se_high_nc",
            "ro.vendor.alc.voltbl_id.btl_high",
            "ro.vendor.alc.voltbl_id.btl_low",
            "ro.vendor.eq.voltbl_id.se_high",
            "ro.vendor.eq.voltbl_id.se_low",
            "ro.vendor.eq.voltbl_id.btl_high",
            "ro.vendor.eq.voltbl_id.btl_low",
            "ro.product.model_id",
            "ro.product.bundled_hp"
    };

    private static final String[] INT_FIELDS = {
            "ro.product.destination",
            "ro.user.destination",
            "ro.app.highgain.mode",
            "ro.safe_volume.enabled",
            "ro.safe_volume.default",
            "ro.safe_volume.v3.enabled",
            "ro.volume.gain.se",
            "ro.volume.gain.btl",
            "ro.volume.default",
            "ro.volume.default.se.high",
            "ro.volume.default.se.normal",
            "ro.volume.default.btl.high",
            "ro.volume.default.btl.normal",
            "ro.regiondata.version"
    };

    public static void main(String[] args) {
        Nvp.log("=== NVPTOOL read-only dump ===");
        Nvp.log("model=" + android.os.Build.MODEL + " fingerprint=" + android.os.Build.FINGERPRINT);
        Nvp.log("uid=" + android.os.Process.myUid());

        Nvp nvp;
        try {
            nvp = Nvp.connect();
        } catch (Throwable t) {
            Nvp.log("FATAL: cannot reach HAL: " + t);
            return;
        }

        Nvp.log("--- volume table selectors (ALC) ---");
        for (int i = 0; i < 6; i++) nvp.dump(STRING_FIELDS[i]);

        Nvp.log("--- volume table selectors (EQ) ---");
        for (int i = 6; i < 10; i++) nvp.dump(STRING_FIELDS[i]);

        Nvp.log("--- gain / safe volume / destination ---");
        for (int i = 0; i < INT_FIELDS.length; i++) nvp.dump(INT_FIELDS[i]);

        Nvp.log("--- identity ---");
        for (int i = 10; i < STRING_FIELDS.length; i++) nvp.dump(STRING_FIELDS[i]);

        Nvp.log("=== done ===");
    }
}
