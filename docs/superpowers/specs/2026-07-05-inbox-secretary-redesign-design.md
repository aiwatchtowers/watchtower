# Inbox Secretary Redesign — Design

**Date:** 2026-07-05
**Status:** Approved by owner (brainstorm session)
**Replaces the decision core of:** `docs/superpowers/specs/2026-04-23-inbox-pulse-design.md`

## Problem

The current Inbox Pulse is perceived as dumb: it surfaces irrelevant items and
misses what actually matters. The root cause is the decision chain — algorithmic
trigger detection (mention / DM / Jira / calendar) → per-trigger class rules →
batch AI prioritization without user context → separate pinned selector. Nothing
in that chain looks at the *whole* message stream with knowledge of who the user
is, so "important but not mentioning me" is invisible (the known INBOX-03 gap)
and "mentioning me but worthless" scores high.

## Goal

Rebuild the inbox decision core as a **continuous smart secretary**:

- Runs every daemon sync cycle (~5–10 min latency is acceptable).
- AI reads the **entire stream** of newly synced messages/events, not just
  triggers. Triggers (mention, DM, Jira, calendar, target_due) remain
  guaranteed candidates.
- Two tiers, no chronological everything-feed:
  **Action** (needs me personally) and **Awareness** (important FYI).
- Every surfaced item carries a secretary card: **why this matters to me**,
  a **collapsed thread digest**, and a **draft reply**.
- The secretary knows the user from three sources: an explicit user-written
  profile, auto-context assembled from Watchtower data (tracks, people, Jira,
  calendar), and the existing learned-rules mechanism.

## Non-goals

- Sending replies to Slack (draft is copy-paste only; Watchtower stays
  read-only towards Slack).
- Sub-minute latency / real-time event contour.
- Redesigning the learner, feedback, auto-resolve, or snooze mechanics — they
  are kept as-is.

## Architecture (chosen: two-stage secretary)

Considered alternatives: (B) evolving the current pipeline by adding a
full-stream detector on top — rejected because it keeps the decision chain the
owner explicitly wants gone; (C) an agentic AI session with DB tools each cycle
— rejected as non-deterministic, expensive, and untestable for a
trust-critical surface.

The package stays `internal/inbox/`. The storage (`inbox_items`), lifecycle
(pending/resolved/snoozed), auto-resolve, learner/feedback, and watermark
survive. The decision core is replaced:

```
Layer 0 — Candidates (SQL, free)
  ├─ triggers: mention, DM, jira, calendar, target_due  → guaranteed candidates
  └─ ALL new messages since the watermark               → ordinary candidates

Layer 1 — Triage scan (cheap model: haiku/mini tier, 1–2 batch calls per cycle)
  input:  message snippets grouped by channel + the secretary brief
  output: per candidate → action / awareness / ignore + one-line reason
  rule:   trigger candidates cannot be dropped to ignore, only demoted to
          awareness (hard-muted user_rule sources are filtered out before AI)

Layer 2 — Secretary card (strong model: sonnet/gpt tier, one call per item)
  scope:  all action items + up to N awareness items per cycle
          (config inbox.max_awareness_cards, default 3)
  input:  full thread, conversation history, track/person context
  output: why-it-matters + thread digest + draft reply
  UX:     the item is visible in the feed right after triage (snippet only);
          the card catches up asynchronously

Layer 3 — Lifecycle (unchanged): auto-resolve, unsnooze, awareness auto-archive
```

### Deleted from the old pipeline

- `classifier.go` — per-trigger class rules (replaced by triage tiers).
- `aiPrioritizeNewItems` + `inbox.prioritize` prompt — batch 1–5 priority.
- `pinned_selector.go` + its prompt + the `pinned` column — two tiers replace
  pinned+feed; no separate pinning AI call.

### Volume & failure behavior

- Triage input is chunked (~150 snippets per call); a config cap bounds one
  cycle's work. On overflow (e.g. post-vacation flood) the remainder is
  processed next cycle — the watermark only advances over what was actually
  triaged (INBOX-09 principle preserved).
- Triage call fails → watermark frozen, existing feed untouched (INBOX-07
  principle).
- Card call fails → item stays with snippet, `card_status='failed'`, retried
  next cycle.

## The Secretary Brief

Assembled by `buildSecretaryBrief()` each cycle and injected into both prompts:

1. **Explicit profile** — free text written by the user (role, projects,
   people, what counts as urgent). Stored in the DB (single record), editable
   in Desktop from the Inbox screen. This is the primary steering wheel: when
   the inbox is dumb, the user edits the brief and the next cycle behaves
   differently.
2. **Auto-context from Watchtower** — queried per cycle: active tracks (name +
   one-liner), key people from the People pipeline, the user's open Jira
   issues, today/tomorrow calendar.
3. **Learned rules** — existing learner unchanged: mute/boost weights injected
   as today (`buildUserPreferencesBlock`), hard-mutes filter candidates before
   AI, `source='user_rule'` stays protected.

## Data model

`inbox_items` is kept; changes:

- `class` values keep the actionable/ambient enum storage but the semantics
  become **action / awareness** (awareness auto-archives like ambient today).
- New columns: `triage_reason` (one-liner from Layer 1), `why_matters`,
  `thread_digest`, `draft_reply`,
  `card_status` (`none`/`ready`/`failed`), `card_generated_at`.
- Dropped: `pinned`.
- Prompt store: new `inbox.triage` (cheap tier) and `inbox.card` (strong
  tier); `inbox.prioritize` and the pinned prompt are removed.
- Migration via goose per `add-migration` skill (schema.sql mirror, golden
  snapshot, `TestAllTablesExist`).

## Desktop UI

- Two tiers replace pinned+feed: **"Требует действия"** on top (cards
  expanded), **"К сведению"** below (compact rows, expand on click).
- Card: title + who/where + why-it-matters + thread digest + draft reply with
  a Copy button + actions (Done / Snooze / 👎 feedback / open in Slack).
- Items appear immediately after triage with the snippet and a
  "готовлю контекст…" placeholder; the card fills in when ready.
- The **Learned** tab stays; a **Profile** editor (the explicit brief) is
  added next to it.

## Behavior contracts (docs/inventory/inbox-pulse.md)

- **Kept as-is:** INBOX-02 (auto-resolve on user reply), INBOX-04/05/06
  (gradual learning, visibility, manual-rule supremacy), INBOX-09 (watermark
  never advances on failure).
- **Rewritten:** INBOX-01 (two tones → two tiers; "AI may only downgrade"
  stays), INBOX-07 (AI-failure stability now covers triage + cards instead of
  pinned).
- **Closed:** INBOX-03 — the full-stream triage with the secretary brief IS
  the learned signal-vs-noise scoring the gap tracked.
- Pinned-specific guard tests are replaced by tier analogs (e.g. "muted
  sources never reach the action tier"). All contract edits ship with owner
  approval as part of this work.

## Testing

- Guard tests for kept contracts remain untouched.
- New: triage chunking, "trigger cannot be dropped to ignore", card retry
  after failure, brief assembly, watermark-frozen-on-triage-error.
- Prompt contract tests for `inbox.triage` and `inbox.card` on **both**
  providers (claude + codex) per the `add-ai-prompt` skill.
- Desktop: ViewModel tests for the two-tier feed, card placeholder → ready
  transition, profile editor persistence.

## Rollout notes

- Existing pending items survive the migration (class semantics map 1:1).
- `docs/inventory/inbox-pulse.md`, `internal/db/schema.sql`, and
  `docs/app-guide.md` (chat-bot system prompt) are updated in the same change.
