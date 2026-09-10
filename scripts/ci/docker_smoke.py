"""Start the actual production image and verify its local HTTP service and media tools."""

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def run(args: list[str]) -> str:
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="bjj-telestrator:ci")
    args = parser.parse_args()
    name = "bjj-smoke-" + uuid.uuid4().hex
    volume = name + "-data"
    try:
        run(["docker", "volume", "create", volume])
        run(["docker", "run", "-d", "--name", name, "--publish", "127.0.0.1::8000",
             "--volume", volume + ":/data", args.image])
        port = run(["docker", "port", name, "8000/tcp"]).splitlines()[0].rsplit(":", 1)[1]
        base = "http://127.0.0.1:" + port
        deadline = time.monotonic() + 90
        while True:
            try:
                with urllib.request.urlopen(base + "/api/health", timeout=3) as response:
                    health = json.load(response)
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("Production container did not become healthy.") from None
                time.sleep(1)
        if not health.get("ffmpeg") or not health.get("ffprobe"):
            raise RuntimeError("Production FFmpeg/FFprobe are missing.")
        with urllib.request.urlopen(base, timeout=5) as response:
            if 'id="root"' not in response.read().decode():
                raise RuntimeError("Production frontend was not served.")
        with urllib.request.urlopen(base + "/api/projects", timeout=5) as response:
            if json.load(response) != []:
                raise RuntimeError("The isolated test volume was not empty.")
        print("Production Docker startup, frontend, project storage and FFmpeg health passed.")
    except Exception:
        subprocess.run(["docker", "logs", name], check=False)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)
        subprocess.run(["docker", "volume", "rm", volume], capture_output=True, check=False)


if __name__ == "__main__":
    main()
