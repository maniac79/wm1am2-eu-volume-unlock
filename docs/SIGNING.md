# APK signing: identity, custody and the rule for future releases

The APK is the privileged helper (`org.maniac79.nvptool`). Android only
**upgrades** an installed app when the new APK carries the **same signing
certificate**; anything else is refused with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` and the old helper has to be removed first.

## Current key: dedicated release key

| | |
|---|---|
| DN | `CN=nvptool release key, O=wm1am2-eu-volume-unlock, C=DE` |
| Certificate SHA-256 | `c21c663d2171dcbd8bdc47c5bb5b2103a0fbf7aa349d7e5aebb67123de42c992` |
| Key | RSA 4096, validity 30 years |
| Keystore | `~/.nvptool/nvptool-release.jks` (PKCS#12, `0600`) |
| Password | `~/.nvptool/keystore.pass` (`0600`), never printed, never committed |
| Created by | `./tools/init_signing_key.sh` (refuses to overwrite) |
| Signature scheme | APK Signature Scheme v3 only (`minSdkVersion=28`) |

`tools/build.sh` reads the password from `NVPTOOL_KEYSTORE_PASS` or that file,
signs, then verifies the certificate against the fingerprint pinned in the
script and **fails the build** if it differs. There is no fallback to a
generated key: a missing keystore is a build error, not a new identity.

## What was signed with what

| Build | versionCode / versionName | Signer |
|---|---|---|
| 0.1.0, 1.1.0, 0.2.0, 0.2.1 | 0 of none, 2, 3, 4 / 1.1.0, 0.2.0, 0.2.1 | shared Android debug key `a934c760…255ec1` (`CN=Android Debug`) |
| **0.2.2 and later** | **5 / 0.2.2** | **dedicated release key `c21c663d…42c992`** |

**Consequence, stated plainly:** a helper installed from any build up to 0.2.1
cannot be upgraded to 0.2.2. It must be removed once:

```bash
adb uninstall org.maniac79.nvptool
```

That removes the helper only. **It does not undo anything**: the eight NVRAM
values are device state, not app data, and stay exactly as they are. Running
`install` again afterwards is safe. This rotation was acceptable because the
project has no installed base; it is not a precedent for silent rotation.

## Custody

The keystore and its password live outside the repository, under a `0700`
directory, and are never copied into `out/`, `dist/` or any archive. Each release
audit checks that no key material is packaged. **Back both files up** somewhere
off-machine: losing them means future releases cannot upgrade 0.2.2+ installs,
and the recovery is the uninstall-first dance again.

## The rule

1. **The certificate is pinned** in `tools/build.sh`; a different key fails the
   build instead of shipping a non-upgradeable APK.
2. **Rotation is a deliberate, announced act**: bump `versionCode`, change the
   pin, put "uninstall the old helper first" in the release notes, and update
   this file. Never as a side effect of a rebuild.
3. **The package name never changes.** A rename is a different app.
4. **Private key material is never published**: no keystore, no password, no
   `*.jks`/`*.pass` in git or in a release asset.
5. **No automatic uninstall** in the tools or menus. Removing an app is the
   user's decision, and the instructions say so explicitly.
6. **Anyone can build their own APK** with their own key; that build is a
   different app as far as Android's update rules are concerned, which is why the
   published fingerprint is recorded here.
