# Target next step (live) + assistant chat tabs — design

Status: proposed
Date: 2026-08-18

## Problem

The next-step card on the target detail screen looks like a step in a sequence,
but nothing about it advances. An operator clicks the primary action (e.g.
"Collect the checklist from the channel"), does real work with the assistant,
comes back — and the card is unchanged, still proposing the step that was just
carried out.

Three independent causes, all confirmed in the current code:

1. **The card is a cache with a manual-only refresh.** `syncNextStep()`
   (`WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift:819`) reads
   the stored `targets.next_step` and generates a new one only when none was
   ever stored. Regeneration otherwise happens on the ↻ button or a
   `Different plan` action.
2. **A chat session is invisible to the staleness rule.** The daemon
   (`phaseNextStep` → `GenerateAllNextSteps`) does refresh stale suggestions,
   where stale means `next_step_at = '' OR next_step_at < updated_at`
   (`internal/db/targets.go:158`). Chatting with the assistant without approving
   an action never touches `targets.updated_at`, so the suggestion never becomes
   stale — and a background refresh that *does* happen is not picked up by an
   open screen (GRDB does not observe another process's writes; see the comment
   at `TargetDetailView.swift:815`).
3. **The prompt is blind to the work.** `buildNextStepPrompt`
   (`internal/targets/nextstep.go:150`) passes text, intent, status, priority,
   ownership, horizon, due date, ball, blocking, parent, checklist and a link
   count. It does not pass `progress`, notes, or anything at all from the
   assistant conversation — so even a manual regeneration can legitimately
   return the same step.

Separately, a target owns exactly one assistant conversation
(`ChatConversationQueries.fetchByContext` takes the newest single row), so
parallel lines of work on one target share a single thread.

## Part A — the next step becomes live

No migration. `targets.next_step_at` is already documented as "compared to
updated_at for staleness" (`internal/db/schema.sql:404`) and Go already uses it.

### A1. Staleness includes assistant activity

Last activity on a target = `max(targets.updated_at, latest assistant
conversation updated_at)`. The second term is the new part: a chat turn already
calls `ChatConversationQueries.touch`, so a session that produced no target
mutation still registers as work.

A note on units: `targets.updated_at` is ISO-8601 TEXT, while
`chat_conversations.updated_at` is a REAL unix timestamp (the chat tables are
Swift-owned, created by `ensureTable`). Both are converted to `Date` at the
comparison site; a value that fails to parse is treated as "no activity" rather
than "stale now".

Swift gets one new query — `ChatConversationQueries.latestActivity(type:id:)`
(`SELECT MAX(updated_at) …`) — and the detail view derives
`isNextStepStale` from it plus the target row it already re-reads from the DB.

### A2. The card says so, and offers one click

When the suggestion is stale the card keeps showing its current text (it is
still the last thing the operator agreed to work on) and gains a header strip:
a short "context changed since this step" line and a primary
**Refresh step** button. The existing ↻ stays as the unconditional
regenerate affordance.

There is no automatic AI call: the strong-model call fires on the click, or on
the daemon's own schedule as it does today.

### A3. Recomputed while the screen is open

`TargetChatViewModel.finishStream()` and the two approve paths already call
`reloadTarget()` / `viewModel.load()`. The detail view re-runs the staleness
check on the same signals (a callback from the chat VM, plus `onAppear` as
today), re-reading `targets` from the pool — which also picks up a suggestion
the daemon regenerated in the background while the screen stayed open.

### A4. The prompt stops being blind

`buildNextStepPrompt` additionally renders:

- `progress` (as a percentage) — currently not passed at all;
- the last 2–3 target notes;
- a bounded excerpt of the target's assistant conversation: the most recent
  turns across roles, capped by both turn count and characters. `system` turns
  are included deliberately — the "Action applied: …" lines written by
  `sendFollowUp` are the highest-signal record of what was actually done.

This needs one new reader in `internal/db` returning the recent messages for a
`(context_type, context_id)` pair. Like `ListOwnerChatTurns`, it must tolerate
the chat tables being absent (a CLI-only install has never run the Desktop app,
which is what creates them) and return no rows rather than an error.

The system prompt gains one rule: if the history shows the previous step was
already carried out, propose what comes after it rather than repeating it.

### A5. Non-goals for Part A

- No step entity, no step history, no multi-step plan. A step stays a
  regenerable suggestion (explicit owner decision, 2026-08-18).
- No automatic regeneration after a chat turn — the badge plus one click is the
  contract.
- No change to the action kinds (`assistant` / `open_links` / `mark_done` /
  `dismiss`).

## Part B — assistant tabs inside a target

`chat_conversations` already supports many rows per context; only the read path
assumes one. No migration here either.

### B1. Queries

- `ChatConversationQueries.fetchAllByContext(type:id:)` — ordered by
  `created_at`, so the existing conversation is tab #1.
- `updateTitle` and `delete` already exist and back rename/close.

### B2. `TargetChatViewModel` takes a conversation

The VM currently resolves "find or create" itself in `loadOrCreateConversation`.
That decision moves up to the container; the VM is initialised with a
conversation id. Streaming, action cards and approve/approveAll are unchanged.

### B3. A container, held in `AppState`

`TargetAssistantViewModel` owns, for one target: the list of conversations, the
active tab, and a `conversationID → TargetChatViewModel` map. Because the VMs
outlive tab switches, a turn started in one tab keeps streaming while the
operator reads another; the inactive tab's chip shows a "working" dot.

Containers live in a center on `AppState`, keyed by target id — per the house
rule that async operations survive navigation, leaving the target screen must
not kill a working agent. The center keeps a bounded number of target
containers (a small LRU); a container is only evicted when none of its VMs is
streaming.

### B4. UI

A chip row in the `TargetChatSection` header plus a `+` button. Chip context
menu: Rename / Close. Closing deletes the conversation and its messages
(`ON DELETE CASCADE`); the last remaining tab cannot be closed. A new tab is
titled "New chat" until its first user message, then auto-titled from that
message's first ~30 characters.

### B5. Routing and edge cases

- Next-step actions of kind `assistant`, the Watch tab's seed and the inline
  "Ask the assistant" field all route into the **active** tab, exactly as they
  route into the single chat today. "Open in a new tab" is deliberately out of
  scope.
- A target opened for the first time gets one tab, created lazily on first use —
  the current behaviour.
- Deleting a target already removes its conversations by the existing path; the
  center drops the container.

## Testing

Go:
- `internal/targets/nextstep_test.go` — the enriched prompt renders progress,
  notes and the chat excerpt; the excerpt is capped; absent chat tables produce
  a prompt rather than an error.
- `internal/db` — the new recent-messages reader: ordering, cap, absent tables.

Swift (`WatchtowerCore` where possible):
- staleness: no `next_step_at`; `next_step_at` older than `targets.updated_at`;
  `next_step_at` older than the latest conversation activity; both fresh;
  unparseable timestamps.
- container: create/switch/rename/close, last tab not closable, a stream in a
  background tab keeps running across a switch, auto-title from the first
  message.
- `TargetChatViewModelTests` keeps passing with the injected conversation id.

## Rollout

No feature flag: both parts are direct improvements to an existing surface with
no new AI spend beyond the click the operator makes.
