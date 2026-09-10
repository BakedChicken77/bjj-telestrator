"""Run the real native iOS acceptance tests on an available iPhone simulator.

Requires macOS, Xcode 26+, an installed iOS 17+ simulator, and npm run ios:sync.
No signing credentials are required for simulator tests. Device installation is separate.
"""

import argparse
import json
import platform
import subprocess
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Optional simulator UDID, otherwise use the first available iPhone")
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--result-bundle", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Native iOS tests require macOS and Xcode. No native tests were run on this host.")
    if not (ROOT / "frontend/ios/App/App/public/index.html").exists():
        raise SystemExit("Build the bundled editor first: cd frontend && npm ci && npm run ios:sync")
    subprocess.run(["xcodebuild", "-version"], check=True)
    device = args.device
    if not device:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            check=True,
            text=True,
            capture_output=True,
        )
        available = json.loads(result.stdout)["devices"]
        candidates = [
            d
            for runtime, devices in available.items()
            if "iOS" in runtime
            for d in devices
            if "iPhone" in d["name"] and d.get("isAvailable")
        ]
        if not candidates:
            raise SystemExit("Install an iPhone simulator in Xcode Settings → Components, then retry.")
        candidates.sort(key=lambda d: d.get("state") != "Booted")
        device = candidates[0]["udid"]
        print(f"Using {candidates[0]['name']} ({device})", flush=True)
    output = ROOT / "tests/generated" / ("ios-" + datetime.now(UTC).strftime("%Y%m%d-%H%M%S") + ".xcresult")
    output = args.result_bundle or output
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "xcodebuild",
            "test",
            "-project",
            str(ROOT / "frontend/ios/App/App.xcodeproj"),
            "-scheme",
            "App",
            "-destination",
            f"platform=iOS Simulator,id={device}",
            "-resultBundlePath",
            str(output),
            "-test-timeouts-enabled",
            "YES",
            "-default-test-execution-time-allowance",
            "120",
            "-maximum-test-execution-time-allowance",
            "600",
            "-parallel-testing-enabled",
            "NO",
            *(["-derivedDataPath", str(args.derived_data)] if args.derived_data else []),
            "CODE_SIGNING_ALLOWED=NO",
        ],
        cwd=ROOT,
        check=True,
    )
    print(f"Native simulator tests passed. Results: {output}")


if __name__ == "__main__":
    main()
