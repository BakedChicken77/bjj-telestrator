# Native media import expansion

Implementation candidate based on preview `d55085668c2d5a66235f800c292211d54dc82b38`
(2.1.0 / 38.1). Steve authorized implementation and a TestFlight candidate on
October 11, 2026. No production App Store release or main merge is included.

## Scope

Native iOS now parses Dolby configuration records before deciding support.
The new qualified route is HEVC 10-bit, Dolby profile 8, compatibility ID 4,
RPU present, base layer present, no enhancement layer, Rec.2020 HLG. Missing,
truncated, contradictory, unknown-version, other-profile and inconsistent color
metadata fail closed. Mixed sample descriptions fail safely. This is not a
promise to decode every codec in MOV/MP4, nor native HDR export.

The existing AVFoundation Rec.709 composition and H.264/AAC renderer produces
an SDR preview and SDR export directly from the retained original. There is
no intermediate master and no additional lossy conversion of saved originals.
Hashes, copy validation, space checks, cancellation, finite background tasks,
proxy validation, atomic publication and exact staging cleanup are retained.
Existing H.264/HEVC SDR and PQ/HLG behavior remains covered by regression tests.

All original consumers share BJJMedia.inspect: import, repair, narration
preview, export and source-only backup restoration. Newly created Dolby reviews
truthfully retain Dolby metadata and require `media.dolby84-to-sdr.v1` plus the
existing HDR capability. Old iOS builds and desktop/browser runtimes that do
not advertise this capability refuse the new review before editing it. Existing
reviews are not migrated in place. Native reads do not depend on the new-import
switch: `BJJDolbyImportsEnabled=false` can stop new imports in a rollback build
without abandoning existing Dolby reviews.

Photos remains **compatible**, provider Progress reads remain **disabled** as
in 38.1. No import-speed improvement is claimed. A failed Files or automatic
Photos attempt can offer **Choose compatible copy**. This opens a new compatible
picker, asks the user to select the same video, creates a fresh job linked by
`retryOf`, and treats that selection as authoritative. Compatible failures and
retries cannot trigger another recovery loop. Storage, cancellation, background
expiration and generic decode errors do not offer this recovery.

The legacy browser bridge also retains compatible Photos selection and records
that provenance; it uses shared source inspection. The explicit recovery action
is on the native library screen. A supported descriptor identifies an eligible
route, not a promise that decoding, storage or publication will succeed.

## Diagnostic envelope 4

Additive optional job fields preserve historic decoding:

| Field | Evidence |
|---|---|
| descriptor | Codec, bit depth if available, transfer/primaries/matrix, Dolby presence, parsed profile/level/compatibility/layer flags, finite duration and dimensions |
| supportPolicyVersion | `native-media-v1` |
| importSource | `files`, `photos`, or `retained_source` |
| supportDecision / conversionRoute | `supported`/`rejected`; `native_sdr`, `hdr_to_sdr`, `dolby84_to_sdr`, `unsupported` |
| rejectionReason | Bounded classification; no system error descriptions |

The descriptor is captured before rejection and never added after a terminal
stop. Codec facts describe the delivered rendition, not the original Photos
selection. Older fields remain absent/unknown; export-time builds do not fill
missing provenance. No atom payloads, filenames, paths, Photos IDs, media or
annotation text enter diagnostics. Existing event cap, retention, local export,
clear and diagnostic-write failure isolation remain unchanged. No permissions
or remote telemetry were added. The app retains prior error domain/code rules.

## Verification and release gates

- Parser: actual layout, truncation, conflicting records, version, profile 5,
  compatibility ID, EL/BL/RPU flags and color mismatch.
- Licensed real Dolby bitstream: native inspect/import, SDR proxy and export,
  color consistency, annotation timing, AAC narration preview/export, reopen,
  repair, original hash, and source-only backup restore. Fixture attribution is
  in `tests/fixtures/DOLBY_LICENSE.md`; no user footage is committed.
- Failure: unsupported descriptor/cause/phase persistence and preserved prior
  reviews; recovery eligibility and no loops; existing cancellation/expiration,
  provider races, low-space, atomic-save, pause narration and UI/StoreKit tests.
- Desktop/browser explicitly reject the native capability without changing files.
- Required local aggregate and repository checks, then all GitHub CI jobs,
  native simulator tests and archive. Exact CI SHA and TestFlight receipt must
  be recorded before reporting release availability.

**Physical gates still require Steve's phone after candidate availability.**
The rejected Files video is not attached; its Dolby profile is unknown. Test
that exact file plus real portrait/landscape iPhone Dolby, SDR, edited/VFR and
long videos. Check preview and exported MP4 colors, highlights, skin tones,
audio sync, rotation, paused narration, saved-review reopening, cancellation,
short switch/lock and actual background expiration. Test compatible reselection,
Cancel, VoiceOver and larger text. Export the version-4 report through Previous
reviews and record phone/iOS/build, fixture label, conditions and elapsed time.
Do not sum overlapping cumulative reports or call a faster warm repeat a fix.

Actual problem-video success, other Dolby profiles, ProRes/other native codec
qualification and controlled Photos performance results remain evidence gates,
not implementation claims. No new decoder dependency, automatic asset
reselection, global current policy or silent fallback is introduced.
