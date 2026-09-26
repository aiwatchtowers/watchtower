# Target Observers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach user-editable "observers" to targets that periodically run the cross-source event stream through an LLM and produce an activity timeline of relevant events, each optionally carrying a confirmable proposed action or attached decision.

**Architecture:** A polymorphic `observers` config table + an `observer_events` timeline table. A new `internal/observers` pipeline runs as a daemon phase: for each enabled observer it gathers recent already-summarized activity (channel digests + tracks + inbox items, which between them cover Slack/Jira/Calendar/decisions) since a per-observer watermark, makes one AI call seeded by the observer's natural-language instruction, and persists the produced events. Active targets with zero observers get a default observer lazily inside the pipeline (single Go chokepoint, no Go/Swift duplication). Events with a `proposed_action` reuse the existing Desktop `ProposedAction` + `TargetActionExecutor` chat infrastructure.

**Tech Stack:** Go 1.25 (modernc.org/sqlite, goose migrations), SwiftUI/GRDB Desktop, multi-provider AI via `digest.Generator`.

## Global Constraints

- Module path is `watchtower`; Go 1.25.
- Migrations are **goose** files `internal/db/migrations/0000N_<name>.sql` with `-- +goose Up`/`-- +goose Down`, auto-applied on `db.Open`. Do NOT bump `CurrentSchemaFormat`.
- Every new table/column must be mirrored into `internal/db/schema.sql` (embedded into the AI prompt), new tables added to `TestAllTablesExist`, and the golden regenerated: `go test ./internal/db/ -run TestSchemaGolden -update`.
- SQLite has no `ALTER TABLE ... ADD CONSTRAINT`; expanding a CHECK enum later needs the table-recreation dance.
- AI prompts must work on BOTH the `claude` and `codex` providers — no provider-specific syntax. New prompt registered via id const in `internal/prompts/store.go` + entry in `Defaults`/`AllIDs`/`DefaultVersions`/`Descriptions` in `internal/prompts/defaults.go`.
- `digest.Generator.Generate(ctx, systemPrompt, userMessage, sessionID) (string, *digest.Usage, string, error)`; tag the call site with `digest.WithSource(ctx, "observer.run")`.
- The `proposed_action` JSON must match the Swift `ProposedAction` shape exactly (`type`, `reason`, `status`, `note`, `progress`, `text`, `intent`, `priority`, `target_id`, `relation`) so the existing executor applies it unchanged.
- PR-facing text in English (per user preference). Go logging via the injected `*log.Logger`.
- For `:memory:` test DBs the pool is already pinned to one connection by `db.Open`.

---

## File Structure

**Go (create):**
- `internal/db/migrations/00005_observers.sql` — schema migration
- `internal/db/observers.go` — Observer/ObserverEvent CRUD, watermark, activity gather
- `internal/db/observers_test.go` — CRUD + activity tests
- `internal/observers/pipeline.go` — Pipeline, New, Run, RunForTarget, lazy default
- `internal/observers/prompt.go` — prompt build + AI-output parse
- `internal/observers/pipeline_test.go` — mockGenerator tests
- `cmd/observers.go` — `observers` CLI command tree

**Go (modify):**
- `internal/db/schema.sql` — mirror both tables
- `internal/db/models.go` — `Observer`, `ObserverEvent` structs
- `internal/db/db_test.go` — add tables to `TestAllTablesExist`
- `internal/db/testdata/schema_v73.golden` — regenerated
- `internal/prompts/store.go` — `ObserverRun` id const
- `internal/prompts/defaults.go` — register `observer.run` + `defaultObserverRun`
- `internal/daemon/daemon.go` — `observerPipe`, `SetObserverPipeline`, `phaseObservers`
- `cmd/sync.go` — wire `SetObserverPipeline`
- `cmd/targets_ai.go` — `targets observe <id>` subcommand
- `cmd/root.go` (or wherever commands register) — register `observersCmd`

**Swift (create):**
- `WatchtowerDesktop/Sources/Models/Observer.swift`
- `WatchtowerDesktop/Sources/Models/ObserverEvent.swift`
- `WatchtowerDesktop/Sources/Database/Queries/ObserverQueries.swift`
- `WatchtowerDesktop/Sources/Services/TargetObserveService.swift`
- `WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift`
- `WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift`
- `WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift`
- `WatchtowerDesktop/Tests/ObserverQueriesTests.swift`

**Swift (modify):**
- `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift` — mount timeline section + manage button

---

## Task 1: Schema — migration, mirror, models, table test

**Files:**
- Create: `internal/db/migrations/00005_observers.sql`
- Modify: `internal/db/schema.sql` (after the targets/target_links block)
- Modify: `internal/db/models.go`
- Modify: `internal/db/db_test.go:107` (table list)
- Test: `internal/db/observers_test.go` (new)
- Regenerate: `internal/db/testdata/schema_v73.golden`

**Interfaces:**
- Produces: tables `observers`, `observer_events`; Go structs `db.Observer`, `db.ObserverEvent`.

- [ ] **Step 1: Write the migration**

Create `internal/db/migrations/00005_observers.sql`:

```sql
-- +goose Up
-- Observers: user-editable watchers attached to an entity (polymorphic via
-- entity_type/entity_id; v1 only uses entity_type='target'). Each enabled
-- observer is run by the daemon over recent cross-source activity since its
-- last_run_at watermark, producing rows in observer_events.
CREATE TABLE IF NOT EXISTS observers (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type  TEXT NOT NULL DEFAULT 'target' CHECK(entity_type IN ('target')),
    entity_id    INTEGER NOT NULL,
    name         TEXT NOT NULL DEFAULT '',
    instruction  TEXT NOT NULL DEFAULT '',
    enabled      INTEGER NOT NULL DEFAULT 1,
    last_run_at  TEXT NOT NULL DEFAULT '',   -- '' = never run; else ISO8601 watermark
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_observers_entity  ON observers(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_observers_enabled ON observers(enabled);

-- observer_events: the per-entity activity timeline produced by observers.
-- decision / proposed_action are optional JSON blobs ('' = absent). proposed_action
-- uses the same shape as the Desktop chat ProposedAction so the existing executor
-- applies it. action_status tracks the lifecycle of a proposed_action.
CREATE TABLE IF NOT EXISTS observer_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    observer_id     INTEGER NOT NULL REFERENCES observers(id) ON DELETE CASCADE,
    entity_type     TEXT NOT NULL DEFAULT 'target',
    entity_id       INTEGER NOT NULL,
    summary         TEXT NOT NULL DEFAULT '',
    detail          TEXT NOT NULL DEFAULT '',
    source_type     TEXT NOT NULL DEFAULT '',
    source_id       TEXT NOT NULL DEFAULT '',
    source_refs     TEXT NOT NULL DEFAULT '[]',
    decision        TEXT NOT NULL DEFAULT '',
    proposed_action TEXT NOT NULL DEFAULT '',
    action_status   TEXT NOT NULL DEFAULT 'none'
                    CHECK(action_status IN ('none','pending','applied','dismissed')),
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_observer_events_entity   ON observer_events(entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_observer_events_observer ON observer_events(observer_id);

-- +goose Down
DROP TABLE IF EXISTS observer_events;
DROP TABLE IF EXISTS observers;
```

- [ ] **Step 2: Mirror into schema.sql**

In `internal/db/schema.sql`, after the `target_links` table block, paste the two `CREATE TABLE IF NOT EXISTS observers (...)` / `observer_events (...)` statements and their indexes **verbatim from Step 1** (the Up section, without the goose comments).

- [ ] **Step 3: Add structs to models.go**

Append to `internal/db/models.go`:

```go
// Observer is a user-editable watcher attached to an entity (polymorphic via
// EntityType/EntityID; v1 only 'target'). The daemon runs each enabled observer
// over recent activity since LastRunAt and writes ObserverEvents.
type Observer struct {
	ID          int    `json:"id"`
	EntityType  string `json:"entity_type"`
	EntityID    int    `json:"entity_id"`
	Name        string `json:"name"`
	Instruction string `json:"instruction"`
	Enabled     bool   `json:"enabled"`
	LastRunAt   string `json:"last_run_at"` // "" = never run
	CreatedAt   string `json:"created_at"`
	UpdatedAt   string `json:"updated_at"`
}

// ObserverEvent is one item on an entity's observer-produced activity timeline.
// Decision and ProposedAction are optional raw JSON ("" = absent). ProposedAction
// matches the Desktop chat ProposedAction shape so the existing executor applies it.
type ObserverEvent struct {
	ID             int    `json:"id"`
	ObserverID     int    `json:"observer_id"`
	EntityType     string `json:"entity_type"`
	EntityID       int    `json:"entity_id"`
	Summary        string `json:"summary"`
	Detail         string `json:"detail"`
	SourceType     string `json:"source_type"`
	SourceID       string `json:"source_id"`
	SourceRefs     string `json:"source_refs"`     // JSON array
	Decision       string `json:"decision"`        // JSON object or ""
	ProposedAction string `json:"proposed_action"` // JSON object or ""
	ActionStatus   string `json:"action_status"`
	ReadAt         string `json:"read_at"` // "" = unread
	CreatedAt      string `json:"created_at"`
}
```

- [ ] **Step 4: Add tables to TestAllTablesExist**

In `internal/db/db_test.go`, add `"observers", "observer_events",` to the `tables` slice (around line 107-111).

- [ ] **Step 5: Run the table test (expect PASS after regen)**

Run: `go test ./internal/db/ -run TestAllTablesExist -v`
Expected: PASS (migration auto-applies on `Open`).

- [ ] **Step 6: Regenerate the schema golden**

Run: `go test ./internal/db/ -run TestSchemaGolden -update && go test ./internal/db/ -run TestSchemaGolden -v`
Expected: second run PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/db/migrations/00005_observers.sql internal/db/schema.sql internal/db/models.go internal/db/db_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(observers): add observers + observer_events schema"
```

---

## Task 2: DB layer — CRUD, watermark, activity gather

**Files:**
- Create: `internal/db/observers.go`
- Test: `internal/db/observers_test.go`

**Interfaces:**
- Consumes: `db.Observer`, `db.ObserverEvent` (Task 1).
- Produces (methods on `*db.DB`):
  - `CreateObserver(o Observer) (int, error)`
  - `GetObserverByID(id int) (*Observer, error)`
  - `GetObserversForEntity(entityType string, entityID int) ([]Observer, error)`
  - `GetEnabledObservers() ([]Observer, error)`
  - `UpdateObserver(id int, name, instruction string) error`
  - `SetObserverEnabled(id int, enabled bool) error`
  - `SetObserverLastRun(id int, at string) error`
  - `DeleteObserver(id int) error`
  - `CountObserversForEntity(entityType string, entityID int) (int, error)`
  - `InsertObserverEvent(e ObserverEvent) (int, error)`
  - `GetObserverEventsForEntity(entityType string, entityID, limit int) ([]ObserverEvent, error)`
  - `MarkObserverEventRead(id int, at string) error`
  - `SetObserverEventActionStatus(id int, status string) error`
  - `GetObserverActivity(since string, limit int) (ObserverActivity, error)` returning `ObserverActivity{Digests []ActivityDigest; Tracks []ActivityTrack; Inbox []ActivityInbox}`

- [ ] **Step 1: Write the failing test**

Create `internal/db/observers_test.go`:

```go
package db

import "testing"

func TestObserverCRUD(t *testing.T) {
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	id, err := d.CreateObserver(Observer{
		EntityType: "target", EntityID: 7,
		Name: "Progress watcher", Instruction: "track progress", Enabled: true,
	})
	if err != nil || id == 0 {
		t.Fatalf("create: id=%d err=%v", id, err)
	}

	got, err := d.GetObserverByID(id)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "Progress watcher" || !got.Enabled || got.EntityID != 7 {
		t.Fatalf("unexpected observer: %+v", got)
	}
	if got.LastRunAt != "" {
		t.Fatalf("new observer should have empty watermark, got %q", got.LastRunAt)
	}

	if err := d.UpdateObserver(id, "Renamed", "new instruction"); err != nil {
		t.Fatal(err)
	}
	if err := d.SetObserverEnabled(id, false); err != nil {
		t.Fatal(err)
	}
	if err := d.SetObserverLastRun(id, "2026-06-27T10:00:00Z"); err != nil {
		t.Fatal(err)
	}
	got, _ = d.GetObserverByID(id)
	if got.Name != "Renamed" || got.Enabled || got.LastRunAt != "2026-06-27T10:00:00Z" {
		t.Fatalf("update/enable/watermark not applied: %+v", got)
	}

	cnt, err := d.CountObserversForEntity("target", 7)
	if err != nil || cnt != 1 {
		t.Fatalf("count: %d err=%v", cnt, err)
	}

	// enabled list excludes the disabled one
	enabled, err := d.GetEnabledObservers()
	if err != nil {
		t.Fatal(err)
	}
	if len(enabled) != 0 {
		t.Fatalf("expected 0 enabled, got %d", len(enabled))
	}

	if err := d.DeleteObserver(id); err != nil {
		t.Fatal(err)
	}
	cnt, _ = d.CountObserversForEntity("target", 7)
	if cnt != 0 {
		t.Fatalf("expected 0 after delete, got %d", cnt)
	}
}

func TestObserverEvents(t *testing.T) {
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	obsID, _ := d.CreateObserver(Observer{EntityType: "target", EntityID: 3, Name: "w", Enabled: true})

	evID, err := d.InsertObserverEvent(ObserverEvent{
		ObserverID: obsID, EntityType: "target", EntityID: 3,
		Summary: "decision made", SourceType: "digest", SourceID: "12",
		SourceRefs: `["https://x"]`,
		ProposedAction: `{"type":"update_status","reason":"done in slack","status":"done"}`,
		ActionStatus: "pending",
	})
	if err != nil || evID == 0 {
		t.Fatalf("insert event: id=%d err=%v", evID, err)
	}

	events, err := d.GetObserverEventsForEntity("target", 3, 50)
	if err != nil || len(events) != 1 {
		t.Fatalf("events: %d err=%v", len(events), err)
	}
	if events[0].ProposedAction == "" || events[0].ActionStatus != "pending" {
		t.Fatalf("event fields lost: %+v", events[0])
	}

	if err := d.MarkObserverEventRead(evID, "2026-06-27T11:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if err := d.SetObserverEventActionStatus(evID, "applied"); err != nil {
		t.Fatal(err)
	}
	events, _ = d.GetObserverEventsForEntity("target", 3, 50)
	if events[0].ReadAt == "" || events[0].ActionStatus != "applied" {
		t.Fatalf("read/action not updated: %+v", events[0])
	}

	// deleting the observer cascades its events
	if err := d.DeleteObserver(obsID); err != nil {
		t.Fatal(err)
	}
	events, _ = d.GetObserverEventsForEntity("target", 3, 50)
	if len(events) != 0 {
		t.Fatalf("events should cascade-delete, got %d", len(events))
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db/ -run 'TestObserver' -v`
Expected: FAIL — undefined methods.

- [ ] **Step 3: Implement the DB layer**

Create `internal/db/observers.go`:

```go
package db

import (
	"database/sql"
	"fmt"
)

// CreateObserver inserts a new observer and returns its id.
func (db *DB) CreateObserver(o Observer) (int, error) {
	if o.EntityType == "" {
		o.EntityType = "target"
	}
	res, err := db.Exec(`
		INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
		VALUES (?, ?, ?, ?, ?)`,
		o.EntityType, o.EntityID, o.Name, o.Instruction, boolToInt(o.Enabled))
	if err != nil {
		return 0, fmt.Errorf("create observer: %w", err)
	}
	id, err := res.LastInsertId()
	return int(id), err
}

func scanObserver(s interface{ Scan(...any) error }) (*Observer, error) {
	var o Observer
	var enabled int
	if err := s.Scan(&o.ID, &o.EntityType, &o.EntityID, &o.Name, &o.Instruction,
		&enabled, &o.LastRunAt, &o.CreatedAt, &o.UpdatedAt); err != nil {
		return nil, err
	}
	o.Enabled = enabled != 0
	return &o, nil
}

const observerCols = `id, entity_type, entity_id, name, instruction, enabled, last_run_at, created_at, updated_at`

// GetObserverByID loads one observer.
func (db *DB) GetObserverByID(id int) (*Observer, error) {
	row := db.QueryRow(`SELECT `+observerCols+` FROM observers WHERE id = ?`, id)
	o, err := scanObserver(row)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("observer %d not found", id)
	}
	return o, err
}

// GetObserversForEntity returns all observers attached to an entity, newest first.
func (db *DB) GetObserversForEntity(entityType string, entityID int) ([]Observer, error) {
	rows, err := db.Query(`SELECT `+observerCols+`
		FROM observers WHERE entity_type = ? AND entity_id = ? ORDER BY created_at`,
		entityType, entityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collectObservers(rows)
}

// GetEnabledObservers returns every enabled observer across all entities.
func (db *DB) GetEnabledObservers() ([]Observer, error) {
	rows, err := db.Query(`SELECT ` + observerCols + ` FROM observers WHERE enabled = 1 ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return collectObservers(rows)
}

func collectObservers(rows *sql.Rows) ([]Observer, error) {
	var out []Observer
	for rows.Next() {
		o, err := scanObserver(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *o)
	}
	return out, rows.Err()
}

// UpdateObserver edits the name and instruction and bumps updated_at.
func (db *DB) UpdateObserver(id int, name, instruction string) error {
	_, err := db.Exec(`UPDATE observers
		SET name = ?, instruction = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, name, instruction, id)
	return err
}

// SetObserverEnabled toggles the enabled flag.
func (db *DB) SetObserverEnabled(id int, enabled bool) error {
	_, err := db.Exec(`UPDATE observers
		SET enabled = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, boolToInt(enabled), id)
	return err
}

// SetObserverLastRun advances the per-observer watermark. It intentionally does
// not touch updated_at (a run is not a user edit).
func (db *DB) SetObserverLastRun(id int, at string) error {
	_, err := db.Exec(`UPDATE observers SET last_run_at = ? WHERE id = ?`, at, id)
	return err
}

// DeleteObserver removes an observer; its events cascade-delete.
func (db *DB) DeleteObserver(id int) error {
	_, err := db.Exec(`DELETE FROM observers WHERE id = ?`, id)
	return err
}

// CountObserversForEntity counts observers attached to an entity.
func (db *DB) CountObserversForEntity(entityType string, entityID int) (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM observers WHERE entity_type = ? AND entity_id = ?`,
		entityType, entityID).Scan(&n)
	return n, err
}

// InsertObserverEvent appends one event to the timeline.
func (db *DB) InsertObserverEvent(e ObserverEvent) (int, error) {
	if e.EntityType == "" {
		e.EntityType = "target"
	}
	if e.SourceRefs == "" {
		e.SourceRefs = "[]"
	}
	if e.ActionStatus == "" {
		e.ActionStatus = "none"
	}
	res, err := db.Exec(`
		INSERT INTO observer_events
			(observer_id, entity_type, entity_id, summary, detail, source_type, source_id,
			 source_refs, decision, proposed_action, action_status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.ObserverID, e.EntityType, e.EntityID, e.Summary, e.Detail, e.SourceType, e.SourceID,
		e.SourceRefs, e.Decision, e.ProposedAction, e.ActionStatus)
	if err != nil {
		return 0, fmt.Errorf("insert observer event: %w", err)
	}
	id, err := res.LastInsertId()
	return int(id), err
}

const observerEventCols = `id, observer_id, entity_type, entity_id, summary, detail,
	source_type, source_id, source_refs, decision, proposed_action, action_status,
	COALESCE(read_at, ''), created_at`

// GetObserverEventsForEntity returns the timeline for an entity, newest first.
func (db *DB) GetObserverEventsForEntity(entityType string, entityID, limit int) ([]ObserverEvent, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.Query(`SELECT `+observerEventCols+`
		FROM observer_events WHERE entity_type = ? AND entity_id = ?
		ORDER BY created_at DESC, id DESC LIMIT ?`, entityType, entityID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ObserverEvent
	for rows.Next() {
		var e ObserverEvent
		if err := rows.Scan(&e.ID, &e.ObserverID, &e.EntityType, &e.EntityID, &e.Summary,
			&e.Detail, &e.SourceType, &e.SourceID, &e.SourceRefs, &e.Decision,
			&e.ProposedAction, &e.ActionStatus, &e.ReadAt, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// MarkObserverEventRead sets read_at.
func (db *DB) MarkObserverEventRead(id int, at string) error {
	_, err := db.Exec(`UPDATE observer_events SET read_at = ? WHERE id = ?`, at, id)
	return err
}

// SetObserverEventActionStatus updates the proposed-action lifecycle.
func (db *DB) SetObserverEventActionStatus(id int, status string) error {
	_, err := db.Exec(`UPDATE observer_events SET action_status = ? WHERE id = ?`, status, id)
	return err
}

// ---- Activity gather (cross-source feed for the observer prompt) ----

// ActivityDigest is a compact recent channel digest for the observer prompt.
type ActivityDigest struct {
	ID        int
	ChannelID string
	Summary   string
	Decisions string // JSON array
	CreatedAt string
}

// ActivityTrack is a compact recent track.
type ActivityTrack struct {
	ID        int
	Text      string
	Context   string
	UpdatedAt string
}

// ActivityInbox is a compact recent inbox item (covers Jira/Calendar/decision triggers).
type ActivityInbox struct {
	ID          int
	TriggerType string
	Snippet     string
	Permalink   string
	CreatedAt   string
}

// ObserverActivity is the bundle of recent cross-source activity fed to observers.
type ObserverActivity struct {
	Digests []ActivityDigest
	Tracks  []ActivityTrack
	Inbox   []ActivityInbox
}

// GetObserverActivity returns recent activity created/updated strictly after the
// `since` ISO8601 watermark, capped at `limit` rows per source. These three
// already-summarized sources together cover Slack (digests), action items
// (tracks), and Jira/Calendar/decision signals (inbox items).
func (db *DB) GetObserverActivity(since string, limit int) (ObserverActivity, error) {
	if limit <= 0 {
		limit = 40
	}
	var act ObserverActivity

	dr, err := db.Query(`SELECT id, channel_id, summary, decisions, created_at
		FROM digests WHERE type = 'channel' AND created_at > ?
		ORDER BY created_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return act, err
	}
	for dr.Next() {
		var a ActivityDigest
		if err := dr.Scan(&a.ID, &a.ChannelID, &a.Summary, &a.Decisions, &a.CreatedAt); err != nil {
			dr.Close()
			return act, err
		}
		act.Digests = append(act.Digests, a)
	}
	dr.Close()

	tr, err := db.Query(`SELECT id, text, context, updated_at
		FROM tracks WHERE dismissed_at = '' AND updated_at > ?
		ORDER BY updated_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return act, err
	}
	for tr.Next() {
		var a ActivityTrack
		if err := tr.Scan(&a.ID, &a.Text, &a.Context, &a.UpdatedAt); err != nil {
			tr.Close()
			return act, err
		}
		act.Tracks = append(act.Tracks, a)
	}
	tr.Close()

	ir, err := db.Query(`SELECT id, trigger_type, snippet, permalink, created_at
		FROM inbox_items WHERE created_at > ?
		ORDER BY created_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return act, err
	}
	for ir.Next() {
		var a ActivityInbox
		if err := ir.Scan(&a.ID, &a.TriggerType, &a.Snippet, &a.Permalink, &a.CreatedAt); err != nil {
			ir.Close()
			return act, err
		}
		act.Inbox = append(act.Inbox, a)
	}
	ir.Close()

	return act, nil
}
```

> NOTE: `*DB` embeds `*sql.DB` (verified), so `db.Exec` / `db.Query` / `db.QueryRow` are the embedded methods called directly on the receiver. `boolToInt(bool) int` already exists in `internal/db/dayplans.go` (same package) — reuse it, do not redefine.

- [ ] **Step 4: Run to verify pass**

Run: `go test ./internal/db/ -run 'TestObserver' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/observers.go internal/db/observers_test.go
git commit -m "feat(observers): db CRUD, watermark, and activity gather"
```

---

## Task 3: Register the `observer.run` prompt

**Files:**
- Modify: `internal/prompts/store.go`
- Modify: `internal/prompts/defaults.go`
- Test: `internal/prompts/` existing seed test (run only)

**Interfaces:**
- Produces: const `prompts.ObserverRun = "observer.run"`, default template `defaultObserverRun`.

- [ ] **Step 1: Add the id const**

In `internal/prompts/store.go`, alongside `TargetsLink`, add:

```go
	ObserverRun          = "observer.run"
```

- [ ] **Step 2: Register in defaults.go**

In `internal/prompts/defaults.go`:
- Add to `Defaults`: `ObserverRun: defaultObserverRun,`
- Add to `AllIDs` (after `TargetsLink`): `ObserverRun,`
- Add to `DefaultVersions`: `ObserverRun: 1, // v1: cross-source event timeline for an observed entity`
- Add to `Descriptions`: `ObserverRun: "Observer run — produce timeline events for an observed entity from recent cross-source activity",`

Then add the template const at the bottom of the file:

```go
const defaultObserverRun = `You are an OBSERVER attached to a single tracked item (a "target": a goal or task the operator owns). Your job: read the operator's WATCH INSTRUCTION, scan the RECENT ACTIVITY from all sources, and emit only the events that are genuinely relevant to THIS target per the instruction. Ignore everything unrelated.

Return ONLY a JSON object (no markdown, no prose):
{
  "events": [
    {
      "summary": "one-line, past-tense, what happened and why it matters to this target",
      "detail": "optional 1-2 extra sentences, or \"\"",
      "source_type": "digest | track | inbox | slack | jira | calendar | decision",
      "source_id": "the id/ref from the activity item, or \"\"",
      "source_refs": ["permalink or link backing this event", "..."],
      "decision": {"text": "what was decided", "by": "@user or \"\"", "importance": "high|medium|low"},
      "proposed_action": {"type": "...", "reason": "why", ...}
    }
  ]
}

Rules:
- Emit an event ONLY when the activity is relevant to this specific target per the watch instruction. Relevance is your judgement; when unsure, leave it out. An empty {"events": []} is a correct and common answer.
- "summary" is mandatory and specific — name the change, not "there was activity".
- Omit "decision" unless a real decision was made; omit "proposed_action" unless a concrete target mutation is warranted.
- "proposed_action" MUST be one of these exact shapes (the app applies it after the operator confirms):
  {"type":"update_status","reason":"...","status":"todo|in_progress|blocked|done|dismissed|snoozed"}
  {"type":"update_progress","reason":"...","progress":0-100}
  {"type":"update_notes","reason":"...","note":"text to append"}
  {"type":"add_sub_item","reason":"...","text":"checklist item"}
  Propose an action only when the activity clearly justifies it. Most events have none.
- Do not invent activity. Every event must trace to an item in RECENT ACTIVITY.
- Keep "summary"/"detail" in the operator's language (match the target text's language).`
```

- [ ] **Step 3: Run the prompts package tests**

Run: `go test ./internal/prompts/ -v`
Expected: PASS (the new id is registered consistently across all maps).

- [ ] **Step 4: Commit**

```bash
git add internal/prompts/store.go internal/prompts/defaults.go
git commit -m "feat(observers): register observer.run prompt"
```

---

## Task 4: Observers pipeline — Run, lazy default, parse, persist

**Files:**
- Create: `internal/observers/pipeline.go`
- Create: `internal/observers/prompt.go`
- Test: `internal/observers/pipeline_test.go`

**Interfaces:**
- Consumes: `db.DB` methods (Task 2), `digest.Generator`, `prompts.ObserverRun`.
- Produces:
  - `observers.New(database *db.DB, gen digest.Generator, logger *log.Logger) *Pipeline`
  - `(*Pipeline).Run(ctx context.Context) (int, error)` — runs all enabled observers, lazy-seeds defaults, returns events created.
  - `(*Pipeline).RunForTarget(ctx context.Context, targetID int) ([]db.ObserverEvent, error)` — force one target, returns new events.
  - `DefaultObserverName = "Activity watcher"`, `DefaultObserverInstruction = "..."`.

- [ ] **Step 1: Write the failing test**

Create `internal/observers/pipeline_test.go`:

```go
package observers

import (
	"context"
	"log"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// mockGen returns a canned AI response and records the prompt it saw.
type mockGen struct {
	resp     string
	lastUser string
	calls    int
}

func (m *mockGen) Generate(ctx context.Context, sys, user, sess string) (string, *digest.Usage, string, error) {
	m.calls++
	m.lastUser = user
	return m.resp, &digest.Usage{}, "", nil
}

func newTarget(t *testing.T, d *db.DB, text string) int {
	t.Helper()
	id, err := d.CreateTarget(db.Target{
		Text: text, Level: "week", PeriodStart: "2026-06-22", PeriodEnd: "2026-06-28",
		Status: "in_progress", Priority: "high", Ownership: "mine",
	})
	if err != nil {
		t.Fatal(err)
	}
	return int(id) // CreateTarget returns int64
}

func TestRunSeedsDefaultObserverAndPersistsEvents(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Ship the billing migration")

	gen := &mockGen{resp: `{"events":[
		{"summary":"Billing decision finalized in #eng","source_type":"digest","source_id":"5",
		 "source_refs":["https://x"],"decision":{"text":"go with plan B","by":"@ann","importance":"high"},
		 "proposed_action":{"type":"update_status","reason":"decided","status":"in_progress"}}]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("expected 1 event, got %d", n)
	}

	// lazy default observer created exactly once
	cnt, _ := d.CountObserversForEntity("target", tid)
	if cnt != 1 {
		t.Fatalf("expected 1 default observer, got %d", cnt)
	}

	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 1 || events[0].ActionStatus != "pending" {
		t.Fatalf("event not persisted with pending action: %+v", events)
	}
	if events[0].Decision == "" || events[0].ProposedAction == "" {
		t.Fatalf("decision/proposed_action lost: %+v", events[0])
	}

	// second run does NOT create a second default observer
	gen.resp = `{"events":[]}`
	if _, err := p.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	cnt, _ = d.CountObserversForEntity("target", tid)
	if cnt != 1 {
		t.Fatalf("default observer duplicated on second run: %d", cnt)
	}
}

func TestRunDegenerateNoEventsAdvancesWatermarkCleanly(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Quiet target")
	gen := &mockGen{resp: `{"events":[]}`}
	p := New(d, gen, log.Default())

	n, err := p.Run(context.Background())
	if err != nil {
		t.Fatalf("degenerate run must not error: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected 0 events, got %d", n)
	}
	obs, _ := d.GetObserversForEntity("target", tid)
	if len(obs) != 1 || obs[0].LastRunAt == "" {
		t.Fatalf("watermark must advance even with no events: %+v", obs)
	}
	events, _ := d.GetObserverEventsForEntity("target", tid, 50)
	if len(events) != 0 {
		t.Fatalf("no events should be inserted, got %d", len(events))
	}
}

func TestRunForTargetReturnsNewEvents(t *testing.T) {
	d, _ := db.Open(":memory:")
	defer d.Close()
	tid := newTarget(t, d, "Force target")
	gen := &mockGen{resp: `{"events":[{"summary":"manual run event","source_type":"track"}]}`}
	p := New(d, gen, log.Default())

	events, err := p.RunForTarget(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Summary != "manual run event" {
		t.Fatalf("unexpected: %+v", events)
	}
}
```

> Confirm `db.CreateTarget` signature and `digest.Usage` exist: `grep -n "func (d \*DB) CreateTarget" internal/db/targets.go` and `grep -n "type Usage" internal/digest/pipeline.go`. If `CreateTarget` takes/returns differently, adjust `newTarget` accordingly.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/observers/ -v`
Expected: FAIL — package/methods undefined.

- [ ] **Step 3: Implement prompt.go**

Create `internal/observers/prompt.go`:

```go
package observers

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// aiEvent mirrors one event in the observer AI output.
type aiEvent struct {
	Summary        string          `json:"summary"`
	Detail         string          `json:"detail"`
	SourceType     string          `json:"source_type"`
	SourceID       string          `json:"source_id"`
	SourceRefs     []string        `json:"source_refs"`
	Decision       json.RawMessage `json:"decision"`
	ProposedAction json.RawMessage `json:"proposed_action"`
}

type aiOutput struct {
	Events []aiEvent `json:"events"`
}

// buildObserverPrompt renders the watch instruction, the target context, and the
// recent cross-source activity into the user message.
func buildObserverPrompt(o db.Observer, target *db.Target, act db.ObserverActivity) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Today: %s\n\n", time.Now().Format("2006-01-02"))

	b.WriteString("WATCH INSTRUCTION:\n")
	instr := strings.TrimSpace(o.Instruction)
	if instr == "" {
		instr = DefaultObserverInstruction
	}
	b.WriteString(instr + "\n\n")

	b.WriteString("TARGET:\n")
	fmt.Fprintf(&b, "- text: %s\n", target.Text)
	if target.Intent != "" {
		fmt.Fprintf(&b, "- why: %s\n", target.Intent)
	}
	fmt.Fprintf(&b, "- status: %s | priority: %s | ownership: %s\n", target.Status, target.Priority, target.Ownership)
	if target.DueDate != "" {
		fmt.Fprintf(&b, "- due: %s\n", target.DueDate)
	}
	b.WriteString("\nRECENT ACTIVITY:\n")

	if len(act.Digests) == 0 && len(act.Tracks) == 0 && len(act.Inbox) == 0 {
		b.WriteString("(none)\n")
		return b.String()
	}
	for _, dgt := range act.Digests {
		fmt.Fprintf(&b, "- [digest id=%d ch=%s] %s\n", dgt.ID, dgt.ChannelID, truncate(dgt.Summary, 400))
		if dgt.Decisions != "" && dgt.Decisions != "[]" {
			fmt.Fprintf(&b, "    decisions: %s\n", truncate(dgt.Decisions, 400))
		}
	}
	for _, tr := range act.Tracks {
		fmt.Fprintf(&b, "- [track id=%d] %s — %s\n", tr.ID, tr.Text, truncate(tr.Context, 240))
	}
	for _, in := range act.Inbox {
		fmt.Fprintf(&b, "- [inbox id=%d %s] %s\n", in.ID, in.TriggerType, truncate(in.Snippet, 240))
	}
	return b.String()
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// parseObserverOutput extracts the events array from a raw AI response,
// tolerating markdown fences and surrounding prose. A missing/empty array is
// not an error.
func parseObserverOutput(raw string) ([]aiEvent, error) {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	start := strings.Index(s, "{")
	end := strings.LastIndex(s, "}")
	if start < 0 || end < start {
		return nil, fmt.Errorf("no JSON object found")
	}
	var out aiOutput
	if err := json.Unmarshal([]byte(s[start:end+1]), &out); err != nil {
		return nil, err
	}
	return out.Events, nil
}

// rawJSONOrEmpty returns the compacted JSON object string if m is a non-empty
// JSON object, else "". Used to drop null/empty decision/proposed_action.
func rawJSONOrEmpty(m json.RawMessage) string {
	t := strings.TrimSpace(string(m))
	if t == "" || t == "null" || t == "{}" {
		return ""
	}
	var probe map[string]any
	if err := json.Unmarshal(m, &probe); err != nil || len(probe) == 0 {
		return ""
	}
	return t
}

// encodeRefs marshals source refs to a JSON array string, never "".
func encodeRefs(refs []string) string {
	if len(refs) == 0 {
		return "[]"
	}
	b, err := json.Marshal(refs)
	if err != nil {
		return "[]"
	}
	return string(b)
}
```

- [ ] **Step 4: Implement pipeline.go**

Create `internal/observers/pipeline.go`:

```go
// Package observers runs user-editable watchers over recent cross-source
// activity and produces an activity timeline of relevant events on the watched
// entity (v1: targets). Each event may carry a confirmable proposed action.
package observers

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// DefaultObserverName / DefaultObserverInstruction seed the auto-created observer
// every active target gets so events appear out of the box.
const (
	DefaultObserverName        = "Activity watcher"
	DefaultObserverInstruction = "Track anything across all sources that affects the progress, status, blockers, or decisions of this goal. Surface relevant updates and flag when the status or next step should change."
)

// defaultLookback bounds the first run of a never-run observer.
const defaultLookback = 7 * 24 * time.Hour

// Pipeline runs observers and persists their events.
type Pipeline struct {
	db     *db.DB
	gen    digest.Generator
	logger *log.Logger
}

// New constructs a Pipeline.
func New(database *db.DB, gen digest.Generator, logger *log.Logger) *Pipeline {
	if logger == nil {
		logger = log.Default()
	}
	return &Pipeline{db: database, gen: gen, logger: logger}
}

// Run lazy-seeds default observers for active targets, then runs every enabled
// observer over activity since its watermark. Returns the number of events
// created. Per-observer failures are logged and skipped.
func (p *Pipeline) Run(ctx context.Context) (int, error) {
	if err := p.seedDefaultObservers(); err != nil {
		p.logger.Printf("observers: seeding defaults: %v", err)
	}
	enabled, err := p.db.GetEnabledObservers()
	if err != nil {
		return 0, err
	}
	total := 0
	for i := range enabled {
		if ctx.Err() != nil {
			return total, ctx.Err()
		}
		events, err := p.runOne(ctx, enabled[i])
		if err != nil {
			p.logger.Printf("observers: observer %d: %v", enabled[i].ID, err)
			continue
		}
		total += len(events)
	}
	return total, nil
}

// RunForTarget force-runs all enabled observers attached to one target,
// seeding a default first if it has none, and returns the new events.
func (p *Pipeline) RunForTarget(ctx context.Context, targetID int) ([]db.ObserverEvent, error) {
	if err := p.ensureDefaultForTarget(targetID); err != nil {
		return nil, err
	}
	obs, err := p.db.GetObserversForEntity("target", targetID)
	if err != nil {
		return nil, err
	}
	var out []db.ObserverEvent
	for i := range obs {
		if !obs[i].Enabled {
			continue
		}
		events, err := p.runOne(ctx, obs[i])
		if err != nil {
			p.logger.Printf("observers: observer %d: %v", obs[i].ID, err)
			continue
		}
		out = append(out, events...)
	}
	return out, nil
}

// seedDefaultObservers creates a default observer for every active target that
// has none. This is the single Go chokepoint for the "auto-default" UX.
func (p *Pipeline) seedDefaultObservers() error {
	targets, err := p.db.GetTargets(db.TargetFilter{Limit: 500})
	if err != nil {
		return err
	}
	for i := range targets {
		t := targets[i]
		if !isActiveStatus(t.Status) {
			continue
		}
		if err := p.ensureDefaultForTarget(t.ID); err != nil {
			p.logger.Printf("observers: default for target %d: %v", t.ID, err)
		}
	}
	return nil
}

func (p *Pipeline) ensureDefaultForTarget(targetID int) error {
	cnt, err := p.db.CountObserversForEntity("target", targetID)
	if err != nil {
		return err
	}
	if cnt > 0 {
		return nil
	}
	_, err = p.db.CreateObserver(db.Observer{
		EntityType: "target", EntityID: targetID,
		Name: DefaultObserverName, Instruction: DefaultObserverInstruction, Enabled: true,
	})
	return err
}

// runOne runs a single observer and persists its events, advancing the watermark.
func (p *Pipeline) runOne(ctx context.Context, o db.Observer) ([]db.ObserverEvent, error) {
	if o.EntityType != "target" {
		return nil, nil // v1 only handles targets
	}
	target, err := p.db.GetTargetByID(o.EntityID)
	if err != nil {
		return nil, fmt.Errorf("loading target %d: %w", o.EntityID, err)
	}

	since := o.LastRunAt
	if since == "" {
		since = time.Now().Add(-defaultLookback).UTC().Format("2006-01-02T15:04:05Z")
	}
	act, err := p.db.GetObserverActivity(since, 40)
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC().Format("2006-01-02T15:04:05Z")

	// No new activity: advance watermark and exit cleanly without an AI call.
	if len(act.Digests) == 0 && len(act.Tracks) == 0 && len(act.Inbox) == 0 {
		return nil, p.db.SetObserverLastRun(o.ID, now)
	}

	user := buildObserverPrompt(o, target, act)
	ctx2 := digest.WithSource(ctx, "observer.run")
	raw, _, _, err := p.gen.Generate(ctx2, p.systemPrompt(), user, "")
	if err != nil {
		return nil, fmt.Errorf("observer AI call: %w", err)
	}
	parsed, err := parseObserverOutput(raw)
	if err != nil {
		return nil, fmt.Errorf("parsing observer output: %w", err)
	}

	var created []db.ObserverEvent
	for _, ev := range parsed {
		if strings.TrimSpace(ev.Summary) == "" {
			continue
		}
		action := rawJSONOrEmpty(ev.ProposedAction)
		status := "none"
		if action != "" {
			status = "pending"
		}
		rec := db.ObserverEvent{
			ObserverID: o.ID, EntityType: "target", EntityID: o.EntityID,
			Summary: ev.Summary, Detail: ev.Detail,
			SourceType: ev.SourceType, SourceID: ev.SourceID,
			SourceRefs:     encodeRefs(ev.SourceRefs),
			Decision:       rawJSONOrEmpty(ev.Decision),
			ProposedAction: action,
			ActionStatus:   status,
		}
		id, err := p.db.InsertObserverEvent(rec)
		if err != nil {
			p.logger.Printf("observers: insert event for observer %d: %v", o.ID, err)
			continue
		}
		rec.ID = id
		created = append(created, rec)
	}

	if err := p.db.SetObserverLastRun(o.ID, now); err != nil {
		return created, err
	}
	return created, nil
}

// systemPrompt loads the registered observer.run template from the DB, falling
// back to the built-in default if the DB has no row. db.GetPrompt returns
// (*db.Prompt, error) and (nil, nil) when the id is not seeded.
func (p *Pipeline) systemPrompt() string {
	if row, err := p.db.GetPrompt(prompts.ObserverRun); err == nil && row != nil && row.Template != "" {
		return row.Template
	}
	return prompts.DefaultFor(prompts.ObserverRun)
}

func isActiveStatus(s string) bool {
	switch s {
	case "todo", "in_progress", "blocked":
		return true
	default:
		return false
	}
}
```

> `systemPrompt()` imports `"watchtower/internal/prompts"` and uses `prompts.ObserverRun` (id const from Task 3) + `prompts.DefaultFor(...)` (the built-in template). `db.GetPrompt` returns `(*db.Prompt, error)` with `(nil, nil)` when not seeded — verified. There is no import cycle: `internal/prompts` does not import `internal/observers`.

- [ ] **Step 5: Run to verify pass**

Run: `go test ./internal/observers/ -v`
Expected: PASS (all three tests).

- [ ] **Step 6: Commit**

```bash
git add internal/observers/
git commit -m "feat(observers): pipeline with lazy default, watermark, and event persistence"
```

---

## Task 5: Daemon phase + CLI wiring

**Files:**
- Modify: `internal/daemon/daemon.go`
- Modify: `cmd/sync.go:288` (near `SetNextStepPipeline`)
- Create: `cmd/observers.go`
- Modify: `cmd/targets_ai.go` (add `targets observe <id>`)
- Modify: command registration (`cmd/root.go` or `cmd/targets_ai.go` `init`)

**Interfaces:**
- Consumes: `observers.New`, `(*observers.Pipeline).Run`, `RunForTarget`.
- Produces: `(*daemon.Daemon).SetObserverPipeline(*observers.Pipeline)`; CLI `watchtower observers ...` and `watchtower targets observe <id>`.

- [ ] **Step 1: Add the daemon field + setter + phase**

In `internal/daemon/daemon.go`:
- Add import `"watchtower/internal/observers"`.
- Add field next to `nextStepPipe`: `observerPipe *observers.Pipeline`.
- Add setter after `SetNextStepPipeline`:

```go
// SetObserverPipeline sets the observers pipeline that produces target activity
// timelines from recent cross-source events.
func (d *Daemon) SetObserverPipeline(p *observers.Pipeline) {
	d.observerPipe = p
}
```

- Add the phase function near `phaseNextStep`:

```go
// phaseObservers runs enabled observers over recent activity, producing timeline
// events on watched targets. Runs after next-step so freshly surfaced targets and
// their lazy default observers are included.
func (d *Daemon) phaseObservers(ctx context.Context) {
	if d.observerPipe == nil {
		return
	}
	d.trackedPipelineRun("observers", func() pipelineRunStats {
		n, err := d.observerPipe.Run(ctx)
		if err != nil {
			d.logger.Printf("observers error: %v", err)
		} else if n > 0 {
			d.logger.Printf("observers: created %d event(s)", n)
		}
		return pipelineRunStats{items: n, err: err}
	})
}
```

- In `runSync`, add the call right after `d.phaseNextStep(ctx)`:

```go
	d.phaseNextStep(ctx)
	d.phaseObservers(ctx)
```

- [ ] **Step 2: Verify daemon builds**

Run: `go build ./internal/daemon/`
Expected: success.

- [ ] **Step 3: Wire the pipeline in cmd/sync.go**

In `cmd/sync.go`, right after the `d.SetNextStepPipeline(...)` line (~288), add:

```go
			d.SetObserverPipeline(observers.New(database, gen, logger))
```

Add `"watchtower/internal/observers"` to the imports of `cmd/sync.go`.

- [ ] **Step 4: Write the observers CLI command**

Create `cmd/observers.go`:

```go
package cmd

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/observers"
)

var (
	observerFlagEntity      string // "target:<id>"
	observerFlagName        string
	observerFlagInstruction string
	observerFlagDisable     bool
	observerFlagEnable      bool
)

var observersCmd = &cobra.Command{
	Use:   "observers",
	Short: "Manage observers that watch entities and produce activity timelines",
}

var observersListCmd = &cobra.Command{
	Use:   "list",
	Short: "List observers (optionally for one entity)",
	RunE:  runObserversList,
}

var observersShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show one observer and its recent events",
	Args:  cobra.ExactArgs(1),
	RunE:  runObserversShow,
}

var observersCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create an observer on an entity (--entity target:<id>)",
	RunE:  runObserversCreate,
}

var observersEditCmd = &cobra.Command{
	Use:   "edit <id>",
	Short: "Edit an observer's name/instruction or toggle enabled",
	Args:  cobra.ExactArgs(1),
	RunE:  runObserversEdit,
}

var observersDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete an observer (events cascade)",
	Args:  cobra.ExactArgs(1),
	RunE:  runObserversDelete,
}

var observersRunCmd = &cobra.Command{
	Use:   "run",
	Short: "Run all enabled observers once (the daemon calls this each cycle)",
	RunE:  runObserversRun,
}

func init() {
	observersListCmd.Flags().StringVar(&observerFlagEntity, "entity", "", "filter by entity, e.g. target:42")
	observersCreateCmd.Flags().StringVar(&observerFlagEntity, "entity", "", "entity to attach to, e.g. target:42")
	observersCreateCmd.Flags().StringVar(&observerFlagName, "name", "", "observer name")
	observersCreateCmd.Flags().StringVar(&observerFlagInstruction, "instruction", "", "natural-language watch instruction")
	observersEditCmd.Flags().StringVar(&observerFlagName, "name", "", "new name")
	observersEditCmd.Flags().StringVar(&observerFlagInstruction, "instruction", "", "new instruction")
	observersEditCmd.Flags().BoolVar(&observerFlagEnable, "enable", false, "enable the observer")
	observersEditCmd.Flags().BoolVar(&observerFlagDisable, "disable", false, "disable the observer")

	observersCmd.AddCommand(observersListCmd, observersShowCmd, observersCreateCmd,
		observersEditCmd, observersDeleteCmd, observersRunCmd)
	rootCmd.AddCommand(observersCmd)
}

func openObserverDB() (*db.DB, *config.Config, error) {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, nil, fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return nil, nil, err
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return nil, nil, fmt.Errorf("opening database: %w", err)
	}
	return database, cfg, nil
}

func parseEntity(s string) (string, int, error) {
	if s == "" {
		return "", 0, fmt.Errorf("--entity is required, e.g. target:42")
	}
	var typ string
	var id int
	if _, err := fmt.Sscanf(s, "%[^:]:%d", &typ, &id); err != nil {
		return "", 0, fmt.Errorf("invalid --entity %q (want target:<id>): %w", s, err)
	}
	if typ != "target" {
		return "", 0, fmt.Errorf("only entity type 'target' is supported")
	}
	return typ, id, nil
}

func runObserversList(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()

	var list []db.Observer
	if observerFlagEntity != "" {
		typ, id, err := parseEntity(observerFlagEntity)
		if err != nil {
			return err
		}
		list, err = database.GetObserversForEntity(typ, id)
		if err != nil {
			return err
		}
	} else {
		list, err = database.GetEnabledObservers()
		if err != nil {
			return err
		}
	}
	for _, o := range list {
		state := "on"
		if !o.Enabled {
			state = "off"
		}
		fmt.Fprintf(cmd.OutOrStdout(), "#%d [%s] %s:%d  %s\n", o.ID, state, o.EntityType, o.EntityID, o.Name)
	}
	return nil
}

func runObserversShow(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid id %q: %w", args[0], err)
	}
	o, err := database.GetObserverByID(id)
	if err != nil {
		return err
	}
	events, err := database.GetObserverEventsForEntity(o.EntityType, o.EntityID, 50)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{"observer": o, "events": events})
}

func runObserversCreate(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	typ, id, err := parseEntity(observerFlagEntity)
	if err != nil {
		return err
	}
	name := observerFlagName
	if name == "" {
		name = observers.DefaultObserverName
	}
	instr := observerFlagInstruction
	if instr == "" {
		instr = observers.DefaultObserverInstruction
	}
	newID, err := database.CreateObserver(db.Observer{
		EntityType: typ, EntityID: id, Name: name, Instruction: instr, Enabled: true,
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "created observer #%d\n", newID)
	return nil
}

func runObserversEdit(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid id %q: %w", args[0], err)
	}
	o, err := database.GetObserverByID(id)
	if err != nil {
		return err
	}
	name, instr := o.Name, o.Instruction
	if observerFlagName != "" {
		name = observerFlagName
	}
	if observerFlagInstruction != "" {
		instr = observerFlagInstruction
	}
	if err := database.UpdateObserver(id, name, instr); err != nil {
		return err
	}
	if observerFlagEnable {
		if err := database.SetObserverEnabled(id, true); err != nil {
			return err
		}
	}
	if observerFlagDisable {
		if err := database.SetObserverEnabled(id, false); err != nil {
			return err
		}
	}
	fmt.Fprintf(cmd.OutOrStdout(), "updated observer #%d\n", id)
	return nil
}

func runObserversDelete(cmd *cobra.Command, args []string) error {
	database, _, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid id %q: %w", args[0], err)
	}
	if err := database.DeleteObserver(id); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "deleted observer #%d\n", id)
	return nil
}

func runObserversRun(cmd *cobra.Command, args []string) error {
	database, cfg, err := openObserverDB()
	if err != nil {
		return err
	}
	defer database.Close()
	applyProviderOverride(cfg)
	gen := cliGenerator(cfg)
	pipe := observers.New(database, gen, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	n, err := pipe.Run(ctx)
	if err != nil {
		return fmt.Errorf("observers run failed: %w", err)
	}
	fmt.Fprintf(cmd.OutOrStdout(), "created %d event(s)\n", n)
	return nil
}
```

> Add `"context"` to the imports. Confirm `rootCmd`, `flagConfig`, `flagWorkspace`, `applyProviderOverride`, `cliGenerator` names exist (they are used by `cmd/targets_ai.go`): `grep -n "rootCmd\|flagConfig\|applyProviderOverride\|func cliGenerator" cmd/targets_ai.go cmd/root.go`. Adjust if the root command variable differs.

- [ ] **Step 5: Add `targets observe <id>` subcommand**

In `cmd/targets_ai.go`, add a command + handler mirroring `runTargetsNextStep`:

```go
var targetsObserveCmd = &cobra.Command{
	Use:   "observe <id>",
	Short: "Force-run observers for one target and print new events as JSON",
	Args:  cobra.ExactArgs(1),
	RunE:  runTargetsObserve,
}

func runTargetsObserve(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid target id %q: %w", args[0], err)
	}
	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	applyProviderOverride(cfg)
	gen := cliGenerator(cfg)
	pipe := observers.New(database, gen, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	events, err := pipe.RunForTarget(ctx, id)
	if err != nil {
		return fmt.Errorf("observe failed: %w", err)
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(events)
}
```

Register it where the other `targets*Cmd` subcommands are added to their parent (find with `grep -n "AddCommand(targetsNextStepCmd\|targetsCmd.AddCommand" cmd/targets_ai.go`) — add `targetsObserveCmd` to the same parent. Add `"watchtower/internal/observers"` to the imports of `cmd/targets_ai.go`.

- [ ] **Step 6: Build the whole project**

Run: `go build ./... && go vet ./cmd/ ./internal/daemon/ ./internal/observers/`
Expected: success.

- [ ] **Step 7: Smoke-test the CLI**

Run:
```bash
go run . observers --help
go run . targets observe --help
```
Expected: help text lists the new commands without error.

- [ ] **Step 8: Commit**

```bash
git add internal/daemon/daemon.go cmd/sync.go cmd/observers.go cmd/targets_ai.go
git commit -m "feat(observers): daemon phase + observers/targets-observe CLI"
```

---

## Task 6: Desktop — models + queries

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/Observer.swift`
- Create: `WatchtowerDesktop/Sources/Models/ObserverEvent.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/ObserverQueries.swift`
- Test: `WatchtowerDesktop/Tests/ObserverQueriesTests.swift`

**Interfaces:**
- Produces: `Observer`, `ObserverEvent` GRDB records; `ObserverQueries` with fetch/create/update/delete/mark-read/set-action-status.

- [ ] **Step 1: Write the Observer model**

Create `WatchtowerDesktop/Sources/Models/Observer.swift`:

```swift
import Foundation
import GRDB

/// A user-editable watcher attached to an entity (v1: a target). Mirrors the Go
/// `observers` table. The daemon runs it over recent activity to produce events.
struct Observer: Codable, FetchableRecord, Identifiable, Equatable, Hashable {
    var id: Int
    var entityType: String
    var entityId: Int
    var name: String
    var instruction: String
    var enabled: Bool
    var lastRunAt: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case entityType = "entity_type"
        case entityId = "entity_id"
        case name, instruction, enabled
        case lastRunAt = "last_run_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
```

- [ ] **Step 2: Write the ObserverEvent model**

Create `WatchtowerDesktop/Sources/Models/ObserverEvent.swift`:

```swift
import Foundation
import GRDB

/// One item on a target's observer-produced activity timeline. Mirrors the Go
/// `observer_events` table. `proposedAction` decodes into the existing
/// `ProposedAction` so the chat executor can apply it.
struct ObserverEvent: Codable, FetchableRecord, Identifiable, Equatable {
    var id: Int
    var observerId: Int
    var entityType: String
    var entityId: Int
    var summary: String
    var detail: String
    var sourceType: String
    var sourceId: String
    var sourceRefs: String      // JSON array string
    var decision: String        // JSON object or ""
    var proposedAction: String  // JSON object or ""
    var actionStatus: String
    var readAt: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case observerId = "observer_id"
        case entityType = "entity_type"
        case entityId = "entity_id"
        case summary, detail
        case sourceType = "source_type"
        case sourceId = "source_id"
        case sourceRefs = "source_refs"
        case decision
        case proposedAction = "proposed_action"
        case actionStatus = "action_status"
        case readAt = "read_at"
        case createdAt = "created_at"
    }

    var isUnread: Bool { (readAt ?? "").isEmpty }

    /// Permalinks/links backing this event.
    var decodedRefs: [String] {
        guard let data = sourceRefs.data(using: .utf8),
              let refs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return refs
    }

    /// The confirmable proposed action, if any, decoded into the shared type.
    var decodedAction: ProposedAction? {
        guard !proposedAction.isEmpty, let data = proposedAction.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProposedAction.self, from: data)
    }

    /// The attached decision summary text, if any.
    var decodedDecisionText: String? {
        guard !decision.isEmpty, let data = decision.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}
```

- [ ] **Step 3: Write the queries**

Create `WatchtowerDesktop/Sources/Database/Queries/ObserverQueries.swift`:

```swift
import Foundation
import GRDB

enum ObserverQueries {

    // MARK: - Observers

    static func fetchForEntity(_ db: Database, entityType: String = "target", entityId: Int) throws -> [Observer] {
        try Observer.fetchAll(db, sql: """
            SELECT * FROM observers WHERE entity_type = ? AND entity_id = ? ORDER BY created_at
            """, arguments: [entityType, entityId])
    }

    @discardableResult
    static func create(_ db: Database, entityType: String = "target", entityId: Int,
                       name: String, instruction: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO observers (entity_type, entity_id, name, instruction, enabled)
            VALUES (?, ?, ?, ?, 1)
            """, arguments: [entityType, entityId, name, instruction])
        return db.lastInsertedRowID
    }

    static func update(_ db: Database, id: Int, name: String, instruction: String) throws {
        try db.execute(sql: """
            UPDATE observers SET name = ?, instruction = ?,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [name, instruction, id])
    }

    static func setEnabled(_ db: Database, id: Int, enabled: Bool) throws {
        try db.execute(sql: """
            UPDATE observers SET enabled = ?,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [enabled ? 1 : 0, id])
    }

    static func delete(_ db: Database, id: Int) throws {
        try db.execute(sql: "DELETE FROM observers WHERE id = ?", arguments: [id])
    }

    // MARK: - Events

    static func fetchEvents(_ db: Database, entityType: String = "target", entityId: Int, limit: Int = 100) throws -> [ObserverEvent] {
        try ObserverEvent.fetchAll(db, sql: """
            SELECT * FROM observer_events WHERE entity_type = ? AND entity_id = ?
            ORDER BY created_at DESC, id DESC LIMIT ?
            """, arguments: [entityType, entityId, limit])
    }

    static func unreadCount(_ db: Database, entityType: String = "target", entityId: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM observer_events
            WHERE entity_type = ? AND entity_id = ? AND (read_at IS NULL OR read_at = '')
            """, arguments: [entityType, entityId]) ?? 0
    }

    static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: """
            UPDATE observer_events SET read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [id])
    }

    static func setActionStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(sql: "UPDATE observer_events SET action_status = ? WHERE id = ?",
                       arguments: [status, id])
    }
}
```

- [ ] **Step 4: Write the tests**

Create `WatchtowerDesktop/Tests/ObserverQueriesTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class ObserverQueriesTests: XCTestCase {

    /// Builds an in-memory DB with the observers/observer_events tables.
    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE observers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_type TEXT NOT NULL DEFAULT 'target',
                    entity_id INTEGER NOT NULL,
                    name TEXT NOT NULL DEFAULT '',
                    instruction TEXT NOT NULL DEFAULT '',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    last_run_at TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL DEFAULT '',
                    updated_at TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE observer_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    observer_id INTEGER NOT NULL,
                    entity_type TEXT NOT NULL DEFAULT 'target',
                    entity_id INTEGER NOT NULL,
                    summary TEXT NOT NULL DEFAULT '',
                    detail TEXT NOT NULL DEFAULT '',
                    source_type TEXT NOT NULL DEFAULT '',
                    source_id TEXT NOT NULL DEFAULT '',
                    source_refs TEXT NOT NULL DEFAULT '[]',
                    decision TEXT NOT NULL DEFAULT '',
                    proposed_action TEXT NOT NULL DEFAULT '',
                    action_status TEXT NOT NULL DEFAULT 'none',
                    read_at TEXT,
                    created_at TEXT NOT NULL DEFAULT ''
                );
                """)
        }
        return dbQueue
    }

    func testCreateFetchUpdateDelete() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            let id = try ObserverQueries.create(db, entityId: 5, name: "W", instruction: "watch")
            XCTAssertGreaterThan(id, 0)

            var obs = try ObserverQueries.fetchForEntity(db, entityId: 5)
            XCTAssertEqual(obs.count, 1)
            XCTAssertEqual(obs[0].name, "W")
            XCTAssertTrue(obs[0].enabled)

            try ObserverQueries.update(db, id: Int(id), name: "W2", instruction: "watch2")
            try ObserverQueries.setEnabled(db, id: Int(id), enabled: false)
            obs = try ObserverQueries.fetchForEntity(db, entityId: 5)
            XCTAssertEqual(obs[0].name, "W2")
            XCTAssertFalse(obs[0].enabled)

            try ObserverQueries.delete(db, id: Int(id))
            XCTAssertEqual(try ObserverQueries.fetchForEntity(db, entityId: 5).count, 0)
        }
    }

    func testEventsDecodeAndReadAndAction() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO observer_events
                  (observer_id, entity_id, summary, source_type, source_refs, decision, proposed_action, action_status)
                VALUES (1, 9, 'decided X', 'digest', '["https://x"]',
                        '{"text":"go plan B","by":"@ann","importance":"high"}',
                        '{"type":"update_status","reason":"decided","status":"in_progress"}', 'pending')
                """)
            let events = try ObserverQueries.fetchEvents(db, entityId: 9)
            XCTAssertEqual(events.count, 1)
            let e = events[0]
            XCTAssertTrue(e.isUnread)
            XCTAssertEqual(e.decodedRefs, ["https://x"])
            XCTAssertEqual(e.decodedDecisionText, "go plan B")
            XCTAssertEqual(e.decodedAction?.type, .updateStatus)
            XCTAssertEqual(e.decodedAction?.status, "in_progress")

            XCTAssertEqual(try ObserverQueries.unreadCount(db, entityId: 9), 1)
            try ObserverQueries.markRead(db, id: e.id)
            try ObserverQueries.setActionStatus(db, id: e.id, status: "applied")
            let after = try ObserverQueries.fetchEvents(db, entityId: 9)
            XCTAssertFalse(after[0].isUnread)
            XCTAssertEqual(after[0].actionStatus, "applied")
            XCTAssertEqual(try ObserverQueries.unreadCount(db, entityId: 9), 0)
        }
    }
}
```

- [ ] **Step 5: Run the Swift tests**

Run: `cd WatchtowerDesktop && swift test --filter ObserverQueriesTests`
Expected: PASS.

> If `swift test` builds the whole target and fails on the not-yet-written views from Task 7, run this step's tests after Task 7, or temporarily run `swift build` to confirm models/queries compile. The two tasks are committed separately but the suite is green only once both compile.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/Observer.swift WatchtowerDesktop/Sources/Models/ObserverEvent.swift WatchtowerDesktop/Sources/Database/Queries/ObserverQueries.swift WatchtowerDesktop/Tests/ObserverQueriesTests.swift
git commit -m "feat(observers): Desktop models + queries"
```

---

## Task 7: Desktop — service, view model, timeline + management UI

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TargetObserveService.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift`

**Interfaces:**
- Consumes: `ObserverQueries`, `Observer`, `ObserverEvent`, `ProposedAction`, the existing `TargetActionExecutor`, `CLIRunnerProtocol`, the app's `DatabaseQueue` accessor.
- Produces: `TargetObserveService`, `ObserverTimelineViewModel`, two SwiftUI views.

- [ ] **Step 1: Write the service**

Create `WatchtowerDesktop/Sources/Services/TargetObserveService.swift`:

```swift
import Foundation

/// Bridges the Desktop app to `watchtower targets observe <id>`, which force-runs
/// the target's observers and prints the new events as JSON. Used for manual
/// "refresh now"; the daemon produces events automatically otherwise.
/// See `cmd/targets_ai.go` `runTargetsObserve`.
struct TargetObserveService {
    let runner: CLIRunnerProtocol

    func run(targetID: Int) async throws -> [ObserverEvent] {
        let data = try await runner.run(args: ["targets", "observe", "\(targetID)"])
        if data.isEmpty { return [] }
        return (try? JSONDecoder().decode([ObserverEvent].self, from: data)) ?? []
    }
}
```

> The Go side emits snake_case JSON (struct tags), so decoding into `ObserverEvent` (which has `CodingKeys`) works directly. Confirm `CLIRunnerProtocol.run(args:)` returns `Data` (it does for `TargetNextStepService`).

- [ ] **Step 2: Write the view model**

Create `WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift`:

VERIFIED repo facts this code matches (do NOT re-derive):
- App-wide DB type is `DatabasePool`, reached via `DatabaseManager.dbPool`. ViewModels take a `DatabaseManager` (see `TargetChatViewModel(target:viewModel:dbManager:)`) and use `dbManager.dbPool.read/write { db in ... }`.
- The observation pattern used by `TargetsViewModel` is an async stream: `for try await v in observation.values(in: dbPool) { ... }` inside a `Task`, NOT `.start(in:)`.
- `TargetActionExecutor.apply` is **static and synchronous**: `static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) throws -> String`. So the VM holds the `Target` and the `TargetsViewModel` and calls it directly — there is no executor instance.
- `ObserverQueries` methods take a GRDB `Database` and work with a `DatabasePool` unchanged.

```swift
import Foundation
import GRDB

/// Drives the observer timeline + management UI on a target's detail view.
/// Observes `observers` + `observer_events` for the target and applies a
/// confirmed proposed action through the shared (static) `TargetActionExecutor`,
/// reusing the same Target + TargetsViewModel the chat path uses.
@MainActor
@Observable
final class ObserverTimelineViewModel {
    let target: Target
    private let dbPool: DatabasePool
    private let targetsViewModel: TargetsViewModel
    private let observeService: TargetObserveService

    var observers: [Observer] = []
    var events: [ObserverEvent] = []
    var isRefreshing = false
    var errorMessage: String?

    private var observationTask: Task<Void, Never>?

    init(target: Target, dbManager: DatabaseManager,
         targetsViewModel: TargetsViewModel, observeService: TargetObserveService) {
        self.target = target
        self.dbPool = dbManager.dbPool
        self.targetsViewModel = targetsViewModel
        self.observeService = observeService
    }

    deinit { observationTask?.cancel() }

    func start() {
        let id = target.id
        let dbPool = self.dbPool
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db -> ([Observer], [ObserverEvent]) in
                let obs = try ObserverQueries.fetchForEntity(db, entityId: id)
                let evs = try ObserverQueries.fetchEvents(db, entityId: id)
                return (obs, evs)
            }
            do {
                for try await result in observation.values(in: dbPool) {
                    guard let self else { return }
                    self.observers = result.0
                    self.events = result.1
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await observeService.run(targetID: target.id)
            // The CLI wrote rows; the ValueObservation stream pushes them.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ event: ObserverEvent) {
        guard event.isUnread else { return }
        try? dbPool.write { db in try ObserverQueries.markRead(db, id: event.id) }
    }

    /// Applies a confirmed proposed action via the shared static executor, then
    /// records the event's action_status so the button does not re-fire.
    func applyAction(for event: ObserverEvent) {
        guard let action = event.decodedAction else { return }
        do {
            _ = try TargetActionExecutor.apply(action, target: target, viewModel: targetsViewModel)
            try dbPool.write { db in
                try ObserverQueries.setActionStatus(db, id: event.id, status: "applied")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissAction(for event: ObserverEvent) {
        try? dbPool.write { db in
            try ObserverQueries.setActionStatus(db, id: event.id, status: "dismissed")
        }
    }

    // Observer management
    func createObserver(name: String, instruction: String) {
        try? dbPool.write { db in
            _ = try ObserverQueries.create(db, entityId: target.id, name: name, instruction: instruction)
        }
    }

    func updateObserver(_ o: Observer, name: String, instruction: String) {
        try? dbPool.write { db in try ObserverQueries.update(db, id: o.id, name: name, instruction: instruction) }
    }

    func toggleObserver(_ o: Observer) {
        try? dbPool.write { db in try ObserverQueries.setEnabled(db, id: o.id, enabled: !o.enabled) }
    }

    func deleteObserver(_ o: Observer) {
        try? dbPool.write { db in try ObserverQueries.delete(db, id: o.id) }
    }
}
```

> `applyAction` is now synchronous (the executor is sync); the timeline view calls it as `viewModel.applyAction(for: event)` WITHOUT `Task {}`/`await`. Adjust the "Apply" button in Step 3 accordingly (it currently wraps the call in `Task { await ... }`).

- [ ] **Step 3: Write the timeline view**

Create `WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift`:

```swift
import SwiftUI

/// The observer-produced activity timeline shown on a target's detail page.
struct ObserverTimelineView: View {
    @State var viewModel: ObserverTimelineViewModel
    @State private var showingManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.headline)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor).foregroundColor(.white).clipShape(Capsule())
                }
                Spacer()
                Button { Task { await viewModel.refreshNow() } } label: {
                    if viewModel.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRefreshing)
                Button { showingManage = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
            }

            if viewModel.events.isEmpty {
                Text("No activity yet. Observers will surface relevant updates as they happen.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    ObserverEventRow(event: event, viewModel: viewModel)
                        .onAppear { viewModel.markRead(event) }
                }
            }
        }
        .onAppear { viewModel.start() }
        .sheet(isPresented: $showingManage) {
            ObserverManagementSheet(viewModel: viewModel)
        }
    }

    private var unreadCount: Int { viewModel.events.filter { $0.isUnread }.count }
}

private struct ObserverEventRow: View {
    let event: ObserverEvent
    let viewModel: ObserverTimelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if event.isUnread { Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 6) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary).font(.body)
                    if !event.detail.isEmpty {
                        Text(event.detail).font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        if !event.sourceType.isEmpty {
                            Text(event.sourceType.uppercased()).font(.caption2).foregroundColor(.secondary)
                        }
                        if let decision = event.decodedDecisionText {
                            Label(decision, systemImage: "checkmark.seal")
                                .font(.caption2).foregroundColor(.orange).lineLimit(1)
                        }
                        ForEach(event.decodedRefs, id: \.self) { ref in
                            if let url = URL(string: ref) {
                                Link(destination: url) { Image(systemName: "link").font(.caption2) }
                            }
                        }
                    }
                }
            }
            if event.actionStatus == "pending", let action = event.decodedAction {
                HStack(spacing: 8) {
                    Text(action.reason).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    Spacer()
                    Button("Apply") { viewModel.applyAction(for: event) }
                        .controlSize(.small)
                    Button("Dismiss") { viewModel.dismissAction(for: event) }
                        .controlSize(.small).buttonStyle(.borderless)
                }
                .padding(.top, 2)
            } else if event.actionStatus == "applied" {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundColor(.green)
            }
            Divider()
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 4: Write the management sheet**

Create `WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift`:

```swift
import SwiftUI

/// Add/edit/enable/delete the observers attached to a target.
struct ObserverManagementSheet: View {
    @State var viewModel: ObserverTimelineViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newInstruction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Observers").font(.title3).bold()

            List {
                ForEach(viewModel.observers) { observer in
                    ObserverEditRow(observer: observer, viewModel: viewModel)
                }
            }
            .frame(minHeight: 160)

            Divider()
            Text("Add observer").font(.headline)
            TextField("Name", text: $newName)
            TextField("What should it watch for?", text: $newInstruction, axis: .vertical)
                .lineLimit(2...4)
            HStack {
                Spacer()
                Button("Add") {
                    let name = newName.isEmpty ? "Observer" : newName
                    viewModel.createObserver(name: name, instruction: newInstruction)
                    newName = ""; newInstruction = ""
                }
                .disabled(newInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 460)
    }
}

private struct ObserverEditRow: View {
    let observer: Observer
    let viewModel: ObserverTimelineViewModel
    @State private var name: String
    @State private var instruction: String
    @State private var editing = false

    init(observer: Observer, viewModel: ObserverTimelineViewModel) {
        self.observer = observer
        self.viewModel = viewModel
        _name = State(initialValue: observer.name)
        _instruction = State(initialValue: observer.instruction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(get: { observer.enabled },
                                         set: { _ in viewModel.toggleObserver(observer) }))
                    .labelsHidden()
                if editing {
                    TextField("Name", text: $name)
                } else {
                    Text(observer.name).font(.body)
                }
                Spacer()
                Button(editing ? "Save" : "Edit") {
                    if editing { viewModel.updateObserver(observer, name: name, instruction: instruction) }
                    editing.toggle()
                }
                .controlSize(.small)
                Button(role: .destructive) { viewModel.deleteObserver(observer) } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small).buttonStyle(.borderless)
            }
            if editing {
                TextField("Instruction", text: $instruction, axis: .vertical).lineLimit(2...4)
            } else if !observer.instruction.isEmpty {
                Text(observer.instruction).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 5: Mount in TargetDetailView**

`TargetDetailView` already has `let target: Target`, `let viewModel: TargetsViewModel`, and a `dbManager` in scope (it builds `TargetChatViewModel(target: target, viewModel: viewModel, dbManager: dbManager)` and calls `dbManager.dbPool.read { ... }`). Build the timeline VM **lazily and once**, mirroring how `chatVM` is held — do NOT construct a fresh VM inside `body` (that would re-subscribe the observation every render).

Add a state holder near the other `@State` vars:

```swift
    @State private var observerVM: ObserverTimelineViewModel?
```

Render the section where the next-step card / detail sections are (search for the next-step card or `TargetNextStepCard`/`nextStep` usage), inside the main detail `VStack`:

```swift
            if let observerVM {
                ObserverTimelineView(viewModel: observerVM)
            }
```

And build it once in an `.onAppear` on that container (or reuse the existing `.onAppear`/`.task` the view already has), using the runner pattern the file already uses (`ProcessCLIRunner.makeDefault()`):

```swift
            .onAppear {
                if observerVM == nil, let runner = ProcessCLIRunner.makeDefault() {
                    observerVM = ObserverTimelineViewModel(
                        target: target,
                        dbManager: dbManager,
                        targetsViewModel: viewModel,
                        observeService: TargetObserveService(runner: runner)
                    )
                    observerVM?.start()
                }
            }
```

Use the SAME `dbManager` symbol the surrounding code already uses (e.g. the one passed to `TargetChatViewModel`). Do not introduce a new DB accessor. If the view has multiple `.onAppear`s, fold this into the one that already builds `chatVM`.

- [ ] **Step 6: Build and test Desktop**

Run: `cd WatchtowerDesktop && swift build && swift test --filter ObserverQueriesTests`
Expected: build succeeds; tests PASS.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetObserveService.swift WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift
git commit -m "feat(observers): Desktop timeline + observer management UI"
```

---

## Final verification

- [ ] `go build ./... && go test ./internal/db/ ./internal/observers/ ./internal/prompts/ ./internal/daemon/`
- [ ] `cd WatchtowerDesktop && swift build && swift test`
- [ ] `go run . observers list` and `go run . targets observe <real-id>` against a dev DB produce sane output.
- [ ] Run `local-review` skill before opening the PR (per CLAUDE.md quality gate).

## Notes / deferred (v1 out of scope)

- Explicit per-observer source/channel/people filters (the LLM does relevance from the instruction).
- Observers on non-target entities in the UI (schema is polymorphic and ready).
- Direct Jira/Calendar gather beyond what inbox items already surface.
- Per-observer cadence/scheduling (runs every daemon cycle).
