# Portable editable project packages

P1.05/P1.06, September 13, 2026. Implementation with desktop automation;
fresh native compilation and physical cross-device transfer remain pending.

Use one ZIP/ZIP64 package format for Windows and iPhone. Its manifest binds a
confirmed project revision to immutable source/narration assets by size and SHA-256.
Generated UUID entry names avoid filesystem case/Unicode/Windows-device-name
ambiguity. The original user filename is metadata only. Already compressed media
is stored; optional preview inclusion trades transfer size for restoration speed.
Checkpoints and exports are not included by default in this first package version.

Python uses standard-library zipfile/zlib. Native pins ZIPFoundation 0.9.20 at
`22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, a reviewed MIT dependency, directly in
the existing Xcode project. Its license is bundled in `public/licenses/`. This
avoids JavaScript archive strings, whole-file memory use and another media pipeline.
Native extraction uses Apple's streaming Compression API after raw ZIP preflight;
complete input consumption and actual expansion limits remain observable.

Both implementations check raw directory bounds before library enumeration,
local/central agreement, flags/methods, collisions, CRC, SHA-256 and actual expanded
bytes while reading. Extension and claimed ZIP sizes are insufficient validation.
Strict JSON parsing rejects duplicate keys and excess depth. Archive limits are
documented in PROJECT_FORMAT.md; forced ZIP64 structures use small CI fixtures.
Multigigabyte Files transfers remain a physical-device gate.

Restore always installs a new copy, even when the project ID is unused. This makes
collision behavior predictable and protects the existing review. Remap object IDs
and references; retain literal text, the original document/manifest and remapping
sidecars. A missing optional preview is regenerated using the normal media path.
Validate and reopen staging before atomic installation; reconcile durable completion
receipts and restore markers on restart. Never label a partial transfer complete.

Retain the last good original and recordings. Cleanup initially removes only
unreachable UUID-named previews after a 24-hour grace period. All known durable
references and job leases pin files; damaged metadata blocks deletion. Session
undo can reference removed recordings, so audio reclamation remains conservative.
This policy uses extra disk space to avoid unverifiable ownership assumptions.

Rollback preserves the whole newer project first. Packages do not make an older
binary understand newer required capabilities. Restore a compatible prior copy;
never remove a capability or overwrite new edits to simulate lossless downgrade.

Primary implementation references:

- [ZIPFoundation 0.9.20 source and license](https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d)
- [Apple streaming compression lifecycle](https://developer.apple.com/documentation/compression/compression_stream)
