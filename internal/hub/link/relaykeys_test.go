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
