package relay

import (
	"sync/atomic"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// OnConnected runs once per WebSocket connect: at Connect and at each
// reconnect, never for an HTTPS op, a zone's record-less marker (an
// overflow's or the reconnect's, one per zone) or a control.
func TestOnConnectedOncePerConnect(t *testing.T) {
	h := newHarness(t)
	w := WatchConnects(nil)
	tr := New(NewClient(h.relay.URL, h.key, client.WithHTTPClient(w.HTTPClient())), Options{
		Origin: h.relay.URL, Store: h.store, AssetDir: h.assetDir, Connects: w,
	})
	t.Cleanup(func() { _ = tr.Close() })
	var n atomic.Int32
	connected := make(chan struct{}, 16)
	tr.OnConnected(func() {
		n.Add(1)
		connected <- struct{}{}
	})
	h.relay.SetAccountState(&relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "phone1", Paying: true}}})
	data := transport.DataZone(tr.c.DeviceID())
	box := transport.MailboxZone(tr.c.DeviceID(), "phone1")
	if err := tr.Connect(t.Context(), []string{data, box}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		nextEvent(t, tr)
	}
	if got := n.Load(); got != 1 {
		t.Fatalf("%d connects after Connect, want 1", got)
	}
	// An op over HTTPS and an overflow-style marker are no connect.
	if _, err := tr.AccountState(t.Context()); err != nil {
		t.Fatal(err)
	}
	h.relay.Push(t, &relayv1.Event{Kind: &relayv1.Event_ZoneChanged{ZoneChanged: &relayv1.ZoneChanged{Zone: data}}})
	if ev := nextEvent(t, tr); !ev.Resync {
		t.Fatalf("event %+v, want the marker", ev)
	}
	if got := n.Load(); got != 1 {
		t.Fatalf("%d connects after an op and a marker, want 1", got)
	}
	// A dropped socket: one reconnect, one call, for both zones' markers.
	h.relay.DropSockets()
	for range 2 {
		if ev := nextEvent(t, tr); !ev.Resync {
			t.Fatalf("event %+v, want a reconnect marker", ev)
		}
	}
	for n.Load() < 2 {
		<-connected
	}
	if got := n.Load(); got != 2 {
		t.Fatalf("%d connects after one reconnect, want 2", got)
	}
}
