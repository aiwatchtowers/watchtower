# Target Brief Chat — chat-first target creation + secretary directives

**Date:** 2026-08-19
**Status:** Approved by owner (chat design session), implementation pending
**Owner decisions baked in:** autonomous apply (no approve gate for directives), full write access to the target subtree, one-shot instruction (no stored instruction column, no re-runs), chat-first creation composer, ⌘Enter silent-create escape hatch.

## 1. Problem

Target creation today is a form (`CreateTargetSheet`): title, optional intent ("Add context"), checklist, level. The `intent` field is passive free text injected into downstream prompts (next step, day plan, briefing). The owner wants the opposite: creation as a **briefing to the secretary** — "here's the task, go decompose it, walk the meeting transcripts, gather the synced Jira/Slack data" — with the secretary doing the work instead of the user filling fields.

## 2. Philosophy: secretary, not assistant (TGT-BRIEF-01)

The feature stays inside the project's secretary contract. The line between secretary and assistant runs along three axes, all three preserved:

1. **Intent origin** — every action derives from an explicit owner message. The secretary never originates goals.
2. **Timing** — the secretary acts only in direct response to an owner message. It never initiates chat turns and never mutates the target between owner messages (no daemon re-runs; the instruction is one-shot).
3. **Artifact ownership** — pipelines stay free to write the secretary's own notebook (situations, digests, ideas). The owner's artifacts (targets) are written only under an explicit directive, and only within the mandate.

**Mandate rule ("broad powers, narrow mandate"):** within a directive the secretary may modify the target and its subtree in any way (title, intent, priority, due, status, notes, sub-items, child targets) — but only what the directive implies. Findings beyond the mandate (adjacent tasks discovered in transcripts, other teams' blockers) go into the chat reply as text, never into actions. Creating work items **outside the target's subtree is forbidden**; the secretary reports the finding and the owner's follow-up message ("да, заведи") is a new directive.

## 3. Chat modes: discussion vs directive

The target Discuss chat gains two modes, switched by the *form of the owner's message*, judged by the model:

- **Discussion** ("что думаешь?", "что известно про X?") — the secretary answers, informs, may *propose* actions. Proposals ride the existing `watchtower-action` fenced-JSON contract and require the existing Approve gate. Unchanged behavior.
- **Directive** (imperative: "разбей на шаги", "поставь дедлайн пятница", "собери данные из Jira") — the secretary executes: emits action blocks marked for auto-apply, the app applies them immediately, the reply reports what was done ("Готово: 4 саб-таргета, дедлайн проставлен").

Ambiguity resolves toward discussion (propose, don't apply). Mechanically: each action block gains an optional `"mode"` field, `"propose"` (default when absent — backward compatible, safe) or `"execute"`. The system prompt teaches the model when each is appropriate and states the mandate rule verbatim.

## 4. Chat-first creation

"New target" opens a **composer**, not a form: one multiline text field, a permanent hint line under it, and nothing else.

- **Enter (primary):** the target row is created **mechanically, instantly, locally** — provisional title = first line/sentence of the text, `source_type='manual'`. No AI involvement in row creation (offline-safe; an unreachable AI CLI can never block creating a target). Then the target's Discuss chat opens with the full composer text auto-sent as the first owner message. The secretary treats it as a directive: derives a clean title from the owner's own text (materialization, not initiative), decomposes into sub-items / child targets, gathers context via MCP tools (Jira task context, message/transcript search), fills `intent`, sets priority/due when instructed or clearly implied by the directive.
- **⌘Enter (silent create):** the row is created the same mechanical way; no chat message, no AI call. For trivial targets ("купить билеты").
- **Discoverability:** permanent caption under the field: `Enter — поручить секретарю · ⌘Enter — просто создать` (English in the actual UI: "Enter — brief the secretary · ⌘Enter — just create"), plus a placeholder describing the pattern. Not a transient tooltip.
- **Conversions** (situation/idea/track → target) reuse the composer, prefilled with the source's text; `source_type`/`source_id` wiring unchanged.
- The old form fields (intent editor, checklist builder, level picker, "Add context") are removed from the sheet. Manual precision editing lives where it already lives: the target detail view.

`targets.intent` column and all its downstream prompt readers are unchanged; the UI field dies, the secretary populates the column via an `update_intent` action.

## 5. Action contract extension

`ProposedAction` (Swift) and the Go-side prompt contract gain:

- New kinds: `update_title`, `update_priority`, `update_due`, `update_intent`.
- New optional field `mode: "propose" | "execute"` on every action (absent ⇒ propose).
- Existing kinds (`update_status`, `update_notes`, `update_progress`, `add_sub_item`, `create_child_target`, `link_target`) accept `mode` too.

Apply-side: execute-mode actions are validated and applied by the same Swift apply path the Approve button uses today (single writer, no new dual path); the chat transcript shows applied actions as done-chips rather than pending proposals.

## 6. Run lifecycle & surviving state

The creation-time brief run must survive navigation (house rule): the send + streaming + apply live on state owned above the view (AppState-held VM or a small center, per the existing house pattern — exact vehicle decided in §9 after code recon). Closing the app mid-run aborts the run; the instruction survives as a persisted chat message, so the owner re-asks in the chat. Target detail shows a working indicator while the run streams.

## 7. Failure modes

- AI CLI unavailable / errors: the target row already exists (mechanical create); the chat shows the error like any chat error; no partial invented state.
- Malformed action JSON: existing parser behavior (surfaced as errors, skipped) — an execute-mode malformed block is *not* applied.
- Action validation failure (unknown target id, out-of-subtree write): rejected at apply, reported in the chat UI.

## 8. Out of scope (v1)

- Stored/re-runnable instructions, daemon re-execution (explicitly rejected — assistant territory).
- Secretary-created targets outside the subtree.
- Any Go-side write path for actions (Swift stays the single apply writer).
- Changes to next-step/day-plan/briefing pipelines (they keep reading `intent`).

## 9. Technical design (from code recon)

**Go is untouched.** The entire action contract is Desktop-side: the system prompt (`TargetChatViewModel.taskActionsContract`), the parser (`TargetActionParser`), the model (`ProposedAction`), the apply seam (`TargetActionExecutor`), and the DB writes (`TargetQueries` / `TargetsViewModel` mutators). Go's `internal/ai` is a dumb streaming pipe. The Go track-watcher grammar (`internal/prompts/defaults.go`, `defaultTrackRun`) stays a strict subset of the chat grammar — new kinds are emitted only by the chat, and `TargetActionExecutor` stays backward compatible, so no grammar drift.

### 9.1 Action model (`WatchtowerCore/Models/ProposedAction.swift`)
- `TargetActionKind` gains `update_title`, `update_priority`, `update_due`, `update_intent`.
- New optional `mode: String?` field, decoded leniently; helper `var isExecute: Bool { mode == "execute" }`. Absent/unknown ⇒ propose (backward compatible with old track_events rows and old model output).
- `validate()` extends per kind: `update_title`/`update_intent` require non-empty `text`; `update_priority` requires an allowed priority; `update_due` requires `text` parseable as `YYYY-MM-DD` (reuse the sub-item due-date convention).
- `cardDescription` + `TargetChatView.icon` gain the four kinds.

### 9.2 Contract rewrite (`TargetChatViewModel.taskActionsContract`)
The constant is rewritten (stays a constant — one contract teaches both modes):
- documents the four new kinds and the `"mode"` field;
- **directive vs discussion rule:** when the owner's message is an explicit instruction, emit actions with `"mode":"execute"` — they are applied immediately, and the reply reports what was done; when the owner is discussing/thinking, emit `"mode":"propose"` (or omit) — cards await approval. Ambiguity ⇒ propose.
- **mandate rule (TGT-BRIEF-01) verbatim:** only this target and its subtree; only what the directive implies; findings beyond the mandate go into prose, never actions; never initiate actions the owner didn't ask for.
- The current "never claim it was created / STOP and wait" lines become propose-mode-only wording.

### 9.3 Auto-apply (`TargetChatViewModel.executeStream` post-parse)
Parsing already happens only after a successful stream. New branch: for each parsed action with `isExecute`, run the same resolved-apply path `approve` uses (`reloadTarget` → `TargetActionExecutor.apply` → `reloadTarget`), mark the card `.applied(summary)` (rendered as a done-chip, not a pending card). **No per-action follow-up AI turn** (unlike `approve`, whose "Action applied…" follow-up would spawn N extra turns): instead one persisted `system` chat message summarizing applied actions ("Applied: set due date…, created 3 sub-items"). Apply failures mark the card `.failed` and are reported in the same system message. Propose-mode actions keep today's behavior byte-for-byte.

### 9.4 New write mutators
`TargetQueries` gains `updateText`, `updateIntent`, `updateDueDate` (updatePriority exists); `TargetsViewModel` gains matching mutators following the existing errorMessage-snapshot convention consumed by `TargetActionExecutor`.

### 9.5 Composer (replaces the form in `CreateTargetSheet`)
- UI: one multiline editor (ChatInput-style key handling: **Enter = brief the secretary, ⌘Enter = just create, Shift+Enter = newline**), a permanent caption "Enter — brief the secretary · ⌘Enter — just create", the existing Extract affordance kept as a secondary control (it already consumes free text), and an error row. Title field, intent editor, checklist builder, level/period pickers, "Add context" are removed.
- Submit logic lives in a testable Core type `TargetComposerLogic` (the sheet has no tests today; new logic must not accrete on the View): provisional title = first non-empty line, trimmed, hard-capped; body = full text.
- Both paths create the row **mechanically** via the existing `TargetQueries.create` (level "day" for top-level rows; a sub-target with `parentID` inherits the parent's level/period, mirroring `TargetsViewModel.createChild`; `source_type` per prefill or "manual", `secondaryLinks` honored). ⌘Enter stops there. Enter additionally hands off to `TargetBriefCenter` (§9.6) and navigates to the new target's detail with the Assistant tab active.
- Conversion call sites (Dashboard/Track/Briefing/Digest via `TargetPrefillBuilder`, "Add sub-target" in `TargetDetailView`) keep their `TargetPrefill` wiring — prefill text+intent become the composer's initial text; `onCreated` hooks unchanged. `TargetPrefill` itself is not extended (level/priority now belong to the secretary).

### 9.6 `TargetBriefCenter` (new, house center pattern)
`@MainActor @Observable` center on `AppState` (the `TargetExtractCenter` shape: Phase enum idle/briefing(targetID:)/failed, owned `task`, DB wiring via injected closures after pool open). On brief: fetches the created `Target`, constructs a `TargetChatViewModel`, sends the composer text as the first owner message, holds the VM until the run (stream + auto-apply) finishes. `TargetDetailView` adopts the center's VM for that target id instead of creating its own `@State` copy (avoids two VMs racing one conversation); on run completion the center releases and the detail view owns chat as today. Closing the app mid-run aborts the stream; the persisted user message survives, the owner re-asks in chat.

### 9.7 Tests
- Core: `ProposedActionTests` (new kinds, mode leniency, validation), `TargetActionParserTests` (mode passthrough), new `TargetComposerLogicTests` (title derivation, submit routing).
- App: `TargetChatViewModelTests` — contract prompt includes mode + mandate wording; execute-mode auto-applies without follow-up turn and appends the summary system message; propose-mode unchanged; malformed execute block not applied. `TargetActionExecutorTests` — one test per new kind asserting the DB row. `TargetBriefCenterTests` — «начал → ушёл → вернулся» + failure phase.
- Existing guard to respect: INBOX-02 dual-path cascade in `TargetQueries.updateStatus` (untouched).

### 9.8 Docs
New `docs/inventory/targets.md` with TGT-BRIEF-01 (secretary/assistant line: intent origin, timing, artifact mandate) and TGT-BRIEF-02 (mechanical instant creation — AI can never gate row creation). CLAUDE.md feature note; `docs/app-guide.md` updated for the composer.
