"""Security boundaries and packaging invariants for repository automation."""

import hashlib
import json
import tempfile
import unittest
import zipfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

from scripts.ci.release import checksums, safe_member, validate_version, zip_files
from scripts.ci.sign_ios import patch_app_settings, validate_profile

ROOT = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def test_private_and_unsafe_paths_rejected(self):
        for name in ["../secret", "/etc/passwd", "C:/secrets", "a\\b", "", "x\0y", ".env",
                     "a/.env.local", "x.p12", "x.key", "tests/generated/video.mp4", "data/project.json", ".git/config"]:
            with self.subTest(name=name):
                self.assertFalse(safe_member(name))
        self.assertTrue(safe_member(".env.example"))
        self.assertTrue(safe_member("frontend/src/App.tsx"))

    def test_version_matches_all_three_package_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "frontend").mkdir()
            (root / "frontend/package.json").write_text('{"version":"1.1.0"}')
            lock = {"version": "1.1.0", "packages": {"": {"version": "1.1.0"}}}
            (root / "frontend/package-lock.json").write_text(json.dumps(lock))
            (root / "CHANGELOG.md").write_text("## [1.1.0]\n")
            self.assertEqual(validate_version("v1.1.0", root), "1.1.0")
            lock["packages"][""]["version"] = "1.0.0"
            (root / "frontend/package-lock.json").write_text(json.dumps(lock))
            with self.assertRaises(ValueError):
                validate_version("v1.1.0", root)

    def test_zip_is_deterministic_and_checksum_covers_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "file.txt").write_text("verified source\n")
            a, b = root / "a.zip", root / "b.zip"
            zip_files(a, root, ["file.txt"], "app/")
            zip_files(b, root, ["file.txt"], "app/")
            self.assertEqual(a.read_bytes(), b.read_bytes())
            with zipfile.ZipFile(a) as archive:
                self.assertEqual(archive.read("app/file.txt"), b"verified source\n")
            checksums(root)
            self.assertIn(hashlib.sha256(a.read_bytes()).hexdigest() + "  a.zip", (root / "SHA256SUMS.txt").read_text())

    def test_zip_does_not_follow_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "link").symlink_to(ROOT / "README.md")
            with self.assertRaises(ValueError):
                zip_files(root / "out.zip", root, ["link"], "")


class SigningTests(unittest.TestCase):
    def profile(self):
        return {"UUID": "12345678-1234-1234-1234-123456789abc", "TeamIdentifier": ["ABCDEFGHIJ"],
                "ExpirationDate": datetime.now(UTC) + timedelta(days=10),
                "Entitlements": {"application-identifier": "ABCDEFGHIJ.com.example.app", "get-task-allow": False}}

    def test_valid_app_store_profile(self):
        self.assertEqual(validate_profile(self.profile(), "ABCDEFGHIJ", "com.example.app", "app-store-connect"), self.profile()["UUID"])

    def test_expiry_team_and_bundle_mismatch_rejected(self):
        for mutation in [{"ExpirationDate": datetime(2000, 1, 1)}, {"TeamIdentifier": ["OTHERTEAM1"]},
                         {"Entitlements": {"application-identifier": "ABCDEFGHIJ.*"}}, {"UUID": "../../secret"}]:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_profile(self.profile() | mutation, "ABCDEFGHIJ", "com.example.app", "app-store-connect")

    def test_adhoc_requires_registered_devices(self):
        with self.assertRaises(ValueError):
            validate_profile(self.profile(), "ABCDEFGHIJ", "com.example.app", "release-testing")
        profile = self.profile() | {"ProvisionedDevices": ["test-device"]}
        validate_profile(profile, "ABCDEFGHIJ", "com.example.app", "release-testing")
        with self.assertRaises(ValueError):
            validate_profile(profile, "ABCDEFGHIJ", "com.example.app", "app-store-connect")

    def test_settings_patch_only_app_not_dependencies_or_tests(self):
        source = (ROOT / "frontend/ios/App/App.xcodeproj/project.pbxproj").read_text()
        patched = patch_app_settings(source, "ABCDEFGHIJ", "com.example.app", self.profile()["UUID"], "A" * 40)
        self.assertEqual(patched.count('CODE_SIGN_STYLE = "Manual";'), 2)
        self.assertEqual(patched.count('PROVISIONING_PROFILE_SPECIFIER ='), 2)
        self.assertEqual(source.count("CODE_SIGN_STYLE = Automatic;"), patched.count("CODE_SIGN_STYLE = Automatic;") + 2)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.bjjtelestrator.app.tests", patched)
        with self.assertRaises(ValueError):
            patch_app_settings(source, "injection;", "com.example.app", self.profile()["UUID"], "A" * 40)


if __name__ == "__main__":
    unittest.main()
