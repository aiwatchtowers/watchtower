# Secretary Dashboard — Design

**Date:** 2026-07-06
**Status:** Approved by owner (brainstorm session)
**Builds on:** `docs/superpowers/specs/2026-07-05-inbox-secretary-redesign-design.md` (merged as PR #26)

## Problem

The two-stage inbox secretary (PR #26) surfaces per-message cards. The owner's
verdict after using it: it still reads as "a digest of conversations". What
they actually want is a **work dashboard** — items prepared by the secretary
that correspond to their current goals, from which context is assembled in
place and targets/tracks are created; plus important updates on the
targets/tracks currently in work. The first click never navigates away from
the page.

## Goal

Rebuild the presentation layer (and add one aggregation layer) so the main
screen becomes a secretary-ranked feed of **situations**:

- A situation is a cluster of related signals (Slack threads, Jira, calendar,
  track events, target changes) around one theme — not a single message.
- Goals = the user's active targets and tracks. The secretary matches
  situations to them, but MUST also surface important things outside any goal
  ("держать руку на пульсе" — nothing important slips by). Digests, briefings,
  and the other pipelines are sources, not destinations.
- Work updates (new activity on active targets/tracks) appear as the same
  situation items, linked to their target/track.
- One unified feed, ranked by the secretary. No zones, no chronological dump.
- Everything opens inline; navigation to a target/track/Slack is always an
  explicit second click.

## Non-goals

- No changes to the signal layer semantics: detection, triage, auto-resolve
  (INBOX-02), learned rules (INBOX-04/05/06), and the watermark (INBOX-09)
  stay exactly as merged.
- No write actions to Slack.
- No changes to the Briefings / Day Plan / Tracks / Targets tabs beyond the
  sidebar default; they remain the "detail/archive" views.
- Per-message secretary cards (why_matters / thread_digest / draft_reply on
  `inbox_items`) are retired from the UI and no longer generated; the columns
  remain in the schema as dormant legacy (no destructive migration in this
  iteration).

## Architecture (chosen: situation composer on top of the existing engine)

Considered alternatives: (B) direct situation extraction by a strong model
over the raw stream — rejected: expensive, non-deterministic, discards the
cheap triage filter just built; (C) UI-only heuristic grouping of existing
cards — rejected: keeps the "digest of conversations" feel, no goal matching.

```
Pipeline (internal/inbox, per sync cycle — extends the merged Run):
  detect → triage → learn → auto-resolve
        → situation composer   (NEW, inbox.compose, strong tier, one batch call)
        → situation cards      (NEW, inbox.situation_card, strong tier, per situation)
        → archive/unsnooze → watermark   (unchanged)
```

### Situation composer (`inbox.compose`)

One batched strong-model call per cycle. Input:

1. New/updated pending signals (`inbox_items`, all trigger types incl.
   `stream`) since the last compose pass.
2. New `track_events` (created_at past the compose watermark) and targets
   whose `updated_at` moved past it (targets have no event log — the diff on
   `updated_at` IS the change signal), for ACTIVE tracks/targets only. The
   compose watermark is a `workspace.compose_last_run_ts` scalar, advanced
   only on a successful compose pass.
3. All currently OPEN situations (id, title, kind, linked signal summaries) —
   so new signals merge into existing situations instead of duplicating them.
4. The secretary brief (existing `buildSecretaryBrief`) + learned rules
   (existing `buildUserPreferencesBlock` semantics); hard-muted signals are
   filtered before the AI sees them.

Output (JSON): a list of operations —
- `create`: new situation {title, kind, priority, reason, member signal keys,
  optional target_id/track_id}
- `merge`: add signal keys to an existing situation id (optionally retitle /
  re-rank / refresh reason)
- `rerank`: change priority/rank of an existing situation
- Situations are ranked against the brief: goal-linked work first-class,
  important out-of-goal situations must still rank up (the "не проебать"
  contract).

`kind`: `external` (no goal link) | `target_update` | `track_update` |
`mixed`. Composer failures leave all situations untouched (feed stability,
DASH-02); the composer pass has its own watermark-free idempotency — signals
not yet composed are picked up next cycle (tracked via a `composed_at` marker
on `inbox_items`).

### Situation cards (`inbox.situation_card`)

Per-situation strong-model call producing the **context packet**:
- `summary` — what is happening, current state first;
- `why_matters` — judged against the brief (which goal it touches / why it
  matters even outside goals);
- `chronology` — ordered list of member signals with one-line essence each
  (the UI renders originals expandable inline from the stored signals).

Card generation mirrors the merged per-item card mechanics: `card_status`
none/ready/failed on the situation, failures retry next cycle, item visible
in the feed immediately after compose with title+reason placeholder.
Regenerated when new signals merge in (card_status resets to `none`).

## Data model

New tables (goose migration, mirrored into schema.sql, golden regenerated):

```
situations:
  id, title, kind CHECK(external|target_update|track_update|mixed),
  status CHECK(open|done|dismissed|converted|stale|snoozed),
  snooze_until TEXT NOT NULL DEFAULT '',
  priority CHECK(high|medium|low), rank REAL,
  ai_reason, summary, why_matters, chronology,
  card_status CHECK(none|ready|failed), card_generated_at,
  target_id NULLABLE, track_id NULLABLE,
  converted_target_id NULLABLE, converted_track_id NULLABLE,
  last_signal_at, created_at, updated_at, resolved_reason

situation_signals:
  situation_id → situations(id) ON DELETE CASCADE,
  inbox_item_id → inbox_items(id) ON DELETE CASCADE,
  UNIQUE(situation_id, inbox_item_id)
```

`inbox_items` gains `composed_at TEXT` (marker: signal was seen by a compose
pass). Signal lifecycle stays owned by the existing engine.

## Lifecycle

- `open` → `done`/`dismissed` by explicit user action on the dashboard.
- `open` → `snoozed` (1h / tomorrow / Monday) hides the situation until
  `snooze_until`; the existing unsnooze phase flips it back to `open`.
- `open` → `stale` automatically when no new signals for
  `dashboard.stale_after_days` (default 7); stale situations leave the feed.
- `open` → `converted` when the user creates a target/track from it (link
  recorded in converted_target_id/converted_track_id). Subsequent activity on
  that target arrives as new `target_update` situations.
- Signal auto-resolve feeds situation state: when ALL member signals of an
  open situation are resolved, the next compose pass proposes auto-close
  (status `done`, resolved_reason `signals_resolved`).
- Feedback: 👍/👎 on a situation maps to the existing learned-rules engine via
  the scopes (sender/channel) of its member signals — INBOX-04/05/06
  mechanics untouched. Mute rules filter signals before compose.

## Desktop UI

- The Inbox tab becomes **Dashboard** and is the app's default destination on
  launch. Inner tabs: Dashboard | Learned | Profile (Learned/Profile move
  over unchanged).
- One ranked feed of situations. Compact row: title + kind badge (colored
  target/track badge for work updates) + one-line why-it-matters.
- Click expands inline (single-open, like the current feed): context packet
  (summary, why-it-matters, chronology with expandable original signals) +
  action row:
  - **Create target** / **Create track** — explicit buttons, prefilled from
    the situation via the existing mechanisms (`TargetPrefillBuilder` for
    targets; the compose-flow `CustomTrackManagementSheet` for tracks); user
    stays on the dashboard after creation. ("Attach to existing track" is
    deferred — no linking mechanism exists in the app today and the owner
    asked only for create.)
  - Done / Dismiss / Snooze (1h / tomorrow / Monday), 👍/👎 feedback.
  - "Open in Slack" / "Open target/track" — explicit second-click navigation.
- AI failure never blanks the feed: existing situations render from the DB
  regardless of the last cycle's outcome.
- English UI copy.

## CLI

`watchtower situations` (list open, ranked) and `watchtower situations show
<id>` (context packet). Minimal — Desktop-first feature.

## Behavior contracts

Signal-layer contracts (`docs/inventory/inbox-pulse.md`) keep their guard
tests untouched, with one owner-approved wording update: INBOX-01's
observable ("the UI distinguishes two tiers visually") moves to the signal
layer — action/awareness classes still exist on signals, still feed the
composer, and the AI still may only downgrade (guards unchanged); the
dashboard surfaces them through situation ranking instead of two visual
sections. This spec is the owner approval for that rewording. New file
`docs/inventory/dashboard.md`:

- **DASH-01 — situations merge, not duplicate:** a new signal on an existing
  open theme joins that situation; the composer receives open situations
  precisely to prevent duplicates.
- **DASH-02 — AI failure does not lose the feed:** a composer or card failure
  leaves existing situations, their ranks, and their cards untouched
  (transplant of the INBOX-07 principle).
- **DASH-03 — conversion keeps the link:** creating a target/track from a
  situation records the link both ways; the situation history remains
  reachable from the born entity.

## Testing

- Guard tests for DASH-01..03 (Go, mock generator; composer merge behavior,
  failure stability, conversion links).
- Prompt-contract tests for `inbox.compose` and `inbox.situation_card` on
  both providers (routing tables + mock-driven pipeline tests).
- Swift: ViewModel tests for the ranked feed, inline expansion, conversion
  actions, badge rendering; queries tests for the situations tables.
- Composer idempotency: `composed_at` marker — a failed compose pass leaves
  signals eligible for the next pass, none skipped.

## Rollout

- Migration creates `situations`/`situation_signals`, adds
  `inbox_items.composed_at`; existing pending signals are picked up by the
  first compose pass (no backfill needed).
- Per-item card generation stops (runCards retired; `inbox.card` prompt
  deregistered like `inbox.prioritize` was); `inbox_items` card columns stay
  dormant.
- Config: `dashboard.stale_after_days` (7), `dashboard.max_situations_per_compose`
  (safety cap on composer input, default 200 signals).
- Docs updated in the same change: `docs/inventory/dashboard.md` (new),
  `docs/inventory/inbox-pulse.md` (note that presentation moved to
  dashboard), `docs/app-guide.md` (Dashboard section), `CLAUDE.md`.
