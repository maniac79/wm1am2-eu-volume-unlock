#!/usr/bin/env bash
# Build and sign the nvptool APK.
#
# Requires: JDK (javac/keytool), Python 3, Android SDK build-tools + a platform jar.
# Set ANDROID_HOME (or ANDROID_SDK_ROOT) if it is not auto-detected.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required for build provenance." >&2; exit 1; }

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
    for c in "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools "$HOME/Android/Sdk"; do
        [ -d "$c" ] && SDK="$c" && break
    done
fi
[ -n "$SDK" ] || { echo "ERROR: Android SDK not found. Set ANDROID_HOME." >&2; exit 1; }

if [ -n "${NVPTOOL_BUILD_TOOLS_VERSION:-}" ]; then
    BT="$SDK/build-tools/$NVPTOOL_BUILD_TOOLS_VERSION"
else
    BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
fi
if [ -n "${NVPTOOL_PLATFORM_API:-}" ]; then
    AJ="$SDK/platforms/android-$NVPTOOL_PLATFORM_API/android.jar"
else
    AJ="$(ls -d "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
fi
[ -n "$BT" ] || { echo "ERROR: no build-tools found in $SDK" >&2; exit 1; }
[ -n "$AJ" ] || { echo "ERROR: no platform android.jar found in $SDK" >&2; exit 1; }
[ -x "$BT/d8" ] && [ -x "$BT/aapt" ] && [ -x "$BT/zipalign" ] && [ -x "$BT/apksigner" ] || {
    echo "ERROR: incomplete build-tools at $BT" >&2; exit 1;
}
[ -f "$AJ" ] || { echo "ERROR: platform jar missing: $AJ" >&2; exit 1; }

# The maintainer release key is the default and is the only identity eligible
# for an official release. Explicit ci/local mode permits an independent key
# for offline testing or self builds, never as a silent fallback.
SIGNING_MODE="${NVPTOOL_SIGNING_MODE:-release}"
case "$SIGNING_MODE" in
    release|ci|local) ;;
    *) echo "ERROR: NVPTOOL_SIGNING_MODE must be release, ci or local" >&2; exit 1 ;;
esac
KS="${NVPTOOL_KEYSTORE:-$HOME/.nvptool/nvptool-release.jks}"
PASSFILE="${NVPTOOL_KEYSTORE_PASSFILE:-$HOME/.nvptool/keystore.pass}"
ALIAS="${NVPTOOL_KEY_ALIAS:-nvptool}"
NL_EXPECTED_CERT_SHA256="c21c663d2171dcbd8bdc47c5bb5b2103a0fbf7aa349d7e5aebb67123de42c992"
if [ ! -f "$KS" ]; then
    echo "ERROR: no signing keystore at $KS" >&2
    echo "Create or select one explicitly; the build never invents a signing identity." >&2
    exit 1
fi
if [ -n "${NVPTOOL_KEYSTORE_PASS:-}" ]; then
    KS_PASS_ARG='env:NVPTOOL_KEYSTORE_PASS'
elif [ -f "$PASSFILE" ]; then
    KS_PASS_ARG="file:$PASSFILE"
else
    echo "ERROR: no keystore password available (env or passfile)." >&2
    exit 1
fi

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
# installed app when the new APK carries the SAME signing certificate.
#
# This is a dedicated release key, NOT the shared Android debug key that 0.1.0
# through 0.2.1 were signed with. Builds signed with that key cannot be upgraded
# in place; such an install must be removed first (see docs/SIGNING.md). The key
# lives outside the repository, is never copied into dist/, and its password is
# never committed or printed.
#
#   ./tools/init_signing_key.sh     one-time: create key + password file
#
# Rotation is a deliberate act: change NL_EXPECTED_CERT_SHA256 below, bump
# versionCode, announce "uninstall the old helper first", update docs/SIGNING.md.
# Deterministic schemes: minSdkVersion is 28, so every supported platform
# verifies APK Signature Scheme v3 and v1 (JAR) / v2 are unnecessary. They are
# disabled explicitly rather than left to build-tools defaults, which differ
# between versions and would make the output depend on the installed SDK.
"$BT/apksigner" sign --ks "$KS" --ks-key-alias "$ALIAS" --ks-pass "$KS_PASS_ARG" \
    --v1-signing-enabled false --v2-signing-enabled false --v3-signing-enabled true \
    out/nvptool.apk

# Fail loudly instead of shipping an APK that cannot upgrade an existing install.
got=$("$BT/apksigner" verify --verbose --print-certs out/nvptool.apk 2>/dev/null \
        | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -1)
if [ "$SIGNING_MODE" = release ] && [ "$got" != "$NL_EXPECTED_CERT_SHA256" ]; then
    echo "ERROR: the signing certificate changed." >&2
    echo "  expected: $NL_EXPECTED_CERT_SHA256" >&2
    echo "  actual:   ${got:-<none>}" >&2
    echo "Publishing this APK would break upgrades for everyone who already has" >&2
    echo "a previous build installed. Restore the pinned keystore, or rotate the" >&2
    echo "certificate deliberately and document the uninstall-first requirement." >&2
    exit 1
fi
if [ -z "$got" ]; then
    echo "ERROR: no verified signing certificate" >&2
    exit 1
fi
if [ "$SIGNING_MODE" = release ]; then
    echo "certificate: $got (pinned release identity)"
else
    echo "certificate: $got ($SIGNING_MODE identity, NOT eligible for official release)"
fi

python3 tools/release_receipt.py create --root "$ROOT" --apk "$ROOT/out/nvptool.apk" \
    --receipt "$ROOT/out/build-receipt.json" --build-tools "$BT" \
    --platform-jar "$AJ" --signing-mode "$SIGNING_MODE"

# Source-checkout operation uses the same adjacent manifest name as the flat
# release archives. It is regenerated only after the APK and receipt verify.
python3 - "$ROOT/out/build-receipt.json" "$ROOT/out/SOURCE-COMMIT.txt" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
commit = r['source']['commit'] + ('+dirty' if r['source']['dirty'] else '')
with open(sys.argv[2], 'w') as f:
    f.write('commit=' + commit + '\n')
    f.write('tool=' + r['apk']['version_name'] + '\n')
    f.write('apk_sha256=' + r['apk']['sha256'] + '\n')
    f.write('signing_mode=' + r['signing_mode'] + '\n')
    f.write('certificate_sha256=' + r['apk']['certificate_sha256'] + '\n')
    f.write('release_eligible=' + str(r['release_eligible']).lower() + '\n')
PY

echo
echo "Built: $ROOT/out/nvptool.apk"
echo "Receipt: $ROOT/out/build-receipt.json"
echo "Manifest: $ROOT/out/SOURCE-COMMIT.txt"
