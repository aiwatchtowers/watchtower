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

// relayWorld is a desktop hub's relay processor, the hub on the relay as the
// switcher records it.
func relayWorld(t *testing.T) *world {
	t.Helper()
	return switchedWorld(t, transport.KindRelay, transport.KindRelay, string(transport.KindRelay))
}

// switchedWorld is a processor on kind of a hub with a switcher whose active
// transport is active; meta is hub_meta.transport ("" = unset).
func switchedWorld(t *testing.T, kind, active transport.Kind, meta string) *world {
	t.Helper()
	w := newWorld(t, kind)
	w.withSwitch(&fakeSwitch{active: active})
	if meta != "" {
		if err := w.st.SetMeta(state.MetaTransport, meta); err != nil {
			t.Fatal(err)
		}
	}
	return w
}

// wantAckOnly asserts the ack counted and no offer was stored.
func (w *world) wantAckOnly(epoch uint32) {
	w.t.Helper()
	if d := w.device(w.phone); d.AckedEpoch != epoch || d.KXOffer != nil || d.KXOfferEpoch != 0 {
		w.t.Fatalf("device: acked %d (want %d), offer %x @%d (want none)", d.AckedEpoch, epoch, d.KXOffer, d.KXOfferEpoch)
	}
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

// A hub with no switcher (headless, relay-only) never switches: its
// processor's transport decides, whatever hub_meta.transport says (unset, or
// a stale value from an earlier run).
func TestHeadlessRelayHubDecidesByItsOwnTransport(t *testing.T) {
	for _, c := range []struct {
		kind transport.Kind
		meta string
		want bool
	}{
		{transport.KindRelay, "", true},
		{transport.KindRelay, string(transport.KindCloudKit), true},
		{transport.KindCloudKit, "", false},
		{transport.KindCloudKit, string(transport.KindRelay), false},
	} {
		t.Run(string(c.kind)+"/meta="+c.meta, func(t *testing.T) {
			w := newWorld(t, c.kind)
			if c.meta != "" {
				if err := w.st.SetMeta(state.MetaTransport, c.meta); err != nil {
					t.Fatal(err)
				}
			}
			pub := freshOffer(t)
			epoch := w.ackWithOffer(base64.RawURLEncoding.EncodeToString(pub))
			d := w.device(w.phone)
			if d.AckedEpoch != epoch || (d.KXOffer != nil) != c.want {
				t.Fatalf("device: acked %d (want %d), offer %x (want stored %v)", d.AckedEpoch, epoch, d.KXOffer, c.want)
			}
		})
	}
}

// An offer read off the iCloud mailbox is never stored, even while the hub
// is on the relay: a desktop hub's other (PollOther) processor, or the
// window of a switch toward the relay before its commit.
func TestOfferReadOffICloudIsNeverStored(t *testing.T) {
	for name, active := range map[string]transport.Kind{
		"other processor of a hub on the relay": transport.KindRelay,
		"mid-switch, iCloud still active":       transport.KindCloudKit,
	} {
		t.Run(name, func(t *testing.T) {
			w := switchedWorld(t, transport.KindCloudKit, active, string(transport.KindRelay))
			w.wantAckOnly(w.ackWithOffer(base64.RawURLEncoding.EncodeToString(freshOffer(t))))
		})
	}
}

// With a switcher, an unset hub_meta.transport is not known: nothing stored.
func TestOfferWithSwitcherAndNoTransportMetaIsDropped(t *testing.T) {
	w := switchedWorld(t, transport.KindRelay, transport.KindRelay, "")
	w.wantAckOnly(w.ackWithOffer(base64.RawURLEncoding.EncodeToString(freshOffer(t))))
}
