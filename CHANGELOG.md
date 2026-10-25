# Changelog

Versioning: this is an **experimental** project. A `0.x` version can change
or be withdrawn. A successful original manual method is not hardware
validation of later packaged implementations.

`v0.2.2` remains available as an older experimental pre-release with known
issues. Older 0.1.0, 0.2.0 and 0.2.1 binaries were withdrawn; their Git tags
remain for traceability. An entry here is not evidence that a build passed CI,
that an asset was published or that physical hardware was tested.

---

## 0.2.3 — experimental release

`versionName=0.2.3`, `versionCode=6`; the intended official APK retains the
0.2.2 dedicated release signing certificate. No automatic app uninstall and
no change to the eight target/reference NVRAM values or backup schema 1.

- The packaged first-user path now finds adjacent `platform-tools`; menu option
  7 and host CLI `install` explicitly install/update the bundled APK and verify
  installed APK bytes. `status` does not install an app; `read` and `apply` stop
  with an install hint when it is missing.
- Before privileged work, the host verifies the installed APK against the
  package's APK hash, checks both `settings list` and `settings get`, and
  refuses any already-present or unverifiably absent
  `hidden_api_blacklist_exemptions` key. It does not change someone else's
  pre-existing value to make the command run.
- A per-run payload path, local lock and atomic device-wide lock coordinate
  privileged phases. Interrupted/failed cleanup is reported separately,
  keeps a protected recovery record and lock when unresolved, and is never
  silently retried. Unknown data outcomes stay unknown. A lock or setting
  requiring manual recovery must be inspected; no generic delete command is
  supplied.
- Build receipts bind source/build inputs and APK metadata to packaging;
  official packaging rejects a dirty tree, stale receipt or test key by
  default. CI now exercises package entry points with simulated ADB before
  any later publication decision. `release`, `local` and `ci` signing modes
  are explicit; password material is not put literally in process arguments.
- Documentation distinguishes original manual success, simulated host tests
  and still-unperformed hardware acceptance. It corrects the status property,
  baseline terminology, first-user download/install path, recovery limits and
  firmware-update guidance.

**Still open:** the finished 0.2.3 macOS, Windows and Linux tools have not
been tested on a physical Walkman. Automatic backup, restore, real USB/HAL
behavior, partial-write recovery and measured loudness remain unverified on
hardware. `baseline` is a reference-value match, not independent proof of
historical original values for a specific unit. Ordinary restore deliberately
rejects certain damaged current field values even with a valid backup. A
manual return to a previous device state and a first macOS package test are
future, separately reviewed device actions, not results of this source change.

---

## 0.2.2 — older published experimental pre-release with known issues

Source commit: the `v0.2.2` tag. Functionally identical to 0.2.1 — this release
exists for **one** reason: the signing key.

- **The APK is now signed with a dedicated release key**, not the shared Android
  debug key that 0.1.0 through 0.2.1 used. Certificate
  `c21c663d…42c992`, RSA 4096, `CN=nvptool release key`; see `docs/SIGNING.md`.
  A helper installed from an earlier build must be removed once before
  installing this one (`adb uninstall org.maniac79.nvptool`). That removes the
  app only: the eight NVRAM values are device state and are unaffected.
  `versionCode` 4 → 5. This rotation was safe because the project has no
  installed base; it is not a precedent for silent rotation.
- **`build.sh` no longer creates a debug key on demand.** It requires the
  dedicated keystore (created once by the new `tools/init_signing_key.sh`), reads
  the password from `NVPTOOL_KEYSTORE_PASS` or a `0600` file, and fails the build
  if the keystore is missing or the certificate does not match the pin.
- **Archive names now carry the version** (`wm1am2-nvptool-macos-0.2.2.zip`), so
  two downloads can coexist and a stale copy is identifiable. The directory
  inside is unchanged, so the starters and the inner manifest are unaffected.
- `tests/docs/check_docs.sh` also verifies that the README names the archives for
  the current version.

Everything from 0.2.1 is included: the `restore-reference` false-success fix, the
fail-closed `apply`/`restore` cleanup handling, the Windows-menu output fix, the
rewritten `QUICKSTART.txt`, the README corrections and the documentation checks.

---

## 0.2.1 — withdrawn (binaries removed, tag kept)

Source commit: the `v0.2.1` tag. Replaces the withdrawn 0.2.0 binaries: those
contained the three defects below (the Windows menu in particular printed
nothing after any action), so they are no longer downloadable. Its Git tag stays
for traceability.

Version metadata: `versionName=0.2.1`, `versionCode=4` (upgrades an installed
0.2.0 or 1.1.0 helper in place — same signing certificate, see
`docs/SIGNING.md`). The unlock mechanism itself is unchanged.

Audit findings fixed after the 0.2.0 tag. No change to the unlock mechanism
itself: every code change tightens failure handling, and the rest is
documentation.

- **`restore-reference` reported success after a failed cleanup.** A leftover
  `hidden_api_blacklist_exemptions` payload could be paired with "reference
  profile restored (8/8 verified)" and a reboot suggestion. It now exits 7 with
  an explicit recovery-required message and no success claim.
- **`apply` continued into the write phase after an unclean backup read.** A
  failed cleanup in the read phase is now fatal *before* any write (exit 7), and
  the message states that nothing was written.
- **`restore` kept writing fields after an unclean field.** Restore now stops
  between fields, reporting which fields were written and how many were not.
- **The Windows menu swallowed the orchestrator's output.** `Run-Action` was
  called as `[void](Run-Action ...)`, which discarded the child process's stdout
  along with the return value: choosing *Status* printed a header and nothing
  else, and error messages from `nvptool.ps1` never reached the user. The
  launcher → menu → orchestrator test found it; `Run-Action` now routes the
  child's output to the host.
- **Windows PowerShell 5.1 is tested explicitly**, including the shipped
  `START-windows.bat` → menu → orchestrator path. The harness no longer
  silently substitutes `pwsh`, and `menu.ps1` now uses the host that runs it
  instead of a hard-coded `powershell`.
- **APK signing identity is pinned and checked at build time**;
  `docs/SIGNING.md` records the certificate fingerprint shared by 0.1.0, 1.1.0
  and 0.2.0, and the rule for any future rotation.
- **`QUICKSTART.txt` rewritten** against the real menu. It had called Windows
  read-only, labelled option 3 a restore, described the discontinued
  factory-restore workflow and quoted an unmeasured ~3 dB figure.
- **README corrections**: removed the deleted `Rollback.java` reference and the
  "Run Rollback" FAQ answer, stopped recommending a blind re-`apply` after an
  unknown firmware update, separated "unknown outcome" from "safe retry",
  clarified that the escalation is temporary while the helper APK and the NVRAM
  values persist, and qualified the battery/third-party claims.
- **New check**: `tests/docs/check_docs.sh` fails when the menus, `QUICKSTART`,
  `README` or the version metadata drift apart.

---

## 0.2.0 — withdrawn (binaries removed, tag kept)

Source commit: the `v0.2.0` tag. Replaces the withdrawn 0.1.0 preview.

Changes since the 0.1.0 preview:

- **Mandatory verified backup before any write.** The device-side payload now
  refuses to write without a state digest, which the host can only compute after
  it has written and re-read a backup. "No backup, no write" is enforced in the
  payload, not by convention.
- **Device-specific backup and restore.** Backups record the serial, model,
  firmware fingerprint, field lengths and a SHA-256 of their own contents; they
  are only accepted for the device that produced them. Restore is per-field and
  verified. A backup of an already-modified state is labelled `snapshot` and is
  never used automatically as a factory baseline.
- **Strict model and firmware validation** on every entry point, with the same
  fail-closed guard in the Java payload and in the host tools.
- **Improved error detection and cleanup.** A failed cleanup of the temporary
  setting is now exit 7 (recovery-required) instead of a warning followed by
  "success"; cleanup state is captured once per command so a failure cannot be
  laundered into the next phase.
- **Protection against false-success reporting.** Structured completion records
  are bound to a run id; FATAL, ABORT, INCOMPLETE, timeout, stale, malformed,
  truncated and duplicate results are never treated as success.
- **Native Windows support** (`nvptool.ps1`) at feature parity with the bash
  tool, sharing the same guards, backup format, digest and exit codes. The
  low-level runner refuses write classes outright: there is one protected write
  path per platform.
- **Automated tests**: Java payload tests against a mock HAL, bash host tests
  against a simulated `adb`, and PowerShell tests against a simulated `adb`.
- **GitHub Actions CI** runs the bash suites on Linux and the PowerShell suite on
  Windows.

Known limitations: not hardware-validated; the output-power increase is
unmeasured; only the documented NW-WM1AM2 / Android 11 / 1.09.00 profile is
supported.

Withdrawn because its binaries contain the three fail-open/false-success defects
fixed in 0.2.1 (see above) and, like every build up to 0.2.1, it is signed with
the retired debug key. **Do not build or run the 0.2.0 source either**: it is an
ancestor of the current branch, so it is part of normal Git history.

---

## 0.1.0 — withdrawn preview (historical)

Tag: `v0.1.0` → `f82eac34c7e3cf4deb68e73d125009b9f6c26ae7`

This was the first public preview. **Its GitHub Release object and binaries have
been withdrawn** because they contain known safety defects. The tag is kept
unchanged for traceability, and the source is still reachable through Git
history.

Known defects in that build:

- **No verified backup before writing.** Nothing forced a backup to exist, and
  the state of the device was not bound to it.
- **Unreliable failure handling.** Cleanup failure was reported as a warning and
  the run still returned success, offering a reboot. A stale global setting
  could survive a "successful" run.
- **No strict result checking.** Output was accepted without a run id or a
  completion record, so missing, stale or malformed output could be read as
  success.
- **No provenance.** The archives carried no `SOURCE-COMMIT.txt`, no
  `SHA256SUMS.txt` and no `LICENSE`, and the APK declared no `versionName` or
  `versionCode` at all — it identifies itself as no particular version.
- **Not hardware-tested** beyond the author's initial manual unlock.

**Do not build or run it.** Its binaries are gone; its source stays reachable
only so the history can be audited. If you still have those files, delete them
and use the current release named at the top of this file.
