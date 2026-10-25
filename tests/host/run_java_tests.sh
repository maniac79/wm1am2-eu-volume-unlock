#!/usr/bin/env bash
# Host-side tests for the device-side Java logic, using Android stubs and a mock HAL.
# No device, no adb, no NVP writes.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
OUT="$ROOT/tests/host/build"

rm -rf "$OUT"
mkdir -p "$OUT"

SRC=$(find src tests/host/stubs tests/host/mock tests/host/driver -name '*.java')
javac -nowarn -d "$OUT" $SRC 2>&1 || { echo "COMPILE FAILED"; exit 1; }

CP="$OUT"
# The payload takes an exclusive claim before touching the HAL. On the host that
# needs a writable directory, otherwise every run correctly refuses.
export NVPTOOL_CLAIM_DIR="${TMPDIR:-/tmp}/nvptool-java-claims.$$"
export NVPTOOL_LINGER_MS=0   # no need to wait on the host: there is no AMS here
mkdir -p "$NVPTOOL_CLAIM_DIR"
trap 'rm -rf "$NVPTOOL_CLAIM_DIR"' EXIT
PASS=0
FAIL=0
FAILED=""

t() {  # t <name> <expected-substring> <actual-output>
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED="$FAILED
  - $1 (missing: $2)"
    fi
}

run() {  # run <setup> <op> [args]
    java -cp "$CP" Driver "$@" 2>&1
    echo "RC=$?"
}

run_model() {  # run with overridden Build fields
    local model="$1" fp="$2"; shift 2
    java -Dnvptool.test.model="$model" -Dnvptool.test.fingerprint="$fp" -cp "$CP" Driver "$@" 2>&1
    echo "RC=$?"
}

echo "== environment guards =="
O=$(run_model "NW-A306" "SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys" factory apply R1)
t "wrong model refuses"      "reason=unsupported_model"    "$O"
t "wrong model zero writes"  "writes=0"                    "$O"

O=$(run_model "NW-WM1AM2" "SonyAudio/icx1298_001/icx1298:11/1.09.05/70:user/release-keys" factory apply R2)
t "wrong firmware refuses"   "reason=unsupported_firmware" "$O"
t "wrong firmware no write"  "writes=0"                    "$O"

O=$(run factory read R3)
t "read ok"                  "status=OK"                   "$O"
t "read emits 8 fields"      "ev=field idx=7"              "$O"

O=$(run "factory,short:0" read R4)
t "field length refused"     "reason=field_length_0"       "$O"

echo "== apply =="
O=$(run factory apply R5 @DIGEST)
t "apply ok"                 "status=OK"                   "$O"
t "apply writes 8"           "written=8"                   "$O"
t "apply verified 8"         "verified=8"                  "$O"
t "apply effective writes"   "writes=8"                    "$O"

O=$(run target apply R6 @DIGEST)
t "re-apply noop"            "reason=already_applied"      "$O"
t "re-apply zero writes"     "writes=0"                    "$O"

O=$(run corrupt:2 apply R7 @DIGEST)
t "unrecognised value"       "reason=unrecognized_value_2" "$O"
t "unrecognised no write"    "writes=0"                    "$O"

O=$(run nohal apply R8)
t "hal unavailable"          "reason=hal_unavailable"      "$O"

O=$(run partial:3 apply R9 @DIGEST)
t "partial state accepted"   "status=OK"                   "$O"
t "partial writes only rest" "written=5"                   "$O"

echo "== a write without a backup digest is refused =="
O=$(run factory apply R20)
t "digest is mandatory"     "reason=missing_state_digest" "$O"
t "no digest, no write"     "writes=0"                    "$O"

O=$(run factory apply R21 not-a-digest)
t "bad digest refused"      "reason=missing_state_digest" "$O"
t "bad digest, no write"    "writes=0"                    "$O"

echo "== digest binding =="
O=$(run factory apply R10 0000000000000000000000000000000000000000000000000000000000000000)
t "digest mismatch aborts"   "reason=state_changed_since_backup" "$O"
t "digest mismatch no write" "writes=0"                    "$O"

echo "== partial write handling =="
O=$(run "factory,failset:2" apply R11 @DIGEST)
t "stops on write failure"   "reason=write_failed_2"       "$O"
t "status incomplete"        "status=INCOMPLETE"           "$O"
t "only earlier fields"      "writes=2"                    "$O"
t "no writes after failure"  "setCalls=3"                  "$O"

O=$(run "factory,ignoreset:2" apply R12 @DIGEST)
t "verify failure detected"  "reason=verify_failed_2"      "$O"
t "verify failure no effect" "writes=2"                    "$O"

echo "== restore (per field, from backup) =="
HEX7=$(printf '01000000')
O=$(run target restore R13 7 "$HEX7")
t "restore field ok"         "status=OK"                   "$O"
t "restore reason"           "reason=restored_7"           "$O"

O=$(run factory restore R14 7 "$HEX7")
t "restore idempotent"       "reason=already_restored"     "$O"
t "restore idempotent no wr" "writes=0"                    "$O"

O=$(run "corrupt:1" restore R15 1 "$(printf '61%.0s' $(seq 1 256))")
t "restore refuses unknown"  "reason=unrecognized_current_1" "$O"
t "restore refuses no write" "writes=0"                    "$O"

O=$(run target restore R16 3 abcdef)
t "restore bad length"       "reason=backup_length_mismatch" "$O"

echo "== reference profile (advanced) =="
O=$(run factory restore_ref R17)
t "token required"           "reason=confirmation_missing"  "$O"
t "token required no write"  "writes=0"                     "$O"

O=$(run target restore_ref R18 CONFIRM_REFERENCE_PROFILE)
t "reference restore ok"     "status=OK"                    "$O"
t "reference restores 8"     "verified=8"                   "$O"

O=$(run corrupt:0 restore_ref R19 CONFIRM_REFERENCE_PROFILE)
t "reference refuses stray"  "reason=unrecognized_value_0"  "$O"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf 'Failures:%s\n' "$FAILED"
    exit 1
fi
exit 0
