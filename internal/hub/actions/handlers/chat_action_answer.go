package handlers

import (
	"context"
	"errors"
	"log"

	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/inboxfeed"
	"watchtower/internal/tools"
	"watchtower/internal/tower/api"
)

// chatActionAnswer is `chat_action_answer` (params {action_id, decision
// approve|reject|retry|dismiss, args_sha256}): the owner's decision on an action a chat
// proposed, from the phone. It needs the permissions grant as well as chat
// (D9: never implied by chat). approve goes through the registry's
// ApproveSeen bound to the args the phone showed: a hash that no longer
// matches is refused changed ("The action changed — look again") and the
// row stays pending. An approved action no chat session runs itself is then
// run after the answer, as `watchtower actions approve` runs it. A row that
// is no longer pending (decided on the Mac, or failed by the chat's gate
// because its session died) answers not_pending with its status, the row's
// final state. An action of a chat that is not a main chat (a Discuss chat,
// spec §1) or of a deleted chat is not_found. retry and dismiss (mobile
// Inbox spec §12.9) follow inbox.act's own rules (inboxfeed.RetryAction,
// inboxfeed.DismissAction): a retried row is run after the answer as an
// approved one is; a repeated dismiss answers already and writes nothing.
// Non-idempotent. Result {status} (plus already).
func (h *Handlers) chatActionAnswer(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_action_answer", r, true, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		id, okID := intParam(r, "action_id")
		decision, okDec := stringParam(r, "decision")
		seen, _ := stringParam(r, "args_sha256")
		if !okID || !okDec || !validChatDecision(decision) {
			return failed(reasonInvalidParams, "chat_action_answer needs an action_id and a decision (approve, reject, retry or dismiss)")
		}
		if decision == "approve" && seen == "" {
			return failed(reasonInvalidParams, "approve needs the args_sha256 the phone showed")
		}
		row, err := h.d.DB.GetAgentAction(id)
		if err != nil {
			log.Printf("hub chat: reading action %d failed (%s)", id, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		if row == nil || row.ConversationID == 0 {
			return failed(reasonNotFound, chatActionGoneMessage)
		}
		// The phone answers only a main chat's actions (spec §1): a Discuss
		// chat's or a deleted chat's action is not found here.
		main, err := c.Engine.ConversationExists(ctx, row.ConversationID)
		if err != nil {
			log.Printf("hub chat: reading the chat of action %d failed (%s)", id, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		if !main {
			return failed(reasonNotFound, chatActionGoneMessage)
		}
		reg := c.Tools
		if reg == nil {
			reg = tools.New(h.d.DB)
		}
		switch decision {
		case "retry":
			return h.chatActionRetry(reg, id, h.d.Clock())
		case "dismiss":
			return chatActionDismiss(h.d.DB, reg, id)
		}
		if decision == "reject" {
			ok, err := reg.Reject(id)
			if err != nil {
				log.Printf("hub chat: rejecting action %d failed (%s)", id, errClass(err))
				return failed(reasonWriteFailed, chatWriteFailedMessage)
			}
			if !ok {
				return h.chatActionSettled(id)
			}
			return applied(map[string]any{"status": "rejected"})
		}
		ok, err := reg.ApproveSeen(ctx, id, nil, seen)
		switch {
		case errors.Is(err, tools.ErrBadTransition):
			return failed(reasonChanged, chatChangedMessage)
		case errors.Is(err, tools.ErrNotFound):
			return failed(reasonNotFound, chatActionGoneMessage)
		case err != nil:
			var v *tools.ValidationError
			if errors.As(err, &v) {
				return failed(reasonConflict, v.Msg)
			}
			log.Printf("hub chat: approving action %d failed (%s)", id, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		case !ok:
			return h.chatActionSettled(id)
		}
		if t, known := reg.Get(row.Tool); !known || !t.AppliedBySession {
			h.chatApply(reg, id)
		}
		return applied(map[string]any{"status": "approved"})
	})
}

// validChatDecision is a decision chat_action_answer takes.
func validChatDecision(d string) bool {
	return d == "approve" || d == "reject" || d == "retry" || d == "dismiss"
}

// chatApply runs approved (or retried) action id after the answer: the run
// is the registry's (its outcome reaches the phone through the feed).
func (h *Handlers) chatApply(reg *tools.Registry, id int64) {
	started := h.chatAsync("chat_action_apply", func(ctx context.Context) {
		if _, err := reg.Apply(ctx, id); err != nil {
			log.Printf("hub chat: action %d approved, its run failed (%s)", id, errClass(err))
		}
	})
	if !started {
		// The approval is on disk; `watchtower actions apply` or the Mac's
		// Retry runs it.
		log.Printf("hub chat: action %d approved while the hub stops: not run", id)
	}
}

// chatActionRetry is the retry decision: inbox.act's retry rule
// (inboxfeed.RetryAction), then the run after the answer, as approve does.
// Already running or applied answers not_pending with the row's state.
func (h *Handlers) chatActionRetry(reg *tools.Registry, id int64, now time.Time) actions.Outcome {
	row, res, run, err := inboxfeed.RetryAction(h.d.DB, reg, id, now)
	if err != nil {
		return chatActionRefusal("retrying", id, err)
	}
	if !run {
		o := failed(reasonNotPending, chatActionStatusMessage(row.Status))
		o.Result = map[string]any{"status": row.Status, "already": res.Already}
		return o
	}
	h.chatApply(reg, id)
	return applied(map[string]any{"status": "approved"})
}

// chatActionDismiss is the dismiss decision: inbox.act's dismiss rule
// (inboxfeed.DismissAction). A row already dismissed answers already, with
// its dismissed state, and writes nothing.
func chatActionDismiss(d *db.DB, reg *tools.Registry, id int64) actions.Outcome {
	res, err := inboxfeed.DismissAction(d, reg, id)
	if err != nil {
		return chatActionRefusal("dismissing", id, err)
	}
	return applied(map[string]any{"status": "failed", "dismissed": true, "already": res.Already})
}

// chatActionRefusal maps an inboxfeed refusal onto the chat's reasons and
// sentences; any other error is a write failure (its class logged).
func chatActionRefusal(verb string, id int64, err error) actions.Outcome {
	var r *inboxfeed.ActionRefusal
	if !errors.As(err, &r) {
		log.Printf("hub chat: %s action %d failed (%s)", verb, id, errClass(err))
		return failed(reasonWriteFailed, chatWriteFailedMessage)
	}
	switch r.Code {
	case api.CodeNotFound:
		return failed(reasonNotFound, chatActionGoneMessage)
	case api.CodeUnsupported:
		return failed(reasonNotSupported, chatSessionOnlyMessage)
	default:
		return failed(reasonChanged, chatChangedMessage)
	}
}

// chatActionSettled is the answer for a row that is no longer pending: its
// final state.
func (h *Handlers) chatActionSettled(id int64) actions.Outcome {
	var row *db.AgentAction
	row, err := h.d.DB.GetAgentAction(id)
	if err != nil || row == nil {
		return failed(reasonNotFound, chatActionGoneMessage)
	}
	o := failed(reasonNotPending, chatActionStatusMessage(row.Status))
	o.Result = map[string]any{"status": row.Status}
	return o
}

func chatActionStatusMessage(status string) string {
	switch status {
	case "approved", "executing", "applied":
		return "Already approved"
	case "rejected":
		return "Already declined"
	case "failed":
		return "This action ended without running here — its chat's answer may have ended"
	}
	return "This action is no longer waiting for an answer"
}
