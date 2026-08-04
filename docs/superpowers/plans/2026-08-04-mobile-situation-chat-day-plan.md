# Mobile: per-situation Discuss chat + day plan on Today (2026-08-04)

Items 4 and 5 of `2026-08-03-mobile-catchup-plan.md`. Two independent features,
two stacked branches off `feature/mobile-recordings-ui` (PR #64):

1. `feature/mobile-situation-chat` — item 4
2. `feature/mobile-day-plan` — item 5, stacked on top

**Merge rule unchanged: PRs into `mobile-app` use a merge commit, never squash.**

---

## Item 4 — per-situation Discuss chat

The desktop has a Discuss chat per situation (`SituationChatViewModel`,
`chat_conversations.context_type='situation'`) with an intent-draft contract:
the owner states WHAT to reply, the secretary renders it in the owner's voice
(style profile + counterparty people cards + a register sample of the owner's
own messages). The phone has a generic secretary chat with no context binding.

### Owner decisions (2026-08-04)

- **One thread, shared with the desktop.** The relay resolves the situation's
  existing `chat_conversations` row, reuses its CLI `session_id`, and persists
  both the mobile user turn and the assistant answer into `chat_messages`. The
  desktop Discuss pane shows mobile turns, and the Phase-4 memory chat ingest
  (owner turns → owner-rank belief evidence) starts seeing phone-authored turns
  for free — it already stages `role='user'` situation turns.
  - **v1 limitation:** sync is one-way for history. The phone renders only the
    turns it authored (its own replica rows); desktop-authored turns are NOT
    synced down — that needs a `chat_message` slice kind and a privacy call
    about chat text in DataZone. Out of scope here, stated in the UI.
- **Relay only, no BYOK.** A situation Discuss session never routes to the
  on-device agent: the feature's value is a draft in the owner's voice, built
  from `workspace.style_profile`, people cards and raw messages — none of which
  exist on the phone. The direct-mode offer is suppressed for context-bound
  sessions and the composer says so.

### Design

**Wire (`ChatMessagePayload`)** — two optional fields, `contextType` /
`contextID`, following the `isError` discipline: absent on the wire when nil,
so pre-change desktops and phones interoperate unchanged. A payload with no
context decodes exactly as today and takes the existing generic path.

**Kit**

- `ChatContext` (public struct: `type`, `id`) — the one shape passed through
  `ChatAssembler.send` → `MobileAgentBackend.sendTurn`.
- `ReplicaStore.chat_sessions` gains `context_type` / `context_id` columns
  (in-place `ALTER`, the `direct_mode` precedent — existing sessions read NULL
  and stay generic).
- `ReplicaStore.chatSession(contextType:contextID:)` — the phone's lookup for
  "does this situation already have a thread on this device".
- `ChatAssembler.send(text:sessionID:route:context:)` stamps the context onto
  the session row it mints and onto the relay payload. `.localOnly` route
  unchanged.
- `MobileAgentBackend.sendTurn` gains `context:` (defaulted, so the direct
  backend's conformance is unchanged in behavior).

**Desktop hub (`RelayProcessor`)**

`processChatMessage` branches on the payload's context:

- No context → today's path, byte-for-byte (sidecar CLI-session map,
  `ChatViewModel.buildSystemPrompt`). No regression risk for the generic chat.
- `situation` → `SituationChatRelay` (new file, hub-local):
  1. Load the `Situation` and its member signals (the situation's
     `situation_signals` → `inbox_items`), the same inputs the desktop VM takes.
  2. `ChatConversationQueries.fetchByContext(db, type: "situation", id:)`, or
     create it with the desktop's title format — so both surfaces converge on
     ONE row.
  3. CLI session = that conversation's `session_id` (NOT the sidecar map: the
     desktop owns this thread's session and may have advanced it). Empty →
     first turn: full `SituationChatViewModel.buildSystemPrompt`. Non-empty →
     resume, and the turn text is prefixed with `situationContextBlock`, exactly
     as the desktop VM does on a resumed session.
  4. Persist the user turn before streaming; accumulate the answer text while
     chunking to the phone and persist it on completion, then `touch` the
     conversation. A `.sessionID` stream event writes through to
     `ChatConversationQueries.updateSessionID`.
  5. A situation that no longer exists → an error chunk ("this situation is
     closed"), never a silent generic answer.

Failure containment is unchanged: the watchdog, the error-path final chunk and
`markRelayProcessed` all stay in `processChatMessage`; the situation branch only
supplies prompt/session/persistence.

**Mobile UI**

- `SituationReviewView` gains a "Discuss with secretary" row → `ChatThreadView`
  bound to the situation's context. Existing thread on this device → open it;
  otherwise the session is minted by the first send (the assembler's contract).
- `ChatThreadView` accepts a `ChatContext?`; when set it suppresses the
  direct-mode offer and the toolbar toggle, and the composer placeholder reads
  "Ask your desktop about this situation…".

### Tests

- Kit: payload round-trip with and without context (absent key on the wire);
  assembler stamps context on the minted session; context lookup returns the
  situation's session; empty-text guard unchanged.
- Hub: a situation-context message creates the conversation, reuses an existing
  one (and its session id), persists user + assistant turns, resumes with the
  context block, and a context-less message still takes the generic path.
- Mobile: the Discuss row appears on a situation, opens the existing thread, and
  a context-bound thread offers no direct mode.

---

## Item 5 — day plan on Today

`day_plans` / `day_plan_items` are in the schema and the desktop has a full Day
Plan screen; Today on the phone shows only briefing + calendar.

### Owner decision (2026-08-04)

- **Actions, not read-only:** items can be marked done or skipped from the
  phone.

### Concern to flag (found during design)

`day_plan_items.status = 'skipped'` is a **dead state** today: nothing in Go or
the desktop ever writes it, and the only reader is an unused `isSkipped`
computed property — the desktop renders a skipped item indistinguishably from a
pending one. Shipping mobile skip without a desktop reader would create state
the owner can only see on the phone. So this branch also adds the minimal
desktop rendering (dimmed + struck-through row, "Move back to pending" in the
context menu) and `DayPlanQueries.markItemSkipped`. Scope note: this is the
smallest change that makes the new action legible, not a Day Plan redesign.

### Design

**Slices** — two new `SliceKind`s (`day_plan`, `day_plan_item`), published like
every other kind:

- `day_plan`: today's plan only (`plan_date = date('now','localtime')`, the
  desktop's `fetchToday` rule, local zone on both sides).
- `day_plan_item`: items of that plan, `SELECT *` (all columns are small).

Kit models `DayPlan` / `DayPlanItem` mirror the desktop models (row-dict
payloads, no Codable), carrying only what the phone renders.

**Actions** — two new `ActionKind`s, `day_plan_item_done` /
`day_plan_item_skip`, applied by `RelayProcessor` through `DayPlanQueries`. The
`cascadeToTask` decision is made on the Mac from the row's `source_type` (the
desktop's rule), never trusted from the phone. Unknown id → `.failed`, the
existing `requireRow` path.

**Today** — a "Plan" section above the calendar: timeblocks with their time
range, then backlog items, a done/total progress line, and the conflict summary
when `has_conflicts`. Swipe actions enqueue done/skip; the existing pending-chip
+ retry machinery (`InboxViewModel`'s pattern) shows in-flight state. A full
list lives behind a detail screen when the plan is long.

### Tests

- Publisher: today's plan and its items are published; yesterday's is not.
- Relay: done cascades to the source task only for `source_type='task'`; skip
  writes `skipped`; unknown item id fails cleanly.
- Mobile: the section renders timeblocks/backlog in order, and a swipe enqueues
  the right action kind.

---

## Verification

Per branch: `swift build && swift test` in `WatchtowerDesktop` and
`WatchtowerKit`, `make mobile-test` (uninstall the sim app first — the shared
on-disk replica trap), `go build ./...` (item 5 touches no Go, but the schema
doc is read there). Real exit codes, no `| tail`.
