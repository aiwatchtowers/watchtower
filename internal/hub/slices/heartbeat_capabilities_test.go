package slices

import (
	"bytes"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

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
	var on atomic.Bool
	on.Store(true)
	f := heartbeatFacts(func() time.Time { return now }, nil)
	f.Recordings = on.Load
	src := HeartbeatSource(f)
	first := onlyItem(t, src).Payload
	if !bytes.Contains(first, []byte(`"capabilities":{"recordings":"on"}`)) {
		t.Fatalf("payload %s", first)
	}
	// A switch change restamps the heartbeat at once, no interval wait.
	on.Store(false)
	now = now.Add(time.Second)
	if c := capabilitiesOf(t, onlyItem(t, src).Payload); c == nil || c.Recordings != "off" {
		t.Fatalf("capabilities = %+v", c)
	}
	// Without a switch (no Recordings fact) the heartbeat has no capabilities.
	if c := capabilitiesOf(t, onlyItem(t, HeartbeatSource(heartbeatFacts(func() time.Time { return now }, nil))).Payload); c != nil {
		t.Fatalf("capabilities without a switch: %+v", c)
	}
}

func TestSwitchChangeIsPublishedWithinMaxDebounceWait(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	var on atomic.Bool
	on.Store(true)
	f := heartbeatFacts(r.clock, nil)
	f.Recordings = on.Load
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
	on.Store(false) // `hub recordings off` stores the switch and nudges the heartbeat
	start := ru.ft.Now()
	ru.publishSoon(KindHeartbeat)
	ru.step(MaxDebounceWait)
	if got := recordings(); got != "off" {
		t.Fatalf("after %v: recordings %q, want off", ru.ft.Now().Sub(start), got)
	}
}
