"""Build and package an unsigned device archive and the tested simulator app on macOS."""

import json
import os
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


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
    simulator = ROOT / ".ci-artifacts/ios-derived/Build/Products/Debug-iphonesimulator/App.app"
    for source, name in [(archive, "unsigned-xcarchive"), (simulator, "simulator")]:
        if not source.exists():
            raise SystemExit(f"Expected build output missing: {source.name}")
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source),
                        str(output / f"bjj-telestrator-{version}-{name}.zip")], check=True)


if __name__ == "__main__":
    main()
