# Fresh Frame UX/UI backlog

This folder preserves the **October 16, 2026** comprehensive iPhone UX/UI review and explains how to manage its 32 recommendations in GitHub. Backlog established October 17, 2026.

**Start here:** [Tracking issue #43](https://github.com/BakedChicken77/bjj-telestrator/issues/43) · [Open UX feature requests](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20is%3Aopen%20label%3Aux-review%20label%3Aenhancement%20UX-%20in%3Atitle) · [Quick wins](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20is%3Aopen%20label%3Aux-review%20label%3Aeffort%3Aeasy)

All recommendations were created **open, unassigned, Backlog, and not selected for development**. There are no release commitments, due dates, milestones, or coding-agent assignments. Neither a high priority nor assignment to this backlog authorizes implementation.

## Preserved research

- [GitHub-readable original review](2026-10-16-review.md): architecture, workflow inventory, all 32 recommendations in original order, quick wins, larger initiatives, evaluation tasks, confidence levels, and source register.
- [Original HTML report](FreshFrame_UX_UI_Review_2026-10-16.html): exact original bytes; download and open locally to use its category and quick-win filters.
- HTML SHA-256: `6aed8bc8d722f6000c2f27b1202947f0206811f7c36803848da0385e761a6862`.

Keep the original report frozen. Record later evidence and changed decisions in issues, or add a separately dated follow-up review. The Markdown transcription adds stable UX anchors and issue links but does not change the original recommendations. Acceptance criteria and relationship notes added on October 17 are planning elaborations, not claims that the original review performed these tests.

The inspected native baseline was [`ae2437b15f95bf08a4c11a266c119b6846e308bb`](https://github.com/BakedChicken77/bjj-telestrator/tree/ae2437b15f95bf08a4c11a266c119b6846e308bb), marketing version 2.1.0 on `preview/native-iphone`. On October 17 that ref was unchanged. Default `main` was `d661fa683021a8df5f5bd9b212ab1f6ce55d1b9e`, 44 commits behind the reviewed native source. Before development, confirm the intended base and the existing native PR stack (#37–#42); do not assume default-branch behavior matches the review or merge that stack as a side effect of selecting a UX issue.

The review inspected native source and supplied recording samples. It did not run a live device/simulator session, new test suite, full accessibility audit, or performance benchmark. The private supplied video and personal account/payment frames are not included. Historical Photos-plan context and observation timestamps are preserved in the source register; temporary source snapshots are replaced by pinned repository links.

## One issue per recommendation

The 32 feature requests are the authoritative work records. Each contains current behavior, proposed interaction, benefit, immutable review rank, initial priority rationale, relative effort, evidence confidence, acceptance checklist, evaluation plan, implementation boundaries, prerequisite decisions, and related issues.

`UX-01` through `UX-32` are stable review identifiers. Do not renumber them when priorities change. Existing `enhancement` classification follows the repository's feature-request template. Do not duplicate these issues as separate feature requests, roadmap cards, or category epics.

### Globally ranked index

This table is a historical index. Its priority column is the **initial** execution band, not a live status or priority mirror. Read the issue labels for current priority and lifecycle.

| Original rank | Feature request | Category | Effort | Initial priority |
| --- | --- | --- | --- | --- |
| 1 | [UX-01 — Give the editor one zoomable, precise timeline](https://github.com/BakedChicken77/bjj-telestrator/issues/44) | Timeline & playback | Difficult | High |
| 2 | [UX-02 — Create a focused, unmistakable recording interface](https://github.com/BakedChicken77/bjj-telestrator/issues/45) | Narration & audio | Moderate | High |
| 3 | [UX-03 — Keep the video and playback available while editing a drawing](https://github.com/BakedChicken77/bjj-telestrator/issues/46) | Drawing & editing | Moderate | High |
| 4 | [UX-04 — Make take playback visible beside the video](https://github.com/BakedChicken77/bjj-telestrator/issues/47) | Narration & audio | Moderate | High |
| 5 | [UX-05 — Make repeated audio and undo adjustments feel immediate](https://github.com/BakedChicken77/bjj-telestrator/issues/48) | Import & responsiveness | Difficult | High |
| 6 | [UX-06 — Make every core workflow usable with larger text and assistive controls](https://github.com/BakedChicken77/bjj-telestrator/issues/49) | Accessibility | Difficult | High |
| 7 | [UX-07 — Explain original-video time and finished-review time consistently](https://github.com/BakedChicken77/bjj-telestrator/issues/50) | Timeline & playback | Moderate | High |
| 8 | [UX-08 — Add one-tap Continue review to the branded home](https://github.com/BakedChicken77/bjj-telestrator/issues/51) | Navigation & library | Easy | High |
| 9 | [UX-09 — Turn import into a clear, recoverable sequence](https://github.com/BakedChicken77/bjj-telestrator/issues/52) | Import & responsiveness | Moderate | High |
| 10 | [UX-10 — Support a natural freeze, draw, and explain workflow](https://github.com/BakedChicken77/bjj-telestrator/issues/53) | Narration & audio | Difficult | High |
| 11 | [UX-11 — Make narration pauses understandable and safe to edit](https://github.com/BakedChicken77/bjj-telestrator/issues/54) | Narration & audio | Moderate | High |
| 12 | [UX-12 — Make export a visual choice with sensible presets](https://github.com/BakedChicken77/bjj-telestrator/issues/55) | Export & sharing | Moderate | High |
| 13 | [UX-13 — Show save state and put Undo beside consequential actions](https://github.com/BakedChicken77/bjj-telestrator/issues/56) | Save & recovery | Easy | Medium |
| 14 | [UX-14 — Make looping a visible range rather than a menu sequence](https://github.com/BakedChicken77/bjj-telestrator/issues/57) | Timeline & playback | Moderate | Medium |
| 15 | [UX-15 — Expose the common drawing actions without menu hunting](https://github.com/BakedChicken77/bjj-telestrator/issues/58) | Drawing & editing | Moderate | Medium |
| 16 | [UX-16 — Remember simple drawing styles and duration choices](https://github.com/BakedChicken77/bjj-telestrator/issues/59) | Drawing & editing | Easy | Medium |
| 17 | [UX-17 — Make annotations readable against real footage](https://github.com/BakedChicken77/bjj-telestrator/issues/60) | Drawing & editing | Moderate | Medium |
| 18 | [UX-18 — Place and edit text directly where it belongs](https://github.com/BakedChicken77/bjj-telestrator/issues/61) | Drawing & editing | Moderate | Medium |
| 19 | [UX-19 — Expose storage and recovery tools in the native library](https://github.com/BakedChicken77/bjj-telestrator/issues/62) | Save & recovery | Moderate | Medium |
| 20 | [UX-20 — Teach the next useful action at the moment it matters](https://github.com/BakedChicken77/bjj-telestrator/issues/63) | Onboarding & help | Moderate | Medium |
| 21 | [UX-21 — Let users reopen and reshare completed exports](https://github.com/BakedChicken77/bjj-telestrator/issues/64) | Export & sharing | Moderate | Medium |
| 22 | [UX-22 — Make reviews easy to identify and their actions easy to find](https://github.com/BakedChicken77/bjj-telestrator/issues/65) | Navigation & library | Easy | Medium |
| 23 | [UX-23 — Add nondestructive take trimming and targeted rerecording](https://github.com/BakedChicken77/bjj-telestrator/issues/66) | Narration & audio | Difficult | Medium |
| 24 | [UX-24 — Add named moments for reviewing and sharing key sections](https://github.com/BakedChicken77/bjj-telestrator/issues/67) | Timeline & playback | Moderate | Medium |
| 25 | [UX-25 — Offer a simple voice-priority audio option](https://github.com/BakedChicken77/bjj-telestrator/issues/68) | Narration & audio | Moderate | Medium |
| 26 | [UX-26 — Expose named versions before substantial edits](https://github.com/BakedChicken77/bjj-telestrator/issues/69) | Save & recovery | Moderate | Medium |
| 27 | [UX-27 — Apply one coherent native visual system](https://github.com/BakedChicken77/bjj-telestrator/issues/70) | Visual design & feedback | Moderate | Low |
| 28 | [UX-28 — Consolidate diagnostics and make help match the installed app](https://github.com/BakedChicken77/bjj-telestrator/issues/71) | Onboarding & help | Easy | Low |
| 29 | [UX-29 — Use restrained feedback for important editing moments](https://github.com/BakedChicken77/bjj-telestrator/issues/72) | Visual design & feedback | Easy | Low |
| 30 | [UX-30 — Allow starting a review from the iPhone share sheet](https://github.com/BakedChicken77/bjj-telestrator/issues/73) | Navigation & library | Difficult | Low |
| 31 | [UX-31 — Offer editable captions for narrated reviews](https://github.com/BakedChicken77/bjj-telestrator/issues/74) | Accessibility | Difficult | Low |
| 32 | [UX-32 — Explore an optional reference-video comparison](https://github.com/BakedChicken77/bjj-telestrator/issues/75) | Video review | Difficult | Low |

### Category index

| Category | Recommendations in original rank order |
| --- | --- |
| Timeline & playback | [UX-01 / #44](https://github.com/BakedChicken77/bjj-telestrator/issues/44), [UX-07 / #50](https://github.com/BakedChicken77/bjj-telestrator/issues/50), [UX-14 / #57](https://github.com/BakedChicken77/bjj-telestrator/issues/57), [UX-24 / #67](https://github.com/BakedChicken77/bjj-telestrator/issues/67) |
| Narration & audio | [UX-02 / #45](https://github.com/BakedChicken77/bjj-telestrator/issues/45), [UX-04 / #47](https://github.com/BakedChicken77/bjj-telestrator/issues/47), [UX-10 / #53](https://github.com/BakedChicken77/bjj-telestrator/issues/53), [UX-11 / #54](https://github.com/BakedChicken77/bjj-telestrator/issues/54), [UX-23 / #66](https://github.com/BakedChicken77/bjj-telestrator/issues/66), [UX-25 / #68](https://github.com/BakedChicken77/bjj-telestrator/issues/68) |
| Drawing & editing | [UX-03 / #46](https://github.com/BakedChicken77/bjj-telestrator/issues/46), [UX-15 / #58](https://github.com/BakedChicken77/bjj-telestrator/issues/58), [UX-16 / #59](https://github.com/BakedChicken77/bjj-telestrator/issues/59), [UX-17 / #60](https://github.com/BakedChicken77/bjj-telestrator/issues/60), [UX-18 / #61](https://github.com/BakedChicken77/bjj-telestrator/issues/61) |
| Import & responsiveness | [UX-05 / #48](https://github.com/BakedChicken77/bjj-telestrator/issues/48), [UX-09 / #52](https://github.com/BakedChicken77/bjj-telestrator/issues/52) |
| Accessibility | [UX-06 / #49](https://github.com/BakedChicken77/bjj-telestrator/issues/49), [UX-31 / #74](https://github.com/BakedChicken77/bjj-telestrator/issues/74) |
| Navigation & library | [UX-08 / #51](https://github.com/BakedChicken77/bjj-telestrator/issues/51), [UX-22 / #65](https://github.com/BakedChicken77/bjj-telestrator/issues/65), [UX-30 / #73](https://github.com/BakedChicken77/bjj-telestrator/issues/73) |
| Export & sharing | [UX-12 / #55](https://github.com/BakedChicken77/bjj-telestrator/issues/55), [UX-21 / #64](https://github.com/BakedChicken77/bjj-telestrator/issues/64) |
| Save & recovery | [UX-13 / #56](https://github.com/BakedChicken77/bjj-telestrator/issues/56), [UX-19 / #62](https://github.com/BakedChicken77/bjj-telestrator/issues/62), [UX-26 / #69](https://github.com/BakedChicken77/bjj-telestrator/issues/69) |
| Onboarding & help | [UX-20 / #63](https://github.com/BakedChicken77/bjj-telestrator/issues/63), [UX-28 / #71](https://github.com/BakedChicken77/bjj-telestrator/issues/71) |
| Visual design & feedback | [UX-27 / #70](https://github.com/BakedChicken77/bjj-telestrator/issues/70), [UX-29 / #72](https://github.com/BakedChicken77/bjj-telestrator/issues/72) |
| Video review | [UX-32 / #75](https://github.com/BakedChicken77/bjj-telestrator/issues/75) |

## Prioritization and lightweight tracking

Use exactly one current `priority:*` label per recommendation:

| Label | Meaning at backlog creation |
| --- | --- |
| `priority:high` | Original ranks 1–12: core workflow and trust |
| `priority:medium` | Original ranks 13–26: productivity and confidence |
| `priority:low` | Original ranks 27–32: finishing work and optional expansion |

These bands are mutable planning choices, not a claim that every low-band item has low user value. Preserve original rank and rationale; change the priority label with a short issue comment explaining new evidence, dependency, user demand, or effort information. Within a band, original rank is the default tie-breaker until an explicit ordering decision is recorded.

Other labels:

| Label family | Purpose |
| --- | --- |
| `ux-review` | This review's tracker and feature requests |
| `enhancement` | Existing repository feature-request convention |
| `area:*` | One of the 11 categories; full original category remains in the issue |
| `effort:easy`, `effort:moderate`, `effort:difficult` | Relative implementation scope; update after investigation with rationale |
| `status:backlog` | Unselected proposal; applied to every recommendation initially |
| `scope:exploratory` | UX-30–UX-32 need explicit concept/feasibility selection before product implementation |

No duplicate status spreadsheet is required. GitHub issue state is authoritative for open/closed; a single `status:*` label describes open work. The tracking issue is a navigation/checklist summary, not a second specification.

### Selection and lifecycle

1. The owner explicitly selects an individual issue and records the approved scope in a comment. A developer or AI agent should not interpret ranking, a dependency link, or this guide as selection.
2. Replace `status:backlog` with `status:ready`; assign the selected developer/agent only then. Create a release milestone only when an actual release scope is chosen.
3. When work begins, use `status:in-progress`. Link the implementation branch/PR and confirm the native base, current behavior, design decisions, and validation plan before changing functionality.
4. Use `status:blocked` only for an actual unmet prerequisite, linking the blocker and the exact unblock condition. Use `status:review` when the implementation is ready for review.
5. Close as **completed** only after the selected scope and all remaining acceptance criteria are satisfied, with a linked implementation PR and validation evidence. If only a slice ships, keep this recommendation open and record what remains.
6. Remove open-work status labels on closure. Use **not planned** or **duplicate**, with rationale and a replacement link where relevant, for proposals not pursued. Do not mark them implemented. Update the tracker checklist as “resolved”; the issue's close reason preserves the distinction.

The later lifecycle labels are conventions to create when first needed; only Backlog is applied now. Do not mark work Done merely because research, a prototype, or this planning setup is complete. Reopen the original issue when acceptance fails instead of silently creating a duplicate.

### Splitting larger recommendations

Keep each original issue as the scope record. If an approved recommendation is too large for one implementation, create narrow child issues (native sub-issues when available) for independently testable slices and link them back. Record which original acceptance criteria each slice satisfies. Close the parent only when the full agreed scope is complete or explicitly revised by the owner, retaining deferred ideas as linked pending work.

## Quick wins and larger initiatives

**Six whole-recommendation quick wins:** [UX-08 / #51](https://github.com/BakedChicken77/bjj-telestrator/issues/51), [UX-13 / #56](https://github.com/BakedChicken77/bjj-telestrator/issues/56), [UX-16 / #59](https://github.com/BakedChicken77/bjj-telestrator/issues/59), [UX-22 / #65](https://github.com/BakedChicken77/bjj-telestrator/issues/65), [UX-28 / #71](https://github.com/BakedChicken77/bjj-telestrator/issues/71), [UX-29 / #72](https://github.com/BakedChicken77/bjj-telestrator/issues/72).

UX-02's recording layout/state wording and UX-07's clock labels/VoiceOver value are useful limited early slices. The full recommendations remain Moderate effort and must not be closed after those slices alone.

| Initiative | Related issues | Sequencing guidance |
| --- | --- | --- |
| Connected editor | [UX-01 / #44](https://github.com/BakedChicken77/bjj-telestrator/issues/44), [UX-03 / #46](https://github.com/BakedChicken77/bjj-telestrator/issues/46), [UX-07 / #50](https://github.com/BakedChicken77/bjj-telestrator/issues/50), [UX-14 / #57](https://github.com/BakedChicken77/bjj-telestrator/issues/57), [UX-15 / #58](https://github.com/BakedChicken77/bjj-telestrator/issues/58) | Agree clock semantics; reuse a shared video/transport; integrate loop handles with the common timeline. |
| Narration clarity and correction | [UX-02 / #45](https://github.com/BakedChicken77/bjj-telestrator/issues/45), [UX-04 / #47](https://github.com/BakedChicken77/bjj-telestrator/issues/47), [UX-05 / #48](https://github.com/BakedChicken77/bjj-telestrator/issues/48), [UX-11 / #54](https://github.com/BakedChicken77/bjj-telestrator/issues/54), [UX-23 / #66](https://github.com/BakedChicken77/bjj-telestrator/issues/66), [UX-25 / #68](https://github.com/BakedChicken77/bjj-telestrator/issues/68) | Improve visible states/preview; measure preparation latency; settle hold ownership before trimming/rerecording. |
| Save, import, and recovery confidence | [UX-09 / #52](https://github.com/BakedChicken77/bjj-telestrator/issues/52), [UX-13 / #56](https://github.com/BakedChicken77/bjj-telestrator/issues/56), [UX-19 / #62](https://github.com/BakedChicken77/bjj-telestrator/issues/62), [UX-21 / #64](https://github.com/BakedChicken77/bjj-telestrator/issues/64), [UX-26 / #69](https://github.com/BakedChicken77/bjj-telestrator/issues/69) | Reuse existing service safeguards and a shared Review details entry point. |
| Creative coaching | [UX-10 / #53](https://github.com/BakedChicken77/bjj-telestrator/issues/53), [UX-24 / #67](https://github.com/BakedChicken77/bjj-telestrator/issues/67) | Prototype freeze/draw/explain; define time contracts before persisting new interactions. |
| Optional expansion | [UX-30 / #73](https://github.com/BakedChicken77/bjj-telestrator/issues/73), [UX-31 / #74](https://github.com/BakedChicken77/bjj-telestrator/issues/74), [UX-32 / #75](https://github.com/BakedChicken77/bjj-telestrator/issues/75) | Select discovery/feasibility separately; no automatic implementation commitment. |

Accessibility (UX-06) and visual consistency (UX-27) are cross-cutting acceptance concerns, not blanket blockers that force every other issue to wait.

### Dependency semantics

The issue section **Prerequisite decisions / integration** names the required contract or shared component. It is deliberately more precise than “finish issue X first.” For example, UX-01 needs UX-07's time/hold contract, but not necessarily its entire saved-position implementation. UX-14 should reuse UX-01's timeline surface rather than independently inventing another one.

**Coordinate with** links indicate related design/code and are not blockers. Agree an interface or record a decision when parallel implementation is safe. The links are normal GitHub cross-references, not native blocking/sub-issue relationships; no automated blocking is implied. If native dependencies are later added, use them only for genuine whole-issue delivery blockers and avoid cycles.

## Suggested GitHub views

- [All open UX work](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20is%3Aopen%20label%3Aux-review)
- [High-priority backlog](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20is%3Aopen%20label%3Aux-review%20label%3Apriority%3Ahigh%20label%3Astatus%3Abacklog)
- [Easy-effort quick wins](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20is%3Aopen%20label%3Aux-review%20label%3Aeffort%3Aeasy)
- [Narration](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20label%3Aux-review%20label%3Aarea%3Anarration)
- [Resolved UX issues](https://github.com/BakedChicken77/bjj-telestrator/issues?q=is%3Aissue%20is%3Aclosed%20label%3Aux-review)

A GitHub Projects board was **not created**: the connected operations do not expose Projects management, and the browser session was signed out. The working issue-based backlog is complete and does not depend on a board. If Projects access becomes available, add the existing 32 issues to one board with Backlog / Ready / In progress / In review / Done views; do not create duplicate draft cards. Use labels and issue state as authoritative, or explicitly migrate authority before adding duplicate custom fields. Native sub-issues/blocking links were likewise not created.

## Repository and development safeguards

Follow [CONTRIBUTING.md](../../CONTRIBUTING.md). The native entry point is SwiftUI/UIKit; legacy web workflows must not be confused with the reviewed iPhone app. Preserve original assets, atomic persistence, normalized geometry, source-time annotation meaning, held-frame timing, preview/export agreement, compatibility, and one completed gesture per undoable edit where relevant. Keep all core capabilities free and tips optional.

This documentation lives on `docs/ux-backlog-2026-10` in a documentation-only draft PR. The commit includes `[skip ci]` because the owner explicitly requested no builds or releases. `main` requires the CI gate, so this task does not bypass protection or merge with missing checks. The archive is already committed and all issues link to this branch. Retain the branch until the documentation PR is merged under an appropriate later authorization; then update navigation links to `main` if desired.

No application source, project configuration, CI workflow, build number, release tag, or existing implementation PR is changed by this setup.

