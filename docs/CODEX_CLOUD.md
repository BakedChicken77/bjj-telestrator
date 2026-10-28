# Codex Cloud: BJJ Telestrator / Fresh Frame

This is the owner-facing setup and review runbook for reusable Codex Cloud tasks. It supplements, rather than replaces, [CI and release controls](GITHUB_SETUP.md), [contribution rules](../CONTRIBUTING.md), and [agent guidance](../AGENTS.md).

## Repository topology and safe branch selection

- Repository: `BakedChicken77/bjj-telestrator`. Default `main` branch is used for general development/configuration. As checked on October 28, 2026, it has the 2.1.0 frontend version.
- `preview/native-iphone` carries the more recent shipping Fresh Frame iPhone implementation (2.1.2 at the same check). **It is not interchangeable with `main`.** Inspect both heads and the relevant PR/issue before selecting a feature base.
- CI runs for PRs to either branch; `.github/workflows/ci.yml` aggregates frontend/repository, backend/FFmpeg, Playwright browser, Docker, and native Xcode jobs into `CI gate`.
- **A push/merge to `preview/native-iphone` triggers `.github/workflows/release.yml` and can result in internal TestFlight distribution.** Keep exploratory and setup PRs against `main`. Work targeting the preview branch needs an explicit owner release decision before merge.
- Backlog issue #43 and UX-01–UX-32 issues describe potential work, not automatic authorization. Documentation is preserved on `docs/ux-backlog-2026-10` while its draft PR is pending.

## 1. Connect and publish a reusable cloud environment (owner action)

1. On [ChatGPT web](https://chatgpt.com) or the Windows desktop app, start a Codex task and choose **Work in → Cloud → Select environment → Create environment**. Alternatively go to **Settings → Codex Cloud → Environments → Create environment**.
2. Connect the GitHub account **BakedChicken77**, approve access to `BakedChicken77/bjj-telestrator`, and select that repository. The connection used for ChatGPT GitHub browsing does not automatically guarantee Codex Cloud access.
3. Suggested environment name: **fresh-frame-dev**. Let Codex inspect the repository and prepare a Linux development image. Request **Node.js 24.19.0**, **Python 3.12.13**, **FFmpeg/FFprobe**, Git, npm, and Playwright's Chromium Linux dependencies. These track the existing GitHub CI toolchain; a Linux cloud VM cannot run Xcode.
4. Set the reusable **Install script** to `bash .codex/bootstrap.sh` after the script is available on the environment's checkout (merge the setup PR first). It installs pinned `backend/requirements.txt` and `frontend/package-lock.json` dependencies, creates `backend/.venv`, and downloads Playwright Chromium. The default installs Chromium; `CODEX_INSTALL_BROWSER=0` skips that optional download for a lightweight environment. If the browser reports missing system libraries, ask Codex setup to install Chromium's Linux dependencies and retest before publishing.
5. Choose **package-manager domains only** for network access initially. Allow Chromium's download host, such as `cdn.playwright.dev`, only if the setup logs show that it is needed. Do not enable broad public internet access by default.
6. No API keys, GitHub personal-access tokens, Apple signing keys, or App Store Connect secrets are needed for normal code/test work. Keep Apple credentials exclusively in the existing protected GitHub Actions `ios-release` environment. Do not copy local footage or actual `.bjjproj` backup files into Codex.
7. Ask Codex to run the environment's installation and basic tests, inspect the setup report, **save and Publish**. A draft environment is not available for new tasks. New tasks get separate workspaces from the published setup.

Suggested setup request to paste into the environment setup conversation:

> Prepare this repository for Linux-based frontend, Python backend, FFmpeg, and Playwright development. Use Node.js 24.19.0 and Python 3.12.13, install FFmpeg and FFprobe and required Chromium Linux libraries, then run `bash .codex/bootstrap.sh`. Verify `backend/.venv/bin/python scripts/verify.py`, then attempt `backend/.venv/bin/python scripts/verify.py --browser`. Report any missing packages or tests and fix the environment rather than changing project assertions. Do not configure Apple signing, change source files, or deploy a release. Use `AGENTS.md` as repository guidance.

Optional **Start skill** guidance: check the current branch/commit, read `AGENTS.md` and the relevant issue, and run targeted tests first. Only start `uvicorn` and Vite on `127.0.0.1` when an interactive dev server is necessary; the Playwright test runner starts its own isolated servers and fixtures.

## 2. Test matrix and definition of done

Run from the repository root after successful installation:

| Gate | Command / execution | Required when |
| --- | --- | --- |
| Fast unit, type, lint, build, real FFmpeg | `backend/.venv/bin/python scripts/verify.py` | Every code PR; run focused tests earlier while editing |
| Browser/voiceover/import/export E2E | `backend/.venv/bin/python scripts/verify.py --browser` | Browser, editor, import/export, recording, persistence, or shared changes |
| Repository/release utilities | `backend/.venv/bin/python -m unittest discover -s tests/repository -v` | CI, signing/packaging or repository automation changes |
| Docker smoke | `docker build -t bjj-telestrator:ci .` and `python3 scripts/ci/docker_smoke.py` | Via required GitHub Actions job (cloud Docker availability is not assumed) |
| Native iOS XCTest/UI/unsigned archive | `npm run ios:sync`, `python3 scripts/test_ios.py` and native build on macOS/Xcode | Every PR via required `ios` CI job; especially Swift, Capacitor, rendering, and native changes |
| Physical iPhone acceptance | `docs/DEVICE_ACCEPTANCE.md` and issue-specific reproductions | Hardware-sensitive/release candidates; record what is pending |

`scripts/verify.py --browser` generates synthetic media and uses Playwright's isolated test ports. **Do not substitute web/browser results for the macOS XCTest job or device testing.** A code change is not ready to merge until the actual GitHub `CI gate` passes, review threads are resolved, and the owner evaluates any remaining on-device risks. A new PR may temporarily have pending checks; never call them passed before their actual result is shown.

## 3. Task → branch → PR → review workflow

1. Select the environment, then give Codex one bounded issue/fix with acceptance criteria. Explicitly name the **base branch** (`main` for general work or `preview/native-iphone` for an approved iPhone task). Ask it to examine the latest remote head before creating a task branch.
2. Require a short root-cause summary or implementation plan, targeted tests, and a clean diff. Do not combine unrelated UX backlog items or silently bump versions.
3. Have Codex create a **draft PR** against the selected base with the existing PR template: goal, linked issue, test evidence, remaining device checks, and branch/release consequences. Do not merge as part of the coding task.
4. Configure **Codex Code Review** separately from the new Cloud environment: connect this GitHub repository in Codex settings, choose the repository under **Review code**, and enable **Automatic review** if desired. Set the review trigger under **Personal preferences**. For an on-demand review, comment `@codex review` on the PR; use the **Code Review** experience on desktop/web to investigate findings. The legacy GitHub review integration is separate from the newly published Cloud environment. Inspect findings and request specific fixes rather than automatically accepting them.
5. Review `Files changed` and all GitHub Actions results. Check native timing/audio, preserved user media, project data integrity, generated files, secrets, and unintended signing/build/version changes. Re-run checks after fixes. Resolve review conversations only when addressed.
6. Owner decides when to mark the PR ready and merge. **Never automatically merge or push tags.** Merging to `preview/native-iphone` starts the release pipeline; obtain a separate explicit decision and check the TestFlight impact before doing so.

### Example coding task

> Work in `BakedChicken77/bjj-telestrator`. Inspect the current `preview/native-iphone` branch and issue #45. Investigate the remaining recorded-audio device acceptance without assuming the issue needs a code change. Reproduce with synthetic fixtures, preserve saved narration and existing timing semantics, run relevant backend/frontend tests, and verify native macOS CI for any changes. Produce an evidence-backed draft PR against `preview/native-iphone` **only if a code change is warranted**. Do not merge, tag, upload to TestFlight, modify signing credentials, or select additional UX issues.

## 4. Updating and troubleshooting

- After changing dependencies/tools or `.codex/bootstrap.sh`, open **Settings → Codex Cloud → Environments → Edit**, retest, **Republish**, then start a new task. Existing tasks retain their own saved environment state.
- If the repository is missing, verify the Codex Cloud GitHub connection, selected repository, and user permissions. The separate ChatGPT GitHub plugin being connected is not proof that the environment has access.
- If Node/Python version checks fail, provision the versions above during environment setup; do not loosen CI locks as a workaround.
- If Chromium install fails, inspect the exact download URL and Linux libraries and allow only the necessary domains. `npm ci` and PyPI should work with package-manager network access.
- For Xcode failures inspect the macOS Actions logs and native artifacts; no Linux-only workaround counts as passing an Apple SDK test.
- Branch protection settings need to be verified by the repository owner in GitHub Settings; the GitHub connector may lack permission to inspect those controls.

Official guides: [Codex Cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environments) and [PR review with Codex](https://help.openai.com/en/articles/20001552-review-pull-requests-with-codex).
