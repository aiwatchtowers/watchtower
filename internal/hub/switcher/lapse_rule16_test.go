package switcher_test

import (
	"database/sql"
	"errors"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Rule 16 (ask #1075): the Mac stays on the relay while any phone other than
// the lapsed one pays (a fresh account read, linked to this Mac or not), and
// moves to iCloud when nobody does, whatever the routes. A read that cannot
// be made afresh decides nothing: the lapse waits and is retried.

// expire is the hub hearing of ph's lapse (the relay's control).
func (w *world) expire(ph *hubtest.Phone) {
	w.t.Helper()
	w.lapse(ph)
	if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: ph.RelayDeviceID()}); err != nil {
		w.t.Fatal(err)
	}
}

// askLapse is ph's own transport_switch(cloudkit, entitlement_expired).
func (w *world) askLapse(ph *hubtest.Phone) {
	w.t.Helper()
	w.lapse(ph)
	w.onCloudKit(ph)
	target, reason := wire.TransportCloudKit, wire.SwitchedByEntitlement
	if _, err := ph.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target, Reason: &reason}); err != nil {
		w.t.Fatal(err)
	}
}

func TestAnUnlinkedPayerKeepsTheHubAndTheLapsedPhoneIsTold(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.moveTo(a, wire.TransportRelay)
		w.mu.Lock()
		w.unmatched = true // a paying phone of the account that is not linked here
		w.mu.Unlock()
		w.askLapse(a)
		w.settle(a)
		w.wantActive(transport.KindRelay)
		if n := count(a, wire.ControlHubOnRelay); n != 1 {
			t.Fatalf("%d hub_on_relay, want 1: the lapsed phone is told", n)
		}
	})
}

func TestNobodyPayingMovesTheHubWhateverTheRoutes(t *testing.T) {
	for _, routes := range []string{"every phone has a route", "one phone has no route"} {
		t.Run(routes, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				a, b := w.addPhone(true), w.addPhone(true)
				w.route(a, true)
				w.route(b, routes == "every phone has a route")
				w.moveTo(a, wire.TransportRelay, b)
				w.mu.Lock()
				w.paying[b.ID().String()] = false
				w.mu.Unlock()
				w.expire(a)
				w.settle(a, b)
				w.wantActive(transport.KindCloudKit)
				if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != wire.SwitchedByEntitlement {
					t.Fatalf("switched_by %q %v %v", by, ok, err)
				}
			})
		})
	}
}

func TestARestartWithNoReadYetAndAnotherPayerKeepsTheHub(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.rebuild(nil) // no account read yet
		w.expire(a)
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
	})
}

// A read that failed, or was not made afresh, moves nothing: the phone's own
// request is answered with where the hub runs (once), the lapse is retried at
// the next Step and then decided, both ways.
func TestAFailedOrNotFreshReadMovesNothingAndTheLapseIsRetriedThenDecided(t *testing.T) {
	for _, how := range []string{"failed", "not fresh"} {
		for _, then := range []string{"another phone pays", "nobody pays"} {
			t.Run(how+"/"+then, func(t *testing.T) {
				eachFlavour(t, func(t *testing.T, w *world) {
					a, b := w.addPhone(true), w.addPhone(true)
					w.moveTo(a, wire.TransportRelay, b)
					w.mu.Lock()
					if how == "failed" {
						w.payErr = errors.New("relay account unreachable")
					} else {
						w.notFresh = true
					}
					w.mu.Unlock()
					before := len(switched(a))
					w.askLapse(a)
					w.settle(a, b)
					w.wantActive(transport.KindRelay)
					if len(switched(a)) != before+1 {
						t.Fatalf("the request was not answered with where the hub runs: %d notices after %d", len(switched(a)), before)
					}
					for range 3 { // retried, still undecided, never answered again
						if err := w.sw.Step(w.ctx); err != nil {
							t.Fatal(err)
						}
					}
					w.wantActive(transport.KindRelay)
					if len(switched(a)) != before+1 {
						t.Fatal("the request was answered again")
					}
					w.mu.Lock()
					w.payErr, w.notFresh = nil, false
					w.paying[b.ID().String()] = then == "another phone pays"
					w.mu.Unlock()
					if err := w.sw.Step(w.ctx); err != nil {
						t.Fatal(err)
					}
					w.settle(a, b)
					if then == "another phone pays" {
						w.wantActive(transport.KindRelay)
					} else {
						w.wantActive(transport.KindCloudKit)
					}
				})
			})
		}
	}
}

// A restart while a lapse waits keeps it: it is in the sidecar, and the next
// Step decides it.
func TestARestartMidLapseKeepsTheLapse(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.mu.Lock()
		w.payErr = errors.New("relay account unreachable")
		w.paying[b.ID().String()] = false
		w.mu.Unlock()
		w.expire(a)
		w.wantActive(transport.KindRelay)
		w.rebuild(nil) // the restart
		w.mu.Lock()
		w.payErr = nil
		w.mu.Unlock()
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
	})
}

// Who else moves the hub meanwhile (G2's poll, a person's switch): the lapse
// is decided over a read taken with no lock held, and accept orders the
// writers. Here G2 had counted once and the lapse then moves the hub: the
// poll that follows finds the hub on iCloud and does nothing.
func TestALapseAndTheNoPayerPollDoNotCollide(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := g2World(t, w)
		w.pollAfterInterval() // G2 counted once
		w.expire(a)
		w.settle(a)
		w.wantActive(transport.KindCloudKit)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
		_ = switcher.NoPayerPoll
	})
}

// A press behind a lapse is read and acted on while the account read hangs:
// the lapse only records (the pass never reads the relay), and the Step
// carries out the accepted press before it spends a read on the lapse.
func TestAPressBehindALapseIsActedOnWhileTheAccountReadHangs(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.mu.Lock()
		w.payHang = true
		w.mu.Unlock()
		w.askLapse(a) // a's request, first in the CloudKit pass
		w.onCloudKit(b)
		target := wire.TransportCloudKit
		if _, err := b.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target}); err != nil { // b presses Switch to iCloud
			t.Fatal(err)
		}
		start := time.Now()
		w.sw.PollOther(w.ctx)
		if d := time.Since(start); d > testOldSide/2 {
			t.Fatalf("the pass waited %s on the account read", d)
		}
		start = time.Now()
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if d := time.Since(start); d > testOldSide/2 {
			t.Fatalf("the press waited %s behind the lapse's account read", d)
		}
		w.wantActive(transport.KindCloudKit)
		if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != b.ID().String() {
			t.Fatalf("switched_by %q %v %v: the press was not the one acted on", by, ok, err)
		}
	})
}

// A phone with no relay id cannot be excluded from the account's list, so a
// paying phone there counts as another one and the hub stays (the safe side).
func TestALapsedPhoneWithNoRelayIDLeavesTheHubOnTheRelay(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE devices SET relay_device_id = NULL WHERE device_id = ? COLLATE NOCASE`, a.ID().String())
			return err
		}); err != nil {
			t.Fatal(err)
		}
		w.mu.Lock()
		w.paying[b.ID().String()] = false
		w.unmatched = true // the account lists a paying phone this hub cannot tell from the lapsed one
		w.mu.Unlock()
		w.expire(a)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
	})
}

// On a host with no CloudKit (or for a phone with no CloudKit mailbox) a
// lapse that leaves the hub on the relay still marks the phone lapsed: its
// relay actions are not applied either.
func TestALapseOnAHostWithNoCloudKitStillMarksThePhoneLapsed(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.rebuild(func(c *switcher.Config) { c.CloudKit = nil })
		w.wantActive(transport.KindRelay)
		w.expire(a)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if !w.lapsedNow(a) {
			t.Fatal("the lapsed phone is not marked lapsed")
		}
		if w.lapsedNow(b) {
			t.Fatal("the paying phone is marked lapsed")
		}
	})
}
