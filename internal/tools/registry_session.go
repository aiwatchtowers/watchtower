package tools

import (
	"encoding/json"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// Session-applied rows (Tool.AppliedBySession, #737). The chat session that
// proposed the row is its only applier: it waits on the CLI's permission
// request, claims the row once the owner approved, answers the CLI with the
// approved input and records the call's outcome. Every transition is the same
// conditional update Apply uses, so a row runs at most once (AGENT-05).

// agentActionTimeLayout is agent_actions.created_at's own layout
// (strftime('%Y-%m-%dT%H:%M:%SZ')), so a cutoff compares as a string.
const agentActionTimeLayout = "2006-01-02T15:04:05Z"

// Error texts of rows a dead session left behind (ExpireSessionCalls).
const (
	sessionEndedBeforeApproval = "session ended before approval"
	sessionEndedWhileRunning   = "session ended while the call ran; outcome unknown"
)

// sessionRow reads row id and checks it belongs to an AppliedBySession tool:
// these methods never move a row Apply owns.
func (r *Registry) sessionRow(id int64) (*db.AgentAction, error) {
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
	return row, nil
}

// ClaimSessionCall takes an approved session call for running:
// `approved → executing` in one conditional update, so of two claims only one
// wins. On success the returned row carries the approved args (the owner's
// edits included). False (no error) means the row was not approved; the row
// returned then is the one read just before the claim, so the caller can
// tell "still pending, keep waiting" from a row that will never run here
// (rejected, expired, claimed by another) — and re-reads when it read
// "approved" (another claim won in between).
func (r *Registry) ClaimSessionCall(id int64) (*db.AgentAction, bool, error) {
	before, err := r.sessionRow(id)
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
func (r *Registry) FinishSessionCall(id int64, resultJSON string, callErr string) error {
	if _, err := r.sessionRow(id); err != nil {
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

// CancelSessionCall withdraws a call that has not run — `pending|approved →
// rejected` with reason as its error (Stop, Close, the approval timeout).
// False (no error) means the row was no longer pending or approved: the
// session claimed it, the owner rejected it, or it expired.
func (r *Registry) CancelSessionCall(id int64, reason string) (bool, error) {
	if _, err := r.sessionRow(id); err != nil {
		return false, err
	}
	return r.db.TransitionAgentAction(id, []string{"pending", "approved"}, "rejected", "", reason)
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

// sessionApplied reports whether name is a registered AppliedBySession tool.
func (r *Registry) sessionApplied(name string) bool {
	t, ok := r.Get(name)
	return ok && t.AppliedBySession
}
