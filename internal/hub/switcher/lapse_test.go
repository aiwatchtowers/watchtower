package switcher_test

import (
	"context"
	"database/sql"
	"errors"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Rule 16 lapses kept in the sidecar (review round 1 of Go hub plan 3
// Task 20): a lapse outlives a restart and a switch away and back, ends
// only when an account read lists the phone paying again, and a relay
// action the phone was told is not delivered never applies.

// lapseWithAnotherPayer moves a and b to the relay, lets a's entitlement
// lapse and has the hub hear of it; z is a's action left on the relay.
func (w *world) lapseWithAnotherPayer() (a, b *hubtest.Phone, z uint64) {
	w.t.Helper()
	a, b = w.addPhone(true), w.addPhone(true)
	w.moveTo(a, wire.TransportRelay, b)
	z = w.act(a)
	w.lapse(a)
	if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: a.RelayDeviceID()}); err != nil {
		w.t.Fatal(err)
	}
	w.settle(b)
	w.onCloudKit(a)
	w.settle(a, b)
	w.wantActive(transport.KindRelay)
	if n := count(a, wire.ControlHubOnRelay); n != 1 {
		w.t.Fatalf("%d hub_on_relay, want 1", n)
	}
	// R32: the phone lists z as not delivered and drops it.
	a.Forget(z)
	return a, b, z
}

func (w *world) lapsedNow(ph *hubtest.Phone) bool {
	w.t.Helper()
	d, _, err := w.st.Device(ph.ID().String())
	if err != nil {
		w.t.Fatal(err)
	}
	return d.RelayLapsedAt != nil
}

// payAgain is the phone subscribing again: the relay takes its writes and
// the account lists it paying.
func (w *world) payAgain(ph *hubtest.Phone) {
	w.advance(time.Second) // later than the lapse
	w.relay.RefuseWrites(relayZone(ph), nil)
	w.mu.Lock()
	w.paying[ph.ID().String()] = true
	w.mu.Unlock()
}

// F1: a lapsed phone that pays again is lapsed no more — at the next poll,
// or at once on its own switch request toward the relay the hub is on —
// and its next relay action applies (its gap closed by skip_to, the held
// action drained); the action it was told is not delivered never applies.
func TestALapsedPhoneThatPaysAgainIsLapsedNoMore(t *testing.T) {
	for _, how := range []string{"poll", "request"} {
		t.Run(how, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				a, b, z := w.lapseWithAnotherPayer()
				w.payAgain(a)
				w.onRelay(a)
				if how == "poll" {
					w.sw.PollOther(w.ctx)
				} else {
					before := len(switched(a))
					w.ask(a, wire.TransportRelay)
					w.settle(a, b)
					if len(switched(a)) != before+1 {
						t.Fatal("the request was not answered with where the hub runs")
					}
				}
				if w.lapsedNow(a) {
					t.Fatal("still lapsed after paying again")
				}
				y := w.act(a)
				w.settle(a, b)
				w.appliedOnce(a, y)
				if slices.Contains(w.callLog(), call(a, z)) {
					t.Fatal("the not-delivered action applied")
				}
				if !slices.Contains(a.Undelivered, z) {
					t.Fatalf("undelivered %v", a.Undelivered)
				}
			})
		})
	}
}

// An unreadable account ends no lapse.
func TestAnUnreadableAccountEndsNoLapse(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, _, _ := w.lapseWithAnotherPayer()
		w.payAgain(a)
		w.mu.Lock()
		w.payErr = errors.New("relay account unreachable")
		w.mu.Unlock()
		w.sw.PollOther(w.ctx)
		if !w.lapsedNow(a) {
			t.Fatal("a lapse ended on an unreadable account")
		}
	})
}

// F2: the lapse outlives a restart and a switch to CloudKit and back; the
// relay action the phone was told is not delivered is read again after
// each rewind and never applied, before the lapse ends and after.
func TestALapseOutlivesARestartAndASwitchAwayAndBack(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b, z := w.lapseWithAnotherPayer()
		w.rebuild(nil) // a restart
		if lapsed, err := w.sw.Lapsed(transport.KindRelay, a.ID().String(), 0); err != nil || !lapsed {
			t.Fatalf("after a restart lapsed %v %v", lapsed, err)
		}
		roundTrip := func() {
			w.advance(switcher.AntiFlap)
			w.onCloudKit(b)
			w.moveTo(b, wire.TransportCloudKit)
			w.advance(switcher.AntiFlap)
			w.moveTo(b, wire.TransportRelay)
		}
		roundTrip()
		if !w.lapsedNow(a) {
			t.Fatal("a switch away and back ended the lapse")
		}
		if slices.Contains(w.callLog(), call(a, z)) {
			t.Fatal("the not-delivered action applied after a switch back")
		}
		w.payAgain(a)
		w.sw.PollOther(w.ctx)
		if w.lapsedNow(a) {
			t.Fatal("still lapsed after paying again")
		}
		roundTrip()
		if slices.Contains(w.callLog(), call(a, z)) {
			t.Fatal("the not-delivered action applied after the lapse ended")
		}
	})
}

// F6: two reports of one lapse at once tell the phone hub_on_relay once.
func TestConcurrentLapseReportsTellOnce(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.lapse(a)
		var wg sync.WaitGroup
		for range 4 {
			wg.Go(func() {
				_ = w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: a.RelayDeviceID()})
			})
		}
		wg.Wait()
		w.onCloudKit(a)
		w.settle(a, b)
		if n := count(a, wire.ControlHubOnRelay); n != 1 {
			t.Fatalf("%d hub_on_relay, want 1", n)
		}
	})
}

// F4/F5: on CloudKit already, the request is answered with where the hub
// runs; with a switch toward the relay accepted but not run, it supersedes
// it like any request toward CloudKit (no rotation).
func TestAnEntitlementRequestOnCloudKitIsAnsweredAndSupersedes(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		e := w.epoch()
		target, reason := wire.TransportCloudKit, wire.SwitchedByEntitlement
		if err := w.sw.Request(w.ctx, a.ID().String(), transport.KindCloudKit, reason); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		if len(switched(a)) != 1 || *switched(a)[0].Target != wire.TransportCloudKit {
			t.Fatalf("a read %+v", a.Controls)
		}
		if err := w.sw.Request(w.ctx, b.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if _, err := a.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target, Reason: &reason}); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
		if w.epoch() != e {
			t.Fatalf("epoch %d, want %d (no switch ran)", w.epoch(), e)
		}
	})
}

// F3: an old epoch keeps its keys while a queued write is sealed in it — a
// hub_on_relay stalled on an unreachable CloudKit — even when every phone
// acked a newer epoch; once written, the epoch retires.
func TestAnOldEpochIsKeptWhileAQueuedNoticeIsSealedInIt(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		e := w.epoch()
		w.ckFake.SetAvailable(false)
		w.lapse(a)
		if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: a.RelayDeviceID()}); err != nil {
			t.Fatal(err)
		}
		w.settle(b) // the notice waits in a's CloudKit queue
		if err := w.keys.Rotate(identity.ReasonManual); err != nil {
			t.Fatal(err)
		}
		ackAll(t, w, e+1)
		if err := w.keys.RetireOld(); err != nil {
			t.Fatal(err)
		}
		if kept, _ := w.keys.Retained(); !slices.Contains(kept, e) {
			t.Fatalf("epoch %d retired with a notice sealed in it queued (retained %v)", e, kept)
		}
		w.ckFake.SetAvailable(true)
		w.onCloudKit(a)
		w.settle(a, b)
		if n := count(a, wire.ControlHubOnRelay); n != 1 {
			t.Fatalf("%d hub_on_relay", n)
		}
		if err := w.keys.RetireOld(); err != nil {
			t.Fatal(err)
		}
		if kept, _ := w.keys.Retained(); slices.Contains(kept, e) {
			t.Fatalf("epoch %d kept after the notice was written (retained %v)", e, kept)
		}
	})
}

func ackAll(t *testing.T, w *world, epoch uint32) {
	t.Helper()
	devices, err := w.st.Devices()
	if err != nil {
		t.Fatal(err)
	}
	if err := w.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		for _, d := range devices {
			if err := state.AckEpoch(tx, d.ID, epoch); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// The cut for ordered actions is the action_seq, not a time: with the
// Mac's clock 30 s ahead of the relay's, an action written 1 s after the
// lapse ended is applied, and the one sent before it still never is.
func TestAnActionAfterTheLapseAppliesWhateverTheClockSkew(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		w.rebuild(func(c *switcher.Config) {
			c.Clock = func() time.Time { return w.clock().Add(30 * time.Second) }
		})
		a, b, z := w.lapseWithAnotherPayer()
		w.payAgain(a) // 1 s later by the relay's clock
		w.sw.PollOther(w.ctx)
		if w.lapsedNow(a) {
			t.Fatal("still lapsed after paying again")
		}
		w.onRelay(a)
		y := w.act(a)
		w.settle(a, b)
		w.appliedOnce(a, y)
		if slices.Contains(w.callLog(), call(a, z)) {
			t.Fatal("the not-delivered action applied")
		}
	})
}

// The lapse never ends blind: an ordered action the phone sent before the
// lapse and the hub never read is found in the relay mailbox when the lapse
// ends and never applied; an action written after it applies. A mailbox
// that cannot be read keeps the phone lapsed until the next poll.
func TestAnUnreadPreLapseActionNeverAppliesAfterTheLapseEnds(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		z := w.act(a) // on the relay; no hub pass reads it
		w.lapse(a)
		if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: a.RelayDeviceID()}); err != nil {
			t.Fatal(err)
		}
		a.Forget(z) // R32: listed as not delivered
		w.payAgain(a)
		w.relay.SetAvailable(false)
		w.sw.PollOther(w.ctx)
		if !w.lapsedNow(a) {
			t.Fatal("the lapse ended without reading the mailbox")
		}
		w.relay.SetAvailable(true)
		w.sw.PollOther(w.ctx)
		if w.lapsedNow(a) {
			t.Fatal("still lapsed after paying again")
		}
		if d, _, _ := w.st.Device(a.ID().String()); d.RelaySkipSeq != z {
			t.Fatalf("relay_skip_seq %d, want %d", d.RelaySkipSeq, z)
		}
		w.onRelay(a)
		y := w.act(a)
		w.settle(a, b)
		w.appliedOnce(a, y)
		if slices.Contains(w.callLog(), call(a, z)) {
			t.Fatal("the unread pre-lapse action applied")
		}
		if e, ok := a.Echoes[z]; !ok || e.Status != wire.StatusExpired {
			t.Fatalf("the skipped action got %+v, want an expired echo", e)
		}
	})
}
