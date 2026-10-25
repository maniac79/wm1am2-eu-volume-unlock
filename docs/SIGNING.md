# APK signing: current identity and the rule for future releases

The APK is the privileged helper (`org.maniac79.nvptool`). Android will only
**upgrade** an installed app when the new APK is signed with the **same
certificate** as the installed one. A silent certificate change would force every
existing user to uninstall first — and here the app is harmless to uninstall, but
the update path would be broken without warning, which is not acceptable for a
tool people are told to trust.

## Current signing certificate

Verified with `apksigner verify --print-certs` on the APKs of every release that
still exists locally:

| APK | versionCode / versionName | certificate SHA-256 |
|---|---|---|
| v0.1.0 (withdrawn) | none declared | `a934c760f210a385cc0ce0f349a480c8c482ed2c9c3080896d9c6ca800255ec1` |
| v1.1.0 (retired) | 2 / 1.1.0 | `a934c760f210a385cc0ce0f349a480c8c482ed2c9c3080896d9c6ca800255ec1` |
| v0.2.0 (withdrawn) | 3 / 0.2.0 | `a934c760f210a385cc0ce0f349a480c8c482ed2c9c3080896d9c6ca800255ec1` |
| v0.2.1 (current) | 4 / 0.2.1 | `a934c760f210a385cc0ce0f349a480c8c482ed2c9c3080896d9c6ca800255ec1` |

* DN: `CN=Android Debug, O=Android, C=US`
* Public key SHA-256: `c3825abd60d1921ad88eb2d0d9c3405b36f31505b786dfe4c4abb7a571029777`
* Signature scheme: APK Signature Scheme **v3** only (see below)
* Package: `org.maniac79.nvptool`

Every release so far was signed with the same certificate, so an installed 1.1.0
or 0.2.0 build can be upgraded by the 0.2.1 APK (`versionCode` increases each
time, same signer). This is an archive comparison, not a hardware test.

## The rule

1. **The certificate is pinned.** `tools/build.sh` refuses to finish if the
   signed APK does not carry the fingerprint above. A different keystore fails
   the build instead of shipping a non-upgradeable APK.
2. **Rotation is a deliberate, announced act**, never a build accident. If it
   ever becomes necessary, the release notes must say "uninstall the old helper
   first", the new fingerprint replaces the one in this file, and the APK
   `versionCode` must still increase.
3. **The package name never changes.** Same reason: a rename is a different app.
4. **Private key material is never published.** The keystore lives outside the
   repository (`$HOME/.android/debug.keystore`, override with
   `NVPTOOL_KEYSTORE`), is never copied into `out/` or `dist/`, and no password
   is stored in git. The archives contain exactly one APK and no key material —
   this is verified when each release is audited.
5. **No uninstall step in the instructions.** Upgrade in place with
   `adb install -r`; the tool never tells anyone to uninstall an existing app.

## Why "Android Debug"

The key is the standard local debug key, which is acceptable for an experimental
helper that is never distributed through Play and never holds user data. It is
*not* a secret in the way a release key would be — but it is still a private key,
so it stays out of the repository and out of every archive. Anyone can build
their own APK with their own key; that build is simply a different app from the
point of view of Android's update rules, which is exactly why the fingerprint is
recorded here.
