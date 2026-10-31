package relay

import (
	"slices"
	"testing"

	"watchtower/internal/hub/transport/relay/relayv1"
)

func TestRelayTransport_WatchPairZoneSubscribes(t *testing.T) {
	h := newHarness(t)
	if err := h.tr.WatchPairZone(t.Context(), "slot1"); err == nil {
		t.Fatal("watched a pair zone before Connect")
	}
	if err := h.tr.Connect(t.Context(), []string{h.data}); err != nil {
		t.Fatal(err)
	}
	waitZoneEvent(t, h.tr, h.data)
	if err := h.tr.WatchPairZone(t.Context(), "slot1"); err != nil {
		t.Fatal(err)
	}
	h.relay.mu.Lock()
	subscribed := slices.Clone(h.relay.subscribed)
	h.relay.mu.Unlock()
	if !slices.Contains(subscribed, "pair/slot1") {
		t.Fatalf("pair zone not subscribed: %v", subscribed)
	}
	for _, bad := range []string{"", "a/b"} {
		if err := h.tr.WatchPairZone(t.Context(), bad); err == nil {
			t.Errorf("slot %q accepted", bad)
		}
	}
}

func TestRelayTransport_WatchZoneSubscribesAMailbox(t *testing.T) {
	h := newHarness(t)
	box := "relay/" + h.tr.o.HubRelayID + "/phone1"
	if err := h.tr.WatchZone(t.Context(), box); err == nil {
		t.Fatal("watched a zone before Connect")
	}
	if err := h.tr.Connect(t.Context(), []string{h.data}); err != nil {
		t.Fatal(err)
	}
	waitZoneEvent(t, h.tr, h.data)
	if err := h.tr.WatchZone(t.Context(), box); err != nil {
		t.Fatal(err)
	}
	h.relay.mu.Lock()
	subscribed := slices.Clone(h.relay.subscribed)
	h.relay.mu.Unlock()
	if !slices.Contains(subscribed, box) {
		t.Fatalf("mailbox not subscribed: %v", subscribed)
	}
	for _, bad := range []string{"", "pair/slot1"} {
		if err := h.tr.WatchZone(t.Context(), bad); err == nil {
			t.Errorf("zone %q accepted", bad)
		}
	}
}

// TestRelayTransport_SetLinkedReadersKeepsSlottedPhones: the relay refuses a
// whole set_hub_readers naming a phone that does not hold the hub in a slot
// (a phone confirmed but not yet promoted), so only slotted phones are sent,
// read from a fresh account state.
func TestRelayTransport_SetLinkedReadersKeepsSlottedPhones(t *testing.T) {
	h := newHarness(t)
	h.relay.account = &relayv1.AccountState{Phones: []*relayv1.SlotHolder{
		{PhoneDeviceId: "p1", Paying: true}, {PhoneDeviceId: "p3", Paying: false},
	}}
	if err := h.tr.SetLinkedReaders(t.Context(), []string{"p3", "p2", "p1"}); err != nil {
		t.Fatal(err)
	}
	if n := len(h.relay.requests("get_account_state")); n != 1 {
		t.Fatalf("account state reads: %d", n)
	}
	if got := h.relay.readers; len(got) != 1 || !slices.Equal(got[0], []string{"p1", "p3"}) {
		t.Fatalf("readers: %v", got)
	}
	// No linked phone: the set is cleared.
	if err := h.tr.SetLinkedReaders(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	if got := h.relay.readers; len(got) != 2 || len(got[1]) != 0 {
		t.Fatalf("readers after clearing: %v", got)
	}
	// A failed account read sends nothing.
	h.relay.failNext("get_account_state", relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
	if err := h.tr.SetLinkedReaders(t.Context(), []string{"p1"}); err == nil {
		t.Fatal("no error when the account state could not be read")
	}
	if got := h.relay.readers; len(got) != 2 {
		t.Fatalf("readers sent without an account state: %v", got)
	}
}
