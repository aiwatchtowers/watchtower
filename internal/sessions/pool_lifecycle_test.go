package sessions

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"
)

// waitingPoolContext observes the public Context protocol when an acquisition
// reaches its full-capacity wait. Tests can then close/resize without sleeps or
// guessing whether the goroutine has started waiting yet.
type waitingPoolContext struct {
	context.Context
	waiting chan struct{}
	once    sync.Once
}

func (c *waitingPoolContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}

type poolAcquisition struct {
	worker *Worker
	err    error
}

func blockedPoolAcquisition(t *testing.T, p *SessionPool) <-chan poolAcquisition {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	waiting := &waitingPoolContext{Context: ctx, waiting: make(chan struct{})}
	result := make(chan poolAcquisition, 1)
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		worker, err := p.Acquire(waiting)
		result <- poolAcquisition{worker, err}
	}()
	t.Cleanup(func() { cancel(); p.Close(); <-exited })
	<-waiting.waiting // the acquisition reached the full-capacity wait
	return result
}

func TestSessionPoolAlreadyCancelledAcquirePreservesAvailablePermit(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := NewSessionPool(1)
		defer p.Close()
		cancelled, cancel := context.WithCancel(context.Background())
		cancel()
		worker, err := p.Acquire(cancelled)
		if worker != nil || !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled acquisition: worker=%v err=%v", worker, err)
		}
		ctx := context.Background()
		worker, err = p.Acquire(ctx)
		if err != nil || worker == nil {
			t.Fatalf("cancelled request consumed the available permit: worker=%v err=%v", worker, err)
		}
		full, stopFull := context.WithTimeout(ctx, 20*time.Millisecond)
		defer stopFull()
		if extra, err := p.Acquire(full); extra != nil || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("one permit must still bound capacity: worker=%v err=%v", extra, err)
		}
		p.Release(worker)
		worker, err = p.Acquire(ctx)
		if err != nil || worker == nil {
			t.Fatalf("cancelled waiter consumed a future permit: worker=%v err=%v", worker, err)
		}
		p.Release(worker)
	})
}

func TestSessionPoolCloseWakesWaiterAndResizeCannotReopen(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := NewSessionPool(1)
		defer p.Close()
		worker, err := p.Acquire(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		pending := blockedPoolAcquisition(t, p)
		p.Close()
		result := <-pending
		if result.worker != nil || result.err == nil || !strings.Contains(result.err.Error(), "closed") {
			t.Fatalf("Close must wake the waiter with closure, not admit it or wait for cancellation: %+v", result)
		}
		p.Release(worker)
		p.Close()
		p.Resize(4)
		if worker, err := p.Acquire(context.Background()); worker != nil || err == nil || !strings.Contains(err.Error(), "closed") {
			t.Fatalf("release, repeated Close and Resize must not reopen a closed pool: worker=%v err=%v", worker, err)
		}
	})
}

func TestSessionPoolResizeWakesWaiterAndZeroShrinkKeepsActiveAdmissions(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		p := NewSessionPool(1)
		defer p.Close()
		ctx := context.Background()
		first, err := p.Acquire(ctx)
		if err != nil {
			t.Fatal(err)
		}
		pending := blockedPoolAcquisition(t, p)
		p.Resize(2)
		result := <-pending
		if result.err != nil || result.worker == nil {
			t.Fatalf("Resize growth must wake a waiter without releasing the old worker: %+v", result)
		}
		p.Resize(0)
		p.Release(first)
		full, stopFull := context.WithTimeout(ctx, 20*time.Millisecond)
		defer stopFull()
		if worker, err := p.Acquire(full); worker != nil || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("zero-size shrink must retain one occupied permit: worker=%v err=%v", worker, err)
		}
		p.Release(result.worker)
		next, err := p.Acquire(ctx)
		if err != nil || next == nil {
			t.Fatalf("zero-size shrink must retain a usable minimum capacity: worker=%v err=%v", next, err)
		}
		p.Release(next)
	})
}
