# Project format — schema version 2

`project.json` is UTF-8 JSON. The backend validates it with `backend/app/models.py`; the browser validates it with Zod in `frontend/src/model.ts`. `docs/project.schema.json` is generated from Pydantic, and `docs/example-project.json` is a complete illustrative document (its relative media assets are not bundled).

## Document fields

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `2`. Version 1 migrates; future versions require an upgrade. |
| `revision` | Storage-assigned positive JSON safe integer; saves use the expected revision. |
| `requiredCapabilities` | Unique capability strings; version 2 requires `project.revisions.v1`. Unknown requirements block editing/export. |
| `projectId` | Canonical UUID, also the project directory identifier. |
| `projectName` | Editable display/export name. |
| `createdAt`, `updatedAt` | ISO-8601 timestamps. |
| `source` | Immutable original-media metadata and project-relative asset reference. |
| `proxy` | Service-owned editing-media metadata and relative asset reference; only validated repair may replace it. |
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

TypeScript, Python, and Swift use ordered migration registries and the canonical
`tests/fixtures/project-conformance.json` cases. Version 1 migrates to version 2
with revision 1 and `project.revisions.v1`; repeated migration is a no-op. Unknown
optional object fields survive. Unknown required capabilities and future schemas
require an upgrade. Storage retains the exact prior JSON, validates assets, installs
atomically, then reopens the migrated document. Source files are not rewritten.

Editable JSON does not include the selection, playhead, active tool, undo stack, backend job processes or absolute paths. Export job records are stored separately. Back up each complete project directory, not just `project.json`, to retain its referenced media.

## Native iOS implementation (application version 1.1)

Both runtimes now use schema 2. Geometry, source-time annotation intervals and
linear voiceover semantics are unchanged. `BJJProjectMigrations.swift` provides
the native registry and the native test bundle consumes the same canonical JSON
as TypeScript/Python. No composition, new visual type, or audio trim field is added.

Native source/proxy metadata uses AVFoundation FourCC codec strings, for example `avc1` (H.264), `hvc1`/`hev1` (HEVC), and `mp4a` (AAC), instead of FFprobe's `h264`, `hevc`, and `aac` names. The native metadata adds `videoStartSec` (source track time-range origin) and `nativeEngine: "AVFoundation"`. Logical project time zero is the first source video time; original audio offsets are relative to that origin. Assets remain project-relative, and bridge media URLs are transient UUID lookups rather than persisted filesystem paths.

Native recordings use 48 kHz mono `pcm_s16le` WAV and the same clip schema. `voiceover/assets.json` holds a clip-ID-to-metadata registry; `voiceover/pending.json` holds recovered takes pending acknowledgement by an editor save. These implementation sidecars differ from the desktop's per-clip registry files. Removing a clip from the document retains its audio for undo. Desktop and native project directories cannot be copied between implementations without migrating those registry sidecars; a portable project import/export feature is not included.

Native export restricts `fps` to at most 60. Its UI maps High/Balanced/Smaller file to the existing `crf` numeric values, which the native renderer converts to a bounded target bitrate. `preset` remains in the schema for compatibility but is not an Apple encoder control and is hidden in the iPhone export dialog. Native projects use the same settings for original/clip/master gain and mute. Native peak clamping differs from the desktop audio limiter; it does not change clip timing.

## Save, export, and recovery protocol

`GET /api/capabilities` and native `getCapabilities` report schema/capabilities.
Desktop GET returns `ETag: "N"`. PUT requires `If-Match: "N"` and document
`revision=N`; a successful save returns N+1, and stale writes return 412 with
`PROJECT_CONFLICT` and `currentRevision`. Missing preconditions return 428.
Native `saveProject` accepts `expectedRevision` and rejects stale saves with the
same code. Revision is not editable or restored by undo/redo.

Export POST requires the same conditional revision; native `createExport` accepts
`expectedRevision`. The job's `projectRevision` identifies its immutable in-memory
input. Durable restart/retry manifests are described in the P1.06 section below.

A recovery draft has `version:1`, generated `writerId`/`draftId`, `savedAt`, and
validated `project` including its base revision. Desktop drafts use local browser
storage; native drafts use `recovery/{writerId}.json`. Each writer owns its slot.
Cleanup compares `draftId`, so an old acknowledgment cannot delete a newer draft.
Drafts over four million UTF-16 code units are not journaled; an explicit recovery
error is shown, and a direct durable save remains available. Storage quota can be
lower. No force-close guarantee is made for edits not yet journaled.

Recovery-copy accepts the validated draft, verifies immutable media against the
owning project, copies its source/proxy/recordings into a new project, remaps known
UUID references, and publishes project JSON only after validation. Failed copies
are removed; existing projects remain intact. Optional-field reference values
matching remapped UUIDs are retained with updated IDs. Literal `text`,
`projectName` and `originalFilename` values are never interpreted as UUID references,
even when their content matches an old ID. The copied review receives the explicit
copy-name suffix. There is no cross-project
hard-linking or portable ZIP/package format in this work package.

Rollback: preserve the entire current project directory first. Use a separately
copied directory plus `project.pre-migration-v1.json` with the previous binary for
prior-version recovery. That copy excludes later edits by design; never overwrite
the newer project to pretend to downgrade it. Phone rollback must preserve the
app container and bundle identity. Do not uninstall to roll back.

## P1.06 storage sidecars and immutable export input

The project remains schema 2. Storage-owned files do not enter undo or autosave:

- `assets.json`: `{version: 1, assets: [...]}`. Each asset has a generated UUID
  `assetId`, `kind` (`source`, `proxy`, `voiceover`), safe `reference`, integer
  `byteSize`, lowercase SHA-256 `sha256`, and immutable `metadata`.
- `assets.cache.json`: local filesystem fingerprints used to avoid rehashing
  unchanged assets. This cache is disposable; the manifest's content identity is
  retained and a differing source is rejected.
- `exports/inputs/<job UUID>.json`: `{version: 1, projectId, revision,
  requiredCapabilities, project, assets, output}`. `project` is the full immutable
  revision; `assets` includes its source and referenced recordings, even muted
  takes. Proxies are not required by an export retry. `output` specifies `[0,duration)`,
  oriented even dimensions, fps, current quality settings, MP4/H.264/AAC/yuv420p,
  `supported-sdr-v1` color policy and `linear-mix-v1` audio policy. These names
  preserve the current SDR path and existing platform audio limitations.

Jobs add `retryOf`, `retryAvailable`, `outputAvailable`, and `errorCode` to the
existing `projectRevision`. A retry has a fresh job UUID and the old revision;
cleanup sets output availability false and retains the input. Legacy jobs remain
visible but have no retry input. Stored input version/output/capability mismatch,
UUID/reference corruption and hash mismatch cannot silently export current edits.
See `tests/fixtures/export-plan-conformance.json` and
[decision 002](docs/decisions/002-durable-export-inputs.md).

Runtime capabilities add `exportRetry`, `storageBreakdown` and
`exportFileCleanup`. HTTP/native equivalents are project-scoped storage inspection,
retry by job UUID, and completed-file removal by job UUID. Clients provide no
asset path. Source/recording files are never reclaimed by this work package;
portable packages and full reference-based collection remain later work.
Checkpoints and project trash are described below.


### Checkpoint and recently deleted records (storage version 1)

Project schema remains 2. Checkpoints are not user-editable project fields:

```json
{
  "version": 1,
  "checkpointId": "<UUID>",
  "projectId": "<UUID>",
  "revision": 7,
  "label": "Before review",
  "createdAt": "<UTC timestamp>",
  "input": "<full version-1 immutable render-plan object>"
}
```

`checkpoints/<checkpoint UUID>.json` retains the full input object (the placeholder
above abbreviates it). IDs, project ownership, schema, required capabilities and
source/recording identities must validate before restore. No downgrade is attempted.
The old revision is evidence; restore assigns a newer current revision. A checkpoint
is never silently overwritten. Labels are 1–120 characters; at most 1,000 versions
per project are accepted. Required recordings remain retained even after removal
from the current timeline. The current derived proxy is preserved during restore.

`projects/recently-deleted/<trash UUID>/metadata.json` contains
`{version:1, trashId, projectId, projectName, revision, deletedAt}`. Its sibling
`projects/<project UUID>/` holds the complete moved project. Empty metadata-only
entries from interrupted moves do not hide or replace the still-live project.
Restore uses the original ID if free. A collision remaps project/annotation/take
UUIDs and known references in a new copy, leaving old jobs/versions in the retained
archive. Unknown optional fields survive. Individual unknown required capabilities
still prevent lossy restore/edit/export. Trash has no automatic retention expiry.

New capability flags: `projectCheckpoints`, `projectDuplicate`, `projectTrash`.
Desktop interfaces (native bridge exposes the same UUID/revision semantics):

- `GET/POST /api/projects/{id}/checkpoints`; POST carries `{label}` and If-Match.
- `POST /api/projects/{id}/checkpoints/{checkpointId}/restore`, with If-Match.
- `POST /api/projects/{id}/duplicate`, with If-Match.
- `DELETE /api/projects/{id}`, now recoverable and requiring If-Match.
- `GET /api/recently-deleted`; `POST /api/recently-deleted/{trashId}/restore` returns
  `{project,copied}`; `DELETE /api/recently-deleted/{trashId}` permanently removes it.

Project summaries include `revision`. Missing/stale revision returns 428/412;
clients cannot submit paths. Recovery errors retain files and use typed conflict,
asset/storage or `RECOVERY_INVALID`/`RECOVERY_LIMIT` codes. Old binaries do not know
these sidecars: preserve the complete new directory before any rollback and use a
separate prior copy; never remove new versions to simulate a downgrade.


### Media inspection and preparation records (P1.04)

Schema stays at 2. Optional media strings are `transferFunction`, `colorPrimaries`,
`colorMatrix`, `colorRange`, `averageFrameRateRational`, `nominalFrameRateRational`
and `timeBase`; each is absent/null or 1–100 characters. `dolbyVision` is an
optional strict Boolean. The 26-case TypeScript/Python/Swift corpus covers these
fields in addition to prior migration/capability rules. No new required rendering
capability is introduced. Unknown optional fields continue to round-trip.

These are reported immutable inspection facts, not editable delivery intent.
FFprobe strings use its metadata names; AVFoundation retains its reported color
identifiers and uses `unknown` when range is unavailable. Missing color metadata
is not proof of SDR. Native does not fabricate an exact rational frame rate from
its floating nominal rate. `timeBase` describes the inspected track; these fields
are not a presentation-timestamp index and cannot establish exact VFR stepping.

Runtime `mediaJobs` / `proxyRepair` report support; `hdrToSdr` remains false.
Desktop reserves with `POST /api/import-jobs`, attaches `X-BJJ-Import-ID` to the
existing import request, polls `GET /api/media-jobs/{id}` and cancels with DELETE.
`POST /api/projects/{id}/proxy-jobs` requires `If-Match` and returns 202. Native
uses `createImportJob`, `getMediaJob`, `cancelMediaJob` and `repairProxy`, with
`jobId` on `importVideo` and `expectedRevision` on repair. Asset resolution remains
service-owned. Duplicate or cancelled reservations cannot start a second import.

Operation sidecar: `{version: 1, job: ...}` with UUID `jobId`/`projectId`, operation
`import|repair`, status `queued|running|completed|failed|cancelled`, stage
`copying|inspecting|preparing_preview|validating|ready`, optional bounded progress,
byte counts, cancel request, domain error and completed `projectRevision`.
Terminal records are bounded by retention, not embedded in undo snapshots.
Repair changes only proxy metadata plus the storage revision/update timestamp;
source, annotation intervals and narration placement are not redefined. Source
and recordings are required for saves; an unchanged absent derived preview may be
saved so pending edits survive repair. Creation/replacement requires its preview.
Rollback to the preceding schema-2 build retains originals and project JSON;
keep a whole-project copy before switching binaries. Do not uninstall the phone
app. The previous binary lacks preparation controls and does not understand these
operation records, but the additive media fields do not alter rendering semantics.
