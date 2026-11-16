package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"runtime/debug"
	"time"

	"watchtower/internal/chatengine"
	"watchtower/internal/chatstore"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
	"watchtower/internal/tools"
)

// The AI chat from the phone (iPhone chat spec §4.5). Every chat_* kind
// needs the device's chat grant; chat_action_answer also needs its
// permissions grant. While the hub's chat is off (not on the relay, no chat
// runner, an old Desktop app running, the organization's policy) every one
// is refused not_supported, so a stale phone never runs a turn over iCloud.

// Wire reasons of the chat kinds (the Kit's ChatActionReason).
const (
	reasonConversationBusy  = "conversation_busy"
	reasonAttachmentMissing = "attachment_missing"
	reasonChanged           = "changed"
)

// MaxChatText is the most characters (runes) a chat_turn's text may carry.
const MaxChatText = 32000

// MaxChatSearchQuery is the most characters a chat_search query may carry.
const MaxChatSearchQuery = 200

const (
	chatNotAllowedLead      = "This phone is not allowed to use chat"
	chatPermissionsLead     = "This phone is not allowed to answer the chat's actions"
	aiChatTimeoutMessage    = "Your Mac did not answer in time — check the chat there"
	chatGoneMessage         = "This chat no longer exists on your Mac"
	chatMessageGoneMessage  = "This message no longer exists on your Mac"
	chatBusyMessage         = "This chat is already answering. Wait for it or stop it."
	chatAttachmentGone      = "A file of this message is no longer on your Mac. Attach it again."
	chatChangedMessage      = "The action changed — look again"
	chatActionGoneMessage   = "This action no longer exists on your Mac"
	chatTurnEndedMessage    = "This answer has already ended"
	chatTextTooLongMessage  = "This message is over 32,000 characters"
	chatHubStoppingMessage  = "Your Mac is stopping chat right now — try again in a moment"
	chatWriteFailedMessage  = "Your Mac could not save this"
	chatUnavailableFallback = "This Mac can't run chat"
)

// chatOffMessages are the not_supported messages, by the capability's off
// reason (wire.ChatOff*).
var chatOffMessages = map[string]string{
	wire.ChatOffNotRelay:      "Chat works over Relay. Switch this Mac to Relay to chat.",
	wire.ChatOffRunnerDown:    "Chat can't run on your Mac right now",
	wire.ChatOffDesktopTooOld: "Update Watchtower on your Mac",
	wire.ChatOffPolicy:        "Chat is turned off by your organization",
}

// ChatRunner runs chat turns (chatengine.Engine).
type ChatRunner interface {
	// Turn starts a turn and returns once its start transaction committed.
	Turn(ctx context.Context, req chatengine.TurnRequest) (chatstore.Started, error)
	// Cancel asks the turn's lease holder (this hub or the Mac) to stop.
	Cancel(conv int64, turnID string) (bool, error)
}

// ChatRequests is the hub's register of what the phone asked of the chat
// (sources.ChatWatches, behind the wiring: handlers cannot import sources).
// at is when the phone asked; the register adds the request's length.
type ChatRequests interface {
	WatchFeed(conv int64, purpose string, at time.Time)
	RequestPage(conv, before int64, at time.Time)
	RequestSearch(query string, at time.Time)
}

// ChatDeps is the AI chat's side of the hub. Available says whether chat is
// on (the heartbeat's capabilities.chat) and why not; Runner (nil = none,
// Available is then off) runs the turns; Store writes conversations; Tools
// approves the chat's actions and runs the ones no session runs (nil = a
// registry with no tools); FilesDir is <workspace>/chat_files.
type ChatDeps struct {
	Available func() (on bool, reason string)
	Runner    ChatRunner
	Store     *chatstore.Store
	Requests  ChatRequests
	Tools     *tools.Registry
	FilesDir  string
	// Spawn runs work after an answer on the hub's tracked background
	// (the hub's stop waits for it, bounded); false = the hub is stopping
	// and work did not start. nil = the handlers' own tracking (WaitChat).
	Spawn func(work func()) bool
}

// chatKinds are the chat action kinds and their handlers.
func (h *Handlers) chatKinds() map[string]actions.Handler {
	return map[string]actions.Handler{
		"chat_new":           h.chatNew,
		"chat_turn":          h.chatTurn,
		"chat_cancel":        h.chatCancel,
		"chat_feed_request":  h.chatFeedRequest,
		"chat_page":          h.chatPage,
		"chat_search":        h.chatSearch,
		"chat_read":          h.chatRead,
		"chat_branch_select": h.chatBranchSelect,
		"chat_manage":        h.chatManage,
		"chat_action_answer": h.chatActionAnswer,
	}
}

// chatGate is every chat kind's first check: chat on, then the device's chat
// grant (and, with permissions, its permissions grant). A refusal is the
// outcome to answer.
func (h *Handlers) chatGate(device secure.ID, permissions bool) (*ChatDeps, *actions.Outcome) {
	c := h.d.Chat
	if c == nil || c.Available == nil {
		o := failed(reasonNotSupported, chatOffMessages[wire.ChatOffPolicy])
		return nil, &o
	}
	if on, reason := c.Available(); !on {
		msg, ok := chatOffMessages[reason]
		if !ok {
			msg = chatUnavailableFallback
		}
		o := failed(reasonNotSupported, msg)
		return nil, &o
	}
	d, linked, err := h.d.Store.Device(device.String())
	if err != nil {
		o := failed(reasonWriteFailed, chatWriteFailedMessage)
		return nil, &o
	}
	if !linked || !d.ChatAllowed {
		o := failed(reasonDeviceNotAllowed, h.chatAllowStep(chatNotAllowedLead, device, "chat"))
		return nil, &o
	}
	if permissions && !d.PermissionsAllowed {
		o := failed(reasonDeviceNotAllowed, h.chatAllowStep(chatPermissionsLead, device, "permissions"))
		return nil, &o
	}
	return c, nil
}

// chatAllowStep is a chat grant refusal: the Mac app's Settings → Mobile on
// a Mac hub, the `watchtower hub allow` line on a server hub.
func (h *Handlers) chatAllowStep(lead string, device secure.ID, grant string) string {
	if !h.d.ServerHost {
		return lead + macTypingAllowStep
	}
	return lead + serverAllowSteps(device, grant)
}

// chatAction runs a chat kind behind its gate with the handlers' deadline.
func (h *Handlers) chatAction(ctx context.Context, name string, r actions.Request, permissions bool,
	work func(context.Context, *ChatDeps) actions.Outcome,
) actions.Outcome {
	return h.withTimeout(ctx, name, aiChatTimeoutMessage, func(ctx context.Context) actions.Outcome {
		c, refused := h.chatGate(r.Device, permissions)
		if refused != nil {
			return *refused
		}
		return work(ctx, c)
	})
}

// chatAsync runs work after the action's answer (an approved action's
// apply): never cut by the pass, and tracked by the hub (ChatDeps.Spawn), so
// a stop waits for it rather than close the database under it; a panic is
// logged and contained. False: the hub is stopping and work did not start.
func (h *Handlers) chatAsync(name string, work func(context.Context)) bool {
	run := func() {
		defer func() {
			if p := recover(); p != nil {
				// The value's type and the stack, never the value (FILES-01:
				// it may carry content). The registry has no path that fails
				// a claimed row from outside it, so an apply that panicked
				// mid-run leaves its row `executing` for `watchtower actions
				// apply --force`.
				log.Printf("hub handlers: %s panicked (%T)\n%s", name, p, debug.Stack())
			}
		}()
		work(context.Background())
	}
	h.chatWG.Add(1)
	if c := h.d.Chat; c != nil && c.Spawn != nil {
		ok := c.Spawn(func() { defer h.chatWG.Done(); run() })
		if !ok {
			h.chatWG.Done()
		}
		return ok
	}
	go func() {
		defer h.chatWG.Done()
		run()
	}()
	return true
}

// WaitChat waits for the chat work started after an answer (tests).
func (h *Handlers) WaitChat() { h.chatWG.Wait() }

// askedAt is when the phone asked: the action's created_at, never later
// than now (a phone clock ahead of the hub's counts from now).
func (h *Handlers) askedAt(r actions.Request) time.Time {
	now := h.d.Clock()
	if at := r.Action.CreatedAt.Time; !at.IsZero() && at.Before(now) {
		return at
	}
	return now
}

// int64sParam is params[name] when it is a JSON array of integers (missing
// or null = none).
func int64sParam(r actions.Request, name string) ([]int64, bool) {
	if isNull(r, name) {
		return nil, true
	}
	var v []int64
	if err := json.Unmarshal(r.Action.Params[name], &v); err != nil {
		return nil, false
	}
	return v, true
}

// chatRouting is params.routing: {mode auto|pinned, provider?, model?};
// nil when absent.
func chatRouting(r actions.Request) (*chatstore.Routing, bool) {
	if isNull(r, "routing") {
		return nil, true
	}
	var v struct {
		Mode     string `json:"mode"`
		Provider string `json:"provider"`
		Model    string `json:"model"`
	}
	if err := json.Unmarshal(r.Action.Params["routing"], &v); err != nil {
		return nil, false
	}
	switch v.Mode {
	case "auto":
		return &chatstore.Routing{Automatic: true}, true
	case "pinned":
		if v.Provider == "" {
			return nil, false
		}
		return &chatstore.Routing{Provider: v.Provider, Model: v.Model}, true
	}
	return nil, false
}

// errClass is a log line's error class: never an error's text (FILES-01).
func errClass(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, chatstore.ErrConversationGone):
		return "conversation_gone"
	}
	return "error"
}
