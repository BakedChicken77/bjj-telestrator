# Project format — schema version 1

`project.json` is UTF-8 JSON. The backend validates it with `backend/app/models.py`; the browser validates it with Zod in `frontend/src/model.ts`. `docs/project.schema.json` is generated from Pydantic, and `docs/example-project.json` is a complete illustrative document (its relative media assets are not bundled).

## Document fields

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `1`. Unsupported versions fail explicitly. |
| `projectId` | Canonical UUID, also the project directory identifier. |
| `projectName` | Editable display/export name. |
| `createdAt`, `updatedAt` | ISO-8601 timestamps. |
| `source` | Immutable original-media metadata and project-relative asset reference. |
| `proxy` | Immutable browser editing-media metadata and relative asset reference. |
| `settings` | Default annotation duration, keyboard seek steps and audio controls. |
| `exportSettings` | Output frame rate, H.264 CRF and CPU encoding preset. |
| `annotations` | Discriminated union of timed visual objects. |
| `voiceovers` | Timed normalized audio assets. Empty for projects without narration. |

Media metadata includes `asset`, `originalFilename`, `durationSec`, `codec`, `audioCodec`, `hasAudio`, `codedWidth`, `codedHeight`, `displayWidth`, `displayHeight`, `sampleAspectRatio`, `displayAspectRatio`, `rotation` and `avgFrameRate`. Additional source timing fields may preserve original stream timing. `codedWidth`/`codedHeight` describe encoded raster pixels; display dimensions incorporate sample aspect ratio and orientation. The proxy has orientation baked in and square pixels.

Only project-relative paths such as `source/<uuid>.mov` or `proxy/<uuid>.mp4` are valid asset references. Absolute paths, traversal components, Windows drive prefixes, backslashes and NUL bytes are rejected. The backend verifies filesystem containment and asset existence. Clients cannot substitute source/proxy metadata during edits.

## Annotation base fields

Every annotation contains `id`, `type`, `startSec`, `endSec`, `zIndex`, `strokeColor`, `strokeWidth`, `strokeOpacity`, `fillColor`, `fillOpacity`, `geometry`, `createdAt` and `updatedAt`.

- IDs are unique canonical UUIDs across annotations and voiceover clips.
- All numeric values must be finite.
- Colors use six-digit RGB hex, for example `#ff3333`. Opacity is separate, in `[0,1]`.
- Stroke width is a positive normalized fraction, at most `0.1` of the smaller display dimension.
- `zIndex` increases toward the viewer. Equal-layer objects retain deterministic array order.
- `fillOpacity: 0` means transparent fill; fill is meaningful for rectangle/ellipse objects.

## Geometry and normalization

All positions use the **display-oriented video picture**, not the player container or its black padding. Horizontal and vertical coordinates are normalized to `[0,1]` independently. Shapes are clipped to this picture. Width/height are fractions of their respective picture dimension; stroke width, arrowhead size and font size are fractions of the smaller picture dimension.

| `type` | `geometry` fields |
| --- | --- |
| `line` | `x1`, `y1`, `x2`, `y2` |
| `arrow` | Line endpoints plus `arrowheadSize` |
| `rectangle` | `x`, `y`, `width`, `height` |
| `ellipse` | `centerX`, `centerY`, `radiusX`, `radiusY` |
| `freehand` | Ordered `points: [{x,y},…]`, `smoothing: 0` |
| `text` | `x`, `y`, `text`, `fontSize`, `alignment`, `backgroundColor`, `backgroundOpacity` |

Rectangle and ellipse extents must fit inside the picture. Text's `(x,y)` is its left/center/right horizontal anchor (per alignment) and top edge; text outside the picture is clipped. The bundled DejaVu Sans font is used for both canvas and final rasterization. Freehand currently uses sampled straight segments with round joins; smoothing is reserved at `0` so export and preview match.

Example: an arrow from `(0.25,0.5)` to `(0.75,0.5)` spans the middle half of the image horizontally. `strokeWidth: 0.006` becomes 6.48 pixels on a 1920×1080 export regardless of its preview size.

## Temporal semantics

Times are seconds relative to the video media timeline. An annotation is visible iff:

```text
startSec <= currentMediaTime < endSec
```

The end is exclusive. For `[84,89)`, the object is hidden at 83.999, visible at 84 and 88.999, and hidden at 89. Validation enforces `0 <= startSec < endSec <= source.durationSec`.

Creation uses the current playhead and the configurable default duration (initially five seconds), clamped to the source duration. At the absolute end, creation is placed just before the end to keep a positive interval. All edits preserve valid intervals. Constant-frame-rate exports activate at the first frame whose media time is at or after a start boundary and deactivate at the first frame at or after an end boundary.

## Project settings

Defaults:

```json
{
  "defaultAnnotationDuration": 5,
  "seekStepSec": 0.1,
  "largeSeekStepSec": 1,
  "originalAudioGain": 1,
  "originalAudioMuted": false,
  "voiceoverMasterGain": 1
}
```

`exportSettings` supplies `fps`, `crf` and `preset`, for example `{"fps":30,"crf":18,"preset":"medium"}`. Gain zero is silent; one is unity. Mute overrides gain without discarding its stored value.

## Voiceover clips

| Field | Meaning |
| --- | --- |
| `id`, `asset` | UUID identity and generated project-relative audio file. |
| `startSec` | Original linear timeline placement. |
| `durationSec` | Decoded clip duration, trimmed to fit the video. |
| `endSec` | `startSec + durationSec`. |
| `gain`, `muted` | Per-clip playback/export controls. |
| `timingOffsetMs` | Manual placement nudge in milliseconds. |
| `recordedAt` | ISO-8601 recording timestamp. |
| `codec`, `sampleRate`, `channels` | Normalized audio stream metadata. |

Effective start is `startSec + timingOffsetMs/1000`; effective end is `endSec + timingOffsetMs/1000`. The entire effective interval must fit in the video. Multiple overlapping clips mix together, subject to individual/master gain. Audio files are stored separately, never embedded as Base64. The backend stores an immutable registry sidecar beside each WAV, validates its identity/duration/sample metadata on saves, and exposes the uploaded audio before it is first added to a saved project. Removing a clip from the editable document retains the asset for undo; permanent deletion uses the explicit asset API or project deletion.

## Compatibility and migrations

Both validators preserve unknown object fields when loading/saving version 1 documents. This allows additive metadata without silent loss. A higher `schemaVersion` is rejected with a useful error rather than being rewritten as version 1. A future migration should be implemented at the project-load boundary in `backend/app/storage.py` before `Project.model_validate_json`, with explicit source/target versions and a backup; corresponding browser schema updates belong in `frontend/src/model.ts`. No older project version exists to migrate in this release.

Editable JSON does not include the selection, playhead, active tool, undo stack, backend job processes or absolute paths. Export job records are stored separately. Back up each complete project directory, not just `project.json`, to retain its referenced media.

## Native iOS implementation (application version 1.1)

The iPhone editor retains **schemaVersion 1** and the same normalized geometry, temporal intervals, settings, and voiceover clip fields. A new application version alone does not require a project schema migration. Swift validation lives in `frontend/ios/App/App/Native/BJJProject.swift`; future native migrations belong immediately before its project-load validation, with the original document backed up. Unknown additive fields survive native reads/edits/saves.

Native source/proxy metadata uses AVFoundation FourCC codec strings, for example `avc1` (H.264), `hvc1`/`hev1` (HEVC), and `mp4a` (AAC), instead of FFprobe's `h264`, `hevc`, and `aac` names. The native metadata adds `videoStartSec` (source track time-range origin) and `nativeEngine: "AVFoundation"`. Logical project time zero is the first source video time; original audio offsets are relative to that origin. Assets remain project-relative, and bridge media URLs are transient UUID lookups rather than persisted filesystem paths.

Native recordings use 48 kHz mono `pcm_s16le` WAV and the same clip schema. `voiceover/assets.json` holds a clip-ID-to-metadata registry; `voiceover/pending.json` holds recovered takes pending acknowledgement by an editor save. These implementation sidecars differ from the desktop's per-clip registry files. Removing a clip from the document retains its audio for undo. Desktop and native project directories cannot be copied between implementations without migrating those registry sidecars; a portable project import/export feature is not included.

Native export restricts `fps` to at most 60. Its UI maps High/Balanced/Smaller file to the existing `crf` numeric values, which the native renderer converts to a bounded target bitrate. `preset` remains in the schema for compatibility but is not an Apple encoder control and is hidden in the iPhone export dialog. Native projects use the same settings for original/clip/master gain and mute. Native peak clamping differs from the desktop audio limiter; it does not change clip timing.
