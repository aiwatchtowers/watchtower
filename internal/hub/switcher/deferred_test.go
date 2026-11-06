package switcher_test

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Nothing in a processor's pass reads the relay (board #1562): a request
// toward the relay and the answer to a stale write only record, and the Step
// decides them over one bounded read. A hung read in the pass burned the
// pass's context, so the record stayed unread and every phone behind it
// starved. These tests count reads and order, never time.

func (w *world) paysRead() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.payReads
}

// wantPressActedOn: ph's Switch to iCloud is the switch the hub carried out.
func (w *world) wantPressActedOn(ph *hubtest.Phone) {
	w.t.Helper()
	w.wantActive(transport.KindCloudKit)
	if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != ph.ID().String() {
		w.t.Fatalf("switched_by %q %v %v: the press was not the one acted on", by, ok, err)
	}
}

// rejections is what ph heard in transport_switch_rejected.
func rejections(ph *hubtest.Phone) []string {
	var out []string
	for _, c := range ph.Controls {
		if c.Kind == wire.ControlSwitchRejected {
			out = append(out, *c.Reason)
		}
	}
	return out
}

// staleWriter puts the hub on the relay through b with a left behind on
// CloudKit, not having followed.
func staleWriter(t *testing.T, w *world) (a, b *hubtest.Phone) {
	t.Helper()
	a, b = w.addPhone(true), w.addPhone(true)
	w.moveTo(b, wire.TransportRelay)
	return a, b
}

// Path 1: phone a's transport_switch(relay) is first in the CloudKit pass with
// the account read hanging; phone b's Switch to iCloud sits behind it.
func TestARelayRequestOnAHungAccountReadLeavesThePressBehindItRead(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.unreadable("hanging")
		w.onCloudKit(a)
		w.ask(a, wire.TransportRelay)
		w.onCloudKit(b)
		w.ask(b, wire.TransportCloudKit)
		before := w.paysRead()
		w.sw.PollOther(w.ctx)
		if n := w.paysRead() - before; n != 0 {
			t.Fatalf("%d account reads in the pass", n)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if n := w.paysRead() - before; n != 1 {
			t.Fatalf("%d account reads for the Step's decisions, want one", n)
		}
		w.wantPressActedOn(b)
	})
}

// However many asks wait, the Step makes one account read for them, so a press
// behind them waits one old-side timeout, not one per ask.
func TestARunOfDecisionsMakesOneAccountRead(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b, c := w.addPhone(true), w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b, c)
		w.unreadable("hanging")
		for _, ph := range []*hubtest.Phone{a, b} {
			w.onCloudKit(ph)
			w.ask(ph, wire.TransportRelay)
		}
		w.onCloudKit(c)
		w.ask(c, wire.TransportCloudKit)
		before := w.paysRead()
		w.sw.PollOther(w.ctx)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if n := w.paysRead() - before; n != 1 {
			t.Fatalf("%d account reads, want one", n)
		}
		w.wantPressActedOn(c)
	})
}

// The reviewer's proof of the same path through whole hub cycles.
func TestAHungAccountReadNeverKeepsTheHubOnTheRelayBehindARelayRequest(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.unreadable("hanging")
		w.onCloudKit(a)
		w.ask(a, wire.TransportRelay)
		w.onCloudKit(b)
		w.ask(b, wire.TransportCloudKit)
		for range 8 {
			w.hub()
		}
		w.wantPressActedOn(b)
	})
}

// Path 2: phone a's stale action is first in the CloudKit pass with the account
// read hanging (Stale's hub_on_relay check); b's press sits behind it.
func TestAStaleWriteOnAHungAccountReadLeavesThePressBehindItRead(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := staleWriter(t, w)
		w.act(a)
		w.unreadable("hanging")
		w.onCloudKit(b)
		w.ask(b, wire.TransportCloudKit)
		before := w.paysRead()
		w.sw.PollOther(w.ctx)
		if n := w.paysRead() - before; n != 0 {
			t.Fatalf("%d account reads in the pass", n)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if n := w.paysRead() - before; n != 1 {
			t.Fatalf("%d account reads for the Step's decisions, want one", n)
		}
		w.wantPressActedOn(b)
	})
}

// Path 2 through whole hub cycles. answerStale never stops the mailbox, but the
// pass's context is gone after the read: b's epoch_ack cannot commit, the read
// stops there, and the press behind it is never reached.
func TestAHungAccountReadNeverKeepsTheHubOnTheRelayBehindAStaleWrite(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := staleWriter(t, w)
		w.act(a)
		w.unreadable("hanging")
		w.onCloudKit(b)
		epoch := w.epoch()
		if _, err := b.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &epoch}); err != nil {
			t.Fatal(err)
		}
		w.ask(b, wire.TransportCloudKit)
		for range 8 {
			w.hub()
		}
		w.wantPressActedOn(b)
	})
}

// Path 3: a free phone's not_paying is decided outside the pass and still
// reaches it, on the transport it asked on, with no pass in between.
func TestNotPayingIsDecidedInTheStepAndHeardOnTheTransportAsked(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free := w.addPhone(false)
		w.ask(free, wire.TransportRelay)
		before := w.paysRead()
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		if n := w.paysRead() - before; n != 0 {
			t.Fatalf("%d account reads in the pass", n)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if _, err := free.Sync(); err != nil {
			t.Fatal(err)
		}
		if got := rejections(free); !slices.Equal(got, []string{wire.SwitchNotPaying}) {
			t.Fatalf("rejections %v, want one not_paying written by the Step", got)
		}
		w.wantActive(transport.KindCloudKit)
		w.settle(free)
		if got := rejections(free); len(got) != 1 {
			t.Fatalf("rejections %v after more rounds", got)
		}
	})
}

// A request read on the relay's standby side is answered there and only there.
func TestARejectionGoesOnlyToTheTransportTheRequestWasReadOn(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free := w.addPhone(false)
		w.onRelay(free)
		w.ask(free, wire.TransportRelay)
		for range 3 {
			w.hub()
		}
		if _, err := free.Sync(); err != nil {
			t.Fatal(err)
		}
		if got := rejections(free); !slices.Equal(got, []string{wire.SwitchNotPaying}) {
			t.Fatalf("on the relay %v", got)
		}
		w.onCloudKit(free)
		before := len(free.Controls)
		if _, err := free.Sync(); err != nil {
			t.Fatal(err)
		}
		if len(free.Controls) != before {
			t.Fatalf("a copy on CloudKit too: %+v", free.Controls[before:])
		}
	})
}

// A too_soon keeps its wait when the Step decides it.
func TestTooSoonIsHeardWithItsWaitFromTheStep(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		ph := w.addPhone(true)
		w.moveTo(ph, wire.TransportRelay)
		w.moveTo(ph, wire.TransportCloudKit)
		w.advance(time.Minute)
		w.ask(ph, wire.TransportRelay)
		w.settle(ph)
		var got []wire.Control
		for _, c := range ph.Controls {
			if c.Kind == wire.ControlSwitchRejected {
				got = append(got, c)
			}
		}
		if len(got) != 1 || *got[0].Reason != wire.SwitchTooSoon || got[0].RetryAfterS == nil || *got[0].RetryAfterS != 240 {
			t.Fatalf("rejections %+v", got)
		}
	})
}

// Restart: a request read and not decided yet is kept across a restart, and
// decided once by the new process.
func TestARelayRequestWaitingForTheStepSurvivesARestart(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, free := w.addPhone(true), w.addPhone(false)
		w.ask(free, wire.TransportRelay)
		w.ask(a, wire.TransportRelay)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.rebuild(nil) // the host restarts before any Step
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err) // the records count as read: nothing asks twice
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindRelay)
		w.settle(a, free)
		if got := rejections(free); !slices.Equal(got, []string{wire.SwitchNotPaying}) {
			t.Fatalf("the free phone heard %v", got)
		}
		if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != a.ID().String() {
			t.Fatalf("switched_by %q %v %v", by, ok, err)
		}
	})
}

// Restart: a stale write's answer is owed across a restart too.
func TestAStaleAnswerWaitingForTheStepSurvivesARestart(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, _ := staleWriter(t, w)
		if _, err := a.Sync(); err != nil {
			t.Fatal(err)
		}
		before := len(switched(a))
		w.act(a)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.rebuild(nil)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		// Standby: its queue goes out at the next poll (the run loop's next line).
		w.sw.PollOther(w.ctx)
		if _, err := a.Sync(); err != nil {
			t.Fatal(err)
		}
		if got := len(switched(a)); got <= before {
			t.Fatalf("no answer after the restart: %d notices, had %d", got, before)
		}
	})
}

// A failed or hung read counts as paying, as it always has: no phone is refused
// by mistake, and the Step goes on.
func TestAnUnreadableAccountAtTheStepCountsAsPaying(t *testing.T) {
	for _, how := range []string{"failed", "hanging"} {
		t.Run(how, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				free := w.addPhone(false)
				w.unreadable(how)
				w.ask(free, wire.TransportRelay)
				if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
					t.Fatal(err)
				}
				if err := w.sw.Step(w.ctx); err != nil {
					t.Fatal(err)
				}
				w.wantActive(transport.KindRelay)
				if got := rejections(free); len(got) != 0 {
					t.Fatalf("refused on an unreadable account: %v", got)
				}
			})
		})
	}
}

// The same for the stale answer: an unknown account never says hub_on_relay,
// a phone behind on the epoch hears transport_switched again.
func TestAnUnreadableAccountNeverTellsAStalePhoneHubOnRelay(t *testing.T) {
	for _, how := range []string{"failed", "hanging"} {
		t.Run(how, func(t *testing.T) {
			eachFlavour(t, func(t *testing.T, w *world) {
				free, b := w.addPhone(false), w.addPhone(true)
				w.moveTo(b, wire.TransportRelay)
				if _, err := free.Sync(); err != nil {
					t.Fatal(err)
				}
				told, notices := count(free, wire.ControlHubOnRelay), len(switched(free))
				w.unreadable(how)
				w.act(free)
				w.hub() // the poll records it, the Step queues the answer
				w.hub() // the next poll writes the standby queue
				if _, err := free.Sync(); err != nil {
					t.Fatal(err)
				}
				if n := count(free, wire.ControlHubOnRelay); n != told {
					t.Fatalf("%d hub_on_relay, had %d", n, told)
				}
				if n := len(switched(free)); n != notices+1 {
					t.Fatalf("%d notices, want %d", n, notices+1)
				}
			})
		})
	}
}

// The host closing during the read decides nothing: the phone is not taken as
// paying, and the restarted hub decides over an answer.
func TestTheHostClosingDuringTheReadDecidesNothing(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free := w.addPhone(false)
		w.ask(free, wire.TransportRelay)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		cctx, closeHost := context.WithCancel(w.ctx)
		defer closeHost()
		w.mu.Lock()
		w.payHang, w.onPayRead = true, closeHost
		w.mu.Unlock()
		_ = w.sw.Step(cctx)
		w.wantActive(transport.KindCloudKit)
		if w.sw.Pending() {
			t.Fatal("the closing host took the phone as paying")
		}
		w.mu.Lock()
		w.payHang, w.onPayRead = false, nil
		w.mu.Unlock()
		w.rebuild(nil)
		w.settle(free)
		w.wantActive(transport.KindCloudKit)
		if got := rejections(free); !slices.Equal(got, []string{wire.SwitchNotPaying}) {
			t.Fatalf("rejections %v", got)
		}
	})
}

// The hub reads in the order the passes read: a relay request first and b's
// press second ends on b's press, whichever read answers.
func TestTheOrderTheRequestsWereReadInDecides(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.ask(a, wire.TransportRelay)
		w.ask(b, wire.TransportCloudKit)
		e := w.epoch()
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
		if w.epoch() != e {
			t.Fatalf("epoch %d, want %d: the later press lost", w.epoch(), e)
		}
		w.ask(b, wire.TransportCloudKit)
		w.ask(a, wire.TransportRelay)
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
	})
}

// A request read while the switch's drain runs still replaces a switch not
// rotated yet (the last accepted wins), as when it was decided in the pass:
// the Step decides it before the rotation.
func TestARequestReadDuringTheDrainStillWins(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.advance(switcher.AntiFlap)
		e := w.epoch()
		w.onCloudKit(a) // a asks iCloud on the standby side: the Step's drain reads the relay only
		w.ask(a, wire.TransportCloudKit)
		w.sw.PollOther(w.ctx) // accepted, not carried out
		w.onRelay(b)          // b's relay request sits in the relay mailbox the drain reads
		w.ask(b, wire.TransportRelay)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindRelay)
		if w.epoch() != e {
			t.Fatalf("epoch %d, want %d: the later request lost to the drain", w.epoch(), e)
		}
	})
}

// A request from a link that no longer stands is dropped: a re-link's phone
// never hears, and the hub never moves on, what the old link asked.
func TestARelinkDropsTheRequestWaitingForTheStep(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.ask(a, wire.TransportRelay)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		if err := w.st.WithTx(w.ctx, func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE devices SET link_nonce = 'a-new-link' WHERE device_id = ? COLLATE NOCASE`, a.ID().String())
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindCloudKit)
		if w.sw.Pending() {
			t.Fatal("the old link's request was accepted")
		}
	})
}

// G2 waits for the Step: a person's request read in the same PollOther is
// decided first, so it cannot replace G2's move afterward. G2 moves on its next
// poll, its count kept.
func TestG2DoesNotJumpAheadOfARequestWaitingForTheStep(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := g2World(t, w)
		w.rebuild(func(c *switcher.Config) { // G2's read says nobody pays, Paying lists a
			c.AnyPaying = func(context.Context) (bool, error) { return false, nil }
		})
		w.mu.Lock()
		w.paying[a.ID().String()] = true
		w.mu.Unlock()
		w.pollAfterInterval() // the first of G2's two reads
		w.onCloudKit(a)
		w.ask(a, wire.TransportRelay)
		w.pollAfterInterval() // the request is read; G2's second read waits
		w.wantActive(transport.KindRelay)
		w.sw.PollOther(w.ctx) // G2's second read
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindCloudKit)
		if _, by, ok, err := w.sw.SwitchedAt(); err != nil || !ok || by != wire.SwitchedByEntitlement {
			t.Fatalf("switched_by %q %v %v", by, ok, err)
		}
	})
}

// A waiting list that does not decode stops no switch: it is dropped, and a
// press goes through.
func TestAnUnreadableWaitingListStopsNoSwitch(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		if err := w.st.SetMeta("switch_asks", "not json"); err != nil {
			t.Fatal(err)
		}
		w.moveTo(a, wire.TransportRelay)
	})
}

// A lapsed phone that pays again and asks for the relay is lapsed no more,
// decided in the Step with no read in the pass.
func TestARelayRequestEndsALapseFromTheStep(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b)
		w.mu.Lock()
		w.paying[a.ID().String()] = false
		w.mu.Unlock()
		w.expire(a)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if d, _, _ := w.st.Device(a.ID().String()); d.RelayLapsedAt == nil {
			t.Fatal("the phone was not marked lapsed")
		}
		w.mu.Lock()
		w.paying[a.ID().String()] = true
		w.mu.Unlock()
		w.onCloudKit(a)
		w.ask(a, wire.TransportRelay)
		before := w.paysRead()
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		if n := w.paysRead() - before; n != 0 {
			t.Fatalf("%d account reads in the pass", n)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if d, _, _ := w.st.Device(a.ID().String()); d.RelayLapsedAt != nil {
			t.Fatal("the lapse did not end")
		}
	})
}

// A list that does not decode is cleared, not just read past: left in place it
// would hold G2's guard for good.
func TestAnUnreadableWaitingListIsClearedAndG2MovesOn(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		g2World(t, w)
		if err := w.st.SetMeta("switch_asks", "not json"); err != nil {
			t.Fatal(err)
		}
		w.pollAfterInterval()
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v != "" {
			t.Fatalf("the list is %q %v", v, err)
		}
		w.pollAfterInterval()
		w.pollAfterInterval()
		w.wantActive(transport.KindCloudKit)
	})
}

func wantUnavailable(t *testing.T, ph *hubtest.Phone) {
	t.Helper()
	for _, c := range ph.Controls {
		if c.Kind == wire.ControlSwitchRejected && *c.Reason == wire.SwitchUnavailable && c.RetryAfterS != nil && *c.RetryAfterS == 60 {
			return
		}
	}
	t.Fatalf("no unavailable with its wait: %+v", ph.Controls)
}

// A request the record cannot take (switched_at unreadable) is answered
// unavailable, as it was in the pass, and leaves the list: a press toward iCloud
// behind it is told where the hub runs at once.
func TestARequestTheRecordCannotTakeIsAnsweredAndThePressBehindGoesOn(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		if err := w.st.SetMeta(switcher.MetaSwitchedAt, "unreadable"); err != nil {
			t.Fatal(err)
		}
		w.ask(a, wire.TransportRelay)
		w.ask(b, wire.TransportCloudKit)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v != "" {
			t.Fatalf("the list is %q %v", v, err)
		}
		for _, ph := range []*hubtest.Phone{a, b} {
			if _, err := ph.Sync(); err != nil {
				t.Fatal(err)
			}
		}
		wantUnavailable(t, a)
		if c, ok := b.LastSwitch(); !ok || *c.Target != wire.TransportCloudKit {
			t.Fatalf("the press behind it was not answered: %+v", b.Controls)
		}
	})
}

// The same head on a hub moving to iCloud: a's press stands, c's press behind
// the refused request is answered, and the hub moves.
func TestARequestTheRecordCannotTakeNeverHoldsTheMoveToICloud(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b, c := w.addPhone(true), w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay, b, c)
		if err := w.st.SetMeta(switcher.MetaSwitchedAt, "unreadable"); err != nil {
			t.Fatal(err)
		}
		for _, ph := range []*hubtest.Phone{a, b, c} {
			w.onCloudKit(ph)
		}
		w.ask(a, wire.TransportCloudKit)
		w.ask(b, wire.TransportRelay)
		w.ask(c, wire.TransportCloudKit)
		w.sw.PollOther(w.ctx)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindCloudKit)
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v != "" {
			t.Fatalf("the list is %q %v", v, err)
		}
		if _, err := b.Sync(); err != nil {
			t.Fatal(err)
		}
		wantUnavailable(t, b)
	})
}

// sealFailing is the hub's keys with one phone's relay key out of reach.
type sealFailing struct {
	secure.KeySource
	w *world
}

func (k sealFailing) RelayKey(dir secure.Direction, device secure.ID, epoch uint32) ([]byte, error) {
	k.w.mu.Lock()
	failed := dir == secure.HubToPhone && device.String() == k.w.noSeal
	k.w.mu.Unlock()
	if failed {
		return nil, errors.New("the key store is out of reach")
	}
	return k.KeySource.RelayKey(dir, device, epoch)
}

func (w *world) failSealsFor(ph *hubtest.Phone) {
	w.mu.Lock()
	w.noSeal = ""
	if ph != nil {
		w.noSeal = ph.ID().String()
	}
	w.mu.Unlock()
}

// sealingCanFail restarts the hub on keys failSealsFor can break.
func (w *world) sealingCanFail() {
	w.t.Helper()
	w.rebuild(func(c *switcher.Config) { c.Actions.Sealer = secure.NewSealer(sealFailing{w.keys, w}) })
}

// An answer that cannot be sealed is kept and retried, its decision kept with
// it (a phone paying by then still hears not_paying), and nobody behind it
// waits.
func TestAnAnswerThatDoesNotSealIsRetriedAndHoldsNobody(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free, b := w.addPhone(false), w.addPhone(true)
		w.moveTo(b, wire.TransportRelay)
		w.sealingCanFail()
		w.failSealsFor(free)
		w.onCloudKit(b)
		w.ask(free, wire.TransportRelay)
		w.ask(b, wire.TransportCloudKit)
		w.sw.PollOther(w.ctx)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantPressActedOn(b)
		// One try per Step, though the Step decided asks twice (around the drain).
		if v, _, err := w.st.Meta("switch_asks"); err != nil || !strings.Contains(v, `"tries":1`) {
			t.Fatalf("the answer was not kept: %q %v", v, err)
		}
		w.failSealsFor(nil)
		w.mu.Lock()
		w.paying[free.ID().String()] = true
		w.mu.Unlock()
		w.rebuild(nil) // a restart keeps it too
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		if _, err := free.Sync(); err != nil {
			t.Fatal(err)
		}
		if got := rejections(free); !slices.Equal(got, []string{wire.SwitchNotPaying}) {
			t.Fatalf("rejections %v", got)
		}
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v != "" {
			t.Fatalf("the list is %q %v", v, err)
		}
	})
}

// The retries are bounded: a key that never returns ends the ask, the phone
// gets no answer, and nothing waits on it any more.
func TestAnAnswerThatNeverSealsIsDroppedAfterItsTries(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free := w.addPhone(false)
		w.sealingCanFail()
		w.failSealsFor(free)
		w.ask(free, wire.TransportRelay)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		for i := range 3 {
			if v, _, err := w.st.Meta("switch_asks"); err != nil || v == "" {
				t.Fatalf("dropped before try %d: %q %v", i+1, v, err)
			}
			if err := w.sw.Step(w.ctx); err != nil {
				t.Fatal(err)
			}
		}
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v != "" {
			t.Fatalf("the list after its tries is %q %v", v, err)
		}
	})
}

// countedPolls counts the reads of the standby relay: one Run loop, one poll.
type countedPolls struct {
	transport.Transport
	n *atomic.Int64
}

func (c countedPolls) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	c.n.Add(1)
	return c.Transport.Changes(ctx, zone, since)
}

// An ask that cannot be finished does not spin Run: it is retried at the run
// loop's tick, not by a kick of its own, so its tries last. The one kick is the
// ask's own, from the pass.
func TestAWaitingAskDoesNotSpinTheRunLoop(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free := w.addPhone(false)
		var polls atomic.Int64
		w.rebuild(func(c *switcher.Config) {
			c.Actions.Sealer = secure.NewSealer(sealFailing{w.keys, w})
			c.Relay = countedPolls{w.relay, &polls}
		})
		w.failSealsFor(free)
		w.ask(free, wire.TransportRelay)
		if _, err := w.sw.Processor(transport.KindCloudKit).Pass(w.ctx); err != nil {
			t.Fatal(err)
		}
		ctx, stop := context.WithCancel(w.ctx)
		done := make(chan struct{})
		go func() { defer close(done); _ = w.sw.Run(ctx) }()
		t.Cleanup(func() { stop(); <-done })
		time.Sleep(2 * testOldSide)     // far longer than a loop
		if n := polls.Load(); n > 2*2 { // two mailboxes at most, two loops
			t.Fatalf("%d relay reads: the run loop spins", n)
		}
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v == "" {
			t.Fatalf("the ask's tries were burned by spinning: %q %v", v, err)
		}
	})
}

// A switch still pending (here the last request undid the first and the Step
// has not settled it) is not replaced by G2's move: only a lost Step leaves one
// behind now that requests are decided in the Step.
func TestG2APendingRecordIsNotOverridden(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := g2World(t, w)
		w.pollAfterInterval() // the first of G2's two reads
		rec := fmt.Sprintf(`{"id":"pending-switch","from":"relay","target":"relay","by":%q,"at":"2026-11-01T12:00:00Z"}`, a.ID().String())
		if err := w.st.SetMeta("transport_switch", rec); err != nil {
			t.Fatal(err)
		}
		w.advance(switcher.NoPayerPoll)
		w.sw.PollOther(w.ctx) // G2's second read would move here
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantActive(transport.KindRelay)
	})
}

// A stale answer that did not seal is decided again at its retry: a free phone
// never hears hub_on_relay from a hub that has moved to iCloud meanwhile.
func TestAKeptStaleAnswerIsDecidedAgainAtItsRetry(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		free, b := w.addPhone(false), w.addPhone(true)
		w.moveTo(b, wire.TransportRelay)
		w.sealingCanFail()
		if _, err := free.Sync(); err != nil {
			t.Fatal(err)
		}
		told := count(free, wire.ControlHubOnRelay)
		w.failSealsFor(free)
		w.act(free)
		w.sw.PollOther(w.ctx)
		if err := w.sw.Step(w.ctx); err != nil { // does not seal: kept
			t.Fatal(err)
		}
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v == "" {
			t.Fatalf("the stale answer was not kept: %q %v", v, err)
		}
		w.onCloudKit(b)
		w.ask(b, wire.TransportCloudKit)
		w.sw.PollOther(w.ctx)
		if err := w.sw.Step(w.ctx); err != nil {
			t.Fatal(err)
		}
		w.wantPressActedOn(b)
		w.failSealsFor(nil)
		if err := w.sw.Step(w.ctx); err != nil { // the key is back, the hub on iCloud
			t.Fatal(err)
		}
		w.sw.PollOther(w.ctx)
		if _, err := free.Sync(); err != nil {
			t.Fatal(err)
		}
		if n := count(free, wire.ControlHubOnRelay); n != told {
			t.Fatalf("%d hub_on_relay from a hub on iCloud, had %d", n, told)
		}
		if v, _, err := w.st.Meta("switch_asks"); err != nil || v != "" {
			t.Fatalf("the list is %q %v", v, err)
		}
	})
}
