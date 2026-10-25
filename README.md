# Sony NW-WM1AM2 EU volume cap tool (experimental)

> ## ⚠️ USE ENTIRELY AT YOUR OWN RISK
>
> This tool writes **persistent NVRAM** on an expensive player through a temporary
> privilege escalation and an undocumented vendor interface. It can leave the
> player unbootable, unstable, or with broken audio. Recovery may require Sony
> service tools that are not publicly available.
>
> **The author accepts no responsibility or liability** for damage, data loss,
> bricking, voided warranty, or other harm from using, misusing, or building this
> software. There is **no warranty of any kind**. If you are not prepared to lose
> the device, do not run it.

This is a repair and interoperability tool for an EU Sony NW-WM1AM2 owned by the
project author. It changes eight audio configuration fields so the firmware
selects its non-EU volume table and shows the High Gain control. The audible
effect of High Gain and the size of any volume increase have not been measured.
It requires neither root nor a bootloader unlock and does not modify firmware or
include Sony binaries. It **does** use CVE-2024-31317 to obtain temporary access
to the vendor HAL; that is a real exploit with real device risk.

**Supported profile:** `NW-WM1AM2`, Android 11, Sony firmware `1.09.00`, exact
build fingerprint `SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys`.
Privileged operations reject other models and fingerprints. No second unit,
other Walkman model, or other firmware has been confirmed compatible. Menu
option 1 (`status`) displays three properties; it does **not** prove that the
device is compatible.

**Essential procedure: one privileged CLI command per boot, then reboot.**
`read`, `apply`, `restore`, and `restore-reference` are privileged commands. An
optional separate `read` must be followed by a **reboot before `apply`**. `apply`
already creates and verifies its own backup before writing, so a separate
`read` is not required. Reboot after every privileged command, including a
successful read, before using the player's apps. See
[Procedure](#procedure-and-backup-meaning).

## Evidence and validation

The author reported success with the original manual method on one physical
NW-WM1AM2 running firmware `1.09.00`. Subsequent **packaged macOS** passes on
that same unit provide the following narrower evidence:

| Pass | Hardware observation |
|---|---|
| 0.2.4 | Privileged `read`; `apply` wrote and verified 8/8 fields and made a verified host backup; `restore-reference` wrote and verified 8/8 fields, with the EU cap returning after reboot. |
| 0.2.5-era re-test | `restore` from that unit's own `baseline` backup restored eight fields; the cap returned after reboot (`01000000`). The re-test used the packaged 0.2.4 macOS archive. |
| 0.2.6 | `apply` on an already changed player verified 8/8 values and wrote 0 fields. This tested the no-write path, not another eight-write apply. |

Those historical passes support the listed hardware behavior on **one unit**.
They do not turn the built-in reference profile into a universal factory image.
`baseline` means the eight values match the reference observed on one EU unit;
it does not prove the historical original values of any particular player.

Version **0.2.7** has current **offline host validation**, with no new physical
device run claimed. At source commit `5c93f99`, [CI run 40211579731](https://github.com/maniac79/wm1am2-eu-volume-unlock/actions/runs/40211579731)
passed the Linux/Bash, Windows PowerShell 5.1, Windows PowerShell 7, and packaged
macOS jobs. Its logs report **42/42 Java mock-HAL**, **166/166 Bash fake-adb**,
**123/123 Windows PowerShell 5.1**, **123/123 Windows PowerShell 7**, and
**34/34 documentation** checks. A separate local PowerShell 7.6.8 review on
macOS reported **121/121**; the Windows CI jobs include two additional BAT
checks. These tests cover identity
and backup guards, result validation, cleanup handling, and host/package behavior
under simulation. They cannot establish real USB, driver, adb, Zygote, HAL,
firmware, or acoustic behavior on another device.

| Host | Offline coverage | Physical Walkman run |
|---|---|---|
| macOS | Bash host suite and packaged macOS CI job | The 0.2.4–0.2.6 passes above |
| Linux | Bash host suite with fake adb | None reported |
| Windows | PowerShell suite with simulated adb on PS 5.1 and 7 | None reported |

The project accepts the historical hardware evidence for the actions it
actually covered; 0.2.7's host validation is described separately. For test
boundaries and the vendor evidence, see [FINDINGS](docs/FINDINGS.md),
[SECURITY](docs/SECURITY.md), and the [manual test plan](docs/MANUAL-TEST-PLAN.md).

## Before you start

1. Get the **full matching 0.2.7 ZIP** for your computer from the named Assets
   on the [v0.2.7 release page](https://github.com/maniac79/wm1am2-eu-volume-unlock/releases/tag/v0.2.7):
   `wm1am2-nvptool-macos-0.2.7.zip`,
   `wm1am2-nvptool-windows-0.2.7.zip`, or
   `wm1am2-nvptool-linux-0.2.7.zip`. GitHub's automatic “Source code” archives
   have no built helper APK. A standalone APK cannot upgrade an older host
   package: use its matching host scripts, receipt, and APK together. The full
   0.2.7 ZIP is the recommended update path. Older binary assets were withdrawn;
   their Git tags remain for traceability.
2. Compare the ZIP's SHA-256 with the hash **outside the ZIP** in its release
   notes. `SHA256SUMS.txt` checks the ZIP's contents but does not authenticate
   the ZIP itself. `SOURCE-COMMIT.txt` records the source commit, APK hash, and
   release eligibility; compare the APK's certificate with the pin in
   [SIGNING](docs/SIGNING.md). The receipt supports provenance checks but does
   not independently reproduce the APK byte for byte. Release APK 0.2.7 has
   Android `versionCode=10` and the same pinned certificate SHA-256 as the
   preceding release APKs:
   `c21c663d2171dcbd8bdc47c5bb5b2103a0fbf7aa349d7e5aebb67123de42c992`.
3. Install [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools)
   for your computer. Put the extracted `platform-tools` folder beside the
   starter or put `adb` on `PATH`; the adjacent executable takes priority. A
   suitable Windows USB driver or Linux USB access rule may be needed. You need
   no JDK, Python, or full Android SDK to use a release ZIP.
4. On the player, enable Developer options (Settings → About device → tap
   **Build number** seven times), enable **USB debugging**, connect a data USB
   cable, and approve this computer's debugging prompt. `adb devices` must show
   exactly one player marked `device`, not `unauthorized` or `offline`.

After extraction, launch `START-macos.command` on macOS,
`START-windows.bat` on Windows, or `./START-linux.sh` on Linux (`chmod +x` may
be needed after extraction). macOS may prompt about a downloaded unsigned
script; the Windows starter uses a local PowerShell execution-policy bypass.
Inspect the package and published hash before opening it; the prompts do not
authenticate the archive.

## Menu and first run

The menu on all three platforms offers these exact choices:

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

1. Choose **1** to view `device`, `destination`, and `safe_volume`. This is a
   property-only view, with no helper installation or privilege. It does not
   check the exact fingerprint or read all eight NVRAM fields.
2. Choose **7** to explicitly install or update the bundled helper. This
   installs an Android app but writes **no NVRAM**. `read` and `apply` do not
   install it for you. Installation checks the supported device and the trusted
   bundled APK. Android refuses an update signed with a different certificate;
   the tool never uninstalls an existing helper automatically. Older debug-key
   helpers cannot upgrade in place to the pinned release key. Review the
   installed package and [SIGNING](docs/SIGNING.md) before any owner decision
   about removing one; do not bypass an install failure with an adb downgrade.
3. You may choose **2** to record all eight values before deciding whether to
   write. This is a **privileged read**, not a harmless dry run. Save the printed
   `.conf` and `.sha256` backup files together, then choose **5 to reboot**
   before any later `apply`. The menu has no automatic reboot prompt after a
   read. Alternatively, proceed straight to **3**: `apply` makes and verifies
   the same backup before it starts its NVRAM writes.
4. Choose **3** only after reviewing the risks and a recovery plan for this
   device. It verifies the backup and writes up to eight fields with readback.
   After a successful write the menu asks to reboot and defaults to **yes**.
   The table is selected at boot, so check the result only after restarting.

Option **4** restores from the latest verified `baseline`-labelled backup for
that same device. It writes fields individually. Type `restore-ref` at the menu
only for the **advanced** built-in reference-profile write, with its separate
confirmation; it is not a per-device backup or automatic factory restore.
Option **5** requests a reboot. Option **6** explains Platform Tools and USB
debugging. See [Recovery](#failure-and-recovery) before restoring any uncertain
or damaged state.

### Command line equivalent

Run these from the extracted release ZIP directory. The menu and CLI use the
same host implementation and guards. One privileged CLI command is followed by
one reboot; the optional two-command sequence below has a reboot **between**
`read` and `apply`.

| Action | macOS / Linux Bash | Windows PowerShell |
|---|---|---|
| Status | `./nvptool.sh status` | `.\nvptool.ps1 status` |
| Install helper | `./nvptool.sh install` | `.\nvptool.ps1 install` |
| Optional read and backup | `./nvptool.sh read` | `.\nvptool.ps1 read` |
| Reboot after that read | `./nvptool.sh reboot` | `.\nvptool.ps1 reboot` |
| Apply, including its own backup | `./nvptool.sh apply` | `.\nvptool.ps1 apply` |
| Reboot after apply | `./nvptool.sh reboot` | `.\nvptool.ps1 reboot` |
| Restore latest baseline-labelled backup | `./nvptool.sh restore` | `.\nvptool.ps1 restore` |
| Restore a chosen backup | `./nvptool.sh restore "/path/to/backup.conf"` | `.\nvptool.ps1 restore "C:\path\to\backup.conf"` |
| Advanced reference write | `./nvptool.sh restore-reference` | `.\nvptool.ps1 restore-reference` |

Reboot after `restore` or `restore-reference` too. On Windows, run the commands
in PowerShell; the Windows starter handles its own script policy. A separately
launched PowerShell may need an appropriate process-scoped execution-policy
invocation. For example, from the verified ZIP directory, run
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\nvptool.ps1 status`.
The command output also prints its reboot command. The optional explicit-file
restore of a `snapshot` or `foreign` backup additionally requires
`NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1`; it returns to those saved values, which
may already be modified. Do not set that flag for the default restore.

## Procedure and backup meaning

On the tested firmware, one privileged host request may execute more than once
on the device. The tool checks duplicate execution results and refuses
inconsistent or incomplete evidence. For the rest of that boot, new app
processes can be replaced by the payload; Settings and other apps may not open.
After **one privileged CLI command**, reboot before using apps or issuing
another privileged command. `status`, `install`, and `reboot` are not privileged
NVRAM operations. A successful `read` needs a manual menu reboot (option 5);
successful writes get a menu reboot prompt defaulted to yes. A write's effect
on the boot-selected table also needs a reboot. The observed Zygote behavior is
documented in [ZYGOTE-SINGLE-EXECUTION](docs/ZYGOTE-SINGLE-EXECUTION.md).

Backups are saved on the **host**, under `~/.nvptool/backups/<adb-serial>/`
(under the user's home `.nvptool\backups` directory on Windows), never on the
player. Preserve the `.conf` and `.sha256` files as a pair and keep a second
private copy. They contain serial, fingerprint, and raw NVRAM values. Redact
serials and never publish full backups or private local paths.

`kind=baseline` means an exact eight-value match with the built-in reference
profile observed on one EU unit. `kind=snapshot` means a match with the tool's
target state; `foreign` is another pattern. A backup taken after a previous
change records that current state, **not** historical factory values. The
schema-1 format remains compatible with previous versions, subject to its
device and firmware identity checks. A verified backup is required before
`apply` writes, but it cannot guarantee recovery from a partial or damaged
NVRAM state. The eight writes are not atomic, and ordinary `restore` rejects
unrecognized current field values. The reference profile is also not a
universal recovery image.

Before privileged work, the tool checks the exact model and fingerprint,
installed helper APK bytes, and a device-wide lock. It temporarily uses the
global `hidden_api_blacklist_exemptions` setting, then removes it and checks
that it is absent. A present value, including literal `null` or empty, or an
uncertain absence check is refused before mutation. Do not clear an unknown
pre-existing setting to force a run. Readback of NVRAM or the status property
does not prove acoustic loudness or all behavior after reboot. Start listening
at low volume and raise it gradually; no dB increase is established.

## Failure and recovery

| Exit | Meaning |
|---|---|
| `0` | Command completed; inspect its operation-specific result. |
| `3` | Read or backup incomplete before the NVRAM write phase. |
| `4` | No trustworthy completion record; data outcome **UNKNOWN**. |
| `5` | Definite write failure; state may be **PARTIAL**. |
| `7` | Cleanup or lock release failed; recovery is required even if a data step looked complete. |
| `11` | Unsupported model, firmware, component, or identity. |
| `12` | Present or uncertain global setting, or an existing local or device lock. |
| `20` | Backup missing or invalid. |
| `21` | Non-baseline restore needs an explicit file and consent flag. |

For `UNKNOWN`, `PARTIAL`, or exit `7`, **do not automatically retry** a read,
apply, or restore. Preserve the output, backup pair, recovery record, host lock,
and device lock. Failed cleanup retains a protected local recovery record and
device-wide lock; the tool does not silently retry cleanup. While the lock is
retained, the tool refuses another privileged read, so inspect the record and
lock owner without privileged operations first. On Bash, the host lock is
`${TMPDIR:-/tmp}/nvptool.lock.<serial>/` with a `pid` file; the printed
`recovery-<run>-<op>.state` file is in the backup directory. On Windows, the
host lock is a file named `nvptool.lock.<serial>` under the system temp directory,
and the backup directory contains `recovery-<operation-id>.txt`. Both hosts use
the device lock `/data/local/tmp/nvptool.lock`. The recovery records identify
the device and run and preserve the original setting state and remote lock path.

Correlate the lock owner, recovery record, output, and operation phase. A live
owner must finish or be deliberately stopped; never take over its run. Only
after confirming that the owner is gone and the run cannot continue should you
assess removing that specific lock and record the reason. Never remove an
unexplained lock or setting. Then run **one** privileged read, reboot, compare all eight fields
with the preserved backup, and decide on further action. A failed restore may
already have changed earlier fields. A matching backup and readback do not
guarantee rollback; damaged fields may be rejected and service may be needed.
Keep the matching ZIP and APK with the backup for future recovery.

## What changes, and what remains uncertain

The firmware reads `ro.safe_volume.enabled` at boot: the EU reference value
`1` selects its shipped `ov_1298_cew.tbl` table; target `0` selects its shipped
`ov_1298.tbl` table. The tool also selects the non-EU high and low gain tables
for both outputs and enables the High Gain setting:

| NVRAM field | One-unit EU reference | Target |
|---|---|---|
| `ro.safe_volume.enabled` | `1` | `0` |
| `ro.app.highgain.mode` | `0` | `1` |
| `ro.vendor.alc.voltbl_id.se_high` | `kVolTblIcx1298CewHpSe` | `kVolTblIcx1298HpSeGainHigh` |
| `ro.vendor.alc.voltbl_id.se_low` | `kVolTblIcx1298CewHpSe` | `kVolTblIcx1298HpSeGainLow` |
| `ro.vendor.alc.voltbl_id.btl_high` | `kVolTblIcx1298CewHpBtl` | `kVolTblIcx1298HpBtlGainHigh` |
| `ro.vendor.alc.voltbl_id.btl_low` | `kVolTblIcx1298CewHpBtl` | `kVolTblIcx1298HpBtlGainLow` |
| `ro.volume.gain.se` | `0` | `1` |
| `ro.volume.gain.btl` | `0` | `1` |

It does not change destination or identity fields, `ro.safe_volume.default`,
or the equalizer table selectors. `vendor.safe_volume.enabled=00000000` after
reboot is a property observation, not a sound-level measurement or proof of all
eight original values. The High Gain switch can appear while its audible
effect remains unverified. [FINDINGS](docs/FINDINGS.md) documents the boot
table path, raw observations, and approaches that did not work.

A firmware update can change the boot script, shipped tables, exploit path, or
NVRAM state. This tool refuses a different fingerprint; do not rerun `apply`
on an updated build. A factory reset's effect on these fields is untested.
After an update or reset, use `status` for property observation, verify the
fingerprint separately, and compare all eight values against your own prior
records only when a privileged read is appropriate. One property or a reset
alone is no basis for applying again. Firmware and app updates may carry
security fixes. The tool does not disable the Sony updater, Play Store, or
other packages, and makes no blanket recommendation to disable them.

## Source, signing, and provenance

Archive users do not need to build anything. A source build needs JDK,
Python 3, Android SDK build-tools, and `android.jar`. Maintainer release builds
use the dedicated pinned signing key; contributors must explicitly use a
separate local signing mode and key. A locally signed APK cannot upgrade the
official release APK in place and is not eligible for an official release ZIP.
The packaging process verifies the source, build receipt, APK identity, and
package inputs before producing eligible archives. See [SIGNING](docs/SIGNING.md)
for the precise commands and limits of those checks.

The original method and readback were reported by the project author on their
own unit. Code and prose were developed with AI assistance: **Cline** driving
**DeepSeek v4.1 Flash 1017 (high reasoning)**, with additional independent code
reviews by **ChatGPT**. Offline test results and the historical hardware
observations are separate kinds of evidence; neither proves compatibility
with a different player.

This repository contains no Sony firmware images, dumped APKs or shared
libraries, calibration `.tbl` files, extracted keys, decompiled vendor source,
or copied third-party prose. It contains first-party code, scripts, and prose,
plus the field names and observed values needed to reproduce the result. The
vendor interface is read from the device at runtime. Prior art includes the
[Head-Fi WM1Z/WM1A M2 discussion](https://www.head-fi.org/threads/sony-nw-wm1z-m2-wm1a-m2.962054/page-863)
of a distinct rooted destination-change route and
[Tellementnomade's older Walkman service discussion](https://forum.tellementnomade.org/viewtopic.php?t=15978).
Neither establishes that this package works on another device. The
[Android June 2024 security bulletin](https://source.android.com/docs/security/bulletin/2024-06-01)
lists CVE-2024-31317, but by itself does not establish the behavior of this
Sony Android 11 build. See [SECURITY](docs/SECURITY.md) for that distinction.

For a failure report, include tool version, computer OS and architecture,
firmware fingerprint, command, exit code, and redacted output. Do not publish
ADB serials, backup contents, local paths, or personal identifiers.

## License

MIT — see [LICENSE](LICENSE).
