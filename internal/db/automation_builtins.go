package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Automation origins (automations.origin, 00150).
const (
	OriginOwner   = "owner"
	OriginBuiltin = "builtin"
)

// TriggerKindSync is the trigger kind of a built-in that runs at its slot in
// every sync cycle (automations.trigger_kind, 00150).
const TriggerKindSync = "sync"

// builtinPathPrefix keys a built-in's row: path = "builtin:" + its id.
const builtinPathPrefix = "builtin:"

// ErrNotBuiltin refuses a built-in-only write on an owner row.
var ErrNotBuiltin = errors.New("automation is not a built-in")

// UpsertBuiltinAutomation writes the shipped recipe a.BuiltinID into its row,
// keyed by path "builtin:<id>", and returns the row id. The row is personal
// with origin 'builtin'; it writes builtin_id, overridden, builtin_base_hash
// and the parsed columns, and — like UpsertAutomationIndex — never the
// owner's confirmed_hash, enabled or schedule columns. An empty BuiltinID or
// Slug is refused before anything is written.
func (db *DB) UpsertBuiltinAutomation(a Automation) (int64, error) {
	if a.BuiltinID == "" || a.Slug == "" {
		return 0, fmt.Errorf("indexing built-in automation: builtin id %q and slug %q must both be set", a.BuiltinID, a.Slug)
	}
	a = withAutomationDefaults(a)
	path := builtinPathPrefix + a.BuiltinID
	var id int64
	err := db.QueryRow(`INSERT INTO automations
		(slug, scope, project_id, path, name, trigger_kind, trigger_spec, missed_policy, concurrency,
		 budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
		 recipe_text, content_hash, approval_hash, parse_error,
		 origin, builtin_id, overridden, builtin_base_hash)
		VALUES (?, 'personal', NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'builtin', ?, ?, ?)
		ON CONFLICT(path) DO UPDATE SET
		 slug = excluded.slug, name = excluded.name, trigger_kind = excluded.trigger_kind,
		 trigger_spec = excluded.trigger_spec, missed_policy = excluded.missed_policy,
		 concurrency = excluded.concurrency, budget_tokens = excluded.budget_tokens,
		 budget_minutes = excluded.budget_minutes, pause_timeout_hours = excluded.pause_timeout_hours,
		 permissions_json = excluded.permissions_json, outputs_json = excluded.outputs_json,
		 recipe_text = excluded.recipe_text, content_hash = excluded.content_hash,
		 approval_hash = excluded.approval_hash, parse_error = excluded.parse_error,
		 builtin_id = excluded.builtin_id, overridden = excluded.overridden,
		 builtin_base_hash = excluded.builtin_base_hash, removed_at = NULL,
		 updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		RETURNING id`,
		a.Slug, path, a.Name, a.TriggerKind, a.TriggerSpec, a.MissedPolicy, a.Concurrency,
		a.BudgetTokens, a.BudgetMinutes, a.PauseTimeoutHours, a.PermissionsJSON, a.OutputsJSON,
		a.RecipeText, a.ContentHash, a.ApprovalHash, a.ParseError,
		a.BuiltinID, a.Overridden, a.BuiltinBaseHash,
	).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("indexing built-in automation %s: %w", a.BuiltinID, err)
	}
	return id, nil
}

// ConfirmShippedBuiltin confirms the shipped text of built-in row id: it sets
// confirmed_hash = approvalHash only while the row is a built-in whose
// content_hash is contentHash and whose approval_hash is approvalHash, so
// only the exact shipped bytes are ever confirmed without the owner. An owner
// row fails with ErrNotBuiltin, any other mismatch (or an empty hash) with
// ErrHashMismatch, a missing row with ErrAutomationNotFound; the row is left
// unchanged on every failure. A confirmation that changes confirmed_hash sets
// last_scheduled_for = now, as ConfirmAutomation does.
func (db *DB) ConfirmShippedBuiltin(id int64, contentHash, approvalHash string, now time.Time) error {
	stamp := formatAutomationTime(now)
	res, err := db.Exec(`UPDATE automations SET
		last_scheduled_for = CASE WHEN confirmed_hash != ? THEN ? ELSE last_scheduled_for END,
		confirmed_hash = ?, updated_at = ?
		WHERE id = ? AND origin = 'builtin' AND ? != '' AND content_hash = ? AND approval_hash = ?`,
		approvalHash, stamp, approvalHash, stamp, id, approvalHash, contentHash, approvalHash)
	if err != nil {
		return fmt.Errorf("confirming built-in automation %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("confirming built-in automation %d: %w", id, err)
	}
	if n == 1 {
		return nil
	}
	a, err := db.GetAutomation(id)
	if err != nil {
		return err
	}
	if !a.IsBuiltin() {
		return fmt.Errorf("automation %d: %w", id, ErrNotBuiltin)
	}
	return fmt.Errorf("built-in automation %d: %w", id, ErrHashMismatch)
}

// GetBuiltinAutomation returns the row of built-in builtinID (the owner's
// copy when overridden); ErrAutomationNotFound when there is none.
func (db *DB) GetBuiltinAutomation(builtinID string) (*Automation, error) {
	a, err := scanAutomation(db.QueryRow(`SELECT `+automationCols+` FROM automations WHERE builtin_id = ?`, builtinID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("built-in automation %s: %w", builtinID, ErrAutomationNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("reading built-in automation %s: %w", builtinID, err)
	}
	return a, nil
}

// SetBuiltinEnabled mirrors the on/off state of built-in builtinID into its
// row. It only writes enabled (and updated_at): disabled_reason and the
// schedule columns are left alone. ErrAutomationNotFound when there is no row.
func (db *DB) SetBuiltinEnabled(builtinID string, on bool, now time.Time) error {
	res, err := db.Exec(`UPDATE automations SET enabled = ?, updated_at = ? WHERE builtin_id = ?`,
		on, formatAutomationTime(now), builtinID)
	if err != nil {
		return fmt.Errorf("setting built-in automation %s enabled=%v: %w", builtinID, on, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("setting built-in automation %s enabled=%v: %w", builtinID, on, err)
	}
	if n == 0 {
		return fmt.Errorf("built-in automation %s: %w", builtinID, ErrAutomationNotFound)
	}
	return nil
}

// TakeQueuedBuiltinRun returns the oldest queued manual run of automationID
// (a Run Now waiting for the built-in's slot), nil when there is none. It
// claims nothing: the slot executor claims the run it returns.
func (db *DB) TakeQueuedBuiltinRun(automationID int64) (*AutomationRun, error) {
	r, err := scanAutomationRun(db.QueryRow(`SELECT `+automationRunCols+` FROM automation_runs
		WHERE automation_id = ? AND status = 'queued' AND trigger = 'manual'
		ORDER BY queued_at, id LIMIT 1`, automationID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the queued run of built-in automation %d: %w", automationID, err)
	}
	return r, nil
}

// BuiltinMigration is one row of builtin_migrations (00150): the one-time
// move of a built-in from the old pipeline settings.
type BuiltinMigration struct {
	BuiltinID, Status, Error string
	Attempts                 int
	UpdatedAt                time.Time
}

// Built-in migration statuses (builtin_migrations.status).
const (
	BuiltinMigrationDone   = "done"
	BuiltinMigrationFailed = "failed"
)

// RecordBuiltinMigration records one attempt of builtinID's move: status
// 'done' or 'failed', errText ("" when done), attempts incremented.
func (db *DB) RecordBuiltinMigration(builtinID, status, errText string, now time.Time) error {
	if err := requireRunTime(now, "recording built-in migration "+builtinID); err != nil {
		return err
	}
	_, err := db.Exec(`INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at)
		VALUES (?, ?, ?, 1, ?)
		ON CONFLICT(builtin_id) DO UPDATE SET status = excluded.status, error = excluded.error,
		 attempts = builtin_migrations.attempts + 1, updated_at = excluded.updated_at`,
		builtinID, status, errText, formatAutomationTime(now))
	if err != nil {
		return fmt.Errorf("recording built-in migration %s: %w", builtinID, err)
	}
	return nil
}

// GetBuiltinMigration returns builtinID's migration record, nil when none.
func (db *DB) GetBuiltinMigration(builtinID string) (*BuiltinMigration, error) {
	var (
		m       BuiltinMigration
		updated string
	)
	err := db.QueryRow(`SELECT builtin_id, status, error, attempts, updated_at FROM builtin_migrations
		WHERE builtin_id = ?`, builtinID).Scan(&m.BuiltinID, &m.Status, &m.Error, &m.Attempts, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading built-in migration %s: %w", builtinID, err)
	}
	if m.UpdatedAt, err = time.Parse(automationTimeLayout, updated); err != nil {
		return nil, fmt.Errorf("built-in migration %s updated_at %q: %w", builtinID, updated, err)
	}
	return &m, nil
}

// BuiltinCostSum is what a built-in cost since a moment. Reported is true
// when at least one run or pipeline row reported a cost.
type BuiltinCostSum struct {
	USD      float64
	Reported bool
}

// BuiltinCost sums automationID's reported run costs (automation_runs.
// reported_cost_usd, dry runs left out) from the moment since on, plus the
// cost_usd of the pipeline_runs of pipelines from that moment on local dates
// before the built-in's first run: the old pipeline's cost before the
// built-in took over, never counted twice for one day. With no run yet every
// pipeline row from that moment on counts.
func (db *DB) BuiltinCost(automationID int64, pipelines []string, since time.Time) (BuiltinCostSum, error) {
	var (
		sum      BuiltinCostSum
		runUSD   sql.NullFloat64
		runCount int
		first    sql.NullString
	)
	sinceStamp := formatAutomationTime(since)
	err := db.QueryRow(`SELECT
		(SELECT SUM(reported_cost_usd) FROM automation_runs WHERE automation_id = ? AND trigger != 'dry_run'
		   AND reported_cost_usd IS NOT NULL AND COALESCE(started_at, queued_at) >= ?),
		(SELECT COUNT(*) FROM automation_runs WHERE automation_id = ? AND trigger != 'dry_run'
		   AND reported_cost_usd IS NOT NULL AND COALESCE(started_at, queued_at) >= ?),
		(SELECT MIN(started_at) FROM automation_runs WHERE automation_id = ? AND trigger != 'dry_run'
		   AND started_at IS NOT NULL)`,
		automationID, sinceStamp, automationID, sinceStamp, automationID).Scan(&runUSD, &runCount, &first)
	if err != nil {
		return sum, fmt.Errorf("reading the run costs of automation %d: %w", automationID, err)
	}
	sum.USD, sum.Reported = runUSD.Float64, runCount > 0
	if len(pipelines) == 0 {
		return sum, nil
	}
	until := ""
	if first.Valid {
		t, err := time.Parse(automationTimeLayout, first.String)
		if err != nil {
			return sum, fmt.Errorf("automation %d first run started_at %q: %w", automationID, first.String, err)
		}
		local := t.Local()
		until = formatAutomationTime(time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.Local))
	}
	q := `SELECT COALESCE(SUM(cost_usd), 0), COUNT(*) FROM pipeline_runs
		WHERE started_at >= ? AND (? = '' OR started_at < ?) AND pipeline IN (` + placeholders(len(pipelines)) + `)`
	args := []any{sinceStamp, until, until}
	for _, p := range pipelines {
		args = append(args, p)
	}
	var (
		pipeUSD   float64
		pipeCount int
	)
	if err := db.QueryRow(q, args...).Scan(&pipeUSD, &pipeCount); err != nil {
		return sum, fmt.Errorf("reading the pipeline costs of automation %d: %w", automationID, err)
	}
	sum.USD += pipeUSD
	sum.Reported = sum.Reported || pipeCount > 0
	return sum, nil
}
