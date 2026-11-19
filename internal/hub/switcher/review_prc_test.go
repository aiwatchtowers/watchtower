package switcher_test

import (
	"context"
	"database/sql"
	"testing"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// PR C final review (relay client Phase 5).

// owedDeparture leaves a's departure unfinished: its keys are cleared, the
// lapsed mark failed, so it is in the owed set.
func owedDeparture(t *testing.T) (w *world, a, b *hubtest.Phone) {
	t.Helper()
	w, a, b = relayPair(t)
	restore := w.failing("relay_lapsed_at")
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	restore()
	if v, _, _ := w.st.Meta(state.MetaReaderLostOwed); v == "" || w.lapsedNow(a) {
		t.Fatalf("the departure is not owed: meta %q, lapsed %v", v, w.lapsedNow(a))
	}
	return w, a, b
}

// M1: an owed ReaderLost does not outlive a move off the relay. Back on the
// relay, the phone, paying again, gets no hub_on_relay.
func TestOwedDepartureIsDroppedWhenTheHubLeavesTheRelay(t *testing.T) {
	w, a, b := owedDeparture(t)
	w.ask(b, wire.TransportCloudKit)
	w.settle(a, b)
	w.wantActive(transport.KindCloudKit)
	w.follow(a)
	w.follow(b)
	w.settle(a, b)
	w.pollAfterInterval() // a poll on iCloud
	if v, _, _ := w.st.Meta(state.MetaReaderLostOwed); v != "" {
		t.Fatalf("the owed departure outlived the move off the relay: %q", v)
	}
	w.back(a) // a pays and holds the slot again
	before := count(a, wire.ControlHubOnRelay)
	w.advance(switcher.AntiFlap)
	w.ask(b, wire.TransportRelay)
	w.settle(a, b)
	w.wantActive(transport.KindRelay)
	w.follow(a)
	w.follow(b)
	w.settle(a, b)
	w.pollAfterInterval()
	w.settle(a, b)
	if n := count(a, wire.ControlHubOnRelay); n != before {
		t.Fatalf("%d hub_on_relay after the return, want %d", n, before)
	}
	if w.lapsedNow(a) {
		t.Fatal("the returned phone was marked lapsed")
	}
}

// M1: a re-link drops the phone's owed entry; the new link is not marked.
func TestOwedDepartureIsDroppedOnARelink(t *testing.T) {
	w, a, b := owedDeparture(t)
	w.advance(switcher.NoPayerPoll)
	d := a.Device()
	d.LinkedAt = w.clock()
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }); err != nil {
		t.Fatal(err)
	}
	w.pollAfterInterval() // still out of the slot: only the owed entry could mark it
	w.settle(a, b)
	if w.lapsedNow(a) {
		t.Fatal("the re-linked phone was marked lapsed by the old link's departure")
	}
	if v, _, _ := w.st.Meta(state.MetaReaderLostOwed); v != "" {
		t.Fatalf("the re-linked phone stays owed: %q", v)
	}
}

// M2: a switch accepted while the departure check reads the account stops
// it: no ReaderLost on a hub that is leaving the relay.
func TestNoReaderLostWhenASwitchStartsDuringTheRead(t *testing.T) {
	w, a, b := relayPair(t)
	reads := 0
	w.rebuild(func(c *switcher.Config) {
		slotted := c.Slotted
		c.Slotted = func(ctx context.Context) ([]string, error) {
			reads++
			if reads == 2 {
				if err := w.sw.Request(ctx, transport.KindRelay, b.ID().String(), transport.KindCloudKit, ""); err != nil {
					t.Fatalf("the switch request: %v", err)
				}
			}
			return slotted(ctx)
		}
	})
	w.leave(a)
	w.advance(switcher.NoPayerPoll)
	w.sw.PollOther(w.ctx)
	w.advance(switcher.NoPayerPoll)
	w.sw.PollOther(w.ctx)
	if !w.sw.Pending() {
		t.Fatal("the switch is not pending")
	}
	if w.lapsedNow(a) {
		t.Fatal("ReaderLost ran on a hub leaving the relay")
	}
	if offer, rows := w.kx(a); !offer && rows == 0 {
		t.Fatal("the departure cleared the keys of a hub leaving the relay")
	}
}
