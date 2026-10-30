# Save feedback and local Undo (UX-13)

The native editor and narration screens show confirmed local save state. A staged
inspector/canvas edit is unsaved; a failed document write has a distinct state.
Audio playback preparation is independent of persistence and cannot turn a saved
take into an unsaved one. Recording remains covered by its dedicated dock.

Undo labels follow the existing 50-entry, session-local document history. Labels
move with successful undo/redo writes and remain unchanged when a write fails.
The persistent action remains reachable without a timed snackbar. Inspector
Save/Cancel and one-gesture transactions retain their existing behavior.

Automated regression: injected journal-write failure retains the inspector draft,
leaves the durable document/history unchanged, and successful retry/Undo/reopen
reports confirmed state. Native XCTest and existing compact/large-text snapshots
run in required macOS CI. Linux repository tests: 19 passed on October 30.

Device acceptance for the TestFlight candidate: draw/delete/Undo; change mix and
Undo from Narration; delete take and Undo; remove pause and Undo; stage/cancel a
drawing; reopen and confirm committed edits. Check small-screen portrait,
landscape, largest text and VoiceOver. Device results are pending, not inferred
from simulator coverage. Original media and recording assets are never removed.
