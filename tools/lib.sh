#!/usr/bin/env bash
# Shared host-side helpers: device binding, locking, settings preservation,
# privileged run, strict result parsing, backup and journal handling.
#
# Source this file; do not execute it.

NL_TOOL_VERSION="0.2.3"
NL_TAG="NVPTOOL"
NL_PKG="org.maniac79.nvptool"
NL_HAL="/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk"
NL_MODEL="NW-WM1AM2"
NL_FINGERPRINT="SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys"
NL_SCHEMA="1"

NL_KEYS=(
  "ro.vendor.alc.voltbl_id.se_high"
  "ro.vendor.alc.voltbl_id.se_low"
  "ro.vendor.alc.voltbl_id.btl_high"
  "ro.vendor.alc.voltbl_id.btl_low"
  "ro.app.highgain.mode"
  "ro.volume.gain.se"
  "ro.volume.gain.btl"
  "ro.safe_volume.enabled"
)
NL_LENS=(256 256 256 256 4 4 4 4)

nl_die() { echo "nvptool: $1" >&2; exit "${2:-1}"; }
nl_warn() { echo "nvptool: WARNING: $1" >&2; }

# ---------------------------------------------------------------- run scratch
nl_mktempdir() {
    NL_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nvptool.XXXXXX") || nl_die "cannot create temp dir"
    chmod 700 "$NL_RUN_DIR" 2>/dev/null || true
}

nl_cleanup_local() {
    [ -n "${NL_RUN_DIR:-}" ] && [ -d "${NL_RUN_DIR:-}" ] && rm -rf "$NL_RUN_DIR"
}

# ------------------------------------------------------------- device binding
nl_serial() { printf '%s' "${NL_SERIAL:-}"; }

nl_find_adb() {
    if [ -n "${NL_ADB:-}" ]; then return 0; fi
    if [ -n "${NVPTOOL_ADB:-}" ]; then
        case "$NVPTOOL_ADB" in /*) ;; *) nl_die "NVPTOOL_ADB must be an absolute path" ;; esac
        [ -x "$NVPTOOL_ADB" ] || nl_die "NVPTOOL_ADB is not executable"
        NL_ADB="$NVPTOOL_ADB"
    elif [ -x "$HERE/platform-tools/adb" ]; then
        NL_ADB="$HERE/platform-tools/adb"
    else
        NL_ADB=$(command -v adb 2>/dev/null) || nl_die "adb not found (put platform-tools next to this tool or add adb to PATH)"
    fi
}

nl_adb() { "$NL_ADB" -s "$NL_SERIAL" "$@"; }

nl_select_device() {
    nl_find_adb
    local list n
    list=$("$NL_ADB" devices | awk 'NR>1 && $2=="device" {print $1}') || nl_die "adb devices failed"
    n=$(printf '%s\n' "$list" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        nl_die "no authorised adb device (enable USB debugging and accept the prompt)"
    fi
    if [ "$n" -gt 1 ]; then
        nl_die "more than one adb device is attached; disconnect the others or set NVPTOOL_SERIAL"
    fi
    if [ -n "${NVPTOOL_SERIAL:-}" ] && [ "$NVPTOOL_SERIAL" != "$list" ]; then
        nl_die "attached device $list does not match requested serial $NVPTOOL_SERIAL"
    fi
    NL_SERIAL="$list"
    export NL_SERIAL
}

nl_bind_serial() {
    [ -n "${NL_SERIAL:-}" ] || nl_die "internal: device not selected"
    local now
    now=$("$NL_ADB" devices | awk 'NR>1 && $2=="device" {print $1}') || nl_die "adb devices failed"
    case " $(printf '%s' "$now" | tr '\n' ' ') " in
        *" $NL_SERIAL "*) ;;
        *) nl_die "device $NL_SERIAL disappeared during the operation" ;;
    esac
}

# ----------------------------------------------------------------------- lock
NL_LOCAL_LOCK_HELD=0
nl_lock_acquire() {
    NL_LOCK_DIR="${TMPDIR:-/tmp}/nvptool.lock.${NL_SERIAL}"
    if ! mkdir "$NL_LOCK_DIR" 2>/dev/null; then
        local pid
        pid=$(cat "$NL_LOCK_DIR/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            nl_die "another nvptool run is active for this device (pid $pid)"
        fi
        nl_die "an old local lock exists at $NL_LOCK_DIR (pid ${pid:-unknown}); inspect and remove it manually if safe" 12
    fi
    NL_LOCAL_LOCK_HELD=1
    printf '%s' "$$" > "$NL_LOCK_DIR/pid" || nl_die "cannot record local lock owner"
}

nl_lock_release() {
    if [ "${NL_LOCAL_LOCK_HELD:-0}" = 1 ] && [ -n "${NL_LOCK_DIR:-}" ] &&
       [ "$(cat "$NL_LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$NL_LOCK_DIR"
    fi
    NL_LOCAL_LOCK_HELD=0
    NL_LOCK_DIR=""
}

# The local lock does not coordinate two computers. Keep this atomic lock on the
# device across every privileged phase, including the gap between backup and
# apply or between restore fields. Never remove a lock whose owner is unknown.
NL_REMOTE_LOCK="/data/local/tmp/nvptool.lock"
NL_REMOTE_LOCK_HELD=0
NL_REMOTE_LOCK_OWNER=""

nl_remote_lock_acquire() {
    [ "${NL_REMOTE_LOCK_HELD:-0}" = 1 ] && return 0
    local owner="$1" seen
    if ! nl_adb shell "mkdir $NL_REMOTE_LOCK" >/dev/null 2>&1; then
        seen=$(nl_adb shell "cat $NL_REMOTE_LOCK/owner" 2>/dev/null | tr -d '\r' || true)
        nl_die "device is locked by another or interrupted nvptool run (${seen:-owner unknown}); inspect $NL_REMOTE_LOCK before manual recovery" 12
    fi
    NL_REMOTE_LOCK_HELD=1
    NL_REMOTE_LOCK_OWNER="$owner"
    nl_adb shell "printf '%s\\n' '$owner' > $NL_REMOTE_LOCK/owner" >/dev/null 2>&1 || \
        nl_die "could not record device lock owner; inspect $NL_REMOTE_LOCK" 7
}

nl_remote_lock_release() {
    [ "${NL_REMOTE_LOCK_HELD:-0}" = 1 ] || return 0
    [ "${NL_SETTINGS_TOUCHED:-0}" = 0 ] || return 1
    [ -z "${NL_REMOTE_PAYLOAD:-}" ] || return 1
    local seen
    seen=$(nl_adb shell "cat $NL_REMOTE_LOCK/owner" 2>/dev/null | tr -d '\r') || return 1
    [ "$seen" = "$NL_REMOTE_LOCK_OWNER" ] || return 1
    nl_adb shell "rm -f $NL_REMOTE_LOCK/owner && rmdir $NL_REMOTE_LOCK" >/dev/null 2>&1 || return 1
    NL_REMOTE_LOCK_HELD=0
}

# ------------------------------------------------------------------ preflight
nl_getprop() { nl_adb shell getprop "$1" 2>/dev/null | tr -d '\r'; }

nl_preflight() {
    nl_bind_serial
    local model fp
    model=$(nl_getprop ro.product.model)
    fp=$(nl_getprop ro.build.fingerprint)
    [ "$model" = "$NL_MODEL" ] || nl_die "unsupported model '$model' (expected $NL_MODEL)" 11
    [ "$fp" = "$NL_FINGERPRINT" ] || nl_die "unsupported firmware '$fp'" 11
    NL_MODEL_SEEN="$model"
    NL_FP_SEEN="$fp"
    nl_adb shell "test -r $NL_HAL" >/dev/null 2>&1 || nl_die "HAL apk not readable at $NL_HAL" 11
}

nl_local_apk() {
    if [ -n "${NVPTOOL_APK:-}" ]; then
        case "$NVPTOOL_APK" in /*) ;; *) nl_die "NVPTOOL_APK must be an absolute path" ;; esac
        printf '%s' "$NVPTOOL_APK"
    elif [ -f "$HERE/nvptool.apk" ]; then
        printf '%s' "$HERE/nvptool.apk"
    else
        printf '%s' "$HERE/../out/nvptool.apk"
    fi
}

nl_trusted_apk_hash() {   # $1 = local packaged/build APK
    local manifest="$(dirname "$1")/SOURCE-COMMIT.txt" count want got
    [ -f "$manifest" ] || nl_die "APK provenance file missing: $manifest"
    count=$(grep -c '^apk_sha256=' "$manifest" || true)
    [ "$count" = 1 ] || nl_die "APK provenance must contain exactly one apk_sha256"
    want=$(sed -n 's/^apk_sha256=//p' "$manifest")
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || nl_die "APK provenance hash is malformed"
    got=$(nl_sha256 < "$1") || nl_die "cannot hash bundled APK"
    [ "$got" = "$want" ] || nl_die "bundled APK does not match SOURCE-COMMIT.txt" 11
    printf '%s' "$want"
}

nl_require_apk() {
    local path ver local_apk pulled expected got
    [ -n "${NL_RUN_DIR:-}" ] || nl_die "internal: private run directory missing"
    local_apk=$(nl_local_apk) || nl_die "cannot locate bundled APK"
    [ -f "$local_apk" ] || nl_die "trusted bundled APK not found at $local_apk"
    expected=$(nl_trusted_apk_hash "$local_apk") || nl_die "bundled APK provenance check failed" 11
    path=$(nl_adb shell pm path "$NL_PKG" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -1)
    [ -n "$path" ] || nl_die "helper app is not installed; use menu option 7 or nvptool.sh install"
    [[ "$path" =~ ^/[A-Za-z0-9_./=+~:-]+$ ]] || nl_die "installed helper has an unsafe APK path"
    ver=$(nl_adb shell dumpsys package "$NL_PKG" 2>/dev/null | tr -d '\r' | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1)
    [ "$ver" = "$NL_TOOL_VERSION" ] || nl_die "installed app version '$ver' does not match $NL_TOOL_VERSION; use menu option 7 or nvptool.sh install"
    pulled="$NL_RUN_DIR/installed-${NL_RUN_ID:-check}.apk"
    nl_adb pull "$path" "$pulled" >/dev/null 2>&1 || nl_die "could not read installed helper APK"
    [ -s "$pulled" ] || nl_die "installed helper APK is empty"
    got=$(nl_sha256 < "$pulled") || nl_die "cannot hash installed helper APK"
    [ "$got" = "$expected" ] || nl_die "installed helper APK differs from the bundled APK; refusing privileged run" 11
    NL_VERIFIED_APK_PATH="$path"
}

# ---------------------------------------------------------------- settings
# The "original" value must be captured ONCE per command, before the first
# privileged run. If each phase re-captured, a phase whose cleanup failed would
# launder its own pollution into the next phase's "original" and the run would
# report success with the payload still on the device.
NL_SETTINGS_STATE=""
NL_SETTINGS_TOUCHED=0
NL_SETTINGS_CAPTURED=0
NL_RECOVERY_FILE=""
NL_RECOVERY_FILES=()
NL_CLEANUP_ATTEMPTED=0

nl_settings_capture() {
    nl_settings_assert_absent
    if [ "${NL_SETTINGS_CAPTURED:-0}" = "1" ]; then return 0; fi
    NL_SETTINGS_STATE="absent"
    NL_SETTINGS_CAPTURED=1
    NL_SETTINGS_TOUCHED=0
}

# Re-run before every privileged phase. The first capture remains the command's
# original state; a separate actor changing the key between phases cannot be
# adopted as the new original or overwritten by the next payload.
nl_settings_assert_absent() {
    local listed v
    listed=$(nl_adb shell settings list global 2>/dev/null | tr -d '\r') || \
        nl_die "could not list global settings; refusing before mutation" 1
    if printf '%s\n' "$listed" | grep -q '^hidden_api_blacklist_exemptions='; then
        nl_die "hidden_api_blacklist_exemptions already exists; this release refuses to overwrite a present value" 12
    fi
    v=$(nl_adb shell settings get global hidden_api_blacklist_exemptions 2>/dev/null | tr -d '\r') || \
        nl_die "could not read hidden_api_blacklist_exemptions; refusing before mutation" 1
    [ "$v" = null ] || nl_die "hidden_api_blacklist_exemptions is not verifiably absent; refusing before mutation" 12
}

nl_record_recovery() {
    local run="$1" op="$2" dir file
    dir=$(nl_backup_dir)
    mkdir -p "$dir" || nl_die "cannot create private recovery directory before mutation"
    chmod 700 "$dir" || nl_die "cannot protect private recovery directory"
    file="$dir/recovery-${run}-${op}.state"
    ( umask 077; set -o noclobber; printf 'serial=%s\nrun=%s\noperation=%s\nsetting=%s\nremote_lock=%s\n' \
        "$NL_SERIAL" "$run" "$op" "$NL_SETTINGS_STATE" "$NL_REMOTE_LOCK" > "$file" ) || \
        nl_die "cannot persist original setting before mutation"
    NL_RECOVERY_FILE="$file"
    NL_RECOVERY_FILES+=("$file")
}


nl_settings_restore() {
    if [ "${NL_SETTINGS_TOUCHED:-0}" -eq 0 ]; then
        return 0
    fi
    NL_CLEANUP_ATTEMPTED=1
    [ "${NL_SETTINGS_STATE:-}" = absent ] || return 1
    nl_adb shell settings delete global hidden_api_blacklist_exemptions >/dev/null 2>&1 || return 1
    local after listed
    listed=$(nl_adb shell settings list global 2>/dev/null | tr -d '\r') || return 1
    printf '%s\n' "$listed" | grep -q '^hidden_api_blacklist_exemptions=' && return 1
    after=$(nl_adb shell settings get global hidden_api_blacklist_exemptions 2>/dev/null | tr -d '\r') || return 1
    [ "$after" = null ] || return 1
    NL_SETTINGS_TOUCHED=0
    [ -n "$NL_RECOVERY_FILE" ] && printf 'cleanup=verified_absent\n' >> "$NL_RECOVERY_FILE"
    return 0
}

# ------------------------------------------------------ temporary write hold
# One privileged request can execute MORE THAN ONCE on device: the exemption in
# hidden_api_blacklist_exemptions is consumed by every zygote fork while it is
# armed, and the Settings trigger is retried by ActivityManager. For a read that
# is wasteful; for a write it means an unbounded number of NVRAM operations.
# Until at most one execution per request is proven on hardware, every write
# path stays closed. See docs/ZYGOTE-SINGLE-EXECUTION.md.
nl_require_write_enabled() {
    [ "${NVPTOOL_ALLOW_UNVALIDATED_WRITE:-0}" = "1" ] && return 0
    nl_die "NVRAM writes are disabled in this build.

Reason: one privileged request can run more than once on the device (duplicate
execution through the Zygote exemption), and that is not yet safe for writes.
Reads - 'status' and 'read' - remain available and are unaffected.

This is a deliberate safety hold, not a transient bug. Lifting it requires the
single-shot design in docs/ZYGOTE-SINGLE-EXECUTION.md to be validated on an
Android 11 NW-WM1AM2. Bypassing it is possible only on purpose:
  NVPTOOL_ALLOW_UNVALIDATED_WRITE=1
and it is then entirely at your own risk." 13
}

# --------------------------------------------------------- privileged run
NL_REMOTE_PAYLOAD=""
NL_SETTLE_SECS="${NVPTOOL_SETTLE_SECS:-3}"
NL_REMOTE_FILE_CLEANUP_ATTEMPTED=0
NL_INJECT_RC=1
NL_CLEANUP_OK=1

nl_build_payload() {   # $1 class, $2 run id, remaining = tool args (space free)
    local cls="$1" run="$2" apk="$3"
    shift 3
    local extra=""
    local a
    for a in "$@"; do extra="$extra $a"; done
    local cmd="CLASSPATH=$apk:$NL_HAL /system/bin/app_process /system/bin $cls $run$extra #"
    {
        printf 'LClass1;->method1(\n9\n'
        printf '%s' "--setuid=1000"
        printf '\n%s' "--setgid=1000" "--setgroups=3003" "--runtime-args" \
            "--seinfo=platform:targetSdkVersion=29:complete" "--runtime-flags=1" \
            "--nice-name=nvptool" "--invoke-with" "$cmd"
    } > "$NL_RUN_DIR/payload.txt"
}

nl_inject() {   # nl_inject <class> <op> <runid> [tool args...]
    local cls="$1" op="$2" run="$3"
    shift 3
    NL_RUN_ID="$run"
    nl_remote_lock_acquire "$run"
    nl_require_apk
    local apk="$NL_VERIFIED_APK_PATH"
    NL_REMOTE_PAYLOAD="/data/local/tmp/nvptool-${run}-${op}.txt"
    NL_REMOTE_FILE_CLEANUP_ATTEMPTED=0

    nl_build_payload "$cls" "$run" "$apk" "$@"

    nl_settings_capture
    nl_record_recovery "$run" "$op"
    nl_adb push "$NL_RUN_DIR/payload.txt" "$NL_REMOTE_PAYLOAD" >/dev/null 2>&1 \
        || nl_die "could not push payload (settings untouched)"
    nl_adb shell "chmod 600 $NL_REMOTE_PAYLOAD" >/dev/null 2>&1 || \
        nl_die "could not protect remote payload (settings untouched)"
    NL_SETTINGS_TOUCHED=1
    NL_CLEANUP_ATTEMPTED=0
    nl_adb shell "settings put global hidden_api_blacklist_exemptions \"\$(cat $NL_REMOTE_PAYLOAD)\"" >/dev/null 2>&1 \
        || {
            if nl_settings_restore; then
                nl_die "could not install payload; original setting verified restored"
            else
                nl_die "could not install payload AND could not restore original setting; recovery record: $NL_RECOVERY_FILE" 7
            fi
        }
    nl_adb shell am force-stop com.android.settings >/dev/null 2>&1
    nl_adb shell am start -a android.settings.SETTINGS >/dev/null 2>&1

    # Disarm immediately. The exemption is applied to EVERY zygote fork while it
    # is present, so the arming window must cover one fork, not the whole poll
    # loop. Waiting for a summary first leaves the payload live for seconds, and
    # ActivityManager retries the start in that time: that is where the second
    # execution comes from.
    local file_clean=1 setting_clean=1
    NL_REMOTE_FILE_CLEANUP_ATTEMPTED=1
    nl_settings_restore || setting_clean=0
    nl_adb shell "rm -f $NL_REMOTE_PAYLOAD" >/dev/null 2>&1 || file_clean=0
    [ "$file_clean" = 1 ] && NL_REMOTE_PAYLOAD=""

    # Bounded wait for the first summary, then a settle window, then ONE final
    # read. The snapshot must cover the whole window: a summary that arrives
    # after the host stopped reading is exactly what hid the duplicate execution.
    local i lines
    lines=""
    for i in $(seq 1 20); do
        sleep 1
        lines=$(nl_adb shell "logcat -d -s $NL_TAG:V" 2>/dev/null | tr -d '\r' | grep -F "run=$run " || true)
        if printf '%s' "$lines" | grep -q "ev=summary"; then break; fi
    done
    if [ "${NL_SETTLE_SECS}" -gt 0 ]; then sleep "$NL_SETTLE_SECS"; fi
    lines=$(nl_adb shell "logcat -d -s $NL_TAG:V" 2>/dev/null | tr -d '\r' | grep -F "run=$run " || true)
    printf '%s\n' "$lines" > "$NL_RUN_DIR/result.txt"

    if [ "$file_clean" = 1 ] && [ "$setting_clean" = 1 ]; then
        NL_CLEANUP_OK=1
    else
        NL_CLEANUP_OK=0
    fi

    # Prioritise an unclean device even when the Java operation also failed or
    # timed out. The result is retained so the user sees both failure modes.
    nl_require_cleanup "$op"

    if printf '%s' "$lines" | grep -q "ev=summary"; then
        NL_INJECT_RC=0
    else
        NL_INJECT_RC=3    # timeout / no summary => outcome unknown
    fi
    printf '%s\n' "$lines"
    return 0
}

# ------------------------------------------------------------ strict parsing
NL_PARSE_ERR=""
NL_STATUS=""
NL_WRITTEN=""
NL_VERIFIED=""
NL_TOTAL=""
NL_REASON=""
NL_FIELDS=0

nl_parse() {   # nl_parse <op> <runid>   (reads $NL_RUN_DIR/result.txt)
    local op="$1" run="$2" f="$NL_RUN_DIR/result.txt"
    NL_PARSE_ERR=""; NL_STATUS=""; NL_WRITTEN=""; NL_VERIFIED=""; NL_TOTAL=""
    NL_REASON=""; NL_FIELDS=0

    [ -s "$f" ] || { NL_PARSE_ERR="no_output"; return 3; }

    local begins summaries bline sline line
    begins=$(grep -c "ev=begin" "$f" || true)
    summaries=$(grep -c "ev=summary" "$f" || true)
    [ "$begins" = "1" ] || { NL_PARSE_ERR="bad_begin_count"; return 3; }
    [ "$summaries" = "1" ] || { NL_PARSE_ERR="bad_summary_count"; return 3; }

    bline=$(grep -n "ev=begin" "$f" | head -1 | cut -d: -f1)
    sline=$(grep -n "ev=summary" "$f" | head -1 | cut -d: -f1)
    [ "$sline" -gt "$bline" ] || { NL_PARSE_ERR="summary_before_begin"; return 3; }

    line=$(sed -n "${sline}p" "$f")
    case "$line" in *"run=$run "*|*"run=$run") ;; *) NL_PARSE_ERR="run_mismatch"; return 3 ;; esac
    case "$line" in *"op=$op"*) ;; *) NL_PARSE_ERR="op_mismatch"; return 3 ;; esac

    # Reply association: the summary must belong to the same execution as the
    # begin. Two executions produce two begins (rejected above); a summary that
    # does not match its begin means records from different processes were
    # mixed into one snapshot.
    local beginline bpid spid
    beginline=$(sed -n "${bline}p" "$f")
    bpid=$(printf '%s' "$beginline" | tr ' ' '\n' | sed -n 's/^pid=//p' | head -1)
    spid=$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^pid=//p' | head -1)
    [ -n "$bpid" ] || { NL_PARSE_ERR="begin_without_pid"; return 3; }
    [ -n "$spid" ] || { NL_PARSE_ERR="summary_without_pid"; return 3; }
    [ "$bpid" = "$spid" ] || { NL_PARSE_ERR="pid_mismatch"; return 3; }

    NL_STATUS=$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^status=//p' | head -1)
    NL_WRITTEN=$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^written=//p' | head -1)
    NL_VERIFIED=$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^verified=//p' | head -1)
    NL_TOTAL=$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^total=//p' | head -1)
    NL_REASON=$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^reason=//p' | head -1)
    NL_FIELDS=$(grep -c "ev=field" "$f" || true)

    case "$NL_STATUS" in
        OK|ABORT|REFUSED|INCOMPLETE|FATAL) ;;
        *) NL_PARSE_ERR="bad_status"; return 3 ;;
    esac

    if [ "$op" = "read" ]; then
        [ "$NL_FIELDS" = "8" ] || { NL_PARSE_ERR="field_count_$NL_FIELDS"; return 3; }
        local i
        for i in 0 1 2 3 4 5 6 7; do
            grep -q "ev=field idx=$i " "$f" || { NL_PARSE_ERR="missing_field_$i"; return 3; }
        done
    fi
    return 0
}

nl_success() { [ "${NL_STATUS:-}" = "OK" ]; }

# --------------------------------------------------------------- hashing
nl_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    else openssl dgst -sha256 -r | cut -d' ' -f1
    fi
}

# canonical "idx=hex" text over the eight fields, used for the backup digest
nl_canonical() {
    local f="$NL_RUN_DIR/result.txt" i val
    for i in 0 1 2 3 4 5 6 7; do
        val=$(grep "ev=field idx=$i " "$f" | head -1 | tr ' ' '\n' | sed -n 's/^val=//p' | head -1)
        printf '%s=%s\n' "$i" "${val:--}"
    done
}


# --------------------------------------------------------------------- backup
NL_BACKUP_ROOT="${NVPTOOL_BACKUP_DIR:-$HOME/.nvptool/backups}"
NL_BACKUP_FILE=""

nl_backup_dir() {
    printf '%s/%s' "$NL_BACKUP_ROOT" "$(printf '%s' "$NL_SERIAL" | tr -c 'A-Za-z0-9._-' '_')"
}

# Store the eight raw values read from the device. Never overwrites anything:
# every snapshot gets a unique name, and the first verified baseline is also
# copied to baseline.conf with noclobber semantics.
nl_backup_write() {   # $1 kind: baseline|snapshot
    local kind="$1" dir ts file canon digest i key len hex
    canon=$(nl_canonical)
    digest=$(printf '%s' "$canon" | nl_sha256)
    dir=$(nl_backup_dir)
    mkdir -p "$dir" 2>/dev/null || nl_die "cannot create backup directory $dir"
    chmod 700 "$dir" 2>/dev/null || true

    ts=$(date -u +%Y%m%dT%H%M%SZ)
    file="$dir/${ts}-${kind}-${NL_RUN_ID}.conf"
    [ -e "$file" ] && nl_die "backup file already exists: $file"

    {
        printf 'schema=%s\n' "$NL_SCHEMA"
        printf 'tool=%s\n' "$NL_TOOL_VERSION"
        printf 'kind=%s\n' "$kind"
        printf 'serial=%s\n' "$NL_SERIAL"
        printf 'model=%s\n' "${NL_MODEL_SEEN:-}"
        printf 'fingerprint=%s\n' "${NL_FP_SEEN:-}"
        printf 'created=%s\n' "$ts"
        printf 'run=%s\n' "$NL_RUN_ID"
        printf 'digest=%s\n' "$digest"
        for i in 0 1 2 3 4 5 6 7; do
            key="${NL_KEYS[$i]}"
            len="${NL_LENS[$i]}"
            hex=$(grep "ev=field idx=$i " "$NL_RUN_DIR/result.txt" | head -1 \
                  | tr ' ' '\n' | sed -n 's/^val=//p' | head -1)
            printf 'field.%s.key=%s\n' "$i" "$key"
            printf 'field.%s.len=%s\n' "$i" "$len"
            printf 'field.%s.hex=%s\n' "$i" "$hex"
        done
    } > "$file"

    ( cd "$dir" && printf '%s  %s\n' "$(nl_sha256 < "$(basename "$file")")" "$(basename "$file")" > "$file.sha256" )
    NL_BACKUP_FILE="$file"

    if [ "$kind" = "baseline" ]; then
        local base="$dir/baseline.conf"
        if [ ! -e "$base" ]; then
            if ( set -o noclobber; cat "$file" > "$base" ) 2>/dev/null; then
                ( cd "$dir" && printf '%s  %s\n' "$(nl_sha256 < baseline.conf)" "baseline.conf" > baseline.conf.sha256 )
            fi
        fi
    fi
}

nl_backup_latest() {   # prints the original (baseline) backup path, or fails
    local dir f
    dir=$(nl_backup_dir)
    if [ -f "$dir/baseline.conf" ]; then printf '%s/baseline.conf' "$dir"; return 0; fi
    f=$(ls -1t "$dir"/*-baseline-*.conf 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    printf '%s' "$f"
}

# Validate a backup file and load its eight hex values into NL_BK_HEX.
nl_backup_load() {   # $1 file
    local f="$1" i
    [ -f "$f" ] || nl_die "backup not found: $f" 20
    local sidecar; sidecar="$f.sha256"
    [ -f "$sidecar" ] || nl_die "backup has no integrity file: $f.sha256" 20
    local want got
    want=$(cut -d' ' -f1 < "$sidecar")
    got=$(nl_sha256 < "$f")
    [ "$want" = "$got" ] || nl_die "backup integrity check failed (corrupt or edited)" 20

    local schema serial model fp digest
    schema=$(sed -n 's/^schema=//p' "$f" | head -1)
    serial=$(sed -n 's/^serial=//p' "$f" | head -1)
    model=$(sed -n 's/^model=//p' "$f" | head -1)
    fp=$(sed -n 's/^fingerprint=//p' "$f" | head -1)
    digest=$(sed -n 's/^digest=//p' "$f" | head -1)

    [ "$schema" = "$NL_SCHEMA" ] || nl_die "backup schema $schema is not supported" 20
    [ "$serial" = "$NL_SERIAL" ] || nl_die "backup belongs to device $serial, not $NL_SERIAL" 20
    [ "$model" = "$NL_MODEL_SEEN" ] || nl_die "backup model $model does not match device" 20
    [ "$fp" = "$NL_FP_SEEN" ] || nl_die "backup firmware does not match device" 20

    NL_BK_HEX=()
    local key len hex canon=""
    for i in 0 1 2 3 4 5 6 7; do
        key=$(sed -n "s/^field\.$i\.key=//p" "$f" | head -1)
        len=$(sed -n "s/^field\.$i\.len=//p" "$f" | head -1)
        hex=$(sed -n "s/^field\.$i\.hex=//p" "$f" | head -1)
        [ "$key" = "${NL_KEYS[$i]}" ] || nl_die "backup field $i has unexpected key '$key'" 20
        [ "$len" = "${NL_LENS[$i]}" ] || nl_die "backup field $i has unexpected length $len" 20
        [ -n "$hex" ] && [ "$hex" != "-" ] || nl_die "backup field $i is empty" 20
        [ "${#hex}" -eq "$((len * 2))" ] || nl_die "backup field $i hex length is wrong" 20
        case "$hex" in *[!0-9a-f]*) nl_die "backup field $i is not hex" 20 ;; esac
        NL_BK_HEX[$i]="$hex"
        canon="${canon}${i}=${hex}"$'\n'
    done
    local recomputed
    canon="${canon%$'\n'}"
    recomputed=$(printf '%s' "$canon" | nl_sha256)
    [ "$recomputed" = "$digest" ] || nl_die "backup digest does not match its contents" 20
}

# --------------------------------------------------------------------- journal
nl_journal() {   # $1 phase, $2 detail
    local dir; dir=$(nl_backup_dir)
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s phase=%s run=%s device=%s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${NL_RUN_ID:-}" "${NL_SERIAL:-}" "$2" \
        >> "$dir/journal.log" 2>/dev/null || true
}


# A leftover payload setting means this run did not leave the device clean.
# That is a recovery-required state: never report it as success.
nl_require_cleanup() {   # $1 = operation label
    if [ "${NL_CLEANUP_OK:-1}" = "1" ]; then
        return 0
    fi
    nl_journal "cleanup-failed" "op=$1"
    local result
    result=$(grep 'ev=summary' "$NL_RUN_DIR/result.txt" 2>/dev/null | tail -1 || true)
    nl_die "$1: cleanup failed after the operation (result: ${result:-UNKNOWN}).
hidden_api_blacklist_exemptions or the run's remote file could not be verified clean.
This is recovery-required, regardless of the operation's result.

  Original setting: ${NL_SETTINGS_STATE:-unknown}
  Recovery record: ${NL_RECOVERY_FILE:-none}
  Device lock: $NL_REMOTE_LOCK
  Check the setting and record before manual lock recovery." 7
}
