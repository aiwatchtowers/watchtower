package builtin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Gate decides, before any run row exists, whether a built-in's sync run is
// due now (the daemon's hour gates, attempt budgets and freshness rules).
type Gate interface {
	Due(ctx context.Context, e Entry, now time.Time) bool
}

// InlineExecutor runs a slot automation's queued run in the caller's
// goroutine (automations.Executor.ExecuteBuiltinInline).
type InlineExecutor interface {
	ExecuteBuiltinInline(ctx context.Context, runID int64) (*db.AutomationRun, error)
}

// Why a built-in did not run at its slot (SlotOutcome.Skipped).
const (
	SkippedOff          = "off"           // its features are off
	SkippedNotConfirmed = "not_confirmed" // its text is not confirmed
	SkippedNotDue       = "not_due"       // its gate said not now
	// SkippedDisabled: the daemon stopped it after a run that would not end
	// (disabled_reason, AUTO-08); it stays off until the owner turns it on.
	SkippedDisabled = "disabled"
)

// ErrBuiltinStopped is RunNow's refusal of a built-in the daemon stopped
// after a run that would not end (its row's disabled_reason, AUTO-08).
var ErrBuiltinStopped = errors.New("the built-in was stopped after a run that would not end")

// StatusError is SlotOutcome.Status when the slot could not run a built-in
// (a database or executor failure, logged).
const StatusError = "error"

// SlotOutcome is what one built-in did at its slot: the run it executed
// (RunID, and Status = the run's status, "queued" when its claim lost) or why
// it did not run (Skipped).
type SlotOutcome struct {
	BuiltinID string
	RunID     int64
	Status    string
	Skipped   string
}

// Runner executes the built-ins at their slots and their manual runs.
type Runner struct {
	db     *db.DB
	exec   InlineExecutor
	gates  map[string]Gate // by built-in id
	cfg    *config.Config
	clock  automations.Clock
	logger *log.Logger
}

// NewRunner returns a runner over the slot executor exec; gates holds each
// built-in's Gate by id (a built-in without one is never due).
func NewRunner(d *db.DB, exec InlineExecutor, gates map[string]Gate, cfg *config.Config, clock automations.Clock, logger *log.Logger) *Runner {
	if clock == nil {
		clock = automations.RealClock{}
	}
	if logger == nil {
		logger = log.Default()
	}
	return &Runner{db: d, exec: exec, gates: gates, cfg: cfg, clock: clock, logger: logger}
}

// RunSlot runs every built-in at slot, in card order. A built-in whose
// features are off is skipped before any pipeline is read or run (FEAT-01):
// it writes nothing but the cancellation of a Run Now queued before it was
// turned off. One whose text is not confirmed, or that the daemon stopped
// after a run that would not end (AUTO-08), cancels its queued manual runs
// and is skipped. Otherwise a queued manual run (Run Now) is executed
// without asking the gate; with none, the gate decides and only a due
// built-in gets a sync run row, executed inline.
func (r *Runner) RunSlot(ctx context.Context, slot Slot) []SlotOutcome {
	var out []SlotOutcome
	for _, e := range AtSlot(slot) {
		if ctx.Err() != nil {
			break
		}
		out = append(out, r.runEntry(ctx, e))
	}
	return out
}

func (r *Runner) runEntry(ctx context.Context, e Entry) SlotOutcome {
	o := SlotOutcome{BuiltinID: e.ID}
	fail := func(what string, err error) SlotOutcome {
		r.logger.Printf("built-in %s: %s: %v", e.ID, what, err)
		o.Status = StatusError
		return o
	}
	skip := func(why string) SlotOutcome {
		if err := r.cancelQueued(e.ID); err != nil {
			return fail("cancelling its queued runs", err)
		}
		o.Skipped = why
		return o
	}
	if !e.Enabled(r.cfg) {
		return skip(SkippedOff)
	}
	r.endStaleRuns()
	a, err := r.db.GetBuiltinAutomation(e.ID)
	if err != nil {
		return fail("reading its row", err)
	}
	if a.DisabledReason != "" {
		r.logger.Printf("built-in %s: stopped (%s); not run until the owner turns it on again", e.ID, a.DisabledReason)
		return skip(SkippedDisabled)
	}
	if !a.Confirmed() {
		return skip(SkippedNotConfirmed)
	}
	queued, err := r.db.TakeQueuedBuiltinRun(a.ID)
	if err != nil {
		return fail("reading its queued run", err)
	}
	if queued != nil {
		return r.execute(ctx, o, queued.ID, false)
	}
	gate := r.gates[e.ID]
	if gate == nil {
		r.logger.Printf("built-in %s: no gate, not run", e.ID)
		o.Skipped = SkippedNotDue
		return o
	}
	now := r.clock.Now()
	if !gate.Due(ctx, e, now) {
		o.Skipped = SkippedNotDue
		return o
	}
	runID, _, err := r.db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync, Now: now})
	if err != nil {
		return fail("queueing its sync run", err)
	}
	return r.execute(ctx, o, runID, true)
}

// execute runs runID inline. A sync run whose claim lost (another run of the
// built-in is active) is cancelled — the next cycle asks the gate again; a
// manual run stays queued for the next slot.
func (r *Runner) execute(ctx context.Context, o SlotOutcome, runID int64, sync bool) SlotOutcome {
	o.RunID = runID
	run, err := r.exec.ExecuteBuiltinInline(ctx, runID)
	switch {
	case err == nil:
		o.Status = run.Status
	case errors.Is(err, automations.ErrRunNotClaimed) && sync:
		r.logger.Printf("built-in %s: another run is active; sync run %d cancelled", o.BuiltinID, runID)
		if _, cerr := r.db.CancelAutomationRun(runID, r.clock.Now()); cerr != nil {
			r.logger.Printf("built-in %s: cancelling sync run %d: %v", o.BuiltinID, runID, cerr)
		}
		o.Status = db.RunCancelled
	case errors.Is(err, automations.ErrRunNotClaimed):
		r.logger.Printf("built-in %s: another run is active; run %d waits for the next slot", o.BuiltinID, runID)
		o.Status = db.RunQueued
	case errors.Is(err, automations.ErrNotRunnable):
		o.Status = db.RunCancelled
	default:
		r.logger.Printf("built-in %s: executing run %d: %v", o.BuiltinID, runID, err)
		o.Status = StatusError
	}
	return o
}

// endStaleRuns ends the built-in runs past their deadline
// (db.MarkStaleBuiltinRuns): a CLI killed while it ran one inline (SIGKILL;
// SIGINT/SIGTERM end the run themselves) leaves it running, and it would
// hold the built-in's one concurrency slot until the next daemon start. A
// failure is logged; the slot then runs as if nothing were stale.
func (r *Runner) endStaleRuns() {
	n, err := r.db.MarkStaleBuiltinRuns(r.clock.Now())
	switch {
	case err != nil:
		r.logger.Printf("built-ins: ending stale runs: %v", err)
	case n > 0:
		r.logger.Printf("built-ins: %d stale run(s) whose process stopped ended as interrupted", n)
	}
}

// cancelQueued cancels the queued manual runs (Run Now) of built-in id as
// not_runnable, as the executor would, logging how many: the slot calls it
// for a built-in that cannot run them now.
func (r *Runner) cancelQueued(id string) error {
	n, err := r.db.CancelQueuedBuiltinRuns(id, r.clock.Now())
	if n > 0 {
		r.logger.Printf("built-in %s: %d queued run(s) cancelled: it cannot run now", id, n)
	}
	return err
}

// ErrRunNowQueued is RunNow's refusal (it also wraps
// automations.ErrRunNotClaimed) when a manual run of the built-in with other
// input is already queued for its next slot.
var ErrRunNowQueued = errors.New("a Run Now is already queued for the next sync")

// RunNow runs built-in id now, inline, with input in (the CLI's generate
// commands): a manual run with event_json {"builtin": in}, whether or not the
// built-in is on. A built-in the daemon stopped (AUTO-08) is refused with
// ErrBuiltinStopped before any run is queued. An unconfirmed built-in's run
// is cancelled and the error wraps automations.ErrNotRunnable; one that
// cannot be claimed (another run of it is active, or — ErrRunNowQueued too —
// a manual run with other input is already queued for the next slot) wraps
// automations.ErrRunNotClaimed; a run this call queued is then cancelled
// while it is still queued, so it never runs later with in (one the slot
// claimed meanwhile is left running: the error still says it runs now).
func (r *Runner) RunNow(ctx context.Context, id string, in automations.BuiltinInput) (*db.AutomationRun, error) {
	if _, ok := Lookup(id); !ok {
		return nil, fmt.Errorf("unknown built-in automation %q", id)
	}
	r.endStaleRuns()
	a, err := r.db.GetBuiltinAutomation(id)
	if err != nil {
		return nil, err
	}
	if a.DisabledReason != "" {
		return nil, fmt.Errorf("built-in %s: %w", id, ErrBuiltinStopped)
	}
	payload, err := json.Marshal(map[string]automations.BuiltinInput{"builtin": in})
	if err != nil {
		return nil, fmt.Errorf("built-in %s: encoding the run's input: %w", id, err)
	}
	runID, coalesced, err := r.db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual,
		EventJSON: string(payload), Now: r.clock.Now()})
	if err != nil {
		return nil, err
	}
	if coalesced {
		queued, err := r.db.GetAutomationRun(runID)
		if err != nil {
			return nil, err
		}
		if queued.EventJSON != string(payload) {
			return nil, fmt.Errorf("built-in %s: run %d: %w: %w", id, runID, ErrRunNowQueued, automations.ErrRunNotClaimed)
		}
	}
	run, err := r.exec.ExecuteBuiltinInline(ctx, runID)
	if errors.Is(err, automations.ErrRunNotClaimed) && !coalesced {
		// The run this call made must never run later with its input; one
		// the slot claimed meanwhile runs now and is left alone.
		if _, cerr := r.db.CancelQueuedAutomationRun(runID, r.clock.Now()); cerr != nil {
			return nil, errors.Join(err, fmt.Errorf("built-in %s: cancelling run %d: %w", id, runID, cerr))
		}
	}
	return run, err
}
