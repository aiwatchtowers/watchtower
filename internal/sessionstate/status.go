// Package sessionstate is the Go twin of the Desktop's SessionAgentStatus
// (WatchtowerCore/Models/SessionAgentStatus.swift): what a Claude Code or
// Codex session's workbench hooks last reported, resolved with the open asks
// into one state. The two sides are pinned by testdata/status_cases.json.
package sessionstate

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// Querier is the one read the package needs; *sql.DB, *sql.Tx and *sql.Conn
// satisfy it.
type Querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Row is what the state is resolved from: a terminal_sessions row, its open
// asks, and the start of the process run the caller (the session host) knows.
type Row struct {
	ID   int64
	Kind string
	// AgentState is the raw column; a value this build does not know reads as
	// no state.
	AgentState        *string
	AgentStateAt      *string
	FinishedAt        *string
	AgentFailedAt     *string
	AgentBackgroundAt *string
	ChatQuestionAt    *string
	AgentCwdAt        *string
	AgentBackground   *int
	// Open asks of the session; the question and review ones are subsets.
	OpenAsks         int
	OpenQuestionAsks int
	OpenReviewAsks   int
	// RunStartedAt is the start of the live process run in the agent-state
	// stamp layout; "" = the session is not live. Load leaves it empty: only
	// the host knows the run.
	RunStartedAt string
}

// State is a session's effective status.
type State string

const (
	StateNotStarted    State = "not_started"
	StateRunning       State = "running"        // live, no hook state in this run
	StateMarkedIdle    State = "marked_idle"    // live, the run's mark and no turn yet
	StateWorking       State = "working"        //
	StateAgentsWorking State = "agents_working" // main turn over, background agents run
	StateNeedsApproval State = "needs_approval"
	StateError         State = "error"
	StateStopped       State = "stopped"
	StateWaitingForYou State = "waiting_for_you" // an open question ask
	StateReadyToCheck  State = "ready_to_check"  // open asks, none a question
	StateFinished      State = "finished"
)

// backgroundGrace is how long a background count of zero still shows as
// agents working (SessionBackgroundPolicy.grace).
const backgroundGrace = 120 * time.Second

// Resolve is SessionAgentStatus.effective: the hook states count only for a
// live session and only when written during the current run; finished and the
// open asks are not run-scoped.
func Resolve(r Row, now time.Time) State {
	live := r.RunStartedAt != ""
	hook := trustedHook(r)
	failed := hook == "waiting" && r.AgentFailedAt != nil && r.AgentStateAt != nil && *r.AgentFailedAt == *r.AgentStateAt
	switch {
	case hook == "approval":
		return StateNeedsApproval
	case failed:
		return StateError
	case hook == "working":
		return StateWorking
	case hook == "waiting" && backgroundRuns(r, now):
		return StateAgentsWorking
	}
	switch {
	case r.OpenAsks > 0 && r.OpenQuestionAsks == 0:
		return StateReadyToCheck
	case r.FinishedAt != nil:
		return StateFinished
	case r.OpenAsks > 0:
		return StateWaitingForYou
	case hook == "waiting":
		return StateStopped
	case !live:
		return StateNotStarted
	case runMarked(r):
		return StateMarkedIdle
	}
	return StateRunning
}

// HooksReported reports whether the hooks wrote during the current run (a state or the run's
// mark), so a permission prompt on screen would show as needs_approval.
func HooksReported(r Row) bool { return r.RunStartedAt != "" && (trustedHook(r) != "" || runMarked(r)) }

// IsIdle reports whether the agent sits at its prompt with nothing running.
func IsIdle(s State) bool {
	return s == StateStopped || s == StateFinished || s == StateWaitingForYou || s == StateReadyToCheck ||
		s == StateError || s == StateAgentsWorking || s == StateMarkedIdle
}

// IsWorking reports whether the agent, or its background agents, are busy.
func IsWorking(s State) bool { return s == StateWorking || s == StateAgentsWorking }

// NeedsApproval reports whether a permission dialog waits.
func NeedsApproval(s State) bool { return s == StateNeedsApproval }

// trustedHook is the stored hook state when the session is live and it was
// written at or after the run's start; "" otherwise (an unreadable stamp or an
// unknown value counts as none).
func trustedHook(r Row) string {
	if r.AgentState == nil || !writtenThisRun(r) {
		return ""
	}
	switch s := *r.AgentState; s {
	case "working", "waiting", "approval":
		return s
	}
	return ""
}

func writtenThisRun(r Row) bool {
	if r.RunStartedAt == "" || r.AgentStateAt == nil {
		return false
	}
	start, ok := db.ParseAgentStateStamp(r.RunStartedAt)
	if !ok {
		return false
	}
	at, ok := db.ParseAgentStateStamp(*r.AgentStateAt)
	return ok && !at.Before(start)
}

// runMarked: no state at all (an unknown value may be a dialog of its own, so
// it vouches for nothing) and a stamp of this run.
func runMarked(r Row) bool { return r.AgentState == nil && writtenThisRun(r) }

// backgroundRuns is SessionBackgroundPolicy.verdict over the row's count.
func backgroundRuns(r Row, now time.Time) bool {
	if r.AgentBackground == nil || r.AgentBackgroundAt == nil {
		return false
	}
	reported, ok := db.ParseAgentStateStamp(*r.AgentBackgroundAt)
	if !ok || reported.After(now) {
		return false
	}
	return *r.AgentBackground > 0 || now.Sub(reported) < backgroundGrace
}

// Load reads the session's row and its open asks. RunStartedAt stays empty.
func Load(ctx context.Context, q Querier, sessionID int64) (Row, error) {
	r := Row{ID: sessionID}
	err := q.QueryRowContext(ctx, `
SELECT t.kind, t.agent_state, t.agent_state_at, t.finished_at, t.agent_failed_at,
       t.agent_background, t.agent_background_at, t.chat_question_at, t.agent_cwd_at,
       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = t.id AND a.status = 'open'),
       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = t.id AND a.status = 'open' AND a.kind = 'question'),
       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = t.id AND a.status = 'open' AND a.kind = 'review')
FROM terminal_sessions t WHERE t.id = ?`, sessionID).Scan(
		&r.Kind, &r.AgentState, &r.AgentStateAt, &r.FinishedAt, &r.AgentFailedAt,
		&r.AgentBackground, &r.AgentBackgroundAt, &r.ChatQuestionAt, &r.AgentCwdAt,
		&r.OpenAsks, &r.OpenQuestionAsks, &r.OpenReviewAsks)
	if err != nil {
		return Row{}, fmt.Errorf("load session %d state: %w", sessionID, err)
	}
	return r, nil
}
