# Changelog

## [1.1.1] - 2026-09-27

- Fence native voiceover preparation, playback, capture, interruption and stop with session IDs; initialize capture after playback and preserve valid partial clips.
- Correct interruption messages so a cancelled or empty take is never described as saved; add native lifecycle diagnostics without media content.
- Move Audio & voiceovers into an accessible modal with an always-visible close control, internal scrolling and focus restoration.
- Add expanded video editing without remounting video or annotations; collapse project actions on phones.
- Add recording-race, phone overlay and expanded-canvas regression coverage. Physical-device audio/synchronization acceptance remains required for this candidate.

## [1.1.0] - 2026-09-10

- Added the standalone iPhone source target with native storage, imports, recording and MP4 rendering.
- Adapted the editor for touch, safe areas, portrait and landscape screens.
- Added native bridge and touch-browser tests; native Apple SDK/device acceptance remains pending.
- Added GitHub CI for backend/frontend/browser/Docker/iOS, gated version-tag releases, optional signing/TestFlight, dependency update configuration and repository setup automation.
- Preserved the Windows/Docker application, reported working by the user.

## [1.0.0] - 2026-09-05

- Local video import, timed annotations, editing, undo/redo, persistence and FFmpeg MP4 export.
- Linear microphone commentary, synchronized preview, audio controls and final mixing.
