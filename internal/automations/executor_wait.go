package automations

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"watchtower/internal/db"
)

// runWait is what a wait needs to know about the run it pauses; the executor
// puts it on the run's Env.Ctx.
type runWait struct {
	runID        int64
	meter        *Meter
	pauseTimeout time.Duration
	// stopping is the daemon's stop (the executor's ctx); nil for a CLI's
	// inline run, which never stays waiting. journal tells whether the wait
	// could be resumed; left is set once a wait returned errDaemonStopping.
	stopping <-chan struct{}
	journal  *Journal
	left     atomic.Bool

	mu          sync.Mutex
	resumeSince time.Time // a resumed wait's original start (pause_timeout_hours)
}

// resumeAt makes the next wait count its pause timeout from t (the resumed
// waiting step's start).
func (rw *runWait) resumeAt(t time.Time) {
	rw.mu.Lock()
	defer rw.mu.Unlock()
	rw.resumeSince = t
}

// waitStart is when the wait began: now, or the resumed wait's original
// start (taken once).
func (rw *runWait) waitStart(now time.Time) time.Time {
	rw.mu.Lock()
	defer rw.mu.Unlock()
	if t := rw.resumeSince; !t.IsZero() {
		rw.resumeSince = time.Time{}
		return t
	}
	return now
}

// stayWaiting reports — and records — that a wait whose ctx ended stays
// waiting for a resume: the daemon is stopping and the run could resume at
// this wait (AUTO-08 as amended by board #795). Otherwise the wait ends as
// before.
func (rw *runWait) stayWaiting(ctx context.Context) bool {
	if ctx.Err() == nil || rw.stopping == nil || rw.journal == nil {
		return false
	}
	select {
	case <-rw.stopping:
	default:
		return false
	}
	if !rw.journal.waitingResumable() {
		return false
	}
	rw.left.Store(true)
	return true
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
	since := rw.waitStart(w.e.clock.Now())
	rw.meter.PauseActive()
	defer rw.meter.ResumeActive()
	if err := w.e.db.SetAutomationRunWaiting(rw.runID, reason); err != nil {
		return fmt.Errorf("automation wait: %w", err)
	}
	readyErr, err := w.e.pollReady(ctx, rw, since, ready)
	if err != nil {
		return err
	}
	if readyErr != nil && rw.stayWaiting(ctx) {
		return errDaemonStopping // the check failed under the stop: the resume asks again
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
		if err := e.idle(ctx, rw, nudge); err != nil {
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
		if err := e.idle(ctx, rw, nudge); err != nil {
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

// idle waits for a Wake, PollInterval or ctx's end. An ended ctx is
// errDaemonStopping when the run stays waiting for a resume (stayWaiting),
// else (the CLI stopping, the sandbox interrupting, a run that cannot
// resume) a cancel interrupt, so the script stops rather than seeing a
// catchable error.
func (e *Executor) idle(ctx context.Context, rw *runWait, nudge <-chan struct{}) error {
	select {
	case <-ctx.Done():
		if rw.stayWaiting(ctx) {
			return errDaemonStopping
		}
		return &RunInterrupted{Reason: InterruptCancel}
	case <-nudge:
	case <-e.clock.After(PollInterval):
	}
	return nil
}
