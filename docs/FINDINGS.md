# Findings

The original manual method below was reported successful on one EU
**NW-WM1AM2**, Android 11,
build fingerprint `SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys`,
kernel `5.4.233`, platform `imx` (NXP i.MX), audio codec board `icx1298`.

No root, no bootloader unlock, no firmware modification. The change is a write
to factory NVRAM through a vendor HAL that requires no permission.

---

## 1. The chain that creates the EU limit

```
NVP field  ro.safe_volume.enabled = 1
   |
   |  published as a property, hex encoded (4 bytes -> 8 hex chars)
   v
prop  vendor.safe_volume.enabled = 01000000
   |
   |  vendor init service (in the vendor ramdisk /etc/init):
   |      service load_volume_table /vendor/bin/load_volume_table ${vendor.safe_volume.enabled}
   |  which runs the script:
   |      dacdat auto icx1298 0x400000 $1
   v
/vendor/usr/share/audio_dac/ov_1298_cew.tbl      <- EU output volume table
```

With the field set to `0` the property becomes `00000000` and the same boot
script loads `/vendor/usr/share/audio_dac/ov_1298.tbl` (the non-EU table).

Both tables ship in the firmware; the destination flag only chooses between
them. There are no other output-volume tables for this codec (`icx1298`):
`ov_1298.tbl`, `ov_1298_cew.tbl` and the two DSD variants.

Observation: writing `ro.safe_volume.enabled = 0` and rebooting flips
`vendor.safe_volume.enabled` to `00000000`. This is the change that mattered.

---

## 2. Why "just enable high gain" never worked

`IzmAudioManager` exposes `setGain(int headset, int gain)` over an exported,
permission-free binder service. Calling it does exactly what it promises:

```
IzmAudioManager: setGain: 1, 1
SoundServiceImpl: SetParams: izm_headphone_smaster_btl_gain_mode=high
MixerCtrl: mixer: imx-audio-cxd3778gf: mixer_ctl: headphone smaster btl gain mode, ENUM
MixerCtrl: Set: headphone smaster btl gain mode, high
audio_hw_default: adev_set_parameters: exit with code(0)
```

The mixer control is set, the audio HAL returns success, and nothing audible
happens. The reason is visible in the NVP fields that select the volume table
per gain mode:

```
ro.vendor.alc.voltbl_id.se_high  = kVolTblIcx1298CewHpSe
ro.vendor.alc.voltbl_id.se_low   = kVolTblIcx1298CewHpSe     <- identical
ro.vendor.alc.voltbl_id.btl_high = kVolTblIcx1298CewHpBtl
ro.vendor.alc.voltbl_id.btl_low  = kVolTblIcx1298CewHpBtl    <- identical
```

On a CEW unit, "high" and "low" gain resolve to the *same* table, so the switch
cannot change anything. Non-CEU firmware has separate tables named
`kVolTblIcx1298HpSeGainHigh` / `...GainLow` (and `E`-suffixed EQ variants).

That explains the widely reported "the High Gain toggle does nothing on EU
units, but the logcat shows the hardware being set" observation.

---

## 3. Finding a write path to NVP

A read-only NVP node was reachable as `/dev/icx_nvp/NNN`, one node per field.
SELinux denied it from shell, from `system_app` and from `platform_app`:

```
/dev/icx_nvp(/.*)?    u:object_r:nvp_chr_device:s0
```

The vendor policy allows exactly one domain to touch it:

```
(allow hw_properties nvp_chr_device (chr_file (ioctl read write getattr lock append map open ...)))
(allow hw_properties nvp_device     (blk_file (ioctl read write getattr lock append map open ...)))
```

`hw_properties` is the domain of the vendor HAL process
`izm.android.properties`.

That HAL's interface turns out to have exactly two methods:

```
izm.android.properties@1.0::IProperties
    get(string key, vec<uint8_t> buf) -> vec<uint8_t>
    set(string key, vec<uint8_t> value)
```

`set` reaches `nvp_write` inside the vendor library, i.e. it is a general NVP
writer keyed by property name. Its HIDL transaction code is 2 (`get` is 1).

Access control is only SELinux on the *service*, not a permission:

```
(allow platform_app_30_0 properties_hwservice (hwservice_manager (find)))
(allow priv_app_30_0     properties_hwservice (hwservice_manager (find)))
(allow system_app_30_0   properties_hwservice (hwservice_manager (find)))
```

So anything running in `platform_app`, `priv_app` or `system_app` can rewrite
factory NVRAM. That is the primitive this tool uses. See `docs/SECURITY.md`.

---

## 4. The writes

Observed factory state versus the state that produced the result:

| NVP field | Factory (EU) | After |
|---|---|---|
| `ro.safe_volume.enabled` | `1` | **`0`** ← the effective change |
| `ro.app.highgain.mode` | `0` | `1` |
| `ro.vendor.alc.voltbl_id.se_high` | `kVolTblIcx1298CewHpSe` | `kVolTblIcx1298HpSeGainHigh` |
| `ro.vendor.alc.voltbl_id.se_low` | `kVolTblIcx1298CewHpSe` | `kVolTblIcx1298HpSeGainLow` |
| `ro.vendor.alc.voltbl_id.btl_high` | `kVolTblIcx1298CewHpBtl` | `kVolTblIcx1298HpBtlGainHigh` |
| `ro.vendor.alc.voltbl_id.btl_low` | `kVolTblIcx1298CewHpBtl` | `kVolTblIcx1298HpBtlGainLow` |
| `ro.volume.gain.se` | `0` | `1` |
| `ro.volume.gain.btl` | `0` | `1` |

**Deliberately not changed:** `ro.product.destination` (`03010000` = CEW),
`ro.user.destination`, `ro.safe_volume.default`, the `ro.vendor.eq.voltbl_id.*`
selectors, and anything related to identity (serial, model, product code).

Side effect worth knowing: with `ro.app.highgain.mode = 1` the **High Gain
option appears in Settings** on units where it was absent.

### Two practical gotchas

1. **String fields are fixed length.** The volume-table IDs are 256-byte
   fields. Writing a 26-character value is silently rejected by a length check
   inside the vendor library — `set()` returns without error and the value does
   not change. Always pad to the field's current length and verify by reading
   back. This cost a lot of time to notice.
2. **Integer fields are little-endian.** `1` is the bytes `01 00 00 00`.

---

## 5. What did not work (negative results)

Recorded so nobody repeats them:

* `IProperties` was initially assumed read-only. It is not — it has a `set`.
* `setGain()` on the exported `IzmAudioManager` service: sets the mixer, no
  audible effect on CEW firmware (see section 2).
* `setVolume()` / `adjustVolume()` are clamped to 0..120 in the service; no
  way to exceed the range. Values above 120 collapse to a single write of 120.
* Repointing the `alc.voltbl_id.*` selectors alone changed nothing audible.
  The effect processor's `ResolveConfig` kept resolving to
  `kVolTblIcx1298CewHp*`, because it keys off destination + output + gain, not
  off those NVP fields.
* `ro.app.highgain.mode = 1` alone: exposes the UI option, does not change
  loudness by itself.
* `ro.volume.gain.se/.btl = 1` alone: no audible change.
* Reading `/dev/icx_nvp/*`, `/proc/icx_audio_cxd3778gf_data` and
  `/vendor/usr/share/audio_dac/*` directly: denied from shell and from app
  domains; they are the `hw_properties` domain's business.
* `nvpflag` (visible in `/vendor/bin`) only manages boot flags
  (`bmd`, `prk`, `tst`, `gty`, `sid`, `mso`, `nvr`, `ins`) — it has no
  destination or sound-pressure zone, and its files are not executable by
  shell anyway.
* Bootloader route: `ro.oem_unlock_supported=1` but `fastboot flashing
  get_unlock_ability` returned `0` and `secure:yes`, so a patched boot image
  was not a realistic path. Firmware `.UPG` is encrypted and Sony-signed.
* The older-Walkman destination workflow described by
  [Tellementnomade](https://forum.tellementnomade.org/viewtopic.php?t=15978)
  is not a validated method for this Android M2 profile. This project did not
  use that tool for its observed write path.

---

## 6. Verification and honest expectations

Objective checks available after a reboot:

```bash
adb shell getprop vendor.safe_volume.enabled    # 00000000 = off, 01000000 = EU clamp on
adb shell getprop vendor.destination            # unchanged: 03010000
```

The DAC's log output (`dacdat`) is not captured in logcat, so the loaded table
cannot be confirmed by log. The property above is the input that boot script
receives, which is why it is the check we rely on.

The target field values can be written again when the current state satisfies
the payload guards. Do not use a repeat `Apply` as a harmless confirmation:
`Apply` attempts persistent NVRAM writes and cleanup of a temporary global
setting. Use `status` for a property-only check and a separately assessed
privileged `read` for all eight values. The packaged 0.2.3 implementation
remains untested on physical hardware.

**Magnitude: not established.** The two shipped output tables differ in 3202 of
15738 bytes. That is a byte-diff, not an attenuation measurement: converting it
to decibels requires decoding the table format, which has not been done, and no
electrical or acoustic measurement has been made. The honest statement is
"something changed in the calibration data, weighted towards the upper volume
range", not "3.2 dB louder". Earlier revisions of this document quoted ~3.2 dB;
that figure was an unsupported inference and has been removed.

**What is observed vs. what is interpreted.** For the original manual run,
the author reports that eight field values were written and read back equal
on the tested unit. This is not a hardware result for the packaged 0.2.3 tool. Interpreted: that the
boot script then loads the non-CEU table, because `vendor.safe_volume.enabled`
reads `00000000`. Not established: the minimum field set required, whether the
High Gain switch becomes audible, and the size of any loudness change.
Listening impressions are just that — impressions, not measurements.

Be careful with your ears while testing: the change applies at high volume.

---

## 7. Open questions

* Which combination is strictly necessary is not proven. Setting
  `ro.safe_volume.enabled = 0` produced the property flip and is the most
  likely single cause; the gain-table selectors were set in the same session.
  Anyone with a spare unit could bisect this properly.
* The `ro.product.destination` encoding was never decoded (`03010000` = CEW).
  Changing the destination would make Sony's own logic pick the non-EU
  configuration consistently, but the valid codes are unknown and writing a
  wrong region can affect locale/radio behaviour — so it was left alone.
* Whether a firmware update rewrites these NVP fields is untested.

