#!/usr/bin/env bash
# nvptool.sh - host-side orchestrator.
#
#   nvptool.sh status             read-only: three properties, no privilege
#   nvptool.sh read               privileged full NVP read + verified backup
#   nvptool.sh apply              back up, then write the target configuration
#   nvptool.sh restore [file]     restore each field from a validated backup
#   nvptool.sh restore-reference  ADVANCED: reference profile, no backup needed
#   nvptool.sh install            explicitly install the bundled helper APK
#
# Binds to exactly one adb device, takes a per-device lock, preserves the
# previous hidden_api_blacklist_exemptions value, and requires a complete
# matching structured result before reporting success.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CMD="${1:-status}"

nl_on_exit() {
    local rc="$1"
    trap - EXIT INT TERM
    if [ "${NL_SETTINGS_TOUCHED:-0}" = 1 ] && [ "${NL_CLEANUP_ATTEMPTED:-0}" = 0 ]; then
        if ! nl_settings_restore; then
            printf 'nvptool: EXIT cleanup could not restore hidden_api_blacklist_exemptions; recovery record: %s; device lock: %s\n' \
                "${NL_RECOVERY_FILE:-none}" "$NL_REMOTE_LOCK" >&2
            rc=7
        fi
    fi
    if [ -n "${NL_REMOTE_PAYLOAD:-}" ] && [ "${NL_REMOTE_FILE_CLEANUP_ATTEMPTED:-0}" = 0 ]; then
        if nl_adb shell "rm -f $NL_REMOTE_PAYLOAD" >/dev/null 2>&1; then
            NL_REMOTE_PAYLOAD=""
        else
            printf 'nvptool: EXIT cleanup could not remove remote payload %s\n' "$NL_REMOTE_PAYLOAD" >&2
            rc=7
        fi
    fi
    if [ "${NL_REMOTE_LOCK_HELD:-0}" = 1 ]; then
        if ! nl_remote_lock_release; then
            printf 'nvptool: device lock remains at %s; inspect recovery record %s before manual unlock\n' \
                "$NL_REMOTE_LOCK" "${NL_RECOVERY_FILE:-none}" >&2
            rc=7
        fi
    fi
    if [ "${NL_SETTINGS_TOUCHED:-0}" = 0 ] &&
       [ "${NL_REMOTE_LOCK_HELD:-0}" = 0 ] &&
       [ -z "${NL_REMOTE_PAYLOAD:-}" ]; then
        local record
        if [ "${#NL_RECOVERY_FILES[@]}" -gt 0 ]; then
            for record in "${NL_RECOVERY_FILES[@]}"; do rm -f "$record"; done
        fi
    fi
    nl_cleanup_local
    nl_lock_release
    exit "$rc"
}
trap 'nl_on_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

nl_hex_ascii_padded() {   # $1 ascii, $2 length in bytes -> hex
    local hx want
    hx=$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')
    want=$(( $2 * 2 ))
    while [ "${#hx}" -lt "$want" ]; do hx="${hx}00"; done
    printf '%s' "$hx"
}

nl_canon_for() {   # $1 = target | reference ; prints "idx=hex" lines
    local mode="$1"
    local -a hv
    if [ "$mode" = "target" ]; then
        hv=( "$(nl_hex_ascii_padded kVolTblIcx1298HpSeGainHigh 256)"
             "$(nl_hex_ascii_padded kVolTblIcx1298HpSeGainLow 256)"
             "$(nl_hex_ascii_padded kVolTblIcx1298HpBtlGainHigh 256)"
             "$(nl_hex_ascii_padded kVolTblIcx1298HpBtlGainLow 256)"
             "01000000" "01000000" "01000000" "00000000" )
    else
        hv=( "$(nl_hex_ascii_padded kVolTblIcx1298CewHpSe 256)"
             "$(nl_hex_ascii_padded kVolTblIcx1298CewHpSe 256)"
             "$(nl_hex_ascii_padded kVolTblIcx1298CewHpBtl 256)"
             "$(nl_hex_ascii_padded kVolTblIcx1298CewHpBtl 256)"
             "00000000" "00000000" "00000000" "01000000" )
    fi
    local i
    for i in 0 1 2 3 4 5 6 7; do printf '%s=%s\n' "$i" "${hv[$i]}"; done
}

nl_classify() {   # baseline | snapshot | foreign
    local canon
    canon=$(nl_canonical)
    if [ "$canon" = "$(nl_canon_for reference)" ]; then printf 'baseline'
    elif [ "$canon" = "$(nl_canon_for target)" ]; then printf 'snapshot'
    else printf 'foreign'; fi
}

nl_cmd_status() {
    nl_select_device
    nl_bind_serial
    local dev dest safe
    dev=$(nl_getprop ro.product.model)
    dest=$(nl_getprop vendor.destination)
    safe=$(nl_getprop vendor.safe_volume.enabled)
    printf 'device      : %s\n' "$dev"
    printf 'destination : %s\n' "$dest"
    if [ "$safe" = "00000000" ]; then
        printf 'safe_volume : %s (limit off)\n' "$safe"
    else
        printf 'safe_volume : %s (factory/limited)\n' "$safe"
    fi
    printf 'adb serial  : %s\n\n' "$NL_SERIAL"
    printf 'Read-only check: no app installed, no privilege used, no setting\n'
    printf 'changed, no NVRAM written.\n'
}

nl_cmd_read() {
    nl_select_device
    nl_lock_acquire
    nl_preflight
    nl_mktempdir
    nl_require_apk
    NL_RUN_ID="$(date +%s)-$$-$RANDOM"

    nl_journal "read-start" "tool=$NL_TOOL_VERSION"
    nl_inject "org.maniac79.nvptool.Read" "read" "$NL_RUN_ID" >/dev/null
    [ "${NL_INJECT_RC:-1}" = "3" ] && \
        nl_die "no completion record - outcome UNKNOWN; nothing was written" 4
    nl_parse "read" "$NL_RUN_ID" || nl_die "incomplete result ($NL_PARSE_ERR)" 3
    [ "$NL_STATUS" = "OK" ] || nl_die "read $NL_STATUS ($NL_REASON)" 3

    local kind
    kind=$(nl_classify)
    nl_backup_write "$kind"
    nl_backup_load "$NL_BACKUP_FILE"
    nl_require_cleanup "read"
    nl_journal "read-ok" "kind=$kind"
    printf 'read OK (%s configuration)\nbackup: %s\n' "$kind" "$NL_BACKUP_FILE"
}

nl_cmd_apply() {
    nl_require_write_enabled
    nl_select_device
    nl_lock_acquire
    nl_preflight
    nl_mktempdir
    nl_require_apk
    NL_RUN_ID="$(date +%s)-$$-$RANDOM"

    # 1. back up first; nothing is written until a verified backup exists
    nl_journal "apply-backup-start" "run=$NL_RUN_ID"
    nl_inject "org.maniac79.nvptool.Read" "read" "$NL_RUN_ID" >/dev/null
    [ "${NL_INJECT_RC:-1}" = "3" ] && \
        nl_die "backup read produced no record; NOTHING WRITTEN" 4
    nl_parse "read" "$NL_RUN_ID" || nl_die "backup read incomplete ($NL_PARSE_ERR); NOTHING WRITTEN" 3
    [ "$NL_STATUS" = "OK" ] || nl_die "backup read $NL_STATUS; NOTHING WRITTEN" 3

    local kind digest
    kind=$(nl_classify)
    nl_backup_write "$kind" || nl_die "could not write backup; NOTHING WRITTEN" 20
    nl_backup_load "$NL_BACKUP_FILE" || nl_die "backup failed verification; NOTHING WRITTEN" 20
    digest=$(nl_canonical | nl_sha256)
    nl_journal "apply-backup-ok" "kind=$kind digest=$digest"

    # Fail closed: if the privileged read phase could not put the temporary
    # setting back, the device is not clean. Do not start a second privileged
    # run, and do not write NVRAM on top of an unclean state.
    if [ "${NL_CLEANUP_OK:-1}" != "1" ]; then
        nl_journal "apply-abort-unclean" "phase=backup-read"
        nl_die "apply aborted after the backup-read phase: the temporary setting
hidden_api_blacklist_exemptions could NOT be restored.

The NVRAM write phase was NOT started, so this run wrote nothing.
A valid backup was taken first:
  backup: $NL_BACKUP_FILE

This is a recovery-required state, not a clean result:

  Check:    adb shell settings get global hidden_api_blacklist_exemptions
  Expected: null (stock) or your original value
  Original: ${NL_SETTINGS_STATE:-unknown}

Fix that setting before running apply again." 7
    fi

    # 2. write, bound to the digest of the backup just taken
    NL_RUN_ID="$(date +%s)-$$-$RANDOM"
    nl_journal "apply-write-start" "digest=$digest"
    nl_inject "org.maniac79.nvptool.Apply" "apply" "$NL_RUN_ID" "$digest" >/dev/null

    if [ "${NL_INJECT_RC:-1}" = "3" ]; then
        nl_journal "apply-unknown" "no summary"
        nl_die "no completion record: outcome UNKNOWN. Do not assume nothing changed.
Recovery: 'nvptool.sh read' and compare against
  $NL_BACKUP_FILE" 4
    fi
    nl_parse "apply" "$NL_RUN_ID" || {
        nl_journal "apply-malformed" "err=$NL_PARSE_ERR"
        nl_die "malformed result ($NL_PARSE_ERR): treat outcome as UNKNOWN" 4
    }

    if [ "$NL_STATUS" = "OK" ]; then
        # A leftover payload setting is a recovery-required state, not a success.
        nl_require_cleanup "apply"
        nl_journal "apply-ok" "written=$NL_WRITTEN verified=$NL_VERIFIED cleanup=$NL_CLEANUP_OK"
        printf 'apply OK - %s/%s verified (wrote %s)\n' "$NL_VERIFIED" "$NL_TOTAL" "$NL_WRITTEN"
        printf 'backup: %s\n' "$NL_BACKUP_FILE"
        printf 'Reboot for the change to take effect.\n'
        return 0
    fi

    nl_journal "apply-$NL_STATUS" "reason=$NL_REASON verified=$NL_VERIFIED"
    nl_die "apply $NL_STATUS (reason $NL_REASON, verified $NL_VERIFIED/$NL_TOTAL)
Recovery: 'nvptool.sh read', then 'nvptool.sh restore'
  $NL_BACKUP_FILE" 5
}

nl_cmd_restore() {
    nl_require_write_enabled
    local file="${1:-}" kind
    nl_select_device
    nl_lock_acquire
    nl_preflight
    nl_mktempdir
    nl_require_apk

    [ -n "$file" ] || file=$(nl_backup_latest) || \
        nl_die "no original (baseline) backup found for this device.
A backup of an already-modified state is not a factory backup. Options:
  - restore the built-in reference profile:  nvptool.sh restore-reference
  - or pass an explicit file plus NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1" 20

    nl_backup_load "$file"
    kind=$(sed -n 's/^kind=//p' "$file" | head -1)

    if [ "$kind" != "baseline" ]; then
        printf 'WARNING: this backup is kind=%s, not a factory baseline.\n' "$kind"
        printf '         Restoring it returns the device to an ALREADY MODIFIED state.\n'
        if [ "${NVPTOOL_ALLOW_NON_BASELINE_RESTORE:-0}" != "1" ]; then
            nl_journal "restore-refused" "kind=$kind"
            nl_die "refusing to restore a non-baseline backup without explicit consent.
Re-run with NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1 if that is really what you want." 21
        fi
    fi

    printf 'restoring from: %s (kind=%s)\n' "$file" "$kind"

    local i run
    for i in 0 1 2 3 4 5 6 7; do
        run="$(date +%s)-$$-$RANDOM"
        nl_journal "restore-start" "field=$i"
        nl_inject "org.maniac79.nvptool.RestoreField" "restore" "$run" "$i" "${NL_BK_HEX[$i]}" >/dev/null
        if [ "${NL_INJECT_RC:-1}" = "3" ]; then
            nl_journal "restore-unknown" "field=$i"
            nl_die "field $i: no completion record, outcome UNKNOWN. Re-run 'nvptool.sh read'." 4
        fi
        nl_parse "restore" "$run" || nl_die "field $i: malformed result ($NL_PARSE_ERR)" 4
        if [ "$NL_STATUS" != "OK" ]; then
            nl_die "field $i: $NL_STATUS ($NL_REASON); fields 0..$((i - 1)) were restored" 5
        fi
        nl_journal "restore-field-ok" "field=$i reason=$NL_REASON"
        printf '  field %s: %s\n' "$i" "$NL_REASON"

        # Fail closed between fields: a field that leaves the temporary setting
        # behind makes the device unclean, so no further field may be written.
        if [ "${NL_CLEANUP_OK:-1}" != "1" ]; then
            nl_journal "restore-abort-unclean" "field=$i"
            nl_die "restore stopped after field $i: the NVRAM field was restored and
verified, but the temporary setting hidden_api_blacklist_exemptions could NOT
be put back.

  Restored: fields 0..$i (verified)
  NOT written: $((7 - i)) field(s)

No further field was written. This is a recovery-required state, not a clean
result:

  Check:    adb shell settings get global hidden_api_blacklist_exemptions
  Expected: null (stock) or your original value
  Original: ${NL_SETTINGS_STATE:-unknown}

Fix that setting before running restore again (it is safe to re-run: already
restored fields are rewritten with the same values)." 7
        fi
    done

    nl_require_cleanup "restore"
    nl_journal "restore-ok" "file=$file kind=$kind"
    printf 'restore OK (%s) - reboot to reload the table for these values.\n' "$kind"
}

nl_cmd_restore_reference() {
    nl_require_write_enabled
    nl_select_device
    nl_lock_acquire
    nl_preflight
    nl_mktempdir
    nl_require_apk
    NL_RUN_ID="$(date +%s)-$$-$RANDOM"
    nl_journal "restore-reference-start" "run=$NL_RUN_ID"
    nl_inject "org.maniac79.nvptool.RestoreReference" "restore_reference" \
        "$NL_RUN_ID" "CONFIRM_REFERENCE_PROFILE" >/dev/null
    [ "${NL_INJECT_RC:-1}" = "3" ] && nl_die "no completion record, outcome UNKNOWN" 4
    nl_parse "restore_reference" "$NL_RUN_ID" || nl_die "malformed result ($NL_PARSE_ERR)" 4
    [ "$NL_STATUS" = "OK" ] || nl_die "reference restore $NL_STATUS ($NL_REASON)" 5
    # The reference restore writes NVRAM, so a leftover payload setting is a
    # recovery-required state here exactly as it is for apply and restore.
    nl_require_cleanup "restore-reference"
    nl_journal "restore-reference-ok" "verified=$NL_VERIFIED"
    printf 'reference profile restored (%s/%s verified). Reboot.\n' "$NL_VERIFIED" "$NL_TOTAL"
}

nl_cmd_reboot() {
    nl_select_device
    nl_bind_serial
    printf 'rebooting %s ...\n' "$NL_SERIAL"
    nl_adb reboot >/dev/null 2>&1 || nl_die "reboot command failed" 6
    printf 'reboot requested.\n'
}

nl_cmd_install() {
    nl_select_device
    nl_lock_acquire
    nl_preflight
    nl_mktempdir
    local apk
    apk=$(nl_local_apk) || nl_die "cannot locate bundled APK"
    [ -f "$apk" ] || nl_die "bundled helper APK not found at $apk"
    nl_trusted_apk_hash "$apk" >/dev/null || nl_die "bundled APK provenance check failed" 11
    NL_RUN_ID="$(date +%s)-$$-$RANDOM"
    nl_remote_lock_acquire "$NL_RUN_ID"
    nl_adb install -r "$apk" || nl_die "APK installation failed; no package was uninstalled" 6
    nl_require_apk
    printf 'bundled helper installed and byte-verified for %s\n' "$NL_SERIAL"
}

case "$CMD" in
    status)            nl_cmd_status ;;
    read)              nl_cmd_read ;;
    apply)             nl_cmd_apply ;;
    restore)           shift; nl_cmd_restore "${1:-}" ;;
    restore-reference) nl_cmd_restore_reference ;;
    reboot)            nl_cmd_reboot ;;
    install)           nl_cmd_install ;;
    -h|--help|help)    sed -n '2,12p' "$0" ;;
    *)
        echo "unknown command: $CMD (try: status read apply restore restore-reference reboot install)" >&2
        exit 64 ;;
esac

