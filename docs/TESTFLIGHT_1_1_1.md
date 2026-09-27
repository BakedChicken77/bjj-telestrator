# TestFlight 1.1.1 candidate

## Scope and evidence

Addresses the three September 27 reports on 1.1.0 (1.1), iPhone 16 Pro / iOS 26.6 / 402 × 874 points: microphone preparation error, obscured Audio & voiceovers close button, and cramped video editing.

The baseline 1.1.0 release successfully signed and uploaded in [Release 36335553431](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/36335553431). Device testing exposed the issues above, so physical acceptance remains false. This patch preserves the app identity, local project schema, source footage, and existing signing pipeline.

## Changes

- Session IDs fence pending permission/playback/start operations and stale completion callbacks. Native transitions run on MainActor, preventing overlapping preparation and duplicate completion. Permission/storage preparation no longer activates capture; playback starts first, then the native recorder is created and started in one operation. Capture permits audio-session mixing. Genuine interruptions still stop capture and preserve readable clips.
- The session ordering addresses a code-supported race, but the exact WKWebView/AVAudioSession trigger has not been observed on a connected physical device. Native OSLog recording events identify state and random session ID, never media content. Verify real audio routing and timing before accepting the build.
- Audio controls use a portaled HTML dialog in the browser top layer, a fixed header with a 44-point close target, an independently scrolling body, native focus containment, Escape dismissal, and focus restoration. Recording completion no longer opens this modal unexpectedly.
- Expand keeps the same video and canvas mounted, retaining normalized geometry and history. Project actions are behind the phone header’s ellipsis; Done exits expanded mode to reach timeline and properties.

Apple documents that playAndRecord is nonmixable by default and that mixWithOthers allows coexistence with other sessions: https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers . This documents the configuration; it does not prove the device-specific cause or fix.

## Validation

- Local frontend tests: 67 passed, including seven new native-session controller tests. TypeScript, ESLint and production build passed.
- Browser download failed in the Linux workspace; the new browser regressions and existing full suite must pass in GitHub CI. Native compilation/XCTest and Docker validation also remain CI gates.
- New native lifecycle XCTest fences cancelled permission and stale transitions.
- New browser cases exercise exact 402 × 874 and 874 × 402 viewports plus 375 × 667, long audio lists, close-button hit testing, Escape/focus restoration, larger portrait video, rotation, stable video identity, normalized annotations and undo/redo. Existing tests continue to cover real recording, persistence and MP4 output.

## Device acceptance after TestFlight processing

Install the update over the existing app, retaining its project container. Record version/build, device and iOS version with results.

1. Open an existing project and confirm all annotations and voiceovers remain available.
2. Record on first microphone permission and again on subsequent attempts; preview each clip and check alignment. Test built-in speaker and headphones. Confirm no false “saved” message and no stuck recording state.
3. Deny permission, then enable it in Settings and retry. Background during preparation and during recording; test a genuine audio interruption and repeated rapid start/stop.
4. Open audio controls with no clips and many clips. Scroll to the end, focus numeric inputs, rotate the phone and close without scrolling the header into view.
5. Expand portrait and landscape footage, draw/edit/undo, rotate and collapse. Confirm larger useful image area, stable annotations/playhead and reachable Done/recording controls.
6. Export an annotated video with voiceover, play the resulting MP4 and check visual geometry, audio and timing. Save/relaunch and recheck the project.

Do not mark IOS_DEVICE_ACCEPTED true until the actual candidate passes device checks. App Review submission and public App Store release are outside this patch deployment.
