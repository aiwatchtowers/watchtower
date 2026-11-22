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
