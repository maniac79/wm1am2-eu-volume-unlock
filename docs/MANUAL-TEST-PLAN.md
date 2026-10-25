# Manual hardware validation plan (written for 0.2.5; historical)

**This is a 0.2.5-era document, kept as evidence of that pass.** v0.2.6 was
released at commit `a8be4de`; the current release is v0.2.7, which carries only
host-validation fixes and has no hardware evidence at all.

**Status, for 0.2.5 only: the macOS items for `status`, `read`, `apply`,
`restore-reference` and `restore` were run on the author's unit; the Windows
and Linux items and the interruption items were NOT.** The project author reports that the
original manual method worked on their NW-WM1AM2. Mock tests, CI and ZIP
integrity checks are different evidence. Record `pass`, `fail` or `not run`
for each step; do not turn a skipped or simulated step into hardware acceptance.

This plan applies only to `NW-WM1AM2`, Android 11, Sony firmware `1.09.00`,
exact fingerprint `SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys`.
It is a review checklist, **not authorization to restore, apply or reboot** a
particular Walkman. Do not deliberately disconnect USB during a real NVRAM
write to simulate interruption on the owner's only player.

## 0. Artifact and starting state

- [ ] Identify the actual release ZIP by filename and SHA-256 from its release
      notes. Record its `SOURCE-COMMIT.txt`, internal `SHA256SUMS.txt`,
      `PACKAGE-INPUTS.json`, APK signer and version. GitHub's automatic source
      archive is not the ready-to-run package. A local build receipt does not
      alone establish independent bit-for-bit reproducibility.
- [ ] Record the host OS and architecture, Platform Tools version, USB driver
      or permissions where relevant, and `adb devices`. Exactly one device
      must be authorized. Redact its serial in shared reports.
- [ ] Record model, `ro.build.fingerprint`, `vendor.destination` and
      `vendor.safe_volume.enabled`. `status` does not check firmware support;
      privileged operations do. Record the same properties after the run.
- [ ] Record whether `hidden_api_blacklist_exemptions` is truly **absent** using
      both `settings list global` and `settings get global ...`. A present
      setting, even with literal `null` or empty value, or a failed query is
      a stop condition for this tool. Do not delete it as a routine preflight.
- [ ] Independently establish the history of this unit. Preserve any external
      pre-modification eight-field record and its provenance if one exists.
      Absence of such a record from this repository proves neither that it
      exists nor that it was lost. The built-in reference values came from one
      EU unit; their identity relationship to this owner unit is not established
      by the software's `baseline` label.
- [ ] Record the current eight raw field values, lengths and a private copy of
      every `.conf` and `.sha256` pair. A `snapshot` of an already-modified state
      is useful for return to that state, not proof of original factory values.
      Set player volume low before listening checks.

## 1. Package entry points, before any NVRAM write

- [ ] From the extracted ZIP, put `platform-tools` beside the starter with
      `adb` absent from the rest of `PATH`; confirm the adjacent executable is
      selected. Repeat on the intended host OS. Do not substitute a source
      checkout for this first-user test.
- [ ] Choose menu option 1 (`status`). Confirm three properties appear, no APK
      was installed, no privileged payload or global setting was written and
      no NVRAM field changed. Note that status alone gives no fingerprint gate.
- [ ] With helper not installed, `read` and `apply` refuse and point to explicit
      option 7/CLI `install`; neither may silently install or write NVRAM.
- [ ] Choose option 7/CLI `install` deliberately. Confirm bundled APK bytes
      match `SOURCE-COMMIT.txt`, Android install reports success, and pulling
      the installed APK gives the same hash. Installation writes an app, not
      NVRAM; an existing differently signed app is not auto-uninstalled.
- [ ] Confirm a present global setting or failed `settings list`/`get` query
      refuses *before* payload/setting mutation (prefer isolated mocks; do
      not alter a real device's pre-existing setting just for this test).

## 2. Full read and backup

- [ ] Run the platform's `read`. It is privileged and creates a local backup;
      it is **not** a no-change dry run. Record begin, eight fields and an `OK`
      completion record, exit code and exact backup path. Confirm lengths
      256/256/256/256/4/4/4/4 and schema 1.
- [ ] Independently verify backup `.conf` and `.sha256`, model/firmware/serial
      binding, and `kind`. `baseline` means exact match to built-in reference;
      `snapshot` matches target; `foreign` means neither. Preserve raw values
      privately. A second read must not overwrite an existing `baseline.conf`.
- [ ] After read, confirm the global setting is absent, temporary remote
      payload removed, device lock released and no recovery record remains
      after clean completion. A failed cleanup must report exit 7, leave the
      recovery record and lock for inspection and must not auto-retry.

## 3. Define the return route before any write

Choose **one evidence path** and record what is actually available:

1. A verified pre-modification record from **this** unit: compare all eight
   original bytes, source, date, integrity and matching device/firmware before
   claiming restoration of its historical state.
2. A `baseline`-labelled backup from the tool: it matches one built-in EU
   reference profile but does not by itself prove that profile's historical
   origin on this unit. Record that limitation.
3. A previously modified-state `snapshot`: explicit file plus
   `NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1` may return to those saved modified
   values; it is not a factory rollback.
4. The advanced `restore-reference`: deliberately writes the built-in
   reference profile. State that the reference-to-unit provenance is not
   established here. Do not label it a factory restore without separate proof.

A manual rollback was performed before the first packaged macOS test, and the
later `restore` run used the device's own `baseline` backup. Its exact historical evidence and procedure must be reviewed
separately. This checklist neither assumes an original backup is absent nor
approves `restore-reference` as a substitute. A damaged current NVRAM field
may be refused by the normal `RestoreField` guard despite a valid backup;
that is a deliberate fail-closed limit. Have a concrete fallback (including
Sony service if necessary) rather than assuming `restore` always works.

## 4. Apply, reboot and observation — only after separate authorization

- [ ] Before Apply: exact fingerprint, all eight current bytes, backup path,
      backup kind, global setting absence and return route recorded. Check the
      device lock is not held by another or interrupted run.
- [ ] Run `apply` once. Record exit, written/verified counts, backup path and
      any incomplete/unknown outcome. Confirm no success report when cleanup
      or lock release fails. Do not treat eight readbacks as an atomic write.
- [ ] Run `read` before reboot to compare eight target values if the state is
      clean. If exit 4/5/7 or an unknown field appears, stop and inspect; do
      not automatically retry Apply or Restore.
- [ ] After separately authorized reboot: compare `vendor.safe_volume.enabled`
      and unchanged `vendor.destination`, then read all eight values again.
      `00000000` is a property input to boot table selection, not proof of
      exact loaded table or measured loudness.
- [ ] At low volume, verify 3.5 mm and 4.4 mm audio, full volume control, and
      subjective listening response. Record High Gain presence/effect as an
      observation. Do not convert impressions or table byte counts into dB.

## 5. Restore or manual return — its own result

- [ ] Identify the exact file/profile and expected eight values before any
      write. `restore`, `restore-reference` and a manual NVRAM rollback are
      separate operations with separate provenance.
- [ ] Record each field written/verified, the cleanup/lock result, exit code
      and eight-field readback. If a current field is outside the accepted
      state, ordinary restore may refuse it; do not override the guard blindly.
- [ ] After authorized reboot, check property, audio and all eight fields.
      Claim “returned to this unit's original values” only if a separately
      authenticated record for this unit establishes those original bytes.

## 6. Failure evidence and platform scope

- [ ] Simulate timeout, FATAL, malformed result, SIGINT/SIGTERM and PowerShell
      exception with fake ADB in isolated tests; do not intentionally cause
      dangerous interruptions on real NVRAM. Confirm that data outcome and
      cleanup outcome are reported separately and that exit 7 takes precedence
      when cleanup is unverified.
- [ ] For exit 7/12 on a real unit, preserve the protected recovery record,
      lock path and exact output; inspect before any manual unlock or setting
      repair. Never publish serials, backups or unredacted local paths.
- [ ] macOS, Windows and Linux each require their **own** package-to-device
      run before being marked hardware-tested. Windows CI and Linux/macOS fake
      ADB tests cannot stand in for USB, drivers, firmware or listening.

For every item write: date, package hash, command, exit code, redacted output,
observed before/after values and `pass` / `fail` / `not run`. A reviewer should
be able to distinguish software tests, historical manual evidence, a new
physical run and human listening acceptance.
