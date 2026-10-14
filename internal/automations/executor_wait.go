package automations

import (
	"context"
	"errors"
	"fmt"
	"time"
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

// Wait sets the run waiting with reason and pauses its active time, then
// polls ready every PollInterval and on Wake. ready true resumes the run
// (nil); a run ended meanwhile (a CLI cancel) is a cancel interrupt; a wait
// longer than the recipe's pause_timeout_hours is an expired interrupt (the
// executor ends the run expired); an error from ready resumes the run and is
// returned.
func (w executorWaiter) Wait(ctx context.Context, reason string, ready func(context.Context) (bool, error)) error {
	rw, ok := ctx.Value(runWaitKey{}).(*runWait)
	if !ok {
		return errors.New("automation wait: the context does not belong to an executor run")
	}
	if ready == nil {
		return errors.New("automation wait: no ready check")
	}
	if err := w.e.db.SetAutomationRunWaiting(rw.runID, reason); err != nil {
		return fmt.Errorf("automation wait: %w", err)
	}
	rw.meter.PauseActive()
	defer rw.meter.ResumeActive()
	return w.e.pollWait(ctx, rw, w.e.clock.Now(), ready)
}

func (e *Executor) pollWait(ctx context.Context, rw *runWait, since time.Time, ready func(context.Context) (bool, error)) error {
	for {
		nudge := e.nudged()
		ended, err := e.runEnded(rw.runID)
		if err != nil {
			return fmt.Errorf("automation wait: %w", err)
		}
		if ended {
			return &RunInterrupted{Reason: InterruptCancel}
		}
		done, err := ready(ctx)
		if err != nil || done {
			return e.resumeAfterWait(rw.runID, err)
		}
		if e.clock.Now().Sub(since) >= rw.pauseTimeout {
			return &RunInterrupted{Reason: InterruptExpired}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-nudge:
		case <-e.clock.After(PollInterval):
		}
	}
}

// resumeAfterWait moves the run back to running; readyErr, when set, is the
// ready check's failure the wait returns.
func (e *Executor) resumeAfterWait(runID int64, readyErr error) error {
	if err := e.db.ResumeAutomationRun(runID); err != nil {
		return errors.Join(readyErr, fmt.Errorf("automation wait: resuming: %w", err))
	}
	if readyErr != nil {
		return fmt.Errorf("automation wait: %w", readyErr)
	}
	return nil
}
