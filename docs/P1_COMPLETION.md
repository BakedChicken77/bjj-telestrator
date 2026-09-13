# Phase 1 completion record — September 13, 2026

Status: implemented with local automated evidence; **Phase 1 is not accepted**.
The new native code has not compiled or run against an Apple SDK. Physical-device,
signed-update, actual Files interchange and fresh Windows/Docker gates remain open.

Upload authorization received: Steve explicitly authorized uploading Phase One
code after the public repository/source/fixture/CI scope was presented. The earlier
approval blocks below are historical. Upload the prepared commits, open the next
draft PR above #11 and run the existing CI; signing, release publication and
physical-device acceptance remain separate gates.

Starting commit: `dadeee523f8a933c53333c2b298a8058b9f8e604`; branch
`codex/p1-completion`, isolated from the original workspace. Application version
remains 1.1.0; project schema remains 2. No existing branch was reset.

Local implementation commits:

- `b876fa3`: P1.04 HDR delivery spike and shared encoded fixtures.
- `c950351`: P1.04–P1.06 package services/native bridge, timing fixtures and cleanup.
- `8663030`: P1.05/P1.07 real package actions, semantic editing and appearance.
- `e725da5`: P1.08 immutable history sharing and bounded PCM preview.
- `e7fb325`: P1.05 lost-acknowledgement package retry keeps the same request UUID.
- `14d77f9`: P1.08 disposable summary cache, native parity tests and full scale evidence.
- `8aaa933`: P1.07/P1.08 reachable audio/playback layout and actual browser profile.

The final source implementation is `8aaa933`; this completion record is committed
after it as documentation. Web build/`ios:sync` passed again at that source commit.

The starting commit passed all six CI gates in
[run 34753976427](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34753976427),
including 25 XCTest methods, Docker and an unsigned archive. That is baseline
evidence only. No new remote branch/PR or CI run was published in this work:
automatic approval review rejected the attempted GitHub tree upload because remote
publication authorization was not established. Explicit branch-upload/CI approval
is the next action after local review. No alternate upload route was attempted.

Continuation attempt on September 13: after Steve replied “Continue” to the
branch-upload/CI request, read-only GitHub checks confirmed the connected account
is `BakedChicken77`, with administrator/push rights to this **public** repository.
Main remains `f5323b3`; draft #11 remains open at `dadeee5`. A normal Git push
could not authenticate in this runtime. The connected GitHub tree upload was then
rejected by automatic approval review: it interpreted the brief's publication
restriction as prohibiting public disclosure of the large source/fixture payload
without specific approval. No remote branch, commit, draft PR or CI run was
created. No retry or alternate route followed that rejection. Remaining action:
explicit approval to upload the Phase 1 source and generated fixtures to the public
repository, create the next draft PR above #11, and run its existing CI.

## Automated commands and results

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
12 package archives, two HDR movies and two timing movies; they are authored,
not executed. `npm run ios:sync` passed the web build and asset copy; it does not
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
| P1.01 | Refreshed README/IOS_README/VERIFICATION/DEVICE_ACCEPTANCE/tracker. Existing candidate SHA/version/build-specific signing evidence gate and bundle identity preserved. | **device/staging verification pending**: fresh native/Docker CI, signed install/update over populated projects, actual phone exports/share, 20-minute/lower-resource hardware and Windows 11 host. |
| P1.02 | Existing schema-2 migration/revision/unknown-field recovery preserved. HDR capability added in TypeScript/Python/Swift; source metadata stays immutable. `model.ts` caches only owned frozen validated nodes for editing. | **automatically verified** for established save/migration contracts; added native HDR conformance must run with the new candidate. |
| P1.03 | Existing dirty/saving/failed/conflict and draft recovery remain tested. `diagnostics.ts` retains bounded allowlisted codes, now including package/cleanup failures. Stale drafts after proxy repair resolve the current valid preview on recovery-as-copy. | **automatically verified** locally and previously in native CI for foundations; current physical suspension, force-close, low-space and diagnostic sharing remain pending. |
| P1.04 | `color.py`, `media.py`, native `BJJRenderer`, render-plan color policy and shared fixtures implement PQ/HLG→SDR before annotations. Preserve transfer/primaries/matrix/range, static HDR probe facts and rational timing intent. Real 120 fps/VFR PTS fixtures verify time alignment. | **implemented**: desktop fixtures pass; native conversion/timing fixtures and actual phone color/format acceptance pending. Runtime `hdrToSdr` remains false; all Dolby Vision variants are rejected. |
| P1.05 | `package_archive.py`, `packages.py`, `package_jobs.py`; native `BJJPackageArchive`, `BJJPackageJSON`, `BJJProjectPackage`, `BJJPackageJobs`, plugin/inbox/UTI; `api.ts`, `native.ts`, `usePackages`, `ProjectPackages`. Revision-bound jobs, bounded ZIP64, checksum/media validation, new-copy install and Files/download actions. | **implemented**: desktop safety/browser/real export checks pass; native build/tests, iPhone→Windows→iPhone and multigigabyte ZIP64/Files transfer pending. |
| P1.06 | Earlier checksums/space/immutable retry/checkpoints/trash/copies preserved. New `cleanup.py`, `BJJAssets.previewCleanup`, conditional API/bridge and `ProjectStorage` UI reclaim only unreachable old UUID previews. `storage.py`/`BJJProjectRecovery` repair stale-draft preview references safely. | **implemented**: local recovery/cleanup tests pass; new Swift and physical storage/lease/interruption checks pending. Source/recording reclamation remains conservative retention. |
| P1.07 | `AnnotationAccess`, `GeometryFields`, `NumberField`, `Modal`, `Appearance`; App/Inspector/VoiceoverPanel and CSS expose keyboard/non-drag creation, selection, geometry, timing and layers; focus return, themes, larger text, reduced motion and touch targets. | **device/staging verification pending**: browser workflows and visual inspection pass; actual VoiceOver, large-text portrait/landscape and adjacent touch targets need physical acceptance. |
| P1.08 | `shareUnchanged.ts`, `model.ts`, `store.ts`, `pcmPreview.ts`, audio transport/hook and tests; `storage.py`/`BJJStore` summary index; editor/browser/media profile scripts. Shared immutable history, bounded PCM windows, all audible overlaps retained, explicit capacity stop. ZIP/path/origin/UUID and dependency boundaries preserved. | **implemented**: reproducible Linux results below; new native index tests and native/device memory/thermal/real-roll measurements remain open. |

## Real media and export evidence

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
  Native round-trip checks use identical bytes but await execution.
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

Next eligible work: authorize upload of this local working branch and run the
existing native/Docker CI, fix any candidate failures, then use the exact signed
candidate for the device/Windows checklist. Phase 2 remains not started. No release,
merge, signing, TestFlight upload, paid service or customer charge was performed.
