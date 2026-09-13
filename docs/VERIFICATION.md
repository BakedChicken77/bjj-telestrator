# Verification record

## P1.06 project recovery candidate — 2026-09-13 (started September 12)

Start: `04b03a8cac59ae6266b32117ed2a7b797a4f6636`, branch
`codex/p1-project-recovery`. Both service adapters and the shared UI implement
checkpoints, before-restore preservation, independent copies and retained deletion.
Initial backend suite: 138 passed (89.81 s), including 13 new recovery cases.
Frontend: 92 passed. The first candidate passed all six CI gates in [run 34726637336](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34726637336) at
`976343d46dd0fd08984e6422c10b1f1bea1d7960`. Native SDK compilation, all 22 XCTest
methods (48.621 s) and the unsigned archive passed. The follow-up conformance candidate also passed all six gates in
[run 34727251987](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34727251987). The existing real native export test now includes checkpoint restoration,
project deletion/restoration and retry from the retained input, keeping its pixel,
audio, codec/duration and source-hash assertions. Four new native recovery tests
cover stale revisions, checkpoint write failure, copy/collision and unsafe paths.

Local browser checks initially collided with retained test-project names. Cases
now use unique project names, await the destructive response and assert absence
through HTTP after reload. The checkout-backed local fixture store intermittently
returned removed directories after successful `os.rename`/`shutil.rmtree` calls;
an isolated Python filesystem audit recorded no application recreation call.
The **unchanged deletion/reload assertions passed** in clean GitHub CI (all 14
browser scenarios; new desktop/phone cases 6.7/6.3 s) and locally using a temporary
data root outside the synced checkout (23.0/17.3 s, 46.4 s including setup).
This isolates the observed anomaly to the local checkout-backed test storage;
it does not establish support for externally synchronized live project folders.
`BJJ_E2E_DATA_DIR` now permits an isolated local test data root. Normal CI keeps its
existing generated fixture path. No runtime save/delete workaround, weakened
assertion, disabled gate or enlarged timeout was introduced.

Local non-browser `scripts/verify.py` passed all backend/frontend/repository,
lint/type/build/format gates. Native compilation, 22 tests and the archive passed for the first candidate; physical install, VoiceOver, interruption, low-space
and realistic 20-minute workload checks remain open.

A follow-up conformance review found that Python's direct render-plan validator
could migrate schema-1 input while Swift rejected it. Both now reject migration
inside an immutable job/checkpoint input; the shared invalid fixture retains this
boundary. This preserves the separate explicit project-migration path. Recovery
metadata also validates timestamps and bounded storage revisions consistently.


## P1.06 storage/export work package — 2026-09-12

Starting commit: `dd0d0843ccc912fb5fa0cdd8e036979e7d9f6262`, whose complete CI
passed in [run 34718720639](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34718720639).
Branch: `codex/p1-storage-foundations`, stacked on draft PR #8.

Initial checks: 123 backend tests passed in 80.52 s, including real MP4 retries;
frontend checks passed. The new browser storage/retry/reopen workflow passed
(19.2 s test, 25.6 s with setup) after correcting its initial accessible-button
selector. The old isolated job fake was given an explicit fake validator; a separate
test proves the real validator rejects those non-MP4 bytes. No assertion gate or
render timeout was disabled. The full local run passed: 125 backend tests (78.03 s), 91 frontend tests, 12 repository tests and 12 browser tests (3.6 min), plus all lint/type/build/format checks.

A focused real export evidence run passed in 5.17 s: H.264, no audio, 320×180,
4.0 seconds, 6,448 bytes. At 0.9/1.0/1.9/2.0 seconds, red pixels matched the
original `[1,2)` cue after restart and removal of that cue from current edits.
The source SHA-256 stayed
`89441d06c652971cfba6065c85cb59999b2bea81f812977be4b0d91ab57cb9d5`.

Native tests add the shared 16-case input corpus, revision retry after restart,
retained recording references, cancellation, lease/space/path guards, and real
H.264/AAC retry with timed pixels and audio energy. `npm run ios:sync` passed.
The first native CI run compiled successfully and passed the real native retry export (H.264/AAC, 320×180, 4 s, 26,570 bytes), but one recording-journal assertion failed: a just-recovered take could reappear after removal. The assertion is retained; native save now journals the document and recording acknowledgments as one recoverable transaction. A write-failure replay test was added. The fix passed fresh CI at `04b03a8cac59ae6266b32117ed2a7b797a4f6636`: [run 34725049253](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34725049253), all six gates including 18 native tests (195.008 s) and the unsigned archive. Its real native retry was H.264/AAC, 320×180, 4 s, 26,558 bytes, source SHA-256 `a4b27a39adf8ddca0e036080f1af375295c28819275d5fc38afca143d9e08555`.
Physical signed install/update, interrupted recording, low-space/share-sheet
behavior, thermal/memory/20-minute performance and Windows 11/Docker acceptance
remain open. Checkpoints and trash are the next separately verified work package;
no HDR or package transfer is claimed by this storage/export slice.


## P1.02 / P1.03 first vertical package — 2026-09-12

Starting commit: `f5323b3b270e3836d7df10309d1684cf8d98e9ca` (live main checked
through GitHub and git). Local branch: `codex/p1-save-recovery`. Implementation
commits: `6c77e2f` and `2fdb591`; the latter fixes an edit arriving during journal cleanup.
The final verification addendum below identifies the tested candidate commit.

**Native baseline correction:** [CI run 34532184666](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34532184666)
passed at `f5323b3b`, including 11 native XCTest cases and an unsigned archive.
Older local-only records below describe earlier dates; their statements that Apple
SDK tests had never run are superseded by that successful CI evidence. They do
not establish signed installation, a physical phone result, or this candidate.

Local baseline was rerun: 74 backend tests (71.01 s), 60 frontend tests, 11 repository
tests, and all 9 real browser scenarios (2.9 min). Python 3.12.14, Node 24.19.0,
FFmpeg/FFprobe and Playwright 1.63.0 were used on Linux. The existing pinned
Ruff 0.16.6 and dependency installations were reused without upgrades. Playwright's
standard Chromium download was unavailable; a locally installed Chromium 149 was
selected through the existing BJJ_E2E_CHROMIUM_PATH option.

The baseline verification script exposed working-directory-dependent Ruff import
classification: root CI passed while the backend-directory invocation failed.
Explicit first-party imports now make both invocations agree (no gate disabled;
see [Ruff's setting](https://docs.astral.sh/ruff/settings/#lint_isort_known-first-party)).
The first new browser-test import was corrected to the repository's existing
Playwright module path. A subsequent run overlapped a source refresh and its mobile
case was invalidated; the clean final run, not that partial run, is authoritative.
Recovery failure injection keeps writes blocked through the lifecycle flush so it
tests a genuinely uncommitted draft; reconnecting before reload had correctly
allowed the real service to save it.

Automated implementation evidence: 100 backend tests passed, including
real FFmpeg exports; 90 frontend tests passed; 12 repository tests passed. Strict
TypeScript, ESLint, Ruff, build and formatting passed. Shared TypeScript/Python/
Swift fixtures include 22 validation cases and an exact expected migration.
The native suite now contains 15 authored test methods, including revision
conflicts, retained original JSON, recovery copies/journals and fixture conformance.
Its runner was invoked locally and truthfully refused because macOS/Xcode are absent. Fresh macOS CI subsequently compiled the candidate, passed all 15 tests and produced the unsigned archive, as recorded below.

**Publication update:** Steve explicitly authorized publishing the branch and
opening a draft PR on September 12. [Draft PR #8](https://github.com/BakedChicken77/bjj-telestrator/pull/8) is open and
[CI run 34718055711](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34718055711) passed all six jobs, including the aggregate gate. Command-line Git had no credentials;
the connected GitHub account published the same four file trees and commit
sequence. Each GitHub commit records its original local commit in a trailer.
The published head is `06ca668eeadce6ce383d98c4c107e3998bd1434a`; its tree is
`f7b679210a80b0d2cba28625667f68083ec020f8`, exactly matching local `5919039`.
The earlier automatic approval rejection is resolved. No merge, release tag,
signing, TestFlight upload, paid service or customer charge was performed.

Exact remaining acceptance: signed install over
populated projects; physical iPhone recovery/export/share/VoiceOver; Windows 11/
Docker on this candidate; realistic 20-minute and lower-resource-device results.
Native recovery-copy responsiveness on large projects remains unmeasured. Source
media and pre-migration documents are retained; no Phase 1 exit gate is claimed.


## Final local verification addendum — 2026-09-12

The complete unchanged-production-code gate passed at
`2fdb591679a99e79373313c7a4d9562553144fbb`. Follow-up
`349567c730c74b46da46a7545a917cab5d3f988a` extends the existing real export tests
with version-1 disk migration, an edit, revision-aware save/export and reopen;
it changes tests only. The enhanced FFmpeg scenario passed separately. The
native counterpart passed in fresh macOS CI. Later report-only commits do not
change the tested application. Full file inventory and structured evidence are in
[p1-save-recovery-verification.json](p1-save-recovery-verification.json).

| Gate | Result |
| --- | --- |
| `backend/.venv/bin/python scripts/verify.py --browser` with existing Chromium selected | Passed, exit 0; all requested gates passed. |
| Backend / real FFmpeg | 100 passed, 74.19 seconds. |
| Frontend | 90 passed in 10 files. |
| Repository | 12 passed. |
| Browser | 11 passed, 3.4 minutes; real editing, recording, exports, conflict/copy, failed save/reload, diagnostics and touch flows. |
| Ruff / ESLint / TypeScript / build / Prettier | Passed using the repository configuration. |
| Enhanced migration-to-real-export test at `349567c` | 1 passed, 4.33 seconds; existing timed pixels/audio assertions retained. |
| `npm run ios:sync` at `349567c` | Passed; rebuilt and copied the editor and updated Capacitor plugin configuration. This does not compile Swift. |
| Candidate native SDK / 15 XCTest methods / unsigned archive | Passed in [CI run 34718055711](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34718055711); all 15 tests, zero failures, and unsigned archive. |
| Signed phone / fresh Windows Docker / VoiceOver / 20-minute workload | Not run; explicit acceptance gates remain pending. |

### Fresh GitHub CI and native evidence

[CI run 34718055711](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34718055711) passed for published application head
`06ca668eeadce6ce383d98c4c107e3998bd1434a` (the same tree as locally verified `5919039`).
Backend: 100 tests in 18.95 seconds. Frontend: 90 tests. Repository: 12 tests,
plus actionlint. Browser: 11 scenarios in 1.3 minutes. Production Docker build,
startup, frontend, storage and FFmpeg health all passed on Ubuntu; this is not a
Windows 11 execution claim. The aggregate CI gate passed.

Xcode 26.6 on the iPhone 17 Pro **simulator** compiled the actual native target.
All 15 XCTest methods passed with zero failures in 46.367 seconds of test time;
build, simulator startup and artifact packaging took additional time. The real
native MP4 migration/edit/export/reopen scenario passed in 36.550 seconds. It
asserted H.264 (`avc1`), AAC, 320×180, 4 seconds within 100 ms, annotation pixels
before/at/after `[1,2)`, original-audio energy, and equality of pre/post source
SHA-256. Recovery, stale revisions, the 22 canonical fixture cases, rotated silent
video, voiceover timing/mute and queued cancellation also passed. Numeric native
file size/source digest were not emitted in this run; no invented values are
reported. This test evidence does not establish physical-phone timing or thermals.

`ARCHIVE SUCCEEDED` was recorded and the following bounded artifacts were uploaded
(retention through September 26, 2026):

| Artifact | ID | ZIP bytes |
| --- | --- | --- |
| ios-unsigned | 10306075698 | 12492259 |
| ios-test-results | 10305361516 | 65675900 |
| browser-results | 10305097614 | 1440970 |

The unsigned archive cannot be installed directly on a phone. No signed IPA,
TestFlight upload, merge or release was produced. Documentation updates after
this application head preserve its application code; PR checks identify their own
run and commit separately.

All four measured outputs below are real finalized MP4s from the clean browser
run, with H.264/yuv420p at 30 fps and AAC/48 kHz where audio exists. Sources were
synthetic. Sizes are observed results, not estimates or quality guarantees.

| Source fixture | Saved revision | Output dimensions | Duration | Bytes | Audio |
| --- | --- | --- | --- | --- | --- |
| acceptance.mp4 | 8 | 640×360 | 20.000 s | 428060 | AAC |
| portrait.mp4 | 2 | 360×640 | 4.000 s | 88885 | AAC |
| rotated.mov | 2 | 360×640 | 4.000 s | 88480 | AAC |
| silent.mp4 | 2 | 640×360 | 4.000 s | 8069 | None |

The 20-second scenario confirmed arrow `[5,10)` and circle `[7,9)` before and
after undo/redo and reopening; decoded output samples checked visibility at
4.9, 5, 7.5, 9.5 and 10 seconds. Its preserved source SHA-256 is
`4482a5a94aeab9b50e982b97a3029b31fcb7d70bf1c505d4c6ec662e7f3c598d`.
The structured record contains hashes for the portrait, rotation and silent
fixtures. The browser narration test additionally verified real microphone
capture, clip persistence and audible tone placement in AAC. Recovery copies
were checked independently for new IDs, unchanged source hashes, independent
edits and an intact original project.

No source media, recordings, generated movies, credentials or test traces were added to the
commits. The pre-existing large-bundle and upstream test-client deprecation
advisories remain; no assertion, meaningful gate or timeout was removed or widened.
Rollback retains the full newer project and uses the untouched pre-migration JSON
in a separate older-version copy. An older binary cannot read schema 2; do not
uninstall the iPhone app or overwrite newer work to simulate a downgrade.

## Version 1.1 iPhone conversion — 2026-09-10

The user reports successful Windows 11/Docker Desktop operation of the original desktop app. The following checks were performed for the iPhone source conversion. This is **not** a signed or device-verified iOS release.

| Check | Measured result |
| --- | --- |
| Desktop backend regression suite | 74 Pytest tests passed, including actual FFmpeg annotation/audio exports; 87.50 seconds. |
| Shared frontend unit suite | 60 tests passed in 8 files, including 8 native bridge contract tests and Web Crypto UUID fallback for custom WebView schemes. |
| TypeScript, ESLint, Ruff, Prettier | Passed. |
| Vite production build / Capacitor sync | Passed; bundled frontend copied into the Xcode app. |
| Complete browser suite | 9 scenarios passed in 3.2 minutes: the 7 desktop/voiceover regressions and 2 real Chromium touch workflows. |
| Final phone-layout rerun | 2 scenarios passed after the final touch-header/UUID changes. |
| Native source inspection | 11 Swift files syntax-parsed without errors; OpenStep project parsed (65 objects); native source membership, plists, privacy manifest, and shared AppTests scheme checked. |
| Apple SDK compilation | **Not run:** this environment is Linux, with no Xcode or Apple SDK. Syntax inspection does not establish SDK type compatibility. |
| Native XCTest integration suite | 9 tests authored, **not run**; includes actual AVFoundation-generated media, MP4 rendering/pixels/audio, source preservation, rotation, journal recovery, validation, byte ranges, and queued cancellation. |
| iPhone signing, installation, hardware acceptance | **Not run.** No signed IPA or TestFlight build was produced. |

The touch suite uses 393×852 and 375×667 portrait layouts and an 852×393 landscape layout. It sends actual touch/pointer input, including multiple fingers, through Chromium; draws an arrow/ellipse, changes duration, trims an edge, verifies one-command undo/redo, reloads a saved project, and downloads a real H.264 MP4. It verifies portrait picture containment, stable normalized geometry after viewport rotation, and no page-wide horizontal overflow. `iphone-layout.png` is a screenshot from this browser run, not a physical iPhone screenshot.

The full desktop acceptance export again confirmed H.264/AAC, dimensions/duration, burned annotation pixels at the correct half-open intervals, and an unchanged original SHA-256. The voiceover scenario again used actual MediaRecorder/Web Audio and verified the exported tone's temporal position. These exports used the existing **FFmpeg backend**. They must not be cited as proof that the new **native AVFoundation renderer** has run.

The native test runner was invoked on Linux and correctly refused with `Native iOS tests require macOS and Xcode. No native tests were run on this host.` Follow IOS_README.md on a Mac to obtain a real `.xcresult`, then complete physical-device acceptance. The machine-readable companion is `ios-verification.json`.

## Original desktop delivery record

Validation performed in a Linux x86-64 development environment using Python 3.12.13, Node 24.19.0, npm 11.9.0, native FFmpeg 6.1.1, and Playwright 1.63.0 with real headless Chromium 149.0.7827.0. No application behavior or export output was mocked in the integration/browser acceptance flows.

## Milestone 1 gate — passed before voiceover development

| Check | Result |
| --- | --- |
| Backend Pytest | 50 passed: 27 backend/API tests and 23 renderer tests. |
| Frontend Vitest | 30 passed: schemas, visibility, geometry, timeline math and grouped history. |
| TypeScript / ESLint / Ruff | Passed. |
| Frontend production build | Passed. |
| Real browser scenarios | All 5 passed. |
| Production HTTP smoke | FastAPI served compiled HTML, JavaScript and bundled font; FFmpeg/FFprobe health true. |

The browser scenarios cover:

1. The 20-second manual acceptance sequence: arrow `[5,10)`, yellow ellipse `[7,9)`, visibility checks at 4.9/5/7.5/9.5/10 seconds, arrow move and endpoint resize, undo/redo, changed circle duration, autosave, browser reload and real export download.
2. Line, box, freehand and text creation, actual timeline bar shifting and edge trimming, grouped undo/redo, and layout at 1280×720.
3. Portrait input, normalized overlay rectangle, H.264 proxy and portrait export.
4. MOV with actual 90-degree display-matrix metadata, oriented proxy and export.
5. A source without audio, annotations and a valid silent MP4 export.

Downloaded output was inspected with FFprobe and decoded pixel samples. Checks confirmed MP4/H.264, AAC where expected, dimensions, duration, red/yellow pixels during their expected intervals, absent pixels outside those intervals, and unchanged source SHA-256. Renderer tests also verify antialiasing/alpha, all six annotation types, 100 annotation transitions, fractional boundaries, rotated anamorphic geometry, a delayed original-audio start, and cancellation of a real running encoder.

The fixture generator probes its rotation output and falls back to FFmpeg's display-matrix override when legacy rotation tags are ignored. This ensures the rotation case actually contains rotation metadata.

## 1080p smoke measurement

`performance-smoke.json` records a five-second 1920×1080 H.264/AAC source exported with 100 simultaneously visible annotations, the medium encoding preset, and two encoder threads. The export completed in 7.48 seconds in this environment and retained 1920×1080 dimensions and 5.0-second duration. The source uses a simple synthetic background; this is a full-resolution functional/memory smoke test, **not** a speed prediction for complex rolling footage. A full 20-minute 1080p workload was not benchmarked.

## Milestone 2 and final quality checks

| Check | Result |
| --- | --- |
| Complete backend suite | 74 passed, including all Milestone 1 regressions. |
| Complete frontend suite | 51 passed in 7 test files. |
| Ruff, ESLint, strict TypeScript, Prettier | Passed. |
| Production Vite build | Passed; 656.99 kB JavaScript, 197.83 kB gzip. |
| Cross-platform verification script | Executed successfully through every non-browser gate. |
| Native browser voiceover workflow | Passed with Chromium's actual synthetic microphone device; no capture/recorder/upload substitutions. |
| Final browser acceptance | All 7 scenarios passed: five M1 regression scenarios and two final voiceover/permission scenarios. |

Voiceover tests use real WebM/Opus input and encoded AAC outputs. They check 48 kHz mono WAV normalization, duration clipping, immediate range-capable audio access before project autosave, restart persistence, undo-safe removal, immutable asset validation, invalid uploads, and permanent deletion protection during exports. Spectral/RMS checks verify 880/1320 Hz clip placement, overlaps, gains and master gain, a 125 ms nudge, original 440 Hz gain/mute, voice-only exports, silent cases and output duration.

The browser workflow uses `getUserMedia`, `MediaRecorder`, actual asset uploads and native `AudioBufferSourceNode` scheduling. It records three takes, exercises deletion/undo/redo and rerecording, retains two clips, edits timing/gain/mute, reloads the project, checks seeking into a narration clip and stopping on pause, and exports a real MP4. The final audio contains the 880 Hz microphone tone only at the intended times with the source 440 Hz tone muted. Microphone start and preview scheduling tolerance is 100 ms, matching the requested behavior; actual recorded clip timestamps are authoritative.

The final browser gate combines the five M1 regression scenarios with the two targeted voiceover scenarios rerun after the microphone-permission fix. Native permission denial produces a useful message and restores editor controls. The last two scenarios completed in 49 seconds. Browser setup also successfully generated all four missing video fixtures without manual preparation.

The preview unit suite additionally verifies scheduling at half-open boundaries, overlaps, gain changes, pause/resume, buffering, context lifecycle and project replacement, bounded prefetch/eviction, and failed decoding without breaking original audio.

## Reproduce

Install dependencies as described in the README and install the Playwright Chromium browser. Then run from the repository root with the backend virtualenv's Python:

```powershell
.\backend\.venv\Scripts\python.exe scripts/verify.py --browser
```

The script generates fixtures and runs backend tests, Ruff, frontend tests, ESLint, TypeScript, production build, formatting and Playwright. Use `BJJ_E2E_API_PORT` / `BJJ_E2E_WEB_PORT` to change test ports. An optional `BJJ_E2E_CHROMIUM_PATH` selects an existing compatible Chromium executable. Normal Windows development should use Playwright's standard installed Chromium.

## Environmental limits

- At the original delivery, Docker Desktop and a Windows 11 host were unavailable in the implementation environment. On 2026-09-10 the user reported successful Windows 11/Docker Desktop operation. This is user-reported acceptance, not an automated Windows run in this environment.
- Headless Chromium exercised browser functionality. The Windows report does not specify a browser version or separate physical microphone/speaker measurements. Native iPhone hardware remains untested.
- Long-form 20-minute real footage, HDR-to-SDR color conversion, unusual non-right-angle rotation, and device-specific variable-rate camera files were not exhaustively tested. Non-right-angle rotations are explicitly rejected.
- Upstream Starlette's test client emits deprecation warnings for its current HTTPX/AnyIO compatibility APIs; tests pass. Vite reports the editor bundle exceeds its generic 500 KB advisory threshold; the production build passes.

The pinned base tags were checked against the official [Node image](https://hub.docker.com/layers/library/node/24.19.0-bookworm-slim/images/sha256-33d3c9370f604454931ddbae819aed9d85d3e6e7ebace2e4bbd352bad515cd30) and [Python image](https://hub.docker.com/layers/library/python/3.12.13-slim-bookworm/images/sha256-5460fd0a2ec4f0df02e5846778236134f2e24d2bce9f95bc97b1d88dd9a0b556) listings. This verifies availability, not a Docker build or a Windows launch.

## GitHub automation delivery — 2026-09-10

Re-ran the actual application gates after adding repository automation:

- Backend: **74 passed**, including FFmpeg pixel/timing, audio mix, orientation, source-integrity and MP4 export tests (72.55 seconds).
- Frontend: **60 passed** in eight files. ESLint, strict TypeScript, Vite production build and Prettier passed. Vite reports the existing large-bundle advisory; it is not a build failure.
- Repository automation: **11 passed**. Covers version/lock consistency, unsafe/private paths, deterministic ZIP/checksums, symlink rejection, Apple profile validation, App-only signing patches, wrong-account refusal, nested-repository refusal, and missing CLI behavior.
- Ruff on backend, scripts and repository tests passed. Both workflows passed actionlint 1.7.12; its downloaded executable was verified against the published SHA256.
- The nine browser scenarios retain the passing evidence above; application/editor behavior was unchanged by this repository-only work.
- Native SDK, Docker-in-this-host, signing and TestFlight are **not executed** here: this host has neither Xcode nor Docker. The user-reported Windows Docker result remains valid.
- GitHub repository creation, push, settings and Actions execution are **not completed** here. The connected GitHub tools lack creation/admin capabilities and no authenticated CLI is present. `scripts/setup_github.py` performs the remaining setup from Windows.

Do not interpret static workflow validation or mocked bootstrap boundary tests as proof of a successful GitHub API operation or native iOS build. First-run native failures must be fixed before publication; the release workflow enforces that gate.

Release packaging smoke test passed: 145 tracked source files were archived, required workflow/native/setup files were present, ZIP integrity checks passed, the compiled web package was produced, and SHA256 files were generated. Generated iOS public assets remain outside Git and are recreated by `npm run ios:sync`; the downloadable working-source archive also retains them for continuity.


### Isolated local browser data

For a synced/virtual checkout, run the existing browser gate with a local temporary
data root: `BJJ_E2E_DATA_DIR=/tmp/bjj-recovery-tests BJJ_E2E_CHROMIUM_PATH=<existing compatible Chromium> backend/.venv/bin/python scripts/verify.py --browser`.
Use a task-specific generated directory; never point this test setting at real
projects. On Windows, set `BJJ_E2E_DATA_DIR` to a generated test directory on local
storage if needed. This changes fixture placement, not test assertions or product
storage behavior. Keep live projects in the documented application container or
Docker volume, not a concurrently synchronized working tree.


### Native recovery export evidence

CI run 34726637336 exported and retried a real four-second H.264 (`avc1`)/AAC,
320×180 MP4 after checkpoint restoration and whole-project deletion/restore.
The retained revision's rectangle appeared at 1 s and was absent at 2 s; decoded
audio energy passed. Retry output: 26,570 bytes. The original source SHA-256 stayed
`6d4b3d63ff338abd82642b25c4624d1ed723b7883433b7e370c7d6050093c1f7`.
The preserved pre-migration document also matched exactly. This is simulator SDK
and encoded-file evidence, not a signed phone installation or listening acceptance.


### Final local regression — 2026-09-13

Application commit `3f3b286444e37d68f6628d3e0edcf41a215c8e4e` passed the full
`verify.py --browser` gate using isolated local temporary test storage: **139
backend tests (76.38 s), 92 frontend tests, 12 repository tests, 14 browser scenarios
(4.2 min)**, Ruff, ESLint, strict TypeScript, production build and Prettier. Native
sync also passed. No test assertions or timeouts were weakened. The final shared
immutable-input corpus has 17 cases.

A focused FFmpeg evidence run passed in 4.99 s: silent H.264, 320×180, 4.0 seconds,
6,448 bytes; red visibility at 0.9/1.0/1.9/2.0 seconds was false/true/true/false.
Source SHA-256 stayed `89441d06c652971cfba6065c85cb59999b2bea81f812977be4b0d91ab57cb9d5`.
The actual restored-review browser exports and native recovery/retry render are
separate end-to-end evidence. CI for this final application commit is [run
34727251987](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34727251987);
all six gates passed, including 22 native tests (31.480 s), the unsigned archive,
real FFmpeg/browser exports and the Ubuntu Docker build/startup.


### Copy fidelity regression — 2026-09-13

The duplicate regression reproduced a text annotation changing when its literal
text equaled the original annotation UUID. Both Python and Swift now preserve
literal text/name/filename fields while remapping object IDs and references. The
existing copy tests retain their independence/hash assertions and additionally
check exact geometry/text, unchanged media metadata and remapped optional references.
The Python regression failed before the fix; the focused recovery/export suite
then passed **39 tests in 5.84 s**, with Ruff and diff checks passing. No UI or
renderer changed. Application commit `33be6315eb4fdee79ac7fe5d973292bfc09b182f`
passed every CI gate in [run 34727786132](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34727786132): **139 backend (20.61 s), 92 frontend, 12 repository, 14 browser (1.8 min), 22 native (54.894 s)**, lint/type/build/format, Docker and the unsigned archive. The expanded native copy regression passed in 0.141 s.

The final native recovery/retry export was H.264 (`avc1`)/AAC, 320×180, 4 seconds,
26,570 bytes. Source SHA-256 remained
`912a9244dfbf0023c1696c2d368fe87a584e4980e1340c5bc720074eea501f1e`;
retained-revision cue boundaries, decoded audio and pre-migration bytes all passed.
The new browser recovery workflows passed at desktop/phone sizes in 6.7/6.4 s.

This is the automatically verified application commit; the accompanying completion
record is a documentation-only follow-up. Signed installation/update, a fresh
Windows 11 host run, VoiceOver and realistic device workloads remain pending.
See [the complete task record](p1-project-recovery-verification.json).
