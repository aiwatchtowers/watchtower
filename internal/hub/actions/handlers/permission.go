package handlers

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/wire"
	"watchtower/internal/sessionstate"
)

// Wire reasons of the PROJ-21 kinds (the Kit's ActionReason).
const (
	reasonNotPending        = "not_pending"
	reasonAnswerOnMac       = "answer_on_mac"
	reasonSessionNotRunning = "session_not_running"
	reasonNotWorking        = "not_working"
	reasonExpired           = "expired"
)

// PROJ-21 values (PermissionAnswerHandlers), verbatim.
const (
	// InterruptMaxAge is the oldest interrupt the hub still sends: an Esc must
	// not land on a later turn the owner never saw.
	InterruptMaxAge = 120 * time.Second

	permissionTimeoutMessage   = "The Mac did not finish this in time — check the session on the Mac"
	answeredOnMacMessage       = "Answered on the Mac"
	tooLateMessage             = "Too late — answer on the Mac"
	sessionGoneMessage         = "This session no longer exists on the Mac"
	promptMayBeOpenMessage     = "A permission prompt may be open — answer it on the Mac or with Deny"
	notRunningMessage          = "This session is not running on the Mac"
	notWorkingMessage          = "The agent is not working right now"
	requestGoneMessage         = "This permission request no longer exists on the Mac"
	permissionsNotAllowedMsg   = "This phone is not allowed to answer permission prompts"
	typingNotAllowedMessage    = "This phone is not allowed to type into sessions"
	unnamedDevice              = "phone"
	permissionAnswerParamsMsg  = "permission_answer needs a session id, request_id and behavior"
	permissionBehaviorParamMsg = "behavior must be allow or deny"
)

// permissionAnswer is `permission_answer` (#517, spec
// 2026-10-17-phone-permission-answers §5.3; entity the session id, params
// {request_id, behavior: allow|deny}): decides one permission_requests row
// that the session's waiting permission-wait hook polls. Order: the device's
// own permissions_allowed grant (never implied by typing; else
// device_not_allowed) → the row is this board Claude session's (else
// not_found) and pending (else not_pending, its message naming why) → an
// allow the phone may give (AllowBlock plus the resolved path; else
// answer_on_mac, the row left pending; a deny always may) → the session runs
// (else session_not_running) → one guarded UPDATE … WHERE status = 'pending',
// so a Mac answer or a second phone that got there first leaves this one
// not_pending. Only the hook's JSON decides the prompt: nothing is typed into
// the terminal (PROJ-16 holds). Claimed begun before the handler, never held
// or retried.
func (h *Handlers) permissionAnswer(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, "permission_answer", permissionTimeoutMessage, func(ctx context.Context) actions.Outcome {
		return h.applyPermissionAnswer(ctx, r)
	})
}

func (h *Handlers) applyPermissionAnswer(ctx context.Context, r actions.Request) actions.Outcome {
	sessionID, okID := entityID(r)
	requestID, okReq := intParam(r, "request_id")
	behavior, okBeh := stringParam(r, "behavior")
	if !okID || !okReq || !okBeh {
		return failed(reasonInvalidParams, permissionAnswerParamsMsg)
	}
	var allow bool
	switch behavior {
	case "allow":
		allow = true
	case "deny":
	default:
		return failed(reasonInvalidParams, permissionBehaviorParamMsg)
	}
	device, linked, err := h.d.Store.Device(r.Device.String())
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !linked || !device.PermissionsAllowed {
		return failed(reasonDeviceNotAllowed, permissionsNotAllowedMsg)
	}
	board, err := h.claudeBoardSession(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !board {
		return failed(reasonNotFound, requestGoneMessage)
	}
	stored, found, err := h.storedRequest(ctx, requestID, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !found {
		return failed(reasonNotFound, requestGoneMessage)
	}
	if stored.status != "pending" {
		return notPending(stored.status)
	}
	if allow {
		if block, blocked := storedAllowBlock(stored.tool, stored.summary, stored.clipped); blocked {
			return failed(reasonAnswerOnMac, allowBlockNotes[block])
		}
	}
	live, ok, err := h.d.Sessions.Live(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !ok || live.Exited {
		return failed(reasonSessionNotRunning, notRunningMessage)
	}
	decided := "denied"
	if allow {
		decided = "allowed"
	}
	name := device.Name
	if name == "" {
		name = unnamedDevice
	}
	// One short write: the guard keeps an answer that landed since the read.
	res, err := h.d.DB.ExecContext(ctx, `UPDATE permission_requests SET status = ?, decided_at = ?, decided_by = ?
		WHERE id = ? AND terminal_session_id = ? AND status = 'pending'`,
		decided, db.AgentStateStamp(h.d.Clock()), name, requestID, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if n, err := res.RowsAffected(); err != nil {
		return failed(reasonWriteFailed, err.Error())
	} else if n != 1 {
		after, _, err := h.storedRequest(ctx, requestID, sessionID)
		if err != nil {
			return failed(reasonWriteFailed, err.Error())
		}
		return notPending(after.status)
	}
	return applied(map[string]any{"status": decided})
}

// notPending is not_pending with a message the phone shows as it is.
func notPending(status string) actions.Outcome {
	msg := "This prompt is no longer waiting for an answer"
	switch status {
	case "answered_on_mac":
		msg = answeredOnMacMessage
	case "expired":
		msg = tooLateMessage
	case "allowed":
		msg = "Already allowed"
	case "denied":
		msg = "Already denied"
	}
	return failed(reasonNotPending, msg)
}

// storedPermission is what an answer needs of a stored request.
type storedPermission struct {
	status, tool, summary string
	clipped               bool
}

// storedRequest is the row when it is sessionID's request; found is false
// otherwise.
func (h *Handlers) storedRequest(ctx context.Context, requestID, sessionID int64) (storedPermission, bool, error) {
	var p storedPermission
	err := h.d.DB.QueryRowContext(ctx, `SELECT status, tool_name, summary, summary_clipped FROM permission_requests
		WHERE id = ? AND terminal_session_id = ?`, requestID, sessionID).Scan(&p.status, &p.tool, &p.summary, &p.clipped)
	if errors.Is(err, sql.ErrNoRows) {
		return p, false, nil
	}
	return p, err == nil, err
}

// sessionInterrupt is `session_interrupt` (entity the session id): one Esc
// through session-host's InputTo, under the typing grant. Order:
// typing_allowed → a board Claude session → running → its resolved state is
// Working (Agents working included; never Running, which is no turn
// reported, and never Needs approval: an Esc must not answer a prompt; else
// not_working) → the action at most InterruptMaxAge old (else expired) → no
// pending permission request (Claude Code draws a prompt before its hook
// reports it, so the state may still say Working; else not_working with the
// prompt message). Claimed begun before the handler, never held or retried.
func (h *Handlers) sessionInterrupt(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withTimeout(ctx, "session_interrupt", permissionTimeoutMessage, func(ctx context.Context) actions.Outcome {
		return h.applySessionInterrupt(ctx, r)
	})
}

func (h *Handlers) applySessionInterrupt(ctx context.Context, r actions.Request) actions.Outcome {
	sessionID, ok := entityID(r)
	if !ok {
		return failed(reasonInvalidParams, "session_interrupt needs a session id")
	}
	device, linked, err := h.d.Store.Device(r.Device.String())
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !linked || !device.TypingAllowed {
		return failed(reasonDeviceNotAllowed, typingNotAllowedMessage)
	}
	board, err := h.claudeBoardSession(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !board {
		return failed(reasonNotFound, sessionGoneMessage)
	}
	live, running, err := h.d.Sessions.Live(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if !running || live.Exited {
		return failed(reasonSessionNotRunning, notRunningMessage)
	}
	if s, _, fresh := h.readState(ctx, sessionID, live); !fresh || !sessionstate.IsWorking(s) {
		return failed(reasonNotWorking, notWorkingMessage)
	}
	if h.d.Clock().Sub(r.Action.CreatedAt.Time) > InterruptMaxAge {
		return actions.Outcome{Status: wire.StatusExpired, Reason: reasonExpired}
	}
	pending, err := h.hasPendingRequest(ctx, sessionID)
	if err != nil {
		return failed(reasonWriteFailed, err.Error())
	}
	if pending {
		return failed(reasonNotWorking, promptMayBeOpenMessage)
	}
	if err := h.d.Sessions.Interrupt(ctx, sessionID, live.Run); err != nil {
		// The Esc may or may not have reached the terminal: a session gone
		// meanwhile is not running, anything else is for the Mac to check.
		if _, still, lerr := h.d.Sessions.Live(ctx, sessionID); lerr == nil && !still {
			return failed(reasonSessionNotRunning, notRunningMessage)
		}
		return failed(reasonOutcomeUnknown, permissionTimeoutMessage)
	}
	return applied(nil)
}

func (h *Handlers) hasPendingRequest(ctx context.Context, sessionID int64) (bool, error) {
	var pending bool
	err := h.d.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM permission_requests
		WHERE terminal_session_id = ? AND status = 'pending')`, sessionID).Scan(&pending)
	return pending, err
}

// claudeBoardSession: a claude session of a workbench that still exists
// (BoardSessionScope.fetchBoardSession, kind claude). The phone sees nothing
// else, and Codex keeps "Needs approval on the Mac".
func (h *Handlers) claudeBoardSession(ctx context.Context, sessionID int64) (bool, error) {
	var ok bool
	err := h.d.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM terminal_sessions s
		JOIN projects p ON p.id = s.project_id WHERE s.id = ? AND s.kind = 'claude')`, sessionID).Scan(&ok)
	return ok, err
}
