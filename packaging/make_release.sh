#!/usr/bin/env bash
# Build the per-OS release archives into dist/.
#
# Each archive contains the licence, the disclaimer/compatibility notes and a
# SHA-256 manifest of its own contents.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APK="$ROOT/out/nvptool.apk"
COMMON="$ROOT/packaging/common"

if [ ! -f "$APK" ]; then
    echo "out/nvptool.apk is missing - run ./tools/build.sh first." >&2
    exit 1
fi

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
    {
        printf 'commit=%s\n' "$COMMIT"
        printf 'tool=%s\n' "$(sed -n 's/.*TOOL_VERSION = "\([^"]*\)".*/\1/p' \
            "$ROOT/src/org/maniac79/nvptool/Profile.java" | head -1)"
        printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'apk_sha256=%s\n' "$(sha_line "$APK" | cut -d' ' -f1)"
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
cp "$ROOT/tools/inject.ps1"                    "$W/"
common_files "$W"
finish "$W"

# ---------------- zip ----------------
cd "$DIST"
for d in wm1am2-nvptool-macos wm1am2-nvptool-linux wm1am2-nvptool-windows; do
    rm -f "$d.zip"
    zip -qr "$d.zip" "$d"
done

echo "Built:"
ls -la "$DIST"/*.zip
echo
echo "SHA-256:"
for z in "$DIST"/*.zip; do sha_line "$z"; done

