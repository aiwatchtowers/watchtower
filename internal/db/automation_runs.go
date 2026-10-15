package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Run statuses (automation_runs.status, migration 00113).
const (
	RunQueued         = "queued"
	RunRunning        = "running"
	RunWaiting        = "waiting"
	RunSucceeded      = "succeeded"
	RunFailed         = "failed"
	RunBudgetExceeded = "budget_exceeded"
	RunTimedOut       = "timed_out"
	RunCancelled      = "cancelled"
	RunExpired        = "expired"
)

// Run triggers (automation_runs.trigger).
const (
	TriggerSchedule = "schedule"
	TriggerCatchUp  = "catch_up"
	TriggerButton   = "button"
	TriggerEvent    = "event"
	TriggerManual   = "manual"
	TriggerDryRun   = "dry_run"
)

// Waiting reasons (automation_runs.waiting_reason).
const (
	WaitNone     = ""
	WaitApproval = "approval"
	WaitAsk      = "ask"
	WaitSession  = "session"
	WaitApp      = "app"
)

// Error kinds (automation_runs.error_kind).
const (
	ErrKindScript      = "script"
	ErrKindPermission  = "permission"
	ErrKindBudget      = "budget"
	ErrKindTimeout     = "timeout"
	ErrKindInterrupted = "interrupted"
	ErrKindNotRunnable = "not_runnable"
	ErrKindExpired     = "expired"
	ErrKindCancelled   = "cancelled"
	ErrKindBackend     = "backend"
)

var (
	// ErrAutomationRunNotFound is wrapped when no automation_runs row matches.
	ErrAutomationRunNotFound = errors.New("automation run not found")
	// ErrAutomationRunStepNotFound is wrapped when no automation_run_steps row matches.
	ErrAutomationRunStepNotFound = errors.New("automation run step not found")
	// ErrRunNotActive refuses a transition that needs a running/waiting run
	// (or, for ResumeAutomationRun, a waiting one).
	ErrRunNotActive = errors.New("automation run is not active")
	// ErrRunNotQueued refuses a transition that needs a queued run (it was
	// claimed or ended meanwhile).
	ErrRunNotQueued = errors.New("automation run is not queued")
	// ErrCommitOnFailure refuses a state/output commit on a run that did not
	// succeed (AUTO-04).
	ErrCommitOnFailure = errors.New("state and outputs commit only with a succeeded run")
	// ErrStepFinished refuses a write to a step that is already finished.
	ErrStepFinished = errors.New("automation run step is already finished")
)

// terminalRunStatuses are the statuses FinishAutomationRun may write.
var terminalRunStatuses = map[string]bool{
	RunSucceeded: true, RunFailed: true, RunBudgetExceeded: true,
	RunTimedOut: true, RunCancelled: true, RunExpired: true,
}

// waitReasons are the reasons SetAutomationRunWaiting accepts (WaitNone is not one).
var waitReasons = map[string]bool{WaitApproval: true, WaitAsk: true, WaitSession: true, WaitApp: true}

// AutomationRun is one row of automation_runs.
type AutomationRun struct {
	ID, AutomationID int64
	Trigger          string
	ScheduledFor     *time.Time
	EventCycle       string // '' = NULL
	EventJSON        string
	RerunOf          int64 // 0 = NULL
	Status           string
	WaitingReason    string
	RecipeHash       string
	RecipeSnapshot   string
	BudgetTokens     int
	BudgetMinutes    int
	InputTokens      int64
	OutputTokens     int64
	TokensEstimated  bool
	ReportedCostUSD  *float64
	ActiveMS         int64
	Error, ErrorKind string
	Summary          string
	QueuedAt         time.Time
	StartedAt        *time.Time
	FinishedAt       *time.Time
}

// AutomationEventPayload is the event_json shape of a trigger='event' run
// (spec §8): P4's bus and merge write it, the executor decodes it.
type AutomationEventPayload struct {
	Cycles    []string          `json:"cycles"`
	Events    []json.RawMessage `json:"events"`
	Count     int               `json:"count"`
	Truncated bool              `json:"truncated"`
}

// MarshalJSON writes nil slices as [] so the payload always has the pinned shape.
func (p AutomationEventPayload) MarshalJSON() ([]byte, error) {
	type plain AutomationEventPayload
	if p.Cycles == nil {
		p.Cycles = []string{}
	}
	if p.Events == nil {
		p.Events = []json.RawMessage{}
	}
	return json.Marshal(plain(p))
}

const automationRunCols = `id, automation_id, trigger, scheduled_for, event_cycle, event_json, rerun_of, status,
	waiting_reason, recipe_hash, recipe_snapshot, budget_tokens, budget_minutes, input_tokens, output_tokens,
	tokens_estimated, reported_cost_usd, active_ms, error, error_kind, summary, queued_at, started_at, finished_at`

func scanAutomationRun(row interface{ Scan(...any) error }) (*AutomationRun, error) {
	var (
		r                            AutomationRun
		scheduled, started, finished sql.NullString
		cycle                        sql.NullString
		rerun                        sql.NullInt64
		cost                         sql.NullFloat64
		queued                       string
	)
	if err := row.Scan(&r.ID, &r.AutomationID, &r.Trigger, &scheduled, &cycle, &r.EventJSON, &rerun, &r.Status,
		&r.WaitingReason, &r.RecipeHash, &r.RecipeSnapshot, &r.BudgetTokens, &r.BudgetMinutes, &r.InputTokens,
		&r.OutputTokens, &r.TokensEstimated, &cost, &r.ActiveMS, &r.Error, &r.ErrorKind, &r.Summary, &queued,
		&started, &finished); err != nil {
		return nil, err
	}
	r.EventCycle, r.RerunOf = cycle.String, rerun.Int64
	if cost.Valid {
		r.ReportedCostUSD = &cost.Float64
	}
	var err error
	if r.ScheduledFor, err = parseAutomationTime(scheduled, "scheduled_for"); err != nil {
		return nil, err
	}
	if r.StartedAt, err = parseAutomationTime(started, "started_at"); err != nil {
		return nil, err
	}
	if r.FinishedAt, err = parseAutomationTime(finished, "finished_at"); err != nil {
		return nil, err
	}
	if r.QueuedAt, err = time.Parse(automationTimeLayout, queued); err != nil {
		return nil, fmt.Errorf("automation run %d queued_at %q: %w", r.ID, queued, err)
	}
	return &r, nil
}

// requireRunTime refuses a zero timestamp before a writer stamps it.
func requireRunTime(t time.Time, what string) error {
	if t.IsZero() {
		return fmt.Errorf("%s: time is zero", what)
	}
	return nil
}

// closeOpenStepsSQL ends every still-open step of the runs a run-ending
// update is about to end, in the same transaction: status 'error' (the step
// never completed) and an error naming why. The placeholder ?-list is: error
// text, finished_at, then the run predicate's own arguments.
const closeOpenStepsSQL = `UPDATE automation_run_steps SET status = 'error', error = ?, finished_at = ?
	WHERE finished_at IS NULL AND run_id IN (SELECT id FROM automation_runs WHERE `

func closeOpenStepsTx(tx *sql.Tx, runStatus, stamp, runPredicate string, args ...any) error {
	all := append([]any{"the run ended (" + runStatus + ") before this step finished", stamp}, args...)
	if _, err := tx.Exec(closeOpenStepsSQL+runPredicate+`)`, all...); err != nil {
		return fmt.Errorf("closing open steps of ended automation runs: %w", err)
	}
	return nil
}

func nullRunText(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }

func nullRunInt(n int64) sql.NullInt64 { return sql.NullInt64{Int64: n, Valid: n != 0} }

func nullRunCost(f *float64) sql.NullFloat64 {
	if f == nil {
		return sql.NullFloat64{}
	}
	return sql.NullFloat64{Float64: *f, Valid: true}
}

// EnqueueRequest is one trigger's request for a run (the only way a run is created).
type EnqueueRequest struct {
	AutomationID      int64
	Trigger           string
	ScheduledFor      *time.Time
	EventCycle        string
	EventJSON         string
	RerunOf           int64
	AdvanceScheduleTo *time.Time // set: last_scheduled_for advances in the same tx
	NextRunAt         *time.Time // written with AdvanceScheduleTo (nil stores NULL)
	// ExpectLastScheduledFor is, with AdvanceScheduleTo, the last_scheduled_for
	// the caller read (nil = NULL); a row that no longer has it fails the whole
	// request with ErrScheduleChanged.
	ExpectLastScheduledFor *time.Time
	Now                    time.Time
}

// EnqueueAutomationRun queues a run in one transaction. Checks, in order:
// (1) a run of the automation already carrying EventCycle — in event_cycle or
// in event_json's cycles array — is returned with coalesced=true; (2) a queued
// run of (automation, trigger) is returned with coalesced=true and nothing is
// inserted (P4 merges the new cycle's events into it); else a queued row is
// inserted with queued_at = Now. When AdvanceScheduleTo is set,
// last_scheduled_for/next_run_at advance in the same tx whether or not a row
// was inserted — compare-and-set against ExpectLastScheduledFor: when the
// row's last_scheduled_for moved since the caller read it, the transaction
// rolls back (no run inserted) and the error wraps ErrScheduleChanged.
func (db *DB) EnqueueAutomationRun(r EnqueueRequest) (runID int64, coalesced bool, err error) {
	if err := requireRunTime(r.Now, fmt.Sprintf("enqueueing a run of automation %d", r.AutomationID)); err != nil {
		return 0, false, err
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, false, fmt.Errorf("enqueueing a run of automation %d: %w", r.AutomationID, err)
	}
	defer func() { _ = tx.Rollback() }()

	runID, coalesced, err = enqueueRunTx(tx, r)
	if err != nil {
		return 0, false, err
	}
	if r.AdvanceScheduleTo != nil {
		if err := advanceScheduleTx(tx, r); err != nil {
			return 0, false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, false, fmt.Errorf("enqueueing a run of automation %d: %w", r.AutomationID, err)
	}
	return runID, coalesced, nil
}

// advanceScheduleTx is EnqueueAutomationRun's compare-and-set schedule write.
func advanceScheduleTx(tx *sql.Tx, r EnqueueRequest) error {
	res, err := tx.Exec(`UPDATE automations SET last_scheduled_for = ?, next_run_at = ?
		WHERE id = ? AND last_scheduled_for IS ?`,
		nullAutomationTime(r.AdvanceScheduleTo), nullAutomationTime(r.NextRunAt), r.AutomationID,
		nullAutomationTime(r.ExpectLastScheduledFor))
	if err != nil {
		return fmt.Errorf("advancing the schedule of automation %d: %w", r.AutomationID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("advancing the schedule of automation %d: %w", r.AutomationID, err)
	}
	if n == 1 {
		return nil
	}
	var exists bool
	if err := tx.QueryRow(`SELECT EXISTS (SELECT 1 FROM automations WHERE id = ?)`, r.AutomationID).Scan(&exists); err != nil {
		return fmt.Errorf("advancing the schedule of automation %d: %w", r.AutomationID, err)
	}
	if !exists {
		return fmt.Errorf("automation %d: %w", r.AutomationID, ErrAutomationNotFound)
	}
	return fmt.Errorf("automation %d: %w", r.AutomationID, ErrScheduleChanged)
}

func enqueueRunTx(tx *sql.Tx, r EnqueueRequest) (int64, bool, error) {
	if r.EventCycle != "" {
		id, found, err := runOfEventCycleTx(tx, r.AutomationID, r.EventCycle)
		if err != nil || found {
			return id, found, err
		}
	}
	var id int64
	err := tx.QueryRow(`SELECT id FROM automation_runs WHERE automation_id = ? AND trigger = ? AND status = 'queued'`,
		r.AutomationID, r.Trigger).Scan(&id)
	if err == nil {
		return id, true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, false, fmt.Errorf("looking up a queued %s run of automation %d: %w", r.Trigger, r.AutomationID, err)
	}
	err = tx.QueryRow(`INSERT INTO automation_runs
		(automation_id, trigger, scheduled_for, event_cycle, event_json, rerun_of, status, queued_at)
		VALUES (?, ?, ?, ?, ?, ?, 'queued', ?) RETURNING id`,
		r.AutomationID, r.Trigger, nullAutomationTime(r.ScheduledFor), nullRunText(r.EventCycle), r.EventJSON,
		nullRunInt(r.RerunOf), formatAutomationTime(r.Now)).Scan(&id)
	if err != nil {
		return 0, false, fmt.Errorf("inserting a %s run of automation %d: %w", r.Trigger, r.AutomationID, err)
	}
	return id, false, nil
}

// runOfEventCycleTx finds the run of an automation that already carries cycle:
// first by the indexed event_cycle column, then inside the cycles array of an
// event run's event_json (a cycle P4 merged into an earlier queued run). A
// malformed event_json never fails the lookup.
func runOfEventCycleTx(tx *sql.Tx, automationID int64, cycle string) (int64, bool, error) {
	queries := []string{
		`SELECT id FROM automation_runs WHERE automation_id = ? AND event_cycle = ?`,
		`SELECT id FROM automation_runs WHERE automation_id = ? AND trigger = 'event' AND event_json != ''
		   AND EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(event_json) THEN event_json ELSE '{}' END,
		       '$.cycles') WHERE value = ?)
		 ORDER BY id LIMIT 1`,
	}
	for _, q := range queries {
		var id int64
		err := tx.QueryRow(q, automationID, cycle).Scan(&id)
		if err == nil {
			return id, true, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return 0, false, fmt.Errorf("looking up event cycle %q of automation %d: %w", cycle, automationID, err)
		}
	}
	return 0, false, nil
}

// NextQueuedAutomationRuns returns up to limit queued runs, oldest queued_at
// first; limit ≤ 0 returns all of them. Dry-run rows are left out: the CLI
// claims and executes its own dry_run row by id (ExecuteInline), so the
// daemon's executor never picks one up.
func (db *DB) NextQueuedAutomationRuns(limit int) ([]AutomationRun, error) {
	return db.listAutomationRuns(`WHERE status = 'queued' AND trigger != 'dry_run' ORDER BY queued_at, id`, limit)
}

// ListAutomationRuns returns up to limit runs of an automation, newest first;
// limit ≤ 0 returns all of them.
func (db *DB) ListAutomationRuns(automationID int64, limit int) ([]AutomationRun, error) {
	return db.listAutomationRuns(`WHERE automation_id = ? ORDER BY id DESC`, limit, automationID)
}

// ListActiveAutomationRuns returns every running or waiting run, oldest first.
func (db *DB) ListActiveAutomationRuns() ([]AutomationRun, error) {
	return db.listAutomationRuns(`WHERE status IN ('running','waiting') ORDER BY id`, 0)
}

func (db *DB) listAutomationRuns(tail string, limit int, args ...any) ([]AutomationRun, error) {
	q := `SELECT ` + automationRunCols + ` FROM automation_runs ` + tail
	if limit > 0 {
		q += ` LIMIT ?`
		args = append(args, limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing automation runs: %w", err)
	}
	defer rows.Close()
	out := []AutomationRun{}
	for rows.Next() {
		r, err := scanAutomationRun(rows)
		if err != nil {
			return nil, fmt.Errorf("listing automation runs: %w", err)
		}
		out = append(out, *r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing automation runs: %w", err)
	}
	return out, nil
}

// GetAutomationRun returns run id; ErrAutomationRunNotFound when there is none.
func (db *DB) GetAutomationRun(id int64) (*AutomationRun, error) {
	r, err := scanAutomationRun(db.QueryRow(`SELECT `+automationRunCols+` FROM automation_runs WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("automation run %d: %w", id, ErrAutomationRunNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("reading automation run %d: %w", id, err)
	}
	return r, nil
}

// runExistsTx distinguishes "no such run" from "the condition did not hold"
// after a conditional write touched no row.
func runExistsTx(q interface {
	QueryRow(string, ...any) *sql.Row
}, id int64) error {
	var one int
	err := q.QueryRow(`SELECT 1 FROM automation_runs WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("automation run %d: %w", id, ErrAutomationRunNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading automation run %d: %w", id, err)
	}
	return nil
}

// ClaimAutomationRun moves a queued run to running in one conditional UPDATE
// inside a BEGIN IMMEDIATE transaction (AUTO-05): it wins only while the run
// is still queued and the automation's running+waiting count is below its
// concurrency. The claim snapshots the recipe hash and text and the budgets.
// It returns false (no error) when the condition did not hold — another
// executor won, or the automation is at its concurrency — and
// ErrAutomationRunNotFound when the run does not exist.
//
// The claim deliberately does not check that the automation is runnable: the
// executor (Task 10) cancels a queued row of a non-runnable automation with
// CancelQueuedNotRunnable before claiming, and a dry run of an unconfirmed but
// parsable recipe must still be claimable (AUTO-06's dry-run exemption).
func (db *DB) ClaimAutomationRun(runID int64, recipeHash, recipeSnapshot string, budgetTokens, budgetMinutes int, now time.Time) (bool, error) {
	return db.claimAutomationRun(runID, recipeHash, recipeSnapshot, budgetTokens, budgetMinutes, 0, now)
}

// ClaimAutomationRunWithin is ClaimAutomationRun with one more condition in
// the same UPDATE: fewer than maxRunning runs (across every automation) are
// running — the daemon executor's maxConcurrentRuns, so a slot count read
// before the claim cannot go stale. maxRunning ≤ 0 means no global bound.
func (db *DB) ClaimAutomationRunWithin(runID int64, recipeHash, recipeSnapshot string, budgetTokens, budgetMinutes, maxRunning int, now time.Time) (bool, error) {
	return db.claimAutomationRun(runID, recipeHash, recipeSnapshot, budgetTokens, budgetMinutes, maxRunning, now)
}

func (db *DB) claimAutomationRun(runID int64, recipeHash, recipeSnapshot string, budgetTokens, budgetMinutes, maxRunning int, now time.Time) (bool, error) {
	if err := requireRunTime(now, fmt.Sprintf("claiming automation run %d", runID)); err != nil {
		return false, err
	}
	tx, err := db.Begin()
	if err != nil {
		return false, fmt.Errorf("claiming automation run %d: %w", runID, err)
	}
	defer func() { _ = tx.Rollback() }()
	res, err := tx.Exec(`UPDATE automation_runs SET status = 'running', started_at = ?,
		recipe_hash = ?, recipe_snapshot = ?, budget_tokens = ?, budget_minutes = ?
		WHERE id = ? AND status = 'queued'
		  AND (SELECT COUNT(*) FROM automation_runs a WHERE a.automation_id = automation_runs.automation_id
		       AND a.status IN ('running','waiting'))
		    < (SELECT concurrency FROM automations WHERE id = automation_runs.automation_id)
		  AND (? <= 0 OR (SELECT COUNT(*) FROM automation_runs g WHERE g.status = 'running') < ?)`,
		formatAutomationTime(now), recipeHash, recipeSnapshot, budgetTokens, budgetMinutes, runID, maxRunning, maxRunning)
	if err != nil {
		return false, fmt.Errorf("claiming automation run %d: %w", runID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("claiming automation run %d: %w", runID, err)
	}
	if n == 0 {
		return false, runExistsTx(tx, runID)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("claiming automation run %d: %w", runID, err)
	}
	return true, nil
}

// CancelQueuedNotRunnable ends a queued run of a non-runnable automation:
// cancelled with error_kind='not_runnable'. ErrRunNotQueued when the run was
// claimed or ended meanwhile. A queued run has no steps to close.
func (db *DB) CancelQueuedNotRunnable(runID int64, now time.Time) error {
	if err := requireRunTime(now, fmt.Sprintf("cancelling not-runnable automation run %d", runID)); err != nil {
		return err
	}
	res, err := db.Exec(`UPDATE automation_runs SET status = 'cancelled', error_kind = 'not_runnable',
		error = 'the automation is not runnable', finished_at = ?
		WHERE id = ? AND status = 'queued'`, formatAutomationTime(now), runID)
	if err != nil {
		return fmt.Errorf("cancelling not-runnable automation run %d: %w", runID, err)
	}
	return requireRunTransition(db, res, runID, ErrRunNotQueued)
}

// requireRunTransition maps a conditional update that touched no row to
// ErrAutomationRunNotFound or to notMatched.
func requireRunTransition(q interface {
	QueryRow(string, ...any) *sql.Row
}, res sql.Result, runID int64, notMatched error) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("automation run %d: %w", runID, err)
	}
	if n == 1 {
		return nil
	}
	if err := runExistsTx(q, runID); err != nil {
		return err
	}
	return fmt.Errorf("automation run %d: %w", runID, notMatched)
}

// CancelAutomationRun ends a queued, running or waiting run as cancelled with
// error_kind='cancelled' and closes its open steps in the same transaction.
// It returns false when the run is already terminal.
func (db *DB) CancelAutomationRun(runID int64, now time.Time) (bool, error) {
	what := fmt.Sprintf("cancelling automation run %d", runID)
	if err := requireRunTime(now, what); err != nil {
		return false, err
	}
	tx, err := db.Begin()
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	defer func() { _ = tx.Rollback() }()
	stamp := formatAutomationTime(now)
	const active = `id = ? AND status IN ('queued','running','waiting')`
	if err := closeOpenStepsTx(tx, RunCancelled, stamp, active, runID); err != nil {
		return false, err
	}
	res, err := tx.Exec(`UPDATE automation_runs SET status = 'cancelled', error_kind = 'cancelled',
		waiting_reason = '', finished_at = ? WHERE `+active, stamp, runID)
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	err = requireRunTransition(tx, res, runID, ErrRunNotActive)
	if errors.Is(err, ErrRunNotActive) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	return true, nil
}

// SetAutomationRunWaiting moves a running run to waiting with reason, or
// changes the reason of a waiting run (status and active_ms untouched).
// Any other status → ErrRunNotActive; an empty or unknown reason is refused.
func (db *DB) SetAutomationRunWaiting(runID int64, reason string) error {
	if !waitReasons[reason] {
		return fmt.Errorf("automation run %d: unknown waiting reason %q", runID, reason)
	}
	res, err := db.Exec(`UPDATE automation_runs SET status = 'waiting', waiting_reason = ?
		WHERE id = ? AND status IN ('running','waiting')`, reason, runID)
	if err != nil {
		return fmt.Errorf("setting automation run %d waiting: %w", runID, err)
	}
	return requireRunTransition(db, res, runID, ErrRunNotActive)
}

// ResumeAutomationRun moves a waiting run back to running and clears its
// reason; any other status → ErrRunNotActive.
func (db *DB) ResumeAutomationRun(runID int64) error {
	res, err := db.Exec(`UPDATE automation_runs SET status = 'running', waiting_reason = ''
		WHERE id = ? AND status = 'waiting'`, runID)
	if err != nil {
		return fmt.Errorf("resuming automation run %d: %w", runID, err)
	}
	return requireRunTransition(db, res, runID, ErrRunNotActive)
}

// ResumeAutomationRunIfSlot moves a waiting run back to running only while
// fewer than maxRunning runs (across every automation) are running, in one
// conditional UPDATE: false (no error) when no slot is free;
// ErrRunNotActive when the run is not waiting.
func (db *DB) ResumeAutomationRunIfSlot(runID int64, maxRunning int) (bool, error) {
	res, err := db.Exec(`UPDATE automation_runs SET status = 'running', waiting_reason = ''
		WHERE id = ? AND status = 'waiting'
		  AND (SELECT COUNT(*) FROM automation_runs r WHERE r.status = 'running') < ?`, runID, maxRunning)
	if err != nil {
		return false, fmt.Errorf("resuming automation run %d: %w", runID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("resuming automation run %d: %w", runID, err)
	}
	if n == 1 {
		return true, nil
	}
	r, err := db.GetAutomationRun(runID)
	if err != nil {
		return false, err
	}
	if r.Status != RunWaiting {
		return false, fmt.Errorf("automation run %d: %w", runID, ErrRunNotActive)
	}
	return false, nil
}

// RunUsage is what a run spent since the last debit; AddAutomationRunUsage adds it.
type RunUsage struct {
	InputTokens, OutputTokens int64
	Estimated                 bool
	ReportedCostUSD           *float64 // nil = the provider reported none
	ActiveMS                  int64
}

// AddAutomationRunUsage adds u to the run's counters (whatever its status:
// tokens spent before a cancel still count on the run).
// tokens_estimated sticks once set; reported_cost_usd stays NULL until a
// provider reports a cost.
func (db *DB) AddAutomationRunUsage(runID int64, u RunUsage) error {
	res, err := db.Exec(`UPDATE automation_runs SET
		input_tokens = input_tokens + ?, output_tokens = output_tokens + ?,
		tokens_estimated = MAX(tokens_estimated, ?),
		reported_cost_usd = CASE WHEN ? IS NULL THEN reported_cost_usd ELSE COALESCE(reported_cost_usd, 0) + ? END,
		active_ms = active_ms + ?
		WHERE id = ?`,
		u.InputTokens, u.OutputTokens, u.Estimated, nullRunCost(u.ReportedCostUSD), nullRunCost(u.ReportedCostUSD),
		u.ActiveMS, runID)
	if err != nil {
		return fmt.Errorf("adding usage to automation run %d: %w", runID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("adding usage to automation run %d: %w", runID, err)
	}
	if n == 0 {
		return fmt.Errorf("automation run %d: %w", runID, ErrAutomationRunNotFound)
	}
	return nil
}

// RunFinish is a run's terminal status.
type RunFinish struct {
	Status, ErrorKind, Error, Summary string
	// ActiveMS is added to the run's active_ms in the same transaction (the
	// active time the executor measured; pauses excluded).
	ActiveMS int64
	Now      time.Time
}

// RunCommit is what a succeeded run commits: the new state (nil = unchanged)
// and its outputs.
type RunCommit struct {
	StateJSON json.RawMessage
	Outputs   []AutomationOutput
}

// FinishAutomationRun ends a running or waiting run with f (else
// ErrRunNotActive) and, in the same transaction, closes its open steps and
// commits c. A non-nil c is accepted only with Status == RunSucceeded (else
// ErrCommitOnFailure, nothing written). Outputs take the run's automation and
// run ids; a non-zero id that differs is refused, and any failed write rolls
// the whole finish back (the run stays active, state and outputs unchanged).
func (db *DB) FinishAutomationRun(runID int64, f RunFinish, c *RunCommit) error {
	if err := validateRunFinish(runID, f, c); err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("finishing automation run %d: %w", runID, err)
	}
	defer func() { _ = tx.Rollback() }()
	stamp := formatAutomationTime(f.Now)
	const active = `id = ? AND status IN ('running','waiting')`
	if err := closeOpenStepsTx(tx, f.Status, stamp, active, runID); err != nil {
		return err
	}
	var automationID int64
	err = tx.QueryRow(`UPDATE automation_runs SET status = ?, error_kind = ?, error = ?, summary = ?,
		active_ms = active_ms + ?, waiting_reason = '', finished_at = ? WHERE `+active+` RETURNING automation_id`,
		f.Status, f.ErrorKind, f.Error, f.Summary, max(f.ActiveMS, 0), stamp, runID).Scan(&automationID)
	if errors.Is(err, sql.ErrNoRows) {
		if err := runExistsTx(tx, runID); err != nil {
			return err
		}
		return fmt.Errorf("automation run %d: %w", runID, ErrRunNotActive)
	}
	if err != nil {
		return fmt.Errorf("finishing automation run %d: %w", runID, err)
	}
	if c != nil {
		if err := commitRunTx(tx, automationID, runID, stamp, c); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("finishing automation run %d: %w", runID, err)
	}
	return nil
}

// validateRunFinish refuses a finish before anything is written.
func validateRunFinish(runID int64, f RunFinish, c *RunCommit) error {
	if err := requireRunTime(f.Now, fmt.Sprintf("finishing automation run %d", runID)); err != nil {
		return err
	}
	if !terminalRunStatuses[f.Status] {
		return fmt.Errorf("finishing automation run %d: %q is not a terminal status", runID, f.Status)
	}
	if c == nil {
		return nil
	}
	if f.Status != RunSucceeded {
		return fmt.Errorf("finishing automation run %d as %s: %w", runID, f.Status, ErrCommitOnFailure)
	}
	if c.StateJSON != nil && !json.Valid(c.StateJSON) {
		return fmt.Errorf("finishing automation run %d: state is not valid JSON", runID)
	}
	return nil
}

func commitRunTx(tx *sql.Tx, automationID, runID int64, stamp string, c *RunCommit) error {
	if c.StateJSON != nil {
		if _, err := tx.Exec(`INSERT INTO automation_state (automation_id, state_json, run_id, updated_at)
			VALUES (?, ?, ?, ?) ON CONFLICT(automation_id) DO UPDATE SET
			state_json = excluded.state_json, run_id = excluded.run_id, updated_at = excluded.updated_at`,
			automationID, string(c.StateJSON), runID, stamp); err != nil {
			return fmt.Errorf("committing state of automation run %d: %w", runID, err)
		}
	}
	for i, o := range c.Outputs {
		if (o.AutomationID != 0 && o.AutomationID != automationID) || (o.RunID != 0 && o.RunID != runID) {
			return fmt.Errorf("committing output %d of automation run %d: belongs to automation %d run %d",
				i, runID, o.AutomationID, o.RunID)
		}
		priority := o.Priority
		if priority == "" {
			priority = "medium"
		}
		if _, err := tx.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, priority, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`, automationID, runID, o.Kind, o.Title, o.Body, priority, stamp); err != nil {
			return fmt.Errorf("committing output %d of automation run %d: %w", i, runID, err)
		}
	}
	return nil
}

// liveDryRunSQL matches a dry run still inside its deadline: started_at +
// budget minutes (the run's snapshot, else the automation's) + a 1-minute
// grace is after now. Such a dry run belongs to a live CLI process
// (ExecuteInline), not to a previous daemon. The one argument is now.
const liveDryRunSQL = `trigger = 'dry_run'
	AND started_at IS NOT NULL
	AND julianday(started_at) + (COALESCE(NULLIF(budget_minutes, 0),
		(SELECT a.budget_minutes FROM automations a WHERE a.id = automation_runs.automation_id)) + 1) / 1440.0
	    > julianday(?)`

// interruptedRunSQL selects the runs a daemon start ends as interrupted:
// every running/waiting run except a live dry run (liveDryRunSQL). The one
// argument is now.
const interruptedRunSQL = `status IN ('running','waiting') AND NOT (` + liveDryRunSQL + `)`

// staleDryRunSQL selects the running/waiting dry runs past their deadline: the
// CLI process that claimed one was killed before it could finish the row. The
// one argument is now.
const staleDryRunSQL = `status IN ('running','waiting') AND trigger = 'dry_run' AND NOT (` + liveDryRunSQL + `)`

// MarkInterruptedAutomationRuns ends every running/waiting run as failed with
// error_kind='interrupted' (a daemon restart; goja state is not resumable),
// closes their open steps in the same transaction, and returns how many runs
// it ended. Queued runs are untouched, and so is a dry run still within its
// deadline (see liveDryRunSQL).
func (db *DB) MarkInterruptedAutomationRuns(now time.Time) (int, error) {
	return db.endRunsInterrupted(now, interruptedRunSQL, "interrupted by a daemon restart",
		"marking interrupted automation runs")
}

// MarkStaleDryRuns ends every running/waiting dry run past its deadline as
// failed with error_kind='interrupted' and closes its open steps in the same
// transaction; it returns how many it ended. The daemon's executor calls it on
// every poll: a dry run's CLI process that was killed leaves its row running,
// where it would hold a concurrency slot until the next daemon start. A dry
// run still inside its deadline is untouched.
func (db *DB) MarkStaleDryRuns(now time.Time) (int, error) {
	// A read-only check first: this runs on every poll, and almost always
	// finds nothing, so no write transaction is opened for nothing.
	if err := requireRunTime(now, "ending stale automation dry runs"); err != nil {
		return 0, err
	}
	var found bool
	err := db.QueryRow(`SELECT EXISTS (SELECT 1 FROM automation_runs WHERE `+staleDryRunSQL+`)`,
		formatAutomationTime(now)).Scan(&found)
	if err != nil {
		return 0, fmt.Errorf("ending stale automation dry runs: %w", err)
	}
	if !found {
		return 0, nil
	}
	return db.endRunsInterrupted(now, staleDryRunSQL, "the dry run's process stopped before it finished the run",
		"ending stale automation dry runs")
}

// endRunsInterrupted ends the runs matching predicate (whose one argument is
// now) as failed/interrupted with errText.
func (db *DB) endRunsInterrupted(now time.Time, predicate, errText, what string) (int, error) {
	if err := requireRunTime(now, what); err != nil {
		return 0, err
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("%s: %w", what, err)
	}
	defer func() { _ = tx.Rollback() }()
	stamp := formatAutomationTime(now)
	if err := closeOpenStepsTx(tx, RunFailed, stamp, predicate, stamp); err != nil {
		return 0, err
	}
	//nolint:gosec // G202: predicate is one of the package's constant run predicates; every value is a bound arg.
	res, err := tx.Exec(`UPDATE automation_runs SET status = 'failed', error_kind = 'interrupted',
		error = ?, waiting_reason = '', finished_at = ?
		WHERE `+predicate, errText, stamp, stamp)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", what, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("%s: %w", what, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("%s: %w", what, err)
	}
	return int(n), nil
}

// AutomationRunStep is one row of automation_run_steps (one SDK call).
type AutomationRunStep struct {
	ID, RunID                  int64
	Seq                        int
	Kind, Name                 string
	ArgsJSON, ResultSummary    string
	Status                     string
	Auto                       bool
	Permission                 string
	ActionID, AskID, SessionID int64 // 0 = NULL
	InputTokens, OutputTokens  int64
	TokensEstimated            bool
	ReportedCostUSD            *float64
	DurationMS                 int64
	Error                      string
	StartedAt                  time.Time
	FinishedAt                 *time.Time
}

// StepFinish is a step's outcome (FinishAutomationRunStep) or, for
// MarkAutomationRunStep, only its non-zero ActionID/AskID/SessionID links.
// Permission (the entry that admitted the call, or the one it lacked) is
// written by FinishAutomationRunStep only when non-empty.
type StepFinish struct {
	Status, ResultSummary, Error string
	Permission                   string
	Auto                         bool
	ActionID, AskID, SessionID   int64
	InputTokens, OutputTokens    int64
	TokensEstimated              bool
	ReportedCostUSD              *float64
	DurationMS                   int64
	Now                          time.Time
}

// AppendAutomationRunStep inserts s with seq = the run's max seq + 1 (in one
// transaction) and returns its id. StartedAt must be set; clipping args and
// summaries is the journal's job.
func (db *DB) AppendAutomationRunStep(s AutomationRunStep) (int64, error) {
	if err := requireRunTime(s.StartedAt, fmt.Sprintf("appending a step to automation run %d", s.RunID)); err != nil {
		return 0, err
	}
	tx, err := db.Begin()
	if err != nil {
		return 0, fmt.Errorf("appending a step to automation run %d: %w", s.RunID, err)
	}
	defer func() { _ = tx.Rollback() }()
	var id int64
	err = tx.QueryRow(`INSERT INTO automation_run_steps
		(run_id, seq, kind, name, args_json, result_summary, status, auto, permission, action_id, ask_id, session_id,
		 input_tokens, output_tokens, tokens_estimated, reported_cost_usd, duration_ms, error, started_at, finished_at)
		VALUES (?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM automation_run_steps WHERE run_id = ?),
		        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`,
		s.RunID, s.RunID, s.Kind, s.Name, s.ArgsJSON, s.ResultSummary, s.Status, s.Auto, s.Permission,
		nullRunInt(s.ActionID), nullRunInt(s.AskID), nullRunInt(s.SessionID), s.InputTokens, s.OutputTokens,
		s.TokensEstimated, nullRunCost(s.ReportedCostUSD), s.DurationMS, s.Error, formatAutomationTime(s.StartedAt),
		nullAutomationTime(s.FinishedAt)).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("appending a %s step to automation run %d: %w", s.Kind, s.RunID, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("appending a step to automation run %d: %w", s.RunID, err)
	}
	return id, nil
}

// stepLinkSQL keeps a link column unless the new value is non-zero.
const stepLinkSQL = `action_id = CASE WHEN ? != 0 THEN ? ELSE action_id END,
	ask_id = CASE WHEN ? != 0 THEN ? ELSE ask_id END,
	session_id = CASE WHEN ? != 0 THEN ? ELSE session_id END`

// MarkAutomationRunStep is the one non-final step update (a step that waits):
// it writes status and only the non-zero link.ActionID/AskID/SessionID;
// finished_at stays NULL. A finished step → ErrStepFinished.
func (db *DB) MarkAutomationRunStep(id int64, status string, link StepFinish) error {
	res, err := db.Exec(`UPDATE automation_run_steps SET status = ?, `+stepLinkSQL+`
		WHERE id = ? AND finished_at IS NULL`, status,
		link.ActionID, link.ActionID, link.AskID, link.AskID, link.SessionID, link.SessionID, id)
	if err != nil {
		return fmt.Errorf("marking automation run step %d: %w", id, err)
	}
	return requireOpenStep(db, res, id)
}

// FinishAutomationRunStep closes step id with f (finished_at = f.Now); links
// are written only when non-zero. A finished step → ErrStepFinished.
func (db *DB) FinishAutomationRunStep(id int64, f StepFinish) error {
	if err := requireRunTime(f.Now, fmt.Sprintf("finishing automation run step %d", id)); err != nil {
		return err
	}
	res, err := db.Exec(`UPDATE automation_run_steps SET status = ?, result_summary = ?, error = ?, auto = ?,
		permission = CASE WHEN ? != '' THEN ? ELSE permission END,
		`+stepLinkSQL+`, input_tokens = ?, output_tokens = ?, tokens_estimated = ?, reported_cost_usd = ?,
		duration_ms = ?, finished_at = ?
		WHERE id = ? AND finished_at IS NULL`,
		f.Status, f.ResultSummary, f.Error, f.Auto, f.Permission, f.Permission,
		f.ActionID, f.ActionID, f.AskID, f.AskID, f.SessionID, f.SessionID,
		f.InputTokens, f.OutputTokens, f.TokensEstimated, nullRunCost(f.ReportedCostUSD), f.DurationMS,
		formatAutomationTime(f.Now), id)
	if err != nil {
		return fmt.Errorf("finishing automation run step %d: %w", id, err)
	}
	return requireOpenStep(db, res, id)
}

func requireOpenStep(db *DB, res sql.Result, id int64) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("automation run step %d: %w", id, err)
	}
	if n == 1 {
		return nil
	}
	var one int
	err = db.QueryRow(`SELECT 1 FROM automation_run_steps WHERE id = ?`, id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("automation run step %d: %w", id, ErrAutomationRunStepNotFound)
	}
	if err != nil {
		return fmt.Errorf("reading automation run step %d: %w", id, err)
	}
	return fmt.Errorf("automation run step %d: %w", id, ErrStepFinished)
}

// ListAutomationRunSteps returns the run's steps in seq order (never nil).
func (db *DB) ListAutomationRunSteps(runID int64) ([]AutomationRunStep, error) {
	rows, err := db.Query(`SELECT id, run_id, seq, kind, name, args_json, result_summary, status, auto, permission,
		action_id, ask_id, session_id, input_tokens, output_tokens, tokens_estimated, reported_cost_usd,
		duration_ms, error, started_at, finished_at
		FROM automation_run_steps WHERE run_id = ? ORDER BY seq`, runID)
	if err != nil {
		return nil, fmt.Errorf("listing steps of automation run %d: %w", runID, err)
	}
	defer rows.Close()
	out := []AutomationRunStep{}
	for rows.Next() {
		var (
			s                    AutomationRunStep
			action, ask, session sql.NullInt64
			cost                 sql.NullFloat64
			started              string
			finished             sql.NullString
		)
		if err := rows.Scan(&s.ID, &s.RunID, &s.Seq, &s.Kind, &s.Name, &s.ArgsJSON, &s.ResultSummary, &s.Status,
			&s.Auto, &s.Permission, &action, &ask, &session, &s.InputTokens, &s.OutputTokens, &s.TokensEstimated,
			&cost, &s.DurationMS, &s.Error, &started, &finished); err != nil {
			return nil, fmt.Errorf("listing steps of automation run %d: %w", runID, err)
		}
		s.ActionID, s.AskID, s.SessionID = action.Int64, ask.Int64, session.Int64
		if cost.Valid {
			s.ReportedCostUSD = &cost.Float64
		}
		if s.StartedAt, err = time.Parse(automationTimeLayout, started); err != nil {
			return nil, fmt.Errorf("automation run step %d started_at %q: %w", s.ID, started, err)
		}
		if s.FinishedAt, err = parseAutomationTime(finished, "finished_at"); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing steps of automation run %d: %w", runID, err)
	}
	return out, nil
}

// GetAutomationState returns the automation's committed state, `{}` when none.
func (db *DB) GetAutomationState(automationID int64) (json.RawMessage, error) {
	var s string
	err := db.QueryRow(`SELECT state_json FROM automation_state WHERE automation_id = ?`, automationID).Scan(&s)
	if errors.Is(err, sql.ErrNoRows) {
		return json.RawMessage(`{}`), nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading state of automation %d: %w", automationID, err)
	}
	return json.RawMessage(s), nil
}

// AutomationOutput is one row of automation_outputs.
type AutomationOutput struct {
	ID, AutomationID, RunID int64
	Kind, Title, Body       string
	Priority                string // '' stores medium
	CreatedAt               time.Time
	ReadAt, DismissedAt     *time.Time
}

// ListAutomationOutputs returns up to limit outputs of kind (” = every
// kind), newest first; limit ≤ 0 returns all of them.
func (db *DB) ListAutomationOutputs(kind string, limit int) ([]AutomationOutput, error) {
	q := `SELECT ` + automationOutputCols + `
		FROM automation_outputs WHERE (? = '' OR kind = ?) ORDER BY created_at DESC, id DESC`
	args := []any{kind, kind}
	if limit > 0 {
		q += ` LIMIT ?`
		args = append(args, limit)
	}
	rows, err := db.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("listing automation outputs: %w", err)
	}
	defer rows.Close()
	out := []AutomationOutput{}
	for rows.Next() {
		o, err := scanAutomationOutput(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing automation outputs: %w", err)
	}
	return out, nil
}

// NamedAutomationOutput is an automation output with the name of the
// automation that wrote it (its slug when the recipe has no name).
type NamedAutomationOutput struct {
	AutomationOutput
	AutomationName string
}

// ListAutomationOutputsSince returns the newest limit outputs of kind created
// at or after since, newest first, each with its automation's name and its
// body cut to maxBodyChars characters, plus the count of every matching row
// (so a caller can say how many it left out). Never nil.
func (db *DB) ListAutomationOutputsSince(kind string, since time.Time, limit, maxBodyChars int) ([]NamedAutomationOutput, int, error) {
	rows, err := db.Query(`SELECT o.id, o.automation_id, o.run_id, o.kind, o.title, substr(o.body, 1, ?), o.priority,
			o.created_at, o.read_at, o.dismissed_at, COALESCE(NULLIF(a.name, ''), a.slug), COUNT(*) OVER ()
		FROM automation_outputs o JOIN automations a ON a.id = o.automation_id
		WHERE o.kind = ? AND o.created_at >= ? ORDER BY o.created_at DESC, o.id DESC LIMIT ?`,
		maxBodyChars, kind, formatAutomationTime(since), limit)
	if err != nil {
		return nil, 0, fmt.Errorf("listing %s automation outputs since %s: %w", kind, formatAutomationTime(since), err)
	}
	defer rows.Close()
	out := []NamedAutomationOutput{}
	total := 0
	for rows.Next() {
		var n NamedAutomationOutput
		if n.AutomationOutput, err = scanAutomationOutput(rows, &n.AutomationName, &total); err != nil {
			return nil, 0, err
		}
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, fmt.Errorf("listing %s automation outputs: %w", kind, err)
	}
	return out, total, nil
}

const automationOutputCols = `id, automation_id, run_id, kind, title, body, priority, created_at, read_at, dismissed_at`

// scanAutomationOutput scans one automationOutputCols row; extra receives any
// columns the query selects after them.
func scanAutomationOutput(rows *sql.Rows, extra ...any) (AutomationOutput, error) {
	var (
		o               AutomationOutput
		created         string
		read, dismissed sql.NullString
	)
	dest := append([]any{&o.ID, &o.AutomationID, &o.RunID, &o.Kind, &o.Title, &o.Body, &o.Priority, &created,
		&read, &dismissed}, extra...)
	if err := rows.Scan(dest...); err != nil {
		return o, fmt.Errorf("scanning automation output: %w", err)
	}
	var err error
	if o.CreatedAt, err = time.Parse(automationTimeLayout, created); err != nil {
		return o, fmt.Errorf("automation output %d created_at %q: %w", o.ID, created, err)
	}
	if o.ReadAt, err = parseAutomationTime(read, "read_at"); err != nil {
		return o, err
	}
	if o.DismissedAt, err = parseAutomationTime(dismissed, "dismissed_at"); err != nil {
		return o, err
	}
	return o, nil
}
