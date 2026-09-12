# Changelog

## [Unreleased]

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
- Added native bridge and touch-browser tests; native Apple SDK/device acceptance remains pending.
- Added GitHub CI for backend/frontend/browser/Docker/iOS, gated version-tag releases, optional signing/TestFlight, dependency update configuration and repository setup automation.
- Preserved the Windows/Docker application, reported working by the user.

## [1.0.0] - 2026-09-05

- Local video import, timed annotations, editing, undo/redo, persistence and FFmpeg MP4 export.
- Linear microphone commentary, synchronized preview, audio controls and final mixing.
