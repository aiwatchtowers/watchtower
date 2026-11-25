package hub

import (
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
)

// #2191 Task 3: the runtime asks the switcher for its relay-link check on a
// confirm that links and when an account read newly lists a linked phone, so
// a phone that linked a CloudKit Mac over a Relay pairing slot and pays moves
// the hub to the relay at once, not at the check's next NoPayerPoll.

// kicked bounds the bubble time from a confirm to the switch it leads to.
// With holdUpkeep the only other path to the check is the switcher's own
// cadence (OtherPoll, then NoPayerPoll between reads), so only the confirm's
// kick meets it.
const kicked = time.Second

// holdUpkeep keeps the link upkeep's account reads out of the way (its short
// retry after a link never fires, its backstop is an hour): such a read newly
// lists a phone and kicks the check through markAdmitted, a second path that
// would hide a missing confirm kick.
func holdUpkeep(o *Options) {
	o.linkEvery = time.Hour
	o.soonTimer = func(time.Duration) (<-chan time.Time, func()) { return nil, func() {} }
}

// slotCode asks for a code on c (a CloudKit code, or the relay code a Mac
// without iCloud falls back to), parses it and makes the phone that scans it
// (over the relay fake).
func slotCode(t *testing.T, r *deskRig, c *ControlClient) (wire.LinkPayload, *hubtest.Phone) {
	t.Helper()
	lp := newCode(t, c)
	phone, err := hubtest.FromLink(lp, r.fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	return lp, phone
}

// newCode asks for a code on c and parses it.
func newCode(t *testing.T, c *ControlClient) wire.LinkPayload {
	t.Helper()
	qr := pairStep(t, c, ControlRequest{Op: OpPair}, link.EventQR)[link.EventQR]
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	if lp.RelayDeviceID == "" {
		t.Fatalf("the code names no relay: %+v", lp)
	}
	return lp
}

// answerOverSlot brings phone's hello to the hub through the Relay pairing
// slot slot, the way a paying iPhone does with a CloudKit code that offers
// Relay: the hello (a relay device id, no iCloud user) in pair/<slot>,
// PAIRING_OPENED, the SAS on c's stream; then the owner's answer, Link when
// confirm. It returns the bubble's time just before the answer was sent.
func answerOverSlot(t *testing.T, r *deskRig, c *ControlClient, phone *hubtest.Phone, slot string, confirm bool) time.Time {
	t.Helper()
	helloOverSlot(t, r, c, phone, slot)
	if !confirm {
		at := time.Now()
		pairStep(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String()})
		return at
	}
	return linkShown(t, c, phone, slot)
}

// helloOverSlot writes phone's hello into pair/<slot>, sends PAIRING_OPENED
// and waits for the SAS on c's stream.
func helloOverSlot(t *testing.T, r *deskRig, c *ControlClient, phone *hubtest.Phone, slot string) {
	t.Helper()
	if err := phone.Hello(transport.PairZone(slot)); err != nil {
		t.Fatal(err)
	}
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: slot}})
	for {
		a, err := c.Next()
		if err != nil {
			t.Fatalf("waiting for the SAS: %v", err)
		}
		if a.Error != "" {
			t.Fatalf("waiting for the SAS: %+v", a)
		}
		if a.Event == link.EventSAS {
			return
		}
	}
}

// linkShown is the phone comparing the SAS of its waiting request in
// pair/<slot> and the owner's Link on c. It returns the bubble's time just
// before the Link was sent.
func linkShown(t *testing.T, c *ControlClient, phone *hubtest.Phone, slot string) time.Time {
	t.Helper()
	pair := transport.PairZone(slot)
	req := ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}
	var awaiting wire.Keybox
	eventually(t, "the awaiting keybox in the pair zone", func() bool {
		kb, ok, err := phone.ReadKeybox(pair)
		if err != nil {
			t.Fatal(err)
		}
		awaiting = kb
		return ok && kb.Grant.ConfirmNonce != nil
	})
	if _, err := phone.SAS(*awaiting.Grant.ConfirmNonce); err != nil {
		t.Fatal(err)
	}
	at := time.Now()
	pairStep(t, c, req, link.EventLinked)
	return at
}

// pairOverSlot links phone through pair/slot1 (answerOverSlot, Link).
func pairOverSlot(t *testing.T, r *deskRig, c *ControlClient, phone *hubtest.Phone) time.Time {
	t.Helper()
	return answerOverSlot(t, r, c, phone, "slot1", true)
}

// account lists the phone's relay id in the hub's slot, paying or not.
func account(p *hubtest.Phone, paying bool) *relayv1.AccountState {
	return &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: p.RelayDeviceID(), Paying: paying}}}
}

// onRelayBy waits until the hub runs on the relay, failing once the bubble
// passes since+within (with the last status) instead of waiting for ever,
// and checks the switch was made by phone.
func onRelayBy(t *testing.T, r *deskRig, phone *hubtest.Phone, since time.Time, within time.Duration) Status {
	t.Helper()
	deadline := since.Add(within)
	for {
		s, changed := r.rec.lastAndChanged()
		left := time.Until(deadline)
		if left <= 0 {
			t.Fatalf("not on the relay under %v after the cause (no kick): last status %s/%s on %s",
				within, s.State, s.Reason, s.Transport)
		}
		if s.State == StateRunning && s.Transport == string(transport.KindRelay) {
			if !strings.EqualFold(s.SwitchedBy, phone.ID().String()) {
				t.Fatalf("switched_by %q, want the phone %s", s.SwitchedBy, phone.ID())
			}
			return s
		}
		select {
		case <-changed:
		case <-time.After(left):
		}
	}
}

// The phone is not in the hub's slot at the confirm: the confirm's check
// reads it unlisted and waits, and SLOT_ADDED (the phone's promote) newly
// lists it paying, which runs the check again at once — never at the next
// NoPayerPoll. The relay fake has no relayAdmission, so the read that lists
// the phone is the link upkeep's that SLOT_ADDED asks for (on its short
// retry tick), not the transport's own: within one OtherPoll, while the
// check's own next read would come a NoPayerPoll after the confirm's.
func TestRelayPairingOnACloudKitDesktopSwitches(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startPairDesk(t, transport.KindCloudKit)
		r.fake.SetAccountState(&relayv1.AccountState{})
		lp, phone := slotCode(t, r, c)
		if lp.Transport != wire.TransportCloudKit {
			t.Fatalf("want a CloudKit code, got %q", lp.Transport)
		}
		pairOverSlot(t, r, c, phone)
		r.cycles(1)
		if s := r.rec.last(); s.Transport != string(transport.KindCloudKit) {
			t.Fatalf("moved before the phone was listed paying: %+v", s)
		}
		at := time.Now()
		r.fake.SetAccountState(account(phone, true))
		r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.SlotAdded}})
		onRelayBy(t, r, phone, at, switcher.OtherPoll)
	})
}

// The account already lists the phone paying when the owner confirms: the
// confirm alone (no SLOT_ADDED, the link upkeep held) runs the check.
func TestRelayPairingKicksOnTheConfirm(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startPairDesk(t, transport.KindCloudKit, holdUpkeep)
		_, phone := slotCode(t, r, c)
		r.fake.SetAccountState(account(phone, true))
		onRelayBy(t, r, phone, pairOverSlot(t, r, c, phone), kicked)
	})
}

// A confirm that links nothing kicks nothing: the owner declines a re-link
// of a phone linked over a slot (its row is there, linked) after its
// account started paying. The check already read it not paying, so with no
// kick it does not read again before NoPayerPoll and the hub stays on
// CloudKit.
func TestRelayPairingDeclinedRelinkDoesNotKick(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startPairDesk(t, transport.KindCloudKit, holdUpkeep)
		_, phone := slotCode(t, r, c)
		r.fake.SetAccountState(account(phone, false))
		pairOverSlot(t, r, c, phone)
		r.cycles(1) // the confirm's check read it not paying
		r.fake.SetAccountState(account(phone, true))
		if err := phone.UseLink(newCode(t, c)); err != nil {
			t.Fatal(err)
		}
		answerOverSlot(t, r, c, phone, "slot2", false)
		time.Sleep(10 * kicked)
		if s := r.rec.last(); s.Transport != string(transport.KindCloudKit) {
			t.Fatalf("a declined re-link moved the hub: %s/%s on %s", s.State, s.Reason, s.Transport)
		}
	})
}

// The request-bound confirm (hubRuntime.confirm) kicks only when it links:
// a no_request answer (the phone already linked, nothing waits) and a
// code_changed answer (the owner answered another code than the one shown)
// leave the hub on CloudKit although the account now lists the phone
// paying; the Link of the request shown then moves it at once.
func TestRelayPairingRequestBoundConfirmKicksOnlyOnALink(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startPairDesk(t, transport.KindCloudKit, holdUpkeep)
		_, phone := slotCode(t, r, c)
		r.fake.SetAccountState(account(phone, false))
		pairOverSlot(t, r, c, phone)
		r.cycles(1) // the confirm's check read it not paying
		r.fake.SetAccountState(account(phone, true))
		stays := func(what string) {
			t.Helper()
			time.Sleep(10 * kicked)
			if s := r.rec.last(); s.Transport != string(transport.KindCloudKit) {
				t.Fatalf("%s moved the hub: %s/%s on %s", what, s.State, s.Reason, s.Transport)
			}
		}
		device := phone.ID().String()
		if a := confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: device, Confirm: true}); a.Error != ErrClassNoRequest {
			t.Fatalf("a confirm with nothing waiting answered %+v, want %s", a, ErrClassNoRequest)
		}
		stays(ErrClassNoRequest)
		if err := phone.UseLink(newCode(t, c)); err != nil {
			t.Fatal(err)
		}
		helloOverSlot(t, r, c, phone, "slot2")
		a := confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: device, Confirm: true, Code: "not the code shown"})
		if a.Error != ErrClassCodeChanged {
			t.Fatalf("a confirm of another code answered %+v, want %s", a, ErrClassCodeChanged)
		}
		stays(ErrClassCodeChanged)
		onRelayBy(t, r, phone, linkShown(t, c, phone, "slot2"), kicked)
	})
}

// F7 at runtime (Review Focus): iCloud is gone before the code is asked for,
// so the Mac shows a relay code; the phone links over the slot, and the hub
// moves to the relay with its CloudKit side held: the status leaves
// paused/no_icloud and the publisher writes its heartbeat into the relay
// data zone.
func TestRelayPairingOnADesktopWithoutICloudSwitches(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, c := startPairDesk(t, transport.KindCloudKit, holdUpkeep)
		ck.acct.Store(transport.AccountNoAccount)
		r.cycles(1)
		r.waitState(StatePaused, ReasonNoICloud)
		lp, phone := slotCode(t, r, c)
		if lp.Transport != wire.TransportRelay {
			t.Fatalf("want the relay code fallback, got %q", lp.Transport)
		}
		r.fake.SetAccountState(account(phone, true))
		s := onRelayBy(t, r, phone, pairOverSlot(t, r, c, phone), kicked)
		if s.Reason != "" {
			t.Fatalf("still %s/%s on the relay", s.State, s.Reason)
		}
		zone := transport.DataZone(s.RelayDeviceID)
		eventually(t, "the heartbeat in the relay data zone", func() bool {
			return slices.Contains(liveRecords(t, r.fake, zone), "heartbeat")
		})
	})
}

// Review Focus: the iCloud account dies after a CloudKit code that offers
// Relay was shown and before the switch. The phone still links over the
// slot, and the switch to Relay completes with CloudKit held: once
// switchedTo re-runs applyICloudHold on the new active transport, the
// publisher's iCloud hold lifts (it publishes the heartbeat on the relay)
// while CloudKit's own side stays held. The account lists the phone paying
// before the owner's Link, so the confirm's kick alone runs the check.
func TestRelayPairingWhenICloudDiesAfterTheCodeSwitches(t *testing.T) {
	bubble(t, func(t *testing.T) {
		var rt atomic.Pointer[hubRuntime]
		r, ck, c := startPairDesk(t, transport.KindCloudKit, holdUpkeep, func(o *Options) {
			o.started = func(h *hubRuntime) { rt.Store(h) }
		})
		lp, phone := slotCode(t, r, c)
		if lp.Transport != wire.TransportCloudKit || !slices.Contains(lp.Transports, wire.TransportRelay) {
			t.Fatalf("want a CloudKit code that offers Relay, got %q %v", lp.Transport, lp.Transports)
		}
		ck.acct.Store(transport.AccountNoAccount)
		r.cycles(1)
		r.waitState(StatePaused, ReasonNoICloud)
		h := rt.Load()
		if !h.ckPubHeld.Load() {
			t.Fatal("the publisher is not held while CloudKit is active without iCloud")
		}
		r.fake.SetAccountState(account(phone, true))
		s := onRelayBy(t, r, phone, pairOverSlot(t, r, c, phone), kicked)
		if s.Reason != "" {
			t.Fatalf("still %s/%s on the relay", s.State, s.Reason)
		}
		if h.ckPubHeld.Load() {
			t.Fatal("the publisher's iCloud hold did not lift on the relay")
		}
		h.ckHoldMu.Lock()
		held := h.ckHeld
		h.ckHoldMu.Unlock()
		if !held {
			t.Fatal("CloudKit's side is no longer held without iCloud")
		}
		zone := transport.DataZone(s.RelayDeviceID)
		eventually(t, "the heartbeat in the relay data zone", func() bool {
			return slices.Contains(liveRecords(t, r.fake, zone), "heartbeat")
		})
	})
}
