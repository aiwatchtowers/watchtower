package daemon

import (
	"context"
	"testing"
)

// TestPhaseSessionCleanup_RunsAtMostOncePerInterval: the first cycle runs
// the pass, the next cycles within sessionCleanupEvery do not; a cancelled
// ctx or no pass runs nothing.
func TestPhaseSessionCleanup_RunsAtMostOncePerInterval(t *testing.T) {
	d := &Daemon{}
	d.phaseSessionCleanup(context.Background()) // no pass set: nothing to run
	runs := 0
	d.SetSessionCleanup(func(ctx context.Context) {
		if _, ok := ctx.Deadline(); !ok {
			t.Error("the pass runs without a budget")
		}
		runs++
	})
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	d.phaseSessionCleanup(cancelled)
	if runs != 0 {
		t.Fatalf("a cancelled cycle ran the pass")
	}
	d.phaseSessionCleanup(context.Background())
	d.phaseSessionCleanup(context.Background())
	if runs != 1 {
		t.Fatalf("runs = %d, want 1", runs)
	}
	d.sessionCleanupAt = d.sessionCleanupAt.Add(-sessionCleanupEvery)
	d.phaseSessionCleanup(context.Background())
	if runs != 2 {
		t.Fatalf("runs = %d after the interval, want 2", runs)
	}
}
