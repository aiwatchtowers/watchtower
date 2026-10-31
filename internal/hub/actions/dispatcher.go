// Package actions is the Go hub's action lane (Go hub spec §8, relay client
// spec §5 hub half, relay sim rules 1–7a): it reads every linked phone's
// mailbox, applies each phone's actions strictly in action_seq order and
// exactly once, holds what arrives ahead of a gap and asks for it once per
// gap (resend_from), answers every action record it reads with an echo, and
// writes echoes and controls through the sidecar's durable control queue,
// never fire-and-forget. Handlers run outside any sidecar transaction.
package actions

import (
	"context"
	"fmt"
	"slices"
	"sync"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// Today's hub constants (the Swift RelayProcessor's), carried over verbatim.
const (
	// ActionMaxAge is how old an action may be when it is applied.
	ActionMaxAge = 7 * 24 * time.Hour
	// SessionRequestMaxAge is the shorter window of session requests and
	// automation runs (Swift sessionRequestKinds).
	SessionRequestMaxAge = 24 * time.Hour
	// MaxClockSkew is how far ahead of the hub's clock a phone's created_at
	// may be before the action counts as expired.
	MaxClockSkew = 300 * time.Second
	// BatchLimit is the most actions one pass applies or holds; the rest
	// waits for the next pass (repeats never count).
	BatchLimit = 200
	// MaxSkipAhead bounds a phone's skip_to(m): m may lie at most this far
	// past the next expected action_seq. A skip only gives up actions the
	// phone lost after a resend_from, never a jump across the counter.
	MaxSkipAhead = 1 << 16
)

// NonIdempotentKinds are claimed begun before their handler runs, so a hub
// that stops mid-apply answers outcome_unknown instead of applying twice.
var NonIdempotentKinds = []string{
	"board_comment_add", "board_comment_reply", "board_target_create", "session_start", "session_input",
	"session_finish_request", "permission_answer", "session_interrupt", "automation_run",
}

// ReceivedEchoKinds get a non-final received echo before their handler runs.
var ReceivedEchoKinds = []string{"session_start", "session_input", "board_target_create"}

// RefusedKinds are the pre-POC Today/task kinds: failed unsupported_in_poc,
// never dispatched, even with a handler registered.
var RefusedKinds = []string{"target_done", "target_snooze", "task_create"}

// sessionRequestKinds expire after SessionRequestMaxAge (Swift
// sessionRequestKinds).
var sessionRequestKinds = []string{
	"session_input", "session_finish_request", "session_start", "session_chat_request", "automation_run",
}

// Request is one action handed to a handler: the authenticated sender, this
// hub's id, the action's plain record name (a-<device>-<action_seq>, or a
// legacy action's action-<uuid>), the decoded payload and when the hub read
// it.
type Request struct {
	Device     secure.ID
	Hub        secure.ID
	RecordName string
	Action     wire.ActionRequest
	ReceivedAt time.Time
}

// Outcome is a handler's answer, echoed to the phone: Status is a wire
// status (applied, failed, expired, cancelled, or a non-final one a later
// echo replaces), Reason a wire reason (failed: the error class), Message
// the error message, Delivery how a line reached a session (echoed as
// result.delivery) and Result the rest of the echo's result.
type Outcome struct {
	Status                    string
	Reason, Message, Delivery string
	Result                    map[string]any
}

// Handler applies one action. It runs with the pass's context and never sees
// a sidecar transaction; it owns its own timeout.
type Handler func(ctx context.Context, r Request) Outcome

// KindOptions describe a kind: NonIdempotent claims it begun before the
// handler, ReceivedEcho echoes received before the handler, MaxAge is its
// window (0 = ActionMaxAge) and Nudges are what the runtime refreshes after
// an applied action (Config.Nudge).
type KindOptions struct {
	NonIdempotent, ReceivedEcho bool
	MaxAge                      time.Duration
	Nudges                      []string
}

type registration struct {
	handler Handler
	opts    KindOptions
}

// Dispatcher maps action kinds to handlers; safe for concurrent use.
type Dispatcher struct {
	mu    sync.RWMutex
	kinds map[string]registration
}

// NewDispatcher returns an empty dispatcher: every kind is unsupported until
// registered.
func NewDispatcher() *Dispatcher { return &Dispatcher{kinds: map[string]registration{}} }

// Register adds kind's handler. The canonical lists win over o: a kind in
// NonIdempotentKinds is always claimed, one in ReceivedEchoKinds always gets
// its received echo, and a session request never gets more than
// SessionRequestMaxAge. A duplicate kind, an empty kind or a nil handler
// panics (a wiring bug).
func (d *Dispatcher) Register(kind string, h Handler, o KindOptions) {
	if kind == "" || h == nil {
		panic("actions: Register needs a kind and a handler")
	}
	if slices.Contains(NonIdempotentKinds, kind) {
		o.NonIdempotent = true
	}
	if slices.Contains(ReceivedEchoKinds, kind) {
		o.ReceivedEcho = true
	}
	if slices.Contains(sessionRequestKinds, kind) && (o.MaxAge <= 0 || o.MaxAge > SessionRequestMaxAge) {
		o.MaxAge = SessionRequestMaxAge
	}
	if o.MaxAge <= 0 {
		o.MaxAge = ActionMaxAge
	}
	o.Nudges = slices.Clone(o.Nudges)
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, dup := d.kinds[kind]; dup {
		panic(fmt.Sprintf("actions: kind %q registered twice", kind))
	}
	d.kinds[kind] = registration{handler: h, opts: o}
}

// lookup is kind's registration; ok is false for an unregistered kind.
func (d *Dispatcher) lookup(kind string) (registration, bool) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	r, ok := d.kinds[kind]
	return r, ok
}
