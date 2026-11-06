package switcher_test

import (
	"database/sql"
	"errors"
	"slices"
	"strconv"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The relay sim's rules 14–16 (relay repo sim/README.md) on real envelopes,
// over the relay memfake and CloudKit in both fakes, with the 7-day key
// retention of ask #843 in place of rule 14's 14 days (Go hub plan 3
// Task 20).

// relayZone is ph's mailbox zone on the relay.
func relayZone(ph *hubtest.Phone) string {
	return transport.MailboxZone(hubRelayID, ph.RelayDeviceID())
}

// lapse is the relay ending ph's entitlement: its mailbox refuses writes
// (ENTITLEMENT_INACTIVE) and the account no longer lists it as paying.
func (w *world) lapse(ph *hubtest.Phone) {
	w.relay.RefuseWrites(relayZone(ph), transport.ErrEntitlementInactive)
	w.mu.Lock()
	w.paying[ph.ID().String()] = false
	w.mu.Unlock()
}

// queued seals n actions into ph's outbox without writing them (a phone
// offline).
func (w *world) queued(ph *hubtest.Phone, n int) []uint64 {
	w.t.Helper()
	var out []uint64
	for range n {
		seq, err := ph.Queue(ph.NewAction("test_noop"))
		if err != nil {
			w.t.Fatal(err)
		}
		out = append(out, seq)
	}
	return out
}

// send writes action seq of ph's outbox (its bytes as sealed).
func (w *world) send(ph *hubtest.Phone, seq uint64) {
	w.t.Helper()
	if err := ph.Send(seq); err != nil {
		w.t.Fatal(err)
	}
}

// keep gives ph the keybox the hub publishes in data zone of store (the
// phone read it there) and acks its epoch.
func (w *world) keep(ph *hubtest.Phone) {
	w.t.Helper()
	kb, ok, err := ph.ReadKeybox(dataZone)
	if err != nil || !ok || kb.Keys == nil {
		w.t.Fatalf("keybox %+v %v %v", kb, ok, err)
	}
	if err := ph.Keep(*kb.Keys); err != nil {
		w.t.Fatal(err)
	}
	epoch := kb.Keys.Epoch
	if _, err := ph.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &epoch}); err != nil {
		w.t.Fatal(err)
	}
}

// appliedOnce fails unless each of seqs of ph was applied exactly once, in
// that order.
func (w *world) appliedOnce(ph *hubtest.Phone, seqs ...uint64) {
	w.t.Helper()
	got := w.callLog()
	last := -1
	for _, s := range seqs {
		c := call(ph, s)
		n, at := 0, -1
		for i, g := range got {
			if g == c {
				n, at = n+1, i
			}
		}
		if n != 1 || at < last {
			w.t.Fatalf("%s applied %d times (calls %v), want once in order", c, n, got)
		}
		last = at
	}
}

// Rule 14 (the sim's TestOldEpochActionAfter14DaysResealed with the 7-day
// cap): a phone on the relay is away while the hub moves back to CloudKit.
// It returns after 7 days, follows the relay's marker, takes its keybox on
// CloudKit and resends its outbox with the old bytes: the hub no longer
// holds that epoch, answers resend_from once, and the resealed actions (same
// action_seq) apply once.
func TestOldEpochActionAfter7DaysResealed(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, away := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, away)
		e := w.epoch()
		w.onCloudKit(a)
		w.ask(a, wire.TransportCloudKit)
		w.settle(a)
		w.wantActive(transport.KindCloudKit)
		w.follow(a)
		w.settle(a)
		w.publish()

		w.advance(identity.PreviousEpochGrace)
		seqs := w.queued(away, 2) // made offline on the last day, sealed in the old epoch
		m, ok := w.marker(away, w.relay, "")
		if !ok || *m.Target != wire.TransportCloudKit || *m.Epoch != e+1 {
			t.Fatalf("relay marker %+v %v", m, ok)
		}
		w.onCloudKit(away)
		w.keep(away)
		if err := away.ResendOutbox(); err != nil { // the old bytes, rule 13
			t.Fatal(err)
		}
		w.settle(a, away)
		if n := count(away, wire.ControlResendFrom); n != 1 {
			t.Fatalf("%d resend_from, want 1", n)
		}
		if !slices.Equal(away.Resealed, seqs) {
			t.Fatalf("resealed %v, want %v", away.Resealed, seqs)
		}
		w.appliedOnce(away, seqs...)
		if len(away.Outbox()) != 0 {
			t.Fatalf("outbox %v", away.Outbox())
		}
	})
}

// Decision 2 (ask #843): a phone offline 8 days across a switch keeps
// reading the hub. With only its old keys it opens the marker in the old
// transport, follows it, reads its keybox on the new one; each queued
// action sealed in the retired epoch gets one resend_from, is resealed with
// the same action_seq and applied once.
func TestAPhoneOfflineOver7DaysAcrossASwitchRecovers(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, away := w.addPhone(true), w.addPhone(true)
		e := w.epoch()
		w.ask(a, wire.TransportRelay)
		w.settle(a)
		w.wantActive(transport.KindRelay)
		w.follow(a)
		w.settle(a)
		w.publish()

		w.advance(8 * 24 * time.Hour)
		seqs := w.queued(away, 2) // made offline on the last day, sealed in the old epoch
		if ok, _ := w.keys.AcceptsRelayEpoch(e, away.ID()); ok {
			t.Fatal("the old epoch is still accepted after 8 days")
		}
		m, ok := w.marker(away, w.ckStore, transport.SharedMailboxZone(hubRelayID))
		if !ok || *m.Target != wire.TransportRelay || *m.Epoch != e+1 {
			t.Fatalf("CloudKit marker %+v %v", m, ok)
		}
		w.onRelay(away)
		w.keep(away)
		if !away.HoldsEpoch(e+1) || !away.HoldsEpoch(e) {
			t.Fatal("the phone does not hold both epochs")
		}
		if err := away.ResendOutbox(); err != nil {
			t.Fatal(err)
		}
		w.settle(a, away)
		if n := count(away, wire.ControlResendFrom); n != 1 {
			t.Fatalf("%d resend_from, want 1", n)
		}
		if !slices.Equal(away.Resealed, seqs) {
			t.Fatalf("resealed %v, want %v", away.Resealed, seqs)
		}
		w.appliedOnce(away, seqs...)
		if len(away.Outbox()) != 0 || len(away.Undelivered) != 0 {
			t.Fatalf("outbox %v, undelivered %v", away.Outbox(), away.Undelivered)
		}
	})
}

// Retention is the same for every rotation: an action sealed in the old
// epoch 6 d 23 h after it was retired applies as sealed; at 7 days it gets
// resend_from and applies once resealed.
func TestEveryEpochKeptAtMost7Days(t *testing.T) {
	for _, how := range []string{"manual", "transport_switch"} {
		t.Run(how, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				a := w.addPhone(true)
				w.act(a)
				w.settle(a) // a runs ordered
				seqs := w.queued(a, 2)
				if how == "manual" {
					if err := w.keys.Rotate(identity.ReasonManual); err != nil {
						t.Fatal(err)
					}
					kk, err := w.keys.KeyboxKeys()
					if err != nil {
						t.Fatal(err)
					}
					if err := a.Keep(kk); err != nil { // its keybox, no ack
						t.Fatal(err)
					}
				} else {
					w.ask(a, wire.TransportRelay)
					w.settle(a)
					w.wantActive(transport.KindRelay)
					c, _ := a.LastSwitch()
					w.onRelay(a)
					if err := a.Follow(c); err != nil {
						t.Fatal(err)
					}
					w.settle(a)
				}
				w.advance(identity.PreviousEpochGrace - time.Hour)
				w.send(a, seqs[0])
				w.settle(a)
				w.appliedOnce(a, seqs[0])
				if n := count(a, wire.ControlResendFrom); n != 0 || len(a.Resealed) != 0 {
					t.Fatalf("at 6 d 23 h: %d resend_from, resealed %v", n, a.Resealed)
				}
				w.advance(time.Hour)
				w.send(a, seqs[1])
				w.settle(a)
				if n := count(a, wire.ControlResendFrom); n != 1 || !slices.Equal(a.Resealed, seqs[1:]) {
					t.Fatalf("at 7 d: %d resend_from, resealed %v", n, a.Resealed)
				}
				w.appliedOnce(a, seqs...)
			})
		})
	}
}

// Rule 15, Review Focus 4: after a switch from the relay back to CloudKit
// and the phones emptying the mailboxes they left, no record is left on the
// relay, and neither copy of the switch request (written on both
// transports) is left on CloudKit. Nothing applies twice.
func TestNoCopiesLeftOnRelayAfterSwitch(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		x, y := w.act(a), w.act(b)
		w.settle(a, b)

		// a asks on both transports, one control id (rule 9).
		target := wire.TransportCloudKit
		id, err := a.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target})
		if err != nil {
			t.Fatal(err)
		}
		w.onCloudKit(a)
		if _, err := a.WriteControl(wire.Control{ID: id, Kind: wire.ControlSwitch, Target: &target}); err != nil {
			t.Fatal(err)
		}
		w.onRelay(a)
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
		w.follow(a)
		w.follow(b)
		w.settle(a, b)
		for _, ph := range []*hubtest.Phone{a, b} {
			w.onRelay(ph)
			if err := ph.Empty(); err != nil {
				t.Fatal(err)
			}
			w.onCloudKit(ph)
		}
		w.settle(a, b) // the hub keeps polling the relay mailboxes
		for _, ph := range []*hubtest.Phone{a, b} {
			w.onRelay(ph)
			if left := records(t, ph); len(left) != 0 {
				t.Fatalf("records left in a relay mailbox: %v", left)
			}
			w.onCloudKit(ph)
		}
		if slices.Contains(records(t, a), a.ControlWireName(id)) {
			t.Fatal("a copy of the switch request is left on CloudKit")
		}
		w.appliedOnce(a, x)
		w.appliedOnce(b, y)
	})
}

// Rule 16: the only paying phone lapses and asks to go back to CloudKit
// (the relay refuses its write, so on CloudKit only); the hub moves at once,
// by entitlement_expired, and its action left on the relay applies once.
func TestEntitlementExpiredFallsBackToCloudKit(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.moveTo(a, wire.TransportRelay)
		x := w.act(a) // on the relay, not yet read
		w.lapse(a)
		w.onCloudKit(a)
		target, reason := wire.TransportCloudKit, wire.SwitchedByEntitlement
		if _, err := a.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target, Reason: &reason}); err != nil {
			t.Fatal(err)
		}
		w.settle(a)
		w.wantActive(transport.KindCloudKit)
		if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != wire.SwitchedByEntitlement {
			t.Fatalf("switched_by %q %v %v", by, ok, err)
		}
		c, ok := a.LastSwitch()
		if !ok || *c.Target != wire.TransportCloudKit || *c.By != wire.SwitchedByEntitlement {
			t.Fatalf("notice %+v", c)
		}
		w.follow(a)
		w.settle(a)
		w.appliedOnce(a, x)
		if len(a.Outbox()) != 0 {
			t.Fatalf("outbox %v", a.Outbox())
		}
		y := w.act(a)
		w.settle(a)
		w.appliedOnce(a, x, y)
	})
}

// Rule 16: another phone still pays, so the hub stays on the relay. It
// applies none of the lapsed phone's actions there (not even one written
// before it heard), tells it hub_on_relay over CloudKit, and answers its
// retry there the same way; the paying phone goes on.
func TestEntitlementExpiredOtherPayingPhoneKeepsHub(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		e := w.epoch()
		z := w.act(a) // on the relay, not yet read
		w.lapse(a)
		if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: a.RelayDeviceID()}); err != nil {
			t.Fatal(err)
		}
		w.onCloudKit(a)
		target, reason := wire.TransportCloudKit, wire.SwitchedByEntitlement
		if _, err := a.WriteControl(wire.Control{Kind: wire.ControlSwitch, Target: &target, Reason: &reason}); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
		if w.epoch() != e {
			t.Fatal("the epoch rotated without a switch")
		}
		if slices.Contains(w.callLog(), call(a, z)) {
			t.Fatal("the lapsed phone's relay action was applied")
		}
		if n := count(a, wire.ControlHubOnRelay); n != 1 {
			t.Fatalf("%d hub_on_relay, want 1", n)
		}
		retry := w.act(a) // on CloudKit
		w.settle(a, b)
		if n := count(a, wire.ControlHubOnRelay); n != 2 {
			t.Fatalf("%d hub_on_relay after a retry, want 2", n)
		}
		if slices.Contains(w.callLog(), call(a, retry)) {
			t.Fatal("the retry was applied")
		}
		y := w.act(b)
		w.settle(a, b)
		w.appliedOnce(b, y)
	})
}

// Rule 16: the hub applied the phone's action before it heard of the lapse;
// the echo is refused on the relay, owed, and written over CloudKit before
// hub_on_relay, so the phone counts the action delivered.
func TestLapsedPhoneActionAppliedBeforeHubKnewIsEchoed(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		x := w.act(a)
		w.lapse(a)
		w.settle(b) // the hub applies x; its echo is refused on the relay
		w.wantActive(transport.KindRelay)
		w.appliedOnce(a, x)
		w.onCloudKit(a)
		if _, err := a.Sync(); err != nil {
			t.Fatal(err)
		}
		echo, notice := slices.Index(a.Read, "echo:"+strconv.FormatUint(x, 10)+":"+wire.StatusApplied), slices.Index(a.Read, "control:"+wire.ControlHubOnRelay)
		if echo < 0 || notice < 0 || echo > notice {
			t.Fatalf("read %v: want the applied echo of %d before hub_on_relay", a.Read, x)
		}
		if len(a.Outbox()) != 0 {
			t.Fatalf("outbox %v: the action was not counted delivered", a.Outbox())
		}
	})
}

// Rule 16, R31: the Mac's ENTITLEMENT_EXPIRED names the lapsed phone; the
// hub acts on it at once, as on that phone's transport_switch(cloudkit),
// which never comes. A control naming no linked phone changes nothing.
func TestHubActsOnEntitlementControl(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.moveTo(a, wire.TransportRelay)
		e := w.epoch()
		if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: "no-such-phone"}); err != nil {
			t.Fatal(err)
		}
		w.settle(a)
		w.wantActive(transport.KindRelay)
		w.lapse(a)
		if err := w.sw.OnControl(w.ctx, transport.Control{Kind: transport.EntitlementExpired, Detail: a.RelayDeviceID()}); err != nil {
			t.Fatal(err)
		}
		w.onCloudKit(a)
		w.settle(a)
		w.wantActive(transport.KindCloudKit)
		if w.epoch() != e+1 {
			t.Fatalf("epoch %d, want %d", w.epoch(), e+1)
		}
		c, ok := a.LastSwitch()
		if !ok || *c.Target != wire.TransportCloudKit || *c.By != wire.SwitchedByEntitlement {
			t.Fatalf("notice %+v", c)
		}
	})
}

// G2 (relay client launch conditions): the account lists no paying phone and
// no control or request told the hub (a lost ENTITLEMENT_EXPIRED, slots
// dropped, a stuck transfer, a relay-side gap, a wiped phone that never asks).
// nopayer.go moves the desktop host to CloudKit by itself, on two quiet reads.
// A healthy subscription move is not this case: it adopts the Mac into the
// new account's slots, so a paying phone stays listed.

// g2World is a hub on the relay whose phone was linked long ago and whose
// account lists nobody paying.
func g2World(t *testing.T, w *world) *hubtest.Phone {
	t.Helper()
	a := w.addPhone(true)
	w.route(a, true)
	w.moveTo(a, wire.TransportRelay)
	w.advance(switcher.NoPayerPoll)
	w.mu.Lock()
	w.paying = map[string]bool{} // the revoked slots are gone from the account
	w.mu.Unlock()
	return a
}

// route gives ph an iCloud route (it was linked over CloudKit) or takes it
// away: the sidecar's user_record_name, which CloudKitLinks counts.
func (w *world) route(ph *hubtest.Phone, on bool) {
	w.t.Helper()
	user := ""
	if on {
		user = "_user"
	}
	if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET user_record_name = ? WHERE device_id = ? COLLATE NOCASE`, user, ph.ID().String())
		return err
	}); err != nil {
		w.t.Fatal(err)
	}
}

// poll runs one PollOther, one interval after the last.
func (w *world) pollAfterInterval() {
	w.t.Helper()
	w.advance(switcher.NoPayerPoll)
	w.sw.PollOther(w.ctx)
	if err := w.sw.Step(w.ctx); err != nil {
		w.t.Fatal(err)
	}
}

func TestG2NoPayingPhoneLeftMovesADesktopHostToCloudKit(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		w.pollAfterInterval()
		w.wantActive(transport.KindRelay) // one read is not enough
		w.sw.PollOther(w.ctx)             // inside the interval: no second read
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
		if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != wire.SwitchedByEntitlement {
			t.Fatalf("switched_by %q %v %v", by, ok, err)
		}
	})
}

func TestG2AnOutageOrATimeoutMovesNothing(t *testing.T) {
	for _, how := range []string{"error", "timeout"} {
		t.Run(how, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				g2World(t, w)
				w.pollAfterInterval() // count 1
				w.mu.Lock()
				if how == "error" {
					w.payErr = errors.New("relay unreachable")
				} else {
					w.payHang = true
				}
				w.mu.Unlock()
				w.pollAfterInterval()
				w.pollAfterInterval()
				w.wantActive(transport.KindRelay)
				w.mu.Lock()
				w.payErr, w.payHang = nil, false
				w.mu.Unlock()
				w.pollAfterInterval() // the outage reset the count: 1 again
				w.wantActive(transport.KindRelay)
				w.pollAfterInterval()
				w.wantActive(transport.KindCloudKit)
			})
		})
	}
}

func TestG2ARestartRestartsTheCount(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		w.pollAfterInterval()
		w.rebuild(nil)
		w.pollAfterInterval()
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

func TestG2APayerAppearingResetsTheCount(t *testing.T) {
	for _, how := range []string{"linked phone", "unmatched account phone"} {
		t.Run(how, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				a := g2World(t, w)
				w.pollAfterInterval()
				w.mu.Lock()
				if how == "linked phone" {
					w.paying[a.ID().String()] = true
				} else {
					w.unmatched = true // a phone whose relay id is not learned yet
				}
				w.mu.Unlock()
				w.pollAfterInterval()
				w.mu.Lock()
				w.paying[a.ID().String()] = false
				w.unmatched = false
				w.mu.Unlock()
				w.pollAfterInterval()
				w.wantActive(transport.KindRelay)
				w.pollAfterInterval()
				w.wantActive(transport.KindCloudKit)
			})
		})
	}
}

func TestG2APhoneLinkingMovesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		w.pollAfterInterval() // count 1
		w.addPhone(false)     // linked just now, not in the account yet
		w.sw.PollOther(w.ctx)
		w.pollAfterInterval() // the list changed: the count restarts at 1
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

// A hub with no linked phone at all, on the relay by its stored route, is
// not moved (the guard on the list, not the start state).
func TestG2NoPhonesLinkedOnTheRelayMovesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		if err := w.st.SetMeta(switcher.MetaTransport, string(transport.KindRelay)); err != nil {
			t.Fatal(err)
		}
		w.rebuild(nil)
		w.wantActive(transport.KindRelay)
		for range 4 {
			w.pollAfterInterval()
		}
		w.wantActive(transport.KindRelay)
	})
}

// A phone linked a moment ago (its relay slot may not be listed yet) is not
// counted: the first read waits for it to be an interval old.
func TestG2APhoneLinkedWithinTheIntervalIsNotCounted(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.route(a, true)
		w.moveTo(a, wire.TransportRelay)
		w.sw.PollOther(w.ctx) // a paying read arms the interval now
		w.advance(2 * time.Minute)
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error { // the phone links now
			_, err := tx.Exec(`UPDATE devices SET linked_at = ?`, float64(w.clock().UnixNano())/1e9)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		w.mu.Lock()
		w.paying = map[string]bool{}
		w.mu.Unlock()
		w.advance(3 * time.Minute)
		w.sw.PollOther(w.ctx) // the interval is up, the phone is 3 minutes old: nothing counts
		w.pollAfterInterval() // count 1
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

// A phone that links while the account is being read changes the list under
// the answer: that answer counts for nothing.
func TestG2APhoneLinkingDuringTheReadResetsTheCount(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		w.pollAfterInterval() // count 1
		w.mu.Lock()
		w.onRead = func() {
			w.mu.Lock()
			w.onRead = nil
			w.mu.Unlock()
			w.addPhone(false)
		}
		w.mu.Unlock()
		w.pollAfterInterval() // the list changed during this read
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval() // count 1 for the new list
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

// The Mac moves to iCloud only if every linked phone has an iCloud route
// (ask #1072): all with routes move it on two reads; one without keeps it on
// the relay, however long nobody pays; a phone gaining or losing its route
// between the reads restarts the count.
func TestG2EveryPhoneWithARouteMovesTheHub(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		b := w.addPhone(false)
		w.route(b, true)
		w.advance(switcher.NoPayerPoll)
		w.pollAfterInterval()
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

func TestG2OnePhoneWithoutARouteKeepsTheHub(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		b := w.addPhone(false) // a relay-only phone: no iCloud user on its row
		w.advance(switcher.NoPayerPoll)
		for range 5 {
			w.pollAfterInterval()
		}
		w.wantActive(transport.KindRelay)
		// The phone is unlinked-for-routes no more: it gains one, and counts again.
		w.route(b, true)
		w.pollAfterInterval() // count 1
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

func TestG2ARouteGainedOrLostBetweenTheReadsRestartsTheCount(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := g2World(t, w)
		w.pollAfterInterval() // count 1
		w.route(a, false)     // lost between the reads
		w.pollAfterInterval()
		w.pollAfterInterval()
		w.wantActive(transport.KindRelay)
		w.route(a, true)
		w.pollAfterInterval() // count 1 again
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

// A route that cannot be told (the sidecar cannot be read) is unknown:
// nothing moves.
func TestG2AnUnreadableRouteMovesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		w.pollAfterInterval() // count 1
		_ = w.st.Close()
		w.advance(switcher.NoPayerPoll)
		w.sw.PollOther(w.ctx)
		w.wantActive(transport.KindRelay)
	})
}

// A phone's own request is in flight (the hub heads for the relay again after
// a pending move off it): the check does not replace it with its own.
func TestG2APendingSwitchIsNotOverridden(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := g2World(t, w)
		w.pollAfterInterval() // count 1
		id := a.ID().String()
		w.mu.Lock()
		w.paying[id] = true // so the phone may ask for the relay
		w.mu.Unlock()
		if err := w.sw.Request(w.ctx, id, transport.KindCloudKit, ""); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Request(w.ctx, id, transport.KindRelay, ""); err != nil {
			t.Fatal(err)
		}
		w.mu.Lock()
		w.paying[id] = false
		w.mu.Unlock()
		if !w.sw.Pending() {
			t.Fatal("no request in flight")
		}
		w.advance(switcher.NoPayerPoll)
		w.sw.PollOther(w.ctx) // no Step: the request stays in flight
		w.sw.PollOther(w.ctx)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindRelay) // the phone's last word stood
	})
}

func TestG2AfterTheMoveTheAntiFlapStillHolds(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := g2World(t, w)
		w.pollAfterInterval()
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
		w.mu.Lock()
		w.paying[a.ID().String()] = true
		w.mu.Unlock()
		w.onCloudKit(a)
		w.ask(a, wire.TransportRelay) // a paying phone asks at once: too soon
		w.settle(a)
		w.wantActive(transport.KindCloudKit)
	})
}

// A read that was not made afresh (the reader answered from an earlier read)
// counts for nothing and resets nothing: the count stays and the next poll
// tries again at once, not an interval later.
func TestG2ANotFreshReadKeepsTheCountAndRetriesAtOnce(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		w.pollAfterInterval() // count 1
		w.mu.Lock()
		w.payErr = switcher.ErrNotFresh
		w.mu.Unlock()
		w.pollAfterInterval() // not fresh: nothing counted, nothing reset
		w.wantActive(transport.KindRelay)
		w.mu.Lock()
		w.payErr = nil
		w.mu.Unlock()
		w.sw.PollOther(w.ctx) // no interval to wait: the count was kept
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindCloudKit)
	})
}

// The number of phones with an iCloud route is part of what the two reads
// must agree on, by itself: the phones and their ids stay the same here.
func TestG2ARouteLostBetweenTheReadsRestartsTheCountAlone(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		b := w.addPhone(false)
		w.route(b, true)
		w.advance(switcher.NoPayerPoll) // b is no longer new
		w.pollAfterInterval()           // count 1, two routes
		w.route(b, false)               // one route left, the same phones
		w.pollAfterInterval()           // the routes changed: count 1 again
		w.wantActive(transport.KindRelay)
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}
