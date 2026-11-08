package hubtest

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"testing"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

func pairText(p *Phone, epoch uint32) string {
	return string(p.pairs[epoch][secure.PhoneToHub]) + string(p.pairs[epoch][secure.HubToPhone])
}

// The twin's merge follows the Kit's HubLinkKeys.merging
// (HubLinkKeys+Ephemeral.swift): the same pair is skipped, another refused
// with nothing taken (F17), a cleared epoch stays static, and the previous
// epoch counts only with both previous keys.

func twin(t *testing.T) *Phone {
	t.Helper()
	hub, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p, err := New(Config{Hub: [16]byte{1}, HubKX: hub.PublicKey()})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// hubEph is a fresh hub_eph public, base64url.
func hubEph(t *testing.T) string {
	t.Helper()
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(k.PublicKey().Bytes())
}

func kx(hub string, device []byte) *wire.KeyboxRelayKX {
	return &wire.KeyboxRelayKX{HubPub: hub, DevicePub: base64.RawURLEncoding.EncodeToString(device)}
}

// keys is a keybox for epoch naming rx, with the previous epoch's keys and
// prx when prev is non-zero.
func keys(epoch uint32, rx *wire.KeyboxRelayKX, prev uint32, prx *wire.KeyboxRelayKX) wire.KeyboxKeys {
	k := wire.KeyboxKeys{Epoch: epoch, RelayKX: rx}
	if prev != 0 {
		d, a := "d", "a"
		k.PreviousEpoch, k.PreviousDataKey, k.PreviousAlertKey, k.PreviousRelayKX = &prev, &d, &a, prx
	}
	return k
}

// merged2 is a phone that offered and merged epoch 2's pair (hub pub h2).
func merged2(t *testing.T) (p *Phone, h2 string, dev2 []byte) {
	t.Helper()
	p = twin(t)
	if _, err := p.Offer(); err != nil {
		t.Fatal(err)
	}
	h2, dev2 = hubEph(t), p.Offered()
	if err := p.takeRelayKX(keys(2, kx(h2, dev2), 0, nil)); err != nil {
		t.Fatal(err)
	}
	if !p.HoldsPair(2) || p.Offered() != nil || p.Current() == nil {
		t.Fatal("epoch 2 not merged and promoted")
	}
	return p, h2, dev2
}

func TestTwinMergeSkipsTheSamePairAndRefusesAnother(t *testing.T) {
	p, h2, dev2 := merged2(t)
	before := pairText(p, 2)
	if err := p.takeRelayKX(keys(2, kx(h2, dev2), 0, nil)); err != nil {
		t.Fatalf("the same pair again: %v", err)
	}
	// Another hub_eph for the held epoch, its device key still held.
	if err := p.takeRelayKX(keys(2, kx(hubEph(t), dev2), 0, nil)); err == nil {
		t.Fatal("another pair for a held epoch was taken")
	}
	if pairText(p, 2) != before {
		t.Fatal("the held pair changed")
	}
}

// The hub names another previous_relay_kx than the pair the phone merged
// for that epoch (the device key since replaced by a newer offer): the
// whole keybox is refused, its own epoch not taken, the offer not promoted.
func TestTwinMergeRefusesAnotherPreviousRelayKX(t *testing.T) {
	p, h2, dev2 := merged2(t)
	if _, err := p.Offer(); err != nil {
		t.Fatal(err)
	}
	h3, dev3 := hubEph(t), p.Offered()
	if err := p.takeRelayKX(keys(3, kx(h3, dev3), 2, kx(hubEph(t), dev2))); err == nil {
		t.Fatal("a different previous_relay_kx was taken")
	}
	if p.HoldsPair(3) || p.Offered() == nil {
		t.Fatal("a refused keybox took its epoch or promoted the offer")
	}
	if err := p.takeRelayKX(keys(3, kx(h3, dev3), 2, kx(h2, dev2))); err != nil {
		t.Fatalf("the same previous pair: %v", err)
	}
	if !p.HoldsPair(2) || !p.HoldsPair(3) || p.Offered() != nil {
		t.Fatal("epoch 3 not merged beside 2")
	}
}

func TestTwinMergeClearedEpochStaysStatic(t *testing.T) {
	p, h2, dev2 := merged2(t)
	if err := p.takeRelayKX(keys(2, nil, 0, nil)); err != nil {
		t.Fatal(err)
	}
	if p.HoldsPair(2) {
		t.Fatal("a static keybox kept the pair")
	}
	if err := p.takeRelayKX(keys(2, kx(h2, dev2), 0, nil)); err != nil || p.HoldsPair(2) {
		t.Fatalf("the dropped pair named again: %v, pair held %v (want skipped, static)", err, p.HoldsPair(2))
	}
	if err := p.takeRelayKX(keys(2, kx(hubEph(t), dev2), 0, nil)); err == nil {
		t.Fatal("another pair for a cleared epoch was taken")
	}
}

// A static keybox carrying the previous epoch with both its keys and no
// previous_relay_kx drops that pair; without both keys the previous epoch
// is not read.
func TestTwinMergeReadsThePreviousEpochOnlyWithBothKeys(t *testing.T) {
	p, _, _ := merged2(t)
	k := keys(3, nil, 0, nil)
	two := uint32(2)
	k.PreviousEpoch = &two
	if err := p.takeRelayKX(k); err != nil || !p.HoldsPair(2) {
		t.Fatalf("previous epoch without its keys: %v, pair 2 held %v", err, p.HoldsPair(2))
	}
	if err := p.takeRelayKX(keys(3, nil, 2, nil)); err != nil || p.HoldsPair(2) {
		t.Fatalf("previous epoch with its keys and no relay_kx: %v, pair 2 held %v", err, p.HoldsPair(2))
	}
}
