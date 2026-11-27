package daemon

import (
	"context"
	"testing"
	"time"
)

// TestSessionCleanup_RunsAtStartAndPerTickUntilStopped: one pass at start,
// one per tick, each with a budget, one at a time; stopping ends the loop.
// The ticker is a channel the test drives: no wall clock.
func TestSessionCleanup_RunsAtStartAndPerTickUntilStopped(t *testing.T) {
	d := &Daemon{}
	passes := make(chan struct{})
	d.SetSessionCleanup(func(ctx context.Context) {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("a pass runs without a budget")
		}
		passes <- struct{}{}
	})
	ctx, cancel := context.WithCancel(context.Background())
	tick := make(chan time.Time)
	done := make(chan struct{})
	go func() {
		defer close(done)
		d.runSessionCleanup(ctx, tick)
	}()
	<-passes // the start pass
	tick <- time.Time{}
	<-passes // the tick's pass
	cancel()
	<-done
}

// TestSessionCleanup_NoPassNoLoop: a daemon without a pass starts nothing.
func TestSessionCleanup_NoPassNoLoop(t *testing.T) {
	stop := (&Daemon{}).startSessionCleanup(context.Background())
	stop()
}

// TestSessionCleanup_StopWaitsForTheLoop: stop cancels the running pass's
// ctx and returns only once the loop ended.
func TestSessionCleanup_StopWaitsForTheLoop(t *testing.T) {
	d := &Daemon{}
	started := make(chan struct{})
	ended := false
	d.SetSessionCleanup(func(ctx context.Context) {
		close(started)
		<-ctx.Done()
		ended = true
	})
	stop := d.startSessionCleanup(context.Background())
	<-started
	stop()
	if !ended {
		t.Fatal("stop returned before the pass ended")
	}
}

// TestSessionCleanup_BudgetCoversBothParts (#2402 step 0): a pass's ctx
// is bounded by 20 minutes, the sum of AutoRun's two parts (the session
// applies, then the repository pass, 10 minutes each), so the repository
// pass is not cut short by the daemon's own bound. The deadline is read,
// never waited for.
func TestSessionCleanup_BudgetCoversBothParts(t *testing.T) {
	d := &Daemon{}
	left := make(chan time.Duration, 1)
	d.SetSessionCleanup(func(ctx context.Context) {
		deadline, _ := ctx.Deadline()
		left <- time.Until(deadline)
	})
	ctx, cancel := context.WithCancel(context.Background())
	tick := make(chan time.Time)
	done := make(chan struct{})
	go func() {
		defer close(done)
		d.runSessionCleanup(ctx, tick)
	}()
	got := <-left
	cancel()
	<-done
	if got <= 19*time.Minute || got > 20*time.Minute {
		t.Fatalf("a pass has %v, want 20 minutes", got)
	}
}
