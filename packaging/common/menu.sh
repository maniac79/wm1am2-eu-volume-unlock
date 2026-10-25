#!/usr/bin/env bash
# Interactive menu (macOS / Linux). Thin wrapper: every action is delegated to
# nvptool.sh and judged only by its exit code, so a failure can never fall
# through to the "reboot now?" prompt.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 1
NV="$HERE/nvptool.sh"

hr()    { printf '%s\n' "------------------------------------------------------------"; }
pause() { printf '\nPress Enter to continue...'; read -r _ 2>/dev/null || true; }

if [ ! -x "$NV" ]; then
    hr; echo "  nvptool.sh is missing next to this menu."; hr
    pause; exit 1
fi

adb_help() {
    hr
    echo "  Requirements"
    hr
    cat <<'EOF'
  You do not need the full Android SDK - only "Platform Tools".

    1. https://developer.android.com/tools/releases/platform-tools
    2. Unzip it; you get a folder named "platform-tools".
    3. Either move that folder next to this menu, so that this file exists:
         platform-tools/adb        (macOS/Linux)
         platform-tools\adb.exe    (Windows)
       or add it to your PATH.

  On the player:
    Settings > About device > tap "Build number" 7x
    Settings > System > Developer options > enable "USB debugging"
    Connect USB, then accept "Allow USB debugging?" and tick "Always allow".

  This tool supports exactly one configuration:
    NW-WM1AM2, Android 11, firmware 1.09.00
EOF
    hr
    pause
}

confirm_yes() {
    printf '%s [yes/NO] ' "$1"
    local a; read -r a 2>/dev/null || a=no
    case "$a" in yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

run_action() {   # $1 label, rest = nvptool args
    local label="$1"; shift
    hr; echo "  $label"; hr
    "$NV" "$@"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "  The operation did not complete successfully (exit code $rc)."
        echo "  Do not assume the player is unchanged - read the message above."
        pause
        return 1
    fi
    return 0
}

while true; do
    hr
    echo "  Sony NW-WM1AM2 - EU volume cap tool  (experimental)"
    hr
    echo "  1) Status               read-only, no privilege, changes nothing"
    echo "  2) Full NVP read        privileged read + verified backup"
    echo "  3) Apply the change     back up first, then write"
    echo "  4) Restore from backup  per-field restore, verified"
    echo "  5) Reboot the player"
    echo "  6) Requirements / where is adb"
    echo "  0) Exit"
    echo
    echo "  Advanced:  'restore-ref' restores the built-in reference profile,"
    echo "             which is NOT a backup (needs explicit confirmation)."
    echo
    printf '  Choice: '
    read -r choice 2>/dev/null || choice=0

    case "$choice" in
        1) run_action "Status (read-only)" status; pause ;;
        2) run_action "Full NVRAM read" read; pause ;;
        3)
            hr
            echo "  This writes eight NVRAM fields. A backup is taken first and"
            echo "  the write is refused if the backup cannot be verified."
            hr
            confirm_yes "Continue?" || continue
            if run_action "Applying configuration" apply; then
                if confirm_yes "Reboot now so the change takes effect?"; then
                    "$NV" reboot
                else
                    echo "  Reboot before judging the result."
                fi
                pause
            fi
            ;;
        4)
            hr
            echo "  Restores each field from the newest verified backup for this"
            echo "  device. A corrupt or foreign backup is rejected."
            hr
            confirm_yes "Restore from backup?" || continue
            run_action "Restoring" restore
            pause
            ;;
        5) "$NV" reboot; pause ;;
        6) adb_help ;;
        restore-ref)
            hr
            echo "  ADVANCED: writes the reference profile recorded from one unit."
            echo "  This is not your device's backup. Only use it if no backup exists."
            hr
            if confirm_yes "Really write the reference profile?"; then
                run_action "Restoring reference profile" restore-reference
                pause
            fi
            ;;
        0|q|Q|"") exit 0 ;;
        *) echo "  Unknown choice."; sleep 1 ;;
    esac
done
