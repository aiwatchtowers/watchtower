# Agent instructions — session instructions, target procedure, repeat suggestions (2026-10-17)

Spec: `docs/superpowers/specs/2026-10-17-agent-instructions-design.md`. Owner decisions in asks #270–#272, #320–#322, #327. Contract: PROJ-22 in `docs/inventory/workbench.md`; DEV-06 gained the additive `procedure` key.

## Summary

The owner's own standing directions for the agents working in a workbench, as plain text in two fields, each with a global value and a per-workbench addition:

- **Session instructions** reach the agent in the brief of every new workbench session (Claude Code and Codex).
- **Target procedure** reaches the agent in the result of `update_target` each time it sets a target `in_progress`.

A daily phase reads the owner's lines in recent session feeds and proposes directions the owner keeps repeating. The model only proposes; only the owner's Add changes text. The agent has no tool to read or change these texts, and nothing lands in the workbench folder.

## Storage

Migration `00137_agent_instructions.sql`, mirrored in `schema.sql`; Go access in `internal/db/instructions.go`.

- `owner_instructions(scope 'session'|'procedure' PRIMARY KEY, body, updated_at)` — the global texts.
- `projects.session_instructions`, `projects.target_procedure` — nullable per-workbench texts.
- `instruction_suggestions` — `text`, `field`, `workbench_id` (NULL = global), `session_count`, `workbench_count`, `first_seen_at`, `last_seen_at`, `status` open|added|dismissed, `fingerprint` UNIQUE, `decided_at`.

## Rendering — `internal/instructions`

One package owns validation and rendering, so the brief, `update_target` and Preview share the code.

- `MaxRunes` = 1000 per text (global/workbench × session/procedure), surrounding space not counted; `Validate` returns `ErrTooLong`. `AppendLine` (used by Add) refuses a result over the limit.
- `BriefSlot(Texts)`: `Owner's instructions (follow in every turn):`, the global text, then `For this workbench:` and the workbench text (the second header only when that text is non-empty). When any procedure text exists it adds one pointer line (`Target procedure: update_target returns it when a target goes in_progress.`). Empty when there is nothing.
- `Procedure(Texts, targetID)`: `Owner's target procedure — follow it for #<id>:` plus the same two parts; empty when both procedure texts are empty.
- `SlotMaxRunes` is the slot's size for maximal texts (the most the brief cap grows by).

## The brief — `cmd/workbench_brief.go`

`renderSessionBrief` and the Codex path (`runCodexBrief`) both place the slot after the board rules and the folder rules. The cap is `briefMaxCharsFor(slot)` = 4000 + the rendered slot's size (plus its joining newline; 4000 with no slot), so the board, comments and asks keep exactly the room they had; the slot is inline in full, never cut to a pointer. Texts are read when the brief is built: an edit applies from the next new session. They are the owner's words, injected as instructions on purpose, not fenced as data.

## Taking a target — `internal/tools/workbench_targets.go`

`update_target` adds `procedure` to its result on every call whose `status` argument is `in_progress` (including a target already `in_progress`, and a `column` move into an `in_progress` column, which sets the status); never for another status or none, and not when both texts are empty. Read at call time, so an edit applies from the next target even in a running session. Groups count. `create_targets` has no status argument and never returns it. Status changes by Desktop drag or phone deliver nothing by themselves.

## CLI — `cmd/instructions.go`

Every write (Settings, Agent Settings, Add and Dismiss from Settings or Home) goes through `watchtower instructions`:

- `show [--workbench N] --json` — pinned keys `ok`, `limit`, `global{session,procedure}`, `workbench{id,session,procedure}` (null without `--workbench`), `suggestions[]` (`id`, `text`, `field`, `workbench_id`, `session_count`, `workbench_count`, `first_seen_at`, `last_seen_at`).
- `set --field session|procedure [--workbench N] --stdin` — the text comes on stdin, never argv; empty clears it.
- `preview [--workbench N] --json` — `ok`, `brief_slot`, `procedure`; the Preview sheet shows this, so Swift holds no copy of the format.
- `suggestion add|dismiss <id>` — Add appends the line to the right text (a suggestion from one workbench writes that workbench's addition) and marks it `added` in one transaction; Dismiss marks it `dismissed` for good.

A failure with `--json` prints `{"ok":false,"error":…}` and exits non-zero.

## Suggestions — `internal/instructions/suggest.go`, `internal/daemon/instruction_suggestions.go`

`phaseInstructionSuggestions` runs once per calendar day (stamp `<workspace>/last_instruction_suggestions.txt`, written after every run, a failed one included, so a failure is retried next day and clears nothing). `planusage.NearLimit` skips the run; the model call runs outside any write transaction. The generator is stdin-only (owner text is never on argv).

1. **Input:** the owner entries (`KindOwner` only: no ask answers, briefs or Watchtower lines) of every workbench terminal session of the last 14 days, both agents, read through `sessionfeed` (`NewFeedReader`). Long entries are truncated, pasted blocks skipped, and the app-typed start prompts (`Work on target #…` / `Work on group #…`, with the phone's `Plan first:` line after one) dropped.
2. **Model:** prompt id `instructions.suggest`, light tier (`TierLight`), runs on the claude and codex providers. It gets the owner lines grouped by session, the four current texts and the open and dismissed suggestions, and returns standing directions, each with `field` and session ids.
3. **Validation in Go:** session ids must exist in the input; distinct sessions are recomputed and must be at least 3 (`minSuggestSessions`); the scope is the one workbench when all sessions belong to it, else global; lines over 200 runes are dropped.
4. **Upsert** by `Fingerprint` (normalised text): new -> `open`; open -> text, field, scope, counts and `last_seen_at` refreshed; `added` and `dismissed` untouched, so that suggestion (that fingerprint) never comes back. A reworded repeat has a new fingerprint and is held back only by the prompt, which sees the dismissed suggestions.
5. **Caps:** at most 5 open per field and scope are shown; the rest stay in the table.

## Codex reader — `internal/sessionfeed/codex.go`

`ParseCodex` and `LocateCodex` read Codex rollouts into the same agent-neutral entries as Claude's, so the miner sees both agents and the session chat feed gains Codex support (see [session-chat-feed.md](session-chat-feed.md)). `sessionfeed.SessionConversations` moved there from `cmd`.

## Desktop

- `OwnerInstructions` (WatchtowerCore) — the decoded `show --json` state; `WorkbenchesViewModel` instruction methods call the CLI.
- Settings -> System -> Workbench: `InstructionsSettingsSection` with a `InstructionFieldBlock` per field (counter `n / limit`, its own **Save**, enabled while the text differs), the yellow **You keep saying this — N suggestions** block with **Add** / **Dismiss** (Add off while the field has an unsaved edit, `OwnerInstructionsState.hasUnsavedEdit`, hint "Save or revert your edit first"), and **Preview what the agent gets…** (`InstructionsPreviewSheet`, **What the agent gets**).
- Workbench **…** -> **Agent Settings…**: the section **Your instructions — this workbench**, global text collapsed with **Edit in Settings**, then the workbench's own field. The `workflow.md` row stays and is the team's folder rules.
- Home: Today shows one card for the newest open suggestion first seen in the last 7 days — **Add**, **Dismiss**, **More…** (opens Settings at the field). A successful Add/Dismiss re-reads Home at once (`HomeCenter.rereadNow`: the CLI writes from another process, which the observation misses). It leaves once acted on or at 7 days; older open suggestions stay in Settings only. It follows the Today card conventions (a failed read is not an all-clear).

## Limits

- No per-target texts, variables, structured rule list, "remember this" capture or phone sync.
- Edits reach running sessions only through `procedure`; their brief keeps the text they started with.
- Suggestions need at least 3 sessions in 14 days; a quiet owner sees none.

## Tests

PROJ-22 guards: `cmd/workbench_brief_instructions_test.go`, `internal/tools/workbench_targets_procedure_test.go`; `internal/instructions/*_test.go`; `internal/daemon` phase tests; Desktop `OwnerInstructionsStateTests`, `WorkbenchCLIInstructionsTests`, `WorkbenchInstructionsViewModelTests`.
