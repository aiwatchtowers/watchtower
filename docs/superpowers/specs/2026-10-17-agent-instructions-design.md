# Agent instructions — session instructions, target procedure, repeat suggestions

**Date:** 2026-10-17 · **Status:** design, owner-approved in asks #270–#272, #320–#322, #327 · **Mockup:** https://claude.ai/artifact/T3X8DTm8XF9ssh13Pu5Zoy

## Why

The owner keeps typing the same directions into new workbench sessions ("talk to me in Russian", "never build in the background", "test only the touched package") and wants one standing procedure for working any target (read the target first, ask when unclear, what "done" means). Today the only home for that is `.watchtower/workflow.md`, which is the team's committed file, not the owner's own words, and is invisible unless opened.

Claude's own memory already covers "remember this" inside a session, so Watchtower does not build that again (owner, ask #320/#321). What memory cannot do, and what this feature adds:

1. **One owner text for both agents** (Claude Code and Codex), visible and editable in the app.
2. **A target procedure delivered at the moment it matters** — when the agent takes a target into work — which a session-start memory cannot time.
3. **Suggestions from repetition**: Watchtower reads every session's feed, of both agents, and notices directions the owner keeps repeating that the text does not yet hold.

## Goals

- Two plain-text fields, each with a global value and a per-workbench addition:
  - **Session instructions** — reach the agent in the brief of every new workbench session.
  - **Target procedure** — reaches the agent each time it moves a target to `in_progress`.
- Daily suggestions mined from the owner's own repeated words in session feeds, offered with Add / Dismiss.
- Works the same for Claude Code and Codex sessions.

## Non-goals

- No "remember this" capture in a session (Claude memory does it).
- No per-target instructions, role templates, variables such as `{target.id}`.
- Nothing on the board or the target panel.
- No structured rule list — the owner chose text (ask #320).
- No sync of these texts to the phone.

## Anti-goals (a failure even if it works)

- An interface that feels heavier: the settings gain two fields and one quiet suggestion block, nothing else.
- A suggestion engine that edits text by itself. The model only proposes; only the owner's Add changes text.
- Suggestions that nag: a dismissed suggestion never comes back; at most a handful are shown at once.
- Owner text that leaks into the repository (it is personal; it never lands in the folder).

## What the owner sees

### Settings → System → Workbench (mockup screen 1)

Under the existing **Default agent** row, two labelled text areas:

- **Session instructions** — "Every new session in any workbench starts with these. Workbenches can add their own." Rune counter `n / limit`.
- **Target procedure** — "How to work any target. The agent gets it each time it moves a target to In progress." Rune counter.

Below the Session instructions field, only while there are open global suggestions, a yellow block **"You keep saying this — N suggestions"**: one row per suggestion with the quoted direction, "· K sessions, M workbenches", **Add** and **Dismiss**. A suggestion whose repeats come from one workbench reads "only <workbench> → adds to that workbench" and its Add writes the workbench addition. Suggestions classified as procedure steps show under the Target procedure field the same way.

A link **Preview what the agent gets…** opens a read-only sheet with the exact text the agent receives (screen 3).

Each field saves through the CLI with its own **Save** button, enabled while the text differs from the stored one (*my call*: the System pane's `ConfigSaveBar` saves `config.yaml`, which these texts are not in).

### Workbench ⋯ → Agent Settings… (mockup screen 2)

A new section **"Your instructions — this workbench"** below the methodology pickers, one block per field:

- the global text in grey, collapsed to its first lines, with **Edit in Settings**;
- "Added after them, for sessions in this workbench only:" and the workbench's own text area with a counter.

Suggestions for this workbench appear in the same yellow style under the matching field. The `workflow.md` row stays, labelled as the team's folder rules.

### Home

When an open suggestion first seen in the last 7 days exists, Home's Today zone shows one card: "You keep telling agents: “<direction>” — add to your instructions?" with **Add**, **Dismiss** and **More…** (opens Settings at the field). One card at a time, the newest; the card leaves once acted on (here or in Settings) or once it is 7 days old — older open suggestions stay in Settings only (*my call*: no nagging). It follows the existing Today card conventions (`HomeTodayBuilder`, failed read ≠ all clear).

## What the agent receives (mockup screen 3)

### A · The brief

A new slot in the session brief, placed after the board rules and the folder rules:

```
Owner's instructions (follow in every turn):
<global session instructions>
For this workbench:
<workbench session instructions>
```

The "For this workbench:" line appears only when the workbench text is non-empty; the whole slot is absent when both are empty. When a target procedure is set (global or workbench), the brief adds one line: `Target procedure: update_target returns it when a target goes in_progress.`

The slot is inline in full — the field limits (below) guarantee it fits; it is never cut to a pointer. The brief's existing `briefMaxChars` budget grows by the rendered slot's size so the board, comments and asks keep the room they have today.

Instructions reach a session when its brief is built: an edit takes effect from the next new session (a resumed or running session keeps the text it started with).

### B · Taking a target

When `update_target` changes a target's status to `in_progress` (from any other status), the tool's result gains a `procedure` field:

```
"procedure": "Owner's target procedure — follow it for #612:\n<global>\nFor this workbench:\n<workbench>"
```

- Present on **every** `update_target` call whose `status` argument is `in_progress`, including when the target already was `in_progress` (a resumed Work on It) — no comparison with the stored status, so no race between writers. A `column` move that lands the target in an `in_progress` column counts the same (a column move sets the status). `create_targets` has no status argument, so it never returns a procedure. A call that sets any other status, or no status, carries no `procedure`. *(My call: the owner asked for "every time it takes a target"; a re-take is a take.)*
- Status changes made outside the agent's tools (Desktop drag, phone) deliver nothing by themselves; Work on It and a phone start already tell the agent to work the target, and the board rules make it set `in_progress` itself, which delivers the procedure.
- Absent when both texts are empty.
- Read at call time, so an edit applies from the next target, even in a running session.
- Applies to groups too (a group moved to `in_progress` gets the procedure).

## Limits

- Each of the four texts (global/workbench × session/procedure): **1000 runes**. The session slot is therefore at most ~2050 runes with its headers; `briefMaxChars` grows by the rendered slot's size, at most that amount. *(My call: the existing brief cap is `briefMaxChars` = 4000 in `cmd/workbench_brief.go` and the methodology slot `briefMethodChars` = 1400 in `cmd/workbench_brief_method.go`; the builder confirms the combined brief stays inside the SessionStart context limits of Claude Code and Codex and, if they don't fit, lowers the per-field limit — never cuts the slot to a pointer and never takes room from the board.)*
- The text is the owner's, injected as instructions on purpose; it is not fenced as untrusted data. Suggestion candidates (model output derived from transcripts) are data until the owner presses Add.

## Storage

My call, following existing patterns (`projects.methodology_*` columns, migration 00123):

- Global: two rows in an owner-settings store the Desktop and Go both read — a new table `owner_instructions(scope TEXT CHECK(scope IN ('session','procedure')) PRIMARY KEY, body TEXT NOT NULL, updated_at TEXT NOT NULL)`.
- Per workbench: two nullable columns on `projects` — `session_instructions`, `target_procedure`.
- Suggestions: `instruction_suggestions(id, text, field CHECK(field IN ('session','procedure')), workbench_id NULL = global, session_count, workbench_count, first_seen_at, last_seen_at, status CHECK(status IN ('open','added','dismissed')), fingerprint UNIQUE, decided_at)`. `fingerprint` is a normalised form of the direction so a re-mined repeat matches an existing row (a dismissed one stays dismissed).
- Writes from Desktop go through a CLI command (as `workbench methodology` does), so Go owns validation and limits: `watchtower instructions show|set [--workbench N] --field session|procedure [--stdin] [--json]` and `watchtower instructions suggestions [--json]`, `… suggestion add|dismiss <id>`. *(The builder may choose direct GRDB writes if the house rules prefer it; one writer per value either way.)*

Mirror into `schema.sql`, `TestAllTablesExist`, golden and the Swift test schema per CLAUDE.md.

## Suggestions — how they are mined

A daemon phase, `phaseInstructionSuggestions`, at most once a day (stamp-gated like the other daily phases):

1. **Input:** the owner entries (`sessionfeed` `KindOwner`, no ask answers, no briefs, no Watchtower lines) of every workbench terminal session of the last **14 days**, both agents. `sessionfeed` reads Claude Code transcripts only today (its v1 limit: "codex sessions are not supported yet"); this feature adds a Codex rollout reader to `sessionfeed` producing the same agent-neutral entries (owner, ask answers and briefs told apart as for Claude), so the session chat feed gains Codex support as a side effect (owner, ask #327). Update `docs/features/session-chat-feed.md` and the FEED inventory accordingly. Very long entries are truncated; pasted blocks (stack traces, code) are skipped by a simple heuristic.
2. **Model:** the cheap tier (`add-ai-prompt` skill; must run on both the claude and codex providers). Given the owner entries grouped by session, the current four texts, and the open + dismissed suggestions, it returns standing directions (not one-off task requests) that appear in **≥ 3 distinct sessions** and are not already covered by the texts. For each: a short imperative line in the owner's language, `field` (session instruction vs. a target-procedure step), and the session ids it saw them in.
3. **Validation in Go (not trusted from the model):** session ids must exist in the input; the count of distinct sessions is recomputed and must be ≥ 3; workbench scope = the one workbench when all those sessions belong to it, otherwise global. Lines over 200 runes are dropped.
4. **Upsert** by fingerprint: new → `open`; existing `open` → counts and `last_seen_at` refreshed; `added`/`dismissed` → untouched.
5. **Caps:** at most 5 open suggestions per field and scope; the oldest open beyond that is left out of the UI, not deleted.

**Add** appends the line (on a new line) to the right text and marks the suggestion `added`; if the text would exceed its limit, Add is refused with a message asking the owner to make room. **Dismiss** marks it `dismissed`, permanently.

There is no workbench entry in the feature registry; the phase runs when at least one workbench terminal session was active in the window and is skipped otherwise. Failure of the model call writes nothing and is retried next day; it never clears existing suggestions.

## Constraints

- Go 1.26 backend, SwiftUI Desktop, existing brief/MCP/hook paths; nothing new installed into the agent's folder.
- Brief is built by `cmd/workbench_brief.go` (`renderSessionBrief`) and the Codex path (`runCodexBrief`); both get the slot.
- `update_target` lives in `internal/tools/workbench_targets.go`; the `procedure` field is additive to its result (existing keys unchanged).
- Behaviour inventory: a new **PROJ-22** in `docs/inventory/workbench.md` holds this contract (brief slot, `procedure` field, suggestions never edit text); DEV-06 in `docs/inventory/dev-surface.md` is amended for the additive `procedure` key. The existing brief guard tests (`TestProj12_AnsweredAskSurvivesAFullBoard` and the budget tests) must keep passing unchanged.
- User guide page updated in the same PR (`docs/guide/`, per `WRITING.md`).
- Public repo hygiene: tests and fixtures use neutral sample texts.

## Settled while writing (my calls)

- Every write (Settings, Agent Settings, Add/Dismiss on Settings or Home) goes through the `watchtower instructions …` CLI; the agent surface gets no tool to read or change these texts — it receives them only through the brief and `update_target`.
- **Preview** renders through Go (`watchtower instructions preview [--workbench N] --json` returning the brief slot and the procedure text, sharing the render code with the brief and `update_target`), so there is no Swift copy of the format.
- The Codex brief path (`runCodexBrief`) gets the same slot; `update_target` is the same MCP tool for both agents, so `procedure` needs nothing agent-specific.
- The phase follows the history-backfill gating: `planusage.NearLimit` skips the run, the model call runs outside any write transaction; nothing is published to the phone slice.

## Left to the builder

- Exact wording of field captions and the Home card copy (keep the meaning above).
- The truncation/paste heuristics and the fingerprint normalisation.
- Whether the Preview sheet is one shared view for Settings and Agent Settings.
- Phase placement within the daemon cycle (after the ingest phases; outside any write transaction for the model call).
