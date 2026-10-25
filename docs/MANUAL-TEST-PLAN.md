# Manual hardware validation plan

Everything in this list requires the physical device. **None of it has been
performed as part of the automated test work**, and it must not be reported as
passed until a human actually runs it on the documented profile.

Applies to: `NW-WM1AM2`, Android 11, firmware `1.09.00`,
fingerprint `SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys`.

---

## 0. Preconditions

- [ ] Record `adb shell getprop ro.build.fingerprint` — must match exactly.
- [ ] Record `adb shell getprop vendor.destination` — expected `03010000`.
- [ ] Record `adb shell getprop vendor.safe_volume.enabled` — expected `01000000`
      on a factory EU unit.
- [ ] Note the audio volume level before starting; set the player to a **low**
      volume and use the same track for every listening step.

## 1. Basic status (no privilege)

- [ ] `./tools/nvptool.sh status` succeeds and reports the three properties.
- [ ] `adb shell settings get global hidden_api_blacklist_exemptions` is
      unchanged afterwards (`null` on a stock unit).
- [ ] No package was installed by this step: `adb shell pm path org.maniac79.nvptool`
      still fails if it was absent before.

## 2. Payload execution

- [ ] `./tools/nvptool.sh read` returns a complete result (begin + 8 fields +
      summary `status=OK`).
- [ ] The backup file appears under `~/.nvptool/backups/<serial>/` and its
      recorded lengths are 256/256/256/256/4/4/4/4.
- [ ] A second `read` does not overwrite `baseline.conf`.

**Expected on the owner's unit:** it is *already modified*, so the first read
will classify as `kind=snapshot` and **no `baseline.conf` will be created**.
That is correct behaviour, and it has a consequence:

- [ ] `nvptool.sh restore` refuses with "no original (baseline) backup" (exit 20).
- [ ] `nvptool.sh restore <snapshot>` refuses without
      `NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1` (exit 21).
- [ ] Conclusion recorded: on this device the only route back is
      `restore-reference`, because the true factory values were never captured
      before the first modification.

## 3. Apply

- [ ] `./tools/nvptool.sh apply` reports `verified`, not `INCOMPLETE`.
- [ ] `hidden_api_blacklist_exemptions` is back to its previous value
      (absent stays absent, an existing value is unchanged).
- [ ] Before rebooting, `nvptool.sh read` shows the eight target values.

## 4. After reboot

- [ ] `adb shell getprop vendor.safe_volume.enabled` reads `00000000`.
- [ ] `adb shell getprop vendor.destination` still reads `03010000`
      (the destination must not have changed).
- [ ] Audio plays normally on both the 3.5 mm and 4.4 mm outputs.
- [ ] Volume control still steps through its full range.

## 5. Listening comparison (subjective, record as such)

- [ ] At a fixed, low volume, compare the same passage before and after.
- [ ] Record honestly whether the difference was obvious, marginal, or
      indistinguishable. **Do not convert an impression into a dB figure.**
- [ ] If a High Gain switch is present, toggle it and record whether it now has
      an audible effect.

## 6. Restore

- [ ] `./tools/nvptool.sh restore` reports all eight fields restored.
- [ ] After reboot, `vendor.safe_volume.enabled` reads `01000000` again.
- [ ] The eight values match the backup exactly (`nvptool.sh read` vs backup).

## 7. Failure and recovery

- [ ] Disconnect USB mid-`apply`: the tool must report an unknown outcome or a
      disconnect, **not** success; a journal line must exist.
- [ ] With two devices attached, every command aborts.
- [ ] Corrupt the backup hex by hand: `restore` refuses it.
- [ ] Delete `hidden_api_blacklist_exemptions` mid-run is not possible to
      simulate safely — instead verify after an interrupted run that the setting
      is either original or absent, and that the tool says which.

## 8. Record the result

For each item record: pass / fail / not run, the exact command, and the observed
output. Anything not run must be reported as **not run**, not as passed.
