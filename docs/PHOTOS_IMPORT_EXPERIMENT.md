# Photos import diagnostic repair and policy experiment

## October 6 automatic comparison candidate

Steve authorized the automatic-policy TestFlight comparison. This candidate changes only the two signed app-target policy settings from compatible to automatic; diagnostics, provider/copy ownership, cancellation, hashes, Dolby/color guards and media preparation remain identical to control build 2.1.0 (36.1), preview SHA `41ff232540ecfe98607938981e7a914ccfeefa0d`. The compatible picker unit test now requests compatible explicitly and also checks that default construction follows the embedded configuration. This is an experiment, not adoption of a proven faster shipping policy. No main merge, production release, media migration or automatic retry is included.

The October 6 control report recorded one 17.333-second video: provider wait 267.587 seconds, copy 0.098 seconds, preparation 3.180 seconds, editor ready 271.063 seconds. A brief background/return was observed and did not cancel the import; no expiration occurred. Cache/local/cloud condition is unknown. This is not a controlled foreground-only baseline and cannot establish conversion or speed improvement. The 36.1 release passed full CI and its TestFlight receipt verified availability; older pending-automation statements below are historical.

Phone handoff: update without uninstalling, select that same video, keep the app foregrounded and screen-record picker processing if practical. Repeat three times, retain failures, label repeats as warm, export diagnostics, and check preview plus MP4 color/audio/orientation. Compare against three foreground-only compatible-control runs using TestFlight's 36.1 build, alternating policy order where practical; do not install 30.2 or older project software. Preserve backups and saved reviews. If automatic rejects Dolby, export diagnostics and use the compatible control for now: explicit in-app compatible reselection is still Phase 3 work, not implemented here. Stop testing if colors are wrong or prior reviews are affected.

Required candidate release gates: exact-head full CI, signed IPA policy `automatic`, matching SHA/version/build receipt, Apple processing VALID and intended internal tester availability. Actual physical performance/quality acceptance remains open.

October 5, 2026. Implementation is a candidate; physical acceptance and performance remain open. Steve subsequently authorized source upload and a TestFlight validation release after required CI passes. Production publication remains out of scope.

## Baseline and scope

PR #37 was rechecked as draft/open, head `6d3193d8e18911e954fe1bd396a89790a0ef1a97`. Preview baseline: `faee763780353424f600e065a37b5d5da6528666`, 2.1.0 (35.1). Historical comparison: 30.2 `3553980a3678834da79781bc8f345dd58ad44c61`, 31.1 `4227fcd033eb2dd048349ab86b79092a503f391c`. This focused branch is stacked on #37; it does not merge main or change the preview branch.

The global compatible policy remains the default. Phase 3 (adopting automatic and explicit Dolby compatible reselection) is deliberately gated on physical Phase 2 results. No renderer, Dolby guard, source/hash/proxy validation, saved-project format, narration, editing, tip, logo or diagnostics-entry-point change is made.

## Implemented contract

- Typed worker phase replaces inference from legacy stage and Photos-wait boolean. `importPhase` is optional in saved records; `phaseAtStop` and the first accepted stop reason survive cleanup/reload. Terminal counters and import timings cannot be changed by late workers. Success already committed wins over cancellation.
- A request completion gate claims the callback once. Cancellation before claim settles a never-callback request; cancellation during callback ownership signals the cooperative copy and waits asynchronously for callback settlement before cleanup. The provider URL is copied inside its validity callback. No temporary URL is handed to a later task. Publication still requires the cancellation fence.
- Provider events distinguish request/success/failure/cancellation/ignored callback and actual copy start. Sanitized provider errors are supporting evidence; media/library boundaries report the canonical job cause. Historical `photosReady` records remain unchanged.
- UIKit scene callbacks use one coordinator and the exact library hosted by the home controller. Owning-scene transitions distinguish inactive/background/active and deduplicate repeats; inactive delays editor presentation without cancelling or pretending to be background. Editor recording/gesture lifecycle is unchanged. Capacitor URL/activity/connect forwarding remains.
- Background assertions are acquired once, with denial recorded separately from expiration, and balanced on success/stop/failure. Expiration checkpoints phase, lifecycle, cause and finite allowance before signalling cancellation. No unlimited execution or restart/resume claim.
- Five-second checkpoints remain. A 15-second helper shows observed elapsed Photos wait without a timeout or fabricated ETA. Diagnostics remain local and manually exported.

## Diagnostic envelope version 3

Persisted media record version stays 1 with optional fields, and project schemas are unchanged. Exported import rows now include `sessionId`, `operationId` (the app-owned job correlation UUID), `attemptId`, optional `retryOf`, `requestedRepresentation`, `importPolicyVersion`, `phaseAtStop`, `providerOutcome`, `lifecycleState`, `lifecycleSource`, `backgroundTaskGranted`, and finite `backgroundTimeRemainingSec`. Legacy missing fields remain unknown. No Photos asset IDs, filenames, paths, annotation text or raw error descriptions are added. Existing 500-event/seven-day bounds, redaction and failure isolation remain.

`provider_wait` ends at an observed provider outcome, including failure; interpret it with `providerOutcome`. `provider_wait_elapsed` is partial observed time, frozen at stop. `copy` and `prepare_total` are completed measurements only when recorded normally. Keys ending in `_elapsed` are partial observations; they are not additional completed phases. Encoding, hashing, inspection and validation are children of `prepare_total`. `provider_and_copy` overlaps provider wait and copy: never add all three. `editor_open` measures object construction only. `editor_ready` measures accepted request through audio composition and the actual prepared AVPlayerItem's ready-to-play observation; it remains absent on failure/dismissal. `post_import_ready` is the nonoverlapping post-preparation refresh/presentation/audio/player-readiness interval (including deferred background presentation). It is not first-pixel or picker-visible processing time. Measure picker-owned work by screen recording. Delivered codec/hash/HDR describe the rendition, not the camera original or an original Photos identity.

## Preparing instrumented variants

`BJJ_PHOTO_IMPORT_POLICY` is an Xcode build setting for both Debug and Release, embedded in signed `Info.plist` as `BJJPhotoImportPolicy`. Values are `compatible` (control/default) or `automatic` (candidate). Both picker construction and request metadata use the same captured policy. There is no home mode setting, new Photos authorization, global `.current` experiment or automatic retry.

For an authorized candidate build, change only the two app-target `BJJ_PHOTO_IMPORT_POLICY = compatible;` settings in `frontend/ios/App/App.xcodeproj/project.pbxproj` to `automatic`, on a separately labeled experimental commit; retain identical instrumentation. The existing preview workflow signs those Release settings. Inspect the archived app's Info.plist and each exported request's representation; mismatches fail the experiment. Re-run native tests and archive for each variant. Do not publish or update the preview branch without separate authorization. Legacy Capacitor importer intentionally stays compatible; native home is the experiment entry point.

## Run sheet (copy this table for every run)

| Run | Fixture label | Policy | SHA / version / build | Xcode / SDK | iPhone / iOS | Storage band / thermal / Low Power | Local / cloud / unknown | Warm / first observation | Picker sec | Provider sec / outcome | Copy sec / bytes | Prepare sec | Editor ready sec | Result / preview / MP4 color, audio, duration, orientation | Operation / attempt |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pending | pending | pending | pending | pending | pending | pending | unknown | unknown | | | | | | not run | |

Fixtures: Steve's troublesome approximately 20-second clip, local SDR, HEVC SDR, Dolby Vision HDR, trimmed/edited Photos video, six-minute and fifteen-minute clips; include portrait/landscape and VFR. Labels stay in this external run sheet, not app telemetry. Keep original diagnostic files unchanged; use the newest cumulative report rather than summing snapshots. Do not downgrade pause-aware saved reviews or delete personal media to force cache eviction.

Keep performance trials foregrounded, same iPhone/OS and controlled conditions. Alternate A/B then B/A, at least three trials each; use five or more when spread is large. Document local/offline preparation (which warms caches), warm repeats, authorized cloud-dependent media, and unknown availability separately. A local Files control isolates post-provider work but may contain a different delivered rendition. Record medians, ranges and failures, not a small-sample p95.

Predeclared gates: material compatible latency >5 seconds should improve by at least 30% in median provider-plus-picker time on problematic local short clips; no unexplained repeatable local stall >30 seconds. Investigate median readiness regression exceeding max(10%, 1 second). If the stall cannot be reproduced, outcome is inconclusive. Quality gates always apply. No measured speed improvement has been established.

## Acceptance still required

Run repository tests and `backend/.venv/bin/python scripts/verify.py --browser`; macOS CI must pass native/StoreKit/UI tests, unsigned archive, frontend/backend/browser/Docker and aggregate checks. Check exact commit, not an earlier green build. No Linux substitute proves Swift compilation.

On iPhone: switch/return and lock/unlock while waiting/copying/encoding; actual long-absence expiration, retry, successful background completion, once-only foreground opening, termination/relaunch and saved-review preservation. Missing lifecycle breadcrumbs fail the physical gate. Test exact troublesome Dolby clip, preview/export color/audio/orientation, narration, drawing/timing, undo, backups, tips, VoiceOver and larger text. No phone, screen recording, paired timings or Instruments trace is available in this coding environment.

Only after measured policy/quality acceptance implement Phase 3 recovery and consider changing the default. If inconclusive, retain compatible and isolate 31.1 polling/presentation changes one at a time in test-only builds. No new PhotoKit permission or architecture is in scope.

## Local verification and remaining automation

Local verification passed 216 backend tests, 111 frontend tests, 19 repository tests, backend/script lint, frontend lint, TypeScript, production web build and formatting. The required browser command was attempted: all 21 cases could not launch because the pinned Chromium executable was absent. Installing that pinned browser returned an invalid/empty ZIP, so browser acceptance remains open. Docker is unavailable on this host. Native Swift/StoreKit/UI tests and the archive require macOS CI and have not run for this change.

The initial GitHub push was rejected by automatic approval review, which interpreted the no-publication instruction as excluding source upload. Steve then explicitly approved upload and TestFlight release after completion. Draft PR #38 is stacked on #37; GitHub macOS/full CI is now the release gate. No main merge, tag or production App Store submission is authorized. Physical comparisons are required before adopting automatic as the default.
