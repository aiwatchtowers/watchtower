package relay

import (
	"errors"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// TestRegistersAsAHubWithoutAttestation (relay "Vouched hubs"): the hub
// registers as DEVICE_KIND_HUB with the registration nonce, its Ed25519
// signature and an empty attestation, logs in with the signature only, and
// reads itself unvouched until a phone slots it.
func TestRegistersAsAHubWithoutAttestation(t *testing.T) {
	h := newHarness(t)
	if err := h.tr.Connect(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	reg := h.relay.Requests("register")
	if len(reg) != 1 {
		t.Fatalf("%d registers", len(reg))
	}
	r := reg[0].GetRegister()
	if r.GetDeviceKind() != relayv1.DeviceKind_DEVICE_KIND_HUB || r.GetAttestation() != nil ||
		len(r.GetSignature()) == 0 || len(r.GetNonce()) == 0 {
		t.Fatalf("register: %v", r)
	}
	logins := h.relay.Requests("login")
	if len(logins) == 0 {
		t.Fatal("no login")
	}
	for _, l := range logins {
		if l.GetLogin().GetAttestation() != nil || len(l.GetLogin().GetSignature()) == 0 {
			t.Fatalf("login: %v", l.GetLogin())
		}
	}
	if h.tr.Vouched() || h.tr.Admitted() {
		t.Fatal("vouched with no phone holding the hub in a slot")
	}
}

// HUB_NOT_VOUCHED on any op maps to transport.ErrNotVouched and clears the
// cached slots (Vouched false), and the hub never registers again for it.
func TestHubNotVouchedClearsVouchedAndNeverReregisters(t *testing.T) {
	h := newHarness(t)
	h.relay.SetAccountState(&relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "phone1", Paying: true}}})
	if err := h.tr.Connect(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	if !h.tr.Vouched() {
		t.Fatal("not vouched with a phone holding the hub")
	}
	h.relay.FailNext("save", relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED)
	_, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", "{}")}})
	if !errors.Is(err, transport.ErrNotVouched) {
		t.Fatalf("save: %v, want ErrNotVouched", err)
	}
	if h.tr.Vouched() || h.tr.Admitted() {
		t.Fatal("still vouched after HUB_NOT_VOUCHED")
	}
	if n := len(h.relay.Requests("register")); n != 1 {
		t.Fatalf("%d registers after HUB_NOT_VOUCHED", n)
	}
}

// Control{SLOT_ADDED} reaches the consumer only after the transport read
// the account state (once), so Vouched already shows the slot.
func TestSlotAddedReadsTheAccountStateFirst(t *testing.T) {
	h := newHarness(t)
	if err := h.tr.Connect(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	if err := h.tr.WatchPairZone(t.Context(), "s1"); err != nil {
		t.Fatal(err)
	}
	reads := len(h.relay.Requests("get_account_state"))
	h.relay.SetAccountState(&relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "phone1", Paying: true}}})
	h.relay.Push(t, &relayv1.Event{Kind: &relayv1.Event_Control{Control: &relayv1.Control{
		Kind: relayv1.ControlKind_CONTROL_KIND_SLOT_ADDED, Detail: "phone1",
	}}})
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ev := <-h.tr.Events():
			if ev.Control == nil || ev.Control.Kind != transport.SlotAdded {
				continue
			}
			if ev.Control.Detail != "phone1" || !h.tr.Vouched() {
				t.Fatalf("SLOT_ADDED %+v, vouched %v", ev.Control, h.tr.Vouched())
			}
			if n := len(h.relay.Requests("get_account_state")) - reads; n != 1 {
				t.Fatalf("%d account-state reads for one SLOT_ADDED", n)
			}
			return
		case <-deadline:
			t.Fatal("no SLOT_ADDED")
		}
	}
}
