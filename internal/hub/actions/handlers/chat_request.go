package handlers

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"watchtower/internal/hub/actions"
)

// ChatWatchLength is how long one session_chat_request keeps a chat watched
// (SessionChatRunner.Timing.watch, FEED-05): the phone repeats the request
// every minute while its Chat screen is open.
const ChatWatchLength = 5 * time.Minute

const (
	chatTimeoutMessage = "The Mac did not answer in time — check the chat on the Mac"
	chatUnknownSession = "unknown_session"
	// requestTimeout is the request handlers' own deadline (one DB read).
	requestTimeout = 10 * time.Second
)

// SessionWindows answers whether a session is in a runner-fed slice's
// window; the terminal_session source implements it (one truth for what
// the phone sees). Published: an agent session of a published workbench
// (TerminalSessionSlice.publishedSessions, the session_chat window).
// InReportWindow: a published session that is live or was active in the
// last 7 days (SessionReportSlice.window).
type SessionWindows interface {
	Published(ctx context.Context, sessionID int64) (bool, error)
	InReportWindow(ctx context.Context, sessionID int64) (bool, error)
}

// ChatWatch is one watched chat: the session's own (AgentID and ToolUseID
// empty) or one subagent's (both set), watched until Expires.
type ChatWatch struct {
	SessionID          int64
	AgentID, ToolUseID string
	Expires            time.Time
}

// ChatWatches is the in-memory registry of the chats the phone asked for
// (FEED-05): session_chat_request opens or extends a watch, the session_chat
// source (Task 8) publishes only the watched chats and drops a payload whose
// watch ended. Nothing in it is ever written to disk.
type ChatWatches interface {
	// Watch opens or extends the watch of w's chat until w.Expires; a repeat
	// never shortens a watch a newer request already holds.
	Watch(w ChatWatch)
	// Active is every watch still open at now (expired ones are dropped).
	Active(now time.Time) []ChatWatch
	// DropAll forgets every watch (no phone is linked any more).
	DropAll()
}

type chatKey struct {
	session          int64
	agent, toolUseID string
}

// ChatWatchRegistry is the hub's ChatWatches.
type ChatWatchRegistry struct {
	mu      sync.Mutex
	watches map[chatKey]time.Time
}

// NewChatWatchRegistry is an empty registry.
func NewChatWatchRegistry() *ChatWatchRegistry {
	return &ChatWatchRegistry{watches: map[chatKey]time.Time{}}
}

// Watch implements ChatWatches.
func (r *ChatWatchRegistry) Watch(w ChatWatch) {
	r.mu.Lock()
	defer r.mu.Unlock()
	k := chatKey{w.SessionID, w.AgentID, w.ToolUseID}
	if cur, ok := r.watches[k]; !ok || w.Expires.After(cur) {
		r.watches[k] = w.Expires
	}
}

// Active implements ChatWatches.
func (r *ChatWatchRegistry) Active(now time.Time) []ChatWatch {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]ChatWatch, 0, len(r.watches))
	for k, exp := range r.watches {
		if !exp.After(now) {
			delete(r.watches, k)
			continue
		}
		out = append(out, ChatWatch{SessionID: k.session, AgentID: k.agent, ToolUseID: k.toolUseID, Expires: exp})
	}
	return out
}

// DropAll implements ChatWatches.
func (r *ChatWatchRegistry) DropAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	clear(r.watches)
}

// sessionChatRequest is `session_chat_request` (entity the session id,
// params {session_id?, subagent_id?, tool_use_id?}: the subagent's two ids
// come together or not at all; session_id, when sent, must be the entity).
// Opens or extends the 5-minute watch of the session's chat (or one
// subagent's), counted from when the phone asked: a request older than the
// watch applies without one. Idempotent: a re-run only extends the watch.
// Needs no grant: reading is what the phone's link already allows. A session
// outside the published window fails not_found with the message
// unknown_session. The result is {}; the chat reaches the phone through the
// session_chat slice.
func (h *Handlers) sessionChatRequest(ctx context.Context, r actions.Request) actions.Outcome {
	return h.withRequestTimeout(ctx, "session_chat_request", chatTimeoutMessage, func(ctx context.Context) actions.Outcome {
		return h.applySessionChatRequest(ctx, r)
	})
}

func (h *Handlers) applySessionChatRequest(ctx context.Context, r actions.Request) actions.Outcome {
	sessionID, ok := entityID(r)
	if !ok {
		return failed(reasonInvalidParams, "session_chat_request needs a session id")
	}
	if !isNull(r, "session_id") {
		if v, ok := intParam(r, "session_id"); !ok || v != sessionID {
			return failed(reasonInvalidParams, "session_id does not match the session")
		}
	}
	agentID, ok := optionalText(r, "subagent_id")
	if !ok {
		return failed(reasonInvalidParams, "subagent_id must be a text")
	}
	toolUseID, ok := optionalText(r, "tool_use_id")
	if !ok {
		return failed(reasonInvalidParams, "tool_use_id must be a text")
	}
	if (agentID == "") != (toolUseID == "") {
		return failed(reasonInvalidParams, "subagent_id and tool_use_id come together")
	}
	known := false
	if h.d.Windows != nil {
		var err error
		if known, err = h.d.Windows.Published(ctx, sessionID); err != nil {
			return failed(reasonWriteFailed, err.Error())
		}
	}
	if !known {
		return failed(reasonNotFound, chatUnknownSession)
	}
	// The watch counts from when the phone asked, not from when the relay
	// got to the record. A phone clock ahead of the Mac (negative age) still
	// gets a full watch; a request older than the watch opens none.
	now := h.d.Clock()
	age := now.Sub(r.Action.CreatedAt.Time)
	if age >= ChatWatchLength || h.d.ChatWatches == nil {
		return applied(nil)
	}
	remaining := min(ChatWatchLength, ChatWatchLength-age)
	h.d.ChatWatches.Watch(ChatWatch{SessionID: sessionID, AgentID: agentID, ToolUseID: toolUseID, Expires: now.Add(remaining)})
	return applied(nil)
}

// optionalText is params[name] as a non-empty text, "" when missing or null;
// ok is false for any other value.
func optionalText(r actions.Request, name string) (string, bool) {
	if isNull(r, name) {
		return "", true
	}
	var v string
	if err := json.Unmarshal(r.Action.Params[name], &v); err != nil || v == "" {
		return "", false
	}
	return v, true
}

// withRequestTimeout is withTimeout with the request handlers' shorter
// deadline (10 s, or the Deps' Timeout when a test set a shorter one).
func (h *Handlers) withRequestTimeout(ctx context.Context, name, msg string, work func(context.Context) actions.Outcome) actions.Outcome {
	ctx, cancel := context.WithTimeout(ctx, min(requestTimeout, h.d.Timeout))
	defer cancel()
	return h.withTimeout(ctx, name, msg, work)
}
