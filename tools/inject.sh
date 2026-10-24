#!/usr/bin/env bash
#
# inject.sh - start one of the nvptool classes in a platform_app context.
# macOS / Linux. Needs only `adb` (no Python, no JDK).
#
# Usage:
#   ./tools/inject.sh org.maniac79.nvptool.Read
#   ./tools/inject.sh org.maniac79.nvptool.Apply
#   ./tools/inject.sh org.maniac79.nvptool.Rollback
#
# Override with environment variables if needed:
#   NVPTOOL_PKG, NVPTOOL_UID, NVPTOOL_SEINFO, NVPTOOL_HAL, NVPTOOL_WAIT
#
# See tools/inject.py for the full explanation of why this step exists.
set -uo pipefail

CLASS="${1:-}"
PKG="${NVPTOOL_PKG:-org.maniac79.nvptool}"
RUN_UID="${NVPTOOL_UID:-1000}"
SEINFO="${NVPTOOL_SEINFO:-platform:targetSdkVersion=29:complete}"
HAL="${NVPTOOL_HAL:-/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk}"
WAIT="${NVPTOOL_WAIT:-8}"
TAG="NVPTOOL"
REMOTE="/data/local/tmp/nvptool_payload.txt"
LOCAL="$(mktemp "${TMPDIR:-/tmp}/nvptool_payload.XXXXXX")"

if [ -z "$CLASS" ]; then
    echo "usage: $0 <class>   e.g. $0 org.maniac79.nvptool.Read" >&2
    exit 64
fi

cleanup() {
    adb shell "settings delete global hidden_api_blacklist_exemptions" >/dev/null 2>&1
    adb shell "rm -f $REMOTE" >/dev/null 2>&1
    rm -f "$LOCAL"
}
trap cleanup EXIT

# --- preflight -------------------------------------------------------------
STATE="$(adb get-state 2>/dev/null | tr -d '\r')"
if [ "$STATE" != "device" ]; then
    echo "adb device not ready (state='${STATE:-none}')" >&2
    exit 1
fi
echo "device model: $(adb shell getprop ro.product.model | tr -d '\r')"

APK="$(adb shell pm path "$PKG" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -1)"
if [ -z "$APK" ]; then
    echo "package $PKG is not installed - run: adb install -r out/nvptool.apk" >&2
    exit 1
fi
if ! adb shell "test -r $HAL" >/dev/null 2>&1; then
    echo "cannot read HAL apk at $HAL" >&2
    exit 1
fi

# --- build the zygote payload ---------------------------------------------
CMD="CLASSPATH=$APK:$HAL /system/bin/app_process /system/bin $CLASS #"

# No trailing newline: this must match the payload format exactly, otherwise the
# zygote argument parser sees an extra empty argument.
ZARGS=(
    "--setuid=$RUN_UID"
    "--setgid=$RUN_UID"
    "--setgroups=3003"
    "--runtime-args"
    "--seinfo=$SEINFO"
    "--runtime-flags=1"
    "--nice-name=nvptool"
    "--invoke-with"
    "$CMD"
)
{
    printf 'LClass1;->method1(\n%d\n' "${#ZARGS[@]}"
    printf '%s' "${ZARGS[0]}"
    for ((i = 1; i < ${#ZARGS[@]}; i++)); do
        printf '\n%s' "${ZARGS[i]}"
    done
} > "$LOCAL"

adb push "$LOCAL" "$REMOTE" >/dev/null 2>&1
adb shell "logcat -c" >/dev/null 2>&1
adb shell "am force-stop com.android.settings" >/dev/null 2>&1
adb shell "settings put global hidden_api_blacklist_exemptions \"\$(cat $REMOTE)\"" >/dev/null 2>&1
sleep 1
adb shell "am start -a android.settings.SETTINGS" >/dev/null 2>&1
sleep "$WAIT"

OUT="$(adb shell "logcat -b all -d" 2>/dev/null | grep "$TAG")"

# cleanup runs via trap
if [ -n "$OUT" ]; then
    printf '%s\n' "$OUT"
else
    echo "(no $TAG output - the spawn is flaky, just run the command again)" >&2
    exit 2
fi
