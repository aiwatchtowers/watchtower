// Package sessionline is the one rule set for typing a line into a running
// agent session (PROJ-16, PROJ-12): when a line may go (Gate), when a line
// just submitted still holds the next (JustSubmitted), and when its Return
// may follow (Vouch). The hub's phone lines and the daemon's agent messages
// both decide by it; who sent the line and how its outcome is reported stay
// with each caller.
package sessionline

import (
	"context"
	"time"

	"watchtower/internal/agentkind"
	"watchtower/internal/db"
	"watchtower/internal/sessionagent"
	"watchtower/internal/sessionstate"
)

// Hold reasons (the phone's ActionReason wire values).
const (
	HoldNeedsApproval = "needs_approval"
	HoldAgentBusy     = "agent_busy"
)

// BusyAfterSubmit is how long a session counts as busy after a line was
// submitted into it, unless a hook reports after the submit first
// (SessionControl.submitSettle).
const BusyAfterSubmit = 30 * time.Second

// Gate is the session condition for a line right before its paste, from the
// session's state row (RunStartedAt set for the live run) and its agent's
// capability row: hold is "" when the line may go, HoldNeedsApproval at a
// permission prompt, HoldAgentBusy when the agent is neither idle nor
// working, or works and its row does not TakesLineWhileWorking (an MCP form
// it opens mid-turn would take the line). whileBusy reports a line that goes
// while the agent works. A line just submitted holds too (JustSubmitted).
func Gate(row sessionstate.Row, now time.Time) (hold string, whileBusy bool) {
	agent, _ := agentkind.Parse(row.Kind)
	return GateWith(row, now, sessionagent.CapsOf(string(agent)))
}

// GateWith is Gate over the capability row caps instead of the row's kind's
// (the hub's handlers decide by their own, swappable, caps lookup).
func GateWith(row sessionstate.Row, now time.Time, caps sessionagent.Caps) (hold string, whileBusy bool) {
	s := sessionstate.Resolve(row, now)
	working := sessionstate.IsWorking(s) && caps.Phone().InputWhileWorking
	switch {
	case sessionstate.NeedsApproval(s):
		return HoldNeedsApproval, false
	case !sessionstate.IsIdle(row, s) && !working:
		return HoldAgentBusy, false
	}
	return "", working
}

// JustSubmitted reports a line that went into the session at submittedAt
// (zero: none) within BusyAfterSubmit, with no hook reported since — the
// agent is turning to it, so the next line waits.
func JustSubmitted(submittedAt time.Time, row sessionstate.Row, now time.Time) bool {
	if submittedAt.IsZero() || now.Sub(submittedAt) >= BusyAfterSubmit {
		return false
	}
	stamp, ok := db.ParseAgentStateStamp(sessionstate.TrustedHookAt(row))
	return !ok || !stamp.After(submittedAt)
}

// Vouch is a delivery check's answer (PROJ-12, "the hooks vouch for the
// run"): the Return goes only on a fresh read of a run whose hooks reported
// and that shows no permission dialog; at a dialog the line answers it.
func Vouch(row sessionstate.Row, s sessionstate.State, fresh bool) (fresh2, canSubmit, answersDialog bool) {
	return fresh, fresh && sessionstate.HooksReported(row) && !sessionstate.NeedsApproval(s), sessionstate.NeedsApproval(s)
}

// Load reads the session's state row with runStarted (zero: no live run
// known) as its run and resolves it at now. A row that is gone or being
// deleted is sql.ErrNoRows (wrapped).
func Load(ctx context.Context, q sessionstate.Querier, sessionID int64, runStarted, now time.Time) (sessionstate.State, sessionstate.Row, error) {
	row, err := sessionstate.Load(ctx, q, sessionID)
	if err != nil {
		return "", row, err //nolint:wrapcheck // sessionstate.Load names the session
	}
	if !runStarted.IsZero() {
		row.RunStartedAt = db.AgentStateStamp(runStarted)
	}
	return sessionstate.Resolve(row, now), row, nil
}
