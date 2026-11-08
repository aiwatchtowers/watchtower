package switcher_test

import (
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// A lapse clears the phone's relay keys in queueLapse, before any account
// read (relay client Phase 5, asks #1081 and #1101): from that commit every
// key for it is static, and no offer is taken back until the lapse ends.

func (w *world) step() {
	w.t.Helper()
	if err := w.sw.Step(w.ctx); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) pendingLapse(ph *hubtest.Phone) bool {
	w.t.Helper()
	p, err := w.st.LapsePending(ph.ID().String())
	if err != nil {
		w.t.Fatal(err)
	}
	return p
}

func TestLapseWithAnotherPayerClearsOfferAndRows(t *testing.T) {
	w, a, b := relayPair(t)
	w.offer(b)
	w.expire(a)
	w.wantCleared(a) // at the signal, before the Step's read
	w.step()
	w.wantActive(transport.KindRelay)
	if !w.lapsedNow(a) {
		t.Fatal("the phone is not marked lapsed")
	}
	w.wantCleared(a)
	if offer, _ := w.kx(b); !offer {
		t.Fatal("the paying phone lost its offer")
	}
}

func TestLapseClearsKeysUnderEveryAnswer(t *testing.T) {
	cases := []struct {
		name string
		set  func(w *world, a, b *hubtest.Phone)
		lap  func(w *world, a *hubtest.Phone)
		// moves: the Mac moves to iCloud; waits: the lapse stays pending.
		moves, waits, asked bool
	}{
		{name: "another linked phone pays", lap: (*world).expire},
		{name: "an unlinked phone pays", set: func(w *world, _, b *hubtest.Phone) {
			w.mu.Lock()
			w.unmatched = true
			w.mu.Unlock()
			w.setPaying(b, false)
		}, lap: (*world).expire},
		{name: "nobody pays", set: func(w *world, _, b *hubtest.Phone) { w.setPaying(b, false) }, lap: (*world).expire, moves: true},
		{name: "failed read, own request", set: func(w *world, _, _ *hubtest.Phone) {
			w.mu.Lock()
			w.payErr = errBoom
			w.mu.Unlock()
		}, lap: (*world).askLapse, moves: true, asked: true},
		{name: "failed read, relay signal", set: func(w *world, _, _ *hubtest.Phone) {
			w.mu.Lock()
			w.payErr = errBoom
			w.mu.Unlock()
		}, lap: (*world).expire, waits: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w, a, b := relayPair(t)
			if c.set != nil {
				c.set(w, a, b)
			}
			c.lap(w, a)
			if !c.asked { // the phone's request is read by the next pass
				if offer, rows := w.kx(a); offer || rows != 0 {
					t.Fatalf("not cleared at the signal: offer %v, %d rows", offer, rows)
				}
			}
			w.settle(b)
			if c.moves {
				w.wantActive(transport.KindCloudKit)
			} else {
				w.wantActive(transport.KindRelay)
			}
			if c.waits != w.pendingLapse(a) {
				t.Fatalf("lapse pending %v, want %v", !c.waits, c.waits)
			}
			if offer, rows := w.kx(a); offer || rows != 0 {
				t.Fatalf("offer %v, %d rows after the decision", offer, rows)
			}
		})
	}
	t.Run("a host with no CloudKit", func(t *testing.T) {
		w := newWorld(t, "memfake")
		a, b := w.addPhone(true), w.addPhone(true)
		w.rebuild(func(c *switcher.Config) { c.CloudKit = nil })
		w.onRelay(a)
		w.onRelay(b)
		w.ephemeral(a)
		w.expire(a)
		w.step()
		w.wantActive(transport.KindRelay)
		w.wantCleared(a)
	})
}

func TestRotationAfterLapseDerivesNoRowForThatPhone(t *testing.T) {
	w, a, b := relayPair(t)
	w.offer(b)
	w.expire(a)
	w.step()
	if err := w.keys.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	if _, rows := w.kx(a); rows != 0 {
		t.Fatalf("%d relay-key rows for the lapsed phone", rows)
	}
	w.takeKeys(b)
	if !b.HoldsPair(w.epoch()) {
		t.Fatal("the paying phone's epoch is not ephemeral")
	}
}

// F24: a rotation and a lapse in the same moment are serialised: rotate
// first, the lapse deletes the row it wrote; lapse first, no row is written.
func TestLapseAndRotationEitherOrder(t *testing.T) {
	for _, rotateFirst := range []bool{true, false} {
		name := "lapse first"
		if rotateFirst {
			name = "rotate first"
		}
		t.Run(name, func(t *testing.T) {
			w, a, _ := relayPair(t)
			rotate := func() {
				if err := w.keys.Rotate(identity.ReasonManual); err != nil {
					t.Fatal(err)
				}
			}
			if rotateFirst {
				rotate()
				if _, ok, err := w.st.EpochRelayKeys(w.epoch(), a.ID().String()); err != nil || !ok {
					t.Fatal("the rotation derived no row for the offering phone")
				}
				w.expire(a)
			} else {
				w.expire(a)
				rotate()
			}
			w.wantCleared(a)
		})
	}
}

// F25: a restart between the lapse's commit and its decision keeps the keys
// cleared, and an ack read meanwhile stores no offer.
func TestLapseRestartKeepsKXCleared(t *testing.T) {
	w, a, b := relayPair(t)
	w.mu.Lock()
	w.payErr = errBoom
	w.mu.Unlock()
	w.expire(a)
	w.step()
	w.rebuild(nil)
	w.wantCleared(a)
	w.relay.RefuseWrites(relayZone(a), nil)
	w.offer(a) // an old ack's copy
	if offer, _ := w.kx(a); offer {
		t.Fatal("an offer was taken while the lapse waits")
	}
	w.mu.Lock()
	w.payErr = nil
	w.mu.Unlock()
	w.settle(b)
	if !w.lapsedNow(a) {
		t.Fatal("the lapse was not decided after the restart")
	}
	w.wantCleared(a)
}

// hub_on_relay after a lapse is sealed static: a phone that kept none of its
// pairs opens it.
func TestHubOnRelaySealedStaticAfterLapse(t *testing.T) {
	w, a, b := relayPair(t)
	w.expire(a)
	w.step()
	epochs, err := w.keys.Retained()
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range epochs {
		a.ErasePair(e)
	}
	w.onCloudKit(a)
	w.settle(a, b)
	if n := count(a, wire.ControlHubOnRelay); n != 1 {
		t.Fatalf("%d hub_on_relay opened on static keys, want 1", n)
	}
}

// F29b: an old epoch_ack read between queueLapse and the lapsed mark, a failed
// read holding that window open, stores no offer; once the read answers, the
// hub writes no row and hub_on_relay stays static.
func TestOldAckInTheLapseWindowLeavesHubOnRelayStatic(t *testing.T) {
	w, a, b := relayPair(t)
	if _, err := a.AckEpoch(w.epoch()); err != nil { // written, not yet read
		t.Fatal(err)
	}
	w.mu.Lock()
	w.payErr = errBoom
	w.mu.Unlock()
	w.expire(a)
	w.relay.RefuseWrites(relayZone(a), nil)
	w.hub() // reads the old ack; the lapse waits
	if offer, rows := w.kx(a); offer || rows != 0 {
		t.Fatalf("the old ack wrote back: offer %v, %d rows", offer, rows)
	}
	w.mu.Lock()
	w.payErr = nil
	w.mu.Unlock()
	w.step()
	if !w.lapsedNow(a) {
		t.Fatal("the lapse was not decided")
	}
	if err := w.keys.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	w.wantCleared(a)
	epochs, _ := w.keys.Retained()
	for _, e := range epochs {
		a.ErasePair(e)
	}
	w.onCloudKit(a)
	w.settle(a, b)
	if count(a, wire.ControlHubOnRelay) != 1 {
		t.Fatal("hub_on_relay did not open on static keys")
	}
}

// F43: the relay's signal with a failed read, and the phone renews meanwhile:
// listed paying past LapseFresh, the lapse ends, and its new offer is taken.
func TestLapseEndedByRenewalAcceptsANewOffer(t *testing.T) {
	w, a, b := relayPair(t)
	w.mu.Lock()
	w.payErr = errBoom
	w.mu.Unlock()
	w.expire(a)
	w.step()
	w.advance(switcher.LapseFresh + time.Second)
	w.mu.Lock()
	w.payErr = nil
	w.mu.Unlock()
	w.payAgain(a)
	w.settle(b)
	if w.pendingLapse(a) || w.lapsedNow(a) {
		t.Fatal("the renewal did not end the lapse")
	}
	w.takeKeys(a) // "Coming back": the static keybox drops its stale pair
	w.offer(a)
	if offer, _ := w.kx(a); !offer {
		t.Fatal("the renewed phone's offer was refused")
	}
}

// A lapse publishes the device_grant slice soon, so the zone keybox without
// keys does not wait for the next full diff.
func TestALapseRepublishesTheGrantAtOnce(t *testing.T) {
	w, a, _ := relayPair(t)
	if w.pub.Dirty(hubslices.KindDeviceGrant) {
		t.Skip("device_grant already waits for a publish")
	}
	w.expire(a)
	if !w.pub.Dirty(hubslices.KindDeviceGrant) {
		t.Fatal("the lapse did not ask for the grant to be published")
	}
}

// A lapsed phone that pays again: the Paying read ends the lapse, and its
// next ack's offer is stored again.
func TestRenewedPhoneOffersAgain(t *testing.T) {
	w, a, b := relayPair(t)
	w.expire(a)
	w.step()
	w.payAgain(a)
	w.sw.PollOther(w.ctx)
	if w.lapsedNow(a) {
		t.Fatal("still lapsed")
	}
	w.takeKeys(a) // "Coming back": the static keybox drops its stale pair
	w.offer(a)
	if offer, _ := w.kx(a); !offer {
		t.Fatal("the renewed phone's offer was refused")
	}
	w.settle(b)
}
