# Reaction Commands Wave 2 + Inbox as an action strip

**Status:** design, pending owner review
**Branch:** `feature/reaction-commands-wave2` (off `feature/agent-actions`)
**Depends on:** Wave 1 (`internal/reactioncmd/`, migration 00063) + agent-actions registry (`internal/tools/`, migration 00062), both currently living only in `feature/agent-actions`.
**Predecessor spec:** `docs/superpowers/specs/2026-09-05-reaction-commands-design.md` (§7 dictionary, §8 owner call, §11 waves, §12 open questions).

---

## 1. Problem & intent

Two owner observations set the direction:

1. **The inbox is a bin the owner does not open.** Today the Inbox tab is a Dashboard of AI-clustered **situations** (`compose` + `situation_card`, heavy AI each cycle). Recap — "what happened while I was away" — is already owned by **Catch-Up**. So the situations Dashboard duplicates Catch-Up's job with none of its focus, and gets ignored.
2. **The valuable moment is a gesture, not a feed.** "I react to a Slack message → the system assesses what's happening, gathers the context, and brings me a ready decision." That is the archetype Wave 1 shipped. The owner wants the inbox to *be* that: a place where gesture-driven, context-gathered **decisions** live, each a button — not a stream you scroll and forget.

**This slice turns the inbox into a flat action strip and widens the reaction vocabulary (Wave 2).** The heavy situations machinery is *muted* (feature-gated off), not yet deleted — its physical removal, and the fate of its consumers (memory, MCP, Catch-Up), is a separate follow-up spec (§10). This is the owner-approved staging: raise the strip now, prove it, demolish later.

### The boundary, stated once

- **Catch-Up (recap)** = everything passive / "what I missed", including Jira the owner never touched. Comprehensive, no gesture required.
- **Inbox action strip** = only what the owner *gestured* at (a Slack reaction, a "remind me", a chat proposal awaiting approval). **No trash bin by construction: nothing lands without a gesture.**
- Mentions / DMs are *not* strip material — the owner sees those in Slack. Proactive Jira → Catch-Up. A Jira "gesture" mechanism does not exist yet and is out of scope (§9).

---

## 2. What already exists (the foundation this builds on)

- **agent-actions registry** (`internal/tools/`): `Propose` records one `agent_actions` row (`pending`); `Apply` executes once via a CAS to `executing` (AGENT-05). Per-tool trust in `tool_trust` (`ask` default, `execute` opt-in); `External` tools can never be `execute` (AGENT-03). Two tools registered: `create_target` (`Surfaces:["main"]`), `create_jira_issue` (`External`).
- **`agent_actions` already carries the binding** (migration 00062): `surface`, `context_type`, `context_id`, `conversation_id`, `turn_id`, `status`, `trust_at_create`, `result_json`. Reaction dispatch already sets `Binding{Surface:"reaction", ContextType:"reaction"}` (`reactioncmd/pipeline.go:167`) — so a reaction proposal is **already** a chat-less `agent_actions` row. **No new binding column is needed; the strip queries by `surface`.**
- **reaction commands pipeline** (`internal/reactioncmd/`, migration 00063): owner-token `reactions.list` poll → ledger diff (idempotent, REACT-03) → light-tier `reactioncmd.command` compose → dispatch through the registry. `reaction_command_map(emoji, kind, tool, handler_id, enabled)` seeded with `white_check_mark→create_target`, `ticket→create_jira_issue`. Daemon phase `phaseReactionCommands` (throttle 6h), feature `reaction-commands` (OFF by default). CLI `reaction-commands poll|list`.
- **Desktop agent-action UI**: `AgentActionCardView` (Approve/Reject/Retry, no buttons while `executing`), `AgentActionFeed` (per-conversation), `AgentActionQueries` (GRDB). These are the reusable parts the strip is built from.
- **Feature gate**: `secretary-inbox` currently gates the **whole** inbox pipeline — triage + compose + situation cards, and it "Feeds Memory and the daily Briefing". Turning it off is too coarse for this slice (it would also kill triage + `inbox_items`, which Catch-Up reads via `ListCatchupInbox`).

---

## 3. Scope of this slice

**In:**
1. Four new registry tools: `create_track`, `create_idea`, `remind_me`, `brief_context`.
2. A new `reminders` entity (own table + daemon phase) backing `remind_me` / `:later:`.
3. The **inbox action strip** — a flat, cross-source queue of things awaiting the owner's decision, replacing the situations Dashboard as the Inbox tab's content. Reuses `AgentActionCardView`. This is the §8 home (a purpose-built flat list, not shoehorned into situations).
4. **Mute situations** at a finer grain than `secretary-inbox`: a new gate that disables only `runCompose` + `runSituationCards`, leaving triage + detectors + `inbox_items` running for Catch-Up / Memory.
5. Dictionary breadth: migration seeds `:track:`/`:idea:`/`:later:`/`:brief:`; **Settings → Slack** dictionary editor (emoji → tool, enable/disable, trust shown from `tool_trust`).

**Out (deferred, §10):** physical deletion of the situations pipeline and rework of its consumers (memory situations-ingest, MCP `list_situations`/`get_situation`, Catch-Up's inbox read); custom agent handlers (`kind="agent"`, Wave 3, gated on runtime B); Jira gesture; pulling any *new* proactive source into the strip.

---

## 4. The action strip

### 4.1 Data model — union of two sources, no new "feed" table

The strip is a **read-time union**, computed by a query, of:

1. **Agent-action cards** — `agent_actions` rows in a non-terminal or recently-terminal state that are awaiting or recording the owner's decision, regardless of origin surface. Concretely: `status IN ('pending','approved','failed','executing')` plus a short tail of recently `applied`/`rejected` for confirmation. This unifies reaction proposals (`surface='reaction'`), un-acted chat proposals (`surface='main'|'target'`), and `brief_context` result cards into one "awaiting decision" list.
2. **Reminder cards** — `reminders` rows that have come due (§5.3).

Ordering: newest-actionable first; due reminders sort by `remind_at`. Terminal rows age out of the tail after a small window.

> **Owner-review call (STRIP-A):** should un-acted **chat** proposals (`surface='main'|'target'`) appear in the strip, given they are *also* shown inside their chat via `AgentActionFeed`? Default here = **yes, include them** (the strip becomes the single "everything awaiting my decision" home; a proposal made in a chat two days ago is findable without reopening the chat). The alternative is strip = reaction + reminder only. Low-risk either way; call it at review.

### 4.2 Desktop surface

- The **Inbox** sidebar tab renders the action strip instead of the situations Dashboard. A flat list of `AgentActionCardView`s + reminder cards; empty state = "Nothing waiting on you."
- New `ActionStripView` + `ActionStripViewModel` (async state on `AppState`, house rule), reading via a widened `AgentActionQueries` (a `fetchStrip()` that is not conversation-scoped) plus a new `ReminderQueries`.
- Cards reuse `AgentActionCardView`; reminder cards get Done / Snooze.
- The situations Dashboard code (`InboxFeedView`, `SituationReviewPane`, …) is **not deleted** this slice — it is simply no longer the Inbox tab's content. (Kept reachable-in-code so the demolition spec removes it deliberately, DASH contracts in hand.)

### 4.3 Behavioral contracts (new)

- **STRIP-01 — gesture-gated.** A card exists in the strip only because of an owner gesture (a reaction, a `remind_me`, a chat proposal the owner elicited). The strip never manufactures a card from passive/ambient activity. (Inherits REACT-01 owner-only for the reaction path.)
- **STRIP-02 — the strip is a view, not a store.** It writes nothing on read; every card's state lives in its backing `agent_actions` / `reminders` row. Approve/Reject/Done/Snooze mutate those rows through the existing registry / new reminder mutators — never a strip-local table.
- **STRIP-03 — decisions flow through the registry.** Approve/Reject/Retry on an agent-action card is exactly the existing `Registry.Apply`/reject path (AGENT-05 exactly-once preserved). The strip adds no new write path for agent actions.

---

## 5. New tools

All four register in `internal/tools/` beside `create_target` / `create_jira_issue`, and gain an `argGuide` branch in `reactioncmd/prompt.go` so the composer knows their arguments. Trust follows the §7 table (confirmed by owner).

### 5.1 `create_track` (`:track:` 👀, trust `ask`)
Direct analogue of `create_target`: `Apply` calls the existing tracks create path. Needs an AI brief (compose fills title/intent from the reacted context). `Surfaces` unset (chat-visible where relevant), but the reaction caller is surface-independent per Wave 1.

### 5.2 `create_idea` (`:idea:` 💡, trust `execute`, light tier)
Analogue calling the existing ideas create path (`IdeaQueries.createManual` equivalent on the Go side — the manual-create path, `status='active'`, `source='owner'`). Light brief. `execute` trust = a reaction auto-applies (no Approve needed) — idea capture is low-stakes and reversible.

### 5.3 `remind_me` (`:later:` ⏰, trust `execute`) + `reminders` entity
The owner chose **a separate reminder entity**, not a due-dated target and not inbox snooze (whose machinery is exactly what we are muting).

- **Table `reminders`** (new migration): `id, account_id, message_ref TEXT, channel_id, message_ts, note TEXT, remind_at TEXT, status TEXT CHECK(status IN ('pending','due','done','dismissed')) DEFAULT 'pending', created_at, done_at`.
- **`remind_me` tool**: `Apply` inserts one `reminders` row (`pending`) carrying the reacted message's real ref (REACT-02 provenance) and a `remind_at` the composer derives from context ("later" → sensible default, e.g. next morning; explicit "tomorrow 3pm" honored). No AI brief needed beyond parsing the time hint.
- **Daemon phase `phaseReminders`** (cheap, no AI): flips `pending` reminders whose `remind_at ≤ now` to `due`. Due reminders surface as strip cards. Done / Snooze mutate the row (`done` / bump `remind_at`, back to `pending`).
- **REMIND-01 — a reminder is inert until due.** A `pending` reminder shows nothing; only `due` reaches the strip. Snooze returns it to `pending`.
- **REMIND-02 — read-only Slack.** Consistent with REACT-05: a reminder posts nothing back to Slack; it is a Watchtower-local row.

### 5.4 `brief_context` (`:brief:` 📌, trust `execute`)
A read-only summarizer. `Apply` gathers the reacted message's thread/context (from what `reactions.list` + local DB already provide — no new Slack scope, no live `conversations.replies`, matching Wave 1's freshness caveat) and generates a summary, written into the `agent_actions` row's `result_json`. **No side effect beyond its own row** — the card renders the brief and is dismissable. `execute` trust = it produces the brief immediately on reaction. An empty `allowed`-less summary is always safe.

---

## 6. Muting situations without killing triage

`secretary-inbox` is too coarse (it gates triage + `inbox_items` + Memory/Briefing feed). Introduce a **narrower gate** that disables only the two expensive AI stages:

- New config key **`inbox.situations.enabled`** (default **false** in this slice). In `internal/inbox/pipeline.go`'s `Run`, `runCompose` and `runSituationCards` early-return when it is false (the FEAT-01 early-return shape: off = zero AI, no locks, no `pipeline_runs`). Triage, detectors, `inbox_items`, auto-resolve, unsnooze — **unchanged** (Catch-Up's `ListCatchupInbox` and Memory keep their inputs).
- The compose watermark (INBOX-09 / DASH-02) is untouched: with compose gated off it simply does not advance, and re-enabling later resumes cleanly (the situations follow-up decides whether that ever happens or the stages are deleted).
- No existing situation is deleted; MCP `list_situations` / Memory situations-ingest keep reading the historical set. They just stop growing.

> **Owner-review call (SIT-A):** confirm `inbox.situations.enabled=false` is the right default *now* (situations go dark the moment this ships) vs. shipping it defaulting **true** and flipping it in a follow-up once the strip is validated. Default in this spec = **false** (the owner said "сразу" — mute now); flagged for explicit confirmation because it darkens a shipped surface.

---

## 7. Dictionary breadth + editor

- **Migration** seeds the four new rows into `reaction_command_map` (`INSERT OR IGNORE`, matching 00063's style): `:track:→create_track`, `:idea:→create_idea`, `:later:→remind_me`, `:brief:→brief_context`, all `kind='builtin_tool'`, `enabled=1`.
- **Settings → Slack** gains a dictionary editor (`ReactionDictionary*` — Queries + ViewModel + a table view): list emoji → tool rows, toggle `enabled`, and show the mapped tool's trust read from `tool_trust` (edited where chat-surface trust is edited, not duplicated — §7 of the predecessor spec). Add / remove a mapping writes `reaction_command_map`. Emoji entry is by Slack short-name (`white_check_mark`), matching the ledger key. No custom-handler (`kind='agent'`) UI — that is Wave 3.

---

## 8. Trust (confirmed)

Per the predecessor §7 table, confirmed by the owner: `create_idea` / `remind_me` / `brief_context` default **execute** (auto-apply on reaction — low-stakes, reversible, or read-only); `create_target` / `create_track` / `create_jira_issue` default **ask** (land as pending strip cards). `create_jira_issue` is `External` → always `ask` regardless (AGENT-03). Seeded into `tool_trust` by the same migration, `INSERT OR IGNORE` so an owner's prior choice is never overwritten.

---

## 9. Non-goals (this slice)

- Physical removal of the situations pipeline and its consumers (§10).
- Custom agent handlers (`kind='agent'`, `reaction_command_handlers`, the agent tool-loop) — Wave 3, gated on runtime B.
- Any Jira "gesture" / marking mechanism; proactive Jira into the strip (Jira stays Catch-Up's).
- Live `conversations.replies` thread fetch for out-of-window context (v1 = local DB + `reactions.list` text).
- Pulling mentions / DMs / ambient traffic into the strip.

---

## 10. Follow-up: the situations demolition (separate spec)

Once the strip is validated on live use, a second spec removes the muted machinery deliberately, with each contract change owner-approved:
- Delete `compose` + `situation_card` + `situation_feedback` + the situations Dashboard views.
- Decide Memory's situations-ingest (episodes aliased `situation:<id>`): keep as historical, or migrate its source.
- Decide MCP `list_situations` / `get_situation` (dev-surface, DEV contracts): drop or repoint.
- Decide `inbox_items` / trigger-detector fate now that mentions/DMs are explicitly not strip material (Catch-Up may or may not keep reading them).
- Retire the DASH-01/02/03 contracts and reword INBOX-01..09.

---

## 11. Migrations & contracts summary

- **Migration 00064** (next free number; re-number if the base branch adds one first): `reminders` table; seed 4 `reaction_command_map` rows; seed 4 `tool_trust` rows (`INSERT OR IGNORE`). Mirror into `schema.sql`, add `reminders` to `TestAllTablesExist`, regenerate the golden snapshot.
- **New contracts:** STRIP-01..03, REMIND-01..02 (add to `docs/inventory/` — new numbers only for new principles, per the maintenance rule). REACT-01..05 inherited unchanged.
- **New config:** `inbox.situations.enabled` (default false).

---

## 12. Owner-review calls (decide on spec review)

1. **STRIP-A** — do un-acted chat proposals appear in the strip too? (default: yes.)
2. **SIT-A** — `inbox.situations.enabled` default false *now* vs. flip-after-validation? (default: false.)
3. **`remind_me` default time** — what does a bare `:later:` with no explicit time resolve to? (default: next morning ~9:00 local.)
