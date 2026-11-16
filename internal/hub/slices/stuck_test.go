package slices

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// #1873: a kind whose save the transport refuses is stuck from its first
// failed attempt until an attempt goes through; the other kinds publishing
// meanwhile do not clear it.
func TestStuckSinceFollowsAFailingKind(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &refusingTransport{Fake: r.tr, refuse: map[string]error{
		r.wireName("owner_ask-1"): transport.ErrRecordTooLarge,
	}}
	ask, target := &fakeSource{kind: "owner_ask"}, &fakeSource{kind: "target"}
	ask.set(item("1", `{"id":1}`))
	target.set(item("1", `{"id":1}`))
	p := r.publisherWith(Config{Transport: tr}, target, ask)
	if _, ok := p.StuckSince(); ok {
		t.Fatal("stuck before any cycle")
	}
	first := r.clock()
	_, _ = p.Cycle(context.Background(), nil)
	if at, ok := p.StuckSince(); !ok || !at.Equal(first) {
		t.Fatalf("StuckSince = %v %v, want %v", at, ok, first)
	}
	if !p.DirtyForTest(KindHeartbeat) {
		t.Fatal("a kind turning stuck did not mark the heartbeat for the next cycle")
	}
	r.advance(time.Minute)
	target.set(item("1", `{"id":2}`))
	_, _ = p.Cycle(context.Background(), nil)
	if at, ok := p.StuckSince(); !ok || !at.Equal(first) {
		t.Fatalf("a later failure moved StuckSince to %v %v", at, ok)
	}
	tr.allow(r.wireName("owner_ask-1"))
	r.advance(time.Minute)
	if _, err := p.Cycle(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if at, ok := p.StuckSince(); ok {
		t.Fatalf("StuckSince = %v after the kind went through", at)
	}
}

// A source that fails keeps its kind stuck; the failure's line names a
// content-free reason and repeats once per window, not every cycle.
func TestStuckSinceCountsAFailedSource(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"id":1}`))
	src.mu.Lock()
	src.err = errors.New("db gone " + logcanary.Text("source"))
	src.mu.Unlock()
	p := r.publisher(src)
	r.cycle(p)
	r.advance(time.Second)
	r.cycle(p)
	if _, ok := p.StuckSince(); !ok {
		t.Fatal("a failed source left its kind not stuck")
	}
	if n := strings.Count(sink.String(), "target source failed (error: untyped)"); n != 1 {
		t.Fatalf("source failure logged %d times in one window, want 1: %q", n, sink.String())
	}
	src.mu.Lock()
	src.err = nil
	src.mu.Unlock()
	r.advance(time.Second)
	r.cycle(p)
	if _, ok := p.StuckSince(); ok {
		t.Fatal("still stuck after the source read")
	}
}

// A record the cycle skips (here oversized) leaves its kind stuck though the
// kind's other records are saved.
func TestStuckSinceCountsASkippedRecord(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: "target"}
	src.set(item("big", `{"title":"`+strings.Repeat("a", secure.MaxEnvelopeBytes)+`"}`), item("1", `{"title":"ok"}`))
	p := r.publisher(src)
	r.cycle(p)
	if at, ok := p.StuckSince(); !ok || !at.Equal(r.clock()) {
		t.Fatalf("StuckSince = %v %v", at, ok)
	}
	src.set(item("big", `{"title":"small"}`), item("1", `{"title":"ok"}`))
	r.advance(time.Minute)
	r.cycle(p)
	if _, ok := p.StuckSince(); ok {
		t.Fatal("still stuck after the record shrank and went")
	}
}

// deleteRefusing answers every Delete with each item refused while refuse is
// set, and passes the rest to the fake.
type deleteRefusing struct {
	*memfake.Fake
	refuse bool
}

func (t *deleteRefusing) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	if !t.refuse {
		return t.Fake.Delete(ctx, zone, items)
	}
	outs := make([]transport.Outcome, len(items))
	for i := range outs {
		outs[i] = transport.Outcome{Refused: transport.ErrForbidden}
	}
	return outs, nil
}

// A record whose delete the transport refuses stays on the phone: its kind
// is stuck until the delete goes through.
func TestStuckSinceCountsARefusedDelete(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	tr := &deleteRefusing{Fake: r.tr}
	src := &fakeSource{kind: "target"}
	src.set(item("1", `{"id":1}`), item("2", `{"id":2}`))
	p := r.publisherWith(Config{Transport: tr}, src)
	if _, err := p.Cycle(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	tr.refuse = true
	src.set(item("1", `{"id":1}`))
	r.advance(time.Minute)
	if _, err := p.Cycle(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if at, ok := p.StuckSince(); !ok || !at.Equal(r.clock()) {
		t.Fatalf("StuckSince = %v %v after a refused delete", at, ok)
	}
	tr.refuse = false
	r.advance(time.Minute)
	if _, err := p.Cycle(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := p.StuckSince(); ok {
		t.Fatal("still stuck after the delete went through")
	}
}

// The heartbeat carries stuck_since while set and restamps at once when it
// changes, not at the next 15 min stamp.
func TestHeartbeatCarriesStuckSince(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var stuck time.Time
	f := heartbeatFacts(func() time.Time { return now }, nil)
	f.StuckSince = func() (time.Time, bool) { return stuck, !stuck.IsZero() }
	src := HeartbeatSource(f)
	clean := onlyItem(t, src).Payload
	if bytes.Contains(clean, []byte("stuck_since")) {
		t.Fatalf("stuck_since present while nothing is stuck: %s", clean)
	}
	now = now.Add(time.Minute)
	stuck = now.Add(-30 * time.Second)
	var hb wire.Heartbeat
	if err := json.Unmarshal(onlyItem(t, src).Payload, &hb); err != nil {
		t.Fatal(err)
	}
	if hb.StuckSince == nil || !hb.StuckSince.Equal(stuck) || !hb.UpdatedAt.Equal(now) {
		t.Fatalf("heartbeat = %+v, want stuck_since %v restamped at %v", hb, stuck, now)
	}
	now = now.Add(time.Minute)
	stuck = time.Time{}
	if got := onlyItem(t, src).Payload; bytes.Contains(got, []byte("stuck_since")) {
		t.Fatalf("stuck_since kept after it cleared: %s", got)
	}
}
