package sources

import (
	"context"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"
)

// Go twins of HubRunnerWakeTests' wait tests (board #842, ask #337): the
// wait between two passes of a runner, on synctest's fake clock.

// startWait runs w.wait(ctx, d) and returns a channel closed when it ends
// and the time it took.
func startWait(ctx context.Context, w *runnerWake, d time.Duration) (<-chan struct{}, *atomic.Int64) {
	done := make(chan struct{})
	took := &atomic.Int64{}
	go func() {
		start := time.Now()
		w.wait(ctx, d)
		took.Store(int64(time.Since(start)))
		close(done)
	}()
	return done, took
}

func ended(done <-chan struct{}) bool {
	select {
	case <-done:
		return true
	default:
		return false
	}
}

// twin of HubRunnerWakeTests.testASignalEndsAWaitInProgressAtOnceOnceTheGapIsOver
func TestASignalEndsAWaitInProgressAtOnceOnceTheGapIsOver(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		done, took := startWait(context.Background(), w, 15*time.Second)
		time.Sleep(6 * time.Second)
		synctest.Wait()
		if ended(done) {
			t.Fatal("the wait ended before its timer or a signal")
		}
		w.signal()
		synctest.Wait()
		if !ended(done) {
			t.Fatal("the signal did not end the wait")
		}
		if got := time.Duration(took.Load()); got != 6*time.Second {
			t.Fatalf("the wait took %v, want 6s (no gap left)", got)
		}
	})
}

// twin of HubRunnerWakeTests.testASignalInsideTheGapWaitsOnlyTheRestOfIt
func TestASignalInsideTheGapWaitsOnlyTheRestOfIt(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		done, took := startWait(context.Background(), w, 15*time.Second)
		time.Sleep(2 * time.Second)
		w.signal()
		w.signal()
		time.Sleep(2 * time.Second)
		synctest.Wait()
		if ended(done) {
			t.Fatal("the wait ended inside the gap")
		}
		<-done
		if got := time.Duration(took.Load()); got != runnerMinimumGap {
			t.Fatalf("the wait took %v, want the %v gap", got, runnerMinimumGap)
		}
	})
}

// twin of HubRunnerWakeTests.testASignalSentBetweenWaitsEndsTheNextWaitAfterTheGap
func TestASignalSentBetweenWaitsEndsTheNextWaitAfterTheGap(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		w.signal()
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != runnerMinimumGap {
			t.Fatalf("the pending signal's wait took %v, want the gap", got)
		}
		// Taken once: the wait after it runs its timer.
		done, took = startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != 15*time.Second {
			t.Fatalf("the next wait took %v, want 15s", got)
		}
	})
}

// twin of HubRunnerWakeTests.testWithoutASignalTheWaitEndsWhenItsTimerDoes
func TestWithoutASignalTheWaitEndsWhenItsTimerDoes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != 15*time.Second {
			t.Fatalf("the wait took %v, want 15s and no gap", got)
		}
	})
}

// twin of HubRunnerWakeTests.testCancellingTheTaskEndsTheWait
func TestCancellingTheContextEndsTheWait(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		ctx, cancel := context.WithCancel(context.Background())
		done, took := startWait(ctx, w, 15*time.Second)
		time.Sleep(3 * time.Second)
		cancel()
		<-done
		if got := time.Duration(took.Load()); got != 3*time.Second {
			t.Fatalf("the wait took %v after a cancel at 3s", got)
		}
	})
}

// twin of HubRunnerWakeTests.testAZeroWaitReturnsAtOnce
func TestAZeroWaitReturnsAtOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		w.signal()
		for _, d := range []time.Duration{0, -time.Second} {
			done, took := startWait(context.Background(), w, d)
			<-done
			if took.Load() != 0 {
				t.Fatalf("a %v wait took %v", d, time.Duration(took.Load()))
			}
		}
		// The zero waits left the signal for the next real wait.
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != runnerMinimumGap {
			t.Fatalf("the next wait took %v, want the gap", got)
		}
	})
}

// twin of HubRunnerWakeTests.testACancelledWaitLeavesALaterSignalForTheNextWait
func TestACancelledWaitLeavesALaterSignalForTheNextWait(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		ctx, cancel := context.WithCancel(context.Background())
		done, _ := startWait(ctx, w, 15*time.Second)
		synctest.Wait()
		w.signal() // ends the wait: its gap runs
		synctest.Wait()
		w.signal() // sent during the gap
		cancel()
		<-done

		// The signal sent during the cancelled loop's gap is still pending.
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != runnerMinimumGap {
			t.Fatalf("the next wait took %v, want only the gap", got)
		}
	})
}

// Runners on request (#1996): a phone request wakes the runner with
// signalNow, which skips the minimum gap; background signals keep it.

func TestAnUrgentSignalEndsTheWaitWithoutTheGap(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		done, took := startWait(context.Background(), w, 15*time.Second)
		time.Sleep(time.Second)
		w.signalNow()
		synctest.Wait()
		if !ended(done) {
			t.Fatal("the urgent signal did not end the wait at once")
		}
		if got := time.Duration(took.Load()); got != time.Second {
			t.Fatalf("the wait took %v, want 1s (no gap)", got)
		}
	})
}

func TestAnUrgentSignalSentBetweenWaitsEndsTheNextWaitAtOnce(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		w.signalNow()
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != 0 {
			t.Fatalf("the pending urgent signal's wait took %v, want 0", got)
		}
	})
}

func TestAnUrgentSignalCutsTheGapABackgroundSignalStarted(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		done, took := startWait(context.Background(), w, 15*time.Second)
		time.Sleep(time.Second)
		w.signal() // a state change: its gap runs to 5 s
		time.Sleep(time.Second)
		synctest.Wait()
		if ended(done) {
			t.Fatal("the background signal skipped the gap")
		}
		w.signalNow()
		synctest.Wait()
		if !ended(done) {
			t.Fatal("the urgent signal did not cut the gap")
		}
		if got := time.Duration(took.Load()); got != 2*time.Second {
			t.Fatalf("the wait took %v, want 2s", got)
		}
	})
}

// A burst of requests while a pass runs (signals sent before the next wait)
// costs exactly one follow-up pass: the next wait ends at once, the one
// after it runs its full timer.
func TestABurstOfUrgentSignalsDuringAPassMakesOneFollowUpPass(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		for range 5 {
			w.signalNow()
			w.signal()
		}
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != 0 {
			t.Fatalf("the follow-up pass waited %v", got)
		}
		done, took = startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != 15*time.Second {
			t.Fatalf("a second follow-up pass: the wait took %v, want 15s", got)
		}
	})
}

// A loop stopped while an urgent signal is pending (its ctx ended) leaves
// it for the next wait of the same wake.
func TestACancelledWaitKeepsAnUrgentSignalForTheNextWait(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		w := newRunnerWake(0)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		w.signalNow()
		done, _ := startWait(ctx, w, 15*time.Second)
		<-done
		done, took := startWait(context.Background(), w, 15*time.Second)
		<-done
		if got := time.Duration(took.Load()); got != 0 {
			t.Fatalf("the next wait took %v, want 0", got)
		}
	})
}

func TestCadenceAnUrgentRequestSkipsTheSpacingOnceForThatWorkbenchOnly(t *testing.T) {
	c := newCadence[int](time.Minute, 5*time.Second)
	t0 := time.Unix(1_800_000_000, 0)
	keep := map[int64]bool{1: true, 2: true}
	never := func(int64) bool { return false }
	first := func(int64, bool) bool { return true }
	if due := c.takeDue([]int64{1, 2}, keep, t0, first, never); len(due) != 2 {
		t.Fatalf("first pass: %v", due)
	}
	c.requestNow(1)
	c.request(2, true)
	due := c.takeDue([]int64{1, 2}, keep, t0.Add(time.Second), first, never)
	if len(due) != 1 || due[0].id != 1 {
		t.Fatalf("an urgent request inside the spacing: due %v, want only workbench 1", due)
	}
	// Once: a background request of workbench 1 right after waits again.
	c.request(1, true)
	due = c.takeDue([]int64{1, 2}, keep, t0.Add(2*time.Second), first, never)
	if len(due) != 0 {
		t.Fatalf("the spacing was skipped twice: %v", due)
	}
	// A pass cut before it ran workbench 1 keeps its urgency.
	c.requestNow(1)
	due = c.takeDue([]int64{1, 2}, keep, t0.Add(3*time.Second), first, never)
	if len(due) != 1 || due[0].id != 1 {
		t.Fatalf("due %v", due)
	}
	c.restore(due)
	due = c.takeDue([]int64{1, 2}, keep, t0.Add(4*time.Second), first, never)
	if len(due) != 1 || due[0].id != 1 {
		t.Fatalf("an unfinished urgent run was not kept due: %v", due)
	}
}
