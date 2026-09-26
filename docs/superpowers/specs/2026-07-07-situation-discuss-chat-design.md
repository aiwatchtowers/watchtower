# Situation Discuss Chat + Communication Style Profile — Design

**Date:** 2026-07-07
**Status:** Approved by owner (brainstorm session)
**Builds on:** `docs/superpowers/specs/2026-07-07-inbox-master-detail-design.md` (master-detail Dashboard, shipped on `feature/secretary-dashboard`)

## Problem

Reviewing a situation often ends with "now I have to go write the reply
myself." The owner wants to discuss a situation with the secretary right in
the review pane and get a ready-to-send Slack reply — written in *their own
voice*, not generic assistant prose. Today the app has a per-target chat
(`TargetChatViewModel`/`TargetChatView`) but nothing situation-scoped, and no
notion of the user's communication style.

## Goal

Two connected deliverables:

1. **Communication style profile** — a persisted, human-editable distillation
   of how the owner actually writes on Slack, generated on demand from their
   own synced messages (plus their People-pipeline card), managed from the
   Inbox → Profile tab.
2. **Discuss chat** — a collapsed chat section at the bottom of
   `SituationReviewPane`. Expanding shows a persisted per-situation
   conversation with the secretary; a **Draft reply** button (or a plain
   request in chat) produces a ready-to-send reply in the thread's language
   and the owner's style, with one-click copy. Sending is always manual:
   copy + the existing "Open in Slack" deep links.

## Non-goals

- **No Slack write access.** The app never posts; the draft flow ends at
  copy + deep link (unchanged dashboard-spec constraint).
- **No auto-draft / no AI call on expand.** The chat is inert until the
  owner sends a message or clicks Draft reply.
- **No per-audience style profiles** in v1 — one profile; the per-thread
  register comes from injecting the owner's recent messages in the
  situation's channels at prompt-build time.
- Catch-Up, DASH-01..04, INBOX-01..09 untouched. No changes to compose,
  triage, situation cards, or feedback paths.
- No changes to the global Chat tab (`ChatViewModel`) or Target chat.

## Part 1 — Communication style profile

### Storage

Goose migration (00013): `ALTER TABLE workspace ADD COLUMN style_profile
TEXT NOT NULL DEFAULT ''` and `style_profile_updated_at TEXT NOT NULL
DEFAULT ''`. Mirror into `internal/db/schema.sql`, regenerate the schema
golden, mirror into the Swift test schema (`TestDatabase.swift` — known
drift trap).

### Generation pipeline (Go)

New CLI: `watchtower inbox style-sample` (in `cmd/inbox.go`, wired like
`inbox feedback`). Flow in `internal/inbox/style_sample.go`:

1. Resolve `workspace.current_user_id`.
2. Sample the owner's sent messages from the synced DB: most recent ~150,
   split across audiences — DMs, private, and public channels — capped per
   conversation so one noisy channel doesn't dominate. Pure SQL, no AI.
3. Fetch the owner's own latest `people_cards` row (if any):
   `communication_style` + `summary` as an extra analyst's view.
4. One AI call (strong tier; `digest.Generator`, source tag
   `inbox.style_sample`; package-private prompt const — same decision as
   `inbox.situation_learn`, not store-registered) that distills: languages
   used and when, tone/formality by audience (DM vs channel, insiders vs
   external partners), typical phrases and quirks, sign-off habits. Output:
   plain text (not JSON) meant to be pasted into a drafting prompt.
5. Persist to `workspace.style_profile` + timestamp. **An AI failure or
   empty sample leaves the stored profile untouched** (DASH-02 spirit).

### Desktop (Inbox → Profile tab)

`SecretaryProfileView` gains a second section, "Communication style":
- Editable `TextEditor` bound to `workspace.style_profile` with the same
  Save affordance as the secretary brief (hand edits are first-class — the
  generator writes a starting point, the owner curates it).
- "Generate from my messages" button → runs the CLI via `CLIRunnerProtocol`.
  Generation state (`isGenerating`) lives in an AppState-owned VM
  (`SecretaryProfileViewModel`, new) so an in-flight run survives tab/sidebar
  navigation — same rule that moved `DashboardViewModel` into AppState.
  On completion the editor reloads from DB (a hand-edit in progress is not
  silently overwritten: Generate is disabled while the editor has unsaved
  changes).

## Part 2 — Discuss chat in the review pane

### ViewModel

`SituationChatViewModel` (new) mirrors `TargetChatViewModel` wholesale:
- Conversation persisted in the existing `chat_conversations` /
  `chat_messages` tables with `contextType: "situation"`, `contextID:
  String(situation.id)`, title `"Situation: <title prefix>"`. No migration
  needed (Swift-managed table, `context_type` is unconstrained TEXT).
- Streaming via `AIServiceProtocol` (`WatchtowerAIService`), session resume
  semantics identical to Target chat (system prompt sent only on the first
  message of a session; codex never resumes — handled by the service).
- Owned as `@State` by the pane per selected situation (`.id(situation.id)`
  resets it on selection change). History reloads from DB on re-open; an
  in-flight stream cancelled by switching situations is acceptable — Target
  chat parity.

### System prompt (pure builder, unit-testable)

`SituationChatViewModel.buildSystemPrompt(situation:memberSignals:db:)`
assembles, in order:
- Secretary role preamble + the hard rule: a requested draft must be
  ready-to-send Slack text in the owner's voice — thread language, no
  meta-commentary, no signatures the owner wouldn't type.
- Situation context: title, kind, priority, why-it-matters, summary,
  chronology; linked target/track one-liners when set.
- Member signals verbatim (sender display name, channel, time, text).
- `workspace.secretary_profile` (who the owner is).
- `workspace.style_profile` (how the owner writes) — omitted cleanly when
  empty, with a fallback line telling the model to mirror the owner's
  messages quoted below.
- Counterparty briefs: for each distinct non-owner sender among member
  signals, the latest `people_cards` row's `communication_style`,
  `communication_guide`, `relationship_context` (skip when absent).
- Register sample: the owner's last ~10 messages in each of the situation's
  channels/DMs (from synced messages) — the concrete voice to imitate with
  this audience.

### View

`SituationDiscussSection` (new file) rendered at the bottom of
`SituationReviewPane`'s scroll content, below member signals:
- Collapsed `DisclosureGroup`-style header "Discuss with secretary" (with a
  message-count badge when a persisted conversation exists). Nothing is
  created or called while collapsed beyond a cheap conversation-exists read.
- Expanded: message list (reusing the app's chat bubble components where
  they fit), input field + send, and a **Draft reply** button that sends a
  canned user message ("Draft a reply I can send in this thread").
- Every assistant message gets a **Copy** button; the pane's existing
  Sources block already covers "open the thread in Slack".
- Errors surface inline in the section (CLI/AI failure never blanks the
  pane or the feed).

## Error handling

- Style generation: CLI failure → error banner in the Profile section,
  stored profile untouched. Empty message sample (fresh DB) → explicit
  "not enough messages yet" error, no AI call.
- Chat: stream errors append an inline error row (Target chat behavior);
  the conversation stays usable; no effect on situation state.

## Testing

- **Go:** style-sample gathering query (only `current_user_id` messages,
  caps respected, mixed audiences); AI failure leaves `style_profile`
  untouched; empty-sample short-circuits without an AI call (degenerate
  clean-exit case); CLI registration/flags tests (mirroring `inbox
  feedback`'s).
- **Swift:** `buildSystemPrompt` includes/omits each block correctly
  (style profile present vs empty, counterparty card present vs absent,
  register sample scoping); conversation created with
  `contextType "situation"` and reloaded on reopen; Draft-reply button
  sends the canned message through the mocked service; profile VM —
  generate re-entry guard, unsaved-edit guard, state survives simulated
  navigation (VM identity in AppState).
- Guard tests DASH-01..04, INBOX-01..09 stay green and unmodified.

## Docs

- `docs/app-guide.md`: Discuss section + Profile "Communication style".
- `CLAUDE.md`: feature-notes bullet.
- `docs/inventory/dashboard.md` candidate (decide at review): "Discuss is
  inert until first user action — no AI call on expand."
