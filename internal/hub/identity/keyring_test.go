package identity

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/chacha20poly1305"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/logcanary"
)

var (
	_ secure.KeySource     = (*Keyring)(nil)
	_ secure.RollbackGuard = (*Keyring)(nil)
)

func run(from, through byte) []byte {
	out := make([]byte, 0, int(through-from)+1)
	for b := int(from); b <= int(through); b++ {
		out = append(out, byte(b))
	}
	return out
}

// fixedIdentity is the Swift vector's identity: hub_sig 0x41…0x60, hub_kx
// 0x01…0x20, wrap 32 × 0xF0; relay_auth 0x61…0x80.
func fixedIdentity(t *testing.T) Identity {
	t.Helper()
	id, err := fromSeeds(run(0x41, 0x60), run(0x01, 0x20), [32]byte(bytes.Repeat([]byte{0xF0}, 32)), run(0x61, 0x80))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func newClock() *clock { return &clock{t: time.Unix(1_800_000_000, 0).UTC()} }

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func openStore(t *testing.T) *state.Store {
	t.Helper()
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func newKeyring(t *testing.T, st *state.Store, c *clock) *Keyring {
	t.Helper()
	k, err := NewKeyring(fixedIdentity(t), st, c.now)
	if err != nil {
		t.Fatalf("NewKeyring: %v", err)
	}
	return k
}

// The pinned sidecar AADs, written out here rather than through the
// keyring's helpers.
func pinnedMetaAAD(hub secure.ID) []byte { return append([]byte("wt/hub-meta/v1"), hub[:]...) }

func pinnedEpochAAD(hub secure.ID, epoch uint32) []byte {
	return binary.BigEndian.AppendUint32(append([]byte("wt/hub-epoch/v1"), hub[:]...), epoch)
}

// openCombined opens CryptoKit's combined layout: nonce 12 ‖ ct ‖ tag 16.
func openCombined(t *testing.T, wrap []byte, sealed, aad []byte) []byte {
	t.Helper()
	aead, err := chacha20poly1305.New(wrap)
	if err != nil {
		t.Fatal(err)
	}
	if len(sealed) < 12+16 {
		t.Fatalf("sealed value of %d bytes", len(sealed))
	}
	plain, err := aead.Open(nil, sealed[:12], sealed[12:], aad)
	if err != nil {
		t.Fatalf("does not open: %v", err)
	}
	return plain
}

type swiftVector struct {
	HubID       string `json:"hub_id"`
	KMetaSealed string `json:"k_meta_sealed"`
	Epochs      []struct {
		Epoch      uint32 `json:"epoch"`
		SealedKeys string `json:"sealed_keys"`
	} `json:"epochs"`
	KMeta    string `json:"k_meta"`
	DataKey  string `json:"data_key"`
	AlertKey string `json:"alert_key"`
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestKeyring_OpensSwiftSealedKeys(t *testing.T) {
	raw, err := os.ReadFile("testdata/swift-keyring.json")
	if err != nil {
		t.Fatal(err)
	}
	var v swiftVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Epochs) != 1 {
		t.Fatalf("vector has %d epochs", len(v.Epochs))
	}
	hub, err := secure.ParseID(v.HubID)
	if err != nil {
		t.Fatal(err)
	}
	wrap := bytes.Repeat([]byte{0xF0}, 32)
	metaSealed, epochSealed := unhex(t, v.KMetaSealed), unhex(t, v.Epochs[0].SealedKeys)

	// Directly, with the pinned AADs.
	if got := openCombined(t, wrap, metaSealed, pinnedMetaAAD(hub)); hex.EncodeToString(got) != v.KMeta {
		t.Fatal("K_meta differs")
	}
	if got := openCombined(t, wrap, epochSealed, pinnedEpochAAD(hub, v.Epochs[0].Epoch)); hex.EncodeToString(got) != v.DataKey+v.AlertKey {
		t.Fatal("K_data ‖ K_alert differ")
	}

	// Through a Keyring over a sidecar holding the Swift rows.
	st := openStore(t)
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := state.SetMetaTx(tx, state.MetaHubID, strings.ToLower(v.HubID)); err != nil {
			return err
		}
		if err := state.SetMetaTx(tx, state.MetaKMetaSealed, base64.StdEncoding.EncodeToString(metaSealed)); err != nil {
			return err
		}
		return state.InsertEpoch(tx, state.Epoch{Epoch: v.Epochs[0].Epoch, SealedKeys: epochSealed, CreatedAt: time.Now()})
	}); err != nil {
		t.Fatal(err)
	}
	k := newKeyring(t, st, newClock())
	if k.HubID() != hub {
		t.Fatalf("hub id %s, want %s", k.HubID(), hub)
	}
	meta, err := k.MetaKey()
	if err != nil || hex.EncodeToString(meta) != v.KMeta {
		t.Fatalf("MetaKey: %v", err)
	}
	data, err := k.DataKey(v.Epochs[0].Epoch)
	if err != nil || hex.EncodeToString(data) != v.DataKey {
		t.Fatalf("DataKey: %v", err)
	}
	alert, err := k.AlertKey(v.Epochs[0].Epoch)
	if err != nil || hex.EncodeToString(alert) != v.AlertKey {
		t.Fatalf("AlertKey: %v", err)
	}
	if epochs, _ := st.Epochs(); len(epochs) != 1 {
		t.Fatalf("NewKeyring added epochs over the Swift ones: %d", len(epochs))
	}
}

func TestKeyring_SealsWhatSwiftFormatReads(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	hubText, ok, err := st.Meta(state.MetaHubID)
	if err != nil || !ok || hubText != strings.ToUpper(hubText) {
		t.Fatalf("hub_id %q ok %v err %v, want an uppercase UUID", hubText, ok, err)
	}
	if hubText != k.HubID().String() {
		t.Fatal("stored hub_id differs from HubID")
	}
	if k.HubID()[6]>>4 != 4 || k.HubID()[8]>>6 != 2 {
		t.Fatal("hub_id is not a version 4 UUID")
	}
	wrap := bytes.Repeat([]byte{0xF0}, 32)

	text, _, _ := st.Meta(state.MetaKMetaSealed)
	metaSealed, err := base64.StdEncoding.DecodeString(text)
	if err != nil {
		t.Fatalf("k_meta_sealed is not standard base64: %v", err)
	}
	if len(metaSealed) != 12+32+16 {
		t.Fatalf("k_meta_sealed is %d bytes, want nonce 12 ‖ ct 32 ‖ tag 16", len(metaSealed))
	}
	meta, _ := k.MetaKey()
	if !bytes.Equal(openCombined(t, wrap, metaSealed, pinnedMetaAAD(k.HubID())), meta) {
		t.Fatal("K_meta opened with the pinned AAD differs")
	}

	epochs, _ := st.Epochs()
	if len(epochs) != 1 || epochs[0].Epoch != 1 {
		t.Fatalf("epochs = %+v, want epoch 1", epochs)
	}
	if len(epochs[0].SealedKeys) != 12+64+16 {
		t.Fatalf("sealed_keys is %d bytes", len(epochs[0].SealedKeys))
	}
	data, _ := k.DataKey(1)
	alert, _ := k.AlertKey(1)
	if !bytes.Equal(openCombined(t, wrap, epochs[0].SealedKeys, pinnedEpochAAD(k.HubID(), 1)), append(data, alert...)) {
		t.Fatal("epoch keys opened with the pinned AAD differ")
	}
	if bytes.Equal(data, alert) || bytes.Equal(data, meta) {
		t.Fatal("group keys repeat")
	}

	// A second keyring over the same sidecar keeps every key.
	k2 := newKeyring(t, st, newClock())
	meta2, _ := k2.MetaKey()
	data2, _ := k2.DataKey(1)
	if k2.HubID() != k.HubID() || !bytes.Equal(meta2, meta) || !bytes.Equal(data2, data) {
		t.Fatal("a second keyring changed the keys")
	}
}

func TestKeyring_RefusesASidecarOfAnotherIdentity(t *testing.T) {
	st := openStore(t)
	newKeyring(t, st, newClock())
	other, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewKeyring(other, st, time.Now); !errors.Is(err, ErrSealedKeyUnreadable) {
		t.Fatalf("NewKeyring with another identity = %v, want ErrSealedKeyUnreadable", err)
	}
}

func TestKeyring_NextSeqStartsAtOneAndReservesABlock(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	for want := uint64(1); want <= 3; want++ {
		if got, err := k.NextSeq(); err != nil || got != want {
			t.Fatalf("NextSeq = %d, %v; want %d", got, err, want)
		}
	}
	if v, _, _ := st.Meta(state.MetaSeqCeiling); v != "1025" {
		t.Fatalf("envelope_seq_ceiling = %q, want 1025", v)
	}
	if err := st.SetMeta(state.MetaSeqCeiling, "x"); err != nil {
		t.Fatal(err)
	}
	if _, err := NewKeyring(fixedIdentity(t), st, time.Now); err != nil {
		t.Fatal(err) // the ceiling is read lazily
	}
	k3, _ := NewKeyring(fixedIdentity(t), st, time.Now)
	if _, err := k3.NextSeq(); !errors.Is(err, ErrCorruptSeqCeiling) {
		t.Fatalf("NextSeq over a corrupt ceiling = %v", err)
	}
}

func TestKeyring_RotatesAt90DaysOrSeqCap(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	ctx := context.Background()
	if err := st.WithTx(ctx, func(tx *sql.Tx) error { return state.SetSliceState(tx, "target-1", "w", "h", c.now()) }); err != nil {
		t.Fatal(err)
	}
	data1, _ := k.DataKey(1)

	c.advance(RotationAge - time.Second)
	if rotated, err := k.RotateIfDue(); err != nil || rotated {
		t.Fatalf("RotateIfDue before 90 days = %v, %v", rotated, err)
	}
	c.advance(time.Second)
	if rotated, err := k.RotateIfDue(); err != nil || !rotated {
		t.Fatalf("RotateIfDue at 90 days = %v, %v", rotated, err)
	}
	if cur, _ := k.CurrentEpoch(); cur != 2 {
		t.Fatalf("epoch %d, want 2", cur)
	}
	if rotated, _ := k.RotateIfDue(); rotated {
		t.Fatal("rotated twice")
	}
	epochs, _ := st.Epochs()
	if epochs[0].RetiredAt == nil || !epochs[0].RetiredAt.Equal(c.now()) || epochs[1].RetiredAt != nil {
		t.Fatalf("retirement stamps wrong: %+v", epochs)
	}
	if got, _ := st.SliceHashes("target"); got["target-1"].Hash != "" {
		t.Fatal("the rotation kept slice hashes")
	}
	data2, _ := k.DataKey(2)
	if bytes.Equal(data1, data2) {
		t.Fatal("the new epoch reuses K_data")
	}
	if old, err := k.DataKey(1); err != nil || !bytes.Equal(old, data1) {
		t.Fatal("the retired epoch's keys are gone")
	}

	// The seq cap: counted from the epoch's first seq.
	first := epochs[1].FirstSeq
	if err := st.SetMeta(state.MetaSeqCeiling, strconv.FormatUint(first+RotationSeqCap-1, 10)); err != nil {
		t.Fatal(err)
	}
	if rotated, _ := k.RotateIfDue(); rotated {
		t.Fatal("rotated below the seq cap")
	}
	if err := st.SetMeta(state.MetaSeqCeiling, strconv.FormatUint(first+RotationSeqCap, 10)); err != nil {
		t.Fatal(err)
	}
	if rotated, err := k.RotateIfDue(); err != nil || !rotated {
		t.Fatalf("RotateIfDue at the seq cap = %v, %v", rotated, err)
	}
	epochs, _ = st.Epochs()
	if len(epochs) != 3 || epochs[2].FirstSeq != first+RotationSeqCap {
		t.Fatalf("epoch 3 = %+v, want first_seq at the ceiling", epochs)
	}
}

func TestKeyring_RotateWithRollsBackTogether(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	boom := errors.New("boom")
	if err := k.RotateWith(ReasonUnlink, func(*sql.Tx) error { return boom }); !errors.Is(err, boom) {
		t.Fatalf("RotateWith = %v", err)
	}
	if cur, _ := k.CurrentEpoch(); cur != 1 {
		t.Fatalf("a failed rotation moved the epoch to %d", cur)
	}
	if err := k.Rotate("other"); err == nil {
		t.Fatal("an unknown reason rotated")
	}
}

// linkPhone writes a linked device row with fresh relay material and returns
// the phone's id and agreement key.
func linkPhone(t *testing.T, st *state.Store, nonce []byte) (secure.ID, *ecdh.PrivateKey) {
	t.Helper()
	sig, _ := fixedPhoneSigning()
	kx, err := ecdh.X25519().NewPrivateKey(run(0x21, 0x40))
	if err != nil {
		t.Fatal(err)
	}
	dev := secure.DeviceID(sig)
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: dev.String(), Name: "Phone", Scope: "private", LinkedAt: time.Unix(1_800_000_000, 0),
			SigningKey: sig, AgreementKey: kx.PublicKey().Bytes(),
			LinkNonce: base64.RawURLEncoding.EncodeToString(nonce),
		})
	}); err != nil {
		t.Fatal(err)
	}
	return dev, kx
}

func fixedPhoneSigning() (ed25519.PublicKey, ed25519.PrivateKey) {
	priv := ed25519.NewKeyFromSeed(run(0x61, 0x80))
	return priv.Public().(ed25519.PublicKey), priv
}

func TestKeyring_PreviousEpochAcceptedFor7Days(t *testing.T) {
	st := openStore(t)
	c := newClock()
	k := newKeyring(t, st, c)
	dev, phoneKX := linkPhone(t, st, run(0xA0, 0xBF))
	unknown := secure.ID{1}

	if ok, err := k.AcceptsRelayEpoch(1, unknown); err != nil || ok {
		t.Fatalf("unknown device accepted: %v %v", ok, err)
	}
	if kk, _ := k.KeyboxKeys(); kk.PreviousEpoch != nil || kk.Epoch != 1 {
		t.Fatalf("keybox keys before a rotation = %+v", kk)
	}
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	for _, e := range []uint32{1, 2} {
		if ok, err := k.AcceptsRelayEpoch(e, dev); err != nil || !ok {
			t.Fatalf("epoch %d refused right after the rotation: %v", e, err)
		}
	}
	if ok, _ := k.AcceptsRelayEpoch(3, dev); ok {
		t.Fatal("a future epoch was accepted")
	}
	kk, err := k.KeyboxKeys()
	if err != nil || kk.Epoch != 2 || kk.PreviousEpoch == nil || *kk.PreviousEpoch != 1 {
		t.Fatalf("keybox keys = %+v, %v", kk, err)
	}
	old, _ := k.DataKey(1)
	if *kk.PreviousDataKey != base64.RawURLEncoding.EncodeToString(old) {
		t.Fatal("previous data key differs")
	}
	meta, _ := k.MetaKey()
	cur, _ := k.AlertKey(2)
	if kk.MetaKey != base64.RawURLEncoding.EncodeToString(meta) || kk.AlertKey != base64.RawURLEncoding.EncodeToString(cur) {
		t.Fatal("current keybox keys differ")
	}

	c.advance(PreviousEpochGrace - time.Second)
	if ok, _ := k.AcceptsRelayEpoch(1, dev); !ok {
		t.Fatal("previous epoch refused inside the grace")
	}
	c.advance(time.Second)
	if ok, _ := k.AcceptsRelayEpoch(1, dev); ok {
		t.Fatal("previous epoch accepted after 7 days")
	}
	if kk, _ := k.KeyboxKeys(); kk.PreviousEpoch != nil || kk.PreviousDataKey != nil {
		t.Fatal("keybox still carries the previous epoch after 7 days")
	}
	if ok, _ := k.AcceptsRelayEpoch(2, dev); !ok {
		t.Fatal("current epoch refused")
	}

	// The relay key is the pairwise key the phone derives on its side.
	hubKey, err := k.RelayKey(secure.PhoneToHub, dev, 2)
	if err != nil {
		t.Fatal(err)
	}
	phoneKey, err := secure.RelayKey(phoneKX, k.Agreement().PublicKey(), run(0xA0, 0xBF), k.HubID(), dev, 2, secure.PhoneToHub)
	if err != nil || !bytes.Equal(hubKey, phoneKey) {
		t.Fatalf("relay key differs from the phone's: %v", err)
	}
	h2p, _ := k.RelayKey(secure.HubToPhone, dev, 2)
	if bytes.Equal(h2p, hubKey) {
		t.Fatal("directions share a key")
	}
	// A re-link with a new nonce re-derives.
	linkPhone(t, st, run(0xB0, 0xCF))
	relinked, _ := k.RelayKey(secure.PhoneToHub, dev, 2)
	if bytes.Equal(relinked, hubKey) {
		t.Fatal("the cached relay key survived a re-link")
	}
	if _, err := k.RelayKey(secure.PhoneToHub, unknown, 2); !errors.Is(err, ErrUnknownDevice) {
		t.Fatalf("relay key for an unknown device: %v", err)
	}
	// Removing the device drops its material.
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM devices`)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := k.RelayKey(secure.PhoneToHub, dev, 2); !errors.Is(err, ErrUnknownDevice) {
		t.Fatalf("relay key after removal: %v", err)
	}
}

func TestKeyring_KeyboxRecipient(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	dev, phoneKX := linkPhone(t, st, run(0xA0, 0xBF))
	pub, err := k.KeyboxRecipient(dev)
	if err != nil || !pub.Equal(phoneKX.PublicKey()) {
		t.Fatalf("KeyboxRecipient = %v", err)
	}
	if _, err := k.KeyboxRecipient(secure.ID{9}); !errors.Is(err, ErrNoKeyboxRecipient) {
		t.Fatalf("KeyboxRecipient for nobody = %v", err)
	}
}

func TestKeyring_RollbackGuard(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	dev := secure.ID{0xAB}
	if v, err := k.Check("w", dev, 1, 5); err != nil || v != secure.Newer {
		t.Fatalf("Check on nothing = %v, %v", v, err)
	}
	if err := k.Record("w", dev, 1, 5); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		epoch uint32
		seq   uint64
		want  secure.Verdict
	}{{1, 5, secure.Same}, {1, 4, secure.Older}, {1, 6, secure.Newer}, {2, 1, secure.Newer}, {0, 99, secure.Older}} {
		if v, _ := k.Check("w", dev, c.epoch, c.seq); v != c.want {
			t.Fatalf("Check %d/%d = %v, want %v", c.epoch, c.seq, v, c.want)
		}
	}
	if err := k.Record("w", dev, 1, 2); err != nil {
		t.Fatal(err)
	}
	if v, _ := k.Check("w", dev, 1, 5); v != secure.Same {
		t.Fatal("Record lowered the mark")
	}
	if v, _ := k.Check("w", secure.ID{0xCD}, 1, 1); v != secure.Newer {
		t.Fatal("the mark is not per sender")
	}
}

func TestSealLocalRoundTripAndLabelBinding(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	plain := []byte("milestone text")
	sealed, err := k.SealLocal("session_milestones.text", plain)
	if err != nil {
		t.Fatal(err)
	}
	if len(sealed) != 12+len(plain)+16 || bytes.Contains(sealed, plain) {
		t.Fatal("not the combined sealed layout")
	}
	got, err := k.OpenLocal("session_milestones.text", sealed)
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("OpenLocal = %q, %v", got, err)
	}
	hub := k.HubID()
	aad := append(append([]byte("wt/hub-local/v1"), hub[:]...), "session_milestones.text"...)
	if !bytes.Equal(openCombined(t, bytes.Repeat([]byte{0xF0}, 32), sealed, aad), plain) {
		t.Fatal("the pinned local AAD does not open it")
	}
	if _, err := k.OpenLocal("session_reports.payload", sealed); !errors.Is(err, ErrSealedKeyUnreadable) {
		t.Fatalf("OpenLocal under another label = %v", err)
	}
	sealed[len(sealed)-1] ^= 1
	if _, err := k.OpenLocal("session_milestones.text", sealed); !errors.Is(err, ErrSealedKeyUnreadable) {
		t.Fatalf("OpenLocal of a tampered value = %v", err)
	}
	if _, err := k.SealLocal("", plain); err == nil {
		t.Fatal("an empty label sealed")
	}
	again, _ := k.SealLocal("session_milestones.text", plain)
	if bytes.Equal(again[:12], sealed[:12]) {
		t.Fatal("nonce reused")
	}
}

func TestIdentityNeverLogged(t *testing.T) {
	sink := logcanary.Capture(t)
	dir := filepath.Join(t.TempDir(), "hub")
	fs := FileStore{Path: filepath.Join(dir, FileName)}
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := fs.Save(id); err != nil {
		t.Fatal(err)
	}
	loaded, err := fs.Load()
	if err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	c := newClock()
	k, err := NewKeyring(loaded, st, c.now)
	if err != nil {
		t.Fatal(err)
	}
	dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	c.advance(RotationAge)
	if _, err := k.RotateIfDue(); err != nil {
		t.Fatal(err)
	}
	relay, _ := k.RelayKey(secure.HubToPhone, dev, 3)
	// An unusable device row and a recipient that does not parse log a line each.
	bad := secure.ID{0x77}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{ID: bad.String(), Name: "x", Scope: "private", AgreementKey: []byte{1, 2}, LinkNonce: "AAAA"})
	}); err != nil {
		t.Fatal(err)
	}
	_, _ = k.RelayKey(secure.HubToPhone, bad, 3)
	_, _ = k.KeyboxRecipient(bad)

	if !strings.Contains(sink.String(), "epoch 3 begun") {
		t.Fatalf("the rotation did not log (the check would prove nothing): %q", sink.String())
	}
	secrets := [][]byte{loaded.Signing.Seed(), loaded.Agreement.Bytes(), loaded.Wrap[:], loaded.RelayAuth.Seed(), relay}
	meta, _ := k.MetaKey()
	secrets = append(secrets, meta)
	for e := uint32(1); e <= 3; e++ {
		d, _ := k.DataKey(e)
		a, _ := k.AlertKey(e)
		secrets = append(secrets, d, a)
	}
	logged := strings.ToLower(sink.String())
	for _, s := range secrets {
		for _, form := range []string{
			hex.EncodeToString(s), hex.EncodeToString(s[:8]),
			strings.ToLower(base64.StdEncoding.EncodeToString(s)), strings.ToLower(base64.RawURLEncoding.EncodeToString(s)),
		} {
			if strings.Contains(logged, form) {
				t.Fatalf("key material reached the log: %q", sink.String())
			}
		}
	}
	sink.AssertClean(t)
}

func TestKeyring_RelayDevicesListsUsableLinkedPhones(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	if ids, err := k.RelayDevices(); err != nil || len(ids) != 0 {
		t.Fatalf("RelayDevices on no phones = %v, %v", ids, err)
	}
	dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
	bad := secure.ID{0x77}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{ID: bad.String(), Name: "x", Scope: "private", AgreementKey: []byte{1, 2}, LinkNonce: "AAAA"})
	}); err != nil {
		t.Fatal(err)
	}
	ids, err := k.RelayDevices()
	if err != nil || len(ids) != 1 || ids[0] != dev {
		t.Fatalf("RelayDevices = %v, %v; want only %s", ids, err, dev)
	}
}

// The Sealer and Opener zero every key they get: a key the keyring hands out
// must be a fresh copy, so zeroing it leaves the keyring's own intact.
func TestKeyring_ReturnedKeysAreFreshCopies(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
	getters := map[string]func() ([]byte, error){
		"meta":  k.MetaKey,
		"data":  func() ([]byte, error) { return k.DataKey(1) },
		"alert": func() ([]byte, error) { return k.AlertKey(1) },
		"relay": func() ([]byte, error) { return k.RelayKey(secure.PhoneToHub, dev, 1) },
	}
	for name, get := range getters {
		first, err := get()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		want := bytes.Clone(first)
		clear(first)
		again, err := get()
		if err != nil || !bytes.Equal(again, want) {
			t.Fatalf("%s: zeroing a returned key changed the keyring's copy", name)
		}
	}
}

// Review fix: RelayKey against concurrent re-links and removals never hands
// out a zeroed key or one derived from a wiped nonce (run with -race).
func TestKeyring_RelayKeyRacesReLinkAndUnlink(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	nonces := [][]byte{run(0xA0, 0xBF), run(0xB0, 0xCF)}
	dev, phoneKX := linkPhone(t, st, nonces[0])
	valid := map[string]bool{}
	for _, n := range nonces {
		for _, dir := range []secure.Direction{secure.PhoneToHub, secure.HubToPhone} {
			key, err := secure.RelayKey(phoneKX, k.Agreement().PublicKey(), n, k.HubID(), dev, 1, dir)
			if err != nil {
				t.Fatal(err)
			}
			valid[string(key)] = true
		}
	}
	stop := make(chan struct{})
	var wg sync.WaitGroup
	errs := make(chan string, 8)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			dir := []secure.Direction{secure.PhoneToHub, secure.HubToPhone}[i%2]
			for {
				select {
				case <-stop:
					return
				default:
				}
				key, err := k.RelayKey(dir, dev, 1)
				if errors.Is(err, ErrUnknownDevice) {
					continue
				}
				if err != nil {
					errs <- err.Error()
					return
				}
				if allZero(key) || !valid[string(key)] {
					errs <- "RelayKey returned a zeroed or foreign key"
					return
				}
				clear(key) // as the Sealer does
			}
		}(i)
	}
	for i := 0; i < 200; i++ {
		if i%3 == 2 {
			if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
				_, err := tx.Exec(`DELETE FROM devices`)
				return err
			}); err != nil {
				t.Fatal(err)
			}
		} else {
			linkPhone(t, st, nonces[i%2])
		}
		_, _ = k.RelayDevices()
		_, _ = k.AcceptsRelayEpoch(1, dev)
	}
	close(stop)
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Fatal(e)
	}
}

func TestKeyring_RotateWithSkipWritesNothing(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	err := k.RotateWith(ReasonUnlink, func(tx *sql.Tx) error {
		if _, err := tx.Exec(`DELETE FROM hub_epochs`); err != nil {
			return err
		}
		return ErrSkipRotation
	})
	if err != nil {
		t.Fatalf("RotateWith with a skip = %v, want nil", err)
	}
	epochs, _ := st.Epochs()
	if len(epochs) != 1 || epochs[0].Epoch != 1 || epochs[0].RetiredAt != nil {
		t.Fatalf("a skipped rotation wrote: %+v", epochs)
	}
}

func TestKeyring_UnusableRowLoggedOncePerChange(t *testing.T) {
	sink := logcanary.Capture(t)
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	bad := secure.ID{0x77}
	link := func(nonce string) {
		t.Helper()
		if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
			return state.LinkDevice(tx, state.Device{ID: bad.String(), Name: "x", Scope: "private", AgreementKey: []byte{1, 2}, LinkNonce: nonce})
		}); err != nil {
			t.Fatal(err)
		}
	}
	link("AAAA")
	for i := 0; i < 5; i++ {
		_, _ = k.RelayKey(secure.HubToPhone, bad, 1)
	}
	link("BBBB")
	_, _ = k.RelayKey(secure.HubToPhone, bad, 1)
	_, _ = k.RelayKey(secure.HubToPhone, bad, 1)
	if n := strings.Count(sink.String(), "is unusable"); n != 2 {
		t.Fatalf("unusable row logged %d times, want 2 (once per change)", n)
	}
}

func TestRelayMaterialWipeLeavesNothing(t *testing.T) {
	m := &relayMaterial{nonce: []byte{1, 2}, keys: map[string][]byte{"p2h/1": {3, 4}}}
	key, nonce := m.keys["p2h/1"], m.nonce
	m.wipe()
	if m.keys != nil || m.nonce != nil || m.peer != nil || !allZero(key) || !allZero(nonce) {
		t.Fatal("wipe left material reachable")
	}
}

// A rotation moves the work alerts with the sync generation, as the Swift
// hub's wipeForRotation does: a pushed alert stays published under the new
// epoch.
func TestRotateMovesWorkAlertsToTheNewGeneration(t *testing.T) {
	c := newClock()
	st := openStore(t)
	k := newKeyring(t, st, c)
	ctx := context.Background()
	if _, _, err := st.NoteWorkAlerts(ctx, []string{"ask-1"}, map[string]bool{"ask-1": true}, c.now()); err != nil {
		t.Fatal(err)
	}
	if err := k.Rotate(ReasonManual); err != nil {
		t.Fatal(err)
	}
	gen, marks, err := st.NoteWorkAlerts(ctx, nil, nil, c.now())
	if err != nil {
		t.Fatal(err)
	}
	if gen != 1 || marks["ask-1"].Generation != 1 {
		t.Fatalf("after rotation: gen %d, mark %+v", gen, marks["ask-1"])
	}
}

func TestKeyring_WipeZeroesRelayMaterialAndReDerives(t *testing.T) {
	st := openStore(t)
	k := newKeyring(t, st, newClock())
	dev, _ := linkPhone(t, st, run(0xA0, 0xBF))
	before, err := k.RelayKey(secure.PhoneToHub, dev, 1)
	if err != nil {
		t.Fatal(err)
	}
	k.mu.Lock()
	m := k.relay[dev]
	k.mu.Unlock()
	if m == nil || len(m.keys) == 0 {
		t.Fatal("no cached relay material before Wipe")
	}
	var held [][]byte
	for _, key := range m.keys {
		held = append(held, key)
	}
	nonce := m.nonce

	k.Wipe()
	for _, key := range held {
		if !allZero(key) {
			t.Fatal("a cached relay key survived Wipe")
		}
	}
	if !allZero(nonce) {
		t.Fatal("the cached link nonce survived Wipe")
	}
	k.mu.Lock()
	left := len(k.relay)
	k.mu.Unlock()
	if left != 0 || m.keys != nil || m.peer != nil {
		t.Fatalf("material still cached after Wipe: %d entries", left)
	}

	again, err := k.RelayKey(secure.PhoneToHub, dev, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again, before) || allZero(again) {
		t.Fatal("the keyring did not re-derive the same relay key after Wipe")
	}
}
