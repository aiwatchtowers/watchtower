# Catch-Up Absence Recap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unread-driven Catch-Up review session with a time-window "absence recap" built from existing digests, stream digests, meeting recaps and the decisions ledger, plus the owner-facing items in the window, with one "I'm caught up" action that marks the window read on both write paths.

**Architecture:** Go owns the pipeline (`internal/catchup/`: resolve window → top-up existing digest pipelines → gather eight window queries → one strong-tier compose call → validate refs → persist one `catchup_recaps` row) and the CLI (`cmd/catchup.go`). Swift (`WatchtowerDesktop`) reads `catchup_recaps` via GRDB, runs the CLI for builds/feedback, and writes acknowledge directly (the existing dual-path). The old `catchup_sessions`/`catchup_themes` tables, peel/expand passes and the review UI are deleted.

**Tech Stack:** Go 1.25 + `modernc.org/sqlite` + goose migrations + cobra; SwiftUI (macOS 14+) + GRDB.swift; XCTest; testify.

**Spec:** `docs/superpowers/specs/2026-09-04-catchup-absence-recap-design.md`

## Global Constraints

- Migration file is `internal/db/migrations/00061_catchup_recaps.sql`; mirror every schema change in `internal/db/schema.sql` and in `WatchtowerDesktop/Tests/Support/TestDatabase.swift`; regenerate the golden with `go test ./internal/db/ -run TestSchemaGolden -update`.
- Ref areas are exactly `digests | streams | recaps | transcripts | decisions | inbox | tracks | targets`.
- `catchup_recaps.status` ∈ `building | ready | failed`.
- Window cap: `maxWindowDays = 31` (code constant). Auto-window fallback: `now − 24h`. Top-up runs only when `to ≥ now − 5 min`.
- Prompt budget trim order when over `catchup.max_prompt_chars`: **streams → tracks → decisions → digests**; inbox, targets, meetings are never trimmed.
- Feedback rows keep `entity_type = 'catchup_theme'`, `entity_id = "<recap_id>:<topic_idx>"`.
- Every AI call carries `prompts.Directive(cfg.Digest.Language)` in the system prompt; the compose call is tagged `digest.WithSource(ctx, "catchup.compose")` (strong tier); learn stays `"catchup.learn"` (light).
- Guard test names: `TestCatchup01_AcknowledgeMarksWindowRead`, `TestCatchup01_AcknowledgeIsIdempotent`, `TestCatchup02_ComposePromptCarriesLanguageDirective`, `TestCatchup03_TopUpFailureStillProducesRecap`, `TestCatchup04_InventedRefsAreDroppedNotPersisted` (Go); `testAcknowledgeMarksWindowReadOnFiveSurfaces`, `testAcknowledgeLeavesItemsOutsideWindowUnread`, `testAcknowledgeIsIdempotent` (Swift, `Tests/Core`).
- Inner loop: `go test ./internal/<pkg>`; Swift `make test-swift FILTER=<Class>`. Never delete `WatchtowerDesktop/.build`. Commit after every task with the `Co-Authored-By` / `Claude-Session` trailers used on this branch.
- All docs/comments in English.

---

## File map

**Go — modify/rewrite**
- `internal/db/migrations/00061_catchup_recaps.sql` (create)
- `internal/db/schema.sql` — replace the two catchup tables with `catchup_recaps`
- `internal/db/db_test.go` — `TestAllTablesExist` list
- `internal/db/testdata/schema_v73.golden` — regenerated
- `internal/db/catchup_store.go` — rewrite: recap row store + window mark-read
- `internal/db/catchup_store_test.go` (create)
- `internal/db/catchup.go` — rewrite: the eight window gather queries + coverage + scope hints
- `internal/db/catchup_test.go` (create)
- `internal/config/config.go`, `internal/config/config_test.go` — `CatchupConfig`
- `internal/prompts/store.go`, `internal/prompts/defaults.go`, `internal/prompts/defaults_extra_test.go` — `catchup.compose`
- `internal/digest/models.go`, `internal/digest/models_test.go` — tier table
- `internal/catchup/window.go` (create), `window_test.go` (create)
- `internal/catchup/types.go` — rewrite: compose result, body, validation
- `internal/catchup/types_test.go` — rewrite
- `internal/catchup/prompt.go` — rewrite: compose user message + budget; learn prompt kept
- `internal/catchup/prompt_test.go` (create)
- `internal/catchup/pipeline.go` — rewrite: Run / Acknowledge / top-up seam
- `internal/catchup/pipeline_test.go` — rewrite
- `internal/catchup/learn.go`, `learn_test.go` — adapt to recap topics
- `cmd/catchup.go` — rewrite; `cmd/catchup_test.go` rewrite; `cmd/coverage_gap_test.go` (the `TestRunCatchup_EmptyBacklog` block)
- `docs/inventory/catchup.md` — rewrite; `docs/inventory/README.md` — module mapping line; `CLAUDE.md` — feature note

**Swift — modify/rewrite**
- `WatchtowerDesktop/Tests/Support/TestDatabase.swift` — schema block
- `WatchtowerDesktop/Sources/WatchtowerCore/Models/CatchUpModels.swift` — rewrite
- `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/CatchUpQueries.swift` — rewrite
- `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/StreamDigestQueries.swift` — add `fetchByID`
- `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/MeetingRecapQueries.swift` — add `fetchByID`
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift` — rewrite
- `WatchtowerDesktop/Tests/Core/CatchUpModelsTests.swift` (create)
- `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift`, `Tests/SidebarCountsViewModelTests.swift`
- `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift` — rewrite; `Tests/CatchUpViewModelTests.swift` — rewrite
- `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift` — rewrite
- `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpRecapRow.swift` (create)
- `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpRecapDocument.swift` (create)
- `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpSourceInline.swift` — keep + extend
- `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpSourceInlineExtra.swift` (create)
- delete `CatchUpThemeRow.swift`, `CatchUpReviewPane.swift`

---

### Task 1: Migration + schema mirror

**Files:**
- Create: `internal/db/migrations/00061_catchup_recaps.sql`
- Modify: `internal/db/schema.sql` (the `catchup_sessions`/`catchup_themes` block around line 532)
- Modify: `internal/db/db_test.go:166-215` (`TestAllTablesExist`)
- Regenerate: `internal/db/testdata/schema_v73.golden`

**Interfaces:**
- Produces: table `catchup_recaps` with the columns below.

- [ ] **Step 1: Write the failing test** — add `"catchup_recaps"` to the `expectedTables` slice in `TestAllTablesExist` (`internal/db/db_test.go`).

- [ ] **Step 2: Run it** — `go test ./internal/db/ -run TestAllTablesExist` → FAIL (table missing).

- [ ] **Step 3: Create the migration**

```sql
-- +goose Up
-- Catch-Up becomes an absence recap (spec 2026-09-04): one persisted recap per
-- time window replaces the unread-driven review session + per-theme rows.
-- The old tables held only review state (no history), so they are dropped, not
-- migrated.
DROP TABLE IF EXISTS catchup_themes;
DROP TABLE IF EXISTS catchup_sessions;

CREATE TABLE catchup_recaps (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from     REAL NOT NULL,
    period_to       REAL NOT NULL,
    status          TEXT NOT NULL CHECK(status IN ('building','ready','failed')),
    tldr            TEXT NOT NULL DEFAULT '',
    body_json       TEXT NOT NULL DEFAULT '{}',
    coverage_json   TEXT NOT NULL DEFAULT '{}',
    error           TEXT NOT NULL DEFAULT '',
    regen_of_id     INTEGER REFERENCES catchup_recaps(id) ON DELETE SET NULL,
    acknowledged_at TEXT,
    model           TEXT NOT NULL DEFAULT '',
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    cost_usd        REAL NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_catchup_recaps_ack ON catchup_recaps(acknowledged_at, period_to DESC);

-- +goose Down
DROP TABLE IF EXISTS catchup_recaps;

CREATE TABLE IF NOT EXISTS catchup_sessions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at     TEXT NOT NULL,
    status         TEXT NOT NULL CHECK(status IN ('building','active','done','failed')),
    total_themes   INTEGER NOT NULL DEFAULT 0,
    reviewed_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS catchup_themes (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id       INTEGER NOT NULL REFERENCES catchup_sessions(id) ON DELETE CASCADE,
    order_idx        INTEGER NOT NULL DEFAULT 0,
    title            TEXT NOT NULL DEFAULT '',
    narrative        TEXT NOT NULL DEFAULT '',
    priority         TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    needs_you        INTEGER NOT NULL DEFAULT 0,
    suggested_action TEXT NOT NULL DEFAULT '',
    refs             TEXT NOT NULL DEFAULT '[]',
    gen_state        TEXT NOT NULL DEFAULT 'skeleton' CHECK(gen_state IN ('skeleton','expanding','ready','failed')),
    review_state     TEXT NOT NULL DEFAULT 'pending' CHECK(review_state IN ('pending','reviewed','snoozed')),
    snooze_until     TEXT NOT NULL DEFAULT '',
    task_id          INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_catchup_themes_session ON catchup_themes(session_id, order_idx);
```

- [ ] **Step 4: Mirror in `schema.sql`** — replace the `catchup_sessions` + `catchup_themes` definitions (comment "Catch-Up v2 — …") with the `catchup_recaps` CREATE + index from the Up section, comment: `-- Catch-Up — one persisted absence recap per time window (see 00061)`.

- [ ] **Step 5: Regenerate the golden and run the db package**

```bash
go test ./internal/db/ -run TestSchemaGolden -update
go test ./internal/db/
```
Expected: PASS (compile errors from `catchup_store.go` are impossible at this point because the old functions only reference the old tables at runtime; if `TestCatchupStore*` tests exist they will fail — that is Task 2's job, note it and continue).

- [ ] **Step 6: Commit** — `git add internal/db && git commit -m "feat(catchup): migration 00061 — catchup_recaps replaces sessions/themes"`.

---

### Task 2: Go recap store + window mark-read

**Files:**
- Rewrite: `internal/db/catchup_store.go`
- Create: `internal/db/catchup_store_test.go`

**Interfaces (produces):**

```go
type CatchupRef struct { Area string `json:"area"`; ID int `json:"id"`; Label string `json:"label"` } // kept
type CatchupRecap struct {
    ID             int64
    PeriodFrom     float64
    PeriodTo       float64
    Status         string
    TLDR           string
    BodyJSON       string
    CoverageJSON   string
    Error          string
    RegenOfID      int64  // 0 when NULL
    AcknowledgedAt string // "" when NULL
    Model          string
    InputTokens    int
    OutputTokens   int
    CostUSD        float64
    CreatedAt      string
    UpdatedAt      string
}
func (db *DB) InsertCatchupRecap(from, to float64, regenOfID int64) (int64, error)      // status='building'
func (db *DB) FinishCatchupRecap(id int64, tldr, bodyJSON, coverageJSON, model string, inTok, outTok int, cost float64) error // status='ready'
func (db *DB) FailCatchupRecap(id int64, coverageJSON, errMsg string) error              // status='failed'
func (db *DB) GetCatchupRecap(id int64) (*CatchupRecap, error)                           // sql.ErrNoRows wrapped when missing
func (db *DB) ListCatchupRecaps(limit int) ([]CatchupRecap, error)                       // newest first by id
func (db *DB) LastAcknowledgedCatchupTo() (float64, error)                               // 0 when none
func (db *DB) AcknowledgeCatchupWindow(id int64, from, to float64) error                 // one tx: 5 surfaces + acknowledged_at
```

- [ ] **Step 1: Write the failing tests** (`internal/db/catchup_store_test.go`)

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCatchupRecapLifecycle(t *testing.T) {
	d := openTestDB(t)
	id, err := d.InsertCatchupRecap(100, 200, 0)
	require.NoError(t, err)
	r, err := d.GetCatchupRecap(id)
	require.NoError(t, err)
	assert.Equal(t, "building", r.Status)
	assert.Equal(t, 100.0, r.PeriodFrom)

	require.NoError(t, d.FinishCatchupRecap(id, "tl;dr", `{"topics":[]}`, `{"topup":"ok"}`, "sonnet", 10, 5, 0.01))
	r, err = d.GetCatchupRecap(id)
	require.NoError(t, err)
	assert.Equal(t, "ready", r.Status)
	assert.Equal(t, "tl;dr", r.TLDR)
	assert.Equal(t, `{"topics":[]}`, r.BodyJSON)
	assert.Equal(t, 10, r.InputTokens)

	id2, err := d.InsertCatchupRecap(100, 200, id)
	require.NoError(t, err)
	require.NoError(t, d.FailCatchupRecap(id2, `{"topup":"skipped"}`, "boom"))
	r2, err := d.GetCatchupRecap(id2)
	require.NoError(t, err)
	assert.Equal(t, "failed", r2.Status)
	assert.Equal(t, "boom", r2.Error)
	assert.Equal(t, id, r2.RegenOfID)

	list, err := d.ListCatchupRecaps(10)
	require.NoError(t, err)
	require.Len(t, list, 2)
	assert.Equal(t, id2, list[0].ID, "newest first")

	_, err = d.GetCatchupRecap(999)
	assert.Error(t, err)
}

func TestLastAcknowledgedCatchupTo(t *testing.T) {
	d := openTestDB(t)
	got, err := d.LastAcknowledgedCatchupTo()
	require.NoError(t, err)
	assert.Equal(t, 0.0, got, "no recaps → 0")

	a, _ := d.InsertCatchupRecap(100, 200, 0)
	b, _ := d.InsertCatchupRecap(200, 300, 0)
	_, err = d.Exec(`UPDATE catchup_recaps SET acknowledged_at='2026-09-04T10:00:00Z' WHERE id=?`, a)
	require.NoError(t, err)
	got, err = d.LastAcknowledgedCatchupTo()
	require.NoError(t, err)
	assert.Equal(t, 200.0, got, "only acknowledged recaps count; b (%d) is unacknowledged", b)
}

// BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
func TestCatchup01_AcknowledgeMarksWindowRead(t *testing.T) {
	d := openTestDB(t)
	// in-window rows (from=1000, to=2000)
	in, _ := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', 1500, 1600, 'channel', 'in')`)
	inID, _ := in.LastInsertId()
	out, _ := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', 2500, 2600, 'channel', 'out')`)
	outID, _ := out.LastInsertId()
	_, err := d.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('gmail', 1, '1970-01-01T00:25:00Z', '1970-01-01T00:26:40Z')`) // period_to = 1600s
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO tracks (text, updated_at, has_updates, dismissed_at) VALUES ('t', '1970-01-01T00:25:00Z', 1, '')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, created_at) VALUES ('1:C1', '1500.0', '1:U1', 'mention', '1970-01-01T00:25:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO briefings (user_id, date) VALUES ('1:U0', '1970-01-01')`)
	require.NoError(t, err)

	id, _ := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, d.AcknowledgeCatchupWindow(id, 1000, 2000))

	var readAt *string
	require.NoError(t, d.QueryRow(`SELECT read_at FROM digests WHERE id=?`, inID).Scan(&readAt))
	assert.NotNil(t, readAt, "in-window digest read")
	require.NoError(t, d.QueryRow(`SELECT read_at FROM digests WHERE id=?`, outID).Scan(&readAt))
	assert.Nil(t, readAt, "outside-window digest untouched")
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM stream_digests WHERE read_at IS NOT NULL`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM tracks WHERE read_at IS NOT NULL AND has_updates = 0`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE read_at IS NOT NULL`).Scan(&n))
	assert.Equal(t, 1, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM briefings WHERE read_at IS NOT NULL`).Scan(&n))
	assert.Equal(t, 1, n)
	r, _ := d.GetCatchupRecap(id)
	assert.NotEmpty(t, r.AcknowledgedAt)
}

// BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
func TestCatchup01_AcknowledgeIsIdempotent(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, read_at) VALUES ('1:C1', 1500, 1600, 'channel', 'x', '2020-01-01T00:00:00Z')`)
	require.NoError(t, err)
	id, _ := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, d.AcknowledgeCatchupWindow(id, 1000, 2000))
	first, _ := d.GetCatchupRecap(id)
	require.NoError(t, d.AcknowledgeCatchupWindow(id, 1000, 2000))
	second, _ := d.GetCatchupRecap(id)
	assert.Equal(t, first.AcknowledgedAt, second.AcknowledgedAt, "second ack keeps the first stamp")
	var readAt string
	require.NoError(t, d.QueryRow(`SELECT read_at FROM digests`).Scan(&readAt))
	assert.Equal(t, "2020-01-01T00:00:00Z", readAt, "already-read rows keep their stamp")
}
```

Check what the package-private test opener is called (`openTestDB` per `testhelpers.go`'s comment; adjust if the name differs) and whether `briefings.user_id`/`tracks.text` inserts need more NOT NULL columns — add defaults as the schema demands.

- [ ] **Step 2: Run** — `go test ./internal/db/ -run 'TestCatchupRecap|TestLastAcknowledged|TestCatchup01'` → FAIL (undefined).

- [ ] **Step 3: Rewrite `internal/db/catchup_store.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// CatchupRef points at one source row a recap item was built from.
type CatchupRef struct {
	Area  string `json:"area"`
	ID    int    `json:"id"`
	Label string `json:"label"`
}

// CatchupRecap is one persisted absence recap (catchup_recaps row).
type CatchupRecap struct {
	ID                     int64
	PeriodFrom, PeriodTo   float64
	Status                 string
	TLDR                   string
	BodyJSON, CoverageJSON string
	Error                  string
	RegenOfID              int64
	AcknowledgedAt         string
	Model                  string
	InputTokens            int
	OutputTokens           int
	CostUSD                float64
	CreatedAt, UpdatedAt   string
}

const catchupRecapCols = `id, period_from, period_to, status, tldr, body_json, coverage_json, error,
	COALESCE(regen_of_id, 0), COALESCE(acknowledged_at, ''), model, input_tokens, output_tokens, cost_usd, created_at, updated_at`

func scanCatchupRecap(s interface{ Scan(...any) error }) (*CatchupRecap, error) {
	var r CatchupRecap
	err := s.Scan(&r.ID, &r.PeriodFrom, &r.PeriodTo, &r.Status, &r.TLDR, &r.BodyJSON, &r.CoverageJSON, &r.Error,
		&r.RegenOfID, &r.AcknowledgedAt, &r.Model, &r.InputTokens, &r.OutputTokens, &r.CostUSD, &r.CreatedAt, &r.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &r, nil
}

// InsertCatchupRecap creates a recap row in status='building'. regenOfID links a
// regenerated recap to the one it corrects (0 = none).
func (db *DB) InsertCatchupRecap(from, to float64, regenOfID int64) (int64, error) {
	var regen any
	if regenOfID > 0 {
		regen = regenOfID
	}
	res, err := db.Exec(`INSERT INTO catchup_recaps (period_from, period_to, status, regen_of_id) VALUES (?, ?, 'building', ?)`, from, to, regen)
	if err != nil {
		return 0, fmt.Errorf("creating catchup recap: %w", err)
	}
	return res.LastInsertId()
}

// FinishCatchupRecap persists a successful compose and flips status to 'ready'.
func (db *DB) FinishCatchupRecap(id int64, tldr, bodyJSON, coverageJSON, model string, inTok, outTok int, cost float64) error {
	_, err := db.Exec(`UPDATE catchup_recaps SET status='ready', tldr=?, body_json=?, coverage_json=?, model=?,
		input_tokens=?, output_tokens=?, cost_usd=?, error='', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?`,
		tldr, bodyJSON, coverageJSON, model, inTok, outTok, cost, id)
	if err != nil {
		return fmt.Errorf("finishing catchup recap %d: %w", id, err)
	}
	return nil
}

// FailCatchupRecap records a compose/parse failure; whatever coverage was
// computed before the failure is kept for the UI.
func (db *DB) FailCatchupRecap(id int64, coverageJSON, errMsg string) error {
	_, err := db.Exec(`UPDATE catchup_recaps SET status='failed', coverage_json=?, error=?,
		updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=?`, coverageJSON, errMsg, id)
	if err != nil {
		return fmt.Errorf("failing catchup recap %d: %w", id, err)
	}
	return nil
}

// GetCatchupRecap returns one recap or a wrapped sql.ErrNoRows.
func (db *DB) GetCatchupRecap(id int64) (*CatchupRecap, error) {
	r, err := scanCatchupRecap(db.QueryRow(`SELECT `+catchupRecapCols+` FROM catchup_recaps WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("catchup recap %d: %w", id, err)
	}
	if err != nil {
		return nil, fmt.Errorf("getting catchup recap %d: %w", id, err)
	}
	return r, nil
}

// ListCatchupRecaps returns the newest recaps first.
func (db *DB) ListCatchupRecaps(limit int) ([]CatchupRecap, error) {
	rows, err := db.Query(`SELECT `+catchupRecapCols+` FROM catchup_recaps ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup recaps: %w", err)
	}
	defer rows.Close()
	var out []CatchupRecap
	for rows.Next() {
		r, err := scanCatchupRecap(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning catchup recap: %w", err)
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// LastAcknowledgedCatchupTo returns period_to of the most recently acknowledged
// recap (the "I'm caught up until T" boundary), or 0 when none exists.
func (db *DB) LastAcknowledgedCatchupTo() (float64, error) {
	var to sql.NullFloat64
	err := db.QueryRow(`SELECT MAX(period_to) FROM catchup_recaps WHERE acknowledged_at IS NOT NULL`).Scan(&to)
	if err != nil {
		return 0, fmt.Errorf("reading last acknowledged catchup: %w", err)
	}
	return to.Float64, nil
}

// AcknowledgeCatchupWindow marks everything inside [from, to] read on the five
// read_at surfaces and stamps the recap acknowledged_at (first stamp wins).
// Set-based, one transaction, idempotent (CATCHUP-01).
func (db *DB) AcknowledgeCatchupWindow(id int64, from, to float64) error {
	fromISO := time.Unix(int64(from), 0).UTC().Format("2006-01-02T15:04:05Z")
	toISO := time.Unix(int64(to), 0).UTC().Format("2006-01-02T15:04:05Z")
	fromDate := time.Unix(int64(from), 0).Local().Format("2006-01-02")
	toDate := time.Unix(int64(to), 0).Local().Format("2006-01-02")
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("acknowledging catchup %d: %w", id, err)
	}
	defer tx.Rollback() //nolint:errcheck
	now := `strftime('%Y-%m-%dT%H:%M:%SZ','now')`
	stmts := []struct {
		q    string
		args []any
	}{
		{`UPDATE digests SET read_at=` + now + ` WHERE read_at IS NULL AND period_to > ? AND period_to <= ?`, []any{from, to}},
		{`UPDATE stream_digests SET read_at=` + now + ` WHERE read_at IS NULL AND period_to > ? AND period_to <= ?`, []any{fromISO, toISO}},
		{`UPDATE tracks SET read_at=` + now + `, has_updates=0 WHERE dismissed_at='' AND updated_at > ? AND updated_at <= ? AND (read_at IS NULL OR has_updates=1)`, []any{fromISO, toISO}},
		{`UPDATE inbox_items SET read_at=` + now + ` WHERE read_at IS NULL AND created_at > ? AND created_at <= ?`, []any{fromISO, toISO}},
		{`UPDATE briefings SET read_at=` + now + ` WHERE read_at IS NULL AND date >= ? AND date <= ?`, []any{fromDate, toDate}},
		{`UPDATE catchup_recaps SET acknowledged_at=` + now + `, updated_at=` + now + ` WHERE id=? AND acknowledged_at IS NULL`, []any{id}},
	}
	for _, s := range stmts {
		if _, err := tx.Exec(s.q, s.args...); err != nil {
			return fmt.Errorf("acknowledging catchup %d: %w", id, err)
		}
	}
	return tx.Commit()
}
```

Delete every old session/theme function (`CreateCatchupSession`, `SetCatchupSessionStatus`, `SetCatchupSessionTotals`, `IncrementReviewed`, `GetActiveCatchupSession`, `InsertCatchupTheme`, `UpdateCatchupThemeExpansion`, `GetCatchupTheme`, `ListCatchupThemes`, `SetCatchupThemeReview`, `SetCatchupThemeTask`, `CloseOpenCatchupSessions`) and the `CatchupSession`/`CatchupTheme` types. `go build ./...` will now fail in `internal/catchup` and `cmd` — expected until Tasks 6–7; run only `./internal/db/` here.

- [ ] **Step 4: Run** — `go test ./internal/db/ -run 'TestCatchupRecap|TestLastAcknowledged|TestCatchup01'` → PASS. Also `go vet ./internal/db/`.

- [ ] **Step 5: Commit** — `feat(catchup): recap store + window acknowledge (CATCHUP-01 Go path)`.

---

### Task 3: Go window gather queries + coverage + scope hints

**Files:**
- Rewrite: `internal/db/catchup.go`
- Create: `internal/db/catchup_test.go`

**Interfaces (produces):**

```go
// CatchupItem is one gathered source row, display-ready for the prompt.
type CatchupItem struct {
	Area      string // digests|streams|recaps|transcripts|decisions|inbox|tracks|targets
	ID        int
	Title     string // short label (channel name, subject, meeting title…)
	Body      string // trimmed content for the prompt
	Meta      string // provenance line: "#chan · to 17:40", "gmail · acct", sender name…
	ChannelID string // learned-rule scope hint (digests, inbox)
	SenderID  string // learned-rule scope hint (inbox)
}
func (db *DB) ListCatchupDigests(from, to float64, limit int) ([]CatchupItem, error)
func (db *DB) ListCatchupStreams(from, to float64, limit int) ([]CatchupItem, error)
func (db *DB) ListCatchupMeetings(from, to float64, limit int) ([]CatchupItem, error) // recaps + ad-hoc transcripts, two areas in one slice
func (db *DB) ListCatchupDecisions(from, to float64, limit int) ([]CatchupItem, error)
func (db *DB) ListCatchupInbox(from, to float64, limit int) ([]CatchupItem, error)
func (db *DB) ListCatchupTracks(from, to float64, limit int) ([]CatchupItem, error)
func (db *DB) ListCatchupTargets(from, to float64, limit int) ([]CatchupItem, error)
func (db *DB) CatchupCoverage(from, to float64) (slackTo, streamsTo float64, err error)
func (db *DB) FetchItemScopeHints(area string, id int) (channelID, senderID string, err error) // kept, new areas
```

Helper: `func unixToISO(ts float64) string` (UTC `2006-01-02T15:04:05Z`).

- [ ] **Step 1: Write the failing tests** (`internal/db/catchup_test.go`). Use `openTestDB(t)`. Window `from=1000, to=2000` → ISO `1970-01-01T00:16:40Z`..`1970-01-01T00:33:20Z`.

```go
func TestListCatchupDigests_WindowOverlapAndTopics(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'eng', 'public')`)
	require.NoError(t, err)
	in, _ := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary, message_count) VALUES ('1:C1', 900, 1100, 'channel', 'overlaps start', 7)`)
	inID, _ := in.LastInsertId()
	_, _ = d.Exec(`INSERT INTO digest_topics (digest_id, idx, title, summary) VALUES (?, 0, 'Deploy', 'shipped v2')`, inID)
	_, _ = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', 2100, 2200, 'channel', 'after')`)
	_, _ = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('', 1000, 2000, 'daily', 'rollup excluded')`)
	items, err := d.ListCatchupDigests(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "digests", items[0].Area)
	assert.Equal(t, int(inID), items[0].ID)
	assert.Equal(t, "#eng", items[0].Title)
	assert.Contains(t, items[0].Body, "overlaps start")
	assert.Contains(t, items[0].Body, "Deploy: shipped v2")
	assert.Equal(t, "1:C1", items[0].ChannelID)
}

func TestListCatchupStreams(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO stream_digests (source, account_id, scope, period_from, period_to, topics_json)
		VALUES ('jira', 1, 'PROJ', '1970-01-01T00:20:00Z', '1970-01-01T00:30:00Z', '[{"title":"Bug bash","summary":"12 fixed"}]')`)
	require.NoError(t, err)
	_, _ = d.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('gmail', 1, '1970-01-01T01:00:00Z', '1970-01-01T02:00:00Z')`)
	items, err := d.ListCatchupStreams(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "streams", items[0].Area)
	assert.Equal(t, "jira · PROJ", items[0].Title)
	assert.Contains(t, items[0].Body, "Bug bash: 12 fixed")
}

func TestListCatchupMeetings_RecapAndAdHoc(t *testing.T) {
	d := openTestDB(t)
	// event-linked recap whose calendar row is gone → title falls back to the transcript title, then "Meeting"
	_, err := d.Exec(`INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at) VALUES (NULL, 's', '{"summary":"we agreed","key_decisions":["ship"],"action_items":["a"]}', '1970-01-01T00:20:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Ad hoc sync', 'txt', '{"summary":"quick"}', '1970-01-01T00:25:00Z')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO meeting_transcripts (event_id, title, transcript_text, summary_json, created_at) VALUES (NULL, 'Old', 'txt', '{"summary":"old"}', '1970-01-01T05:00:00Z')`)
	require.NoError(t, err)
	items, err := d.ListCatchupMeetings(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 2)
	assert.Equal(t, "recaps", items[0].Area)
	assert.Equal(t, "Meeting", items[0].Title)
	assert.Contains(t, items[0].Body, "we agreed")
	assert.Contains(t, items[0].Body, "Decisions: ship")
	assert.Equal(t, "transcripts", items[1].Area)
	assert.Equal(t, "Ad hoc sync", items[1].Title)
}

func TestListCatchupDecisions_MentionInWindow(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO ideas (id, kind, title, essence, status) VALUES (1, 'decision', 'Use Postgres', 'for analytics', 'active'), (2, 'decision', 'Old', '', 'active'), (3, 'idea', 'Not a decision', '', 'active')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO idea_mentions (idea_id, source, ref, quote, author, said_at) VALUES
		(1, 'slack', 'C1|1', 'let us use pg', 'Ann', '1970-01-01T00:20:00Z'),
		(2, 'slack', 'C1|2', 'old', 'Bob', '1970-01-01T05:00:00Z'),
		(3, 'slack', 'C1|3', 'idea', 'Cy', '1970-01-01T00:20:00Z')`)
	require.NoError(t, err)
	items, err := d.ListCatchupDecisions(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "decisions", items[0].Area)
	assert.Equal(t, 1, items[0].ID)
	assert.Equal(t, "Use Postgres", items[0].Title)
	assert.Contains(t, items[0].Body, "for analytics")
	assert.Contains(t, items[0].Meta, "Ann")
}

func TestListCatchupInbox_ActionablePendingInWindow(t *testing.T) {
	d := openTestDB(t)
	_, _ = d.Exec(`INSERT INTO users (id, name, display_name) VALUES ('1:U1', 'ann', 'Ann')`)
	_, _ = d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C1', 'eng', 'public')`)
	_, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, status, item_class, created_at) VALUES
		('1:C1', '1', '1:U1', 'mention', 'can you review?', 'pending', 'actionable', '1970-01-01T00:20:00Z'),
		('1:C1', '2', '1:U1', 'mention', 'resolved one', 'resolved', 'actionable', '1970-01-01T00:20:00Z'),
		('1:C1', '3', '1:U1', 'stream', 'ambient', 'pending', 'ambient', '1970-01-01T00:20:00Z'),
		('1:C1', '4', '1:U1', 'dm', 'too late', 'pending', 'actionable', '1970-01-01T05:00:00Z')`)
	require.NoError(t, err)
	items, err := d.ListCatchupInbox(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, items, 1)
	assert.Equal(t, "inbox", items[0].Area)
	assert.Equal(t, "mention", items[0].Title)
	assert.Equal(t, "can you review?", items[0].Body)
	assert.Contains(t, items[0].Meta, "Ann")
	assert.Contains(t, items[0].Meta, "#eng")
	assert.Equal(t, "1:C1", items[0].ChannelID)
	assert.Equal(t, "1:U1", items[0].SenderID)
}

func TestListCatchupTracksAndTargets(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO tracks (text, context, priority, ownership, updated_at, dismissed_at) VALUES
		('Review PR', 'ctx', 'high', 'mine', '1970-01-01T00:20:00Z', ''),
		('Dismissed', '', 'low', 'mine', '1970-01-01T00:20:00Z', '2020-01-01T00:00:00Z'),
		('Old', '', 'low', 'mine', '1970-01-01T05:00:00Z', '')`)
	require.NoError(t, err)
	tracks, err := d.ListCatchupTracks(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, tracks, 1)
	assert.Equal(t, "Review PR", tracks[0].Title)
	assert.Contains(t, tracks[0].Meta, "high")

	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, status, priority, due_date) VALUES
		('Due in window', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-01T00:20'),
		('Overdue', '1970-01-01', '1970-01-01', 'in_progress', 'medium', '1969-12-31T10:00'),
		('Done', '1970-01-01', '1970-01-01', 'done', 'high', '1970-01-01T00:20'),
		('Later', '1970-01-01', '1970-01-01', 'todo', 'high', '1970-01-02T00:00'),
		('No due', '1970-01-01', '1970-01-01', 'todo', 'high', '')`)
	require.NoError(t, err)
	targets, err := d.ListCatchupTargets(1000, 2000, 10)
	require.NoError(t, err)
	require.Len(t, targets, 2)
	assert.ElementsMatch(t, []string{"Due in window", "Overdue"}, []string{targets[0].Title, targets[1].Title})
}

func TestCatchupCoverage(t *testing.T) {
	d := openTestDB(t)
	slackTo, streamsTo, err := d.CatchupCoverage(1000, 2000)
	require.NoError(t, err)
	assert.Equal(t, 0.0, slackTo)
	assert.Equal(t, 0.0, streamsTo)
	_, _ = d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', 1000, 1500, 'channel', 'a'), ('1:C2', 1000, 1800, 'channel', 'b'), ('1:C3', 2000, 2500, 'channel', 'c')`)
	_, _ = d.Exec(`INSERT INTO stream_digests (source, account_id, period_from, period_to) VALUES ('jira', 1, '1970-01-01T00:16:40Z', '1970-01-01T00:26:40Z')`) // 1600
	slackTo, streamsTo, err = d.CatchupCoverage(1000, 2000)
	require.NoError(t, err)
	assert.Equal(t, 1800.0, slackTo)
	assert.Equal(t, 1600.0, streamsTo)
}

func TestFetchItemScopeHints_Areas(t *testing.T) {
	d := openTestDB(t)
	res, _ := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C9', 1, 2, 'channel', 's')`)
	id, _ := res.LastInsertId()
	ch, snd, err := d.FetchItemScopeHints("digests", int(id))
	require.NoError(t, err)
	assert.Equal(t, "1:C9", ch)
	assert.Empty(t, snd)
	for _, area := range []string{"streams", "recaps", "transcripts", "decisions", "tracks", "targets"} {
		ch, snd, err := d.FetchItemScopeHints(area, 1)
		require.NoError(t, err, area)
		assert.Empty(t, ch+snd, area)
	}
	_, _, err = d.FetchItemScopeHints("briefings", 1)
	assert.Error(t, err, "briefings is no longer an area")
}
```

If an INSERT trips a NOT NULL column not listed above, add that column with a sensible literal — do not weaken the assertion.

- [ ] **Step 2: Run** — `go test ./internal/db/ -run 'TestListCatchup|TestCatchupCoverage|TestFetchItemScopeHints'` → FAIL.

- [ ] **Step 3: Rewrite `internal/db/catchup.go`**

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// CatchupItem is one gathered source row, display-ready for the compose prompt
// and resolvable by (Area, ID) for the recap's refs.
type CatchupItem struct {
	Area      string
	ID        int
	Title     string
	Body      string
	Meta      string
	ChannelID string
	SenderID  string
}

func unixToISO(ts float64) string {
	return time.Unix(int64(ts), 0).UTC().Format("2006-01-02T15:04:05Z")
}

// ListCatchupDigests returns channel digests overlapping [from, to], newest
// first, each with its topics folded into Body ("Title: summary" lines).
func (db *DB) ListCatchupDigests(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT d.id, d.channel_id, COALESCE(c.name, ''), d.summary, d.period_to, d.message_count
		FROM digests d LEFT JOIN channels c ON c.id = d.channel_id
		WHERE d.type = 'channel' AND d.period_to > ? AND d.period_from < ?
		ORDER BY d.period_to DESC LIMIT ?`, from, to, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup digests: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var name, summary string
		var periodTo float64
		var msgs int
		if err := rows.Scan(&it.ID, &it.ChannelID, &name, &summary, &periodTo, &msgs); err != nil {
			return nil, fmt.Errorf("scanning catchup digest: %w", err)
		}
		it.Area = "digests"
		it.Title = "#" + name
		if name == "" {
			it.Title = it.ChannelID
		}
		var b strings.Builder
		b.WriteString(summary)
		topics, _ := db.GetDigestTopics(it.ID)
		for i, t := range topics {
			if i >= 5 {
				break
			}
			fmt.Fprintf(&b, "\n- %s: %s", t.Title, t.Summary)
		}
		it.Body = b.String()
		it.Meta = fmt.Sprintf("%d messages · to %s", msgs, time.Unix(int64(periodTo), 0).Local().Format("Mon 15:04"))
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupStreams returns Gmail/Jira stream digests overlapping the window.
// Body is the topics_json rendered as "Title: summary" lines.
func (db *DB) ListCatchupStreams(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT id, source, account_id, scope, topics_json, period_to
		FROM stream_digests
		WHERE period_to > ? AND period_from < ?
		ORDER BY period_to DESC LIMIT ?`, unixToISO(from), unixToISO(to), limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup streams: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var source, scope, topicsJSON, periodTo string
		var accountID int64
		if err := rows.Scan(&it.ID, &source, &accountID, &scope, &topicsJSON, &periodTo); err != nil {
			return nil, fmt.Errorf("scanning catchup stream: %w", err)
		}
		it.Area = "streams"
		it.Title = source
		if scope != "" {
			it.Title += " · " + scope
		}
		it.Body = renderStreamTopics(topicsJSON)
		it.Meta = fmt.Sprintf("%s account %d · to %s", source, accountID, periodTo)
		out = append(out, it)
	}
	return out, rows.Err()
}

// renderStreamTopics turns stream_digests.topics_json into "Title: summary" lines.
func renderStreamTopics(topicsJSON string) string {
	var topics []struct {
		Title   string `json:"title"`
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal([]byte(topicsJSON), &topics); err != nil {
		return ""
	}
	lines := make([]string, 0, len(topics))
	for _, t := range topics {
		lines = append(lines, t.Title+": "+t.Summary)
	}
	return strings.Join(lines, "\n")
}
```
(add `"encoding/json"` to the imports)

```go
// ListCatchupMeetings returns meeting recaps (area "recaps") followed by ad-hoc
// transcript summaries (area "transcripts") created inside the window. Meetings
// are keyed on the recap's created_at because calendar_events retains only ~24h
// of past events while recaps survive (spec §5.2). Title resolution for a recap:
// calendar event title → linked transcript title → "Meeting".
func (db *DB) ListCatchupMeetings(from, to float64, limit int) ([]CatchupItem, error) {
	fromISO, toISO := unixToISO(from), unixToISO(to)
	rows, err := db.Query(`
		SELECT r.id, COALESCE(e.title, ''), COALESCE(t.title, ''), r.recap_json, r.created_at
		FROM meeting_recaps r
		LEFT JOIN calendar_events e ON e.id = r.event_id
		LEFT JOIN meeting_transcripts t ON t.id = r.transcript_id
		WHERE r.created_at > ? AND r.created_at <= ?
		ORDER BY r.created_at ASC LIMIT ?`, fromISO, toISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup recaps: %w", err)
	}
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var eventTitle, transcriptTitle, recapJSON, createdAt string
		if err := rows.Scan(&it.ID, &eventTitle, &transcriptTitle, &recapJSON, &createdAt); err != nil {
			rows.Close()
			return nil, fmt.Errorf("scanning catchup recap: %w", err)
		}
		it.Area = "recaps"
		it.Title = firstNonEmpty(eventTitle, transcriptTitle, "Meeting")
		it.Body = renderRecapJSON(recapJSON)
		it.Meta = "meeting · " + createdAt
		out = append(out, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows, err = db.Query(`
		SELECT id, title, COALESCE(summary_json, ''), created_at
		FROM meeting_transcripts
		WHERE event_id IS NULL AND summary_json IS NOT NULL AND created_at > ? AND created_at <= ?
		ORDER BY created_at ASC LIMIT ?`, fromISO, toISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup transcripts: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var it CatchupItem
		var summaryJSON, createdAt string
		if err := rows.Scan(&it.ID, &it.Title, &summaryJSON, &createdAt); err != nil {
			return nil, fmt.Errorf("scanning catchup transcript: %w", err)
		}
		it.Area = "transcripts"
		it.Body = renderRecapJSON(summaryJSON)
		it.Meta = "ad-hoc recording · " + createdAt
		out = append(out, it)
	}
	return out, rows.Err()
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// renderRecapJSON renders a meeting recap (summary + key_decisions +
// action_items, the internal/meeting RecapResult shape) as prompt text.
func renderRecapJSON(raw string) string {
	var r struct {
		Summary      string   `json:"summary"`
		KeyDecisions []string `json:"key_decisions"`
		ActionItems  []string `json:"action_items"`
	}
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return ""
	}
	var b strings.Builder
	b.WriteString(r.Summary)
	if len(r.KeyDecisions) > 0 {
		b.WriteString("\nDecisions: " + strings.Join(r.KeyDecisions, "; "))
	}
	if len(r.ActionItems) > 0 {
		b.WriteString("\nAction items: " + strings.Join(r.ActionItems, "; "))
	}
	return b.String()
}

// ListCatchupDecisions returns ledger decisions with a mention inside the window
// (said_at, or created_at when said_at is empty), newest mention first. Body is
// the essence; Meta carries the latest in-window quote and author.
func (db *DB) ListCatchupDecisions(from, to float64, limit int) ([]CatchupItem, error) {
	fromISO, toISO := unixToISO(from), unixToISO(to)
	rows, err := db.Query(`
		SELECT i.id, i.title, i.essence, m.quote, m.author, m.source
		FROM ideas i
		JOIN idea_mentions m ON m.idea_id = i.id
		WHERE i.kind = 'decision'
		  AND CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END > ?
		  AND CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END <= ?
		GROUP BY i.id
		ORDER BY MAX(CASE WHEN m.said_at <> '' THEN m.said_at ELSE m.created_at END) DESC
		LIMIT ?`, fromISO, toISO, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup decisions: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var quote, author, source string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &quote, &author, &source); err != nil {
			return nil, fmt.Errorf("scanning catchup decision: %w", err)
		}
		it.Area = "decisions"
		it.Meta = fmt.Sprintf("%s · %s: %q", source, author, quote)
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupInbox returns actionable, still-open inbox items created inside
// the window: the things that arrived for the owner while away.
func (db *DB) ListCatchupInbox(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT i.id, i.trigger_type, i.snippet, i.channel_id, i.sender_user_id,
		       COALESCE(NULLIF(u.display_name, ''), NULLIF(u.real_name, ''), u.name, i.sender_user_id),
		       COALESCE(c.name, '')
		FROM inbox_items i
		LEFT JOIN users u ON u.id = i.sender_user_id
		LEFT JOIN channels c ON c.id = i.channel_id
		WHERE i.item_class = 'actionable' AND i.status IN ('pending','snoozed')
		  AND i.created_at > ? AND i.created_at <= ?
		ORDER BY CASE i.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, i.created_at DESC
		LIMIT ?`, unixToISO(from), unixToISO(to), limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup inbox: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var sender, channel string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &it.ChannelID, &it.SenderID, &sender, &channel); err != nil {
			return nil, fmt.Errorf("scanning catchup inbox item: %w", err)
		}
		it.Area = "inbox"
		it.Meta = "from " + sender
		if channel != "" {
			it.Meta += " in #" + channel
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupTracks returns non-dismissed tracks updated inside the window.
func (db *DB) ListCatchupTracks(from, to float64, limit int) ([]CatchupItem, error) {
	rows, err := db.Query(`
		SELECT id, text, substr(context, 1, 280), priority, ownership
		FROM tracks
		WHERE dismissed_at = '' AND updated_at > ? AND updated_at <= ?
		ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, updated_at DESC
		LIMIT ?`, unixToISO(from), unixToISO(to), limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup tracks: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var priority, ownership string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &priority, &ownership); err != nil {
			return nil, fmt.Errorf("scanning catchup track: %w", err)
		}
		it.Area = "tracks"
		it.Meta = priority + " · " + ownership
		out = append(out, it)
	}
	return out, rows.Err()
}

// ListCatchupTargets returns open targets due inside the window or already
// overdue at its end. targets.due_date is "YYYY-MM-DDTHH:MM" local, or "".
func (db *DB) ListCatchupTargets(from, to float64, limit int) ([]CatchupItem, error) {
	fromLocal := time.Unix(int64(from), 0).Local().Format("2006-01-02T15:04")
	toLocal := time.Unix(int64(to), 0).Local().Format("2006-01-02T15:04")
	rows, err := db.Query(`
		SELECT id, text, intent, due_date, status, priority
		FROM targets
		WHERE status NOT IN ('done','dismissed') AND due_date <> ''
		  AND ((due_date > ? AND due_date <= ?) OR due_date < ?)
		ORDER BY due_date ASC LIMIT ?`, fromLocal, toLocal, fromLocal, limit)
	if err != nil {
		return nil, fmt.Errorf("listing catchup targets: %w", err)
	}
	defer rows.Close()
	var out []CatchupItem
	for rows.Next() {
		var it CatchupItem
		var due, status, priority string
		if err := rows.Scan(&it.ID, &it.Title, &it.Body, &due, &status, &priority); err != nil {
			return nil, fmt.Errorf("scanning catchup target: %w", err)
		}
		it.Area = "targets"
		it.Meta = fmt.Sprintf("due %s · %s · %s", due, status, priority)
		out = append(out, it)
	}
	return out, rows.Err()
}

// CatchupCoverage reports how far into the window the summaries actually reach:
// the latest channel-digest period_to and the latest stream-digest period_to
// inside [from, to] (0 when none).
func (db *DB) CatchupCoverage(from, to float64) (slackTo, streamsTo float64, err error) {
	var s sql.NullFloat64
	if err = db.QueryRow(`SELECT MAX(period_to) FROM digests WHERE type='channel' AND period_to > ? AND period_to <= ?`, from, to).Scan(&s); err != nil {
		return 0, 0, fmt.Errorf("catchup slack coverage: %w", err)
	}
	var st sql.NullString
	if err = db.QueryRow(`SELECT MAX(period_to) FROM stream_digests WHERE period_to > ? AND period_to <= ?`, unixToISO(from), unixToISO(to)).Scan(&st); err != nil {
		return 0, 0, fmt.Errorf("catchup streams coverage: %w", err)
	}
	if st.Valid {
		if ts, perr := time.Parse("2006-01-02T15:04:05Z", st.String); perr == nil {
			streamsTo = float64(ts.Unix())
		}
	}
	return s.Float64, streamsTo, nil
}

// FetchItemScopeHints resolves the Slack ids the learning interpreter builds
// scope keys from. Only digests (channel) and inbox (channel + sender) carry
// hints; every other recap area yields none. Unknown areas are an error.
func (db *DB) FetchItemScopeHints(area string, id int) (channelID, senderID string, err error) {
	switch area {
	case "digests":
		err = db.QueryRow(`SELECT channel_id FROM digests WHERE id=?`, id).Scan(&channelID)
	case "inbox":
		err = db.QueryRow(`SELECT channel_id, sender_user_id FROM inbox_items WHERE id=?`, id).Scan(&channelID, &senderID)
	case "streams", "recaps", "transcripts", "decisions", "tracks", "targets":
		return "", "", nil
	default:
		return "", "", fmt.Errorf("fetching scope hints: unknown area %q", area)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", nil
	}
	if err != nil {
		return "", "", fmt.Errorf("fetching %s#%d scope hints: %w", area, id, err)
	}
	return channelID, senderID, nil
}
```

Delete `UnreadItem`, `ageCutoffUnix`, `GetUnread*`, `FetchItemSnippet`.

- [ ] **Step 4: Run** — `go test ./internal/db/` → PASS (whole package). Fix any `digests_test.go` reference to removed functions.

- [ ] **Step 5: Commit** — `feat(catchup): window gather queries, coverage, scope hints`.

---

### Task 4: Config

**Files:**
- Modify: `internal/config/config.go` (`CatchupConfig`, `CatchupCaps`, defaults ~line 445)
- Modify: `internal/config/config_test.go:76`

- [ ] **Step 1: Failing test** — replace the assertion at line 76:

```go
assert.Equal(t, CatchupCaps{Digests: 150, Streams: 40, Meetings: 20, Decisions: 40, Inbox: 120, Tracks: 80, Targets: 40}, cfg.Catchup.Caps)
assert.Equal(t, 120000, cfg.Catchup.MaxPromptChars)
```

- [ ] **Step 2: Run** — `go test ./internal/config/` → FAIL.

- [ ] **Step 3: Implement**

```go
// CatchupConfig controls the on-demand absence recap.
type CatchupConfig struct {
	Caps           CatchupCaps `mapstructure:"caps"`
	MaxPromptChars int         `mapstructure:"max_prompt_chars"` // whole compose user message budget (default: 120000)
}

// CatchupCaps bounds how many window items per area feed the compose call.
type CatchupCaps struct {
	Digests   int `mapstructure:"digests"`
	Streams   int `mapstructure:"streams"`
	Meetings  int `mapstructure:"meetings"`
	Decisions int `mapstructure:"decisions"`
	Inbox     int `mapstructure:"inbox"`
	Tracks    int `mapstructure:"tracks"`
	Targets   int `mapstructure:"targets"`
}
```
Defaults: remove `catchup.max_age_days` and `catchup.caps.briefings`; set `catchup.caps.streams 40`, `meetings 20`, `decisions 40`, `targets 40`, `catchup.max_prompt_chars 120000`. Grep `MaxAgeDays`/`Briefings` under `internal/config` and fix any other reference.

- [ ] **Step 4: Run** — `go test ./internal/config/` → PASS.
- [ ] **Step 5: Commit** — `feat(catchup): config — window caps + prompt budget`.

---

### Task 5: Prompt registration + tier routing

**Files:**
- Modify: `internal/prompts/store.go` (const block), `internal/prompts/defaults.go` (`Defaults`, `AllIDs`, `DefaultVersions`, descriptions map, template const)
- Modify: `internal/prompts/defaults_extra_test.go`
- Modify: `internal/digest/models.go`, `internal/digest/models_test.go`

**Interfaces (produces):** `prompts.CatchupCompose = "catchup.compose"`, `prompts.Defaults[CatchupCompose]` — a template with exactly one `%s` (the language directive) and no data marker (catchup splits system/user itself).

- [ ] **Step 1: Failing tests**

`internal/prompts/defaults_extra_test.go`:
```go
func TestCatchupComposePromptRegistered(t *testing.T) {
	tmpl, ok := Defaults[CatchupCompose]
	require.True(t, ok)
	assert.Contains(t, tmpl, `"needs_you"`)
	assert.Contains(t, AllIDs, CatchupCompose)
	assert.Equal(t, 1, DefaultVersions[CatchupCompose])
	assert.Equal(t, 1, strings.Count(tmpl, "%s"), "one placeholder: the language directive")
}
```
`internal/digest/models_test.go`: remove `"catchup.peel"` from the light list; add a strong assertion:
```go
assert.Equal(t, TierStrong, TierForSource("catchup.compose"))
assert.Equal(t, TierLight, TierForSource("catchup.learn"))
```
(if `catchup.learn` was not in the light list before, add it there now — the learn interpreter is a classification task.)

- [ ] **Step 2: Run** — `go test ./internal/prompts/ ./internal/digest/ -run 'Catchup|TierForSource'` → FAIL.

- [ ] **Step 3: Implement** — in `store.go` add `CatchupCompose = "catchup.compose"`. In `defaults.go` add to `Defaults`, `AllIDs`, `DefaultVersions: 1`, description `"Catch-Up: compose one absence recap from the window's digests, meetings, decisions and owner items (strong tier; code validates refs)"`, and the template:

```go
// defaultCatchupCompose is the strong-tier absence-recap composer
// (catchup.compose). Arg: the language directive. Catch-Up builds the user
// message itself (window header, profile, learned rules, tagged sections) and
// validates every ref the model cites against the gathered set (CATCHUP-04).
const defaultCatchupCompose = `%s

You are the chief-of-staff writing the recap the operator reads after being away. You receive everything that happened inside one time window, grouped by source, every line tagged with its source id like [digests#12] or [inbox#7].

Write ONE recap with these parts:
- tldr: 3-5 sentences — the most consequential things first, in plain words.
- topics: what happened in the company, one entry per real-world story (a story may span several sources). Each has a concrete title, a 2-4 sentence narrative, a priority ("high" | "medium" | "low" — consequence for the operator, not volume), and refs: the tags of the lines it was built from.
- decisions: choices that were made, each with its refs.
- meetings: meetings that took place, each with a short summary and its refs.
- needs_you: what waits for the operator personally (mentions, DMs, emails, tracks, target deadlines). kind is one of "mention" | "dm" | "email" | "track" | "target_due". Personal items belong here, never in topics.

Rules:
- Use ONLY facts present in the input. Never invent names, numbers, dates or decisions.
- refs: copy tags EXACTLY as they appear in the input ([area#id]). A tag not present in the input is discarded by the code; an entry with no valid refs is dropped entirely. Every topic, decision, meeting and needs_you entry MUST cite at least one tag.
- Ignore routine noise (bot alerts, status pings, scheduling chatter) unless it changed something.
- If an OPERATOR CORRECTION block is present, it is authoritative: apply it over your own judgement.

Respond with ONLY a JSON object, no markdown fences:
{"tldr":"...","topics":[{"title":"...","narrative":"...","priority":"high","refs":["digests#12","inbox#7"]}],"decisions":[{"text":"...","refs":["decisions#3"]}],"meetings":[{"title":"...","summary":"...","refs":["recaps#5"]}],"needs_you":[{"text":"...","kind":"mention","refs":["inbox#7"]}]}`
```

In `digest/models.go` `TierForSource`: remove `"catchup.peel"`, add `"catchup.learn"` to the light case (leave `catchup.compose` to fall to strong).

- [ ] **Step 4: Run** — `go test ./internal/prompts/ ./internal/digest/` → PASS.
- [ ] **Step 5: Commit** — `feat(catchup): register catchup.compose prompt, retire peel/expand tiers`.

---

### Task 6: Window resolution (`internal/catchup/window.go`)

**Files:**
- Create: `internal/catchup/window.go`, `internal/catchup/window_test.go`

**Interfaces (produces):**

```go
type WindowSpec struct {
	Preset string    // "", "today", "yesterday", "3d", "week"
	From   time.Time // custom start (zero = not custom)
	To     time.Time // custom end (zero = now)
}
type Window struct {
	From, To time.Time
	Source   string // "auto" | "preset:<name>" | "custom"
}
const maxWindowDays = 31
var ErrWindow = errors.New("invalid catch-up window")
func ResolveWindow(spec WindowSpec, now time.Time, lastAckTo float64) (Window, error)
func ParseWindowTime(s string, loc *time.Location) (time.Time, error) // "2006-01-02" → local midnight, else RFC3339
```

- [ ] **Step 1: Failing tests** (`window_test.go`, package `catchup`)

```go
func TestResolveWindow_AutoFromLastAck(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	w, err := ResolveWindow(WindowSpec{}, now, float64(now.Add(-30*time.Hour).Unix()))
	require.NoError(t, err)
	assert.Equal(t, now.Add(-30*time.Hour).Unix(), w.From.Unix())
	assert.Equal(t, now, w.To)
	assert.Equal(t, "auto", w.Source)
}

func TestResolveWindow_AutoFallback24h(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	w, err := ResolveWindow(WindowSpec{}, now, 0)
	require.NoError(t, err)
	assert.Equal(t, now.Add(-24*time.Hour), w.From)
}

func TestResolveWindow_Presets(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	midnight := time.Date(2026, 9, 4, 0, 0, 0, 0, time.Local)
	cases := map[string][2]time.Time{
		"today":     {midnight, now},
		"yesterday": {midnight.AddDate(0, 0, -1), midnight},
		"3d":        {now.Add(-72 * time.Hour), now},
		"week":      {now.Add(-7 * 24 * time.Hour), now},
	}
	for preset, want := range cases {
		w, err := ResolveWindow(WindowSpec{Preset: preset}, now, 12345)
		require.NoError(t, err, preset)
		assert.Equal(t, want[0], w.From, preset)
		assert.Equal(t, want[1], w.To, preset)
		assert.Equal(t, "preset:"+preset, w.Source)
	}
	_, err := ResolveWindow(WindowSpec{Preset: "fortnight"}, now, 0)
	assert.ErrorIs(t, err, ErrWindow)
}

func TestResolveWindow_CustomAndValidation(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	from := now.Add(-48 * time.Hour)
	w, err := ResolveWindow(WindowSpec{From: from}, now, 0)
	require.NoError(t, err)
	assert.Equal(t, from, w.From)
	assert.Equal(t, now, w.To, "custom To defaults to now")
	assert.Equal(t, "custom", w.Source)

	_, err = ResolveWindow(WindowSpec{From: now, To: now.Add(-time.Hour)}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "from must precede to")
	_, err = ResolveWindow(WindowSpec{From: now.AddDate(0, 0, -40)}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "31-day cap")
	_, err = ResolveWindow(WindowSpec{Preset: "today", From: from}, now, 0)
	assert.ErrorIs(t, err, ErrWindow, "preset and custom are exclusive")
}

func TestParseWindowTime(t *testing.T) {
	d, err := ParseWindowTime("2026-09-03", time.Local)
	require.NoError(t, err)
	assert.Equal(t, time.Date(2026, 9, 3, 0, 0, 0, 0, time.Local), d)
	r, err := ParseWindowTime("2026-09-03T10:15:00Z", time.Local)
	require.NoError(t, err)
	assert.Equal(t, int64(1788516900), r.Unix())
	_, err = ParseWindowTime("yesterday", time.Local)
	assert.Error(t, err)
}
```
(Recompute the RFC3339 expectation with `date -u -j -f '%Y-%m-%dT%H:%M:%SZ' 2026-09-03T10:15:00Z +%s` if the literal above is off.)

- [ ] **Step 2: Run** — `go test ./internal/catchup/ -run 'ResolveWindow|ParseWindowTime'` → FAIL (the package will not compile yet because pipeline.go still references deleted db functions — temporarily move `pipeline.go`, `learn.go`, `prompt.go`, `types.go` and their tests to `*.go.old`? No: instead do Tasks 6–8 in one compile unit if needed. Preferred: delete the old `pipeline.go`/`prompt.go`/`types.go`/`learn.go` and their `_test.go` files at the START of this task so the package compiles with only `window.go`; Tasks 7–9 rebuild them.)

- [ ] **Step 3: Implement `window.go`**

```go
package catchup

import (
	"errors"
	"fmt"
	"time"
)

// maxWindowDays bounds a recap window; a longer one is rejected, not clamped.
const maxWindowDays = 31

// ErrWindow is returned (wrapped) for every invalid WindowSpec.
var ErrWindow = errors.New("invalid catch-up window")

// WindowSpec is the operator's window request. Empty = auto.
type WindowSpec struct {
	Preset string
	From   time.Time
	To     time.Time
}

// Window is a resolved [From, To] plus how it was chosen.
type Window struct {
	From, To time.Time
	Source   string
}

// ResolveWindow turns a spec into a concrete window. Auto: from the last
// acknowledged recap's period_to (lastAckTo, unix seconds; 0 = none → now-24h)
// to now. Presets use now's location for day boundaries.
func ResolveWindow(spec WindowSpec, now time.Time, lastAckTo float64) (Window, error) {
	custom := !spec.From.IsZero() || !spec.To.IsZero()
	if spec.Preset != "" && custom {
		return Window{}, fmt.Errorf("%w: --preset and --from/--to are exclusive", ErrWindow)
	}
	var w Window
	switch {
	case spec.Preset != "":
		w.Source = "preset:" + spec.Preset
		w.To = now
		midnight := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
		switch spec.Preset {
		case "today":
			w.From = midnight
		case "yesterday":
			w.From, w.To = midnight.AddDate(0, 0, -1), midnight
		case "3d":
			w.From = now.Add(-72 * time.Hour)
		case "week":
			w.From = now.Add(-7 * 24 * time.Hour)
		default:
			return Window{}, fmt.Errorf("%w: unknown preset %q", ErrWindow, spec.Preset)
		}
	case custom:
		w.Source = "custom"
		w.From, w.To = spec.From, spec.To
		if w.To.IsZero() {
			w.To = now
		}
		if w.From.IsZero() {
			return Window{}, fmt.Errorf("%w: --from is required with --to", ErrWindow)
		}
	default:
		w.Source = "auto"
		w.To = now
		if lastAckTo > 0 {
			w.From = time.Unix(int64(lastAckTo), 0).In(now.Location())
		} else {
			w.From = now.Add(-24 * time.Hour)
		}
	}
	if !w.From.Before(w.To) {
		return Window{}, fmt.Errorf("%w: from must precede to", ErrWindow)
	}
	if w.To.Sub(w.From) > maxWindowDays*24*time.Hour {
		return Window{}, fmt.Errorf("%w: longer than %d days", ErrWindow, maxWindowDays)
	}
	return w, nil
}

// ParseWindowTime accepts "2006-01-02" (local midnight in loc) or RFC 3339.
func ParseWindowTime(s string, loc *time.Location) (time.Time, error) {
	if d, err := time.ParseInLocation("2006-01-02", s, loc); err == nil {
		return d, nil
	}
	if ts, err := time.Parse(time.RFC3339, s); err == nil {
		return ts, nil
	}
	return time.Time{}, fmt.Errorf("%w: %q is neither YYYY-MM-DD nor RFC 3339", ErrWindow, s)
}
```

- [ ] **Step 4: Run** → PASS. (Only `window_test.go` + `testmain_test.go` exist in the package now.)
- [ ] **Step 5: Commit** — `feat(catchup): window resolution (auto / presets / custom)`.

---

### Task 7: Compose result types + validation (`internal/catchup/types.go`)

**Files:**
- Create (replacing the deleted old file): `internal/catchup/types.go`, `internal/catchup/types_test.go`

**Interfaces (produces):**

```go
// Exported so cmd/ can decode body_json for `catchup show`.
type Body struct {
	Topics    []Topic        `json:"topics"`
	Decisions []Entry        `json:"decisions"`
	Meetings  []MeetingEntry `json:"meetings"`
	NeedsYou  []NeedEntry    `json:"needs_you"`
}
type Topic struct { Title, Narrative, Priority string; Refs []db.CatchupRef }           // json tags: title, narrative, priority, refs
type Entry struct { Text string; Refs []db.CatchupRef }                                  // text, refs
type MeetingEntry struct { Title, Summary string; Refs []db.CatchupRef }                 // title, summary, refs
type NeedEntry struct { Text, Kind string; Refs []db.CatchupRef }                        // text, kind, refs
type Coverage struct { SlackTo, StreamsTo float64; Meetings int; Topup, TopupError string } // json: slack_to, streams_to, meetings, topup, topup_error
func (b Body) IsEmpty() bool

// model output (unexported): refs are "area#id" strings
type composeResult struct { TLDR string; Topics []rawTopic; Decisions []rawEntry; Meetings []rawMeeting; NeedsYou []rawNeed }
func parseCompose(raw string) (composeResult, error)
func validateBody(res composeResult, known map[refKey]db.CatchupItem) (Body, int) // (body, rejected)
func parseRefTag(s string) (refKey, bool)  // "digests#12" → {digests,12}
type refKey struct{ area string; id int }
func normalizePriority(p, fallback string) string  // high|medium|low
func normalizeKind(k string) string                // mention|dm|email|track|target_due, fallback mention
func trimToJSONObject(raw string) string           // kept from the old file
// learn types kept from the old file: learnResult, learnRule, parseLearn
```

- [ ] **Step 1: Failing tests** (`types_test.go`)

```go
func TestParseCompose_TolerantOfFences(t *testing.T) {
	raw := "```json\n{\"tldr\":\"x\",\"topics\":[{\"title\":\"T\",\"narrative\":\"n\",\"priority\":\"high\",\"refs\":[\"digests#1\"]}]}\n```"
	res, err := parseCompose(raw)
	require.NoError(t, err)
	assert.Equal(t, "x", res.TLDR)
	require.Len(t, res.Topics, 1)
	assert.Equal(t, []string{"digests#1"}, res.Topics[0].Refs)
}

func TestValidateBody_DropsInventedRefsAndEmptyEntries(t *testing.T) {
	known := map[refKey]db.CatchupItem{
		{"digests", 1}: {Area: "digests", ID: 1, Title: "#eng"},
		{"inbox", 7}:   {Area: "inbox", ID: 7, Title: "mention"},
	}
	res := composeResult{
		Topics: []rawTopic{
			{Title: "ok", Narrative: "n", Priority: "urgent", Refs: []string{"digests#1", "digests#999", "garbage"}},
			{Title: "ghost", Narrative: "n", Priority: "low", Refs: []string{"tracks#5"}},
		},
		Decisions: []rawEntry{{Text: "d", Refs: []string{"decisions#2"}}},
		NeedsYou:  []rawNeed{{Text: "ping", Kind: "poke", Refs: []string{"inbox#7"}}},
	}
	body, rejected := validateBody(res, known)
	require.Len(t, body.Topics, 1)
	assert.Equal(t, "medium", body.Topics[0].Priority, "unknown priority → medium")
	assert.Equal(t, []db.CatchupRef{{Area: "digests", ID: 1, Label: "#eng"}}, body.Topics[0].Refs, "label filled from the gathered item")
	assert.Empty(t, body.Decisions, "entry with no valid refs is dropped")
	require.Len(t, body.NeedsYou, 1)
	assert.Equal(t, "mention", body.NeedsYou[0].Kind, "unknown kind → mention")
	assert.Equal(t, 4, rejected, "digests#999, garbage, tracks#5, decisions#2")
}

func TestBodyIsEmptyAndRoundTrip(t *testing.T) {
	assert.True(t, Body{}.IsEmpty())
	b := Body{Topics: []Topic{{Title: "t", Refs: []db.CatchupRef{{Area: "digests", ID: 1}}}}}
	assert.False(t, b.IsEmpty())
	raw, err := json.Marshal(b)
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"needs_you":[]`, "arrays marshal as [] not null")
	var back Body
	require.NoError(t, json.Unmarshal(raw, &back))
	assert.Equal(t, b.Topics[0].Title, back.Topics[0].Title)
}

func TestParseRefTag(t *testing.T) {
	k, ok := parseRefTag("[inbox#12]")
	assert.True(t, ok)
	assert.Equal(t, refKey{"inbox", 12}, k)
	_, ok = parseRefTag("inbox#x")
	assert.False(t, ok)
	_, ok = parseRefTag("briefings#1")
	assert.False(t, ok, "not a recap area")
}
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement `types.go`**

```go
// Package catchup builds an on-demand absence recap: one persisted document per
// time window composed from the summaries Watchtower already keeps (channel
// digests, Gmail/Jira stream digests, meeting recaps, the decisions ledger) plus
// the items that arrived for the owner in that window (inbox, tracks, targets).
package catchup

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"watchtower/internal/db"
)

// Body is the validated, persisted recap (catchup_recaps.body_json).
type Body struct {
	Topics    []Topic        `json:"topics"`
	Decisions []Entry        `json:"decisions"`
	Meetings  []MeetingEntry `json:"meetings"`
	NeedsYou  []NeedEntry    `json:"needs_you"`
}

// Topic is one "what happened" story with its provenance.
type Topic struct {
	Title     string          `json:"title"`
	Narrative string          `json:"narrative"`
	Priority  string          `json:"priority"`
	Refs      []db.CatchupRef `json:"refs"`
}

// Entry is a decision line with provenance.
type Entry struct {
	Text string          `json:"text"`
	Refs []db.CatchupRef `json:"refs"`
}

// MeetingEntry is one meeting that took place in the window.
type MeetingEntry struct {
	Title   string          `json:"title"`
	Summary string          `json:"summary"`
	Refs    []db.CatchupRef `json:"refs"`
}

// NeedEntry is something waiting for the owner personally.
type NeedEntry struct {
	Text string          `json:"text"`
	Kind string          `json:"kind"`
	Refs []db.CatchupRef `json:"refs"`
}

// Coverage records how far the summaries reached and whether the top-up ran
// (catchup_recaps.coverage_json).
type Coverage struct {
	SlackTo    float64 `json:"slack_to"`
	StreamsTo  float64 `json:"streams_to"`
	Meetings   int     `json:"meetings"`
	Topup      string  `json:"topup"` // ok | skipped | failed
	TopupError string  `json:"topup_error,omitempty"`
}

// IsEmpty reports whether the recap has nothing to show.
func (b Body) IsEmpty() bool {
	return len(b.Topics) == 0 && len(b.Decisions) == 0 && len(b.Meetings) == 0 && len(b.NeedsYou) == 0
}

// MarshalJSON guarantees "[]" (never null) for every list so the Swift decoder
// and `catchup show` never meet a null array.
func (b Body) MarshalJSON() ([]byte, error) {
	type alias Body
	a := alias(b)
	if a.Topics == nil {
		a.Topics = []Topic{}
	}
	if a.Decisions == nil {
		a.Decisions = []Entry{}
	}
	if a.Meetings == nil {
		a.Meetings = []MeetingEntry{}
	}
	if a.NeedsYou == nil {
		a.NeedsYou = []NeedEntry{}
	}
	return json.Marshal(a)
}

// --- model output (refs as "area#id" tags) ---

type rawTopic struct {
	Title     string   `json:"title"`
	Narrative string   `json:"narrative"`
	Priority  string   `json:"priority"`
	Refs      []string `json:"refs"`
}
type rawEntry struct {
	Text string   `json:"text"`
	Refs []string `json:"refs"`
}
type rawMeeting struct {
	Title   string   `json:"title"`
	Summary string   `json:"summary"`
	Refs    []string `json:"refs"`
}
type rawNeed struct {
	Text string   `json:"text"`
	Kind string   `json:"kind"`
	Refs []string `json:"refs"`
}
type composeResult struct {
	TLDR      string       `json:"tldr"`
	Topics    []rawTopic   `json:"topics"`
	Decisions []rawEntry   `json:"decisions"`
	Meetings  []rawMeeting `json:"meetings"`
	NeedsYou  []rawNeed    `json:"needs_you"`
}

// refKey indexes gathered items by (area, id).
type refKey struct {
	area string
	id   int
}

// recapAreas is the closed set of ref areas (spec §4).
var recapAreas = map[string]bool{
	"digests": true, "streams": true, "recaps": true, "transcripts": true,
	"decisions": true, "inbox": true, "tracks": true, "targets": true,
}

// parseCompose extracts the compose object, tolerating markdown fences.
func parseCompose(raw string) (composeResult, error) {
	var out composeResult
	if err := json.Unmarshal([]byte(trimToJSONObject(raw)), &out); err != nil {
		return composeResult{}, fmt.Errorf("parsing catchup compose output: %w", err)
	}
	return out, nil
}

// parseRefTag decodes "area#id" (optionally bracketed) into a refKey.
func parseRefTag(s string) (refKey, bool) {
	s = strings.Trim(strings.TrimSpace(s), "[]")
	area, idStr, ok := strings.Cut(s, "#")
	if !ok || !recapAreas[area] {
		return refKey{}, false
	}
	id, err := strconv.Atoi(idStr)
	if err != nil || id <= 0 {
		return refKey{}, false
	}
	return refKey{area: area, id: id}, true
}

// validateBody keeps only refs present in the gathered set, filling labels from
// the gathered item, drops entries left with no valid refs, and normalises the
// enum fields. rejected counts every dropped ref (CATCHUP-04).
func validateBody(res composeResult, known map[refKey]db.CatchupItem) (Body, int) {
	rejected := 0
	resolve := func(tags []string) []db.CatchupRef {
		var refs []db.CatchupRef
		for _, tag := range tags {
			k, ok := parseRefTag(tag)
			if !ok {
				rejected++
				continue
			}
			item, ok := known[k]
			if !ok {
				rejected++
				continue
			}
			refs = append(refs, db.CatchupRef{Area: k.area, ID: k.id, Label: item.Title})
		}
		return refs
	}
	var body Body
	for _, t := range res.Topics {
		if refs := resolve(t.Refs); len(refs) > 0 {
			body.Topics = append(body.Topics, Topic{Title: t.Title, Narrative: t.Narrative, Priority: normalizePriority(t.Priority, "medium"), Refs: refs})
		}
	}
	for _, d := range res.Decisions {
		if refs := resolve(d.Refs); len(refs) > 0 {
			body.Decisions = append(body.Decisions, Entry{Text: d.Text, Refs: refs})
		}
	}
	for _, m := range res.Meetings {
		if refs := resolve(m.Refs); len(refs) > 0 {
			body.Meetings = append(body.Meetings, MeetingEntry{Title: m.Title, Summary: m.Summary, Refs: refs})
		}
	}
	for _, n := range res.NeedsYou {
		if refs := resolve(n.Refs); len(refs) > 0 {
			body.NeedsYou = append(body.NeedsYou, NeedEntry{Text: n.Text, Kind: normalizeKind(n.Kind), Refs: refs})
		}
	}
	return body, rejected
}

func normalizePriority(p, fallback string) string {
	switch p {
	case "high", "medium", "low":
		return p
	}
	return fallback
}

func normalizeKind(k string) string {
	switch k {
	case "mention", "dm", "email", "track", "target_due":
		return k
	}
	return "mention"
}

// trimToJSONObject narrows a model response to the outermost {...}.
func trimToJSONObject(raw string) string {
	s := raw
	if i := strings.Index(s, "{"); i >= 0 {
		if j := strings.LastIndex(s, "}"); j >= i {
			s = s[i : j+1]
		}
	}
	return s
}
```
Plus, copied verbatim from the old `types.go`: `learnResult`, `learnRule`, `parseLearn`.

- [ ] **Step 4: Run** — `go test ./internal/catchup/` → PASS.
- [ ] **Step 5: Commit** — `feat(catchup): compose result types + ref validation (CATCHUP-04 core)`.

---

### Task 8: Prompt builder with budget (`internal/catchup/prompt.go`)

**Files:**
- Create: `internal/catchup/prompt.go`, `internal/catchup/prompt_test.go`

**Interfaces (produces):**

```go
type gathered struct {
	Digests, Streams, Meetings, Decisions, Inbox, Tracks, Targets []db.CatchupItem
	byRef map[refKey]db.CatchupItem
}
func (g gathered) isEmpty() bool
func (g *gathered) index()                       // fills byRef from every list
type promptInput struct {
	Window     Window
	Profile    string // workspace.secretary_profile
	Prefs      string // LearnedPreferencesBlock output
	Correction string // regen only
}
func buildComposeUserMessage(in promptInput, g gathered, budget int) (string, gathered) // budget 0 = unlimited; returns the gathered actually rendered (indexed)
const learnSystemPrompt = `...`                   // moved from the old prompt.go, area→pipeline table updated (below)
func buildLearnUserMessage(topic Topic, refs []learnRef, rating int, comment string) string
type learnRef struct{ Area, ChannelID, SenderID, Label string }
```

Per-item body caps (spec §5.3): digests 900, streams 600, meetings 800, decisions 300, inbox 280, tracks 280, targets 200 — truncate with `…`. Section order and exact headers:

```
WINDOW: <from local "Mon 2 Jan 15:04"> → <to local>
OPERATOR PROFILE:
<profile or "(none)">

<prefs block, if any>

OPERATOR CORRECTION: <text>   (only when non-empty)

=== SLACK DIGESTS (n) ===
[digests#12] #eng — 41 messages · to Thu 17:40
  <body lines, each indented two spaces>

=== EMAIL / JIRA STREAMS (n) ===
=== MEETINGS (n) ===
=== DECISIONS (n) ===
=== FOR YOU — INBOX (n) ===
=== TRACKS UPDATED (n) ===
=== TARGETS DUE (n) ===
```
Every item line is `[area#id] Title — Meta` then the indented body. Empty sections are omitted. Budget loop: render; while `budget > 0 && len(msg) > budget`, drop the LAST item of the first non-empty list in the order Streams → Tracks → Decisions → Digests and re-render; stop when those four are all empty.

- [ ] **Step 1: Failing tests** (`prompt_test.go`)

```go
func TestBuildComposeUserMessage_SectionsAndTags(t *testing.T) {
	now := time.Date(2026, 9, 4, 18, 30, 0, 0, time.Local)
	g := gathered{
		Digests: []db.CatchupItem{{Area: "digests", ID: 12, Title: "#eng", Body: "shipped\n- Deploy: v2", Meta: "41 messages · to Thu 17:40"}},
		Inbox:   []db.CatchupItem{{Area: "inbox", ID: 7, Title: "mention", Body: "can you review?", Meta: "from Ann in #eng"}},
	}
	msg, used := buildComposeUserMessage(promptInput{Window: Window{From: now.Add(-time.Hour), To: now}, Profile: "CTO", Prefs: "PREFS", Correction: "shorter"}, g, 0)
	assert.Contains(t, msg, "OPERATOR PROFILE:\nCTO")
	assert.Contains(t, msg, "PREFS")
	assert.Contains(t, msg, "OPERATOR CORRECTION: shorter")
	assert.Contains(t, msg, "=== SLACK DIGESTS (1) ===\n[digests#12] #eng — 41 messages · to Thu 17:40\n  shipped\n  - Deploy: v2")
	assert.Contains(t, msg, "=== FOR YOU — INBOX (1) ===\n[inbox#7] mention — from Ann in #eng\n  can you review?")
	assert.NotContains(t, msg, "=== MEETINGS", "empty sections omitted")
	assert.Len(t, used.Digests, 1)
	assert.Len(t, used.Inbox, 1)
	_, ok := used.byRef[refKey{"inbox", 7}]
	assert.True(t, ok, "returned gathered is indexed")
}

func TestBuildComposeUserMessage_BudgetTrimOrder(t *testing.T) {
	big := strings.Repeat("x", 200)
	item := func(area string, id int) db.CatchupItem { return db.CatchupItem{Area: area, ID: id, Title: "t", Body: big} }
	g := gathered{
		Digests:   []db.CatchupItem{item("digests", 1), item("digests", 2)},
		Streams:   []db.CatchupItem{item("streams", 1), item("streams", 2)},
		Decisions: []db.CatchupItem{item("decisions", 1)},
		Tracks:    []db.CatchupItem{item("tracks", 1)},
		Inbox:     []db.CatchupItem{item("inbox", 1)},
		Targets:   []db.CatchupItem{item("targets", 1)},
		Meetings:  []db.CatchupItem{item("recaps", 1)},
	}
	full, _ := buildComposeUserMessage(promptInput{}, g, 0)
	// One dropped item shrinks the message by ~200 body chars + its line; a
	// budget of full-550 needs three drops: streams#2, streams#1, tracks#1.
	budget := len(full) - 550
	msg, used := buildComposeUserMessage(promptInput{}, g, budget)
	assert.LessOrEqual(t, len(msg), budget)
	assert.Empty(t, used.Streams, "streams trimmed first")
	assert.Empty(t, used.Tracks, "then tracks")
	assert.Len(t, used.Decisions, 1)
	assert.Len(t, used.Digests, 2)
	assert.Len(t, used.Inbox, 1, "inbox never trimmed")
	assert.Len(t, used.Targets, 1)
	assert.Len(t, used.Meetings, 1)
}

func TestBuildComposeUserMessage_PerItemTrim(t *testing.T) {
	g := gathered{Inbox: []db.CatchupItem{{Area: "inbox", ID: 1, Title: "dm", Body: strings.Repeat("y", 1000)}}}
	msg, _ := buildComposeUserMessage(promptInput{}, g, 0)
	assert.Less(t, strings.Count(msg, "y"), 300)
	assert.Contains(t, msg, "…")
}

func TestBuildComposeUserMessage_UntrimmableOverBudgetStops(t *testing.T) {
	g := gathered{Inbox: []db.CatchupItem{{Area: "inbox", ID: 1, Title: "dm", Body: "hello"}}}
	msg, used := buildComposeUserMessage(promptInput{}, g, 10)
	assert.Greater(t, len(msg), 10, "nothing trimmable → message stays over budget, no infinite loop")
	assert.Len(t, used.Inbox, 1)
}
```
(If the trim-order test's budget arithmetic does not land on exactly "two streams + one track", adjust the `550` — the ORDER assertions are the point.)

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement `prompt.go`** — write `gathered`, `promptInput`, a `renderSection(b *strings.Builder, header string, items []db.CatchupItem, bodyCap int)` helper (writes `=== HEADER (n) ===`, one `[area#id] Title — Meta` line per item — omit ` — Meta` when Meta is empty — then each body line indented two spaces, truncating the body to `bodyCap` runes with `…`), `buildComposeUserMessage` with the render+trim loop, the learn prompt with this area table:

```
- area "digests"     → pipeline "digest"
- area "streams"     → pipeline "digest"   (Gmail/Jira stream digests)
- area "inbox"       → pipeline "inbox"
- area "tracks"      → pipeline "tracks"
- areas "recaps", "transcripts", "decisions", "targets" → no source pipeline; only "catchup" rules apply
A correction about how the recap itself grouped, titled, or phrased things belongs to pipeline "catchup".
```
and `buildLearnUserMessage` rendering `TOPIC:` / `NARRATIVE:` / `TOPIC PRIORITY:` / `SOURCE REFS (…)` / `OPERATOR RATING:` / `OPERATOR COMMENT:` as the old function did for a theme. Keep `oneLine`.

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(catchup): compose prompt builder with budget trimming`.

---

### Task 9: Pipeline — Run, top-up seam, Acknowledge

**Files:**
- Create: `internal/catchup/pipeline.go`, `internal/catchup/pipeline_test.go`

**Interfaces (produces):**

```go
// TopUp is the coverage top-up seam. The CLI wires the real digest + ideas
// pipelines; tests inject fakes.
type TopUp interface {
	ChannelDigests(ctx context.Context) error
	StreamDigests(ctx context.Context) error
}
type Pipeline struct {
	db *db.DB; cfg *config.Config; gen digest.Generator; logger *log.Logger
	promptStore *prompts.Store; topUp TopUp
	now func() time.Time // injectable clock
}
func New(database *db.DB, cfg *config.Config, gen digest.Generator, logger *log.Logger) *Pipeline
func (p *Pipeline) SetPromptStore(s *prompts.Store)
func (p *Pipeline) SetTopUp(t TopUp)
type RunOptions struct { Spec WindowSpec; RegenOfID int64; Correction string }
type RunResult struct { RecapID int64; Status string; Window Window; Coverage Coverage; RefsRejected int; Error string }
func (p *Pipeline) Run(ctx context.Context, opts RunOptions) (RunResult, error) // error only for an invalid window / no row created
func (p *Pipeline) Acknowledge(recapID int64) error
const topUpFreshness = 5 * time.Minute
```

Run algorithm:
1. `lastAck, _ := p.db.LastAcknowledgedCatchupTo()`. If `opts.RegenOfID > 0`: `GetCatchupRecap` (error → return) and use its window verbatim with `Source: "regen"`; else `ResolveWindow(opts.Spec, p.now(), lastAck)` (error → return).
2. `id := InsertCatchupRecap(from, to, opts.RegenOfID)` (error → return).
3. `cov := Coverage{Topup: "skipped"}`. If `opts.RegenOfID == 0 && p.topUp != nil && !to.Before(p.now().Add(-topUpFreshness))`: run `ChannelDigests` when `cfg.Digest.Enabled`, then `StreamDigests` when `cfg.Streams.Enabled` (always attempt the second even if the first failed); if neither gate is on keep "skipped"; first error → `Topup="failed"`, `TopupError=err.Error()`, logged; else `"ok"`.
4. Gather via the seven `ListCatchup*` calls with `cfg.Catchup.Caps`; a gather error fails the recap row (`FailCatchupRecap`) and returns `Status:"failed"`. `cov.SlackTo, cov.StreamsTo = CatchupCoverage(from,to)`; `cov.Meetings = len(g.Meetings)`.
5. Empty → `FinishCatchupRecap(id, "", marshal(Body{}), marshal(cov), "", 0, 0, 0)`; return `ready`.
6. `profile, _ := p.db.GetSecretaryProfile()`; `user, used := buildComposeUserMessage(promptInput{Window, profile, catchupPrefs(), opts.Correction}, g, cfg.Catchup.MaxPromptChars)`; `system := fmt.Sprintf(p.getPrompt(prompts.CatchupCompose), prompts.Directive(cfg.Digest.Language))`.
7. `raw, usage, _, err := p.gen.Generate(digest.WithSource(ctx, "catchup.compose"), system, user, "")`; on error or parse error → `FailCatchupRecap(id, marshal(cov), err.Error())`, return `RunResult{Status:"failed", Error: …}` with nil error.
8. `body, rejected := validateBody(res, used.byRef)`; `FinishCatchupRecap(id, res.TLDR, marshal(body), marshal(cov), usage model/tokens/cost)` — read the real `digest.Usage` field names first (`grep -n "type Usage struct" -A 8 internal/digest/*.go`); a nil usage means zeros.
9. Return `RunResult{RecapID: id, Status: "ready", Window: w, Coverage: cov, RefsRejected: rejected}`.

`Acknowledge(id)`: `r, err := GetCatchupRecap(id)` → `AcknowledgeCatchupWindow(id, r.PeriodFrom, r.PeriodTo)`.
`catchupPrefs()`: `ListLearnedRulesByPipeline("catchup", 20)` → `digest.LearnedPreferencesBlock`, best-effort. `getPrompt(id)`: store → `prompts.Defaults[id]`.

- [ ] **Step 1: Failing tests** (`pipeline_test.go`; keep `mockGenerator` + `testLogger` from the old file)

```go
type fakeTopUp struct {
	channelCalls, streamCalls int
	channelErr, streamErr     error
}
func (f *fakeTopUp) ChannelDigests(context.Context) error { f.channelCalls++; return f.channelErr }
func (f *fakeTopUp) StreamDigests(context.Context) error  { f.streamCalls++; return f.streamErr }

func newCfg() *config.Config {
	c := &config.Config{}
	c.Catchup.Caps = config.CatchupCaps{Digests: 40, Streams: 10, Meetings: 10, Decisions: 10, Inbox: 30, Tracks: 20, Targets: 10}
	c.Catchup.MaxPromptChars = 120000
	c.Digest.Enabled = true
	c.Streams.Enabled = true
	c.Digest.Language = "Russian"
	return c
}

func newPipeline(t *testing.T, gen *mockGenerator, top *fakeTopUp) (*Pipeline, *db.DB) {
	d := db.OpenTestDB(t)
	p := New(d, newCfg(), gen, testLogger())
	p.SetTopUp(top)
	p.now = func() time.Time { return time.Unix(2000, 0) }
	return p, d
}

func seedDigest(t *testing.T, d *db.DB, from, to float64) int64 {
	res, err := d.Exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('1:C1', ?, ?, 'channel', 'shipped v2')`, from, to)
	require.NoError(t, err)
	id, _ := res.LastInsertId()
	return id
}

const composeOK = `{"tldr":"quiet day","topics":[{"title":"Ship","narrative":"v2 shipped","priority":"high","refs":["digests#%d"]}],"decisions":[],"meetings":[],"needs_you":[]}`

func TestRun_EmptyWindowMakesNoAICall(t *testing.T) {
	gen := &mockGenerator{out: "{}"}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0), To: time.Unix(1500, 0)}})
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.False(t, gen.called)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "ready", r.Status)
	assert.Equal(t, "skipped", res.Coverage.Topup, "window in the past → no top-up")
}

func TestRun_ComposesAndPersists(t *testing.T) {
	top := &fakeTopUp{}
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, top)
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(composeOK, id)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}}) // To = now(2000) → fresh → top-up runs
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.Equal(t, 1, top.channelCalls)
	assert.Equal(t, 1, top.streamCalls)
	assert.Equal(t, "ok", res.Coverage.Topup)
	assert.Equal(t, 1900.0, res.Coverage.SlackTo)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "quiet day", r.TLDR)
	var body Body
	require.NoError(t, json.Unmarshal([]byte(r.BodyJSON), &body))
	require.Len(t, body.Topics, 1)
	assert.Equal(t, "1:C1", body.Topics[0].Refs[0].Label, "no channels row → the id is the title")
}

func TestRun_AutoWindowStartsAtLastAck(t *testing.T) {
	gen := &mockGenerator{out: `{"tldr":"","topics":[]}`}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	prev, _ := d.InsertCatchupRecap(100, 1700, 0)
	require.NoError(t, d.AcknowledgeCatchupWindow(prev, 100, 1700))
	res, err := p.Run(context.Background(), RunOptions{})
	require.NoError(t, err)
	assert.Equal(t, int64(1700), res.Window.From.Unix())
	assert.Equal(t, int64(2000), res.Window.To.Unix())
	assert.Equal(t, "auto", res.Window.Source)
}

// BEHAVIOR CATCHUP-02 — see docs/inventory/catchup.md
func TestCatchup02_ComposePromptCarriesLanguageDirective(t *testing.T) {
	var system string
	gen := &mockGenerator{fn: func(s, _ string) string { system = s; return `{"tldr":"","topics":[]}` }}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	_, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Contains(t, system, prompts.Directive("Russian"))
}

// BEHAVIOR CATCHUP-03 — see docs/inventory/catchup.md
func TestCatchup03_TopUpFailureStillProducesRecap(t *testing.T) {
	top := &fakeTopUp{channelErr: errors.New("digest lock held")}
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, top)
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(composeOK, id)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, "ready", res.Status)
	assert.Equal(t, "failed", res.Coverage.Topup)
	assert.Contains(t, res.Coverage.TopupError, "digest lock held")
	assert.Equal(t, 1, top.streamCalls, "stream top-up still attempted after the channel failure")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Contains(t, r.CoverageJSON, `"topup":"failed"`)
}

func TestRun_TopUpRespectsFeatureGates(t *testing.T) {
	top := &fakeTopUp{}
	gen := &mockGenerator{out: `{"tldr":"","topics":[]}`}
	p, d := newPipeline(t, gen, top)
	p.cfg.Digest.Enabled = false
	p.cfg.Streams.Enabled = false
	seedDigest(t, d, 1500, 1900)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, 0, top.channelCalls+top.streamCalls)
	assert.Equal(t, "skipped", res.Coverage.Topup)
}

// BEHAVIOR CATCHUP-04 — see docs/inventory/catchup.md
func TestCatchup04_InventedRefsAreDroppedNotPersisted(t *testing.T) {
	gen := &mockGenerator{}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	id := seedDigest(t, d, 1500, 1900)
	gen.out = fmt.Sprintf(`{"tldr":"x","topics":[{"title":"real","narrative":"n","priority":"low","refs":["digests#%d","digests#4242"]},{"title":"ghost","narrative":"n","priority":"low","refs":["inbox#77"]}],"decisions":[{"text":"d","refs":["decisions#1"]}]}`, id)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err)
	assert.Equal(t, 3, res.RefsRejected)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.NotContains(t, r.BodyJSON, "4242")
	assert.NotContains(t, r.BodyJSON, "ghost")
	assert.Contains(t, r.BodyJSON, `"decisions":[]`)
}

func TestRun_AIFailureMarksRecapFailed(t *testing.T) {
	gen := &mockGenerator{out: "not json"}
	p, d := newPipeline(t, gen, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	res, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{From: time.Unix(1000, 0)}})
	require.NoError(t, err, "a failed recap is a row, not an error")
	assert.Equal(t, "failed", res.Status)
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, "failed", r.Status)
	assert.NotEmpty(t, r.Error)
}

func TestRun_RegenReusesWindowAndSkipsTopUp(t *testing.T) {
	top := &fakeTopUp{}
	var user string
	gen := &mockGenerator{fn: func(_, u string) string { user = u; return `{"tldr":"","topics":[]}` }}
	p, d := newPipeline(t, gen, top)
	seedDigest(t, d, 1500, 1900)
	orig, _ := d.InsertCatchupRecap(1200, 1950, 0)
	res, err := p.Run(context.Background(), RunOptions{RegenOfID: orig, Correction: "less about deploys"})
	require.NoError(t, err)
	assert.Equal(t, int64(1200), res.Window.From.Unix())
	assert.Equal(t, int64(1950), res.Window.To.Unix())
	assert.Equal(t, 0, top.channelCalls)
	assert.Contains(t, user, "OPERATOR CORRECTION: less about deploys")
	r, _ := d.GetCatchupRecap(res.RecapID)
	assert.Equal(t, orig, r.RegenOfID)
}

func TestRun_InvalidWindowIsAnError(t *testing.T) {
	p, _ := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	_, err := p.Run(context.Background(), RunOptions{Spec: WindowSpec{Preset: "fortnight"}})
	assert.ErrorIs(t, err, ErrWindow)
}

func TestAcknowledge_UsesRecapWindow(t *testing.T) {
	p, d := newPipeline(t, &mockGenerator{}, &fakeTopUp{})
	seedDigest(t, d, 1500, 1900)
	id, _ := d.InsertCatchupRecap(1000, 2000, 0)
	require.NoError(t, p.Acknowledge(id))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM digests WHERE read_at IS NOT NULL`).Scan(&n))
	assert.Equal(t, 1, n)
	assert.Error(t, p.Acknowledge(999))
}
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement `pipeline.go`** per the algorithm. Read the real `digest.Usage` fields before step 8.
- [ ] **Step 4: Run** — `go test ./internal/catchup/` → PASS; `go vet ./internal/catchup/`.
- [ ] **Step 5: Commit** — `feat(catchup): absence-recap pipeline — top-up, gather, compose, persist (CATCHUP-02/03/04)`.

---

### Task 10: Feedback → learned rules (`internal/catchup/learn.go`)

**Files:**
- Create: `internal/catchup/learn.go`, `internal/catchup/learn_test.go`

**Interfaces (produces):**

```go
func (p *Pipeline) SubmitTopicFeedback(ctx context.Context, recapID int64, topicIdx int, rating int, comment string) (regeneratedID int64, err error)
```

Behaviour: `GetCatchupRecap` (error if missing), decode `Body`, bounds-check `topicIdx` (error before any write); `AddFeedback{EntityType:"catchup_theme", EntityID: fmt.Sprintf("%d:%d", recapID, topicIdx), Rating, Comment}`; bare rating → `(0, nil)`, no AI call; else resolve `learnRef`s via `FetchItemScopeHints` for the topic's refs, `Generate(digest.WithSource(ctx, "catchup.learn"), learnSystemPrompt + "\n\n" + prompts.Directive(lang), buildLearnUserMessage(...), "")`, `parseLearn`, upsert each well-formed rule (`UpsertLearnedRule{Pipeline (default "inbox"), RuleType, ScopeKey, Weight, Source:"explicit_feedback", EvidenceCount:1}`), and when `parsed.Regenerate` call `p.Run(ctx, RunOptions{RegenOfID: recapID, Correction: comment})` and return the new recap id.

- [ ] **Step 1: Failing tests** (`learn_test.go`): a helper seeds a digest with channel `1:C1` and a ready recap whose body has one topic citing `digests#<id>`. Cases: (a) bare rating → one `feedback` row with `entity_id = "<id>:0"`, `gen.called == false`; (b) comment + model output `{"rules":[{"pipeline":"digest","rule_type":"source_mute","scope_key":"digest:channel:1:C1","weight":-1,"reason":"noise"}],"regenerate":false}` → `inbox_learned_rules` row with `pipeline='digest'`, `scope_key='digest:channel:1:C1'`, and the learn user message contains `channel_id=1:C1`; (c) `"regenerate":true` → returned id > 0, that recap's `RegenOfID` equals the original, the compose call received the comment as a correction (mock `fn` distinguishes the learn call from the compose call by `strings.HasPrefix(system, learnSystemPrompt)`); (d) `topicIdx` 5 on a one-topic recap and recap id 999 both error, and `SELECT COUNT(*) FROM feedback` stays 0.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(catchup): per-topic feedback derives learned rules, regen on correction`.

---

### Task 11: CLI

**Files:**
- Rewrite: `cmd/catchup.go`, `cmd/catchup_test.go`
- Modify: `cmd/coverage_gap_test.go` (`TestRunCatchup_EmptyBacklog` → `TestRunCatchup_EmptyWindow`)

**Commands:** `catchup run [--preset today|yesterday|3d|week | --from X [--to Y]] [--regen ID [--comment C]] [--json]`, `catchup ack <id>`, `catchup feedback <id> --topic N --rating up|down [--comment C]`, `catchup list [--json]`, `catchup show <id>`.

Wiring in `catchupPipeline()` after `catchup.New(...)`:

```go
p.SetPromptStore(prompts.New(database, nil))
digestPipe := digest.New(database, cfg, gen, logger)
ideasPipe := ideas.New(database, cfg, gen, logger)
ideasPipe.SetPromptStore(prompts.New(database, nil))
p.SetTopUp(cliTopUp{digests: digestPipe, ideas: ideasPipe})
```
```go
// cliTopUp adapts the real digest + ideas pipelines to catchup.TopUp.
type cliTopUp struct {
	digests *digest.Pipeline
	ideas   *ideas.Pipeline
}
func (c cliTopUp) ChannelDigests(ctx context.Context) error { _, _, err := c.digests.RunChannelDigestsOnly(ctx); return err }
func (c cliTopUp) StreamDigests(ctx context.Context) error  { return c.ideas.RunStreamDigests(ctx) }
```
`run --json` prints one object: `{"recap_id","status","period_from","period_to","source","coverage":{…},"refs_rejected","error","tldr","body":{…}}` (tldr/body re-read from the row). Plain output = `renderRecapText(r db.CatchupRecap, body catchup.Body) string` (window header in local time, coverage line, TL;DR, `What happened` / `Decisions` / `Meetings` / `For you` sections with `[area#id label]` refs; `failed` → the error; empty body → `Quiet — nothing happened in this window.`), shared by `show`. A `failed` recap exits 0. `--from/--to` parse via `catchup.ParseWindowTime(s, time.Local)`; `--regen` with `--preset`/`--from` is a flag error. `list` prints `id  window(local)  status  ack` lines or a JSON array of rows.

- [ ] **Step 1: Failing tests** — rewrite `cmd/catchup_test.go`: registration of the five subcommands; the `run` flags `preset/from/to/regen/comment/json` and `feedback` flags `topic/rating/comment`; `parseRating`; `renderRecapText` on a fixture (`db.CatchupRecap{PeriodFrom: 1000, PeriodTo: 2000, Status: "ready", TLDR: "tl"}` + a `catchup.Body` with one topic and one needs-you) contains `tl`, the topic title, the needs-you text and `[digests#1 #eng]`; `renderRecapText` on a failed recap contains its error; an ack round-trip: seed a recap + in-window digest through the `setupWatchTestEnv`/`openDBFromConfig` harness, run `catchupAckCmd.RunE(catchupAckCmd, []string{id})`, assert the digest is read. Rewrite `TestRunCatchup_EmptyBacklog` → `TestRunCatchup_EmptyWindow`: `catchupRunFlagJSON = true`, `catchupRunFlagFrom = "<yesterday YYYY-MM-DD>"` on an empty DB → output contains `"status":"ready"` and `"topics":[]` (an empty gather returns before any generator call, so the real `cliPooledGenerator` is never invoked).
- [ ] **Step 2: Run** — `go test ./cmd/ -run Catchup` → FAIL. **Step 3: Implement.** **Step 4:** `go build ./... && go test ./cmd/ -run Catchup` → PASS; `go vet ./...`; `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(catchup): CLI — run/ack/feedback/list/show over recaps`.

---

### Task 12: Go docs + inventory

**Files:**
- Rewrite: `docs/inventory/catchup.md`
- Modify: `docs/inventory/README.md:15` (module mapping → `internal/catchup/`, `internal/db/catchup.go`, `internal/db/catchup_store.go`, the `CatchUp*` Swift files)
- Modify: `CLAUDE.md` — add `### Catch-Up — absence recap (2026-09-04)` under Feature Notes (≤ 8 lines: window rule incl. the 24 h fallback and 31-day cap, top-up through the existing digest pipelines, one `catchup.compose` call, ack-by-window on both write paths, CATCHUP-01..04 pointer, spec path)
- Modify: `internal/memory/digest_compare.go:16` comment ("the CATCHUP-03 spirit" → "per-item isolation")

`docs/inventory/catchup.md`: keep the header block shape (module line, `Last full audit: 2026-09-04`), rewrite "What it is" from spec §1–§6, the four contracts from spec §12 in the existing `## CATCHUP-NN — title / **Status:** Enforced / **Observable:** / **Why locked:** / **Test guards:** / **Locked since:** 2026-09-04` shape (guard names from Global Constraints), a `## Changelog` entry dated 2026-09-04 `([OWNER] confirmed)` stating the replacement, the retired old CATCHUP-03, the dropped `decision_reads` cascade, then the existing older entries verbatim.

- [ ] **Step 1:** Write the docs. **Step 2:** `grep -rn "CatchUpReviewPane\|catchup_themes\|peel" docs/inventory CLAUDE.md` → only changelog lines. **Step 3: Commit** — `docs(catchup): inventory CATCHUP-01..04 for the absence recap`.

---

## Swift

Before the first Swift build in this worktree: `WatchtowerDesktop/.build` does not exist here. Copy it from the main checkout to avoid the ~5-minute cold ML build — `cp -R /Users/vadimtrunov/IdeaProjects/watchtower/WatchtowerDesktop/.build WatchtowerDesktop/.build` (only if absent). Then `cd WatchtowerDesktop && swift build` once so incremental builds are fast.

### Task 13: Core models + queries + test schema

**Files:**
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase.swift:1003-1028` (replace the two catchup tables)
- Rewrite: `WatchtowerDesktop/Sources/WatchtowerCore/Models/CatchUpModels.swift`
- Rewrite: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/CatchUpQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/StreamDigestQueries.swift` (add `fetchByID`), `MeetingRecapQueries.swift` (add `fetchByID`)
- Rewrite: `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift`
- Create: `WatchtowerDesktop/Tests/Core/CatchUpModelsTests.swift`

**Interfaces (produces):**

```swift
package struct CatchUpRef: Codable, Identifiable, Equatable { area, id, label; compositeID }   // unchanged
package struct CatchUpTopic: Codable, Equatable { title, narrative, priority: String; refs: [CatchUpRef] }
package struct CatchUpEntry: Codable, Equatable { text: String; refs: [CatchUpRef] }
package struct CatchUpMeeting: Codable, Equatable { title, summary: String; refs: [CatchUpRef] }
package struct CatchUpNeed: Codable, Equatable { text, kind: String; refs: [CatchUpRef] }
package struct CatchUpRecapBody: Codable, Equatable { topics, decisions, meetings, needsYou (key needs_you); isEmpty }
package struct CatchUpCoverage: Codable, Equatable { slackTo, streamsTo: Double; meetings: Int; topup, topupError: String
    package func summaryLine(formatter: (Double) -> String) -> String }   // "Slack to 17:40 · Jira/Gmail to 14:00 · 3 meetings" (+ " · top-up failed")
package struct CatchUpRecap: FetchableRecord, Identifiable, Equatable {
    id: Int; periodFrom, periodTo: Double; status, tldr, bodyJSON, coverageJSON, error: String
    regenOfID: Int?; acknowledgedAt: String?; model: String; createdAt, updatedAt: String
    isBuilding/isReady/isFailed/isAcknowledged; decodedBody: CatchUpRecapBody; decodedCoverage: CatchUpCoverage
    package static func windowLabel(from: Date, to: Date, calendar: Calendar = .current) -> String }
package enum CatchUpQueries {
    fetchRecaps(_ db, limit: Int = 50) -> [CatchUpRecap]      // ORDER BY id DESC
    fetchRecap(_ db, id: Int) -> CatchUpRecap?
    observeRecaps(limit:) -> ValueObservation<…[CatchUpRecap]>
    autoWindowStart(_ db) -> Date?                            // MAX(period_to) WHERE acknowledged_at IS NOT NULL
    hasUnacknowledgedReady(_ db) -> Bool
    acknowledge(_ db, recap: CatchUpRecap)                    // five UPDATEs + stamp; mirrors Go AcknowledgeCatchupWindow
}
StreamDigestQueries.fetchByID(_ db, id: Int) -> StreamDigest?
MeetingRecapQueries.fetchByID(_ db, id: Int) -> MeetingRecap?
```

Tolerant decoding: every body/coverage field decodes with `decodeIfPresent` and a default (`""`, `[]`, `0`), the `CatchUpRef` init already does. `windowLabel`: same calendar day → `"Sat 4 Sep, 09:00 → 18:30"`; otherwise `"31 Aug 18:00 – 2 Sep 09:15"`.

- [ ] **Step 1: Failing tests**

`Tests/Core/CatchUpModelsTests.swift`:
```swift
final class CatchUpModelsTests: XCTestCase {
    func testBodyDecodesTolerantly() throws {
        let raw = #"{"topics":[{"title":"T","narrative":"n","priority":"high","refs":[{"area":"digests","id":1,"label":"#eng"}]}],"needs_you":[{"text":"ping","kind":"dm","refs":[]}]}"#
        let body = try JSONDecoder().decode(CatchUpRecapBody.self, from: Data(raw.utf8))
        XCTAssertEqual(body.topics.first?.refs.first?.compositeID, "digests:1")
        XCTAssertEqual(body.decisions, [], "missing key → empty")
        XCTAssertEqual(body.needsYou.first?.kind, "dm")
        XCTAssertFalse(body.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(CatchUpRecapBody.self, from: Data("{}".utf8)).isEmpty)
    }

    func testCoverageSummaryLine() throws {
        let cov = try JSONDecoder().decode(CatchUpCoverage.self, from: Data(#"{"slack_to":1000,"streams_to":0,"meetings":2,"topup":"failed","topup_error":"lock"}"#.utf8))
        let line = cov.summaryLine { _ in "17:40" }
        XCTAssertEqual(line, "Slack to 17:40 · 2 meetings · top-up failed")
        XCTAssertEqual(CatchUpCoverage().summaryLine { _ in "" }, "No summaries in this window")
    }

    func testWindowLabelSameDayAndMultiDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let from = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 9))!
        let sameDay = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 18, minute: 30))!
        XCTAssertEqual(CatchUpRecap.windowLabel(from: from, to: sameDay, calendar: cal), "Fri 4 Sep, 09:00 → 18:30")
        let later = cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9, minute: 15))!
        XCTAssertEqual(CatchUpRecap.windowLabel(from: from, to: later, calendar: cal), "4 Sep 09:00 – 6 Sep 09:15")
    }
}
```
(Use `DateFormatter` with `calendar.timeZone` and `locale: en_US_POSIX` inside `windowLabel` so the expectations are deterministic.)

`Tests/Core/CatchUpQueriesTests.swift` — helpers `insertRecap(db, from:to:status:ack:) -> Int64` (raw INSERT into `catchup_recaps`), then:
- `testFetchRecapsNewestFirstAndFetchRecap`
- `testAutoWindowStartUsesLastAcknowledged` (nil with none; ignores unacknowledged; returns the max acknowledged `period_to`)
- `testHasUnacknowledgedReady` (false: none / only building / only acknowledged; true: one ready unacknowledged)
- `testAcknowledgeMarksWindowReadOnFiveSurfaces` — seed one in-window row in each of `digests` (period_to 1600), `stream_digests` (period_to `1970-01-01T00:26:40Z`), `tracks` (updated_at `…00:25:00Z`, has_updates 1), `inbox_items` (created_at `…00:25:00Z`), `briefings` (date `1970-01-01`); acknowledge a recap 1000→2000; assert each has `read_at`, tracks `has_updates = 0`, recap `acknowledged_at` set. **BEHAVIOR CATCHUP-01** comment on top.
- `testAcknowledgeLeavesItemsOutsideWindowUnread` — a digest with period_to 2500 and an inbox item created `…01:00:00Z` stay unread. **BEHAVIOR CATCHUP-01**.
- `testAcknowledgeIsIdempotent` — pre-read digest keeps its `read_at`; second ack keeps the first `acknowledged_at`. **BEHAVIOR CATCHUP-01**.

- [ ] **Step 2: Run** — `make test-swift FILTER=CatchUpQueriesTests` → FAIL to compile.

- [ ] **Step 3: Implement.** `TestDatabase.swift`: replace the block with

```sql
CREATE TABLE IF NOT EXISTS catchup_recaps (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from     REAL NOT NULL,
    period_to       REAL NOT NULL,
    status          TEXT NOT NULL CHECK(status IN ('building','ready','failed')),
    tldr            TEXT NOT NULL DEFAULT '',
    body_json       TEXT NOT NULL DEFAULT '{}',
    coverage_json   TEXT NOT NULL DEFAULT '{}',
    error           TEXT NOT NULL DEFAULT '',
    regen_of_id     INTEGER REFERENCES catchup_recaps(id) ON DELETE SET NULL,
    acknowledged_at TEXT,
    model           TEXT NOT NULL DEFAULT '',
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    cost_usd        REAL NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_catchup_recaps_ack ON catchup_recaps(acknowledged_at, period_to DESC);
```

`CatchUpQueries.acknowledge` — the exact SQL twin of Go's `AcknowledgeCatchupWindow` (same six statements, ISO strings from `Date(timeIntervalSince1970:)` via an `ISO8601DateFormatter` with `.withInternetDateTime` in UTC, briefing dates via a `yyyy-MM-dd` formatter in the current time zone), run inside the caller's `dbPool.write`. Do not use `MarkXRead` helpers (they are per-id).

- [ ] **Step 4: Run** — `make test-swift FILTER=CatchUpQueriesTests` and `FILTER=CatchUpModelsTests` → PASS. Also `swift build` succeeds only after Task 15 (the VM still references old types) — expected; run tests with the filter only.

- [ ] **Step 5: Commit** — `feat(desktop): Catch-Up recap models + queries, window acknowledge (CATCHUP-01 Swift path)`.

---

### Task 14: Sidebar badge

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift` (`pendingThemeCount`, `catchUpTotalCount`, `pendingThemeCount(_:)`, the observed-table list at ~line 76, `fetch()`)
- Modify: `WatchtowerDesktop/Tests/SidebarCountsViewModelTests.swift` (the three Catch-Up tests)

**Interfaces:** `var unacknowledgedRecapCount: Int` (0 or 1); `var catchUpTotalCount: Int { unacknowledgedRecapCount }`; observed tables: replace `"catchup_sessions", "catchup_themes"` with `"catchup_recaps"`.

- [ ] **Step 1: Failing tests** — replace `testCatchUpTotalCountIsSumOfSourceCounts`, `testCatchUpTotalCountIsZeroWhenNoUnread`, `testCatchUpTotalCountIsPendingThemesOfActiveSession` with:
  - `testCatchUpBadgeIsOneWhenReadyUnacknowledgedRecapExists` (insert a `ready` recap, `unreadDigestCount = 99` must not matter → 1)
  - `testCatchUpBadgeIsZeroWhenAcknowledged` (ready + acknowledged_at → 0)
  - `testCatchUpBadgeIgnoresBuildingAndFailed` (one building + one failed → 0)
- [ ] **Step 2: Run** — `make test-swift FILTER=SidebarCountsViewModelTests` → FAIL. **Step 3: Implement** (`unacknowledgedRecapCount = try CatchUpQueries.hasUnacknowledgedReady(db) ? 1 : 0`). **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(desktop): Catch-Up badge = unacknowledged ready recap`.

---

### Task 15: CatchUpViewModel

**Files:**
- Rewrite: `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift`
- Rewrite: `WatchtowerDesktop/Tests/CatchUpViewModelTests.swift`

**Interfaces (produces):**

```swift
enum CatchUpWindowChoice: Equatable {
    case auto, today, yesterday, threeDays, week
    case custom(from: Date, to: Date)
    var cliArguments: [String]   // auto → []; today → ["--preset","today"]; …; custom → ["--from", iso, "--to", iso]
    var title: String            // segmented labels
}

@MainActor @Observable final class CatchUpViewModel {
    var recaps: [CatchUpRecap]; var selected: CatchUpRecap?
    var isBuilding: Bool; var error: String?
    var windowChoice: CatchUpWindowChoice = .auto
    var autoWindowStart: Date?           // for the "since Thu 18:40" caption; reloaded with the list
    init(dbPool: DatabasePool)
    func startObserving(); func reload() async
    func build()                          // catchup run --json + windowChoice.cliArguments
    func regenerate(comment: String)      // catchup run --regen <selected.id> [--comment] ; also the Retry action for a failed recap
    func acknowledge() async              // direct DB write via CatchUpQueries.acknowledge, then reload
    func submitFeedback(topicIndex: Int, rating: Int, comment: String)  // catchup feedback <id> --topic N --rating up|down [--comment]
    // read-only source fetches for inline cards (VM's own dbPool):
    func digest(byID:) -> Digest?; func track(byID:) -> Track?; func streamDigest(byID:) -> StreamDigest?
    func meetingRecap(byID:) -> MeetingRecap?; func transcript(byID:) -> MeetingTranscript?
    func decision(byID:) -> (Idea, [IdeaMention])?; func inboxItem(byID:) -> InboxItem?; func target(byID:) -> Target?
    nonisolated static func slackMessageURL(for item: InboxItem) -> URL?   // kept
}
```

Build flow: `isBuilding = true`, `startPolling()` (1 s, the existing cross-process pattern), run the CLI detached; on exit `isBuilding = false`, stop polling, `reload()`, and if `exitCode != 0` set `error` from stderr; when exit is 0 parse the stdout JSON for `"status":"failed"` + `"error"` and surface it as `error` too. Selection: after reload keep the selected id if still present, else select the newest recap. `acknowledge()` re-reads the selected row after the write so the button flips to the label.

- [ ] **Step 1: Failing tests** (`CatchUpViewModelTests.swift`; keep the `waitFor` helper; helpers `insertRecap(db, from:to:status:) -> Int`, `insertDigest(db, periodTo:) -> Int`):
  - `testWindowChoiceCLIArguments` — `.auto → []`, `.yesterday → ["--preset","yesterday"]`, `.custom` → `--from`/`--to` RFC 3339 strings.
  - `testStartObservingPopulatesRecapsAndSelectsNewest` — two ready recaps → `recaps.count == 2`, `selected?.id == newest`.
  - `testAcknowledgeMarksWindowAndFlipsSelected` — recap 1000→2000 + in-window digest; `await vm.acknowledge()` → digest read, `vm.selected?.isAcknowledged == true`.
  - `testReloadRefreshesAutoWindowStart` — after acknowledging, `vm.autoWindowStart == Date(timeIntervalSince1970: 2000)`.
- [ ] **Step 2: Run** — `make test-swift FILTER=CatchUpViewModelTests` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** — `feat(desktop): CatchUpViewModel over recaps (build / regen / acknowledge / feedback)`.

---

### Task 16: Views

**Files:**
- Rewrite: `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpView.swift`
- Create: `WatchtowerDesktop/Sources/Views/CatchUp/CatchUpRecapRow.swift`, `CatchUpRecapDocument.swift`, `CatchUpSourceInlineExtra.swift`
- Keep: `CatchUpSourceInline.swift` (`DigestInlineDetail`, `TrackInlineDetail`)
- Delete: `CatchUpThemeRow.swift`, `CatchUpReviewPane.swift`
- Unchanged: `Navigation.swift`, `AppState.swift` (init signature is the same), `SidebarView.swift`

**Structure:**

`CatchUpView` — `HSplitView { leftColumn.frame(minWidth: 260, idealWidth: 300, maxWidth: 380); rightPane }`, `.onAppear { vm.startObserving() }`.
- `leftColumn`: `windowBar` (a `Picker` with `.segmented` style over auto/today/yesterday/3d/week + a "Range" toggle revealing two `DatePicker`s bound to `@State` dates that feed `.custom`, a caption `Text("since \(shortDateTime(autoWindowStart))")` when `.auto`, and a `Button("Build recap") { vm.build() }.disabled(vm.isBuilding)` with a `ProgressView` while building); `Divider`; the recap list as a `ScrollView { LazyVStack { ForEach(vm.recaps) { CatchUpRecapRow … } } }` of plain buttons (the TargetsListView precedent, same selection background as the old theme list).
- `rightPane`: `if let recap = vm.selected { CatchUpRecapDocument(recap: recap, vm: vm) } else { emptyState }` — empty state: `tray.and.arrow.down` icon, "No recaps yet", "Pick a window and build one."
- `error` shown as a top banner (orange, dismissable) inside the left column, not a full-screen state, since older recaps stay readable.

`CatchUpRecapRow(recap:)` — `CatchUpRecap.windowLabel(...)` as title, a caption row: `ProgressView().controlSize(.mini)` for building, red `exclamationmark.triangle` for failed, green `checkmark.circle.fill` + "caught up" when acknowledged, a small "regenerated" capsule when `regenOfID != nil`.

`CatchUpRecapDocument(recap:vm:)` — `VStack { ScrollView { header; tldr; sections }; Divider(); actionBar }`:
- `header`: window label `.title2`, coverage caption (`decodedCoverage.summaryLine { TimeFormatting.shortTime($0) }`), "Regenerated from an earlier recap" note when `regenOfID != nil`.
- `building` → `ProgressView("Building the recap…")`; `failed` → orange notice with the error and `Button("Retry") { vm.regenerate(comment: "") }`; `ready && decodedBody.isEmpty` → "Quiet — nothing happened in this window."
- `tldr` paragraph (`.body`, `textSelection`).
- Sections with `Label` headers: **What happened** (`ForEach(topics.indices) { CatchUpTopicCard(index:topic:vm:) }`), **Decisions** (`ForEach` of `decisions` → text + `CatchUpRefList`), **Meetings** (title + summary + refs), **For you** (kind glyph: mention `at`, dm `bubble.left`, email `envelope`, track `checkmark.circle`, target_due `flag` + text + refs).
- `CatchUpTopicCard`: title + priority chip (colors from the old `CatchUpThemeRow.priorityColor`) + narrative; `DisclosureGroup("Sources (n)")` → `CatchUpRefList(refs:vm:)`; trailing 👍/👎 buttons and a comment `TextField` + "Send" that call `vm.submitFeedback(topicIndex:rating:comment:)` (the old review pane's comment affordance, moved onto the card).
- `CatchUpRefList(refs:vm:)`: one `CatchUpSourceCard(ref:vm:)` per ref — a row with an area glyph + label + chevron that expands into the inline view for its area:
  `digests → DigestInlineDetail`, `tracks → TrackInlineDetail`, `streams → StreamDigestInline`, `recaps → MeetingRecapInline(content: recap.parsed, title:)`, `transcripts → MeetingRecapInline(content: decoded summaryJSON, title: transcript.title)`, `decisions → DecisionInline`, `inbox → InboxItemInline` (+ "Open in Slack" link via `CatchUpViewModel.slackMessageURL`), `targets → TargetInline`. A vanished row renders "Source no longer available". Inbox/track/target rows also offer "Open" → `appState.selectedDestination = .inbox / .tracks / .targets` (check the `SidebarDestination` case names).
- `actionBar`: `Button("I'm caught up") { Task { await vm.acknowledge() } }` (`.borderedProminent`, hidden when `!recap.isReady`); once acknowledged a `Label("Caught up \(relative time)", systemImage: "checkmark.circle.fill")` instead; a `TextField("Correction…")` + `Button("Regenerate") { vm.regenerate(comment:) }`.

`CatchUpSourceInlineExtra.swift` — five compact read-only views (each ≤ 40 lines, same padding/background as `TrackInlineDetail`):
- `StreamDigestInline(digest: StreamDigest)` — source/scope caption + `parsedTopics` as "title — summary" rows.
- `MeetingRecapInline(title: String, content: MeetingRecap.Content?)` — summary, "Decisions" list, "Action items" list; nil content → "No recap".
- `DecisionInline(idea: Idea, mentions: [IdeaMention])` — title, essence, latest mention quote/author.
- `InboxItemInline(item: InboxItem, url: URL?)` — snippet, sender/channel caption, `Link("Open in Slack")` when url.
- `TargetInline(target: Target)` — text, intent, due/status/priority caption.

- [ ] **Step 1:** Delete the two old files; write the views. **Step 2:** `cd WatchtowerDesktop && swift build` → succeeds; `make lint-swift` → clean (fix line-length / trailing-whitespace as reported). **Step 3:** `make test-swift FILTER=CatchUp` → PASS. **Step 4:** Launch the app via the `run` skill against a dev config if available and click through: build a recap (Auto), expand a topic's sources, press "I'm caught up", confirm the badge clears. Record what was verified in the commit body.
- [ ] **Step 5: Commit** — `feat(desktop): Catch-Up recap document UI with inline sources`.

---

### Task 17: Gate, review, PR, merge

- [ ] **Step 1:** `make test` (full Go), `make test-swift` (full Swift), `make lint-all`. Fix everything; re-run until green.
- [ ] **Step 2:** `grep -rn "catchup_sessions\|catchup_themes\|CatchupTheme\|GetUnreadDigests\|catchup.peel\|catchup.expand" --include=*.go --include=*.swift --include=*.sql . | grep -v migrations/00003 | grep -v migrations/00061` → only the Down section of 00061 and historical docs.
- [ ] **Step 3:** Run the `local-review` skill on the branch (final PR into `main` → it runs the debate-review panel); triage and fix accepted findings; repeat until the reviewers converge.
- [ ] **Step 4:** `git push -u origin feature/catchup-absence-recap`; `gh pr create --base main --title "feat(catchup): Catch-Up as an absence recap" --body-file <generated body>` — body: summary, the four contracts, what was retired, how it was tested (Go/Swift/manual), spec + plan paths, the required footer.
- [ ] **Step 5:** Watch CI (`gh pr checks --watch`); fix failures on the branch; when green and the review panel is satisfied, `gh pr merge --squash --delete-branch` (the repo's release commits are squash merges — confirm with `git log --merges -3` first and match the house style).

---

## Self-review checklist (done while writing)

- Spec §3 window rule → Task 6; §4 schema → Task 1/2 + Task 13 test schema; §5.1 top-up → Task 9 (+ CLI wiring Task 11); §5.2 gather → Task 3; §5.3 compose/budget → Tasks 5, 8, 9; §5.4 validate → Task 7; §5.5 persist → Tasks 2, 9; §5.6 regen → Tasks 9, 10, 11, 15; §6 acknowledge → Tasks 2, 9, 13, 15; §7 feedback → Tasks 10, 11, 15, 16; §8 CLI → Task 11; §9 config → Task 4; §10 Desktop → Tasks 13–16; §11 retirement → Tasks 2, 3, 6 (file deletion), 16; §12 inventory → Task 12; §13 testing → every task.
- Names cross-checked: `CatchupItem`, `ListCatchup*`, `CatchupCoverage`, `AcknowledgeCatchupWindow`, `LastAcknowledgedCatchupTo`, `Body`/`Topic`/`Entry`/`MeetingEntry`/`NeedEntry`/`Coverage`, `gathered`, `promptInput`, `buildComposeUserMessage`, `TopUp`, `RunOptions`/`RunResult`, `SubmitTopicFeedback`, Swift `CatchUpRecap`/`CatchUpRecapBody`/`CatchUpCoverage`/`CatchUpWindowChoice`, `CatchUpQueries.acknowledge(_:recap:)`, `hasUnacknowledgedReady`, `autoWindowStart`.
