#!/bin/bash
# Double-click launcher for macOS.
#
# If macOS refuses to open this file ("cannot be opened because it is from an
# unidentified developer"), right-click it and choose "Open", or run once in
# Terminal:   chmod +x START-macos.command
#
cd "$(dirname "$0")" || exit 1

# keep the helper scripts executable after unzipping
chmod +x ./menu.sh ./inject.sh 2>/dev/null

# remove the quarantine flag if it is present, so the menu runs without prompts
xattr -d com.apple.quarantine ./menu.sh ./inject.sh 2>/dev/null

./menu.sh
rc=$?
if [ $rc -ne 0 ]; then
    echo
    echo "The menu exited with an error (code $rc)."
    printf 'Press Enter to close...'
    read -r _
fi
