# Behavior Inventory — Targets (brief chat + creation)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in
> `WatchtowerDesktop/Sources/Views/Targets/`,
> `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift`,
> `WatchtowerDesktop/Sources/Services/TargetActionExecutor.swift`,
> `WatchtowerDesktop/Sources/WatchtowerCore/` (ProposedAction /
> TargetActionParser / TargetComposerLogic / TargetQueries), or the
> Go track-watcher grammar (`internal/prompts/defaults.go`,
> `defaultTrackRun`), read this file first. Any proposed change that
> would break a guard test or remove a contract must be raised as a
> question before touching code.

**Module:** `WatchtowerDesktop/Sources/Views/Targets/` (composer + detail + chat) + `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift` + `WatchtowerDesktop/Sources/Services/{TargetActionExecutor,TargetBriefCenter}.swift` + `WatchtowerDesktop/Sources/WatchtowerCore/` (`Models/ProposedAction.swift`, `Services/TargetActionParser.swift`, `TargetComposerLogic`, `Database/Queries/TargetQueries.swift`)
**Last full audit:** 2026-08-19

## TGT-BRIEF-01 — Directive-bound, never autonomous

**Status:** Enforced

**Observable:** The target brief chat keeps the assistant directive-bound — never autonomous — along three axes:

1. **Intent origin** — every action the assistant takes derives from an explicit owner message. The assistant never originates goals; even the clean title it derives at creation time is a materialization of the owner's own composer text, not initiative.
2. **Timing** — the assistant acts only in direct response to an owner message. It never initiates chat turns, never mutates the target between owner messages, and there are no scheduled or daemon-driven re-runs — the instruction is one-shot (no stored instruction column exists).
3. **Artifact mandate ("broad powers, narrow mandate")** — within a directive the assistant may modify the target's **vertical line** in any way the directive implies (title, intent, priority, due, status, notes, labels, sub-items, child targets): the target itself, its sub-tasks at any depth, and its parent chain. Findings beyond the mandate — sibling branches, adjacent tasks discovered in transcripts, other teams' blockers — go into the chat reply as prose, never into actions. Creating work items outside the target's vertical line is forbidden: the assistant reports the finding, and the owner's follow-up message is a new directive.

The mandate rule is stated in the chat system prompt (`TargetChatViewModel.taskActionsContract`). Mechanically, the boundary is enforced **at apply**: every action except `link_target` may carry an optional `target_id` naming the task it writes to (omitted = the chat's own target), and `TargetChatViewModel.resolveActionTarget` rejects the card unless `TargetTreeScope.isInScope` puts that id on the current target's vertical line — a sibling branch or an unrelated task can never be written, and an id absent from the targets table is out of scope by construction. `create_child_target`'s `target_id` is the parent the new sub-task is created under. The one action whose `target_id` is not a write-target, `link_target`, adds a link row owned by the current target (it never mutates the other target) and is validated at apply: the linked target must exist and must not be the target itself; an invalid link is rejected and reported in the chat UI. Widening `TargetTreeScope` past the vertical line — to siblings, to an arbitrary id, to the whole table — would break this contract and needs owner approval.

**Why locked:** This is the philosophical line of the whole product (spec §2): pipelines write the assistant's own notebook (situations, digests, ideas), but the owner's artifacts (targets) are written only under an explicit directive and only within its mandate. Weakening any axis — background re-runs, unsolicited mutations, out-of-mandate writes — silently turns a directive-bound assistant into an autonomous agent the owner never agreed to.

**Test guards:**
- `WatchtowerDesktop/Tests/TargetChatViewModelTests.swift` (contract prompt contains the mode field + mandate wording; no follow-up AI turns after auto-apply; an addressed action outside the vertical line fails its card)
- `WatchtowerDesktop/Tests/TargetActionExecutorTests.swift` (`testApplyLinkTargetRejectsSelfLink`, `testApplyLinkTargetRejectsUnknownTarget` — the action whose `target_id` is not a write-target is validated at apply)
- `WatchtowerDesktop/Tests/Core/TargetTreeScopeTests.swift` (the vertical-line predicate itself: self, descendants and ancestors in scope; siblings, unrelated and unknown ids out; parent-cycle safety)

**Locked since:** 2026-08-19

## TGT-BRIEF-02 — Mechanical instant creation

**Status:** Enforced

**Observable:** Submitting the creation composer (Enter or ⌘Enter alike) always creates the target row **locally and synchronously, with no AI involvement**: provisional title = first non-empty line of the composer text (`TargetComposerLogic`), written via the existing `TargetQueries.create`. AI unavailability — an unreachable or erroring AI CLI — can never block or delay creating a target: on Enter the brief hand-off (`TargetBriefCenter`) happens only *after* the row exists, and a failed brief run leaves the already-created row plus a visible chat error, with no partial invented state.

**Why locked:** Target creation is the owner capturing their own intent; making it depend on a model call would turn an offline-safe local write into a network/CLI-availability gamble. The row-first ordering is also what makes every failure mode in spec §7 recoverable — the instruction survives as a persisted chat message on a target that already exists.

**Test guards:**
- `WatchtowerDesktop/Tests/TargetComposerLogicTests.swift` (provisional-title derivation — the mechanical-create input)
- `WatchtowerDesktop/Tests/TargetBriefCenterTests.swift` (failure phase leaves the created row; run survives navigation)

The Enter/⌘Enter → `TargetQueries.create` routing itself lives in the view layer (`CreateTargetSheet.submit`) and has no direct unit test (house convention: views are not unit-tested); the row-first ordering is code-review-guarded — keep the `TargetQueries.create` call ahead of any `TargetBriefCenter` hand-off.

**Locked since:** 2026-08-19

## TGT-BRIEF-03 — Propose is the default

**Status:** Enforced

**Observable:** A `watchtower-action` block without `"mode":"execute"` — mode absent, `"propose"`, or any unknown value — is **never auto-applied**: it renders as a pending proposal card behind the existing Approve gate, byte-for-byte today's behavior. Execute mode is further scoped to the chat's **own** target: an action carrying a `target_id` naming another task on the vertical line stays a pending card however the model marked it (`ProposedAction.autoApplies(inChatFor:)`), so the owner approves every write that leaves the target they are looking at. `link_target` is exempt from that narrowing — its `target_id` names the link partner, not a write target. Execute mode exists **only** in the Desktop target chat (`TargetChatViewModel` parse → `TargetActionExecutor` apply, the same single Swift writer the Approve button uses); the Go track-watcher grammar (`internal/prompts/defaults.go`, `defaultTrackRun`) stays a propose-only subset — it is never taught `"mode"` or the Desktop-only kinds (update_title/priority/due/intent from the brief-chat feature, add_label/remove_label from 2026-08-24), so old `track_events` rows and old model output decode as propose. A malformed execute-mode block is surfaced as an error and skipped, never applied.

**Why locked:** Auto-apply is safe only because ambiguity resolves toward proposing — the lenient default is the safety net that makes the owner's Approve gate the fallback for everything the model didn't explicitly mark as a directive execution. If absent-mode ever defaulted to execute, or a second (Go-side) writer gained execute powers, every historical action block and every watcher-emitted event would become an unreviewed write to the owner's artifacts.

**Test guards:**
- `WatchtowerDesktop/Tests/Core/ProposedActionTests.swift` (mode leniency: absent/unknown ⇒ propose; an execute-mode action addressing another target does not auto-apply)
- `WatchtowerDesktop/Tests/TargetActionParserTests.swift` (mode passthrough)
- `WatchtowerDesktop/Tests/TargetChatViewModelTests.swift` (propose-mode unchanged; malformed execute block not applied)

**Locked since:** 2026-08-19

## Changelog

- 2026-08-24: grammar widened with two Desktop-only kinds, `add_label`/`remove_label` (assistant-managed target labels). No contract semantics changed: both ride the standard propose→Approve path, execute mode auto-applies them only on the chat's own target via the unchanged `autoApplies` default (TGT-BRIEF-03), and the Go track-watcher grammar is still not taught them. TGT-BRIEF-03's Observable reworded from "the four new kinds" to "the Desktop-only kinds", and `labels` added to TGT-BRIEF-01's mandate field list (mirrored in the system prompt's MANDATE paragraph), to stay accurate.
- 2026-08-19: persona merge (owner decision 2026-08-19): the two-persona concept (secretary/assistant) is collapsed into a single **assistant** — wording-only here; no contract semantics, guard tests, or gates changed. Historical changelog entries keep the old word. See "The assistant & chat contracts" in `docs/review/review-rules.md`.
- 2026-08-19: TGT-BRIEF-01 mandate widened from "the target and its subtree" to the target's **vertical line** (self + descendants + parent chain), and the mechanism restated: the boundary no longer holds by construction of the grammar but is enforced at apply by `TargetTreeScope.isInScope`, since every action except `link_target` now accepts an optional `target_id`. Owner-approved on 2026-08-19 during the review of the target chat-tabs branch; the corresponding narrowing landed on TGT-BRIEF-03 in the same change — an action addressing another target never auto-applies, so widening the *reach* of the grammar did not widen what happens without an Approve.
- 2026-08-19: file created with 3 contracts (TGT-BRIEF-01..03), all Enforced. Introduced by the target brief chat feature (spec `docs/superpowers/specs/2026-08-19-target-brief-chat-design.md`), which replaces the Create Target form with a brief-the-secretary composer and gives the target Discuss chat an execute mode for directives. The INBOX-02 dual-path status cascade in `TargetQueries.updateStatus` (see `docs/inventory/inbox-pulse.md`) is untouched by this feature.
