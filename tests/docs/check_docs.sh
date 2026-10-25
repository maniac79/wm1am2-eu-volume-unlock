#!/usr/bin/env bash
# Documentation consistency checks. No device, no build, no network.
#
# These guard the failure mode that produced the stale v0.2.0 QUICKSTART: prose
# drifting away from the menus and the code it documents.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

PASS=0
FAIL=0
FAILED=""
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED
  - $1"; }

# Menu option lines, normalised so indentation and column padding do not matter.
# Each source is parsed with its own syntax so that `case`/`switch` branches
# (which also look like "3) something") cannot be mistaken for the menu itself.
norm() { sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }
opts_sh()  { sed -nE 's/^[[:space:]]*echo "[[:space:]]*([0-7]\) [A-Za-z][^"]*)".*/\1/p' "$1" 2>/dev/null | norm | sort -u; }
opts_ps()  { sed -nE "s/^[[:space:]]*Write-Host '[[:space:]]*([0-7]\) [A-Za-z][^']*)'.*/\1/p" "$1" 2>/dev/null | norm | sort -u; }
opts_doc() { sed -nE 's/^[[:space:]]*([0-7]\) [A-Za-z][^"]*)$/\1/p' "$1" 2>/dev/null | norm | sort -u; }

MENU_SH=packaging/common/menu.sh
MENU_PS=packaging/windows/menu.ps1
QS=packaging/common/QUICKSTART.txt
README=README.md

echo "== menu options match between bash menu, PowerShell menu, QUICKSTART, README =="
if [ ! -f "$MENU_SH" ]; then
    bad "missing $MENU_SH"
else
    OPTS=$(opts_sh "$MENU_SH")
    COUNT=$(printf '%s\n' "$OPTS" | grep -c ') ' || true)
    if [ "$COUNT" -ge 8 ]; then ok; else bad "menu.sh exposes only $COUNT options"; fi
    for pair in "$MENU_PS:ps" "$QS:doc" "$README:doc"; do
        f=${pair%:*}; kind=${pair##*:}
        if [ ! -f "$f" ]; then bad "missing $f"; continue; fi
        if [ "$kind" = "ps" ]; then OTHER=$(opts_ps "$f"); else OTHER=$(opts_doc "$f"); fi
        MISSING=$(comm -23 <(printf '%s\n' "$OPTS") <(printf '%s\n' "$OTHER"))
        if [ -z "$MISSING" ]; then
            ok
        else
            bad "$f is missing menu options: $(printf '%s' "$MISSING" | tr '\n' ';')"
        fi
    done
fi

echo "== AUDIT: the menu must distinguish restore, apply and the advanced path =="
if opts_sh "$MENU_SH" | grep -q '^3) Apply'; then ok; else bad "menu option 3 is not an apply"; fi
if opts_sh "$MENU_SH" | grep -q '^4) Restore from backup'; then ok; else bad "menu option 4 is not a backup restore"; fi
if opts_sh "$MENU_SH" | grep -q '^7) Install'; then ok; else bad "menu option 7 does not offer explicit helper installation"; fi
if grep -qF 'restore-ref' "$QS" && grep -qiF 'advanced' "$QS"; then
    ok
else
    bad "QUICKSTART does not document restore-ref separately as an advanced path"
fi

echo "== QUICKSTART must not repeat the withdrawn claims =="
if grep -qiE 'read-only for now|READ-ONLY for now|Apply and restore are only available on macOS' "$QS"; then
    bad "QUICKSTART still calls Windows read-only"
else
    ok
fi
if grep -qiE '3 dB|roughly 3 db|approximately 3' "$QS" "$README"; then
    bad "an unmeasured dB figure is still claimed"
else
    ok
fi
if grep -qiE 'undoes everything|option 3 undoes' "$QS"; then
    bad "QUICKSTART still calls option 3 an undo"
else
    ok
fi
if grep -qiE 'Restore factory setting|undoes everything' "$QS"; then
    bad "QUICKSTART still describes the old factory-restore workflow"
else
    ok
fi
if grep -qiE 'menu installs the APK for you|menu offers to install it from nvptool.apk when needed' "$QS" "$README"; then
    bad "documentation still promises implicit helper installation"
else
    ok
fi

echo "== QUICKSTART must carry the validation limits =="
for phrase in 'NOT been run on a Walkman' 'simulated adb' \
              'no exploit, no risk' \
              'A snapshot of an already-modified player is NOT proof of the original EU baseline.'; do
    if grep -qF "$phrase" "$QS"; then ok; else bad "QUICKSTART lacks: $phrase"; fi
done

echo "== README must not reference removed code or the old rollback idea =="
if grep -qF 'Rollback.java' "$README"; then bad "README still references Rollback.java"; else ok; fi
if grep -qE 'Run `Rollback`|run `Rollback`' "$README"; then bad "README still says 'Run Rollback'"; else ok; fi
if [ -e src/org/maniac79/nvptool/Rollback.java ]; then bad "Rollback.java exists again"; else ok; fi

echo "== version metadata is consistent across every source =="
V_PROFILE=$(sed -n 's/.*TOOL_VERSION *= *"\([^"]*\)".*/\1/p' src/org/maniac79/nvptool/Profile.java | head -1)
V_MANIFEST=$(sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' src/AndroidManifest.xml | head -1)
V_CODE=$(sed -n 's/.*android:versionCode="\([^"]*\)".*/\1/p' src/AndroidManifest.xml | head -1)
V_LIB=$(sed -n 's/^NL_TOOL_VERSION="\([^"]*\)".*/\1/p' tools/lib.sh | head -1)
V_PS=$(sed -n "s/^\$ToolVersion = '\([^']*\)'.*/\1/p" tools/nvptool.ps1 | head -1)
V_ADB=$(sed -n 's/^PKGVER="\${FAKE_PKGVER:-\([^}]*\)}".*/\1/p' tests/host/fakebin/adb | head -1)
echo "  Profile=$V_PROFILE manifest=$V_MANIFEST code=$V_CODE lib=$V_LIB ps1=$V_PS fakeadb=$V_ADB"
for pair in "manifest:$V_MANIFEST" "lib:$V_LIB" "ps1:$V_PS" "fakeadb:$V_ADB"; do
    name=${pair%%:*}; val=${pair#*:}
    if [ "$val" = "$V_PROFILE" ] && [ -n "$val" ]; then ok; else bad "$name version '$val' != Profile '$V_PROFILE'"; fi
done
case "$V_CODE" in ''|*[!0-9]*) bad "versionCode is not numeric ('$V_CODE')" ;; *) ok ;; esac

# Before publication, the README must say explicitly that this source version
# is not a published release; afterwards it must link the matching release.
if grep -qF "releases/tag/v$V_PROFILE" "$README" ||
   grep -qF "This $V_PROFILE source is not a published release yet." "$README"; then
    ok
else
    bad "README neither links v$V_PROFILE nor labels it unpublished"
fi

echo "== archive names carry the current version =="
for os in macos windows linux; do
    name="wm1am2-nvptool-$os-$V_PROFILE.zip"
    if grep -qF "$name" "$README"; then ok; else bad "README does not name $name"; fi
done
if grep -qF 'out="$d-$VER$suffix.zip"' packaging/make_release.sh &&
   grep -qF 'PACKAGE_ELIGIBLE=true' packaging/make_release.sh; then
    ok
else
    bad "make_release.sh does not separate official and candidate archive names"
fi
if grep -qF 'release_receipt.py verify' packaging/make_release.sh &&
   grep -qF 'PACKAGE-INPUTS.json' packaging/make_release.sh; then
    ok
else
    bad "release packaging does not verify a fresh APK receipt and package inputs"
fi

echo "== the signing pin and its documentation agree =="
PIN=$(sed -n 's/^NL_EXPECTED_CERT_SHA256="\([a-f0-9]*\)".*/\1/p' tools/build.sh | head -1)
if [ -n "$PIN" ] && grep -qF "$PIN" docs/SIGNING.md; then
    ok
else
    bad "docs/SIGNING.md does not record the pinned certificate '${PIN}'"
fi
if grep -qF 'a934c760f210a385cc0ce0f349a480c8c482ed2c9c3080896d9c6ca800255ec1' tools/build.sh; then
    bad "build.sh still pins the withdrawn debug-key certificate"
else
    ok
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'Failures:%s\n' "$FAILED"; exit 1; fi
exit 0
