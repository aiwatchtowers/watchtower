package hub

import (
	"context"
	"strings"
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
// confirm and when an account read newly lists a linked phone, so a phone
// that linked a CloudKit Mac over a Relay pairing slot and pays moves the
// hub to the relay at once, not at the check's next NoPayerPoll.

// slotCode asks for a code on c (a CloudKit code, or the relay code a Mac
// without iCloud falls back to), parses it and makes the phone that scans it
// (over the relay fake). The bubble's clock moves on a second first: a
// relay-linked candidate is linked after hub_meta relay_link_since (written
// at the hub's start, whole seconds), as any code shown to a person is.
func slotCode(t *testing.T, r *deskRig, c *ControlClient) (wire.LinkPayload, *hubtest.Phone) {
	t.Helper()
	time.Sleep(time.Second)
	qr := pairStep(t, c, ControlRequest{Op: OpPair}, link.EventQR)[link.EventQR]
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	if lp.RelayDeviceID == "" {
		t.Fatalf("the code names no relay: %+v", lp)
	}
	phone, err := hubtest.FromLink(lp, r.fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	return lp, phone
}

// pairOverSlot links phone through a Relay pairing slot,
// the way a paying iPhone does with a CloudKit code that offers Relay: its
// hello (a relay device id, no iCloud user) in pair/slot1, PAIRING_OPENED,
// the SAS on c's stream, then the owner's confirm. It returns the bubble's
// time just before the confirm was sent.
func pairOverSlot(t *testing.T, r *deskRig, c *ControlClient, phone *hubtest.Phone) time.Time {
	t.Helper()
	pair := transport.PairZone("slot1")
	if err := phone.Hello(pair); err != nil {
		t.Fatal(err)
	}
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "slot1"}})
	for {
		a, err := c.Next()
		if err != nil {
			t.Fatalf("waiting for the SAS: %v", err)
		}
		if a.Error != "" {
			t.Fatalf("waiting for the SAS: %+v", a)
		}
		if a.Event == link.EventSAS {
			break
		}
	}
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
	pairStep(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}, link.EventLinked)
	return at
}

// payingAccount lists the phone's relay id in the hub's slot, paying.
func payingAccount(p *hubtest.Phone) *relayv1.AccountState {
	return &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: p.RelayDeviceID(), Paying: true}}}
}

// kicked bounds the bubble time from a confirm to the switch it leads to:
// far under the switcher's own cadence (OtherPoll), so only a kick meets it.
const kicked = time.Second

// onRelayBy waits until the hub runs on the relay and checks the switch was
// made by phone less than within after since: a kick, not the switcher's
// own cadence, ran the check.
func onRelayBy(t *testing.T, r *deskRig, phone *hubtest.Phone, since time.Time, within time.Duration) Status {
	t.Helper()
	var got Status
	r.waitStatus("running on the relay", func(s Status) bool {
		got = s
		return s.State == StateRunning && s.Transport == string(transport.KindRelay)
	})
	if took := time.Since(since); took >= within {
		t.Fatalf("the switch came %v after its cause, want under %v: no kick", took, within)
	}
	if !strings.EqualFold(got.SwitchedBy, phone.ID().String()) {
		t.Fatalf("switched_by %q, want the phone %s", got.SwitchedBy, phone.ID())
	}
	return got
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
		r.fake.SetAccountState(payingAccount(phone))
		r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.SlotAdded}})
		onRelayBy(t, r, phone, at, switcher.OtherPoll)
	})
}

// The account already lists the phone paying when the owner confirms: the
// confirm alone (no SLOT_ADDED) runs the check.
func TestRelayPairingKicksOnTheConfirm(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startPairDesk(t, transport.KindCloudKit)
		_, phone := slotCode(t, r, c)
		r.fake.SetAccountState(payingAccount(phone))
		onRelayBy(t, r, phone, pairOverSlot(t, r, c, phone), kicked)
	})
}

// F7 at runtime (Review Focus): iCloud is gone before the code is asked for,
// so the Mac shows a relay code; the phone links over the slot, and the hub
// moves to the relay with its CloudKit side held: the status leaves
// paused/no_icloud and the publisher writes the relay data zone.
func TestRelayPairingOnADesktopWithoutICloudSwitches(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, c := startPairDesk(t, transport.KindCloudKit)
		ck.acct.Store(transport.AccountNoAccount)
		r.waitState(StatePaused, ReasonNoICloud)
		lp, phone := slotCode(t, r, c)
		if lp.Transport != wire.TransportRelay {
			t.Fatalf("want the relay code fallback, got %q", lp.Transport)
		}
		r.fake.SetAccountState(payingAccount(phone))
		s := onRelayBy(t, r, phone, pairOverSlot(t, r, c, phone), kicked)
		if s.Reason != "" {
			t.Fatalf("still %s/%s on the relay", s.State, s.Reason)
		}
		zone := transport.DataZone(s.RelayDeviceID)
		eventually(t, "a record in the relay data zone", func() bool {
			b, err := r.fake.Changes(context.Background(), zone, 0)
			if err != nil {
				t.Fatal(err)
			}
			return len(b.Changed) > 0
		})
	})
}
