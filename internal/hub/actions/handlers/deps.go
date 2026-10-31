// Package handlers holds the Go hub's action handlers (Go hub spec §8 p. 4):
// the Swift MobileHubCommandDispatcher table moved to Go with the same
// request and outcome payloads. Each handler owns its timeout and never sees
// a sidecar transaction; lines typed into a session go through SessionPort.
package handlers

import (
	"context"
	"encoding/json"
	"log"
	"strconv"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// Wire reasons the handlers answer with (the Kit's ActionReason).
const (
	reasonNotFound         = "not_found"
	reasonNotOnBoard       = "not_on_board"
	reasonAskNotOpen       = "ask_not_open"
	reasonInvalidAnswer    = "invalid_answer"
	reasonInvalidParams    = "invalid_params"
	reasonConflict         = "conflict"
	reasonDeviceNotAllowed = "device_not_allowed"
	reasonCannotType       = "cannot_type"
	reasonOutcomeUnknown   = "outcome_unknown"
	reasonWriteFailed      = "write_failed"
)

// DefaultTimeout is every handler's own deadline (Swift HandlerTimeout's 30 s):
// ample for a write waiting on the database lock or a delivery's pause.
const DefaultTimeout = 30 * time.Second

// submitSettle is the pause between a line's paste and its Return (both agent
// profiles, PROJ-12).
const submitSettle = 500 * time.Millisecond

// CannotTypeMessage is a no_paste_mode line's echo on a host without a fresh
// Desktop heartbeat (spec §8 p. 4b).
const CannotTypeMessage = "This session can't take typed text right now"

// Deps is what the handlers run against. DesktopHost reports a fresh Desktop
// heartbeat (Task 5); Clipboard (pbcopy) is used only while it does.
// WakeAutomations, when set, wakes the automation executor after a run is
// queued or an automation's ask is answered (best effort: its next tick
// picks the work up anyway). Timeout 0 is DefaultTimeout; Clock nil is
// time.Now.
type Deps struct {
	DB              *db.DB
	Store           *state.Store
	Sessions        SessionPort
	DesktopHost     func() bool
	Clipboard       func(string) error
	RecordingsDir   string
	Clock           func() time.Time
	Policy          func() string
	WakeAutomations func()
	Timeout         time.Duration
}

// Handlers is the registered handler set: its in-memory state (asks being
// answered, answers held for their session) lives as long as the hub.
type Handlers struct {
	d Deps

	mu        sync.Mutex
	answering map[int64]bool
	held      []heldAnswer
}

// Register adds every handler kind of this plan to d and returns the set;
// the runtime calls DeliverHeld on it after each read of the session states.
// Every kind registered here has a NudgeTable entry.
func Register(d *actions.Dispatcher, deps Deps) *Handlers {
	if deps.Clock == nil {
		deps.Clock = time.Now
	}
	if deps.Timeout <= 0 {
		deps.Timeout = DefaultTimeout
	}
	if deps.DesktopHost == nil {
		deps.DesktopHost = func() bool { return false }
	}
	h := &Handlers{d: deps, answering: map[int64]bool{}}
	h.loadHeld()
	reg := func(kind string, fn actions.Handler) {
		if len(NudgeTable[kind]) == 0 {
			panic("handlers: " + kind + " has no NudgeTable entry")
		}
		d.Register(kind, fn, actions.KindOptions{Nudges: nudgeNames(kind)})
	}
	reg("ask_answer", h.askAnswer)
	for _, k := range boardKinds {
		reg(k, h.board)
	}
	reg("automation_run", h.automationRun)
	return h
}

func nudgeNames(kind string) []string {
	out := make([]string, 0, len(NudgeTable[kind]))
	for _, k := range NudgeTable[kind] {
		out = append(out, string(k))
	}
	return out
}

// withTimeout runs work in its own goroutine on a context the pass cannot
// cancel, and answers its outcome, or outcome_unknown with msg once the
// handler's deadline (or the pass) ends first. The work then runs to its end
// with its outcome dropped: it is never cut mid-write, so the phone is told
// to check on the Mac. name is a fixed label for the log, never
// payload-derived.
func (h *Handlers) withTimeout(ctx context.Context, name, msg string, work func(context.Context) actions.Outcome) actions.Outcome {
	done := make(chan actions.Outcome, 1)
	go func() {
		defer func() {
			if p := recover(); p != nil {
				log.Printf("hub handlers: %s panicked", name)
				done <- failed(reasonWriteFailed, "The Mac hit an internal error applying this")
			}
		}()
		done <- work(context.WithoutCancel(ctx))
	}()
	t := time.NewTimer(h.d.Timeout)
	defer t.Stop()
	select {
	case o := <-done:
		return o
	case <-t.C:
	case <-ctx.Done():
	}
	return failed(reasonOutcomeUnknown, msg)
}

func failed(reason, message string) actions.Outcome {
	return actions.Outcome{Status: wire.StatusFailed, Reason: reason, Message: message}
}

func applied(result map[string]any) actions.Outcome {
	return actions.Outcome{Status: wire.StatusApplied, Result: result}
}

// refusal is a failed outcome raised inside a check or a transaction (rolling
// it back).
type refusal struct{ reason, message string }

func (r *refusal) Error() string { return r.reason + ": " + r.message }

func invalid(message string) *refusal { return &refusal{reasonInvalidParams, message} }

// entityID is the action's entity as an id; ok is false when it is missing or
// not a decimal integer.
func entityID(r actions.Request) (int64, bool) {
	if r.Action.EntityID == nil {
		return 0, false
	}
	id, err := strconv.ParseInt(*r.Action.EntityID, 10, 64)
	return id, err == nil
}

// intParam is params[name] when it is a JSON integer.
func intParam(r actions.Request, name string) (int64, bool) {
	raw, ok := r.Action.Params[name]
	if !ok {
		return 0, false
	}
	var v int64
	if err := json.Unmarshal(raw, &v); err != nil {
		return 0, false
	}
	return v, true
}

// stringParam is params[name] when it is a JSON string.
func stringParam(r actions.Request, name string) (string, bool) {
	raw, ok := r.Action.Params[name]
	if !ok {
		return "", false
	}
	var v string
	if err := json.Unmarshal(raw, &v); err != nil {
		return "", false
	}
	return v, true
}

// isNull reports whether params[name] is missing or JSON null.
func isNull(r actions.Request, name string) bool {
	raw, ok := r.Action.Params[name]
	return !ok || string(raw) == "null"
}

// wake asks the automation executor to look now, when the hub can.
func (h *Handlers) wake() {
	if h.d.WakeAutomations != nil {
		h.d.WakeAutomations()
	}
}
