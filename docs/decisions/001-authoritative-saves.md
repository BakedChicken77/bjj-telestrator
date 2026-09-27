# Authoritative saves and recovery (P1.02 / P1.03)

Starting point: `f5323b3b270e3836d7df10309d1684cf8d98e9ca`, app 1.1.0,
schema 1. Working branch: `codex/p1-save-recovery`.

The first vertical package introduces schema 2, `project.revisions.v1`, a
storage-assigned revision, and conditional saves/exports. The server/native store
checks the expected revision while holding its persistence lock. Undo/redo can
restore editable content, but never an older storage revision. Unknown optional
JSON survives; unsupported schemas/capabilities prevent editing and export.

Migrations keep the exact prior JSON before atomic replacement and validate the
replacement by reopening it. Sources and recording assets remain immutable.
An older binary cannot read schema 2; rollback uses the retained schema-1 copy,
without deleting or pretending to downgrade the schema-2 project.

Pending edits are journaled separately from the confirmed project. Saves are
serialized and advance the expected revision only after acknowledgment. A lost
response is reconciled against the durable content; conflicting content is never
automatically merged. Recovery offers a copy or the durable version. Copying
uses new project/object IDs and project-local asset copies, retaining originals.

Native recording recovery remains asset-backed and must not be discarded by a
concurrent save. Diagnostics use an allowlist of codes and coarse platform/build
information, never arbitrary exception text or project/media metadata.

Only this first package and baseline/device-evidence preparation are selected for
the initial branch. The remaining core tasks retain the user's dependency order;
P5.01–P5.07 are not selected. No release, signing, paid service, external media
upload, account, or billing change is part of this package.
