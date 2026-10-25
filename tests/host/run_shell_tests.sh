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
    export PATH="$FAKEBIN:$PATH"
    unset FAKE_RESPONSE FAKE_RESPONSE_READ FAKE_RESPONSE_WRITE FAKE_DEVICES FAKE_MODEL FAKE_FP FAKE_PKGVER FAKE_BK_HEX NVPTOOL_SERIAL FAKE_PROFILE FAKE_SETTINGS_RESTORE_FAIL NVPTOOL_ALLOW_NON_BASELINE_RESTORE 2>/dev/null || true
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
expect_has "version mismatch message" "does not match tool version" "$OUT"

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
[ "$(cat "$FAKE_STATE_DIR/setting" 2>/dev/null)" = "EXISTING-VALUE" ] && ok || bad "existing setting not restored"

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

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'Failures:%s\n' "$FAILED"; exit 1; fi
exit 0

