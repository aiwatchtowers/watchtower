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

func (s *saveTimes) NudgeCycleDone(_, _ string, _, _ time.Time) {}

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
	ft.drive(p)
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
	limited := rateLimited
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

// rateLimited is the relay's RATE_LIMITED with retry_after_s.
func rateLimited(after uint32) error {
	return relay.MapError(&client.Error{E: &relayv1.Error{
		Code: relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, RetryAfterS: &after,
	}})
}

// A kind held by the relay's retry_after_s stays unsent across the periodic
// full diff, which still publishes every other kind.
func TestFullDiffKeepsARetryHold(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	held, other := &fakeSource{kind: "target"}, &fakeSource{kind: "workbench"}
	held.set(item("1", `{"v":0}`))
	other.set(item("1", `{"v":0}`))
	ru := r.runFake(held, other)
	ru.step(FullDiffEvery - time.Second)
	r.tr.FailNext("save", rateLimited(30))
	held.set(item("1", `{"v":1}`))
	ru.publishNow("target") // fails at 59 s: held until 89 s
	other.set(item("1", `{"v":1}`))
	ru.step(time.Second) // the full diff at 60 s
	if n := len(other.readTimes()); n != 2 {
		t.Fatalf("the other kind read %d times by the full diff, want 2", n)
	}
	if n := len(held.readTimes()); n != 2 {
		t.Fatalf("the held kind read %d times by the full diff, want 2 (start + the failed save)", n)
	}
	ru.step(29*time.Second - time.Millisecond)
	if n := len(held.readTimes()); n != 2 {
		t.Fatalf("the held kind read %d times before its retry_after_s ran out", n)
	}
	ru.step(time.Millisecond)
	if n := len(held.readTimes()); n != 3 {
		t.Fatalf("the held kind read %d times when its hold ran out, want 3", n)
	}
}

// Resume's full diff does not lift a retry hold either.
func TestResumeKeepsARetryHold(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	held, other := &fakeSource{kind: "target"}, &fakeSource{kind: "workbench"}
	held.set(item("1", `{"v":0}`))
	other.set(item("1", `{"v":0}`))
	ru := r.runFake(held, other)
	ru.step(RelaySpacing)
	r.tr.FailNext("save", rateLimited(30))
	held.set(item("1", `{"v":1}`))
	ru.publishNow("target") // held for 30 s
	ru.p.Pause()
	ru.step(time.Second)
	n := ru.ft.armedCount()
	ru.p.Resume()
	ru.settle(n)
	if n := len(other.readTimes()); n != 2 {
		t.Fatalf("the other kind read %d times by Resume's full diff, want 2", n)
	}
	if n := len(held.readTimes()); n != 2 {
		t.Fatalf("Resume read the held kind: %d reads, want 2", n)
	}
	ru.step(29 * time.Second)
	if n := len(held.readTimes()); n != 3 {
		t.Fatalf("the held kind read %d times when its hold ran out, want 3", n)
	}
}

// kindSaves records the kinds the publisher saved, in order.
type kindSaves struct {
	mu    sync.Mutex
	kinds []Kind
}

// NudgeCycleDone completes SaveLatency (Task 3); these tests count saves only.
func (s *kindSaves) NudgeCycleDone(_, _ string, _, _ time.Time) {}

func (s *kindSaves) Saved(_, kind string, _, _ time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.kinds = append(s.kinds, Kind(kind))
}

// A PublishNow that arrives while a full cycle runs is taken between kinds:
// the nudged kind is the next one saved, not the last of the cycle.
func TestPublisher_PublishNowJoinsRunningCycle(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	saves := &kindSaves{}
	var sources []Source
	srcs := map[Kind]*fakeSource{}
	for _, k := range AllKinds {
		s := &fakeSource{kind: k}
		s.set(item("1", `{"v":1}`))
		srcs[k] = s
		sources = append(sources, s)
	}
	p := r.publisherWith(Config{Latency: saves}, sources...)
	order := p.sourceKinds()
	if len(order) < 34 {
		t.Fatalf("%d kinds with a source, want the full set", len(order))
	}
	late := order[len(order)-1]
	// The hook runs while the cycle is on its first kinds; saved counts the
	// kinds finished by then (the one being read is the next to finish).
	saved := -1
	srcs[order[1]].during = func() {
		saves.mu.Lock()
		saved = len(saves.kinds)
		saves.mu.Unlock()
		p.PublishNow(late)
	}
	if _, err := p.Cycle(context.Background(), nil); err != nil {
		t.Fatalf("Cycle: %v", err)
	}
	got := saves.kinds
	at := slices.Index(got, late)
	if saved < 0 || at < 0 || at > saved+1 {
		t.Fatalf("saved order %v (nudged after %d saves), want %s as the next kind", got, saved, late)
	}
	if n := slices.Index(got[at+1:], late); n >= 0 {
		t.Fatalf("%s saved twice in one cycle: %v", late, got)
	}
	if p.DirtyForTest(late) {
		t.Fatalf("%s still waits for a publish after the cycle took it", late)
	}
}

// midCycleRig is a publisher over a source for every kind; hook runs inside
// the read of the kind at index at of the publish order.
func midCycleRig(t *testing.T, at int, hook func(p *Publisher, order []Kind)) (*rig, *Publisher, []Kind, *kindSaves) {
	t.Helper()
	r := newRig(t, transport.KindRelay)
	saves := &kindSaves{}
	var sources []Source
	srcs := map[Kind]*fakeSource{}
	for _, k := range AllKinds {
		s := &fakeSource{kind: k}
		s.set(item("1", `{"v":1}`))
		srcs[k] = s
		sources = append(sources, s)
	}
	p := r.publisherWith(Config{Latency: saves}, sources...)
	order := p.sourceKinds()
	srcs[order[at]].during = func() { hook(p, order) }
	return r, p, order, saves
}

func (s *kindSaves) has(k Kind) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Contains(s.kinds, k)
}

// A kind Run still holds (a retry or spacing that has not run out) is not
// taken mid-cycle: it waits for its time, dirty.
func TestPublisher_PublishNowHeldKindNotTakenMidCycle(t *testing.T) {
	_, p, order, saves := midCycleRig(t, 1, func(p *Publisher, order []Kind) { p.PublishNow(order[5]) })
	late := order[5]
	p.setHolds(map[Kind]time.Time{late: time.Now().Add(time.Hour)})
	if _, err := p.Cycle(context.Background(), order[:3]); err != nil {
		t.Fatalf("Cycle: %v", err)
	}
	if saves.has(late) || !p.DirtyForTest(late) {
		t.Fatalf("held %s: saved %v, dirty %v; want not saved and still dirty", late, saves.has(late), p.DirtyForTest(late))
	}
}

// A kind already tried this cycle is not tried again by a nudge: it stays
// dirty for Run.
func TestPublisher_PublishNowKindAlreadyTriedLeftForRun(t *testing.T) {
	_, p, _, saves := midCycleRig(t, slices.Index(publishOrder, "target"), func(p *Publisher, _ []Kind) { p.PublishNow("owner_ask") })
	if _, err := p.Cycle(context.Background(), []Kind{"owner_ask", "target", "track"}); err != nil {
		t.Fatalf("Cycle: %v", err)
	}
	n := 0
	for _, k := range saves.kinds {
		if k == "owner_ask" {
			n++
		}
	}
	if n != 1 || !p.DirtyForTest("owner_ask") {
		t.Fatalf("owner_ask saved %d times, dirty %v; want once and still dirty", n, p.DirtyForTest("owner_ask"))
	}
}

// With no phone linked a cycle may take only the unlinked kinds mid-cycle.
func TestJoinableHonoursTheLinkState(t *testing.T) {
	if joinable(false, "target") || !joinable(false, KindDeviceGrant) || !joinable(true, "target") {
		t.Fatal("joinable: want only the unlinked kinds without a phone, any kind with one")
	}
}

// runFakeKinds is runFake with the saved kinds recorded in order.
func (r *rig) runFakeKinds(sources ...Source) (*runner, *kindSaves) {
	r.t.Helper()
	ft := newFakeTime()
	saves := &kindSaves{}
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
	ru.settle(0)
	return ru, saves
}

func (s *kindSaves) list() []Kind {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.kinds)
}

// A kind whose hold runs out while a cycle runs and that is nudged then
// joins that cycle ahead of the kinds still waiting in it, and is settled
// like the rest (a later failure backs off from the first step).
func TestPublisher_JoinedKindSettledLikeTheRest(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	a := &fakeSource{kind: "owner_ask"}
	x := &fakeSource{kind: "target"}
	y := &fakeSource{kind: "track"}
	x.set(item("1", `{"v":1}`))
	ru, saves := r.runFakeKinds(a, x, y)
	ru.step(RelaySpacing)
	x.set(item("1", `{"v":9}`))
	r.tr.FailNext("save", transport.ErrUnavailable)
	ru.publishNow("target") // x's save fails: held for RetryFirst, backoff set
	a.set(item("1", `{"v":1}`))
	y.set(item("1", `{"v":1}`))
	fired := false
	a.during = func() {
		if fired {
			return
		}
		fired = true
		ru.ft.advance(RetryFirst) // x's hold runs out while the cycle runs
		ru.p.PublishNow("target")
	}
	n := ru.ft.armedCount()
	ru.p.PublishNow("owner_ask", "track")
	ru.settle(n)
	got := saves.list()
	if len(got) < 3 || !slices.Equal(got[len(got)-3:], []Kind{"owner_ask", "target", "track"}) {
		t.Fatalf("saved %v, want target joined between owner_ask and track", got)
	}
	ru.step(RelaySpacing)
	ru.step(RelaySpacing)
	ru.step(RelaySpacing)
	x.set(item("1", `{"v":2}`))
	r.tr.FailNext("save", transport.ErrUnavailable)
	ru.publishNow("target")
	failed := len(x.readTimes())
	ru.step(RetryFirst)
	if n := len(x.readTimes()); n != failed+1 {
		t.Fatalf("x read %d times after the retry wait, want %d: it kept the stale doubled backoff", n, failed+1)
	}
}

// A joined kind that the spacing defers keeps a hold and is published when
// the spacing ends, not at the next full diff.
func TestPublisher_JoinedKindDeferredBySpacingKeepsItsHold(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	a := &fakeSource{kind: "owner_ask"}
	x := &fakeSource{kind: "target"}
	x.set(item("1", `{"v":1}`))
	y := &fakeSource{kind: "track"}
	ru, saves := r.runFakeKinds(a, x, y) // x saved at start: its spacing runs
	a.set(item("1", `{"v":1}`))
	y.set(item("1", `{"v":1}`))
	fired := false
	a.during = func() {
		if fired {
			return
		}
		fired = true
		x.set(item("1", `{"v":2}`))
		ru.p.PublishNow("target")
	}
	n := ru.ft.armedCount()
	ru.p.PublishNow("owner_ask", "track") // track follows owner_ask: x joins before it
	ru.settle(n)
	before := len(saves.list())
	ru.step(RelaySpacing)
	if got := saves.list(); len(got) != before+1 || got[len(got)-1] != "target" {
		t.Fatalf("saved %v after the spacing, want target published then", got)
	}
}
