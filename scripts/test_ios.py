"""Run the real native iOS acceptance tests on an available iPhone simulator.

Requires macOS, Xcode 26+, an installed iOS 17+ simulator, and npm run ios:sync.
No signing credentials are required for simulator tests. Device installation is separate.
"""

import argparse
import json
import platform
import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]



def choose_simulator(available: dict) -> dict:
    """Avoid the documented StoreKitTest service regression in iOS 26.3–26.5.

    https://developer.apple.com/forums/thread/826971
    Select the newest compatible installed runtime; never skip purchase tests.
    """
    candidates = []
    for runtime, devices in available.items():
        match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version < (17, 0, 0) or (26, 3, 0) <= version < (26, 6, 0):
            continue
        for device in devices:
            if "iPhone" in device["name"] and device.get("isAvailable"):
                candidates.append({**device, "runtime": runtime, "version": version})
    if not candidates:
        raise ValueError("Install a compatible iPhone simulator (for example iOS 26.2 or 26.6+). "
                         "iOS 26.3–26.5 has a known StoreKitTest connection failure. No tests were skipped.")
    return max(candidates, key=lambda d: (d["version"], d.get("state") == "Booted"))


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
        print("Installed simulator runtimes: " + ", ".join(available), flush=True)
        candidate = choose_simulator(available)
        device = candidate["udid"]
        print(f"Using {candidate['name']} ({device}), {candidate['runtime']}", flush=True)
    output = ROOT / "tests/generated" / ("ios-" + datetime.now(UTC).strftime("%Y%m%d-%H%M%S") + ".xcresult")
    output = args.result_bundle or output
    output.parent.mkdir(parents=True, exist_ok=True)
    tests = subprocess.run(
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
        check=False,
    )
    if output.exists():
        subprocess.run([
            "xcrun", "xcresulttool", "export", "attachments", "--path", str(output),
            "--output-path", str(ROOT / ".ci-artifacts/native-screenshots"),
        ], check=True, cwd=ROOT)
    tests.check_returncode()
    print(f"Native simulator tests passed. Results: {output}")


if __name__ == "__main__":
    main()
