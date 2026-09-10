"""Opt-in upload of a signed App Store IPA; does not submit a production App Store release."""

import base64
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    if os.environ.get("IOS_EXPORT_METHOD") != "app-store-connect":
        raise SystemExit("TestFlight upload requires the app-store-connect export method.")
    key_id = os.environ.get("ASC_API_KEY_ID", "")
    issuer = os.environ.get("ASC_API_ISSUER_ID", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id) or not re.fullmatch(r"[0-9a-fA-F-]{36}", issuer):
        raise SystemExit("Set a valid App Store Connect team API key ID and issuer ID.")
    ipas = list((ROOT / ".ci-artifacts/signed").glob("*-app-store-connect.ipa"))
    if len(ipas) != 1:
        raise SystemExit("Exactly one signed App Store IPA is required.")
    with tempfile.TemporaryDirectory(prefix="bjj-upload-", dir=os.environ.get("RUNNER_TEMP")) as folder:
        keys = Path(folder) / "private_keys"
        keys.mkdir(mode=0o700)
        key = keys / f"AuthKey_{key_id}.p8"
        key.write_bytes(base64.b64decode(os.environ["ASC_API_KEY_P8_BASE64"], validate=True))
        key.chmod(0o600)
        subprocess.run(["xcrun", "altool", "--upload-app", "-f", str(ipas[0]), "-t", "ios",
                        "--apiKey", key_id, "--apiIssuer", issuer], cwd=folder, check=True)
    print("Upload accepted. Wait for Apple processing, then add the build to your TestFlight tester group.")


if __name__ == "__main__":
    main()
