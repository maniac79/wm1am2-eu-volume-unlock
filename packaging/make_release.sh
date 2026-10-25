#!/usr/bin/env bash
# Build the per-OS release archives into dist/ from a verified APK receipt.
#
# Each archive contains the licence, the disclaimer/compatibility notes and a
# SHA-256 manifest of its own contents.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APK="$ROOT/out/nvptool.apk"
RECEIPT="$ROOT/out/build-receipt.json"
COMMON="$ROOT/packaging/common"
ALLOW_DIRTY=0
ALLOW_TEST_KEY=0

for arg in "$@"; do
    case "$arg" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --allow-test-key) ALLOW_TEST_KEY=1 ;;
        *) echo "usage: $0 [--allow-dirty] [--allow-test-key]" >&2; exit 64 ;;
    esac
done

if [ ! -f "$APK" ] || [ ! -f "$RECEIPT" ]; then
    echo "APK/build receipt missing - run ./tools/build.sh for this exact source first." >&2
    exit 1
fi

# This checks the actual APK signature, package/version, source hashes, SDK
# fingerprint and Git state before any old dist/ is removed. Test/local keys and
# dirty trees require explicit flags, so neither can enter an official release
# by accident.
check=(python3 tools/release_receipt.py verify --root "$ROOT" --apk "$APK" --receipt "$RECEIPT")
[ "$ALLOW_DIRTY" -eq 0 ] || check+=(--allow-dirty)
[ "$ALLOW_TEST_KEY" -eq 0 ] || check+=(--allow-test-key)
"${check[@]}"

MODE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["signing_mode"])' "$RECEIPT")
CERT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["apk"]["certificate_sha256"])' "$RECEIPT")
DIRTY=$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1]))["source"]["dirty"]).lower())' "$RECEIPT")
RECEIPT_ELIGIBLE=$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1]))["release_eligible"]).lower())' "$RECEIPT")
case "$MODE" in release|ci|local) ;; *) echo "invalid receipt signing mode" >&2; exit 1;; esac
if [ "$MODE" = release ] && [ "$DIRTY" = false ] &&
   [ "$RECEIPT_ELIGIBLE" = true ] && [ "$ALLOW_DIRTY" -eq 0 ] &&
   [ "$ALLOW_TEST_KEY" -eq 0 ]; then
    suffix=""
    PACKAGE_ELIGIBLE=true
else
    suffix=""
    [ "$MODE" = release ] || suffix="-$MODE"
    if [ "$DIRTY" = true ]; then suffix="$suffix-dirty"; fi
    [ -n "$suffix" ] || suffix="-candidate"
    PACKAGE_ELIGIBLE=false
fi

python3 tools/release_receipt.py package-inputs --root "$ROOT" --apk "$APK" \
    > "$ROOT/out/package-inputs.json"
PKG_HASH=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["files_sha256"])' \
    "$ROOT/out/package-inputs.json")

rm -rf "$DIST"
mkdir -p "$DIST"

# Provenance stamped into every archive so an artifact can be tied to a commit.
COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1)" ]; then
    COMMIT="$COMMIT+dirty"
fi

sha_line() {   # emit "<hash>  <name>" for one file
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | sed "s|  .*/|  |"
    else
        shasum -a 256 "$f" | sed "s|  .*/|  |"
    fi
}

finish() {   # $1 = archive dir; writes SHA256SUMS.txt over the shipped files
    local d="$1"
    (
        cd "$d"
        : > SHA256SUMS.txt
        for f in $(ls -1 | grep -v '^SHA256SUMS.txt$'); do
            [ -f "$f" ] && sha_line "$f" >> SHA256SUMS.txt
        done
    )
}

common_files() {   # $1 = target dir
    local d="$1"
    cp "$ROOT/LICENSE"              "$d/"
    cp "$COMMON/QUICKSTART.txt"     "$d/"
    cp "$APK"                       "$d/"
    cp "$ROOT/out/package-inputs.json" "$d/PACKAGE-INPUTS.json"
    {
        printf 'commit=%s\n' "$COMMIT"
        printf 'tool=%s\n' "$(sed -n 's/.*TOOL_VERSION = "\([^"]*\)".*/\1/p' \
            "$ROOT/src/org/maniac79/nvptool/Profile.java" | head -1)"
        printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'apk_sha256=%s\n' "$(sha_line "$APK" | cut -d' ' -f1)"
        printf 'build_receipt_sha256=%s\n' "$(sha_line "$RECEIPT" | cut -d' ' -f1)"
        printf 'package_inputs_sha256=%s\n' "$PKG_HASH"
        printf 'signing_mode=%s\n' "$MODE"
        printf 'certificate_sha256=%s\n' "$CERT"
        printf 'release_eligible=%s\n' "$PACKAGE_ELIGIBLE"
    } > "$d/SOURCE-COMMIT.txt"
}

# ---------------- macOS ----------------
M="$DIST/wm1am2-nvptool-macos"
mkdir -p "$M"
cp "$ROOT/packaging/macos/START-macos.command" "$M/"
cp "$COMMON/menu.sh"                            "$M/"
cp "$ROOT/tools/nvptool.sh"                     "$M/"
cp "$ROOT/tools/lib.sh"                         "$M/"
common_files "$M"
chmod +x "$M/START-macos.command" "$M/menu.sh" "$M/nvptool.sh" "$M/lib.sh"
finish "$M"

# ---------------- Linux ----------------
L="$DIST/wm1am2-nvptool-linux"
mkdir -p "$L"
cp "$ROOT/packaging/linux/START-linux.sh" "$L/"
cp "$COMMON/menu.sh"                      "$L/"
cp "$ROOT/tools/nvptool.sh"               "$L/"
cp "$ROOT/tools/lib.sh"                   "$L/"
common_files "$L"
chmod +x "$L/START-linux.sh" "$L/menu.sh" "$L/nvptool.sh" "$L/lib.sh"
finish "$L"

# ---------------- Windows ----------------
W="$DIST/wm1am2-nvptool-windows"
mkdir -p "$W"
cp "$ROOT/packaging/windows/START-windows.bat" "$W/"
cp "$ROOT/packaging/windows/menu.ps1"          "$W/"
cp "$ROOT/tools/nvptool.ps1"                   "$W/"
cp "$ROOT/tools/inject.ps1"                    "$W/"
common_files "$W"
finish "$W"

# ---------------- zip ----------------
VER=$(sed -n 's/.*TOOL_VERSION = "\([^"]*\)".*/\1/p' \
    "$ROOT/src/org/maniac79/nvptool/Profile.java" | head -1)
if [ -z "$VER" ]; then
    echo "cannot read TOOL_VERSION from src/org/maniac79/nvptool/Profile.java" >&2
    exit 1
fi

cd "$DIST"
for d in wm1am2-nvptool-macos wm1am2-nvptool-linux wm1am2-nvptool-windows; do
    # Versioned archive names: two downloads can coexist on disk, a stale copy is
    # identifiable, and a checksum in the notes points at exactly one file. The
    # directory inside stays unversioned so the starters' relative paths and the
    # manifest inside are unaffected.
    # Only the clean pinned-key default gets the official basename. Every
    # explicitly relaxed candidate is unmistakable in downloads and metadata.
    out="$d-$VER$suffix.zip"
    rm -f "$d.zip" "$out"
    zip -qr "$out" "$d"
done

echo "Built:"
ls -la "$DIST"/*.zip
echo
echo "SHA-256:"
for z in "$DIST"/*.zip; do sha_line "$z"; done

