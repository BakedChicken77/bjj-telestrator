# Original-video and finished-review time (UX-07)

Original-video seconds anchor drawings and the existing loop preferences. Finished
review seconds include inserted narration holds and drive playback, take display
and export ranges. The transport and VoiceOver now agree on finished-review time;
drawing controls and the existing loop menu explicitly label original-video time.
A source lasting 10 seconds plus a 5-second hold is a 15-second review.

All spans are half-open [start, end). At a hold's review start the frozen picture
begins; at its review end source playback resumes. Source drawing [a,b) includes
holds anchored at a and excludes holds anchored at b. Source loop [a,b) uses the
same rule, mapping both edges with output(before:). Use loop range in Export uses
those same mapped edges. An explicitly entered review export range can select
part of a hold. Take placements retain 48 kHz sample boundaries and stable hold
IDs; a new clock label never reinterprets stored annotation or audio timestamps.

Device-only transport preferences add optional reviewTime/projectRevision fields.
They do not change project schema, backups, undo, or exports. Missing/invalid
fields or a different document revision fall back to the existing source position.
A pending restore survives the initial asynchronous playback composition; it is
cleared only by an explicit seek/successful prepared-player seek. Existing bounded
seek generation fencing remains active.

Native regression prepares real synthetic media, seeks inside a five-second hold,
closes/reopens, prepares playback again and checks precise output/source positions
without changing the durable revision. Existing timeline/placement and generated
MP4 tests cover half-open boundaries. Device acceptance: verify clock wording,
VoiceOver, a 10+5-second review, loop/export edges and reopen inside a hold.
