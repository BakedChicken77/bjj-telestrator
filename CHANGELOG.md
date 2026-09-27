# Changelog

## [2.0.3] - 2026-09-27

### Native narration and export candidate
- Record at 1× with microphone metering, playback-clock anchoring, and interruption/route handling.
- Preview the saved mix; adjust take volume, mute, timing, and deletion with undo/redo.
- Share one audio mixing policy between native preview and export.
- Export the full video or a selected range at aspect-correct sizes without upscaling.
- Preview MP4s, save to Photos or Files, and retry immutable export inputs.
- Real-device recording, route, and A/V alignment acceptance remains required before retiring the original editor.

## [2.0.2] - 2026-09-27

### Native cue editing candidate
- Select overlapping cues, move and resize shapes, and adjust arrow/line endpoints.
- Edit text, colors, opacity, geometry, and precise start/end times in native properties.
- Reorder layers, browse a timed cue strip, and use accessible numeric/nudge controls.
- Stage gestures and property forms until commit; cancel safely and undo/redo complete edits.
- Preserve native copies and unknown project fields. Native narration remains the next milestone.

## [2.0.1] - 2026-09-27

### Native library and review candidate
- Import videos directly from Photos or Files with progress and cancellation.
- Search thumbnail reviews; rename, duplicate, back up, restore, and recover recently deleted native reviews.
- Review at 0.25×, 0.5×, 1×, or 2×; set an A/B loop and restore the playhead on reopening.
- Coalesce scrubbing and fence cancelled resume-seeks; preserve original reviews and document revisions during playback.
- Bundle annotation fonts independently of the web editor and retain their license.
- Retain TestFlight receipts from the CI artifact directory.

Native narration and advanced annotation editing remain later milestones. Original reviews are copied before native editing.

## [2.0.0]

- Internal native iPhone pilot: SwiftUI library and controls, AVPlayer playback, filmstrip scrubbing, native drawing/undo, and MP4 share.
- Pilot edits use verified copies in a separate project root; originals remain in the existing editor.
- Integrates the pending Phase 1 storage, revision, recovery, package, and media-job foundations while preserving 1.1.1 recording lifecycle fixes.
- Adds TestFlight processing and existing-group distribution verification to upload automation.
- Native narration, full cue editing, import, accessibility/device acceptance, and desktop retirement remain migration milestones. This is not a completed 2.0 production release.

## [1.1.1] - 2026-09-27

- Fence native voiceover preparation, playback, capture, interruption and stop with session IDs; initialize capture after playback and preserve valid partial clips.
- Correct interruption messages so a cancelled or empty take is never described as saved; add native lifecycle diagnostics without media content.
- Move Audio & voiceovers into an accessible modal with an always-visible close control, internal scrolling and focus restoration.
- Add expanded video editing without remounting video or annotations; collapse project actions on phones.
- Add recording-race, phone overlay and expanded-canvas regression coverage. Physical-device audio/synchronization acceptance remains required for this candidate.

## [Unreleased]

Phase 1 candidate changes below are uploaded in draft PR #12. Current automated
evidence is in `docs/P1_COMPLETION.md`; signed-device acceptance remains pending.
These changes are not a published release.

- P1.05: editable `.bjjproj` backup/restore with source/narration checksums,
  bounded ZIP/ZIP64 extraction, optional previews, independent restored copies,
  persistent progress/cancel/restart results and desktop download/native Files.
- P1.07: semantic annotation creation/selection and numeric geometry/point edits,
  keyboard dialog/audio focus return, light/dark/system themes, larger text,
  reduced motion and reachable touch actions. Physical VoiceOver remains pending.
  The desktop audio panel no longer covers playback controls when many takes are open.
- P1.08: share unchanged immutable geometry across undo snapshots and read bounded
  PCM narration windows, retaining all audible overlaps. Pause explicitly if the
  audible window set exceeds capacity. Cache disposable project summaries to avoid
  loading every timeline when opening the project browser. Added reproducible editor/library/export
  workloads; actual phone memory/thermal behavior remains unverified.
- P1.06: conservative obsolete-preview cleanup with a 24-hour grace period,
  reference/lease protection and current-preview recovery for stale pending drafts.
- P1.04: PQ/HLG-to-Rec.709 SDR implementation and synthetic native/FFmpeg fixtures;
  shared native/FFmpeg pixel checks pass; actual phone color checks remain pending. Dolby Vision
  remains rejected. Added original 120 fps/VFR PTS and moving-color boundary tests.

- P1.04 preparation slice: tracked import stages, real cancellation and same-project
  preview repair on desktop/native iOS. Pending edits can save through a missing
  derived preview; repair validates media and source hashes before revisioned
  publication. Previews are bounded to 1920 pixels / 30 fps. Reported color and
  timing metadata are retained. The HDR candidate is described above.

- P1.06 storage/export slice: retained asset checksums, storage estimates/breakdown,
  restart-safe retry of immutable saved revisions, and safe completed-MP4 cleanup.
  Desktop exports are probed before atomic publication. Individual recording files
  remain retained for undo/recovery.

- P1.06 project recovery: named checkpoints with before-restore protection,
  verified independent review copies, and Recently deleted with separate permanent
  removal. Source/recording assets and existing export inputs remain retained.
  Copying preserves annotation text even when its content equals an object UUID.
- Native recording acknowledgments now use a recoverable two-file save transaction;
  a recovered take intentionally removed after reopening is not re-added.

- P1.02: schema-2 migration with retained original JSON, runtime capabilities,
  conditional saves/exports, and cross-runtime conformance fixtures.
- P1.03: serialized save acknowledgments, recovery drafts/copies, explicit stale
  write handling, and inspectable redacted support summaries.
- P1.01 preparation: refreshed native baseline evidence and candidate-specific
  signed-device acceptance checks. Physical hardware acceptance remains pending.
- Make Ruff import classification identical in local and CI working directories.

## [1.1.0] - 2026-09-10

- Added the standalone iPhone source target with native storage, imports, recording and MP4 rendering.
- Adapted the editor for touch, safe areas, portrait and landscape screens.
- Added native bridge and touch-browser tests. Native SDK verification subsequently ran in CI; physical-device acceptance remains pending (see the current verification record).
- Added GitHub CI for backend/frontend/browser/Docker/iOS, gated version-tag releases, optional signing/TestFlight, dependency update configuration and repository setup automation.
- Preserved the Windows/Docker application, reported working by the user.

## [1.0.0] - 2026-09-05

- Local video import, timed annotations, editing, undo/redo, persistence and FFmpeg MP4 export.
- Linear microphone commentary, synchronized preview, audio controls and final mixing.
