package handlers

import (
	"context"

	"watchtower/internal/askanswer"
)

// The delivery types live with the one answer path (askanswer); the
// handlers keep their names.
const (
	DeliverSubmitted   = askanswer.DeliverSubmitted
	DeliverTyped       = askanswer.DeliverTyped
	DeliverHeld        = askanswer.DeliverHeld
	DeliverNoSession   = askanswer.DeliverNoSession
	DeliverNoPasteMode = askanswer.DeliverNoPasteMode
)

type (
	// DeliverRequest is askanswer.DeliverRequest: every phone line sets
	// HoldIfPromptText, so the host never pastes beside the owner's draft,
	// a pending Return or a line left typed.
	DeliverRequest = askanswer.DeliverRequest
	CheckAnswer    = askanswer.CheckAnswer
	DeliverResult  = askanswer.DeliverResult
	LiveRun        = askanswer.LiveRun
)

// StartRequest starts an agent session on a workbench (Task 3/15). Brief ""
// is the work-on prompt; PlanFirst follows the brief (or that prompt) with
// TerminalLaunch.planFirstSuffix; OpenExisting answers (and resumes) the
// target's session when it has one, sending neither. Refusals:
// ErrStartNotOnBoard, ErrStartInProgress, ErrStartCleaningUp,
// *AgentNotFoundError. Title "" is the target's text (else a provisional
// title); AutomationRunID (0 = none) is the automation run whose session()
// step starts it — stored on the row and carried by every launch.
// FolderID is the workbench folder the session starts for (0 = the home
// folder); ParentSessionID the session starting it as a sub-session (0 =
// none; multi-folder workbench, spec 2026-11-18 §6.4–6.5).
type StartRequest struct {
	Workbench               int64
	Target                  *int64
	Agent, Place, Brief     string
	Title                   string
	AutomationRunID         int64
	PlanFirst, OpenExisting bool
	FolderID                int64
	ParentSessionID         int64
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
	// Live and Deliver: askanswer.Sessions.
	askanswer.Sessions
	// Interrupt writes one Esc through InputTo.
	Interrupt(ctx context.Context, sessionID int64, run uint64) error
	Start(ctx context.Context, r StartRequest) (StartResult, error)
	// Stop is a host Stop request: its Exit carries requested: true.
	Stop(ctx context.Context, sessionID int64) error
}
