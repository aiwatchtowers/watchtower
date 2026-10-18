package automationstest

import (
	"encoding/json"
	"fmt"
	"sync"

	"watchtower/internal/db"
)

// SessionOutcome is how FakeSessionDesk ends the session it launched for one
// session() step. The zero value finishes it (finish_session) with an empty
// summary.
type SessionOutcome struct {
	Summary    string // finish_summary of a finished session
	AgentError string // non-empty: the agent failed (agent_failed_at, agent_error)
	Stopped    bool   // the process ended unfinished (`automations session-ended stopped`)
	// LaunchFailed: the Desktop could not launch it (`session-ended
	// launch_failed --error LaunchFailed`); session() throws NotAvailable.
	LaunchFailed string
}

// SessionLaunch is one session FakeSessionDesk launched: the step it was for,
// the session row it attached, and the step's {prompt, agent, title}.
type SessionLaunch struct {
	Step                 db.PendingSessionStep
	SessionID            int64
	Prompt, Agent, Title string
}

// FakeSessionDesk plays the Desktop's AutomationSessionCenter for session()
// steps: Poll reads PendingAutomationSessionSteps, inserts a terminal_sessions
// row of each step's run in its workbench, attaches it to the step, ends it
// per Outcomes (indexed by launch; past the end a session finishes with
// summary "done") and calls Wake (the CLI's SIGUSR2).
type FakeSessionDesk struct {
	DB       *db.DB
	Outcomes []SessionOutcome
	Wake     func()

	mu       sync.Mutex
	launches []SessionLaunch
}

// Poll launches and ends every pending session step once and returns how
// many it handled.
func (d *FakeSessionDesk) Poll() (int, error) {
	pending, err := d.DB.PendingAutomationSessionSteps()
	if err != nil {
		return 0, err
	}
	for _, p := range pending {
		if err := d.launch(p); err != nil {
			return 0, err
		}
	}
	if len(pending) > 0 && d.Wake != nil {
		d.Wake()
	}
	return len(pending), nil
}

// Launches returns a copy of the sessions launched so far, in order.
func (d *FakeSessionDesk) Launches() []SessionLaunch {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]SessionLaunch(nil), d.launches...)
}

func (d *FakeSessionDesk) launch(p db.PendingSessionStep) error {
	var args struct{ Prompt, Agent, Title string }
	if err := json.Unmarshal([]byte(p.ArgsJSON), &args); err != nil {
		return fmt.Errorf("step %d args %q: %w", p.StepID, p.ArgsJSON, err)
	}
	d.mu.Lock()
	out := SessionOutcome{Summary: "done"}
	if n := len(d.launches); n < len(d.Outcomes) {
		out = d.Outcomes[n]
	}
	l := SessionLaunch{Step: p, Prompt: args.Prompt, Agent: args.Agent, Title: args.Title}
	d.mu.Unlock()
	if out.LaunchFailed != "" {
		ok, err := d.DB.EndAutomationSessionStep(p.StepID, db.SessionStepLaunchFailed, out.LaunchFailed)
		if err == nil && !ok {
			err = fmt.Errorf("ending step %d launch_failed was refused", p.StepID)
		}
		return d.record(l, err)
	}

	wb, err := d.DB.GetWorkbench(p.WorkbenchID)
	if err != nil {
		return fmt.Errorf("workbench %d: %w", p.WorkbenchID, err)
	}
	res, err := d.DB.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id, automation_run_id)
		VALUES (?, ?, ?, ?, 'fake-session', ?)`, p.WorkbenchID, args.Agent, args.Title, wb.FolderPath, p.RunID)
	if err != nil {
		return fmt.Errorf("inserting the session of step %d: %w", p.StepID, err)
	}
	if l.SessionID, err = res.LastInsertId(); err != nil {
		return err
	}
	if ok, err := d.DB.AttachAutomationSessionStep(p.StepID, l.SessionID); err != nil {
		return err
	} else if !ok {
		return fmt.Errorf("attaching session %d to step %d was refused", l.SessionID, p.StepID)
	}
	switch {
	case out.Stopped:
		var ok bool
		if ok, err = d.DB.EndAutomationSessionStep(p.StepID, db.SessionStepStopped, ""); err == nil && !ok {
			err = fmt.Errorf("ending step %d stopped was refused", p.StepID)
		}
	case out.AgentError != "":
		_, err = d.DB.Exec(`UPDATE terminal_sessions SET agent_failed_at = '2026-10-14T12:30:00.000Z', agent_error = ? WHERE id = ?`,
			out.AgentError, l.SessionID)
	default:
		_, err = d.DB.Exec(`UPDATE terminal_sessions SET finished_at = '2026-10-14T12:30:00.000Z', finish_summary = ? WHERE id = ?`,
			out.Summary, l.SessionID)
	}
	return d.record(l, err)
}

func (d *FakeSessionDesk) record(l SessionLaunch, err error) error {
	if err != nil {
		return err
	}
	d.mu.Lock()
	d.launches = append(d.launches, l)
	d.mu.Unlock()
	return nil
}
