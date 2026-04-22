# Day Plan — Design Spec

**Date:** 2026-04-23
**Status:** Approved (brainstorm complete, pending implementation plan)
**Branch:** feature/jira-integration (base for new feature branch)

## Context

Watchtower already has a **Briefing** pipeline (`internal/briefing/`) that aggregates digests, tasks, tracks, people, and calendar into an informational morning summary with 5 JSON sections (`attention`, `your_day`, `what_happened`, `team_pulse`, `coaching`). Briefing answers *"what's happening and what to watch."*

Users need a complementary **actionable** layer: a personal, time-aware plan for the day with explicit time-blocks for deep work, an ordered backlog for "if time permits" items, interactive editing, and calendar-change awareness. Briefing is not the right place to add this — it would tangle read-model and action-model, break regeneration semantics, and bloat the briefing prompt.

This spec introduces a new **Day Plan** entity as a sibling to Briefing.

## Goals

- Generate a personalized day plan each morning after briefing completes.
- Hybrid format: up to 3 AI-scheduled time-blocks (9:00–19:00 window) + 3–8 backlog items.
- Calendar events are first-class, read-only items in the plan; new events after generation flag conflicts.
- Interactive edits in Desktop: delete, add manual, reorder backlog, mark done, cascade to `tasks`, regenerate with free-form feedback.
- Manual user items are preserved across regeneration.
- CLI provides read + generate + reset + conflict-check for scripting / debugging; interactive editing is Desktop-only.
- Graceful degradation: missing briefing, missing calendar, missing Jira — plan still generates.

## Non-Goals (MVP)

- Manual timeblock move/resize — users regenerate-with-feedback instead.
- Explicit pin/unpin of items — manual items (`source_type=manual`) are implicitly pinned.
- Notes/comments on items.
- Plan-version history (regeneration overwrites non-manual items in place).
- Multi-user support (single-user, `user_id=me` pattern as the rest of the project).
- Auto-skip weekends/holidays (hour-gate only, same as briefing).
- Push notifications for conflicts (in-app banner only).
- Inbox or Tracks as day-plan inputs (they belong to different user journeys).

## High-Level Architecture

```
sync → inbox → channel_digests → tracks → rollups → people → briefing → day_plan → calendar_sync → conflict_detection
```

- **`internal/dayplan/`** (new Go package): pipeline, prompt, gather, merge, conflict detection.
- **`internal/db/dayplans.go`** + migration `v47`: `day_plans` + `day_plan_items` tables.
- **`internal/daemon/`**: new phase 7 (Day Plan) after briefing + phase 9 (Conflict Detection) after calendar sync.
- **`cmd/day_plan.go`**: `watchtower day-plan {show|list|generate|reset|check-conflicts}`.
- **`internal/prompts/`**: new `day_plan.generate` template registered in `defaults.go`.
- **Swift Desktop (`WatchtowerDesktop/`)**: models, queries (GRDB), `DayPlanViewModel` (@Observable), views (timeline + backlog + conflict banner + regenerate sheet), settings panel.

Go handles all backend concerns (generation, persistence, CLI, daemon). Swift handles UI (timeline, drag-reorder, edit actions). Swift mutates DB directly via GRDB for edits; regeneration is shelled out to `watchtower day-plan generate --feedback ...` via a `CLIRunnerProtocol` abstraction.

## Data Model

### Migration `0047_day_plan.sql`

```sql
CREATE TABLE day_plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    plan_date TEXT NOT NULL,                     -- YYYY-MM-DD, local date
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'archived')),
    has_conflicts INTEGER NOT NULL DEFAULT 0,
    conflict_summary TEXT,
    generated_at TEXT NOT NULL,
    last_regenerated_at TEXT,
    regenerate_count INTEGER NOT NULL DEFAULT 0,
    feedback_history TEXT,                       -- JSON []string
    prompt_version TEXT,
    briefing_id INTEGER,
    read_at TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (user_id, plan_date),
    FOREIGN KEY (briefing_id) REFERENCES briefings(id) ON DELETE SET NULL
);

CREATE INDEX idx_day_plans_date ON day_plans(plan_date DESC);
CREATE INDEX idx_day_plans_user_date ON day_plans(user_id, plan_date DESC);

CREATE TABLE day_plan_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day_plan_id INTEGER NOT NULL,
    kind TEXT NOT NULL
        CHECK (kind IN ('timeblock', 'backlog')),
    source_type TEXT NOT NULL
        CHECK (source_type IN ('task', 'briefing_attention', 'jira', 'calendar', 'manual', 'focus')),
    source_id TEXT,                              -- NULL for manual/focus
    title TEXT NOT NULL,
    description TEXT,
    rationale TEXT,
    start_time TEXT,                             -- RFC3339, required if kind=timeblock
    end_time TEXT,                               -- RFC3339, required if kind=timeblock
    duration_min INTEGER,
    priority TEXT CHECK (priority IN ('high','medium','low')),
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'done', 'skipped')),
    order_index INTEGER NOT NULL DEFAULT 0,
    tags TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (day_plan_id) REFERENCES day_plans(id) ON DELETE CASCADE
);

CREATE INDEX idx_day_plan_items_plan ON day_plan_items(day_plan_id);
CREATE INDEX idx_day_plan_items_source ON day_plan_items(source_type, source_id);
```

`tasks` table and `feedback` table CHECK constraints are **unchanged**. `day_plan_items.source_id` is generic TEXT to reference any source entity (tasks.id as stringified int, jira.key as string, calendar_events.id as string, etc.) at the cost of no true FK enforcement.

### Go types (`internal/db/models.go` additions)

```go
type DayPlan struct {
    ID                 int64
    UserID             string
    PlanDate           string         // YYYY-MM-DD
    Status             string
    HasConflicts       bool
    ConflictSummary    sql.NullString
    GeneratedAt        time.Time
    LastRegeneratedAt  sql.NullTime
    RegenerateCount    int
    FeedbackHistory    string         // JSON []string
    PromptVersion      sql.NullString
    BriefingID         sql.NullInt64
    ReadAt             sql.NullTime
    CreatedAt          time.Time
    UpdatedAt          time.Time
}

type DayPlanItem struct {
    ID           int64
    DayPlanID    int64
    Kind         string              // timeblock | backlog
    SourceType   string              // task | briefing_attention | jira | calendar | manual | focus
    SourceID     sql.NullString
    Title        string
    Description  sql.NullString
    Rationale    sql.NullString
    StartTime    sql.NullTime
    EndTime      sql.NullTime
    DurationMin  sql.NullInt64
    Priority     sql.NullString
    Status       string              // pending | done | skipped
    OrderIndex   int
    Tags         string              // JSON
    CreatedAt    time.Time
    UpdatedAt    time.Time
}
```

### Invariants

1. `UNIQUE (user_id, plan_date)` — exactly one active plan per date. Regeneration mutates the existing row.
2. `kind=timeblock` ⇒ `start_time` and `end_time` required (enforced in Go, not in SQL CHECK).
3. `source_type=calendar` items created only by pipeline; UI blocks user-initiated delete/reorder/toggle.
4. `source_type=manual` items preserved across regeneration; `ReplaceAIItems` never touches them.
5. Cascade delete on `day_plans` removes items.

### DB API (`internal/db/dayplans.go`)

**Writes:** `CreateDayPlan`, `UpsertDayPlan` (by `(user_id, plan_date)`), `CreateDayPlanItems`, `ReplaceAIItems(planID, newItems)` *(deletes items where `source_type NOT IN ('manual', 'calendar')`, inserts new AI items; manual and calendar items preserved)*, `UpdateItemStatus`, `UpdateItemOrder(planID, orderedIDs)`, `DeleteDayPlanItem`, `MarkDayPlanRead`, `SetHasConflicts(planID, value, summary)`, `IncrementRegenerateCount(planID, feedback)`, `InsertCalendarItems`.

**Reads:** `GetDayPlan(userID, date)`, `GetDayPlanByID(id)`, `GetDayPlanItems(planID)`, `ListDayPlans(userID, limit)`, `GetDayPlanItemsBySource(sourceType, sourceID)`, `GetCalendarEventsForDate(date)`.

**Transaction handling:** write methods accept a `sqltx.Ext` (`*sql.DB` or `*sql.Tx`) via an interface so both direct-db and in-transaction callers work. The pipeline uses `BeginTx` + commit/rollback around `ReplaceAIItems` + `SyncCalendarItems` for atomicity.

## AI Prompt & Generation Flow

### Prompt template (`day_plan.generate`)

Registered in `internal/prompts/defaults.go` as `DayPlanGenerate`. Sections (English, as with other project prompts):

1. `=== TODAY ===` — date, weekday, local time, user role, working hours.
2. `=== CALENDAR EVENTS ===` — today's events with times, title, location, attendee summary, meeting-prep flag. Marked read-only.
3. `=== ACTIVE TASKS ===` — active tasks (`status` in `todo/in_progress/blocked`), id, priority, due, overdue flag, ownership, text, intent, blocking.
4. `=== TODAY'S BRIEFING ===` — `attention` items + `coaching` hints from today's briefing (fallback to yesterday's marked stale).
5. `=== JIRA ===` — active issues assigned to user: key, status, priority, due, summary, blockers.
6. `=== PEOPLE TO WATCH ===` — people cards with non-empty red_flags, status=active.
7. `=== MANUAL ITEMS USER PINNED ===` — existing manual items to echo back untouched.
8. `=== PREVIOUS PLAN ===` — short summary of yesterday's plan for context.
9. `=== USER FEEDBACK FOR REGENERATION ===` — verbatim feedback string or `(initial generation)`.

**Output format:** strict JSON (no markdown fences, fence-stripping in parser):

```json
{
  "timeblocks": [
    {
      "source_type": "task|briefing_attention|jira|focus",
      "source_id": "<string or null>",
      "title": "<short, imperative>",
      "description": "<1-2 sentences>",
      "rationale": "<why today, why this slot>",
      "start_time_local": "HH:MM",
      "end_time_local": "HH:MM",
      "priority": "high|medium|low"
    }
  ],
  "backlog": [
    {
      "source_type": "task|briefing_attention|jira|focus",
      "source_id": "<string or null>",
      "title": "<short>",
      "description": "<1 sentence>",
      "rationale": "<why>",
      "priority": "high|medium|low"
    }
  ],
  "summary": "<1-2 sentences>"
}
```

**Constraints in prompt:**

1. Max 3 timeblocks, each 45–120 min, no overlap with calendar events, aligned to 15-min grid.
2. Backlog 3–8 items, sorted by priority.
3. Never create `source_type=calendar` items — pipeline adds those from real events.
4. Never duplicate `MANUAL PINNED ITEMS`.
5. If day is meeting-packed, return empty `timeblocks` and focus backlog on async tasks.
6. `source_id` must match an ID from input sections; `focus` items have null source_id.
7. Every item needs rationale grounded in inputs.
8. Respect user feedback literally if provided.

### Pipeline flow (`dayplan.Pipeline.Run`)

1. Load existing plan for `(user_id, plan_date)`.
2. Short-circuit if exists and neither `Force` nor `RegenerateWithFeedback` set.
3. Gather inputs (tasks, calendar events today, briefing today-or-yesterday, Jira active, people red-flagged, manual pinned items, previous plan summary, user role, working hours).
4. Build prompt with template + inputs.
5. Call `digest.Generator.Generate(ctx, sysPrompt, "Generate the day plan.", "")` with context-source `"day_plan.generate"`.
6. Parse JSON response (fence-stripping reused from briefing).
7. Convert HH:MM (local) + `plan_date` to RFC3339 in project timezone.
8. Validate each item; drop invalid ones (bad source_id, time parse error, calendar-overlap, missing fields) with logged warnings.
9. Transaction: upsert `day_plans` row → `ReplaceAIItems(planID, aiItems)` → `SyncCalendarItems(planID)` → commit.
10. Run `DetectConflicts(planID)` inline (the just-generated plan against current calendar).
11. Return persisted plan + items.

### Gather sub-module (`internal/dayplan/gather.go`)

Collects all inputs. Tolerates missing sections (Jira table absent → empty slice, no briefing → nil with `(none)` rendering). Never fails the pipeline on missing input; only propagates errors from actual DB failures.

### Merge (`internal/dayplan/merge.go`)

`ReplaceAIItems(planID, newItems)`:
1. `DELETE FROM day_plan_items WHERE day_plan_id=? AND source_type NOT IN ('manual', 'calendar')`
2. Insert new items (from AI response).
3. Calendar items handled separately by `SyncCalendarItems`.

### Config (`config.yaml`)

```yaml
day_plan:
  enabled: true
  hour: 8
  working_hours_start: "09:00"
  working_hours_end: "19:00"
  max_timeblocks: 3
  min_backlog: 3
  max_backlog: 8
```

All fields editable in Desktop Settings → Day Plan (write-through via `ConfigService` + Yams).

### Error handling & degradation

| Situation | Behavior |
|---|---|
| AI returns invalid JSON | Log error + raw response, return `ErrInvalidResponse`, no plan mutation. |
| AI timeblock overlaps calendar event | Log warning, drop the timeblock; plan saves without it. |
| AI item with unknown `source_id` | Log warning, drop item. |
| No briefing today | `(none)` in prompt; plan still generates. |
| No calendar connected | `(none)` in prompt; all working-hour slots considered free. |
| Jira disabled / table missing | Section `(none)`. |
| People_cards empty | Section `(none)`. |

## Daemon Integration & Conflict Detection

### Phase order

Existing daemon runs `CalendarSyncer` after Slack sync, before pipelines. Day plan inserts after briefing. Conflict detection runs at the end of every cycle (not only at generation hour) so mid-day calendar changes surface quickly.

```
Phase 0:   Sync Slack
Phase 0.3: Calendar sync                                        (existing — pre-pipelines)
Phase 0.5: Inbox
Phase 1:   Channel digests
Phase 2:   Tracks
Phase 3:   Rollups
Phase 4:   People cards
Phase 5:   People team summary
Phase 6:   Briefing
Phase 7:   Day Plan                                             (new, hour-gated + dedup)
Phase 8:   SyncCalendarItems + DetectConflicts on today's plan  (new, runs every cycle)
```

### Daemon hooks

- `Daemon.SetDayPlanPipeline(p)` — wire-up in `cmd/root.go`.
- `Daemon.shouldRunDayPlan(now)` — enabled + hour match + no plan for today.
- `Daemon.runDayPlanPhase(ctx)` — invokes `dayplan.Pipeline.Run`, errors logged non-fatal.
- Phase 8 handler — calls `dayplan.SyncCalendarItems` then `dayplan.DetectConflicts`; on `has_conflicts` flip false→true, fires `NotificationService.Send("Day plan conflicts detected", conflictSummary)`.

### Conflict detection (`internal/dayplan/conflicts.go`)

```go
func DetectConflicts(ctx, db, userID, date) error
// For each plan item with kind=timeblock AND source_type != 'calendar',
// compare [start_time, end_time] against calendar_events for date.
// Any overlap → append human-readable line to conflicts slice.
// Persist via SetHasConflicts(planID, len>0, joined summary).
```

```go
func SyncCalendarItems(ctx, db, userID, date) error
// Diff current calendar_events for date against day_plan_items
// where source_type=calendar. Add new events, remove orphans,
// update modified times/titles. source_id = event.id.
```

### Graceful chain

If briefing fails, day plan still runs with `(none)` in briefing section. If day plan fails, calendar sync and conflict detection still run. Each phase logs its own errors.

## CLI

### `cmd/day_plan.go`

```
watchtower day-plan                          # alias for show
watchtower day-plan show [date]              # date default = today
watchtower day-plan list [--limit N]         # default 7
watchtower day-plan generate [flags]
watchtower day-plan reset [date]             # delete plan, tasks unaffected
watchtower day-plan check-conflicts [date]   # run conflict detection
```

### `generate` flags

```
--date YYYY-MM-DD    target date (default today)
--force              regenerate even if plan exists
--feedback "text"    pass feedback to AI (implies --force)
--json               print JSON output
```

### Output format — `show` (human-friendly)

Progress header, conflict banner (if any), timeline section with color-coded source-type tags, backlog section with status checkboxes, summary line, metadata footer. JSON mode serializes `DayPlan` + `[]DayPlanItem`.

### Exit codes

- 0: success
- 1: unexpected error
- 2: plan not found (for `show` on historical date)
- 3: AI generation failed

### Out of scope for CLI (MVP)

No interactive item-level editing (`add/done/delete/reorder`) — Desktop is the editing surface. No interactive TUI.

## Swift UI

### Navigation

New `Destination.dayPlan` case. Sidebar position: Chat → Briefings → **Day Plan** → Inbox → Calendar → Tasks → Tracks → People → ... Icon `calendar.day.timeline.left`. Badge: red dot when `plan.has_conflicts == true`.

### Models

- `DayPlan` (GRDB FetchableRecord + PersistableRecord, Identifiable).
- `DayPlanItem` (same).
- Enums: `DayPlanItemKind`, `DayPlanItemSourceType`, `DayPlanItemStatus`.
- Computed: `DayPlan.isToday`, `DayPlanItem.isCalendarEvent`, `.isManual`, `.isReadOnly`, `.timeRange`.

### Queries (`DayPlanQueries`)

Read: `fetchToday`, `fetchByDate`, `fetchList(limit)`, `fetchItems(planId)`.

Mutate: `markItemDone(itemId, cascadeToTask: Bool)`, `markItemPending(itemId, cascadeToTask: Bool)`, `deleteItem(itemId)`, `reorderBacklog(planId, orderedIds)`, `addManualItem(planId, item)`, `markRead(planId)`.

**Cascade semantics:** `markItemDone(cascadeToTask: true)` on a `source_type=task` item sets `tasks.status='done'` in the same transaction; `markItemPending(cascadeToTask: true)` always sets task back to `todo` (not the original status — simpler).

### ViewModel (`DayPlanViewModel`)

`@MainActor @Observable`, subscribes via `ValueObservation` to `day_plans` + `day_plan_items` for today. Exposes:

- `plan`, `items`, `calendarEvents`, `isGenerating`, `generationError`, `feedbackDraft`
- Computed: `timeblocks`, `backlogItems`, `progress`, `hasConflicts`
- Actions: `markDone`, `markPending`, `delete`, `addManual`, `reorderBacklog`, `regenerate(feedback:)`, `reset()`, `checkConflicts()`
- `regenerate` / `reset` / `checkConflicts` shell out through `CLIRunnerProtocol` (testable).

### Views

- `DayPlanView` — main screen: progress header, conflict banner, timeline (pulled from `DayPlanTimelineView`), backlog (list of `DayPlanItemRow`), summary, footer actions (Regenerate, Reset).
- `DayPlanTimelineView` — vertical timeline 09:00–20:00 with absolute positioning of timeblocks + calendar events (color-coded by source_type: calendar grey, focus blue, task green, jira purple, briefing_attention yellow, manual outline).
- `DayPlanItemRow` — for backlog. SwiftUI `.draggable` + `.dropDestination` for reorder. Context menu: Mark done, Mark pending, Delete, Go to source.
- `DayPlanConflictBanner` — red banner with `conflict_summary` + `[Regenerate]` + `[Check again]` buttons.
- `RegenerateFeedbackSheet` — modal with textbox, last-N feedback history for reference, info note "manual items preserved", Cancel/Regenerate buttons.
- `CreateDayPlanItemSheet` — form to add manual item; fields: kind radio (timeblock/backlog), title, description, start/end time if timeblock; source_type fixed `manual`.

### Settings

New "Day Plan" section in `SettingsView` (adjacent to "Briefing"):

- Enabled toggle
- Generate-at-hour picker
- Working hours range (start/end)
- Max timeblocks (2–4)
- Backlog range (min/max)

`ConfigService` read/writes `day_plan.*` in config.yaml via Yams.

### Notifications

Existing `NotificationService` fires on `has_conflicts` false→true flip. Detected by Swift poller (e.g. `DigestWatcher`-analogue subscribing to `day_plans` updates) — daemon also sends an OS-level notification server-side in Phase 8.

## Testing

### Go

- `internal/dayplan/pipeline_test.go` — initial generate, skip-when-exists, force-regenerate, regenerate-with-feedback, preserve-manual, graceful-no-briefing, graceful-no-calendar, drop-invalid-ai-items. Uses `mockGenerator` + in-memory SQLite.
- `gather_test.go` — each gather func in isolation (tasks filter, briefing fallback, graceful missing tables).
- `merge_test.go` — `ReplaceAIItems` preserves manual + calendar, replaces AI items, handles empty new list.
- `conflicts_test.go` — no overlap, exact overlap, partial overlap, calendar changed after generation, `SyncCalendarItems` add/remove/update.
- `prompt_test.go` — snapshot against golden prompt for fixed inputs.
- `internal/db/dayplans_test.go` — CRUD, transaction atomicity for `ReplaceAIItems`, UNIQUE constraint on upsert, cascade delete.
- `internal/daemon/daemon_test.go` — phase order, `shouldRunDayPlan` hour match + dedup + disabled config.
- `cmd/day_plan_test.go` — each subcommand via `rootCmd.SetArgs` + stdout capture + mocked pipeline; golden-file snapshot for `show`.

**Coverage targets:** ≥80% for `internal/dayplan/`, ≥70% for `internal/db/dayplans.go`.

### Swift

- `DayPlanQueriesTests` — all reads + mutations on in-memory GRDB DB; `markItemDone(cascadeToTask)` verifies task.status flipped in same transaction.
- `DayPlanViewModelTests` — initial load, cascade mark-done, delete, reorder-persists-order, add-manual, regenerate-shells-to-CLI (via mocked `CLIRunnerProtocol`), observes-conflict-flag-change.
- `DayPlanModelTests` — codec roundtrip, computed properties.

No UI snapshot tests in MVP (too brittle).

### Manual E2E checklist (pre-merge)

1. Fresh DB → daemon at 8:00 → plan appears for today.
2. `watchtower day-plan show` — correct output.
3. Desktop: tab renders timeline + backlog + calendar overlay.
4. Checkbox on task-item → task in Tasks tab flips to done.
5. Add manual item → appears in backlog.
6. Regenerate with feedback → AI items rewritten, manual preserved.
7. Add Google Calendar event overlapping a timeblock → after sync, conflict banner appears.
8. `watchtower day-plan check-conflicts` — prints summary.
9. `watchtower day-plan reset` → plan deleted, tasks intact.
10. Next morning → fresh plan generated, yesterday's pending items not carried over (but active tasks re-surface naturally).

## Dependencies

### Reused

- `digest.Generator` interface (Claude / Codex providers).
- `internal/prompts/` store + tuner (for `day_plan.generate` template registration).
- `db.Task` + `tasks` table for cascade.
- `briefings` table for `attention` + `coaching` input.
- `calendar_events` table.
- `jira_issues` table (optional; if feature disabled, graceful skip).
- `people_cards` table (filtered by red_flags + status=active).
- `NotificationService` (Swift + Go daemon side).

### New

- `internal/dayplan/` package.
- `internal/db/dayplans.go`.
- Migration `0047_day_plan.sql`.
- `cmd/day_plan.go`.
- `internal/prompts/defaults_day_plan.go` (prompt template constant).
- Swift: `Sources/Models/DayPlan.swift`, `DayPlanItem.swift`; `Sources/Queries/DayPlanQueries.swift`; `Sources/ViewModels/DayPlanViewModel.swift`; `Sources/Views/DayPlan/*.swift`.
- Swift: `CLIRunnerProtocol` (or equivalent) for shelling out to `watchtower day-plan generate …`.

## Estimated Size

- Go: ~800 lines pipeline + gather + merge + conflicts + prompt + ~250 CLI + ~150 DB layer + migration = **~1200 lines production + ~800 lines tests**.
- Swift: ~120 models + 100 queries + 180 view-model + ~500 views + 40 settings + 300 tests = **~1200 lines**.

## Open Questions & Follow-ups

- CLI golden-file snapshots vs `assert.Contains` — defer to implementer preference.
- Whether `CLIRunnerProtocol` already exists in Desktop (`MeetingPrepViewModel` has a similar mechanism — reuse that pattern).
- Jira table naming / availability — confirm during implementation; pipeline must tolerate its absence.
- Feedback-history max length in `day_plans.feedback_history` (suggest last 5 entries).

---

**Next step after approval:** run `writing-plans` skill to produce an implementation plan.
