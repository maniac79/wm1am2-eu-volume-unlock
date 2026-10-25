# Security note: unauthenticated NVRAM write via a vendor HAL

This file documents the access model that made the volume-cap change possible.
It is included because anyone relying on this tool should understand exactly
what it depends on, and because the design is worth knowing about if you are
assessing the platform.

---

## Summary

The vendor HAL `izm.android.properties` exposes a generic NVRAM read/write
interface (`get` / `set`, keyed by property name) with **no caller
authorisation other than SELinux**. Any process running in the `platform_app`,
`priv_app` or `system_app` domain can therefore read and write factory NVRAM.

## Affected component

```
service    izm.android.properties@1.0::IProperties  (HIDL, instance "default")
process    izm.android.properties@1.0-service
SELinux    u:r:hw_properties:s0
interface  get(string key, vec<uint8_t> buf) -> vec<uint8_t>   (transaction 1)
           set(string key, vec<uint8_t> value)                 (transaction 2)
```

`set()` is implemented by a vendor library that provides `nvp_open`,
`nvp_read`, `nvp_write`, and it ultimately opens `/dev/icx_nvp/NNN` — one
character device per NVP field.

## Root cause

Two issues combine:

1. **No permission on the HAL method.** There is no `android:permission`
   equivalent on the interface and no `permission` check in the service; the
   only gate is SELinux.
2. **The SELinux gate is too broad for a general-purpose writer.** The
   hwservice is labelled `properties_hwservice` and is reachable by
   `platform_app`, `priv_app` and `system_app`:

   ```
   (allow platform_app_30_0 properties_hwservice (hwservice_manager (find)))
   (allow priv_app_30_0     properties_hwservice (hwservice_manager (find)))
   (allow system_app_30_0   properties_hwservice (hwservice_manager (find)))
   ```

   Meanwhile the device node itself is correctly locked down — only the HAL's
   own domain may touch it:

   ```
   (allow hw_properties nvp_chr_device (chr_file (ioctl read write ...)))
   (allow hw_properties nvp_device     (blk_file (ioctl read write ...)))
   ```

   So the node protection is bypassed entirely by handing a generic writer to
   every privileged app on the system.

## Impact

### What was actually demonstrated

On the tested unit, from a process spawned as uid 1000 with
`seinfo=platform:targetSdkVersion=29:complete` (SELinux domain `platform_app`):

* `get()` returned the raw bytes of the eight audio fields used by this tool;
* `set()` changed those fields, and a subsequent `get()` returned the new bytes;
* writes survived a reboot.

That is the entire demonstrated surface. It is enough to justify reporting the
design, and not enough to characterise the full blast radius.

### What is inferred, not demonstrated

The interface is generic (any key the vendor table contains) and the property
list we extracted names identity and region fields such as
`ro.product.serial_number`, `ro.product.model_id` and `ro.product.destination`.
It follows that those are *reachable in principle*, but **no identity field was
written** and no attempt was made to do so. Treat that as an assessment, not a
finding.

### Access model — be precise

SELinux is an access-control mechanism, not a permission system. The policy text
grants `hwservice_manager find` on `properties_hwservice` to `platform_app`,
`priv_app` and `system_app`, and grants the device node itself only to
`hw_properties`. Reading policy is not the same as testing every domain, and
testing one uid proves nothing about "any app": an ordinary sideloaded app runs
as `untrusted_app` and was **not** shown to be able to reach the HAL.

No claim is made here about battery life, third-party applications, or any other
behaviour; nothing of that kind was measured.


## Tool boundary (source review of 0.2.5; released v0.2.6 shares it)

The host checks the exact supported model/build before privileged work. It
compares the installed helper APK bytes, pulled from the device, with the
bundled APK hash, and requires both successful `settings list` and `settings
get` queries to establish that `hidden_api_blacklist_exemptions` is absent.
Any present value is refused without modification, including an empty or
literal `null` value. A global setting query error also stops before mutation.
The temporary setting, payload file and device-wide lock require verified
cleanup. If cleanup cannot be confirmed, the host reports a recovery state
and retains a protected local record and device lock for inspection; it does
not blindly retry or delete an unknown pre-existing setting.

These are source-level controls, not an independent test of the Sony device.
The original manual method reached the vendor HAL on the author's unit. With
0.2.5 the packaged macOS tool was run on that unit for `read`, `apply`
(8/8 written), `restore` and `restore-reference`. A separate 0.2.6 run of
`apply` on the already-patched unit reported `wrote 0` and is not an
eight-write result. The Windows and Linux tools have not been run on a
Walkman, nothing here is a second-unit result, and the unreleased
`fix/0.2.6-review` branch has no hardware evidence.
An eight-field NVRAM operation is not atomic, and the normal restore code
intentionally rejects certain unexpected current values. No claim is made
that every damaged state can be recovered by this tool.

## What was not tested

To keep this honest: no attempt was made to write identity fields, no attempt
was made to test whether a wrong value bricks the device, and only audio fields
were modified. The impact section is an assessment from the exposed key set,
not from experiment.

## Suggested remediation

1. Require a signature-level permission (or a dedicated system UID check) on
   `IProperties`, and restrict `set()` to the specific service that needs it.
2. Split the interface: a narrow, read-only property HAL for general clients,
   and a separate writer restricted to the audio/calibration service.
3. Never expose identity fields (`serial_number`, `model_id`, `product_code`,
   `destination`) through a generic key/value writer.
4. Narrow the `properties_hwservice` `find` rules so `properties` is not
   reachable by every `platform_app` / `priv_app` / `system_app`.
5. Add a length- and range-validating wrapper on NVP writes, so a wrong value
   is rejected instead of silently ignored.
