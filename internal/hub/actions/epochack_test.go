package actions

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// relayWorld is a hub on the relay, as the switcher records it.
func relayWorld(t *testing.T) *world {
	t.Helper()
	w := newWorld(t, transport.KindRelay)
	if err := w.st.SetMeta(state.MetaTransport, string(transport.KindRelay)); err != nil {
		t.Fatal(err)
	}
	return w
}

func freshOffer(t *testing.T) []byte {
	t.Helper()
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k.PublicKey().Bytes()
}

// ackWithOffer writes an epoch_ack of the current epoch carrying nextKX and
// runs a pass; it returns the epoch.
func (w *world) ackWithOffer(nextKX string) uint32 {
	w.t.Helper()
	epoch, err := w.keys.CurrentEpoch()
	if err != nil {
		w.t.Fatal(err)
	}
	if _, err := w.phone.WriteControl(wire.Control{Kind: wire.ControlEpochAck, Epoch: &epoch, NextKX: &nextKX}); err != nil {
		w.t.Fatal(err)
	}
	w.pass()
	w.wantEmptyMailbox()
	return epoch
}

func TestEpochAckStoresOffer(t *testing.T) {
	w := relayWorld(t)
	pub := freshOffer(t)
	epoch := w.ackWithOffer(base64.RawURLEncoding.EncodeToString(pub))
	d := w.device(w.phone)
	if d.AckedEpoch != epoch || !bytes.Equal(d.KXOffer, pub) || d.KXOfferEpoch != epoch {
		t.Fatalf("device after the ack: acked %d, offer %x @%d; want %d, %x", d.AckedEpoch, d.KXOffer, d.KXOfferEpoch, epoch, pub)
	}
}

func TestBadOfferIsIgnoredAckStillCounted(t *testing.T) {
	one := make([]byte, 32)
	one[0] = 1 // u = 1: a low-order point, its exchange is all zero
	for name, offer := range map[string]string{
		"short":          base64.RawURLEncoding.EncodeToString(make([]byte, 16)),
		"long":           base64.RawURLEncoding.EncodeToString(make([]byte, 33)),
		"not base64url":  "not+a/key==",
		"all-zero point": base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
		"low order":      base64.RawURLEncoding.EncodeToString(one),
	} {
		t.Run(name, func(t *testing.T) {
			w := relayWorld(t)
			epoch := w.ackWithOffer(offer)
			if d := w.device(w.phone); d.AckedEpoch != epoch || d.KXOffer != nil || d.KXOfferEpoch != 0 {
				t.Fatalf("device after a bad offer: acked %d (want %d), offer %x @%d", d.AckedEpoch, epoch, d.KXOffer, d.KXOfferEpoch)
			}
		})
	}
}

// An ack read once the hub has left the relay (the switch's commit wrote
// hub_meta.transport) counts; its offer does not, nor one from a phone whose
// lapse waits for a Step.
func TestOfferReadAfterSwitchAwayIsDropped(t *testing.T) {
	t.Run("switched to iCloud", func(t *testing.T) {
		w := relayWorld(t)
		if err := w.st.SetMeta(state.MetaTransport, string(transport.KindCloudKit)); err != nil {
			t.Fatal(err)
		}
		epoch := w.ackWithOffer(base64.RawURLEncoding.EncodeToString(freshOffer(t)))
		if d := w.device(w.phone); d.AckedEpoch != epoch || d.KXOffer != nil {
			t.Fatalf("device: acked %d (want %d), offer %x", d.AckedEpoch, epoch, d.KXOffer)
		}
	})
	t.Run("lapse pending", func(t *testing.T) {
		w := relayWorld(t)
		if err := w.st.SetMeta(state.MetaLapsePending, w.phone.ID().String()+"@1"); err != nil {
			t.Fatal(err)
		}
		epoch := w.ackWithOffer(base64.RawURLEncoding.EncodeToString(freshOffer(t)))
		if d := w.device(w.phone); d.AckedEpoch != epoch || d.KXOffer != nil {
			t.Fatalf("device: acked %d (want %d), offer %x", d.AckedEpoch, epoch, d.KXOffer)
		}
	})
}

// A hub with no switcher (headless, relay-only) never writes
// hub_meta.transport: its processor's transport decides.
func TestHeadlessRelayHubStoresOfferWithoutTransportMeta(t *testing.T) {
	for _, k := range []transport.Kind{transport.KindRelay, transport.KindCloudKit} {
		t.Run(string(k), func(t *testing.T) {
			w := newWorld(t, k)
			pub := freshOffer(t)
			epoch := w.ackWithOffer(base64.RawURLEncoding.EncodeToString(pub))
			d := w.device(w.phone)
			if want := k == transport.KindRelay; d.AckedEpoch != epoch || (d.KXOffer != nil) != want {
				t.Fatalf("device: acked %d (want %d), offer %x (want stored %v)", d.AckedEpoch, epoch, d.KXOffer, want)
			}
		})
	}
}
