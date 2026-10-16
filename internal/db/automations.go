package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ErrAutomationNotFound is what the automation getters and setters wrap when no row
// matches, so a caller can tell a missing automation from a failed lookup.
var ErrAutomationNotFound = errors.New("automation not found")

// ErrHashMismatch refuses a confirmation whose hash is not the row's current
// approval_hash: the recipe changed after the owner looked at it.
var ErrHashMismatch = errors.New("approval hash does not match the recipe")

// ErrScheduleChanged refuses a scheduler write whose expected
// last_scheduled_for is no longer the row's: another writer (a confirm, an
// enable, the indexer) moved the schedule point since the scheduler read it.
var ErrScheduleChanged = errors.New("automation schedule changed since it was read")

// automationTimeLayout is the form of every automation timestamp (UTC RFC 3339
// seconds, the house created_at default).
const automationTimeLayout = "2006-01-02T15:04:05Z"

// Column defaults of automations (migration 00113). UpsertAutomationIndex
// stores them for a zero field — a recipe with a parse error carries no values.
const (
	automationDefaultTriggerSpec  = "{}"
	automationDefaultMissed       = "run_once"
	automationDefaultConcurrency  = 1
	automationDefaultBudgetTokens = 50000
	automationDefaultBudgetMins   = 5
	automationDefaultPauseHours   = 72
	automationDefaultJSONList     = "[]"
)

// Automation is one indexed recipe (automations, migration 00113).
type Automation struct {
	ID                int64
	Slug              string
	Scope             string // personal | workbench
	ProjectID         int64  // workbench id; 0 = personal
	Path              string
	Name              string
	TriggerKind       string
	TriggerSpec       string
	MissedPolicy      string
	Concurrency       int
	BudgetTokens      int
	BudgetMinutes     int
	PauseTimeoutHours int
	PermissionsJSON   string
	OutputsJSON       string
	RecipeText        string
	ContentHash       string
	ApprovalHash      string
	ConfirmedHash     string
	ParseError        string
	Enabled           bool
	LastScheduledFor  *time.Time
	NextRunAt         *time.Time
	RemovedAt         *time.Time
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// Runnable reports whether the executor may run a: parsed, enabled, its file
// present, and the owner confirmed exactly the current approval hash.
func (a Automation) Runnable() bool {
	return a.ParseError == "" && a.Enabled && a.RemovedAt == nil &&
		a.ConfirmedHash != "" && a.ConfirmedHash == a.ApprovalHash
}

// runnableAutomationSQL is Runnable() as a predicate over automations.
const runnableAutomationSQL = `parse_error = '' AND enabled = 1 AND removed_at IS NULL
	AND confirmed_hash != '' AND confirmed_hash = approval_hash`

const automationCols = `id, slug, scope, project_id, path, name, trigger_kind, trigger_spec, missed_policy,
	concurrency, budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
	recipe_text, content_hash, approval_hash, confirmed_hash, parse_error, enabled,
	last_scheduled_for, next_run_at, removed_at, created_at, updated_at`

func scanAutomation(row interface{ Scan(...any) error }) (*Automation, error) {
	var (
		a                    Automation
		projectID            sql.NullInt64
		last, next, removed  sql.NullString
		createdAt, updatedAt string
	)
	if err := row.Scan(&a.ID, &a.Slug, &a.Scope, &projectID, &a.Path, &a.Name, &a.TriggerKind, &a.TriggerSpec,
		&a.MissedPolicy, &a.Concurrency, &a.BudgetTokens, &a.BudgetMinutes, &a.PauseTimeoutHours,
		&a.PermissionsJSON, &a.OutputsJSON, &a.RecipeText, &a.ContentHash, &a.ApprovalHash, &a.ConfirmedHash,
		&a.ParseError, &a.Enabled, &last, &next, &removed, &createdAt, &updatedAt); err != nil {
		return nil, err
	}
	a.ProjectID = projectID.Int64
	var err error
	if a.LastScheduledFor, err = parseAutomationTime(last, "last_scheduled_for"); err != nil {
		return nil, err
	}
	if a.NextRunAt, err = parseAutomationTime(next, "next_run_at"); err != nil {
		return nil, err
	}
	if a.RemovedAt, err = parseAutomationTime(removed, "removed_at"); err != nil {
		return nil, err
	}
	if a.CreatedAt, err = time.Parse(automationTimeLayout, createdAt); err != nil {
		return nil, fmt.Errorf("automation %d created_at %q: %w", a.ID, createdAt, err)
	}
	if a.UpdatedAt, err = time.Parse(automationTimeLayout, updatedAt); err != nil {
		return nil, fmt.Errorf("automation %d updated_at %q: %w", a.ID, updatedAt, err)
	}
	return &a, nil
}

func parseAutomationTime(s sql.NullString, column string) (*time.Time, error) {
	if !s.Valid {
		return nil, nil
	}
	t, err := time.Parse(automationTimeLayout, s.String)
	if err != nil {
		return nil, fmt.Errorf("%s %q: %w", column, s.String, err)
	}
	return &t, nil
}

func formatAutomationTime(t time.Time) string { return t.UTC().Format(automationTimeLayout) }

func nullAutomationTime(t *time.Time) sql.NullString {
	if t == nil {
		return sql.NullString{}
	}
	return sql.NullString{Valid: true, String: formatAutomationTime(*t)}
}

func nullProjectID(id int64) sql.NullInt64 {
	return sql.NullInt64{Int64: id, Valid: id != 0}
}

func withAutomationDefaults(a Automation) Automation {
	if a.TriggerSpec == "" {
		a.TriggerSpec = automationDefaultTriggerSpec
	}
	if a.MissedPolicy == "" {
		a.MissedPolicy = automationDefaultMissed
	}
	if a.Concurrency == 0 {
		a.Concurrency = automationDefaultConcurrency
	}
	if a.BudgetTokens == 0 {
		a.BudgetTokens = automationDefaultBudgetTokens
	}
	if a.BudgetMinutes == 0 {
		a.BudgetMinutes = automationDefaultBudgetMins
	}
	if a.PauseTimeoutHours == 0 {
		a.PauseTimeoutHours = automationDefaultPauseHours
	}
	if a.PermissionsJSON == "" {
		a.PermissionsJSON = automationDefaultJSONList
	}
	if a.OutputsJSON == "" {
		a.OutputsJSON = automationDefaultJSONList
	}
	return a
}

// UpsertAutomationIndex writes a's parsed recipe into its index row, keyed by
// path, and returns the row id. It never writes the owner's columns —
// confirmed_hash, enabled, last_scheduled_for — nor the scheduler's
// next_run_at: a new row starts unconfirmed and disabled, and an existing one
// keeps them, so a changed approval_hash leaves it not runnable until the
// owner confirms again. It clears removed_at (the file is back). A zero
// numeric/JSON field stores the column default. An empty Slug or Path is
// refused before anything is written.
func (db *DB) UpsertAutomationIndex(a Automation) (int64, error) {
	if a.Slug == "" || a.Path == "" {
		return 0, fmt.Errorf("indexing automation: slug %q and path %q must both be set", a.Slug, a.Path)
	}
	a = withAutomationDefaults(a)
	var id int64
	err := db.QueryRow(`INSERT INTO automations
		(slug, scope, project_id, path, name, trigger_kind, trigger_spec, missed_policy, concurrency,
		 budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
		 recipe_text, content_hash, approval_hash, parse_error)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(path) DO UPDATE SET
		 slug = excluded.slug, scope = excluded.scope, project_id = excluded.project_id,
		 name = excluded.name, trigger_kind = excluded.trigger_kind, trigger_spec = excluded.trigger_spec,
		 missed_policy = excluded.missed_policy, concurrency = excluded.concurrency,
		 budget_tokens = excluded.budget_tokens, budget_minutes = excluded.budget_minutes,
		 pause_timeout_hours = excluded.pause_timeout_hours, permissions_json = excluded.permissions_json,
		 outputs_json = excluded.outputs_json, recipe_text = excluded.recipe_text,
		 content_hash = excluded.content_hash, approval_hash = excluded.approval_hash,
		 parse_error = excluded.parse_error, removed_at = NULL,
		 updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		RETURNING id`,
		a.Slug, a.Scope, nullProjectID(a.ProjectID), a.Path, a.Name, a.TriggerKind, a.TriggerSpec,
		a.MissedPolicy, a.Concurrency, a.BudgetTokens, a.BudgetMinutes, a.PauseTimeoutHours,
		a.PermissionsJSON, a.OutputsJSON, a.RecipeText, a.ContentHash, a.ApprovalHash, a.ParseError,
	).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("indexing automation %s: %w", a.Path, err)
	}
	return id, nil
}

// GetAutomation returns automation id; ErrAutomationNotFound when there is none.
func (db *DB) GetAutomation(id int64) (*Automation, error) {
	a, err := scanAutomation(db.QueryRow(`SELECT `+automationCols+` FROM automations WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("automation %d: %w", id, ErrAutomationNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("reading automation %d: %w", id, err)
	}
	return a, nil
}

// GetAutomationBySlug returns the automation of slug in a scope (projectID 0
// for personal), removed rows included; ErrAutomationNotFound when there is none.
func (db *DB) GetAutomationBySlug(scope string, projectID int64, slug string) (*Automation, error) {
	a, err := scanAutomation(db.QueryRow(`SELECT `+automationCols+` FROM automations
		WHERE scope = ? AND COALESCE(project_id, 0) = ? AND slug = ?`, scope, projectID, slug))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("automation %s/%d/%s: %w", scope, projectID, slug, ErrAutomationNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("reading automation %s/%d/%s: %w", scope, projectID, slug, err)
	}
	return a, nil
}

// AutomationFilter narrows ListAutomations; a zero field does not filter.
// Removed rows are left out unless IncludeRemoved (RunnableOnly never lists one).
type AutomationFilter struct {
	Scope          string
	ProjectID      int64
	TriggerKind    string
	RunnableOnly   bool
	IncludeRemoved bool
}

// ListAutomations returns the automations matching f in slug order.
func (db *DB) ListAutomations(f AutomationFilter) ([]Automation, error) {
	var (
		where []string
		args  []any
	)
	if f.Scope != "" {
		where, args = append(where, "scope = ?"), append(args, f.Scope)
	}
	if f.ProjectID != 0 {
		where, args = append(where, "project_id = ?"), append(args, f.ProjectID)
	}
	if f.TriggerKind != "" {
		where, args = append(where, "trigger_kind = ?"), append(args, f.TriggerKind)
	}
	if f.RunnableOnly {
		where = append(where, runnableAutomationSQL)
	}
	if !f.IncludeRemoved {
		where = append(where, "removed_at IS NULL")
	}
	q := `SELECT ` + automationCols + ` FROM automations`
	if len(where) > 0 {
		q += ` WHERE ` + strings.Join(where, " AND ")
	}
	rows, err := db.Query(q+` ORDER BY slug, id`, args...)
	if err != nil {
		return nil, fmt.Errorf("listing automations: %w", err)
	}
	defer rows.Close()
	out := []Automation{}
	for rows.Next() {
		a, err := scanAutomation(rows)
		if err != nil {
			return nil, fmt.Errorf("listing automations: %w", err)
		}
		out = append(out, *a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing automations: %w", err)
	}
	return out, nil
}

// MarkAutomationsRemovedExcept stamps removed_at = now on every row of the
// scope (projectID 0 for personal) whose path is not in keepPaths and that is
// not removed already, and returns how many it stamped. An empty keepPaths
// removes the whole scope (the folder is empty or gone).
func (db *DB) MarkAutomationsRemovedExcept(scope string, projectID int64, keepPaths []string, now time.Time) (int, error) {
	if keepPaths == nil {
		keepPaths = []string{}
	}
	keep, err := json.Marshal(keepPaths)
	if err != nil {
		return 0, fmt.Errorf("encoding kept paths: %w", err)
	}
	stamp := formatAutomationTime(now)
	res, err := db.Exec(`UPDATE automations SET removed_at = ?, updated_at = ?
		WHERE scope = ? AND COALESCE(project_id, 0) = ? AND removed_at IS NULL
		  AND path NOT IN (SELECT value FROM json_each(?))`,
		stamp, stamp, scope, projectID, string(keep))
	if err != nil {
		return 0, fmt.Errorf("marking removed automations of %s/%d: %w", scope, projectID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("marking removed automations of %s/%d: %w", scope, projectID, err)
	}
	return int(n), nil
}

// SetAutomationEnabled turns automation id on or off. Turning a disabled row
// on sets last_scheduled_for = now, so the scheduler never back-fills the
// ticks it missed while off; enabling an enabled row keeps its schedule point.
func (db *DB) SetAutomationEnabled(id int64, enabled bool, now time.Time) error {
	stamp := formatAutomationTime(now)
	res, err := db.Exec(`UPDATE automations SET
		last_scheduled_for = CASE WHEN ? AND enabled = 0 THEN ? ELSE last_scheduled_for END,
		enabled = ?, updated_at = ?
		WHERE id = ?`, enabled, stamp, enabled, stamp, id)
	if err != nil {
		return fmt.Errorf("setting automation %d enabled=%v: %w", id, enabled, err)
	}
	return requireAutomationRow(res, id)
}

// ConfirmAutomation records the owner's confirmation of hash. A hash that is
// empty or not the row's current approval_hash fails with ErrHashMismatch and
// leaves the row unchanged; a missing row fails with ErrAutomationNotFound.
// A confirmation that changes confirmed_hash also sets last_scheduled_for =
// now, so the scheduler never catches up on the ticks
// the recipe spent unconfirmed (the same rule as enabling); confirming the
// already confirmed hash again keeps the schedule point.
func (db *DB) ConfirmAutomation(id int64, hash string, now time.Time) error {
	if hash == "" {
		return fmt.Errorf("automation %d: empty hash: %w", id, ErrHashMismatch)
	}
	stamp := formatAutomationTime(now)
	res, err := db.Exec(`UPDATE automations SET
		last_scheduled_for = CASE WHEN confirmed_hash != ? THEN ? ELSE last_scheduled_for END,
		confirmed_hash = ?, updated_at = ?
		WHERE id = ? AND approval_hash = ?`, hash, stamp, hash, stamp, id, hash)
	if err != nil {
		return fmt.Errorf("confirming automation %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("confirming automation %d: %w", id, err)
	}
	if n == 1 {
		return nil
	}
	if _, err := db.GetAutomation(id); err != nil {
		return err
	}
	return fmt.Errorf("automation %d: %w", id, ErrHashMismatch)
}

// SetAutomationSchedule writes last_scheduled_for and next_run_at
// unconditionally; nil stores NULL. The scheduler uses
// CompareAndSetAutomationSchedule instead.
func (db *DB) SetAutomationSchedule(id int64, lastScheduledFor, nextRunAt *time.Time) error {
	res, err := db.Exec(`UPDATE automations SET last_scheduled_for = ?, next_run_at = ? WHERE id = ?`,
		nullAutomationTime(lastScheduledFor), nullAutomationTime(nextRunAt), id)
	if err != nil {
		return fmt.Errorf("setting automation %d schedule: %w", id, err)
	}
	return requireAutomationRow(res, id)
}

// CompareAndSetAutomationSchedule writes last_scheduled_for and next_run_at
// only while last_scheduled_for still equals prev (nil = NULL), the value the
// scheduler read; otherwise it fails with ErrScheduleChanged and writes
// nothing. ErrAutomationNotFound when there is no row.
func (db *DB) CompareAndSetAutomationSchedule(id int64, prev, lastScheduledFor, nextRunAt *time.Time) error {
	res, err := db.Exec(`UPDATE automations SET last_scheduled_for = ?, next_run_at = ?
		WHERE id = ? AND last_scheduled_for IS ?`,
		nullAutomationTime(lastScheduledFor), nullAutomationTime(nextRunAt), id, nullAutomationTime(prev))
	if err != nil {
		return fmt.Errorf("setting automation %d schedule: %w", id, err)
	}
	return db.requireScheduleRow(res, id)
}

// requireScheduleRow maps a compare-and-set schedule update that touched no
// row to ErrScheduleChanged, or to ErrAutomationNotFound when the row is gone.
func (db *DB) requireScheduleRow(res sql.Result, id int64) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("automation %d: %w", id, err)
	}
	if n == 1 {
		return nil
	}
	if _, err := db.GetAutomation(id); err != nil {
		return err
	}
	return fmt.Errorf("automation %d: %w", id, ErrScheduleChanged)
}

// PrimeAutomationSchedule sets last_scheduled_for = now on automation id
// only while the row is not a runnable schedule automation, and reports
// whether it did. The indexer calls it just before an upsert that makes the
// row runnable, so the scheduler never catches up on the window the row was
// not runnable; the condition keeps a second indexer working from a stale
// snapshot from rewinding a schedule point the scheduler already advanced.
// ErrAutomationNotFound when there is no row.
func (db *DB) PrimeAutomationSchedule(id int64, now time.Time) (bool, error) {
	res, err := db.Exec(`UPDATE automations SET last_scheduled_for = ?
		WHERE id = ? AND NOT (trigger_kind = 'schedule' AND `+runnableAutomationSQL+`)`,
		formatAutomationTime(now), id)
	if err != nil {
		return false, fmt.Errorf("priming automation %d schedule: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("priming automation %d schedule: %w", id, err)
	}
	if n == 1 {
		return true, nil
	}
	if _, err := db.GetAutomation(id); err != nil {
		return false, err
	}
	return false, nil
}

// AutomationScopeGeneration is a cheap fingerprint of a scope's rows
// (projectID 0 for personal): row count, highest id and latest updated_at.
// It changes when a row is inserted, deleted, re-indexed, confirmed or
// toggled, so the indexer's Changed check notices a delete that frees a slug.
func (db *DB) AutomationScopeGeneration(scope string, projectID int64) (string, error) {
	var (
		count, maxID int64
		maxUpdated   string
	)
	err := db.QueryRow(`SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(MAX(updated_at), '')
		FROM automations WHERE scope = ? AND COALESCE(project_id, 0) = ?`, scope, projectID).
		Scan(&count, &maxID, &maxUpdated)
	if err != nil {
		return "", fmt.Errorf("reading automation generation of %s/%d: %w", scope, projectID, err)
	}
	return fmt.Sprintf("%d/%d/%s", count, maxID, maxUpdated), nil
}

// deleteRunAsksSQL deletes the asks of automation ?'s runs. Every path that
// deletes runs executes it first, in the same transaction: the run's FK would
// otherwise null automation_run_id and leave the ask looking like an
// external terminal's, which session-side readers then see.
const deleteRunAsksSQL = `DELETE FROM owner_asks WHERE automation_run_id IN (
	SELECT id FROM automation_runs WHERE automation_id = ?)`

// DeleteAutomation deletes automation id with its runs' asks and, by FK
// cascade, its runs, steps, state and outputs; ErrAutomationNotFound when
// there is none.
func (db *DB) DeleteAutomation(id int64) error {
	return db.WithTx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(deleteRunAsksSQL, id); err != nil {
			return fmt.Errorf("deleting the asks of automation %d: %w", id, err)
		}
		res, err := tx.Exec(`DELETE FROM automations WHERE id = ?`, id)
		if err != nil {
			return fmt.Errorf("deleting automation %d: %w", id, err)
		}
		return requireAutomationRow(res, id)
	})
}

func requireAutomationRow(res sql.Result, id int64) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("automation %d: %w", id, err)
	}
	if n == 0 {
		return fmt.Errorf("automation %d: %w", id, ErrAutomationNotFound)
	}
	return nil
}

// automationsFeatureOffError is the error FastForwardAutomations writes on the
// queued runs it cancels.
const automationsFeatureOffError = "the automations feature was off when this run was queued"

// FastForwardAutomations is the automations feature's enable hook (FEAT-03:
// enabling resumes from now). In one transaction it sets last_scheduled_for =
// now on every schedule automation, so no schedule catches up on the window
// the feature was off, and cancels every queued run except dry runs (those
// belong to a live CLI): error_kind 'cancelled', error
// automationsFeatureOffError. A queued run has no steps to close. It returns
// how many automations it primed and how many runs it cancelled.
func (db *DB) FastForwardAutomations(now time.Time) (primed, cancelled int, err error) {
	const what = "fast-forwarding automations"
	if err := requireRunTime(now, what); err != nil {
		return 0, 0, err
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, 0, fmt.Errorf("%s: %w", what, err)
	}
	defer func() { _ = tx.Rollback() }()
	stamp := formatAutomationTime(now)
	res, err := tx.Exec(`UPDATE automations SET last_scheduled_for = ? WHERE trigger_kind = 'schedule'`, stamp)
	if err != nil {
		return 0, 0, fmt.Errorf("%s: priming schedules: %w", what, err)
	}
	p, err := res.RowsAffected()
	if err != nil {
		return 0, 0, fmt.Errorf("%s: priming schedules: %w", what, err)
	}
	res, err = tx.Exec(`UPDATE automation_runs SET status = 'cancelled', error_kind = 'cancelled', error = ?,
		finished_at = ? WHERE status = 'queued' AND trigger <> 'dry_run'`, automationsFeatureOffError, stamp)
	if err != nil {
		return 0, 0, fmt.Errorf("%s: cancelling queued runs: %w", what, err)
	}
	c, err := res.RowsAffected()
	if err != nil {
		return 0, 0, fmt.Errorf("%s: cancelling queued runs: %w", what, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, 0, fmt.Errorf("%s: %w", what, err)
	}
	return int(p), int(c), nil
}
