package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"unicode/utf8"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions"
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
		id, err := c.Engine.NewConversation(ctx, project, routing)
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

// chatTurn is `chat_turn` (params as chat.sock's chat_turn, read by
// chatengine.DecodeTurn: {conversation_id, mode, message_id?, text,
// attachment_ids, routing?, client_key?, compose?, …}):
// a turn the daemon's engine runs (chatengine.Engine). client_key is the
// phone's id of the send: a resend under a new action id with the same key
// is answered with the first turn, never a second one (the engine's
// chat_messages.client_key). compose is the composer's skill and mentions,
// as the Mac sends them on chat.sock. Non-idempotent with a received echo: the answer waits
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
		st, err := c.Engine.Turn(ctx, req)
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
			return failed(reasonInvalidParams, chatTurnInvalidMessage)
		case errors.Is(err, chatengine.ErrClosed):
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

// chatTurnRequest reads a chat_turn's params with the engine's own decoder
// (chatengine.DecodeTurn, the one chat.sock uses), so every field the engine
// knows reaches it from the phone too. Only the text cap (MaxChatText,
// counted in runes) is the hub's own, from the protocol (iPhone chat spec
// §4.5): the Mac has no such cap and the store does not check one.
func chatTurnRequest(r actions.Request) (chatengine.TurnRequest, *actions.Outcome) {
	bad := func(msg string) (chatengine.TurnRequest, *actions.Outcome) {
		o := failed(reasonInvalidParams, msg)
		return chatengine.TurnRequest{}, &o
	}
	params, err := json.Marshal(r.Action.Params)
	if err != nil {
		return bad(chatTurnInvalidMessage)
	}
	req, err := chatengine.DecodeTurn(params)
	if err != nil {
		return bad(chatTurnInvalidMessage)
	}
	if utf8.RuneCountInString(req.Text) > MaxChatText {
		return bad(chatTextTooLongMessage)
	}
	return req, nil
}

// chatCancel is `chat_cancel` (params {conversation_id, turn_id}): a Stop
// of the turn (the engine's cancel request). {} once asked; not_found when
// no such turn runs.
func (h *Handlers) chatCancel(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_cancel", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		conv, okConv := intParam(r, "conversation_id")
		turn, okTurn := stringParam(r, "turn_id")
		if !okConv || !okTurn || turn == "" {
			return failed(reasonInvalidParams, "chat_cancel needs a conversation_id and a turn_id")
		}
		ok, err := c.Engine.Cancel(conv, turn)
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
