package cloudkit_test

import (
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/transport/cloudkit"
)

// TestRateLimitStartsTheThrottleAndASuccessEndsIt: the first rate_limited
// answer starts ThrottledSince, later ones keep its start, an event with the
// class counts too, and any answered request without it ends it (Settings →
// Mobile's "iCloud is slowing sync down", plan 3 Task 23).
func TestRateLimitStartsTheThrottleAndASuccessEndsIt(t *testing.T) {
	r := newRig(t)
	// A clock that moves one second per read: a later refusal that re-read
	// it would move the start.
	var (
		mu  sync.Mutex
		now = time.Unix(1_800_000_000, 0)
	)
	_ = r.c.Close()
	r.c = cloudkit.New(cloudkit.Config{Dir: r.dir, HubID: r.hub, RelayID: relayID, Clock: func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		now = now.Add(time.Second)
		return now
	}})
	t.Cleanup(func() { _ = r.c.Close() })
	if !r.c.ThrottledSince().IsZero() {
		t.Fatal("throttled before any answer")
	}
	r.fake.FailNext("changes", "rate_limited")
	_, _ = r.c.Changes(r.ctx, dataZone, 0)
	first := r.c.ThrottledSince()
	if first.IsZero() {
		t.Fatal("a rate_limited answer did not start the throttle")
	}
	r.fake.FailNext("changes", "rate_limited")
	_, _ = r.c.Changes(r.ctx, dataZone, 0)
	if got := r.c.ThrottledSince(); !got.Equal(first) {
		t.Fatalf("a later refusal moved the start: %v, want %v", got, first)
	}
	r.fake.FailNext("changes", "unavailable")
	_, _ = r.c.Changes(r.ctx, dataZone, 0)
	if !r.c.ThrottledSince().IsZero() {
		t.Fatal("another failure class kept the throttle")
	}
	r.fake.FailNext("changes", "rate_limited")
	_, _ = r.c.Changes(r.ctx, dataZone, 0)
	if _, err := r.c.Changes(r.ctx, dataZone, 0); err != nil {
		t.Fatal(err)
	}
	if !r.c.ThrottledSince().IsZero() {
		t.Fatal("a success did not end the throttle")
	}
}
