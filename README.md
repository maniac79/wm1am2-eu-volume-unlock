# WM1AM2 EU volume cap: NVRAM configuration change (experimental)

Repair and interoperability tool for a Sony NW-WM1AM2 that I own.

My player was sold in the EU, where the regional firmware applies a lower
output-volume ceiling than the same hardware sold elsewhere. This tool restores
the non-EU output-volume configuration by setting the factory NVRAM field that
the boot process uses to choose the volume table. It also makes the
**High Gain** toggle appear in Settings, which the EU configuration suppresses —
whether that toggle then becomes audible is unproven (see the FAQ).

No root, no bootloader unlock, no firmware modification, no Sony binaries.

Scope: the original manual method was reported successful on one NW-WM1AM2,
firmware `1.09.00`. The packaged host tools are not yet hardware-tested.
Privileged commands refuse other models and build fingerprints; `status` only
displays properties and is not a compatibility check.

---

## Testing & Validation Status

**Experimental. Read this before using anything here.**

- The **original unlock method** was successfully tested by the project author
  on their own Sony NW-WM1AM2.
- The **current hardened implementation has not been tested end-to-end on
  physical hardware.**
- The **automatic backup feature has NOT been tested on the author's Walkman.**
- **Backup-based restoration has NOT been tested on physical hardware.**
- **Linux has NOT been tested by the project author.**
- **Windows has NOT been tested by the project author.**
- **Automated tests and Windows CI results are not physical-device
  validation.** They run against a simulated `adb` and a mock device. They
  cannot exercise USB behaviour, adb versions, driver quirks, real HAL timing,
  or firmware differences.
- **No other firmware versions or Walkman models have been confirmed
  compatible.** Only `1.09.00` on `NW-WM1AM2` is targeted, and everything else
  is refused.

### Platform support matrix

| Platform | Write path | Automated tests | Physical device |
|---|---|---|---|
| macOS | `nvptool.sh` (bash) | yes — simulated adb | **packaged 0.2.3 not tested** |
| Linux | `nvptool.sh` (bash) | yes — simulated adb | **not tested** |
| Windows | `nvptool.ps1` (PowerShell) | yes — simulated adb, incl. CI | **not tested** |

Windows has full feature parity in the *code* (status, install, read, apply,
restore, reference-restore, reboot) and its tests pass, but **feature parity in code is
not evidence that it works on a Walkman.**

### What the automated tests do establish

Offline, with no hardware: the guards reject unknown models and firmware; a
write cannot happen without a verified backup; FATAL/ABORT/INCOMPLETE/timeout/
stale/malformed/duplicate results are never treated as success; a failed
cleanup exits 7 instead of claiming success; backups are integrity-checked and
bound to one device; corrupt or foreign backups are refused; known target values are classified as a snapshot; backups matching the built-in
reference values are classified as `baseline` (a value match, not proof of
historical factory provenance); and both language implementations produce
byte-identical backup files and the same state digest.

### What they do not establish

That the payload runs at all on your firmware; that the temporary privilege
step behaves the same on your adb version; that the volume change is audible;
that interruption recovery works on real hardware; or that the value written is
the one the boot loader ends up using.

---

## Supported configuration and limitations

* **One documented, tested configuration only:**

  | | |
  |---|---|
  | Model | `NW-WM1AM2` |
  | Android | 11 |
  | Sony firmware | `1.09.00` |
  | Build fingerprint | `SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys` |
  | Regional property | `vendor.destination=03010000` (CEW / EU) |

  Any other model, firmware or build is **rejected**, not assumed compatible.
  Nothing here has been validated on a second unit.

* **It uses temporary privilege escalation.** To reach the vendor HAL the tool
  spawns a process in the `platform_app` SELinux domain via CVE-2024-31317, a
  publicly documented Android zygote vulnerability. "No root and no bootloader
  unlock required" does **not** mean "no exploit and no risk". The escalation
  itself lasts only for the command, but two things outlive it: the helper app
  (`org.maniac79.nvptool`) stays installed until you remove it with
  `adb uninstall org.maniac79.nvptool`, and the NVRAM values stay changed until
  you restore them.

* **It changes persistent NVRAM.** Eight audio calibration fields are written to
  factory NVRAM. They survive reboots. A partial or damaged write may not be restorable by this tool even with a
  validated backup. The reference profile is not a universal recovery image;
  Sony service may be required.

* **Known limitations.** No atomicity across the eight writes (a failure can
  leave a partial state, which the tool reports precisely); the Windows package
  has never been run on hardware; recovery depends on the current field state as well as a verified backup for
  *that* device; firmware updates are untested and may undo or alter the result.

* **Verified so far** on the profile above: the device-side read/apply/restore
  logic and the whole host layer are covered by host tests with a fake `adb` and
  a mock HAL. What has **not** been verified is anything requiring hardware:
  see [docs/MANUAL-TEST-PLAN.md](docs/MANUAL-TEST-PLAN.md).

---

## What the EU limit actually is

The ceiling is not in the audio app or the amplifier. It is a single NVRAM
field that determines which calibrated volume table the DAC is loaded with at
boot:

```
NVP  ro.safe_volume.enabled = 1
  -> property vendor.safe_volume.enabled = 01000000
  -> init: service load_volume_table /vendor/bin/load_volume_table ${vendor.safe_volume.enabled}
  -> dacdat auto icx1298 0x400000 01000000
  -> /vendor/usr/share/audio_dac/ov_1298_cew.tbl     (EU table)
```

Setting that field to `0` makes the same boot script load `ov_1298.tbl`, the
table used by units sold outside the EU. Both tables ship in the firmware; the
flag only selects between them.

The second effect is the High Gain switch. On an EU unit the volume-table
selectors for "gain high" and "gain normal" point at *the same* table, which is
why the switch is normally inert:

```
ro.vendor.alc.voltbl_id.btl_high = kVolTblIcx1298CewHpBtl
ro.vendor.alc.voltbl_id.btl_low  = kVolTblIcx1298CewHpBtl   <- identical
```

Non-EU firmware uses distinct `...HpBtlGainHigh` / `...HpBtlGainLow` tables.
This tool points the selectors at those and sets `ro.app.highgain.mode = 1`,
which brings back the setting in the Walkman UI.

Full technical writeup, including the things that did *not* work:
[docs/FINDINGS.md](docs/FINDINGS.md).

---

## What it changes

| NVP field | EU default | After |
|---|---|---|
| `ro.safe_volume.enabled` | `1` | `0` |
| `ro.app.highgain.mode` | `0` | `1` |
| `ro.vendor.alc.voltbl_id.se_high` | `kVolTblIcx1298CewHpSe` | `kVolTblIcx1298HpSeGainHigh` |
| `ro.vendor.alc.voltbl_id.se_low` | `kVolTblIcx1298CewHpSe` | `kVolTblIcx1298HpSeGainLow` |
| `ro.vendor.alc.voltbl_id.btl_high` | `kVolTblIcx1298CewHpBtl` | `kVolTblIcx1298HpBtlGainHigh` |
| `ro.vendor.alc.voltbl_id.btl_low` | `kVolTblIcx1298CewHpBtl` | `kVolTblIcx1298HpBtlGainLow` |
| `ro.volume.gain.se` | `0` | `1` |
| `ro.volume.gain.btl` | `0` | `1` |

Not touched: `ro.product.destination` (still `03010000`, CEW),
`ro.user.destination`, `ro.safe_volume.default`, the `ro.vendor.eq.voltbl_id.*`
selectors, and any identity field (serial number, model ID, product code).
A `read` or `apply` records your unit's current eight values. Copy the backup
and its `.sha256` file somewhere safe before a write. A backup made after an
earlier modification records that modified state, not historical factory values.
The built-in reference values were observed on one EU unit before modification;
their relationship to a particular user's original values must be established
from independent records.

---

## Requirements

* Sony NW-WM1AM2, Android 11, USB debugging enabled.
* **`adb` (Android Platform Tools).** Not bundled — download the package for
  your computer from https://developer.android.com/tools/releases/platform-tools
  and place its `platform-tools` folder beside the starter, or put `adb` on
  `PATH`. The tool prefers the adjacent executable. On Windows, a suitable USB
  driver may be needed; on Linux, USB access rules may be needed. Check `adb
  devices`: exactly one player must show `device`, not `unauthorized` or
  `offline`. A data-capable USB cable and approval of the debugging prompt on
  the player are required.

Only if you build from source:

* JDK (`javac`, `keytool`), Python 3, Android SDK build-tools and a platform
  `android.jar`. See [SIGNING.md](docs/SIGNING.md) for release versus local
  signing. Building from source does not require the maintainer's private key
  when explicit local mode is selected.

---

## Firmware updates and factory reset

A firmware update may change the boot script, calibration tables or NVRAM state.
This tool accepts only the exact `1.09.00` fingerprint listed above; do not
re-run `apply` on a new build. Firmware and app updates can also carry security
fixes. The project does not automatically disable any updater, Play Store app
or other package and makes no blanket recommendation to disable them.

After an update or factory reset, use `status` only to observe properties, then
check the exact build fingerprint separately. A privileged `read` requires the
supported build and installed helper; compare all eight values with a preserved
pre-change record. `vendor.safe_volume.enabled=01000000` alone does not prove
that all original per-device calibration values are present. A reset's effect on
these fields has not been tested. Do not infer that `apply` is appropriate from
one property or from a reset alone.

---

## Usage

### Download and inspect the package

For version 0.2.3, use the named **Assets** on the
[v0.2.3 release page](https://github.com/maniac79/wm1am2-eu-volume-unlock/releases/tag/v0.2.3)
when they are available: `wm1am2-nvptool-macos-0.2.3.zip`,
`wm1am2-nvptool-windows-0.2.3.zip` or
`wm1am2-nvptool-linux-0.2.3.zip`. If those Assets are not shown, wait for the
release package; GitHub's automatically generated “Source code” archives are
not ready-to-run packages and contain no built helper APK. The older
[v0.2.2 release](https://github.com/maniac79/wm1am2-eu-volume-unlock/releases/tag/v0.2.2)
remains available with the known issues described in [CHANGELOG.md](CHANGELOG.md).
The 0.1.0, 0.2.0 and 0.2.1 binaries were withdrawn; their Git tags remain for
traceability.

For a published package, compare the ZIP's SHA-256 with the hash **outside**
the ZIP in that release's notes. `SHA256SUMS.txt` checks files *inside* a ZIP
but cannot authenticate the ZIP by itself. `SOURCE-COMMIT.txt` records the
source commit and APK hash. Compare the APK's signing certificate with
[SIGNING.md](docs/SIGNING.md). The build receipt strengthens provenance but
is not an independent byte-for-byte source reproduction.

Extract the archive, place the matching Android `platform-tools` folder next
to the starter if `adb` is not already on `PATH`, and connect exactly one
USB-debugging-authorized NW-WM1AM2. Then open the platform starter:

| OS | Starter |
|---|---|
| macOS | `START-macos.command` |
| Windows | `START-windows.bat` |
| Linux | `START-linux.sh` (`chmod +x` may be needed after extraction) |

macOS may ask you to review a downloaded, unsigned script. Inspect the
archive's source and published hash before choosing to open it. The Windows
starter invokes local PowerShell with `ExecutionPolicy Bypass` for the
unsigned script; inspect the package before running it. Neither prompt proves
that the archive is trustworthy.

```text
1) Status               read-only, no privilege, changes nothing
2) Full NVP read        privileged read + verified backup
3) Apply the change     back up first, then write
4) Restore from backup  per-field restore, verified
5) Reboot the player
6) Requirements / where is adb
7) Install/update bundled helper APK (no NVRAM write)
0) Exit
```

Start with **1** to view `device`, `destination` and `safe_volume`. It reads
system properties only and does not verify the firmware fingerprint. **7** is
an explicit APK installation/update; it writes an app to the device but no
NVRAM. It never uninstalls another app. If a different signing key is already
installed, Android rejects the update; inspect that state before deciding
whether to uninstall. `read` and `apply` do not install the helper implicitly:
if it is absent, they stop and point to option 7.

**2** is not a no-change dry run. It checks the supported fingerprint,
compares the installed APK's pulled bytes with the trusted bundled APK,
acquires a device-wide lock, briefly writes the global
`hidden_api_blacklist_exemptions` setting, deletes it again and checks that it
is absent, and saves the eight-field backup locally. It refuses to start if
the setting already exists, even with a value of `null` or an empty value, or
if its absence cannot be confirmed. It does not try to repair or delete an
unknown pre-existing setting. Only **1** is the read-only check. **3**, **4**
and advanced `restore-ref` write persistent NVRAM; **5** reboots.

A successful read prints the backup path under
`~/.nvptool/backups/<adb-serial>/` (on Windows under the user's home
`.nvptool\backups` directory). Keep that `.conf` and its `.sha256` file as an
unchanged pair, preferably with a second private copy. Backups contain a
serial, firmware fingerprint and raw NVRAM values; redact serials and never
post full backups publicly. `kind=baseline` means the eight values exactly
match the built-in one-unit reference profile, **not** that their historical
origin on this device has been proven. `snapshot` matches the tool's target
values; `foreign` is another pattern. All kinds can be saved. The default
`restore` only selects a `baseline`-labelled backup and still checks current
field values. An explicitly selected non-baseline backup requires
`NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1` and returns to that saved state, which
may already have been modified. The backup format remains schema 1 and is
compatible with the previous version, subject to device/firmware checks.

`apply` first records and verifies the current eight values, then attempts
the target writes with per-field readback. The Java payload also checks the
current state and digest before writes. These checks do not make the eight
writes atomic. On a damaged partial state, ordinary `restore` may refuse a
field whose current bytes are outside its accepted states even with a valid
backup; a verified backup is **not** a guaranteed recovery path. The advanced
`restore-reference` writes values observed on one EU reference unit; it is
not an automatic factory restore or a replacement for independently proven
original values for your unit. Its relationship to the owner's historical
values was not verified here.

A successful NVRAM write requires a reboot before assessing the boot-selected
volume table. Check `vendor.safe_volume.enabled`, the eight read-back values
and audio function separately. Neither a property nor immediate HAL readback
proves an acoustic level or all post-reboot behavior. Lower the volume before
listening; the loudness change has not been measured in dB.

### Failure and recovery

| Exit | Meaning and first response |
|---|---|
| 0 | Operation completed; inspect its specific output. |
| 3 | Read/backup phase incomplete; the NVRAM write phase did not begin. |
| 4 | No trustworthy completion record; outcome unknown. Read current state before any further write. |
| 5 | Definite write failure; a partial state is possible. Preserve the printed backup and inspect each field. |
| 7 | Cleanup or lock release failed; recovery required even if the operation result looked complete. Preserve the recovery record and device lock for inspection. |
| 11 | Unsupported model, firmware or expected component/identity. |
| 12 | Present/uncertain global setting or existing local/device lock; inspect the condition, do not remove an unknown value or lock blindly. |
| 20 | Missing or invalid backup. |
| 21 | Non-baseline restore needs an explicit file and explicit consent. |

If cleanup cannot confirm absence of
`hidden_api_blacklist_exemptions`, the tool does not automatically retry the
restore; its protected local recovery record and the device-wide lock remain.
Do not manually delete the setting or the lock from a generic recipe: first
inspect the record, device and original state. A failed `restore` can have
already written earlier fields. The tool reports that boundary; a subsequent
write needs an assessed current state and recovery plan. Preserve the
package's APK for future use, as well as your backups.

### From source

Building needs the JDK, Python 3, Android SDK build-tools and a platform
`android.jar`. The normal maintainer build uses the dedicated pinned release
certificate. Third-party builders must create/select their own key and
explicitly set `NVPTOOL_SIGNING_MODE=local` (or `ci` for offline tests); the
result has a different Android signing identity and cannot upgrade an
installation signed by the project's release key. It is not eligible for an
official release archive. Follow [SIGNING.md](docs/SIGNING.md). Do not run
`./tools/init_signing_key.sh` on the maintainer's existing keystore.

A clean official package must be built from the same source as its APK receipt;
`make_release.sh` checks the receipt, Git state, package/version, certificate,
source and build inputs before it creates archives. `--allow-dirty` and
`--allow-test-key` are explicit local exceptions and do not make a package an
official release. `out/SOURCE-COMMIT.txt` accompanies a source-built APK for
host identity checks. A downloaded archive already includes its own flat
`SOURCE-COMMIT.txt`. Building code from source is optional for archive users.

---

## Why the helper step is needed

The NVRAM interface is a vendor HAL, `izm.android.properties::IProperties`, and
it is reachable only from SELinux domains granted `hwservice_manager find` on
`properties_hwservice`: `platform_app`, `priv_app`, `system_app`. A normally
installed app runs as `untrusted_app` and is denied.

The host CLI (`tools/nvptool.sh`, via `tools/lib.sh`) starts `app_process` as uid 1000 with
`seinfo=platform:targetSdkVersion=29:complete`, putting it in the `platform_app`
domain so it can talk to the HAL. It uses the publicly documented zygote
command-line issue CVE-2024-31317 to do that; this is a thin wrapper, and the
vendor-side Java stub is loaded from the APK already present on the device
rather than bundled here. On a device where that issue is patched, this step
will not work.

The spawn may produce no completion record. Treat the data outcome as unknown,
inspect the current eight values and cleanup/lock state, and do not blindly
re-run a command after an interrupted or uncertain operation.

---

## Repository layout

```
src/org/maniac79/nvptool/Nvp.java       HAL client: get/set + read-back verify
src/org/maniac79/nvptool/Profile.java   profile, field schema, guards
tools/nvptool.ps1                       host CLI / orchestrator (Windows)
tools/inject.ps1                        strict runner; refuses write classes
src/org/maniac79/nvptool/Result.java    structured completion records
src/org/maniac79/nvptool/Read.java      privileged read
src/org/maniac79/nvptool/Apply.java     write the configuration
src/org/maniac79/nvptool/RestoreField.java  per-field restore from backup
src/org/maniac79/nvptool/RestoreReference.java  advanced reference profile
src/AndroidManifest.xml                 no components, on purpose
tools/build.sh                          build + sign the APK (bash)
tools/lib.sh                            host helpers (device, lock, backup)
tools/nvptool.sh                        host CLI / orchestrator
packaging/macos/START-macos.command     double-click starter (macOS)
packaging/linux/START-linux.sh          starter (Linux)
packaging/windows/START-windows.bat     double-click starter (Windows)
packaging/common/menu.sh                interactive menu (macOS/Linux)
packaging/windows/menu.ps1              interactive menu (Windows)
packaging/common/QUICKSTART.txt         plain-language instructions for users
packaging/make_release.sh               builds dist/*.zip for a release
docs/FINDINGS.md                        technical writeup and negative results
docs/SECURITY.md                        analysis of the vendor HAL access model
```


---
## FAQ

**Will a firmware update or factory reset undo the change?** Unknown. Both may
alter the NVRAM state or firmware table selection; recheck the exact supported
build and all eight fields. The tool never automatically disables updaters.
Do not re-run `apply` based on one property alone.

**Do I need root or an unlocked bootloader?** No. The tool uses a temporary
privileged spawn via CVE-2024-31317. If that path has been patched, it fails;
there is no supported fallback for unknown firmware.

**Will this work on another Walkman?** No other model is supported by the
current guards or profile.

**How much louder is it?** Unknown. The observed difference between the two
shipped calibration tables is a byte difference, not a dB measurement. The
High Gain toggle can appear; its audible effect has not been established.

**Can I undo it?** A matching backup may allow a per-field restore, but the
accepted current-state guard can reject a damaged field. The built-in
reference profile is separate from your own historical values. A backup made
from an already modified device returns to that modified state if explicitly
selected. See *Failure and recovery* before starting a write.

**What should I report if a command fails?** Open an issue with the tool
version, computer OS/architecture, device firmware fingerprint, command,
exit code and redacted output. Do not publish your ADB serial, backup contents,
local paths or personal identifiers. A report is not hardware acceptance.

---

## No third-party IP

This repository contains no Sony or other third-party intellectual property: no
firmware images, no dumped APKs or shared libraries, no `.tbl` calibration
tables, no extracted keys, no decompiled vendor source, and no copied text from
other sites. It contains only first-party source code, scripts and prose, plus
the field names and observed values needed to reproduce the result. Everything
else is read from the device at runtime.

---

## Credits and prior art

* A [Head-Fi WM1Z/WM1A M2 discussion](https://www.head-fi.org/threads/sony-nw-wm1z-m2-wm1a-m2.962054/page-863)
  records a rooted destination-change recipe. It is distinct from this tool's
  eight-field HAL route and is not evidence that this package works.
* [Tellementnomade's Sony service discussion](https://forum.tellementnomade.org/viewtopic.php?t=15978)
  documents destination and sound-pressure settings for older Walkmans. Its
  scsitool instructions are not a method validated here for Android M2 models.
* The [Android June 2024 security bulletin](https://source.android.com/docs/security/bulletin/2024-06-01)
  lists CVE-2024-31317. Its listed updated AOSP versions are 12–14; the
  bulletin by itself does not establish the behavior of this Sony Android 11
  build. The project's device observation and host implementation are
  documented separately in [FINDINGS.md](docs/FINDINGS.md).

---

## Provenance

The original manual method and its readback were reported successful by the
project author on their unit. That observation does not validate the current
0.2.3 host wrappers, automatic backup, packaged installers or restoration on
physical hardware. Code and prose were developed with AI assistance and
reviewed with offline tests; hardware acceptance remains separate.

---

## License

MIT — see [LICENSE](LICENSE).

