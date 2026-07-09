# Feed Dashboard — Social-Wall Inbox Design

**Date:** 2026-07-09
**Status:** Approved for planning
**Branch:** feature/secretary-dashboard (or successor)

## Problem

The Dashboard tab currently shows one kind of item: ranked open situations.
The user wants the inbox to read like a social-network wall — a single
chronological feed where the secretary also posts time-anchored items
(upcoming meetings, briefings, meeting recaps, day plans), with history
preserved and a filter bar on top.

## Decisions (from brainstorm)

1. **Feed model:** single chronological feed (`event_ts DESC`) mixing all
   item types. Rank no longer orders the list; it feeds the importance
   filter and visual emphasis.
2. **Item types in this iteration:** situations (existing), upcoming
   calendar meetings (published N minutes before start), briefings,
   meeting recaps, day plans. Track/target/Jira observations, learned-rule
   announcements, catch-up and system items are explicitly out of scope —
   each is a later `item_type` addition.
3. **Lifecycle:** items stay in the feed as history; they scroll down as
   time passes. A filter bar hides irrelevant items and filters by
   importance.
4. **Architecture:** feed index table (`feed_items`) holding per-item
   state only; content is always joined live from source tables. No
   content duplication.
5. **UX:** master-detail stays. The left list becomes the mixed feed;
   the right pane switches per item type.

## Data Model

Migration `00013_feed_items.sql` (goose, per `add-migration` skill —
mirror into `schema.sql`, add to `TestAllTablesExist`, regenerate golden):

```sql
CREATE TABLE feed_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item_type   TEXT NOT NULL CHECK (item_type IN
                  ('situation','meeting','briefing','meeting_recap','day_plan')),
    source_id   TEXT NOT NULL,   -- situations.id / calendar_events.id /
                                 -- briefings.id / day_plans.id (recap: event_id)
    event_ts    TEXT NOT NULL,   -- ISO8601, chronological position
    importance  INTEGER NOT NULL DEFAULT 50,   -- 0..100
    hidden_at   TEXT,            -- user hid the item (never reset by publisher)
    seen_at     TEXT,            -- set when the user selects the row
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(item_type, source_id)
);
CREATE INDEX idx_feed_items_event_ts ON feed_items(event_ts DESC);
```

## Publisher — `internal/feed`

`feed.Publish(db, cfg, now)` — pure SQL scan, **zero AI calls**, invoked
by the daemon at the end of each cycle, outside `inbox.Run`. All writes
are upserts keyed on `UNIQUE(item_type, source_id)`.

| Source | Published when | `event_ts` | `importance` |
|---|---|---|---|
| `situations` (status=open) | on create/merge/rerank | situation `updated_at` | from `priority`: high=90, medium=60, low=30 |
| `calendar_events` | within `feed.meeting_lead_minutes` (config, default 30) of `start_time` | `start_time` | 70 |
| `briefings` | new row | `created_at` | 60 |
| `meeting_recaps` | new row | `created_at` | 60 |
| `day_plans` (active) | new row / regeneration | `generated_at` | 60 |

Consequences of `event_ts = start_time` for meetings: an upcoming meeting
sits at the top of the DESC feed until its start time passes, then slides
down naturally — no expiry logic. A situation merge bumps `updated_at`,
so the feed item resurfaces like a bumped thread.

**Bootstrap guard:** on first run after the migration, only rows created
after the feature's introduction are published (cutoff recorded in
`sync_state`), so years of old briefings/recaps don't flood the feed.

**Publisher invariants:**
- never touches source tables;
- never deletes feed rows (hide = `hidden_at`, history stays);
- re-upsert never resets `hidden_at`/`seen_at`;
- per-source transactions: one broken source (e.g. bad `recap_json`)
  is logged and skipped, the rest still publish;
- a `feed.Publish` error never fails the daemon cycle and never affects
  inbox watermarks.

## Desktop (SwiftUI)

**Feed query.** `FeedQueries.fetchFeed(filter:)` joins `feed_items` to
source tables, `ORDER BY event_ts DESC`, returning:

```swift
enum FeedItemContent {
    case situation(Situation)
    case meeting(CalendarEvent, prep: MeetingPrep?)
    case briefing(Briefing)
    case meetingRecap(MeetingRecap, event: CalendarEvent)
    case dayPlan(DayPlan)
}
```

An item whose source row fails to load is dropped from the list (no
error placeholders).

**Left list.** `SituationRow` unchanged; new compact rows per type
(`MeetingFeedRow`, `BriefingFeedRow`, `RecapFeedRow`, `DayPlanFeedRow`)
with a type icon, title, and time. Unseen items get an unread accent.

**Filter bar** above the list:
- type chips (Situations / Meetings / Briefings / Recaps / Plans);
- "Important only" toggle (`importance >= 70`);
- "Show hidden" toggle (hidden excluded by default).

Filter state is UI-local (`@AppStorage`), not in the DB.

**Right pane** switches on the selected item's type:
- situation → existing `SituationReviewPane` (unchanged);
- meeting → meeting-prep card (attendees with people-card links,
  context, `html_link`) reusing existing meeting-prep components;
- briefing → attention / your_day / what_happened sections reusing
  Briefing tab components;
- recap → `recap_json` render with action items;
- day plan → time blocks + backlog reusing Day Plan tab components.

**Actions.** "Hide" on any item writes `hidden_at` via `FeedQueries`;
selecting a row stamps `seen_at`. Situation actions (feedback, Target/
Track conversion, Discuss chat) are unchanged — all DASH-01..04 and
INBOX contracts untouched.

**ViewModels.** New `FeedViewModel` owns the feed list + filters;
`DashboardViewModel` keeps serving the situation-specific actions.

## Error Handling

- Publisher: best-effort per source; log-and-continue on bad rows;
  whole-publish failure is logged, daemon cycle proceeds.
- Swift: missing/broken source rows are silently omitted from the feed.

## Testing

Go (`internal/feed/`):
- happy path per type: source row appears → feed item with correct
  `event_ts`/`importance`;
- idempotency: repeated `Publish` creates no duplicates and does not
  reset `hidden_at`/`seen_at`;
- meeting lead-time: outside window → not published; inside → published;
  bootstrap: pre-cutoff rows never published;
- degradation: one broken source row doesn't block the others
  (valid-but-degenerate input, not just happy + explicit-error);
- situation merge bumps the existing feed item's `event_ts`.

Swift:
- `FeedQueries` join correctness per type;
- filters (type / importance / hidden);
- hide → `hidden_at`; select → `seen_at`.

## New Behavior Contracts (`docs/inventory/dashboard.md`)

- **DASH-05 — Publisher is additive and state-preserving:** the feed
  publisher never deletes feed rows and never resets user state
  (`hidden_at`/`seen_at`) on re-upsert.
- **DASH-06 — Feed publish is AI-free and non-blocking:** `feed.Publish`
  makes no AI calls; its failure never affects the inbox pipeline or its
  watermarks.

## Docs

Update `docs/app-guide.md` (feed, filter bar, per-type panes) — it is
injected into the chat-bot system prompt.

## Out of Scope

Track/target/Jira observations, "learned a rule" announcements, system
items, catch-up items — each lands later as: one new `item_type` value +
one publisher rule + one row view + one detail pane.
