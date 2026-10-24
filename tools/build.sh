#!/usr/bin/env bash
# Build and sign the nvptool APK.
#
# Requires: JDK (javac/keytool), Android SDK build-tools + a platform jar.
# Set ANDROID_HOME (or ANDROID_SDK_ROOT) if it is not auto-detected.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
    for c in "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools "$HOME/Android/Sdk"; do
        [ -d "$c" ] && SDK="$c" && break
    done
fi
[ -n "$SDK" ] || { echo "ERROR: Android SDK not found. Set ANDROID_HOME." >&2; exit 1; }

BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
AJ="$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
[ -n "$BT" ] || { echo "ERROR: no build-tools found in $SDK" >&2; exit 1; }
[ -n "$AJ" ] || { echo "ERROR: no platform android.jar found in $SDK" >&2; exit 1; }

echo "SDK     : $SDK"
echo "build   : $BT"
echo "android : $AJ"

rm -rf build out
mkdir -p build out

echo "== compiling =="
javac -nowarn -source 8 -target 8 -bootclasspath "$AJ" \
      -d build $(find src -name '*.java')

echo "== dexing =="
# d8 8.2.x crashes on synthetic inner classes, so this code avoids them.
"$BT/d8" --min-api 28 --lib "$AJ" --output build $(find build -name '*.class')

echo "== packaging =="
"$BT/aapt" package -f -M src/AndroidManifest.xml -I "$AJ" -F out/base.apk
( cd build && "$BT/aapt" add ../out/base.apk classes.dex >/dev/null )
"$BT/zipalign" -p -f 4 out/base.apk out/nvptool.apk

echo "== signing =="
KS="$HOME/.android/debug.keystore"
if [ ! -f "$KS" ]; then
    mkdir -p "$(dirname "$KS")"
    keytool -genkeypair -v -keystore "$KS" -storepass android -keypass android \
            -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
            -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
    echo "created $KS"
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android out/nvptool.apk

echo
echo "Built: $ROOT/out/nvptool.apk"
echo "Install with:  adb install -r out/nvptool.apk"
