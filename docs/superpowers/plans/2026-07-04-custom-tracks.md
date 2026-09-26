# Custom Tracks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the observer engine into first-class **custom tracks** — user describes what to watch, an LLM drafts a watch instruction, a scan pipeline reads recent activity and emits a timeline of events (with confirmable actions), and custom tracks take dedup priority so auto-extracted tracks fold into them instead of duplicating.

**Architecture:** One entity — the `tracks` row — gains an `origin` (`auto`|`custom`). Custom tracks carry an `instruction`, an `enabled` flag, a `last_run_at` scan watermark, and an optional `linked_target_id`. A new `track_events` table holds their timeline (ported from `observer_events`). The `internal/observers` engine is ported to a new `internal/customtracks` package, re-pointed from targets to tracks. The existing tracks dedup ladder in `storeTrackItems` is extended to prefer custom tracks and **fold** matching auto content into them without overwriting their narrative. The `observers`/`observer_events` tables, `internal/observers`, `cmd/observers.go`, and the `targets observe` verb are removed (no data to migrate).

**Tech Stack:** Go 1.25 · `modernc.org/sqlite` (`database/sql`) · goose migrations · SwiftUI macOS (Swift 5.10, macOS 14+) · GRDB.swift · cobra/viper.

## Global Constraints

- Go module `watchtower`; Go 1.25. SQLite via `modernc.org/sqlite` (pure Go, `database/sql`).
- Schema changes use **goose** migrations: `internal/db/migrations/0000N_<name>.sql` with `-- +goose Up` / `-- +goose Down`, auto-embedded and applied on `db.Open`. **Do NOT** bump `CurrentSchemaFormat` for ordinary changes. Next migration number: **`00008`**.
- Every schema change must be mirrored into `internal/db/schema.sql` (embedded + injected into the AI prompt), new tables added to `TestAllTablesExist`, and the golden snapshot regenerated: `go test ./internal/db/ -run TestSchemaGolden -update`.
- SQLite cannot `ALTER TABLE ... ADD CONSTRAINT`; widening an **existing** column's CHECK needs the table-recreation dance. Adding a **new** column with a column-level CHECK whose default satisfies it (e.g. `origin TEXT NOT NULL DEFAULT 'auto' CHECK(...)`) is allowed via `ADD COLUMN` — no recreation.
- `tracks` positional column lists must stay in sync across four places when a column is added: `internal/db/schema.sql` (CREATE TABLE), `trackSelectCols` (`internal/db/tracks.go:9-17`), the `scanTrack` arg order (`internal/db/tracks.go:22-30`), and both `UpsertTrack` INSERT/UPDATE lists. Swift `Track.init(row:)` reads columns by name, so append there too.
- Prompts must work on **both** the `claude` and `codex` providers. Register a new prompt in all four `internal/prompts/defaults.go` maps + a template const, keyed by a `store.go` const. See the `.claude/skills/add-ai-prompt` skill.
- Behavior inventory: before touching `internal/tracks` or `internal/targets`, read the matching file under `docs/inventory/` (map in `docs/inventory/README.md`). Guard tests use the `Test<Module>NN_` convention — do NOT weaken/rename/split them. If a change would break a guard, **stop and ask the owner**.
- Desktop tests: `cd WatchtowerDesktop && swift test`. Go tests: `go test ./...`. Lint mirror before PR: gofmt + `go vet` + golangci-lint + `go build` (+ `swift build`/lint when Desktop changed) — via the `local-review` skill.
- All GitHub-facing text (PR titles/bodies) in English.

---

## File Structure

**Go — created:**
- `internal/db/migrations/00008_custom_tracks.sql` — schema migration.
- `internal/db/track_events.go` — `TrackEvent` CRUD + scan-activity gather (ported from `internal/db/observers.go`).
- `internal/customtracks/pipeline.go` — scan/compose engine (ported from `internal/observers/pipeline.go`).
- `internal/customtracks/prompt.go` — prompt builders + parsers (ported from `internal/observers/prompt.go`).
- `internal/customtracks/pipeline_test.go` — engine tests.

**Go — modified:**
- `internal/db/schema.sql` — mirror the migration.
- `internal/db/tracks.go` + `internal/db/models.go` — `Track` gains 5 fields; new custom-track DB methods; fold method.
- `internal/tracks/pipeline.go` — dedup priority + fold in `storeTrackItems`.
- `internal/prompts/store.go` + `internal/prompts/defaults.go` — `track.compose`/`track.run`/`track.shortlist` prompts.
- `internal/daemon/daemon.go` — add custom-track scan phase before auto extraction; remove observer phase/field.
- `cmd/tracks.go` — new subcommands. `cmd/main.go`/wherever the pipeline is constructed — wire `customtracks`.
- `internal/db/schema_golden_test.go` (or wherever `TestAllTablesExist`/`TestSchemaGolden` live) — table list + snapshot.

**Go — deleted:**
- `internal/observers/` (whole package), `internal/db/observers.go`, `cmd/observers.go`, the `targets observe` command (`cmd/targets.go` def + `cmd/targets_ai.go` `runTargetsObserve`).

**Swift — created:**
- `WatchtowerDesktop/Sources/Models/TrackEvent.swift` (from `ObserverEvent.swift`).
- `WatchtowerDesktop/Sources/Database/Queries/TrackEventQueries.swift` (from `ObserverQueries.swift`).
- `WatchtowerDesktop/Sources/Services/TrackComposeService.swift`, `TrackScanService.swift` (from the two observer services).
- `WatchtowerDesktop/Sources/ViewModels/CustomTrackTimelineViewModel.swift` (from `ObserverTimelineViewModel.swift`).
- `WatchtowerDesktop/Sources/Views/Tracks/CustomTrackTimelineView.swift`, `CustomTrackManagementSheet.swift` (from the two Targets observer views).

**Swift — modified:**
- `Sources/Models/Track.swift` — 5 new fields + `isCustom`.
- `Sources/Views/Tracks/TracksListView.swift` — pinned "Custom" section.
- `Sources/Views/Tracks/TrackDetailView.swift` — Activity section for custom tracks.
- `Sources/ViewModels/TracksViewModel.swift` — custom-track partitioning.
- `Sources/Views/Targets/TargetDetailView.swift` — remove Activity tab; add "Watch" button.

**Swift — deleted:**
- `Sources/Models/Observer.swift`, `Sources/Models/ObserverEvent.swift`, `Sources/Database/Queries/ObserverQueries.swift`, `Sources/Services/ObserverComposeService.swift`, `Sources/Services/TargetObserveService.swift`, `Sources/ViewModels/ObserverTimelineViewModel.swift`, `Sources/Views/Targets/ObserverManagementSheet.swift`, `Sources/Views/Targets/ObserverTimelineView.swift`, and their test files.

---

## PHASE 1 — Schema & DB foundation

### Task 1: Migration 00008 + schema mirror

**Files:**
- Create: `internal/db/migrations/00008_custom_tracks.sql`
- Modify: `internal/db/schema.sql:281-319` (tracks), append a `track_events` block, delete the `observers`/`observer_events` blocks (`:417-453`)
- Modify: the test holding `TestAllTablesExist` (grep for it: `grep -rn "TestAllTablesExist" internal/db/`)
- Test: `internal/db/migrations_test.go` (or the existing migration test file)

**Interfaces:**
- Produces: `tracks.origin`, `tracks.instruction`, `tracks.enabled`, `tracks.last_run_at`, `tracks.linked_target_id`; table `track_events`. Removes tables `observers`, `observer_events`.

- [ ] **Step 1: Write the failing test**

Add to the migration test file (adjust package/helper to match the existing ones — find an existing `db.Open` test helper first with `grep -rn "func testDB\|Open(\":memory:\|t.TempDir" internal/db/*_test.go`):

```go
func TestMigration00008CustomTracks(t *testing.T) {
	database := openTestDB(t) // existing helper that runs migrations on a fresh DB
	defer database.Close()

	// New columns exist on tracks.
	for _, col := range []string{"origin", "instruction", "enabled", "last_run_at", "linked_target_id"} {
		var count int
		err := database.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('tracks') WHERE name = ?`, col).Scan(&count)
		if err != nil || count != 1 {
			t.Fatalf("tracks.%s missing (count=%d err=%v)", col, count, err)
		}
	}
	// origin defaults to 'auto' and rejects bad values.
	if _, err := database.Exec(`INSERT INTO tracks (text, origin) VALUES ('x', 'bogus')`); err == nil {
		t.Fatal("expected CHECK violation for origin='bogus'")
	}
	// track_events exists; observers/observer_events are gone.
	assertTableExists(t, database, "track_events")
	assertTableGone(t, database, "observers")
	assertTableGone(t, database, "observer_events")
}
```

Add small helpers if the file lacks them:

```go
func assertTableExists(t *testing.T, d *DB, name string) {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&n); err != nil || n != 1 {
		t.Fatalf("table %s expected to exist (n=%d err=%v)", name, n, err)
	}
}
func assertTableGone(t *testing.T, d *DB, name string) {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, name).Scan(&n); err != nil || n != 0 {
		t.Fatalf("table %s expected to be dropped (n=%d err=%v)", name, n, err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestMigration00008CustomTracks -v`
Expected: FAIL (columns/table missing, `observers` still present).

- [ ] **Step 3: Write the migration**

Create `internal/db/migrations/00008_custom_tracks.sql`:

```sql
-- +goose Up
-- Custom tracks: promote the observer engine into first-class tracks.
-- Adds custom-only columns to tracks, creates track_events (the ported
-- observer timeline), and drops the now-superseded observers tables.
PRAGMA defer_foreign_keys = ON;

-- New-column CHECK/FK are legal via ADD COLUMN because the default satisfies
-- the CHECK ('auto') and the FK column defaults to NULL.
ALTER TABLE tracks ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto'
    CHECK(origin IN ('auto','custom'));
ALTER TABLE tracks ADD COLUMN instruction TEXT NOT NULL DEFAULT '';
ALTER TABLE tracks ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
ALTER TABLE tracks ADD COLUMN last_run_at TEXT NOT NULL DEFAULT '';
ALTER TABLE tracks ADD COLUMN linked_target_id INTEGER
    REFERENCES targets(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tracks_origin ON tracks(origin);
CREATE INDEX IF NOT EXISTS idx_tracks_custom_enabled ON tracks(origin, enabled)
    WHERE origin = 'custom';

CREATE TABLE IF NOT EXISTS track_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id        INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS idx_track_events_track ON track_events(track_id, created_at DESC);

DROP TABLE IF EXISTS observer_events;
DROP TABLE IF EXISTS observers;

-- +goose Down
PRAGMA defer_foreign_keys = ON;

DROP INDEX IF EXISTS idx_track_events_track;
DROP TABLE IF EXISTS track_events;

DROP INDEX IF EXISTS idx_tracks_custom_enabled;
DROP INDEX IF EXISTS idx_tracks_origin;
ALTER TABLE tracks DROP COLUMN linked_target_id;
ALTER TABLE tracks DROP COLUMN last_run_at;
ALTER TABLE tracks DROP COLUMN enabled;
ALTER TABLE tracks DROP COLUMN instruction;
ALTER TABLE tracks DROP COLUMN origin;

CREATE TABLE IF NOT EXISTS observers (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type  TEXT NOT NULL DEFAULT 'target' CHECK(entity_type IN ('target')),
    entity_id    INTEGER NOT NULL,
    name         TEXT NOT NULL DEFAULT '',
    instruction  TEXT NOT NULL DEFAULT '',
    enabled      INTEGER NOT NULL DEFAULT 1,
    last_run_at  TEXT NOT NULL DEFAULT '',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_observers_entity  ON observers(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_observers_enabled ON observers(enabled);

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
```

- [ ] **Step 4: Mirror into `internal/db/schema.sql`**

In `schema.sql`, inside the `CREATE TABLE ... tracks (...)` (`:281-314`) append these column lines before the closing `)`, after `updated_at`:

```sql
    ,
    origin              TEXT NOT NULL DEFAULT 'auto' CHECK(origin IN ('auto','custom')),
    instruction         TEXT NOT NULL DEFAULT '',       -- custom tracks: watch instruction
    enabled             INTEGER NOT NULL DEFAULT 1,      -- custom tracks: scan on/off
    last_run_at         TEXT NOT NULL DEFAULT '',        -- custom tracks: scan watermark, ''=never
    linked_target_id    INTEGER REFERENCES targets(id) ON DELETE SET NULL
```

Add after the existing tracks indexes:

```sql
CREATE INDEX IF NOT EXISTS idx_tracks_origin ON tracks(origin);
CREATE INDEX IF NOT EXISTS idx_tracks_custom_enabled ON tracks(origin, enabled) WHERE origin = 'custom';
```

Replace the `observers` + `observer_events` blocks (`:417-453`) with the `track_events` block:

```sql
CREATE TABLE IF NOT EXISTS track_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id        INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS idx_track_events_track ON track_events(track_id, created_at DESC);
```

- [ ] **Step 5: Update `TestAllTablesExist`**

In the file found via grep, remove `"observers"` and `"observer_events"` from the expected-table list and add `"track_events"`.

- [ ] **Step 6: Run migration + table tests to verify they pass**

Run: `go test ./internal/db/ -run 'TestMigration00008CustomTracks|TestAllTablesExist' -v`
Expected: PASS.

- [ ] **Step 7: Regenerate the golden snapshot**

Run: `go test ./internal/db/ -run TestSchemaGolden -update`
Then: `go test ./internal/db/ -run TestSchemaGolden -v`
Expected: PASS (snapshot now includes the new columns + `track_events`, no `observers`).

- [ ] **Step 8: Commit**

```bash
git add internal/db/migrations/00008_custom_tracks.sql internal/db/schema.sql internal/db/*_test.go internal/db/testdata
git commit -m "feat(db): custom-tracks schema — tracks columns + track_events, drop observers"
```

---

### Task 2: `Track` model + custom-track DB methods

**Files:**
- Modify: `internal/db/models.go:167-200` (add fields to `Track`)
- Modify: `internal/db/tracks.go:9-35` (`trackSelectCols` + `scanTrack`), `:37-102` (`UpsertTrack`), `:108-157` (`UpdateTrackFromExtraction`)
- Create: `internal/db/custom_tracks.go` (new custom-track methods + fold)
- Test: `internal/db/custom_tracks_test.go`

**Interfaces:**
- Produces:
  - `Track` fields `Origin, Instruction string`, `Enabled bool`, `LastRunAt string`, `LinkedTargetID int` (0 = none).
  - `func (db *DB) CreateCustomTrack(t Track) (int64, error)`
  - `func (db *DB) GetEnabledCustomTracks() ([]Track, error)`
  - `func (db *DB) SetTrackLastRun(id int, at string) error`
  - `func (db *DB) SetTrackEnabled(id int, enabled bool) error`
  - `func (db *DB) UpdateCustomTrackInstruction(id int, text, instruction string) error`
  - `func (db *DB) FoldSourceRefsIntoTrack(id int, sourceRefs, channelIDs, relatedDigestIDs string) error`
- Consumes: `Track` struct, `trackSelectCols`, `scanTrack`, `mergeJSONArrays` (existing, `internal/db/tracks.go`).

- [ ] **Step 1: Add fields to `Track`** (`internal/db/models.go`, after `UpdatedAt` at `:199`):

```go
	Origin         string // "auto" (default) or "custom"
	Instruction    string // custom tracks: watch instruction
	Enabled        bool   // custom tracks: scan on/off
	LastRunAt      string // custom tracks: scan watermark, "" = never
	LinkedTargetID int    // custom tracks: linked target id, 0 = none
```

- [ ] **Step 2: Extend `trackSelectCols` + `scanTrack`** (`internal/db/tracks.go:9-35`).

Append to `trackSelectCols` (after `updated_at`):

```go
	created_at, updated_at,
	origin, instruction, enabled, last_run_at, COALESCE(linked_target_id, 0)`
```

Append to the `scanTrack` `row.Scan(...)` args (after `&t.UpdatedAt`):

```go
		&t.CreatedAt, &t.UpdatedAt,
		&t.Origin, &t.Instruction, &t.Enabled, &t.LastRunAt, &t.LinkedTargetID,
```

- [ ] **Step 3: Write the failing test** (`internal/db/custom_tracks_test.go`):

```go
func TestCreateCustomTrackAndFetch(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	id, err := d.CreateCustomTrack(Track{
		AssigneeUserID: "U1", Text: "Watch HashBank refund",
		Context: "the refund decision and who owns it",
		Instruction: "surface anything about the HashBank refund decision",
		Fingerprint: `["hashbank"]`,
	})
	if err != nil {
		t.Fatalf("CreateCustomTrack: %v", err)
	}
	got, err := d.GetTrackByID(int(id))
	if err != nil {
		t.Fatalf("GetTrackByID: %v", err)
	}
	if got.Origin != "custom" || !got.Enabled || got.Instruction == "" {
		t.Fatalf("unexpected custom track: origin=%q enabled=%v instr=%q", got.Origin, got.Enabled, got.Instruction)
	}

	enabled, err := d.GetEnabledCustomTracks()
	if err != nil || len(enabled) != 1 {
		t.Fatalf("GetEnabledCustomTracks: n=%d err=%v", len(enabled), err)
	}

	if err := d.SetTrackLastRun(int(id), "2026-07-04T00:00:00Z"); err != nil {
		t.Fatalf("SetTrackLastRun: %v", err)
	}
	if err := d.SetTrackEnabled(int(id), false); err != nil {
		t.Fatalf("SetTrackEnabled: %v", err)
	}
	enabled, _ = d.GetEnabledCustomTracks()
	if len(enabled) != 0 {
		t.Fatalf("disabled track still enabled: %d", len(enabled))
	}
}

func TestFoldSourceRefsPreservesNarrative(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	id, _ := d.CreateCustomTrack(Track{
		AssigneeUserID: "U1", Text: "Watch refund", Context: "orig narrative",
		Instruction: "watch", SourceRefs: `[{"ts":"1","author":"a","text":"x"}]`,
		ChannelIDs: `["C1"]`, RelatedDigestIDs: `[1]`,
	})
	if err := d.FoldSourceRefsIntoTrack(int(id),
		`[{"ts":"2","author":"b","text":"y"}]`, `["C2"]`, `[2]`); err != nil {
		t.Fatalf("Fold: %v", err)
	}
	got, _ := d.GetTrackByID(int(id))
	if got.Text != "Watch refund" || got.Context != "orig narrative" || got.Instruction != "watch" {
		t.Fatalf("fold overwrote narrative: %+v", got)
	}
	if !got.HasUpdates {
		t.Fatal("fold should set has_updates")
	}
	// channel/digest ids merged.
	if !strings.Contains(got.ChannelIDs, "C1") || !strings.Contains(got.ChannelIDs, "C2") {
		t.Fatalf("channel ids not merged: %s", got.ChannelIDs)
	}
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `go test ./internal/db/ -run 'TestCreateCustomTrack|TestFoldSourceRefs' -v`
Expected: FAIL (`CreateCustomTrack` undefined).

- [ ] **Step 5: Implement** (`internal/db/custom_tracks.go`):

```go
package db

import "fmt"

// CreateCustomTrack inserts a user-authored (origin='custom') track. The
// narrative (text/context) and instruction are set at creation; the scan
// pipeline appends track_events over time.
func (db *DB) CreateCustomTrack(t Track) (int64, error) {
	if t.Priority == "" {
		t.Priority = "medium"
	}
	if t.Category == "" {
		t.Category = "task"
	}
	if t.Ownership == "" {
		t.Ownership = "watching"
	}
	if t.Fingerprint == "" {
		t.Fingerprint = "[]"
	}
	var linked any
	if t.LinkedTargetID > 0 {
		linked = t.LinkedTargetID
	}
	res, err := db.Exec(`INSERT INTO tracks
		(assignee_user_id, text, context, category, ownership, priority,
		 fingerprint, source_refs, channel_ids, related_digest_ids,
		 origin, instruction, enabled, linked_target_id)
		VALUES (?, ?, ?, ?, ?, ?, ?,
		        COALESCE(NULLIF(?, ''), '[]'), COALESCE(NULLIF(?, ''), '[]'), COALESCE(NULLIF(?, ''), '[]'),
		        'custom', ?, 1, ?)`,
		t.AssigneeUserID, t.Text, t.Context, t.Category, t.Ownership, t.Priority,
		t.Fingerprint, t.SourceRefs, t.ChannelIDs, t.RelatedDigestIDs,
		t.Instruction, linked)
	if err != nil {
		return 0, fmt.Errorf("inserting custom track: %w", err)
	}
	return res.LastInsertId()
}

// GetEnabledCustomTracks returns active, enabled custom tracks for scanning.
func (db *DB) GetEnabledCustomTracks() ([]Track, error) {
	rows, err := db.Query(`SELECT ` + trackSelectCols + `
		FROM tracks WHERE origin = 'custom' AND enabled = 1 AND dismissed_at = ''
		ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Track
	for rows.Next() {
		t, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// SetTrackLastRun advances a custom track's scan watermark.
func (db *DB) SetTrackLastRun(id int, at string) error {
	_, err := db.Exec(`UPDATE tracks SET last_run_at = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, at, id)
	return err
}

// SetTrackEnabled toggles a custom track's scanning.
func (db *DB) SetTrackEnabled(id int, enabled bool) error {
	_, err := db.Exec(`UPDATE tracks SET enabled = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?`, enabled, id)
	return err
}

// UpdateCustomTrackInstruction edits a custom track's narrative + instruction.
func (db *DB) UpdateCustomTrackInstruction(id int, text, instruction string) error {
	_, err := db.Exec(`UPDATE tracks SET text = ?, instruction = ?,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ? AND origin = 'custom'`, text, instruction, id)
	return err
}

// FoldSourceRefsIntoTrack folds matching auto-extracted content into a custom
// track: it merges channel_ids/related_digest_ids and flags an update, WITHOUT
// touching the custom track's text/context/instruction/priority (custom is
// authoritative — see the design's fold rule).
func (db *DB) FoldSourceRefsIntoTrack(id int, sourceRefs, channelIDs, relatedDigestIDs string) error {
	existing, err := db.GetTrackByID(id)
	if err != nil {
		return fmt.Errorf("loading track %d for fold: %w", id, err)
	}
	mergedChannels := mergeJSONArrays(existing.ChannelIDs, channelIDs)
	mergedDigests := mergeJSONArrays(existing.RelatedDigestIDs, relatedDigestIDs)
	// A fold is always news → flag has_updates unconditionally (unlike
	// UpdateTrackFromExtraction, which guards on read_at; here the custom
	// track's narrative is untouched, so the flag is the only signal).
	_, err = db.Exec(`UPDATE tracks SET
		channel_ids = ?, related_digest_ids = ?,
		has_updates = 1,
		updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = ?`, mergedChannels, mergedDigests, id)
	_ = sourceRefs // reserved: appending quote-level refs is out of scope for v1
	return err
}
```

> The `database/sql` import in this file is only needed if other methods use it; if `go build` reports `sql` imported and not used, drop it — `FoldSourceRefsIntoTrack` no longer references `sql`.

- [ ] **Step 6: Run to verify it passes**

Run: `go test ./internal/db/ -run 'TestCreateCustomTrack|TestFoldSourceRefs' -v`
Expected: PASS. If `TestFoldSourceRefsPreservesNarrative` fails on `HasUpdates`, apply the note (set `has_updates = 1` in fold).

- [ ] **Step 7: Verify existing track tests still pass** (scan-column change is load-bearing)

Run: `go test ./internal/db/ ./internal/tracks/ -v`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add internal/db/models.go internal/db/tracks.go internal/db/custom_tracks.go internal/db/custom_tracks_test.go
git commit -m "feat(db): Track custom fields + CreateCustomTrack/fold methods"
```

---

### Task 3: `track_events` DB layer + scan-activity gather

**Files:**
- Create: `internal/db/track_events.go`
- Test: `internal/db/track_events_test.go`
- Reference (port from): `internal/db/observers.go` (`InsertObserverEvent:129`, `GetObserverEventSummaries:185`, `GetObserverActivity:287`, `GetObserverActivityTitles:363`, `GetObserverActivityByIDs:412`) + `models.go:869-884` (`ObserverEvent`) + `observers.go:225-260,353-358` (activity structs)

**Interfaces:**
- Produces:
  - `type TrackEvent struct { ID, TrackID int; Summary, Detail, SourceType, SourceID, SourceRefs, Decision, ProposedAction, ActionStatus, ReadAt, CreatedAt string }`
  - `type ScanActivity struct { Digests []ActivityDigest; Tracks []ActivityTrack; Inbox []ActivityInbox; CappedAt string }` and `ActivityDigest/ActivityTrack/ActivityInbox/ActivityTitle` (move from observers.go verbatim).
  - `func (db *DB) InsertTrackEvent(e TrackEvent) (int, error)`
  - `func (db *DB) GetTrackEvents(trackID, limit int) ([]TrackEvent, error)`
  - `func (db *DB) GetTrackEventSummaries(trackID, limit int) ([]string, error)`
  - `func (db *DB) MarkTrackEventRead(id int, at string) error`
  - `func (db *DB) SetTrackEventActionStatus(id int, status string) error`
  - `func (db *DB) GetScanActivity(since string, limit int) (ScanActivity, error)`
  - `func (db *DB) GetScanActivityTitles(since string, limit int) ([]ActivityTitle, error)`
  - `func (db *DB) GetScanActivityByIDs(digestIDs, trackIDs, inboxIDs []int) (ScanActivity, error)`

- [ ] **Step 1: Write the failing test** (`internal/db/track_events_test.go`):

```go
func TestTrackEventsCRUD(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	tid, _ := d.CreateCustomTrack(Track{AssigneeUserID: "U1", Text: "watch", Instruction: "i"})

	id, err := d.InsertTrackEvent(TrackEvent{
		TrackID: int(tid), Summary: "refund approved",
		SourceType: "digest", SourceRefs: `["http://x"]`, ActionStatus: "none",
	})
	if err != nil || id == 0 {
		t.Fatalf("InsertTrackEvent: id=%d err=%v", id, err)
	}
	evs, err := d.GetTrackEvents(int(tid), 10)
	if err != nil || len(evs) != 1 || evs[0].Summary != "refund approved" {
		t.Fatalf("GetTrackEvents: %+v err=%v", evs, err)
	}
	sums, _ := d.GetTrackEventSummaries(int(tid), 10)
	if len(sums) != 1 {
		t.Fatalf("summaries: %v", sums)
	}
	// Deleting the track cascades events.
	if _, err := d.Exec(`DELETE FROM tracks WHERE id = ?`, tid); err != nil {
		t.Fatal(err)
	}
	evs, _ = d.GetTrackEvents(int(tid), 10)
	if len(evs) != 0 {
		t.Fatalf("events not cascaded: %d", len(evs))
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/db/ -run TestTrackEventsCRUD -v`
Expected: FAIL (`TrackEvent` undefined).

- [ ] **Step 3: Implement `internal/db/track_events.go`**

Port from `internal/db/observers.go`, dropping `observer_id/entity_type/entity_id` in favor of `track_id`. The activity structs (`ActivityDigest`, `ActivityTrack`, `ActivityInbox`, `ActivityTitle`, and the container renamed `ScanActivity`) move here verbatim from `observers.go:225-260,353-358`. For `GetScanActivity` copy the body of `GetObserverActivity` verbatim but add `AND origin = 'auto'` to the `tracks` sub-query so a custom track's feed excludes other custom tracks. Core CRUD:

```go
package db

import "fmt"

type TrackEvent struct {
	ID             int    `json:"id"`
	TrackID        int    `json:"track_id"`
	Summary        string `json:"summary"`
	Detail         string `json:"detail"`
	SourceType     string `json:"source_type"`
	SourceID       string `json:"source_id"`
	SourceRefs     string `json:"source_refs"`     // JSON array
	Decision       string `json:"decision"`        // JSON object or ""
	ProposedAction string `json:"proposed_action"` // JSON object or ""
	ActionStatus   string `json:"action_status"`
	ReadAt         string `json:"read_at"`
	CreatedAt      string `json:"created_at"`
}

const trackEventCols = `id, track_id, summary, detail, source_type, source_id,
	source_refs, decision, proposed_action, action_status, COALESCE(read_at,''), created_at`

func scanTrackEvent(row interface{ Scan(...any) error }) (*TrackEvent, error) {
	var e TrackEvent
	if err := row.Scan(&e.ID, &e.TrackID, &e.Summary, &e.Detail, &e.SourceType, &e.SourceID,
		&e.SourceRefs, &e.Decision, &e.ProposedAction, &e.ActionStatus, &e.ReadAt, &e.CreatedAt); err != nil {
		return nil, err
	}
	return &e, nil
}

func (db *DB) InsertTrackEvent(e TrackEvent) (int, error) {
	if e.SourceRefs == "" {
		e.SourceRefs = "[]"
	}
	if e.ActionStatus == "" {
		e.ActionStatus = "none"
	}
	res, err := db.Exec(`INSERT INTO track_events
		(track_id, summary, detail, source_type, source_id, source_refs, decision, proposed_action, action_status)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.TrackID, e.Summary, e.Detail, e.SourceType, e.SourceID, e.SourceRefs, e.Decision, e.ProposedAction, e.ActionStatus)
	if err != nil {
		return 0, fmt.Errorf("inserting track event: %w", err)
	}
	id, err := res.LastInsertId()
	return int(id), err
}

func (db *DB) GetTrackEvents(trackID, limit int) ([]TrackEvent, error) {
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.Query(`SELECT `+trackEventCols+`
		FROM track_events WHERE track_id = ? ORDER BY created_at DESC, id DESC LIMIT ?`, trackID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrackEvent
	for rows.Next() {
		e, err := scanTrackEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

func (db *DB) GetTrackEventSummaries(trackID, limit int) ([]string, error) {
	if limit <= 0 {
		limit = 400
	}
	rows, err := db.Query(`SELECT summary FROM track_events
		WHERE track_id = ? ORDER BY created_at DESC LIMIT ?`, trackID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (db *DB) MarkTrackEventRead(id int, at string) error {
	_, err := db.Exec(`UPDATE track_events SET read_at = ? WHERE id = ?`, at, id)
	return err
}

func (db *DB) SetTrackEventActionStatus(id int, status string) error {
	_, err := db.Exec(`UPDATE track_events SET action_status = ? WHERE id = ?`, status, id)
	return err
}
```

Then port `GetScanActivity`, `GetScanActivityTitles`, `GetScanActivityByIDs` and the activity structs from `observers.go` (verbatim bodies; rename `ObserverActivity`→`ScanActivity`, add `AND origin='auto'` to the tracks sub-select). Delete those structs/methods from `observers.go` in Task 8.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/db/ -run TestTrackEventsCRUD -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/track_events.go internal/db/track_events_test.go
git commit -m "feat(db): track_events CRUD + scan-activity gather"
```

---

## PHASE 2 — Custom-track scan engine (Go)

### Task 4: Register `track.*` prompts

**Files:**
- Modify: `internal/prompts/store.go:38-42` (add consts)
- Modify: `internal/prompts/defaults.go` — 4 maps (`:8-35`, `:38-65`, `:76-96`, `:109-130`) + 3 template consts
- Test: `internal/prompts/defaults_test.go` (or wherever prompt-registration tests live; grep `TestDefaults\|TestAllIDs`)

**Interfaces:**
- Produces consts `TrackCompose = "track.compose"`, `TrackRun = "track.run"`, `TrackShortlist = "track.shortlist"`.

- [ ] **Step 1: Add consts** (`internal/prompts/store.go`, after `ObserverShortlist` at `:42`):

```go
	TrackCompose   = "track.compose"
	TrackRun       = "track.run"
	TrackShortlist = "track.shortlist"
```

(Leave the `Observer*` consts for now; Task 8 deletes them.)

- [ ] **Step 2: Add template consts** (`internal/prompts/defaults.go`, near the observer templates `:1178-1225`). Reuse the observer wording but drop the "target" framing where a standalone track has none:

```go
const defaultTrackRun = `You are a CUSTOM TRACK watcher. Your job: read the track's WATCH INSTRUCTION, scan the RECENT ACTIVITY from all sources, and emit only the events genuinely relevant to THIS track per the instruction. Ignore everything unrelated.

Return ONLY a JSON object (no markdown, no prose):
{
  "events": [
    {
      "summary": "one-line, past-tense, what happened and why it matters to this track",
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
- Emit an event ONLY when the activity is relevant to this specific track per the watch instruction. When unsure, leave it out. An empty {"events": []} is a correct and common answer.
- "summary" is mandatory and specific — name the change, not "there was activity".
- Omit "decision" unless a real decision was made.
- Include "proposed_action" ONLY when this track is linked to a goal/task the operator owns AND the activity clearly justifies a mutation to it. Standalone tracks (no linked target) MUST omit "proposed_action". When present it MUST be one of:
  {"type":"update_status","reason":"...","status":"todo|in_progress|blocked|done|dismissed|snoozed"}
  {"type":"update_progress","reason":"...","progress":0-100}
  {"type":"update_notes","reason":"...","note":"text to append"}
  {"type":"add_sub_item","reason":"...","text":"checklist item"}
- Do not invent activity. Every event must trace to an item in RECENT ACTIVITY.
- Keep "summary"/"detail" in the operator's language.`

const defaultTrackCompose = `You design a WATCH INSTRUCTION for a CUSTOM TRACK the operator wants to follow. A custom track scans recent cross-source activity (Slack digests, action-item tracks, inbox/Jira/calendar items) and surfaces ONLY updates relevant to its instruction.

You are given the operator's free-text USER REQUEST describing what they want watched (and, when present, a linked TARGET for context). Produce:
- "title": a short label (at most 6 words) naming what this track follows.
- "instruction": a precise watch instruction. Name the concrete topics, people, decisions, or blockers to watch for, and explicitly exclude unrelated chatter. Another AI reads this as its relevance filter, so be specific and unambiguous. Write it in the operator's language.

Return ONLY a JSON object (no markdown fences, no prose) with exactly this shape:
{"title": "...", "instruction": "..."}`

const defaultTrackShortlist = `You are the RELEVANCE FILTER (stage 1 of 2) for a CUSTOM TRACK. You are shown the WATCH INSTRUCTION and a numbered list of activity TITLES (one short headline per item, across Slack digests, action-item tracks, and inbox items). A second AI will read the FULL content of whatever you select, so your only job is to cast a sensible net: pick every item whose title could plausibly relate to this track per the instruction.

Return ONLY a JSON object (no markdown, no prose):
{"refs": [{"kind": "digest|track|inbox", "id": 123}, ...]}

Rules:
- Judge from the title alone. When ambiguous but possibly related, INCLUDE it — stage 2 discards false positives. Only drop titles clearly unrelated.
- Use the exact kind and id printed in brackets. Do not invent ids.
- Respect the selection cap stated in the request. An empty {"refs": []} is valid when nothing fits.`
```

- [ ] **Step 3: Register in the 4 maps** (`defaults.go`):
  - `Defaults` (`:8-35`): `TrackCompose: defaultTrackCompose,` `TrackRun: defaultTrackRun,` `TrackShortlist: defaultTrackShortlist,`
  - `AllIDs` (`:38-65`): add `TrackCompose, TrackRun, TrackShortlist,` (near the tracks entries).
  - `DefaultVersions` (`:76-96`): `TrackCompose: 1,` `TrackRun: 1,` `TrackShortlist: 1,`
  - Descriptions (`:109-130`): one line each, e.g. `TrackRun: "Custom track run — timeline events from recent cross-source activity",` etc.

- [ ] **Step 4: Run the prompt-registration test**

Run: `go test ./internal/prompts/ -v`
Expected: PASS (if a test enforces every `AllIDs` entry has a default + version + description, these three must be present in all maps).

- [ ] **Step 5: Commit**

```bash
git add internal/prompts/store.go internal/prompts/defaults.go
git commit -m "feat(prompts): register track.compose/track.run/track.shortlist"
```

---

### Task 5: `internal/customtracks` scan engine

**Files:**
- Create: `internal/customtracks/pipeline.go`, `internal/customtracks/prompt.go`
- Test: `internal/customtracks/pipeline_test.go`
- Reference (port from): `internal/observers/pipeline.go` + `prompt.go` (verbatim structure)

**Interfaces:**
- Produces:
  - `type Pipeline struct { db *db.DB; gen digest.Generator; lang string; logger *log.Logger }`
  - `func New(database *db.DB, gen digest.Generator, lang string, logger *log.Logger) *Pipeline`
  - `func (p *Pipeline) Run(ctx context.Context) (int, error)` — scans all enabled custom tracks, returns #events created.
  - `func (p *Pipeline) RunForTrack(ctx context.Context, trackID int) ([]db.TrackEvent, error)`
  - `func (p *Pipeline) RunForTrackSince(ctx context.Context, trackID int, since string) ([]db.TrackEvent, error)`
  - `func (p *Pipeline) Compose(ctx context.Context, linkedTargetID int, input string) (ComposeResult, error)` (linkedTargetID 0 = standalone)
  - `type ComposeResult struct { Title string \`json:"title"\`; Instruction string \`json:"instruction"\` }`
- Consumes: `db.GetEnabledCustomTracks`, `db.GetScanActivity`, `db.GetTrackEventSummaries`, `db.InsertTrackEvent`, `db.SetTrackLastRun`, `db.GetTrackByID`, `digest.Generator`, `prompts.TrackRun/TrackCompose/TrackShortlist`.

- [ ] **Step 1: Write the failing test** (`internal/customtracks/pipeline_test.go`). Model the mock on `internal/observers/pipeline_test.go` (find its `mockGenerator`):

```go
func TestScanEmptyActivityAdvancesWatermarkNoAICall(t *testing.T) {
	d := dbtest.Open(t) // use the same helper observers_test uses
	tid, _ := d.CreateCustomTrack(db.Track{AssigneeUserID: "U1", Text: "watch", Instruction: "i"})
	mock := &mockGenerator{} // fails the test if Generate is called
	p := New(d, mock, "", nil)

	events, err := p.RunForTrack(context.Background(), int(tid))
	if err != nil {
		t.Fatalf("RunForTrack: %v", err)
	}
	if len(events) != 0 {
		t.Fatalf("expected no events on empty activity, got %d", len(events))
	}
	if mock.calls != 0 {
		t.Fatalf("AI called %d times on empty activity; want 0", mock.calls)
	}
	got, _ := d.GetTrackByID(int(tid))
	if got.LastRunAt == "" {
		t.Fatal("watermark not advanced on empty activity")
	}
}

func TestComposeParsesTitleAndInstruction(t *testing.T) {
	d := dbtest.Open(t)
	mock := &mockGenerator{out: `{"title":"HashBank refund","instruction":"watch the refund decision"}`}
	p := New(d, mock, "", nil)
	res, err := p.Compose(context.Background(), 0, "watch the hashbank refund")
	if err != nil {
		t.Fatalf("Compose: %v", err)
	}
	if res.Title != "HashBank refund" || res.Instruction == "" {
		t.Fatalf("bad compose result: %+v", res)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/customtracks/ -v`
Expected: FAIL (package/methods undefined).

- [ ] **Step 3: Implement `pipeline.go` + `prompt.go`**

Port `internal/observers/pipeline.go` verbatim with these substitutions:
- `db.Observer` → `db.Track` (loaded via `GetEnabledCustomTracks`); the watch instruction is `t.Instruction`, watermark `t.LastRunAt`.
- `db.ObserverActivity` → `db.ScanActivity`; `GetObserverActivity` → `GetScanActivity`, `GetObserverActivityTitles` → `GetScanActivityTitles`, `GetObserverActivityByIDs` → `GetScanActivityByIDs`.
- `db.ObserverEvent`/`InsertObserverEvent` → `db.TrackEvent`/`InsertTrackEvent` (set `TrackID`); dedup via `GetTrackEventSummaries(trackID, 400)`.
- `SetObserverLastRun` → `SetTrackLastRun`.
- prompt ids `prompts.ObserverRun/Shortlist/Compose` → `prompts.TrackRun/TrackShortlist/TrackCompose`; source tags `"observer.run"` → `"customtrack.run"` etc.
- Drop the `o.EntityType != "target"` guard entirely (custom tracks have no entity guard). `runOne` iterates a `db.Track`.
- `Compose` takes `linkedTargetID int`; when >0, load the target for context via `db.GetTargetByID` and include it in `buildComposePrompt`; when 0, omit the TARGET block.

Port `prompt.go` verbatim, renaming `buildObserverPrompt`→`buildScanPrompt`, `ComposeResult.Name`→`Title` (json tag `"title"`), and the compose parser to read `title`. Keep `aiEvent`, `parseScanOutput`, shortlist helpers identical.

The watermark-safety (`CappedAt`) and empty-activity short-circuit (`observers/pipeline.go` around the `if activity is empty → advance watermark, return`) must be preserved verbatim — this is what `TestScanEmptyActivityAdvancesWatermarkNoAICall` checks.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/customtracks/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/customtracks/
git commit -m "feat(customtracks): scan+compose engine ported from observers"
```

---

### Task 6: Dedup priority + fold in `storeTrackItems`

**Files:**
- Modify: `internal/tracks/pipeline.go:597-760` (`storeTrackItems`), `:1537-1569` (`findSimilarTrack`)
- Test: `internal/tracks/pipeline_test.go` (custom-fold cases)

**Interfaces:**
- Consumes: `db.FindTracksByFingerprint`, `db.FoldSourceRefsIntoTrack`, `Track.Origin`, `p.allActiveTracksRef`.

- [ ] **Step 1: Write the failing test** (`internal/tracks/pipeline_test.go`). Follow the file's existing pipeline-test setup (seed a custom track, run an extraction that would match it):

```go
func TestAutoExtractionFoldsIntoCustomTrack(t *testing.T) {
	p, d := newTestPipeline(t) // existing helper; if none, mirror an existing pipeline test
	// Seed a custom track whose fingerprint/text match the auto item below.
	custID, _ := d.CreateCustomTrack(db.Track{
		AssigneeUserID: testUserID, Text: "Watch the HashBank refund decision",
		Context: "refund ownership", Instruction: "watch refund", Fingerprint: `["hashbank"]`,
	})
	p.refreshActiveTracksCache() // ensure allActiveTracksRef includes the custom track

	stored := p.storeTrackItems([]aiItem{{
		Text: "Decide HashBank refund owner", Context: "who owns the hashbank refund",
		Priority: "high", Ownership: "mine", SourceRefs: `[{"ts":"1","author":"a","text":"x"}]`,
	}}, testUserID, "C1", "general", nil, 1, 0, 0)

	// The auto item folded into the custom track → no new auto track created.
	if stored != 1 {
		t.Fatalf("stored=%d", stored)
	}
	autos, _ := d.GetTracks(db.TrackFilter{})
	customCount, autoCount := 0, 0
	for _, tr := range autos {
		if tr.Origin == "custom" {
			customCount++
		} else {
			autoCount++
		}
	}
	if autoCount != 0 || customCount != 1 {
		t.Fatalf("expected fold into the 1 custom track, got auto=%d custom=%d", autoCount, customCount)
	}
	// Narrative preserved.
	got, _ := d.GetTrackByID(int(custID))
	if got.Text != "Watch the HashBank refund decision" {
		t.Fatalf("custom narrative overwritten: %q", got.Text)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/tracks/ -run TestAutoExtractionFoldsIntoCustomTrack -v`
Expected: FAIL (auto track created alongside the custom one; or narrative overwritten).

- [ ] **Step 3: Add a custom-preferring matcher + fold branch to `storeTrackItems`**

In `storeTrackItems`, BEFORE the existing fingerprint-match block (`internal/tracks/pipeline.go:712`), insert a custom-track fold check:

```go
		// Custom tracks take priority: fold matching auto content into them
		// without overwriting their user-authored narrative/instruction.
		if custID := p.matchCustomTrack(userID, fp, item.Text, item.Context); custID > 0 {
			if err := p.db.FoldSourceRefsIntoTrack(custID, sourceRefs, channelIDsJSON, itemDigestIDs); err != nil {
				p.logger.Printf("tracks: warning: fold into custom track #%d failed: %v", custID, err)
			} else {
				p.logger.Printf("tracks: folded auto content into custom track #%d: %.80s", custID, item.Text)
				stored++
			}
			continue
		}
```

Add the matcher method (near `findSimilarTrack`, `:1537`). It searches custom tracks first, with a softer Jaccard threshold (`customSimilarityThreshold = 0.22`, below the `0.30` used for auto). Fingerprint match reuses `FindTracksByFingerprint` but keeps only `origin=='custom'` rows:

```go
// customSimilarityThreshold is intentionally below textSimilarityThreshold so
// custom tracks (which the operator explicitly created) claim borderline
// matches before the auto splitter can spawn a near-duplicate.
const customSimilarityThreshold = 0.22

// matchCustomTrack returns the id of a custom track this item should fold into,
// or 0. Fingerprint match wins; else best Jaccard over custom tracks >= 0.22.
func (p *Pipeline) matchCustomTrack(userID string, fp []string, text, context string) int {
	if len(fp) > 0 {
		if matches, err := p.db.FindTracksByFingerprint(userID, fp); err == nil {
			for _, m := range matches {
				if m.Origin == "custom" {
					return m.ID
				}
			}
		}
	}
	p.cacheMu.RLock()
	all := p.allActiveTracksRef
	p.cacheMu.RUnlock()
	newTokens := tokenizeText(text, context)
	if len(newTokens) == 0 {
		return 0
	}
	bestID, bestScore := 0, 0.0
	for _, t := range all {
		if t.Origin != "custom" || t.AssigneeUserID != userID {
			continue
		}
		score := jaccardSimilarity(newTokens, tokenizeText(t.Text, t.Context))
		if score > bestScore {
			bestScore, bestID = score, t.ID
		}
	}
	if bestScore >= customSimilarityThreshold {
		return bestID
	}
	return 0
}
```

> `p.allActiveTracksRef` already includes custom tracks (it comes from `GetAllActiveTracks`, no origin filter). If the test helper doesn't populate the cache, expose a small `refreshActiveTracksCache()` that calls the existing cache-populate path (find it near `pipeline.go:101`).

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/tracks/ -run TestAutoExtractionFoldsIntoCustomTrack -v`
Expected: PASS.

- [ ] **Step 5: Run the full tracks suite** (dedup change is load-bearing; ensure no auto→auto regression)

Run: `go test ./internal/tracks/ -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/tracks/pipeline.go internal/tracks/pipeline_test.go
git commit -m "feat(tracks): fold matching auto content into priority custom tracks"
```

---

### Task 7: Daemon wiring — scan phase before auto extraction

**Files:**
- Modify: `internal/daemon/daemon.go:47-68` (struct field), `:94-140` (setter), `:204-252` (`runSync` order), `:419-458` (`phaseTracksAndRollups`), `:532-549` (remove `phaseObservers`)
- Modify: the daemon construction site (grep `SetObserverPipeline\|observers.New` outside cmd/) to wire `customtracks`
- Test: none new (covered by pipeline tests); build must pass.

**Interfaces:**
- Consumes: `customtracks.Pipeline`, `customtracks.New`.
- Produces: `func (d *Daemon) SetCustomTracksPipeline(p *customtracks.Pipeline)`; new `phaseCustomTrackScan`.

- [ ] **Step 1: Replace the struct field** — in `daemon.go:47-68` change `observerPipe *observers.Pipeline` to:

```go
	customTracksPipe *customtracks.Pipeline
```

- [ ] **Step 2: Replace the setter** (`:112-119`):

```go
// SetCustomTracksPipeline sets the pipeline that scans user-authored custom
// tracks over recent cross-source activity, producing their event timelines.
// It runs BEFORE auto-track extraction so custom narratives/fingerprints are
// current when the auto splitter dedups against them.
func (d *Daemon) SetCustomTracksPipeline(p *customtracks.Pipeline) {
	d.customTracksPipe = p
}
```

- [ ] **Step 3: Add `phaseCustomTrackScan`** (replace `phaseObservers` at `:532-549`):

```go
// phaseCustomTrackScan runs enabled custom tracks over recent activity,
// appending timeline events. Runs before auto-track extraction so folds land.
func (d *Daemon) phaseCustomTrackScan(ctx context.Context) {
	if d.customTracksPipe == nil {
		return
	}
	d.trackedPipelineRun("custom_tracks", func() pipelineRunStats {
		n, err := d.customTracksPipe.Run(ctx)
		if err != nil {
			d.logger.Printf("custom tracks error: %v", err)
		} else if n > 0 {
			d.logger.Printf("custom tracks: created %d event(s)", n)
		}
		return pipelineRunStats{items: n, err: err}
	})
}
```

- [ ] **Step 4: Reorder the cycle** — in `runSync` (`:204-252`): insert `d.phaseCustomTrackScan(ctx)` immediately before the `phasesWg` block that launches `phaseTracksAndRollups` (i.e. before `:227`), and DELETE the `d.phaseObservers(ctx)` call at `:234`.

```go
	d.phaseUnsnooze()

	d.phaseCustomTrackScan(ctx) // before auto extraction so folds land

	// Phases 2-4 run in parallel where possible ...
```

- [ ] **Step 5: Wire construction** — at the daemon build site, replace `observers.New(...)` + `d.SetObserverPipeline(...)` with:

```go
	customTracksPipe := customtracks.New(database, gen, cfg.Digest.Language, logger)
	d.SetCustomTracksPipeline(customTracksPipe)
```

Update imports: drop `.../internal/observers`, add `.../internal/customtracks`.

- [ ] **Step 6: Build**

Run: `go build ./... && go vet ./internal/daemon/`
Expected: builds clean (residual `observers` references surface here and in Task 8).

- [ ] **Step 7: Commit**

```bash
git add internal/daemon/daemon.go cmd/
git commit -m "feat(daemon): custom-track scan phase before auto extraction; drop observer phase"
```

---

### Task 8: Delete the observers subsystem

**Files:**
- Delete: `internal/observers/` (whole dir), `internal/db/observers.go`, `cmd/observers.go`
- Modify: `cmd/targets.go:202-207,239,250` (remove `targetsObserveCmd` + registration + flag), `cmd/targets_ai.go:665-708` (`runTargetsObserve` + `targetsFlagObserveSince`)
- Modify: `internal/prompts/store.go` (remove `ObserverRun/ObserverCompose/ObserverShortlist` consts) + `defaults.go` (remove their 4-map entries + template consts)
- Modify: any remaining referencer surfaced by build.

**Interfaces:** none produced; this is removal.

- [ ] **Step 1: Delete files**

```bash
git rm -r internal/observers internal/db/observers.go cmd/observers.go
```

- [ ] **Step 2: Remove `targets observe`** — delete `targetsObserveCmd` (`cmd/targets.go:202-207`), its `AddCommand` (`:239`), its `--since` flag (`:250`), `runTargetsObserve` (`cmd/targets_ai.go:665-708`), and the `targetsFlagObserveSince` var.

- [ ] **Step 3: Remove observer prompts** — in `store.go` delete the three `Observer*` consts; in `defaults.go` remove their entries from all four maps and delete `defaultObserverRun/Compose/Shortlist` consts.

- [ ] **Step 4: Move the activity structs** — if Task 3 left `ActivityDigest/ActivityTrack/ActivityInbox/ActivityTitle` in the deleted `observers.go`, they now live in `track_events.go` (Task 3 moved them). Confirm no dangling refs.

- [ ] **Step 5: Build + vet + full Go test**

Run: `go build ./... && go vet ./... && go test ./...`
Expected: PASS. Fix any stray reference (e.g. `mcp` or `repl` packages that imported `observers` — grep `grep -rn "internal/observers\|Observer" --include=*.go`).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove observers subsystem (superseded by custom tracks)"
```

---

## PHASE 3 — CLI

### Task 9: `tracks create/watch/scan/events/enable/disable`

**Files:**
- Modify: `cmd/tracks.go:33-89` (command defs + `init` registration)
- Test: `cmd/tracks_test.go` (if the package has command tests; else a smoke test invoking `RunE` with a temp DB — mirror an existing `cmd/*_test.go`)

**Interfaces:**
- Consumes: `customtracks.New`, `db.CreateCustomTrack`, `db.GetEnabledCustomTracks`, `db.SetTrackEnabled`, `db.GetTrackEvents`, `cliGenerator`, `openObserverDB`-equivalent (use the tracks command's existing DB-open helper — grep `func openTracksDB\|db.Open` in `cmd/tracks.go`).

- [ ] **Step 1: Add command defs** (`cmd/tracks.go`, near `:33-72`). Model `runTracksCreate` on `cmd/observers.go:runObserversCompose` (compose → JSON draft) and `runTracksScan` on `runTracksGenerate` (pipeline run). Full new subcommands:

```go
var (
	tracksCreateFlagText   string
	tracksCreateFlagTarget int
	tracksScanFlagSince    string
)

var tracksCreateCmd = &cobra.Command{
	Use:   "create",
	Short: "Create a custom track from a description (AI drafts the watch instruction)",
	RunE:  runTracksCreate,
}

var tracksWatchCmd = &cobra.Command{
	Use:   "watch <target-id>",
	Short: "Create a custom track linked to a target",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksWatch,
}

var tracksScanCmd = &cobra.Command{
	Use:   "scan [<id>]",
	Short: "Run the custom-track scan (all enabled, or one id)",
	Args:  cobra.MaximumNArgs(1),
	RunE:  runTracksScan,
}

var tracksEventsCmd = &cobra.Command{
	Use:   "events <id>",
	Short: "Show a custom track's event timeline",
	Args:  cobra.ExactArgs(1),
	RunE:  runTracksEvents,
}

var tracksEnableCmd = &cobra.Command{
	Use:   "enable <id>",
	Short: "Enable scanning for a custom track",
	Args:  cobra.ExactArgs(1),
	RunE:  func(c *cobra.Command, a []string) error { return setTrackEnabled(c, a, true) },
}

var tracksDisableCmd = &cobra.Command{
	Use:   "disable <id>",
	Short: "Disable scanning for a custom track",
	Args:  cobra.ExactArgs(1),
	RunE:  func(c *cobra.Command, a []string) error { return setTrackEnabled(c, a, false) },
}
```

- [ ] **Step 2: Implement the RunE funcs** (same file). `runTracksCreate` composes then creates; `--json` prints the created id for Swift:

```go
func runTracksCreate(cmd *cobra.Command, _ []string) error {
	database, cfg, err := openTracksDB() // existing helper
	if err != nil {
		return err
	}
	defer database.Close()
	if strings.TrimSpace(tracksCreateFlagText) == "" {
		return fmt.Errorf("--text is required")
	}
	applyProviderOverride(cfg)
	pipe := customtracks.New(database, cliGenerator(cfg), cfg.Digest.Language, nil)
	ctx, cancel := context.WithTimeout(cmd.Context(), 120*time.Second)
	defer cancel()
	res, err := pipe.Compose(ctx, tracksCreateFlagTarget, tracksCreateFlagText)
	if err != nil {
		return fmt.Errorf("compose failed: %w", err)
	}
	uid, _ := database.CurrentUserID()
	id, err := database.CreateCustomTrack(db.Track{
		AssigneeUserID: uid, Text: res.Title, Context: tracksCreateFlagText,
		Instruction: res.Instruction, LinkedTargetID: tracksCreateFlagTarget,
	})
	if err != nil {
		return err
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{"id": id, "title": res.Title, "instruction": res.Instruction})
}

func runTracksWatch(cmd *cobra.Command, args []string) error {
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid target id %q: %w", args[0], err)
	}
	tracksCreateFlagTarget = id
	return runTracksCreate(cmd, nil)
}

func runTracksScan(cmd *cobra.Command, args []string) error {
	database, cfg, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()
	applyProviderOverride(cfg)
	pipe := customtracks.New(database, cliGenerator(cfg), cfg.Digest.Language, nil)
	ctx, cancel := context.WithTimeout(cmd.Context(), 420*time.Second)
	defer cancel()
	if len(args) == 1 {
		id, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid track id: %w", err)
		}
		var events []db.TrackEvent
		if tracksScanFlagSince != "" {
			events, err = pipe.RunForTrackSince(ctx, id, tracksScanFlagSince)
		} else {
			events, err = pipe.RunForTrack(ctx, id)
		}
		if err != nil {
			return fmt.Errorf("scan failed: %w", err)
		}
		if events == nil {
			events = []db.TrackEvent{}
		}
		enc := json.NewEncoder(cmd.OutOrStdout())
		enc.SetIndent("", "  ")
		return enc.Encode(events)
	}
	n, err := pipe.Run(ctx)
	if err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "scanned enabled custom tracks: %d new event(s)\n", n)
	return nil
}

func runTracksEvents(cmd *cobra.Command, args []string) error {
	database, _, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid track id: %w", err)
	}
	events, err := database.GetTrackEvents(id, 100)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(events)
}

func setTrackEnabled(cmd *cobra.Command, args []string, enabled bool) error {
	database, _, err := openTracksDB()
	if err != nil {
		return err
	}
	defer database.Close()
	id, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid track id: %w", err)
	}
	if err := database.SetTrackEnabled(id, enabled); err != nil {
		return err
	}
	fmt.Fprintf(cmd.OutOrStdout(), "track #%d enabled=%v\n", id, enabled)
	return nil
}
```

> If `openTracksDB`/`CurrentUserID` don't exist by those names, use whatever the file already uses (grep `cmd/tracks.go` for the DB-open + current-user helpers used by `runTracksGenerate`).

- [ ] **Step 3: Register** (`cmd/tracks.go` `init`, `:74-89`):

```go
	tracksCmd.AddCommand(tracksCreateCmd, tracksWatchCmd, tracksScanCmd,
		tracksEventsCmd, tracksEnableCmd, tracksDisableCmd)
	tracksCreateCmd.Flags().StringVar(&tracksCreateFlagText, "text", "", "description of what to watch")
	tracksCreateCmd.Flags().IntVar(&tracksCreateFlagTarget, "target", 0, "optional linked target id")
	tracksScanCmd.Flags().StringVar(&tracksScanFlagSince, "since", "", "scan history from this ISO8601 instant")
```

- [ ] **Step 4: Build + smoke test**

Run: `go build ./... && ./watchtower tracks create --help && ./watchtower tracks scan --help`
Expected: help prints, no build error. (Full run needs a workspace; a `cmd/tracks_test.go` invoking `runTracksEvents` against a temp DB is the unit check.)

- [ ] **Step 5: Commit**

```bash
git add cmd/tracks.go cmd/tracks_test.go
git commit -m "feat(cli): tracks create/watch/scan/events/enable/disable"
```

---

## PHASE 4 — Desktop

### Task 10: Swift `Track` fields + `TrackEvent` model

**Files:**
- Modify: `WatchtowerDesktop/Sources/Models/Track.swift:72-139`
- Create: `WatchtowerDesktop/Sources/Models/TrackEvent.swift`
- Delete: `Sources/Models/Observer.swift`, `Sources/Models/ObserverEvent.swift`
- Test: `WatchtowerDesktop/Tests/` — add a `TrackEventDecodeTests` (mirror any existing model test)

**Interfaces:**
- Produces: `Track.origin/instruction/enabled/lastRunAt/linkedTargetID` + `Track.isCustom`; `struct TrackEvent` (Codable+FetchableRecord) with `decodedRefs/decodedAction/decodedDecisionText/isUnread` (ported from `ObserverEvent`).

- [ ] **Step 1: Add fields to `Track`** — in `Track.swift`, add to the stored props (after `updatedAt` at `:138`) and to `init(row:)`:

```swift
    let origin: String
    let instruction: String
    let enabled: Bool
    let lastRunAt: String
    let linkedTargetID: Int?
```

```swift
        origin = row["origin"] ?? "auto"
        instruction = row["instruction"] ?? ""
        enabled = row["enabled"] ?? true
        lastRunAt = row["last_run_at"] ?? ""
        linkedTargetID = row["linked_target_id"]
```

Add a computed prop near `:143`:

```swift
    var isCustom: Bool { origin == "custom" }
```

- [ ] **Step 2: Create `TrackEvent.swift`** — copy `ObserverEvent.swift` verbatim, rename the type to `TrackEvent`, drop `observerId/entityType/entityId`, add `trackId`:

```swift
import Foundation
import GRDB

struct TrackEvent: Codable, FetchableRecord, Identifiable, Equatable {
    var id: Int
    var trackId: Int
    var summary: String
    var detail: String
    var sourceType: String
    var sourceId: String
    var sourceRefs: String
    var decision: String
    var proposedAction: String
    var actionStatus: String
    var readAt: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
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

    var decodedRefs: [String] {
        guard let data = sourceRefs.data(using: .utf8),
              let refs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return refs
    }

    var decodedAction: ProposedAction? {
        guard !proposedAction.isEmpty, let data = proposedAction.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProposedAction.self, from: data)
    }

    var decodedDecisionText: String? {
        guard !decision.isEmpty, let data = decision.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}
```

- [ ] **Step 3: Delete observer models**

```bash
git rm WatchtowerDesktop/Sources/Models/Observer.swift WatchtowerDesktop/Sources/Models/ObserverEvent.swift
```

- [ ] **Step 4: Build** (will surface all remaining observer refs — fixed in Tasks 11-14)

Run: `cd WatchtowerDesktop && swift build 2>&1 | head -40`
Expected: errors only about `Observer*` referencers (queries/services/views), not about `Track`/`TrackEvent`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/
git commit -m "feat(desktop): Track custom fields + TrackEvent model"
```

---

### Task 11: `TrackEventQueries` + `TrackComposeService` + `TrackScanService`

**Files:**
- Create: `Sources/Database/Queries/TrackEventQueries.swift` (from `ObserverQueries.swift`, re-pointed to `track_events`/`tracks`)
- Create: `Sources/Services/TrackComposeService.swift`, `Sources/Services/TrackScanService.swift`
- Modify: `Sources/Database/Queries/TrackQueries.swift` — add `createCustom`, `setEnabled`, `fetchCustom`
- Delete: `Sources/Database/Queries/ObserverQueries.swift`, `Sources/Services/ObserverComposeService.swift`, `Sources/Services/TargetObserveService.swift`
- Test: `Tests/TrackEventQueriesTests.swift`, `Tests/TrackScanServiceTests.swift` (port from the observer test files)

**Interfaces:**
- Produces:
  - `enum TrackEventQueries` — `fetchEvents(_:trackId:limit:)`, `unreadCount(_:trackId:)`, `markRead(_:id:)`, `setActionStatus(_:id:status:)`, `sourcePermalink(_:sourceType:sourceId:)`.
  - `TrackQueries.fetchCustomTracks(_:)`, `.createCustom(_:...)`, `.setEnabled(_:id:enabled:)`.
  - `struct TrackDraft: Decodable { let title: String; let instruction: String }`, `TrackComposeService.compose(text:targetID:) -> TrackDraft`, `TrackScanService.run(trackID:since:) -> [TrackEvent]`.

- [ ] **Step 1: Write the failing test** — `Tests/TrackScanServiceTests.swift`, port `TargetObserveServiceTests.swift`, asserting the CLI args are `["tracks","scan","<id>"]` (+ `--since`) and `[]` decodes empty:

```swift
func testScanInvokesTracksScan() async throws {
    let runner = MockCLIRunner(output: Data("[]".utf8))
    let events = try await TrackScanService(runner: runner).run(trackID: 7)
    XCTAssertEqual(runner.lastArgs, ["tracks", "scan", "7"])
    XCTAssertTrue(events.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter TrackScanServiceTests 2>&1 | tail -20`
Expected: FAIL (type not found).

- [ ] **Step 3: Implement the services**

`Sources/Services/TrackComposeService.swift` (port `ObserverComposeService`, CLI verb `tracks create`):

```swift
import Foundation

struct TrackDraft: Decodable {
    let title: String
    let instruction: String
}

struct TrackComposeService {
    let runner: CLIRunnerProtocol

    /// Composes a custom-track draft. When targetID > 0 the track is linked to it.
    func compose(text: String, targetID: Int? = nil) async throws -> TrackDraft {
        var args = ["tracks", "create", "--text", text]
        if let targetID, targetID > 0 {
            args.append(contentsOf: ["--target", "\(targetID)"])
        }
        let data = try await runner.run(args: args)
        return try JSONDecoder().decode(TrackDraft.self, from: data)
    }
}
```

> Note: `tracks create` above ALSO persists the track (see Task 9) and returns `{id,title,instruction}`. That is the intended one-shot: the Desktop "Generate" both drafts and creates. If you want a preview-before-create flow like the old sheet, add a `--dry-run` flag to `tracks create` that composes without inserting; the sheet then calls create on confirm. Decide in Task 13; default to one-shot create (simpler, matches "describe → it makes the track").

`Sources/Services/TrackScanService.swift` (port `TargetObserveService`, CLI verb `tracks scan`):

```swift
import Foundation

struct TrackScanService {
    let runner: CLIRunnerProtocol

    func run(trackID: Int, since: String? = nil) async throws -> [TrackEvent] {
        var args = ["tracks", "scan", "\(trackID)"]
        if let since, !since.isEmpty {
            args.append(contentsOf: ["--since", since])
        }
        let data = try await runner.run(args: args)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([TrackEvent].self, from: data)
    }
}
```

- [ ] **Step 4: Implement `TrackEventQueries.swift`** — port `ObserverQueries` event methods to `track_events` keyed by `track_id`:

```swift
import Foundation
import GRDB

enum TrackEventQueries {
    static func fetchEvents(_ db: Database, trackId: Int, limit: Int = 100) throws -> [TrackEvent] {
        try TrackEvent.fetchAll(db, sql: """
            SELECT * FROM track_events WHERE track_id = ?
            ORDER BY created_at DESC, id DESC LIMIT ?
            """, arguments: [trackId, limit])
    }

    static func unreadCount(_ db: Database, trackId: Int) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM track_events
            WHERE track_id = ? AND (read_at IS NULL OR read_at = '')
            """, arguments: [trackId]) ?? 0
    }

    static func markRead(_ db: Database, id: Int) throws {
        try db.execute(sql: "UPDATE track_events SET read_at = ? WHERE id = ?",
                       arguments: [ISO8601DateFormatter().string(from: Date()), id])
    }

    static func setActionStatus(_ db: Database, id: Int, status: String) throws {
        try db.execute(sql: "UPDATE track_events SET action_status = ? WHERE id = ?",
                       arguments: [status, id])
    }

    static func sourcePermalink(_ db: Database, sourceType: String, sourceId: String) throws -> String? {
        guard sourceType == "inbox", let iid = Int(sourceId) else { return nil }
        return try String.fetchOne(db, sql: "SELECT permalink FROM inbox_items WHERE id = ?", arguments: [iid])
    }
}
```

Add to `TrackQueries.swift`:

```swift
    static func fetchCustomTracks(_ db: Database) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT * FROM tracks WHERE origin = 'custom' AND dismissed_at = ''
            ORDER BY updated_at DESC
            """)
    }

    static func setEnabled(_ db: Database, id: Int, enabled: Bool) throws {
        try db.execute(sql: """
            UPDATE tracks SET enabled = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?
            """, arguments: [enabled, id])
    }
```

- [ ] **Step 5: Delete observer queries/services**

```bash
git rm WatchtowerDesktop/Sources/Database/Queries/ObserverQueries.swift \
       WatchtowerDesktop/Sources/Services/ObserverComposeService.swift \
       WatchtowerDesktop/Sources/Services/TargetObserveService.swift
```

- [ ] **Step 6: Run to verify the test passes**

Run: `cd WatchtowerDesktop && swift test --filter TrackScanServiceTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Database WatchtowerDesktop/Sources/Services WatchtowerDesktop/Tests
git commit -m "feat(desktop): TrackEventQueries + TrackCompose/TrackScan services"
```

---

### Task 12: `CustomTrackTimelineViewModel`

**Files:**
- Create: `Sources/ViewModels/CustomTrackTimelineViewModel.swift` (port `ObserverTimelineViewModel.swift`)
- Delete: `Sources/ViewModels/ObserverTimelineViewModel.swift` + its test
- Test: `Tests/CustomTrackTimelineViewModelTests.swift` (port `ObserverTimelineViewModelTests.swift`)

**Interfaces:**
- Produces `@MainActor @Observable final class CustomTrackTimelineViewModel` with `events: [TrackEvent]`, `isRefreshing`, `scanStatus`, `errorMessage`; injected `track: Track`, `dbPool`, `scanService: TrackScanService`, optional `targetsViewModel: TargetsViewModel?`; methods `start()`, `refreshNow()`, `scanHistory(since:label:)`, `sourceLink(for:)`, `markRead(_:)`, `applyAction(for:)`, `dismissAction(for:)`, `compose(text:)`, `stop()`.

- [ ] **Step 1: Port the VM** — copy `ObserverTimelineViewModel.swift`, then:
  - Replace `target: Target` injection with `track: Track` (keep an optional `targetsViewModel` for action-apply on linked targets).
  - Replace `ObserverQueries.fetchEvents(...entityId: target.id)` with `TrackEventQueries.fetchEvents(db, trackId: track.id)`; drop the observers list (custom tracks are one instruction per track, not N observers).
  - Replace `observeService: TargetObserveService` with `scanService: TrackScanService`; `refreshNow`/`scanHistory` call `scanService.run(trackID: track.id, since:)`.
  - `applyAction(for:)`: only act when `track.linkedTargetID != nil` — load that target via `TargetQueries.fetchByID`, apply via the existing `TargetActionExecutor`, then `TrackEventQueries.setActionStatus(...,"applied")`. When `linkedTargetID == nil`, hide/disable Apply (the scan prompt already suppresses `proposed_action` for standalone tracks).
  - `compose(text:)` uses `TrackComposeService`.
  - `start()`: GRDB `ValueObservation` over `TrackEventQueries.fetchEvents` for `track.id`.

- [ ] **Step 2: Delete the observer VM + test**

```bash
git rm WatchtowerDesktop/Sources/ViewModels/ObserverTimelineViewModel.swift \
       WatchtowerDesktop/Tests/ObserverTimelineViewModelTests.swift
```

- [ ] **Step 3: Port + run the VM test**

Port `ObserverTimelineViewModelTests.swift` → `CustomTrackTimelineViewModelTests.swift` (construct with a `Track`, a `MockCLIRunner`-backed `TrackScanService`, assert `refreshNow` populates `events`).

Run: `cd WatchtowerDesktop && swift test --filter CustomTrackTimelineViewModelTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels WatchtowerDesktop/Tests/CustomTrackTimelineViewModelTests.swift
git commit -m "feat(desktop): CustomTrackTimelineViewModel"
```

---

### Task 13: Track detail Activity + compose sheet + list section

**Files:**
- Create: `Sources/Views/Tracks/CustomTrackTimelineView.swift` (port `ObserverTimelineView.swift` incl. `ObserverEventRow`→`TrackEventRow` + proposed-action confirm UI)
- Create: `Sources/Views/Tracks/CustomTrackManagementSheet.swift` (port `ObserverManagementSheet.swift` compose/edit flow)
- Modify: `Sources/Views/Tracks/TrackDetailView.swift` — render `CustomTrackTimelineView` when `track.isCustom`
- Modify: `Sources/Views/Tracks/TracksListView.swift` + `Sources/ViewModels/TracksViewModel.swift` — pinned "Custom" section
- Delete: `Sources/Views/Targets/ObserverManagementSheet.swift`, `Sources/Views/Targets/ObserverTimelineView.swift`

**Interfaces:**
- Consumes `CustomTrackTimelineViewModel`, `TrackEvent`, `TrackComposeService`.

- [ ] **Step 1: Port the timeline view** — copy `ObserverTimelineView.swift` → `CustomTrackTimelineView.swift`. Rename `ObserverEventRow`→`TrackEventRow`, `event: ObserverEvent`→`event: TrackEvent`, `viewModel: ObserverTimelineViewModel`→`CustomTrackTimelineViewModel`. Keep the event-row body (`ObserverTimelineView.swift:168-222`) incl. the `actionStatus == "pending"` Apply/Dismiss block verbatim, but gate the Apply button on the VM exposing whether the track is linked (hide when standalone). Drop the multi-observer chip UI (single instruction now); keep the refresh + history-scan menu.

- [ ] **Step 2: Port the compose sheet** — copy `ObserverManagementSheet.swift` → `CustomTrackManagementSheet.swift`. The compose flow (`:26-97`) stays: text field → "Generate with AI" → draft preview (title + instruction) → "Add". `generate()` calls `viewModel.compose(text:)`. Since `tracks create` is one-shot (composes AND persists), either (a) use `--dry-run` for preview then a create-on-confirm call, or (b) skip the preview and create directly. Default to (a): add a `--dry-run` bool to `tracks create` (Task 9) that composes without inserting; the sheet previews, then confirm calls create.

- [ ] **Step 3: Wire into `TrackDetailView`** — in `TrackDetailView.swift`, add a section shown when `track.isCustom`:

```swift
    @State private var timelineVM: CustomTrackTimelineViewModel?

    // in the body, for custom tracks:
    if track.isCustom, let vm = timelineVM {
        CustomTrackTimelineView(viewModel: vm)
    }
```

Construct `timelineVM` in `.onAppear` / rebuild on `.onChange(of: track.id)` (mirror `TargetDetailView.swift:134-163`), injecting `TrackScanService(runner:)`, the `dbPool`, and `appState`'s `TargetsViewModel` (for linked-target action apply).

- [ ] **Step 4: Partition the list** — in `TracksViewModel.swift` add `customTracks: [Track]` populated in `load()` (`TrackQueries.fetchCustomTracks`), and in `TracksListView.swift` render a pinned section above the rest:

```swift
if !viewModel.customTracks.isEmpty {
    Section("Custom") {
        ForEach(viewModel.customTracks) { track in
            TrackRow(track: track).badge(Text("Custom"))
        }
    }
}
```

(Ensure the auto-track sections exclude `origin == "custom"` so a custom track isn't listed twice — filter `allTracks`/`updatedTracks` on `!$0.isCustom` in the VM `load()`.)

- [ ] **Step 5: Delete the Targets observer views**

```bash
git rm WatchtowerDesktop/Sources/Views/Targets/ObserverManagementSheet.swift \
       WatchtowerDesktop/Sources/Views/Targets/ObserverTimelineView.swift
```

- [ ] **Step 6: Build**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -30`
Expected: remaining errors only in `TargetDetailView` (Task 14).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Tracks WatchtowerDesktop/Sources/ViewModels/TracksViewModel.swift
git commit -m "feat(desktop): custom-track Activity timeline + compose sheet + pinned list section"
```

---

### Task 14: Targets — remove Activity tab, add "Watch"

**Files:**
- Modify: `Sources/Views/Targets/TargetDetailView.swift:40,51-56,101-107,134-163,1214-1224`
- Test: build + existing `Tests/TargetChatViewModelTests.swift` etc. stay green.

**Interfaces:**
- Consumes `TrackComposeService` (create linked custom track), navigation to the Tracks tab.

- [ ] **Step 1: Remove the Activity tab** — in `TargetDetailView.swift`: delete `case activity` from the `Tab` enum (`:51-56`), the `observerVM` state (`:40`), its construction/`start()`/`stop()` (`:134-163`), the `.activity` switch arm (`:101-107`), and `activityTab` (`:1214-1224`).

- [ ] **Step 2: Add a "Watch" button** — in the target detail header actions, add:

```swift
    @State private var watchText = ""
    @State private var showWatchSheet = false

    Button {
        showWatchSheet = true
    } label: { Label("Watch", systemImage: "binoculars") }
    .sheet(isPresented: $showWatchSheet) {
        // Minimal compose sheet: text field → creates a custom track linked to this target.
        CustomTrackManagementSheet(linkedTargetID: target.id) // sheet's create passes --target
    }
```

`CustomTrackManagementSheet` (Task 13) gains a `linkedTargetID: Int?` init param it forwards to `TrackComposeService.compose(text:targetID:)`. On success it can navigate to the Tracks tab (via `appState` destination) or just dismiss; default to dismiss + a toast "Custom track created".

- [ ] **Step 3: Build + full Desktop test**

Run: `cd WatchtowerDesktop && swift build && swift test 2>&1 | tail -30`
Expected: build clean; tests PASS (remove/adjust any observer-referencing tests: `TargetObserveServiceTests`, `ObserverTimelineViewModelTests` — the latter deleted in Task 12; delete `TargetObserveServiceTests.swift` too).

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift WatchtowerDesktop/Tests
git commit -m "feat(desktop): replace target Activity tab with Watch → custom track"
```

---

## PHASE 5 — Verification & cleanup

### Task 15: Full local CI mirror + inventory check

**Files:** none (verification).

- [ ] **Step 1: Go pipeline**

Run: `gofmt -l . ; go vet ./... ; go build ./... ; go test ./...`
Expected: gofmt prints nothing; vet/build clean; all tests PASS.

- [ ] **Step 2: golangci-lint**

Run: `golangci-lint run`
Expected: clean (fix any new lint — the branch head commit `08de3ca` established a green baseline).

- [ ] **Step 3: Desktop pipeline**

Run: `cd WatchtowerDesktop && swift build && swift test`
Expected: build clean; all tests PASS.

- [ ] **Step 4: Inventory guard check**

Run: `grep -rn "Test.*[0-9][0-9]_" internal/tracks/ internal/targets/ ; cat docs/inventory/README.md`
Read the `tracks`/`targets` inventory files. Confirm no guard test was weakened/renamed and no behavioral contract broken by the fold/dedup change. If any guard would be affected, STOP and ask the owner.

- [ ] **Step 5: Manual smoke (optional, needs a workspace)**

Run: `./watchtower tracks create --text "watch the release cut" && ./watchtower tracks scan && ./watchtower tracks`
Expected: a custom track is created, scan runs, and the list shows it flagged custom.

- [ ] **Step 6: Final commit (if any fixups)**

```bash
git add -A
git commit -m "chore: green local CI for custom tracks"
```

---

## Notes & deviations from the spec

- **No `track_states.source='custom_scan'`** and **no per-scan narrative rewrite.** A custom track's narrative (`text`/`context`) is authored at creation (compose title + description) and user-editable; the scan appends `track_events` only. This avoids a `track_states` table-recreation for a cosmetic label while preserving the spec's "narrative + timeline" shape and the existing manual-edit snapshot behavior.
- **`tracks` columns added via `ALTER TABLE ADD COLUMN`** (not table-recreation): SQLite permits a column-level CHECK/FK on a new column when the default satisfies it. The migration test (Task 1) validates this against a real applied DB.
- **`proposed_action` apply is limited to linked targets.** Standalone custom tracks suppress `proposed_action` (prompt rule); linked custom tracks reuse the existing `TargetActionExecutor`. No new track-mutating action kinds are introduced (YAGNI).
- **`tracks create` is one-shot** (compose + persist), with an optional `--dry-run` for the Desktop preview-then-confirm flow.
