package switcher_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"errors"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// failingKeyboxes makes the switcher's next n keybox reads fail (a crash
// between the rotation and the announce, as the hub sees it).
func (w *world) failingKeyboxes(n *atomic.Int32) {
	w.rebuild(func(c *switcher.Config) {
		boxes := c.Keyboxes
		c.Keyboxes = func() ([]wire.Keybox, error) {
			if n.Add(-1) >= 0 {
				return nil, errors.New("the hub stops here")
			}
			return boxes()
		}
	})
}

// Between the announce's commit and the old side's notices, the hub already
// answers from the committed transport: a request for it is a no-op told
// where the hub runs, and a phone on the old side gets the new target.
func TestRequestInTheLeaveWindowSeesTheNewTransport(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, lagging := w.addPhone(true), w.addPhone(true)
		e := w.epoch()
		if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Step(w.ctx); err != nil { // no PollOther yet: the old side's notices wait
			t.Fatal(err)
		}
		w.wantActive(transport.KindRelay)
		if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if w.sw.Pending() || w.epoch() != e+1 {
			t.Fatalf("a request for the committed transport started a switch (epoch %d)", w.epoch())
		}
		// On the relay the stale answer is the Step's (asks.go): the old side's
		// queue then carries the switch's own notice and this answer.
		if _, _, ok, err := w.sw.Stale(w.ctx, transport.KindCloudKit, lagging.ID().String()); err != nil || ok {
			t.Fatalf("stale in the pass: %v %v", ok, err)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.sw.PollOther(w.ctx)
		if _, err := lagging.Sync(); err != nil {
			t.Fatal(err)
		}
		got := switched(lagging)
		if len(got) != 2 {
			t.Fatalf("notices %+v, want the switch's and the stale answer", got)
		}
		for _, c := range got {
			if *c.Target != wire.TransportRelay || *c.Epoch != e+1 || *c.By != a.ID().String() {
				t.Fatalf("stale answer %+v", c)
			}
		}
	})
}

// The switch holds the publisher under its own reason from acceptance (and
// after a restart) until the new transport is active, and never lifts the
// admission gate's pause.
func TestSwitchHoldsThePublisherUnderItsOwnReason(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		var n atomic.Int32
		n.Store(1)
		w.failingKeyboxes(&n)
		if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Step(w.ctx); err == nil {
			t.Fatal("the announce did not fail")
		}
		if rep, _ := w.pub.Cycle(w.ctx, nil); !rep.Aborted {
			t.Fatalf("the publisher ran during a failed switch: %+v", rep)
		}
		w.rebuild(nil) // a restart with the switch in flight
		if rep, _ := w.pub.Cycle(w.ctx, nil); !rep.Aborted {
			t.Fatalf("the publisher ran after a restart mid-switch: %+v", rep)
		}
		w.pub.Pause() // the admission gate holds it too
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindRelay)
		if rep, _ := w.pub.Cycle(w.ctx, nil); !rep.Aborted {
			t.Fatal("the switch lifted the admission gate's pause")
		}
		w.pub.Resume()
		w.advance(3 * time.Second)
		if rep, err := w.pub.Cycle(w.ctx, nil); err != nil || rep.Aborted || rep.Saved == 0 {
			t.Fatalf("the publisher did not resume: %+v %v", rep, err)
		}
	})
}

// From the rotation to the announce (here: the hub stops in between, and
// restarts), the old transport's processor seals and applies nothing.
func TestOldSideSealsNothingBetweenRotationAndAnnounce(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		e := w.epoch()
		var n atomic.Int32
		n.Store(1)
		w.failingKeyboxes(&n)
		if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		_ = w.sw.Step(w.ctx)
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d", w.epoch())
		}
		for _, restart := range []bool{false, true} {
			if restart {
				w.rebuild(nil)
			}
			seq := w.act(a)
			if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
				t.Fatal(err)
			}
			if slices.Contains(w.callLog(), call(a, seq)) {
				t.Fatalf("restart %v: an action was applied between the rotation and the announce", restart)
			}
			if _, err := a.Sync(); err != nil {
				t.Fatal(err)
			}
			if len(a.Echoes) != 0 {
				t.Fatalf("restart %v: echoed in the window: %+v", restart, a.Echoes)
			}
		}
		w.settle(a)
		w.wantActive(transport.KindRelay)
		w.follow(a)
		w.settle(a)
		if len(w.callLog()) != 2 || len(a.Outbox()) != 0 {
			t.Fatalf("after the switch: calls %v outbox %v", w.callLog(), a.Outbox())
		}
	})
}

// A rotation between the switch's rotation and its announce (the old epoch
// is no longer accepted) and a phone whose keybox cannot be sealed: the
// switch still ends, every other phone gets its notice on the new side.
func TestASwitchSurvivesARotationBeforeItsAnnounceAndAnUnsealablePhone(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		var n atomic.Int32
		n.Store(1)
		ghost := secure.DeviceID(mustKey(t))
		w.rebuild(func(c *switcher.Config) {
			inner := c.Keyboxes
			c.Keyboxes = func() ([]wire.Keybox, error) {
				if n.Add(-1) >= 0 {
					return nil, errors.New("the hub stops here")
				}
				boxes, err := inner()
				kk := *boxes[0].Keys
				// A keybox for a phone with no keys on this hub: unsealable.
				return append(boxes, wire.Keybox{Grant: wire.DeviceGrant{DeviceID: ghost.String()}, Keys: &kk}), err
			}
		})
		if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		_ = w.sw.Step(w.ctx)
		if err := w.keys.Rotate(identity.ReasonManual); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
		for _, ph := range []*hubtest.Phone{a, b} {
			w.onRelay(ph)
			if _, err := ph.Sync(); err != nil {
				t.Fatal(err)
			}
			c, ok := ph.LastSwitch()
			if !ok || *c.Target != wire.TransportRelay {
				t.Fatalf("no notice on the new side: %+v", ph.Controls)
			}
			if err := ph.Follow(c); err != nil {
				t.Fatal(err)
			}
		}
	})
}

func mustKey(t *testing.T) ed25519.PublicKey {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub
}

// A Step that keeps failing is retried with backoff, not in a hot loop.
func TestAFailingStepBacksOff(t *testing.T) {
	w := newWorld(t, "memfake")
	a := w.addPhone(true)
	var calls atomic.Int32
	w.rebuild(func(c *switcher.Config) {
		c.Keyboxes = func() ([]wire.Keybox, error) {
			calls.Add(1)
			return nil, errors.New("always")
		}
	})
	if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(w.ctx, 1500*time.Millisecond)
	defer cancel()
	go func() {
		for ctx.Err() == nil { // a busy hub: polls and kicks keep coming
			w.sw.PollOther(ctx)
			w.sw.Kick()
			time.Sleep(10 * time.Millisecond)
		}
	}()
	_ = w.sw.Run(ctx)
	// 1 s backoff: the first try and at most one retry in 1.5 s.
	if got := calls.Load(); got < 1 || got > 2 {
		t.Fatalf("%d keybox reads in 1.5 s: no backoff", got)
	}
}

// A relay account that cannot be read never stalls the mailbox: a switch
// toward the relay is accepted (the phone counts as paying) and the
// actions behind it are applied.
func TestAnUnreadableRelayAccountNeverStallsTheMailbox(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.mu.Lock()
		w.payErr = errors.New("relay account unreachable")
		w.mu.Unlock()
		w.ask(a, wire.TransportRelay)
		seq := w.act(a)
		w.settle(a)
		w.wantCalls(call(a, seq))
		w.wantActive(transport.KindRelay)
	})
}

// A hanging (not failing) old side costs the switch at most the old-side
// timeout before the hub serves the new side; its notices wait for it.
func TestAHangingOldSideNeverHoldsTheSwitch(t *testing.T) {
	t.Run("relay", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			a := w.addPhone(true)
			w.moveTo(a, wire.TransportRelay)
			w.relay.SetHanging(true)
			t.Cleanup(func() { w.relay.SetHanging(false) })
			w.onCloudKit(a)
			if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindCloudKit, ""); err != nil {
				t.Fatal(err)
			}
			start := time.Now()
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
			if d := time.Since(start); d > testOldSide+time.Second {
				t.Fatalf("the switch took %s on a hanging relay", d)
			}
			w.wantActive(transport.KindCloudKit)
			if _, err := a.Sync(); err != nil {
				t.Fatal(err)
			}
			w.follow(a)
			seq := w.act(a)
			if _, err := w.sw.ActiveProcessor().Pass(w.ctx); err != nil {
				t.Fatal(err)
			}
			if !slices.Contains(w.callLog(), call(a, seq)) {
				t.Fatal("the new side was not served")
			}
		})
	})
	t.Run("bridge", func(t *testing.T) {
		eachFlavour(t, func(t *testing.T, w *world) {
			a := w.addPhone(true)
			if w.bridge != nil {
				_, release := w.bridge.Block("changes")
				_, releaseSave := w.bridge.Block("save")
				t.Cleanup(func() { release(); releaseSave() })
			} else {
				w.ckFake.SetHanging(true)
				t.Cleanup(func() { w.ckFake.SetHanging(false) })
			}
			if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
				t.Fatal(err)
			}
			start := time.Now()
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
			if d := time.Since(start); d > testOldSide+time.Second {
				t.Fatalf("the switch took %s on a hanging bridge", d)
			}
			w.wantActive(transport.KindRelay)
			w.onRelay(a)
			if _, err := a.Sync(); err != nil {
				t.Fatal(err)
			}
			if c, ok := a.LastSwitch(); !ok || *c.Target != wire.TransportRelay {
				t.Fatalf("no notice on the relay: %+v", a.Controls)
			}
		})
	})
}

// An existing relay hub (relay-linked phones only, never adopted) becoming
// a desktop host starts on the relay; an adopted hub starts on CloudKit.
func TestAnExistingRelayHubStartsOnTheRelay(t *testing.T) {
	w := newWorld(t, "memfake")
	w.addPhone(true) // a relay link: relay device id, no iCloud user
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, switcher.MetaTransport)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	w.rebuild(nil)
	w.wantActive(transport.KindRelay)

	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, switcher.MetaTransport); err != nil {
			return err
		}
		return state.SetMetaTx(tx, "adopted_at", "1730000000")
	}); err != nil {
		t.Fatal(err)
	}
	w.rebuild(nil)
	w.wantActive(transport.KindCloudKit)
}

// The announce rewinds the new transport's mailboxes: each zone token is 0
// once the switch is done, so what waited there on standby is read again.
func TestTheAnnounceRewindsTheNewTransportsMailboxes(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		zone := transport.MailboxZone(hubRelayID, a.RelayDeviceID())
		if err := w.st.SetZoneToken(zone, 7); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Request(w.ctx, w.sw.Active().Kind(), a.ID().String(), transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if tok, err := w.st.ZoneToken(zone); err != nil || tok != 0 {
			t.Fatalf("relay mailbox token %d after the announce, %v", tok, err)
		}
	})
}

// A linked phone whose keybox carries no keys (not confirmed) is skipped:
// it gets no notice, every other phone does, and the switch ends.
func TestAKeylessPhoneIsSkipped(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, keyless := w.addPhone(true), w.addPhone(true)
		w.rebuild(func(c *switcher.Config) {
			inner := c.Keyboxes
			c.Keyboxes = func() ([]wire.Keybox, error) {
				boxes, err := inner()
				for i := range boxes {
					if boxes[i].Grant.DeviceID == keyless.ID().String() {
						boxes[i].Keys = nil
					}
				}
				return boxes, err
			}
		})
		w.ask(a, wire.TransportRelay)
		w.settle(a, keyless)
		w.wantActive(transport.KindRelay)
		if _, ok := a.LastSwitch(); !ok {
			t.Fatal("the phone with keys got no notice")
		}
		if _, ok := keyless.LastSwitch(); ok {
			t.Fatalf("the keyless phone got a notice: %+v", keyless.Controls)
		}
	})
}
