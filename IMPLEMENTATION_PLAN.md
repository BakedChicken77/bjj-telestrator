# Implementation plan

## September 12, 2026 phased implementation assignment

Authoritative brief: Steve's five-phase plan in the implementation assignment.
Starting commit: `f5323b3b270e3836d7df10309d1684cf8d98e9ca` (live main rechecked).
Branch: `codex/p1-save-recovery`. Original checkout remained untouched; work uses
an isolated git worktree. App version stays 1.1.0 until release selection; schema
2 is introduced for the first persisted revision changes.

Selected first work package: P1.02 and P1.03, plus P1.01 baseline and candidate
acceptance preparation. The remaining core work continues in the brief's order.
P5.01–P5.07 are not selected. No publication, paid service, billing, account,
external media upload, repository visibility change, or unrelated dependency PR
is authorized by mentioning those modules.

| Tasks | Status | Exact remaining gate / next action |
| --- | --- | --- |
| P1.01 | device/staging verification pending | Baseline and fresh candidate CI verified; candidate-specific signing/device template and release gate prepared. Run fresh signed-install/update and Windows/Docker acceptance. |
| P1.02 | automatically verified | TypeScript, Python and Swift conformance plus migration/edit/export/reopen passed. Physical-device migration/reopen is still part of release acceptance. |
| P1.03 | automatically verified | Local and native CI recovery/revision tests pass. Physical interruption, storage failure and VoiceOver acceptance remain pending. |
| P1.06 — storage/export slice | automatically verified | All CI gates passed at 04b03a8 in run 34725049253, including 18 native tests and unsigned archive. Physical gates remain pending. |
| P1.06 — project recovery | automatically verified | All six CI gates passed at 33be631 in run 34727786132, including 22 native tests, actual MP4 recovery/retry and the unsigned archive. Device gates remain pending; broad media GC remains conservative retention. |
| P1.04 — import/repair slice | automatically verified | All six CI gates passed at 34fa4f2, including 25 native tests and the unsigned archive. HDR conversion and physical phone-media acceptance remain open. |
| P1.05, P1.07–P1.08 | not started | Continue after the P1.04 media contract and remaining package prerequisites. |
| P2.01–P2.08 | not started | Follow Phase 1 save/media/asset contracts and the brief's batch order. |
| P3.01–P3.07 | not started | Requires Phase 2 transport/timeline/export contracts. |
| P4.01–P4.06 | not started | Requires explicit review composition; no source-time reinterpretation. |
| P5.01–P5.07 | not selected | Each module needs its own selection; no placeholder UI. |

Engineering decisions: [authoritative saves ADR](docs/decisions/001-authoritative-saves.md).
Evidence and commands: [verification](docs/VERIFICATION.md).
Hardware/signing checklist: [device acceptance](docs/DEVICE_ACCEPTANCE.md).

Limits: only the existing six visual types and linear audio are persisted. No
HDR conversion, portable ZIP, audio-asset garbage collection, broad accessibility
audit, 20-minute benchmark or cloud feature is claimed. Large-copy responsiveness
and interruption still need physical-device evidence. Draft storage
is bounded and cannot preserve an edit before it has actually been journaled.

### Completion record — P1.02 / P1.03

- Outcome: storage-owned schema-2 revisions, stale-write rejection, pending-save
  recovery and independent copies on both service adapters; no source rewrite.
- Starting commit: `f5323b3b270e3836d7df10309d1684cf8d98e9ca`.
  Implementation commits: `6c77e2f` and `2fdb591`; real migration/export test extension: `349567c`. Publication was authorized on September 12. [Draft PR #8](https://github.com/BakedChicken77/bjj-telestrator/pull/8) is open; all CI gates passed in [run 34718055711](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34718055711). Final local measurements are recorded in the verification addendum.
- Public interfaces: capability GET/native query; If-Match save/export and native
  expectedRevision; recovery-copy and native draft journal; projectRevision on jobs.
- Migration/retention: preserve exact version-1 JSON; preserve optional fields,
  source and recording files; fresh UUIDs/references on copies. No GC is enabled.
- Tests: TypeScript/Python/Swift share 22 conformance cases; failure injection
  covers stale writers, lost acknowledgment, interrupted atomic install/copy and
  revision-independent undo/redo. The full local gate passed: 100 backend, 90 frontend, 12 repository and 11 browser tests. A version-1 disk migration/edit/export/reopen extension also passed its real FFmpeg test. Fresh Xcode 26.6 compilation, all 15 XCTest methods and the unsigned archive passed in CI run 34718055711; physical acceptance remains pending.
- Accessibility/platform: new recovery actions are semantic buttons; support
  preview uses a native HTML dialog with escape/focus behavior. Comprehensive
  VoiceOver and physical-device checks remain open.
- Rollback: retain the whole newer project, then recover pre-migration JSON in a
  separate prior-version copy. Never uninstall or overwrite new work to downgrade.
- Docs: PROJECT_FORMAT, ARCHITECTURE, README, IOS_README, VERIFICATION, changelog,
  decision record and DEVICE_ACCEPTANCE updated.
- Next eligible package: P1.06 reference/space/snapshot foundations. The whole of
  Phase 1 is not accepted by completion of this first package.

### Current work package — P1.06 storage/export foundations

Authorized by Steve's “Proceed”. Starting commit:
`dd0d0843ccc912fb5fa0cdd8e036979e7d9f6262`, branch
`codex/p1-storage-foundations`, stacked on draft PR #8. The starting tree passed
all CI gates in [run 34718720639](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34718720639).

Selected scope: incremental cached asset checksums, project storage breakdown,
operation space estimates, durable versioned export inputs, restart-from-zero
retry of the same revision, validated atomic MP4 finalization, and safe completed
output cleanup. Apply to desktop and native iOS with working shared controls.
Retain every source and recording, including removed takes; no unreferenced-audio
garbage collection until undo, checkpoints, recovery and job ownership are fully
represented. Manual checkpoints, recently deleted project recovery, general
Duplicate project and package staging remain explicit subsequent P1.06/P1.05 work.
This work package does not complete P1.06 or authorize a release.

Implementation now includes Python/Swift immutable job inputs and shared fixture
validation, source/recording retention, safe output cleanup and real shared editor
controls. Automated verification passed: 125 backend, 91 frontend, 12 repository and 12
browser tests; CI run 34725049253 also passed all 18 native tests and its unsigned
archive at 04b03a8. The native recording-receipt regression caught by the first run
was fixed without removing its assertion.
No physical device, signed installation or Windows/Docker acceptance is claimed.


### Current work package — P1.06 project recovery

Authorized by Steve's “Continue”. Starting commit:
`04b03a8cac59ae6266b32117ed2a7b797a4f6636`, isolated branch
`codex/p1-project-recovery`, stacked on draft PR #9. Selected scope: named durable
checkpoints, restore with a preserved before-restore checkpoint, independent
project duplication, recently deleted projects with explicit permanent deletion,
and restore of retained export attempts. Source/recording files remain immutable;
no automatic expiration or media garbage collection is introduced. Native work
runs off the UI thread; hardware interruption and large-media tests remain open.
Implementation: named, checksummed checkpoints with before-restore preservation;
independent media copies and UUID remapping; complete-project retained deletion,
collision-safe restore, conditional actions and working shared controls. New
recovery metadata stays outside project edit history. The project schema remains 2.

Review: [draft PR #10](https://github.com/BakedChicken77/bjj-telestrator/pull/10).
Implementation commits: `976343d` (recovery), `3f3b286` (immutable-input validation
and test storage), and `33be631` (literal text preservation during UUID copying).
All six CI gates passed at `3f3b286` in [run 34727251987](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34727251987).
Full local verification passed 139 backend, 92 frontend, 12 repository and 14 browser
tests. The final copy-only fix passed 39 focused recovery/export tests; its complete
CI passed all six gates in [run 34727786132](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34727786132): 139 backend, 92 frontend, 12 repository, 14 browser and 22 native tests, Docker and the unsigned archive.
Physical device, large-copy/interruption and fresh Windows-host acceptance remain
open; no complete Phase 1 or release acceptance is claimed. The full completion
record, interfaces, changed files and numerical export evidence are in
[project recovery verification](docs/p1-project-recovery-verification.json).

Retention/rollback: checkpoints and deleted projects keep all source/recording
references. Restore first saves the current edits as a checkpoint and increments
revision; it starts a fresh undo session. Duplicate retains older exports/versions
with the original. Preserve the entire project directory and pre-migration JSON
before rollback; restore trash with this version first. An older binary cannot
understand new sidecars or silently downgrade the project. Never uninstall to roll back.

Documentation updated: README, IOS_README, PROJECT_FORMAT, ARCHITECTURE, CHANGELOG,
VERIFICATION and this tracker. Next eligible feature work is P1.04's observable
import/proxy repair and bounded HDR conversion spike, followed by P1.05 portable
packages. Comprehensive GC remains conservative retention until every history,
checkpoint, recovery and active-job owner is represented. Status: automatically
verified for this package; device/staging verification pending. No Phase 1 release
acceptance is implied.


P1.04 inspection note: desktop `media.py` currently discards transfer/primaries/
matrix/range metadata and does not choose a verified HDR conversion. Native
`BJJMedia` lives in `BJJRenderer.swift` and rejects HDR transfer functions. Begin
the next package with explicit inspection and a fixture-based conversion spike;
keep the native rejection until preview and both exports pass. The desktop proxy
subprocess is currently blocking, so observable import/repair needs a real tracked
operation with cancellation, using the storage estimates and immutable source ID
already established. No HDR support or proxy repair is claimed by this package.


### Current work package — P1.04 observable import and proxy repair

Starting commit: `57af80a4d78242e1f691a5cf6b05ae696e907d78`; isolated branch
`codex/p1-media-jobs`, stacked on draft PR #10. Every gate passed for the starting
commit in CI run 34728175000. The fresh local non-browser baseline also passed
139 backend, 92 frontend and 12 repository tests plus lint/type/build/format.

Selected scope: real tracked import stages/cancellation, bounded SDR preview
preparation, and revision-checked proxy repair on desktop and native iOS. Keep
the legacy import response compatible. Prepare a new preview at a generated path,
validate timing/orientation/audio and source identity, then atomically switch the
project metadata. Preserve annotations, narration, originals and previous proxies.
Do not allow autosave clients to replace immutable media metadata. Repair changes
the authoritative revision; a stale concurrent edit remains a recoverable conflict.

HDR conversion is a separate fixture-based spike and remains an explicit open
P1.04 gate; native rejection stays until preview and both export conversions pass.
Physical Photos/Files, cancellation/background and real phone-media acceptance
remain pending. Status: automatically verified for this slice. Local gates pass
153 backend, 97 frontend, 12 repository and 16 browser tests. All six CI gates
passed at `34fa4f2` in [34753579589](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34753579589), including 25 native tests and the unsigned archive.
The final wrong-operation upload guard passed all ten focused media cases; full
current-head CI is recorded on [draft PR #11](https://github.com/BakedChicken77/bjj-telestrator/pull/11).
The completion record, interfaces, retention/rollback and numerical MP4 evidence
are in [media preparation verification](docs/p1-media-preparation-verification.json). A missing derived preview
cannot block saving pending edits; creation and replacement still require media.
Repair opens a fresh undo session. The original source and all old proxies remain
retained. The complete phase is not yet accepted.

## Historical delivery records

These are dated delivery snapshots, not the current candidate status. The September 12 record above supersedes old unchecked native/repository setup items: the remote repository exists and main passed native SDK tests and an unsigned archive. Fresh candidate CI now passes; signed-build and physical-device gates remain open.

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
