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
// schedule columns are left alone, and an unchanged value writes nothing. A
// row the daemon turned off (disabled_reason set, AUTO-08: a run that would
// not end) is never turned on here — only the owner's turn-on
// (ResumeBuiltin) does that. ErrAutomationNotFound when there is no row.
func (db *DB) SetBuiltinEnabled(builtinID string, on bool, now time.Time) error {
	res, err := db.Exec(`UPDATE automations SET enabled = ?, updated_at = ?
		WHERE builtin_id = ? AND enabled != ? AND (? = 0 OR disabled_reason = '')`,
		on, formatAutomationTime(now), builtinID, on, on)
	if err != nil {
		return fmt.Errorf("setting built-in automation %s enabled=%v: %w", builtinID, on, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("setting built-in automation %s enabled=%v: %w", builtinID, on, err)
	}
	if n == 1 {
		return nil
	}
	_, err = db.GetBuiltinAutomation(builtinID) // unchanged, or no row
	return err
}

// ResumeBuiltin is the owner's turn-on of built-in builtinID after the
// daemon turned it off (disabled_reason set by a run that would not end,
// AUTO-08): it clears disabled_reason and disabled_at and sets enabled. It
// reports whether the row was stopped; a row that was not is left alone.
// ErrAutomationNotFound when there is no row.
func (db *DB) ResumeBuiltin(builtinID string, now time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE automations SET enabled = 1, disabled_reason = '', disabled_at = NULL, updated_at = ?
		WHERE builtin_id = ? AND disabled_reason != ''`, formatAutomationTime(now), builtinID)
	if err != nil {
		return false, fmt.Errorf("turning built-in automation %s on again: %w", builtinID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("turning built-in automation %s on again: %w", builtinID, err)
	}
	if n == 1 {
		return true, nil
	}
	_, err = db.GetBuiltinAutomation(builtinID) // not stopped, or no row
	return false, err
}

// CancelQueuedBuiltinRuns cancels every queued manual run (Run Now) of
// built-in builtinID as not_runnable and returns how many: the runner calls it
// when the built-in cannot run them (off, unconfirmed, stopped by the daemon,
// or still on its legacy phases), so a Run Now never waits forever. With none
// queued it writes nothing.
func (db *DB) CancelQueuedBuiltinRuns(builtinID string, now time.Time) (int, error) {
	if err := requireRunTime(now, "cancelling the queued runs of built-in automation "+builtinID); err != nil {
		return 0, err
	}
	res, err := db.Exec(`UPDATE automation_runs SET status = 'cancelled', error_kind = 'not_runnable',
		error = 'the automation is not runnable', finished_at = ?
		WHERE status = 'queued' AND trigger = 'manual'
		  AND automation_id IN (SELECT id FROM automations WHERE builtin_id = ?)`,
		formatAutomationTime(now), builtinID)
	if err != nil {
		return 0, fmt.Errorf("cancelling the queued runs of built-in automation %s: %w", builtinID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("cancelling the queued runs of built-in automation %s: %w", builtinID, err)
	}
	return int(n), nil
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
// when at least one run or pipeline row reported a cost. Tokens is the input
// plus output tokens of the same runs and pipeline rows, reported or not (the
// pipelines report tokens but no cost).
type BuiltinCostSum struct {
	USD      float64
	Reported bool
	Tokens   int64
}

// BuiltinCost sums automationID's reported run costs (automation_runs.
// reported_cost_usd, dry runs left out) from the moment since on, plus the
// cost_usd of the pipeline_runs of pipelines from that moment on local dates
// before the built-in's first succeeded run (any trigger). After that run the
// primitives' usage lands in reported_cost_usd, so counting the pipeline rows
// of that day or later would count it twice; a failed run does not cut the
// old pipeline's cost off. With no succeeded run every pipeline row from that
// moment on counts. Reported is true when a counted run carries a cost or a
// counted pipeline row has cost_usd > 0 (a zero row reported nothing).
// Tokens counts every run from that moment on (dry runs left out) and the
// same pipeline rows.
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
		(SELECT COALESCE(SUM(input_tokens + output_tokens), 0) FROM automation_runs WHERE automation_id = ?
		   AND trigger != 'dry_run' AND COALESCE(started_at, queued_at) >= ?),
		(SELECT MIN(COALESCE(started_at, queued_at)) FROM automation_runs WHERE automation_id = ?
		   AND status = 'succeeded')`,
		automationID, sinceStamp, automationID, sinceStamp, automationID, sinceStamp, automationID).Scan(
		&runUSD, &runCount, &sum.Tokens, &first)
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
			return sum, fmt.Errorf("automation %d first succeeded run at %q: %w", automationID, first.String, err)
		}
		local := t.Local()
		until = formatAutomationTime(time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.Local))
	}
	q := `SELECT COALESCE(SUM(cost_usd), 0), COUNT(CASE WHEN cost_usd > 0 THEN 1 END),
		COALESCE(SUM(input_tokens + output_tokens), 0) FROM pipeline_runs
		WHERE started_at >= ? AND (? = '' OR started_at < ?) AND pipeline IN (` + placeholders(len(pipelines)) + `)`
	args := []any{sinceStamp, until, until}
	for _, p := range pipelines {
		args = append(args, p)
	}
	var (
		pipeUSD    float64
		pipeCount  int
		pipeTokens int64
	)
	if err := db.QueryRow(q, args...).Scan(&pipeUSD, &pipeCount, &pipeTokens); err != nil {
		return sum, fmt.Errorf("reading the pipeline costs of automation %d: %w", automationID, err)
	}
	sum.USD += pipeUSD
	sum.Tokens += pipeTokens
	sum.Reported = sum.Reported || pipeCount > 0
	return sum, nil
}
