# Task AI Agent — agentic chat for a task

**Date:** 2026-06-26
**Status:** Design (approved in brainstorm)
**Branch:** TBD (off `main`)

## Problem

A task (`targets`) has an `intent` field — free text describing what the user
wants to achieve. Today it's dead text. We need a button that starts an AI
conversation from the intent, reads the local Slack database, and helps drive
the task to a result, **proposing actions and asking for permission** — like
LLM tool-calls.

## Decisions (from the brainstorm)

1. **AI action surface:** read the Slack database + draft replies; **modify the
   task itself**. No external sends (Slack/Jira/Calendar). All writes go only to
   the local SQLite watchtower DB. → no external side effects and no TCC risk.
2. **Confirmation model:** AI **proposes** a structured action → Desktop renders
   an Approve/Reject card → the DB write is done by **Swift** (deterministically),
   not the AI. The model is not given write access to the DB.
3. **Conversation:** one persistent conversation per task (tied to `target_id`),
   the intent is the seed/context, history accumulates across sessions.
4. **Action transfer mechanism:** a fenced ```` ```watchtower-action ```` block in
   the response text, parsed on the Swift side. **The Go stream is untouched.**
5. **Action types v1:** all 5 — `updateStatus`, `updateNotes` (append),
   `updateProgress`, `addSubItem`, `createChildTarget`.

## Architecture

All the logic lives in Desktop (Swift) + a new prompt fragment. Go (`internal/ai`,
CLI, `internal/db`) **is not changed**. MCP stays read-only (`read_query`).

Precedent in the codebase: `TrackChatView` / `TrackChatViewModel` — a chat tied
to a track via `ChatConversationQueries.fetchByContext(type:id:)` /
`create(contextType:contextID:)`. The new chat is a copy of this pattern with
context `type:"target"`.

### Components

- **`TaskChatView` + `TaskChatViewModel`** — modeled on `TrackChatView`.
  Conversation context `type:"target", id:String(target.id)`. System prompt is
  built from the task: `text`, `intent`, `status`, `notes`, `sub_items`.
  Streams via `WatchtowerAIService` (existing `ai query`), MCP read-only.
- **`ProposedAction`** — a Swift type (struct + `kind` enum), decoded from a JSON
  block. Fields per type:
  - `updateStatus` → `status` (todo/in_progress/blocked/done/dismissed/snoozed)
  - `updateNotes` → `note` (appended to existing notes)
  - `updateProgress` → `progress` (0–100)
  - `addSubItem` → `text` (+ optional `done` bool)
  - `createChildTarget` → `text`, `intent`, optional `priority`
  - all of them — a required `reason` (why, for the card text)
- **`TaskActionParser`** — extracts all ```` ```watchtower-action ```` blocks from
  the accumulated turn text, hides them from the visible text, and returns
  `[ProposedAction]` + the cleaned-up text.
- **`TaskActionCard` (View)** — human-readable description of the action + `reason`
  + Approve / Reject buttons. Pending/applied/rejected states.
- **`TaskActionExecutor`** — on Approve, calls the existing `TaskQueries`
  (`updateStatus`, `updateSubItems`, `create` for a child, notes/progress update).
  On completion, builds a follow-up message and sends it into the conversation as
  the next user turn so the AI can continue.

### Data flow

```
intent + task context ──seed──▶ system prompt
user msg ─▶ ai query (read_query, read-only) ─stream─▶ text + ```watchtower-action```
                                                  │
                          TaskActionParser ───────┘──▶ [ProposedAction]
                                                          │
                                              TaskActionCard [Approve/Reject]
                                       Approve │                    │ Reject
                          TaskQueries.write(targets)          follow-up "user rejected: <reason>"
                                       │                             │
                          follow-up "action executed: <summary>" ───┴──▶ next turn (AI continues)
```

Invariant: **the AI only proposes, the write is always done by Swift.** The
model is not given write-MCP tools; `--allowed-tools` stays read-only.

## Action contract (prompt)

A new fragment in the conversation's system prompt instructs the model:

> To modify the task — do NOT write to the DB and do NOT call write tools.
> Output a block ```` ```watchtower-action ```` with a SINGLE JSON object
> `{ "type": "...", ...fields, "reason": "..." }`. One action per block
> (multiple blocks are allowed). After the block, stop and wait for
> confirmation — do NOT treat the action as applied.

The list of `type` values and their required fields is fixed and validated by
the Swift decoder.

## Error handling / edge cases

- Invalid/unknown `type` or malformed JSON → a visible **error card**
  (not a silent no-op), the AI gets a follow-up "action invalid: …".
- Reject → follow-up "user rejected, reason: …"; the AI re-asks/adjusts.
- The conversation survives across runs: resumed by `session_id` from
  `chat_conversations` (as in `TrackChatViewModel`).
- Approve applies exactly one action; the UI serializes confirmations — no races.
- Empty intent → the seed is built from `text`; the conversation works without
  an intent section.

## Testing

- **Go:** unchanged → existing tests stay green (explicit non-goal: do not touch
  `internal/ai`/CLI/`internal/db`).
- **Swift:**
  - `TaskActionParser`: single block, multiple blocks, a block in the middle of
    text, malformed JSON, no block (plain text) — correct extraction and visible
    text.
  - `ProposedAction` decoder: each of the 5 types; unknown type → error.
  - `TaskActionExecutor`: each type maps to the correct `TaskQueries` call;
    follow-up is built both on Approve and on Reject (degenerate clean-exit
    branches are tested explicitly — see the working principle "test degenerate
    clean-exit branches").
  - `TaskChatViewModel`: loading/creating a conversation by `target_id`, seed
    prompt contains the intent.

## Not doing (YAGNI)

External Slack sends, Jira/Calendar actions, batch confirmation at the end, real
MCP write + `canUseTool`, a separate model tier (we use the current chat model),
editing arbitrary task fields outside the 5 action types.
