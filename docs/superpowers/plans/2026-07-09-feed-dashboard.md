# Feed Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Dashboard tab into a social-wall feed: one chronological list mixing situations, upcoming meetings, briefings, meeting recaps, and day plans, backed by a `feed_items` index table with per-item hide/seen state and a filter bar.

**Architecture:** A new `feed_items` index table holds chronology + user state only (never content); content joins live from source tables. A new AI-free `internal/feed` package publishes rows each daemon cycle via idempotent SQL upserts. Desktop reads the index through `FeedItemQueries`, renders per-type rows on the left and per-type panes on the right.

**Tech Stack:** Go 1.25 (goose migrations, `modernc.org/sqlite`), SwiftUI macOS 14+ with GRDB.

**Spec:** `docs/superpowers/specs/2026-07-09-feed-dashboard-design.md`

## Global Constraints

- Behavior inventory contracts DASH-01..04 and INBOX-01..09 must not be weakened (`docs/inventory/dashboard.md`, `docs/inventory/inbox-pulse.md`). This plan ADDS DASH-05/06.
- Do NOT bump `CurrentSchemaFormat` in `internal/db/migrations.go`.
- All timestamps are UTC ISO8601 `YYYY-MM-DDTHH:MM:SSZ` — SQL: `strftime('%Y-%m-%dT%H:%M:%SZ','now')`, Go: `now.UTC().Format("2006-01-02T15:04:05Z")`.
- Importance scale 0..100: situations map from `priority` (high=90, medium=60, low=30); meetings=70; briefings/recaps/day-plans=60. "Important only" threshold = 70.
- The publisher makes zero AI calls, never deletes feed rows, never resets `hidden_at`/`seen_at` (DASH-05/06).
- All commit messages / code comments in English. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Swift verification: never pipe through `tail`/`head` — redirect to a log file and check `$?` explicitly, e.g. `swift test > /tmp/swift-test.log 2>&1; echo "exit=$?"`.

---

### Task 1: Migration 00014 — `feed_items` + `feed_state`

**Files:**
- Create: `internal/db/migrations/00014_feed_items.sql`
- Modify: `internal/db/schema.sql` (append after the `situation_signals` block at the end)
- Modify: `internal/db/db_test.go` (the `expectedTables` slice in `TestAllTablesExist`, ~lines 97-104)
- Regenerate: `internal/db/testdata/schema_v73.golden`

**Interfaces:**
- Produces: tables `feed_items` (UNIQUE(item_type, source_id)) and `feed_state` (singleton id=1, `bootstrap_cutoff` seeded at migration time). All later tasks depend on these exact columns.

- [ ] **Step 1: Extend `TestAllTablesExist` (failing test first)**

In `internal/db/db_test.go`, append `"feed_items", "feed_state"` to the `expectedTables` slice (it currently ends with `"situations", "situation_signals"`).

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/db/ -run TestAllTablesExist -v`
Expected: FAIL — `feed_items` / `feed_state` missing.

- [ ] **Step 3: Create the migration**

`internal/db/migrations/00014_feed_items.sql`:

```sql
-- +goose Up
-- Feed index for the dashboard's social-wall feed: one row per feed item,
-- holding chronology and per-item user state only. Content is always joined
-- live from the source tables (situations, calendar_events, briefings,
-- meeting_recaps, day_plans) — never duplicated here.
CREATE TABLE feed_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item_type   TEXT NOT NULL CHECK (item_type IN ('situation','meeting','briefing','meeting_recap','day_plan')),
    source_id   TEXT NOT NULL,
    event_ts    TEXT NOT NULL,
    importance  INTEGER NOT NULL DEFAULT 50,
    hidden_at   TEXT,
    seen_at     TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(item_type, source_id)
);
CREATE INDEX idx_feed_items_event_ts ON feed_items(event_ts DESC);

-- Bootstrap cutoff: the moment this migration ran. The publisher only feeds
-- briefings/recaps/day-plans created after this, so an old backlog doesn't
-- flood the feed on first publish.
CREATE TABLE feed_state (
    id               INTEGER PRIMARY KEY CHECK (id = 1),
    bootstrap_cutoff TEXT NOT NULL
);
INSERT INTO feed_state (id, bootstrap_cutoff) VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

-- +goose Down
DROP TABLE feed_state;
DROP TABLE feed_items;
```

- [ ] **Step 4: Mirror into `internal/db/schema.sql`**

Append the same two tables + index at the end of the file (after `situation_signals`), using the `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` style the file uses, keeping the explanatory comments. For `feed_state` in schema.sql include the same seeding `INSERT` guarded as the migration does? **No** — schema.sql is a documentation mirror injected into AI prompts; mirror only the DDL (`CREATE TABLE IF NOT EXISTS feed_state ...`), matching how the file contains no INSERTs today.

- [ ] **Step 5: Regenerate the schema golden**

Run: `go test ./internal/db/ -run TestSchemaGolden -update`
Expected: PASS, `internal/db/testdata/schema_v73.golden` modified.

- [ ] **Step 6: Run the schema guard trio**

Run: `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden' -v`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/db/migrations/00014_feed_items.sql internal/db/schema.sql internal/db/db_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(db): add feed_items index and feed_state bootstrap cutoff

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `internal/db/feed.go` — model + publish upserts

**Files:**
- Create: `internal/db/feed.go`
- Create: `internal/db/feed_test.go`
- Modify: `internal/db/models.go` (add `FeedItem` struct at the end)

**Interfaces:**
- Consumes: Task 1 tables.
- Produces (used by Task 3):
  - `type FeedItem struct { ID int64; ItemType, SourceID, EventTS string; Importance int; HiddenAt, SeenAt, CreatedAt, UpdatedAt string }` (empty string = NULL)
  - `func (db *DB) GetFeedItem(itemType, sourceID string) (*FeedItem, error)` — nil, nil when absent
  - `func (db *DB) CountFeedItems() (int, error)`
  - `func (db *DB) GetFeedBootstrapCutoff() (string, error)`
  - `func (db *DB) PublishSituationFeedItems() (int, error)`
  - `func (db *DB) PublishMeetingFeedItems(nowTS, windowEndTS string) (int, error)`
  - `func (db *DB) PublishBriefingFeedItems(cutoff string) (int, error)`
  - `func (db *DB) PublishRecapFeedItems(cutoff string) (int, error)`
  - `func (db *DB) PublishDayPlanFeedItems(cutoff string) (int, error)`

- [ ] **Step 1: Add the `FeedItem` model**

Append to `internal/db/models.go`:

```go
// FeedItem is one row of the dashboard feed index (table feed_items) — the
// social-wall feed's chronology + per-item user state. Content is never
// stored here; it is joined live from the source table named by ItemType.
type FeedItem struct {
	ID         int64
	ItemType   string // situation | meeting | briefing | meeting_recap | day_plan
	SourceID   string
	EventTS    string
	Importance int
	HiddenAt   string // empty when not hidden
	SeenAt     string // empty when unseen
	CreatedAt  string
	UpdatedAt  string
}
```

- [ ] **Step 2: Write failing tests**

`internal/db/feed_test.go` (this package's own tests use the unexported `openTestDB(t)` helper — see other `internal/db/*_test.go` files for the exact name; if it differs, match it):

```go
package db

import "testing"

func TestFeedBootstrapCutoffSeeded(t *testing.T) {
	d := openTestDB(t)
	cutoff, err := d.GetFeedBootstrapCutoff()
	if err != nil {
		t.Fatalf("GetFeedBootstrapCutoff: %v", err)
	}
	if cutoff == "" {
		t.Fatal("bootstrap cutoff should be seeded by migration 00014")
	}
}

func TestGetFeedItemMissingReturnsNil(t *testing.T) {
	d := openTestDB(t)
	item, err := d.GetFeedItem("situation", "999")
	if err != nil {
		t.Fatalf("GetFeedItem: %v", err)
	}
	if item != nil {
		t.Fatalf("expected nil for missing item, got %+v", item)
	}
}

func TestPublishSituationUpsertPreservesUserState(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'release blocked', 'high', 'open', '2026-07-09T10:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if n, err := d.PublishSituationFeedItems(); err != nil || n != 1 {
		t.Fatalf("first publish: n=%d err=%v", n, err)
	}
	item, err := d.GetFeedItem("situation", "1")
	if err != nil || item == nil {
		t.Fatalf("GetFeedItem: %+v %v", item, err)
	}
	if item.EventTS != "2026-07-09T10:00:00Z" || item.Importance != 90 {
		t.Fatalf("unexpected item: %+v", item)
	}

	// User hides + sees the item; the situation then reranks (merge).
	if _, err := d.Exec(`UPDATE feed_items SET hidden_at='2026-07-09T11:00:00Z', seen_at='2026-07-09T11:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE situations SET priority='low', updated_at='2026-07-09T12:00:00Z' WHERE id=1`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.PublishSituationFeedItems(); err != nil {
		t.Fatal(err)
	}
	item, _ = d.GetFeedItem("situation", "1")
	if item.EventTS != "2026-07-09T12:00:00Z" || item.Importance != 30 {
		t.Fatalf("re-upsert should update event_ts/importance: %+v", item)
	}
	if item.HiddenAt == "" || item.SeenAt == "" {
		t.Fatalf("re-upsert must preserve hidden_at/seen_at: %+v", item)
	}

	// Idempotency: nothing changed → no rows touched.
	if n, err := d.PublishSituationFeedItems(); err != nil || n != 0 {
		t.Fatalf("no-op publish should touch 0 rows: n=%d err=%v", n, err)
	}
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestFeed|TestGetFeedItem|TestPublishSituation' -v`
Expected: FAIL — methods undefined.

- [ ] **Step 4: Implement `internal/db/feed.go`**

```go
package db

import (
	"database/sql"
	"fmt"
)

const feedItemSelectCols = `id, item_type, source_id, event_ts, importance,
	COALESCE(hidden_at,''), COALESCE(seen_at,''), created_at, updated_at`

func scanFeedItem(row interface{ Scan(...any) error }) (*FeedItem, error) {
	var f FeedItem
	err := row.Scan(&f.ID, &f.ItemType, &f.SourceID, &f.EventTS, &f.Importance,
		&f.HiddenAt, &f.SeenAt, &f.CreatedAt, &f.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &f, nil
}

// GetFeedItem returns the feed index row for (itemType, sourceID), or nil
// when the item has not been published.
func (db *DB) GetFeedItem(itemType, sourceID string) (*FeedItem, error) {
	row := db.QueryRow(`SELECT `+feedItemSelectCols+` FROM feed_items
		WHERE item_type = ? AND source_id = ?`, itemType, sourceID)
	item, err := scanFeedItem(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting feed item %s/%s: %w", itemType, sourceID, err)
	}
	return item, nil
}

// CountFeedItems returns the total number of feed index rows.
func (db *DB) CountFeedItems() (int, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM feed_items`).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting feed items: %w", err)
	}
	return n, nil
}

// GetFeedBootstrapCutoff returns the timestamp seeded by migration 00014 —
// briefings/recaps/day-plans created before it are never published, so the
// pre-feature backlog doesn't flood the feed.
func (db *DB) GetFeedBootstrapCutoff() (string, error) {
	var cutoff string
	if err := db.QueryRow(`SELECT bootstrap_cutoff FROM feed_state WHERE id = 1`).Scan(&cutoff); err != nil {
		return "", fmt.Errorf("getting feed bootstrap cutoff: %w", err)
	}
	return cutoff, nil
}

// feedUpsert runs one publish statement and reports rows inserted/updated.
func (db *DB) feedUpsert(name, query string, args ...any) (int, error) {
	res, err := db.Exec(query, args...)
	if err != nil {
		return 0, fmt.Errorf("publishing %s feed items: %w", name, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("publishing %s feed items: %w", name, err)
	}
	return int(n), nil
}

// PublishSituationFeedItems mirrors every open situation into the feed index.
// event_ts follows the situation's updated_at (a compose merge bumps it, so
// the feed item resurfaces); importance maps from priority. The conditional
// DO UPDATE keeps a steady-state publish at zero touched rows, and never
// writes hidden_at/seen_at (DASH-05).
func (db *DB) PublishSituationFeedItems() (int, error) {
	return db.feedUpsert("situation", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'situation', CAST(s.id AS TEXT), s.updated_at,
		       CASE s.priority WHEN 'high' THEN 90 WHEN 'medium' THEN 60 ELSE 30 END
		FROM situations s
		WHERE s.status = 'open'
		ON CONFLICT(item_type, source_id) DO UPDATE SET
		    event_ts   = excluded.event_ts,
		    importance = excluded.importance,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE feed_items.event_ts != excluded.event_ts
		   OR feed_items.importance != excluded.importance`)
}

// PublishMeetingFeedItems publishes confirmed, non-all-day meetings whose
// start_time falls inside (nowTS, windowEndTS]. event_ts = start_time, so an
// upcoming meeting sits at the top of the DESC feed and slides down naturally
// once its time passes; a reschedule inside the window updates event_ts.
func (db *DB) PublishMeetingFeedItems(nowTS, windowEndTS string) (int, error) {
	return db.feedUpsert("meeting", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'meeting', e.id, e.start_time, 70
		FROM calendar_events e
		WHERE e.is_all_day = 0
		  AND e.event_status = 'confirmed'
		  AND e.start_time > ?
		  AND e.start_time <= ?
		ON CONFLICT(item_type, source_id) DO UPDATE SET
		    event_ts   = excluded.event_ts,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE feed_items.event_ts != excluded.event_ts`, nowTS, windowEndTS)
}

// PublishBriefingFeedItems publishes briefings created after the bootstrap
// cutoff. Insert-once: a briefing never changes identity after creation.
func (db *DB) PublishBriefingFeedItems(cutoff string) (int, error) {
	return db.feedUpsert("briefing", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'briefing', CAST(b.id AS TEXT), b.created_at, 60
		FROM briefings b
		WHERE b.created_at > ?
		ON CONFLICT(item_type, source_id) DO NOTHING`, cutoff)
}

// PublishRecapFeedItems publishes meeting recaps created after the bootstrap
// cutoff, keyed by their calendar event id.
func (db *DB) PublishRecapFeedItems(cutoff string) (int, error) {
	return db.feedUpsert("meeting_recap", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'meeting_recap', r.event_id, r.created_at, 60
		FROM meeting_recaps r
		WHERE r.created_at > ?
		ON CONFLICT(item_type, source_id) DO NOTHING`, cutoff)
}

// PublishDayPlanFeedItems publishes active day plans created after the
// bootstrap cutoff. event_ts tracks the latest (re)generation, so a
// regenerated plan resurfaces at its new position.
func (db *DB) PublishDayPlanFeedItems(cutoff string) (int, error) {
	return db.feedUpsert("day_plan", `
		INSERT INTO feed_items (item_type, source_id, event_ts, importance)
		SELECT 'day_plan', CAST(p.id AS TEXT), COALESCE(p.last_regenerated_at, p.generated_at), 60
		FROM day_plans p
		WHERE p.status = 'active'
		  AND p.created_at > ?
		ON CONFLICT(item_type, source_id) DO UPDATE SET
		    event_ts   = excluded.event_ts,
		    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE feed_items.event_ts != excluded.event_ts`, cutoff)
}
```

Note: SQLite counts a row skipped by the upsert's `WHERE` / `DO NOTHING` as NOT affected, which is what makes the idempotency assertions (`n == 0`) work.

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/db/ -run 'TestFeed|TestGetFeedItem|TestPublishSituation' -v`
Expected: PASS. Then the whole package: `go test ./internal/db/` — PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/db/feed.go internal/db/feed_test.go internal/db/models.go
git commit -m "feat(db): feed index model and idempotent publish upserts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `internal/feed` package + `FeedConfig` + DASH-05/06 guards

**Files:**
- Modify: `internal/config/config.go` (add `FeedConfig` struct near `InboxConfig` ~line 52; mount `Feed FeedConfig` on `Config` ~line 159; add `v.SetDefault` calls near the inbox ones ~line 213)
- Modify: `internal/config/defaults.go` (add `DefaultFeedMeetingLeadMinutes = 30`)
- Create: `internal/feed/publish.go`
- Create: `internal/feed/publish_test.go`
- Create: `internal/feed/testmain_test.go` (copy of `internal/inbox/testmain_test.go` with `package feed`)
- Modify: `docs/inventory/dashboard.md` (add DASH-05, DASH-06, changelog entry)

**Interfaces:**
- Consumes: Task 2 `Publish*FeedItems` / `GetFeedBootstrapCutoff` methods.
- Produces (used by Task 4):
  - `config.FeedConfig{ Enabled bool; MeetingLeadMinutes int }`, accessed as `cfg.Feed.Enabled` / `cfg.Feed.MeetingLeadMinutes`
  - `func feed.New(database *db.DB, cfg *config.Config, logger *log.Logger) *Pipeline`
  - `func (p *Pipeline) Publish(now time.Time) (int, error)` — total published, joined per-source errors

- [ ] **Step 1: Add config block**

In `internal/config/config.go`, after `InboxConfig`:

```go
// FeedConfig holds settings for the dashboard feed publisher (internal/feed).
type FeedConfig struct {
	Enabled            bool `mapstructure:"enabled"`              // enable feed publishing (default: true)
	MeetingLeadMinutes int  `mapstructure:"meeting_lead_minutes"` // minutes before start a meeting enters the feed (default: 30)
}
```

Mount on `Config`: `Feed FeedConfig \`mapstructure:"feed"\`` (next to `Inbox`/`Dashboard`). In `defaults.go`: `DefaultFeedMeetingLeadMinutes = 30` (next to the inbox defaults). In the viper defaults block: `v.SetDefault("feed.enabled", true)` and `v.SetDefault("feed.meeting_lead_minutes", DefaultFeedMeetingLeadMinutes)`.

Run: `go test ./internal/config/` — expected PASS (defaults tests, if any, unaffected; if a test enumerates config keys, extend it the same way the inbox keys appear there).

- [ ] **Step 2: Copy the test template bootstrap**

Copy `internal/inbox/testmain_test.go` to `internal/feed/testmain_test.go` verbatim, changing only `package inbox` → `package feed`. (It calls `db.InitTestTemplate()` so `:memory:` opens clone a pre-migrated template.)

- [ ] **Step 3: Write failing tests**

`internal/feed/publish_test.go`:

```go
package feed

import (
	"io"
	"log"
	"strings"
	"testing"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

func newTestPipeline(t *testing.T, d *db.DB, leadMinutes int) *Pipeline {
	t.Helper()
	cfg := &config.Config{}
	cfg.Feed.Enabled = true
	cfg.Feed.MeetingLeadMinutes = leadMinutes
	return New(d, cfg, log.New(io.Discard, "", 0))
}

// setCutoff rewinds the bootstrap cutoff so fixture rows created "before the
// feature existed" vs "after" can both be simulated.
func setCutoff(t *testing.T, d *db.DB, ts string) {
	t.Helper()
	if _, err := d.Exec(`UPDATE feed_state SET bootstrap_cutoff = ?`, ts); err != nil {
		t.Fatal(err)
	}
}

func insertCalendarEvent(t *testing.T, d *db.DB, id, start string) {
	t.Helper()
	if _, err := d.Exec(`INSERT OR IGNORE INTO calendar_calendars (id, name) VALUES ('cal1', 'Test')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
		VALUES (?, 'cal1', 'Standup', ?, ?)`, id, start, start); err != nil {
		t.Fatal(err)
	}
}

var testNow = time.Date(2026, 7, 9, 12, 0, 0, 0, time.UTC)

func TestPublishEachSourceType(t *testing.T) {
	d := db.OpenTestDB(t)
	setCutoff(t, d, "2026-07-01T00:00:00Z")

	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'release blocked', 'medium', 'open', '2026-07-09T09:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	insertCalendarEvent(t, d, "ev1", "2026-07-09T12:10:00Z") // 10 min away — inside 30-min window
	if _, err := d.Exec(`INSERT INTO briefings (id, user_id, date, created_at)
		VALUES (5, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at)
		VALUES ('ev1', '', '{}', '2026-07-09T11:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO day_plans (id, user_id, plan_date, status, generated_at)
		VALUES (3, 'U1', '2026-07-09', 'active', '2026-07-09T06:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	n, err := newTestPipeline(t, d, 30).Publish(testNow)
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if n != 5 {
		t.Fatalf("expected 5 published items, got %d", n)
	}
	for _, tc := range []struct{ typ, id, eventTS string; importance int }{
		{"situation", "1", "2026-07-09T09:00:00Z", 60},
		{"meeting", "ev1", "2026-07-09T12:10:00Z", 70},
		{"briefing", "5", "2026-07-09T07:00:00Z", 60},
		{"meeting_recap", "ev1", "2026-07-09T11:00:00Z", 60},
		{"day_plan", "3", "2026-07-09T06:00:00Z", 60},
	} {
		item, err := d.GetFeedItem(tc.typ, tc.id)
		if err != nil || item == nil {
			t.Fatalf("%s/%s: %+v %v", tc.typ, tc.id, item, err)
		}
		if item.EventTS != tc.eventTS || item.Importance != tc.importance {
			t.Fatalf("%s/%s: got %+v", tc.typ, tc.id, item)
		}
	}
}

func TestPublishMeetingLeadWindow(t *testing.T) {
	d := db.OpenTestDB(t)
	insertCalendarEvent(t, d, "soon", "2026-07-09T12:10:00Z")   // inside
	insertCalendarEvent(t, d, "later", "2026-07-09T14:00:00Z")  // beyond window
	insertCalendarEvent(t, d, "past", "2026-07-09T11:00:00Z")   // already started
	insertCalendarEvent(t, d, "allday", "2026-07-09T12:05:00Z")
	if _, err := d.Exec(`UPDATE calendar_events SET is_all_day = 1 WHERE id = 'allday'`); err != nil {
		t.Fatal(err)
	}

	if _, err := newTestPipeline(t, d, 30).Publish(testNow); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	for id, want := range map[string]bool{"soon": true, "later": false, "past": false, "allday": false} {
		item, err := d.GetFeedItem("meeting", id)
		if err != nil {
			t.Fatal(err)
		}
		if (item != nil) != want {
			t.Fatalf("meeting %q: published=%v, want %v", id, item != nil, want)
		}
	}
}

func TestPublishBootstrapCutoffExcludesBacklog(t *testing.T) {
	d := db.OpenTestDB(t)
	setCutoff(t, d, "2026-07-09T00:00:00Z")
	// Backlog rows from before the cutoff must never enter the feed.
	if _, err := d.Exec(`INSERT INTO briefings (id, user_id, date, created_at)
		VALUES (1, 'U1', '2026-06-01', '2026-06-01T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO day_plans (id, user_id, plan_date, status, generated_at, created_at)
		VALUES (1, 'U1', '2026-06-01', 'active', '2026-06-01T06:00:00Z', '2026-06-01T06:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := newTestPipeline(t, d, 30).Publish(testNow); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	if n, _ := d.CountFeedItems(); n != 0 {
		t.Fatalf("backlog must not be published, got %d items", n)
	}
}

func TestPublishSituationMergeBumpsEventTS(t *testing.T) {
	d := db.OpenTestDB(t)
	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'story', 'medium', 'open', '2026-07-09T09:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	p := newTestPipeline(t, d, 30)
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	// Compose merges a new signal → updated_at bumps → item resurfaces.
	if _, err := d.Exec(`UPDATE situations SET updated_at = '2026-07-09T11:30:00Z' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	item, _ := d.GetFeedItem("situation", "1")
	if item == nil || item.EventTS != "2026-07-09T11:30:00Z" {
		t.Fatalf("merge should bump event_ts: %+v", item)
	}
}

// DASH-05: the publisher is additive and state-preserving — it never deletes
// feed rows and never resets hidden_at/seen_at on re-upsert.
func TestDash05_RepublishPreservesUserStateAndHistory(t *testing.T) {
	d := db.OpenTestDB(t)
	if _, err := d.Exec(`INSERT INTO situations (id, title, priority, status, updated_at)
		VALUES (1, 'story', 'high', 'open', '2026-07-09T09:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	p := newTestPipeline(t, d, 30)
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`UPDATE feed_items SET hidden_at = '2026-07-09T10:00:00Z', seen_at = '2026-07-09T10:00:00Z'`); err != nil {
		t.Fatal(err)
	}
	// The situation closes (drops out of the publisher's SELECT) and a rerank
	// happens elsewhere; the feed row must survive both untouched.
	if _, err := d.Exec(`UPDATE situations SET status = 'done' WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Publish(testNow); err != nil {
		t.Fatal(err)
	}
	item, _ := d.GetFeedItem("situation", "1")
	if item == nil {
		t.Fatal("DASH-05: closed situation's feed row must not be deleted")
	}
	if item.HiddenAt == "" || item.SeenAt == "" {
		t.Fatalf("DASH-05: republish must preserve user state: %+v", item)
	}
}

// DASH-06: one broken source never blocks the others, and the publisher is
// AI-free by construction (Pipeline holds no generator). Degenerate input:
// a whole source table missing.
func TestDash06_SourceFailureDoesNotBlockOthers(t *testing.T) {
	d := db.OpenTestDB(t)
	setCutoff(t, d, "2026-07-01T00:00:00Z")
	if _, err := d.Exec(`DROP TABLE meeting_recaps`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(`INSERT INTO briefings (id, user_id, date, created_at)
		VALUES (7, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	n, err := newTestPipeline(t, d, 30).Publish(testNow)
	if err == nil || !strings.Contains(err.Error(), "meeting_recap") {
		t.Fatalf("expected a meeting_recap error, got %v", err)
	}
	if n != 1 {
		t.Fatalf("briefing should still publish despite recap failure, got n=%d", n)
	}
	if item, _ := d.GetFeedItem("briefing", "7"); item == nil {
		t.Fatal("briefing must be published despite the recap source failing")
	}
}
```


- [ ] **Step 4: Run tests to verify they fail**

Run: `go test ./internal/feed/ -v` — expected: compile FAIL (package doesn't exist yet).

- [ ] **Step 5: Implement `internal/feed/publish.go`**

```go
// Package feed publishes the dashboard's social-wall feed index (feed_items)
// from source tables. Pure SQL, zero AI calls (DASH-06); additive and
// state-preserving (DASH-05). See docs/inventory/dashboard.md.
package feed

import (
	"errors"
	"fmt"
	"log"
	"time"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Pipeline mirrors source tables into the feed_items index each daemon cycle.
type Pipeline struct {
	db     *db.DB
	cfg    *config.Config
	logger *log.Logger
}

func New(database *db.DB, cfg *config.Config, logger *log.Logger) *Pipeline {
	if logger == nil {
		logger = log.Default()
	}
	return &Pipeline{db: database, cfg: cfg, logger: logger}
}

// Publish upserts feed items for every source. Best-effort per source: one
// failing source is logged and reported but never blocks the others, and no
// failure here may affect the inbox pipeline or its watermarks (DASH-06).
// Returns the number of rows inserted/updated and the joined source errors.
func (p *Pipeline) Publish(now time.Time) (int, error) {
	cutoff, err := p.db.GetFeedBootstrapCutoff()
	if err != nil {
		return 0, fmt.Errorf("feed bootstrap cutoff: %w", err)
	}
	nowTS := now.UTC().Format("2006-01-02T15:04:05Z")
	windowEnd := now.UTC().
		Add(time.Duration(p.cfg.Feed.MeetingLeadMinutes) * time.Minute).
		Format("2006-01-02T15:04:05Z")

	total := 0
	var errs []error
	run := func(name string, fn func() (int, error)) {
		n, err := fn()
		if err != nil {
			p.logger.Printf("feed: %s publish failed: %v", name, err)
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
			return
		}
		total += n
	}
	run("situation", p.db.PublishSituationFeedItems)
	run("meeting", func() (int, error) { return p.db.PublishMeetingFeedItems(nowTS, windowEnd) })
	run("briefing", func() (int, error) { return p.db.PublishBriefingFeedItems(cutoff) })
	run("meeting_recap", func() (int, error) { return p.db.PublishRecapFeedItems(cutoff) })
	run("day_plan", func() (int, error) { return p.db.PublishDayPlanFeedItems(cutoff) })
	return total, errors.Join(errs...)
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `go test ./internal/feed/ -v` — expected: all PASS.
Run: `go build ./... && go vet ./...` — expected: clean.

- [ ] **Step 7: Add DASH-05 / DASH-06 to the inventory**

Append to `docs/inventory/dashboard.md` before the `## Changelog` section:

```markdown
## DASH-05 — Feed publisher is additive and state-preserving

**Status:** Enforced

**Observable:** The feed publisher (`internal/feed`, `feed_items` index) never deletes feed rows and never resets user state (`hidden_at`, `seen_at`) when re-upserting an item. A situation that closes or converts drops out of the publisher's SELECT but its feed row stays — the wall keeps history; hiding is a user action recorded in `hidden_at`, not a deletion.

**Why locked:** The feed is the app's start screen and doubles as the day's history. If a publish cycle could delete rows or clear hide/seen marks, a routine daemon cycle would silently rewrite what the user already read or hid — the same "stability beats freshness" promise DASH-02 makes for situation content, extended to feed state.

**Test guards:**
- `internal/feed/publish_test.go::TestDash05_RepublishPreservesUserStateAndHistory`

**Locked since:** 2026-07-09

## DASH-06 — Feed publish is AI-free and non-blocking

**Status:** Enforced

**Observable:** `feed.Publish` makes no AI calls (pure SQL upserts; `feed.Pipeline` holds no generator). One failing source (e.g. a missing/corrupt source table) is logged and reported while every other source still publishes, and a feed failure never fails the daemon cycle nor touches the inbox pipeline or its watermarks (INBOX-09) — the publisher runs entirely outside `inbox.Run`.

**Why locked:** The feed indexes content other pipelines already paid AI calls to produce; re-spending model budget to move pointers would be waste, and a flaky feed phase must not be able to block triage/compose or freeze inbox watermarks.

**Test guards:**
- `internal/feed/publish_test.go::TestDash06_SourceFailureDoesNotBlockOthers`

**Locked since:** 2026-07-09
```

And add to the `## Changelog` list:

```markdown
- 2026-07-09: added DASH-05/06 (feed publisher contracts). Introduced by the feed dashboard feature (spec `docs/superpowers/specs/2026-07-09-feed-dashboard-design.md`), which turns the Dashboard into a chronological social-wall feed (`feed_items` index) mixing situations with meetings, briefings, recaps, and day plans.
```

- [ ] **Step 8: Commit**

```bash
git add internal/config/config.go internal/config/defaults.go internal/feed/ docs/inventory/dashboard.md
git commit -m "feat(feed): AI-free feed publisher with DASH-05/06 contracts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Daemon phase + CLI wiring

**Files:**
- Modify: `internal/daemon/daemon.go` (pipeline field ~line 47-68 block; setter near `SetInboxPipeline` ~line 105; call at the end of `runSync` ~line 254; phase method near `phaseInbox` ~line 493)
- Modify: `cmd/sync.go` (daemon wiring block, ~lines 286-299)

**Interfaces:**
- Consumes: `feed.New`, `(*feed.Pipeline).Publish(now time.Time) (int, error)`, `cfg.Feed.Enabled` from Task 3.

- [ ] **Step 1: Add the daemon phase**

In `internal/daemon/daemon.go`:

1. Add field to the `Daemon` struct pipeline block: `feedPipe *feed.Pipeline` (import `watchtower/internal/feed`).
2. Add setter next to `SetInboxPipeline`:

```go
// SetFeedPipeline installs the dashboard feed publisher (internal/feed).
func (d *Daemon) SetFeedPipeline(p *feed.Pipeline) {
	d.feedPipe = p
}
```

3. At the very end of `runSync` (after `d.runDayPlanConflictPhase(ctx, now)`), add `d.phaseFeed()`.
4. Add the phase method next to `phaseInbox`:

```go
// phaseFeed mirrors source tables into the dashboard feed index. Runs last so
// it sees everything this cycle produced (situations, briefings, recaps, day
// plans). AI-free and best-effort: errors are logged, never propagated, and
// never affect the inbox pipeline or its watermarks (DASH-06).
func (d *Daemon) phaseFeed() {
	if d.feedPipe == nil {
		return
	}
	n, err := d.feedPipe.Publish(time.Now())
	if err != nil {
		d.logger.Printf("feed error: %v", err)
	}
	if n > 0 {
		d.logger.Printf("feed: published %d items", n)
	}
}
```

(No `trackedPipelineRun` — that bookkeeping records AI token/cost stats, which this phase never has.)

- [ ] **Step 2: Wire in `cmd/sync.go`**

Inside the `if cfg.Digest.Enabled { ... }` daemon block, after the `cfg.DayPlan.Enabled` wiring:

```go
if cfg.Feed.Enabled {
	d.SetFeedPipeline(feed.New(database, cfg, logger))
}
```

Add `"watchtower/internal/feed"` to the imports.

- [ ] **Step 3: Verify**

Run: `go build ./... && go vet ./... && go test ./internal/daemon/ ./cmd/`
Expected: clean build, all PASS.

- [ ] **Step 4: Commit**

```bash
git add internal/daemon/daemon.go cmd/sync.go
git commit -m "feat(daemon): publish dashboard feed at the end of each cycle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Swift — FeedItem model, FeedItemQueries, TestDatabase

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/FeedItem.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/FeedItemQueries.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (schema string + fixture helpers)
- Create: `WatchtowerDesktop/Tests/FeedItemQueriesTests.swift`

**Interfaces:**
- Consumes: Task 1 table shapes; existing models `Situation`, `CalendarEvent`, `Briefing`, `DayPlan`, `MeetingRecap`, `MeetingPrepResult`; existing `SituationQueries.fetchByID`, `BriefingQueries.fetchByID`, `MeetingRecapQueries.fetch`.
- Produces (used by Tasks 6-7):
  - `FeedItem` (`FetchableRecord`, `id: Int64`, `itemType: FeedItem.ItemType` enum `CaseIterable`)
  - `FeedContent` enum + `FeedEntry` struct (`id: Int64`)
  - `FeedItemQueries.Filter { types: Set<FeedItem.ItemType>, importantOnly: Bool, showHidden: Bool }`
  - `FeedItemQueries.fetchFeed(_:filter:limit:offset:) throws -> [FeedEntry]`
  - `FeedItemQueries.hide(_:id:)`, `unhide(_:id:)`, `markSeen(_:id:)`

- [ ] **Step 1: Extend the test schema**

In `TestDatabase.swift`'s `schema` string, after the `situation_signals` block, append (mirror of production DDL; `meeting_recaps` and `meeting_prep_cache` are currently missing from the test schema and are now needed for feed joins):

```sql
CREATE TABLE IF NOT EXISTS meeting_prep_cache (
    event_id      TEXT PRIMARY KEY,
    result_json   TEXT NOT NULL DEFAULT '',
    user_notes    TEXT NOT NULL DEFAULT '',
    generated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS meeting_recaps (
    event_id    TEXT PRIMARY KEY REFERENCES calendar_events(id) ON DELETE CASCADE,
    source_text TEXT NOT NULL,
    recap_json  TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS feed_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item_type   TEXT NOT NULL CHECK (item_type IN ('situation','meeting','briefing','meeting_recap','day_plan')),
    source_id   TEXT NOT NULL,
    event_ts    TEXT NOT NULL,
    importance  INTEGER NOT NULL DEFAULT 50,
    hidden_at   TEXT,
    seen_at     TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(item_type, source_id)
);
CREATE INDEX IF NOT EXISTS idx_feed_items_event_ts ON feed_items(event_ts DESC);
```

And fixture helpers next to `insertSituation`:

```swift
@discardableResult
static func insertFeedItem(
    _ db: Database, itemType: String, sourceID: String, eventTs: String,
    importance: Int = 50, hiddenAt: String? = nil, seenAt: String? = nil
) throws -> Int64 {
    try db.execute(
        sql: """
        INSERT INTO feed_items (item_type, source_id, event_ts, importance, hidden_at, seen_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: [itemType, sourceID, eventTs, importance, hiddenAt, seenAt])
    return db.lastInsertedRowID
}

static func insertMeetingRecap(
    _ db: Database, eventID: String,
    recapJSON: String = #"{"summary":"Recap","key_decisions":[],"action_items":["ship it"],"open_questions":[]}"#,
    createdAt: String = "2026-07-09T10:00:00Z"
) throws {
    try db.execute(
        sql: "INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at, updated_at) VALUES (?, '', ?, ?, ?)",
        arguments: [eventID, recapJSON, createdAt, createdAt])
}

static func insertMeetingPrep(_ db: Database, eventID: String, resultJSON: String) throws {
    try db.execute(
        sql: "INSERT INTO meeting_prep_cache (event_id, result_json) VALUES (?, ?)",
        arguments: [eventID, resultJSON])
}
```

- [ ] **Step 2: Write the model**

`Sources/Models/FeedItem.swift`:

```swift
import Foundation
import GRDB

// MARK: - FeedItem

/// One row of the dashboard feed index (table `feed_items`) — chronology plus
/// per-item user state. Content is joined live from the source table named by
/// `itemType`; see `FeedItemQueries.fetchFeed` and `internal/feed` on the Go side.
struct FeedItem: FetchableRecord, Identifiable, Equatable {
    let id: Int64
    let itemTypeRaw: String    // column: item_type
    let sourceID: String       // column: source_id
    let eventTs: String        // column: event_ts (ISO8601)
    let importance: Int
    let hiddenAt: String?      // column: hidden_at
    let seenAt: String?        // column: seen_at

    enum ItemType: String, CaseIterable {
        case situation
        case meeting
        case briefing
        case meetingRecap = "meeting_recap"
        case dayPlan = "day_plan"

        /// Filter-chip / badge label.
        var label: String {
            switch self {
            case .situation: return "Situations"
            case .meeting: return "Meetings"
            case .briefing: return "Briefings"
            case .meetingRecap: return "Recaps"
            case .dayPlan: return "Plans"
            }
        }
    }

    var itemType: ItemType { ItemType(rawValue: itemTypeRaw) ?? .situation }
    var isSeen: Bool { seenAt != nil }

    init(row: Row) {
        id = row["id"]
        itemTypeRaw = row["item_type"] ?? "situation"
        sourceID = row["source_id"] ?? ""
        eventTs = row["event_ts"] ?? ""
        importance = row["importance"] ?? 50
        hiddenAt = row["hidden_at"] as String?
        seenAt = row["seen_at"] as String?
    }

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    var eventDate: Date? { Self.iso8601.date(from: eventTs) }
}

// MARK: - FeedContent / FeedEntry

/// The live-joined source content behind a feed item.
enum FeedContent: Equatable {
    case situation(Situation)
    case meeting(CalendarEvent, prep: MeetingPrepResult?)
    case briefing(Briefing)
    case meetingRecap(MeetingRecap, event: CalendarEvent?)
    case dayPlan(DayPlan)
}

extension MeetingRecap: Equatable {}

/// A feed index row plus its resolved content — one entry of the wall.
struct FeedEntry: Identifiable, Equatable {
    let item: FeedItem
    let content: FeedContent
    var id: Int64 { item.id }
}
```

- [ ] **Step 3: Write failing query tests**

`Tests/FeedItemQueriesTests.swift`:

```swift
import GRDB
import XCTest

@testable import WatchtowerDesktop

final class FeedItemQueriesTests: XCTestCase {
    var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertWorkspace(db)
            // Calendar fixtures (FK: calendar_events → calendar_calendars).
            try db.execute(sql: "INSERT INTO calendar_calendars (id, name) VALUES ('cal1', 'Test')")
            try db.execute(sql: """
                INSERT INTO calendar_events (id, calendar_id, title, start_time, end_time)
                VALUES ('ev1', 'cal1', 'Standup', '2026-07-09T12:10:00Z', '2026-07-09T12:25:00Z')
                """)
        }
    }

    private func insertSituationRow(_ db: Database, id: Int, title: String) throws {
        try db.execute(sql: """
            INSERT INTO situations (id, title, priority, status, updated_at)
            VALUES (?, ?, 'high', 'open', '2026-07-09T09:00:00Z')
            """, arguments: [id, title])
    }

    func test_fetchFeed_ordersByEventTsDescAndJoinsEachType() throws {
        try dbQueue.write { db in
            try insertSituationRow(db, id: 1, title: "release blocked")
            try db.execute(sql: """
                INSERT INTO briefings (id, user_id, date, created_at)
                VALUES (5, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')
                """)
            try TestDatabase.insertMeetingRecap(db, eventID: "ev1", createdAt: "2026-07-09T11:00:00Z")
            try db.execute(sql: """
                INSERT INTO day_plans (id, user_id, plan_date, status, generated_at, created_at, updated_at)
                VALUES (3, 'U1', '2026-07-09', 'active', '2026-07-09T06:00:00Z', '2026-07-09T06:00:00Z', '2026-07-09T06:00:00Z')
                """)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "meeting", sourceID: "ev1", eventTs: "2026-07-09T12:10:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "briefing", sourceID: "5", eventTs: "2026-07-09T07:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "meeting_recap", sourceID: "ev1", eventTs: "2026-07-09T11:00:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "day_plan", sourceID: "3", eventTs: "2026-07-09T06:00:00Z")
        }
        let entries = try dbQueue.read { db in
            try FeedItemQueries.fetchFeed(db, limit: 50, offset: 0)
        }
        XCTAssertEqual(entries.map(\.item.itemTypeRaw),
                       ["meeting", "meeting_recap", "situation", "briefing", "day_plan"])
        guard case .situation(let s) = entries[2].content else { return XCTFail("expected situation") }
        XCTAssertEqual(s.title, "release blocked")
        guard case .meeting(let event, _) = entries[0].content else { return XCTFail("expected meeting") }
        XCTAssertEqual(event.title, "Standup")
        guard case .meetingRecap(let recap, let recapEvent) = entries[1].content else { return XCTFail("expected recap") }
        XCTAssertEqual(recap.parsed?.actionItems, ["ship it"])
        XCTAssertEqual(recapEvent?.id, "ev1")
    }

    func test_fetchFeed_dropsEntriesWithMissingSource() throws {
        try dbQueue.write { db in
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "404", eventTs: "2026-07-09T09:00:00Z")
        }
        let entries = try dbQueue.read { db in
            try FeedItemQueries.fetchFeed(db, limit: 50, offset: 0)
        }
        XCTAssertTrue(entries.isEmpty)
    }

    func test_fetchFeed_filters() throws {
        try dbQueue.write { db in
            try insertSituationRow(db, id: 1, title: "low importance")
            try db.execute(sql: "UPDATE situations SET priority = 'low' WHERE id = 1")
            try insertSituationRow(db, id: 2, title: "hidden one")
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z", importance: 30)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "2", eventTs: "2026-07-09T10:00:00Z", importance: 90, hiddenAt: "2026-07-09T10:30:00Z")
            try TestDatabase.insertFeedItem(db, itemType: "meeting", sourceID: "ev1", eventTs: "2026-07-09T12:10:00Z", importance: 70)
        }
        // Default: hidden excluded.
        var entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, limit: 50, offset: 0) }
        XCTAssertEqual(entries.count, 2)
        // showHidden reveals the hidden situation.
        var filter = FeedItemQueries.Filter()
        filter.showHidden = true
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50, offset: 0) }
        XCTAssertEqual(entries.count, 3)
        // importantOnly keeps >= 70 only.
        filter = FeedItemQueries.Filter()
        filter.importantOnly = true
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50, offset: 0) }
        XCTAssertEqual(entries.map(\.item.itemTypeRaw), ["meeting"])
        // Type filter.
        filter = FeedItemQueries.Filter()
        filter.types = [.situation]
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50, offset: 0) }
        XCTAssertEqual(entries.map(\.item.sourceID), ["1"])
        // Empty type set → empty feed, not a SQL error.
        filter.types = []
        entries = try dbQueue.read { db in try FeedItemQueries.fetchFeed(db, filter: filter, limit: 50, offset: 0) }
        XCTAssertTrue(entries.isEmpty)
    }

    func test_hide_and_markSeen_writeState() throws {
        var itemID: Int64 = 0
        try dbQueue.write { db in
            try self.insertSituationRow(db, id: 1, title: "s")
            itemID = try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z")
        }
        try dbQueue.write { db in
            try FeedItemQueries.hide(db, id: itemID)
            try FeedItemQueries.markSeen(db, id: itemID)
        }
        let (hidden, seen) = try dbQueue.read { db -> (String?, String?) in
            let row = try Row.fetchOne(db, sql: "SELECT hidden_at, seen_at FROM feed_items WHERE id = ?", arguments: [itemID])!
            return (row["hidden_at"], row["seen_at"])
        }
        XCTAssertNotNil(hidden)
        XCTAssertNotNil(seen)
        // markSeen is first-write-wins; a later call must not move the timestamp.
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE feed_items SET seen_at = '2020-01-01T00:00:00Z' WHERE id = ?", arguments: [itemID])
            try FeedItemQueries.markSeen(db, id: itemID)
        }
        let seenAfter = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT seen_at FROM feed_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertEqual(seenAfter, "2020-01-01T00:00:00Z")
        // unhide clears hidden_at.
        try dbQueue.write { db in try FeedItemQueries.unhide(db, id: itemID) }
        let hiddenAfter = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT hidden_at FROM feed_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertNil(hiddenAfter)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter FeedItemQueriesTests > /tmp/swift-feed-queries.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` (compile failure — `FeedItemQueries` undefined). Inspect `/tmp/swift-feed-queries.log` on surprises.

- [ ] **Step 5: Implement `FeedItemQueries`**

`Sources/Database/Queries/FeedItemQueries.swift`:

```swift
import Foundation
import GRDB

/// Reads and per-item state writes for the dashboard feed (`feed_items` index).
/// Content is joined live from the source tables; an entry whose source row is
/// missing is silently dropped (never an error placeholder in the wall).
enum FeedItemQueries {
    /// Threshold for the "Important only" filter — meetings (70) and
    /// high-priority situations (90) pass; routine items (60) don't.
    static let importantThreshold = 70

    struct Filter: Equatable {
        var types: Set<FeedItem.ItemType> = Set(FeedItem.ItemType.allCases)
        var importantOnly: Bool = false
        var showHidden: Bool = false
    }

    static func fetchFeed(_ db: Database, filter: Filter = Filter(), limit: Int, offset: Int) throws -> [FeedEntry] {
        if filter.types.isEmpty { return [] }
        var conditions: [String] = []
        var args: [DatabaseValueConvertible] = []
        if !filter.showHidden {
            conditions.append("hidden_at IS NULL")
        }
        if filter.importantOnly {
            conditions.append("importance >= ?")
            args.append(importantThreshold)
        }
        if filter.types.count < FeedItem.ItemType.allCases.count {
            let placeholders = Array(repeating: "?", count: filter.types.count).joined(separator: ",")
            conditions.append("item_type IN (\(placeholders))")
            args.append(contentsOf: filter.types.map(\.rawValue).sorted())
        }
        var sql = "SELECT * FROM feed_items"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY event_ts DESC, id DESC LIMIT ? OFFSET ?"
        args.append(limit)
        args.append(offset)

        let items = try FeedItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        var entries: [FeedEntry] = []
        entries.reserveCapacity(items.count)
        for item in items {
            guard let content = try loadContent(db, item: item) else { continue }
            entries.append(FeedEntry(item: item, content: content))
        }
        return entries
    }

    static func hide(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: """
            UPDATE feed_items
            SET hidden_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
            WHERE id = ?
            """, arguments: [id])
    }

    static func unhide(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE feed_items SET hidden_at = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
            arguments: [id])
    }

    /// First-write-wins: re-selecting an already-seen item keeps the original mark.
    static func markSeen(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE feed_items SET seen_at = COALESCE(seen_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) WHERE id = ?",
            arguments: [id])
    }

    // MARK: - Content joins

    private static func loadContent(_ db: Database, item: FeedItem) throws -> FeedContent? {
        switch item.itemType {
        case .situation:
            guard let id = Int(item.sourceID),
                  let s = try SituationQueries.fetchByID(db, id: id) else { return nil }
            return .situation(s)
        case .meeting:
            guard let event = try fetchEvent(db, id: item.sourceID) else { return nil }
            return .meeting(event, prep: try fetchPrep(db, eventID: item.sourceID))
        case .briefing:
            guard let id = Int(item.sourceID),
                  let b = try BriefingQueries.fetchByID(db, id: id) else { return nil }
            return .briefing(b)
        case .meetingRecap:
            guard let recap = try MeetingRecapQueries.fetch(db, eventID: item.sourceID) else { return nil }
            return .meetingRecap(recap, event: try fetchEvent(db, id: item.sourceID))
        case .dayPlan:
            guard let id = Int64(item.sourceID),
                  let plan = try DayPlan.fetchOne(db, sql: "SELECT * FROM day_plans WHERE id = ?", arguments: [id]) else { return nil }
            return .dayPlan(plan)
        }
    }

    private static func fetchEvent(_ db: Database, id: String) throws -> CalendarEvent? {
        try CalendarEvent.fetchOne(db, sql: "SELECT * FROM calendar_events WHERE id = ?", arguments: [id])
    }

    private static func fetchPrep(_ db: Database, eventID: String) throws -> MeetingPrepResult? {
        guard let json = try String.fetchOne(
                  db, sql: "SELECT result_json FROM meeting_prep_cache WHERE event_id = ?", arguments: [eventID]),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MeetingPrepResult.self, from: data)
    }
}
```

If `BriefingQueries.fetchByID` / `SituationQueries.fetchByID` signatures differ from `(_ db:, id:)`, match the existing signatures — do not change the existing Queries files.

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd WatchtowerDesktop && swift test --filter FeedItemQueriesTests > /tmp/swift-feed-queries.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/FeedItem.swift WatchtowerDesktop/Sources/Database/Queries/FeedItemQueries.swift WatchtowerDesktop/Tests/Helpers/TestDatabase.swift WatchtowerDesktop/Tests/FeedItemQueriesTests.swift
git commit -m "feat(desktop): feed item model and queries with live content joins

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Swift — FeedViewModel + AppState wiring

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/FeedViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`feedViewModel` property near `dashboardViewModel` ~line 47; create it in `initDashboard(dbManager:)` ~line 344)
- Create: `WatchtowerDesktop/Tests/FeedViewModelTests.swift`

**Interfaces:**
- Consumes: Task 5 `FeedItemQueries` / `FeedEntry`.
- Produces (used by Task 7):
  - `FeedViewModel` (`@MainActor @Observable`): `entries: [FeedEntry]`, `selectedFeedItemID: Int64?`, `selectedEntry: FeedEntry?`, `typeFilter: Set<FeedItem.ItemType>`, `importantOnly: Bool`, `showHidden: Bool`, `load()`, `loadMore()`, `refresh()`, `select(_ id: Int64?)`, `hide(_ entry: FeedEntry)`, `unhide(_ entry: FeedEntry)`, `toggleType(_ type: FeedItem.ItemType)`
  - `AppState.feedViewModel: FeedViewModel?` created alongside `dashboardViewModel` (AppState-owned so filters/selection survive navigation — see the async-state rule)

- [ ] **Step 1: Write failing VM tests**

`Tests/FeedViewModelTests.swift`:

```swift
import GRDB
import XCTest

@testable import WatchtowerDesktop

@MainActor
final class FeedViewModelTests: XCTestCase {
    var dbManager: DatabaseManager!
    var dbPath: String!
    var defaults: UserDefaults!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        defaults = UserDefaults(suiteName: "FeedViewModelTests")!
        defaults.removePersistentDomain(forName: "FeedViewModelTests")
        try dbManager.dbPool.write { db in
            try TestDatabase.insertWorkspace(db)
            try db.execute(sql: """
                INSERT INTO situations (id, title, priority, status, updated_at)
                VALUES (1, 'story', 'high', 'open', '2026-07-09T09:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO briefings (id, user_id, date, created_at)
                VALUES (5, 'U1', '2026-07-09', '2026-07-09T07:00:00Z')
                """)
            try TestDatabase.insertFeedItem(db, itemType: "situation", sourceID: "1", eventTs: "2026-07-09T09:00:00Z", importance: 90)
            try TestDatabase.insertFeedItem(db, itemType: "briefing", sourceID: "5", eventTs: "2026-07-09T07:00:00Z", importance: 60)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeVM() -> FeedViewModel {
        FeedViewModel(dbManager: dbManager, defaults: defaults)
    }

    func test_load_populatesEntriesChronologically() {
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.entries.map(\.item.itemTypeRaw), ["situation", "briefing"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_select_marksSeenInDB() throws {
        let vm = makeVM()
        vm.load()
        vm.select(vm.entries[0].id)
        XCTAssertEqual(vm.selectedEntry?.id, vm.entries[0].id)
        let seen = try dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT seen_at FROM feed_items WHERE id = ?", arguments: [vm.entries[0].id])
        }
        XCTAssertNotNil(seen)
    }

    func test_hide_removesEntryWhenHiddenNotShown() throws {
        let vm = makeVM()
        vm.load()
        let target = vm.entries[1]
        vm.hide(target)
        XCTAssertEqual(vm.entries.count, 1)
        vm.showHidden = true
        XCTAssertEqual(vm.entries.count, 2)
    }

    func test_importantOnly_filters() {
        let vm = makeVM()
        vm.load()
        vm.importantOnly = true
        XCTAssertEqual(vm.entries.map(\.item.itemTypeRaw), ["situation"])
    }

    func test_filtersPersistAcrossInstances() {
        let vm = makeVM()
        vm.load()
        vm.importantOnly = true
        vm.toggleType(.briefing) // switch briefings off
        let vm2 = makeVM()
        XCTAssertTrue(vm2.importantOnly)
        XCTAssertFalse(vm2.typeFilter.contains(.briefing))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter FeedViewModelTests > /tmp/swift-feed-vm.log 2>&1; echo "exit=$?"
```
Expected: `exit=1` (`FeedViewModel` undefined).

- [ ] **Step 3: Implement `FeedViewModel`**

`Sources/ViewModels/FeedViewModel.swift`:

```swift
import Foundation
import GRDB

/// Drives the dashboard's social-wall feed: a chronological list of `FeedEntry`
/// (situations, meetings, briefings, recaps, day plans) with type/importance/
/// hidden filters. AppState-owned so selection and filters survive navigation;
/// filter state persists in UserDefaults (UI preference, not DB state).
@MainActor
@Observable
final class FeedViewModel {
    private(set) var entries: [FeedEntry] = []
    var errorMessage: String?
    var selectedFeedItemID: Int64?

    /// Page size for the feed query; overridable by tests.
    var pageSize: Int = 50
    private var offset: Int = 0

    var typeFilter: Set<FeedItem.ItemType> {
        didSet { persistFilters(); load() }
    }
    var importantOnly: Bool {
        didSet { persistFilters(); load() }
    }
    var showHidden: Bool {
        didSet { persistFilters(); load() }
    }

    var selectedEntry: FeedEntry? {
        guard let id = selectedFeedItemID else { return nil }
        return entries.first { $0.id == id }
    }

    private let dbManager: DatabaseManager
    private let defaults: UserDefaults

    private static let typesKey = "feed.filter.types"
    private static let importantKey = "feed.filter.importantOnly"
    private static let hiddenKey = "feed.filter.showHidden"

    init(dbManager: DatabaseManager, defaults: UserDefaults = .standard) {
        self.dbManager = dbManager
        self.defaults = defaults
        if let raw = defaults.stringArray(forKey: Self.typesKey) {
            typeFilter = Set(raw.compactMap(FeedItem.ItemType.init(rawValue:)))
        } else {
            typeFilter = Set(FeedItem.ItemType.allCases)
        }
        importantOnly = defaults.bool(forKey: Self.importantKey)
        showHidden = defaults.bool(forKey: Self.hiddenKey)
    }

    private var filter: FeedItemQueries.Filter {
        FeedItemQueries.Filter(types: typeFilter, importantOnly: importantOnly, showHidden: showHidden)
    }

    func load() {
        offset = 0
        do {
            entries = try dbManager.dbPool.read { db in
                try FeedItemQueries.fetchFeed(db, filter: self.filter, limit: self.pageSize, offset: 0)
            }
            offset = entries.count
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    func loadMore() {
        do {
            let more = try dbManager.dbPool.read { db in
                try FeedItemQueries.fetchFeed(db, filter: self.filter, limit: self.pageSize, offset: self.offset)
            }
            entries.append(contentsOf: more)
            offset += more.count
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
        }
    }

    func refresh() { load() }

    /// Selects an entry and stamps `seen_at` (first-write-wins in the query).
    func select(_ id: Int64?) {
        selectedFeedItemID = id
        guard let id else { return }
        do {
            try dbManager.dbPool.write { db in
                try FeedItemQueries.markSeen(db, id: id)
            }
        } catch {
            errorMessage = "Failed to mark seen: \(error.localizedDescription)"
        }
    }

    func hide(_ entry: FeedEntry) {
        mutate(entry) { db, id in try FeedItemQueries.hide(db, id: id) }
    }

    func unhide(_ entry: FeedEntry) {
        mutate(entry) { db, id in try FeedItemQueries.unhide(db, id: id) }
    }

    func toggleType(_ type: FeedItem.ItemType) {
        if typeFilter.contains(type) {
            typeFilter.remove(type)
        } else {
            typeFilter.insert(type)
        }
    }

    private func mutate(_ entry: FeedEntry, _ write: (Database, Int64) throws -> Void) {
        do {
            try dbManager.dbPool.write { db in
                try write(db, entry.id)
            }
            if selectedFeedItemID == entry.id {
                selectedFeedItemID = nil
            }
            load()
        } catch {
            errorMessage = "Failed to update feed item: \(error.localizedDescription)"
        }
    }

    private func persistFilters() {
        defaults.set(typeFilter.map(\.rawValue).sorted(), forKey: Self.typesKey)
        defaults.set(importantOnly, forKey: Self.importantKey)
        defaults.set(showHidden, forKey: Self.hiddenKey)
    }
}
```

- [ ] **Step 4: Wire into AppState**

In `AppState.swift`, next to `dashboardViewModel`: `private(set) var feedViewModel: FeedViewModel?`. In `initDashboard(dbManager:)` add `feedViewModel = FeedViewModel(dbManager: dbManager)` after the dashboard VM assignment.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd WatchtowerDesktop && swift test --filter FeedViewModelTests > /tmp/swift-feed-vm.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/FeedViewModel.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Tests/FeedViewModelTests.swift
git commit -m "feat(desktop): feed view model with persistent filters

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Swift — feed UI (rows, filter bar, per-type panes, DashboardView integration)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/FeedRow.swift`
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/FeedFilterBar.swift`
- Create: `WatchtowerDesktop/Sources/Views/Dashboard/FeedDetailPanes.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Dashboard/DashboardView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift`

**Interfaces:**
- Consumes: Task 6 `FeedViewModel` / `AppState.feedViewModel`; existing `SituationRow`, `SituationReviewPane`, `BriefingDetailView(briefing:)`, `DayPlanQueries.fetchItems(_:planId:)`, `appState.navigateToDayPlan(_:)`, `appState.navigateToBriefing(_:)`.
- Produces: the integrated feed UI. No new public interfaces consumed later.

- [ ] **Step 1: Row views**

`Sources/Views/Dashboard/FeedRow.swift`:

```swift
import SwiftUI

/// One row of the wall — dispatches to `SituationRow` for situations and to a
/// shared compact layout (icon + title + badge + relative time) for the rest,
/// mirroring `SituationRow`'s visual language.
struct FeedRow: View {
    let entry: FeedEntry

    var body: some View {
        switch entry.content {
        case .situation(let situation):
            SituationRow(situation: situation)
        case .meeting(let event, _):
            GenericFeedRow(icon: "calendar", tint: .blue, title: event.title,
                           badge: "Meeting", date: event.startDate, isSeen: entry.item.isSeen)
        case .briefing(let briefing):
            GenericFeedRow(icon: "sunrise", tint: .orange, title: "Briefing — \(briefing.dateLabel)",
                           badge: "Briefing", date: entry.item.eventDate, isSeen: entry.item.isSeen)
        case .meetingRecap(let recap, let event):
            GenericFeedRow(icon: "text.badge.checkmark", tint: .green,
                           title: event?.title ?? recap.eventID,
                           badge: "Recap", date: entry.item.eventDate, isSeen: entry.item.isSeen)
        case .dayPlan(let plan):
            GenericFeedRow(icon: "list.bullet.rectangle", tint: .purple,
                           title: "Day plan — \(plan.planDate)",
                           badge: "Plan", date: entry.item.eventDate, isSeen: entry.item.isSeen)
        }
    }
}

/// Shared compact row for non-situation feed types. Unseen items render the
/// title semibold, echoing unread affordances elsewhere in the app.
struct GenericFeedRow: View {
    let icon: String
    let tint: Color
    let title: String
    let badge: String
    let date: Date?
    let isSeen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSeen ? .regular : .semibold)
                    .lineLimit(2)
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 4)
            if let date {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Filter bar**

`Sources/Views/Dashboard/FeedFilterBar.swift`:

```swift
import SwiftUI

/// Thin filter strip above the feed list: per-type chips plus "Important" and
/// "Hidden" toggles. State lives on `FeedViewModel` (persisted to UserDefaults).
struct FeedFilterBar: View {
    @Bindable var vm: FeedViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(FeedItem.ItemType.allCases, id: \.rawValue) { type in
                    Button {
                        vm.toggleType(type)
                    } label: {
                        Text(type.label)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                vm.typeFilter.contains(type) ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Toggle("Important only", isOn: $vm.importantOnly)
                    .font(.caption2)
                Toggle("Show hidden", isOn: $vm.showHidden)
                    .font(.caption2)
                Spacer()
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
```

- [ ] **Step 3: Per-type detail panes**

`Sources/Views/Dashboard/FeedDetailPanes.swift`:

```swift
import SwiftUI

// MARK: - MeetingFeedPane

/// Right pane for an upcoming meeting: event facts plus the cached meeting
/// prep (if `meeting_prep_cache` has one) — no CLI call from the feed.
struct MeetingFeedPane: View {
    let event: CalendarEvent
    let prep: MeetingPrepResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event.title).font(.title2).fontWeight(.semibold)
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(event.startDate, style: .time)
                    Text("–")
                    Text(event.endDate, style: .time)
                    if !event.location.isEmpty {
                        Image(systemName: "mappin").padding(.leading, 8)
                        Text(event.location)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let url = URL(string: event.htmlLink), !event.htmlLink.isEmpty {
                    Link("Open in Google Calendar", destination: url).font(.callout)
                }

                let attendees = event.parsedAttendees
                if !attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attendees").font(.headline)
                        ForEach(attendees) { a in
                            Text(a.displayName.isEmpty ? a.email : a.displayName)
                                .font(.callout)
                        }
                    }
                }

                if let prep {
                    Divider()
                    if !prep.talkingPoints.isEmpty {
                        feedPaneSection("Talking points", prep.talkingPoints.map(\.text))
                    }
                    if !prep.openItems.isEmpty {
                        feedPaneSection("Open items", prep.openItems.map(\.text))
                    }
                    if !prep.suggestedPrep.isEmpty {
                        feedPaneSection("Suggested prep", prep.suggestedPrep)
                    }
                } else if !event.description.isEmpty {
                    Divider()
                    Text(event.description).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - RecapFeedPane

/// Right pane for a finished meeting's recap: summary, decisions, action items.
struct RecapFeedPane: View {
    let recap: MeetingRecap
    let event: CalendarEvent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event?.title ?? "Meeting recap").font(.title2).fontWeight(.semibold)
                if let content = recap.parsed {
                    Text(content.summary).font(.callout)
                    if !content.keyDecisions.isEmpty {
                        feedPaneSection("Key decisions", content.keyDecisions)
                    }
                    if !content.actionItems.isEmpty {
                        feedPaneSection("Action items", content.actionItems)
                    }
                    if !content.openQuestions.isEmpty {
                        feedPaneSection("Open questions", content.openQuestions)
                    }
                } else {
                    Text("Recap unavailable").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - DayPlanFeedPane

/// Right pane for a day plan: compact time-block/backlog list with a jump to
/// the full Day Plan tab (interactive editing lives there, not in the feed).
struct DayPlanFeedPane: View {
    let plan: DayPlan
    @Environment(AppState.self) private var appState
    @State private var items: [DayPlanItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Day plan — \(plan.planDate)").font(.title2).fontWeight(.semibold)
                    Spacer()
                    Button("Open Day Plan") { appState.navigateToDayPlan(plan.planDate) }
                }
                if plan.hasConflicts, let summary = plan.conflictSummary, !summary.isEmpty {
                    Label(summary, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                ForEach(items, id: \.id) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.status == "done" ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.status == "done" ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout)
                            if let start = item.startTime, let end = item.endTime {
                                Text("\(start) – \(end)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .task(id: plan.id) {
            guard let dbPool = appState.databaseManager?.dbPool else { return }
            items = (try? await dbPool.read { db in
                try DayPlanQueries.fetchItems(db, planId: plan.id)
            }) ?? []
        }
    }
}

// MARK: - Shared

@ViewBuilder
func feedPaneSection(_ title: String, _ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        ForEach(lines, id: \.self) { line in
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(line)
            }
            .font(.callout)
        }
    }
}
```

`DayPlanItem` field names (`status`, `startTime`, `endTime`, `title`, `id`) must match `Sources/Models/DayPlanItem.swift` — verify and adjust property names to the actual model (the columns are `status`, `start_time`, `end_time`, `title`). If `DayPlanQueries.fetchItems`'s parameter label differs (`planId:` vs `dayPlanId:`), match the existing signature.

- [ ] **Step 4: Integrate into `DashboardView`**

Modify `DashboardView.swift`:

1. Add the feed VM alongside the existing one: `let vm: DashboardViewModel` stays, add `let feedVM: FeedViewModel`.
2. Replace `situationList` with a feed list (filter bar docked above the `List`, outside it):

```swift
private var feedList: some View {
    VStack(spacing: 0) {
        FeedFilterBar(vm: feedVM)
        Divider()
        List(selection: Binding(
            get: { feedVM.selectedFeedItemID },
            set: { feedVM.select($0) }
        )) {
            ForEach(feedVM.entries) { entry in
                FeedRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu { feedContextMenu(for: entry) }
            }

            Button("Load more") { feedVM.loadMore() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .listStyle(.sidebar)
    }
}

@ViewBuilder
private func feedContextMenu(for entry: FeedEntry) -> some View {
    if case .situation(let situation) = entry.content {
        contextMenu(for: situation) // existing situation menu, unchanged
        Divider()
    }
    if entry.item.hiddenAt == nil {
        Button { feedVM.hide(entry) } label: { Label("Hide", systemImage: "eye.slash") }
    } else {
        Button { feedVM.unhide(entry) } label: { Label("Unhide", systemImage: "eye") }
    }
}
```

3. In `content`, swap `situationList` → `feedList` and gate the empty state on `feedVM.entries.isEmpty` instead of `vm.situations.isEmpty`.
4. Replace `reviewPane` with a type switch. The situation branch reuses the existing `SituationReviewPane` call **verbatim** (same closures, same call-site `.id(situation.id)` — that comment block and behavior are load-bearing, see the 2026-07-08 discuss-chat fix), except `situation` now comes from the feed entry:

```swift
@ViewBuilder
private var reviewPane: some View {
    if let entry = feedVM.selectedEntry {
        switch entry.content {
        case .situation(let situation):
            SituationReviewPane(
                situation: situation,
                memberSignals: vm.memberSignals(for: situation.id),
                memberSignalsLoaded: vm.memberSignalsLoaded(situation.id),
                senderName: { vm.senderName(for: $0) },
                channelName: { vm.channelName(for: $0) },
                slackURL: { vm.slackURL(for: $0) },
                onDone: { vm.done(situation) },
                onDismiss: { vm.dismiss(situation) },
                onSnooze: { option in vm.snooze(situation, until: SnoozeDates.until(option)) },
                onFeedback: { rating, comment in
                    Task { await vm.submitFeedback(situation, rating: rating, comment: comment) }
                },
                isCreatingTarget: isBuildingPrefill,
                onCreateTarget: { openCreateTarget(for: situation) },
                onCreateTrack: { openCreateTrack(for: situation) },
                onOpenTarget: { appState.navigateToTarget($0) },
                onOpenTrack: { appState.navigateToTrack($0) }
            )
            .id(situation.id)
        case .meeting(let event, let prep):
            MeetingFeedPane(event: event, prep: prep).id(entry.id)
        case .briefing(let briefing):
            BriefingDetailView(briefing: briefing).id(entry.id)
        case .meetingRecap(let recap, let event):
            RecapFeedPane(recap: recap, event: event).id(entry.id)
        case .dayPlan(let plan):
            DayPlanFeedPane(plan: plan).id(entry.id)
        }
    } else {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select an item")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

(Preserve the existing call-site `.id` comment above `.id(situation.id)` when moving the code. If `BriefingDetailView` does not scroll on its own, wrap it in `ScrollView` here.)

5. Keep `vm.select` in sync so member signals load for situation entries — add to `body`:

```swift
.onChange(of: feedVM.selectedFeedItemID) { _, _ in
    if case .situation(let situation)? = feedVM.selectedEntry?.content {
        vm.select(situation.id)
    } else {
        vm.select(nil)
    }
}
```

- [ ] **Step 5: Pass the feed VM through `InboxFeedView`**

In `InboxFeedView.swift`: add `private var feedVM: FeedViewModel? { appState.feedViewModel }`; render `DashboardView(vm: dashboardVM, feedVM: feedVM)` when both exist (keep the `ProgressView` fallback otherwise); in `.onAppear` also call `feedVM?.refresh()` (same cross-process-write rationale as the existing `dashboardVM?.refresh()`).

- [ ] **Step 6: Build and run the full Swift suite**

```bash
cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift test > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: both `exit=0`. Existing `DashboardViewModelTests` must still pass untouched — if one fails, fix the integration, not the test (inventory rule).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Dashboard/ WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift
git commit -m "feat(desktop): social-wall feed UI with filter bar and per-type panes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Docs + full verification

**Files:**
- Modify: `docs/app-guide.md` (Inbox section ~line 24; Background Processes ~line 229; Key Concepts ~line 241)

- [ ] **Step 1: Update the app guide**

In the `### Inbox` section, rewrite the tab description to say the tab is a chronological feed ("wall") mixing situation cards with upcoming meetings (published N minutes before start, default 30), daily briefings, meeting recaps, and day plans; describe the filter bar (type chips, "Important only", "Show hidden"), per-item Hide/Unhide via right-click, and that selecting an item marks it seen while past items stay in the feed as history. Under `## Background Processes` add a bullet: "**Feed publisher** — end of each cycle; mirrors situations/meetings/briefings/recaps/day plans into the feed index (no AI)". Under `## Key Concepts` add: "**Feed items** — index rows (`feed_items`) pointing at source records; hiding an item sets `hidden_at`, never deletes."

- [ ] **Step 2: Full verification (real exit codes)**

```bash
go build ./... && go vet ./... && go test ./... > /tmp/go-test.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift test > /tmp/swift-test.log 2>&1; echo "exit=$?"
```
Expected: both `exit=0`. On failure, read the log file, fix, re-run.

- [ ] **Step 3: Commit**

```bash
git add docs/app-guide.md
git commit -m "docs: describe the social-wall feed in the app guide

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Pre-PR quality gate**

Run the `local-review` skill over the branch before opening any PR (project rule from `.claude/skills/`).
