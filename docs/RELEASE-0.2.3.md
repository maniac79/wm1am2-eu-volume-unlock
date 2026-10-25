# Release notes: v0.2.3

**These notes alone are not evidence of a published asset or a physical-device
test.** The project's original manual method was
reported successful on the author's NW-WM1AM2. The finished 0.2.3 macOS,
Windows and Linux tools, automatic backup and backup-based restore remain
**untested on physical hardware**. Offline tests and CI use simulated ADB and
mock HAL behavior. Only NW-WM1AM2, Android 11, firmware 1.09.00 and the exact
fingerprint listed in the README are targeted.

## Changes from v0.2.2

- The release starter looks for a `platform-tools` folder beside it. Explicit
  menu option **7) Install/update bundled helper APK (no NVRAM write)** and
  host CLI `install` install the supplied helper and verify the installed APK
  bytes. `Status` remains a property-only, read-only check; `read` and `apply`
  do not silently install an app.
- Privileged operations compare a pulled copy of the installed helper with the
  trusted bundled APK before spawning it. An unexpected APK or missing
  bundle/provenance file makes the operation refuse.
- The global `hidden_api_blacklist_exemptions` key must be verifiably absent.
  Both list and get queries must succeed. A present key, including literal
  `null` or an empty value, is not overwritten. No automatic repair of a
  pre-existing value is attempted.
- A device-wide atomic lock and unique payload file prevent overlapping
  package runs from sharing a single payload path. A protected local recovery
  record is written before temporary setting mutation. Interrupted or failed
  cleanup is checked and reported; when unresolved, the device lock and record
  remain for inspection. The tool does not automatically retry a failed
  cleanup or issue a blind manual unlock command.
- Packaging checks a build receipt, source/build inputs, APK metadata and
  signing mode. The official path rejects dirty/test-key inputs by default.
  CI now includes package-path tests with simulated ADB. Passing tests do not
  prove real USB, exploit or vendor HAL behavior.
- The README and QUICKSTART now explain Asset ZIP versus GitHub source archive,
  external SHA-256 versus the internal manifest, explicit installation,
  backup provenance, firmware-update tradeoffs and the limits of restore.

`versionName=0.2.3`, `versionCode=6`. The intended release-signed APK uses the
**same dedicated certificate** as v0.2.2 (SHA-256
`c21c663d2171dcbd8bdc47c5bb5b2103a0fbf7aa349d7e5aebb67123de42c992`).
Android can upgrade a matching v0.2.2 installation by an explicit install
step. Helpers from 0.1.0–0.2.1 used a different certificate; Android refuses
an in-place upgrade. The tool does not automatically uninstall them. An app
uninstall does not undo persistent NVRAM values. Existing backup schema 1 is
unchanged.

## Before any user run

Choose the correct versioned ZIP under GitHub Release **Assets**, not GitHub's
automatic Source code ZIP. Official archive names are
`wm1am2-nvptool-OS-0.2.3.zip`; archives ending `-ci.zip`, `-local.zip`,
`-dirty.zip` or another candidate suffix are nonrelease builds. For an
official archive, inspect `SOURCE-COMMIT.txt` for `signing_mode=release`, the
pinned `certificate_sha256` and `release_eligible=true`. After publication,
place the exact ZIP SHA-256,
source commit, APK SHA-256 and APK certificate here and in the GitHub release
notes; these values **must be filled from the final downloaded assets**, not
from a draft build. The internal `SHA256SUMS.txt` checks archive contents but
cannot authenticate the archive by itself. The archive includes a starter,
helper APK, `QUICKSTART.txt`, `LICENSE`, provenance and checksum files. Android
Platform Tools (`adb`) must be obtained separately for the user's host OS.

This program uses a temporary privilege escalation (CVE-2024-31317) and can
write eight persistent NVRAM fields. A privileged `read` briefly changes a
global setting and saves a backup; it is not a no-change dry run. `apply`,
`restore` and `restore-reference` write NVRAM. Writes are not atomic and a
damaged partial field can make ordinary restore refuse even with a verified
backup. A `baseline` backup label means exact reference-value match, **not**
proof that those were the historical original values of this specific unit.
The built-in reference profile was observed on one EU unit before a change;
its relationship to any user's own historical values requires separate proof.

Lower volume before listening. The output difference has not been measured
in dB. Firmware updates and factory resets are untested and may change the
result; the tool does not disable updaters. Do not automatically re-Apply after
an update or reset. A planned manual rollback and first macOS 0.2.3 device
trial are future, separately authorized steps and are **not** described as
completed here. Windows and Linux hardware testing also remains open.

## Release-gate placeholders

- [ ] Final source commit, clean build receipt, official archive naming and
      release-signed APK verified; candidate archives excluded from Assets.
- [ ] Final macOS, Windows and Linux ZIPs built and tested from extracted
      packages with simulated ADB; exact outcomes recorded separately.
- [ ] Final ZIP/APK SHA-256 and certificate read back from downloaded assets;
      fill the release note hash table only then.
- [ ] CI gates completed before publication, with links to exact runs.
- [ ] GitHub release visibility and assets read back after publication.
- [ ] Physical-device validation status stated as **not run** unless a later
      human run has actually occurred and been separately accepted.
