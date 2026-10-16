package db

import (
	"database/sql"
	"errors"
	"fmt"
)

// The ends the Desktop reports for a session() step through `automations
// session-ended` (EndAutomationSessionStep): the session's process ended
// while it was not finished, or the Desktop could not start it.
const (
	SessionStepStopped      = "stopped"
	SessionStepLaunchFailed = "launch_failed"
)

// PendingSessionStep is a session() step waiting for the Desktop to launch
// its session: args_json is {prompt, agent, title}.
type PendingSessionStep struct {
	StepID, RunID, AutomationID, WorkbenchID int64
	ArgsJSON                                 string
}

// PendingAutomationSessionSteps returns the session() steps of workbench
// runs waiting for the app — step waiting, no session attached, run waiting
// with reason app — in step order (never nil). Its consumer is the Desktop
// session launch center (automations P5 part 2); until it ships, such a step
// waits until its run's pause timeout.
func (db *DB) PendingAutomationSessionSteps() ([]PendingSessionStep, error) {
	rows, err := db.Query(`SELECT st.id, st.run_id, a.id, a.project_id, st.args_json
		FROM automation_run_steps st
		JOIN automation_runs r ON r.id = st.run_id
		JOIN automations a ON a.id = r.automation_id
		WHERE st.kind = 'session' AND st.status = 'waiting' AND st.session_id IS NULL AND st.finished_at IS NULL
		  AND r.status = 'waiting' AND r.waiting_reason = 'app'
		  AND a.scope = 'workbench' AND a.project_id IS NOT NULL
		ORDER BY st.id`)
	if err != nil {
		return nil, fmt.Errorf("listing pending automation session steps: %w", err)
	}
	defer rows.Close()
	out := []PendingSessionStep{}
	for rows.Next() {
		var p PendingSessionStep
		if err := rows.Scan(&p.StepID, &p.RunID, &p.AutomationID, &p.WorkbenchID, &p.ArgsJSON); err != nil {
			return nil, fmt.Errorf("listing pending automation session steps: %w", err)
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing pending automation session steps: %w", err)
	}
	return out, nil
}

// AttachAutomationSessionStep names the session the Desktop launched for a
// session() step, in one conditional update: the step is a waiting session
// step with no session yet, its run waits for the app, and the session row
// belongs to that run (automation_run_id) and no step names it yet. false
// (no error) when any of it does not hold — a second attach, a run cancelled
// or expired meanwhile, a session of another run or of another step. The step stays open; the run's wait resumes it.
func (db *DB) AttachAutomationSessionStep(stepID, sessionID int64) (bool, error) {
	res, err := db.Exec(`UPDATE automation_run_steps SET session_id = ?
		WHERE id = ? AND kind = 'session' AND status = 'waiting' AND session_id IS NULL AND finished_at IS NULL
		  AND EXISTS (SELECT 1 FROM automation_runs r WHERE r.id = automation_run_steps.run_id
		              AND r.status = 'waiting' AND r.waiting_reason = 'app')
		  AND EXISTS (SELECT 1 FROM terminal_sessions s WHERE s.id = ?
		              AND s.automation_run_id = automation_run_steps.run_id)
		  AND NOT EXISTS (SELECT 1 FROM automation_run_steps o WHERE o.session_id = ?)`, sessionID, stepID, sessionID, sessionID)
	if err != nil {
		return false, fmt.Errorf("attaching session %d to automation run step %d: %w", sessionID, stepID, err)
	}
	return oneRowAffected(res, fmt.Sprintf("attaching session %d to automation run step %d", sessionID, stepID))
}

// EndAutomationSessionStep records the Desktop's end of a waiting session()
// step, once: stopped leaves the step status ok with the session's status
// as its summary, launch_failed sets it error with errText. finished_at stays
// NULL — the run's wait reads the end and closes the step through its
// journal. false (no error) when the step is not a waiting session step.
func (db *DB) EndAutomationSessionStep(stepID int64, status, errText string) (bool, error) {
	var stepStatus, summary string
	switch status {
	case SessionStepStopped:
		stepStatus, summary, errText = "ok", `{"status":"stopped"}`, ""
	case SessionStepLaunchFailed:
		stepStatus = "error"
	default:
		return false, fmt.Errorf("ending automation run step %d: unknown session end %q (want %s or %s)",
			stepID, status, SessionStepStopped, SessionStepLaunchFailed)
	}
	res, err := db.Exec(`UPDATE automation_run_steps SET status = ?, result_summary = ?, error = ?
		WHERE id = ? AND kind = 'session' AND status = 'waiting' AND finished_at IS NULL
		  AND EXISTS (SELECT 1 FROM automation_runs r WHERE r.id = automation_run_steps.run_id AND r.status = 'waiting')`,
		stepStatus, summary, errText, stepID)
	if err != nil {
		return false, fmt.Errorf("ending automation run step %d: %w", stepID, err)
	}
	return oneRowAffected(res, fmt.Sprintf("ending automation run step %d", stepID))
}

func oneRowAffected(res sql.Result, what string) (bool, error) {
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("%s: %w", what, err)
	}
	return n == 1, nil
}

// AutomationSessionStep is a session() step as its run's wait reads it: the
// step's status and error (no longer waiting once the Desktop ended it) and,
// once a session is attached, that session's state.
type AutomationSessionStep struct {
	Status, Error string
	SessionID     int64 // 0 = none attached yet
	SessionGone   bool  // the attached session's row was deleted
	Finished      bool  // finished_at is set (finish_session)
	FinishSummary string
	Failed        bool // agent_failed_at is set
	AgentError    string
}

// GetAutomationSessionStep reads step stepID and its attached session;
// ErrAutomationRunStepNotFound when the step is gone.
func (db *DB) GetAutomationSessionStep(stepID int64) (AutomationSessionStep, error) {
	var (
		s       AutomationSessionStep
		session sql.NullInt64
		gone    bool
	)
	err := db.QueryRow(`SELECT st.status, st.error, st.session_id, ts.id IS NULL,
		ts.finished_at IS NOT NULL, COALESCE(ts.finish_summary, ''),
		ts.agent_failed_at IS NOT NULL, COALESCE(ts.agent_error, '')
		FROM automation_run_steps st LEFT JOIN terminal_sessions ts ON ts.id = st.session_id
		WHERE st.id = ?`, stepID).
		Scan(&s.Status, &s.Error, &session, &gone, &s.Finished, &s.FinishSummary, &s.Failed, &s.AgentError)
	if errors.Is(err, sql.ErrNoRows) {
		return s, fmt.Errorf("automation run step %d: %w", stepID, ErrAutomationRunStepNotFound)
	}
	if err != nil {
		return s, fmt.Errorf("reading automation run step %d: %w", stepID, err)
	}
	s.SessionID = session.Int64
	s.SessionGone = session.Valid && gone
	return s, nil
}
