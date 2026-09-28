# Current checkpoint — September 28, 2026

Signing, TestFlight processing, and automatic internal tester distribution are operational through 2.0.4 (20.1). Steve reported device acceptance complete and requested Fresh Frame branding plus completion of App Store preparation, submission, and release. See [Fresh Frame submission package](app-store/fresh-frame.md). The September 26 checkpoint below is retained as historical context and is superseded where it describes pending signing or missing owner authorization.

# iOS App Store release

## Identity and current checkpoint — 2026-09-26

- Public name: BJJ Telestrator.
- Registered explicit Bundle ID: `com.bakedchicken77.bjjtelestrator`.
- Apple team: `554YT3292A` (individual membership).
- App Store Connect app: `6816524004`.
- SKU: `bakedchicken77-bjj-telestrator-ios`. Primary language: English (U.S.).
- Source/release marketing version: `1.1.0`; minimum OS: iOS 17.0.
- First release: iPhone only. Reusable iPad-compatible implementation is retained.
- No optional Developer portal capabilities were enabled. Apple enables In-App Purchase by default; the application contains no purchase implementation.
- Production App Review submission and public release require separate owner approvals. Manual release is the intended mode.

The baseline `main` commit `e65fd6c7f83e6e32348e235690c5fa08d07fea88` passed every job in [CI 36136892978](https://github.com/BakedChicken77/bjj-telestrator/actions/runs/36136892978), including native XCTest and the unsigned device archive. New identity/device settings require their own passing CI. Signing, IPA export, TestFlight processing, and physical iPhone acceptance are still pending; no installable build has been claimed.

Open Phase 1 PRs #8–#12 form a separate stack with schema/storage/media changes. This first signing preparation uses current main; it does not merge that stack or claim its features (portable projects, HDR conversion, recovery UI). Reassess those PRs separately before including their behavior in a release or listing.

## Existing signing architecture

Keep `.github/workflows/release.yml`, `scripts/ci/sign_ios.py`, and `scripts/ci/upload_testflight.py`. A version tag invokes the full reusable CI workflow, then optionally signs on `macos-26` with Xcode 26.6. Signing uses an isolated temporary keychain, an Apple Distribution P12/private key, and an explicit App Store Connect distribution profile. Credentials and temporary files are removed after use. No signing secrets belong in source, artifacts, or logs.

The `ios-release` GitHub environment must restrict deployment to release tags matching `v*`. Its creation/configuration is pending at this checkpoint. Preserve main/tag rulesets and owner-only release initiation.

Environment secrets (names only):

| Name | Purpose |
| --- | --- |
| `IOS_CERTIFICATE_BASE64` | Base64 of password-protected Apple Distribution P12 with private key |
| `IOS_CERTIFICATE_PASSWORD` | P12 password |
| `IOS_PROFILE_BASE64` | Base64 of matching App Store Connect provisioning profile |
| `ASC_API_KEY_ID` | Team API key identifier |
| `ASC_API_ISSUER_ID` | Team API issuer identifier |
| `ASC_API_KEY_P8_BASE64` | Base64 of API private key |

Repository variables:

| Name | Required value / gate |
| --- | --- |
| `IOS_SIGNING_ENABLED` | `true` only after environment and credentials are configured |
| `IOS_TEAM_ID` | `554YT3292A` |
| `IOS_BUNDLE_ID` | `com.bakedchicken77.bjjtelestrator` |
| `IOS_EXPORT_METHOD` | `app-store-connect` |
| `IOS_UPLOAD_TESTFLIGHT` | `true` after the app record and upload credentials are ready |
| `IOS_DEVICE_ACCEPTED` | Keep absent/false until Steve explicitly accepts the actual device build |

`IOS_SIGNING_ENABLED` is a repository variable because the job-level condition is evaluated before entering the environment. API access should use the minimum upload-capable role, not Admin. Verify current Apple role restrictions when issuing the key.

## Version and build procedure

Keep `frontend/package.json`, both root version fields in `frontend/package-lock.json`, the Xcode marketing version and CHANGELOG aligned. Current scripts derive the archive marketing version from package.json. The tag must match package version exactly and its commit must be on main. Never move or overwrite a published tag.

The existing build number is `<GITHUB_RUN_NUMBER>.<GITHUB_RUN_ATTEMPT>` for the Release workflow. Check App Store Connect before uploading; a build number must not have been uploaded for the same version. Do not introduce another upload workflow with an independent counter without replacing this with a shared monotonic allocator. A failed upload must be investigated before retrying.

Merge through a PR only after all seven jobs including `CI gate` pass. The owner initiates the permitted protected release tag. Release reruns tests, builds the frontend, archives/signs/exports, and uploads the IPA when enabled. Confirm Apple processing and assign the processed build to an internal TestFlight group. The workflow does not submit a production App Store version.

## Physical acceptance and production control

Use the actual signed TestFlight build on an iPhone, following `IOS_README.md`. Record the exact commit, version, build, iPhone model/OS and results. Include Photos/Files import, annotation/timeline edits, save/relaunch, microphone denial/allowance, voiceover/audio, portrait/landscape/rotation, H.264, SDR HEVC, silent and VFR footage, exported burned-in MP4 and sharing, interruption/background/cancellation, and representative 20-minute 1080p storage/thermal behavior. HDR input is rejected in this baseline.

Do not set `IOS_DEVICE_ACCEPTED=true` based on simulator/browser results. Reset it before a changed binary and require an explicit fresh device acceptance. Prefer promoting the exact accepted TestFlight build into the production listing; a rebuilt or changed binary requires another acceptance pass. The current boolean controls GitHub release classification only and is not a substitute for build-specific acceptance evidence or an App Review approval.

Before submission, finish screenshots, listing, live support/privacy URLs, audited privacy answers, age rating, encryption, pricing/regions and reviewer contact/notes. Show the owner all final identity/build/compliance fields and ask: “Submit BJJ Telestrator to Apple App Review?” After approval, submit and inspect status/errors. After Apple approval, obtain separate permission for manual public release.

## Hotfix and recovery

Preserve tags, source manifests and acceptance evidence. Fix defects on a branch, run all gates, increment version/build as needed, upload and accept a new binary, then obtain submission approval. App Store distribution does not provide an instant downgrade to an older binary. Do not uninstall the app as a recovery step: deleting it removes local projects. Retain source footage and exported MP4s; this baseline does not offer editable-project backup/restore. Never silently downgrade or overwrite a newer project schema.

## Requirements checked

Apple currently requires Xcode 26+ and the iOS 26+ SDK for uploads; the existing Xcode 26.6 pipeline meets that baseline. The iOS 17 deployment target also exceeds the current iOS 13 minimum deployment target. Sources: [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/). Recheck requirements before future releases.
