package identity

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"strconv"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// The weekly relay keys (relay client Phase 5): the cadence, the ephemeral
// rotation, the key lookup, the keybox recipient and keys, and the erasure.

// relayPhone is a linked phone with its own keys and, once it offered, the
// private half of its offer.
type relayPhone struct {
	id    secure.ID
	kx    *ecdh.PrivateKey
	nonce []byte
	eph   *ecdh.PrivateKey
}

// linkRelayPhone links a fresh phone (its id from seed).
func linkRelayPhone(t *testing.T, st *state.Store, seed byte) *relayPhone {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{seed}, 32))
	sig := priv.Public().(ed25519.PublicKey)
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 32)
	_, _ = rand.Read(nonce)
	p := &relayPhone{id: secure.DeviceID(sig), kx: kx, nonce: nonce}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: p.id.String(), Name: "Phone", Scope: "private", LinkedAt: time.Unix(1_800_000_000, 0),
			SigningKey: sig, AgreementKey: kx.PublicKey().Bytes(), LinkNonce: base64.RawURLEncoding.EncodeToString(nonce),
		})
	}); err != nil {
		t.Fatal(err)
	}
	return p
}

// offer stores a fresh offer for the phone, as its epoch_ack of epoch would.
func (p *relayPhone) offer(t *testing.T, st *state.Store, epoch uint32) {
	t.Helper()
	eph, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		ok, err := state.SetKXOffer(tx, p.id.String(), eph.PublicKey().Bytes(), epoch)
		if err == nil && !ok {
			err = errors.New("offer not stored")
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	p.eph = eph
}

// phoneKey is the key the phone derives on its side from a keybox's pair.
func (p *relayPhone) phoneKey(t *testing.T, k *Keyring, row state.EpochRelayKeys, dir secure.Direction) []byte {
	t.Helper()
	hubPub, err := ecdh.X25519().NewPublicKey(row.HubPub)
	if err != nil {
		t.Fatal(err)
	}
	key, err := secure.EphemeralRelayKey(p.eph, hubPub, p.kx, k.Agreement().PublicKey(), row.HubPub, row.DevicePub,
		p.nonce, k.HubID(), p.id, row.Epoch, dir)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// staticKey is the phone's wt/relay/v1/ key.
func (p *relayPhone) staticKey(t *testing.T, k *Keyring, epoch uint32, dir secure.Direction) []byte {
	t.Helper()
	key, err := secure.RelayKey(p.kx, k.Agreement().PublicKey(), p.nonce, k.HubID(), p.id, epoch, dir)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func setTransport(t *testing.T, st *state.Store, kind string) {
	t.Helper()
	if err := st.SetMeta(state.MetaTransport, kind); err != nil {
		t.Fatal(err)
	}
}

func epochAt(t *testing.T, st *state.Store, epoch uint32) state.Epoch {
	t.Helper()
	epochs, err := st.Epochs()
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range epochs {
		if e.Epoch == epoch {
			return e
		}
	}
	t.Fatalf("no epoch %d", epoch)
	return state.Epoch{}
}

func relayRows(t *testing.T, st *state.Store) int {
	t.Helper()
	var n int
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM epoch_relay_keys`).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

func rowOf(t *testing.T, st *state.Store, epoch uint32, dev secure.ID) (state.EpochRelayKeys, bool) {
	t.Helper()
	row, ok, err := st.EpochRelayKeys(epoch, dev.String())
	if err != nil {
		t.Fatal(err)
	}
	return row, ok
}

func mustRotateIfDue(t *testing.T, k *Keyring, want bool) {
	t.Helper()
	got, err := k.RotateIfDue(nil)
	if err != nil || got != want {
		t.Fatalf("RotateIfDue = %v, %v; want %v", got, err, want)
	}
}

func currentEpoch(t *testing.T, k *Keyring) uint32 {
	t.Helper()
	e, err := k.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func TestKeyring_RotatesAt7DaysOnRelay(t *testing.T) {
	for _, offered := range []bool{false, true} {
		t.Run("offer="+strconv.FormatBool(offered), func(t *testing.T) {
			st := openStore(t)
			c := newClock()
			k := newKeyring(t, st, c)
			setTransport(t, st, "relay")
			p := linkRelayPhone(t, st, 0x11)
			if offered {
				p.offer(t, st, 1)
			}
			c.advance(7*24*time.Hour - time.Second)
			mustRotateIfDue(t, k, false)
			c.advance(time.Second)
			mustRotateIfDue(t, k, true)
			if e := epochAt(t, st, 2); e.OnRelay == nil || !*e.OnRelay || e.Reason != string(ReasonAge) {
				t.Fatalf("epoch 2 = %+v, want an age epoch on the relay", e)
			}
			if _, ok := rowOf(t, st, 2, p.id); ok != offered {
				t.Fatalf("relay keys of epoch 2: %v, want %v", ok, offered)
			}
			mustRotateIfDue(t, k, false)
		})
	}
}

func TestKeyring_RotatesOnceAfterALongClose(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	c.advance(60 * 24 * time.Hour)
	mustRotateIfDue(t, k, true)
	mustRotateIfDue(t, k, false)
	if cur := currentEpoch(t, k); cur != 2 {
		t.Fatalf("epoch %d after a long close, want 2 (no catch-up)", cur)
	}
}

func TestRotationDerivesRelayKeysForOfferedPhonesOnly(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	a := linkRelayPhone(t, st, 0x11)
	b := linkRelayPhone(t, st, 0x22)
	a.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	row, ok := rowOf(t, st, 2, a.id)
	if !ok {
		t.Fatal("no relay keys for the offered phone")
	}
	if !bytes.Equal(row.DevicePub, a.eph.PublicKey().Bytes()) || len(row.HubPub) != 32 {
		t.Fatalf("row publics: device %x hub %d bytes", row.DevicePub, len(row.HubPub))
	}
	for _, dir := range []secure.Direction{secure.PhoneToHub, secure.HubToPhone} {
		hub, err := k.RelayKey(dir, a.id, 2)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(hub, a.phoneKey(t, k, row, dir)) {
			t.Fatalf("%s: the hub's key is not the phone's", dir)
		}
		if bytes.Equal(hub, a.staticKey(t, k, 2, dir)) {
			t.Fatalf("%s: the offered phone got the static key", dir)
		}
		// Epoch 1 began before the offer: static.
		if old, _ := k.RelayKey(dir, a.id, 1); !bytes.Equal(old, a.staticKey(t, k, 1, dir)) {
			t.Fatalf("%s: epoch 1 is not static", dir)
		}
	}
	if _, ok := rowOf(t, st, 2, b.id); ok {
		t.Fatal("a phone with no offer got relay keys")
	}
	for _, dir := range []secure.Direction{secure.PhoneToHub, secure.HubToPhone} {
		if got, _ := k.RelayKey(dir, b.id, 2); !bytes.Equal(got, b.staticKey(t, k, 2, dir)) {
			t.Fatalf("%s: the phone with no offer is not on wt/relay/v1/", dir)
		}
	}
}

// The transcript publics come from the agreement keys themselves (Task 1's
// caller contract): a transcript naming another key derives another key.
func TestEphemeralPairTranscriptIsTheAgreementKeys(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	hubEph, _ := ecdh.X25519().GenerateKey(rand.Reader)
	other, _ := ecdh.X25519().GenerateKey(rand.Reader)
	pair, err := k.ephemeralPair(hubEph, p.eph.PublicKey(), p.kx.PublicKey(), p.nonce, p.id, 5)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(pair)
	want, _ := secure.EphemeralRelayKey(hubEph, p.eph.PublicKey(), k.Agreement(), p.kx.PublicKey(),
		hubEph.PublicKey().Bytes(), p.eph.PublicKey().Bytes(), p.nonce, k.HubID(), p.id, 5, secure.PhoneToHub)
	if !bytes.Equal(pair[:32], want) {
		t.Fatal("p2h is not derived over the agreement keys' own publics")
	}
	forged, _ := secure.EphemeralRelayKey(hubEph, p.eph.PublicKey(), k.Agreement(), p.kx.PublicKey(),
		other.PublicKey().Bytes(), p.eph.PublicKey().Bytes(), p.nonce, k.HubID(), p.id, 5, secure.PhoneToHub)
	if bytes.Equal(forged, want) {
		t.Fatal("a transcript naming another key derives the same key")
	}
}

func relayKeysAAD(hub secure.ID, epoch uint32, dev secure.ID) []byte {
	aad := append([]byte("wt/hub-epoch-relay/v1"), hub[:]...)
	aad = binary.BigEndian.AppendUint32(aad, epoch)
	return append(aad, dev[:]...)
}

func TestRotationErasesTheHubEphemeral(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	row, _ := rowOf(t, st, 2, p.id)
	plain := openCombined(t, bytes.Repeat([]byte{0xF0}, 32), row.SealedKeys, relayKeysAAD(k.HubID(), 2, p.id))
	if len(plain) != 64 {
		t.Fatalf("sealed_keys opens to %d bytes, want 64", len(plain))
	}
	if !bytes.Equal(plain[:32], p.phoneKey(t, k, row, secure.PhoneToHub)) || !bytes.Equal(plain[32:], p.phoneKey(t, k, row, secure.HubToPhone)) {
		t.Fatal("sealed_keys is not p2h ‖ h2p")
	}
	// The row holds the two publics and the two derived keys, nothing else:
	// the hub's private half is nowhere in the sidecar.
	var cols int
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('epoch_relay_keys')`).Scan(&cols)
	}); err != nil {
		t.Fatal(err)
	}
	if cols != 5 {
		t.Fatalf("epoch_relay_keys has %d columns, want 5", cols)
	}
	if bytes.Contains(row.SealedKeys, row.HubPub) {
		t.Fatal("sealed_keys carries the public in the clear")
	}
	// Another aad does not open it (bound to hub, epoch and device).
	if _, err := k.open(row.SealedKeys, relayKeysAAD(k.HubID(), 3, p.id)); err == nil {
		t.Fatal("the sealed keys open under another epoch's aad")
	}
}

func TestRotationFailureMidwayWritesNothing(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	a := linkRelayPhone(t, st, 0x11)
	b := linkRelayPhone(t, st, 0x22)
	a.offer(t, st, 1)
	b.offer(t, st, 1)
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.SetSliceState(tx, "target-1", "w", "h", c.now()) }); err != nil {
		t.Fatal(err)
	}
	boom := errors.New("boom")
	sealed := 0
	sealRelayFault = func(secure.ID) error {
		sealed++
		if sealed == 2 {
			return boom
		}
		return nil
	}
	t.Cleanup(func() { sealRelayFault = nil })
	c.advance(8 * 24 * time.Hour)
	if _, err := k.RotateIfDue(nil); !errors.Is(err, boom) {
		t.Fatalf("RotateIfDue = %v, want the seal failure", err)
	}
	if cur := currentEpoch(t, k); cur != 1 || relayRows(t, st) != 0 {
		t.Fatalf("a failed rotation wrote: epoch %d, %d relay rows", cur, relayRows(t, st))
	}
	if e := epochAt(t, st, 1); e.RetiredAt != nil {
		t.Fatal("a failed rotation retired epoch 1")
	}
	if got, _ := st.SliceHashes("target"); got["target-1"].Hash != "h" {
		t.Fatal("a failed rotation wiped the slice hashes")
	}
	for _, p := range []*relayPhone{a, b} {
		if d, _, _ := st.Device(p.id.String()); !bytes.Equal(d.KXOffer, p.eph.PublicKey().Bytes()) {
			t.Fatal("a failed rotation lost an offer")
		}
	}
	sealRelayFault = nil // the next housekeeping retries
	mustRotateIfDue(t, k, true)
	if relayRows(t, st) != 2 {
		t.Fatalf("%d relay rows after the retry, want 2", relayRows(t, st))
	}
}

func TestRotateToCloudKitClearsOffersAndDerivesNone(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := st.SetMeta(state.MetaServingNobodySince, "1800000000"); err != nil {
		t.Fatal(err)
	}
	if err := k.RotateToward(ReasonTransportSwitch, false, nil); err != nil {
		t.Fatal(err)
	}
	if relayRows(t, st) != 0 {
		t.Fatal("a rotation toward iCloud derived relay keys")
	}
	if d, _, _ := st.Device(p.id.String()); d.KXOffer != nil || d.KXOfferEpoch != 0 {
		t.Fatal("a rotation toward iCloud kept the offer")
	}
	if e := epochAt(t, st, 2); e.OnRelay == nil || *e.OnRelay {
		t.Fatal("the iCloud epoch is marked on the relay")
	}
	if _, ok, _ := st.Meta(state.MetaServingNobodySince); ok {
		t.Fatal("leaving the relay kept relay_serving_nobody_since")
	}
}

func TestRotateIfDueSkipsWhileASwitchIsRunning(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	c.advance(8 * 24 * time.Hour)
	running := func(*sql.Tx) error { return ErrSkipRotation }
	if rotated, err := k.RotateIfDue(running); err != nil || rotated {
		t.Fatalf("RotateIfDue inside a switch = %v, %v", rotated, err)
	}
	if cur := currentEpoch(t, k); cur != 1 || relayRows(t, st) != 0 {
		t.Fatal("a skipped rotation wrote")
	}
	mustRotateIfDue(t, k, true) // the next cycle decides
}

func TestRotateIfDueSkippedWhileHeldOnRelay(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	k.SetHeld(func() bool { return true })
	c.advance(30 * 24 * time.Hour)
	mustRotateIfDue(t, k, false)

	// A held CloudKit hub still rotates at 90 days, as today.
	st2 := openStore(t)
	c2 := newClock()
	k2 := newKeyring(t, st2, c2)
	setTransport(t, st2, "cloudkit")
	k2.SetHeld(func() bool { return true })
	c2.advance(RotationAge - time.Second)
	mustRotateIfDue(t, k2, false)
	c2.advance(time.Second)
	mustRotateIfDue(t, k2, true)
}

// The relay rule a running hub sets wins over hub_meta.transport (a headless
// hub: its transport alone decides).
func TestRelayRuleDecidesTheCadence(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "cloudkit") // stale
	k.SetRelayRule(func(*sql.Tx) (bool, error) { return true, nil })
	c.advance(relayRotationAge)
	mustRotateIfDue(t, k, true)
	if e := epochAt(t, st, 2); e.OnRelay == nil || !*e.OnRelay {
		t.Fatal("the rule's relay epoch is not on the relay")
	}
}

func TestKeyboxRecipientIsTheOfferForALinkedPhone(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	p := linkRelayPhone(t, st, 0x11)
	if pub, err := k.KeyboxRecipient(p.id); err != nil || !bytes.Equal(pub.Bytes(), p.kx.PublicKey().Bytes()) {
		t.Fatalf("no offer: recipient %v, want dev_kx", err)
	}
	p.offer(t, st, 1)
	if pub, err := k.KeyboxRecipient(p.id); err != nil || !bytes.Equal(pub.Bytes(), p.eph.PublicKey().Bytes()) {
		t.Fatalf("with an offer: recipient %v, want the offer", err)
	}
	// A revoked, refused or pending device gets dev_kx, today's order.
	for _, tc := range []struct{ table, insert string }{
		{"revoked", `INSERT INTO revoked_devices (device_id, agreement_key, removed_at) VALUES (?, ?, 1)`},
		{"refused", `INSERT INTO link_refusals (device_id, name, scope, reason, at, agreement_key) VALUES (?, 'P', 'private', 'owner', 1, ?)`},
		{"pending", `INSERT INTO pending_devices (device_id, agreement_key) VALUES (?, ?)`},
	} {
		other, _ := ecdh.X25519().GenerateKey(rand.Reader)
		id := secure.ID{tc.table[0], tc.table[2], 0x42}
		if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
			_, err := tx.Exec(tc.insert, id.String(), other.PublicKey().Bytes())
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if pub, err := k.KeyboxRecipient(id); err != nil || !bytes.Equal(pub.Bytes(), other.PublicKey().Bytes()) {
			t.Fatalf("%s device: recipient %v, want its dev_kx", tc.table, err)
		}
	}
}

func kxOf(row state.EpochRelayKeys) *wire.KeyboxRelayKX {
	b64 := base64.RawURLEncoding.EncodeToString
	return &wire.KeyboxRelayKX{HubPub: b64(row.HubPub), DevicePub: b64(row.DevicePub)}
}

func TestKeyboxKeysNameBothEpochs(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	p.offer(t, st, 2)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	r2, _ := rowOf(t, st, 2, p.id)
	r3, _ := rowOf(t, st, 3, p.id)
	kk, err := k.KeyboxKeysFor(p.id)
	if err != nil {
		t.Fatal(err)
	}
	if kk.Epoch != 3 || kk.PreviousEpoch == nil || *kk.PreviousEpoch != 2 {
		t.Fatalf("keybox epochs %d / %v", kk.Epoch, kk.PreviousEpoch)
	}
	if kk.RelayKX == nil || *kk.RelayKX != *kxOf(r3) || kk.PreviousRelayKX == nil || *kk.PreviousRelayKX != *kxOf(r2) {
		t.Fatalf("relay_kx %+v / %+v", kk.RelayKX, kk.PreviousRelayKX)
	}
	// Another phone with no relay keys: static, both epochs' keys as today.
	q := linkRelayPhone(t, st, 0x22)
	kq, err := k.KeyboxKeysFor(q.id)
	if err != nil || kq.RelayKX != nil || kq.PreviousRelayKX != nil || kq.PreviousEpoch == nil || kq.DataKey != kk.DataKey {
		t.Fatalf("static phone keybox %+v, %v", kq, err)
	}
}

func TestStaticKeyboxOmitsAnEphemeralPreviousEpoch(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	q := linkRelayPhone(t, st, 0x22)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	if err := k.RotateToward(ReasonTransportSwitch, false, nil); err != nil {
		t.Fatal(err)
	}
	kk, err := k.KeyboxKeysFor(p.id)
	if err != nil {
		t.Fatal(err)
	}
	if kk.Epoch != 3 || kk.RelayKX != nil || kk.PreviousEpoch != nil || kk.PreviousDataKey != nil || kk.PreviousRelayKX != nil {
		t.Fatalf("a dev_kx keybox carries an ephemeral previous epoch: %+v", kk)
	}
	if kq, _ := k.KeyboxKeysFor(q.id); kq.PreviousEpoch == nil || *kq.PreviousEpoch != 2 {
		t.Fatal("a phone with no relay keys lost its previous epoch")
	}
}

func TestEraseExpiredRemovesKeysAtRetentionEnd(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	stampCurrent(t, k) // the hub's start: epoch 1 began on the relay
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil { // epoch 2, on the relay
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil { // epoch 3; epoch 2 retired
		t.Fatal(err)
	}
	if n, err := k.EraseExpired(); err != nil || n != 0 {
		t.Fatalf("EraseExpired inside retention = %d, %v", n, err)
	}
	c.advance(PreviousEpochGrace)
	if n, err := k.EraseExpired(); err != nil || n != 2 {
		t.Fatalf("EraseExpired at retention end = %d, %v; want 2 (epochs 1 and 2 began on the relay)", n, err)
	}
	if e := epochAt(t, st, 2); len(e.SealedKeys) != 0 {
		t.Fatal("epoch 2's keys are still sealed in the sidecar")
	}
	if _, err := k.DataKey(2); err == nil {
		t.Fatal("an erased epoch still opens")
	}
	if _, ok := rowOf(t, st, 2, p.id); ok {
		t.Fatal("an erased epoch's relay keys stay")
	}
	if ok, _ := k.AcceptsRelayEpoch(2, p.id); ok {
		t.Fatal("an erased epoch is accepted")
	}
	if len(epochAt(t, st, 1).SealedKeys) != 0 {
		t.Fatal("epoch 1, stamped on the relay at the hub's start, kept its keys")
	}
	if n, _ := k.EraseExpired(); n != 0 {
		t.Fatal("an erased epoch was erased again")
	}
}

func stampCurrent(t *testing.T, k *Keyring) {
	t.Helper()
	if err := k.StampCurrentEpoch(); err != nil {
		t.Fatal(err)
	}
}

// A headless hub's start: its relay rule stamps a new sidecar's epoch 1 as a
// relay epoch (no hub_meta.transport), erased at its retention end.
func TestStampedRelayRuleEpochOneIsErasedAtRetentionEnd(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	k.SetRelayRule(func(*sql.Tx) (bool, error) { return true, nil })
	stampCurrent(t, k)
	if e := epochAt(t, st, 1); e.OnRelay == nil || !*e.OnRelay {
		t.Fatalf("epoch 1 on_relay %v after the relay hub's start, want true", e.OnRelay)
	}
	if err := k.Rotate(ReasonManual); err != nil { // epoch 2; epoch 1 retired
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil { // epoch 3; epoch 2 retired
		t.Fatal(err)
	}
	if n, err := k.EraseExpired(); err != nil || n != 0 {
		t.Fatalf("EraseExpired inside retention = %d, %v", n, err)
	}
	c.advance(PreviousEpochGrace)
	if n, err := k.EraseExpired(); err != nil || n != 2 {
		t.Fatalf("EraseExpired at retention end = %d, %v; want 2", n, err)
	}
	if len(epochAt(t, st, 1).SealedKeys) != 0 {
		t.Fatal("the relay hub's epoch 1 kept its keys past its retention")
	}
}

// A retired epoch with no on_relay is a row from before sidecar migration
// 00016: the hub's start stamps only the current epoch, so it keeps its keys
// (ask #1066).
func TestEraseExpiredKeepsARetiredEpochWithNoOnRelay(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c) // epoch 1, not stamped: as a row from before 00016
	setTransport(t, st, "relay")
	if err := k.Rotate(ReasonManual); err != nil { // epoch 2, on the relay
		t.Fatal(err)
	}
	stampCurrent(t, k) // a later start: epoch 2 is stamped already, epoch 1 is not current
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	c.advance(PreviousEpochGrace)
	if n, err := k.EraseExpired(); err != nil || n != 1 {
		t.Fatalf("EraseExpired = %d, %v; want 1 (epoch 1 has no on_relay value and is never erased)", n, err)
	}
	if e := epochAt(t, st, 1); e.OnRelay != nil || len(e.SealedKeys) == 0 {
		t.Fatalf("epoch 1 with no on_relay changed: on_relay %v, %d key bytes", e.OnRelay, len(e.SealedKeys))
	}
}

func TestRotationWritesOnRelay(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	c.advance(relayRotationAge)
	mustRotateIfDue(t, k, true)                                               // 2: on the relay
	if err := k.RotateToward(ReasonTransportSwitch, false, nil); err != nil { // 3: toward iCloud
		t.Fatal(err)
	}
	setTransport(t, st, "cloudkit")
	if err := k.RotateToward(ReasonTransportSwitch, true, nil); err != nil { // 4: toward the relay
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil { // 5: meta still says cloudkit (inside the switch): epoch 4's
		t.Fatal(err)
	}
	setTransport(t, st, "relay")
	if err := k.RotateToward(ReasonTransportSwitch, false, nil); err != nil { // 6: toward iCloud
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonUnlink); err != nil { // 7: meta still says relay: epoch 6's
		t.Fatal(err)
	}
	want := map[uint32]bool{2: true, 3: false, 4: true, 5: true, 6: false, 7: false}
	for e, on := range want {
		if got := epochAt(t, st, e).OnRelay; got == nil || *got != on {
			t.Fatalf("epoch %d on_relay %v, want %v", e, got, on)
		}
	}
	if epochAt(t, st, 1).OnRelay != nil {
		t.Fatal("epoch 1 got an on_relay value")
	}
	// A pre-00016 current epoch (on_relay NULL): hub_meta.transport decides.
	st2 := openStore(t)
	k2 := newKeyring(t, st2, newClock())
	setTransport(t, st2, "relay")
	if err := k2.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	if on := epochAt(t, st2, 2).OnRelay; on == nil || !*on {
		t.Fatal("a NULL current epoch did not fall back to hub_meta.transport")
	}
}

func TestEraseExpiredLeavesAnICloudEpoch(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "cloudkit")
	stampCurrent(t, k) // the hub's start: epoch 1 began on iCloud
	if e := epochAt(t, st, 1); e.OnRelay == nil || *e.OnRelay {
		t.Fatalf("epoch 1 on_relay %v after the iCloud hub's start, want false", e.OnRelay)
	}
	if err := k.Rotate(ReasonManual); err != nil { // epoch 2, on_relay 0
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	c.advance(30 * 24 * time.Hour)
	if n, err := k.EraseExpired(); err != nil || n != 0 {
		t.Fatalf("EraseExpired on iCloud = %d, %v", n, err)
	}
	for _, e := range []uint32{1, 2} {
		if len(epochAt(t, st, e).SealedKeys) == 0 {
			t.Fatalf("iCloud epoch %d lost its sealed_keys", e)
		}
		if _, err := k.DataKey(e); err != nil {
			t.Fatalf("iCloud epoch %d does not open: %v", e, err)
		}
	}
}

func TestLinkDuringRotationStartsStatic(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	a := linkRelayPhone(t, st, 0x11)
	a.offer(t, st, 1)
	var wg sync.WaitGroup
	var fresh *relayPhone
	wg.Add(2)
	go func() { defer wg.Done(); fresh = linkRelayPhone(t, st, 0x33) }()
	go func() {
		defer wg.Done()
		if err := k.Rotate(ReasonManual); err != nil {
			t.Error(err)
		}
	}()
	wg.Wait()
	if _, ok := rowOf(t, st, 2, fresh.id); ok {
		t.Fatal("a phone linked during the rotation got relay keys")
	}
	for _, e := range []uint32{1, 2} {
		if got, _ := k.RelayKey(secure.HubToPhone, fresh.id, e); !bytes.Equal(got, fresh.staticKey(t, k, e, secure.HubToPhone)) {
			t.Fatalf("the new phone's epoch %d is not static", e)
		}
	}
	if pub, _ := k.KeyboxRecipient(fresh.id); !bytes.Equal(pub.Bytes(), fresh.kx.PublicKey().Bytes()) {
		t.Fatal("the new phone's keybox is not sealed to dev_kx")
	}
}

// F8: an epoch_ack that never arrives keeps the epoch only until the 7-day
// cap; its relay keys are erased then.
func TestLostAckStillRetiresAt7Days(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil { // 2, with p's keys
		t.Fatal(err)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.AckEpoch(tx, p.id.String(), 2) }); err != nil {
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil { // 3: its ack is lost
		t.Fatal(err)
	}
	if err := k.RetireOld(); err != nil {
		t.Fatal(err)
	}
	if got := retained(t, k); len(got) != 2 || got[0] != 2 {
		t.Fatalf("retained %v: a lost ack retired epoch 2 early", got)
	}
	c.advance(PreviousEpochGrace)
	if got := retained(t, k); len(got) != 1 || got[0] != 3 {
		t.Fatalf("retained %v at 7 days", got)
	}
	if n, _ := k.EraseExpired(); n != 1 {
		t.Fatal("epoch 2 not erased at 7 days")
	}
}

func TestRelayKeyCacheDropsAnErasedEpoch(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	row, _ := rowOf(t, st, 2, p.id)
	eph, err := k.RelayKey(secure.HubToPhone, p.id, 2)
	if err != nil || !bytes.Equal(eph, p.phoneKey(t, k, row, secure.HubToPhone)) {
		t.Fatal("epoch 2's key is not the pair's")
	}
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	c.advance(PreviousEpochGrace)
	if n, _ := k.EraseExpired(); n != 1 {
		t.Fatal("nothing erased")
	}
	k.mu.Lock()
	for slot := range k.relay[p.id].keys {
		if slot == "h2p/2" || slot == "p2h/2" {
			k.mu.Unlock()
			t.Fatalf("the cache kept %s of an erased epoch", slot)
		}
	}
	k.mu.Unlock()
	if got, _ := k.RelayKey(secure.HubToPhone, p.id, 2); bytes.Equal(got, eph) {
		t.Fatal("an erased epoch's key is still handed out")
	}
}

// A phone's rows cleared (a lapse, a lost reader) make every key static at
// once, the cache included.
func TestRelayKeyIsStaticOnceRowsAreCleared(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	p.offer(t, st, 1)
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	if _, err := k.RelayKey(secure.HubToPhone, p.id, 2); err != nil {
		t.Fatal(err)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.ClearDeviceKX(tx, p.id.String()) }); err != nil {
		t.Fatal(err)
	}
	if got, _ := k.RelayKey(secure.HubToPhone, p.id, 2); !bytes.Equal(got, p.staticKey(t, k, 2, secure.HubToPhone)) {
		t.Fatal("a cleared phone still gets its ephemeral key")
	}
}

func TestPhoneEpochIsTheAckedEpochWhileRetained(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	p := linkRelayPhone(t, st, 0x11)
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.AckEpoch(tx, p.id.String(), 1) }); err != nil {
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	dev := func() state.Device { d, _, _ := st.Device(p.id.String()); return d }
	if e, _ := k.PhoneEpoch(dev()); e != 0 {
		t.Fatalf("a never-offered phone's epoch %d, want 0 (current)", e)
	}
	if e, _ := k.AckedEpochRetained(dev()); e != 1 {
		t.Fatalf("acked retained %d, want 1", e)
	}
	// An offer read after the rotation: epoch 2 is static for the phone, so
	// it is sealed in (no move back to epoch 1).
	p.offer(t, st, 1)
	if e, _ := k.PhoneEpoch(dev()); e != 0 {
		t.Fatalf("an offer with no keys in the current epoch: %d, want 0", e)
	}
	// The next rotation derives its keys: the acked epoch while retained.
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.AckEpoch(tx, p.id.String(), 2) }); err != nil {
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	if e, _ := k.PhoneEpoch(dev()); e != 2 {
		t.Fatalf("an offered phone's epoch %d, want 2", e)
	}
	c.advance(PreviousEpochGrace)
	if e, _ := k.PhoneEpoch(dev()); e != 0 {
		t.Fatalf("past retention %d, want 0", e)
	}
}

// countingErasure counts the secure_delete transactions and checkpoints the
// erasure issues.
func countingErasure(t *testing.T) (secureDeletes, checkpoints *int) {
	t.Helper()
	sd, cp := 0, 0
	oldSD, oldCP := secureDeleteTx, checkpointStore
	secureDeleteTx = func(st *state.Store, ctx context.Context, fn func(*sql.Tx) error) error {
		sd++
		return oldSD(st, ctx, fn)
	}
	checkpointStore = func(st *state.Store) error { cp++; return oldCP(st) }
	t.Cleanup(func() { secureDeleteTx, checkpointStore = oldSD, oldCP })
	return &sd, &cp
}

// With no relay epoch to erase (a CloudKit hub above all) housekeeping's
// erasure issues neither secure_delete nor wal_checkpoint; with one it
// issues each once.
func TestNoEraseNoPragmaNoCheckpoint(t *testing.T) {
	for _, kind := range []string{"cloudkit", "relay"} {
		t.Run(kind, func(t *testing.T) {
			sd, cp := countingErasure(t)
			st := openStore(t)
			c := newClock()
			k := newKeyring(t, st, c)
			setTransport(t, st, kind)
			for range 2 {
				if err := k.Rotate(ReasonManual); err != nil {
					t.Fatal(err)
				}
			}
			// Nothing past retention yet; on iCloud nothing ever.
			if n, err := k.EraseExpired(); err != nil || n != 0 || *sd != 0 || *cp != 0 {
				t.Fatalf("EraseExpired = %d, %v: %d secure_delete, %d checkpoints", n, err, *sd, *cp)
			}
			c.advance(4 * PreviousEpochGrace)
			want := 0
			if kind == "relay" {
				want = 1 // epoch 2 began on the relay
			}
			if n, err := k.EraseExpired(); err != nil || n != want || *sd != want || *cp != want {
				t.Fatalf("EraseExpired = %d, %v: %d secure_delete, %d checkpoints; want %d", n, err, *sd, *cp, want)
			}
			if n, _ := k.EraseExpired(); n != 0 || *sd != want || *cp != want {
				t.Fatal("a second erasure issued pragmas again")
			}
		})
	}
}

// A checkpoint that did not complete (busy, or an error) is owed: the next
// erasure pass retries it, with nothing new to erase, until one completes.
func TestACheckpointNotDoneIsRetried(t *testing.T) {
	sd, cp := countingErasure(t)
	fail := 1
	inner := checkpointStore
	checkpointStore = func(st *state.Store) error {
		if fail > 0 {
			fail--
			*cp++
			return errors.New("busy")
		}
		return inner(st)
	}
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	setTransport(t, st, "relay")
	for range 2 {
		if err := k.Rotate(ReasonManual); err != nil {
			t.Fatal(err)
		}
	}
	c.advance(2 * PreviousEpochGrace)
	if n, err := k.EraseExpired(); err != nil || n != 1 || *sd != 1 || *cp != 1 {
		t.Fatalf("EraseExpired = %d, %v: %d secure_delete, %d checkpoints", n, err, *sd, *cp)
	}
	if n, err := k.EraseExpired(); err != nil || n != 0 || *sd != 1 || *cp != 2 {
		t.Fatalf("the owed checkpoint: %d, %v: %d secure_delete, %d checkpoints; want a retry", n, err, *sd, *cp)
	}
	if n, _ := k.EraseExpired(); n != 0 || *cp != 2 {
		t.Fatalf("%d checkpoints after one completed, want no more", *cp)
	}
}
