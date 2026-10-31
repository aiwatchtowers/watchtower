package slices

import (
	"bytes"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// switchFake is a recording switch a test flips.
type switchFake struct {
	mu   sync.Mutex
	on   bool
	fail bool
}

func (s *switchFake) read() (bool, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.on, !s.fail
}

func (s *switchFake) set(on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.on = on
}

func capabilitiesOf(t *testing.T, payload []byte) *wire.HeartbeatCapabilities {
	t.Helper()
	var hb wire.Heartbeat
	if err := json.Unmarshal(payload, &hb); err != nil {
		t.Fatal(err)
	}
	return hb.Capabilities
}

func TestHeartbeatCarriesTheRecordingsCapability(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	sw := &switchFake{on: true}
	f := heartbeatFacts(func() time.Time { return now }, nil)
	f.Recordings = sw.read
	src := HeartbeatSource(f)
	on := onlyItem(t, src).Payload
	if c := capabilitiesOf(t, on); c == nil || c.Recordings != "on" {
		t.Fatalf("capabilities = %+v in %s", c, on)
	}
	if !bytes.Contains(on, []byte(`"capabilities":{"recordings":"on"}`)) {
		t.Fatalf("payload %s", on)
	}
	// A switch change restamps the heartbeat at once, no interval wait.
	sw.set(false)
	now = now.Add(time.Second)
	off := onlyItem(t, src).Payload
	if c := capabilitiesOf(t, off); c == nil || c.Recordings != "off" {
		t.Fatalf("capabilities = %+v in %s", c, off)
	}
	// An unreadable switch keeps the value last carried.
	sw.mu.Lock()
	sw.on, sw.fail = true, true
	sw.mu.Unlock()
	now = now.Add(time.Second)
	if got := onlyItem(t, src).Payload; !bytes.Equal(got, off) {
		t.Fatalf("a failed switch read changed the heartbeat: %s", got)
	}
	// Without a switch (no Recordings fact) the heartbeat has no capabilities.
	if c := capabilitiesOf(t, onlyItem(t, HeartbeatSource(heartbeatFacts(func() time.Time { return now }, nil))).Payload); c != nil {
		t.Fatalf("capabilities without a switch: %+v", c)
	}
}

func TestSwitchChangeIsPublishedWithinMaxDebounceWait(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	sw := &switchFake{on: true}
	f := heartbeatFacts(r.clock, nil)
	f.Recordings = sw.read
	ru := r.runFake(HeartbeatSource(f))
	recordings := func() string {
		env, ok := r.live()["heartbeat"]
		if !ok {
			t.Fatal("no heartbeat record")
		}
		c := capabilitiesOf(t, r.opened(env, "heartbeat").Payload)
		if c == nil {
			t.Fatal("heartbeat without capabilities")
		}
		return c.Recordings
	}
	if got := recordings(); got != "on" {
		t.Fatalf("start: recordings %q", got)
	}
	sw.set(false) // `hub recordings off` stores the switch and nudges the heartbeat
	start := ru.ft.Now()
	ru.publishSoon(KindHeartbeat)
	ru.step(MaxDebounceWait)
	if got := recordings(); got != "off" {
		t.Fatalf("after %v: recordings %q, want off", ru.ft.Now().Sub(start), got)
	}
}
