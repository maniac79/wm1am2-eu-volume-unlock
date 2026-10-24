#!/usr/bin/env bash
# Build the per-OS release archives into dist/.
# Run from anywhere: ./packaging/make_release.sh
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

# ---------------- macOS ----------------
M="$DIST/wm1am2-nvptool-macos"
mkdir -p "$M"
cp "$ROOT/packaging/macos/START-macos.command" "$M/"
cp "$COMMON/menu.sh"                            "$M/"
cp "$ROOT/tools/inject.sh"                      "$M/"
cp "$COMMON/QUICKSTART.txt"                     "$M/"
cp "$APK"                                       "$M/"
chmod +x "$M/START-macos.command" "$M/menu.sh" "$M/inject.sh"

# ---------------- Linux ----------------
L="$DIST/wm1am2-nvptool-linux"
mkdir -p "$L"
cp "$ROOT/packaging/linux/START-linux.sh" "$L/"
cp "$COMMON/menu.sh"                      "$L/"
cp "$ROOT/tools/inject.sh"                "$L/"
cp "$COMMON/QUICKSTART.txt"               "$L/"
cp "$APK"                                 "$L/"
chmod +x "$L/START-linux.sh" "$L/menu.sh" "$L/inject.sh"

# ---------------- Windows ----------------
W="$DIST/wm1am2-nvptool-windows"
mkdir -p "$W"
cp "$ROOT/packaging/windows/START-windows.bat" "$W/"
cp "$ROOT/packaging/windows/menu.ps1"          "$W/"
cp "$ROOT/tools/inject.ps1"                    "$W/"
cp "$COMMON/QUICKSTART.txt"                    "$W/"
cp "$APK"                                      "$W/"

# ---------------- zip ----------------
cd "$DIST"
for d in wm1am2-nvptool-macos wm1am2-nvptool-linux wm1am2-nvptool-windows; do
    rm -f "$d.zip"
    zip -qr "$d.zip" "$d"
done

echo "Built in $DIST:"
ls -la "$DIST"/*.zip
echo
echo "SHA-256:"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$DIST"/*.zip
else
    sha256sum "$DIST"/*.zip
fi
