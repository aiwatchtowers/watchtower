package state

import (
	"bytes"
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

const kxPhone = "0D0D0D0D-0D0D-0D0D-0D0D-0D0D0D0D0D0D"

func linkKXPhone(t *testing.T, s *Store, nonce string) {
	t.Helper()
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		return LinkDevice(tx, Device{ID: kxPhone, Name: "phone", Scope: "private", LinkedAt: time.Unix(1, 0), LinkNonce: nonce})
	}); err != nil {
		t.Fatal(err)
	}
}

func offer(t *testing.T, s *Store, device string, pub []byte, epoch uint32) bool {
	t.Helper()
	var ok bool
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		ok, err = SetKXOffer(tx, device, pub, epoch)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return ok
}

func wantOffer(t *testing.T, s *Store, pub []byte, epoch uint32) {
	t.Helper()
	d, ok, err := s.Device(kxPhone)
	if err != nil || !ok {
		t.Fatalf("device: %v %v", ok, err)
	}
	if !bytes.Equal(d.KXOffer, pub) || d.KXOfferEpoch != epoch {
		t.Fatalf("offer %x @%d, want %x @%d", d.KXOffer, d.KXOfferEpoch, pub, epoch)
	}
}

func key32(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func TestOlderAckDoesNotReplaceANewerOffer(t *testing.T) {
	s := openTest(t)
	linkKXPhone(t, s, "n1")
	if !offer(t, s, kxPhone, key32(1), 5) {
		t.Fatal("the first offer was refused")
	}
	if offer(t, s, kxPhone, key32(2), 4) {
		t.Fatal("an older ack's offer was stored")
	}
	wantOffer(t, s, key32(1), 5)
	// The same epoch offered again (renewed after a lapse) replaces it.
	if !offer(t, s, strings.ToLower(kxPhone), key32(3), 5) {
		t.Fatal("a same-epoch offer was refused")
	}
	wantOffer(t, s, key32(3), 5)
	if offer(t, s, "0E0E0E0E-0E0E-0E0E-0E0E-0E0E0E0E0E0E", key32(4), 9) {
		t.Fatal("an offer was stored for a phone not linked")
	}
}

func TestOfferRefusedWhileLapsed(t *testing.T) {
	s := openTest(t)
	linkKXPhone(t, s, "n1")
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := LapseRelay(tx, kxPhone, time.Unix(100, 0))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if offer(t, s, kxPhone, key32(1), 2) {
		t.Fatal("an offer was stored for a lapsed phone")
	}
	wantOffer(t, s, nil, 0)
}

func TestOfferRefusedWhileLapsePending(t *testing.T) {
	s := openTest(t)
	linkKXPhone(t, s, "n1")
	// The switcher's format: "<canonical id>@<unix seconds>", comma-joined.
	if err := s.SetMeta(MetaLapsePending, "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A@5,"+kxPhone+"@7"); err != nil {
		t.Fatal(err)
	}
	if offer(t, s, kxPhone, key32(1), 2) {
		t.Fatal("an offer was stored for a phone whose lapse waits")
	}
	wantOffer(t, s, nil, 0)
	// Another phone's waiting lapse does not refuse this one.
	if err := s.SetMeta(MetaLapsePending, "0A0A0A0A-0A0A-0A0A-0A0A-0A0A0A0A0A0A@5"); err != nil {
		t.Fatal(err)
	}
	if !offer(t, s, kxPhone, key32(1), 2) {
		t.Fatal("an offer was refused for another phone's lapse")
	}
	wantOffer(t, s, key32(1), 2)
}

func relayKeys(epoch uint32, b byte) EpochRelayKeys {
	return EpochRelayKeys{Epoch: epoch, DeviceID: kxPhone, HubPub: key32(b), DevicePub: key32(b + 1), SealedKeys: []byte{b, b, b}}
}

func insertRelayKeys(t *testing.T, s *Store, k EpochRelayKeys) {
	t.Helper()
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error { return InsertEpochRelayKeys(tx, k) }); err != nil {
		t.Fatal(err)
	}
}

func hasRelayKeys(t *testing.T, s *Store, epoch uint32) bool {
	t.Helper()
	_, ok, err := s.EpochRelayKeys(epoch, kxPhone)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

func TestRelinkClearsOfferAndRelayKeys(t *testing.T) {
	s := openTest(t)
	linkKXPhone(t, s, "n1")
	offer(t, s, kxPhone, key32(1), 3)
	insertRelayKeys(t, s, relayKeys(3, 7))
	got, ok, err := s.EpochRelayKeys(3, "0d0d0d0d-0d0d-0d0d-0d0d-0d0d0d0d0d0d")
	if err != nil || !ok || !bytes.Equal(got.HubPub, key32(7)) || !bytes.Equal(got.DevicePub, key32(8)) ||
		!bytes.Equal(got.SealedKeys, []byte{7, 7, 7}) || got.Epoch != 3 || got.DeviceID != kxPhone {
		t.Fatalf("relay keys %+v %v %v", got, ok, err)
	}
	// The same link written again keeps them.
	linkKXPhone(t, s, "n1")
	wantOffer(t, s, key32(1), 3)
	if !hasRelayKeys(t, s, 3) {
		t.Fatal("a rewrite under the same nonce dropped the relay keys")
	}
	// A re-link (new nonce) starts with neither.
	linkKXPhone(t, s, "n2")
	wantOffer(t, s, nil, 0)
	if hasRelayKeys(t, s, 3) {
		t.Fatal("a re-link kept the old link's relay keys")
	}
}

func TestClearKXOffersAndClearDeviceKX(t *testing.T) {
	s := openTest(t)
	linkKXPhone(t, s, "n1")
	offer(t, s, kxPhone, key32(1), 3)
	insertRelayKeys(t, s, relayKeys(3, 7))
	if err := s.WithTx(context.Background(), ClearKXOffers); err != nil {
		t.Fatal(err)
	}
	wantOffer(t, s, nil, 0)
	if !hasRelayKeys(t, s, 3) {
		t.Fatal("ClearKXOffers dropped relay keys")
	}
	offer(t, s, kxPhone, key32(2), 4)
	if err := s.WithTx(context.Background(), func(tx *sql.Tx) error { return ClearDeviceKX(tx, strings.ToLower(kxPhone)) }); err != nil {
		t.Fatal(err)
	}
	wantOffer(t, s, nil, 0)
	if hasRelayKeys(t, s, 3) {
		t.Fatal("ClearDeviceKX kept the relay keys")
	}
}

func TestEraseEpochLeavesTheRowWithoutKeys(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	linkKXPhone(t, s, "n1")
	yes, no := true, false
	at := time.Unix(1_700_000_000, 0)
	for _, e := range []Epoch{
		{Epoch: 1, SealedKeys: []byte{1}, CreatedAt: at, FirstSeq: 1},                // before 00016: never erased
		{Epoch: 2, SealedKeys: []byte{2}, CreatedAt: at, FirstSeq: 2, OnRelay: &no},  // began on iCloud
		{Epoch: 3, SealedKeys: []byte{3}, CreatedAt: at, FirstSeq: 3, OnRelay: &yes}, // began on the relay
		{Epoch: 4, SealedKeys: []byte{4}, CreatedAt: at, FirstSeq: 4, OnRelay: &yes},
	} {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error { return InsertEpoch(tx, e) }); err != nil {
			t.Fatal(err)
		}
	}
	insertRelayKeys(t, s, relayKeys(3, 7))
	insertRelayKeys(t, s, relayKeys(4, 9))
	for _, e := range []uint32{1, 2, 3} {
		if err := s.WithTx(ctx, func(tx *sql.Tx) error { return EraseEpoch(tx, e) }); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.Epochs()
	if err != nil || len(got) != 4 {
		t.Fatalf("epochs %+v %v", got, err)
	}
	if !bytes.Equal(got[0].SealedKeys, []byte{1}) || got[0].OnRelay != nil {
		t.Fatalf("an older row was erased: %+v", got[0])
	}
	if !bytes.Equal(got[1].SealedKeys, []byte{2}) || got[1].OnRelay == nil || *got[1].OnRelay {
		t.Fatalf("an iCloud epoch was erased: %+v", got[1])
	}
	if len(got[2].SealedKeys) != 0 || got[2].OnRelay == nil || !*got[2].OnRelay || got[2].FirstSeq != 3 {
		t.Fatalf("the erased relay epoch: %+v", got[2])
	}
	if !bytes.Equal(got[3].SealedKeys, []byte{4}) {
		t.Fatalf("another epoch was erased: %+v", got[3])
	}
	if hasRelayKeys(t, s, 3) {
		t.Fatal("the erased epoch's relay keys remain")
	}
	if !hasRelayKeys(t, s, 4) {
		t.Fatal("another epoch's relay keys went")
	}
}
