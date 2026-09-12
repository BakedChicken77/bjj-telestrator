# Durable export inputs and conservative retention

Status: implemented for the P1.06 storage/export work package; release acceptance pending.

An export used to persist its job status but hold its project snapshot only in
memory. Restart therefore lost the information needed to reproduce that review.
Each new attempt now stores a version-1 input under
`exports/inputs/<job UUID>.json` before publishing queued status. It contains the
complete schema-2 project/revision, required capabilities, source and referenced
voiceover identities/checksums, and full-duration output intent. A retry copies
that input into a new attempt; it does not read current edits or resume a partial
MP4. Unknown input versions, capabilities, altered assets and inconsistent output
fields fail explicitly. The shared canonical fixture is checked by Python and
Swift; the editor receives typed job summaries, not writable render plans.

`assets.json` is a version-1 storage-owned manifest: generated asset UUID, kind,
project-relative reference, byte size, SHA-256 and immutable media metadata.
`assets.cache.json` caches filesystem fingerprints. First export hashes required
media incrementally in one-MiB reads; subsequent autosaves never scan media.
Native hashing runs off the main actor. Jobs verify checksums before rendering
and before publication, so export itself reads required media twice for integrity
checks in addition to decoding. Large-file preparation latency and hardware costs
remain measurements to collect. Initial inventory preparation precedes the queued
job and currently has no separate cancel control; queued/running verification and
rendering are cancellable. P1.04's observable import/preparation work remains open.

The manifest is lazy and includes required assets as they are consumed. Export
inputs do not depend on regenerable proxies. Existing projects and removed takes
remain intact. Source and recording collection is deliberately disabled: live
projects, browser undo, drafts, recording journals and future checkpoints do not
yet have a complete shared reference graph. A legacy permanent-take deletion API
now returns `ASSET_RETAINED` instead of invalidating those owners. Whole-project
deletion is still the existing explicit permanent action, blocked during leases;
recently deleted project recovery is a subsequent P1.06 change.

An in-process project lease protects preparation, queued/running jobs and shared
outputs from project deletion. Completed-file cleanup targets only a generated
MP4; its job/input remain available. Download/share leases prevent cleanup of an
active transfer. Both services have one owning process/store, as before. Symbolic
links are rejected at project-relative file boundaries. No cross-project hard
links, content upload, new dependency or media engine is introduced.

Space estimates separate retained bytes from additional incoming/output/working
bytes and a margin of at least 100 MiB or 20%. Desktop export budgets retained PNG
states and MP4 relocation; native export budgets streamed rendering plus output
relocation. Their bitrate estimates intentionally differ because CRF and Apple
bitrate settings are different controls. Estimates are approximate, never a file
size promise. Queued exports reserve their estimated budget; workers check again
at start. Import and recording preflights and continuous write failures preserve
committed media/JSON. Package staging estimates wait for P1.05's actual pipeline.

Desktop output now receives a real codec/audio/dimensions/duration probe in its
staging directory before atomic publication. Native retains its corresponding
validation. Neither path promises byte-identical encoding. Native even-dimension
rounding now uses nearest-even to agree with desktop for odd oriented dimensions;
321×183 therefore produces 320×184 in both paths. Existing SDR, six-shape and
linear-audio behavior otherwise stays in place. HDR conversion, native limiting
improvements, ranges and quality-intent UI are separate planned work.

Rollback keeps the entire newer project directory, including manifests and job
inputs. No new project schema migration occurs in this slice. Returning to a
schema-2 build without retry support loses retry controls and retention guards;
use a separate preserved copy and never overwrite newer data to simulate a
lossless downgrade. A schema-1 binary still cannot safely read schema-2 projects.
