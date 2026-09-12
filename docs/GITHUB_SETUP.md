# GitHub repository, CI, and releases

## Delivery status

The owner created the public repository `BakedChicken77/bjj-telestrator`. Source and workflow files can now be uploaded through the GitHub connection. Repository settings (branch protection, merge options, environments) still require GitHub CLI or Settings access because the connection exposes no admin mutation API. No token needs to be pasted into ChatGPT.

For this existing repository, clone it to Windows and apply admin settings with:

```powershell
gh repo clone BakedChicken77/bjj-telestrator
cd bjj-telestrator
py scripts/setup_github.py --resume
```

The script preserves the existing visibility. The fresh-private-repository instructions below are only for a new setup. Native builds, signing and release publication must be confirmed in Actions; source upload alone does not verify them.

The existing Windows application remains intact. The iPhone source has not yet passed an Apple SDK build or physical-device acceptance. Native checks are mandatory CI gates, so an Apple build failure blocks a release instead of publishing an unverified archive.

## Windows 11 setup

Extract the updated ZIP into a fresh folder, outside other Git repositories. Use PowerShell in its `bjj-telestrator` folder. Git, GitHub CLI, and Python 3.12 are prerequisites; install missing tools:

```powershell
winget install --id Git.Git -e
winget install --id GitHub.cli -e
winget install --id Python.Python.3.12 -e
```

Reopen PowerShell after installation. Run:

```powershell
py scripts/setup_github.py --release
```

The script opens GitHub's login flow if needed, verifies **BakedChicken77**, initializes and commits this source, creates **private** `BakedChicken77/bjj-telestrator`, pushes `main`, applies settings, then pushes the `v1.1.0` release tag. It never force-pushes. It refuses an existing repository unless explicitly resumed. A failed first push or settings operation can be resumed with `py scripts/setup_github.py --resume --release` after addressing the reported error. The local working tree must be clean when resuming; do not use this flag to adopt an unrelated repository.

Successful setup prints the actual repository and Actions URLs. `.ci-artifacts/setup-report.json` records settings that could not be applied. Private-repository branch protection and protected environments may depend on your GitHub plan; a permission or plan error is reported and does not silently make the repo public. Check **Settings → Branches** if protection was rejected. GitHub-hosted macOS jobs consume your account's Actions allowance; configure a spending limit before repeated builds. No self-hosted Mac is required for the workflows. See [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Repository conventions

- `main` is the release branch. Use a feature branch and pull request for subsequent changes.
- Require the `CI gate` status, an up-to-date branch, resolved conversations, and linear history; block force pushes and deletions. There are zero mandatory human approvals for this single-maintainer repo, avoiding self-approval deadlock.
- Squash merge; delete merged branches. CODEOWNERS names the owner, and issue/PR templates collect verification evidence.
- Workflow tokens default to read-only. Only the gated publishing job has `contents: write`. PR workflows never receive Apple signing secrets.
- Actions are pinned to full commit SHAs. Dependabot checks npm, pip, Docker, and workflow dependencies weekly. No automatic dependency merge is enabled.
- Vulnerability alerts and automated security fixes are requested by setup. Secret scanning/advanced security availability should be reviewed in GitHub settings for your plan.
- No open-source license has been assigned. Keep the repository private until you choose one. Existing third-party font licenses remain included.

## CI and automatic release behavior

`.github/workflows/ci.yml` runs on pushes to `main`, pull requests, manual dispatch, and calls from Release:

| Job | Required checks |
|---|---|
| Frontend/repository | Vitest, ESLint, TypeScript, Vite production build, Prettier, packaging/signing unit tests, checksum-pinned actionlint |
| Backend | Pytest including actual FFmpeg exports and pixel/audio checks; Ruff |
| Browser | Nine real Chromium scenarios covering import, persistence, voiceover, touch editing, and MP4 download |
| Docker | Production image build, isolated-volume startup, frontend/API/FFmpeg health |
| iOS | Native XCTest on an iPhone simulator; Release device archive without signing |
| CI gate | Requires every preceding job to succeed; failure, cancellation, or skipping is not a pass |

The iOS jobs use GitHub's `macos-26` runner and Xcode 26.6. Runner images evolve; if that Xcode path disappears, update both workflows after reviewing [the official runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). The filename contains `arm64`, but the workflow runner label is `macos-26`.

Release runs when a `v*` tag is pushed. It verifies the tag matches all three root npm version fields and a CHANGELOG section, verifies its commit is on `main`, and reruns every CI gate for that commit. It packages:

- Full tracked source ZIP, including desktop and native iPhone code.
- Compiled web ZIP. This is the frontend, not a standalone replacement for the desktop API.
- Simulator `.app` ZIP and unsigned `.xcarchive` ZIP. Neither installs directly on a physical iPhone.
- Optional signed IPA when Apple signing is enabled.
- Source inventory/commit manifest and SHA256 checksums.

Publication starts with a draft, uploads artifacts, and publishes only after successful upload. An interrupted draft for the same commit can be retried; a published release is never overwritten. Releases are **prerelease** unless an IPA exists, `IOS_DEVICE_ACCEPTED=true`, and the version is stable. Confirm physical acceptance before setting that variable. On a published version, make fixes in a new version; do not move its tag.

For a later release, change `frontend/package.json`, both root version fields in `frontend/package-lock.json`, and CHANGELOG, merge the PR, then run on updated `main`:

```powershell
git tag -a v1.1.1 -m "BJJ Telestrator v1.1.1"
git push origin v1.1.1
```

## Apple signing and TestFlight from a Windows workflow

GitHub can supply the Mac build machine, but it cannot supply your Apple developer identity. Paid Apple Developer Program membership, an app identifier, an Apple Distribution certificate **with its private key**, and a matching distribution provisioning profile are needed for the automated distribution flow. The certificate/private-key creation and Apple enrollment are account-owner setup steps; they were not performed here.

Open the **`ios-release` environment** in GitHub Settings → Environments. Setup attempts to create it with a `v*` tag restriction; create it manually if the setup report says this was unavailable. Limit deployments to tags matching `v*` where your plan supports deployment restrictions. Add these **environment secrets**:

| Secret | Value |
|---|---|
| `IOS_CERTIFICATE_BASE64` | Base64 of password-protected distribution P12 containing its private key |
| `IOS_CERTIFICATE_PASSWORD` | P12 password |
| `IOS_PROFILE_BASE64` | Base64 of matching distribution `.mobileprovision` file |

Add these **repository variables** in Settings → Secrets and variables → Actions → Variables:

| Variable | Value |
|---|---|
| `IOS_SIGNING_ENABLED` | `true` only after environment and credentials are ready; absent means disabled |
| `IOS_TEAM_ID` | Your ten-character Apple Team ID |
| `IOS_BUNDLE_ID` | Your registered explicit app ID, for example `com.bakedchicken77.bjjtelestrator` if available |
| `IOS_EXPORT_METHOD` | `app-store-connect` for TestFlight, or `release-testing` for Ad Hoc registered devices |
| `IOS_DEVICE_ACCEPTED` | `true` only after the physical iPhone checklist in IOS_README.md passes |

The signing script validates team, bundle ID, profile expiry and distribution method; changes only App signing settings; creates a temporary keychain; archives and exports; restores the project and removes credentials in `finally`. It never signs pull-request builds. The IPA necessarily contains Apple's embedded provisioning profile. Runner-side signing still needs its first actual macOS execution. See [GitHub's Apple certificate guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

For optional TestFlight upload, create the matching app record in App Store Connect, obtain an authorized **team API key**, and add environment secrets `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, and `ASC_API_KEY_P8_BASE64`. Set repository variable `IOS_UPLOAD_TESTFLIGHT=true` and use `app-store-connect`. The release job uploads the signed IPA with Apple's altool. Apple must process it; then select the build for your internal TestFlight tester group in App Store Connect and install through TestFlight on the iPhone. External testing can require Apple's beta review. This upload does **not** submit a production App Store release. See [Apple's build-upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

To encode a credential without printing it in the terminal, use PowerShell locally:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\distribution.p12))) | Set-Clipboard
```

Paste into the appropriate GitHub secret field; clear the clipboard afterward. Keep credential files outside this source folder. Never commit certificates, profiles, API keys, personal media, or `.env` files.

## Verification and troubleshooting

From the project root with backend dependencies installed:

```powershell
backend\.venv\Scripts\python.exe scripts/verify.py --browser
py -m unittest discover -s tests/repository -v
```

GitHub installs Playwright Chromium and FFmpeg. Locally, see README for dependency installation. Linux workflow validation is `python scripts/ci/install_actionlint.py` then `.ci-artifacts/tools/actionlint`. Docker smoke: `docker build -t bjj-telestrator:ci .` then `py scripts/ci/docker_smoke.py`.

- Repository creation refused: check `gh auth status`, account name, organization policy, and whether the name already exists. Do not force-push to fix a mismatch.
- Workflow push denied: authorize the GitHub CLI for repo/workflow access using `gh auth refresh -h github.com -s repo,workflow`.
- Protection rejected: inspect setup report and GitHub plan; CI still runs, but merge protection is not enforced until settings succeed.
- CI queued: check Actions billing/limits. Cancel obsolete runs in the Actions UI.
- Native compilation failure: inspect the actual Xcode log; this is an outstanding first-run gate, not evidence that the Linux browser tests verified native behavior.
- Test failures: browser traces and native `.xcresult` bundles are retained for 14 days. Download from the Actions run summary.
- Signing skipped: absent `IOS_SIGNING_ENABLED` defaults to off. Signing failure blocks publication when enabled.
- Apple upload accepted but app absent: wait for Apple's processing; check bundle/app record, agreements, role, and TestFlight group assignment.
- Release blocked: fix the failing gate. Do not remove the gate to label an untested iPhone build ready.


Candidate device acceptance now binds the exact commit, version and workflow
run/attempt build; a global `IOS_DEVICE_ACCEPTED` boolean no longer accepts future
builds. See [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md) for the companion
variables, pilot behavior and evidence template. The baseline GitHub repository,
CI and 11 native tests/archive have since completed successfully at `f5323b3b`.
