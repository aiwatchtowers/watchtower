package relaytest_test

import (
	"encoding/base64"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/relaytest"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
)

func codeOf(err error) relayv1.ErrorCode { return client.Code(err) }

func hubSave(t *testing.T, h *hub, zone string) error {
	t.Helper()
	_, err := h.c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_Save{Save: &relayv1.Save{Items: []*relayv1.SaveItem{{
		Record: &relayv1.Record{Zone: zone, Name: "r", Envelope: []byte{1}},
	}}}}})
	return err
}

// An unvouched hub may read its account state, use its pair/ zones and
// subscribe; its data zone, a mailbox, set_hub_readers and add_slot answer
// HUB_NOT_VOUCHED. Vouched (in a phone's slot), the data zone opens.
func TestUnvouchedHubIsGatedUntilSlotted(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	_, store := newPhone(t, srv, h)
	data := transport.DataZone(h.relayID)

	if _, err := h.tr.AccountState(t.Context()); err != nil {
		t.Fatalf("account state: %v", err)
	}
	if err := hubSave(t, h, transport.PairZone("slot1")); err != nil {
		t.Fatalf("pair zone save: %v", err)
	}
	for name, err := range map[string]error{
		"data zone save": hubSave(t, h, data),
		"mailbox save":   hubSave(t, h, transport.MailboxZone(h.relayID, "phone")),
		"set_hub_readers": func() error {
			_, err := h.c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_SetHubReaders{SetHubReaders: &relayv1.SetHubReaders{}}})
			return err
		}(),
		"changes": func() error {
			_, err := h.c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_Changes{Changes: &relayv1.Changes{Zone: data}}})
			return err
		}(),
	} {
		if codeOf(err) != relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED {
			t.Errorf("%s: %v, want HUB_NOT_VOUCHED", name, err)
		}
		if !errors.Is(relay.MapError(err), transport.ErrNotVouched) {
			t.Errorf("%s maps to %v, want transport.ErrNotVouched", name, relay.MapError(err))
		}
	}

	addSlot(t, store, h)
	if err := hubSave(t, h, data); err != nil {
		t.Fatalf("data zone save once vouched: %v", err)
	}
}

// promote_pairing and add_slot of a hub not yet in the phone's slots need a
// live pending vouch of that phone: none, an expired one (10 minutes) or
// one already consumed answers HUB_NOT_VOUCHED, and the pairing slot stays.
// A hub already in the slots needs none.
func TestPendingVouchIsNeededLivesTenMinutesAndIsConsumed(t *testing.T) {
	srv := relaytest.Start(t)
	now := time.Unix(1_800_000_000, 0)
	srv.SetNow(func() time.Time { return now })
	h := newHub(t, srv)
	_, store := newPhone(t, srv, h)
	slot, err := store.OpenPairing(t.Context(), h.relayID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.PromotePairing(t.Context(), slot); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED {
		t.Fatalf("promote without a vouch: %v", err)
	}
	vouch(t, store, h)
	now = now.Add(relaytest.VouchTTL)
	if err := store.PromotePairing(t.Context(), slot); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED {
		t.Fatalf("promote after the vouch expired: %v", err)
	}
	vouch(t, store, h)
	if err := store.PromotePairing(t.Context(), slot); err != nil {
		t.Fatalf("promote within the vouch: %v", err)
	}
	if err := addSlotOnly(t, store, h.relayID); err != nil {
		t.Fatalf("add_slot of a hub already slotted: %v", err)
	}

	other := newHub(t, srv)
	vouch(t, store, other)
	if err := addSlotOnly(t, store, other.relayID); err != nil {
		t.Fatal(err)
	}
	srv.RemoveSlot(store.C.DeviceID(), other.relayID)
	if err := addSlotOnly(t, store, other.relayID); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED {
		t.Fatalf("a consumed vouch was used again: %v", err)
	}
}

// vouch_hub answers in the relay's order: a hub caller FORBIDDEN, a phone
// that does not pay ENTITLEMENT_INACTIVE, a nonce that is not this phone's
// unused VOUCH nonce ATTESTATION_FAILED, a key that is not the hub's (or no
// registered hub) NOT_FOUND, a full account SLOT_LIMIT.
func TestVouchHubChecksInTheRelaysOrder(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	p, store := newPhone(t, srv, h)
	vouchWith := func(c *client.Client, nonce []byte, hubID string, pub []byte) error {
		_, err := c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_VouchHub{VouchHub: &relayv1.VouchHub{
			HubDeviceId: hubID, AuthPub: pub, Nonce: nonce,
		}}})
		return err
	}
	challenge := func(c *client.Client) []byte {
		ch, err := c.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_Challenge{Challenge: &relayv1.GetChallenge{
			DeviceId: c.DeviceID(), Purpose: relayv1.ChallengePurpose_CHALLENGE_PURPOSE_VOUCH,
		}}})
		if err != nil {
			t.Fatal(err)
		}
		return ch.GetChallenge().GetNonce()
	}
	if err := vouchWith(h.c, challenge(h.c), h.relayID, h.sig); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_FORBIDDEN {
		t.Errorf("a hub vouching: %v", err)
	}
	nonce := challenge(store.C)
	if err := vouchWith(store.C, nonce, h.relayID, h.sig); err != nil {
		t.Fatal(err)
	}
	if err := vouchWith(store.C, nonce, h.relayID, h.sig); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED {
		t.Errorf("a spent nonce: %v", err)
	}
	if err := vouchWith(store.C, []byte("made-up"), h.relayID, h.sig); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED {
		t.Errorf("a nonce never issued: %v", err)
	}
	other := newHub(t, srv)
	if err := vouchWith(store.C, challenge(store.C), h.relayID, other.sig); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_NOT_FOUND {
		t.Errorf("a key that is not the hub's: %v", err)
	}
	for range 3 {
		addSlot(t, store, newHub(t, srv))
	}
	if err := vouchWith(store.C, challenge(store.C), h.relayID, h.sig); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_SLOT_LIMIT {
		t.Errorf("a full account: %v", err)
	}
	srv.SetPaying(p.RelayDeviceID(), false)
	if err := vouchWith(store.C, challenge(store.C), h.relayID, h.sig); codeOf(err) != relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE {
		t.Errorf("a phone that does not pay: %v", err)
	}
}

// SLOT_ADDED reaches a hub's open socket when a phone slots it (detail: the
// phone) and is dropped when it has none; the gate holds on a socket opened
// while the hub was vouched once it leaves its last slot.
func TestSlotAddedIsBestEffortAndTheGateHoldsOnAnOpenSocket(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	p, store := newPhone(t, srv, h)
	ws := dialWS(t, srv, h.relayID)
	subscribeWS(t, ws, "pair/x")
	addSlot(t, store, h)
	if c := readFrame(t, ws, 5*time.Second).GetEvent().GetControl(); c.GetKind() != relayv1.ControlKind_CONTROL_KIND_SLOT_ADDED || c.GetDetail() != p.RelayDeviceID() {
		t.Fatalf("SLOT_ADDED: %v", c)
	}

	srv.RemoveSlot(p.RelayDeviceID(), h.relayID)
	if c := readFrame(t, ws, 5*time.Second).GetEvent().GetControl(); c.GetKind() != relayv1.ControlKind_CONTROL_KIND_SLOT_REMOVED {
		t.Fatalf("SLOT_REMOVED: %v", c)
	}
	b, _ := proto.Marshal(&relayv1.Frame{Kind: &relayv1.Frame_Request{Request: &relayv1.Request{
		Id: 9, Op: &relayv1.Request_SetHubReaders{SetHubReaders: &relayv1.SetHubReaders{}},
	}}})
	if err := ws.Write(t.Context(), websocket.MessageBinary, b); err != nil {
		t.Fatal(err)
	}
	if r := readFrame(t, ws, 5*time.Second).GetResponse(); r.GetError().GetCode() != relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED {
		t.Fatalf("an op on the open socket of an unslotted hub: %v", r)
	}

	offline := newHub(t, srv) // no socket when it is slotted
	addSlot(t, store, offline)
	next := dialWS(t, srv, offline.relayID)
	if fr := readFrame(t, next, 300*time.Millisecond); fr != nil {
		t.Fatalf("a SLOT_ADDED with no socket was kept for the next one: %v", fr)
	}
}

// The Go phone's vouch carries the hub's id and key from the link code and
// a fresh VOUCH nonce of its own, and no attestation.
func TestPhoneVouchSendsAChallengeThenVouchHub(t *testing.T) {
	srv := relaytest.Start(t)
	h := newHub(t, srv)
	p, store := newPhone(t, srv, h)
	lp := wire.LinkPayload{RelayDeviceID: h.relayID, RelayAuthPub: base64.RawURLEncoding.EncodeToString(h.sig)}
	if err := p.VouchLink(t.Context(), lp); err != nil {
		t.Fatal(err)
	}
	if err := p.VouchLink(t.Context(), lp); err != nil {
		t.Fatal(err)
	}
	ch := srv.Requests("challenge")
	vh := srv.Requests("vouch_hub")
	if len(vh) != 2 || vh[0].GetVouchHub().GetHubDeviceId() != h.relayID || !slices.Equal(vh[0].GetVouchHub().GetAuthPub(), h.sig) ||
		vh[0].GetVouchHub().GetAttestation() != nil || slices.Equal(vh[0].GetVouchHub().GetNonce(), vh[1].GetVouchHub().GetNonce()) {
		t.Fatalf("vouch_hub requests: %v", vh)
	}
	vouchChallenges := 0
	for _, c := range ch {
		if c.GetChallenge().GetPurpose() == relayv1.ChallengePurpose_CHALLENGE_PURPOSE_VOUCH {
			vouchChallenges++
			if c.GetChallenge().GetDeviceId() != store.C.DeviceID() {
				t.Fatalf("a VOUCH challenge for %q, want the phone's own id", c.GetChallenge().GetDeviceId())
			}
		}
	}
	if vouchChallenges != 2 {
		t.Fatalf("%d VOUCH challenges for two vouches", vouchChallenges)
	}

	memPhone, err := hubtest.New(hubtest.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := memPhone.VouchLink(t.Context(), lp); err == nil {
		t.Fatal("a phone off the relay vouched")
	}
}
