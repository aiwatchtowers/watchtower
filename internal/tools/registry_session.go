package tools

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// Session-applied rows (Tool.AppliedBySession, #737). The chat-session
// process that proposed the row is its only applier: it waits on the CLI's
// permission request, claims the row once the owner approved, answers the CLI
// with the approved input and records the call's outcome. The row carries
// that process's session token (Binding.SessionToken, written by
// ProposeSessionCall and never changed), and every per-row method below takes
// the token and refuses a row of another token — a respawned, resumed or
// replayed process of the same conversation never claims a call it did not
// hold. Every transition is the same conditional update Apply uses, so a row
// runs at most once (AGENT-05).

// agentActionTimeLayout is agent_actions.created_at's own layout
// (strftime('%Y-%m-%dT%H:%M:%SZ')), so a cutoff compares as a string.
const agentActionTimeLayout = "2006-01-02T15:04:05Z"

// Error texts of rows a dead session left behind (ExpireSessionCalls).
const (
	sessionEndedBeforeApproval = "session ended before approval"
	sessionEndedWhileRunning   = "session ended while the call ran; outcome unknown"
)

// ErrNotThisSession is a session method naming a row another session process
// proposed (its session token differs).
var ErrNotThisSession = errors.New("the call belongs to another chat session")

// sessionRow reads row id and checks it is a session-applied call of the
// session holding token: these methods never move a row Apply owns, nor one
// of another session. The token is written once at propose time, so the
// check stays true for the conditional update that follows.
func (r *Registry) sessionRow(id int64, token string) (*db.AgentAction, error) {
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, ErrNotFound
	}
	if !r.sessionApplied(row.Tool) {
		return nil, fmt.Errorf("%w: #%d (%s) is not a session-applied call", ErrBadTransition, id, row.Tool)
	}
	if token == "" || row.SessionToken != token {
		return nil, fmt.Errorf("#%d: %w", id, ErrNotThisSession)
	}
	return row, nil
}

// ClaimSessionCall takes an approved session call for running:
// `approved → executing` in one conditional update, so of two claims only one
// wins. On success the returned row carries the approved args (the owner's
// edits included). False (no error) means the row was not approved; the row
// returned then is the one read just before the claim, so the caller can
// tell "still pending, keep waiting" from a row that will never run here
// (rejected, expired, claimed) — and re-reads when it read "approved"
// (another claim won in between). A row of another session token is
// ErrNotThisSession.
func (r *Registry) ClaimSessionCall(id int64, token string) (*db.AgentAction, bool, error) {
	before, err := r.sessionRow(id, token)
	if err != nil {
		return nil, false, err
	}
	ok, err := r.db.TransitionAgentAction(id, []string{"approved"}, "executing", "", "")
	if err != nil {
		return nil, false, err
	}
	if !ok {
		return before, false, nil
	}
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, false, err
	}
	if row == nil {
		return nil, false, ErrNotFound
	}
	return row, true, nil
}

// FinishSessionCall records a claimed call's outcome: `executing → applied`
// when callErr is empty, else `failed` with callErr — so the caller passes a
// non-empty callErr for every error result, a fixed text when the connector
// gave none. A result that is not JSON (a tool result's text) is stored as a
// JSON string, so result_json always decodes. A row no longer executing
// (expired meanwhile) is ErrBadTransition, and the error carries the outcome
// the row could not record, for the caller to log.
func (r *Registry) FinishSessionCall(id int64, token, resultJSON, callErr string) error {
	if _, err := r.sessionRow(id, token); err != nil {
		return err
	}
	if resultJSON != "" && !json.Valid([]byte(resultJSON)) {
		quoted, _ := json.Marshal(resultJSON) // a Go string always marshals
		resultJSON = string(quoted)
	}
	to := "applied"
	if callErr != "" {
		to = "failed"
	}
	if _, err := r.finishTransition(id, []string{"executing"}, to, resultJSON, callErr); err != nil {
		return fmt.Errorf("recording the %s outcome (result %s, call error %q): %w", to, resultJSON, callErr, err)
	}
	return nil
}

// CancelSessionCall withdraws a call the owner has not approved —
// `pending → rejected` with reason as its error (the approval timeout, Stop).
// It never takes an approved row: an Approve that lands just before the
// timeout wins, and false comes back with the row as it now stands, so the
// caller sees "approved" and goes on to ClaimSessionCall. False with another
// status means the row is settled (rejected by the owner, expired, claimed).
// Withdrawing an approved row that will not be claimed (Close, Stop of a
// session that will not answer) is the explicit ExpireSessionCall.
func (r *Registry) CancelSessionCall(id int64, token, reason string) (*db.AgentAction, bool, error) {
	if _, err := r.sessionRow(id, token); err != nil {
		return nil, false, err
	}
	ok, err := r.db.TransitionAgentAction(id, []string{"pending"}, "rejected", "", reason)
	if err != nil {
		return nil, false, err
	}
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return nil, ok, err
	}
	if row == nil {
		return nil, ok, ErrNotFound
	}
	return row, ok, nil
}

// ExpireSessionCall lands one unclaimed call of this session `failed` with
// reason — from pending or approved — when the session will never run it
// (Close, or Stop after the owner approved). Unlike CancelSessionCall it takes
// an approved row: the owner's Approve stands in the audit trail, the error
// says why it did not run. False means the row was already claimed or settled.
func (r *Registry) ExpireSessionCall(id int64, token, reason string) (bool, error) {
	if _, err := r.sessionRow(id, token); err != nil {
		return false, err
	}
	return r.db.TransitionAgentAction(id, []string{"pending", "approved"}, "failed", "", reason)
}

// ExpireSessionCalls fails every open session call whose session is gone:
// the rows of conversationID (its session is starting anew, so the old one
// is dead) whatever their age, and the rows of any other conversation created
// before staleBefore (no live session waits that long). A pending or approved
// row lands `failed` with "session ended before approval"; an executing one
// with "session ended while the call ran; outcome unknown". Such a row can
// never run again: Apply refuses it and only a live CLI request could. Each
// row moves by its own conditional update, so a row a live session claims
// meanwhile is left alone. Returns how many rows it failed.
func (r *Registry) ExpireSessionCalls(conversationID int64, staleBefore time.Time) (int, error) {
	cutoff := staleBefore.UTC().Format(agentActionTimeLayout)
	n := 0
	for _, status := range []string{"pending", "approved", "executing"} {
		rows, err := r.db.ListAgentActions(db.AgentActionFilter{Status: status})
		if err != nil {
			return n, err
		}
		msg := sessionEndedBeforeApproval
		if status == "executing" {
			msg = sessionEndedWhileRunning
		}
		for _, row := range rows {
			if !r.sessionApplied(row.Tool) {
				continue
			}
			own := conversationID != 0 && row.ConversationID == conversationID
			if !own && row.CreatedAt >= cutoff {
				continue
			}
			ok, err := r.db.TransitionAgentAction(row.ID, []string{status}, "failed", "", msg)
			if err != nil {
				return n, err
			}
			if ok {
				n++
			}
		}
	}
	return n, nil
}

// DismissSessionCall is the owner's acknowledgement of a session call whose
// session ended while it ran ("outcome unknown"): such a row waits on the
// owner (the Desktop's Inbox badge, owner decision in ask #342) until this
// stamps its dismissed_at. The status stays `failed` — nothing ever moves a
// failed session call — so a dismiss is a label, not a transition. A row
// already dismissed is a no-op; any other row (another tool or reason, one
// still open) is ErrBadTransition, ErrNotFound when it is gone.
func (r *Registry) DismissSessionCall(id int64) error {
	row, err := r.db.GetAgentAction(id)
	if err != nil {
		return err
	}
	if row == nil {
		return ErrNotFound
	}
	if !r.sessionApplied(row.Tool) || row.Status != "failed" || row.Error != sessionEndedWhileRunning {
		return fmt.Errorf("%w: #%d is not a chat-session call whose outcome is unknown", ErrBadTransition, id)
	}
	_, err = r.db.DismissAgentAction(id, sessionEndedWhileRunning)
	return err
}

// sessionApplied reports whether name is a registered AppliedBySession tool.
func (r *Registry) sessionApplied(name string) bool {
	t, ok := r.Get(name)
	return ok && t.AppliedBySession
}
