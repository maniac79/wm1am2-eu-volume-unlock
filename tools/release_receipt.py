#!/usr/bin/env python3
"""Create/verify local APK build receipts. Never reads signing secrets.

The receipt binds an APK to the exact source inputs and toolchain observed by
build.sh. Only a clean checkout signed by the pinned maintainer certificate is
eligible for official release packaging. It is not a reproducible-build proof.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

PINNED_CERT = "c21c663d2171dcbd8bdc47c5bb5b2103a0fbf7aa349d7e5aebb67123de42c992"
PACKAGE = "org.maniac79.nvptool"


def fail(message):
    raise SystemExit("release receipt: " + message)


def run(*args, cwd=None):
    completed = subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=False)
    if completed.returncode:
        fail("command failed: " + str(args[0]) + ": " + (completed.stderr or completed.stdout).strip()[:400])
    return completed.stdout.strip()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def source_inputs(root):
    paths = sorted(p for p in (root / "src").rglob("*") if p.is_file())
    paths += [root / "tools" / "build.sh", root / "tools" / "release_receipt.py"]
    return {str(p.relative_to(root)): digest(p) for p in sorted(paths)}


def package_inputs(root, apk):
    paths = sorted(p for p in (root / "packaging").rglob("*") if p.is_file())
    paths += [root / "LICENSE"]
    paths += [root / "tools" / name for name in ("nvptool.sh", "lib.sh", "nvptool.ps1", "inject.ps1")]
    files = {str(p.relative_to(root)): digest(p) for p in sorted(paths)}
    files["out/nvptool.apk"] = digest(apk)
    canonical = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {"schema": 1, "files": files, "files_sha256": hashlib.sha256(canonical).hexdigest()}


def source_version(root):
    profile = (root / "src/org/maniac79/nvptool/Profile.java").read_text()
    manifest = (root / "src/AndroidManifest.xml").read_text()
    v1 = re.search(r'TOOL_VERSION\s*=\s*"([^"]+)"', profile)
    v2 = re.search(r'android:versionName="([^"]+)"', manifest)
    code = re.search(r'android:versionCode="(\d+)"', manifest)
    if not (v1 and v2 and code) or v1.group(1) != v2.group(1):
        fail("source versions disagree")
    return v1.group(1), int(code.group(1))


def apk_metadata(apk, bt):
    badging = run(str(bt / "aapt"), "dump", "badging", str(apk))
    package_line = next((line for line in badging.splitlines() if line.startswith("package: ")), "")
    m = re.search(r"name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", package_line)
    if not m:
        fail("cannot read APK package/version metadata")
    verification = run(str(bt / "apksigner"), "verify", "--verbose", "--print-certs", str(apk))
    if not re.search(r"^Verifies$", verification, re.MULTILINE):
        fail("APK signature did not verify")
    if not re.search(r"^Verified using v3 scheme .*: true$", verification, re.MULTILINE):
        fail("APK v3 signature is missing")
    cert = re.search(r"^Signer #1 certificate SHA-256 digest: ([0-9a-f]{64})$", verification, re.MULTILINE)
    signers = re.search(r"^Number of signers: (\d+)$", verification, re.MULTILINE)
    if not cert or not signers or signers.group(1) != "1":
        fail("expected exactly one APK signer")
    return {
        "package": m.group(1),
        "version_code": int(m.group(2)),
        "version_name": m.group(3),
        "certificate_sha256": cert.group(1),
        "sha256": digest(apk),
    }


def git_state(root):
    commit = run("git", "rev-parse", "HEAD", cwd=root)
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=all", cwd=root))
    return {"commit": commit, "dirty": dirty}


def toolchain(bt, platform_jar):
    bt = bt.resolve()
    platform_jar = platform_jar.resolve()
    names = ("aapt", "apksigner", "d8", "zipalign")
    tools = {name: digest(bt / name) for name in names}
    return {
        "build_tools_directory": str(bt),
        "build_tool_sha256": tools,
        "platform_jar": str(platform_jar),
        "platform_jar_sha256": digest(platform_jar),
        "javac_version": run("javac", "-version"),
        "aapt_version": run(str(bt / "aapt"), "version"),
        "d8_version": run(str(bt / "d8"), "--version"),
        "apksigner_version": run(str(bt / "apksigner"), "version"),
    }


def snapshot(root, apk, bt, platform_jar, mode):
    version, code = source_version(root)
    metadata = apk_metadata(apk, bt)
    if (metadata["package"], metadata["version_name"], metadata["version_code"]) != (PACKAGE, version, code):
        fail("APK identity/version differs from current source")
    if mode == "release" and metadata["certificate_sha256"] != PINNED_CERT:
        fail("APK certificate differs from pinned release certificate")
    source = git_state(root)
    return {
        "schema": 1,
        "signing_mode": mode,
        "release_eligible": mode == "release" and not source["dirty"],
        "source": source,
        "source_inputs_sha256": source_inputs(root),
        "toolchain": toolchain(bt, platform_jar),
        "apk": metadata,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("create", "verify", "package-inputs"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--build-tools", type=Path)
    parser.add_argument("--platform-jar", type=Path)
    parser.add_argument("--signing-mode", choices=("release", "ci", "local"))
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--allow-test-key", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    apk = args.apk.resolve()
    if args.action == "package-inputs":
        print(json.dumps(package_inputs(root, apk), indent=2, sort_keys=True))
        return
    if args.receipt is None:
        fail("create/verify requires --receipt")
    receipt = args.receipt.resolve()
    if args.action == "create":
        if not (args.build_tools and args.platform_jar and args.signing_mode):
            fail("create requires build tools, platform jar and signing mode")
        value = snapshot(root, apk, args.build_tools, args.platform_jar, args.signing_mode)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        print(f"build receipt: {receipt}")
        return
    try:
        saved = json.loads(receipt.read_text())
    except (OSError, ValueError) as exc:
        fail("missing or malformed receipt: " + str(exc))
    if saved.get("schema") != 1 or saved.get("signing_mode") not in ("release", "ci", "local"):
        fail("unsupported receipt")
    if saved["signing_mode"] != "release" and not args.allow_test_key:
        fail("test/local signing key is not eligible for official release")
    if saved["source"]["dirty"] and not args.allow_dirty:
        fail("APK was built from a dirty checkout")
    if not args.allow_dirty and git_state(root)["dirty"]:
        fail("current checkout is dirty")
    bt = Path(saved["toolchain"]["build_tools_directory"])
    platform_jar = Path(saved["toolchain"]["platform_jar"])
    current = snapshot(root, apk, bt, platform_jar, saved["signing_mode"])
    if current != saved:
        changed = [key for key in saved if saved.get(key) != current.get(key)]
        fail("build inputs/identity changed since receipt: " + ", ".join(changed))
    print("build receipt verified: " + str(receipt))


if __name__ == "__main__":
    main()
