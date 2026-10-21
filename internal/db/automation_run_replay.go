package db

import (
	"database/sql"
	"fmt"
)

// AutomationRunReplay is one row of automation_run_replay (00146): what one
// completed SDK call of a live run gave the script, or — Pending — the call
// the run waits in (no outcome yet).
type AutomationRunReplay struct {
	RunID      int64
	Seq        int
	Kind, Name string
	ArgsHash   string
	ResultJSON *string // nil = the call returned undefined
	ErrorJSON  string  // "" = the call did not throw
	ClockJSON  string  // a JSON array of ms values; "" is written as []
	Pending    bool
}

// resumableRunSQL selects (over automation_runs, no arguments) the waiting
// runs a daemon start keeps for a resume (AUTO-08 as amended by board #795):
// a live run whose replay log is complete, waiting in its last step — the
// only open one — whose pending replay row exists while every earlier step
// has its record, of an automation that is still runnable and still
// confirmed at the hash the run was claimed with.
const resumableRunSQL = `status = 'waiting' AND trigger != 'dry_run' AND not_resumable = 0
	AND EXISTS (SELECT 1 FROM automations a WHERE a.id = automation_runs.automation_id
		AND a.parse_error = '' AND a.enabled = 1 AND a.removed_at IS NULL AND a.confirmed_hash != ''
		AND a.confirmed_hash = a.approval_hash AND a.confirmed_hash = automation_runs.recipe_hash)
	AND EXISTS (SELECT 1 FROM automation_run_steps w WHERE w.run_id = automation_runs.id
		AND w.finished_at IS NULL AND w.status = 'waiting'
		AND w.seq = (SELECT MAX(m.seq) FROM automation_run_steps m WHERE m.run_id = automation_runs.id)
		AND NOT EXISTS (SELECT 1 FROM automation_run_steps o WHERE o.run_id = automation_runs.id
			AND o.finished_at IS NULL AND o.seq != w.seq)
		AND (SELECT COUNT(*) FROM automation_run_replay p WHERE p.run_id = automation_runs.id
			AND p.seq < w.seq AND p.pending = 0) = w.seq - 1
		AND EXISTS (SELECT 1 FROM automation_run_replay p WHERE p.run_id = automation_runs.id
			AND p.seq = w.seq AND p.pending = 1))`

// markResumableTx sets resume_pending on every resumable run (the start
// sweep's first half, in its transaction).
func markResumableTx(tx *sql.Tx) error {
	if _, err := tx.Exec(`UPDATE automation_runs SET resume_pending = 1 WHERE ` + resumableRunSQL); err != nil {
		return fmt.Errorf("keeping resumable automation runs: %w", err)
	}
	return nil
}

// NextResumePendingAutomationRuns returns every waiting run kept for a
// resume, oldest first.
func (db *DB) NextResumePendingAutomationRuns() ([]AutomationRun, error) {
	return db.listAutomationRuns(`WHERE status = 'waiting' AND resume_pending = 1 ORDER BY id`, 0)
}

// ClaimResumeAutomationRun moves a run kept for a resume back to running
// (clearing resume_pending and its waiting reason) while fewer than
// maxRunning runs are running, in one conditional UPDATE; false (no error)
// when no slot is free or the run is no longer kept for a resume (cancelled
// meanwhile). The run already holds its per-automation slot.
func (db *DB) ClaimResumeAutomationRun(runID int64, maxRunning int) (bool, error) {
	res, err := db.Exec(`UPDATE automation_runs SET status = 'running', resume_pending = 0, waiting_reason = ''
		WHERE id = ? AND status = 'waiting' AND resume_pending = 1
		  AND (? <= 0 OR (SELECT COUNT(*) FROM automation_runs g WHERE g.status = 'running') < ?)`,
		runID, maxRunning, maxRunning)
	if err != nil {
		return false, fmt.Errorf("claiming automation run %d for a resume: %w", runID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("claiming automation run %d for a resume: %w", runID, err)
	}
	return n == 1, nil
}

// ReturnAutomationRunToWaiting moves a running run back to waiting with
// reason (a resume the daemon's stop cut short before its replay reached the
// wait: the next start judges it again). ErrRunNotActive when it is not
// running.
func (db *DB) ReturnAutomationRunToWaiting(runID int64, reason string) error {
	if !waitReasons[reason] {
		return fmt.Errorf("automation run %d: unknown waiting reason %q", runID, reason)
	}
	res, err := db.Exec(`UPDATE automation_runs SET status = 'waiting', waiting_reason = ?
		WHERE id = ? AND status = 'running'`, reason, runID)
	if err != nil {
		return fmt.Errorf("returning automation run %d to waiting: %w", runID, err)
	}
	return requireRunTransition(db, res, runID, ErrRunNotActive)
}

// SetAutomationRunNotResumable flags the run's replay log incomplete: a
// restart ends it instead of resuming it.
func (db *DB) SetAutomationRunNotResumable(runID int64) error {
	if _, err := db.Exec(`UPDATE automation_runs SET not_resumable = 1 WHERE id = ?`, runID); err != nil {
		return fmt.Errorf("flagging automation run %d not resumable: %w", runID, err)
	}
	return nil
}

// ListAutomationRunReplay returns the run's replay log in seq order (never nil).
func (db *DB) ListAutomationRunReplay(runID int64) ([]AutomationRunReplay, error) {
	rows, err := db.Query(`SELECT run_id, seq, kind, name, args_hash, result_json, error_json, clock_json, pending
		FROM automation_run_replay WHERE run_id = ? ORDER BY seq`, runID)
	if err != nil {
		return nil, fmt.Errorf("listing the replay log of automation run %d: %w", runID, err)
	}
	defer rows.Close()
	out := []AutomationRunReplay{}
	for rows.Next() {
		var (
			r        AutomationRunReplay
			res, err sql.NullString
		)
		if scanErr := rows.Scan(&r.RunID, &r.Seq, &r.Kind, &r.Name, &r.ArgsHash, &res, &err, &r.ClockJSON,
			&r.Pending); scanErr != nil {
			return nil, fmt.Errorf("listing the replay log of automation run %d: %w", runID, scanErr)
		}
		if res.Valid {
			r.ResultJSON = &res.String
		}
		r.ErrorJSON = err.String
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing the replay log of automation run %d: %w", runID, err)
	}
	return out, nil
}

// putReplayTx writes (or replaces) one replay row.
func putReplayTx(tx *sql.Tx, r *AutomationRunReplay) error {
	clock := r.ClockJSON
	if clock == "" {
		clock = "[]"
	}
	var res sql.NullString
	if r.ResultJSON != nil {
		res = sql.NullString{String: *r.ResultJSON, Valid: true}
	}
	if _, err := tx.Exec(`INSERT INTO automation_run_replay
		(run_id, seq, kind, name, args_hash, result_json, error_json, clock_json, pending)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (run_id, seq) DO UPDATE SET kind = excluded.kind, name = excluded.name,
		args_hash = excluded.args_hash, result_json = excluded.result_json, error_json = excluded.error_json,
		clock_json = excluded.clock_json, pending = excluded.pending`,
		r.RunID, r.Seq, r.Kind, r.Name, r.ArgsHash, res, nullRunText(r.ErrorJSON), clock, r.Pending); err != nil {
		return fmt.Errorf("writing replay row %d of automation run %d: %w", r.Seq, r.RunID, err)
	}
	return nil
}

// stepExecer is the Exec subset of *DB and *sql.Tx a step write runs on.
type stepExecer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

// stepWriteTx runs write and, when replay is set, writes the replay row in
// the same transaction.
func (db *DB) stepWriteTx(id int64, replay *AutomationRunReplay, write func(q stepExecer) (sql.Result, error)) error {
	if replay == nil {
		res, err := write(db)
		if err != nil {
			return err
		}
		return requireOpenStep(db, res, id)
	}
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("automation run step %d: %w", id, err)
	}
	defer func() { _ = tx.Rollback() }()
	res, err := write(tx)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil || n != 1 {
		_ = tx.Rollback()
		if err != nil {
			return fmt.Errorf("automation run step %d: %w", id, err)
		}
		return requireOpenStep(db, res, id)
	}
	if err := putReplayTx(tx, replay); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("automation run step %d: %w", id, err)
	}
	return nil
}
