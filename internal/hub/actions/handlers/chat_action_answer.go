package handlers

import (
	"context"
	"errors"
	"log"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/tools"
)

// chatActionAnswer is `chat_action_answer` (params {action_id, decision
// approve|reject, args_sha256}): the owner's decision on an action a chat
// proposed, from the phone. It needs the permissions grant as well as chat
// (D9: never implied by chat). approve goes through the registry's
// ApproveSeen bound to the args the phone showed: a hash that no longer
// matches is refused changed ("The action changed — look again") and the
// row stays pending. An approved action no chat session runs itself is then
// run after the answer, as `watchtower actions approve` runs it. A row that
// is no longer pending (decided on the Mac, or failed by the chat's gate
// because its session died) answers not_pending with its status, the row's
// final state. Non-idempotent. Result {status}.
func (h *Handlers) chatActionAnswer(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_action_answer", r, true, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		id, okID := intParam(r, "action_id")
		decision, okDec := stringParam(r, "decision")
		seen, _ := stringParam(r, "args_sha256")
		if !okID || !okDec || (decision != "approve" && decision != "reject") {
			return failed(reasonInvalidParams, "chat_action_answer needs an action_id and a decision (approve or reject)")
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
		reg := c.Tools
		if reg == nil {
			reg = tools.New(h.d.DB)
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
			// The approval is on disk; the run is the registry's, after the
			// answer (its outcome reaches the phone through the feed).
			started := h.chatAsync("chat_action_apply", func(ctx context.Context) {
				if _, err := reg.Apply(ctx, id); err != nil {
					log.Printf("hub chat: action %d approved, its run failed (%s)", id, errClass(err))
				}
			})
			if !started {
				// The approval is on disk; `watchtower actions apply` or the
				// Mac's Retry runs it.
				log.Printf("hub chat: action %d approved while the hub stops: not run", id)
			}
		}
		return applied(map[string]any{"status": "approved"})
	})
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
