package identity_test

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
)

// F19: an unlink is one transaction with its rotation: the removed phone's
// offer and every relay-key row of it go, and the rotation it begins derives
// none for it; another phone's offer still gets its keys.
func TestUnlinkRemovesOfferAndRelayKeys(t *testing.T) {
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	now := func() time.Time { return time.Unix(1_800_000_000, 0) }
	k, err := identity.NewKeyring(id, st, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SetMeta(state.MetaTransport, "relay"); err != nil {
		t.Fatal(err)
	}
	link1, link2 := linkOffered(t, st, 0x11), linkOffered(t, st, 0x22)
	if err := k.Rotate(identity.ReasonManual); err != nil { // epoch 2: both get keys
		t.Fatal(err)
	}
	for _, d := range []secure.ID{link1, link2} {
		if _, ok, _ := st.EpochRelayKeys(2, d.String()); !ok {
			t.Fatal("no relay keys before the unlink")
		}
	}
	c := link.NewCenter(link.Config{Store: st, Keys: k, Clock: now})
	if err := c.Unlink(link1.String()); err != nil {
		t.Fatal(err)
	}
	if cur, _ := k.CurrentEpoch(); cur != 3 {
		t.Fatalf("epoch %d after the unlink, want 3", cur)
	}
	for _, e := range []uint32{2, 3} {
		if _, ok, _ := st.EpochRelayKeys(e, link1.String()); ok {
			t.Fatalf("the unlinked phone keeps relay keys of epoch %d", e)
		}
	}
	if _, ok, _ := st.EpochRelayKeys(3, link2.String()); !ok {
		t.Fatal("the other phone got no keys in the unlink's epoch")
	}
	kk, err := k.KeyboxKeysFor(link1)
	if err != nil || kk.RelayKX != nil || kk.PreviousRelayKX != nil {
		t.Fatalf("the unlinked phone's keybox names relay keys: %+v, %v", kk, err)
	}
}

func linkOffered(t *testing.T, st *state.Store, seed byte) secure.ID {
	t.Helper()
	sig := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, 32)).Public().(ed25519.PublicKey)
	kx, _ := ecdh.X25519().GenerateKey(rand.Reader)
	eph, _ := ecdh.X25519().GenerateKey(rand.Reader)
	nonce := make([]byte, 32)
	_, _ = rand.Read(nonce)
	dev := secure.DeviceID(sig)
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := state.LinkDevice(tx, state.Device{
			ID: dev.String(), Name: "Phone", Scope: "private", LinkedAt: time.Unix(1_800_000_000, 0),
			SigningKey: sig, AgreementKey: kx.PublicKey().Bytes(), LinkNonce: base64.RawURLEncoding.EncodeToString(nonce),
		}); err != nil {
			return err
		}
		_, err := state.SetKXOffer(tx, dev.String(), eph.PublicKey().Bytes(), 1)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return dev
}
