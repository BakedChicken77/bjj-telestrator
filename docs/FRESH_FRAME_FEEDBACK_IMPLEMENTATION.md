# Fresh Frame TestFlight feedback implementation

Implementation branch: `feature/testflight-feedback-update`, draft PR #37. Baseline: `d661fa683021a8df5f5bd9b212ab1f6ce55d1b9e`. This change has not been merged or released. The original feedback package and detailed implementation plan remain the acceptance sources; the feedback IDs below refer to that package.

## Changes and completion gates

| Feedback | Implemented change | Required evidence before release |
|---|---|---|
| F1 | Pause/Resume video while microphone capture continues; project-owned holds; output-time preview/range export; source-time cues; compound recording recovery | Native media tests plus physical iPhone recording, frame identity and marker alignment checks |
| F2 | Empty editor-style launch, existing artwork, Select a video menu, Previous reviews, successful import opens editor | Native UI tests; Photos/Files cancellation, library re-entry and accessibility on iPhone |
| F3, F9 | Inspector uses less space; collapse/expand enlarges video without ending the draft | Portrait/landscape screenshots and Dynamic Type on iPhone |
| F4 | Inspector and canvas share one draft; selected cue body drag remains available | All six tools, zoom, rotation and interrupted gestures on iPhone |
| F6 | Exact redundant Properties and ellipsis controls removed; drawing tools retained; layer actions moved into properties | Screenshot comparison with F6 and layer overlap tests |
| F7 | Delete inside cue properties, one transaction; undo restores persisted pre-edit cue | Native transaction and UI deletion tests |
| F8 | Existing Start/End controls retained with source-time meaning | Existing range/cancellation tests; short cues and end boundaries on iPhone |
| F5 | Import stage telemetry, accurate provider/copy status, bounded cancellation settlement | Controlled >5-minute before/after measurements; no performance improvement claimed yet |
| F10, F11 | Existing native Done and recording lifecycle preserved; timer keeps meters/stall checks alive during deliberate pauses | Actual microphone permission, route, interruption and dismissal checks |

All drawing, saved reviews, narration, backups, preview and MP4 export remain free. Tip $5 and Custom tip behavior is unchanged and does not gate editing or export.

## Editing contract

`BJJNativeEditorSession` owns the inspector's raw draft, valid render preview, starting revision, staged layer order and active gesture snapshot. Properties and canvas operate on this draft. A completed inspector drag does not save. Cancel drops the whole draft. A cancelled gesture/rotation reverts only that gesture. Collapse/expand does not save or cancel. Save validates and commits once; a no-op Save writes no revision or undo entry. Validation/storage/conflict errors retain the draft. Delete ignores unsaved draft changes and removes the persisted cue in one commit; Undo restores its prior saved content and order. A standalone canvas drag remains one immediate undoable edit. Other-cue selection, recording/export and history are unavailable while the inspector is open. Backgrounding stops recording and active gestures without implicitly committing a cue.

## Narration clocks and compatibility

Source duration and annotation start/end times keep their original meaning. `BJJReviewTimeline` derives half-open play/freeze spans and output duration. Holds use stable UUIDs, ordered source boundaries and duration ticks at 48 kHz, plus an acknowledged frozen source PTS. Same-boundary holds retain array order. `output(before:)` and `output(after:)` distinguish the two sides of a hold. Ten source seconds plus a five-second hold yield fifteen output seconds.

Existing `voiceovers` remain source-anchored and split around holds with silence during each hold. New pause-aware `reviewNarration` stores immutable sample count/asset metadata and audio slices anchored to source time or a hold ID. Microphone audio inside holds remains continuous. Original video audio is silent during holds. Muting/deleting a take preserves project-owned holds; Narration Pauses provides explicit removal. Removing a hold removes its associated audio slices, preserves assets, and remains undoable. Nudge remaps placements by 50 ms and rejects an out-of-range result.

The additive capability `review.pause-narration.v1` makes older Windows/web consumers reject affected projects safely. Merely opening an old review adds no pause fields. Existing render plans v1/v2 retain their previous meaning; pause-aware exports use v3 with explicit output range clock and timeline/audio policies. Duplicate, recovery copy, asset manifest, portable package restore and checkpoint handling include new takes and hold IDs. Compound recording receipts publish holds and narration through the existing atomic save journal. Revision conflicts preserve the original and open an independently named recovery copy with an idempotent operation ID.

Preview and export use the same span mapping and audio builder. A hold inserts/scales exactly one decoded video sample, rather than stretching a multi-frame interval. This must pass frame-identity checks on VFR, rotated and HDR sources before release. A Timer independent of AVPlayer maintains microphone metering and drift checks during deliberate pauses. Seeking, speed, looping and drawing stay disabled during capture. The one-hour per-take limit, 24-hour output limit, storage checks and interruption stops bound resource use. Creating another hold while traversing an existing hold is rejected; narration can continue through it.

Export resolves the original frame at its acknowledged PTS and explicitly samples the composition's output clock on the requested frame grid, retaining at most two decoded pictures. AVFoundation may return a single long-duration picture for a scaled hold; the export scheduler repeats it without relying on reader frame count. The CFR proxy repeats its picture covering the corresponding source instant, since a downsampled proxy may not contain every original VFR timestamp. Ordinary exports retain their existing path. Ordinary source-end takes trim delayed extra capture samples before registration so WAV duration and portable-backup metadata agree; pause-aware takes retain all captured samples.

## Import measurements (F5)

Previous reviews → Share import timing report exports a redacted JSON report for analysis on Windows. Persisted `media-jobs/*.json` diagnostics now include source SHA-256/codec/dimensions/fps/HDR/duration and monotonic stage timings. No user filename, source path or Photos identifier is included in the diagnostic profile. `provider_wait`, `copy`, `provider_and_copy`, `source_hash_before`, `inspect`, `proxy_encode`, `proxy_validation`, `source_hash_after`, `publish`, `prepare_total`, `editor_open`, and the initial `audio_preview` distinguish cloud/provider latency, local I/O, verification and encoding. Failed/cancelled jobs retain available stage timings. The pipeline still protects the original and verifies the proxy; no unmeasured proxy-quality or hashing shortcut was introduced.

Measure the baseline and branch on the same physical iPhone, OS, battery/thermal conditions, free storage, media and connectivity. Use at least three repeats for each combination: local Photos, iCloud Photos, local Files and iCloud Files; 1-, 6- and 15-minute sources; H.264/HEVC, portrait/landscape, SDR/HDR and representative VFR. Record total time until the editor is ready (including its audio preview preparation), provider/copy/encode timings, source bytes, peak memory, main-thread stalls, cancellation latency, source hash and proxy properties. Separate warm/cold cache and cloud download cases. Compare medians and spread. Identify the dominant measured stage before choosing an optimization; rerun the same matrix afterward. Do not call F5 complete until a measured improvement meets the plan's target without a media-quality or cancellation regression.

## Automated verification

Run the existing full CI workflow on this branch. The macOS job performs `npm ci && npm run ios:sync`, real simulator tests through `scripts/test_ios.py`, and the native archive gate. Linux cannot compile SwiftUI/AVFoundation or emulate a microphone. The existing frontend/backend/browser/Docker/ownership gates remain required. New native tests cover the shared draft transaction, failed/stale Save retention, Delete/Undo, timeline boundaries and compatibility, compound take recovery, preview audio and extended MP4 duration. Existing cue timing, export retry, asset safety, narration and StoreKit tests remain enabled.

No simulator result proves microphone hardware, cloud-provider latency, touch ergonomics or thermals. Record exact commit/build, iPhone model/OS, videos, screenshots, MP4 inspection and results in the acceptance record. Do not publish while a gate fails.

## Physical iPhone acceptance checklist

1. Install an update over an existing saved library. Open legacy/native reviews, verify cues and takes, duplicate, back up/restore, rename, trash/restore, preview and export. Compare untouched source hashes.
2. Launch empty editor, use Select a video from Photos/Files, cancel each picker and import stage, select another video afterward, and reopen Previous reviews. Test iCloud and local sources.
3. For every drawing tool, change appearance/timing, drag its body with properties open, collapse, rotate, expand, Cancel, then repeat with Save. Test invalid values and stale saves. Stage layer changes; verify overlap preview and persisted order. Delete and Undo. Keep drawing tools reachable after F6 control removal.
4. Test one-frame/short cues and Start/End boundaries on portrait and landscape; confirm dragging handles seeks visibly, and Cancel preserves timing.
5. Record a 10-second source with a measured 5-second pause. Speak/click markers before, during and after it. Verify live meter remains active, output is 15 seconds within one frame, held frames are identical, no black/slow-motion span appears, and audio markers match within 50 ms. Repeat multiple holds, stop while paused, rerecord through an existing hold, mute/delete take, remove hold and Undo, reopen, back up/restore, and export a range wholly inside a hold.
6. Repeat narration with wired/headphone/speaker/Bluetooth routes, denied/changed permission, interruptions, lock/background, storage pressure, actual playback stall and rapid Pause/Resume/Stop. Confirm valid audio is preserved and no late permission callback starts capture.
7. Export SDR/HDR, VFR, rotated/nonzero-start sources with and without narration and holds. Inspect codec, dimensions, color, duration, cue edges and audio. Cancel/retry immutable exports and verify source/recording files are unchanged.
8. Validate Narration Done and all sheet dismissal/rotation paths, VoiceOver, larger text and smaller iPhone safe areas. Tips stay optional and do not appear during editing/export.

## Remaining release gates

Physical iPhone validation, controlled import benchmarks and exact final-commit CI evidence must be collected. Import optimization depends on those measurements. No merge, tag, build publication or App Store Connect change is part of this implementation branch.
