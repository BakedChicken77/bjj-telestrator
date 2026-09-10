# Implementation plan

## Milestone 1 — annotation editor and exports

- [x] Inspect workspace: empty; scaffold local React/TypeScript and FastAPI application.
- [x] Define shared schema, coordinate system, component interfaces, and API.
- [x] Stream imports, probe metadata, normalize browser proxy, preserve originals.
- [x] Implement canvas tools, timeline, properties, grouped undo/redo, playback synchronization.
- [x] Implement validated atomic persistence, project browser, autosave.
- [x] Render antialiased annotation interval states with FFmpeg and persistent cancellable jobs.
- [x] Pass unit checks, real export integration, browser acceptance, orientation/input variants.

## Milestone 2 — voiceover (Milestone 1 gate passed)

- [x] Record linear microphone clips, normalize media assets, synchronize Web Audio preview.
- [x] Implement gain/mute, clip nudge and deletion, and export audio mixing.
- [x] Pass voiceover tests and browser recording/export checks.

## Delivery

- [x] Docker production build path and localhost Compose configuration written; native production build passed.
- [x] Native Windows instructions and schema/architecture documentation.
- [x] Final tests, reproducible verification report, source archive.

## Decisions

- Local single-user application; no cloud runtime, analytics, or remote media storage.
- Editing proxies always use H.264/AAC with orientation baked into square-pixel frames.
- Geometry uses normalized coordinates; line/text widths use the smaller oriented dimension.
- DejaVu Sans is bundled identically in browser and server.
- Static annotation states change only at their temporal boundaries; rasterization is cached by active state.
- Each export reads a validated immutable project snapshot; completed exports are retained.
- Explicitly verify generated media and actual encoded pixels, not only file existence.
- Docker/Windows execution must be recorded honestly if unavailable in the build environment.

## Milestone 1 gate evidence

- Backend: 50 tests passed, including real encoded video/audio and cancellation.
- Frontend: 30 tests passed; strict TypeScript, ESLint, formatting and production build pass.
- Browser: all 5 scenarios passed using Chromium 149: 20-second acceptance, every tool and timeline drag/trim, portrait, rotated MOV, and silent input.
- Production HTTP smoke: compiled HTML/JavaScript/font and FFmpeg health served successfully from FastAPI.
- At the original delivery, Windows/Docker execution remained a verification limitation. The user reported successful Windows 11/Docker Desktop operation on 2026-09-10.
- Voiceover implementation began only after these results.

## Milestone 2 gate evidence

- Full backend suite: 74 tests passed, including all M1 tests and real normalized/mixed audio.
- Full frontend suite: 51 tests passed; strict TypeScript, ESLint, Prettier and production build passed.
- Native Chromium recording/preview/export passed with actual MediaRecorder and generated microphone input.
- All seven final browser scenarios passed, including native microphone-permission denial and editor recovery.
- Preview caches a bounded working set; currently active takes still require their decoded audio buffers.
- A fixed inspector width preserves stage geometry when selection changes.

## Remaining platform verification

- [x] Launch with Docker Desktop on a Windows 11 host (user-reported success, 2026-09-10).
- [ ] Validate physical microphone, speakers/headphones, and Microsoft Edge on the target machine.
- [ ] Benchmark a full 20-minute 1080p camera recording. A five-second 1080p/100-annotation export passed.

These are explicit verification limits, not placeholder application controls. HDR tone mapping and non-right-angle rotation are unsupported; portable project packaging and waveform editing are later enhancements.

## Version 1.1 — standalone iPhone conversion

- [x] Inspect and preserve the existing desktop source; reuse normalized project and editor logic.
- [x] Pin Capacitor 8.5.1; create the SPM Xcode application and custom Swift bridge.
- [x] Native Photos/Files import, original preservation, orientation-aware proxy, UUID asset routes with bounded byte-range streaming.
- [x] Native validated atomic project storage, persistent export jobs, recovery journal for interrupted recordings.
- [x] Native microphone capture, linear timing, automatic stop/interruption handling, local WAV assets, shared Web Audio preview.
- [x] Native original/voiceover mixing and streaming H.264/AAC MP4 renderer with all six annotation types, progress, cancellation, cleanup, and share sheet.
- [x] Phone portrait/landscape layout, safe areas, touch targets, panel tabs, single-pointer gesture ownership.
- [x] TypeScript bridge tests and real touch-browser scenarios authored; native generated-media XCTest suite and runner authored.
- [x] macOS/Xcode installation, signing, on-phone acceptance, privacy, storage, and format limits documented in IOS_README.md.
- [ ] Apple SDK compilation and nine native simulator tests on macOS/Xcode 26+.
- [ ] Sign/install on the user's iPhone and run the physical-device acceptance checklist.
- [ ] TestFlight/App Store distribution, if later requested; no enrollment or publishing is implied by this source conversion.

The iPhone runtime is standalone; macOS/Xcode is needed for its build/signing, supplied by GitHub-hosted runners in the Windows-only setup. No Windows companion server, FFmpeg WebAssembly, screen recording, cloud media processing, or camera tracking is introduced. Existing Windows tests remain required regressions. Measured version 1.1 test results are recorded in docs/VERIFICATION.md; native tests are explicitly separate from browser touch emulation.

### Version 1.1 checks completed in the implementation environment

- 74 backend tests and 60 frontend tests passed; all lint/type/format/build gates passed.
- All 9 real browser scenarios passed, including 2 phone touch/layout cases; the final phone cases were also rerun after the last small frontend changes.
- Xcode project structure, native source membership, plists, shared test scheme, and Swift syntax inspected; Capacitor sync succeeded.
- The native test runner correctly identifies Linux as unsupported. Apple SDK compilation, nine native tests, and device installation remain open gates, not claimed completions.

## Repository automation — 2026-09-10

- [x] Inspect source and GitHub capabilities; connected owner is BakedChicken77.
- [x] Add SHA-pinned CI for frontend, backend/FFmpeg, browser, Docker, and native iOS.
- [x] Add mandatory aggregate gate and version/tag-gated release publication with checksums.
- [x] Add unsigned simulator/device archives, optional isolated Apple signing and TestFlight upload.
- [x] Add Windows GitHub CLI bootstrap, private defaults, protection/settings requests, and retry safeguards.
- [x] Add CODEOWNERS, issue/PR templates, Dependabot, changelog, contribution/security guidance.
- [x] Validate workflow syntax and local packaging/signing boundaries; rerun application quality gates.
- [ ] Create remote repository and push: connector lacks repository creation/admin tools; no CLI login is present here.
- [ ] Run GitHub-hosted Docker/iOS jobs and publish the first gated release after bootstrap.
- [ ] Supply Apple distribution credentials and complete physical iPhone acceptance.

The setup script is the concrete fallback, not evidence that remote settings were applied. See docs/GITHUB_SETUP.md.
