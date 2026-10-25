#!/usr/bin/env bash
# Guard against accidentally publishing a CI-key or stale APK as a release.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
R="$ROOT/out/build-receipt.json"
APK="$ROOT/out/nvptool.apk"
test -f "$R" && test -f "$APK"
MODE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["signing_mode"])' "$R")
FLAGS=()
if [ "${NVPTOOL_TEST_ALLOW_DIRTY:-0}" = 1 ]; then FLAGS+=(--allow-dirty); fi
if [ "$MODE" != release ]; then
    if python3 tools/release_receipt.py verify --root "$ROOT" --apk "$APK" --receipt "$R" \
        > /dev/null 2>&1; then
        echo 'test/local key was accepted for official packaging' >&2; exit 1
    fi
    FLAGS+=(--allow-test-key)
    VER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["apk"]["version_name"])' "$R")
    for os in linux macos windows; do
        test -f "dist/wm1am2-nvptool-$os-$VER-$MODE.zip" || {
            echo "missing visibly marked $MODE archive for $os" >&2; exit 1;
        }
        if [ -e "dist/wm1am2-nvptool-$os-$VER.zip" ]; then
            echo 'test-key archive received an official release basename' >&2; exit 1
        fi
        grep -q "^signing_mode=$MODE$" "dist/wm1am2-nvptool-$os/SOURCE-COMMIT.txt"
        grep -q '^release_eligible=false$' "dist/wm1am2-nvptool-$os/SOURCE-COMMIT.txt"
    done
fi
python3 tools/release_receipt.py verify --root "$ROOT" --apk "$APK" --receipt "$R" ${FLAGS[@]+"${FLAGS[@]}"}
T=$(mktemp -d "${TMPDIR:-/tmp}/nvp-receipt.XXXXXX")
trap 'rm -rf "$T"' EXIT
cp "$APK" "$T/stale.apk"
printf '\000' >> "$T/stale.apk"
if python3 tools/release_receipt.py verify --root "$ROOT" --apk "$T/stale.apk" \
    --receipt "$R" ${FLAGS[@]+"${FLAGS[@]}"} > /dev/null 2>&1; then
    echo 'modified APK was accepted by the build receipt' >&2; exit 1
fi
echo 'PASS: receipt binds APK bytes and rejects a test key for official release'
