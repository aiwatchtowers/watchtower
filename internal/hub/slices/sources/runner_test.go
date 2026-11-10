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
