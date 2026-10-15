# History Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a source's first sync, the daemon walks it back to 30 days in 2-day chunks, newest first, and runs the AI pipelines over each chunk.

**Architecture:** A `history_backfill` table holds one row per source (Slack account, Google account's Gmail, IMAP account). A new `internal/historybackfill` package owns the chunk loop behind small interfaces (fetch a range, process a range, plan gate). The daemon runs it as the last phase of `runSync`, starts rows from the three sync phases, and gates memory on it. Desktop and the CLI only read the table.

**Tech Stack:** Go 1.26, SQLite (goose migrations), SwiftUI + GRDB (WatchtowerCore).

**Spec:** `docs/superpowers/specs/2026-10-15-history-backfill-design.md` (approved, ask #168). Read it before any task.

## Global Constraints

- `sync.backfill_days` default **30**; `0` = no new backfills. Chunk = **2 days**. Phase wall-clock budget = **5 minutes** per cycle. A chunk is skipped after **3** failures.
- `calendar.history_days` default **14 → 30**.
- Only a source whose sync just ran **with no cursor** starts a backfill. Existing sources never do. A first sync that already reached the floor starts none.
- Processing never moves a forward mark: no write to `search_last_date`, Gmail/IMAP watermarks, `inbox_last_processed_ts`, the rollup/people attempt budgets, or `channels.digest_considered_ts` from backfill code.
- Plan gate: a `will_hit`/`hit` projection on the `session` or `weekly_all` limit pauses AI processing. A missing row, or a status other than `ok`, does not block.
- Memory extraction is skipped while any row is `running` or `paused`.
- Desktop copy: `Loading history: N of M days` and `Loading history paused — Claude plan limit`.
- Repo rules: CLAUDE.md "Build & Test" inner loop (task scope only — `go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, and for Swift `make lint-swift`); migrations per `.claude/skills/add-migration`; Desktop code per `docs/review/review-rules.md` "Swift / Desktop conventions"; no live-install data in fixtures (`acme`, `example.com`).
- Read `docs/inventory/README.md` and the inventory file for each module you touch (digest, daemon, sync, gmail, imap, memory, inbox). A guard test that would have to be relaxed → stop and report.

## Review Focus

1. **A digest chunk that never converges** — a channel the model declines, or a low-activity channel the cooldown would skip, re-offered every pass. Expect the chunk to finish; pinned in Task 4 (`TestRunBackfillWindow_DeclinedChannelDoesNotLoop`, `..._LowActivityChannelNotCooledDown`).
2. **Forward marks after a backfill** — the next forward digest run must neither re-digest the first-sync window nor skip new messages. Pinned in Task 4 (`TestRunBackfillWindow_ForwardWindowUnaffected`).
3. **Slack's day-granular, exclusive `after:`/`before:`** — a message on a chunk's edge day must be fetched exactly once in effect (upsert makes overlap harmless, gaps are not). Pinned in Task 3 (`TestSlackSearchRange`).
4. **Account removed or token revoked mid-backfill** — the row stops (`off` / `paused`) and does not spin or error every cycle; reconnecting resumes. Pinned in Task 6 (`TestRunner_RevokedPausesAndResumes`, `TestRunner_RemovedAccountTurnsOff`).
5. **Plan status missing or stale** — never blocks; `will_hit` blocks processing but the chunk is not advanced. Pinned in Task 5 and Task 6 (`TestRunner_PlanGateHoldsChunk`).

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `internal/db/migrations/00116_history_backfill.sql` | 1 | table |
| `internal/db/history_backfill.go` (+ `_test.go`) | 1 | row CRUD |
| `internal/db/schema.sql`, `db_test.go`, golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` | 1 | schema mirrors |
| `internal/config/{config,defaults}.go` (+ test) | 2 | `sync.backfill_days`, calendar 30 |
| `WatchtowerDesktop/Sources/Services/ConfigService.swift`, `Tests/ConfigServiceTests.swift`, `docs/app-guide.md` | 2 | calendar fallback 30 |
| `internal/sync/search_sync.go` (+ test) | 3 | `BackfillSearch`, `FirstSyncFrom` |
| `internal/gmail/sync.go` (+ test) | 3 | `FetchRange`, `FirstSyncFrom`, `AccountID` |
| `internal/imap/{client,sync}.go` (+ test) | 3 | `SearchRange`, `FetchRange`, `FirstSyncFrom`, `AccountID` |
| `internal/db/digests.go` (+ test), `internal/digest/backfill.go` (+ test), `internal/digest/pipeline.go` | 4 | chunk-scoped digests + rollups |
| `internal/planusage/gate.go` (+ test) | 5 | `NearLimit` |
| `internal/historybackfill/{runner,chunk}.go` (+ tests) | 6 | chunk loop |
| `internal/daemon/history_backfill.go` (+ test), `daemon.go` | 7 | phase, start hooks, memory gate, wiring |
| `cmd/backfill.go` (+ test) | 8 | `watchtower backfill status` |
| `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/BackfillQueries.swift`, `.../Services/BackfillProgress.swift`, `Views/StatusBarView.swift`, `Views/TrayMenuView.swift`, tests in `Tests/Core` | 9 | progress line |
| `docs/features/history-backfill.md`, `CLAUDE.md`, `docs/inventory/*`, `docs/features/first-run.md`, `docs/features/onboarding-v2.md` | 10 | docs |

Dependencies: Task 1 → none. Task 2 → none. Task 3 → none. Task 4 → none. Task 5 → none. Task 6 → 1, 5. Task 7 → 1–6. Task 8 → 1. Task 9 → 1. Task 10 → 7, 8, 9.
Parallel lanes (owner preference): {1, 2, 3, 4, 5} independent; Swift work (Task 9, the Swift part of Task 2) one lane at a time.

---

### Task 1: `history_backfill` table and DB helpers

**Files:**
- Create: `internal/db/migrations/00116_history_backfill.sql`, `internal/db/history_backfill.go`, `internal/db/history_backfill_test.go`
- Modify: `internal/db/schema.sql` (append after `plan_usage_status`), `internal/db/db_test.go:203` (`expectedTables`), golden `internal/db/testdata/schema_v73.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (both regenerated)

**Interfaces — Produces:**
```go
type HistoryBackfill struct {
    ID            int64
    SourceKind    string  // slack | gmail | imap
    AccountID     int64
    FloorTS       float64
    UpperTS       float64
    ReachedTS     float64
    Status        string  // running | paused | done | off
    Waiting       string  // "" | "plan_limit"
    ChunkFailures int
    LastError     string
    StartedAt     time.Time
    UpdatedAt     time.Time
    DoneAt        *time.Time
}
func (db *DB) StartHistoryBackfill(kind string, accountID int64, floorTS, upperTS float64, now time.Time) (created bool, err error)
func (db *DB) ListHistoryBackfills() ([]HistoryBackfill, error)               // all rows, by id
func (db *DB) AdvanceHistoryBackfill(id int64, reachedTS float64, now time.Time) error // sets reached, clears failures/error/waiting; done when reached <= floor
func (db *DB) RecordHistoryBackfillFailure(id int64, msg string, now time.Time) (failures int, err error)
func (db *DB) SetHistoryBackfillStatus(id int64, status string, now time.Time) error
func (db *DB) SetHistoryBackfillWaiting(id int64, waiting string, now time.Time) error
func (db *DB) HasActiveHistoryBackfill() (bool, error)                        // any running|paused
```

- [ ] **Step 1: Migration** — `internal/db/migrations/00116_history_backfill.sql`:

```sql
-- +goose Up
-- One row per source that started a history backfill after its first sync
-- (docs/features/history-backfill.md). reached_ts only moves down, from
-- upper_ts (the first sync's window start) to floor_ts.
CREATE TABLE history_backfill (
    id             INTEGER PRIMARY KEY,
    source_kind    TEXT    NOT NULL CHECK (source_kind IN ('slack', 'gmail', 'imap')),
    account_id     INTEGER NOT NULL,
    floor_ts       REAL    NOT NULL,
    upper_ts       REAL    NOT NULL,
    reached_ts     REAL    NOT NULL,
    status         TEXT    NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running', 'paused', 'done', 'off')),
    waiting        TEXT    NOT NULL DEFAULT '' CHECK (waiting IN ('', 'plan_limit')),
    chunk_failures INTEGER NOT NULL DEFAULT 0,
    last_error     TEXT    NOT NULL DEFAULT '',
    started_at     TEXT    NOT NULL,
    updated_at     TEXT    NOT NULL,
    done_at        TEXT,
    UNIQUE (source_kind, account_id)
);

-- +goose Down
DROP TABLE history_backfill;
```

(`waiting` is a spec detail made concrete: the Desktop needs to tell "paused for the plan limit" from "running".) Mirror the same `CREATE TABLE IF NOT EXISTS history_backfill (...)` with a one-line comment into `internal/db/schema.sql` after `plan_usage_status`, and append `"history_backfill",` to `expectedTables` in `db_test.go`.

- [ ] **Step 2: Failing tests** — `internal/db/history_backfill_test.go`:

```go
package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHistoryBackfill_StartIsIdempotent(t *testing.T) {
	d := OpenTestDB(t)
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	created, err := d.StartHistoryBackfill("slack", 1, 100, 200, now)
	require.NoError(t, err)
	assert.True(t, created)
	created, err = d.StartHistoryBackfill("slack", 1, 50, 300, now)
	require.NoError(t, err)
	assert.False(t, created, "second start for the same source is a no-op")

	rows, err := d.ListHistoryBackfills()
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, 100.0, rows[0].FloorTS)
	assert.Equal(t, 200.0, rows[0].UpperTS)
	assert.Equal(t, 200.0, rows[0].ReachedTS)
	assert.Equal(t, "running", rows[0].Status)
}

func TestHistoryBackfill_AdvanceToFloorIsDone(t *testing.T) {
	d := OpenTestDB(t)
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	_, err := d.StartHistoryBackfill("gmail", 2, 100, 200, now)
	require.NoError(t, err)
	rows, _ := d.ListHistoryBackfills()
	id := rows[0].ID

	_, err = d.RecordHistoryBackfillFailure(id, "boom", now)
	require.NoError(t, err)
	require.NoError(t, d.SetHistoryBackfillWaiting(id, "plan_limit", now))
	require.NoError(t, d.AdvanceHistoryBackfill(id, 150, now))
	rows, _ = d.ListHistoryBackfills()
	assert.Equal(t, 150.0, rows[0].ReachedTS)
	assert.Equal(t, 0, rows[0].ChunkFailures)
	assert.Equal(t, "", rows[0].LastError)
	assert.Equal(t, "", rows[0].Waiting)
	assert.Equal(t, "running", rows[0].Status)

	require.NoError(t, d.AdvanceHistoryBackfill(id, 100, now))
	rows, _ = d.ListHistoryBackfills()
	assert.Equal(t, "done", rows[0].Status)
	require.NotNil(t, rows[0].DoneAt)
}

func TestHistoryBackfill_FailuresCountAndActive(t *testing.T) {
	d := OpenTestDB(t)
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	active, err := d.HasActiveHistoryBackfill()
	require.NoError(t, err)
	assert.False(t, active)

	_, _ = d.StartHistoryBackfill("imap", 3, 100, 200, now)
	rows, _ := d.ListHistoryBackfills()
	id := rows[0].ID
	n, err := d.RecordHistoryBackfillFailure(id, "a", now)
	require.NoError(t, err)
	assert.Equal(t, 1, n)
	n, _ = d.RecordHistoryBackfillFailure(id, "b", now)
	assert.Equal(t, 2, n)

	active, _ = d.HasActiveHistoryBackfill()
	assert.True(t, active)
	require.NoError(t, d.SetHistoryBackfillStatus(id, "paused", now))
	active, _ = d.HasActiveHistoryBackfill()
	assert.True(t, active, "paused still holds memory back")
	require.NoError(t, d.SetHistoryBackfillStatus(id, "off", now))
	active, _ = d.HasActiveHistoryBackfill()
	assert.False(t, active)
}
```

- [ ] **Step 3:** Run `go test ./internal/db -run TestHistoryBackfill` → FAIL (undefined).

- [ ] **Step 4: Implement** `internal/db/history_backfill.go` in the `plan_usage.go` shape (reuse `planTime`/`parsePlanTime` for the TEXT timestamps; wrap errors `fmt.Errorf("history backfill: <op>: %w", err)`):

```go
package db

import (
	"database/sql"
	"fmt"
	"time"
)

// HistoryBackfill is one source's history backfill (docs/features/history-backfill.md).
type HistoryBackfill struct { /* fields as in Interfaces */ }

// StartHistoryBackfill creates the source's row; a second call is a no-op so
// only the first sync ever starts one.
func (db *DB) StartHistoryBackfill(kind string, accountID int64, floorTS, upperTS float64, now time.Time) (bool, error) {
	ts := planTime(now)
	res, err := db.Exec(`INSERT INTO history_backfill
		(source_kind, account_id, floor_ts, upper_ts, reached_ts, started_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(source_kind, account_id) DO NOTHING`,
		kind, accountID, floorTS, upperTS, upperTS, ts, ts)
	if err != nil {
		return false, fmt.Errorf("history backfill: start: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("history backfill: start: %w", err)
	}
	return n > 0, nil
}

func (db *DB) AdvanceHistoryBackfill(id int64, reachedTS float64, now time.Time) error {
	ts := planTime(now)
	_, err := db.Exec(`UPDATE history_backfill SET
		reached_ts = ?, chunk_failures = 0, last_error = '', waiting = '', updated_at = ?,
		status  = CASE WHEN ? <= floor_ts THEN 'done' ELSE status END,
		done_at = CASE WHEN ? <= floor_ts THEN ? ELSE done_at END
		WHERE id = ?`, reachedTS, ts, reachedTS, reachedTS, ts, id)
	if err != nil {
		return fmt.Errorf("history backfill: advance: %w", err)
	}
	return nil
}

func (db *DB) RecordHistoryBackfillFailure(id int64, msg string, now time.Time) (int, error) {
	var n int
	err := db.QueryRow(`UPDATE history_backfill SET chunk_failures = chunk_failures + 1,
		last_error = ?, updated_at = ? WHERE id = ? RETURNING chunk_failures`,
		msg, planTime(now), id).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("history backfill: record failure: %w", err)
	}
	return n, nil
}

func (db *DB) SetHistoryBackfillStatus(id int64, status string, now time.Time) error {
	_, err := db.Exec(`UPDATE history_backfill SET status = ?, updated_at = ? WHERE id = ?`, status, planTime(now), id)
	if err != nil {
		return fmt.Errorf("history backfill: set status: %w", err)
	}
	return nil
}

func (db *DB) SetHistoryBackfillWaiting(id int64, waiting string, now time.Time) error {
	_, err := db.Exec(`UPDATE history_backfill SET waiting = ?, updated_at = ? WHERE id = ?`, waiting, planTime(now), id)
	if err != nil {
		return fmt.Errorf("history backfill: set waiting: %w", err)
	}
	return nil
}

func (db *DB) HasActiveHistoryBackfill() (bool, error) {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM history_backfill WHERE status IN ('running','paused')`).Scan(&n); err != nil {
		return false, fmt.Errorf("history backfill: active: %w", err)
	}
	return n > 0, nil
}
```

`ListHistoryBackfills` selects every column `ORDER BY id`, parses `started_at`/`updated_at` with `parsePlanTime`, and `done_at` via `sql.NullString` → `*time.Time`.

- [ ] **Step 5:** Regenerate mirrors: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db` → PASS.
- [ ] **Step 6:** `make lint-diff`; commit `feat(db): history_backfill table`.

---

### Task 2: Config — `sync.backfill_days`, calendar history 30

**Files:**
- Modify: `internal/config/defaults.go` (sync block near `DefaultInitialHistDays`; `DefaultCalendarHistoryDays` at :91), `internal/config/config.go` (`SyncConfig` :62, defaults :448), `internal/config/config_test.go` (defaults test near :70), `internal/calendar/sync_test.go:551` (comment "default 14" → 30), `WatchtowerDesktop/Sources/Services/ConfigService.swift:50,:161` (`?? 14` → `?? 30`), `WatchtowerDesktop/Tests/ConfigServiceTests.swift:116`, `WatchtowerDesktop/Sources/ViewModels/CalendarViewModel.swift:36` (comment), `docs/app-guide.md:133`.

**Interfaces — Produces:** `config.DefaultBackfillDays = 30`; `cfg.Sync.BackfillDays int` (`mapstructure:"backfill_days"`).

- [ ] **Step 1: Failing test** in `config_test.go`:

```go
func TestConfig_BackfillAndCalendarDefaults(t *testing.T) {
	cfg, err := Load(writeTestConfig(t, "active_workspace: acme\n"))
	require.NoError(t, err)
	assert.Equal(t, 30, cfg.Sync.BackfillDays)
	assert.Equal(t, 30, cfg.Calendar.HistoryDays)
}

func TestConfig_BackfillZeroIsKept(t *testing.T) {
	cfg, err := Load(writeTestConfig(t, "active_workspace: acme\nsync:\n  backfill_days: 0\n"))
	require.NoError(t, err)
	assert.Equal(t, 0, cfg.Sync.BackfillDays, "0 turns new backfills off, never re-defaulted")
}
```
(Match `writeTestConfig`'s real signature in the file; adjust the YAML wrapper to what neighbouring tests pass.)

- [ ] **Step 2:** `go test ./internal/config -run TestConfig_Backfill` → FAIL.
- [ ] **Step 3:** Add `DefaultBackfillDays = 30` (comment: "days a source's history backfill reaches back after its first sync; 0 = off"), the `BackfillDays` field, `v.SetDefault("sync.backfill_days", DefaultBackfillDays)`; set `DefaultCalendarHistoryDays = 30` and update its comment. Do not clamp 0 anywhere.
- [ ] **Step 4:** `go test ./internal/config ./internal/calendar ./internal/caldav` → PASS.
- [ ] **Step 5:** Swift fallback 14 → 30 in `ConfigService.swift` (two places) and its test; `make test-swift FILTER=ConfigServiceTests`; `make lint-swift`.
- [ ] **Step 6:** `make lint-diff`; commit `feat(config): sync.backfill_days, 30-day calendar history`.

---

### Task 3: Range fetchers and first-sync signals for Slack, Gmail, IMAP

Each syncer gains (a) a range fetch that writes **no cursor, no auth state, no account error** and ignores per-cycle caps, and (b) `FirstSyncFrom() (time.Time, bool)`: true only when the **last `Sync`/`Run` was a completed first sync**, returning that sync's window start.

**Files:**
- Modify: `internal/sync/search_sync.go`, `internal/sync/orchestrator.go` (field), `internal/gmail/sync.go`, `internal/imap/client.go`, `internal/imap/sync.go`
- Test: `internal/sync/search_sync_test.go`, `internal/gmail/sync_test.go`, `internal/imap/sync_test.go` (use each package's existing fakes — read the neighbouring tests first)

**Interfaces — Produces:**
```go
// internal/sync
func (o *Orchestrator) BackfillSearch(ctx context.Context, from, to time.Time) (saved int, err error)
func (o *Orchestrator) FirstSyncFrom() (time.Time, bool)
func slackSearchRange(from, to time.Time) (after, before string) // pure
// internal/gmail
func (s *Syncer) AccountID() int64
func (s *Syncer) FetchRange(ctx context.Context, from, to time.Time) (saved int, err error)
func (s *Syncer) FirstSyncFrom() (time.Time, bool)
// internal/imap
func (cl *Client) SearchRange(since, before time.Time) ([]uint32, error)
func (s *Syncer) AccountID() int64
func (s *Syncer) FetchRange(ctx context.Context, from, to time.Time) (saved int, err error)
func (s *Syncer) FirstSyncFrom() (time.Time, bool)
```

- [ ] **Step 1: Slack — failing tests.**

```go
func TestSlackSearchRange(t *testing.T) {
	from := time.Date(2026, 9, 20, 15, 0, 0, 0, time.UTC)
	to := time.Date(2026, 9, 22, 15, 0, 0, 0, time.UTC)
	after, before := slackSearchRange(from, to)
	// after:/before: are exclusive and day-granular: widen by a day on each
	// side so both edge days are inside; the overlap is harmless (upsert).
	assert.Equal(t, "2026-09-19", after)
	assert.Equal(t, "2026-09-23", before)
}
```
Plus an orchestrator test with the package's fake Slack server/client used by the existing `syncViaSearch` tests: `BackfillSearch` sends `query == "after:2026-09-19 before:2026-09-23"`, saves the page's messages, and leaves `GetSlackAccountSearchWatermark` == "" and the account's `error`/`auth_state` unchanged; a `Run` on a fresh account (empty watermark, completed search) makes `FirstSyncFrom()` return the window's `after` date parsed as UTC midnight and `true`; a second `Run` (watermark set) returns `false`; a rate-limited/incomplete first run returns `false`.

- [ ] **Step 2:** Run `go test ./internal/sync -run 'TestSlackSearchRange|BackfillSearch|FirstSyncFrom'` → FAIL.

- [ ] **Step 3: Slack implementation.** In `search_sync.go`:
  1. Extract the page loop of `syncViaSearch` (from `page := 1` through the per-page `upsertSearchPage`) into
     `func (o *Orchestrator) searchAndSave(ctx context.Context, query string, live bool) (completed bool, saved int, seenChannels map[string]bool, err error)`.
     `live=false` skips every `o.progress.*` call and the `o.searchRateLimited`/`o.searchGapNote` writes; a page-1 rate limit returns `completed=false, err=nil` in that mode. `syncViaSearch` calls it with `live=true` and keeps its watermark/discovery tail unchanged.
  2. Add `firstSyncFrom time.Time` to `Orchestrator`; reset it at the top of `Run` (with the other per-run flags). In `syncViaSearch`, when `lastDate == ""` (or unparseable) **and** the watermark write runs, set `o.firstSyncFrom` to `searchAfter` parsed with `time.Parse(searchDateFormat, …)`.
  3. ```go
     func slackSearchRange(from, to time.Time) (after, before string) {
         return from.UTC().AddDate(0, 0, -1).Format(searchDateFormat), to.UTC().AddDate(0, 0, 1).Format(searchDateFormat)
     }

     // BackfillSearch saves every message Slack's search finds in [from, to)
     // (widened to whole days) without touching the search watermark, the
     // progress heartbeat or the account's auth/error state.
     func (o *Orchestrator) BackfillSearch(ctx context.Context, from, to time.Time) (int, error) {
         after, before := slackSearchRange(from, to)
         completed, saved, _, err := o.searchAndSave(ctx, fmt.Sprintf("after:%s before:%s", after, before), false)
         if err != nil {
             return saved, err
         }
         if !completed {
             return saved, fmt.Errorf("slack backfill search %s..%s incomplete (rate limit or partial pages)", after, before)
         }
         return saved, nil
     }

     func (o *Orchestrator) FirstSyncFrom() (time.Time, bool) { return o.firstSyncFrom, !o.firstSyncFrom.IsZero() }
     ```
  Revoked-token errors must stay detectable: return the client error unwrapped-compatible (`%w`) so `sync.IsRevokedAuthError` works on it.

- [ ] **Step 4: Gmail — failing tests** (use the package's fake Gmail client from `sync_test.go`): `FetchRange(from,to)` lists `in:inbox after:<from.Unix()> before:<to.Unix()>`, stores **all** non-noise messages even above `MaxMessagesPerSync`, leaves `GetGmailAccountWatermark` at 0 and the account's auth state unchanged; `Sync` with watermark 0 and a successful list sets `FirstSyncFrom()` to `now − InitialHistoryDays` (inject the clock the way the existing tests do, or compare within a second) — even when the list is empty; `Sync` with a watermark > 0 → `false`.

- [ ] **Step 5: Gmail implementation.** Extract the per-id body of `Sync`'s loop (GetMessage, noise filter, row build, `UpsertGmailMessage`) into `func (s *Syncer) storeMessage(ctx context.Context, id, syncedAt string, maxBody int) (stored bool, msgUnix float64, err error)` and call it from both. `FetchRange` = list with `maxResults 0`, loop `storeMessage`, return the first error (wrapped with `%w`, so `gmail.ErrAuthRevoked` stays matchable). In `Sync`, reset `s.firstSyncFrom` at entry; when `watermark == 0` and the ID list succeeded, set `s.firstSyncFrom = now.AddDate(0, 0, -days)` (the same `days` used for `newer_than`). `AccountID()` returns `s.accountID`.

- [ ] **Step 6: IMAP — failing tests** (the package's fake server/`Client` seam): `SearchRange` sends `SINCE <since> BEFORE <before>`; `FetchRange` stores everything in range uncapped with the dialed UIDVALIDITY and leaves `GetImapWatermark` untouched; `Sync` with `lastUID == 0 && uidValidity == 0` marks `FirstSyncFrom()` = `now − InitialHistoryDays`; a UIDVALIDITY-reset resync (`uidValidity != 0`) does **not**.

- [ ] **Step 7: IMAP implementation.**
```go
func (cl *Client) SearchRange(since, before time.Time) ([]uint32, error) {
	data, err := cl.c.UIDSearch(&imap.SearchCriteria{Since: since, Before: before}, nil).Wait()
	// …same result handling as SearchSince
}
```
(Mirror `SearchSince`'s exact call/return shape.) `FetchRange`: `Dial`, `SearchRange(from, to)`, sort, `FetchUIDs` in batches of `MaxMessagesPerSync` (default 100), `s.upsertImapMessage(row, syncedAt)` with the dialed UIDVALIDITY; close the client. No `recordAuthResult`. `firstSyncFrom` reset at `Sync` entry; set when the pre-sync watermark had `lastUID == 0 && uidValidity == 0` and the search succeeded.

- [ ] **Step 8:** `go test ./internal/sync ./internal/gmail ./internal/imap` → PASS; `make lint-diff`; commit `feat(sync): range fetch and first-sync signal for Slack, Gmail, IMAP`.

---

### Task 4: Chunk-scoped channel digests and daily rollups

**Files:**
- Modify: `internal/db/digests.go` (new query), `internal/digest/pipeline.go` (`stampConsidered` :554, `applyDigestCooldown` :899, a `backfill` field on `Pipeline`)
- Create: `internal/digest/backfill.go`, `internal/digest/backfill_test.go`, test for the query in `internal/db/digests_test.go`

**Interfaces — Produces:**
```go
// internal/db
type ChannelRangeCandidate struct {
	ChannelID      string
	NewestInRange  float64 // newest message ts in (from, to]
	LastDigestInRange float64 // max channel-digest period_to with period_to in (from, to], 0 if none
}
func (db *DB) ChannelsWithMessagesInRange(from, to float64) ([]ChannelRangeCandidate, error)
// internal/digest
type BackfillWindowResult struct{ Digests int; Complete bool }
func (p *Pipeline) RunBackfillWindow(ctx context.Context, from, to float64) (BackfillWindowResult, *Usage, error)
func (p *Pipeline) RunBackfillRollups(ctx context.Context, from, to float64) error
```

Behaviour of `RunBackfillWindow` (read the spec's "Digest windows inside a chunk"):
- returns `{0, true}` with no AI call when `cfg.Digest.Enabled` is false;
- takes the digest lock (`acquireDigestLock`); on contention returns `{0, false}`, nil error — the chunk is retried next cycle;
- sets `p.backfill = &backfillScope{considered: map[string]float64{}}` for its duration (and `defer p.backfill = nil`): while set, `stampConsidered` records `max` into that map **instead of** the DB, and `applyDigestCooldown` returns its input unchanged;
- loops passes (at most 20): candidates from `ChannelsWithMessagesInRange(from, to)`; per channel `since = max(from, LastDigestInRange, considered[ch], fastForwardTS)`; keep it when `NewestInRange > since`; none kept → `Complete=true`; otherwise `runChannelWindows(ctx, windows, to)`; a pass in which no channel's `since` moved → return error `digest backfill: no progress in [from,to]`; ctx cancelled → return `{n, false}`, `ctx.Err()`;
- usage: snapshot the three usage atomics before and return only the delta (the pipeline is shared with the forward phase).

`RunBackfillRollups(from, to)`: digest lock; for each UTC day `d` from `utcDayStart(from)` while `d < to`: `runDailyRollupForDate(ctx, d)`; returns the first error after trying all days. It never touches the daemon's rollup attempt budget (that lives in the daemon).

- [ ] **Step 1: Failing DB test** (`digests_test.go`): seed messages for `C1` at ts 110, 150, 190 and `C2` at 250; a channel digest for `C1` with period 100→150 and one with period 300→400; `ChannelsWithMessagesInRange(100, 200)` → only `C1`, `NewestInRange=190`, `LastDigestInRange=150` (the 400 digest is outside).

- [ ] **Step 2: Implement the query:**
```go
func (db *DB) ChannelsWithMessagesInRange(from, to float64) ([]ChannelRangeCandidate, error) {
	rows, err := db.Query(`
		SELECT m.channel_id, MAX(m.ts_unix),
		       COALESCE((SELECT MAX(d.period_to) FROM digests d
		                 WHERE d.type = 'channel' AND d.channel_id = m.channel_id
		                   AND d.period_to > ? AND d.period_to <= ?), 0)
		FROM messages m
		WHERE m.ts_unix > ? AND m.ts_unix <= ?
		GROUP BY m.channel_id
		ORDER BY m.channel_id`, from, to, from, to)
	// scan into ChannelRangeCandidate; wrap errors "querying channels with messages in range: %w"
}
```

- [ ] **Step 3: Failing pipeline tests** in `backfill_test.go`, built with the package's existing test pipeline/mock generator helpers (see `channel_window_test.go`):
  - `TestRunBackfillWindow_DigestsChunk` — messages in (from,to] for two channels → digests stored with `period_from >= from`, `period_to <= to`, `Complete=true`.
  - `TestRunBackfillWindow_OverLoadCap` — one channel with `db.DefaultTimeRangeLimit + 50` messages in range → two digests, `Complete=true`.
  - `TestRunBackfillWindow_DeclinedChannelDoesNotLoop` — generator returns "no digest" for the channel → returns `Complete=true` after the considered map passes it; `channels.digest_considered_ts` in the DB unchanged.
  - `TestRunBackfillWindow_LowActivityChannelNotCooledDown` — a channel digested 1 minute ago (forward digest, `created_at` now) with 2 messages in the backfill range → still digested.
  - `TestRunBackfillWindow_ForwardWindowUnaffected` — forward digest for `C1` period 1000→2000 exists; backfill [500,1000) creates its digest; then `resolveChannelWindows(3000)` still gives `C1` since = 2000.
  - `TestRunBackfillWindow_DisabledIsComplete` — `Digest.Enabled=false` → `{0,true}`, no generator call.
  - `TestRunBackfillRollups_EachUTCDay` — channel digests on two UTC days in the range → two `daily` rows.

- [ ] **Step 4:** `go test ./internal/db ./internal/digest -run 'ChannelsWithMessagesInRange|RunBackfill'` → FAIL.
- [ ] **Step 5: Implement** `backfill.go` per the behaviour above, plus in `pipeline.go`:
```go
// backfillScope is set only while RunBackfillWindow runs: a backfill window
// sits below every forward mark, so its "considered" stamps stay in memory
// and the trickle-channel cooldown (meant for the live edge) does not apply.
type backfillScope struct{ considered map[string]float64 }
```
`stampConsidered`: `if p.backfill != nil { if tsUnix > p.backfill.considered[channelID] { p.backfill.considered[channelID] = tsUnix }; return }` before the DB write. `applyDigestCooldown`: `if p.backfill != nil { return entries }` first.
- [ ] **Step 6:** `go test ./internal/digest ./internal/db` → PASS; `make lint-diff`; commit `feat(digest): chunk-scoped backfill digests and rollups`.

---

### Task 5: Plan-limit gate

**Files:** Create `internal/planusage/gate.go`, `internal/planusage/gate_test.go`.

**Interfaces — Produces:** `func NearLimit(st *db.PlanUsageStatus) bool`

- [ ] **Step 1: Failing table test:**

```go
func TestNearLimit(t *testing.T) {
	lim := func(key, state string) string {
		return fmt.Sprintf(`{"key":%q,"group":"x","percent":50,"projection":{"state":%q}}`, key, state)
	}
	cases := []struct {
		name string
		st   *db.PlanUsageStatus
		want bool
	}{
		{"no row", nil, false},
		{"status not ok", &db.PlanUsageStatus{State: "stale", LimitsJSON: "[" + lim("session", "hit") + "]"}, false},
		{"session will_hit", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("session", "will_hit") + "]"}, true},
		{"weekly_all hit", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("weekly_all", "hit") + "]"}, true},
		{"scoped weekly ignored", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("weekly_scoped:fable", "hit") + "]"}, false},
		{"safe", &db.PlanUsageStatus{State: "ok", LimitsJSON: "[" + lim("session", "safe") + "]"}, false},
		{"bad json", &db.PlanUsageStatus{State: "ok", LimitsJSON: "{"}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { assert.Equal(t, c.want, NearLimit(c.st)) })
	}
}
```

- [ ] **Step 2:** FAIL. **Step 3: Implement:**

```go
// NearLimit reports whether background AI work should wait: the 5-hour or the
// weekly (all models) limit is projected to be hit, or is hit. Anything it
// cannot read — no row, a status other than ok, malformed limits — does not
// block: the per-step budgets still hold (docs/features/history-backfill.md).
func NearLimit(st *db.PlanUsageStatus) bool {
	if st == nil || st.State != "ok" {
		return false
	}
	var limits []Limit
	if err := json.Unmarshal([]byte(st.LimitsJSON), &limits); err != nil {
		return false
	}
	for _, l := range limits {
		if l.Key != "session" && l.Key != "weekly_all" {
			continue
		}
		if l.Projection.State == "will_hit" || l.Projection.State == "hit" {
			return true
		}
	}
	return false
}
```
- [ ] **Step 4:** `go test ./internal/planusage` → PASS; `make lint-diff`; commit `feat(planusage): NearLimit gate`.

---

### Task 6: `internal/historybackfill` — the chunk loop

**Files:** Create `internal/historybackfill/runner.go`, `internal/historybackfill/chunk.go`, `internal/historybackfill/runner_test.go`, `internal/historybackfill/chunk_test.go`.

**Interfaces — Consumes:** Task 1 DB helpers, `planusage.NearLimit` (Task 5).
**Produces:**
```go
const ChunkDays = 2
const MaxChunkFailures = 3

// Source fetches one account's raw data for a range. Process runs the AI
// steps over that range. Auth reports whether the account can be used now.
type Source interface {
	Kind() string        // slack | gmail | imap
	AccountID() int64
	Fetch(ctx context.Context, from, to time.Time) error
	Process(ctx context.Context, from, to time.Time) (complete bool, err error)
}
type AccountState int
const (AccountOK AccountState = iota; AccountRevoked; AccountGone)

type Store interface { // satisfied by *db.DB
	ListHistoryBackfills() ([]db.HistoryBackfill, error)
	AdvanceHistoryBackfill(id int64, reachedTS float64, now time.Time) error
	RecordHistoryBackfillFailure(id int64, msg string, now time.Time) (int, error)
	SetHistoryBackfillStatus(id int64, status string, now time.Time) error
	SetHistoryBackfillWaiting(id int64, waiting string, now time.Time) error
	GetPlanUsageStatus() (*db.PlanUsageStatus, error)
}

type Runner struct {
	Store    Store
	Sources  []Source                                   // the cycle's wired sources
	Account  func(kind string, id int64) AccountState   // auth/removal lookup
	OnSlackDone func(ctx context.Context, floor time.Time) // once, when every slack row is done
	Budget   time.Duration                              // 5 min
	Now      func() time.Time
	Logger   *log.Logger
}

// Step runs one cycle: at most one chunk per running source, within Budget.
func (r *Runner) Step(ctx context.Context) error

func NextChunk(reached, floor float64) (from, to float64, ok bool) // chunk.go, pure
```

Step behaviour, per row in id order, stopping when `Budget` has elapsed or `ctx` is done:
1. `status == done|off` → skip. Look up `Account(kind, id)`: `AccountGone` → `off`; `AccountRevoked` → `paused` (skip); `AccountOK` and `paused` → back to `running`.
2. No wired `Source` for the row (feature off or wiring failed) → skip this cycle, no state change.
3. `NextChunk(reached, floor)`; `!ok` → `AdvanceHistoryBackfill(id, floor)` (marks done).
4. `Fetch` the chunk. Error → failure path.
5. Plan gate: `NearLimit(GetPlanUsageStatus())` → `SetHistoryBackfillWaiting(id, "plan_limit")`, **do not advance**, and stop the whole Step (log once). The fetch is repeated next cycle — upserts make that harmless.
6. `Process`. Error → failure path. `complete == false` (budget cut, lock held) → leave the row, stop the Step.
7. Success → `AdvanceHistoryBackfill(id, from)`.
Failure path: `n := RecordHistoryBackfillFailure(id, err.Error())`; if `n >= MaxChunkFailures` → log loudly and `AdvanceHistoryBackfill(id, from)` (skip the chunk; `last_error` is cleared by Advance, so log it with the source and range first). A revoked-auth error from Fetch (`Account` says revoked on the next lookup) pauses the row on the next cycle.
After the loop: if at least one slack row exists and every slack row is `done` and this Step moved one of them to done, call `OnSlackDone(ctx, minFloor)` — exactly once per install (the transition is the trigger, so a restart never repeats it).

- [ ] **Step 1: Failing tests** — `chunk_test.go`:
```go
func TestNextChunk(t *testing.T) {
	day := 86400.0
	from, to, ok := NextChunk(10*day, 0)
	assert.True(t, ok); assert.Equal(t, 8*day, from); assert.Equal(t, 10*day, to)
	from, to, ok = NextChunk(day, 0)
	assert.True(t, ok); assert.Equal(t, 0.0, from); assert.Equal(t, day, to) // clamped to the floor
	_, _, ok = NextChunk(0, 0)
	assert.False(t, ok)
}
```
`runner_test.go` with an in-memory `fakeStore` (rows slice + recorded calls + a settable plan status) and `fakeSource{kind, id, fetchErr, processErr, complete, calls}`:
  - `TestRunner_NewestChunkFirst` — row reached=30d floor=0 → one Fetch/Process over [28d,30d), reached becomes 28d.
  - `TestRunner_OneChunkPerSourcePerStep` — two rows, both advance once.
  - `TestRunner_FinishesAtFloor` — reached = floor → status done.
  - `TestRunner_ThreeFailuresSkipChunk` — Process fails 3 Steps in a row → third Step advances past the chunk.
  - `TestRunner_PlanGateHoldsChunk` — plan `will_hit` on `session` → Fetch called, Process not, reached unchanged, waiting = plan_limit; gate clears → next Step processes and waiting is cleared.
  - `TestRunner_IncompleteProcessHolds` — `complete=false` → reached unchanged, no failure recorded.
  - `TestRunner_RevokedPausesAndResumes` — `Account` returns revoked → paused, no Fetch; returns OK → running and fetched.
  - `TestRunner_RemovedAccountTurnsOff` — `AccountGone` → off.
  - `TestRunner_BudgetStopsStep` — `Now` advances past Budget after the first source → second source untouched.
  - `TestRunner_SlackDoneHookOnce` — last slack row reaches the floor → `OnSlackDone` called once with the floor; another Step → not again.
  - `TestRunner_NoSourceWiredSkips` — row with no matching Source → untouched.

- [ ] **Step 2:** `go test ./internal/historybackfill` → FAIL.
- [ ] **Step 3:** Implement `chunk.go` (`NextChunk`: `to = reached; from = max(reached − ChunkDays·86400, floor); ok = reached > floor`) and `runner.go` per the behaviour list. Package doc comment points at `docs/features/history-backfill.md`.
- [ ] **Step 4:** PASS; `make lint-diff`; commit `feat(historybackfill): chunk loop`.

---

### Task 7: Daemon — phase, start hooks, memory gate, wiring

**Files:**
- Create: `internal/daemon/history_backfill.go`, `internal/daemon/history_backfill_test.go`
- Modify: `internal/daemon/daemon.go` (`runSync` :437–506 — add `d.phaseHistoryBackfill(ctx)` as the last line; `phaseSlackSync` :625, `phaseGmailSync` :753, `phaseImapSync` :768 — start hooks; `phaseMemory` :1533 — gate), `internal/daemon/daemon_gates_test.go` (a gate case)

**Interfaces — Consumes:** Tasks 1–6. Daemon fields `orchestrators`, `gmailSyncers`, `imapSyncers`, `digestPipe`, `ideasPipe`, `inboxPipe`, `peoplePipe`, `db`, `config`, `logger`.

- [ ] **Step 1: Failing tests** (package `daemon`, `newQuietDaemon(t)` + `db.OpenTestDB(t)` + `d.SetDB`):
  - `TestStartHistoryBackfill_FromFirstSync` — `d.startHistoryBackfill("slack", 1, from)` with `BackfillDays=30` → row with floor = now−30d, upper = from.
  - `TestStartHistoryBackfill_OffOrAlreadyDeep` — `BackfillDays=0` → no row; `from <= floor` → no row.
  - `TestPhaseMemory_SkipsWhileBackfillActive` — a `running` row → memory pipeline's `Run` not called (use the existing memory test seam in daemon tests; if none, assert via the `memoryOpen` hook not being reached) and one log line; row `done` → runs.
  - `TestPhaseHistoryBackfill_NoRowsNoRun` — no rows → no `pipeline_runs` row (add the case to `daemon_gates_test.go` with `assertNoPipelineRuns`).
  - `TestHistoryBackfill_SlackSourceProcess` — with a stub digest generator: a `slackSource.Process` over a range calls `RunBackfillWindow` then `RunBackfillRollups`, and with `Digest.Enabled=false` returns complete with no AI call.
  - `TestHistoryBackfill_AccountState` — Slack account `status='revoked'` → `AccountRevoked`; `removed`/missing → `AccountGone`; Google/IMAP missing → `AccountGone`, `auth_state='revoked'` → `AccountRevoked`.

- [ ] **Step 2:** `go test ./internal/daemon -run 'HistoryBackfill|SkipsWhileBackfill'` → FAIL.

- [ ] **Step 3: Implement `history_backfill.go`:**

```go
// startHistoryBackfill records a source's backfill right after its first
// sync (docs/features/history-backfill.md). from is that sync's window start.
func (d *Daemon) startHistoryBackfill(kind string, accountID int64, from time.Time) {
	days := d.config.Sync.BackfillDays
	if days <= 0 || d.db == nil {
		return
	}
	now := time.Now()
	floor := now.AddDate(0, 0, -days)
	if !from.After(floor) {
		return
	}
	created, err := d.db.StartHistoryBackfill(kind, accountID, float64(floor.Unix()), float64(from.Unix()), now)
	if err != nil {
		d.logger.Printf("history backfill: start %s account %d: %v", kind, accountID, err)
		return
	}
	if created {
		d.logger.Printf("history backfill: %s account %d — loading %s back to %s", kind, accountID,
			from.Format("2006-01-02"), floor.Format("2006-01-02"))
	}
}
```
Hooks: in `phaseSlackSync` after each `o.Run` returns nil: `if from, ok := o.FirstSyncFrom(); ok { d.startHistoryBackfill("slack", o.AccountID(), from) }`. Same after each Gmail/IMAP `Sync` returns nil (`"gmail"`/`"imap"`, `s.AccountID()`).

Sources (unexported types in the same file):
- `slackSource{o *sync.Orchestrator, d *Daemon}` — `Fetch` = `o.BackfillSearch`; `Process`: `if !d.config.Digest.Enabled || d.digestPipe == nil { return true, nil }`, `res, _, err := d.digestPipe.RunBackfillWindow(ctx, from, to)`; on `err`/`!res.Complete` return; then `d.digestPipe.RunBackfillRollups(ctx, from, to)`; return `true, err`.
- `gmailSource{s *gmail.Syncer, d *Daemon}` — `Fetch` = `s.FetchRange`; `Process`: `if d.ideasPipe == nil || !d.config.Streams.Enabled { return true, nil }`; `release, err := ideas.AcquireBackfillLock(d.config.WorkspaceDir(), "daemon history backfill")`; on err return `false, nil` (held → retry next cycle); `defer release()`; `_, err = d.ideasPipe.Backfill(ctx, from, to, nil)`; return `err == nil, err`.
- `imapSource{s *imap.Syncer}` — `Fetch` = `s.FetchRange`; `Process` returns `true, nil`.

`accountState(kind, id)`: Slack via the account row's `status` (`revoked` → revoked; `removed` or not found → gone); Google via `GetGoogleAccount`-style lookup (not found → gone; `auth_state == "revoked"` → revoked); IMAP via the email account lookup (not found → gone; IMAP has no revoked state). Use the existing DB getters — read `internal/db/{slack,google,email}_accounts.go` for the exact names.

`onSlackBackfillDone(ctx, floor)`: if `Inbox.Enabled && inboxPipe != nil` → `d.inboxPipe.BackfillMentions(ctx, floor, false)` (log result/error); if `People.Enabled && Digest.Enabled && peoplePipe != nil` → `d.trackedPipelineRun("people-backfill", …)` around `d.peoplePipe.RunForWindow(ctx, float64(floor.Unix()), float64(time.Now().Unix()))` with usage from `AccumulatedUsage()` deltas. Neither touches `lastPeople` nor the attempt budgets.

```go
func (d *Daemon) phaseHistoryBackfill(ctx context.Context) {
	if d.db == nil {
		return
	}
	active, err := d.db.HasActiveHistoryBackfill()
	if err != nil || !active {
		if err != nil {
			d.logger.Printf("history backfill: %v", err)
		}
		return
	}
	r := &historybackfill.Runner{
		Store: d.db, Sources: d.historyBackfillSources(), Account: d.accountState,
		OnSlackDone: d.onSlackBackfillDone, Budget: 5 * time.Minute, Now: time.Now, Logger: d.logger,
	}
	d.trackedPipelineRun("history-backfill", func() pipelineRunStats {
		return pipelineRunStats{err: r.Step(ctx)}
	})
}
```
`historyBackfillSources()` builds one source per wired orchestrator / Gmail syncer / IMAP syncer.

Memory gate in `phaseMemory`, right after the `Memory.Enabled` check:
```go
	if active, err := d.db.HasActiveHistoryBackfill(); err == nil && active {
		d.logger.Printf("memory: waiting for the history backfill to finish")
		return
	}
```
(Guard `d.db != nil` as the surrounding code does.)

- [ ] **Step 4:** `go test ./internal/daemon` → PASS (whole package: the gate table and phase-order tests live there). `go test ./cmd -run 'Sync|Daemon'` for the wiring compile.
- [ ] **Step 5:** `make lint-diff`; commit `feat(daemon): history backfill phase, start hooks, memory gate`.

---

### Task 8: CLI — `watchtower backfill status`

**Files:** Create `cmd/backfill.go`, `cmd/backfill_test.go`.

**Interfaces — Produces:** command `backfill status [--json]`; JSON (pinned keys): `{"backfills":[{"source":"slack","account_id":1,"status":"running","waiting":"","days_total":30,"days_done":12,"last_error":"","started_at":"…","done_at":null}]}`. `days_total = round((upper−floor)/86400)`, `days_done = round((upper−reached)/86400)`.

- [ ] **Step 1: Failing test** — seed a row through `db.Open` on a temp workspace (copy the setup of `cmd/usage_plan_test.go`), run the command with `--json`, assert the pinned keys and day math; text mode prints `slack #1  running  12/30 days` and `No history backfill.` for an empty table.
- [ ] **Step 2:** FAIL. **Step 3:** Implement in the `cmd/usage_plan.go` shape (`backfillCmd` + `backfillStatusCmd`, `openDBFromConfig`, `json.NewEncoder(cmd.OutOrStdout())` with `SetIndent("", "  ")`).
- [ ] **Step 4:** `go test ./cmd -run Backfill` → PASS; `make lint-diff`; commit `feat(cli): backfill status`.

---

### Task 9: Desktop — progress line in the status bar and tray

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/BackfillQueries.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/BackfillProgress.swift`, `WatchtowerDesktop/Tests/Core/BackfillQueriesTests.swift`, `WatchtowerDesktop/Tests/Core/BackfillProgressTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/StatusBarView.swift` (its 30 s reload + HStack), `WatchtowerDesktop/Sources/Views/TrayMenuView.swift` (`TrayMenuContent` gets `var backfillLine: String? = nil`, rendered under the status text; `TrayMenuView` feeds it), the tray's existing ViewInspector test file.

**Interfaces — Produces:**
```swift
package struct BackfillRow: Equatable {
    package let status: String      // running | paused | done | off
    package let waiting: String     // "" | plan_limit
    package let floorTS: Double
    package let upperTS: Double
    package let reachedTS: Double
}
package enum BackfillQueries {
    package static func rows(_ db: Database) throws -> [BackfillRow]
}
package enum BackfillProgress {
    /// nil when nothing is loading (no rows, or every row done/off).
    package static func line(_ rows: [BackfillRow]) -> String?
}
```
`line`: consider rows with status running|paused; none → nil. If any considered row has `waiting == "plan_limit"` → `"Loading history paused — Claude plan limit"`. Otherwise totals summed over considered rows: `M = Σ round((upper−floor)/86400)`, `N = Σ round((upper−reached)/86400)` → `"Loading history: N of M days"`.

- [ ] **Step 1: Failing tests** (`Tests/Core`, the `PlanUsageQueriesTests` shape, `TestDatabase.create()`): `rows` reads inserted rows; `line` — empty → nil; all done → nil; one running at 12 of 30 → "Loading history: 12 of 30 days"; two running (slack 10/28, gmail 4/23) → "Loading history: 14 of 51 days"; any plan_limit → the paused copy. Tray test: `TrayMenuContent(… backfillLine: "Loading history: 1 of 30 days")` shows that text; nil shows nothing.
- [ ] **Step 2:** `make test-swift FILTER='BackfillQueriesTests|BackfillProgressTests'` → FAIL.
- [ ] **Step 3:** Implement the query (`Row.fetchAll(db, sql: "SELECT status, waiting, floor_ts, upper_ts, reached_ts FROM history_backfill ORDER BY id")`) and `line`. In `StatusBarView` load `BackfillProgress.line(try BackfillQueries.rows(db))` in the same `dbPool.read` as the workspace stats and show it as a secondary `Text` when non-nil. In `TrayMenuView` read it the same way the view reads its other DB-backed values (follow the file; if it has no DB read, add the line to `AppState`'s existing 30 s status refresh rather than a new timer — check `docs/review/review-rules.md` "Swift / Desktop conventions" first).
- [ ] **Step 4:** `make test-swift FILTER='BackfillQueriesTests|BackfillProgressTests|TrayMenu'` → PASS; `make lint-swift`; commit `feat(desktop): history backfill progress line`.

---

### Task 10: Docs and inventory

**Files:** Create `docs/features/history-backfill.md`. Modify `CLAUDE.md` (Feature Notes list — one line after "First run"), `docs/features/first-run.md` and `docs/features/onboarding-v2.md` (one cross-link sentence each), the inventory files for digest, daemon and sync (`docs/inventory/README.md` maps them) with new entries `BACKFILL-01..03`.

- [ ] **Step 1:** Write the feature note: what starts a backfill (first sync with no cursor; existing sources never), the table and its states, the phase (last in `runSync`, 5-min budget, one 2-day chunk per source, newest first), each source's fetch, what processing runs per kind, the one-time Slack-done hooks (mention backfill, people window), memory gate, digest scope (in-memory considered map, no cooldown, forward marks untouched), plan gate (`planusage.NearLimit`), failures (3 strikes, pause on revoke, off on removal), CLI and Desktop surfaces, v1 limits (copy from the spec).
- [ ] **Step 2:** Inventory entries, each naming its guard test:
  - BACKFILL-01 — only a first sync starts a backfill (`TestStartHistoryBackfill_*`, `FirstSyncFrom` tests).
  - BACKFILL-02 — backfill digests never move forward marks (`TestRunBackfillWindow_ForwardWindowUnaffected`, `..._DeclinedChannelDoesNotLoop`).
  - BACKFILL-03 — the plan gate holds processing, never the fetch's idempotency (`TestRunner_PlanGateHoldsChunk`, `TestNearLimit`).
- [ ] **Step 3:** Commit `docs: history backfill feature note and inventory`.

---

## Phase gate (controller, once, before the PR)

`bash scripts/dev-health.sh`; `make test`; `make test-swift`; `make lint-all`; `go test ./cmd/...`. Then the `local-review` skill (final PR → `debate-review`).
