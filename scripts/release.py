#!/usr/bin/env python3
"""Build, Developer ID sign, notarize, and package a release on an ephemeral Mac.

All subprocess output that may contain signing identity or account details is
captured. Only stage names and sanitized failures reach public workflow logs.
Secrets remain in environment variables and a temporary directory/keychain.
This command never installs a driver, changes networking, or publishes a release.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "APP_BUNDLE_ID", "DRIVER_BUNDLE_ID", "APPLE_TEAM_ID",
    "SIGNING_CERTIFICATE_P12_BASE64", "SIGNING_CERTIFICATE_PASSWORD",
    "APP_PROVISIONING_PROFILE_BASE64", "DRIVER_PROVISIONING_PROFILE_BASE64",
    "NOTARY_KEY_P8_BASE64", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID",
)


class ReleaseError(Exception):
    pass


def pci_grant_allows_device(grant, device=0x10FB8086):
    """Understand Apple's IOPCIPrimaryMatch value/mask distribution grants."""
    if grant is True:
        return True
    if not isinstance(grant, list):
        return False
    for entry in grant:
        if not isinstance(entry, dict):
            continue
        match = entry.get("IOPCIPrimaryMatch")
        if not isinstance(match, str):
            continue
        if match == "*":
            return True
        for expression in match.split():
            parts = re.fullmatch(r"0x([0-9a-fA-F]{1,8})(?:&0x([0-9a-fA-F]{1,8}))?", expression)
            if parts:
                value = int(parts[1], 16)
                mask = int(parts[2], 16) if parts[2] else 0xFFFFFFFF
                if device & mask == value:
                    return True
    return False


def run(command, stage, timeout=120):
    try:
        p = subprocess.run([str(x) for x in command], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ReleaseError(f"{stage} could not complete") from None
    if p.returncode:
        raise ReleaseError(f"{stage} failed (exit {p.returncode}; private output withheld)")
    return p.stdout


def validate_profile(profile, bundle, team, kind, certificate_sha1):
    e = profile.get("Entitlements", {})
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise ReleaseError(f"{kind} requires an all-device Developer ID profile")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime) or expiry.replace(tzinfo=dt.timezone.utc) <= dt.datetime.now(dt.timezone.utc):
        raise ReleaseError(f"{kind} provisioning profile has expired or lacks an expiration")
    if team not in profile.get("TeamIdentifier", []):
        raise ReleaseError(f"{kind} profile belongs to a different team")
    app_id = e.get("com.apple.application-identifier", e.get("application-identifier"))
    prefixes = profile.get("ApplicationIdentifierPrefix", [team])
    if app_id not in [prefix + "." + bundle for prefix in prefixes]:
        raise ReleaseError(f"{kind} profile does not match its bundle identifier")
    if e.get("com.apple.security.get-task-allow") or e.get("get-task-allow"):
        raise ReleaseError(f"{kind} profile allows development debugging")
    certs = profile.get("DeveloperCertificates", [])
    if certificate_sha1.lower() not in [hashlib.sha1(c).hexdigest() for c in certs]:
        raise ReleaseError(f"{kind} profile does not authorize the signing certificate")
    if kind == "App":
        if e.get("com.apple.developer.system-extension.install") is not True:
            raise ReleaseError("App profile lacks system-extension installation permission")
    else:
        for key in ("com.apple.developer.driverkit", "com.apple.developer.driverkit.family.networking"):
            if e.get(key) is not True:
                raise ReleaseError("Driver profile lacks DriverKit networking distribution permission")
        pci = e.get("com.apple.developer.driverkit.transport.pci")
        if not pci_grant_allows_device(pci):
            raise ReleaseError("Driver profile does not authorize the supported PCI device")


def configure_source(destination, app_id, driver_id):
    paths = run(["git", "-C", ROOT, "ls-files", "-z"], "List release source").split(b"\0")
    for encoded in paths:
        if not encoded:
            continue
        relative = Path(os.fsdecode(encoded))
        source = ROOT / relative
        if source.is_symlink() or not source.is_file():
            raise ReleaseError("Release source contains an unsupported file type")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    config = destination / "Configuration/SampleCode.xcconfig"
    text = config.read_text()
    for old, new in (("com.example.Lekuo82599App", app_id), ("com.example.Lekuo82599Driver", driver_id)):
        if text.count(old) != 1:
            raise ReleaseError("Expected one public bundle identifier placeholder")
        text = text.replace(old, new)
    config.write_text(text)
    project = destination / "Lekuo82599.xcodeproj/project.pbxproj"
    text = project.read_text()
    old = "path = com.example.Lekuo82599Driver.dext;"
    if text.count(old) != 1:
        raise ReleaseError("Expected one public driver product placeholder")
    project.write_text(text.replace(old, f'path = "{driver_id}.dext";'))


def notarize(path, key, env):
    response = run(["xcrun", "notarytool", "submit", path, "--key", key,
                    "--key-id", env["NOTARY_KEY_ID"], "--issuer", env["NOTARY_ISSUER_ID"],
                    "--wait", "--timeout", "30m", "--output-format", "json"],
                   "Apple notarization", timeout=1900)
    try:
        accepted = json.loads(response).get("status") == "Accepted"
    except (ValueError, AttributeError):
        accepted = False
    if not accepted:
        raise ReleaseError("Apple has not accepted this notarization submission")


def build(version, build_number, output):
    env = os.environ
    for name in REQUIRED:
        if not env.get(name):
            raise ReleaseError(f"Missing environment secret: {name}")
    for name in ("APP_BUNDLE_ID", "DRIVER_BUNDLE_ID"):
        if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", env[name]):
            raise ReleaseError("Invalid bundle identifier configuration")
    if env["APP_BUNDLE_ID"] == env["DRIVER_BUNDLE_ID"] or not re.fullmatch(r"[A-Z0-9]{10}", env["APPLE_TEAM_ID"]):
        raise ReleaseError("Invalid signing team or duplicate bundle identifier")
    output.mkdir(parents=True, exist_ok=True)
    artifact = output / f"Lekuo-Control-{version}.dmg"
    if artifact.exists():
        raise ReleaseError("The release artifact already exists")
    previous = re.findall(r'"([^"\n]+)"', run(["security", "list-keychains", "-d", "user"], "Read keychain list").decode())
    installed = []
    keychain_created = False
    old_umask = os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="lekuo-release-") as tmp:
        work = Path(tmp)
        keychain = work / "signing.keychain-db"
        try:
            print("Preparing isolated signing assets", flush=True)
            assets = {}
            for name, filename in (("SIGNING_CERTIFICATE_P12_BASE64", "identity.p12"),
                                   ("APP_PROVISIONING_PROFILE_BASE64", "app.provisionprofile"),
                                   ("DRIVER_PROVISIONING_PROFILE_BASE64", "driver.provisionprofile"),
                                   ("NOTARY_KEY_P8_BASE64", "notary.p8")):
                path = work / filename
                try:
                    path.write_bytes(base64.b64decode("".join(env[name].split()), validate=True))
                except ValueError:
                    raise ReleaseError(f"Invalid base64 in {name}") from None
                assets[name] = path
            password = secrets.token_urlsafe(32)
            run(["security", "create-keychain", "-p", password, keychain], "Create signing keychain")
            keychain_created = True
            run(["security", "set-keychain-settings", "-lut", "7200", keychain], "Configure signing keychain")
            run(["security", "unlock-keychain", "-p", password, keychain], "Unlock signing keychain")
            run(["security", "import", assets["SIGNING_CERTIFICATE_P12_BASE64"], "-P", env["SIGNING_CERTIFICATE_PASSWORD"],
                 "-k", keychain, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], "Import signing identity")
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain], "Authorize signing tools")
            run(["security", "list-keychains", "-d", "user", "-s", keychain, *previous], "Select signing keychain")
            identities = run(["security", "find-identity", "-v", "-p", "codesigning", keychain], "Inspect signing identity").decode()
            matches = re.findall(r'([A-F0-9]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(env["APPLE_TEAM_ID"]) + r'\)"', identities)
            if len(matches) != 1:
                raise ReleaseError("Expected exactly one valid Developer ID Application identity for this team")
            identity = matches[0]
            profiles = {}
            profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
            profile_dir.mkdir(parents=True, exist_ok=True)
            for kind, secret, bundle in (("App", "APP_PROVISIONING_PROFILE_BASE64", env["APP_BUNDLE_ID"]),
                                         ("Driver", "DRIVER_PROVISIONING_PROFILE_BASE64", env["DRIVER_BUNDLE_ID"])):
                profile = plistlib.loads(run(["security", "cms", "-D", "-i", assets[secret]], "Decode distribution profile"))
                validate_profile(profile, bundle, env["APPLE_TEAM_ID"], kind, identity)
                uuid = profile.get("UUID", "")
                if not re.fullmatch(r"[A-Fa-f0-9-]{36}", uuid):
                    raise ReleaseError("Invalid provisioning profile identifier")
                path = profile_dir / (uuid + ".provisionprofile")
                if path.exists():
                    raise ReleaseError("Use a clean runner; a matching provisioning profile already exists")
                shutil.copyfile(assets[secret], path)
                installed.append(path)
                profiles[kind] = uuid
            source = work / "source"
            source.mkdir()
            configure_source(source, env["APP_BUNDLE_ID"], env["DRIVER_BUNDLE_ID"])
            print("Archiving app, driver, and rollback helper", flush=True)
            archive = work / "LekuoControl.xcarchive"
            run(["xcodebuild", "-project", source / "Lekuo82599.xcodeproj", "-scheme", "Lekuo82599App",
                 "-configuration", "Release", "-destination", "generic/platform=macOS", "-archivePath", archive,
                 "-derivedDataPath", work / "DerivedData", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=" + identity,
                 "DEVELOPMENT_TEAM=" + env["APPLE_TEAM_ID"], "APP_PROVISIONING_PROFILE_SPECIFIER=" + profiles["App"],
                 "DRIVER_PROVISIONING_PROFILE_SPECIFIER=" + profiles["Driver"], "ENABLE_HARDENED_RUNTIME=YES",
                 "OTHER_CODE_SIGN_FLAGS=--timestamp", "MARKETING_VERSION=" + version,
                 "COPY_PHASE_STRIP=YES", "STRIP_INSTALLED_PRODUCT=YES", "DEPLOYMENT_POSTPROCESSING=YES",
                 "CURRENT_PROJECT_VERSION=" + str(build_number), "LEKUO_BUILD_KIND=Release", "archive"],
                "Signed archive", timeout=1800)
            app = archive / "Products/Applications/Lekuo Control.app"
            # Distribution validation is shared with local packaging.
            sys.path.insert(0, str(ROOT / "scripts"))
            from package_local import verify_app
            verify_app(app, version, False)
            print("Notarizing and assessing the app", flush=True)
            zip_path = work / "app.zip"
            run(["ditto", "-c", "-k", "--keepParent", app, zip_path], "Prepare notarization archive")
            notarize(zip_path, assets["NOTARY_KEY_P8_BASE64"], env)
            run(["xcrun", "stapler", "staple", app], "Staple app ticket")
            run(["xcrun", "stapler", "validate", app], "Validate app ticket")
            run(["spctl", "--assess", "--type", "execute", app], "Gatekeeper app assessment")
            print("Packaging signed release", flush=True)
            run([sys.executable, ROOT / "scripts/package_local.py", "--app", app, "--version", version,
                 "--output", output], "Verified DMG packaging", timeout=300)
            run(["codesign", "--force", "--timestamp", "--sign", identity, artifact], "Sign disk image")
            notarize(artifact, assets["NOTARY_KEY_P8_BASE64"], env)
            run(["xcrun", "stapler", "staple", artifact], "Staple disk-image ticket")
            run(["xcrun", "stapler", "validate", artifact], "Validate disk-image ticket")
            run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", artifact], "Gatekeeper disk-image assessment")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            artifact.with_suffix(".dmg.sha256").write_text(f"{digest}  {artifact.name}\n")
            manifest = {"product": "Lekuo Control", "version": version, "build": build_number,
                        "sha256": digest, "artifact": artifact.name, "notarized": True,
                        "commit": run(["git", "-C", ROOT, "rev-parse", "HEAD"], "Read source revision").decode().strip()}
            (output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
            for path in output.iterdir():
                path.chmod(0o644)
            print("Release passed signature, profile, notarization, and Gatekeeper checks", flush=True)
        finally:
            # Attempt every cleanup even if an earlier cleanup fails. Never
            # leave signing assets behind because restoring the search list failed.
            cleanup_failed = False
            for path in installed:
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    cleanup_failed = True
            if keychain_created:
                for command, label in (
                    (["security", "list-keychains", "-d", "user", "-s", *previous], "Restore keychain list"),
                    (["security", "delete-keychain", keychain], "Remove signing keychain"),
                ):
                    try:
                        run(command, label)
                    except ReleaseError:
                        cleanup_failed = True
            os.umask(old_umask)
            if cleanup_failed:
                raise ReleaseError("Signing cleanup failed; discard this runner before reuse")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"\d{4}\.\d{2}\.\d{2}", args.version):
            raise ReleaseError("Version must use YYYY.MM.DD")
        dt.datetime.strptime(args.version, "%Y.%m.%d")
        if args.build < 1:
            raise ReleaseError("Build number must be positive")
        build(args.version, args.build, args.output.resolve())
        return 0
    except ReleaseError as e:
        print(f"Release failed: {e}", file=sys.stderr)
    except Exception as e:
        print(f"Release failed: {type(e).__name__}; private details withheld", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
