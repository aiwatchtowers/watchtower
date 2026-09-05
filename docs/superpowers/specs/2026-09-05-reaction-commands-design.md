# Reaction Commands — control Watchtower by reacting in Slack

**Status:** design
**Date:** 2026-09-05
**Owner decisions captured:** full emoji dictionary (no undo/toggle); Desktop/notification-only
feedback (Slack stays read-only); per-emoji trust via the existing agent-actions `tool_trust`.

## 1. Problem & intent

The owner wants to drive Watchtower from inside Slack, without switching to the Desktop app:
put a reaction on a message and have Watchtower gather the full context around that message and
bring back a finished piece of work — most importantly a **Target with a full brief**, but also
Tracks, Ideas, reminders, and context summaries.

A reaction becomes a **command**. The emoji picks the verb; the reacted message (plus its thread,
channel, linked Jira keys and people) is the object; the result is an agent-action that lands in
the Desktop app.

## 2. What already exists (the foundation)

- **Reactions are already synced.** `reactions(channel_id, message_ts, user_id, emoji)` is
  populated by `message_sync.go` → `UpsertReactionBatch`. The owner's own reactions are stored
  like anyone else's (namespaced `accountID:Uxxx`).
- **Agent-actions registry** (`internal/tools/`): `Registry.Propose` records a `pending`
  `agent_actions` row and never executes; `Registry.Apply` executes exactly once from
  `approved`/`failed`; per-tool `Trust` (`ask`/`execute`); `External` tools can never be
  execute-trusted (AGENT-03). `create_target` and `create_jira_issue` tools already ship.
- **Context gathering** already exists in several shapes: the inbox composer clusters thread
  context into situations; `get_task_context` resolves a Jira key to its Slack threads, people and
  decisions. Reaction commands reuse this machinery rather than inventing a new context walker.
- **Feature-manager gating** (`internal/features/`): every daemon phase is an early return on its
  config key (FEAT-01: off = zero AI calls, no locks).

## 3. What does NOT exist yet (the gaps this design closes)

1. **Detection of the owner's own reactions as commands.** The current reaction path
   (`FindReactionRequests`) is the inverse and narrow case — *someone else* reacts with an
   attention emoji on *the owner's* message. It is untouched by this design.
2. **Freshness / coverage.** Reactions only enter the DB when a message is re-fetched by
   incremental sync. A reaction on an **old** message (outside the incremental window) may never
   be re-fetched, so the command would be lost. Solved via `reactions.list` (§5).
3. **A command dictionary** mapping emoji → action + trust, editable by the owner.
4. **A place in Desktop** for pending (`ask`-trust) reaction proposals, which have no chat
   conversation to attach an `AgentActionCardView` to.

## 4. Non-goals (v1)

- **No undo / toggle.** Removing a reaction does nothing. (Owner decision 2026-09-05.) This means
  the detection ledger only ever cares about *new* owner reactions; disappearances are ignored.
- **No writing back to Slack.** No confirmation reaction, no DM, no thread reply. Slack scopes stay
  read-only. All feedback is Desktop + macOS notification.
- **No cross-account emoji disambiguation.** The dictionary is workspace-global, not per Slack org.

## 5. Detection mechanism — `reactions.list` poll + ledger

The key insight: Slack's `reactions.list` (slack-go `Client.ListReactions`, available in v0.18.0),
called under the **owner's user token**, enumerates exactly the items *that user* reacted to —
regardless of the message's age and regardless of the incremental-sync window. It is owner-scoped
by construction, so no "is this the owner?" filtering is needed.

New daemon phase **`phaseReactionCommands`**:

1. For each enabled Slack account, call `ListReactions` under that account's owner token
   (paginated). Each returned item carries the message ref and the emoji(s) the owner applied.
2. Keep only items whose emoji is in the **command dictionary** (§7).
3. Diff against a **`reaction_commands` ledger** table keyed by
   `(account_id, channel_id, message_ts, emoji)`. A row not yet in the ledger is a **new command**;
   insert it as `pending` and process it. Rows already present are skipped (idempotency — the
   re-poll must never re-create, mirroring IDEA-05). Disappearances are ignored (no undo).
4. Throttle like the other polling phases (a `reactioncommands.interval_hours`, default 6, plus the
   lock-skip-log pattern). Gate on the feature key (§9).

`ListReactions` needs `reactions:read`, which the app already holds. No new scope.

### Freshness caveat, made explicit

`reactions.list` closes the "old message" gap for **detection**, but the reacted message's *content*
(and its thread) must still be readable to build context. For a message already synced, it is in
the DB. For a message outside the sync window, the phase fetches the message and its thread on demand via the
existing Slack client's thread-fetch path (conversations.replies) — bounded, best-effort;
a fetch failure defers the command (leave it out of the ledger) rather than producing a thin brief.

## 6. Processing a command — the pipeline

`internal/reactioncmd/` (new package), `Pipeline.Run`, one command at a time:

```
new owner reaction (emoji ∈ dictionary)
        │
        ▼
gather context: reacted message + thread + channel + linked Jira keys + people
        │        (reuse composer / get_task_context building blocks)
        ▼
compose action args  ── AI pass (strong tier) for verbs that need a brief
        │              (:task:/:track: compose a title+intent from the thread;
        │               :idea: a one-liner; :brief: a summary; :later: no AI)
        ▼
agent-actions registry
        │
   trust=execute (and not External)        trust=ask  OR  External
        ▼                                        ▼
   Apply immediately                       Propose → pending agent_actions row
        │                                        │  surfaces in Desktop (§8)
        └───────────────┬────────────────────────┘
                        ▼
          Target / Jira / Track / Idea / reminder
                        │
                        ▼
             macOS notification (Slack stays silent)
```

- The **AI pass** composes the tool arguments (e.g. `create_target`'s title/intent) from the
  gathered context, the way the ideas consolidator and target-brief chat already do. Deterministic
  verbs (`:later:`) skip it.
- The registry call is the single write path. For `execute`-trust non-External tools the phase
  calls `Apply` inline; otherwise it records a `pending` row. **`create_jira_issue` is `External`,
  so it is always a proposal regardless of trust (AGENT-03) — the registry enforces this.**
- Every command records its origin ref on the `agent_actions` row (the reacted message permalink),
  so the Desktop card and the created entity link back to the Slack message (link, not copy — the
  DASH-03/IDEA-03 house philosophy).

## 7. The command dictionary

A DB table `reaction_command_map(emoji TEXT PRIMARY KEY, kind TEXT, tool TEXT, handler_id INTEGER,
enabled INTEGER, …)` seeded with a default set, editable from **Settings → Slack**. The `kind`
discriminator makes the dictionary an open extension point from day one:

- **`kind = "builtin_tool"`** — `tool` names a registered agent-actions tool (the §7 table below).
  Trust is *not* duplicated here — it is read from the existing `tool_trust` per the mapped tool, so
  "how autonomous is this emoji" is configured once, in the same place chat-surface trust is.
- **`kind = "agent"`** — `handler_id` points at a **custom agent handler** (§7a). Designed in now,
  implemented in Wave 3 (§11) — see the dependency note there.

Only the `builtin_tool` kind is wired in Waves 1–2; the column exists from the first migration so
the data model never has to be reshaped to admit custom handlers.

Default dictionary (full set; implementation phased in §11):

| Emoji         | Tool / action        | Needs AI brief | Default trust |
|---------------|----------------------|----------------|---------------|
| `:task:` ✅    | `create_target`      | yes            | ask           |
| `:jira:` 🎫    | `create_jira_issue`  | yes            | ask (External → always ask) |
| `:track:` 👀   | `create_track` (new) | yes            | ask           |
| `:idea:` 💡    | `create_idea` (new)  | light          | execute       |
| `:later:` ⏰   | `remind_me` (new)    | no             | execute       |
| `:brief:` 📌   | `brief_context` (new)| yes (summary)  | execute       |

`create_target` currently declares `Surfaces: ["main"]`; reaction commands are a **non-chat**
caller, so they go through the registry with a reaction binding rather than a chat surface — the
Surfaces gate applies to chat surfacing, not to the daemon caller. (A tool's mandate rules, e.g.
TGT-BRIEF-01 axis 3 forbidding `create_target` inside the target chat, are unaffected — reaction
commands are their own surface.)

## 7a. Custom agent handlers (`kind = "agent"`) — designed in, built in Wave 3

Beyond the fixed built-in verbs, the owner can bind an emoji to a **custom agent handler**: a
free-text instruction (optionally a Watchtower skill) plus a whitelist of tools the handler may
use, and a trust setting. When such a reaction fires, the pipeline feeds the gathered context (§6)
to an **agent tool-loop** running that instruction; the model decides which whitelisted tools to
call, and every call still goes through the registry (Propose/Apply). This lets the owner grow the
command vocabulary without a Watchtower release — e.g. `:triage:` → "summarise this thread, decide
if it needs a Jira ticket, and if so draft one" as a single owner-authored handler.

**Data:** `reaction_command_handlers(id, name, instruction, skill_id NULL, allowed_tools JSON,
trust, enabled, …)`, referenced by `reaction_command_map.handler_id` when `kind = "agent"`.

**Hard dependency — runtime B.** A custom handler needs a Go-owned agent tool-loop that dispatches
registry tools in-process. That loop is the agent-actions **mandatory follow-up ("runtime B")** —
it does not exist yet. Custom handlers are therefore **specified now but not implemented until
runtime B lands**; Wave 3 is gated on it.

**Safety is inherited, not re-invented.** A custom handler cannot escape the agent-actions
contracts: its tool calls are validated and recorded by the registry, `External` tools still never
auto-execute (AGENT-03), and the handler's own `trust` only governs whether *its non-External
proposals* auto-apply. A handler whose `allowed_tools` is empty degrades to "propose nothing, just
summarise" — always safe. The `allowed_tools` whitelist is authored by the owner, never inferred.

## 8. Where pending proposals surface in Desktop  — OWNER CALL

Pending (`ask`-trust) reaction proposals have no chat conversation, so the per-conversation
`AgentActionFeed` cannot host them as-is. Two candidate homes:

- **(A)** A dedicated "Pending actions" list (small new surface / section), driven by a
  reaction-scoped binding, reusing `AgentActionCardView` (Approve/Reject/Retry).
- **(B)** Route them into the existing **Inbox/Dashboard** as a new situation/item kind, so
  reaction proposals live next to the other things asking for the owner's attention.

Recommendation: **(B)** — it reuses an attention surface the owner already checks and avoids a
fourth place to look; the reaction proposal becomes a dashboard item whose action bar is the
Approve/Reject of the underlying `agent_actions` row. Final choice is the owner's.

## 9. Feature gating & config

- New feature-registry entry `reaction-commands` (Title "Reaction Commands", cost **medium** — one
  AI compose per new command reaction, only when the owner actually reacts), `ConfigKey:
  "reaction_commands.enabled"`, default **off** until validated end-to-end (the dark-until-proven
  precedent). Fast-forward hook on enable seeds the ledger from the *current* `reactions.list` so a
  freshly-enabled feature does not backfill every historical reaction (FEAT-03).
- Config block `reaction_commands`: `enabled`, `interval_hours` (default 6).

## 10. Behavioral contracts (REACT-01..05)

- **REACT-01 — owner-only.** A command fires only for the owner's own reaction (`reactions.list`
  under the owner token guarantees this); no other user's reaction is ever a command.
- **REACT-02 — no invented provenance.** Every created entity/proposal carries the reacted
  message's real ref; the pipeline never fabricates a source.
- **REACT-03 — idempotent.** Re-polling `reactions.list` never re-creates a command already in the
  ledger. Ledger key = `(account_id, channel_id, message_ts, emoji)`.
- **REACT-04 — the model never writes directly.** All writes flow through the agent-actions
  registry (Propose/Apply), inheriting AGENT-01..06 — including External-never-auto-execute.
- **REACT-05 — read-only Slack.** The feature adds no Slack write scope and posts nothing back to
  Slack; removing a reaction has no effect (no undo).

## 11. Implementation phases

1. **Wave 1 — MVP:** `phaseReactionCommands` + `reaction_commands` ledger + `reaction_command_map`
   (seeded `:task:`, `:jira:`), the compose AI pass, wiring to the existing `create_target` /
   `create_jira_issue` tools, and the Desktop pending-proposal surface (§8). This proves the whole
   loop on the two highest-value verbs.
2. **Wave 2 — dictionary breadth:** new tools `create_track`, `create_idea`, `remind_me`,
   `brief_context`; Settings → Slack dictionary editor.
3. **Wave 3 — custom agent handlers (§7a) + polish:** the `kind = "agent"` path —
   `reaction_command_handlers`, the handler-authoring surface, and the agent tool-loop dispatch.
   **Gated on runtime B** (the agent-actions Go tool-loop); until that lands only `builtin_tool`
   handlers run. Plus per-emoji trust surfacing in the dictionary editor, notification copy,
   coverage metrics.

## 12. Open questions for the owner

1. Desktop home for pending proposals — (A) dedicated list vs (B) into the Inbox/Dashboard (§8).
2. Default trust per emoji — is the §7 table right (idea/later/brief auto, task/track/jira ask)?
3. `:later:` semantics — a Watchtower-side reminder row, or reuse inbox snooze? (Affects whether
   `remind_me` is a new tool or a thin wrapper.)
4. Custom agent handlers (§7a) — confirm they are Wave 3 and gated on runtime B, not pulled earlier.
   Also: is skill-binding (`skill_id`) wanted in v1 of handlers, or is a free-text instruction
   enough to start?
