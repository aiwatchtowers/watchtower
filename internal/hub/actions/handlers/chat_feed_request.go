package handlers

import (
	"context"
	"log"
	"strings"
	"unicode/utf8"

	"watchtower/internal/hub/actions"
)

// The chat requests (iPhone chat spec §4.5–§4.6): the phone asks, the hub
// publishes. Idempotent: a repeat only extends the watch or rebuilds the
// record. The register (ChatRequests) counts each one from when the phone
// asked.

// chatFeedRequest is `chat_feed_request` (params {conversation_id, purpose
// open|prefetch}; a missing purpose is open): an open request watches the
// conversation's feed for 5 minutes (the phone repeats it every 60 s while
// the screen is open); a prefetch publishes it once and holds the record 2
// minutes, never counting as the phone looking. conversation_id 0 is the
// chat list's Retry: nothing is watched, the applied answer's nudge
// publishes chat_list now. not_found for a chat that is not there.
func (h *Handlers) chatFeedRequest(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_feed_request", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		conv, ok := intParam(r, "conversation_id")
		if !ok || conv < 0 {
			return failed(reasonInvalidParams, "chat_feed_request needs a conversation_id")
		}
		purpose := "open"
		if !isNull(r, "purpose") {
			if purpose, ok = stringParam(r, "purpose"); !ok || (purpose != "open" && purpose != "prefetch") {
				return failed(reasonInvalidParams, "purpose must be open or prefetch")
			}
		}
		if conv == 0 {
			return applied(nil)
		}
		if refused := h.chatExists(ctx, c, conv); refused != nil {
			return *refused
		}
		c.Requests.WatchFeed(conv, purpose, h.askedAt(r))
		return applied(nil)
	})
}

// chatPage is `chat_page` (params {conversation_id, before_message_id}): one
// chat_page record of the 60 active-branch messages before that message,
// held 5 minutes.
func (h *Handlers) chatPage(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_page", r, false, func(ctx context.Context, c *ChatDeps) actions.Outcome {
		conv, okConv := intParam(r, "conversation_id")
		before, okBefore := intParam(r, "before_message_id")
		if !okConv || !okBefore || conv <= 0 || before <= 0 {
			return failed(reasonInvalidParams, "chat_page needs a conversation_id and a before_message_id")
		}
		if refused := h.chatExists(ctx, c, conv); refused != nil {
			return *refused
		}
		c.Requests.RequestPage(conv, before, h.askedAt(r))
		return applied(nil)
	})
}

// chatSearch is `chat_search` (params {query}, at most 200 characters): one
// chat_search record of the Mac's ⌘K search, held 5 minutes, named by the
// query as the phone sent it.
func (h *Handlers) chatSearch(ctx context.Context, r actions.Request) actions.Outcome {
	return h.chatAction(ctx, "chat_search", r, false, func(_ context.Context, c *ChatDeps) actions.Outcome {
		q, ok := stringParam(r, "query")
		if !ok || strings.TrimSpace(q) == "" {
			return failed(reasonInvalidParams, "chat_search needs a query")
		}
		if utf8.RuneCountInString(q) > MaxChatSearchQuery {
			return failed(reasonInvalidParams, "The search is over 200 characters")
		}
		c.Requests.RequestSearch(q, h.askedAt(r))
		return applied(nil)
	})
}

// chatExists refuses not_found for a chat that is not there.
func (h *Handlers) chatExists(ctx context.Context, c *ChatDeps, conv int64) *actions.Outcome {
	ok, err := c.Store.ConversationExists(ctx, conv)
	if err != nil {
		log.Printf("hub chat: reading chat %d failed (%s)", conv, errClass(err))
		o := failed(reasonWriteFailed, chatWriteFailedMessage)
		return &o
	}
	if !ok {
		o := failed(reasonNotFound, chatGoneMessage)
		return &o
	}
	return nil
}
