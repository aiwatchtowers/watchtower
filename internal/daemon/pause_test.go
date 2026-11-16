package daemon

import (
	"context"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

// gateRunner counts how often the daemon started it and whether it runs now.
type gateRunner struct {
	runs   atomic.Int32
	active atomic.Int32
}

func (r *gateRunner) Run(ctx context.Context) error {
	r.runs.Add(1)
	r.active.Add(1)
	<-ctx.Done()
	r.active.Add(-1)
	return nil
}

func (r *gateRunner) Wake() {}

func requireNoCycle(t *testing.T, h *loopHarness, what string) {
	t.Helper()
	select {
	case <-h.probe.started:
		t.Fatalf("a sync cycle started: %s", what)
	default:
	}
}

// A paused daemon starts no sync cycle (not on a trigger, not on a tick), no
// scheduled automation and no plan-usage poll, and the executor keeps
// running; a resume starts them again, and a pause lets a running cycle
// finish.
func TestDaemon_PausedStartsNoCycleAutomationOrPlanPoll(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var paused atomic.Bool
		paused.Store(true)
		sched, exec, plan := &gateRunner{}, &gateRunner{}, &gateRunner{}
		ended := make(chan struct{}, 4)
		h := startLoop(t, loopOpts{poll: time.Minute, setup: func(d *Daemon) {
			d.SetSyncPaused(paused.Load)
			d.SetAutomations(sched, exec)
			d.config.PlanUsage.Enabled = true
			d.SetPlanUsage(plan, func() error { return nil })
			d.cycleEnded = func() { ended <- struct{}{} }
		}})

		h.trigger <- struct{}{}
		time.Sleep(2*time.Minute + time.Second) // two poll intervals
		synctest.Wait()
		requireNoCycle(t, h, "paused from the start")
		if n := sched.runs.Load(); n != 0 {
			t.Fatalf("the scheduler ran %d times while paused", n)
		}
		if n := plan.runs.Load(); n != 0 {
			t.Fatalf("the plan-usage poller ran %d times while paused", n)
		}
		if exec.active.Load() != 1 {
			t.Fatal("the executor (approval apply, Run Now) is not running while paused")
		}

		// Resume: the scheduler and the poller start, and a trigger syncs.
		h.probe.block.Store(true)
		paused.Store(false)
		time.Sleep(pauseRecheck)
		synctest.Wait()
		if sched.active.Load() != 1 || plan.active.Load() != 1 {
			t.Fatalf("after resume: scheduler active %d, poller active %d", sched.active.Load(), plan.active.Load())
		}
		h.trigger <- struct{}{}
		recv(t, h.probe.started, "the cycle after resume")

		// Pause while that cycle runs: it finishes, the scheduler and the
		// poller stop, and nothing new starts.
		paused.Store(true)
		time.Sleep(pauseRecheck)
		synctest.Wait()
		if sched.active.Load() != 0 || plan.active.Load() != 0 {
			t.Fatalf("after pause: scheduler active %d, poller active %d", sched.active.Load(), plan.active.Load())
		}
		if exec.active.Load() != 1 {
			t.Fatal("a pause stopped the executor")
		}
		h.probe.release <- struct{}{}
		<-ended
		h.trigger <- struct{}{}
		time.Sleep(2*time.Minute + time.Second)
		synctest.Wait()
		requireNoCycle(t, h, "paused after a cycle")
	})
}
