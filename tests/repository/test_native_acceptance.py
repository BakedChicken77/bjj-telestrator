import tempfile
import unittest
from pathlib import Path

from scripts.ci.build_ios import verify_release_app


class NativeAcceptanceTests(unittest.TestCase):
    def test_release_archive_rejects_debug_fixture_hook(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            with self.assertRaises(ValueError):
                verify_release_app(app)
            (app / "App").write_bytes(b"native executable")
            verify_release_app(app)
            (app / "App").write_bytes(b"native executable BJJ_UI_TEST_SESSION")
            with self.assertRaises(ValueError):
                verify_release_app(app)

    def test_native_ui_runner_remains_in_required_scheme(self):
        root = Path(__file__).resolve().parents[2]
        scheme = (root / "frontend/ios/App/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme").read_text()
        self.assertIn('BlueprintName="AppUITests"', scheme)
        self.assertIn('BlueprintName="AppTests"', scheme)
        fixture = (root / "frontend/ios/App/App/Native/BJJUITestFixture.swift").read_text()
        self.assertTrue(fixture.startswith("#if DEBUG\n"))
        self.assertIn('UUID(uuidString: value)', fixture)


if __name__ == "__main__":
    unittest.main()
