# Verification record

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
