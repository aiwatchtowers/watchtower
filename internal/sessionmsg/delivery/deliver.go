// Package delivery is the daemon's agent-message deliverer (spec 2026-11-18
// §6.6, PROJ-23): it types each queued session_messages row into its
// receiving session through session-host's Deliver, behind the line gate
// the phone's lines use (sessionline), at most once, and never launches or
// resumes a session. It lives apart from sessionmsg because it speaks the
// hub's session port types, which the MCP tools that queue messages cannot
// import.
package delivery

import (
	"context"
	"errors"
	"sync"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/sessionhost"
	"watchtower/internal/sessionline"
	"watchtower/internal/sessionmsg"
	"watchtower/internal/sessionstart"
)

// TickInterval is how often the deliverer looks at the queue without a wake.
const TickInterval = 2 * time.Second

// HeldLifetime is how long a message (or failure line) may wait held before
// it fails; a finished line waits as long as its parent row exists.
const HeldLifetime = 24 * time.Hour

// submitSettle is the pause between the paste and its Return (the hub's).
const submitSettle = 500 * time.Millisecond

// holdPromptText is the host's hold reason for text in the prompt.
const holdPromptText = "prompt_has_text"

// Port is the deliverer's way into session-host (*sessionstart.Port). Runs
// is the host's list without ever starting a host (sessionstart.
// ErrHostNotRunning when none answers: nothing runs); Live and Deliver are
// called only for a session Runs lists, so a queue of messages to stopped
// sessions never starts one.
type Port interface {
	Runs(ctx context.Context) (map[int64]time.Time, error)
	Live(ctx context.Context, sessionID int64) (handlers.LiveRun, bool, error)
	Deliver(ctx context.Context, r handlers.DeliverRequest) (handlers.DeliverResult, error)
	PromptState(ctx context.Context, sessionID int64, run uint64) (holds, known bool, err error)
}

var _ Port = (*sessionstart.Port)(nil)

// Deliverer delivers session_messages. Exactly one runs, in the daemon (the
// sync lock's single instance). Every write is one autocommit statement;
// none spans a Deliver.
type Deliverer struct {
	DB    *db.DB
	Port  Port
	Clock func() time.Time
	Log   func(string, ...any)

	once      sync.Once
	wake      chan struct{}
	mu        sync.Mutex
	submitted map[int64]time.Time // session → its last submitted line
	lastHold  map[int64]string    // message → why it was last held
}

func (d *Deliverer) init() {
	d.once.Do(func() {
		d.wake = make(chan struct{}, 1)
		d.submitted = map[int64]time.Time{}
		d.lastHold = map[int64]string{}
	})
}

func (d *Deliverer) now() time.Time {
	if d.Clock != nil {
		return d.Clock()
	}
	return time.Now()
}

func (d *Deliverer) logf(format string, args ...any) {
	if d.Log != nil {
		d.Log("session messages: "+format, args...)
	}
}

// Wake asks for a tick now; it never blocks, and wakes that arrive during a
// tick collapse into one.
func (d *Deliverer) Wake() {
	d.init()
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

// Start fails every row left delivering by an earlier daemon (whether its
// paste landed is unknown: it is never retried, and its sender is told),
// then ticks every TickInterval and on each Wake until ctx is done; it
// returns nil (a failed read or write is logged and retried next tick).
func (d *Deliverer) Start(ctx context.Context) error {
	d.init()
	// A row left delivering is never claimed again (a claim takes only
	// queued rows), so a failed sweep is logged and the next start retries.
	failed, err := d.DB.FailInFlightSessionMessages(ctx, sessionmsg.ReasonUnknownAfterRestart)
	if err != nil {
		d.logf("%v", err)
	}
	for _, m := range failed {
		d.tellSender(ctx, m, sessionmsg.FailureLine(m.ToSessionID.Int64, sessionmsg.ReasonUnknownAfterRestart))
	}
	t := time.NewTicker(TickInterval)
	defer t.Stop()
	for {
		d.Tick(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		case <-d.wake:
		}
	}
}

// Tick delivers what may go of the queue, then clears the prompt flag of
// typed messages whose text left the prompt.
func (d *Deliverer) Tick(ctx context.Context) {
	d.init()
	if ctx.Err() != nil {
		return
	}
	runs, err := d.Port.Runs(ctx)
	if errors.Is(err, sessionstart.ErrHostNotRunning) {
		runs, err = map[int64]time.Time{}, nil
	}
	if err != nil {
		d.logf("reading the session host: %v", err)
		return
	}
	queued, err := d.DB.QueuedSessionMessages(ctx)
	if err != nil {
		d.logf("%v", err)
		return
	}
	for _, m := range queued {
		if ctx.Err() != nil {
			return
		}
		d.deliver(ctx, m, runs)
	}
	d.clearPromptFlags(ctx, runs)
}

// deliver is one queued row's turn: settled when its target is gone, not
// running or it waited too long; left queued while a finished line's parent
// does not run or the gate holds; else claimed and delivered.
func (d *Deliverer) deliver(ctx context.Context, m db.SessionMessage, runs map[int64]time.Time) {
	to := m.ToSessionID.Int64
	target, ok, err := sessionmsg.LoadSession(ctx, d.DB, to)
	if err != nil {
		d.logf("message %d: %v", m.ID, err)
		return
	}
	if !m.ToSessionID.Valid || !ok {
		d.fail(ctx, m, sessionmsg.ReasonNotFound, false)
		return
	}
	// Re-checked on every row, whoever queued it: only an agent session of
	// the row's own workbench is ever typed into.
	if !sessionmsg.IsPeer(target, m.WorkbenchID) {
		d.fail(ctx, m, sessionmsg.ReasonNotAPeer, false)
		return
	}
	if _, running := runs[to]; !running {
		d.notRunning(ctx, m, false)
		return
	}
	if m.Kind != sessionmsg.KindFinished && d.expired(m) {
		d.fail(ctx, m, d.expiryReason(m.ID), false)
		return
	}
	live, ok, err := d.Port.Live(ctx, to)
	if err != nil {
		d.logf("message %d: reading session %d: %v", m.ID, to, err)
		return
	}
	if !ok || live.Exited {
		d.notRunning(ctx, m, false)
		return
	}
	now := d.now()
	_, row, err := sessionline.Load(ctx, d.DB, target.ID, live.StartedAt, now)
	if err != nil {
		d.logf("message %d: reading session %d's state: %v", m.ID, to, err)
		return
	}
	hold, _ := sessionline.Gate(row, now)
	if hold == "" && sessionline.JustSubmitted(d.submittedAt(to), row, now) {
		hold = sessionline.HoldAgentBusy
	}
	if hold != "" {
		d.noteHold(m.ID, hold)
		return
	}
	claimed, err := d.DB.ClaimSessionMessage(ctx, m.ID)
	if err != nil || !claimed {
		if err != nil {
			d.logf("%v", err)
		}
		return
	}
	res, err := d.Port.Deliver(ctx, handlers.DeliverRequest{
		SessionID: to, Run: live.Run, Text: m.Text, KeepLineBreaks: true, HoldIfPromptText: true, Settle: submitSettle,
		Check: func(ctx context.Context) handlers.CheckAnswer {
			s, row, err := sessionline.Load(ctx, d.DB, to, live.StartedAt, d.now())
			fresh, canSubmit, answersDialog := sessionline.Vouch(row, s, err == nil)
			return handlers.CheckAnswer{Fresh: fresh, CanSubmit: canSubmit, AnswersDialog: answersDialog}
		},
	})
	d.settle(context.WithoutCancel(ctx), m, res, err)
}

// settle maps Deliver's outcome onto the claimed row (spec §6.6 "At most
// once"): only a host hold (nothing pasted) puts it back in the queue.
func (d *Deliverer) settle(ctx context.Context, m db.SessionMessage, res handlers.DeliverResult, err error) {
	to := m.ToSessionID.Int64
	if err != nil {
		d.logf("message %d: delivering into session %d: %v", m.ID, to, err)
		d.fail(ctx, m, sessionmsg.ReasonDeliveryUnknown, true)
		return
	}
	now := d.now()
	switch res.Outcome {
	case handlers.DeliverSubmitted:
		d.noteSubmit(to, now)
		d.done(m.ID)
		d.settleRow(ctx, m.ID, db.SessionMessageDelivered, "", now)
	case handlers.DeliverTyped:
		d.done(m.ID)
		d.settleRow(ctx, m.ID, db.SessionMessageDelivered, db.SessionMessageTypedNotSubmitted, now)
		if m.Kind == sessionmsg.KindMessage {
			d.tellSender(ctx, m, sessionmsg.TypedLine(to))
		}
	case handlers.DeliverHeld:
		reason := res.Reason
		if reason == "" {
			reason = holdPromptText
		}
		d.noteHold(m.ID, reason)
		if err := d.DB.RequeueSessionMessage(ctx, m.ID); err != nil {
			d.logf("%v", err)
		}
	case handlers.DeliverNoPasteMode:
		d.fail(ctx, m, sessionmsg.ReasonCannotType, true)
	default:
		if res.Reason == sessionhost.LostAfterPaste {
			// Pasted, then the run ended: it may have landed. Final, never
			// requeued (at most once); the sender is told.
			d.fail(ctx, m, sessionmsg.ReasonDeliveryUnknown, true)
			return
		}
		// no_session before any byte: the run ended or was replaced since Live.
		d.notRunning(ctx, m, true)
	}
}

// notRunning: a finished line waits for its parent's next run (back in the
// queue when claimed); any other row fails at once (delivery never launches
// or resumes a session).
func (d *Deliverer) notRunning(ctx context.Context, m db.SessionMessage, claimed bool) {
	if m.Kind == sessionmsg.KindFinished {
		if claimed {
			if err := d.DB.RequeueSessionMessage(ctx, m.ID); err != nil {
				d.logf("%v", err)
			}
		}
		return
	}
	d.fail(ctx, m, sessionmsg.ReasonNotRunning, claimed)
}

// fail settles m failed with reason — a row this tick claimed from
// delivering, any other only while it is still queued (never a row another
// tick has claimed) — and tells its sender, except for a finished line (its
// parent was deleted: dropped, logged), a failure line (no failure about a
// failure) and a row whose receiver is no peer (dropped, logged).
func (d *Deliverer) fail(ctx context.Context, m db.SessionMessage, reason string, claimed bool) {
	d.done(m.ID)
	if m.Kind == sessionmsg.KindFinished && reason == sessionmsg.ReasonNotFound {
		reason = sessionmsg.ReasonParentDeleted
	}
	var err error
	if claimed {
		err = d.DB.SettleSessionMessage(ctx, m.ID, db.SessionMessageFailed, reason, d.now())
	} else {
		err = d.DB.FailQueuedSessionMessage(ctx, m.ID, reason)
	}
	if err != nil {
		d.logf("%v", err)
		return
	}
	to := m.ToSessionID.Int64
	switch {
	case m.Kind != sessionmsg.KindMessage || reason == sessionmsg.ReasonNotAPeer:
		d.logf("%s message %d to session %d dropped: %s", m.Kind, m.ID, to, reason)
	case reason == sessionmsg.ReasonDeliveryUnknown:
		d.tellSender(ctx, m, sessionmsg.DeliveryUnknownLine(to))
	default:
		d.tellSender(ctx, m, sessionmsg.FailureLine(to, reason))
	}
}

// settleRow settles one row; false when it was not settled here.
func (d *Deliverer) settleRow(ctx context.Context, id int64, state, reason string, at time.Time) bool {
	if err := d.DB.SettleSessionMessage(ctx, id, state, reason, at); err != nil {
		d.logf("%v", err)
		return false
	}
	return true
}

// tellSender queues line to the sender of m (a failure row, delivered
// through the same path); a sender row that is gone is told nothing.
func (d *Deliverer) tellSender(ctx context.Context, m db.SessionMessage, line string) {
	if m.Kind != sessionmsg.KindMessage || !m.FromSessionID.Valid {
		return
	}
	if _, err := d.DB.InsertSessionMessage(ctx, db.SessionMessage{WorkbenchID: m.WorkbenchID,
		FromSessionID: m.ToSessionID, ToSessionID: m.FromSessionID, Kind: sessionmsg.KindFailure, Text: line}); err != nil {
		d.logf("telling session %d about message %d: %v", m.FromSessionID.Int64, m.ID, err)
	}
}

// expired: a held row older than HeldLifetime by the deliverer's clock. A
// created_at that does not parse never expires.
func (d *Deliverer) expired(m db.SessionMessage) bool {
	at, err := time.Parse(time.RFC3339, m.CreatedAt)
	return err == nil && d.now().Sub(at) > HeldLifetime
}

// expiryReason names why an expired row waited: text that stayed in the
// receiver's prompt, else plain expiry.
func (d *Deliverer) expiryReason(id int64) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.lastHold[id] == holdPromptText {
		return sessionmsg.ReasonPromptNotCleared
	}
	return sessionmsg.ReasonExpired
}

func (d *Deliverer) noteHold(id int64, reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.lastHold[id] = reason
}

func (d *Deliverer) done(id int64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.lastHold, id)
}

func (d *Deliverer) noteSubmit(sessionID int64, at time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.submitted[sessionID] = at
}

func (d *Deliverer) submittedAt(sessionID int64) time.Time {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.submitted[sessionID]
}

// clearPromptFlags sets prompt_cleared_at on every typed message whose text
// left the receiver's prompt: the session or its run is gone, a prompt was
// submitted after the paste (a UserPromptSubmit's `working` with no tool
// run), or the host reads the prompt empty. An unknown read keeps the flag.
func (d *Deliverer) clearPromptFlags(ctx context.Context, runs map[int64]time.Time) {
	rows, err := d.DB.UnclearedPromptMessages(ctx)
	if err != nil {
		d.logf("%v", err)
		return
	}
	for _, m := range rows {
		if ctx.Err() != nil {
			return
		}
		if d.promptCleared(ctx, m, runs) {
			if err := d.DB.ClearPromptFlag(ctx, m.ID, d.now()); err != nil {
				d.logf("%v", err)
			}
		}
	}
}

func (d *Deliverer) promptCleared(ctx context.Context, m db.SessionMessage, runs map[int64]time.Time) bool {
	to := m.ToSessionID.Int64
	target, ok, err := sessionmsg.LoadSession(ctx, d.DB, to)
	if err != nil {
		d.logf("message %d: %v", m.ID, err)
		return false
	}
	if !m.ToSessionID.Valid || !ok {
		return true
	}
	deliveredAt, err := time.Parse(time.RFC3339, m.DeliveredAt.String)
	if err != nil {
		return false
	}
	started, running := runs[to]
	// A run that started after the paste is not the one it was typed into:
	// that run ended.
	if !running || started.After(deliveredAt) {
		return true
	}
	if target.AgentState.String == "working" && !target.ToolRun && target.AgentStateAt.After(deliveredAt) {
		return true // a prompt was submitted after the paste
	}
	live, ok, err := d.Port.Live(ctx, to)
	if err != nil {
		d.logf("message %d: reading session %d: %v", m.ID, to, err)
		return false
	}
	if !ok || live.Exited {
		return true
	}
	pctx, cancel := context.WithTimeout(ctx, sessionhost.PromptStateTimeout)
	defer cancel()
	holds, known, err := d.Port.PromptState(pctx, to, live.Run)
	return err == nil && known && !holds
}
