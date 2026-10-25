#!/usr/bin/env bash
# One-time creation of the release signing key.
#
# The Android debug key that earlier builds used is not suitable for a published
# APK: it is shared, its password is public, and it is usually recreated per
# machine. This script creates a dedicated key that stays on the maintainer's
# machine and is never committed or packaged.
#
#   ./tools/init_signing_key.sh          # create ~/.nvptool/nvptool-release.jks
#
# Output: the certificate SHA-256 to pin in tools/build.sh.
# The password is written to a 0600 file next to the keystore and is never
# printed. Back both files up somewhere safe: losing them means future releases
# cannot upgrade installed builds.
set -euo pipefail

KS="${NVPTOOL_KEYSTORE:-$HOME/.nvptool/nvptool-release.jks}"
PASSFILE="${NVPTOOL_KEYSTORE_PASSFILE:-$HOME/.nvptool/keystore.pass}"
ALIAS="${NVPTOOL_KEY_ALIAS:-nvptool}"

if [ -e "$KS" ]; then
    echo "refusing to overwrite the existing keystore: $KS" >&2
    echo "Delete it deliberately if you really mean to rotate the key." >&2
    exit 1
fi
if [ -e "$PASSFILE" ]; then
    echo "refusing to overwrite the existing password file: $PASSFILE" >&2
    exit 1
fi

mkdir -p "$(dirname "$KS")"
chmod 700 "$(dirname "$KS")"

# 256-bit random password, hex encoded, no shell metacharacters.
if command -v openssl >/dev/null 2>&1; then
    PASS=$(openssl rand -hex 32)
else
    PASS=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

umask 077
printf '%s\n' "$PASS" > "$PASSFILE"
chmod 600 "$PASSFILE"

keytool -genkeypair \
    -keystore "$KS" -storetype PKCS12 \
    -storepass "$PASS" -keypass "$PASS" \
    -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10950 \
    -dname "CN=nvptool release key, O=wm1am2-eu-volume-unlock, C=DE" \
    >/dev/null 2>&1

chmod 600 "$KS"
unset PASS

echo "created keystore : $KS"
echo "created password : $PASSFILE (0600, not printed)"
echo
echo "Certificate fingerprint - pin this in tools/build.sh:"
keytool -list -v -keystore "$KS" -storetype PKCS12 -alias "$ALIAS" \
        -storepass "$(cat "$PASSFILE")" 2>/dev/null \
    | sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | head -1
echo
echo "Back up BOTH files. Without them, a future release cannot upgrade"
echo "installs signed with this key."
