# Fresh Frame — App Store submission package

Prepared September 28, 2026. Listing edits/submission are pending authenticated App Store Connect access. This document does not claim Apple approval or name availability.

- Name: Fresh Frame
- Subtitle: Draw, narrate & review video
- Bundle ID: com.bakedchicken77.bjjtelestrator (unchanged)
- App Store Connect app: 6816524004 (unchanged)
- Candidate marketing version: 2.0.5
- Primary category proposal: Photo & Video
- Keywords: video,annotation,voiceover,coaching,review,drawing,sports,analysis,telestrator
- Support URL: https://github.com/BakedChicken77/bjj-telestrator/blob/main/docs/SUPPORT.md
- Privacy URL: https://github.com/BakedChicken77/bjj-telestrator/blob/main/docs/PRIVACY.md
- Copyright: 2026 Steve Long

## Description

Show what you see with Fresh Frame. Turn videos into clear, visual explanations with drawings, timed annotations, and your own commentary.

Import a video from Photos or Files, pause on the details, and draw arrows, lines, boxes, ellipses, freehand marks, or text. Adjust the position and timing of each annotation, then record commentary to explain the moment in your own words.

• Review at your pace with scrubbing, playback speed, looping, zoom, and landscape support.
• Edit drawings with undo and redo, precise cue timing, and accessible property controls.
• Record narration and adjust each take's volume, mute state, and timing.
• Export the full video or a selected range as a self-contained MP4, ready for Photos, Files, or sharing.
• Organize reviews with search, rename, duplicate, and Recently Deleted.
• Back up and restore editable projects through Files.

Built for coaches, athletes, instructors, and anyone who wants to explain a video. Your reviews are processed on your iPhone, without an account or a developer-operated upload service.

Previously named BJJ Telestrator. Existing reviews and editable project backups remain compatible.

## Reviewer notes

No login or demo account is required. Import a local video with New review → Choose from Photos or Choose from Files. Open it, use Draw for annotations, Record for microphone commentary, and Export for an MP4. Microphone permission is requested when recording; permission to add to Photos is requested when saving an export. Files import/export uses the system picker.

This is the same app as BJJ Telestrator, renamed Fresh Frame, with a native SwiftUI interface. The bundle identifier and existing local storage locations remain unchanged to preserve user data. The public UI no longer opens the legacy web editor.

## Compliance audit / remaining console work

- Native source audit found no URLSession, analytics, tracking, or server upload code in the native runtime. Privacy manifest declares no collected data and no tracking; disk-space API reason E174.1 is retained. Verify App Privacy answers against the final archive and any applicable support collection.
- Encryption declaration remains ITSAppUsesNonExemptEncryption=false; no custom encryption added.
- Complete the actual age-rating questionnaire truthfully based on app features; imported personal footage is not an app-operated public sharing network.
- Preserve existing pricing/regions until inspected. No paid model or subscriptions have been selected in this release task.
- Verify reviewer contact details already on the app record; do not invent contact data.
- Capture actual final-build iPhone screenshots. Existing synthetic test-fixture screenshots are validation evidence, not finished marketing screenshots.
- Confirm Fresh Frame is accepted as the app name in App Store Connect.
- Submission and public release are explicitly requested in Steve's September 28 instruction to complete items 2–4; no additional generic approval is needed. Any new legally binding agreement still requires its applicable confirmation.

## Device acceptance

On September 28, Steve explicitly reported item 1 complete, referring to the structured real-iPhone acceptance checks discussed for TestFlight 2.0.4 (20.1), source 2588d8bf94b3a88135825c4150900faf2c3c971f. This is owner-reported acceptance, not independently collected performance measurements; no numeric results are invented.

2.0.5 changes branding and removes the legacy editor navigation entry. Keep bundle ID, on-disk folders, project IDs, document UTI, extension, and schemas unchanged. A brief signed-update smoke check of this new candidate is still required before recording build-specific acceptance. Do not copy acceptance variables from 2.0.4 onto a different build.
