# WM1AM2 EU volume cap removal (no root, no bootloader unlock)

Repair and interoperability tool for a Sony NW-WM1AM2 that I own.

My player was sold in the EU, where the regional firmware applies a lower
output-volume ceiling than the same hardware sold elsewhere. This tool restores
the non-EU output-volume configuration by setting the factory NVRAM field that
the boot process uses to choose the volume table. It also re-enables the
**High Gain** option that the EU configuration suppresses.

No root, no bootloader unlock, no firmware modification, no Sony binaries.

Scope: written for and tested on NW-WM1AM2, firmware `1.09.00`. The tool
refuses to run on any other model.

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
The original values are in `Rollback.java`, so the change is reversible.

---

## Requirements

* Sony NW-WM1AM2, Android 11, USB debugging enabled.
* **`adb` (Android Platform Tools).** Not bundled, deliberately — get it from
  https://developer.android.com/tools/releases/platform-tools
  The packaged menu detects it, and if it cannot be found it says exactly what
  to download and where to put it. The simplest route is to unzip the
  `platform-tools` folder next to the starter script, where it is picked up
  automatically.

Only if you build from source:

* JDK (`javac`, `keytool`), Android SDK build-tools and a platform `android.jar`.
* Python 3, for `tools/inject.py`.

---

## Firmware updates — read this before you update

Sony still ships firmware for some regions (an Asia-region release appeared in
2026), so the on-device updater is live even though this is an Android 11
device. **Disable it before a firmware update can land.**

Why: the EU limit is enforced by a boot script and a calibrated volume table
that ship inside the firmware. An update can replace either of them, can change
which tables exist, and may or may not preserve the NVRAM fields this tool
writes. Whether a specific firmware update reverts this change is **untested** —
proceed as if it will.

```bash
# disable the Sony updater (reversible)
adb shell pm disable-user --user 0 com.sony.walkman.systemupdater

# confirm: enabled=3 means disabled-by-user, enabled=1 means active
adb shell dumpsys package com.sony.walkman.systemupdater | grep -m1 enabled=

# if you ever want it back
adb shell pm enable com.sony.walkman.systemupdater
```

Consider disabling Play Store auto-updates too, or the Play Store entirely if
you do not install apps from it — it is by far the largest background consumer
on this device and it also auto-updates Chrome and Play services:

```bash
adb shell pm disable-user --user 0 com.android.vending
```

After any firmware update, re-run `Read` and check
`adb shell getprop vendor.safe_volume.enabled`. If it says `01000000`, the cap
is back and `Apply` needs to be run again.


---

## Usage

### Easiest way — download, extract, double-click

Grab the archive for your OS from
[Releases](https://github.com/maniac79/wm1am2-eu-volume-unlock/releases):

| Archive | Starter |
|---|---|
| `wm1am2-nvptool-macos.zip` | `START-macos.command` |
| `wm1am2-nvptool-windows.zip` | `START-windows.bat` |
| `wm1am2-nvptool-linux.zip` | `START-linux.sh` |

Extract, double-click the starter, and pick a menu option:

```
1) Check status            read-only, changes nothing
2) Enable the fix          writes NVRAM, then offers a reboot
3) Restore factory setting undo everything
4) Reboot the player
5) Where is adb? / requirements
```

You do **not** need a compiler, JDK or Android SDK for this route, and the menu
installs the APK for you. All you need is `adb` — see *Requirements*.

Each archive also contains `QUICKSTART.txt`, written for someone who has never
used `adb` before.

### From source

```bash
# 1. build + install the tool (one package, three entry points)
./tools/build.sh
adb install -r out/nvptool.apk

# 2. read-only dump of every relevant NVRAM field, to see the starting state
./tools/inject.sh org.maniac79.nvptool.Read

# 3. write the new values; each one is verified by read-back
./tools/inject.sh org.maniac79.nvptool.Apply

# 4. reboot so init reloads the DAC volume table
adb reboot

# 5. check the flag: 00000000 = EU clamp off, 01000000 = still on
adb shell getprop vendor.safe_volume.enabled
```

`tools/inject.ps1` does the same on Windows, `tools/inject.py` on any OS with
Python 3. All three emit identical payloads.


`Apply` prints how many of the eight fields were written and verified. Every
write is read back and compared, so a silent rejection is not reported as
success.

Expect roughly 3 dB of additional headroom, concentrated in the upper volume
range — the two tables differ by about that much, see section 6 of
`docs/FINDINGS.md`. It is a correction, not a transformation, so use a
moderate volume while confirming the change.

### Rollback

```bash
python3 tools/inject.py org.maniac79.nvptool.Rollback org.maniac79.nvptool
adb reboot
adb shell getprop vendor.safe_volume.enabled     # expect 01000000 again
```

`Rollback` writes the factory values recorded from this device and verifies
them the same way. Keep `out/nvptool.apk` — you need it to roll back, and it is
not committed to this repository.

---

## Why the helper step is needed

The NVRAM interface is a vendor HAL, `izm.android.properties::IProperties`, and
it is reachable only from SELinux domains granted `hwservice_manager find` on
`properties_hwservice`: `platform_app`, `priv_app`, `system_app`. A normally
installed app runs as `untrusted_app` and is denied.

`tools/inject.py` starts `app_process` as uid 1000 with
`seinfo=platform:targetSdkVersion=29:complete`, putting it in the `platform_app`
domain so it can talk to the HAL. It uses the publicly documented zygote
command-line issue CVE-2024-31317 to do that; this is a thin wrapper, and the
vendor-side Java stub is loaded from the APK already present on the device
rather than bundled here. On a device where that issue is patched, this step
will not work.

The spawn occasionally produces no output — re-run the command.

---

## Repository layout

```
src/org/maniac79/nvptool/Nvp.java       HAL client: get/set + read-back verify
src/org/maniac79/nvptool/Read.java      read-only dump
src/org/maniac79/nvptool/Apply.java     write the configuration (model-guarded)
src/org/maniac79/nvptool/Rollback.java  restore factory values
src/AndroidManifest.xml                 no components, on purpose
tools/build.sh                          build + sign the APK (bash)
tools/inject.py                         start a class in platform_app (Python)
tools/inject.sh                         same, macOS/Linux — needs only adb
tools/inject.ps1                        same, Windows — needs only adb
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

**Will a firmware update undo this?**
Assume yes. The EU limit is enforced by a boot script and a calibrated volume
table that ship inside the firmware, and an update can replace either. Re-check
after any update:

```bash
adb shell getprop vendor.safe_volume.enabled
```

`01000000` means the cap is back — run `Apply` again and reboot. `00000000`
means it survived.

**Should I block firmware updates?**
Recommended, and it is a separate one-line step — see *Firmware updates* above.
`com.sony.walkman.systemupdater` is still active on this model, and a 2026
Asia-region firmware exists.

**Does it survive a factory reset?**
Untested. Run `Read` afterwards; if the fields are back at their default
values, run `Apply` and reboot.

**Do I need root, or an unlocked bootloader?**
No. Neither is used, and on this hardware neither was achievable
(`secure:yes`, `get_unlock_ability=0`).

**Will it work on the WM1ZM2, ZX507, A306 or another Walkman?**
No. The tool is guarded to `NW-WM1AM2`. The volume-table identifiers are
specific to the `icx1298` audio board and do not exist on other codecs.

**I ran `Apply` and nothing sounds different.**
Reboot — the table is only loaded by init at boot, so the change cannot take
effect before a restart. Then check `vendor.safe_volume.enabled` and confirm it
reads `00000000`. If `Apply` printed fewer than 8/8 verified fields, re-run it:
the spawn step is occasionally flaky and produces no output at all.

**How much louder is it, really?**
The two output tables differ by roughly 3 dB on average, with the biggest
difference in the upper volume range, plus the High Gain switch starts working.
It is a noticeable step, not a doubling of loudness.

**Does it affect battery life, Plexamp, Chrome or streaming?**
No. It changes audio calibration values only. No background service, process or
hook is installed — nothing from this tool keeps running.

**Can I undo it?**
Yes. Run `Rollback` and reboot. It restores the eight fields to the values
recorded from the tested device and verifies each write.

**Do I need to compile anything?**
No. Download the archive for your OS from *Releases*, extract it and
double-click the `START-*` file. That route needs no JDK, no Android SDK and no
Python — only `adb`, and the menu installs the APK for you. Building from
source is only needed if you want to change the code.

**The menu says adb was not found — what now?**
You do not need the full Android SDK, only Platform Tools. Download it from
https://developer.android.com/tools/releases/platform-tools, unzip it, and drop
the resulting `platform-tools` folder next to the starter script. The menu looks
there before anywhere else, so that alone fixes it. Adding the folder to your
`PATH` works too.



## No third-party IP

This repository contains no Sony or other third-party intellectual property: no
firmware images, no dumped APKs or shared libraries, no `.tbl` calibration
tables, no extracted keys, no decompiled vendor source, and no copied text from
other sites. It contains only first-party source code, scripts and prose, plus
the field names and observed values needed to reproduce the result. Everything
else is read from the device at runtime.

---

## Credits and prior art

* The Head-Fi WM1Z/WM1A M2 thread, where an EU owner documented that the High
  Gain switch sets the mixer without any audible effect, and posted a rooted
  recipe for changing the destination.
* Tellementnomade's Sony service-manual thread, which documents that the
  destination and the sound-pressure regulation are separate settings and that
  Sony's own destination tool is internal.
* TheWalkmanBlog's write-up on uncapping EU Walkmans, including confirmation
  that the scsitool approach does not support Android Walkmans.
* The public work on CVE-2024-31317, used for the helper step.

---

## Provenance

The code and documentation here were produced in a single session with the help
of an AI assistant, then reviewed by running it and comparing the results
against the values read back from the device. The eight field values above are
what is actually stored on the player now.

---

## License

MIT — see [LICENSE](LICENSE).

