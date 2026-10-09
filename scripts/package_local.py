#!/usr/bin/env python3
"""Verify an existing signed Lekuo Control app and package it locally.

This script never builds, activates, signs, notarizes, or publishes software.
Signing identities and provisioning-device identifiers are kept out of output.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import pathlib
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, replace


APP_ENTITLEMENT = "com.apple.developer.system-extension.install"
DRIVER_ENTITLEMENTS = (
    "com.apple.developer.driverkit",
    "com.apple.developer.driverkit.family.networking",
    "com.apple.developer.driverkit.transport.pci",
)
SOURCE_PATH_PATTERN = re.compile(rb"/" + rb"Users/[^/\x00\r\n]+/")
FORBIDDEN_COMPONENTS = {".git", ".svn", ".hg", "DerivedData"}
FORBIDDEN_SUFFIXES = {".p12", ".p8", ".pem", ".key", ".dSYM", ".xcarchive"}


class PackageError(Exception):
    """A safe-to-display packaging failure."""


@dataclass(frozen=True)
class VerifiedApp:
    app_name: str
    driver_name: str
    minimum_macos: str
    common_device_count: int | None


def run(args: list[str], label: str) -> bytes:
    """Run array arguments without emitting tool paths or signing metadata."""
    try:
        result = subprocess.run(args, capture_output=True, check=False)
    except OSError as error:
        raise PackageError(f"{label} could not start.") from error
    if result.returncode:
        raise PackageError(f"{label} failed (exit status {result.returncode}).")
    return result.stdout


def load_plist(path: pathlib.Path, label: str) -> dict:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise PackageError(f"{label} is missing or invalid.") from error
    if not isinstance(value, dict):
        raise PackageError(f"{label} is invalid.")
    return value


def bundle_info(bundle: pathlib.Path, label: str) -> tuple[dict, pathlib.Path]:
    candidates = [bundle / "Contents" / "Info.plist", bundle / "Info.plist"]
    for candidate in candidates:
        if candidate.is_file():
            return load_plist(candidate, label), candidate.parent
    raise PackageError(f"{label} is missing.")


def entitlement_data(path: pathlib.Path, label: str) -> dict:
    data = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(path)], label)
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise PackageError(f"{label} could not be read.") from error
    if not isinstance(value, dict):
        raise PackageError(f"{label} is invalid.")
    return value


def signing_team(path: pathlib.Path, development: bool, label: str, expected_identifier: str | None = None) -> str:
    # codesign writes identity metadata to stderr. Inspect it without displaying it.
    try:
        result = subprocess.run(
            ["/usr/bin/codesign", "--display", "--verbose=4", str(path)],
            capture_output=True, check=False,
        )
    except OSError as error:
        raise PackageError(f"{label} could not be inspected.") from error
    if result.returncode:
        raise PackageError(f"{label} could not be inspected.")
    details = result.stderr.decode("utf-8", errors="replace")
    team_match = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", details, re.MULTILINE)
    authority = "Apple Development:" if development else "Developer ID Application:"
    if team_match is None or not any(
        line.startswith("Authority=" + authority) for line in details.splitlines()
    ):
        kind = "Apple Development" if development else "Developer ID Application"
        raise PackageError(f"{label} requires a {kind} signature with an Apple team.")
    if expected_identifier is not None:
        identifier_match = re.search(r"^Identifier=(.+)$", details, re.MULTILINE)
        if identifier_match is None or identifier_match.group(1) != expected_identifier:
            raise PackageError(f"{label} identifier does not match this app.")
    return team_match.group(1)


def embedded_profile(root: pathlib.Path, label: str) -> dict:
    path = root / "embedded.provisionprofile"
    if not path.is_file():
        raise PackageError(f"{label} is missing.")
    decoded = run(["/usr/bin/security", "cms", "-D", "-i", str(path)], label)
    try:
        profile = plistlib.loads(decoded)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise PackageError(f"{label} is invalid.") from error
    if not isinstance(profile, dict):
        raise PackageError(f"{label} is invalid.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise PackageError(f"{label} has no valid expiration date.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        raise PackageError(f"{label} has expired.")
    return profile


def require_driver_entitlements(entitlements: dict, label: str) -> None:
    if any(entitlements.get(key) is not True for key in DRIVER_ENTITLEMENTS[:2]):
        raise PackageError(f"{label} lacks DriverKit or networking access.")
    pci = entitlements.get(DRIVER_ENTITLEMENTS[2])
    if pci is not True and not (isinstance(pci, (list, dict)) and pci):
        raise PackageError(f"{label} lacks PCI access.")


def profile_devices(profile: dict, development: bool, label: str) -> set[str]:
    if not development:
        if profile.get("ProvisionsAllDevices") is not True:
            raise PackageError(f"{label} requires an all-device distribution profile.")
        return set()
    devices = profile.get("ProvisionedDevices")
    if (
        profile.get("ProvisionsAllDevices") is True
        or not isinstance(devices, list)
        or not devices
        or any(not isinstance(device, str) or not device for device in devices)
    ):
        raise PackageError(f"{label} requires registered development Macs.")
    return set(devices)


def check_private_source_paths(app: pathlib.Path) -> None:
    """Reject source paths/keys without altering any signed bundle contents."""
    root = app.resolve()
    for path in app.rglob("*"):
        if path.name in FORBIDDEN_COMPONENTS or path.suffix in FORBIDDEN_SUFFIXES:
            raise PackageError("The app contains source-control, build, or private key material.")
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(root)
            except (OSError, ValueError) as error:
                raise PackageError("The app contains a link outside its bundle.") from error
        if not path.is_file():
            continue
        # Signed profiles and signature resources intrinsically contain identity data.
        if path.name == "embedded.provisionprofile" or "_CodeSignature" in path.parts:
            continue
        try:
            with path.open("rb") as source:
                overlap = b""
                while chunk := source.read(1_048_576):
                    if SOURCE_PATH_PATTERN.search(overlap + chunk):
                        raise PackageError("The app contains a private source path; rebuild with path remapping.")
                    overlap = chunk[-4096:]
        except OSError as error:
            raise PackageError("The app contents could not be inspected.") from error


def verify_app(app: pathlib.Path, version: str, development: bool) -> VerifiedApp:
    if not app.is_dir() or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]*\.app", app.name):
        raise PackageError("The input must be an existing app bundle with a normal app filename.")
    info, app_root = bundle_info(app, "App information")
    app_identifier = info.get("CFBundleIdentifier")
    if not isinstance(app_identifier, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", app_identifier):
        raise PackageError("The app identifier is missing or invalid.")
    if info.get("CFBundleShortVersionString") != version:
        raise PackageError("The app version does not match the requested date version.")
    extension_dir = app / "Contents" / "Library" / "SystemExtensions"
    drivers = list(extension_dir.glob("*.dext"))
    if len(drivers) != 1 or not drivers[0].is_dir():
        raise PackageError("The app must contain exactly one DriverKit extension.")
    driver = drivers[0]
    driver_info, driver_root = bundle_info(driver, "Driver information")
    if driver_info.get("CFBundleShortVersionString") != version:
        raise PackageError("The driver version does not match the requested date version.")
    if info.get("LekuoDriverBundleIdentifier") != driver_info.get("CFBundleIdentifier"):
        raise PackageError("The app does not identify its embedded driver correctly.")
    helper = app / "Contents" / "Helpers" / "LekuoMTUWatchdog"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise PackageError("The signed MTU rollback helper is missing or not executable.")

    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], "App signature verification")
    run(["/usr/bin/codesign", "--verify", "--strict", str(driver)], "Driver signature verification")
    run(["/usr/bin/codesign", "--verify", "--strict", str(helper)], "Rollback helper signature verification")
    app_entitlements = entitlement_data(app, "App entitlements")
    driver_entitlements = entitlement_data(driver, "Driver entitlements")
    if app_entitlements.get(APP_ENTITLEMENT) is not True:
        raise PackageError("The app lacks permission to install a system extension.")
    require_driver_entitlements(driver_entitlements, "The driver")
    if not development and any(
        entitlements.get("com.apple.security.get-task-allow") is True
        for entitlements in (app_entitlements, driver_entitlements)
    ):
        raise PackageError("A distribution candidate must not allow development debugging.")
    teams = {
        signing_team(path, development, label,
                     expected_identifier=app_identifier + ".MTUWatchdog" if path == helper else None)
        for path, label in (
            (app, "App signing"), (driver, "Driver signing"), (helper, "Helper signing")
        )
    }
    if len(teams) != 1:
        raise PackageError("The app, driver, and helper must be signed by the same Apple team.")
    team = next(iter(teams))
    profiles = (
        (embedded_profile(app_root, "App profile"), info, "App profile"),
        (embedded_profile(driver_root, "Driver profile"), driver_info, "Driver profile"),
    )
    device_sets: list[set[str]] = []
    for profile, bundle, label in profiles:
        if team not in profile.get("TeamIdentifier", []):
            raise PackageError(f"{label} belongs to a different signing team.")
        entitlements = profile.get("Entitlements", {})
        if not isinstance(entitlements, dict):
            raise PackageError(f"{label} has invalid entitlements.")
        application_id = entitlements.get("com.apple.application-identifier") or entitlements.get("application-identifier", "")
        if not isinstance(application_id, str) or not application_id.endswith("." + str(bundle.get("CFBundleIdentifier"))):
            raise PackageError(f"{label} does not match its bundle.")
        if label == "App profile":
            if entitlements.get(APP_ENTITLEMENT) is not True:
                raise PackageError("The app profile lacks system-extension installation access.")
        else:
            require_driver_entitlements(entitlements, "The driver profile")
        device_sets.append(profile_devices(profile, development, label))
    common_count = None
    if development:
        common_count = len(device_sets[0] & device_sets[1])
        if not common_count:
            raise PackageError("The app and driver profiles have no registered Mac in common.")
    check_private_source_paths(app)
    minimum = info.get("LSMinimumSystemVersion", "27.0")
    if not isinstance(minimum, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", minimum):
        raise PackageError("The minimum macOS version is invalid.")
    return VerifiedApp(app.name, driver.name, minimum, common_count)


def install_notes(verified: VerifiedApp, version: str, development: bool) -> str:
    app_path = "/Applications/" + verified.app_name
    common = verified.common_device_count
    signing_note = (
        f"PRIVATE DEVELOPMENT PREVIEW — registered Macs only.\n"
        f"The app and driver profiles cover {common} registered Mac(s) in common.\n"
        "Apple Development signed. This app and disk image are not notarized.\n"
        "Signed development artifacts contain developer certificate identity and\n"
        "registered hardware identifiers in embedded profiles. Keep this preview private.\n"
        if development else
        "DEVELOPER ID BUILD\n"
        "The app, driver, and helper have Developer ID signatures. Official release\n"
        "downloads also complete Apple notarization and Gatekeeper verification.\n"
        "A locally packaged candidate must complete those checks before distribution.\n"
    )
    gatekeeper_note = (
        "\nIf Gatekeeper blocks this development preview, first verify that you trust\n"
        "the build and its source. After copying the app, you may explicitly remove\n"
        "its downloaded-file quarantine in Terminal:\n\n"
        f"    xattr -dr com.apple.quarantine {shlex.quote(app_path)}\n\n"
        "This is an optional action for this trusted development build. It is not\n"
        "performed by the installer and is not needed for a normal notarized release.\n"
        if development else ""
    )
    return (
        f"Lekuo Control {version}\n\n{signing_note}\n"
        f"Requires macOS {verified.minimum_macos} or later and a compatible Intel 82599 enclosure.\n\n"
        "INSTALLATION\n"
        f"1. Drag {verified.app_name} to the Applications shortcut.\n"
        f"2. Open {app_path}.\n"
        "3. Click Install Driver.\n"
        "4. When requested, open System Settings → General → Login Items & Extensions\n"
        "   → Driver Extensions, enable Lekuo Control, and click Done.\n"
        "5. If macOS reports that a restart is required, restart when convenient.\n\n"
        "Keep an alternate network connection available while activating the driver.\n"
        "Jumbo packets require a compatible receiver and network path. Packet-size\n"
        "changes affect the selected adapter on this Mac and use an automatic rollback trial.\n"
        f"{gatekeeper_note}\n"
        "REMOVAL\n"
        "Use Driver Actions → Uninstall Driver in Lekuo Control, and finish any macOS\n"
        "approval or requested restart before removing the app.\n\n"
        "VERIFICATION\n"
        "The package was checked for disk-image integrity and app, driver, and rollback\n"
        "helper signatures after a read-only mount. Signature checks do not guarantee\n"
        "hardware compatibility or Gatekeeper acceptance. The companion SHA-256 file\n"
        "contains the checksum and the disk-image filename, without a local source path.\n"
    )


def verify_image(image: pathlib.Path, mountpoint: pathlib.Path, verified: VerifiedApp, version: str, development: bool, notes: str) -> None:
    attached = False
    try:
        run(
            ["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mountpoint), "-plist", str(image)],
            "Read-only disk-image mount",
        )
        attached = True
        copied = verify_app(mountpoint / verified.app_name, version, development)
        if copied != verified:
            raise PackageError("The mounted app does not match the verified source app.")
        shortcut = mountpoint / "Applications"
        if not shortcut.is_symlink() or os.readlink(shortcut) != "/Applications":
            raise PackageError("The Applications shortcut is invalid.")
        if (mountpoint / "INSTALL.txt").read_text(encoding="utf-8") != notes:
            raise PackageError("The mounted installation notes are invalid.")
        source_root = pathlib.Path(__file__).resolve().parents[1]
        for name in ("LICENSE.txt", "IXY-LICENSE.txt"):
            if (mountpoint / "Licenses" / name).read_bytes() != (source_root / name).read_bytes():
                raise PackageError("The mounted license notices are invalid.")
    finally:
        if attached or os.path.ismount(mountpoint):
            try:
                run(["/usr/bin/hdiutil", "detach", str(mountpoint)], "Disk-image cleanup")
            except PackageError:
                run(["/usr/bin/hdiutil", "detach", "-force", str(mountpoint)], "Disk-image cleanup")


def publish_local(image: pathlib.Path, destination: pathlib.Path, checksum: str) -> None:
    """Publish both local files exclusively, refusing to replace existing files."""
    checksum_path = destination.with_name(destination.name + ".sha256")
    if destination.exists() or checksum_path.exists():
        raise PackageError("A package or checksum already exists; choose a new output directory.")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".lekuo-package-", dir=destination.parent)
    temporary_path = pathlib.Path(temporary_name)
    created_image = False
    created_checksum = False
    try:
        with os.fdopen(descriptor, "wb") as output, image.open("rb") as source:
            shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
        temporary_path.chmod(0o644)
        os.link(temporary_path, destination)
        created_image = True
        with checksum_path.open("x", encoding="utf-8") as output:
            created_checksum = True
            output.write(f"{checksum}  {destination.name}\n")
    except (OSError, ValueError) as error:
        if created_checksum:
            checksum_path.unlink(missing_ok=True)
        if created_image:
            destination.unlink(missing_ok=True)
        raise PackageError("The package could not be saved without replacing existing files.") from error
    finally:
        temporary_path.unlink(missing_ok=True)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify an existing signed Lekuo Control app and create a local DMG and checksum. No build, signing, activation, notarization, or publishing is performed.",
    )
    parser.add_argument("--app", required=True, type=pathlib.Path, help="Existing signed app bundle")
    parser.add_argument("--version", required=True, help="App and driver date version, YYYY.MM.DD")
    parser.add_argument("--output", required=True, type=pathlib.Path, help="Local destination directory; existing package files are never replaced")
    parser.add_argument("--development", action="store_true", help="Package an Apple Development signed preview for registered Macs only")
    result = parser.parse_args()
    if not re.fullmatch(r"\d{4}\.\d{2}\.\d{2}", result.version):
        parser.error("--version must use YYYY.MM.DD")
    try:
        dt.datetime.strptime(result.version, "%Y.%m.%d")
    except ValueError:
        parser.error("--version must be a valid calendar date")
    return result


def main() -> int:
    args = arguments()
    try:
        app = args.app.expanduser().resolve(strict=True)
        output = args.output.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=True)
        suffix = "-dev" if args.development else ""
        filename = f"Lekuo-Control-{args.version}{suffix}.dmg"
        destination = output / filename
        if destination.exists() or destination.with_name(filename + ".sha256").exists():
            raise PackageError("A package or checksum already exists; choose a new output directory.")
        verified = verify_app(app, args.version, args.development)
        verified = replace(verified, app_name="Lekuo Control.app")
        notes = install_notes(verified, args.version, args.development)
        with tempfile.TemporaryDirectory(prefix="lekuo-local-package-") as temporary:
            root = pathlib.Path(temporary)
            staging = root / "staging"
            staging.mkdir()
            run(["/usr/bin/ditto", str(app), str(staging / verified.app_name)], "App staging")
            licenses = staging / "Licenses"
            licenses.mkdir()
            source_root = pathlib.Path(__file__).resolve().parents[1]
            for license_name in ("LICENSE.txt", "IXY-LICENSE.txt"):
                (licenses / license_name).write_bytes((source_root / license_name).read_bytes())
            (staging / "Applications").symlink_to("/Applications")
            (staging / "INSTALL.txt").write_text(notes, encoding="utf-8")
            verify_app(staging / verified.app_name, args.version, args.development)
            image = root / filename
            run(
                ["/usr/bin/hdiutil", "create", "-volname", f"Lekuo Control {args.version}{suffix}", "-srcfolder", str(staging), "-format", "UDZO", str(image)],
                "Disk-image creation",
            )
            run(["/usr/bin/hdiutil", "verify", str(image)], "Disk-image integrity verification")
            mountpoint = root / "mounted"
            mountpoint.mkdir()
            verify_image(image, mountpoint, verified, args.version, args.development, notes)
            digest = sha256_file(image)
            publish_local(image, destination, digest)
        print(f"Created {filename} and {filename}.sha256")
        print("Verified app, driver, and rollback helper signatures after a read-only mount.")
        if args.development:
            print(f"Private development preview: registered Macs only ({verified.common_device_count} common registered Mac(s)).")
        else:
            print("Local distribution candidate: DMG signing and notarization still required.")
        return 0
    except PackageError as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
    except (OSError, ValueError) as error:
        # Do not leak signing identities, profile identifiers, or user paths from errors.
        print(f"Packaging failed: local file operation could not complete ({type(error).__name__}).", file=sys.stderr)
    return 1


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1_048_576):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
