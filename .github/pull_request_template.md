## Problem and change

Describe the user-visible problem, the change, and why it fixes that problem. Link the selected issue, if any.

## Scope and branch

- Target base branch: `main` / `preview/native-iphone` / other (specify).
- In-scope behavior and explicit non-goals:
- Release implications: none / iOS preview push triggers release / other (explain).

## Verification

- [ ] Relevant tests and required CI pass (include actual run link and results).
- [ ] Video timing, orientation, audio and persistence were checked when affected.
- [ ] Native XCTest/UI CI passed for iPhone changes (or explain checks still pending).
- [ ] Documentation and changelog are updated when behavior changes.
- [ ] No uploaded footage, recordings, credentials, signing profiles or generated data are included.

Record commands run, observed outcomes, any skipped/unavailable checks, and physical iPhone testing that remains.

## Review and merge readiness

- [ ] Reviewed the full diff for scope, source-media/data preservation, and unintended release/version changes.
- [ ] Codex Code Review findings were evaluated if Code Review is enabled (otherwise state unavailable).
- [ ] Required `CI gate` passed and actionable review conversations were resolved.

Do not automatically merge into `preview/native-iphone`: pushes trigger the release workflow and may upload a TestFlight build. Merge/release decisions remain with the repository owner.
