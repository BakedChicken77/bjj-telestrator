# Candidate-specific Windows and iPhone acceptance — P1.01

Status: device/staging verification pending. No signed installation or physical
phone has been accessed during this work. The P1.04 import/repair candidate
`34fa4f206615d3d1da2449d3db93c552b5beae17` passed all 25 native XCTest cases and
an unsigned archive in [CI](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/34753579589). That result does not prove installability. Use the exact subsequent signed candidate for every result below.

## Signed pilot from Windows

1. Follow the existing `docs/GITHUB_SETUP.md` and protected `ios-release`
   environment instructions. Use the intended existing `IOS_BUNDLE_ID` and team.
   Keep certificates/profiles/API keys in environment secrets. Do not paste them
   into results. No Mac ownership is required; the workflow uses macOS runners.
2. Select the exact reviewed commit and app version. Run the normal CI gates,
   including native XCTest and unsigned archive. Record the run URL and SHA.
3. When signing/distribution is authorized, use the existing signed pilot route.
   TestFlight is optional and independently enabled. A pending device acceptance
   keeps a pilot labeled prerelease. No distribution was performed for this branch.
4. Record the actual installed `CFBundleShortVersionString` and `CFBundleVersion`.
   The scripts use workflow run number plus attempt, e.g. `7.2`.
5. Install over the existing populated app, with the same bundle identity; do not
   uninstall. Preserve an external copy of irreplaceable media/projects first.
6. Import SDR H.264/HEVC from Files/Photos, add/edit all six cue types, record,
   save/reopen, export, play in an ordinary MP4 player, and share to Files/Photos.
   Record any unsupported media message without claiming HDR support.
7. Run the 20-second arrow `[5,10)`/circle `[7,9)` timing scenario. Verify pixels
   around each boundary, audio timing, export duration/codec, and source SHA-256.
8. Exercise pending drafts: edit, interrupt/background/force-close, reopen, inspect
   recovery choices, create a recovery copy, and verify both reviews/assets. Test
   denied microphone access, low space, failed save and export cancellation.
9. Save a named checkpoint, remove a take, restore the checkpoint and verify its
   audible placement. Duplicate the review and edit it independently. Move one
   generated project to Recently deleted, reopen the app, restore it and retry a
   saved export. Test permanent deletion only on disposable generated projects.
10. Run an actual 20-minute 1080p roll with 100 annotations and realistic narration.
   Record memory, thermal behavior, elapsed export time, free space and failures.
   Repeat on a lower-resource supported device before broader performance claims.
11. Complete keyboard/VoiceOver and large-text portrait/landscape workflows.
    Repeat Windows 11/Docker startup, editing, export, shutdown/restart persistence
    with generated/backed-up projects. Do not use `docker compose down -v` on data.

## Result record (copy for each exact build/device)

| Field | Result |
| --- | --- |
| Commit / PR / CI URL | Pending |
| App version / build / bundle ID | Pending |
| iPhone model / iOS / free space | Pending |
| Source duration / dimensions / fps / color / audio / SHA-256 | Pending |
| Installed over populated build / projects retained | Pending |
| 20-second output codec / size / duration / timing | Pending |
| 20-minute workload / memory / thermal / elapsed export | Pending |
| Draft recovery / checkpoints / independent copy / deleted-project restore | Pending |
| Interruption / low-space / retained export retry results | Pending |
| Files / Photos / ordinary receiving app | Pending |
| Import stages / cancel / same-project preview repair / source hash | Pending |
| Keyboard / VoiceOver / large text / orientation | Pending |
| Windows 11 / Docker versions and fresh result | Pending |
| Failures, limitations, tester, date, evidence location | Pending |
| Decision: accepted / device verification pending | Pending |

## Import and repair acceptance — P1.04

Run on disposable generated or consented SDR media first. Record the exact
candidate SHA/build and the input file selected from each picker.

1. Import from Files, then Photos. Record copy/inspection/preview/validation
   stages and elapsed time. System Photos retrieval may be indeterminate.
2. Cancel a large copy and then a preview encode; confirm a cancelled outcome,
   preserved existing projects and successful retry. Reopen after interruption
   during each stage; incomplete work must not appear as a completed project.
3. Add the timed cues from the 20-second scenario and a narration take. Save and
   checkpoint the review. Use Projects → Repair preview, confirm the same project
   reopens with the same cues/narration and a new saved revision, then edit/export.
   Verify an ordinary MP4 around all cue/audio boundaries and source SHA-256 using
   the authorized device test harness. Record preview and final dimensions/rate.
4. Repeat repair after a derived-preview failure on a generated test project;
   preserve the source. Pending edits must save before repair. Cancel a repair and
   verify the previous durable project; no source or narration may be removed.
5. Test a second-session save conflict where available, insufficient space,
   background/lock/expiration, relaunch and retry. Do not fill storage containing
   irreplaceable unbacked-up media. Record actual failure codes and remaining space.
6. Compare an original high-speed file with a Photos-rendered slow-motion asset.
   Record which representation was selected, source duration/rate and observed
   timing. A 30 fps preview is not every source frame; do not label time stepping
   exact. Run real VFR and HDR cases only as explicit pending format acceptance;
   the current candidate does not provide HDR conversion.
7. With VoiceOver and large text, reach stage/status/cancel/repair, cancel without
   a drag gesture, and verify that progress does not cause per-frame announcements.
   Repeat in portrait/landscape and at 1280×720 on Windows/Docker.

All results above are **device/staging verification pending**. Automated browser
and simulator evidence does not mark these hardware checks passed.

## Release evidence binding

`IOS_DEVICE_ACCEPTED=true` alone is insufficient. Production classification also
requires `IOS_DEVICE_ACCEPTED_SHA`, `IOS_DEVICE_ACCEPTED_VERSION`,
`IOS_DEVICE_ACCEPTED_BUILD`, and `IOS_DEVICE_EVIDENCE_URL` to match the candidate
commit, package version, and actual run/attempt build, with an HTTPS evidence URL.
An older build's acceptance cannot attest to a fresh build. A new build or rerun
needs new evidence. These are metadata, not test substitutes. Preserve the accepted
signed artifact when planning an authorized production promotion; do not rebuild
and reuse an old acceptance record. No variables or repository settings were
changed by this implementation.

## Rollback

Keep the last working source/build and untouched pre-migration JSON. Preserve the
entire newer project and media first; recover the older document in a separate
copy. A schema-1 binary cannot read schema 2. Do not replace newer JSON to simulate
lossless downgrade, delete source files, or uninstall the phone app as rollback.
