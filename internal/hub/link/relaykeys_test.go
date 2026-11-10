package link

import (
	"bytes"
	"context"
	"database/sql"
	"testing"

	"watchtower/internal/hub/state"
)

// An unlink takes the phone's offer (with its row) and its per-epoch relay
// keys: nothing derived for that link outlives it.
func TestUnlinkClearsRelayKeys(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	epoch, err := r.kr.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	k := state.EpochRelayKeys{Epoch: epoch, DeviceID: a.id.String(), HubPub: bytes.Repeat([]byte{1}, 32),
		DevicePub: bytes.Repeat([]byte{2}, 32), SealedKeys: []byte{3}}
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.InsertEpochRelayKeys(tx, k) }); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := r.st.EpochRelayKeys(epoch, a.id.String()); err != nil || ok {
		t.Fatalf("relay keys after unlink: %v %v", ok, err)
	}
}

// Relay client Phase 5, Task 17: the phone ended its link at the term while the
// hub kept its row (the farewell was refused). Linking again, with a new link
// nonce, starts with no offer and no per-epoch relay keys: nothing derived under
// the old link reaches the new one (Task 2's clear in state.LinkDevice).
func TestRelinkAfterTheTermClearsOfferAndRelayKeys(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	r.toRelay()
	r.offer(a)
	epoch, err := r.kr.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	k := state.EpochRelayKeys{Epoch: epoch, DeviceID: a.id.String(), HubPub: bytes.Repeat([]byte{1}, 32),
		DevicePub: bytes.Repeat([]byte{2}, 32), SealedKeys: []byte{3}}
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.InsertEpochRelayKeys(tx, k) }); err != nil {
		t.Fatal(err)
	}
	if has, err := r.st.HasDeviceKX(a.id.String()); err != nil || !has {
		t.Fatalf("before the re-link: offer or rows %v %v", has, err)
	}

	// The phone's row stayed on the hub; the same phone links again with a new code.
	r.confirmLinked(a)

	if has, err := r.st.HasDeviceKX(a.id.String()); err != nil || has {
		t.Fatalf("after the re-link: offer or rows left %v %v", has, err)
	}
	if _, ok, err := r.st.EpochRelayKeys(epoch, a.id.String()); err != nil || ok {
		t.Fatalf("relay keys after the re-link: %v %v", ok, err)
	}
}
