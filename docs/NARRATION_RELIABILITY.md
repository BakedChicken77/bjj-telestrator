# Narration reliability follow-up — October 12, 2026

Baseline: TestFlight 2.1.0 (39.1), source
`9e1d1c1b5dc9d26e908537fc7ffb98c580faf180`. Steve authorized a corrective
TestFlight release; no main merge or production App Store submission is included.

## Evidence and boundaries

The supplied cumulative diagnostic report records a successful compatible Photos
import delivered as H.264/SDR, a normal recording stop after three video pauses,
and two `PROJECT_INVALID` export failures. The screenshot supplies the specific
message, `Paused frame has no duration.` Recording save is not proof of audible
microphone samples. The report contains neither media nor the saved review;
the reported voice silence cannot yet be attributed to capture versus mixing.

## Changes

- Frame selection skips duplicate/non-increasing decoder timestamps until a
  strictly later picture or EOF. It checks cancellation and decoder failure,
  uses actual picture boundaries/raw sample duration, and bounds the final
  picture by the track end. It does not guess nominal FPS or stretch multiple
  pictures. Invalid/out-of-range timestamps still fail safely with a specific
  error code and preservation guidance.
- Recording checks microphone availability and reports one finite, rounded peak
  meter value (`recordingSignal`, dBFS) at stop. No speech recognition or audio
  content enters diagnostics. This is capture-meter evidence, not proof that
  the persisted WAV or mixed output contains the voice.
- Saved takes are separately scanned off the main actor with bounded PCM buffers;
  `recordingFileSignal` records rounded peak dBFS with the app-owned take UUID.
  Near-silent recordings show a preservation/microphone-check warning rather
  than an unqualified success message. Tests distinguish PCM16/float tone from
  silence and verify the original file hash remains unchanged.
- Preview preparation has separate success/failure breadcrumbs; errors retain
  the bounded domain/code chain. Historical `audioPreview` means an attempt,
  not successful preparation. Existing diagnostic retention/export rules remain.
  A failed preparation no longer lets Play run a stale, muted player item:
  Play retries preparation, and new recording is blocked until it succeeds.
- Regression tests combine three pauses (including the final source frame),
  stop while paused, PCM16 narration, reopen, preview and MP4 energy checks on
  SDR, VFR, high-frame-rate and real Dolby 8.4 media. Source/WAV hashes must not
  change. Boundary tests cover missing/zero duration, nonzero track start,
  duplicates, end clamping and invalid timestamps.

No project migration, recording deletion, automatic gain change, permission
expansion, import-policy change or source/proxy replacement is introduced.

## Acceptance

Run repository/aggregate checks and full native simulator tests/archive. The
release workflow must pass every gate and its receipt must confirm TestFlight
processing and intended internal-group availability. Record exact SHA/build.

Phone acceptance remains mandatory: reopen the existing failing review and
check narration/MP4; record a fresh take with three pauses including one near
the end, watch the microphone meter, check playback/export, and export the
diagnostics. If silence persists, inspect the voluntarily supplied review backup
or use new capture/preview evidence. Do not claim the microphone issue is fixed
solely because generated-tone tests pass. Never require uninstalling or deleting
the failing review. The separate Photos provider-latency investigation remains
open.
