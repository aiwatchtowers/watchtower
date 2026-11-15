package handlers

import (
	"context"
	"errors"
	"log"
	"unicode/utf8"

	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/chatrun"
)

// chatNew is `chat_new` (params {client_key, project_id?, routing?}): a new
// main chat, as the Mac's Chats panel makes one. Non-idempotent: the ledger
// answers a repeat with the first echo, so a retried request never makes a
// second chat. Result {conversation_id}; refusals invalid_params, not_found
// (the project).
func (h *Handlers) chatNew(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_new", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		if key, ok := stringParam(r, "client_key"); !ok || key == "" {
			return failed(reasonInvalidParams, "chat_new needs a client_key")
		}
		var project *int64
		if !isNull(r, "project_id") {
			p, ok := intParam(r, "project_id")
			if !ok {
				return failed(reasonInvalidParams, "project_id must be a number")
			}
			project = &p
		}
		routing, ok := chatRouting(r)
		if !ok {
			return failed(reasonInvalidParams, "routing must be {mode: auto} or {mode: pinned, provider, model?}")
		}
		id, err := c.Store.NewConversation(ctx, project, routing)
		switch {
		case errors.Is(err, chatstore.ErrProjectGone):
			return failed(reasonNotFound, "This chat project no longer exists on your Mac")
		case errors.Is(err, chatstore.ErrInvalid):
			return failed(reasonInvalidParams, "This model is not available on your Mac")
		case err != nil:
			log.Printf("hub chat: creating a chat failed (%s)", errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		return applied(map[string]any{"conversation_id": id})
	})
}

// chatTurn is `chat_turn` (params {conversation_id, mode send|regenerate|
// edit, message_id?, text, attachment_ids, routing?}): a turn the hub runs
// (chatrun.Runner). Non-idempotent with a received echo: the answer waits
// only for the start transaction (the owner's row, the lease); the turn then
// runs in the background and reaches the phone through chat_feed. Result
// {user_message_id, assistant_message_id, turn_id}; refusals
// conversation_busy (another turn holds the lease), not_found,
// invalid_params, attachment_missing.
func (h *Handlers) chatTurn(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_turn", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		req, refused := chatTurnRequest(r)
		if refused != nil {
			return *refused
		}
		if c.Runner == nil {
			return failed(reasonNotSupported, chatOffMessages["runner_down"])
		}
		st, err := c.Runner.Run(ctx, req)
		switch {
		case errors.Is(err, chatstore.ErrBusy):
			return failed(reasonConversationBusy, chatBusyMessage)
		case errors.Is(err, chatstore.ErrConversationGone):
			return failed(reasonNotFound, chatGoneMessage)
		case errors.Is(err, chatstore.ErrNotFound):
			return failed(reasonNotFound, chatMessageGoneMessage)
		case errors.Is(err, chatstore.ErrAttachmentMissing):
			return failed(reasonAttachmentMissing, chatAttachmentGone)
		case errors.Is(err, chatstore.ErrInvalid):
			return failed(reasonInvalidParams, "Your Mac can't send this message as it is")
		case errors.Is(err, chatrun.ErrClosed):
			return failed(reasonNotSupported, chatHubStoppingMessage)
		case err != nil:
			log.Printf("hub chat: starting a turn of chat %d failed (%s)", req.ConversationID, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		return applied(map[string]any{
			"user_message_id": st.UserMessageID, "assistant_message_id": st.AssistantMessageID, "turn_id": st.TurnID,
		})
	})
}

// chatTurnRequest reads a chat_turn's params. The text cap (MaxChatText,
// counted in runes) is the hub's own, from the protocol (iPhone chat spec
// §4.5): the Mac has no such cap and the store does not check one.
func chatTurnRequest(r actions.Request) (chatstore.StartRequest, *actions.Outcome) {
	bad := func(msg string) (chatstore.StartRequest, *actions.Outcome) {
		o := failed(reasonInvalidParams, msg)
		return chatstore.StartRequest{}, &o
	}
	conv, ok := intParam(r, "conversation_id")
	if !ok || conv <= 0 {
		return bad("chat_turn needs a conversation_id")
	}
	mode, _ := stringParam(r, "mode")
	switch mode {
	case chatstore.ModeSend, chatstore.ModeRegenerate, chatstore.ModeEdit:
	default:
		return bad("mode must be send, regenerate or edit")
	}
	req := chatstore.StartRequest{ConversationID: conv, Mode: mode}
	if !isNull(r, "message_id") {
		if req.MessageID, ok = intParam(r, "message_id"); !ok {
			return bad("message_id must be a number")
		}
	}
	if !isNull(r, "text") {
		if req.Text, ok = stringParam(r, "text"); !ok {
			return bad("text must be a text")
		}
	}
	if utf8.RuneCountInString(req.Text) > MaxChatText {
		return bad(chatTextTooLongMessage)
	}
	if req.AttachmentIDs, ok = int64sParam(r, "attachment_ids"); !ok {
		return bad("attachment_ids must be a list of numbers")
	}
	if req.Routing, ok = chatRouting(r); !ok {
		return bad("routing must be {mode: auto} or {mode: pinned, provider, model?}")
	}
	return req, nil
}

// chatCancel is `chat_cancel` (params {conversation_id, turn_id}): a Stop
// of the turn, whoever runs it (the lease's cancel request: this hub's
// runner or the Mac honours it). {} once asked; not_found when no such turn
// runs.
func (h *Handlers) chatCancel(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_cancel", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		conv, okConv := intParam(r, "conversation_id")
		turn, okTurn := stringParam(r, "turn_id")
		if !okConv || !okTurn || turn == "" {
			return failed(reasonInvalidParams, "chat_cancel needs a conversation_id and a turn_id")
		}
		if c.Runner == nil {
			return failed(reasonNotSupported, chatOffMessages["runner_down"])
		}
		ok, err := c.Runner.Cancel(conv, turn)
		if err != nil {
			log.Printf("hub chat: stopping a turn of chat %d failed (%s)", conv, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		if !ok {
			return failed(reasonNotFound, chatTurnEndedMessage)
		}
		return applied(nil)
	})
}
