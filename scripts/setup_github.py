"""Create the private repository from Windows using the user's GitHub CLI login."""

import argparse
import base64
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OWNER = "BakedChicken77"
NAME = "bjj-telestrator"


def run(args: list[str]) -> str:
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or f"{args[0]} failed with exit {result.returncode}")
    return result.stdout.strip()


def api(path: str, method: str, data: dict[str, object] | None = None) -> None:
    subprocess.run(["gh", "api", "--method", method, path, "--input", "-"],
                   input=json.dumps(data or {}), text=True, cwd=ROOT, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", help="Push the version tag to start the release gates")
    parser.add_argument("--resume", action="store_true", help="Continue setup of this exact existing repository")
    options = parser.parse_args()
    for executable, install in [("git", "Git.Git"), ("gh", "GitHub.cli")]:
        if not shutil.which(executable):
            raise SystemExit(f"Install with: winget install --id {install} -e\nThen reopen PowerShell.")
    auth = subprocess.run(["gh", "auth", "status", "--hostname", "github.com"], capture_output=True)
    if auth.returncode:
        subprocess.run(["gh", "auth", "login", "--hostname", "github.com", "--web",
                        "--git-protocol", "https", "--scopes", "repo,workflow"], check=True)
    user = json.loads(run(["gh", "api", "user"]))
    if user["login"].lower() != OWNER.lower():
        raise SystemExit(f"Expected GitHub account {OWNER}; use gh auth switch before retrying.")
    run(["gh", "auth", "setup-git", "--hostname", "github.com"])
    repo = f"{OWNER}/{NAME}"
    url = f"https://github.com/{repo}"
    if not (ROOT / ".git").exists():
        parent_git = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, capture_output=True)
        if parent_git.returncode == 0:
            raise SystemExit("Extract outside another Git repository before setup.")
    if (ROOT / ".git").exists():
        if not options.resume:
            raise SystemExit("A Git repository already exists. Review it, then use --resume.")
        if Path(run(["git", "rev-parse", "--show-toplevel"])).resolve() != ROOT:
            raise SystemExit("Unexpected Git root; refusing to change it.")
        if run(["git", "status", "--porcelain"]):
            raise SystemExit("Commit or resolve local changes before resuming.")
    else:
        run(["git", "init", "-b", "main"])
        run(["git", "config", "user.name", user["login"]])
        run(["git", "config", "user.email", f"{user['id']}+{user['login']}@users.noreply.github.com"])
        run(["git", "add", "--", "."])
        from ci.release import tracked_files
        tracked_files(ROOT)  # Reject credentials, private footage, and unsafe release paths.
        run(["git", "commit", "-m", "Set up BJJ Telestrator with tests, builds, and releases"])
    existing = subprocess.run(["gh", "repo", "view", repo, "--json", "nameWithOwner,isPrivate"], capture_output=True, text=True)
    if existing.returncode == 0:
        if not options.resume:
            raise SystemExit("Repository exists; use --resume after verifying its identity.")
        heads = run(["git", "ls-remote", "--heads", url + ".git"])
        if heads:
            marker = json.loads(base64.b64decode(run(["gh", "api",
                f"repos/{repo}/contents/.github/bjj-repository.json", "--jq", ".content"])))
            if marker != json.loads((ROOT / ".github/bjj-repository.json").read_text()):
                raise SystemExit("Existing repository has another identity; refusing to resume.")
    else:
        run(["gh", "repo", "create", repo, "--private", "--description",
             "Local BJJ video annotation, voiceover, and burned-in MP4 export for desktop and iPhone"])
    remote = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT, capture_output=True, text=True)
    if remote.returncode == 0:
        if remote.stdout.strip() not in {url, url + ".git", f"git@github.com:{repo}.git"}:
            raise SystemExit("Origin points elsewhere; refusing to change it.")
    else:
        run(["git", "remote", "add", "origin", url + ".git"])
    run(["git", "push", "-u", "origin", "main"])
    warnings = []
    settings = [
        ("", "PATCH", {"has_issues": True, "has_wiki": False, "has_projects": False,
                        "allow_squash_merge": True, "allow_merge_commit": False,
                        "allow_rebase_merge": False, "delete_branch_on_merge": True}),
        ("/actions/permissions", "PUT", {"enabled": True, "allowed_actions": "all"}),
        ("/actions/permissions/workflow", "PUT", {"default_workflow_permissions": "read",
                                                 "can_approve_pull_request_reviews": False}),
        ("/vulnerability-alerts", "PUT", {}),
        ("/automated-security-fixes", "PUT", {}),
        ("/environments/ios-release", "PUT", {"deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}),
        ("/branches/main/protection", "PUT", {
            "required_status_checks": {"strict": True, "contexts": ["CI gate"]},
            "enforce_admins": True, "required_pull_request_reviews": {
                "required_approving_review_count": 0, "dismiss_stale_reviews": True},
            "restrictions": None, "required_linear_history": True,
            "required_conversation_resolution": True, "allow_force_pushes": False,
            "allow_deletions": False}),
    ]
    for suffix, method, data in settings:
        try:
            api(f"repos/{repo}{suffix}", method, data)
        except subprocess.CalledProcessError:
            warnings.append(suffix or "repository settings")
    try:
        policies = json.loads(run(["gh", "api", f"repos/{repo}/environments/ios-release/deployment-branch-policies"]))
        if not any(p.get("name") == "v*" and p.get("type") == "tag" for p in policies.get("branch_policies", [])):
            api(f"repos/{repo}/environments/ios-release/deployment-branch-policies", "POST", {"name": "v*", "type": "tag"})
    except (subprocess.CalledProcessError, SystemExit):
        warnings.append("ios-release tag deployment restriction")
    if options.release:
        version = json.loads((ROOT / "frontend/package.json").read_text())["version"]
        from ci.release import validate_version
        tag = "v" + version
        validate_version(tag, ROOT)
        if not run(["git", "tag", "--list", tag]):
            run(["git", "tag", "-a", tag, "-m", f"BJJ Telestrator {tag}"])
        if run(["git", "rev-list", "-n", "1", tag]) != run(["git", "rev-parse", "HEAD"]):
            raise SystemExit("Existing version tag points to another commit; use a new version.")
        run(["git", "push", "origin", tag])
    report = {"repository": url, "actions": url + "/actions", "settingsNotApplied": warnings}
    output = ROOT / ".ci-artifacts/setup-report.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if warnings:
        print("Some settings were not applied. Check account plan and permissions; see the setup report.")
    print("Watch Actions. A release is published only after every required job succeeds.")


if __name__ == "__main__":
    main()
