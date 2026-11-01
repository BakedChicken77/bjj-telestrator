# Saved narration pause playback — 2.1.7

The November 1 device report from 2.1.6 (46.1) reached `capturing` on the
Bluetooth HFP route, paused/resumed the picture, and ended with `userStop`.
The take contained 188,052 PCM frames (3.91775 seconds at 48 kHz), with a
measured file peak of -13 dB, followed by `editSaved`. Playback preparation
then failed at `preview_video_holds` with `MEDIA_PAUSED_FRAME_INVALID`.
This establishes a saved-take playback failure. It does not establish complete
Bluetooth acceptance or include the decoder's exact failing timestamps.

The shared preview/export resolver previously treated every strictly greater
rational PTS as a new picture boundary. A request reconstructed from a saved
Double uses a nanosecond clock; the reader can also return the same boundary on
the video's clock. For example, 1,833,333,333/1,000,000,000 and 1100/600 compare
unequal, but their subtraction rounds to zero. Treat differences within one
nanosecond as duplicate boundaries and keep decoding to the next picture.
Apply the same rule to duration fallback at EOF. Real frame boundaries, VFR
timing, final-track clamping and cancellation retain their existing behavior.

The fix operates when rebuilding preview/export from existing saved projects;
no migration or re-recording is required. The timeline, take placements,
original video and WAV remain unchanged. Regression coverage exercises the
mixed-clock boundary and a saved fractional-frame pause through receipt
recovery, preview and actual MP4 export, including picture, audio, duration,
revision and asset-hash checks. Native Xcode CI is required before release.

Physical acceptance remains open under #45. On the affected iPhone, install
the new TestFlight build and reopen the existing review from the report. Tap
Play, check the frozen picture and audible narration, then export and inspect
the MP4. Also record a fresh take with Pause/Resume/Stop and a take stopped
while paused, using the same AirPods. Confirm playback after reopening and
export; collect new diagnostics if either fails. Do not delete the affected
review to test this fix. The earlier five-take Bluetooth checklist remains
applicable; simulator results do not replace it.
