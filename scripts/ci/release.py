"""Validate versions, package tracked source, and publish a gated GitHub release."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:alpha|beta|rc)\.[1-9]\d*)?$")


def command(args: list[str], cwd: Path = ROOT) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def validate_version(tag: str, root: Path = ROOT) -> str:
    if not VERSION.fullmatch(tag):
        raise ValueError("Use a version tag such as v1.1.0 or v1.1.0-rc.1.")
    version = tag[1:]
    package = json.loads((root / "frontend/package.json").read_text())
    lock = json.loads((root / "frontend/package-lock.json").read_text())
    if any(v != version for v in [package["version"], lock["version"], lock["packages"][""]["version"]]):
        raise ValueError("The tag must match frontend/package.json and both root package-lock version fields.")
    if f"## [{version}]" not in (root / "CHANGELOG.md").read_text():
        raise ValueError("Add a CHANGELOG.md section for this version before tagging it.")
    return version


def safe_member(name: str) -> bool:
    p = Path(name)
    return not (
        not name or "\0" in name or ":" in name or p.is_absolute() or ".." in p.parts or "\\" in name
        or any(part in {".git", "node_modules", ".venv", "data", "DerivedData", "xcuserdata"} for part in p.parts)
        or p.parts[:2] == ("tests", "generated") or p.parts[:1] == (".ci-artifacts",)
        or (p.name.startswith(".env") and p.name != ".env.example")
        or (p.suffix.lower() in {".mov", ".mp4", ".wav", ".webm", ".m4a"} and name != "docs/sample-annotated.mp4")
        or p.suffix.lower() in {".p8", ".p12", ".pem", ".key", ".mobileprovision", ".ipa", ".pyc"}
    )


def tracked_files(root: Path = ROOT) -> list[str]:
    data = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    names = sorted(n for n in data.decode().split("\0") if n)
    unsafe = [n for n in names if not safe_member(n)]
    if unsafe:
        raise ValueError("Remove generated data or credential files from Git before releasing: " + ", ".join(unsafe))
    if not names:
        raise ValueError("Commit the source before packaging a release.")
    return names


def zip_files(output: Path, root: Path, names: list[str], prefix: str) -> None:
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(names):
            file = root / name
            if not safe_member(name):
                raise ValueError(f"Unsafe archive path: {name}")
            if file.is_symlink():
                raise ValueError(f"Release packaging does not follow source symlinks: {name}")
            info = zipfile.ZipInfo(prefix + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, file.read_bytes())


def package(output: Path, root: Path = ROOT) -> None:
    output.mkdir(parents=True, exist_ok=True)
    names = tracked_files(root)
    version = json.loads((root / "frontend/package.json").read_text())["version"]
    zip_files(output / f"bjj-telestrator-{version}-source.zip", root, names, "bjj-telestrator/")
    dist = root / "frontend/dist"
    if not (dist / "index.html").is_file():
        raise ValueError("Build the frontend before packaging.")
    zip_files(output / f"bjj-telestrator-{version}-web.zip", dist,
              [p.relative_to(dist).as_posix() for p in dist.rglob("*") if p.is_file()], "web/")
    inventory = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
    manifest = {"version": version, "commit": command(["git", "rev-parse", "HEAD"], root),
                "sourceSha256": inventory, "iosSigning": "see signed artifact and release notes"}
    (output / "BUILD-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")


def checksums(output: Path) -> None:
    lines = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}" for p in sorted(output.iterdir())
             if p.is_file() and p.name != "SHA256SUMS.txt"]
    (output / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")


def device_accepted(environment: dict[str, str], commit: str, version: str) -> bool:
    """A historic boolean cannot attest to another candidate or signed build."""
    build = f"{environment.get('GITHUB_RUN_NUMBER', '1')}.{environment.get('GITHUB_RUN_ATTEMPT', '1')}"
    return (environment.get('IOS_DEVICE_ACCEPTED') == 'true'
            and environment.get('IOS_DEVICE_ACCEPTED_SHA') == commit
            and environment.get('IOS_DEVICE_ACCEPTED_VERSION') == version
            and environment.get('IOS_DEVICE_ACCEPTED_BUILD') == build
            and environment.get('IOS_DEVICE_EVIDENCE_URL', '').startswith('https://'))


def publish(output: Path, tag: str) -> None:
    validate_version(tag)
    repository = os.environ["GITHUB_REPOSITORY"]
    commit = command(["git", "rev-parse", "HEAD"])
    marker = f"<!-- bjj-telestrator:{commit} -->"
    signed = any(output.glob("*.ipa"))
    accepted = device_accepted(dict(os.environ), commit, tag[1:])
    prerelease = not (signed and accepted and "-" not in tag)
    summary = (f"{marker}\n\nBuilt from `{commit}` after all CI gates passed.\n\n"
               "- Source ZIP: full desktop and iPhone source.\n"
               "- Web ZIP: compiled editor; desktop media APIs are still required when used in a browser.\n"
               "- Simulator ZIP: for an iOS Simulator on macOS.\n"
               "- Unsigned xcarchive ZIP: build output requiring Apple signing before device installation.\n")
    summary += "- Signed IPA included; its provisioning method determines installation/distribution.\n" if signed else "- No signed IPA: Apple signing has not been enabled for this release.\n"
    if not accepted:
        summary += "\nPhysical iPhone acceptance has not been confirmed; this release is marked prerelease.\n"
    summary += "\nVerify downloads with SHA256SUMS.txt. Setup and signing instructions are in docs/GITHUB_SETUP.md.\n"
    notes = output.parent / "release-notes.md"
    notes.write_text(summary)
    result = subprocess.run(["gh", "release", "view", tag, "--repo", repository, "--json", "isDraft,body"],
                            capture_output=True, text=True)
    if result.returncode == 0:
        existing = json.loads(result.stdout)
        if not existing["isDraft"] or marker not in existing["body"]:
            raise ValueError("Refusing to overwrite a published release or an unrelated draft. Use a new version.")
    else:
        command(["gh", "release", "create", tag, "--repo", repository, "--verify-tag", "--draft",
                 "--title", f"BJJ Telestrator {tag}", "--notes-file", str(notes)])
    checksums(output)
    command(["gh", "release", "upload", tag, "--repo", repository, "--clobber",
             *[str(p) for p in sorted(output.iterdir()) if p.is_file()]])
    command(["gh", "release", "edit", tag, "--repo", repository, "--draft=false",
             f"--prerelease={'true' if prerelease else 'false'}", f"--latest={'false' if prerelease else 'true'}",
             "--notes-file", str(notes)])
    print(f"Published https://github.com/{repository}/releases/tag/{tag}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["validate", "package", "publish"])
    parser.add_argument("--tag", default=os.environ.get("RELEASE_TAG", ""))
    parser.add_argument("--output", type=Path, default=ROOT / ".ci-artifacts/release")
    args = parser.parse_args()
    if args.action == "validate":
        print(validate_version(args.tag))
        command(["git", "merge-base", "--is-ancestor", "HEAD", "origin/main"])
    elif args.action == "package":
        package(args.output)
    else:
        publish(args.output, args.tag)


if __name__ == "__main__":
    main()
