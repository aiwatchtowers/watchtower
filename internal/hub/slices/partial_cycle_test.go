package slices

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// refusingTransport refuses every Save carrying the wire name it is given
// (a record the relay will not take, whatever the batch), and passes the
// rest to the fake.
type refusingTransport struct {
	*memfake.Fake
	mu     sync.Mutex
	refuse map[string]error
}

func (t *refusingTransport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	t.mu.Lock()
	for _, it := range items {
		if err, ok := t.refuse[it.Record.WireName()]; ok {
			t.mu.Unlock()
			return nil, err
		}
	}
	t.mu.Unlock()
	return t.Fake.Save(ctx, items)
}

func (t *refusingTransport) allow(wire string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.refuse, wire)
}

// #1761: a kind the transport refuses does not stop the cycle: the kinds
// after it are published, only it is unfinished, the cycle still errors
// (the caller logs and backs off) and LastPublishAt moves (the hub is
// publishing).
func TestCycleFailedKindDoesNotStopTheRest(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &refusingTransport{Fake: r.tr, refuse: map[string]error{
		r.wireName("owner_ask-1"): transport.ErrRecordTooLarge,
	}}
	ask, target := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"id":1}`))
	p := r.publisherWith(Config{Transport: tr}, target, ask)
	rep, err := p.Cycle(context.Background(), nil)
	if !errors.Is(err, transport.ErrRecordTooLarge) {
		t.Fatalf("Cycle error = %v, want record_too_large", err)
	}
	if !slices.Equal(rep.Unfinished, []Kind{"owner_ask"}) || !errors.Is(rep.Errors["owner_ask"], transport.ErrRecordTooLarge) {
		t.Fatalf("Cycle = %+v", rep)
	}
	if _, ok := r.live()[r.wireName("target-1")]; !ok {
		t.Fatal("target, after the refused kind, not published")
	}
	if at, ok := p.LastPublishAt(); !ok || !at.Equal(r.clock()) {
		t.Fatalf("LastPublishAt = %v %v after a partial cycle", at, ok)
	}
}

// A cycle that finished no kind it tried (every save refused) leaves
// LastPublishAt where it was: a broken hub is not hidden.
func TestCycleFinishingNothingKeepsLastPublish(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &refusingTransport{Fake: r.tr, refuse: map[string]error{
		r.wireName("target-1"): transport.ErrHubQuota,
	}}
	target := &fakeSource{kind: "target"}
	target.set(item("1", `{"id":1}`))
	p := r.publisherWith(Config{Transport: tr}, target)
	if _, err := p.Cycle(context.Background(), nil); !errors.Is(err, transport.ErrHubQuota) {
		t.Fatalf("Cycle = %v", err)
	}
	if at, ok := p.LastPublishAt(); ok {
		t.Fatalf("LastPublishAt = %v after a cycle that published nothing", at)
	}
}

// The relay closing mid-way (unavailable) still ends the cycle: the kinds
// after the failure would fail the same way and wait for the retry.
func TestCycleUnavailableTransportStopsTheCycle(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	ask, target := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"id":1}`))
	r.tr.FailNext("save", transport.ErrUnavailable)
	rep, err := r.publisher(target, ask).Cycle(context.Background(), nil)
	if !errors.Is(err, transport.ErrUnavailable) || !slices.Equal(rep.Unfinished, []Kind{"owner_ask", "target"}) {
		t.Fatalf("Cycle = %+v %v", rep, err)
	}
	if len(target.readTimes()) != 0 {
		t.Fatal("target read after the transport went down")
	}
}

// An epoch rotation still aborts the cycle after an earlier kind failed:
// the rotated kind and every later one are unfinished, the earlier failure
// is still returned.
func TestCycleEpochMoveStillAbortsAfterAFailure(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &refusingTransport{Fake: r.tr, refuse: map[string]error{
		r.wireName("owner_ask-1"): transport.ErrRecordTooLarge,
	}}
	ask, target, workbench := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}, &fakeSource{kind: "workbench"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"id":1}`))
	workbench.set(item("1", `{"id":1}`))
	target.during = func() {
		target.mu.Lock()
		target.during = nil
		target.mu.Unlock()
		if err := r.kr.Rotate(identity.ReasonManual); err != nil {
			t.Error(err)
		}
	}
	rep, err := r.publisherWith(Config{Transport: tr}, ask, target, workbench).Cycle(context.Background(), nil)
	if !errors.Is(err, transport.ErrRecordTooLarge) || !rep.Aborted {
		t.Fatalf("Cycle = %+v %v", rep, err)
	}
	if !slices.Contains(rep.Unfinished, "owner_ask") || !slices.Contains(rep.Unfinished, "target") {
		t.Fatalf("Unfinished = %v", rep.Unfinished)
	}
	if hashes, _ := r.st.SliceHashes("target"); len(hashes) != 0 {
		t.Fatalf("target recorded across a rotation: %v", hashes)
	}
}

// A kind refused with a permanent class backs off on its own clock, past
// RetryMax, while another kind's successes do not reset it; once the
// transport takes it, it goes at its next retry.
func TestPermanentFailureBacksOffPerKind(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	askWire := r.wireName("owner_ask-1")
	tr := &refusingTransport{Fake: r.tr, refuse: map[string]error{askWire: transport.ErrRecordTooLarge}}
	ask, target := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"v":0}`))
	ft := newFakeTime()
	p := r.publisherWith(Config{Clock: ft.Now, Transport: tr}, ask, target)
	p.mono, p.timer = ft.Now, ft.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			t.Errorf("Run = %v", err)
		}
	})
	ru := &runner{t: t, ft: ft, p: p}
	ru.settle(0)
	if _, ok := r.live()[r.wireName("target-1")]; !ok {
		t.Fatal("target not published beside the refused ask")
	}
	// Retries at +1, +2, +4, +8, +16 s from each failure: the gaps double
	// past RetryMax, and the target's own saves in between change nothing.
	elapsed := time.Duration(0)
	for i, gap := range []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second} {
		for range int(gap / time.Second) {
			elapsed += time.Second
			target.set(item("1", fmt.Sprintf(`{"v":%d}`, elapsed/time.Second)))
			ru.publishNow("target")
			ru.step(time.Second)
		}
		if n := len(ask.readTimes()); n != i+2 {
			t.Fatalf("after %v: ask read %d times, want %d", elapsed, n, i+2)
		}
	}
	if n := len(ask.readTimes()); n != 6 {
		t.Fatalf("ask read %d times in %v", n, elapsed)
	}
	tr.allow(askWire)
	for range 32 {
		ru.step(time.Second)
	}
	if _, ok := r.live()[askWire]; !ok {
		t.Fatal("ask not published once the transport took it")
	}
}

func TestRetryWaitPermanentCap(t *testing.T) {
	var b time.Duration
	var d time.Duration
	for range 20 {
		d = retryWait(transport.ErrRecordTooLarge, &b)
	}
	if d != RetryPermanentMax {
		t.Fatalf("record_too_large backoff tops out at %v, want %v", d, RetryPermanentMax)
	}
	b = 0
	for range 20 {
		d = retryWait(transport.ErrForbidden, &b)
	}
	if d != RetryMax {
		t.Fatalf("forbidden backoff tops out at %v, want %v", d, RetryMax)
	}
}

// hub_quota keeps the short backoff (the zone frees as records go) and, as
// a zone-wide refusal, still ends the cycle: the status's quota flag stays
// until a retry's save takes.
func TestRetryWaitHubQuotaIsNotPermanent(t *testing.T) {
	if !cycleWide(transport.ErrHubQuota) || cycleWide(transport.ErrRecordTooLarge) {
		t.Fatal("hub_quota must end the cycle, record_too_large must not")
	}
	var b, d time.Duration
	for range 20 {
		d = retryWait(transport.ErrHubQuota, &b)
	}
	if d != RetryMax {
		t.Fatalf("hub_quota backoff tops out at %v, want %v", d, RetryMax)
	}
}

// A kind the cycle never tried backs off by what stopped the cycle, not by
// an earlier kind's permanent class: after owner_ask's record_too_large and
// target's unavailable, workbench caps at RetryMax, not RetryPermanentMax.
// An epoch abort leaves the untried kinds on the plain backoff.
func TestUntriedKindsBackOffByTheCycleStop(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &refusingTransport{Fake: r.tr, refuse: map[string]error{
		r.wireName("owner_ask-1"): transport.ErrRecordTooLarge,
		r.wireName("target-1"):    transport.ErrUnavailable,
	}}
	ask, target, workbench := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}, &fakeSource{kind: "workbench"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"id":1}`))
	workbench.set(item("1", `{"id":1}`))
	rep, err := r.publisherWith(Config{Transport: tr}, ask, target, workbench).Cycle(context.Background(), nil)
	if !errors.Is(err, transport.ErrRecordTooLarge) || !slices.Equal(rep.Unfinished, []Kind{"owner_ask", "target", "workbench"}) {
		t.Fatalf("Cycle = %+v %v", rep, err)
	}
	kerr := rep.retryErr("workbench", err)
	if !errors.Is(kerr, transport.ErrUnavailable) || errors.Is(kerr, transport.ErrRecordTooLarge) {
		t.Fatalf("workbench backs off by %v, want the stop's unavailable", kerr)
	}
	var backoff time.Duration
	for range 10 {
		retryWait(kerr, &backoff)
	}
	if backoff != RetryMax {
		t.Fatalf("workbench backoff %v, want the %v cap", backoff, RetryMax)
	}
	if e := rep.retryErr("owner_ask", err); !errors.Is(e, transport.ErrRecordTooLarge) {
		t.Fatalf("owner_ask backs off by %v", e)
	}
	aborted := CycleReport{Aborted: true, Errors: map[Kind]error{"owner_ask": transport.ErrRecordTooLarge}}
	if e := aborted.retryErr("target", transport.ErrRecordTooLarge); e != nil {
		t.Fatalf("after an epoch abort target backs off by %v, want the plain backoff", e)
	}
}

// kindSwitchTransport is the fake with a Kind the test changes, as the
// switcher's front changes its active transport.
type kindSwitchTransport struct {
	*memfake.Fake
	mu   sync.Mutex
	kind transport.Kind
}

func (t *kindSwitchTransport) Kind() transport.Kind {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.kind
}

func (t *kindSwitchTransport) switchTo(k transport.Kind) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.kind = k
}

// A resume after a transport switch drops the retries of the old one: a
// kind backed off there is read at once by the resume's full diff, and its
// next failure starts the backoff over (RetryFirst, not the doubled wait).
func TestResumeAfterASwitchDropsTheOldTransportsRetries(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &kindSwitchTransport{Fake: r.tr, kind: transport.KindRelay}
	held, other := &fakeSource{kind: "target"}, &fakeSource{kind: "workbench"}
	held.set(item("1", `{"v":0}`))
	other.set(item("1", `{"v":0}`))
	ft := newFakeTime()
	p := r.publisherWith(Config{Clock: ft.Now, Transport: tr}, held, other)
	p.mono, p.timer = ft.Now, ft.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			t.Errorf("Run = %v", err)
		}
	})
	ru := &runner{t: t, ft: ft, p: p}
	ru.settle(0)
	ru.step(RelaySpacing)
	r.tr.FailNext("save", transport.ErrUnavailable)
	r.tr.FailNext("save", transport.ErrUnavailable)
	held.set(item("1", `{"v":1}`))
	ru.publishNow("target") // fails: retried in 1 s
	ru.step(RetryFirst)     // fails again: held for 2 s
	if n := len(held.readTimes()); n != 3 {
		t.Fatalf("held kind read %d times before the switch, want 3", n)
	}
	p.Pause()
	tr.switchTo(transport.KindCloudKit)
	r.tr.FailNext("save", transport.ErrUnavailable)
	n := ft.armedCount()
	p.Resume()
	ru.settle(n)
	if n := len(held.readTimes()); n != 4 {
		t.Fatalf("Resume after a switch read the held kind %d times, want 4", n)
	}
	ru.step(RetryFirst - time.Millisecond)
	if n := len(held.readTimes()); n != 4 {
		t.Fatalf("held kind read %d times inside the fresh backoff", n)
	}
	ru.step(time.Millisecond)
	if _, ok := r.live()[r.wireName("target-1")]; !ok {
		t.Fatal("held kind not saved at its fresh RetryFirst retry")
	}
}

// partialSaveTransport saves the first half of the next batch it is armed
// for and then fails the call, as the relay transport does when a later
// request fails.
type partialSaveTransport struct {
	*memfake.Fake
	mu    sync.Mutex
	armed bool
}

func (t *partialSaveTransport) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	t.mu.Lock()
	armed := t.armed
	t.armed = false
	t.mu.Unlock()
	if !armed || len(items) < 2 {
		return t.Fake.Save(ctx, items)
	}
	if _, err := t.Fake.Save(ctx, items[:len(items)/2]); err != nil {
		return nil, err
	}
	return nil, transport.ErrUnavailable
}

// A Save that saves part of the batch and then fails leaves the kind
// unfinished, reports the error and records no hash; the next cycle saves
// the whole batch again and records it.
func TestPartlySavedThenFailedKindIsRetried(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &partialSaveTransport{Fake: r.tr, armed: true}
	target := &fakeSource{kind: "target"}
	target.set(item("1", `{"id":1}`), item("2", `{"id":2}`), item("3", `{"id":3}`), item("4", `{"id":4}`))
	ft := newFakeTime()
	seen := make(chan error, 4)
	p := r.publisherWith(Config{Clock: ft.Now, Transport: tr, OnError: func(err error) { seen <- err }}, target)
	p.mono, p.timer = ft.Now, ft.Timer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- p.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; !errors.Is(err, context.Canceled) {
			t.Errorf("Run = %v", err)
		}
	})
	ru := &runner{t: t, ft: ft, p: p}
	ru.settle(0) // the start cycle: half saved, then the failure
	if err := <-seen; !errors.Is(err, transport.ErrUnavailable) {
		t.Fatalf("OnError got %v", err)
	}
	live := r.live()
	if _, ok := live[r.wireName("target-1")]; !ok {
		t.Fatal("the first half not in the zone")
	}
	if _, ok := live[r.wireName("target-4")]; ok {
		t.Fatal("the second half in the zone after the failure")
	}
	if hashes, _ := r.st.SliceHashes("target"); len(hashes) != 0 {
		t.Fatalf("hashes recorded for a failed save: %v", hashes)
	}
	ru.step(RetryFirst)
	live = r.live()
	for i := 1; i <= 4; i++ {
		if _, ok := live[r.wireName(fmt.Sprintf("target-%d", i))]; !ok {
			t.Fatalf("target-%d not saved by the retry", i)
		}
	}
	if hashes, _ := r.st.SliceHashes("target"); len(hashes) != 4 {
		t.Fatalf("%d hashes after the retry, want 4", len(hashes))
	}
}
