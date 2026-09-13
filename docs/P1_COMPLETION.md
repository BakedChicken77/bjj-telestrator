# Phase 1 completion record — September 13, 2026

Status: **device/staging verification pending**; **Phase 1 is not accepted**.
Code candidate `b5c7ba2` passed all six CI gates, including 32 native XCTest
methods, the unsigned iPhone archive, Docker and all 19 browser workflows.
Signed-update, actual phone media/Files interchange, accessibility, realistic
phone workloads and fresh Windows-host gates remain open.

Steve explicitly authorized uploading Phase One code. The prepared source and
generated fixtures are published in [draft PR #12](https://github.com/BakedChicken77/bjj-telestrator/pull/12),
stacked on #11. Initial published candidate: `162c32916490242810afd0fb8fe693b3d72c205c`.
Its tree matches local `96f1c98` exactly; GitHub-assigned commit metadata gives
the published commits different IDs. The first run is
[34766382957](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34766382957);
current native-test corrections are published at
`b5c7ba292d48e08e820c01a75c9c9f2f2b678f59` in
[CI 34767642230](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34767642230).
Signing, release publication and physical-device acceptance remain separate gates.

Starting commit: `dadeee523f8a933c53333c2b298a8058b9f8e604`; branch
`codex/p1-completion`, isolated from the original workspace. Application version
remains 1.1.0; project schema remains 2. No existing branch was reset.

Published implementation commits (local source trees were verified identical):

| Tasks | Published commit | Local source | Outcome |
| --- | --- | --- | --- |
| P1.04 | [2e8a42c](https://github.com/BakedChicken77/bjj-telestrator/commit/2e8a42c79ada197047763868a434ccc797ff2b93) | `b876fa3` | HDR delivery and shared encoded fixtures |
| P1.04–P1.06 | [c22bef8](https://github.com/BakedChicken77/bjj-telestrator/commit/c22bef859719e26687e253b50061027c694c9b04) | `c950351` | Package services, native bridge, timing fixtures and cleanup |
| P1.05/P1.07 | [8904c6a](https://github.com/BakedChicken77/bjj-telestrator/commit/8904c6aae5075cac0bdcd6e7c86f092faa987b4d) | `8663030` | Real package actions, semantic editing and appearance |
| P1.08 | [0241912](https://github.com/BakedChicken77/bjj-telestrator/commit/02419122645fc0bff7d2682bd0c7e068dcfe121f) | `e725da5` | Immutable history sharing and bounded PCM preview |
| P1.05 | [2323f3d](https://github.com/BakedChicken77/bjj-telestrator/commit/2323f3dc07f83e999c3b7c949e80803ed0f50f97) | `e7fb325` | Lost-acknowledgement package retry identity |
| P1.08 | [17b387d](https://github.com/BakedChicken77/bjj-telestrator/commit/17b387d4d819d2b489be34be79a6d3fb5a063065) | `14d77f9` | Disposable summary cache and scale evidence |
| P1.07/P1.08 | [7ac7309](https://github.com/BakedChicken77/bjj-telestrator/commit/7ac73092dacd2d585149232e6e132ff532dd38fb) | `8aaa933` | Reachable audio controls and actual browser profile |

The local feature implementation is `8aaa933`; web build/`ios:sync` passed again
at that source commit. Subsequent native timing-test corrections are local
`3671cde` and `497a6f7`, published as `3c94cf3` and `b5c7ba2`.

The starting commit passed all six CI gates in
[run 34753976427](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34753976427),
including 25 XCTest methods, Docker and an unsigned archive. That is baseline
evidence only. Two earlier uploads were blocked by automatic approval review
because it required explicit authorization for the public source/fixture upload.
Steve's subsequent authorization resolved that blocker; no alternative upload
route was used to bypass either rejection. Main and the earlier draft PRs remain
unchanged.

## Automated commands and results

Fresh code evidence: [CI 34767642230](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34767642230)
at `b5c7ba292d48e08e820c01a75c9c9f2f2b678f59` passed **216 backend tests
(45.81 seconds), 104 frontend tests, 12 repository tests, 19 browser workflows
(2.2 minutes) and 32 native tests (76.551 seconds)**. Existing lint/type/build/
format/actionlint gates, production Docker build/startup and the aggregate gate
passed. Xcode 26.6 (17F113), iPhone 17 Pro simulator, iOS 26.4.1, SDK 26.5.
`python3 scripts/test_ios.py --derived-data .ci-artifacts/ios-derived --result-bundle .ci-artifacts/ios-tests.xcresult`
and `python3 scripts/ci/build_ios.py` both passed. The unsigned archive uses
version 1.1.0 / build 33.1; it is not an installable signed IPA. CI retains the
unsigned archive/simulator and XCTest artifacts for 14 days. Machine-readable
job IDs, artifact digests, source hashes and results are in
[p1-completion-ci.json](p1-completion-ci.json). This evidence commit follows the
verified code; the PR checks identify subsequent documentation-only candidates.

The first published candidate (`162c329`, CI 34766382957) passed all 216 backend
tests (41.75 seconds), 104 frontend tests, 12 repository tests, all 19 browser
workflows (2.5 minutes), lint/type/build/format and production Docker build/startup.
Native compilation passed, as did package restore/edit/export, PQ/HLG conversion,
preview cleanup and disposable-index tests. One timestamp test failed; the archive
was correctly skipped and the overall CI gate failed.

The timestamp test counted compressed marker/control buffers as pictures (244
versus 240 and 95 versus 91), read media-time timestamps before MP4 edits, and
assumed 30 fps while native import selected a 60 fps default for the fast source.
The correction requests 30 fps, decodes picture buffers and uses output presentation
timestamps. All independently listed PTS/count and source/output color-boundary
assertions remain; output frames are additionally checked at every 30 fps timestamp.
The fix uses Apple's documented [decoded output behavior](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput/outputsettings),
[marker-buffer handling](https://developer.apple.com/videos/play/wwdc2020/10090/)
and [output timestamps](https://developer.apple.com/documentation/coremedia/cmsamplebuffergetoutputpresentationtimestamp(_:)).
[CI 34767065154](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34767065154)
then verified every source PTS, every output PTS and the exact scene transition.
Its four failures were the opposing-channel color threshold: native conversion
of the untagged SDR blue patch measured RGB `[38,46,254]`, above the original
40-level ceiling. The ceiling is now 64, with the dominant channel still above
200; a wrong scene frame fails by more than 130 levels. Timing assertions and
timeouts are unchanged. This is a measured codec/color allowance for the timing
fixture, not acceptance of phone color reproduction. The corrected code passes all six gates in the run listed above.

The following local results preceded publication.

The complete local command was:

```bash
BJJ_E2E_DATA_DIR=/tmp/bjj-phase1-candidate \
BJJ_E2E_CHROMIUM_PATH=/workspace/scratch/dd023ff97e5b/chromium/chromium \
backend/.venv/bin/python scripts/verify.py --browser
```

It passed 203 backend tests (172.74 seconds), 104 frontend tests, 12 repository
tests and 18 Playwright workflows (5.4 minutes), plus backend/script Ruff, ESLint,
strict TypeScript, production build and Prettier. The browser suite includes real
microphone capture/preview/AAC export, pending-save conflict/draft recovery,
retained export retry, all six canvas types, touch gestures and phone orientation.
The package workflow exercises all six numeric creation/edit paths, modal/audio
focus return, large text/themes, ZIP download/upload, independent restore and
actual MP4 output at 1280×720 and 390×844, then phone landscape.

Focused evidence: 37 package/service cases, 16 cleanup/recovery cases, six HDR
cases and two original-PTS timing cases pass. Native tests now include the same
12 package archives, two HDR movies and two timing movies. They were unexecuted
at the time of this local run; subsequent native evidence is recorded above. `npm run ios:sync` passed the web build and asset copy; it does not
compile Swift. Docker, Swift and xcodebuild are unavailable in this Linux runtime.

After the final library-index changes, the entire backend suite passed **216 tests
in 171.14 seconds**. The existing repository-configured Ruff gates and all 12
repository tests passed again. Five targeted browser workflows passed: package
retry/desktop/phone in 47.7 seconds and checkpoint/copy/trash desktop/phone in
43.6 seconds. One new package retry test brings the unique browser coverage to
19 cases; the full run above contained 18, followed by these focused runs.
The retry test accepts a real server operation, loses its acknowledgement, then
recovers the same job after reconnecting with exactly one create request.
Final index/cleanup checks passed 16 focused cases (7.09 seconds), including a
damaged disposable index that must not block safe derived-preview cleanup.
An ad hoc Ruff invocation initially omitted the repository's configuration and
reported nine unrelated script style warnings; rerunning the existing configured
commands passed. No signing/setup scripts or lint rules were changed.

Existing nonblocking warnings remain: Starlette/httpx/AnyIO deprecations, npm's
proxy-configuration warning and the existing large frontend bundle warning.
No assertions, meaningful gates or timeouts were weakened to obtain these results.

The real-editor scale profile found the desktop audio panel covering Play when
three takes were expanded. Moving its bounded panel into normal layout fixes that
overlap. The existing real microphone/preview/rerecord/AAC workflow then passed
again in 36.0 seconds (42.6 including setup), and its documentation screenshot
was refreshed. Prettier, TypeScript and ESLint passed again after the layout fix.

## Task records

| Task | Outcome and changed interfaces/files | Current status and unresolved gate |
| --- | --- | --- |
| P1.01 | Refreshed README/IOS_README/VERIFICATION/DEVICE_ACCEPTANCE/tracker. Existing candidate SHA/version/build-specific signing evidence gate and bundle identity preserved. | **device/staging verification pending**: signed install/update over populated projects, actual phone exports/share, 20-minute/lower-resource hardware and Windows 11 host. |
| P1.02 | Existing schema-2 migration/revision/unknown-field recovery preserved. HDR capability added in TypeScript/Python/Swift; source metadata stays immutable. `model.ts` caches only owned frozen validated nodes for editing. | **automatically verified** for established save/migration contracts; added native HDR conformance passes; physical migration/reopen remains pending. |
| P1.03 | Existing dirty/saving/failed/conflict and draft recovery remain tested. `diagnostics.ts` retains bounded allowlisted codes, now including package/cleanup failures. Stale drafts after proxy repair resolve the current valid preview on recovery-as-copy. | **automatically verified** locally and previously in native CI for foundations; current physical suspension, force-close, low-space and diagnostic sharing remain pending. |
| P1.04 | `color.py`, `media.py`, native `BJJRenderer`, render-plan color policy and shared fixtures implement PQ/HLG→SDR before annotations. Preserve transfer/primaries/matrix/range, static HDR probe facts and rational timing intent. Real 120 fps/VFR PTS fixtures verify time alignment. | **device/staging verification pending**: shared desktop/native HDR and source/output timing checks pass; actual phone color/format acceptance pending. Runtime `hdrToSdr` remains false; all Dolby Vision variants are rejected. |
| P1.05 | `package_archive.py`, `packages.py`, `package_jobs.py`; native `BJJPackageArchive`, `BJJPackageJSON`, `BJJProjectPackage`, `BJJPackageJobs`, plugin/inbox/UTI; `api.ts`, `native.ts`, `usePackages`, `ProjectPackages`. Revision-bound jobs, bounded ZIP64, checksum/media validation, new-copy install and Files/download actions. | **device/staging verification pending**: desktop/native package fixtures, safety/browser checks and real exports pass; iPhone→Windows→iPhone and multigigabyte ZIP64/Files transfer pending. |
| P1.06 | Earlier checksums/space/immutable retry/checkpoints/trash/copies preserved. New `cleanup.py`, `BJJAssets.previewCleanup`, conditional API/bridge and `ProjectStorage` UI reclaim only unreachable old UUID previews. `storage.py`/`BJJProjectRecovery` repair stale-draft preview references safely. | **device/staging verification pending**: desktop/native recovery/cleanup tests pass; physical storage/lease/interruption checks pending. Source/recording reclamation remains conservative retention. |
| P1.07 | `AnnotationAccess`, `GeometryFields`, `NumberField`, `Modal`, `Appearance`; App/Inspector/VoiceoverPanel and CSS expose keyboard/non-drag creation, selection, geometry, timing and layers; focus return, themes, larger text, reduced motion and touch targets. | **device/staging verification pending**: browser workflows and visual inspection pass; actual VoiceOver, large-text portrait/landscape and adjacent touch targets need physical acceptance. |
| P1.08 | `shareUnchanged.ts`, `model.ts`, `store.ts`, `pcmPreview.ts`, audio transport/hook and tests; `storage.py`/`BJJStore` summary index; editor/browser/media profile scripts. Shared immutable history, bounded PCM windows, all audible overlaps retained, explicit capacity stop. ZIP/path/origin/UUID and dependency boundaries preserved. | **device/staging verification pending**: reproducible Linux results below and new native index tests pass; device memory/thermal/real-roll measurements remain open. |

## Real media and export evidence

- Fresh native portable round trip at `b5c7ba2`: H.264/AAC, 320×180, 2.0 seconds,
  **7,815 bytes**, source hash unchanged. Native backup/restore preserves cue
  `[0.5,1.5)`, narration placement `[0.75,1)` and independent object UUIDs.
- Fresh native PQ/HLG exports: H.264 Rec.709, 320×180, 2 seconds, no audio;
  **6,438 / 6,013 bytes**. Preview and export gray ramps matched exactly:
  PQ `[0,30,79,147,201,242,252,254]`, HLG `[0,38,82,111,127,155,191,238]`.
  Half-open cue boundaries and both source SHA-256 checks pass. Native and
  FFmpeg tone curves differ as documented; real phone color review remains open.
- The shared 120 fps/VFR test verifies all **240 / 91** decoded source PTS,
  then all **60** output PTS at 30 fps. Both preview/export change blue to green
  at exactly **1.0 second**, with cue `[0.5,1.5)` and unchanged source hashes.

- The baseline native simulator produced H.264/AAC, 320×180, 4 seconds, 26,906
  bytes; source SHA-256
  `c12bb667c548d7b83c76d179fd987c5fb5fd082bca884cf899eed8648787741b`.
  Xcode 26.6; iPhone 17 Pro simulator, iOS 26.4.1, SDK 26.5. This is not a new
  candidate or physical-device result.
- Desktop HDR fixtures: H.264 Rec.709, 320×180, 2 seconds, no audio; PQ 3,875 bytes
  and HLG 3,809 bytes. Gray patches remained distinct, preview/export matched within
  the fixture tolerance and red cues obeyed `[0.5,1.5)`. Source hashes remained
  `d18a31f34be0a1d8b20570d09f1a8b74c8946d9551e0e64e2f221d6bdbfefa68`
  and `8506c98ef56bb91f778eb7d4cb5ef3a0d8b0d9826f5ca900e154d810ee4a0fea`.
- Package fixture: a two-second 320×180 blue source and a 0.25-second PCM tone
  at `[0.75,1)`, with a red rectangle `[0.5,1.5)`. Repeated portable copy/edit/export
  preserves source hash
  `8c5d74003882b99cd975e7df63da7da7a6df543ed429918284149fbbdef833e4`.
  Native round-trip checks pass with the identical source/recording bytes.
- Shared timing movies contain independently listed PTS at a 120 Hz time base.
  Original 120 fps and VFR imports produce 30 fps previews/exports with a blue→green
  transition at exactly one second and red cue boundaries at 0.5 and 1.5 seconds.
  Source SHA-256 is rechecked after both outputs. No exact-frame-navigation claim.
- Fresh browser output is an ordinary H.264 MP4, four seconds, generated 640×360
  input. Restored source hashes and all six edited geometries match the original
  review. The existing 20-second arrow/circle and narration exports also pass.

## Measured scale and remaining limits

Linux 6.18.44 x64, Node 24.19.0, Python 3.12.14, Xeon Platinum 8370C 2.80 GHz,
nine reported logical CPUs. Measurements include runtime/container scheduling;
they are not Windows-host or iPhone predictions. Commands use generated media only.

```bash
node --expose-gc scripts/profile_editor.mjs .ci-artifacts/editor-profile.json
backend/.venv/bin/python scripts/profile_phase1.py --output .ci-artifacts/new-workload --export
```

| 100-edit history workload: 100 cues, 20 paths × 2,000 points | Before | After |
| --- | ---: | ---: |
| Retained JS heap increase | 394,224,336 bytes | 4,537,696 bytes |
| Distinct retained freehand point arrays | 2,000 | 20 |
| Median edit | 211.05 ms | 133.51 ms |
| 95th-percentile edit | 287.37 ms | 273.03 ms |
| Whole Node process RSS | 999,292,928 bytes | 509,648,896 bytes |
| Three active 20-minute mono takes: decoded audio | 691,200,000 bytes | 11,520,000 bytes of windows |

Raw before/after results are in `docs/performance/`. Node RSS includes Vite/JIT and
transient allocations. Complex edits still have visible latency; this is not a
60 fps editing claim. Per-frame filtering was already inexpensive (0.003–0.007 ms
in these runs), so no replacement interval framework was introduced. PCM windows
have unit tests for overlaps, offsets, seek eviction, original samples, range
failure and seam scheduling; real browser recording/preview/export still passes.
Hardware playback synchronization and audible seam review remain open.

The complete synthetic workload used 100 cues, twenty 2,000-point paths, and three
overlapping 20-minute mono 48 kHz narration tones. The 1080p/30 fps proxy took
294.36 seconds; the final H.264/AAC export took **910.50 seconds** (15 minutes
10.50 seconds). Output is **1920×1080, 1200.0 seconds, 37,132,555 bytes**. Original
size is 15,898,950 bytes; unchanged source SHA-256:
`aea26b1ca9ae655402b40303ee07eb6af10d541d4002c62b245c12aff4682aca`.
Python peak RSS was 225,902,592 bytes; the largest child-process peak was
644,861,952 bytes. These are separate process maxima, not total application memory.
A static grid plus tones cannot substitute for a realistic gym roll, human
listening, a physical iPhone or its thermal/foreground behavior.

The same 200-record library initially required 72.19, 73.14 and 72.82 seconds to
list, because each full drawing timeline was validated. A disposable 8 KiB maximum
summary now refreshes after saves. Rebuilding the pre-existing library took
92.52 seconds; subsequent listings with new store instances took **63.24 and
57.85 milliseconds**. Missing/corrupt/stale/foreign summaries rebuild; unsupported
documents still cannot open/export. Cache write failure does not fail a confirmed
save. The cold rebuild remains a measured limitation. No thumbnail/search/favorites
features from Phase 2 were introduced. Repeat the metadata-only measurement with:

```bash
backend/.venv/bin/python scripts/profile_phase1.py \
  --output .ci-artifacts/relist \
  --existing-library .ci-artifacts/new-workload/library
```

`scripts/profile_browser.mjs` additionally opened the actual 1280×720 development
editor with that 100-cue/three-take project. Chromium 149.0.7827.0 completed ten
numeric style edits and 12.14 seconds of preview. It received eighteen HTTP 206
audio windows/header reads across all three recordings, with a largest body of
480,000 bytes; it did not fetch full 20-minute WAVs. Post-GC JS heap was 24,007,444
bytes with 3,476 DOM nodes. Startup plus edits committed React 53 times; the
playback sample committed 371 times and reported no long tasks (≥50 ms), with
a worst animation-callback gap of 133.4 ms. No hardware sync claim follows from it.

The ten automation-driven edit-to-paint samples ranged from **0.81 to 2.58 seconds**,
including locator/focus/scroll and development StrictMode overhead. The longest
startup/edit long task was 1.29 seconds. Complex-edit responsiveness remains a
measured limitation despite the retained-history memory reduction; no smooth
large-project editing claim is made. These headless development measurements also
ran alongside local verification and are not a production-device benchmark.
Raw values are in `docs/performance/p1-browser.json`. The first profiler attempts
had incorrect control labels and an incorrect audio-route matcher; the corrected
harness retained the real click, source-hash and bounded-response assertions.

```bash
BJJ_E2E_CHROMIUM_PATH=/path/to/chromium \
  node scripts/profile_browser.mjs \
  .ci-artifacts/new-workload/export-device .ci-artifacts/browser-profile
```

This command changes only the generated review's style through real controls.
Use the synthetic workload directory, never a personal library.

## Migration, retention and rollback

Schema stays 2. Packages contain the confirmed document, original and referenced
narration, plus an optional proxy. Restore creates a new UUID copy and retains the
original document/manifest/reference map; it never overwrites a current review.
Exports, checkpoints, removed takes and undo history are excluded from this first
package format. Keep a whole-container/data-folder backup to retain those versions.
Actual expanded bytes/CRC/SHA, JSON depth, media and safe paths are checked before
atomic installation. Failed/cancelled jobs clean only their staging; completion
receipts/install markers reconcile interrupted publication.

Original media and recording files remain immutable and retained for undo and
durable references. Preview cleanup has a 24-hour grace period, checks retained
JSON owners and requires an unleased current revision. Broken metadata retains
files. No cross-project hard links are introduced.

Before rollback, keep the entire newer project and external package. Recover a
compatible prior document in a separate copy; never strip HDR capabilities or
overwrite newer JSON as a fake downgrade. Keep the existing iPhone bundle identity;
uninstalling is not rollback. Preserve the prior working source/release artifacts.

Documentation updated: IMPLEMENTATION_PLAN, PROJECT_FORMAT, ARCHITECTURE, README,
IOS_README, VERIFICATION, DEVICE_ACCEPTANCE, CHANGELOG and two material decision
records. P5.01–P5.07 remain **not selected**, with no placeholder controls.

Next eligible work: review the stacked PRs and run the signed-device/Windows
checklist against the exact reviewed candidate when distribution is authorized. Phase 2 remains not started. No release,
merge, signing, TestFlight upload, paid service or customer charge was performed.
