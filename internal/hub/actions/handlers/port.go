package handlers

import (
	"context"
	"time"
)

// Deliver outcomes (session-host's DeliveredMsg): the line was submitted with
// its own Return, pasted and left typed, held by the host (Reason
// prompt_has_text), the session is gone or runs another launch, or bracketed
// paste is off (nothing written).
const (
	DeliverSubmitted   = "submitted"
	DeliverTyped       = "typed"
	DeliverHeld        = "held"
	DeliverNoSession   = "no_session"
	DeliverNoPasteMode = "no_paste_mode"
)

// DeliverRequest is one line for session-host's typed-never-submitted
// delivery (PROJ-12): Run is the launch the caller checked (another one
// answers no_session), Settle the pause between the paste and the Return
// (submitSettle), Check the caller's re-check after that pause. Every phone
// line sets HoldIfPromptText, so the host never pastes beside the owner's
// draft, a pending Return or a line left typed.
type DeliverRequest struct {
	SessionID                                    int64
	Run                                          uint64
	Text                                         string
	KeepLineBreaks, KeepFormat, HoldIfPromptText bool
	Settle                                       time.Duration
	Check                                        func(ctx context.Context) CheckAnswer
}

// CheckAnswer is the caller's re-check after the pause: Fresh = the state read
// succeeded, CanSubmit = the Return may follow (the hooks reported this run
// and no permission prompt shows), AnswersDialog = a permission prompt shows,
// so the owner's own Return during the pause answered it, not the line.
type CheckAnswer struct{ Fresh, CanSubmit, AnswersDialog bool }

// DeliverResult is the host's answer: Outcome one of the Deliver* values,
// Reason why the host held it (prompt_has_text).
type DeliverResult struct{ Outcome, Reason string }

// LiveRun is one session as session-host's non-attaching list shows it:
// Run is the launch counter, StartedAt when that launch began (the run start
// sessionstate scopes the hook states to), Exited a run that ended and was not
// forgotten yet.
type LiveRun struct {
	SessionID int64
	Run       uint64
	Agent     string
	StartedAt time.Time
	Exited    bool
}

// StartRequest starts an agent session on a workbench (Task 3/15). Brief ""
// is the work-on prompt; PlanFirst follows the brief (or that prompt) with
// TerminalLaunch.planFirstSuffix; OpenExisting answers (and resumes) the
// target's session when it has one, sending neither. Refusals:
// ErrStartNotOnBoard, ErrStartInProgress, ErrStartCleaningUp,
// *AgentNotFoundError.
type StartRequest struct {
	Workbench               int64
	Target                  *int64
	Agent, Place, Brief     string
	PlanFirst, OpenExisting bool
}

// StartResult is the started row and its state.
type StartResult struct {
	SessionID int64
	State     string
}

// SessionPort is the hub's way into session-host (the real wiring is Task
// 15). The hub holds its own dedicated Client, so Deliver blocks for the pause
// plus up to 5 s of re-check; a text that is empty after the host's cleaning
// comes back as an error (not delivered).
type SessionPort interface {
	// Live reads the session from session-host's non-attaching list, this
	// workspace's scope only; ok is false when the host runs no such session.
	Live(ctx context.Context, sessionID int64) (LiveRun, bool, error)
	Deliver(ctx context.Context, r DeliverRequest) (DeliverResult, error)
	// Interrupt writes one Esc through InputTo.
	Interrupt(ctx context.Context, sessionID int64, run uint64) error
	Start(ctx context.Context, r StartRequest) (StartResult, error)
	// Stop is a host Stop request: its Exit carries requested: true.
	Stop(ctx context.Context, sessionID int64) error
}
