# Shared narration pauses (UX-11)

Holds belong to the review and may be used by multiple takes. Narration and take
screens show each relevant hold's frame reference, original-video anchor,
duration and all associated takes. Muting/deleting one take retains its holds;
the take screen explains this and exposes the pause actions directly.

Removal first snapshots the document revision and explains which takes lose how
much placed audio. Cancel writes nothing. Confirm explicitly removes the pause
and its placements, retaining original WAV files. A changed document/pause rejects
a stale confirmation. Existing atomic save and descriptive local Undo restore
the whole hold/placement transaction, including shared holds.

Thumbnail generation reads a bounded-size preview image and does not alter the
original. A missing thumbnail does not prevent textual frame identification or
recovery. Existing source/review clocks and media-rendering contracts are retained.

Native regression covers two takes sharing one hold, take deletion/Undo, stale
confirmation refusal, pause removal/Undo, durable reload and unchanged WAV hashes.
It uses real synthetic media and checks playable previews before/after removal
and Undo, plus an MP4 export after removal. Preserved takes with no placements
contribute no empty audio tracks or gain to the mix.
A separate isolated synthetic-media UI workflow exercises the actual confirmation,
Cancel and Undo controls and captures the restored shared-pause screen.
Required macOS/native/StoreKit/UI/archive and all platform CI must pass before the
protected TestFlight release. Physical acceptance remains: predict consequences
before confirming, cancel, remove/Undo a shared pause, reopen, hear both takes,
and compare preview/export. Include VoiceOver and largest-text layout.
