import tempfile
import unittest
from pathlib import Path

from scripts.ci.build_ios import verify_release_app
from scripts.test_ios import choose_simulator


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

    def test_release_archive_rejects_tip_fixture_and_local_catalog(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / "App").write_bytes(b"native executable BJJ_UI_TEST_TIPS")
            with self.assertRaises(ValueError):
                verify_release_app(app)
            (app / "App").write_bytes(b"native executable")
            (app / "FreshFrameTips.storekit").write_text("{}")
            with self.assertRaises(ValueError):
                verify_release_app(app)

    def test_simulator_selection_avoids_storekit_regression(self):
        def device(name, state="Shutdown"):
            return {"name": "iPhone " + name, "udid": name, "state": state, "isAvailable": True}
        available = {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [device("bad", "Booted")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [device("compatible")],
        }
        self.assertEqual(choose_simulator(available)["udid"], "compatible")
        available["com.apple.CoreSimulator.SimRuntime.iOS-26-6"] = [device("latest")]
        self.assertEqual(choose_simulator(available)["udid"], "latest")
        with self.assertRaises(ValueError):
            choose_simulator({"com.apple.CoreSimulator.SimRuntime.iOS-26-4-1": [device("bad")]})

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
