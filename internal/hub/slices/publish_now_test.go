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
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
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

// A kind whose save failed waits out the backoff: applied actions' nudges
// during it never send it to the transport again, and the backoff still
// doubles.
func TestPublishNowWaitsOutAFailedSavesBackoff(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	r.tr.FailNext("save", transport.ErrUnavailable)
	r.tr.FailNext("save", transport.ErrUnavailable)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	ru := r.runFake(src) // the start cycle's save fails: retried in 1 s
	nudgeFor := func(d time.Duration) {
		for range d / (100 * time.Millisecond) {
			ru.publishNow("target")
			ru.step(100 * time.Millisecond)
		}
	}
	nudgeFor(RetryFirst - 100*time.Millisecond)
	if n := len(src.readTimes()); n != 1 {
		t.Fatalf("read %d times inside the first backoff, want only the start's", n)
	}
	ru.step(100 * time.Millisecond) // the retry: fails, the next waits 2 s
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("read %d times after the first backoff, want 2", n)
	}
	nudgeFor(2*RetryFirst - 100*time.Millisecond)
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("read %d times inside the doubled backoff, want 2", n)
	}
	ru.step(100 * time.Millisecond)
	if _, ok := r.live()[r.wireName("target-1")]; !ok {
		t.Fatal("target not saved once the doubled backoff ended")
	}
}

// A RATE_LIMITED save waits the relay's retry_after_s, not the backoff.
func TestRateLimitedSaveWaitsTheRelaysRetryAfter(t *testing.T) {
	limited := func(after uint32) error {
		return relay.MapError(&client.Error{E: &relayv1.Error{
			Code: relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, RetryAfterS: &after,
		}})
	}
	r := newRig(t, transport.KindRelay)
	r.tr.FailNext("save", limited(3))
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	ru := r.runFake(src)
	for range 29 { // 2.9 s of nudges
		ru.publishNow("target")
		ru.step(100 * time.Millisecond)
	}
	if n := len(src.readTimes()); n != 1 {
		t.Fatalf("read %d times before the relay's 3 s, want only the start's", n)
	}
	ru.step(100 * time.Millisecond)
	if _, ok := r.live()[r.wireName("target-1")]; !ok {
		t.Fatal("target not saved after the relay's retry_after_s")
	}
	var backoff time.Duration
	if d := retryWait(limited(120), &backoff); d != RetryRateLimitedMax || backoff != 0 {
		t.Fatalf("retry_after 120 s waits %v (backoff %v), want the %v cap and no backoff", d, backoff, RetryRateLimitedMax)
	}
	if d := retryWait(transport.ErrRateLimited, &backoff); d != RetryFirst {
		t.Fatalf("RATE_LIMITED without retry_after_s waits %v, want %v", d, RetryFirst)
	}
}

// PublishNow makes only its own kinds due: a kind PublishSoon marked keeps
// its debounce.
func TestPublishNowLeavesPublishSoonKindsOnTheirDebounce(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	soon, now := &fakeSource{kind: "workbench"}, &fakeSource{kind: "target"}
	soon.set(item("1", `{"v":0}`))
	now.set(item("1", `{"v":0}`))
	ru := r.runFake(soon, now)
	ru.step(RelaySpacing)
	ru.publishSoon("workbench")
	ru.publishNow("target")
	if a, b := len(soon.readTimes()), len(now.readTimes()); a != 1 || b != 2 {
		t.Fatalf("reads soon=%d now=%d after the nudge, want 1 and 2", a, b)
	}
	ru.step(Debounce)
	if n := len(soon.readTimes()); n != 2 {
		t.Fatalf("the PublishSoon kind read %d times after its debounce, want 2", n)
	}
}

// PublishNow during a pause publishes nothing; Resume's full diff covers it.
func TestPublishNowWhilePausedWaitsForResume(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":1}`))
	ru := r.runFake(src)
	ru.p.Pause()
	src.set(item("1", `{"v":2}`))
	ru.publishNow("target")
	ru.step(time.Second)
	if n := len(src.readTimes()); n != 1 {
		t.Fatalf("read %d times while paused", n)
	}
	n := ru.ft.armedCount()
	ru.p.Resume()
	ru.settle(n)
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("read %d times after Resume, want 1 + 1", n)
	}
	ru.step(time.Second) // the full diff covered the nudge: no extra read
	if n := len(src.readTimes()); n != 2 {
		t.Fatalf("read %d times after Resume settled, want 2", n)
	}
}

// On CloudKit a stream of actions is saved at most once per 2 s spacing,
// each change within one spacing.
func TestPublishNowBurstOnCloudKitKeepsTheSpacing(t *testing.T) {
	r := newRig(t, transport.KindCloudKit)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"v":0}`))
	ru, saves := r.runFakeSaves(src)
	ru.step(CloudKitSpacing)
	var changes []time.Time
	for i := range 80 { // 8 s in 100 ms steps, an action every 500 ms
		if i%5 == 0 {
			src.set(item("1", fmt.Sprintf(`{"v":%d}`, i+1)))
			changes = append(changes, ru.ft.Now())
			ru.publishNow("target")
		}
		ru.step(100 * time.Millisecond)
	}
	ru.step(CloudKitSpacing)
	got := saves.times()[1:]
	for i := 1; i < len(got); i++ {
		if gap := got[i].Sub(got[i-1]); gap < CloudKitSpacing {
			t.Fatalf("saves %d and %d only %v apart, want at least %v", i-1, i, gap, CloudKitSpacing)
		}
	}
	for _, c := range changes {
		i := sort.Search(len(got), func(i int) bool { return !got[i].Before(c) })
		if i == len(got) || got[i].Sub(c) > CloudKitSpacing {
			t.Fatalf("the change at +%v waited more than %v (saves %v)", c.Sub(changes[0]), CloudKitSpacing, got)
		}
	}
}
