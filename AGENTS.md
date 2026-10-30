# Coding agent instructions — BJJ Telestrator / Fresh Frame

These instructions apply to the entire repository. Keep changes focused, preserve the existing CI and release gates, and report evidence instead of assuming success.

## Discover the intended task and branch

1. Read the relevant parts of `README.md`, `ARCHITECTURE.md`, `IMPLEMENTATION_PLAN.md`, `CONTRIBUTING.md`, and `docs/GITHUB_SETUP.md`. The implementation plan contains historical milestones; it does not authorize new feature work. Check current issues, PRs, and branch heads for the latest status.
2. The default branch is `main`, but recent standalone iPhone/Fresh Frame work is delivered from `preview/native-iphone`. Confirm the intended base and PR target before editing. Do not merge or rebase these branches merely to synchronize them.
3. The 32-item UX backlog is tracked in issue #43 and related issues #44–#75; the October 2026 archive is on `docs/ux-backlog-2026-10` pending its documentation PR. Only implement an issue or feature explicitly selected by the owner. Never treat backlog order as authorization.
4. Inspect existing coverage and reuse established contracts. Prefer one feature/fix per branch and PR; do not modify app versions, dependency pins, distribution settings, or unrelated features as incidental cleanup.

## Architecture and invariants

- React/TypeScript/Vite/Capacitor editor lives in `frontend/`; FastAPI/FFmpeg desktop service lives in `backend/`; the standalone iPhone bridge, native processing, and XCTest live in `frontend/ios/`.
- Preserve original video and recorded audio, normalized stage geometry, half-open annotation time ranges (`[start, end)`), and consistent source-media timestamps. Verify actual encoded frames/audio where rendering behavior changes.
- Project persistence must remain validated, atomic, revision-safe, and recoverable. An audio preview/rebuild failure must not be reported as loss or interruption of an already saved recording. Carefully test seek, pause/resume, multi-take mixing, audio clock boundaries, reopen, and export for related changes.
- Keep native iPhone storage and media processing local. Never check in user recordings, user project backups, real test footage, credentials, certificates, profiles, `.env` files, or generated artifacts. Use synthetic fixtures and sanitized diagnostics.
- Browser/TypeScript tests do not prove AVFoundation, Photos, mic, hardware, TestFlight, accessibility, or native simulator correctness. Native changes require Xcode CI and specific physical-device acceptance notes.

## Reproducible cloud development

See `docs/CODEX_CLOUD.md`. Run `bash .codex/bootstrap.sh` from the repository root on a provisioned Linux cloud VM (Node.js 24, Python 3.12, FFmpeg/FFprobe). The script installs pinned backend/frontend dependencies and Playwright Chromium without modifying release configuration.

From the repository root, using the resulting Python environment:

- Routine verification: `backend/.venv/bin/python scripts/verify.py`.
- Browser and real media verification: `backend/.venv/bin/python scripts/verify.py --browser`.
- Repository/release utility checks alone: `backend/.venv/bin/python -m unittest discover -s tests/repository -v`.
- Native iPhone verification on macOS only: `cd frontend && npm run ios:sync`, then `python3 scripts/test_ios.py` from the root and the unsigned archive check. The required `ios` GitHub Actions job runs on macOS/Xcode; Linux cannot replace it.
- Docker smoke and all platform gates remain covered by `.github/workflows/ci.yml`. Do not mark a job passed unless its actual result is available.

For changed code, run focused tests during development, then the applicable full checks. If unavailable, explicitly identify what did not run and why. Never skip, weaken, or mock away a failing test to report green.

## PR preparation and review rules

- Use a topic branch. Explain the user-visible failure/goal, changed behavior, linked issue, intended base branch, regression tests, and any device acceptance remaining. Follow `.github/pull_request_template.md`.
- Before requesting merge, inspect the complete diff for accidental generated assets, hardcoded credentials, timing regressions, sensitive log content, scope creep, and unwanted version/bundle changes.
- For audio and video changes, scrutinize **sample-clock alignment, pause-boundary edits, half-open timing intervals, preserved original bytes, and playback/export equivalence**. Add regression tests at the failure boundary.
- For project persistence, verify **atomic save, on-disk revision consistency, interrupted writes, backup/restore, and recoverable saved takes**. Do not silently discard or overwrite user data.
- For native iOS changes, verify **Swift bridge contracts, simulator XCTest/UI coverage, generated media, and physical-device limitations**. Demand the native macOS CI result even when web tests pass.
- Request/consider Codex Code Review where available, but a model review is advisory. Required `CI gate`, resolved review threads, and owner decision govern merging. Never fabricate an approval or a passing check.
- No release tags, TestFlight or App Store uploads, Apple account/signing changes, branch-protection weakening, production deployments, or merging into `preview/native-iphone` without explicit owner direction. A push to `preview/native-iphone` triggers `.github/workflows/release.yml`.
