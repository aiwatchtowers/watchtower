package slices

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
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
