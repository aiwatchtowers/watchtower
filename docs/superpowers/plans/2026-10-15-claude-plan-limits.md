# Claude Plan Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the owner's Claude subscription limits (5-hour, weekly, per-model weekly) with a "when do I hit it" projection in the menu bar, on a new Usage → Claude plan tab, and as macOS notifications.

**Architecture:** A new Go package `internal/planusage` reads the Claude Code OAuth token read-only, polls `api.anthropic.com/api/oauth/usage` every 5 min from a daemon goroutine, stores samples + a singleton status row (migration 00115) and computes the projection. The Desktop reads that row every 30 s (the daemon is another process, so GRDB observation never fires) and renders the menu bar text, tray rows, the Usage tab and notifications. `watchtower usage plan [--json] [--now]` exposes the same row.

**Tech Stack:** Go 1.26, `database/sql` + `modernc.org/sqlite`, goose migrations, cobra; SwiftUI + GRDB + Swift Charts (macOS 14+).

**Spec:** `docs/superpowers/specs/2026-10-15-claude-plan-limits-design.md`

## Global Constraints

- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: watchtower/<version>`; HTTP timeout 15 s.
- Credentials: Keychain service `Claude Code-credentials` via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`; fallback `~/.claude/.credentials.json`; JSON object `claudeAiOauth` with `accessToken`, `expiresAt` (ms epoch), `subscriptionType`.
- **Never refresh the token, never write the credentials, never log/store/argv the token.**
- Poll interval 5 min; first poll 10 s after daemon start; failure backoff 5 → 10 → 20 → 30 min (cap).
- Samples kept 8 days.
- Projection lookback: session 60 min, weekly 24 h; "collecting" while samples span < 15 min; rate epsilon 0.01 %/h; same-window tolerance ±60 s on `resets_at`.
- UI thresholds: normal < 70 %, warning 70–89 % or `will_hit`, critical ≥ 90 % or `hit`; values greyed when `fetched_at` is older than 15 min or state ≠ ok.
- Feature id `claude-plan-limits`, config key `plan_usage.enabled`, default on.
- Notifications: one per `(limit_key, resets_at)` for `will_hit` (only `session`, `weekly_all`) and one per `(limit_key, resets_at)` at ≥ 90 % (every limit).
- Naming in UI: "Claude plan" (account-wide), never "Claude Code limits".
- Public repo: fixtures use synthetic values only; no real account data.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); full gate once at the end.

## Review Focus

1. A 5-hour window that has not started (`resets_at: null`, percent 0) → limit shown as 0 % with state `idle`, no crash, no projection noise. *(Task 2 parser test + Task 4 projection test)*
2. A window reset between two polls (`resets_at` jumps) → projection starts over at `collecting`; old-window samples never bend the new slope. *(Task 4 test `TestProject_NewWindowIgnoresOldSamples`)*
3. The Mac slept for hours → status `fetched_at` old; UI greys values instead of presenting them as current. *(Task 8 test `testStaleWhenFetchedLongAgo`)*
4. The Keychain is locked or `security` fails → `unavailable/no_credentials`, no network request, the token never appears in `last_error`. *(Task 3 + Task 5 guard test)*
5. Already at ≥ 100 % → state `hit`, critical tone, one 90 % notification, no "will hit at" sentence in the past. *(Task 4 + Task 8 + Task 11 tests)*

---

## File Structure

Go:
- `internal/db/migrations/00115_plan_usage.sql` — tables.
- `internal/db/plan_usage.go` (+ `_test.go`) — sample/status store methods on `*db.DB`.
- `internal/planusage/parse.go` — response → `Usage`.
- `internal/planusage/credentials.go` — read-only token source.
- `internal/planusage/projection.go` — `Project`.
- `internal/planusage/client.go` — HTTP fetch.
- `internal/planusage/poller.go` — `Poller.PollOnce` / `Run`, `MarkDisabled`.
- `internal/planusage/*_test.go`, `internal/planusage/testdata/*.json`.
- `internal/config/{config.go,defaults.go}` — `PlanUsageConfig`.
- `internal/features/registry.go` — `claude-plan-limits`.
- `internal/daemon/plan_usage.go` — goroutine start/stop.
- `cmd/plan_usage_daemon.go` — wiring; `cmd/usage_plan.go` — CLI.

Swift (`WatchtowerDesktop/Sources`):
- `WatchtowerCore/Models/PlanUsage.swift` — records + decoded limits.
- `WatchtowerCore/Database/Queries/PlanUsageQueries.swift`.
- `WatchtowerCore/Services/PlanUsagePresentation.swift` — pure presentation.
- `WatchtowerCore/Services/PlanUsageNoticePolicy.swift` — pure notification policy.
- `Services/PlanUsageCenter.swift` — 30 s reader, refresh, notifier.
- `Views/Usage/ClaudePlanView.swift` — the tab.
- Modified: `App/AppState.swift`, `App/WatchtowerApp.swift`, `Views/TrayMenuView.swift`, `Views/Usage/UsageView.swift`, `Services/NotificationService.swift`, `WatchtowerCore/Services/OnboardingFeaturePlan.swift`.

---

### Task 1: Migration 00115 + store

**Files:**
- Create: `internal/db/migrations/00115_plan_usage.sql`, `internal/db/plan_usage.go`, `internal/db/plan_usage_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)

**Interfaces:**
- Produces:
  ```go
  type PlanUsageSample struct { LimitKey string; TakenAt time.Time; Percent float64; ResetsAt time.Time } // zero ResetsAt = window not started
  type PlanUsageStatus struct {
      State, Reason, Plan string
      FetchedAt *time.Time
      LastError string
      LastErrorAt *time.Time
      LimitsJSON, BreakdownJSON string
      UpdatedAt time.Time
  }
  func (db *DB) InsertPlanUsageSamples(samples []PlanUsageSample) error
  func (db *DB) PlanUsageSamplesSince(limitKey string, since time.Time) ([]PlanUsageSample, error) // ascending taken_at
  func (db *DB) PrunePlanUsageSamples(before time.Time) (int64, error)
  func (db *DB) UpsertPlanUsageStatus(s PlanUsageStatus) error
  func (db *DB) GetPlanUsageStatus() (*PlanUsageStatus, error) // nil, nil when no row
  ```

- [ ] **Step 1: Use the `add-migration` skill** and write the migration (note `disabled` in the CHECK — a refinement of the spec so the Desktop can say "Turned off" from the one row):

```sql
-- +goose Up
CREATE TABLE plan_usage_samples (
    taken_at   TEXT NOT NULL,
    limit_key  TEXT NOT NULL,
    percent    REAL NOT NULL,
    resets_at  TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (limit_key, taken_at)
);

CREATE TABLE plan_usage_status (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    state          TEXT NOT NULL CHECK (state IN ('ok','stale','unavailable','error','disabled')),
    reason         TEXT NOT NULL DEFAULT '',
    plan           TEXT NOT NULL DEFAULT '',
    fetched_at     TEXT,
    last_error     TEXT NOT NULL DEFAULT '',
    last_error_at  TEXT,
    limits_json    TEXT NOT NULL DEFAULT '[]',
    breakdown_json TEXT NOT NULL DEFAULT '[]',
    updated_at     TEXT NOT NULL
);

-- +goose Down
DROP TABLE plan_usage_status;
DROP TABLE plan_usage_samples;
```

Mirror both tables into `internal/db/schema.sql` with a one-line comment each; add `"plan_usage_samples", "plan_usage_status"` to `TestAllTablesExist`.

- [ ] **Step 2: Write the failing store test** `internal/db/plan_usage_test.go`:

```go
func TestPlanUsageSamples_InsertQueryPrune(t *testing.T) {
	d := openTestDB(t)
	t0 := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	reset := t0.Add(3 * time.Hour)
	require.NoError(t, d.InsertPlanUsageSamples([]PlanUsageSample{
		{LimitKey: "session", TakenAt: t0, Percent: 4, ResetsAt: reset},
		{LimitKey: "session", TakenAt: t0.Add(5 * time.Minute), Percent: 6, ResetsAt: reset},
		{LimitKey: "weekly_all", TakenAt: t0, Percent: 59},
	}))
	got, err := d.PlanUsageSamplesSince("session", t0.Add(time.Minute))
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, 6.0, got[0].Percent)
	assert.True(t, got[0].ResetsAt.Equal(reset))

	weekly, err := d.PlanUsageSamplesSince("weekly_all", t0.Add(-time.Hour))
	require.NoError(t, err)
	require.Len(t, weekly, 1)
	assert.True(t, weekly[0].ResetsAt.IsZero(), "empty resets_at round-trips as zero time")

	n, err := d.PrunePlanUsageSamples(t0.Add(time.Minute))
	require.NoError(t, err)
	assert.Equal(t, int64(2), n)
}

func TestPlanUsageStatus_UpsertGet(t *testing.T) {
	d := openTestDB(t)
	got, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Nil(t, got)

	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	require.NoError(t, d.UpsertPlanUsageStatus(PlanUsageStatus{State: "ok", Plan: "max", FetchedAt: &now, LimitsJSON: `[{"key":"session"}]`, BreakdownJSON: "[]", UpdatedAt: now}))
	require.NoError(t, d.UpsertPlanUsageStatus(PlanUsageStatus{State: "error", Reason: "http_429", Plan: "max", FetchedAt: &now, LastError: "HTTP 429", LastErrorAt: &now, LimitsJSON: `[{"key":"session"}]`, BreakdownJSON: "[]", UpdatedAt: now}))
	got, err = d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "error", got.State)
	assert.Equal(t, "http_429", got.Reason)
	require.NotNil(t, got.FetchedAt)
	assert.True(t, got.FetchedAt.Equal(now))
	assert.Equal(t, `[{"key":"session"}]`, got.LimitsJSON)
}
```

(Use the package's existing test opener — `grep -n "func openTestDB\|func newTestDB" internal/db/*_test.go`; adapt the name if it differs.)

- [ ] **Step 3: Run** `go test ./internal/db -run 'PlanUsage|TestAllTablesExist'` — expect FAIL (undefined methods).

- [ ] **Step 4: Implement `internal/db/plan_usage.go`.** Times are stored as whole-second `time.RFC3339` UTC strings; zero `ResetsAt` is stored as `''`; nullable times use `sql.NullString`.

```go
package db

import (
	"database/sql"
	"fmt"
	"time"
)

// PlanUsageSample is one poll's percent of one Claude plan limit
// (spec 2026-10-15 "Storage"). A zero ResetsAt means the window has not started.
type PlanUsageSample struct {
	LimitKey string
	TakenAt  time.Time
	Percent  float64
	ResetsAt time.Time
}

// PlanUsageStatus is the singleton plan_usage_status row the daemon writes and
// the Desktop and `usage plan` read; LimitsJSON already carries the projection.
type PlanUsageStatus struct {
	State, Reason, Plan       string
	FetchedAt                 *time.Time
	LastError                 string
	LastErrorAt               *time.Time
	LimitsJSON, BreakdownJSON string
	UpdatedAt                 time.Time
}

func planTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	// Whole seconds, fixed width: string comparison in SQL then matches time
	// order (RFC3339Nano trims trailing zeros, so "…00.5Z" < "…00Z").
	return t.UTC().Truncate(time.Second).Format(time.RFC3339)
}

func parsePlanTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	return time.Parse(time.RFC3339, s) // also accepts a fractional part
}

func planNullTime(t *time.Time) sql.NullString {
	if t == nil {
		return sql.NullString{}
	}
	return sql.NullString{String: planTime(*t), Valid: true}
}

// InsertPlanUsageSamples writes one poll's samples in one transaction; a
// repeated (limit_key, taken_at) is ignored.
func (db *DB) InsertPlanUsageSamples(samples []PlanUsageSample) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("plan usage samples: begin: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit
	for _, s := range samples {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO plan_usage_samples (taken_at, limit_key, percent, resets_at) VALUES (?, ?, ?, ?)`,
			planTime(s.TakenAt), s.LimitKey, s.Percent, planTime(s.ResetsAt)); err != nil {
			return fmt.Errorf("plan usage samples: insert %s: %w", s.LimitKey, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("plan usage samples: commit: %w", err)
	}
	return nil
}

// PlanUsageSamplesSince returns limitKey's samples taken at or after since,
// oldest first.
func (db *DB) PlanUsageSamplesSince(limitKey string, since time.Time) ([]PlanUsageSample, error) {
	rows, err := db.Query(`SELECT taken_at, percent, resets_at FROM plan_usage_samples
		WHERE limit_key = ? AND taken_at >= ? ORDER BY taken_at`, limitKey, planTime(since))
	if err != nil {
		return nil, fmt.Errorf("plan usage samples: query %s: %w", limitKey, err)
	}
	defer rows.Close()
	var out []PlanUsageSample
	for rows.Next() {
		var taken, resets string
		s := PlanUsageSample{LimitKey: limitKey}
		if err := rows.Scan(&taken, &s.Percent, &resets); err != nil {
			return nil, fmt.Errorf("plan usage samples: scan: %w", err)
		}
		if s.TakenAt, err = parsePlanTime(taken); err != nil {
			return nil, fmt.Errorf("plan usage samples: taken_at %q: %w", taken, err)
		}
		if s.ResetsAt, err = parsePlanTime(resets); err != nil {
			return nil, fmt.Errorf("plan usage samples: resets_at %q: %w", resets, err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// PrunePlanUsageSamples deletes samples taken before the cutoff.
func (db *DB) PrunePlanUsageSamples(before time.Time) (int64, error) {
	res, err := db.Exec(`DELETE FROM plan_usage_samples WHERE taken_at < ?`, planTime(before))
	if err != nil {
		return 0, fmt.Errorf("plan usage samples: prune: %w", err)
	}
	return res.RowsAffected()
}

// UpsertPlanUsageStatus replaces the singleton status row.
func (db *DB) UpsertPlanUsageStatus(s PlanUsageStatus) error {
	_, err := db.Exec(`INSERT INTO plan_usage_status
		(id, state, reason, plan, fetched_at, last_error, last_error_at, limits_json, breakdown_json, updated_at)
		VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET state=excluded.state, reason=excluded.reason, plan=excluded.plan,
		fetched_at=excluded.fetched_at, last_error=excluded.last_error, last_error_at=excluded.last_error_at,
		limits_json=excluded.limits_json, breakdown_json=excluded.breakdown_json, updated_at=excluded.updated_at`,
		s.State, s.Reason, s.Plan, planNullTime(s.FetchedAt), s.LastError, planNullTime(s.LastErrorAt),
		s.LimitsJSON, s.BreakdownJSON, planTime(s.UpdatedAt))
	if err != nil {
		return fmt.Errorf("plan usage status: upsert: %w", err)
	}
	return nil
}

// GetPlanUsageStatus reads the singleton row; nil, nil before the first write.
func (db *DB) GetPlanUsageStatus() (*PlanUsageStatus, error) {
	var s PlanUsageStatus
	var fetched, lastErrAt sql.NullString
	var updated string
	err := db.QueryRow(`SELECT state, reason, plan, fetched_at, last_error, last_error_at, limits_json, breakdown_json, updated_at
		FROM plan_usage_status WHERE id = 1`).Scan(&s.State, &s.Reason, &s.Plan, &fetched, &s.LastError, &lastErrAt, &s.LimitsJSON, &s.BreakdownJSON, &updated)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("plan usage status: read: %w", err)
	}
	for _, p := range []struct {
		src sql.NullString
		dst **time.Time
	}{{fetched, &s.FetchedAt}, {lastErrAt, &s.LastErrorAt}} {
		if p.src.Valid && p.src.String != "" {
			t, err := parsePlanTime(p.src.String)
			if err != nil {
				return nil, fmt.Errorf("plan usage status: time %q: %w", p.src.String, err)
			}
			*p.dst = &t
		}
	}
	if s.UpdatedAt, err = parsePlanTime(updated); err != nil {
		return nil, fmt.Errorf("plan usage status: updated_at %q: %w", updated, err)
	}
	return &s, nil
}
```

- [ ] **Step 5: Regenerate** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then run `go test ./internal/db` — expect PASS.

- [ ] **Step 6: Commit** `feat(planusage): migration 00115 plan_usage tables and store`.

---

### Task 2: Response parser

**Files:**
- Create: `internal/planusage/parse.go`, `internal/planusage/parse_test.go`, `internal/planusage/testdata/usage_full.json`, `usage_legacy.json`, `usage_idle.json`

**Interfaces:**
- Produces:
  ```go
  type Projection struct {
      State       string     `json:"state"`        // idle | collecting | safe | will_hit | hit
      HitAt       *time.Time `json:"hit_at"`
      RatePerHour float64    `json:"rate_per_hour"`
  }
  type Limit struct {
      Key        string     `json:"key"`        // session | weekly_all | weekly_scoped:<slug>
      Label      string     `json:"label"`      // "5-hour" | "Weekly" | "Weekly · Fable"
      Group      string     `json:"group"`      // session | weekly
      Percent    float64    `json:"percent"`    // clamped 0..100
      ResetsAt   *time.Time `json:"resets_at"`  // nil = window not started
      Severity   string     `json:"severity"`
      Projection Projection `json:"projection"`
  }
  type BreakdownRow struct { Key string `json:"key"`; Label string `json:"label"`; Percent float64 `json:"percent"` }
  type Usage struct { Limits []Limit; Breakdown []BreakdownRow }
  var ErrNoLimits = errors.New("planusage: response has no usable limit")
  func Parse(body []byte) (Usage, error)
  ```

- [ ] **Step 1: Write fixtures.** `testdata/usage_full.json` (synthetic):

```json
{
  "five_hour": {"utilization": 4.0, "resets_at": "2026-10-15T10:59:59.534461+00:00"},
  "seven_day": {"utilization": 59.0, "resets_at": "2026-10-19T15:59:59.534479+00:00"},
  "some_future_key": {"x": 1},
  "limits": [
    {"kind": "session", "group": "session", "percent": 4, "severity": "normal", "resets_at": "2026-10-15T10:59:59.534461+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_all", "group": "weekly", "percent": 59, "severity": "normal", "resets_at": "2026-10-19T15:59:59.534479+00:00", "scope": null, "is_active": true},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 104, "severity": "critical", "resets_at": "2026-10-19T15:59:59.534620+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
  ],
  "seven_day_breakdown": {"rows": [
    {"key": "claude_code", "display_name": "Claude Code", "percent": 80},
    {"key": "chat", "display_name": "Chats", "percent": 20}
  ]}
}
```

`usage_legacy.json`: only `five_hour` (`utilization` 12.5) and `seven_day` (`utilization` 30) plus `"seven_day_opus": {"utilization": 7, "resets_at": "2026-10-19T15:59:59Z"}`, `"seven_day_sonnet": null`, no `limits`.

`usage_idle.json`: `{"limits": [{"kind": "session", "group": "session", "percent": 0, "resets_at": null}, {"kind": "weekly_all", "group": "weekly", "percent": 10, "resets_at": "2026-10-19T15:59:59Z"}]}`.

- [ ] **Step 2: Write failing tests** `parse_test.go`:

```go
func load(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return b
}

func TestParse_LimitsArray(t *testing.T) {
	u, err := Parse(load(t, "usage_full.json"))
	require.NoError(t, err)
	require.Len(t, u.Limits, 3)
	assert.Equal(t, "session", u.Limits[0].Key)
	assert.Equal(t, "5-hour", u.Limits[0].Label)
	assert.Equal(t, "weekly_all", u.Limits[1].Key)
	assert.Equal(t, "Weekly", u.Limits[1].Label)
	assert.Equal(t, "weekly_scoped:fable", u.Limits[2].Key)
	assert.Equal(t, "Weekly · Fable", u.Limits[2].Label)
	assert.Equal(t, 100.0, u.Limits[2].Percent, "clamped")
	require.NotNil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, 10, u.Limits[0].ResetsAt.UTC().Hour())
	require.Len(t, u.Breakdown, 2)
	assert.Equal(t, BreakdownRow{Key: "claude_code", Label: "Claude Code", Percent: 80}, u.Breakdown[0])
}

func TestParse_LegacyFallback(t *testing.T) {
	u, err := Parse(load(t, "usage_legacy.json"))
	require.NoError(t, err)
	keys := []string{}
	for _, l := range u.Limits {
		keys = append(keys, l.Key)
	}
	assert.Equal(t, []string{"session", "weekly_all", "weekly_scoped:opus"}, keys)
	assert.Equal(t, 12.5, u.Limits[0].Percent)
	assert.Nil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, "Weekly · Opus", u.Limits[2].Label)
}

func TestParse_IdleWindowHasNilReset(t *testing.T) {
	u, err := Parse(load(t, "usage_idle.json"))
	require.NoError(t, err)
	assert.Nil(t, u.Limits[0].ResetsAt)
	assert.Equal(t, 0.0, u.Limits[0].Percent)
}

func TestParse_Errors(t *testing.T) {
	for name, body := range map[string]string{
		"garbage": "not json",
		"empty":   "{}",
		"nulls":   `{"five_hour": null, "seven_day": null, "limits": null}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := Parse([]byte(body))
			assert.Error(t, err)
		})
	}
	_, err := Parse([]byte("{}"))
	assert.ErrorIs(t, err, ErrNoLimits)
}
```

- [ ] **Step 3: Run** `go test ./internal/planusage` — expect FAIL.

- [ ] **Step 4: Implement `parse.go`:**

```go
// Package planusage reads the owner's Claude plan limits (5-hour, weekly,
// per-model weekly) from the endpoint Claude Code's /usage reads, stores
// samples and projects when each limit is hit (spec 2026-10-15).
package planusage

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

var ErrNoLimits = errors.New("planusage: response has no usable limit")

type rawWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type rawLimit struct {
	Kind     string   `json:"kind"`
	Group    string   `json:"group"`
	Percent  *float64 `json:"percent"`
	Severity string   `json:"severity"`
	ResetsAt *string  `json:"resets_at"`
	Scope    *struct {
		Model *struct {
			DisplayName string `json:"display_name"`
		} `json:"model"`
		Surface json.RawMessage `json:"surface"`
	} `json:"scope"`
}

type rawResponse struct {
	FiveHour  *rawWindow `json:"five_hour"`
	SevenDay  *rawWindow `json:"seven_day"`
	Opus      *rawWindow `json:"seven_day_opus"`
	Sonnet    *rawWindow `json:"seven_day_sonnet"`
	Limits    []rawLimit `json:"limits"`
	Breakdown *struct {
		Rows []struct {
			Key         string  `json:"key"`
			DisplayName string  `json:"display_name"`
			Percent     float64 `json:"percent"`
		} `json:"rows"`
	} `json:"seven_day_breakdown"`
}

// Parse turns the endpoint's body into limits; unknown keys are ignored and
// every field is optional. limits[] wins; the five_hour/seven_day objects are
// the fallback for responses without it.
func Parse(body []byte) (Usage, error) {
	var r rawResponse
	if err := json.Unmarshal(body, &r); err != nil {
		return Usage{}, fmt.Errorf("planusage: decode: %w", err)
	}
	var u Usage
	for _, l := range r.Limits {
		if lim, ok := fromRawLimit(l); ok {
			u.Limits = append(u.Limits, lim)
		}
	}
	if len(u.Limits) == 0 {
		for _, w := range []struct {
			key, label, group string
			win               *rawWindow
		}{
			{"session", "5-hour", "session", r.FiveHour},
			{"weekly_all", "Weekly", "weekly", r.SevenDay},
			{"weekly_scoped:opus", "Weekly · Opus", "weekly", r.Opus},
			{"weekly_scoped:sonnet", "Weekly · Sonnet", "weekly", r.Sonnet},
		} {
			if w.win == nil || w.win.Utilization == nil {
				continue
			}
			u.Limits = append(u.Limits, Limit{Key: w.key, Label: w.label, Group: w.group,
				Percent: clampPercent(*w.win.Utilization), ResetsAt: parseReset(w.win.ResetsAt)})
		}
	}
	if len(u.Limits) == 0 {
		return Usage{}, ErrNoLimits
	}
	if r.Breakdown != nil {
		for _, row := range r.Breakdown.Rows {
			u.Breakdown = append(u.Breakdown, BreakdownRow{Key: row.Key, Label: row.DisplayName, Percent: row.Percent})
		}
	}
	return u, nil
}

func fromRawLimit(l rawLimit) (Limit, bool) {
	if l.Percent == nil || l.Kind == "" {
		return Limit{}, false
	}
	lim := Limit{Group: l.Group, Percent: clampPercent(*l.Percent), Severity: l.Severity, ResetsAt: parseReset(l.ResetsAt)}
	switch l.Kind {
	case "session":
		lim.Key, lim.Label = "session", "5-hour"
	case "weekly_all":
		lim.Key, lim.Label = "weekly_all", "Weekly"
	default:
		name := scopeName(l)
		if name == "" {
			lim.Key, lim.Label = l.Kind, l.Kind
		} else {
			lim.Key, lim.Label = l.Kind+":"+slug(name), "Weekly · "+name
		}
	}
	if lim.Group == "" {
		lim.Group = "weekly"
		if lim.Key == "session" {
			lim.Group = "session"
		}
	}
	return lim, true
}

func scopeName(l rawLimit) string {
	if l.Scope == nil {
		return ""
	}
	if l.Scope.Model != nil && l.Scope.Model.DisplayName != "" {
		return l.Scope.Model.DisplayName
	}
	var s string
	if json.Unmarshal(l.Scope.Surface, &s) == nil && s != "" {
		return s
	}
	var obj struct {
		DisplayName string `json:"display_name"`
	}
	if json.Unmarshal(l.Scope.Surface, &obj) == nil {
		return obj.DisplayName
	}
	return ""
}

func slug(s string) string { return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), " ", "-") }

func clampPercent(p float64) float64 { return math.Max(0, math.Min(100, p)) }

func parseReset(s *string) *time.Time {
	if s == nil || *s == "" {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, *s)
	if err != nil {
		return nil
	}
	t = t.UTC()
	return &t
}
```

Put the exported types (`Projection`, `Limit`, `BreakdownRow`, `Usage`) at the top of `parse.go` exactly as in the Interfaces block.

- [ ] **Step 5: Run** `go test ./internal/planusage` — expect PASS. **Step 6: Commit** `feat(planusage): parse the oauth usage response`.

---

### Task 3: Read-only credentials

**Files:**
- Create: `internal/planusage/credentials.go`, `internal/planusage/credentials_test.go`

**Interfaces:**
- Produces:
  ```go
  type Credentials struct { AccessToken string; ExpiresAt time.Time; Plan string }
  type CommandRunner func(ctx context.Context, name string, args ...string) ([]byte, error)
  type CredentialSource struct { Run CommandRunner; HomeDir string; UseKeychain bool }
  func DefaultCredentialSource() CredentialSource
  func (s CredentialSource) Load(ctx context.Context) (Credentials, error)
  var ErrNoCredentials = errors.New("planusage: no Claude Code credentials")
  ```

- [ ] **Step 1: Failing tests:**

```go
const credJSON = `{"claudeAiOauth":{"accessToken":"tok-SECRET","refreshToken":"r-SECRET","expiresAt":1760522400000,"subscriptionType":"max"}}`

func TestCredentials_Keychain(t *testing.T) {
	var gotArgs []string
	s := CredentialSource{UseKeychain: true, HomeDir: t.TempDir(), Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
		gotArgs = append([]string{name}, args...)
		return []byte(credJSON + "\n"), nil
	}}
	c, err := s.Load(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "tok-SECRET", c.AccessToken)
	assert.Equal(t, "max", c.Plan)
	assert.Equal(t, time.UnixMilli(1760522400000).UTC(), c.ExpiresAt)
	assert.Equal(t, []string{"/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"}, gotArgs)
}

func TestCredentials_FileFallback(t *testing.T) {
	home := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", ".credentials.json"), []byte(credJSON), 0o600))
	s := CredentialSource{UseKeychain: true, HomeDir: home, Run: func(context.Context, string, ...string) ([]byte, error) {
		return nil, errors.New("exit status 44")
	}}
	c, err := s.Load(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "tok-SECRET", c.AccessToken)
}

func TestCredentials_NoneAnywhere(t *testing.T) {
	s := CredentialSource{UseKeychain: true, HomeDir: t.TempDir(), Run: func(context.Context, string, ...string) ([]byte, error) {
		return nil, errors.New("exit status 44")
	}}
	_, err := s.Load(context.Background())
	assert.ErrorIs(t, err, ErrNoCredentials)
}

func TestCredentials_ErrorsNeverCarryTheToken(t *testing.T) {
	s := CredentialSource{UseKeychain: true, HomeDir: t.TempDir(), Run: func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`{"claudeAiOauth":{"accessToken":"tok-SECRET"`), nil // truncated JSON
	}}
	_, err := s.Load(context.Background())
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "SECRET")
}
```

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement:**

```go
var ErrNoCredentials = errors.New("planusage: no Claude Code credentials")

const keychainService = "Claude Code-credentials"

// CredentialSource reads Claude Code's OAuth credentials read-only: the
// Keychain item first (macOS), then ~/.claude/.credentials.json. It never
// refreshes or writes them — a refresh rotates the refresh token and would sign
// Claude Code out (spec "Credentials").
type CredentialSource struct {
	Run         CommandRunner
	HomeDir     string
	UseKeychain bool
}

type CommandRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

func DefaultCredentialSource() CredentialSource {
	home, _ := os.UserHomeDir()
	return CredentialSource{
		Run: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return exec.CommandContext(ctx, name, args...).Output()
		},
		HomeDir:     home,
		UseKeychain: runtime.GOOS == "darwin",
	}
}

func (s CredentialSource) Load(ctx context.Context) (Credentials, error) {
	if s.UseKeychain && s.Run != nil {
		if out, err := s.Run(ctx, "/usr/bin/security", "find-generic-password", "-s", keychainService, "-w"); err == nil {
			return decodeCredentials(out)
		}
	}
	if s.HomeDir != "" {
		b, err := os.ReadFile(filepath.Join(s.HomeDir, ".claude", ".credentials.json"))
		if err == nil {
			return decodeCredentials(b)
		}
	}
	return Credentials{}, ErrNoCredentials
}

// decodeCredentials never wraps the JSON error: its text can quote the input.
func decodeCredentials(b []byte) (Credentials, error) {
	var raw struct {
		OAuth *struct {
			AccessToken      string `json:"accessToken"`
			ExpiresAt        int64  `json:"expiresAt"`
			SubscriptionType string `json:"subscriptionType"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(bytes.TrimSpace(b), &raw) != nil {
		return Credentials{}, errors.New("planusage: credentials are not valid JSON")
	}
	if raw.OAuth == nil || raw.OAuth.AccessToken == "" {
		return Credentials{}, ErrNoCredentials
	}
	c := Credentials{AccessToken: raw.OAuth.AccessToken, Plan: raw.OAuth.SubscriptionType}
	if raw.OAuth.ExpiresAt > 0 {
		c.ExpiresAt = time.UnixMilli(raw.OAuth.ExpiresAt).UTC()
	}
	return c, nil
}
```

- [ ] **Step 4: Run** — PASS. **Step 5: Commit** `feat(planusage): read-only Claude Code credentials`.

---

### Task 4: Projection

**Files:**
- Create: `internal/planusage/projection.go`, `internal/planusage/projection_test.go`

**Interfaces:**
- Consumes: `Limit`, `Projection` (Task 2), `db.PlanUsageSample` (Task 1).
- Produces:
  ```go
  func Lookback(group string) time.Duration // session: 1h, else 24h
  func Project(now time.Time, l Limit, samples []db.PlanUsageSample) Projection
  ```

- [ ] **Step 1: Failing table tests:**

```go
func at(h, m int) time.Time { return time.Date(2026, 10, 15, h, m, 0, 0, time.UTC) }
func ptr(t time.Time) *time.Time { return &t }

func series(reset time.Time, start time.Time, step time.Duration, pcts ...float64) []db.PlanUsageSample {
	out := make([]db.PlanUsageSample, len(pcts))
	for i, p := range pcts {
		out[i] = db.PlanUsageSample{LimitKey: "session", TakenAt: start.Add(time.Duration(i) * step), Percent: p, ResetsAt: reset}
	}
	return out
}

func TestProject(t *testing.T) {
	reset := at(13, 0)
	cases := []struct {
		name    string
		now     time.Time
		limit   Limit
		samples []db.PlanUsageSample
		state   string
		hitAt   *time.Time
	}{
		{"hit", at(10, 0), Limit{Group: "session", Percent: 100, ResetsAt: &reset}, nil, "hit", nil},
		{"idle window", at(10, 0), Limit{Group: "session", Percent: 0}, nil, "idle", nil},
		{"collecting", at(10, 10), Limit{Group: "session", Percent: 6, ResetsAt: &reset},
			series(reset, at(10, 0), 5*time.Minute, 4, 5, 6), "collecting", nil},
		{"flat is safe", at(10, 30), Limit{Group: "session", Percent: 10, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 10, 10, 10, 10), "safe", nil},
		// 10%/h for 30 min: 40 → 45 → 50 → 55 at 10:30; 45 % left → 4.5 h → 15:00 > reset 13:00 → safe
		{"slow is safe", at(10, 30), Limit{Group: "session", Percent: 55, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 40, 41.6667, 43.3333, 45), "safe", nil},
		// 60%/h: 40 at 10:00 → 70 at 10:30; 30 % left → 0.5 h → 11:00
		{"will hit", at(10, 30), Limit{Group: "session", Percent: 70, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 40, 50, 60, 70), "will_hit", ptr(at(11, 0))},
		{"decreasing floors to zero", at(10, 30), Limit{Group: "session", Percent: 30, ResetsAt: &reset},
			series(reset, at(10, 0), 10*time.Minute, 60, 50, 40, 30), "safe", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := Project(c.now, c.limit, c.samples)
			assert.Equal(t, c.state, p.State)
			if c.hitAt == nil {
				if c.state != "safe" {
					assert.Nil(t, p.HitAt)
				}
				return
			}
			require.NotNil(t, p.HitAt)
			assert.WithinDuration(t, *c.hitAt, *p.HitAt, time.Minute)
		})
	}
}

func TestProject_NewWindowIgnoresOldSamples(t *testing.T) {
	oldReset, newReset := at(10, 0), at(15, 0)
	samples := append(series(oldReset, at(9, 0), 10*time.Minute, 50, 70, 90),
		series(newReset, at(10, 1), 5*time.Minute, 0, 1)...)
	p := Project(at(10, 6), Limit{Group: "session", Percent: 1, ResetsAt: &newReset}, samples)
	assert.Equal(t, "collecting", p.State)
}

func TestProject_LookbackDropsOlderSamples(t *testing.T) {
	reset := at(23, 0)
	// a burst 3 h ago, flat for the last hour → session lookback (1 h) sees flat
	samples := append(series(reset, at(7, 0), 10*time.Minute, 0, 30, 60),
		series(reset, at(9, 30), 10*time.Minute, 60, 60, 60, 60)...)
	p := Project(at(10, 0), Limit{Group: "session", Percent: 60, ResetsAt: &reset}, samples)
	assert.Equal(t, "safe", p.State)
}

func TestLookback(t *testing.T) {
	assert.Equal(t, time.Hour, Lookback("session"))
	assert.Equal(t, 24*time.Hour, Lookback("weekly"))
}
```

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement:**

```go
const (
	minSpan       = 15 * time.Minute
	rateEpsilon   = 0.01 // percent per hour
	sameWindowTol = 60 * time.Second
)

// Lookback is how far back the rate is fitted: the 5-hour window reacts
// within the hour, the weekly one is smoothed over a day.
func Lookback(group string) time.Duration {
	if group == "session" {
		return time.Hour
	}
	return 24 * time.Hour
}

// Project fits a least-squares line through the limit's samples in the
// current window and lookback and says whether 100 % comes before the reset.
func Project(now time.Time, l Limit, samples []db.PlanUsageSample) Projection {
	if l.Percent >= 100 {
		return Projection{State: "hit"}
	}
	if l.ResetsAt == nil {
		return Projection{State: "idle"}
	}
	from := now.Add(-Lookback(l.Group))
	var xs, ys []float64
	var first, last time.Time
	for _, s := range samples {
		if s.TakenAt.Before(from) || s.TakenAt.After(now) || s.ResetsAt.IsZero() {
			continue
		}
		if d := s.ResetsAt.Sub(*l.ResetsAt); d > sameWindowTol || d < -sameWindowTol {
			continue
		}
		if first.IsZero() {
			first = s.TakenAt
		}
		last = s.TakenAt
		xs = append(xs, s.TakenAt.Sub(first).Hours())
		ys = append(ys, s.Percent)
	}
	if len(xs) < 2 || last.Sub(first) < minSpan {
		return Projection{State: "collecting"}
	}
	rate := math.Max(0, slope(xs, ys))
	if rate < rateEpsilon {
		return Projection{State: "safe"}
	}
	hit := now.Add(time.Duration((100 - l.Percent) / rate * float64(time.Hour)))
	p := Projection{RatePerHour: rate, HitAt: &hit, State: "will_hit"}
	if !hit.Before(*l.ResetsAt) {
		p.State = "safe"
	}
	return p
}

func slope(xs, ys []float64) float64 {
	n := float64(len(xs))
	var sx, sy, sxx, sxy float64
	for i := range xs {
		sx += xs[i]
		sy += ys[i]
		sxx += xs[i] * xs[i]
		sxy += xs[i] * ys[i]
	}
	den := n*sxx - sx*sx
	if den == 0 {
		return 0
	}
	return (n*sxy - sx*sy) / den
}
```

- [ ] **Step 4: Run** — PASS. **Step 5: Commit** `feat(planusage): project when a limit is hit`.

---

### Task 5: Client + Poller

**Files:**
- Create: `internal/planusage/client.go`, `internal/planusage/poller.go`, `internal/planusage/poller_test.go`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  ```go
  type HTTPError struct{ Status int }            // Error() = "HTTP <status>"
  type Client struct { HTTP *http.Client; URL string; UserAgent string }
  func NewClient(version string) Client
  func (c Client) Fetch(ctx context.Context, token string) ([]byte, error)

  type Store interface {
      InsertPlanUsageSamples([]db.PlanUsageSample) error
      PlanUsageSamplesSince(string, time.Time) ([]db.PlanUsageSample, error)
      PrunePlanUsageSamples(time.Time) (int64, error)
      UpsertPlanUsageStatus(db.PlanUsageStatus) error
      GetPlanUsageStatus() (*db.PlanUsageStatus, error)
  }
  type CredentialLoader interface{ Load(context.Context) (Credentials, error) }
  type Fetcher interface{ Fetch(context.Context, string) ([]byte, error) }
  type Poller struct { Store Store; Creds CredentialLoader; Client Fetcher; Now func() time.Time; Logger *log.Logger; failures int }
  const PollInterval = 5 * time.Minute
  func (p *Poller) PollOnce(ctx context.Context) (next time.Duration, err error)
  func (p *Poller) Run(ctx context.Context) error   // first poll after 10 s
  func MarkDisabled(store Store, now time.Time) error
  ```

- [ ] **Step 1: Failing tests** (`poller_test.go`, against a real `db.Open(":memory:")` store and a fake fetcher):

```go
type fakeCreds struct{ c Credentials; err error }
func (f fakeCreds) Load(context.Context) (Credentials, error) { return f.c, f.err }

type fakeFetch struct{ body []byte; err error; calls int; tokens []string }
func (f *fakeFetch) Fetch(_ context.Context, tok string) ([]byte, error) {
	f.calls++
	f.tokens = append(f.tokens, tok)
	return f.body, f.err
}

func newPoller(t *testing.T, creds fakeCreds, fetch *fakeFetch, now time.Time) (*Poller, *db.DB) {
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return &Poller{Store: d, Creds: creds, Client: fetch, Now: func() time.Time { return now }, Logger: log.New(io.Discard, "", 0)}, d
}

var validCreds = fakeCreds{c: Credentials{AccessToken: "tok-SECRET", ExpiresAt: at(23, 0), Plan: "max"}}

func TestPollOnce_OK(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	next, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	assert.Equal(t, PollInterval, next)
	st, err := d.GetPlanUsageStatus()
	require.NoError(t, err)
	assert.Equal(t, "ok", st.State)
	assert.Equal(t, "max", st.Plan)
	var limits []Limit
	require.NoError(t, json.Unmarshal([]byte(st.LimitsJSON), &limits))
	require.Len(t, limits, 3)
	assert.Equal(t, "collecting", limits[1].Projection.State)
	assert.Equal(t, "hit", limits[2].Projection.State)
	samples, err := d.PlanUsageSamplesSince("weekly_all", at(9, 0))
	require.NoError(t, err)
	assert.Len(t, samples, 1)
}

func TestPollOnce_BackoffKeepsLastNumbers(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	fetch.body, fetch.err = nil, &HTTPError{Status: 429}
	var delays []time.Duration
	for i := 0; i < 5; i++ {
		next, err := p.PollOnce(context.Background())
		require.Error(t, err)
		delays = append(delays, next)
	}
	assert.Equal(t, []time.Duration{5 * time.Minute, 10 * time.Minute, 20 * time.Minute, 30 * time.Minute, 30 * time.Minute}, delays)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "error", st.State)
	assert.Equal(t, "http_429", st.Reason)
	assert.Contains(t, st.LimitsJSON, "weekly_all", "last good numbers kept")
	require.NotNil(t, st.FetchedAt)
}

func TestPollOnce_401IsStale(t *testing.T) {
	fetch := &fakeFetch{err: &HTTPError{Status: 401}}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	next, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.Equal(t, PollInterval, next)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "stale", st.State)
	assert.Equal(t, "token_expired", st.Reason)
}

// PLANUSAGE-01 guard: an expired token is never sent and never refreshed.
func TestPlanUsage01_ExpiredTokenMakesNoRequest(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	creds := fakeCreds{c: Credentials{AccessToken: "tok-SECRET", ExpiresAt: at(9, 0)}}
	p, d := newPoller(t, creds, fetch, at(10, 0))
	_, _ = p.PollOnce(context.Background())
	assert.Zero(t, fetch.calls)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "stale", st.State)
	assert.Equal(t, "token_expired", st.Reason)
}

func TestPollOnce_NoCredentialsIsUnavailable(t *testing.T) {
	fetch := &fakeFetch{}
	p, d := newPoller(t, fakeCreds{err: ErrNoCredentials}, fetch, at(10, 0))
	_, _ = p.PollOnce(context.Background())
	assert.Zero(t, fetch.calls)
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "unavailable", st.State)
	assert.Equal(t, "no_credentials", st.Reason)
}

// PLANUSAGE-02 guard: the token never lands in the status row or an error.
func TestPlanUsage02_TokenNeverPersisted(t *testing.T) {
	fetch := &fakeFetch{err: fmt.Errorf("network: Bearer tok-SECRET refused")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, err := p.PollOnce(context.Background())
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "SECRET")
	st, _ := d.GetPlanUsageStatus()
	for _, s := range []string{st.LastError, st.Reason, st.LimitsJSON, st.BreakdownJSON, st.Plan} {
		assert.NotContains(t, s, "SECRET")
	}
}

func TestPollOnce_PrunesOldSamples(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	require.NoError(t, d.InsertPlanUsageSamples([]db.PlanUsageSample{{LimitKey: "session", TakenAt: at(10, 0).Add(-9 * 24 * time.Hour), Percent: 1}}))
	_, err := p.PollOnce(context.Background())
	require.NoError(t, err)
	old, _ := d.PlanUsageSamplesSince("session", at(10, 0).Add(-10*24*time.Hour))
	assert.Len(t, old, 1, "only the new sample is left")
}

func TestMarkDisabled_KeepsNumbers(t *testing.T) {
	fetch := &fakeFetch{body: load(t, "usage_full.json")}
	p, d := newPoller(t, validCreds, fetch, at(10, 0))
	_, _ = p.PollOnce(context.Background())
	require.NoError(t, MarkDisabled(d, at(10, 5)))
	st, _ := d.GetPlanUsageStatus()
	assert.Equal(t, "disabled", st.State)
	assert.Contains(t, st.LimitsJSON, "weekly_all")
}

func TestClient_Fetch(t *testing.T) {
	var got *http.Request
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"limits":[]}`))
	}))
	defer srv.Close()
	c := NewClient("1.2.3")
	c.URL = srv.URL
	body, err := c.Fetch(context.Background(), "tok")
	require.NoError(t, err)
	assert.JSONEq(t, `{"limits":[]}`, string(body))
	assert.Equal(t, "oauth-2025-04-20", got.Header.Get("anthropic-beta"))
	assert.Equal(t, "watchtower/1.2.3", got.Header.Get("User-Agent"))
	assert.Equal(t, http.MethodGet, got.Method)
	_, err = c.Fetch(context.Background(), "bad")
	var he *HTTPError
	require.ErrorAs(t, err, &he)
	assert.Equal(t, 401, he.Status)
}
```

(`at`, `load` come from Tasks 2/4 test files in the same package.)

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement `client.go`:**

```go
const usageURL = "https://api.anthropic.com/api/oauth/usage"

type HTTPError struct{ Status int }

func (e *HTTPError) Error() string { return fmt.Sprintf("HTTP %d", e.Status) }

type Client struct {
	HTTP      *http.Client
	URL       string
	UserAgent string
}

func NewClient(version string) Client {
	return Client{HTTP: &http.Client{Timeout: 15 * time.Second}, URL: usageURL, UserAgent: "watchtower/" + version}
}

// Fetch GETs the usage body. Errors never quote the request (it carries the token).
func (c Client) Fetch(ctx context.Context, token string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.URL, nil)
	if err != nil {
		return nil, errors.New("planusage: building request failed")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("User-Agent", c.UserAgent)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("planusage: request failed: %w", redact(err, token))
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &HTTPError{Status: resp.StatusCode}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("planusage: reading body: %w", err)
	}
	return body, nil
}

// redact strips the token from an error text, keeping the message.
func redact(err error, token string) error {
	if token == "" || !strings.Contains(err.Error(), token) {
		return err
	}
	return errors.New(strings.ReplaceAll(err.Error(), token, "<redacted>"))
}
```

Implement `poller.go`:

```go
const (
	PollInterval   = 5 * time.Minute
	maxBackoff     = 30 * time.Minute
	firstPollDelay = 10 * time.Second
	retention      = 8 * 24 * time.Hour
)

// PollOnce reads credentials, fetches, stores samples + status with the
// projection, prunes old samples, and returns the delay before the next poll.
func (p *Poller) PollOnce(ctx context.Context) (time.Duration, error) {
	now := p.Now().UTC().Truncate(time.Second)
	prev, err := p.Store.GetPlanUsageStatus()
	if err != nil {
		return PollInterval, err
	}
	st := db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]"}
	if prev != nil {
		st = *prev
	}
	st.UpdatedAt = now

	creds, err := p.Creds.Load(ctx)
	if err != nil {
		p.failures = 0
		st.State, st.Reason = "unavailable", "no_credentials"
		return PollInterval, p.save(st, err)
	}
	st.Plan = creds.Plan
	if !creds.ExpiresAt.IsZero() && !creds.ExpiresAt.After(now) {
		p.failures = 0
		st.State, st.Reason = "stale", "token_expired"
		return PollInterval, p.save(st, nil)
	}
	body, err := p.Client.Fetch(ctx, creds.AccessToken)
	if err == nil {
		var u Usage
		if u, err = Parse(body); err == nil {
			return PollInterval, p.storeUsage(now, st, u)
		}
		err = &parseError{err}
	}
	err = redact(err, creds.AccessToken)
	var he *HTTPError
	if errors.As(err, &he) && he.Status == http.StatusUnauthorized {
		p.failures = 0
		st.State, st.Reason = "stale", "token_expired"
		return PollInterval, p.fail(st, now, err)
	}
	p.failures++
	st.State, st.Reason = "error", reasonFor(err)
	return backoff(p.failures), p.fail(st, now, err)
}

type parseError struct{ error }

func reasonFor(err error) string {
	var he *HTTPError
	var pe *parseError
	switch {
	case errors.As(err, &he):
		return fmt.Sprintf("http_%d", he.Status)
	case errors.As(err, &pe):
		return "parse"
	default:
		return "network"
	}
}

func backoff(failures int) time.Duration {
	d := PollInterval << (failures - 1)
	if d > maxBackoff || d <= 0 {
		return maxBackoff
	}
	return d
}

func (p *Poller) storeUsage(now time.Time, st db.PlanUsageStatus, u Usage) error {
	samples := make([]db.PlanUsageSample, 0, len(u.Limits))
	for _, l := range u.Limits {
		s := db.PlanUsageSample{LimitKey: l.Key, TakenAt: now, Percent: l.Percent}
		if l.ResetsAt != nil {
			s.ResetsAt = *l.ResetsAt
		}
		samples = append(samples, s)
	}
	if err := p.Store.InsertPlanUsageSamples(samples); err != nil {
		return err
	}
	for i, l := range u.Limits {
		hist, err := p.Store.PlanUsageSamplesSince(l.Key, now.Add(-Lookback(l.Group)))
		if err != nil {
			return err
		}
		u.Limits[i].Projection = Project(now, l, hist)
	}
	limits, err := json.Marshal(u.Limits)
	if err != nil {
		return fmt.Errorf("planusage: encode limits: %w", err)
	}
	breakdown, err := json.Marshal(nonNil(u.Breakdown))
	if err != nil {
		return fmt.Errorf("planusage: encode breakdown: %w", err)
	}
	p.failures = 0
	st.State, st.Reason, st.LastError, st.LastErrorAt = "ok", "", "", nil
	st.FetchedAt = &now
	st.LimitsJSON, st.BreakdownJSON = string(limits), string(breakdown)
	if err := p.Store.UpsertPlanUsageStatus(st); err != nil {
		return err
	}
	if _, err := p.Store.PrunePlanUsageSamples(now.Add(-retention)); err != nil {
		p.Logger.Printf("plan usage: prune: %v", err)
	}
	return nil
}

func nonNil(rows []BreakdownRow) []BreakdownRow {
	if rows == nil {
		return []BreakdownRow{}
	}
	return rows
}

func (p *Poller) fail(st db.PlanUsageStatus, now time.Time, cause error) error {
	st.LastError, st.LastErrorAt = cause.Error(), &now
	return p.save(st, cause)
}

// save writes st and returns cause (or the write error when there is no cause).
func (p *Poller) save(st db.PlanUsageStatus, cause error) error {
	if err := p.Store.UpsertPlanUsageStatus(st); err != nil {
		return errors.Join(cause, err)
	}
	return cause
}

// Run polls until ctx ends: first after 10 s, then at PollOnce's delay.
func (p *Poller) Run(ctx context.Context) error {
	timer := time.NewTimer(firstPollDelay)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-timer.C:
			next, err := p.PollOnce(ctx)
			if err != nil && !errors.Is(err, ErrNoCredentials) {
				p.Logger.Printf("plan usage: %v (next poll in %s)", err, next)
			}
			timer.Reset(next)
		}
	}
}

// MarkDisabled records that the feature is off, keeping the last numbers.
func MarkDisabled(store Store, now time.Time) error {
	prev, err := store.GetPlanUsageStatus()
	if err != nil {
		return err
	}
	st := db.PlanUsageStatus{LimitsJSON: "[]", BreakdownJSON: "[]"}
	if prev != nil {
		st = *prev
	}
	st.State, st.Reason, st.UpdatedAt = "disabled", "", now.UTC()
	return store.UpsertPlanUsageStatus(st)
}
```

Note: `TestPollOnce_NoCredentialsIsUnavailable` and the `Run` log filter rely on `PollOnce` returning the `ErrNoCredentials`-wrapping error from `Load` — the daemon then stays quiet every 5 min for an owner without Claude Code.

- [ ] **Step 4: Run** `go test ./internal/planusage` — PASS; also `go test -race ./internal/planusage` once.
- [ ] **Step 5: Commit** `feat(planusage): client and poller with backoff and stale states`.

---

### Task 6: Config, feature registry, daemon wiring

**Files:**
- Modify: `internal/config/config.go`, `internal/config/defaults.go`, `internal/config/config_test.go`, `internal/features/registry.go`, `internal/features/registry_test.go`, `cmd/sync.go` (one line next to `wireAutomations`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingFeaturePlan.swift`
- Create: `internal/daemon/plan_usage.go`, `internal/daemon/plan_usage_test.go`, `cmd/plan_usage_daemon.go`

**Interfaces:**
- Consumes: `planusage.Poller`, `planusage.MarkDisabled`, `planusage.NewClient`, `planusage.DefaultCredentialSource`.
- Produces: `cfg.PlanUsage.Enabled`; `func (d *Daemon) SetPlanUsage(r PlanUsageRunner, disable func() error)`; `type PlanUsageRunner interface{ Run(ctx context.Context) error }`; `func newPlanUsagePoller(database *db.DB, logger *log.Logger) *planusage.Poller` in `cmd`.

- [ ] **Step 1: Failing tests.** In `config_test.go`:

```go
func TestConfig_PlanUsageDefaults(t *testing.T) {
	cfg, err := Load(writeTestConfig(t, ""))
	require.NoError(t, err)
	assert.True(t, cfg.PlanUsage.Enabled, "absent block = on")
	off, err := Load(writeTestConfig(t, "plan_usage:\n  enabled: false\n"))
	require.NoError(t, err)
	assert.False(t, off.PlanUsage.Enabled)
}
```

In `registry_test.go`: add `"claude-plan-limits": true,` to the default map in `TestRegistry_EnabledReadsConfig` and

```go
func TestRegistry_ClaudePlanLimitsEntry(t *testing.T) {
	f, ok := ByID("claude-plan-limits")
	require.True(t, ok)
	assert.Equal(t, "plan_usage.enabled", f.ConfigKey)
	assert.Equal(t, CostNone, f.Cost)
	assert.Equal(t, "gauge.with.dots.needle.67percent", f.Icon)
	assert.False(t, f.Core)
	assert.Empty(t, f.FeedsInto)
	assert.False(t, f.Enabled(loadConfig(t, "plan_usage:\n  enabled: false\n")))
}
```

In `internal/daemon/plan_usage_test.go` (follow the construction helper used by `automation_wake_test.go`):

```go
type fakePlanRunner struct{ started, stopped chan struct{} }
func (f *fakePlanRunner) Run(ctx context.Context) error { close(f.started); <-ctx.Done(); close(f.stopped); return nil }

func TestStartPlanUsage_RunsAndStops(t *testing.T) {
	d := newTestDaemon(t) // the helper automation_wake_test.go uses
	d.config.PlanUsage.Enabled = true
	r := &fakePlanRunner{started: make(chan struct{}), stopped: make(chan struct{})}
	d.SetPlanUsage(r, func() error { t.Fatal("disable called while on"); return nil })
	stop := d.startPlanUsage(context.Background())
	<-r.started
	stop()
	<-r.stopped
}

func TestStartPlanUsage_OffMarksDisabled(t *testing.T) {
	d := newTestDaemon(t)
	d.config.PlanUsage.Enabled = false
	called := false
	d.SetPlanUsage(&fakePlanRunner{started: make(chan struct{}), stopped: make(chan struct{})}, func() error { called = true; return nil })
	d.startPlanUsage(context.Background())()
	assert.True(t, called)
}
```

- [ ] **Step 2: Run** `go test ./internal/config ./internal/features ./internal/daemon -run 'PlanUsage|ClaudePlan|EnabledReadsConfig'` — FAIL.

- [ ] **Step 3: Implement.**

`config.go`:
```go
// PlanUsageConfig controls Claude plan limits — the daemon polls the owner's
// 5-hour and weekly Claude limits (spec 2026-10-15). No AI, no cost.
type PlanUsageConfig struct {
	Enabled bool `mapstructure:"enabled"` // poll the Claude plan usage endpoint (default: true)
}
```
Field `PlanUsage PlanUsageConfig \`mapstructure:"plan_usage"\`` on `Config`; `v.SetDefault("plan_usage.enabled", DefaultPlanUsageEnabled)`; `DefaultPlanUsageEnabled = true` in `defaults.go`. Not added to `legacyDigestOffFeatureKeys` (no AI).

`registry.go` (append after `automations`):
```go
	{
		ID:          "claude-plan-limits",
		Title:       "Claude plan limits",
		Description: "Shows how much of your Claude plan's 5-hour and weekly limits you have used — chats, Cowork and Claude Code together — and when you will hit them at your current pace. Reads the numbers with your Claude Code sign-in every 5 minutes; no AI, nothing else leaves your Mac.",
		Tagline:     "Know before you hit the wall",
		Benefits: []string{
			"5-hour and weekly usage in the menu bar",
			"A forecast of when you hit each limit",
			"A heads-up before you run out",
		},
		Icon:      "gauge.with.dots.needle.67percent",
		ConfigKey: "plan_usage.enabled",
		Cost:      CostNone,
		Enabled:   func(cfg *config.Config) bool { return cfg.PlanUsage.Enabled },
	},
```

`internal/daemon/plan_usage.go`:
```go
// PlanUsageRunner is the Claude plan limits poller (internal/planusage).
type PlanUsageRunner interface {
	Run(ctx context.Context) error
}

// SetPlanUsage attaches the poller and the "feature is off" writer.
func (d *Daemon) SetPlanUsage(r PlanUsageRunner, disable func() error) {
	d.planUsage, d.planUsageDisable = r, disable
}

// startPlanUsage runs the poller beside the sync loop when plan_usage.enabled
// is on; off, it records the disabled state once so the Desktop says so.
func (d *Daemon) startPlanUsage(ctx context.Context) (stop func()) {
	if d.planUsage == nil {
		return func() {}
	}
	if !d.config.PlanUsage.Enabled {
		if err := d.planUsageDisable(); err != nil {
			d.logger.Printf("plan usage: marking disabled: %v", err)
		}
		d.logger.Println("plan usage: disabled (plan_usage.enabled=false), poller not started")
		return func() {}
	}
	runCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := d.planUsage.Run(runCtx); err != nil {
			d.logger.Printf("plan usage: poller stopped: %v", err)
		}
	}()
	return func() {
		cancel()
		<-done
	}
}
```
Add fields `planUsage PlanUsageRunner; planUsageDisable func() error` to `Daemon`; in `Run`, right after `stopAutomations := …; defer stopAutomations()`, add `stopPlanUsage := d.startPlanUsage(ctx); defer stopPlanUsage()`.

`cmd/plan_usage_daemon.go`:
```go
// wirePlanUsage attaches the Claude plan limits poller (spec 2026-10-15); the
// daemon runs it when plan_usage.enabled is on and marks it disabled otherwise.
func wirePlanUsage(d *daemon.Daemon, database *db.DB, logger *log.Logger) {
	d.SetPlanUsage(newPlanUsagePoller(database, logger), func() error {
		return planusage.MarkDisabled(database, time.Now())
	})
}

func newPlanUsagePoller(database *db.DB, logger *log.Logger) *planusage.Poller {
	return &planusage.Poller{
		Store:  database,
		Creds:  planusage.DefaultCredentialSource(),
		Client: planusage.NewClient(Version),
		Now:    time.Now,
		Logger: logger,
	}
}
```
(`grep -n "Version" cmd/root.go cmd/version.go` for the version variable name; use it.) In `cmd/sync.go` add `wirePlanUsage(d, database, logger)` after `wireAutomations(...)`.

`OnboardingFeaturePlan.swift`: add `"claude-plan-limits"` to `unmanagedFeatureIDs` and extend the comment: "Claude plan limits cost nothing and need no goal."

- [ ] **Step 4: Run** `go test ./internal/config ./internal/features ./internal/daemon ./internal/planusage` and `go build ./...` — PASS; `make test-swift FILTER=OnboardingFeaturePlan` — PASS.
- [ ] **Step 5: Commit** `feat(planusage): feature flag, daemon poller wiring`.

---

### Task 7: CLI `watchtower usage plan`

**Files:**
- Create: `cmd/usage_plan.go`, `cmd/usage_plan_test.go`

**Interfaces:**
- Consumes: `db.GetPlanUsageStatus`, `planusage.Limit`, `planusage.BreakdownRow`, `newPlanUsagePoller`.
- Produces: JSON keys (pinned): `state, reason, plan, fetched_at, last_error, limits, breakdown`.

- [ ] **Step 1: Failing test** (follow the cmd test harness used by `cmd/status_test.go` for running a command against a temp config/DB; copy its setup helper):

```go
func TestUsagePlanJSON_PinnedKeys(t *testing.T) {
	database := setupCmdTestDB(t) // the helper status_test.go uses
	now := time.Date(2026, 10, 15, 8, 0, 0, 0, time.UTC)
	require.NoError(t, database.UpsertPlanUsageStatus(db.PlanUsageStatus{
		State: "ok", Plan: "max", FetchedAt: &now, UpdatedAt: now,
		LimitsJSON:    `[{"key":"session","label":"5-hour","group":"session","percent":4,"resets_at":"2026-10-15T10:59:59Z","severity":"normal","projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]`,
		BreakdownJSON: `[{"key":"chat","label":"Chats","percent":10}]`,
	}))
	out := runCmd(t, "usage", "plan", "--json")
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(out), &m))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	assert.Equal(t, []string{"breakdown", "fetched_at", "last_error", "limits", "plan", "reason", "state"}, keys)
}

func TestUsagePlanText_NoRowYet(t *testing.T) {
	setupCmdTestDB(t)
	out := runCmd(t, "usage", "plan")
	assert.Contains(t, out, "No Claude plan usage yet")
}
```

- [ ] **Step 2: Run** `go test ./cmd -run UsagePlan` — FAIL.

- [ ] **Step 3: Implement:**

```go
var usageCmd = &cobra.Command{Use: "usage", Short: "Usage of your AI plans"}

var usagePlanCmd = &cobra.Command{
	Use:   "plan",
	Short: "Claude plan limits (5-hour, weekly) and when you hit them",
	RunE:  runUsagePlan,
}

var (
	flagUsagePlanJSON bool
	flagUsagePlanNow  bool
)

func init() {
	usagePlanCmd.Flags().BoolVar(&flagUsagePlanJSON, "json", false, "print JSON")
	usagePlanCmd.Flags().BoolVar(&flagUsagePlanNow, "now", false, "poll once before printing")
	usageCmd.AddCommand(usagePlanCmd)
	rootCmd.AddCommand(usageCmd)
}

type usagePlanJSON struct {
	State     string                   `json:"state"`
	Reason    string                   `json:"reason"`
	Plan      string                   `json:"plan"`
	FetchedAt *time.Time               `json:"fetched_at"`
	LastError string                   `json:"last_error"`
	Limits    []planusage.Limit        `json:"limits"`
	Breakdown []planusage.BreakdownRow `json:"breakdown"`
}

func runUsagePlan(cmd *cobra.Command, _ []string) error {
	database, err := openDBFromConfig()
	if err != nil {
		return err
	}
	defer database.Close()
	var pollErr error
	if flagUsagePlanNow {
		_, pollErr = newPlanUsagePoller(database, log.New(io.Discard, "", 0)).PollOnce(cmd.Context())
	}
	st, err := database.GetPlanUsageStatus()
	if err != nil {
		return err
	}
	out := usagePlanJSON{Limits: []planusage.Limit{}, Breakdown: []planusage.BreakdownRow{}}
	if st != nil {
		out.State, out.Reason, out.Plan, out.FetchedAt, out.LastError = st.State, st.Reason, st.Plan, st.FetchedAt, st.LastError
		if err := json.Unmarshal([]byte(st.LimitsJSON), &out.Limits); err != nil {
			return fmt.Errorf("decoding limits: %w", err)
		}
		if err := json.Unmarshal([]byte(st.BreakdownJSON), &out.Breakdown); err != nil {
			return fmt.Errorf("decoding breakdown: %w", err)
		}
	}
	w := cmd.OutOrStdout()
	if flagUsagePlanJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if err := enc.Encode(out); err != nil {
			return err
		}
		return pollErr
	}
	if st == nil {
		fmt.Fprintln(w, "No Claude plan usage yet — the daemon polls every 5 minutes (or run `watchtower usage plan --now`).")
		return pollErr
	}
	fmt.Fprintf(w, "Claude plan (%s) — %s", out.Plan, out.State)
	if out.Reason != "" {
		fmt.Fprintf(w, " (%s)", out.Reason)
	}
	fmt.Fprintln(w)
	for _, l := range out.Limits {
		fmt.Fprintf(w, "  %-18s %5.1f%%  %s  %s\n", l.Label, l.Percent, resetText(l.ResetsAt), projectionText(l.Projection))
	}
	return pollErr
}

func resetText(t *time.Time) string {
	if t == nil {
		return "not started"
	}
	return "resets " + t.Local().Format("Mon 15:04")
}

func projectionText(p planusage.Projection) string {
	switch p.State {
	case "will_hit":
		return "hits " + p.HitAt.Local().Format("Mon 15:04")
	case "hit":
		return "limit reached"
	case "collecting":
		return "collecting data"
	case "idle":
		return ""
	default:
		return "won't hit before reset"
	}
}
```

- [ ] **Step 4: Run** `go test ./cmd -run UsagePlan` — PASS. Manual: `go run . usage plan --now` prints real numbers on the owner's Mac.
- [ ] **Step 5: Commit** `feat(planusage): watchtower usage plan`.

---

### Task 8: Swift Core — model, queries, presentation

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/PlanUsage.swift`, `…/Database/Queries/PlanUsageQueries.swift`, `…/Services/PlanUsagePresentation.swift`, `WatchtowerDesktop/Tests/Core/PlanUsagePresentationTests.swift`, `WatchtowerDesktop/Tests/Core/PlanUsageQueriesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  package struct PlanUsageProjection: Codable, Equatable { package let state: String; package let hitAt: Date?; package let ratePerHour: Double }
  package struct PlanUsageLimit: Codable, Equatable, Identifiable { key, label, group: String; percent: Double; resetsAt: Date?; severity: String?; projection: PlanUsageProjection; id = key }
  package struct PlanUsageBreakdownRow: Codable, Equatable, Identifiable { key, label: String; percent: Double }
  package struct PlanUsageStatus: Equatable { state, reason, plan: String; fetchedAt: Date?; lastError: String; limits: [PlanUsageLimit]; breakdown: [PlanUsageBreakdownRow] }
  package struct PlanUsageSample: Equatable { takenAt: Date; percent: Double; resetsAt: Date? }
  package enum PlanUsageQueries {
      static func status(_ db: Database) throws -> PlanUsageStatus?
      static func samples(_ db: Database, key: String, since: Date) throws -> [PlanUsageSample]
  }
  package enum PlanUsageTone { case normal, warning, critical, muted }
  package enum PlanUsagePresentation {
      static let staleAfter: TimeInterval = 15 * 60
      static func isStale(_ s: PlanUsageStatus, now: Date) -> Bool
      static func tone(_ l: PlanUsageLimit) -> PlanUsageTone
      static func menuBarText(_ s: PlanUsageStatus?) -> String?   // "5h 4% · 7d 59%" or nil
      static func menuBarWarning(_ s: PlanUsageStatus?, now: Date) -> Bool // worst of session/weekly_all is warning/critical and not stale
      static func resetText(_ l: PlanUsageLimit, now: Date) -> String
      static func projectionText(_ l: PlanUsageLimit, now: Date) -> String
      static func trayLine(_ l: PlanUsageLimit, now: Date) -> String
  }
  ```

Menu-bar colour: `MenuBarExtra` labels render as a template, so colour does not show. The plan renders the warning as a `⚠︎ ` prefix (`menuBarWarning`) instead — a refinement of the spec's "colour" that keeps the meaning.

- [ ] **Step 1: Failing tests** `PlanUsagePresentationTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class PlanUsagePresentationTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z")!

    func limit(_ key: String, _ pct: Double, state: String = "safe", hitAt: Date? = nil, resetsIn: TimeInterval? = 3 * 3600) -> PlanUsageLimit {
        PlanUsageLimit(key: key, label: key == "session" ? "5-hour" : "Weekly", group: key == "session" ? "session" : "weekly",
                       percent: pct, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, severity: "normal",
                       projection: PlanUsageProjection(state: state, hitAt: hitAt, ratePerHour: 0))
    }

    func status(_ limits: [PlanUsageLimit], state: String = "ok", fetchedAgo: TimeInterval = 60) -> PlanUsageStatus {
        PlanUsageStatus(state: state, reason: "", plan: "max", fetchedAt: now.addingTimeInterval(-fetchedAgo), lastError: "", limits: limits, breakdown: [])
    }

    func testMenuBarText() {
        let s = status([limit("session", 4.4), limit("weekly_all", 59), limit("weekly_scoped:fable", 4)])
        XCTAssertEqual(PlanUsagePresentation.menuBarText(s), "5h 4% · 7d 59%")
        XCTAssertNil(PlanUsagePresentation.menuBarText(nil))
        XCTAssertNil(PlanUsagePresentation.menuBarText(status([], state: "unavailable")))
        XCTAssertNil(PlanUsagePresentation.menuBarText(status([limit("session", 4)], state: "disabled")))
    }

    func testTone() {
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 69)), .normal)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 70)), .warning)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 10, state: "will_hit", hitAt: now)), .warning)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 90)), .critical)
        XCTAssertEqual(PlanUsagePresentation.tone(limit("session", 100, state: "hit")), .critical)
    }

    func testStaleWhenFetchedLongAgo() {
        XCTAssertFalse(PlanUsagePresentation.isStale(status([limit("session", 4)], fetchedAgo: 60), now: now))
        XCTAssertTrue(PlanUsagePresentation.isStale(status([limit("session", 4)], fetchedAgo: 16 * 60), now: now))
        XCTAssertTrue(PlanUsagePresentation.isStale(status([limit("session", 4)], state: "error"), now: now))
        XCTAssertFalse(PlanUsagePresentation.menuBarWarning(status([limit("session", 95)], fetchedAgo: 3600), now: now), "stale never warns")
        XCTAssertTrue(PlanUsagePresentation.menuBarWarning(status([limit("session", 95)]), now: now))
    }

    func testProjectionText() {
        let hit = now.addingTimeInterval(90 * 60)
        XCTAssertTrue(PlanUsagePresentation.projectionText(limit("session", 70, state: "will_hit", hitAt: hit), now: now)
            .hasPrefix("At this pace you hit it at "))
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 10), now: now), "You won't hit it before the reset")
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 10, state: "collecting"), now: now), "Collecting data…")
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 100, state: "hit"), now: now), "Limit reached")
        XCTAssertEqual(PlanUsagePresentation.projectionText(limit("session", 0, state: "idle", resetsIn: nil), now: now), "Window not started")
    }

    func testResetText() {
        XCTAssertEqual(PlanUsagePresentation.resetText(limit("session", 4, resetsIn: 3 * 3600 + 12 * 60), now: now).prefix(19), "Resets in 3 h 12 m ")
        XCTAssertEqual(PlanUsagePresentation.resetText(limit("session", 0, resetsIn: nil), now: now), "Not started")
    }
}
```

`PlanUsageQueriesTests.swift` (uses `TestDatabase` from `Tests/Support`, as other `Tests/Core/*QueriesTests` do):

```swift
final class PlanUsageQueriesTests: XCTestCase {
    func testStatusDecodesLimitsJSON() throws {
        let db = try TestDatabase.make()   // match the helper name other Core query tests use
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id, state, reason, plan, fetched_at, last_error, limits_json, breakdown_json, updated_at)
                VALUES (1, 'ok', '', 'max', '2026-10-15T08:00:00.123456789Z', '',
                 '[{"key":"session","label":"5-hour","group":"session","percent":4,"resets_at":"2026-10-15T10:59:59Z","severity":"normal","projection":{"state":"will_hit","hit_at":"2026-10-15T09:30:00Z","rate_per_hour":12.5}}]',
                 '[{"key":"chat","label":"Chats","percent":10}]', '2026-10-15T08:00:00Z')
                """)
            try db.execute(sql: "INSERT INTO plan_usage_samples VALUES ('2026-10-15T08:00:00Z','session',4,'2026-10-15T10:59:59Z'), ('2026-10-15T07:00:00Z','session',2,'')")
        }
        let s = try db.read { try PlanUsageQueries.status($0) }
        XCTAssertEqual(s?.limits.first?.projection.state, "will_hit")
        XCTAssertEqual(s?.limits.first?.projection.ratePerHour, 12.5)
        XCTAssertNotNil(s?.fetchedAt, "fractional seconds parse")
        XCTAssertEqual(s?.breakdown.first?.label, "Chats")
        let samples = try db.read { try PlanUsageQueries.samples($0, key: "session", since: .distantPast) }
        XCTAssertEqual(samples.count, 2)
        XCTAssertNil(samples.first?.resetsAt, "'' is nil")
    }

    func testStatusNilWithoutRow() throws {
        let db = try TestDatabase.make()
        XCTAssertNil(try db.read { try PlanUsageQueries.status($0) })
    }
}
```

- [ ] **Step 2: Run** `make test-swift FILTER='PlanUsagePresentationTests|PlanUsageQueriesTests'` — FAIL (build errors).

- [ ] **Step 3: Implement.** Date parsing: one helper `PlanUsageDates.parse(_ s: String?) -> Date?` that first strips any fractional-seconds part (`.` followed by digits before `Z`/offset — Go's `json.Marshal` writes `hit_at`/`resets_at` as RFC3339Nano with up to 9 digits, which `ISO8601DateFormatter` rejects) and then parses with `ISO8601DateFormatter` `[.withInternetDateTime]`; `""`/nil → nil. Add a test case for a 9-digit fraction. JSON decoding uses a `JSONDecoder` with `keyDecodingStrategy = .convertFromSnakeCase` and `dateDecodingStrategy = .custom` calling the same helper (throwing `DecodingError.dataCorruptedError` on failure). Queries:

```swift
package enum PlanUsageQueries {
    package static func status(_ db: Database) throws -> PlanUsageStatus? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT state, reason, plan, fetched_at, last_error, limits_json, breakdown_json
            FROM plan_usage_status WHERE id = 1
            """) else { return nil }
        let decoder = PlanUsageDates.decoder
        let limits = (try? decoder.decode([PlanUsageLimit].self, from: Data((row["limits_json"] as String).utf8))) ?? []
        let breakdown = (try? decoder.decode([PlanUsageBreakdownRow].self, from: Data((row["breakdown_json"] as String).utf8))) ?? []
        return PlanUsageStatus(state: row["state"], reason: row["reason"], plan: row["plan"],
                               fetchedAt: PlanUsageDates.parse(row["fetched_at"]), lastError: row["last_error"],
                               limits: limits, breakdown: breakdown)
    }

    package static func samples(_ db: Database, key: String, since: Date) throws -> [PlanUsageSample] {
        let sinceText = since == .distantPast ? "" : PlanUsageDates.format(since)
        return try Row.fetchAll(db, sql: """
            SELECT taken_at, percent, resets_at FROM plan_usage_samples
            WHERE limit_key = ? AND taken_at >= ? ORDER BY taken_at
            """, arguments: [key, sinceText]).compactMap { row in
            guard let taken = PlanUsageDates.parse(row["taken_at"]) else { return nil }
            return PlanUsageSample(takenAt: taken, percent: row["percent"], resetsAt: PlanUsageDates.parse(row["resets_at"]))
        }
    }
}
```

(A malformed `limits_json` decodes to `[]` — the daemon owns that column; the stale banner still shows. `PlanUsageDates.format` writes whole-second UTC `[.withInternetDateTime]`, the same fixed-width form Go stores in the sample table, so the SQL string comparison matches time order.)

Presentation:

```swift
package enum PlanUsagePresentation {
    package static let staleAfter: TimeInterval = 15 * 60

    package static func isStale(_ s: PlanUsageStatus, now: Date) -> Bool {
        guard s.state == "ok", let fetched = s.fetchedAt else { return true }
        return now.timeIntervalSince(fetched) > staleAfter
    }

    package static func tone(_ l: PlanUsageLimit) -> PlanUsageTone {
        if l.percent >= 90 || l.projection.state == "hit" { return .critical }
        if l.percent >= 70 || l.projection.state == "will_hit" { return .warning }
        return .normal
    }

    package static func menuBarText(_ s: PlanUsageStatus?) -> String? {
        guard let s, ["ok", "stale", "error"].contains(s.state) else { return nil }
        let parts = [("session", "5h"), ("weekly_all", "7d")].compactMap { key, short in
            s.limits.first { $0.key == key }.map { "\(short) \(Int($0.percent.rounded()))%" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package static func menuBarWarning(_ s: PlanUsageStatus?, now: Date) -> Bool {
        guard let s, !isStale(s, now: now) else { return false }
        return s.limits.contains { ["session", "weekly_all"].contains($0.key) && tone($0) != .normal }
    }

    package static func resetText(_ l: PlanUsageLimit, now: Date) -> String {
        guard let reset = l.resetsAt else { return "Not started" }
        let mins = max(0, Int(reset.timeIntervalSince(now) / 60))
        let span = mins >= 24 * 60 ? "\(mins / 1440) d \(mins % 1440 / 60) h" : "\(mins / 60) h \(mins % 60) m"
        return "Resets in \(span) (\(clock(reset, now: now)))"
    }

    package static func projectionText(_ l: PlanUsageLimit, now: Date) -> String {
        switch l.projection.state {
        case "will_hit":
            guard let hit = l.projection.hitAt else { return "You may hit it before the reset" }
            var text = "At this pace you hit it at \(clock(hit, now: now))"
            if let reset = l.resetsAt {
                let lead = Int(reset.timeIntervalSince(hit) / 60)
                text += lead >= 60 ? ", \(lead / 60) h before the reset" : ", \(lead) m before the reset"
            }
            return text
        case "hit": return "Limit reached"
        case "collecting": return "Collecting data…"
        case "idle": return "Window not started"
        default: return "You won't hit it before the reset"
        }
    }

    package static func trayLine(_ l: PlanUsageLimit, now: Date) -> String {
        let reset = l.resetsAt.map { "resets \(clock($0, now: now))" } ?? "not started"
        let tail: String
        switch l.projection.state {
        case "will_hit": tail = l.projection.hitAt.map { "hits \(clock($0, now: now))" } ?? "may hit"
        case "hit": tail = "limit reached"
        case "collecting": tail = "collecting"
        case "idle": tail = ""
        default: tail = "safe"
        }
        return ["\(l.label): \(Int(l.percent.rounded()))%", reset, tail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "13:59" today, "Mon 18:59" on another day — local time.
    static func clock(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}
```

- [ ] **Step 4: Run** the filtered tests — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(planusage): Swift core model, queries and presentation`.

---

### Task 9: PlanUsageCenter, menu bar text, tray rows

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/PlanUsageCenter.swift`, `WatchtowerDesktop/Tests/PlanUsageCenterTests.swift`
- Modify: `App/AppState.swift` (create + start where the other database-backed centers start, next to `WorkbenchNotificationCenter`), `App/WatchtowerApp.swift` (MenuBarExtra label), `Views/TrayMenuView.swift` (`TrayMenuContent` gets `planUsageLines: [String]` and `planUsageAction: () -> Void`)

**Interfaces:**
- Consumes: Task 8.
- Produces:
  ```swift
  @MainActor @Observable final class PlanUsageCenter {
      static let pollInterval: Duration = .seconds(30)
      static let menuBarKey = "planUsage.showInMenuBar"   // @AppStorage, absent = on
      private(set) var status: PlanUsageStatus?
      private(set) var isRefreshing: Bool
      var onStatus: ((PlanUsageStatus) -> Void)?           // Task 11 hooks the notifier here
      init(dbPool: DatabasePool, runner: CLIRunnerProtocol?, now: @escaping () -> Date = Date.init)
      func start(); func stop()
      func reload() async
      func refresh() async                                  // runs `usage plan --now`, then reload()
      func samples(key: String, since: Date) async -> [PlanUsageSample]
      func menuBarLabel(showText: Bool) -> String?          // "⚠︎ 5h 92% · 7d 59%" | "5h 4% · 7d 59%" | nil
      var trayLines: [String]                               // session + weekly_all trayLine()s
  }
  ```

- [ ] **Step 1: Failing test** (temp `DatabasePool` from `TestDatabase` with the generated schema; a stub runner):

```swift
@MainActor
final class PlanUsageCenterTests: XCTestCase {
    final class StubRunner: CLIRunnerProtocol {
        var calls: [[String]] = []
        func run(args: [String]) async throws -> Data { calls.append(args); return Data() }
    }

    func testReloadAndLabels() async throws {
        let pool = try TestDatabase.makePool()   // match the existing pool helper
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id, state, plan, fetched_at, limits_json, breakdown_json, updated_at)
                VALUES (1, 'ok', 'max', '2026-10-15T09:59:00Z',
                '[{"key":"session","label":"5-hour","group":"session","percent":92,"resets_at":"2026-10-15T12:00:00Z","severity":"warning","projection":{"state":"hit","hit_at":null,"rate_per_hour":0}},{"key":"weekly_all","label":"Weekly","group":"weekly","percent":59,"resets_at":"2026-10-19T16:00:00Z","severity":"normal","projection":{"state":"safe","hit_at":null,"rate_per_hour":0}}]',
                '[]', '2026-10-15T09:59:00Z')
                """)
        }
        let now = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z")!
        let runner = StubRunner()
        let center = PlanUsageCenter(dbPool: pool, runner: runner, now: { now })
        var seen: PlanUsageStatus?
        center.onStatus = { seen = $0 }
        await center.reload()
        XCTAssertEqual(center.menuBarLabel(showText: true), "⚠︎ 5h 92% · 7d 59%")
        XCTAssertNil(center.menuBarLabel(showText: false))
        XCTAssertEqual(center.trayLines.count, 2)
        XCTAssertEqual(seen?.plan, "max")
        await center.refresh()
        XCTAssertEqual(runner.calls, [["usage", "plan", "--now"]])
    }
}
```

- [ ] **Step 2: Run** `make test-swift FILTER=PlanUsageCenterTests` — FAIL.

- [ ] **Step 3: Implement** `PlanUsageCenter` following `WorkbenchNotificationCenter`'s start/stop/poll loop shape (30 s `Task.sleep` loop, reads in `dbPool.read`, errors logged with `NSLog("PlanUsageCenter: …")`, `status` left as is on a read error). `refresh()` sets `isRefreshing`, `try? await runner?.run(args: ["usage", "plan", "--now"])` (a nonzero exit still has written the error state — log the error, then `reload()`). `menuBarLabel` returns `nil` when `showText` is false or `menuBarText` is nil, otherwise prefixes `"⚠︎ "` when `menuBarWarning`.

`WatchtowerApp.swift` label:

```swift
} label: {
    HStack(spacing: 4) {
        Image(nsImage: Self.trayIcon)
        if let text = appState.planUsageCenter.menuBarLabel(showText: showPlanUsageInMenuBar) {
            Text(text).monospacedDigit()
        }
    }
    .accessibilityLabel("Watchtower")
    .onAppear { … unchanged … }
}
```
with `@AppStorage(PlanUsageCenter.menuBarKey) private var showPlanUsageInMenuBar = true` on the `App`.

`AppState`: `let planUsageCenter: PlanUsageCenter` is created where `dbPool` and `cliRunner` exist (same init path as `WorkbenchNotificationCenter` at `AppState.swift` ~1685) and `start()`ed there; `stop()` wherever the other centers stop on teardown. If `planUsageCenter` must exist before the DB opens (the label is always mounted), make it optional (`var planUsageCenter: PlanUsageCenter?`) and use `appState.planUsageCenter?.menuBarLabel(...)`.

`TrayMenuContent`: under the status line, one `Text(line).font(.caption)` per `planUsageLines` entry inside a `Button` that runs `planUsageAction` (open the main window like `openAction`, then `appState.selectedDestination = .usage` and `UserDefaults.standard.set(UsageView.Tab.plan.rawValue, forKey: UsageView.selectedTabKey)`). Existing `TrayMenuContent` tests get the two new parameters with empty defaults (`planUsageLines: [String] = []`, `planUsageAction: @escaping () -> Void = {}`) so they compile unchanged.

- [ ] **Step 4: Run** `make test-swift FILTER='PlanUsageCenterTests|TrayMenu'` — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(planusage): menu bar text and tray rows`.

---

### Task 10: Usage → "Claude plan" tab

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Usage/ClaudePlanView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Usage/UsageView.swift`

**Interfaces:**
- Consumes: `PlanUsageCenter` (Task 9), `PlanUsagePresentation` (Task 8).
- Produces: `UsageView.Tab.plan` (`rawValue "Claude plan"`, first case), `UsageView.selectedTabKey = "usage.selectedTab"`.

- [ ] **Step 1: Modify `UsageView`:** `enum Tab: String, CaseIterable { case plan = "Claude plan"; case progress = "Progress"; case usage = "Usage" }`; replace `@State private var selectedTab: Tab = .progress` with `@AppStorage(UsageView.selectedTabKey) private var selectedTab: Tab = .plan` and `static let selectedTabKey = "usage.selectedTab"`; add `case .plan: ClaudePlanView()` to the switch.

- [ ] **Step 2: Write `ClaudePlanView`** — reads `appState.planUsageCenter`; layout:
  - header `HStack`: "Claude plan" `.title2.bold()`, plan badge (`status.plan.capitalized`), `Spacer()`, "Updated \(RelativeDateTimeFormatter)" `.secondary`, `Button("Refresh") { Task { await center.refresh() } }.disabled(center.isRefreshing)`.
  - banner by state: `unavailable` → "Sign in to Claude Code to see your plan limits."; `stale` → "Your Claude Code sign-in expired — open Claude Code to refresh it."; `error` → "Couldn't update: \(lastError). Showing numbers from \(fetchedAt relative)."; `disabled` → "Claude plan limits are turned off in Features."; isStale → secondary text style for all numbers.
  - one `GroupBox` per limit: label, `ProgressView(value: percent, total: 100).tint(color(tone))` (normal `.accentColor`, warning `.orange`, critical `.red`, muted `.secondary`), "\(Int) %", `resetText`, `projectionText`.
  - charts: for `session` and `weekly_all`, a `Chart` (`import Charts`) of `LineMark(x: takenAt, y: percent)` over `center.samples(key:since: resetsAt − window)` (5 h / 7 d; window start = `resetsAt − 5h` / `− 7d`), loaded in `.task(id: status?.fetchedAt)`; a dashed `LineMark` from the last sample to `(hitAt, 100)` for `will_hit` or to `(resetsAt, last + rate × hours)` otherwise (`.lineStyle(StrokeStyle(dash: [4, 3]))`); `RuleMark(x: resetsAt)` labelled "Reset"; y domain `0...100`.
  - breakdown `GroupBox("This week by surface")`: one row per `breakdown` entry, label + "\(Int) %" + a thin `ProgressView`.
  - footer note: "Limits are shared across Claude chats, Cowork and Claude Code."
  - Toggle "Show in the menu bar" bound to `@AppStorage(PlanUsageCenter.menuBarKey)`.

Follow `docs/review/review-rules.md` "Swift / Desktop conventions" (the view stays thin; all text comes from `PlanUsagePresentation`).

- [ ] **Step 3: Build** `cd WatchtowerDesktop && swift build` and `make lint-swift` — clean. **Manual check** via the `run` skill: Usage opens on "Claude plan", shows the owner's numbers, Refresh works.
- [ ] **Step 4: Commit** `feat(planusage): Usage → Claude plan tab`.

---

### Task 11: Notifications

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/PlanUsageNoticePolicy.swift`, `WatchtowerDesktop/Tests/Core/PlanUsageNoticePolicyTests.swift`
- Modify: `Services/NotificationService.swift` (`sendPlanUsageNotice`), `Services/PlanUsageCenter.swift` (hook), `App/WatchtowerApp.swift` (route `"plan_usage"`), `Views/Settings/NotificationSettings.swift` (toggle)

**Interfaces:**
- Produces:
  ```swift
  package struct PlanUsageNotice: Equatable { package let identifier: String; package let title: String; package let body: String }
  package enum PlanUsageNoticePolicy {
      static let enabledKey = "planUsage.notifications"   // absent = on
      static let sentKey = "planUsage.sentNotices"        // [String] of "<kind>|<limit_key>|<resets_at ISO>"
      static func evaluate(_ s: PlanUsageStatus, sent: Set<String>, now: Date) -> (notices: [PlanUsageNotice], sent: Set<String>)
  }
  ```

- [ ] **Step 1: Failing tests:**

```swift
final class PlanUsageNoticePolicyTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00Z")!

    func lim(_ key: String, _ pct: Double, _ state: String, resetIn: TimeInterval = 3600) -> PlanUsageLimit {
        PlanUsageLimit(key: key, label: key, group: key == "session" ? "session" : "weekly", percent: pct,
                       resetsAt: now.addingTimeInterval(resetIn), severity: nil,
                       projection: PlanUsageProjection(state: state, hitAt: state == "will_hit" ? now.addingTimeInterval(1800) : nil, ratePerHour: 1))
    }
    func st(_ l: [PlanUsageLimit], state: String = "ok") -> PlanUsageStatus {
        PlanUsageStatus(state: state, reason: "", plan: "max", fetchedAt: now, lastError: "", limits: l, breakdown: [])
    }

    func testPlanUsage03_OneNoticePerWindow() {
        let s = st([lim("weekly_all", 60, "will_hit")])
        let first = PlanUsageNoticePolicy.evaluate(s, sent: [], now: now)
        XCTAssertEqual(first.notices.count, 1)
        let second = PlanUsageNoticePolicy.evaluate(s, sent: first.sent, now: now)
        XCTAssertTrue(second.notices.isEmpty)
    }

    func testNinetyPercentIsSeparateFromWillHit() {
        let s = st([lim("session", 92, "will_hit")])
        XCTAssertEqual(PlanUsageNoticePolicy.evaluate(s, sent: [], now: now).notices.count, 2)
    }

    func testScopedOnlyAtNinety() {
        XCTAssertTrue(PlanUsageNoticePolicy.evaluate(st([lim("weekly_scoped:fable", 50, "will_hit")]), sent: [], now: now).notices.isEmpty)
        XCTAssertEqual(PlanUsageNoticePolicy.evaluate(st([lim("weekly_scoped:fable", 91, "safe")]), sent: [], now: now).notices.count, 1)
    }

    func testStaleOrNotOkNeverNotifies() {
        XCTAssertTrue(PlanUsageNoticePolicy.evaluate(st([lim("session", 95, "hit")], state: "error"), sent: [], now: now).notices.isEmpty)
    }

    func testPrunesPastWindows() {
        let old = "p90|session|2026-10-14T00:00:00Z"
        let out = PlanUsageNoticePolicy.evaluate(st([lim("session", 10, "safe")]), sent: [old], now: now)
        XCTAssertFalse(out.sent.contains(old))
    }
}
```

- [ ] **Step 2: Run** `make test-swift FILTER=PlanUsageNoticePolicyTests` — FAIL.

- [ ] **Step 3: Implement** the policy: return nothing unless `PlanUsagePresentation.isStale` is false; for each limit with a `resetsAt`: key `"will|\(key)|\(iso)"` when `projection.state == "will_hit"` and key ∈ {session, weekly_all}; key `"p90|\(key)|\(iso)"` when `percent >= 90`; skip keys already in `sent`; prune entries whose `resetsAt` part is earlier than `now`. Titles/bodies:
  - will: title "\(label) Claude limit", body "At this pace you hit it at \(clock(hitAt)) — it resets \(clock(resetsAt))."
  - p90: title "\(label) Claude limit at \(Int(percent))%", body "Resets \(clock(resetsAt))." (`"Limit reached. Resets …"` when ≥ 100).
  - identifier = the key.

`NotificationService.sendPlanUsageNotice(_ n: PlanUsageNotice)`: same shape as `sendSessionAgentNotice`, `userInfo = ["type": "plan_usage"]`.

`PlanUsageCenter`: after each reload, when `UserDefaults` `enabledKey` is not `false`, run `evaluate` with `Set(defaults.stringArray(forKey: sentKey) ?? [])`, send each notice through an injected `PlanUsageNotifying` seam (`protocol PlanUsageNotifying { func sendPlanUsageNotice(_: PlanUsageNotice) }`, `extension NotificationService: PlanUsageNotifying {}`), store the new `sent` set. Extend `PlanUsageCenterTests` with a fake notifier asserting one notice for the fixture's 92 % session and none on a second reload.

`WatchtowerApp` route: add `"plan_usage"` to the `routeNavigation` case list and in `routeNavigation`:
```swift
case "plan_usage":
    UserDefaults.standard.set(UsageView.Tab.plan.rawValue, forKey: UsageView.selectedTabKey)
    appState?.selectedDestination = .usage
```

`NotificationSettings`: a `Toggle("Claude plan limits", isOn: $planUsageNotifications)` bound to `@AppStorage(PlanUsageNoticePolicy.enabledKey) var planUsageNotifications = true`, placed with the other per-kind toggles.

- [ ] **Step 4: Run** `make test-swift FILTER='PlanUsageNoticePolicyTests|PlanUsageCenterTests|NotificationDelegate'` — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(planusage): limit notifications`.

---

### Task 12: Docs + inventory

**Files:**
- Create: `docs/features/claude-plan-limits.md`, `docs/inventory/plan-usage.md`
- Modify: `CLAUDE.md` (Feature Notes line), `docs/inventory/README.md` (module mapping), `docs/features/feature-manager.md` (registry list), `docs/features/tray-daemon-lifecycle.md` (one line: the plan-usage goroutine and the menu bar text)

- [ ] **Step 1: Write `docs/features/claude-plan-limits.md`** — sections: Summary; Data source (endpoint, parse rules, `limits[]` vs fallback); Credentials (read-only, never refresh, `stale/token_expired`); Poller (interval, backoff, `--now`, `disabled`); Storage (00115 tables, retention, `limits_json` shape); Projection (lookbacks, states `idle/collecting/safe/will_hit/hit`); Desktop (30 s read — cross-process, no observation; menu bar `⚠︎` prefix instead of colour; Usage tab; notifications and their dedupe keys); CLI; Contracts PLANUSAGE-01..03.
- [ ] **Step 2: Write `docs/inventory/plan-usage.md`** in the format of `docs/inventory/features.md`:
  - PLANUSAGE-01 — the token is never refreshed or written; an expired token sends no request. Guard: `TestPlanUsage01_ExpiredTokenMakesNoRequest`.
  - PLANUSAGE-02 — the token never reaches the DB, logs or errors. Guard: `TestPlanUsage02_TokenNeverPersisted`.
  - PLANUSAGE-03 — at most one notification per kind per `(limit, window)`. Guard: `PlanUsageNoticePolicyTests.testPlanUsage03_OneNoticePerWindow`.
  Add `internal/planusage`, `PlanUsage*` Swift → `plan-usage.md` to the README mapping.
- [ ] **Step 3: CLAUDE.md** Feature Notes: `- [Claude plan limits — 5h / weekly usage + projection (2026-10-15)](docs/features/claude-plan-limits.md) — \`internal/planusage\` read-only Claude Code token, \`/api/oauth/usage\` poller (5 min, backoff), migration 00115 \`plan_usage_samples\`/\`plan_usage_status\`, Go-side projection, menu bar text, Usage → Claude plan tab, notifications, \`usage plan\`; PLANUSAGE-01..03.`
- [ ] **Step 4: Commit** `docs(planusage): feature note and inventory`.

---

### Final gate (controller)

- [ ] `bash scripts/dev-health.sh`, then `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`.
- [ ] Manual: `watchtower usage plan --now` shows real numbers; the menu bar shows `5h N% · 7d M%`; Usage → Claude plan renders; a forced `will_hit` (edit `limits_json` in a scratch DB copy) fires one notification.
- [ ] `local-review` → PR into `main`.
