# Changelog

Versioning: this is an **experimental** project. Anything with a `0.x` version is
a pre-release, is not hardware-validated, and may change or be withdrawn.

Only one release is downloadable at a time. Historical Git tags are kept for
traceability, but their prebuilt binaries are withdrawn if they contain known
safety defects.

---

## 0.2.0 — current, experimental pre-release

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

Do not use it. If you have those files, replace them with 0.2.0.
