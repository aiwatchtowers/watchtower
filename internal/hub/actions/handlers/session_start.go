package handlers

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	"github.com/rivo/uniseg"

	"watchtower/internal/hub/actions"
)

// SessionStartStopHandlers' values and messages, verbatim.
const (
	// StartBriefLimit is the phone's task description cap for a start
	// without a target, in characters.
	StartBriefLimit        = 4000
	startNotAllowedMessage = "This phone is not allowed to start sessions. " +
		"On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
	startTimeoutMessage = "The Mac did not finish this in time — check the session on the Mac"
	// TerminalLaunch.exitMessage(code: 127, agent:).
	claudeNotFoundMessage = "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart."
	codexNotFoundMessage  = "Codex was not found. Install it, or set codex_path in Watchtower's config, then try again."
)

// Start refusals the session port answers with (WorkbenchesViewModel's
// TargetStartError): the target left its board, a start of it is already
// running, or its session is being cleaned up. Each refuses before anything
// is launched.
var (
	ErrStartNotOnBoard = errors.New("handlers: the target is not on a workbench board")
	ErrStartInProgress = errors.New("handlers: a session for this target is being started")
	ErrStartCleaningUp = errors.New("handlers: this session is being cleaned up")
)

// AgentNotFoundError is the port's answer when the agent binary is missing:
// Codex's launch-args found no codex, or the launch exited 127 within the
// port's launch watch (the login shell found no claude). Agent is "claude"
// or "codex".
type AgentNotFoundError struct{ Agent string }

func (e *AgentNotFoundError) Error() string { return e.Agent + " was not found" }

// startStopKinds are SessionStartStopHandlers.kinds.
var startStopKinds = []string{"session_start", "session_stop"}

// sessionStartStop is `session_start` and `session_stop` (mobile POC spec
// §5.2, §6.5) over the session port.
//
// session_start (entity the target id; params {workbench_id, mode,
// plan_first, bring_forward, brief?}) needs the owner's start grant, typing
// and the phone's own toggle (#565), then re-checks the board scope (§5.2
// rule 3). The brief is the phone's own text only from a device allowed to
// type (PROJ-16), else the work-on prompt (an empty Brief); plan_first is
// the port's to add after either. open_existing answers the target's session
// when it has one. With no entity (#1189) it is New Session: mode new, the
// phone's brief required (1–StartBriefLimit characters after trimming).
// bring_forward is checked and has nothing to bring forward: the hub has no
// window. applied carries {session_id, stage: starting}.
//
// session_stop (entity the session id) is a host Stop request on a live
// board session; one that is not live is applied with no request.
func (h *Handlers) sessionStartStop(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, "session_start_stop", startTimeoutMessage, func(ctx context.Context) actions.Outcome {
		if r.Action.Kind == "session_stop" {
			return h.stopSession(ctx, r)
		}
		return h.startSession(ctx, r)
	})
}

func (h *Handlers) startSession(ctx context.Context, r actions.Request) actions.Outcome {
	workbenchID, okWB := intParam(r, "workbench_id")
	mode, okMode := stringParam(r, "mode")
	planFirst, okPlan := boolParam(r, "plan_first")
	_, okForward := boolParam(r, "bring_forward")
	if !okWB || !okMode || !okPlan || !okForward {
		return failed(reasonInvalidParams, "session_start needs a workbench_id, mode, plan_first and bring_forward")
	}
	if r.Action.EntityID == nil {
		return h.startUntargeted(ctx, r, workbenchID, mode, planFirst)
	}
	targetID, err := strconv.ParseInt(*r.Action.EntityID, 10, 64)
	if err != nil {
		return failed(reasonInvalidParams, "session_start's entity must be a target id")
	}
	if mode != "new" && mode != "open_existing" {
		return failed(reasonInvalidParams, "mode must be new or open_existing")
	}
	brief := ""
	if !isNull(r, "brief") {
		text, ok := stringParam(r, "brief")
		if !ok {
			return failed(reasonInvalidParams, "brief must be text")
		}
		brief = text
	}
	mayStart, typing := h.startGrant(r)
	if !mayStart {
		return failed(reasonDeviceNotAllowed, startNotAllowedMessage)
	}
	if refusal := h.startScope(ctx, targetID, workbenchID); refusal != nil {
		return *refusal
	}
	// An edited brief is honoured only from a device allowed to type (spec
	// §6.5); a blank one is no brief: the work-on prompt goes.
	if !typing || strings.TrimSpace(brief) == "" {
		brief = ""
	}
	target := targetID
	return h.launch(ctx, StartRequest{
		Workbench: workbenchID, Target: &target, Brief: brief, PlanFirst: planFirst, OpenExisting: mode == "open_existing",
	})
}

// startUntargeted is a start with no target (#1189): New Session with the
// phone's brief as the first message. It is the phone's own text, so it needs
// the typing grant too (the start grant already does); the mode can only be
// new.
func (h *Handlers) startUntargeted(ctx context.Context, r actions.Request, workbenchID int64, mode string, planFirst bool) actions.Outcome {
	if mode != "new" {
		return failed(reasonInvalidParams, "a start without a target is always mode new")
	}
	raw, ok := stringParam(r, "brief")
	if !ok {
		return failed(reasonInvalidParams, "a start without a target needs a brief")
	}
	brief := strings.TrimSpace(raw)
	if brief == "" {
		return failed(reasonInvalidParams, "The task description is empty")
	}
	if uniseg.GraphemeClusterCount(brief) > StartBriefLimit {
		return failed(reasonInvalidParams, "The task description is longer than "+strconv.Itoa(StartBriefLimit)+" characters")
	}
	if mayStart, typing := h.startGrant(r); !mayStart || !typing {
		return failed(reasonDeviceNotAllowed, startNotAllowedMessage)
	}
	exists, err := h.workbenchExists(ctx, workbenchID)
	if err != nil {
		return failed(reasonWriteFailed, "Could not read the workbench: "+err.Error())
	}
	if !exists {
		return failed(reasonNotFound, "This workbench no longer exists on the Mac")
	}
	return h.launch(ctx, StartRequest{Workbench: workbenchID, Brief: brief, PlanFirst: planFirst})
}

// launch starts the session through the port and answers its echo.
func (h *Handlers) launch(ctx context.Context, req StartRequest) actions.Outcome {
	res, err := h.d.Sessions.Start(ctx, req)
	var missing *AgentNotFoundError
	switch {
	case err == nil:
		return applied(map[string]any{"session_id": res.SessionID, "stage": "starting"})
	case errors.As(err, &missing):
		if missing.Agent == "codex" {
			return failed("codex_not_found", codexNotFoundMessage)
		}
		return failed("claude_not_found", claudeNotFoundMessage)
	case errors.Is(err, ErrStartNotOnBoard):
		return failed(reasonNotOnBoard, "That target is not on a workbench board")
	case errors.Is(err, ErrStartInProgress):
		return failed(reasonConflict, "A session for this target is being started on the Mac")
	case errors.Is(err, ErrStartCleaningUp):
		return failed(reasonConflict, "This session is being cleaned up on the Mac")
	}
	return failed(reasonWriteFailed, err.Error())
}

// startGrant reads the request's device's grants: mayStart is
// HubSyncState.mayStartSessions (the owner's start grant, typing and the
// phone's own toggle), typing its typing grant. A device not linked, or
// grants that cannot be read, may do neither.
func (h *Handlers) startGrant(r actions.Request) (mayStart, typing bool) {
	d, linked, err := h.d.Store.Device(r.Device.String())
	if err != nil || !linked {
		return false, false
	}
	return d.StartSessionsGranted && d.TypingAllowed && d.StartSessionsAllowed, d.TypingAllowed
}

// startScope is nil when the target is on workbenchID's board (§5.2 rule 3).
func (h *Handlers) startScope(ctx context.Context, targetID, workbenchID int64) *actions.Outcome {
	exists, err := h.workbenchExists(ctx, workbenchID)
	if err != nil {
		o := failed(reasonWriteFailed, "Could not read the workbench: "+err.Error())
		return &o
	}
	if !exists {
		o := failed(reasonNotFound, "This workbench no longer exists on the Mac")
		return &o
	}
	var project sql.NullInt64
	err = h.d.DB.QueryRowContext(ctx, `SELECT project_id FROM targets WHERE id = ?`, targetID).Scan(&project)
	if errors.Is(err, sql.ErrNoRows) {
		o := failed(reasonNotFound, "This target no longer exists on the Mac")
		return &o
	}
	if err != nil {
		o := failed(reasonWriteFailed, "Could not read the target: "+err.Error())
		return &o
	}
	if !project.Valid || project.Int64 != workbenchID {
		o := failed(reasonNotOnBoard, "That target is not on this workbench's board")
		return &o
	}
	return nil
}

func (h *Handlers) workbenchExists(ctx context.Context, workbenchID int64) (bool, error) {
	var one int
	err := h.d.DB.QueryRowContext(ctx, `SELECT 1 FROM projects WHERE id = ?`, workbenchID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// stopSession is a host Stop request (SIGHUP to the process group, then
// SIGKILL after the grace; its Exit carries requested: true). Idempotent: a
// session that is not live is applied with no request. A board session only:
// the phone sees the agent sessions of a workbench and nothing else.
func (h *Handlers) stopSession(ctx context.Context, r actions.Request) actions.Outcome {
	sessionID, ok := entityID(r)
	if !ok {
		return failed(reasonInvalidParams, "session_stop needs a session id")
	}
	_, onBoard, err := h.boardSession(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, "Could not read the session: "+err.Error())
	}
	if !onBoard {
		return failed(reasonNotFound, sessionGoneMessage)
	}
	live, running, err := h.d.Sessions.Live(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, "Could not reach the session host")
	}
	if running && !live.Exited {
		if err := h.d.Sessions.Stop(ctx, sessionID); err != nil {
			return failed(reasonWriteFailed, "Could not stop the session: "+err.Error())
		}
	}
	return applied(nil)
}

// boolParam is params[name] when it is a JSON boolean.
func boolParam(r actions.Request, name string) (bool, bool) {
	raw, ok := r.Action.Params[name]
	if !ok || string(raw) == "null" {
		return false, false
	}
	var v bool
	if err := json.Unmarshal(raw, &v); err != nil {
		return false, false
	}
	return v, true
}
