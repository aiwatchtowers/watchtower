package slices

import (
	"context"
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// Go twins of HubHeartbeatTests' stop, clock and timing tests and of
// MobileHubServiceTests.testRejectedDataRecordClearsItsHash.

// ctxBlindTransport saves whatever ctx says, so a test sees what the
// publisher itself does after a stop (memfake would refuse on its own).
type ctxBlindTransport struct{ *memfake.Fake }

func (b ctxBlindTransport) Save(_ context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	return b.Fake.Save(context.Background(), items)
}

// heldAccounts is an accounts read that ignores ctx and, while held, waits
// for release after saying it arrived.
type heldAccounts struct {
	held             bool
	arrived, release chan struct{}
}

func newHeldAccounts(held bool) *heldAccounts {
	return &heldAccounts{held: held, arrived: make(chan struct{}), release: make(chan struct{})}
}

func (h *heldAccounts) read(context.Context) ([]wire.HeartbeatAccount, error) {
	if h.held {
		close(h.arrived)
		<-h.release
	}
	return []wire.HeartbeatAccount{{Kind: "slack", Label: "acme", Status: "ok"}}, nil
}

func (r *rig) blindPublisher(src Source) *Publisher {
	return NewPublisher(Config{
		Store: r.st, Transport: ctxBlindTransport{r.tr}, Sealer: secure.NewSealer(r.kr), DataZone: testZone,
		Sources: []Source{src}, Clock: r.clock,
		Linked: func() (bool, error) { return true, nil },
	})
}

// stopDuringRead runs one cycle, stops it while the accounts read is held,
// then lets the read return.
func stopDuringRead(t *testing.T, p *Publisher, acc *heldAccounts) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := p.Cycle(ctx, nil)
		done <- err
	}()
	<-acc.arrived
	cancel()
	close(acc.release)
	if err := <-done; err == nil {
		t.Fatal("a stopped cycle reported success")
	}
}

// twin of HubHeartbeatTests.testAStopDuringATicksAccountsReadWritesNothing
func TestAStopDuringAHeartbeatAccountsReadWritesNothing(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	acc := newHeldAccounts(false)
	p := r.blindPublisher(HeartbeatSource(heartbeatFacts(r.clock, acc.read)))
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("first cycle = %+v", rep)
	}
	frames := len(r.tr.Frames())

	acc.held = true
	r.advance(HeartbeatInterval) // the tick's restamp is due
	stopDuringRead(t, p, acc)

	if n := len(r.tr.Frames()) - frames; n != 0 {
		t.Fatalf("a stopped hub wrote %d heartbeats", n)
	}
}

// twin of HubHeartbeatTests.testAStopDuringTheFirstHeartbeatsAccountsReadWritesNothing
// (the heartbeat half; enabled_at is stamped at the hub's start in Go).
func TestAStopDuringTheFirstHeartbeatsAccountsReadWritesNothing(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	acc := newHeldAccounts(true)
	p := r.blindPublisher(HeartbeatSource(heartbeatFacts(r.clock, acc.read)))

	stopDuringRead(t, p, acc)

	if _, ok := r.live()["heartbeat"]; ok {
		t.Fatal("a stopped start wrote the heartbeat")
	}
	if hashes, err := r.st.SliceHashes(string(KindHeartbeat)); err != nil || len(hashes) != 0 {
		t.Fatalf("slice state = %v, %v", hashes, err)
	}
}

// stopAfterWrite stops the cycle (cancels its ctx) right after each Save or
// Delete went through: the hub stopped between a write and its bookkeeping.
type stopAfterWrite struct {
	*memfake.Fake
	stop context.CancelFunc
}

func (s stopAfterWrite) Save(ctx context.Context, items []transport.SaveItem) ([]transport.Outcome, error) {
	defer s.stop()
	return s.Fake.Save(ctx, items)
}

func (s stopAfterWrite) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	defer s.stop()
	return s.Fake.Delete(ctx, zone, items)
}

// A stop between a write and its bookkeeping still records it: a saved
// record slice_state does not name is out of reach of every later delete
// (the policy wipe of a stopped hub left it in the zone, #1756), and a
// deleted one stays forgotten.
func TestAStopAfterAWriteStillRecordsIt(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "workbench"}
	src.set(item("1", `{"id":1}`))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := r.publisherWith(Config{Transport: stopAfterWrite{Fake: r.tr, stop: cancel}}, src)
	_, _ = p.Cycle(ctx, nil) // stopped after its save: the error is ctx's
	if _, ok := r.live()[r.wireName("workbench-1")]; !ok {
		t.Fatal("the save did not go out")
	}
	if hashes, err := r.st.SliceHashes("workbench"); err != nil || hashes["workbench-1"].WireName == "" {
		t.Fatalf("a saved record is not in slice state: %v, %v", hashes, err)
	}

	src.set()
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	p = r.publisherWith(Config{Transport: stopAfterWrite{Fake: r.tr, stop: cancel}}, src)
	_, _ = p.Cycle(ctx, nil)
	if _, ok := r.live()[r.wireName("workbench-1")]; ok {
		t.Fatal("the delete did not go out")
	}
	if hashes, err := r.st.SliceHashes("workbench"); err != nil || len(hashes) != 0 {
		t.Fatalf("a deleted record is still in slice state: %v, %v", hashes, err)
	}
}

// twin of HubHeartbeatTests.testLastPublishAtComesFromTheInjectedClock
func TestLastPublishAtComesFromTheInjectedClock(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	p := r.publisher()
	if _, ok := p.LastPublishAt(); ok {
		t.Fatal("a last publish before any cycle")
	}
	r.cycle(p)
	if at, ok := p.LastPublishAt(); !ok || !at.Equal(r.clock()) {
		t.Fatalf("LastPublishAt = %v %v, want %v", at, ok, r.clock())
	}
}

// twin of HubHeartbeatTests.testPinnedHeartbeatTiming (the interval; the
// Swift three-failed-ticks stop has no Go counterpart, see the T24 report).
func TestPinnedHeartbeatTiming(t *testing.T) {
	if HeartbeatInterval != 15*time.Minute {
		t.Fatalf("HeartbeatInterval = %v", HeartbeatInterval)
	}
	// The phone calls a hub offline after 35 min: two missed restamps
	// must not reach it.
	if 2*HeartbeatInterval >= 35*time.Minute {
		t.Fatal("two restamps outlast the phone's offline threshold")
	}
}

// twin of MobileHubServiceTests.testRejectedDataRecordClearsItsHash: the
// transport answers each save per record, so a refused record never gets
// its new hash and goes out again at the next cycle; the others keep theirs.
func TestARefusedRecordKeepsNoNewHashAndIsResaved(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "workbench"}
	src.set(item("1", `{"id":1}`), item("2", `{"id":2}`))
	p := r.publisher(src)
	if rep := r.cycle(p); rep.Saved != 2 {
		t.Fatalf("first cycle = %+v", rep)
	}
	before, err := r.st.SliceHashes("workbench")
	if err != nil {
		t.Fatal(err)
	}

	src.set(item("1", `{"id":1,"name":"b"}`), item("2", `{"id":2}`))
	r.tr.RefuseWrites(testZone, transport.ErrForbidden)
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 0 || !slices.Contains(rep.Skipped, "workbench-1") {
		t.Fatalf("refused cycle = %+v", rep)
	}
	after, err := r.st.SliceHashes("workbench")
	if err != nil {
		t.Fatal(err)
	}
	if after["workbench-1"].Hash != before["workbench-1"].Hash || after["workbench-2"].Hash != before["workbench-2"].Hash {
		t.Fatalf("a refused save changed the hashes: %+v → %+v", before, after)
	}

	r.tr.RefuseWrites(testZone, nil)
	r.advance(time.Second)
	if rep := r.cycle(p); rep.Saved != 1 {
		t.Fatalf("after the refusal = %+v, want only workbench-1 resaved", rep)
	}
}
