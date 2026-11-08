package switcher_test

import (
	"database/sql"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Task 13 review, fix round 1.

// failing makes every UPDATE of column on devices fail until the returned
// func drops the trigger (a sidecar write refused part-way).
func (w *world) failing(column string) func() {
	w.t.Helper()
	exec := func(q string) {
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { _, err := tx.Exec(q); return err }); err != nil {
			w.t.Fatal(err)
		}
	}
	exec(`CREATE TRIGGER fail_` + column + ` BEFORE UPDATE OF ` + column + ` ON devices BEGIN SELECT RAISE(ABORT, 'refused'); END`)
	return func() { exec(`DROP TRIGGER fail_` + column) }
}

// M1: a ReaderLost whose lapsed mark fails after its first clear is finished
// at the next poll, though the phone has no ephemeral state left.
func TestAFailedReaderLostIsFinishedAtTheNextPoll(t *testing.T) {
	w, a, b := relayPair(t)
	restore := w.failing("relay_lapsed_at")
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	if offer, rows := w.kx(a); offer || rows != 0 {
		t.Fatal("the first clear did not commit")
	}
	if w.lapsedNow(a) {
		t.Fatal("marked lapsed through the failing write")
	}
	restore()
	w.pollAfterInterval()
	if !w.lapsedNow(a) {
		t.Fatal("the failed ReaderLost was not finished")
	}
	w.wantCleared(a)
	w.onCloudKit(a)
	w.settle(a, b)
	if n := count(a, wire.ControlHubOnRelay); n != 1 {
		t.Fatalf("%d hub_on_relay, want 1", n)
	}
}

// M2: a clear that fails in queueLapse does not fail the phone's own
// request (it would be answered rejected while the lapse goes on); the
// lapse's Step clears.
func TestAFailedClearDoesNotRejectThePhonesOwnRequest(t *testing.T) {
	w, a, b := relayPair(t)
	w.lapse(a) // its subscription ended: the relay refuses it, the account lists it not paying
	restore := w.failing("kx_offer")
	if err := w.sw.Request(w.ctx, transport.KindCloudKit, a.ID().String(), transport.KindCloudKit, wire.SwitchedByEntitlement); err != nil {
		t.Fatalf("the request failed with the clear: %v", err)
	}
	if !w.pendingLapse(a) {
		t.Fatal("the lapse is not recorded")
	}
	if offer, _ := w.kx(a); !offer {
		t.Fatal("the failing clear cleared")
	}
	restore()
	w.step()
	w.wantCleared(a)
	w.settle(b)
	w.wantActive(transport.KindRelay)
	if !w.lapsedNow(a) {
		t.Fatal("the lapse was not carried out")
	}
}

// M4: a stale writer the hub answers hub_on_relay (it does not pay) is no
// reader: its relay keys go before the notice is sealed, so its drop of
// every stored pair matches the hub.
func TestAStaleNonReaderLosesItsKeysWithItsHubOnRelay(t *testing.T) {
	w, a, b := relayPair(t)
	w.setPaying(a, false)
	w.onCloudKit(a)
	w.act(a) // a stale write on CloudKit while the hub runs on the relay
	w.settle(a, b)
	if n := count(a, wire.ControlHubOnRelay); n == 0 {
		t.Fatal("the stale writer was not told hub_on_relay")
	}
	w.wantCleared(a)
}

// M4: at a switch to the relay, a free phone holding relay keys from an
// earlier relay period loses them with its hub_on_relay.
func TestAFreePhonesOldRelayKeysGoWithTheSwitchsHubOnRelay(t *testing.T) {
	w, a, b := relayPair(t) // a holds a row in a relay epoch
	w.act(a)                // its first ordered action: an ordered phone
	w.settle(a, b)
	w.ask(b, wire.TransportCloudKit)
	w.settle(a, b)
	w.wantActive(transport.KindCloudKit)
	w.follow(a)
	w.follow(b)
	w.settle(a, b)
	if _, rows := w.kx(a); rows == 0 {
		t.Fatal("the old relay epoch's row is gone before the test")
	}
	w.setPaying(a, false)
	w.advance(switcher.AntiFlap)
	w.ask(b, wire.TransportRelay)
	w.settle(a, b)
	w.wantActive(transport.KindRelay)
	if n := count(a, wire.ControlHubOnRelay); n == 0 {
		t.Fatal("the free phone was not told hub_on_relay")
	}
	w.wantCleared(a)
}

// M1, across a restart: the unfinished departure is kept in hub_meta, and the
// first poll after the restart finishes it, whatever the list says then.
func TestAFailedReaderLostIsFinishedAfterARestart(t *testing.T) {
	w, a, b := relayPair(t)
	restore := w.failing("relay_lapsed_at")
	w.leave(a)
	w.pollAfterInterval()
	w.pollAfterInterval()
	if offer, rows := w.kx(a); offer || rows != 0 || w.lapsedNow(a) {
		t.Fatal("the departure did not fail after its first clear")
	}
	restore()
	w.rebuild(nil) // a restart: nothing in memory survives
	w.mu.Lock()
	w.emptyList = true // the list says nothing about the phone now
	w.mu.Unlock()
	w.pollAfterInterval()
	if !w.lapsedNow(a) {
		t.Fatal("the restart forgot the unfinished departure")
	}
	if v, _, _ := w.st.Meta(state.MetaReaderLostOwed); v != "" {
		t.Fatalf("the finished departure stays in hub_meta: %q", v)
	}
	w.wantCleared(a)
	w.onCloudKit(a)
	w.settle(a, b)
	if n := count(a, wire.ControlHubOnRelay); n != 1 {
		t.Fatalf("%d hub_on_relay, want 1", n)
	}
}
