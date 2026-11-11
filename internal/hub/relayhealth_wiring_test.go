package hub

import (
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// statusSeen reports whether any status the rig recorded matches.
func (r *rig) statusSeen(match func(Status) bool) bool {
	r.rec.mu.Lock()
	defer r.rec.mu.Unlock()
	return slices.ContainsFunc(r.rec.all, match)
}

// TestRelayIndicatorsWiredToTheRealTransport runs the production relay
// transport against relaytest: the connection state comes from
// relay.Transport.Connected, the data zone's quota and last save from its
// save observer, the paying phones from its known account state.
func TestRelayIndicatorsWiredToTheRealTransport(t *testing.T) {
	r := startOnRelay(t, false)
	// Before any admission no phone is listed: the paying list is unknown or
	// empty, never a phone marked not paying.
	l := r.link()
	dev := r.device(t)
	data := transport.DataZone(r.rec.last().RelayDeviceID)
	r.srv.FailNextSaveIn(data, relayv1.ErrorCode_ERROR_CODE_HUB_QUOTA_EXCEEDED)
	r.admit(l)

	eventually(t, "connected", func() bool {
		s := r.rec.last()
		return s.Relay != nil && s.Relay.State == RelayConnected
	})
	eventually(t, "the quota flag from a refused data-zone save", func() bool {
		return r.statusSeen(func(s Status) bool { return s.Relay != nil && s.Relay.QuotaHub })
	})
	eventually(t, "the flag cleared and the save stamped by the next save", func() bool {
		s := r.rec.last()
		return s.Relay != nil && !s.Relay.QuotaHub && s.Relay.LastSavedAt != ""
	})
	eventually(t, "the paying phone", func() bool {
		return slices.Equal(r.rec.last().PayingPhones, []string{dev.ID})
	})
}

// TestRelayReconnectIsAStatusEvent: the relay's WebSocket cut shows as
// connecting, and the reconnect the status refresh sees reaches Desktop's
// watch as a status event.
func TestRelayReconnectIsAStatusEvent(t *testing.T) {
	r := startOnRelay(t, false)
	l := r.link()
	r.admit(l)
	eventually(t, "connected", func() bool {
		s := r.rec.last()
		return s.Relay != nil && s.Relay.State == RelayConnected
	})
	r.srv.SetWebSocketDown(true)
	eventually(t, "connecting", func() bool {
		s := r.rec.last()
		return s.Relay != nil && s.Relay.State == RelayConnecting
	})
	next := watchLines(t, r.dir)
	r.srv.SetWebSocketDown(false)
	eventually(t, "connected again", func() bool {
		s := r.rec.last()
		return s.Relay != nil && s.Relay.State == RelayConnected
	})
	for {
		m, ok := next(5 * time.Second)
		if !ok {
			t.Fatal("no status event after the reconnect")
		}
		if m["event"] == EventStatus {
			return
		}
	}
}
