#!/usr/bin/env bash
# Host-layer tests for tools/nvptool.sh + lib.sh using a fake adb.
# No device, no privileged helper, no settings or NVRAM touched.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
FAKEBIN="$ROOT/tests/host/fakebin"
PASS=0
FAIL=0
FAILED=""

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED
  - $1"; }

expect_has()   { if printf '%s' "$3" | grep -qF -- "$2"; then ok; else bad "$1 (missing: $2)"; fi; }
expect_hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 (unexpected: $2)"; else ok; fi; }
expect_rc()    { if [ "$3" = "$2" ]; then ok; else bad "$1 (rc=$3 want $2)"; fi; }
expect_rcnz()  { if [ "${2:-0}" != "0" ]; then ok; else bad "$1 (expected non-zero rc)"; fi; }

newenv() {
    T=$(mktemp -d "${TMPDIR:-/tmp}/nvptest.XXXXXX")
    export FAKE_STATE_DIR="$T/state"
    export NVPTOOL_BACKUP_DIR="$T/backups"
    export TMPDIR="$T/tmp"
    mkdir -p "$FAKE_STATE_DIR" "$TMPDIR"
    export NVPTOOL_APK="$T/nvptool.apk"
    printf 'trusted-mock-apk\n' > "$NVPTOOL_APK"
    printf 'apk_sha256=%s\n' "$(shasum -a 256 "$NVPTOOL_APK" | cut -d' ' -f1)" > "$T/SOURCE-COMMIT.txt"
    export PATH="$FAKEBIN:$PATH"
    unset FAKE_RESPONSE FAKE_RESPONSE_READ FAKE_RESPONSE_WRITE FAKE_DEVICES FAKE_MODEL FAKE_FP FAKE_PKGVER FAKE_BK_HEX NVPTOOL_SERIAL FAKE_PROFILE FAKE_SETTINGS_RESTORE_FAIL FAKE_SETTINGS_GET_FAIL FAKE_SETTINGS_LIST_FAIL NVPTOOL_ALLOW_NON_BASELINE_RESTORE FAKE_INSTALLED FAKE_INSTALLED_APK FAKE_DUP_LATE FAKE_PID FAKE_PID2 FAKE_NO_CLAIM FAKE_DUP_SKIPPED 2>/dev/null || true
    # The write paths are on a safety hold, so the suites exercise their logic
    # behind the documented bypass. The hold itself is tested on its own.
    export NVPTOOL_ALLOW_UNVALIDATED_WRITE=1
    export NVPTOOL_SETTLE_SECS=0   # keep the suite fast; the double read still happens
}

nv() {   # nv <args...> ; sets OUT and RC
    OUT=$( cd "$ROOT" && ./tools/nvptool.sh "$@" 2>&1 )
    RC=$?
}

echo "== status is genuinely non-mutating =="
newenv; nv status
expect_rc "status rc" 0 "$RC"
expect_has "status shows destination" "destination" "$OUT"
CALLS=$(cat "$FAKE_STATE_DIR/calls.log" 2>/dev/null)
expect_hasnt "status does not install" "pm path" "$CALLS"
expect_hasnt "status does not push"    "push"    "$CALLS"
expect_hasnt "status does not set settings" "settings put" "$CALLS"
expect_hasnt "status does not clear logcat" "logcat -c" "$CALLS"
[ -d "$NVPTOOL_BACKUP_DIR" ] && bad "status created a backup dir" || ok

echo "== device binding =="
newenv; export FAKE_DEVICES="AAA BBB"; nv read
expect_rcnz "multiple devices abort" "$RC"
expect_has "multiple devices explained" "more than one adb device" "$OUT"

newenv; export FAKE_DEVICES="AAA"; export NVPTOOL_SERIAL="ZZZ"; nv read
expect_rcnz "requested serial mismatch aborts" "$RC"

echo "== guards =="
newenv; export FAKE_MODEL="NW-A306"; nv apply
expect_rcnz "wrong model aborts" "$RC"
expect_has "wrong model message" "unsupported model" "$OUT"

newenv; export FAKE_FP="SonyAudio/icx1298_001/icx1298:11/1.09.05/70:user/release-keys"; nv apply
expect_rcnz "unknown firmware aborts" "$RC"
expect_has "unknown firmware message" "unsupported firmware" "$OUT"

newenv; export FAKE_PKGVER="1.0.0"; nv apply
expect_rcnz "stale app version aborts" "$RC"
expect_has "version mismatch message" "does not match 0.2.3" "$OUT"

echo "== read + backup =="
newenv; nv read
expect_rc "read rc" 0 "$RC"
BK=$(ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf 2>/dev/null | head -1)
[ -n "$BK" ] && ok || bad "read did not create baseline.conf"
if [ -n "$BK" ]; then
    expect_has "baseline labelled" "kind=baseline" "$(cat "$BK")"
    LEN=$(sed -n 's/^field\.0\.hex=//p' "$BK" | head -1)
    if [ "${#LEN}" -eq 512 ]; then ok; else bad "field 0 hex is ${#LEN} chars, want 512"; fi
fi

echo "== apply keeps the first baseline =="
newenv; nv apply
expect_rc "apply rc" 0 "$RC"
expect_has "apply reports verified" "verified (wrote" "$OUT"
B1=$(ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf 2>/dev/null | head -1)
H1=$(shasum -a 256 < "$B1" 2>/dev/null | cut -d' ' -f1)
nv apply
B2=$(ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf 2>/dev/null | head -1)
H2=$(shasum -a 256 < "$B2" 2>/dev/null | cut -d' ' -f1)
[ -n "$H1" ] && [ "$H1" = "$H2" ] && ok || bad "repeated apply rewrote baseline.conf"

echo "== result rejection =="
newenv; export FAKE_RESPONSE_WRITE=fatal; nv apply
expect_rcnz "FATAL is not success" "$RC"
expect_has "FATAL surfaced" "FATAL" "$OUT"
expect_hasnt "FATAL no reboot advice" "Reboot for the change" "$OUT"

newenv; export FAKE_RESPONSE_WRITE=incomplete; nv apply
expect_rc "INCOMPLETE rc" 5 "$RC"
expect_has "INCOMPLETE recovery hint" "restore" "$OUT"

newenv; export FAKE_RESPONSE_WRITE=noout; nv apply
expect_rc "timeout rc" 4 "$RC"
expect_has "timeout is unknown" "UNKNOWN" "$OUT"
expect_hasnt "timeout no success claim" "apply OK" "$OUT"

newenv; export FAKE_RESPONSE_WRITE=stale; nv apply
expect_rc "stale result rc" 4 "$RC"
expect_has "stale is unknown" "UNKNOWN" "$OUT"

newenv; export FAKE_RESPONSE_WRITE=malformed; nv apply
expect_rc "malformed rc" 4 "$RC"

newenv; export FAKE_RESPONSE_WRITE=dup; nv apply
expect_rc "duplicate summary rc" 4 "$RC"

newenv; export FAKE_RESPONSE_WRITE=truncated; nv apply
expect_rc "truncated rc" 4 "$RC"

echo "== a failed backup read blocks every write =="
newenv; export FAKE_RESPONSE_READ=fatal; nv apply
expect_rcnz "backup read failure aborts" "$RC"
expect_has "nothing written stated" "NOTHING WRITTEN" "$OUT"
expect_hasnt "no write attempted" "Apply" "$(tail -1 "$FAKE_STATE_DIR/payload.txt" 2>/dev/null)"

echo "== settings preservation =="
newenv; printf 'EXISTING-VALUE' > "$FAKE_STATE_DIR/setting"; nv apply
expect_rc "present setting refused" 12 "$RC"
[ "$(cat "$FAKE_STATE_DIR/setting" 2>/dev/null)" = "EXISTING-VALUE" ] && ok || bad "present setting changed"
expect_hasnt "present setting does not reach payload" "push" "$(cat "$FAKE_STATE_DIR/calls.log")"

newenv; nv apply
[ -f "$FAKE_STATE_DIR/setting" ] && bad "absent setting was recreated" || ok

echo "== restore validation =="
newenv; nv read >/dev/null
BK=$(ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf 2>/dev/null | head -1)
if sed -i '' -e 's/^field\.0\.hex=./field.0.hex=0/' "$BK" 2>/dev/null; then :; else sed -i 's/^field\.0\.hex=./field.0.hex=0/' "$BK"; fi
nv restore
expect_rcnz "corrupt backup rejected" "$RC"

newenv; nv read >/dev/null
BK=$(ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf 2>/dev/null | head -1)
if sed -i '' -e 's/^serial=.*/serial=SOMEOTHERDEVICE/' "$BK" 2>/dev/null; then :; else sed -i 's/^serial=.*/serial=SOMEOTHERDEVICE/' "$BK"; fi
D=$(dirname "$BK")
( cd "$D" && printf '%s  %s\n' "$(shasum -a 256 < baseline.conf | cut -d' ' -f1)" "baseline.conf" > baseline.conf.sha256 )
nv restore
expect_rcnz "wrong-device backup rejected" "$RC"
expect_has "wrong-device explained" "belongs to device" "$OUT"

echo "== restore happy path =="
newenv; nv read >/dev/null; nv restore
expect_rc "restore rc" 0 "$RC"
expect_has "restore reports fields" "field 7" "$OUT"

echo "== paths with spaces =="
newenv; export NVPTOOL_BACKUP_DIR="$T/backups with spaces"; nv read
expect_rc "space path rc" 0 "$RC"
ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf >/dev/null 2>&1 && ok || bad "no backup under path with spaces"

echo "== concurrency lock =="
newenv; mkdir -p "${TMPDIR:-/tmp}/nvptool.lock.SER123"
printf '%s' "$$" > "${TMPDIR:-/tmp}/nvptool.lock.SER123/pid"
nv apply
expect_rcnz "concurrent run blocked" "$RC"
expect_has "lock explained" "another nvptool run is active" "$OUT"
rm -rf "${TMPDIR:-/tmp}/nvptool.lock.SER123"

echo "== already-modified device is never labelled factory =="
newenv; export FAKE_PROFILE=target; nv read
expect_rc "read on modified device" 0 "$RC"
BK=$(ls "$NVPTOOL_BACKUP_DIR"/*/baseline.conf 2>/dev/null | head -1)
if [ -z "$BK" ]; then ok; else bad "modified device produced a baseline.conf"; fi
SNAP=$(ls "$NVPTOOL_BACKUP_DIR"/*/*-snapshot-*.conf 2>/dev/null | head -1)
[ -n "$SNAP" ] && ok || bad "modified device did not record a snapshot"
if [ -n "$SNAP" ]; then
    expect_has "snapshot labelled" "kind=snapshot" "$(cat "$SNAP")"
fi

nv restore
expect_rc "restore without baseline refuses" 20 "$RC"
expect_has "refusal explains snapshot" "not a factory backup" "$OUT"

if [ -n "$SNAP" ]; then
    nv restore "$SNAP"
    expect_rc "explicit snapshot needs consent" 21 "$RC"
fi

echo "== cleanup failure is not success =="
newenv; export FAKE_SETTINGS_RESTORE_FAIL=1; nv apply
expect_rc "cleanup failure rc" 7 "$RC"
expect_hasnt "no success claim on cleanup failure" "apply OK" "$OUT"
expect_has "recovery state stated" "recovery-required" "$OUT"

newenv; export FAKE_SETTINGS_RESTORE_FAIL=1; nv read
expect_rc "read cleanup failure rc" 7 "$RC"

echo "== apply stops before the write phase when the read phase is unclean =="
newenv; : > "$FAKE_STATE_DIR/calls.log"; export FAKE_SETTINGS_RESTORE_FAIL=1; nv apply
expect_rc "aborted apply rc" 7 "$RC"
expect_has "aborted apply reports cleanup" "recovery-required" "$OUT"
expect_hasnt "aborted apply did not claim success" "apply OK" "$OUT"
# One privileged run = the backup read. A second one would be the write.
NINJ=$(grep -c 'settings put global hidden_api_blacklist_exemptions' "$FAKE_STATE_DIR/calls.log" 2>/dev/null || true)
expect_rc "only the backup read ran, no write phase" 1 "$NINJ"
expect_has "the fake setting really was left behind" "NVPTOOL-PAYLOAD" \
    "$(cat "$FAKE_STATE_DIR/setting" 2>/dev/null)"

echo "== restore stops between fields when cleanup fails =="
newenv; nv read
expect_rc "prep read rc" 0 "$RC"
: > "$FAKE_STATE_DIR/calls.log"
export FAKE_SETTINGS_RESTORE_FAIL=1
nv restore
expect_rc "aborted restore rc" 7 "$RC"
expect_hasnt "aborted restore no success claim" "restore OK" "$OUT"
expect_has "aborted restore reports recovery" "recovery-required" "$OUT"
expect_has "aborted restore retains run metadata" "Recovery record:" "$OUT"
# One privileged run after the reset = field 0 only; six more would follow.
NINJ=$(grep -c 'settings put global hidden_api_blacklist_exemptions' "$FAKE_STATE_DIR/calls.log" 2>/dev/null || true)
expect_rc "exactly one field was written" 1 "$NINJ"

echo "== restore-reference cleanup failure is a failure =="
newenv; export FAKE_SETTINGS_RESTORE_FAIL=1; nv restore-reference
expect_rc "restore-reference cleanup rc" 7 "$RC"
expect_hasnt "restore-reference no success claim" "reference profile restored" "$OUT"
expect_hasnt "restore-reference no reboot advice" "Reboot." "$OUT"
expect_has "restore-reference states recovery-required" "recovery-required" "$OUT"
expect_has "restore-reference names the setting" "hidden_api_blacklist_exemptions" "$OUT"
expect_has "reference restore really left the setting dirty" "NVPTOOL-PAYLOAD" \
    "$(cat "$FAKE_STATE_DIR/setting" 2>/dev/null)"

echo "== installed APK identity and explicit installation =="
newenv; export FAKE_INSTALLED=0; nv read
expect_rcnz "missing helper refuses read" "$RC"
expect_has "missing helper explains install" "menu option 7" "$OUT"
expect_hasnt "missing helper never pushes payload" "push" "$(cat "$FAKE_STATE_DIR/calls.log")"
nv install
expect_rc "explicit install succeeds" 0 "$RC"
nv read
expect_rc "read succeeds after install" 0 "$RC"

newenv; printf 'counterfeit-apk\n' > "$T/counterfeit.apk"
export FAKE_INSTALLED_APK="$T/counterfeit.apk"
nv apply
expect_rc "counterfeit helper refuses" 11 "$RC"
expect_has "counterfeit helper explained" "differs from the bundled APK" "$OUT"
expect_hasnt "counterfeit helper cannot reach settings" "settings put" "$(cat "$FAKE_STATE_DIR/calls.log")"

newenv; printf 'tampered' >> "$NVPTOOL_APK"; nv read
expect_rc "modified bundled APK refuses" 11 "$RC"
expect_has "modified bundled APK explained" "does not match SOURCE-COMMIT.txt" "$OUT"
expect_hasnt "modified APK cannot reach settings" "settings put" "$(cat "$FAKE_STATE_DIR/calls.log")"

echo "== settings capture refuses ambiguity before mutation =="
newenv; export FAKE_SETTINGS_LIST_FAIL=1; nv read
expect_rc "settings list failure refuses" 1 "$RC"
expect_hasnt "list failure cannot push" "push" "$(cat "$FAKE_STATE_DIR/calls.log")"
newenv; export FAKE_SETTINGS_GET_FAIL=1; nv read
expect_rc "settings get failure refuses" 1 "$RC"
expect_hasnt "get failure cannot push" "push" "$(cat "$FAKE_STATE_DIR/calls.log")"
newenv; printf 'null' > "$FAKE_STATE_DIR/setting"; nv read
expect_rc "literal null value refuses" 12 "$RC"
expect_hasnt "literal null cannot push" "push" "$(cat "$FAKE_STATE_DIR/calls.log")"

echo "== remote lock, recovery record, and unique payload =="
newenv; : > "$FAKE_STATE_DIR/remote_lock"; nv read
expect_rc "existing device lock refuses" 12 "$RC"
expect_hasnt "existing lock cannot push" "push" "$(cat "$FAKE_STATE_DIR/calls.log")"
newenv; mkdir "$TMPDIR/nvptool.lock.SER123"; printf '999999' > "$TMPDIR/nvptool.lock.SER123/pid"; nv read
expect_rc "stale local lock refuses" 12 "$RC"
[ -f "$TMPDIR/nvptool.lock.SER123/pid" ] && ok || bad "stale local lock was deleted"
newenv; export FAKE_SETTINGS_RESTORE_FAIL=1 FAKE_RESPONSE_READ=fatal; nv read
expect_rc "operation plus cleanup failure prioritises recovery" 7 "$RC"
expect_has "both failures shown" "status=FATAL" "$OUT"
expect_has "recovery reported" "recovery-required" "$OUT"
[ -f "$FAKE_STATE_DIR/remote_lock" ] && ok || bad "device lock lost after cleanup failure"
REC=$(find "$NVPTOOL_BACKUP_DIR" -name 'recovery-*.state' -print -quit)
[ -n "$REC" ] && [ -f "$REC" ] && ok || bad "recovery record missing after cleanup failure"

newenv; nv apply
PUSHES=$(grep ' push ' "$FAKE_STATE_DIR/calls.log" | sed -n 's/.* \(\/data\/local\/tmp\/nvptool-[^ ]*\.txt\)$/\1/p' | sort -u | wc -l | tr -d ' ')
expect_rc "apply uses distinct remote payload paths" 2 "$PUSHES"
ACQUIRES=$(grep -c 'mkdir /data/local/tmp/nvptool.lock' "$FAKE_STATE_DIR/calls.log" || true)
expect_rc "device lock held across apply phases" 1 "$ACQUIRES"
REC_COUNT=$(find "$NVPTOOL_BACKUP_DIR" -name 'recovery-*.state' | wc -l | tr -d ' ')
expect_rc "clean phases leave no recovery records" 0 "$REC_COUNT"

echo "== catchable signal leaves no residue =="
newenv; export FAKE_RESPONSE_READ=noout
./tools/nvptool.sh read > "$T/signal.out" 2>&1 & NV_PID=$!
# Interrupt once the payload has been pushed. The armed window is now
# milliseconds by design (disarm happens right after the trigger), so the signal
# may land before or after the disarm - either way nothing may survive.
for _ in $(seq 1 100); do
    grep -q ' push ' "$FAKE_STATE_DIR/calls.log" 2>/dev/null && break
    sleep 0.05
done
kill -TERM "$NV_PID" 2>/dev/null || true
wait "$NV_PID" 2>/dev/null || true
[ ! -f "$FAKE_STATE_DIR/setting" ] && ok || bad "TERM left temporary setting behind"
[ ! -f "$FAKE_STATE_DIR/remote_lock" ] && ok || bad "TERM left device lock despite clean restore"

echo "== menu.sh delegates and shows the orchestrator output =="
newenv
PKG="$T/pkg menu"
mkdir -p "$PKG"
cp packaging/common/menu.sh "$PKG/"
cp tools/nvptool.sh tools/lib.sh "$PKG/"
chmod +x "$PKG/menu.sh" "$PKG/nvptool.sh"
OUT=$(printf '1\n\n0\n' | ( cd "$PKG" && ./menu.sh ) 2>&1)
RC=$?
expect_rc "menu.sh rc" 0 "$RC"
expect_has "menu.sh shows the status output" "device      :" "$OUT"
expect_has "menu.sh lists the backup restore option" "4) Restore from backup" "$OUT"
expect_hasnt "menu.sh does not claim Windows is read-only" "READ-ONLY for now" "$OUT"

echo "== writes are enabled and the reboot step is stated =="
newenv; nv apply
expect_rc "apply rc" 0 "$RC"
expect_has "apply reports verified fields" "apply OK" "$OUT"
expect_has "apply states the reboot step" "REBOOT REQUIRED" "$OUT"
nv read
expect_has "read states the reboot step" "REBOOT REQUIRED" "$OUT"

echo "== identical read-only duplicates are accepted and flagged =="
newenv; export FAKE_DUP_LATE=1; nv read
expect_rc "identical duplicates accepted" 0 "$RC"
expect_has "read result still reported" "read OK" "$OUT"
expect_has "duplicate count surfaced" "duplicate device execution" "$OUT"
expect_has "reboot required stated" "REBOOT REQUIRED" "$OUT"
: > "$FAKE_STATE_DIR/calls.log"

echo "== a run without the claim record is rejected =="
newenv; export FAKE_NO_CLAIM=1; nv read
expect_rc "missing claim rc" 3 "$RC"
expect_has "missing guard named" "no_guard" "$OUT"
expect_hasnt "missing claim no success" "read OK" "$OUT"

echo "== a claimed-out duplicate is reported, not fatal =="
newenv; export FAKE_DUP_SKIPPED=1; nv read
expect_rc "claimed duplicate rc" 0 "$RC"
expect_has "duplicate is counted" "claimed out" "$OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'Failures:%s\n' "$FAILED"; exit 1; fi
exit 0

