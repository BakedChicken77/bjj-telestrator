# Candidate-specific Windows and iPhone acceptance — P1.01

Status: device/staging verification pending. No signed installation or physical
phone has been accessed during this work. Baseline `f5323b3` passed 11 native
XCTest cases and an unsigned archive in CI run 34532184666. That result does not
accept this candidate or prove installability.

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
9. Run an actual 20-minute 1080p roll with 100 annotations and realistic narration.
   Record memory, thermal behavior, elapsed export time, free space and failures.
   Repeat on a lower-resource supported device before broader performance claims.
10. Complete keyboard/VoiceOver and large-text portrait/landscape workflows.
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
| Draft recovery / copy / interruption / low-space results | Pending |
| Files / Photos / ordinary receiving app | Pending |
| Keyboard / VoiceOver / large text / orientation | Pending |
| Windows 11 / Docker versions and fresh result | Pending |
| Failures, limitations, tester, date, evidence location | Pending |
| Decision: accepted / device verification pending | Pending |

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
copy. An older binary cannot read schema 2. Do not replace newer JSON to simulate
lossless downgrade, delete source files, or uninstall the phone app as rollback.
