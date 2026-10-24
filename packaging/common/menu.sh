#!/usr/bin/env bash
# Interactive helper for the NW-WM1AM2 volume-cap tool.  macOS / Linux.
# Called by START-macos.command and START-linux.sh. Needs only adb.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 1

PKG="org.maniac79.nvptool"
APK="nvptool.apk"
ADB=""

hr()    { printf '%s\n' "------------------------------------------------------------"; }
pause() { printf '\nPress Enter to continue...'; read -r _ 2>/dev/null || true; }

find_adb() {
    if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
    local c
    for c in "$HERE/platform-tools/adb" \
             "$HOME/Library/Android/sdk/platform-tools/adb" \
             "$HOME/Android/Sdk/platform-tools/adb" \
             "/opt/homebrew/bin/adb" "/usr/local/bin/adb" "/usr/bin/adb"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

adb_missing_help() {
    hr
    echo "  adb was not found on this computer."
    hr
    cat <<'EOF'
  You do not need the full Android SDK - only "Platform Tools".

  1. Download "SDK Platform-Tools":
       https://developer.android.com/tools/releases/platform-tools
  2. Unzip it; you get a folder named "platform-tools".
  3. Then do ONE of these:
       a) Move that folder next to this script, so this file exists:
            platform-tools/adb          (macOS / Linux)
            platform-tools/adb.exe      (Windows)
       b) Or add it to your PATH and reopen this window.
  4. Prepare the player:
       - Settings > About device > tap "Build number" seven times
       - Settings > System > Developer options > enable "USB debugging"
       - Connect the USB cable, then accept "Allow USB debugging?" on the
         player (tick "Always allow from this computer").
  5. Start this script again.

  Nothing has been changed on your player.
EOF
    hr
    pause
}

device_ready() { [ "$(adb get-state 2>/dev/null | tr -d '\r')" = "device" ]; }

no_device_help() {
    hr
    echo "  adb is installed, but no authorised player was found."
    hr
    cat <<'EOF'
  Check these, in order:
    - Is the Walkman connected with a data-capable USB cable?
    - Is "USB debugging" enabled in Developer options?
    - Did you accept the "Allow USB debugging?" prompt on the player?
      (If it never appears, unplug and replug the cable.)
EOF
    echo
    echo "  adb devices says:"
    adb devices 2>&1 | sed 's/^/    /'
    echo
    pause
}

ensure_apk() {
    if adb shell pm path "$PKG" 2>/dev/null | grep -q "package:"; then return 0; fi
    echo
    echo "  The helper app is not installed on the player yet."
    printf '  Install it now from %s? [Y/n] ' "$APK"
    local a; read -r a 2>/dev/null || a=y
    case "${a:-y}" in [nN]*) return 1 ;; esac
    [ -f "$APK" ] || { echo "  $APK is missing from this folder."; pause; return 1; }
    echo "  installing..."
    adb install -r "$APK" || { echo "  Install failed."; pause; return 1; }
    echo "  installed."
    return 0
}

run_class() {   # $1 = class, $2 = human label
    hr; echo "  $2"; hr
    local out rc
    out="$(./inject.sh "$1" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        echo "$out"
        echo
        echo "  No usable output came back. This step is known to be flaky;"
        echo "  simply run it again."
        pause
        return 1
    fi
    printf '%s\n' "$out" | sed 's/^/  /'
    return 0
}

confirm() {
    printf '%s [yes/NO] ' "$1"
    local a; read -r a 2>/dev/null || a=no
    case "$a" in yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

do_reboot() {
    echo "  Rebooting the player..."
    adb reboot >/dev/null 2>&1
    echo "  Done. Wait for it to start up again."
    pause
}

menu() {
    hr
    echo "  Sony NW-WM1AM2 - EU volume cap tool"
    hr
    echo "  1) Check status            (read-only, changes nothing)"
    echo "  2) Enable the fix          (writes NVRAM, then reboot)"
    echo "  3) Restore factory setting (undo everything)"
    echo "  4) Reboot the player"
    echo "  5) Where is adb? / requirements"
    echo "  0) Exit"
    echo
    printf '  Choice: '
}

main() {
    ADB="$(find_adb)" || ADB=""
    if [ -n "$ADB" ]; then
        export PATH="$(dirname "$ADB"):$PATH"
    fi

    while true; do
        menu
        local choice; read -r choice 2>/dev/null || choice=0
        case "$choice" in
            1)
                [ -n "$ADB" ] || { adb_missing_help; continue; }
                device_ready || { no_device_help; continue; }
                ensure_apk || continue
                run_class "org.maniac79.nvptool.Read" "Reading current values"
                echo
                echo "  Look for:  ro.safe_volume.enabled = 00000000   (fix active)"
                echo "             ro.safe_volume.enabled = 01000000   (factory / capped)"
                pause
                ;;
            2)
                [ -n "$ADB" ] || { adb_missing_help; continue; }
                device_ready || { no_device_help; continue; }
                ensure_apk || continue
                hr
                echo "  This writes eight calibration fields into the player's NVRAM"
                echo "  and needs a reboot afterwards. Option 3 undoes it."
                hr
                confirm "Continue?" || continue
                if run_class "org.maniac79.nvptool.Apply" "Applying configuration"; then
                    if confirm "Reboot now so the change takes effect?"; then
                        do_reboot
                    else
                        echo "  Remember to reboot before judging the result."
                        pause
                    fi
                fi
                ;;
            3)
                [ -n "$ADB" ] || { adb_missing_help; continue; }
                device_ready || { no_device_help; continue; }
                ensure_apk || continue
                hr
                echo "  This restores the values recorded from the tested unit."
                hr
                confirm "Restore factory settings?" || continue
                if run_class "org.maniac79.nvptool.Rollback" "Restoring factory values"; then
                    if confirm "Reboot now?"; then do_reboot; else pause; fi
                fi
                ;;
            4)
                [ -n "$ADB" ] || { adb_missing_help; continue; }
                device_ready || { no_device_help; continue; }
                do_reboot
                ;;
            5)  adb_missing_help ;;
            0|q|Q|"") exit 0 ;;
            *)  echo "  Unknown choice."; sleep 1 ;;
        esac
    done
}

main

