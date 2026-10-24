#!/usr/bin/env bash
# Starter for Linux. Either double-click (if your file manager allows it) or:
#     chmod +x START-linux.sh
#     ./START-linux.sh
cd "$(dirname "$0")" || exit 1

chmod +x ./menu.sh ./inject.sh 2>/dev/null

./menu.sh
rc=$?
if [ "$rc" -ne 0 ]; then
    echo
    echo "The menu exited with an error (code $rc)."
    printf 'Press Enter to close...'
    read -r _
fi
