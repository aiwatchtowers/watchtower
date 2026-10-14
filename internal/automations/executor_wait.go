package automations

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// runWait is what a wait needs to know about the run it pauses; the executor
// puts it on the run's Env.Ctx.
type runWait struct {
	runID        int64
	meter        *Meter
	pauseTimeout time.Duration
}

type runWaitKey struct{}

func withRunWait(ctx context.Context, w *runWait) context.Context {
	return context.WithValue(ctx, runWaitKey{}, w)
}

// executorWaiter is the Waiter the executor gives every run (spec §7.6).
type executorWaiter struct{ e *Executor }

// Waiter returns the Waiter SDK modules pause a run with (P2 tool waits, P5
// asks and sessions). Wait must be called with the run's Env.Ctx.
func (e *Executor) Waiter() Waiter { return executorWaiter{e: e} }

// Wait pauses the run's active time and sets it waiting with reason, then
// polls ready every PollInterval and on Wake. A run ended meanwhile (a CLI
// cancel) is a cancel interrupt; a wait longer than the recipe's
// pause_timeout_hours (counted from the pause) is an expired interrupt (the
// executor ends the run expired). Once ready reports true — or fails — the
// run goes back to running as soon as a running slot is free (waiting runs
// hold none, so a resume must not push running past MaxConcurrent); the
// ready check's error is then returned.
func (w executorWaiter) Wait(ctx context.Context, reason string, ready func(context.Context) (bool, error)) error {
	rw, ok := ctx.Value(runWaitKey{}).(*runWait)
	if !ok {
		return errors.New("automation wait: the context does not belong to an executor run")
	}
	if ready == nil {
		return errors.New("automation wait: no ready check")
	}
	since := w.e.clock.Now()
	rw.meter.PauseActive()
	defer rw.meter.ResumeActive()
	if err := w.e.db.SetAutomationRunWaiting(rw.runID, reason); err != nil {
		return fmt.Errorf("automation wait: %w", err)
	}
	readyErr, err := w.e.pollReady(ctx, rw, since, ready)
	if err != nil {
		return err
	}
	if err := w.e.resumeWhenSlotFree(ctx, rw, since); err != nil {
		return errors.Join(readyErr, err)
	}
	if readyErr != nil {
		return fmt.Errorf("automation wait: %w", readyErr)
	}
	return nil
}

// pollReady polls until ready reports true (readyErr nil) or fails
// (readyErr set); err ends the wait without resuming (a cancel, an expiry,
// ctx done, an unreadable run).
func (e *Executor) pollReady(ctx context.Context, rw *runWait, since time.Time,
	ready func(context.Context) (bool, error)) (readyErr, err error) {
	for {
		nudge := e.nudged()
		if err := e.stillActive(rw.runID); err != nil {
			return nil, err
		}
		done, rerr := ready(ctx)
		if rerr != nil || done {
			return rerr, nil
		}
		if e.clock.Now().Sub(since) >= rw.pauseTimeout {
			return nil, &RunInterrupted{Reason: InterruptExpired}
		}
		if err := e.idle(ctx, nudge); err != nil {
			return nil, err
		}
	}
}

// resumeWhenSlotFree moves the run back to running once fewer than
// MaxConcurrent runs are running, re-checking every PollInterval and on Wake
// (a finishing run wakes it). Meanwhile it counts in readyWaits, so Step
// claims no queued run into the slot it is owed; the pause_timeout_hours
// expiry still applies (waiting_reason keeps its value: no reason names a
// slot wait).
func (e *Executor) resumeWhenSlotFree(ctx context.Context, rw *runWait, since time.Time) error {
	e.readyWaits.Add(1)
	defer e.readyWaits.Add(-1)
	for {
		nudge := e.nudged()
		resumed, err := e.db.ResumeAutomationRunIfSlot(rw.runID, e.maxConcurrent)
		if errors.Is(err, db.ErrRunNotActive) {
			return &RunInterrupted{Reason: InterruptCancel} // ended (cancelled) while waiting for a slot
		}
		if err != nil {
			return fmt.Errorf("automation wait: resuming: %w", err)
		}
		if resumed {
			return nil
		}
		if e.clock.Now().Sub(since) >= rw.pauseTimeout {
			return &RunInterrupted{Reason: InterruptExpired}
		}
		if err := e.idle(ctx, nudge); err != nil {
			return err
		}
	}
}

// stillActive is nil while the run is running or waiting, a cancel
// interrupt once it ended.
func (e *Executor) stillActive(runID int64) error {
	ended, err := e.runEnded(runID)
	if err != nil {
		return fmt.Errorf("automation wait: %w", err)
	}
	if ended {
		return &RunInterrupted{Reason: InterruptCancel}
	}
	return nil
}

// idle waits for a Wake, PollInterval or ctx's end. An ended ctx (the
// daemon or the CLI stopping, or the sandbox interrupting) is a cancel
// interrupt, so the script stops rather than seeing a catchable error.
func (e *Executor) idle(ctx context.Context, nudge <-chan struct{}) error {
	select {
	case <-ctx.Done():
		return &RunInterrupted{Reason: InterruptCancel}
	case <-nudge:
	case <-e.clock.After(PollInterval):
	}
	return nil
}
