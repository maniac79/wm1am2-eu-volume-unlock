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
# Signing identity must stay stable across releases: Android only upgrades an
# installed app when the new APK carries the SAME signing certificate. Rotating
# the key silently would force every existing user to uninstall first.
#
# The keystore is machine-local and MUST NOT be committed or published. It holds
# a private key: treat it as a secret. It lives outside the repository, is never
# copied into dist/ or any release archive, and its password is not stored here.
KS="${NVPTOOL_KEYSTORE:-$HOME/.android/debug.keystore}"
NL_EXPECTED_CERT_SHA256="a934c760f210a385cc0ce0f349a480c8c482ed2c9c3080896d9c6ca800255ec1"
if [ ! -f "$KS" ]; then
    mkdir -p "$(dirname "$KS")"
    keytool -genkeypair -v -keystore "$KS" -storepass android -keypass android \
            -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
            -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
    echo "created $KS"
fi
# Deterministic schemes: minSdkVersion is 28, so every supported platform
# verifies APK Signature Scheme v3 and v1 (JAR) / v2 are unnecessary. They are
# disabled explicitly rather than left to build-tools defaults, which differ
# between versions and would make the output depend on the installed SDK.
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android \
    --v1-signing-enabled false --v2-signing-enabled false --v3-signing-enabled true \
    out/nvptool.apk

# Fail loudly instead of shipping an APK that cannot upgrade an existing install.
got=$("$BT/apksigner" verify --print-certs out/nvptool.apk 2>/dev/null \
        | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -1)
if [ "$got" != "$NL_EXPECTED_CERT_SHA256" ]; then
    echo "ERROR: the signing certificate changed." >&2
    echo "  expected: $NL_EXPECTED_CERT_SHA256" >&2
    echo "  actual:   ${got:-<none>}" >&2
    echo "Publishing this APK would break upgrades for everyone who already has" >&2
    echo "a previous build installed. Restore the pinned keystore, or rotate the" >&2
    echo "certificate deliberately and document the uninstall-first requirement." >&2
    exit 1
fi
echo "certificate: $got (pinned, unchanged)"

echo
echo "Built: $ROOT/out/nvptool.apk"
echo "Install with:  adb install -r out/nvptool.apk"
