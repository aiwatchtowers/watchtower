package slices

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
)

// saveTimes records the publisher's saves on its clock.
type saveTimes struct {
	mu sync.Mutex
	at []time.Time
}

func (s *saveTimes) Saved(_, _ string, _, doneAt time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.at = append(s.at, doneAt)
}

func (s *saveTimes) times() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.at)
}

// runFakeSaves is runFake with the saves recorded.
func (r *rig) runFakeSaves(sources ...Source) (*runner, *saveTimes) {
	r.t.Helper()
	ft := newFakeTime()
	saves := &saveTimes{}
	p := r.publisherWith(Config{Clock: ft.Now, Latency: saves}, sources...)
	p.mono, p.timer = ft.Now, ft.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()
	r.t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			r.t.Errorf("Run = %v", err)
		}
	})
	ru := &runner{t: r.t, ft: ft, p: p}
	ru.settle(0) // the full cycle at start
	return ru, saves
}

func (ru *runner) publishNow(k Kind) {
	n := ru.ft.armedCount()
	ru.p.PublishNow(k)
	ru.settle(n)
}

// An applied action's nudge on a quiet kind saves at once, not after the
// debounce.
func TestPublishNowSavesAQuietKindAtOnce(t *testing.T) {
	for _, tc := range []struct {
		kind    transport.Kind
		spacing time.Duration
	}{{transport.KindRelay, RelaySpacing}, {transport.KindCloudKit, CloudKitSpacing}} {
		t.Run(string(tc.kind), func(t *testing.T) {
			r := newRig(t, tc.kind)
			src := &fakeSource{kind: "target"}
			src.set(item("1", `{"v":0}`))
			ru, saves := r.runFakeSaves(src)
			ru.step(tc.spacing) // the start cycle's write is a spacing old
			src.set(item("1", `{"v":1}`))
			at := ru.ft.Now()
			ru.publishNow("target")
			got := saves.times()
			if len(got) != 2 || !got[1].Equal(at) {
				t.Fatalf("saves %v, want the nudge's at once (%v)", got, at)
			}
		})
	}
}

// A steady stream of applied actions (~12/s for 3 s) gets every change saved
// within 300 ms, while the kind's saves stay at least the spacing apart.
func TestPublishNowBurstSavesEachChangeQuicklyAtMostOncePerSpacing(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":0}`))
	ru, saves := r.runFakeSaves(src)
	ru.step(RelaySpacing)
	var changes []time.Time
	for i := range 300 { // 3 s in 10 ms steps, an action every 80 ms
		if i%8 == 0 {
			src.set(item("1", fmt.Sprintf(`{"v":%d}`, i+1)))
			changes = append(changes, ru.ft.Now())
			ru.publishNow("target")
		}
		ru.step(10 * time.Millisecond)
	}
	ru.step(time.Second) // the last change's save
	got := saves.times()[1:]
	for i := 1; i < len(got); i++ {
		if gap := got[i].Sub(got[i-1]); gap < RelaySpacing {
			t.Fatalf("saves %d and %d only %v apart, want at least %v", i-1, i, gap, RelaySpacing)
		}
	}
	if len(got) >= len(changes) {
		t.Fatalf("%d saves for %d changes: the burst was not coalesced", len(got), len(changes))
	}
	for _, c := range changes {
		i := sort.Search(len(got), func(i int) bool { return !got[i].Before(c) })
		if i == len(got) || got[i].Sub(c) > 300*time.Millisecond {
			t.Fatalf("the change at +%v waited more than 300 ms (saves %v)", c.Sub(changes[0]), got)
		}
	}
}

// PublishSoon (the data_version poll, the source watchers) keeps the trailing
// debounce: only an action's nudge skips it.
func TestPublishSoonStillWaitsForTheDebounce(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":0}`))
	ru, saves := r.runFakeSaves(src)
	ru.step(RelaySpacing)
	src.set(item("1", `{"v":1}`))
	ru.publishSoon("target")
	if n := len(saves.times()); n != 1 {
		t.Fatalf("%d saves before the debounce, want only the start's", n)
	}
	ru.step(Debounce)
	if n := len(saves.times()); n != 2 {
		t.Fatalf("%d saves after the debounce, want 2", n)
	}
}
