package hub

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/logcanary"
	"watchtower/internal/sessionstart"
)

// fakeLister answers Runs with runs or err, counting the calls.
type fakeLister struct {
	mu    sync.Mutex
	runs  map[int64]time.Time
	err   error
	calls atomic.Int32
}

func (f *fakeLister) Runs(context.Context) (map[int64]time.Time, error) {
	f.calls.Add(1)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	return f.runs, nil
}

func (f *fakeLister) answer(runs map[int64]time.Time, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.runs, f.err = runs, err
}

// With no phone linked the poll never lists the host, however often it is
// kicked or ticks; the view stays the empty one.
func TestLivenessDoesNotPollWithoutALinkedPhone(t *testing.T) {
	f := &fakeLister{runs: map[int64]time.Time{1: time.Now()}}
	var linked atomic.Bool
	l := newLiveness(f, linked.Load, 10*time.Millisecond, nil)
	l.gap = time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { defer close(done); l.run(ctx) }()
	for range 20 {
		l.kick()
		time.Sleep(5 * time.Millisecond)
	}
	if n := f.calls.Load(); n != 0 {
		t.Fatalf("the host was listed %d times with no phone linked", n)
	}
	if live := l.get(); live.Settled || len(live.Runs) != 0 {
		t.Fatalf("liveness %+v with no phone linked", live)
	}
	linked.Store(true)
	eventually(t, 5*time.Second, "a list once a phone is linked", func() bool { return len(l.get().Runs) == 1 })
	cancel()
	<-done
}

// A host that does not answer is logged once per transition, not per
// refresh, and its recovery once; each failed refresh clears the view at
// once (nothing live, not settled).
func TestLivenessLogsAnUnreachableHostOnceAndClearsAtOnce(t *testing.T) {
	sink := logcanary.Capture(t)
	at := time.Now()
	f := &fakeLister{runs: map[int64]time.Time{7: at}}
	changes := 0
	l := newLiveness(f, nil, time.Hour, func() { changes++ })
	ctx := context.Background()
	l.refresh(ctx)
	if live := l.get(); !live.Settled || !live.Runs[7].Equal(at) {
		t.Fatalf("liveness %+v", live)
	}
	f.answer(nil, fmt.Errorf("%w: dial", sessionstart.ErrHostNotRunning))
	for range 50 {
		l.refresh(ctx)
	}
	if live := l.get(); live.Settled || len(live.Runs) != 0 {
		t.Fatalf("a failed list left %+v", live)
	}
	f.answer(nil, errors.New("protocol"))
	l.refresh(ctx)
	l.refresh(ctx)
	f.answer(map[int64]time.Time{7: at}, nil)
	l.refresh(ctx)
	l.refresh(ctx)
	out := sink.String()
	if n := strings.Count(out, "listing the running sessions failed"); n != 2 {
		t.Errorf("%d failure lines, want one per transition (2):\n%s", n, out)
	}
	if n := strings.Count(out, "lists again"); n != 1 {
		t.Errorf("%d recovery lines, want 1:\n%s", n, out)
	}
	if changes != 3 { // listed, cleared, listed again
		t.Errorf("onChange ran %d times, want 3", changes)
	}
}
