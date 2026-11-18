package handlers

import (
	"context"
	"errors"
	"log"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions"
)

// chatRead is `chat_read` (params {conversation_id, message_id}): the Mac's
// markRead, bounded to what the phone showed (read_at never goes back).
func (h *Handlers) chatRead(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_read", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		conv, okConv := intParam(r, "conversation_id")
		msg, okMsg := intParam(r, "message_id")
		if !okConv || !okMsg || conv <= 0 {
			return failed(reasonInvalidParams, "chat_read needs a conversation_id and a message_id")
		}
		if refused := h.chatExists(ctx, c, conv); refused != nil {
			return *refused
		}
		if err := c.Engine.MarkRead(ctx, conv, msg); err != nil {
			log.Printf("hub chat: marking chat %d read failed (%s)", conv, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		return applied(nil)
	})
}

// chatBranchSelect is `chat_branch_select` (params {message_id}): the
// conversation shows that message's branch (its newest leaf). Never refused
// during a turn (D17): a turn writes its rows by message id.
func (h *Handlers) chatBranchSelect(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_branch_select", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		msg, ok := intParam(r, "message_id")
		if !ok || msg <= 0 {
			return failed(reasonInvalidParams, "chat_branch_select needs a message_id")
		}
		err := c.Engine.SelectBranch(ctx, msg)
		switch {
		case errors.Is(err, chatstore.ErrNotFound):
			return failed(reasonNotFound, chatMessageGoneMessage)
		case err != nil:
			log.Printf("hub chat: selecting a branch failed (%s)", errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		return applied(nil)
	})
}

// chatManage is `chat_manage` (params {conversation_id, op pin|unpin|rename|
// delete|use_preferred, title?}): what the Mac's Chats panel writes, and the
// fallback card's "Use preferred" (refused conversation_busy while a turn
// runs). rename sets
// title_source 'user'. delete (the engine's) removes the row (its messages,
// files' rows and lease go with it), stops its running turn and then, after
// the commit, the conversation's attachment folder, as the Mac's ✕ does. The
// phone's 5 s Undo is the phone's: it sends delete once the Undo bar ends.
// Non-idempotent.
func (h *Handlers) chatManage(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_manage", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		conv, okConv := intParam(r, "conversation_id")
		op, okOp := stringParam(r, "op")
		if !okConv || !okOp || conv <= 0 {
			return failed(reasonInvalidParams, "chat_manage needs a conversation_id and an op")
		}
		req := chatengine.ManageRequest{Conversation: conv, Op: op}
		switch op {
		case chatengine.ManagePin, chatengine.ManageUnpin, chatengine.ManageDelete, chatengine.ManageUsePreferred:
		case chatengine.ManageRename:
			title, ok := stringParam(r, "title")
			if !ok {
				return failed(reasonInvalidParams, "rename needs a title")
			}
			req.Title = title
		default:
			return failed(reasonInvalidParams, "op must be pin, unpin, rename, delete or use_preferred")
		}
		err := c.Engine.Manage(ctx, req)
		switch {
		case errors.Is(err, chatstore.ErrConversationGone):
			return failed(reasonNotFound, chatGoneMessage)
		case errors.Is(err, chatstore.ErrBusy):
			return failed(reasonConversationBusy, chatBusyMessage)
		case errors.Is(err, chatstore.ErrInvalid):
			return failed(reasonInvalidParams, "A chat's name can't be empty")
		case err != nil:
			log.Printf("hub chat: %s of chat %d failed (%s)", op, conv, errClass(err))
			return failed(reasonWriteFailed, chatWriteFailedMessage)
		}
		return applied(nil)
	})
}
