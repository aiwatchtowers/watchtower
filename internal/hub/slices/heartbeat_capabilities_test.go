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

// TestHeartbeatCarriesTheInboxCapability: "on" while the Inbox is
// published, "policy_off" with the reason "policy" under workbench_only, a
// change restamps at once, and no Inbox fact leaves the key out (an older
// hub).
func TestHeartbeatCarriesTheInboxCapability(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var on atomic.Bool
	on.Store(true)
	f := heartbeatFacts(func() time.Time { return now }, nil)
	f.Inbox = on.Load
	src := HeartbeatSource(f)
	if p := onlyItem(t, src).Payload; !bytes.Contains(p, []byte(`"capabilities":{"inbox":"on"}`)) {
		t.Fatalf("payload %s", p)
	}
	on.Store(false)
	now = now.Add(time.Second)
	if p := onlyItem(t, src).Payload; !bytes.Contains(p, []byte(`"capabilities":{"inbox":"policy_off","inbox_reason":"policy"}`)) {
		t.Fatalf("payload %s", p)
	}
	if c := capabilitiesOf(t, onlyItem(t, HeartbeatSource(heartbeatFacts(func() time.Time { return now }, nil))).Payload); c != nil {
		t.Fatalf("capabilities without an Inbox fact: %+v", c)
	}
}

// TestHeartbeatCarriesTheHubKind: the hub kind goes out as hub_kind (#1783);
// no kind fact leaves the key out, as an older hub does.
func TestHeartbeatCarriesTheHubKind(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	for _, kind := range []string{wire.HubKindMac, wire.HubKindServer} {
		f := heartbeatFacts(func() time.Time { return now }, nil)
		f.HubKind = kind
		if p := onlyItem(t, HeartbeatSource(f)).Payload; !bytes.Contains(p, []byte(`"hub_kind":"`+kind+`"`)) {
			t.Fatalf("kind %s: payload %s", kind, p)
		}
	}
	if p := onlyItem(t, HeartbeatSource(heartbeatFacts(func() time.Time { return now }, nil))).Payload; bytes.Contains(p, []byte(`hub_kind`)) {
		t.Fatalf("payload without a kind fact: %s", p)
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

// TestHeartbeatCarriesTheChatCapability: "on" only while the chat fact says
// so, else "off" with its reason; a change restamps at once (iPhone chat
// §4.8).
func TestHeartbeatCarriesTheChatCapability(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	on, reason := true, ""
	f := heartbeatFacts(func() time.Time { return now }, nil)
	f.Chat = func() (bool, string) { return on, reason }
	src := HeartbeatSource(f)
	if c := capabilitiesOf(t, onlyItem(t, src).Payload); c == nil || c.Chat != "on" || c.ChatReason != "" {
		t.Fatalf("capabilities = %+v", c)
	}
	on, reason = false, wire.ChatOffDesktopTooOld
	now = now.Add(time.Second)
	if c := capabilitiesOf(t, onlyItem(t, src).Payload); c == nil || c.Chat != "off" || c.ChatReason != wire.ChatOffDesktopTooOld {
		t.Fatalf("capabilities = %+v", c)
	}
}
