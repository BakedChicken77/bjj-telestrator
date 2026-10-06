"""Fetch and sanitize TestFlight beta feedback for the existing app.

Read-only: never deletes feedback, creates testers, or changes App Store Connect state.
Runs only in the protected ios-release GitHub environment.
"""

import base64
import json
import os
import tempfile
from pathlib import Path
from urllib.request import urlopen

from distribute_testflight import APP, AppleAPI

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".ci-artifacts" / "testflight-feedback"


def rel_id(item, name):
    return (((item.get("relationships") or {}).get(name) or {}).get("data") or {}).get("id")


def sanitize(items, builds):
    result = []
    for item in items:
        attrs = item.get("attributes") or {}
        build_id = rel_id(item, "build")
        build = builds.get(build_id, {})
        result.append(
            {
                "id": item.get("id"),
                "createdDate": attrs.get("createdDate"),
                "comment": attrs.get("comment"),
                "deviceModel": attrs.get("deviceModel"),
                "osVersion": attrs.get("osVersion"),
                "locale": attrs.get("locale"),
                "timeZone": attrs.get("timeZone"),
                "appUptimeInMilliseconds": attrs.get("appUptimeInMilliseconds"),
                "batteryPercentage": attrs.get("batteryPercentage"),
                "screenWidthInPoints": attrs.get("screenWidthInPoints"),
                "screenHeightInPoints": attrs.get("screenHeightInPoints"),
                "connectionType": attrs.get("connectionType"),
                "screenshots": attrs.get("screenshots"),
                "buildId": build_id,
                "buildVersion": build.get("version"),
                "buildUploadedDate": build.get("uploadedDate"),
            }
        )
    result.sort(key=lambda x: x.get("createdDate") or "", reverse=True)
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fresh-frame-feedback-", dir=os.environ.get("RUNNER_TEMP")) as folder:
        key = Path(folder) / "key.p8"
        key.write_bytes(base64.b64decode(os.environ["ASC_API_KEY_P8_BASE64"], validate=True))
        key.chmod(0o600)
        api = AppleAPI(key, os.environ["ASC_API_KEY_ID"], os.environ["ASC_API_ISSUER_ID"])

        screenshot_path = (
            f"/v1/apps/{APP}/betaFeedbackScreenshotSubmissions?"
            "include=build&limit=200&"
            "fields[betaFeedbackScreenshotSubmissions]="
            "createdDate,comment,deviceModel,osVersion,locale,timeZone,connectionType,"
            "appUptimeInMilliseconds,batteryPercentage,screenWidthInPoints,screenHeightInPoints,"
            "screenshots,build"
            "&fields[builds]=version,uploadedDate"
        )
        response = api.request(screenshot_path)
        builds = {
            item["id"]: item.get("attributes") or {}
            for item in response.get("included", [])
            if item.get("type") == "builds"
        }
        screenshot_feedback = sanitize(response.get("data", []), builds)

        # Crash feedback is useful context, but do not download crash logs or tester email.
        crash_feedback = []
        try:
            crash = api.request(f"/v1/apps/{APP}/betaFeedbackCrashSubmissions?include=build&limit=200")
            crash_builds = {
                item["id"]: item.get("attributes") or {}
                for item in crash.get("included", [])
                if item.get("type") == "builds"
            }
            crash_feedback = sanitize(crash.get("data", []), crash_builds)
        except RuntimeError:
            # Screenshot feedback is the requested source; lack of crash-feedback permission
            # should not prevent reviewing the user's submitted notes.
            pass

        for item in screenshot_feedback:
            for index, shot in enumerate(item.get("screenshots") or []):
                url = shot.get("url")
                if not url:
                    continue
                target = OUT / f"{item['id']}-{index}.jpg"
                with urlopen(url, timeout=60) as response:
                    target.write_bytes(response.read())

        payload = {
            "appId": APP,
            "screenshotFeedback": screenshot_feedback,
            "crashFeedback": crash_feedback,
        }
        (OUT / "latest.json").write_text(json.dumps(payload, indent=2) + "\n")
        print(
            f"Fetched {len(screenshot_feedback)} screenshot feedback item(s) and "
            f"{len(crash_feedback)} crash feedback item(s)."
        )


if __name__ == "__main__":
    main()
