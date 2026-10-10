"""Exercise unsafe profile rejection and privacy checks without signing keys."""
import copy
import datetime as dt
import hashlib
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import ReleaseError, configure_pci_entitlement, validate_profile
from package_local import PackageError, require_matching_pci_grant
from check_public_source import findings


class DistributionProfiles(unittest.TestCase):
    def setUp(self):
        self.team = "EXAMPLETEAM"
        self.bundle = "com.example.driver"
        self.certificate = b"synthetic certificate for validation fixture"
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest()
        self.profile = {
            "ProvisionsAllDevices": True,
            "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30),
            "TeamIdentifier": [self.team],
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {
                "com.apple.application-identifier": self.team + "." + self.bundle,
                "com.apple.developer.driverkit": True,
                "com.apple.developer.driverkit.family.networking": True,
                "com.apple.developer.driverkit.transport.pci": [{"IOPCIPrimaryMatch": "0x10fb8086"}],
            },
        }

    def validate(self, profile):
        validate_profile(profile, self.bundle, self.team, "Driver", self.fingerprint)

    def test_distribution_profile(self):
        self.validate(self.profile)

    def test_apple_vendor_mask_grant(self):
        p = copy.deepcopy(self.profile)
        key = "com.apple.developer.driverkit.transport.pci"
        p["Entitlements"][key] = [{"IOPCIPrimaryMatch": "0x00008086&0x0000FFFF"}]
        self.validate(p)
        for match in ("0x00008087&0x0000FFFF", "0x00008086&invalid", "0x10fa8086"):
            p["Entitlements"][key] = [{"IOPCIPrimaryMatch": match}]
            with self.assertRaises(ReleaseError):
                self.validate(p)

    def test_runtime_rejects_narrower_signed_pci_expression(self):
        key = "com.apple.developer.driverkit.transport.pci"
        grant = [{"IOPCIPrimaryMatch": "0x00008086&0x0000FFFF"}]
        with self.assertRaises(PackageError):
            require_matching_pci_grant(self.profile["Entitlements"], {key: grant})
        require_matching_pci_grant({key: grant}, {key: grant})
        with self.assertRaises(PackageError):
            require_matching_pci_grant({}, {})

    def test_configure_only_pci_entitlement_from_profile(self):
        key = "com.apple.developer.driverkit.transport.pci"
        p = copy.deepcopy(self.profile)
        p["Entitlements"][key] = [{"IOPCIPrimaryMatch": "0x00008086&0x0000FFFF"}]
        original = {key: [{"IOPCIPrimaryMatch": "0x10fb8086"}],
                    "com.apple.developer.driverkit": True,
                    "com.apple.developer.driverkit.family.networking": True}
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            path = source / "Lekuo82599/Lekuo82599.entitlements"
            path.parent.mkdir()
            path.write_bytes(plistlib.dumps(original))
            configure_pci_entitlement(source, p)
            configured = plistlib.loads(path.read_bytes())
            self.assertEqual(configured, {**original, key: p["Entitlements"][key]})
            require_matching_pci_grant(configured, p["Entitlements"])
            p["Entitlements"][key] = [{"IOPCIPrimaryMatch": "0x00008087&0x0000FFFF"}]
            with self.assertRaises(ReleaseError):
                configure_pci_entitlement(source, p)

    def test_reject_development_expired_wrong_team_or_certificate(self):
        changes = [
            {"ProvisionsAllDevices": False},
            {"ProvisionedDevices": ["example-device"]},
            {"ExpirationDate": dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)},
            {"TeamIdentifier": ["OTHERTEAM"]},
            {"DeveloperCertificates": [b"another certificate"]},
        ]
        for change in changes:
            with self.subTest(change=list(change)):
                p = copy.deepcopy(self.profile)
                p.update(change)
                with self.assertRaises(ReleaseError):
                    self.validate(p)

    def test_reject_wrong_device_debugging_and_missing_networking(self):
        changes = [
            {"com.apple.developer.driverkit.transport.pci": [{"IOPCIPrimaryMatch": "0x00000000"}]},
            {"com.apple.security.get-task-allow": True},
            {"com.apple.developer.driverkit.family.networking": False},
            {"com.apple.application-identifier": self.team + ".com.example.other"},
        ]
        for change in changes:
            p = copy.deepcopy(self.profile)
            p["Entitlements"].update(change)
            with self.assertRaises(ReleaseError):
                self.validate(p)


class PublicationPrivacy(unittest.TestCase):
    def test_sensitive_formats(self):
        samples = [b"-----BEGIN " + b"PRIVATE KEY-----", b"ghp_" + b"x" * 40,
                   b"person" + b"@private.test", b"192" + b".168.1.8",
                   b"/" + b"Users/example/private"]
        for data in samples:
            self.assertTrue(findings("source.swift", data))

    def test_credential_and_capture_files(self):
        for suffix in (".p8", ".p12", ".keychain-db", ".provisionprofile", ".pcap"):
            self.assertTrue(findings("file" + suffix, b"opaque"))

    def test_public_noreply_attribution(self):
        self.assertFalse(findings("README.md", b"example@users.noreply.github.com"))


if __name__ == "__main__":
    unittest.main()
