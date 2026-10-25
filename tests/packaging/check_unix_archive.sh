#!/usr/bin/env bash
# Smoke the exact downloaded-shaped ZIP with a fake adb. No real adb/device.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
OS="${1:-}"
case "$OS" in linux|macos) ;; *) echo "usage: $0 linux|macos" >&2; exit 64;; esac
VER=$(sed -n 's/.*TOOL_VERSION = "\([^"]*\)".*/\1/p' src/org/maniac79/nvptool/Profile.java | head -1)
VARIANT="${NVPTOOL_ARCHIVE_VARIANT:-official}"
case "$VARIANT" in
    official) SUFFIX="" ;;
    ci|local|dirty|candidate|ci-dirty|local-dirty) SUFFIX="-$VARIANT" ;;
    *) echo "invalid NVPTOOL_ARCHIVE_VARIANT: $VARIANT" >&2; exit 64 ;;
esac
ZIP="$ROOT/dist/wm1am2-nvptool-$OS-$VER$SUFFIX.zip"
[ -f "$ZIP" ] || { echo "missing candidate archive: $ZIP" >&2; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/nvp-archive-$OS.XXXXXX")
trap 'rm -rf "$T"' EXIT
unzip -q "$ZIP" -d "$T"
PKG="$T/wm1am2-nvptool-$OS"

python3 - "$PKG" "$ROOT" "$VARIANT" <<'PY'
import hashlib, json, pathlib, sys
pkg, root = map(pathlib.Path, sys.argv[1:3])
variant = sys.argv[3]
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
lines = (pkg / 'SHA256SUMS.txt').read_text().splitlines()
names = set()
for line in lines:
    value, name = line.split('  ', 1)
    target = pkg / name
    assert target.is_file() and sha(target) == value, name
    names.add(name)
assert names == {p.name for p in pkg.iterdir() if p.is_file()} - {'SHA256SUMS.txt'}
source = dict(line.split('=', 1) for line in (pkg / 'SOURCE-COMMIT.txt').read_text().splitlines())
assert source['apk_sha256'] == sha(pkg / 'nvptool.apk')
assert source['tool'] in (root / 'src/org/maniac79/nvptool/Profile.java').read_text()
assert len(source['certificate_sha256']) == 64
if variant == 'official':
    assert source['signing_mode'] == 'release' and source['release_eligible'] == 'true'
    assert not source['commit'].endswith('+dirty')
else:
    expected_mode = variant.split('-')[0] if variant.startswith(('ci', 'local')) else 'release'
    assert source['signing_mode'] == expected_mode and source['release_eligible'] == 'false'
inputs = json.loads((pkg / 'PACKAGE-INPUTS.json').read_text())
assert inputs['files']['out/nvptool.apk'] == source['apk_sha256']
canonical = json.dumps(inputs['files'], sort_keys=True, separators=(',', ':')).encode()
assert hashlib.sha256(canonical).hexdigest() == inputs['files_sha256']
assert inputs['files_sha256'] == source['package_inputs_sha256']
for name in ('nvptool.apk','LICENSE','QUICKSTART.txt','SOURCE-COMMIT.txt','PACKAGE-INPUTS.json'):
    assert (pkg / name).is_file(), name
print('archive members and SHA256SUMS verified')
PY

# A copied mock under the documented sibling platform-tools location exercises
# resolution with adb absent from PATH. Refuse to continue if this host has a
# real adb in the deliberately restricted PATH.
mkdir -p "$PKG/platform-tools" "$T/state" "$T/backups" "$T/scratch"
cp "$ROOT/tests/host/fakebin/adb" "$PKG/platform-tools/adb"
chmod +x "$PKG/platform-tools/adb"
if PATH=/usr/bin:/bin command -v adb >/dev/null 2>&1; then
    echo "unsafe test host: real adb is in the restricted PATH" >&2
    exit 1
fi
export PATH=/usr/bin:/bin
unset NVPTOOL_ADB || true
export FAKE_STATE_DIR="$T/state" FAKE_INSTALLED=0
export NVPTOOL_BACKUP_DIR="$T/backups" TMPDIR="$T/scratch"

"$PKG/nvptool.sh" status > "$T/status.out" 2>&1
grep -q 'NW-WM1AM2' "$T/status.out"
if grep -q 'pm path\| install ' "$T/state/calls.log"; then
    echo "status unexpectedly inspected/installed the helper" >&2; exit 1
fi
if "$PKG/nvptool.sh" read > "$T/read-before.out" 2>&1; then
    echo "read succeeded without the helper" >&2; exit 1
fi
grep -q 'helper app is not installed' "$T/read-before.out"
if [ -e "$T/state/installed" ]; then
    echo "read implicitly installed the helper" >&2; exit 1
fi

# Option 7 must do nothing when declined. Then the actual shipped menu must
# install only after 'yes' and let a full read verify the installed APK.
printf '7\nno\n0\n' | "$PKG/menu.sh" > "$T/menu-declined.out" 2>&1
if [ -e "$T/state/installed" ] || grep -q ' install -r ' "$T/state/calls.log"; then
    echo "declined menu installation still called adb install" >&2; exit 1
fi
printf '7\nyes\n\n2\n\n0\n' | "$PKG/menu.sh" > "$T/menu-approved.out" 2>&1
test -f "$T/state/installed.apk"
cmp -s "$PKG/nvptool.apk" "$T/state/installed.apk"
grep -q 'read OK' "$T/menu-approved.out"
echo "PASS: $OS ZIP status -> missing helper -> menu decline/yes -> verified read (mock adb)"
