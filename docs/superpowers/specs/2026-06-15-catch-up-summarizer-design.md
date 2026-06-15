# Catch-Up — Unread Summarizer & Bulk Clear

**Date:** 2026-06-15
**Status:** Design approved, ready for implementation plan
**Owner:** Vadym

## Problem

Unread state is spread across five independent counters (digests, tracks, inbox, briefings, plus status-based targets) with no aggregated view and no bulk "mark read". Each area is cleared one item at a time, in its own screen. After a few days away the backlog becomes unmanageable ("дохуище непрочитанного"), and because clearing is manual and per-item, the operator either never catches up or clears blindly and misses genuinely new signals.

### Current unread mechanisms (read-tracked areas only)

| Area | DB column | Unread predicate | Sidebar badge source |
|---|---|---|---|
| Digests | `read_at` | `read_at IS NULL` | `DigestQueries.unreadDigestCount` |
| Tracks | `read_at` + `has_updates` | `has_updates=1 AND dismissed_at=''` | `TrackQueries.fetchCounts → updated` |
| Inbox | `read_at` + `status` | `status='pending' AND archived_at IS NULL AND read_at empty` | `InboxQueries.fetchCounts → unread` |
| Briefings | `read_at` | `read_at IS NULL` | `BriefingQueries.unreadCount` |

Targets/calendar/people are **not** read-tracked (status- or time-based) and are out of scope for clearing.

Existing bulk-ish capability: `DigestViewModel.markDigestsRead(ids: Set<Int>)` marks a *selected* set, not all. No other area has bulk mark-read.

## Goals

- A dedicated **Catch-Up** view that, on demand, produces an AI rollup of *exactly the currently-unread* items across the four read-tracked areas.
- The rollup reads as **thematic stories** that span sources, not a per-folder dump — one topic touched in a digest + a track + an inbox mention becomes one card.
- Clear indicators **per-section** (digests / tracks / inbox / briefings) plus a global "mark everything read".
- Marking operates on a **snapshot of item IDs** captured at rollup time, so items that arrive after generation stay unread — catching up never silently swallows new signal.
- Graceful behavior when the backlog is huge (hundreds unread) or when AI fails.

## Non-goals

- Auto-generation by the daemon or any background AI cost (trigger is on-demand only).
- Persisting rollups to the DB (rollup is ephemeral, regenerated on demand; held in ViewModel memory for the session).
- Read-tracking for targets/calendar/people, or clearing them.
- Replacing or modifying the Daily Briefing pipeline (Catch-Up is read-state-driven; Briefing is "today"-driven — they coexist).
- Map-reduce over the full backlog (caps + prioritization instead — see Section 2).

## Resolved open questions

1. **Targets in rollup** — included only as a read-only context line in the TL;DR ("3 overdue, 5 due today"), never as a clearable section.
2. **Caps** — defaults digests 40 / tracks 20 / inbox 30 / briefings 5, configurable under `catchup.*` in `config.yaml`.

---

## Section 1 — Output shape (`CatchupResult`)

The CLI emits a single JSON object. Two projections over the **same set of item IDs**: `stories` for reading, `sections` for clearing.

```jsonc
{
  "generated_at": "2026-06-15T09:00:00Z",
  "window": { "oldest_unread": "2026-06-08T12:00:00Z" },
  "tldr": "While you were away: <2-3 sentences>. Targets: 3 overdue, 5 due today.",
  "counts": {
    "digests":   { "included": 40, "total": 162 },
    "tracks":    { "included": 11, "total": 11 },
    "inbox":     { "included": 18, "total": 18 },
    "briefings": { "included": 3,  "total": 3 },
    "total_unread": 194, "total_included": 72
  },
  "truncated": true,
  "stories": [
    {
      "title": "Payments migration blocked on infra review",
      "narrative": "2-4 sentences synthesizing the thread across sources.",
      "priority": "high",          // high | medium | low
      "needs_you": true,
      "refs": [
        { "area": "track",  "id": 42, "label": "Payments v2 migration" },
        { "area": "inbox",  "id": 90, "label": "@you in #payments" },
        { "area": "digest", "id": 7,  "label": "#payments daily" }
      ]
    }
  ],
  "sections": [
    {
      "area": "digests",            // digests | tracks | inbox | briefings
      "total": 162, "included": 40,
      "items": [ { "id": 7, "title": "#payments daily", "snippet": "…" } ]
    }
  ]
}
```

- `stories` is the AI's value-add: thematic clusters ranked by `priority`, flagged `needs_you` when they require operator action. `refs` link each story back to source items.
- `sections[].items` is the raw, capped, per-area unread set — the authoritative ID list that drives per-section clearing.
- `truncated` + per-area `included`/`total` surface honestly in the UI ("+122 not shown in summary").

## Section 2 — Backend: `internal/catchup`

New package mirroring the `meeting` / `briefing` pipeline pattern.

**`internal/catchup/pipeline.go`** — `Pipeline{ db *db.DB, gen digest.Generator }`, `Run(ctx, Options) (*CatchupResult, error)`:

1. `gather()` — pulls unread per area via new DB queries, applies per-area caps, ranks by **priority → recency**, and builds compact records (id + title + short snippet only; no full bodies). Captures `total` (uncapped count) per area for `truncated`/`counts`.
2. `buildPrompt()` — assembles the capped records + a targets context line into the `catchup.summarize` prompt.
3. One `gen.GenerateJSON`-style call (same Generator interface used by digest/people/tracks — mockable in tests), parse into `CatchupResult`.
4. Attach the snapshot ID lists into `sections` from the gathered (not AI-returned) data, so clearing is driven by ground truth, not by what the model echoed back.

**`internal/catchup/prompt.go`** — `catchup.summarize`: instruct the model to cluster by topic across sources, rank by importance, set `needs_you`, write a tight TL;DR, and **only reference provided item IDs** (no invention). Targets line passed as read-only context.

**`internal/db`** — new functions:
- Gather: `GetUnreadDigests(limit)`, `GetUpdatedTracks(limit)`, `GetUnreadInboxItems(limit)`, `GetUnreadBriefings(limit)` — each returns capped, ranked compact rows + the total count.
- Bulk mark-read **by explicit ID list**: `MarkDigestsRead([]int)`, `MarkTracksRead([]int)` (sets `read_at`, `has_updates=0`, cascades like `MarkTrackRead`), `MarkInboxReadBulk([]int)`, `MarkBriefingsRead([]int)`. Idempotent — already-read IDs are no-ops.

**`cmd/catchup.go`** — `watchtower catchup --json [--limit N] [--max-age 30d]`, selecting provider via existing `cliGenerator()`. Mirrors `meeting-prep`.

**Config** — `catchup.caps.{digests,tracks,inbox,briefings}` with the Section-0 defaults; `catchup.max_age_days` (default 30) to ignore very old unread.

## Section 3 — Desktop: `CatchUpView`

- **Sidebar**: new **Catch Up** entry at the top of `SidebarView`, badge = sum of the four unread counts already in `SidebarCountsViewModel` (no new query needed for the badge).
- **`CatchUpViewModel`** (`@MainActor @Observable`): runs `watchtower catchup --json` via the existing AIService subprocess pattern (cf. `MeetingPrepViewModel`), parses `CatchupResult`, holds it + the snapshot ID lists in memory for the session. `regenerate()` re-runs. `markSectionRead(area)` and `markAllRead()` call the bulk Swift queries with the snapshot IDs, then refresh `SidebarCountsViewModel`.
- **`CatchUpView`** layout: TL;DR header → story cards (color by `priority`, "needs you" flag, tappable `refs` navigating to the source item) → "By source" collapsible sections, each with a **Mark read** button and an "+N not shown" note when `included < total` → footer **Mark everything read**.
- **Swift bulk queries** mirroring the Go funcs: `DigestQueries.markRead(ids:)` (exists), plus `TrackQueries.markRead(ids:)`, `InboxQueries.markRead(ids:)`, `BriefingQueries.markRead(ids:)`.

## Section 4 — Edge cases

- **Snapshot by ID** — mark-read affects only IDs captured in the rollup; items arriving after generation remain unread.
- **Zero unread** — empty state ("Всё разгребено"), no AI call.
- **AI failure / timeout** — fall back to a rollup with `stories` empty and `sections` populated from `gather()` directly; clearing still works (don't block unloading on AI).
- **Truncation** — surfaced per section and in `counts`.
- **Idempotent marking** — already-read / newly-arrived-after-snapshot IDs are safely skipped.

## Section 5 — Testing

**Go (`internal/catchup`, `internal/db`):**
- `mockGenerator` returns canned JSON → pipeline parses into `CatchupResult`.
- `gather()` respects per-area caps and ranking; reports correct `total` vs `included`.
- Bulk mark-read marks **only** snapshot IDs and leaves other unread rows untouched; idempotent on already-read IDs; track cascade preserved.
- Zero-unread short-circuit (no Generator call).
- AI-failure fallback yields populated `sections`, empty `stories`.

**Swift (`WatchtowerDesktop`):**
- `CatchUpViewModel` parses a fixture `CatchupResult`.
- `markSectionRead` / `markAllRead` invoke the right bulk queries with snapshot IDs and trigger a counts refresh.
- Empty state when no unread.
