# Helper APK signing and build identities

Android upgrades an installed `org.maniac79.nvptool` helper only when the new
APK uses the same signing certificate. The installed helper is then executed
through the project's temporary privileged path, so host tools check more than
its package name and version: they pull the installed APK and compare its
SHA-256 with the trusted bundled APK before each privileged operation. The
bundle's own hash must match its adjacent `SOURCE-COMMIT.txt`. A match is an
identity check against the supplied package, not independent proof that the
package came from the stated source commit; inspect published release hashes
and provenance too.

## Maintainer release identity

| Item | Value |
|---|---|
| Package | `org.maniac79.nvptool` |
| Certificate SHA-256 | `c21c663d2171dcbd8bdc47c5bb5b2103a0fbf7aa349d7e5aebb67123de42c992` |
| Certificate | RSA 4096, `CN=nvptool release key, O=wm1am2-eu-volume-unlock, C=DE` |
| Scheme | APK Signature Scheme v3, minSDK 28 |
| 0.2.2 | `versionCode=5`, dedicated release key |
| 0.2.3 | `versionCode=6`, **same** dedicated release certificate |
| 0.2.4 | `versionCode=7`, **same** dedicated release certificate; writes enabled again |
| 0.2.5 | `versionCode=8`, same certificate; documentation and tooling release |
| 0.2.6 | `versionCode=9`, same certificate; reboot made part of the process |
| 0.2.7 | `versionCode=10`, same certificate; host validation only (logcat format, claim-skip records, recovery docs) |

`tools/build.sh` defaults to `NVPTOOL_SIGNING_MODE=release`. It requires the
maintainer's existing keystore (normally `~/.nvptool/nvptool-release.jks`) and
password file (`~/.nvptool/keystore.pass`) or an explicit password environment
variable. The signing program receives `file:` or `env:` rather than a literal
password in a process argument. The build verifies that the resulting APK's
certificate equals the pinned SHA-256 above and writes a build receipt plus
`out/SOURCE-COMMIT.txt`. It does not silently generate or rotate a key.
`tools/init_signing_key.sh` creates a key only on an explicit one-time call,
refuses to overwrite an existing key/password file and does not display the
password. Keep both files private and backed up outside the repository.

The 0.1.0–0.2.1 helper used an earlier shared debug certificate and cannot be
upgraded in place to any 0.2.2-or-later build, including the current 0.2.7. On an installation signed with that older
key, `install` returns Android's signing mismatch and **does not automatically
uninstall** it. If the user has identified that old helper and chooses to
remove it, the explicit command is:

```bash
adb uninstall org.maniac79.nvptool
```

Uninstall removes the app, **not** the eight persistent NVRAM values or backup
files on the host. It is not a rollback. An existing correctly signed 0.2.2
helper can be upgraded in place to the current 0.2.7 release build by explicit menu
option 7 or CLI `install`, provided a verified 0.2.7 package is available. Check
the current GitHub Assets; a source checkout is not proof of publication.

## Independent and CI builds

A new contributor does **not** have the maintainer's private release key.
After explicitly creating/selecting their own keystore (for example with
`./tools/init_signing_key.sh` in a separate local key location), they use
`NVPTOOL_SIGNING_MODE=local ./tools/build.sh`. Offline CI uses
`NVPTOOL_SIGNING_MODE=ci`. Both modes still sign and verify an APK, but their
certificate differs from the release pin and the receipt marks it as local or
CI. They cannot produce an official release package by default. Android will
not upgrade a maintainer-signed installation with such an APK; do not silently
uninstall an existing helper to force it.

For an independent local build, point **both** commands at the same private
key and password paths, away from any maintainer release keystore:

```bash
export NVPTOOL_KEYSTORE="$HOME/.nvptool/my-local.jks"
export NVPTOOL_KEYSTORE_PASSFILE="$HOME/.nvptool/my-local.pass"
./tools/init_signing_key.sh
NVPTOOL_SIGNING_MODE=local ./tools/build.sh
```

For source builds, the host's `out/SOURCE-COMMIT.txt` accompanies
`out/nvptool.apk` and binds the local APK hash. Builds require JDK, Python 3,
Android SDK build-tools and a platform `android.jar`. `tools/build.sh` records
the source/build inputs in `out/build-receipt.json`; `packaging/make_release.sh`
checks the receipt, APK package/version/certificate, source and package inputs
before creating ZIPs. A dirty tree or local/CI key is refused for an official
package unless the builder provides explicit `--allow-dirty` or
`--allow-test-key` test exceptions. Such exceptions do not turn the result into
a maintainer release. A receipt and checksum detect input drift but do not by
themselves prove bit-for-bit reproducibility from public source.

Only a clean, eligible release build uses the unsuffixed official name
`wm1am2-nvptool-OS-0.2.7.zip`. Nonrelease archives carry a visible suffix such
as `-ci`, `-local`, `-dirty` or `-ci-dirty` before `.zip`; they must not be
published as official release assets. Inspect the archive's `SOURCE-COMMIT.txt`:
an official package records `signing_mode=release`, the pinned
`certificate_sha256`, and `release_eligible=true`.

## Custody and rotation

The keystore and password must stay outside Git, `out/`, `dist/` and ZIPs. A
future certificate rotation needs an intentional version bump, new pin, user
migration instructions and release notes. There is no automatic uninstall in
the tools. For published archives, verify an **external** ZIP SHA-256 from the
release notes; the internal `SHA256SUMS.txt` only checks files within the same
ZIP. Verify APK signer and manifest before any device installation.
