"""Sign on an isolated macOS runner. Credentials are removed even when Xcode fails."""

import base64
import json
import os
import platform
import plistlib
import re
import secrets
import shlex
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_CONFIGS = ("504EC3171FED79650016851F", "504EC3181FED79650016851F")


def capture(args: list[str]) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # security arguments may contain a password; never print the command or raw result.
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode}). Check signing credentials.")
    return result.stdout.strip()


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"Set {name} in the ios-release environment.")
    return value


def validate_profile(profile: dict, team: str, bundle: str, method: str) -> str:
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
        raise ValueError("Invalid Apple team or bundle identifier")
    if method not in {"app-store-connect", "release-testing"}:
        raise ValueError("IOS_EXPORT_METHOD must be app-store-connect or release-testing")
    entitlements = profile.get("Entitlements", {})
    if team not in profile.get("TeamIdentifier", []):
        raise ValueError("Provisioning profile belongs to another team")
    if entitlements.get("application-identifier") != f"{team}.{bundle}":
        raise ValueError("An explicit provisioning profile matching IOS_BUNDLE_ID is required")
    if entitlements.get("get-task-allow"):
        raise ValueError("Use a distribution profile, not a development profile")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime) or expiry.replace(tzinfo=UTC) <= datetime.now(UTC):
        raise ValueError("Provisioning profile is expired or missing its expiry")
    if method == "release-testing" and not profile.get("ProvisionedDevices"):
        raise ValueError("Ad Hoc release-testing requires registered device identifiers")
    if method == "app-store-connect" and (profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")):
        raise ValueError("Use an App Store Connect distribution profile")
    identifier = profile.get("UUID", "")
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", identifier):
        raise ValueError("Invalid profile UUID")
    return identifier


def patch_app_settings(source: str, team: str, bundle: str, profile: str, identity: str) -> str:
    values = {"CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": team,
              "PRODUCT_BUNDLE_IDENTIFIER": bundle, "PROVISIONING_PROFILE_SPECIFIER": profile,
              "CODE_SIGN_IDENTITY": identity}
    for identifier in APP_CONFIGS:
        pattern = re.compile(r"(" + identifier + r" /\* (?:Debug|Release) \*/ = \{.*?buildSettings = \{)(.*?)(\n\s*\};)", re.S)
        matches = list(pattern.finditer(source))
        if len(matches) != 1:
            raise ValueError("App build configuration changed; update the signing adapter before signing")
        match = matches[0]
        body = match.group(2)
        for key, value in values.items():
            if not re.fullmatch(r"[A-Za-z0-9.-]+", value):
                raise ValueError("Unsafe signing setting")
            body = re.sub(r"\n\s*" + key + r" = [^;]*;", "", body)
            body += f'\n\t\t\t\t{key} = "{value}";'
        source = source[:match.start(2)] + body + source[match.end(2):]
    return source


def main() -> None:
    if platform.system() != "Darwin":
        raise SystemExit("Signing requires the GitHub macOS runner and Apple distribution credentials.")
    team, bundle = required("IOS_TEAM_ID"), required("IOS_BUNDLE_ID")
    method = required("IOS_EXPORT_METHOD")
    version = json.loads((ROOT / "frontend/package.json").read_text())["version"]
    build = f"{os.environ.get('GITHUB_RUN_NUMBER', '1')}.{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    if not re.fullmatch(r"\d+\.\d+", build):
        raise ValueError("Invalid build number")
    project = ROOT / "frontend/ios/App/App.xcodeproj/project.pbxproj"
    original = project.read_text()
    old_keychains = shlex.split(capture(["security", "list-keychains", "-d", "user"]))
    profile_destination = None
    previous_profile = None
    with tempfile.TemporaryDirectory(prefix="bjj-sign-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        folder = Path(temporary)
        certificate, profile_file = folder / "certificate.p12", folder / "profile.mobileprovision"
        for file, variable in [(certificate, "IOS_CERTIFICATE_BASE64"), (profile_file, "IOS_PROFILE_BASE64")]:
            file.write_bytes(base64.b64decode(required(variable), validate=True))
            file.chmod(0o600)
        profile = plistlib.loads(capture(["security", "cms", "-D", "-i", str(profile_file)]).encode())
        identifier = validate_profile(profile, team, bundle, method)
        keychain = folder / "build.keychain-db"
        password = secrets.token_urlsafe(32)
        try:
            capture(["security", "create-keychain", "-p", password, str(keychain)])
            capture(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
            capture(["security", "unlock-keychain", "-p", password, str(keychain)])
            capture(["security", "import", str(certificate), "-P", required("IOS_CERTIFICATE_PASSWORD"),
                     "-A", "-t", "cert", "-f", "pkcs12", "-k", str(keychain)])
            capture(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                     "-s", "-k", password, str(keychain)])
            capture(["security", "list-keychains", "-d", "user", "-s", str(keychain), *old_keychains])
            identities = capture(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)])
            identities_found = re.findall(r'([0-9A-F]{40}) "Apple Distribution:', identities)
            if len(identities_found) != 1:
                raise ValueError("P12 must contain one valid Apple Distribution identity and private key")
            identity = identities_found[0]
            profile_destination = Path.home() / "Library/MobileDevice/Provisioning Profiles" / f"{identifier}.mobileprovision"
            profile_destination.parent.mkdir(parents=True, exist_ok=True)
            if profile_destination.exists():
                previous_profile = profile_destination.read_bytes()
            profile_destination.write_bytes(profile_file.read_bytes())
            profile_destination.chmod(0o600)
            project.write_text(patch_app_settings(original, team, bundle, identifier, identity))
            archive = folder / "App.xcarchive"
            subprocess.run(["xcodebuild", "archive", "-project", str(project.parent), "-scheme", "App",
                            "-configuration", "Release", "-destination", "generic/platform=iOS",
                            "-archivePath", str(archive), "-derivedDataPath", str(folder / "derived"),
                            f"MARKETING_VERSION={version.split('-')[0]}", f"CURRENT_PROJECT_VERSION={build}"],
                           check=True, cwd=ROOT)
            export_options = folder / "ExportOptions.plist"
            export_options.write_bytes(plistlib.dumps({"method": method, "destination": "export", "teamID": team,
                "signingStyle": "manual", "signingCertificate": identity,
                "provisioningProfiles": {bundle: identifier}, "manageAppVersionAndBuildNumber": False}))
            exported = folder / "exported"
            subprocess.run(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(exported),
                            "-exportOptionsPlist", str(export_options)], check=True, cwd=ROOT)
            ipas = list(exported.glob("*.ipa"))
            if len(ipas) != 1:
                raise ValueError("Xcode did not produce exactly one IPA")
            output = ROOT / ".ci-artifacts/signed"
            output.mkdir(parents=True, exist_ok=True)
            import shutil
            shutil.copyfile(ipas[0], output / f"bjj-telestrator-{version}-{method}.ipa")
            print("Signed IPA exported successfully.")
        finally:
            project.write_text(original)
            if profile_destination:
                if previous_profile is None:
                    profile_destination.unlink(missing_ok=True)
                else:
                    profile_destination.write_bytes(previous_profile)
            # Cleanup failures must not prevent the remaining cleanup operations.
            subprocess.run(["security", "list-keychains", "-d", "user", "-s", *old_keychains], capture_output=True, check=False)
            subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True, check=False)


if __name__ == "__main__":
    main()
