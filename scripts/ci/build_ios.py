"""Build and package an unsigned device archive and the tested simulator app on macOS."""

import json
import os
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def verify_release_app(app: Path) -> None:
    """Fail closed if the debug UI-test launch hook leaks into a device archive."""
    binary = app / "App"
    if not binary.is_file():
        raise ValueError("The archived app executable is missing.")
    binary_data = binary.read_bytes()
    if any(hook in binary_data for hook in (b"BJJ_UI_TEST_SESSION", b"BJJ_UI_TEST_TIPS")):
        raise ValueError("Debug UI-test fixture code must not ship in a release archive.")
    if any(app.rglob("*.storekit")):
        raise ValueError("Local StoreKit catalogs must not ship in a release archive.")


def main() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("The iOS build requires a macOS Xcode runner.")
    version = json.loads((ROOT / "frontend/package.json").read_text())["version"]
    build = f"{os.environ.get('GITHUB_RUN_NUMBER', '1')}.{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    if not re.fullmatch(r"\d+\.\d+", build):
        raise SystemExit("Invalid build number")
    output = ROOT / ".ci-artifacts/ios"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "App.xcarchive"
    subprocess.run(["xcodebuild", "archive", "-project", str(ROOT / "frontend/ios/App/App.xcodeproj"),
                    "-scheme", "App", "-configuration", "Release", "-destination", "generic/platform=iOS",
                    "-archivePath", str(archive), "-derivedDataPath", str(output / "device-build"),
                    "CODE_SIGNING_ALLOWED=NO", f"MARKETING_VERSION={version.split('-')[0]}",
                    f"CURRENT_PROJECT_VERSION={build}"], check=True, cwd=ROOT)
    verify_release_app(archive / "Products/Applications/App.app")
    simulator = ROOT / ".ci-artifacts/ios-derived/Build/Products/Debug-iphonesimulator/App.app"
    for source, name in [(archive, "unsigned-xcarchive"), (simulator, "simulator")]:
        if not source.exists():
            raise SystemExit(f"Expected build output missing: {source.name}")
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source),
                        str(output / f"bjj-telestrator-{version}-{name}.zip")], check=True)


if __name__ == "__main__":
    main()
