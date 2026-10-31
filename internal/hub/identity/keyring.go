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
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// Rotation and relay-window constants (spec §2.2, D10), the Swift
// HubKeyring's values.
const (
	// PreviousEpochGrace: the retired epoch's relay envelopes are accepted,
	// and keyboxes carry its keys, this long after it was retired.
	PreviousEpochGrace = 7 * 24 * time.Hour
	// RotationAge: the epoch rotates when it is this old.
	RotationAge = 90 * 24 * time.Hour
	// RotationSeqCap: … or when it has used this many envelope seqs.
	RotationSeqCap uint64 = 1 << 28
	// seqBlock is the SeqAllocator reservation over envelope_seq_ceiling.
	seqBlock = 1024
)

// Reason says why the epoch rotates.
type Reason string

// The rotation reasons.
const (
	ReasonAge    Reason = "age"
	ReasonCap    Reason = "cap"
	ReasonUnlink Reason = "unlink"
	ReasonManual Reason = "manual"
)

var (
	// ErrKeysUnavailable: the sidecar holds no K_meta or epoch yet.
	ErrKeysUnavailable = errors.New("identity: hub keys unavailable")
	// ErrUnknownEpoch: no hub_epochs row for the epoch.
	ErrUnknownEpoch = errors.New("identity: unknown epoch")
	// ErrSealedKeyUnreadable: a sealed key or local value does not open
	// under this identity's wrap key (the identity was recreated) or does not
	// have the sealed shape. Never names its bytes.
	ErrSealedKeyUnreadable = errors.New("identity: sealed key does not open under this identity")
	// ErrUnknownDevice: no linked phone with usable relay material.
	ErrUnknownDevice = errors.New("identity: no relay material for the device")
	// ErrNoKeyboxRecipient: no agreement key is stored for the device.
	ErrNoKeyboxRecipient = errors.New("identity: no keybox recipient for the device")
	// ErrCorruptSeqCeiling: envelope_seq_ceiling is not a number; never read
	// as 0, which would reuse seqs.
	ErrCorruptSeqCeiling = errors.New("identity: envelope_seq_ceiling is not a number")
	// ErrEpochOverflow: the current epoch is MaxUint32.
	ErrEpochOverflow = errors.New("identity: no epoch after the current one")
)

// The sidecar AADs (pinned with the Swift HubKeyring; phase 3 adopts its
// sealed keys with the same wrap key).
const (
	metaAADLabel  = "wt/hub-meta/v1"
	epochAADLabel = "wt/hub-epoch/v1"
	localAADLabel = "wt/hub-local/v1"
)

// Keyring is the hub's secure.KeySource and relay secure.RollbackGuard over
// the sidecar: K_meta (hub_meta.k_meta_sealed, base64 of the sealed bytes)
// and each epoch's K_data ‖ K_alert (hub_epochs.sealed_keys) sealed with
// ChaChaPoly under the wrap key, one SeqAllocator over
// envelope_seq_ceiling (one keyring per sidecar), and the pairwise relay
// keys cached per (device, epoch, direction), re-derived when the device
// row's agreement_key or link_nonce changes. It borrows the Identity; the
// owner zeroes it.
type Keyring struct {
	id  Identity
	hub secure.ID
	st  *state.Store
	now func() time.Time
	seq *secure.SeqAllocator

	mu    sync.Mutex
	relay map[secure.ID]*relayMaterial
}

// relayMaterial is one phone's relay inputs, checked once, and the keys
// derived from them so far ("p2h/1" → key).
type relayMaterial struct {
	agreementKey []byte
	linkNonce    string
	peer         *ecdh.PublicKey
	nonce        []byte
	keys         map[string][]byte
}

func (m *relayMaterial) wipe() {
	for _, k := range m.keys {
		clear(k)
	}
	clear(m.nonce)
}

// NewKeyring opens the keyring over st, creating in one transaction what is
// missing: hub_id (an uppercase UUID), K_meta and epoch 1. Stored keys that
// do not open under id's wrap key are ErrSealedKeyUnreadable: the hub must
// not run on another identity's sidecar.
func NewKeyring(id Identity, st *state.Store, now func() time.Time) (*Keyring, error) {
	if !id.complete() {
		return nil, errors.New("identity: incomplete identity")
	}
	if now == nil {
		now = time.Now
	}
	k := &Keyring{id: id, st: st, now: now, relay: map[secure.ID]*relayMaterial{}}
	err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		hubText, ok, err := state.MetaTx(tx, state.MetaHubID)
		if err != nil {
			return err
		}
		if !ok {
			if _, err := rand.Read(k.hub[:]); err != nil {
				return fmt.Errorf("identity: random: %w", err)
			}
			k.hub[6] = k.hub[6]&0x0f | 0x40 // version 4
			k.hub[8] = k.hub[8]&0x3f | 0x80 // RFC 4122 variant
			if err := state.SetMetaTx(tx, state.MetaHubID, k.hub.String()); err != nil {
				return err
			}
		} else if k.hub, err = secure.ParseID(hubText); err != nil {
			return errors.New("identity: hub_id is not a UUID")
		}
		if _, ok, err := state.MetaTx(tx, state.MetaKMetaSealed); err != nil {
			return err
		} else if !ok {
			meta := randomKey(32)
			defer clear(meta)
			sealed, err := k.seal(meta, k.metaAAD())
			if err != nil {
				return err
			}
			if err := state.SetMetaTx(tx, state.MetaKMetaSealed, base64.StdEncoding.EncodeToString(sealed)); err != nil {
				return err
			}
		}
		epochs, err := state.EpochsTx(tx)
		if err != nil {
			return err
		}
		if len(epochs) == 0 {
			return k.insertEpoch(tx, 1, k.now())
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	// Probe the stored keys once: a sidecar sealed by another identity fails
	// here, not at the first publish.
	meta, err := k.MetaKey()
	if err != nil {
		return nil, err
	}
	clear(meta)
	cur, err := k.CurrentEpoch()
	if err != nil {
		return nil, err
	}
	keys, err := k.epochKeys(cur)
	if err != nil {
		return nil, err
	}
	clear(keys)
	k.seq = secure.NewSeqAllocator(seqBlock, k.seqCeiling, func(v uint64) error {
		return st.SetMeta(state.MetaSeqCeiling, strconv.FormatUint(v, 10))
	})
	return k, nil
}

// insertEpoch seals fresh K_data ‖ K_alert for epoch and inserts it with
// first_seq = the seq ceiling now, in tx.
func (k *Keyring) insertEpoch(tx *sql.Tx, epoch uint32, at time.Time) error {
	keys := randomKey(64)
	defer clear(keys)
	sealed, err := k.seal(keys, k.epochAAD(epoch))
	if err != nil {
		return err
	}
	text, _, err := state.MetaTx(tx, state.MetaSeqCeiling)
	if err != nil {
		return err
	}
	first, err := parseCeiling(text)
	if err != nil {
		return err
	}
	return state.InsertEpoch(tx, state.Epoch{Epoch: epoch, SealedKeys: sealed, CreatedAt: at, FirstSeq: first})
}

// HubID is the hub's id.
func (k *Keyring) HubID() secure.ID { return k.hub }

// Signer is hub_sig.
func (k *Keyring) Signer() ed25519.PrivateKey { return k.id.Signing }

// Agreement is hub_kx.
func (k *Keyring) Agreement() *ecdh.PrivateKey { return k.id.Agreement }

// NextSeq hands out the next envelope seq.
func (k *Keyring) NextSeq() (uint64, error) { return k.seq.Next() }

func (k *Keyring) seqCeiling() (uint64, error) {
	text, _, err := k.st.Meta(state.MetaSeqCeiling)
	if err != nil {
		return 0, err
	}
	return parseCeiling(text)
}

func parseCeiling(text string) (uint64, error) {
	if text == "" {
		return 0, nil
	}
	v, err := strconv.ParseUint(text, 10, 64)
	if err != nil {
		return 0, ErrCorruptSeqCeiling
	}
	return v, nil
}

// MetaKey opens K_meta. The caller owns (and may zero) the returned slice.
func (k *Keyring) MetaKey() ([]byte, error) {
	text, ok, err := k.st.Meta(state.MetaKMetaSealed)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, ErrKeysUnavailable
	}
	sealed, err := base64.StdEncoding.DecodeString(text)
	if err != nil {
		return nil, fmt.Errorf("%w: k_meta", ErrSealedKeyUnreadable)
	}
	plain, err := k.open(sealed, k.metaAAD())
	if err != nil || len(plain) != 32 {
		clear(plain)
		return nil, fmt.Errorf("%w: k_meta", ErrSealedKeyUnreadable)
	}
	return plain, nil
}

// CurrentEpoch is the newest epoch.
func (k *Keyring) CurrentEpoch() (uint32, error) {
	epochs, err := k.st.Epochs()
	if err != nil {
		return 0, err
	}
	if len(epochs) == 0 {
		return 0, ErrKeysUnavailable
	}
	return epochs[len(epochs)-1].Epoch, nil
}

// DataKey is the epoch's K_data; the caller owns the slice.
func (k *Keyring) DataKey(epoch uint32) ([]byte, error) { return k.epochKey(epoch, 0) }

// AlertKey is the epoch's K_alert; the caller owns the slice.
func (k *Keyring) AlertKey(epoch uint32) ([]byte, error) { return k.epochKey(epoch, 32) }

func (k *Keyring) epochKey(epoch uint32, at int) ([]byte, error) {
	keys, err := k.epochKeys(epoch)
	if err != nil {
		return nil, err
	}
	defer clear(keys)
	return bytes.Clone(keys[at : at+32]), nil
}

// epochKeys opens the epoch's K_data ‖ K_alert (64 bytes).
func (k *Keyring) epochKeys(epoch uint32) ([]byte, error) {
	epochs, err := k.st.Epochs()
	if err != nil {
		return nil, err
	}
	for _, e := range epochs {
		if e.Epoch == epoch {
			return k.openEpoch(e)
		}
	}
	return nil, fmt.Errorf("%w: %d", ErrUnknownEpoch, epoch)
}

func (k *Keyring) openEpoch(e state.Epoch) ([]byte, error) {
	plain, err := k.open(e.SealedKeys, k.epochAAD(e.Epoch))
	if err != nil || len(plain) != 64 {
		clear(plain)
		return nil, fmt.Errorf("%w: epoch %d", ErrSealedKeyUnreadable, e.Epoch)
	}
	return plain, nil
}

// window is the current epoch and, while its grace runs, the retired one
// before it (nil otherwise).
func (k *Keyring) window() (current state.Epoch, previous *state.Epoch, err error) {
	epochs, err := k.st.Epochs()
	if err != nil {
		return state.Epoch{}, nil, err
	}
	if len(epochs) == 0 {
		return state.Epoch{}, nil, ErrKeysUnavailable
	}
	current = epochs[len(epochs)-1]
	if len(epochs) >= 2 {
		retired := epochs[len(epochs)-2]
		at := current.CreatedAt
		if retired.RetiredAt != nil {
			at = *retired.RetiredAt
		}
		if k.now().Sub(at) < PreviousEpochGrace {
			previous = &retired
		}
	}
	return current, previous, nil
}

// KeyboxKeys are the keys a linked phone's keybox carries (spec §2.3): the
// current epoch's K_data and K_alert and K_meta, plus the retired epoch's
// while its grace runs. Strings are unpadded base64url.
func (k *Keyring) KeyboxKeys() (wire.KeyboxKeys, error) {
	current, previous, err := k.window()
	if err != nil {
		return wire.KeyboxKeys{}, err
	}
	keys, err := k.openEpoch(current)
	if err != nil {
		return wire.KeyboxKeys{}, err
	}
	defer clear(keys)
	meta, err := k.MetaKey()
	if err != nil {
		return wire.KeyboxKeys{}, err
	}
	defer clear(meta)
	b64 := base64.RawURLEncoding.EncodeToString
	out := wire.KeyboxKeys{Epoch: current.Epoch, DataKey: b64(keys[:32]), AlertKey: b64(keys[32:]), MetaKey: b64(meta)}
	if previous != nil {
		prev, err := k.openEpoch(*previous)
		if err != nil {
			return wire.KeyboxKeys{}, err
		}
		defer clear(prev)
		epoch, data, alert := previous.Epoch, b64(prev[:32]), b64(prev[32:])
		out.PreviousEpoch, out.PreviousDataKey, out.PreviousAlertKey = &epoch, &data, &alert
	}
	return out, nil
}

// AcceptsRelayEpoch accepts the current epoch, and the previous one until
// PreviousEpochGrace after it was retired (D10). false for a device without
// usable relay material.
func (k *Keyring) AcceptsRelayEpoch(epoch uint32, device secure.ID) (bool, error) {
	m, err := k.material(device)
	if err != nil || m == nil {
		return false, err
	}
	current, previous, err := k.window()
	if errors.Is(err, ErrKeysUnavailable) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return epoch == current.Epoch || (previous != nil && epoch == previous.Epoch), nil
}

// RelayKey is the pairwise relay key for one phone, epoch and direction.
// The caller owns the returned slice; the cache keeps its own copy.
func (k *Keyring) RelayKey(dir secure.Direction, device secure.ID, epoch uint32) ([]byte, error) {
	m, err := k.material(device)
	if err != nil {
		return nil, err
	}
	if m == nil {
		return nil, ErrUnknownDevice
	}
	slot := string(dir) + "/" + strconv.FormatUint(uint64(epoch), 10)
	k.mu.Lock()
	defer k.mu.Unlock()
	if key, ok := m.keys[slot]; ok {
		return bytes.Clone(key), nil
	}
	key, err := secure.RelayKey(k.id.Agreement, m.peer, m.nonce, k.hub, device, epoch, dir)
	if err != nil {
		return nil, fmt.Errorf("identity: deriving a relay key: %w", err)
	}
	m.keys[slot] = key
	return bytes.Clone(key), nil
}

// RelayDevices is every linked phone with usable relay material (the Swift
// relayDeviceIDs): the senders the Opener accepts and the keys it tries for
// the hub's own echoes. The cache keeps exactly these.
func (k *Keyring) RelayDevices() ([]secure.ID, error) {
	rows, err := k.st.Devices()
	if err != nil {
		return nil, err
	}
	var out []secure.ID
	keep := map[secure.ID]bool{}
	for _, row := range rows {
		id, err := secure.ParseID(row.ID)
		if err != nil {
			log.Printf("hub: a linked device id is not a UUID")
			continue
		}
		m, err := k.material(id)
		if err != nil {
			return nil, err
		}
		if m != nil {
			out = append(out, id)
			keep[id] = true
		}
	}
	k.mu.Lock()
	for id, m := range k.relay {
		if !keep[id] {
			m.wipe()
			delete(k.relay, id)
		}
	}
	k.mu.Unlock()
	return out, nil
}

// material re-reads the device row and returns its cached material, kept
// when the row's agreement_key and link_nonce are unchanged and rebuilt
// otherwise; nil when the device is not linked or its row is unusable (a
// key that does not parse or agree, a nonce that is not base64url).
func (k *Keyring) material(device secure.ID) (*relayMaterial, error) {
	row, ok, err := k.st.Device(device.String())
	if err != nil {
		return nil, err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	cached := k.relay[device]
	if !ok || len(row.AgreementKey) == 0 || row.LinkNonce == "" {
		if cached != nil {
			cached.wipe()
			delete(k.relay, device)
		}
		return nil, nil
	}
	if cached != nil && bytes.Equal(cached.agreementKey, row.AgreementKey) && cached.linkNonce == row.LinkNonce {
		return cached, nil
	}
	if cached != nil {
		cached.wipe()
		delete(k.relay, device)
	}
	m := k.makeMaterial(row)
	if m == nil {
		log.Printf("hub: relay material of device %s is unusable", device)
		return nil, nil
	}
	k.relay[device] = m
	return m, nil
}

func (k *Keyring) makeMaterial(row state.Device) *relayMaterial {
	nonce, err := base64.RawURLEncoding.Strict().DecodeString(row.LinkNonce)
	if err != nil || len(nonce) == 0 {
		return nil
	}
	peer, err := ecdh.X25519().NewPublicKey(row.AgreementKey)
	if err != nil {
		return nil
	}
	// Probe the agreement once, so a cached device's relay keys always derive.
	shared, err := k.id.Agreement.ECDH(peer)
	clear(shared)
	if err != nil {
		return nil
	}
	return &relayMaterial{
		agreementKey: bytes.Clone(row.AgreementKey), linkNonce: row.LinkNonce,
		peer: peer, nonce: nonce, keys: map[string][]byte{},
	}
}

// KeyboxRecipient is the agreement key a keybox for device is sealed to: a
// linked, pending, revoked or refused device's (F5). ErrNoKeyboxRecipient
// when none is stored or it does not parse.
func (k *Keyring) KeyboxRecipient(device secure.ID) (*ecdh.PublicKey, error) {
	raw, err := k.st.KeyboxRecipientKey(device.String())
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return nil, ErrNoKeyboxRecipient
	}
	pub, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		log.Printf("hub: stored agreement key of device %s does not parse", device)
		return nil, ErrNoKeyboxRecipient
	}
	return pub, nil
}

// Check implements secure.RollbackGuard over relay_seen.
func (k *Keyring) Check(wireName string, sender secure.ID, epoch uint32, seq uint64) (secure.Verdict, error) {
	storedEpoch, storedSeq, ok, err := k.st.RelaySeen(wireName, sender.String())
	if err != nil {
		return secure.Older, err
	}
	if !ok {
		return secure.Newer, nil
	}
	return secure.CompareVersion(storedEpoch, storedSeq, epoch, seq), nil
}

// Record implements secure.RollbackGuard: the mark in its own transaction,
// never lowered. The relay processor writes it with state.RecordSeen inside
// its decision's transaction instead.
func (k *Keyring) Record(wireName string, sender secure.ID, epoch uint32, seq uint64) error {
	return k.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.RecordSeen(tx, wireName, sender.String(), epoch, seq)
	})
}

// Rotate begins the next epoch: fresh K_data/K_alert sealed here, the
// current epoch retired, the new one inserted (first_seq = the seq ceiling
// now) and the slice hashes wiped, in one transaction. The previous epoch
// stays readable for PreviousEpochGrace.
func (k *Keyring) Rotate(r Reason) error { return k.RotateWith(r, nil) }

// RotateWith is Rotate with also run in the same transaction first: an
// unlink removes the device there, so the device never leaves without the
// rotation or the other way round. An error from also writes nothing.
func (k *Keyring) RotateWith(r Reason, also func(*sql.Tx) error) error {
	switch r {
	case ReasonAge, ReasonCap, ReasonUnlink, ReasonManual:
	default:
		return fmt.Errorf("identity: unknown rotation reason %q", r)
	}
	var next uint32
	err := k.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if also != nil {
			if err := also(tx); err != nil {
				return err
			}
		}
		epochs, err := state.EpochsTx(tx)
		if err != nil {
			return err
		}
		if len(epochs) == 0 {
			return ErrKeysUnavailable
		}
		current := epochs[len(epochs)-1].Epoch
		if current == ^uint32(0) {
			return ErrEpochOverflow
		}
		next = current + 1
		at := k.now()
		if err := state.RetireEpoch(tx, current, at); err != nil {
			return err
		}
		if err := k.insertEpoch(tx, next, at); err != nil {
			return err
		}
		return state.WipeSliceHashes(tx)
	})
	if err != nil {
		return err
	}
	log.Printf("hub: epoch %d begun (%s)", next, r)
	return nil
}

// rotationDue: the current epoch is RotationAge old (ReasonAge) or has used
// RotationSeqCap seqs (ReasonCap). Read from the committed state, so a hub
// restarted after a rotation never rotates twice.
func (k *Keyring) rotationDue() (Reason, bool, error) {
	current, _, err := k.window()
	if err != nil {
		return "", false, err
	}
	if k.now().Sub(current.CreatedAt) >= RotationAge {
		return ReasonAge, true, nil
	}
	ceiling, err := k.seqCeiling()
	if err != nil {
		return "", false, err
	}
	if ceiling >= current.FirstSeq && ceiling-current.FirstSeq >= RotationSeqCap {
		return ReasonCap, true, nil
	}
	return "", false, nil
}

// RotateIfDue rotates when the epoch is 90 days old or used 2^28 seqs; true
// when it did.
func (k *Keyring) RotateIfDue() (bool, error) {
	r, due, err := k.rotationDue()
	if err != nil || !due {
		return false, err
	}
	if err := k.Rotate(r); err != nil {
		return false, err
	}
	return true, nil
}

// SealLocal seals a sidecar content value under the wrap key:
// ChaChaPoly(wrap, plain, AAD "wt/hub-local/v1" ‖ hub_id ‖ label) in the
// combined layout (nonce 12 ‖ ct ‖ tag 16). label names the column (e.g.
// "session_milestones.text"), so a value moved to another column does not
// open.
func (k *Keyring) SealLocal(label string, plain []byte) ([]byte, error) {
	if label == "" {
		return nil, errors.New("identity: SealLocal needs a label")
	}
	return k.seal(plain, k.localAAD(label))
}

// OpenLocal opens a SealLocal value under the same label;
// ErrSealedKeyUnreadable when it does not open.
func (k *Keyring) OpenLocal(label string, sealed []byte) ([]byte, error) {
	if label == "" {
		return nil, errors.New("identity: OpenLocal needs a label")
	}
	plain, err := k.open(sealed, k.localAAD(label))
	if err != nil {
		return nil, fmt.Errorf("%w: %s", ErrSealedKeyUnreadable, label)
	}
	return plain, nil
}

func (k *Keyring) metaAAD() []byte {
	return append([]byte(metaAADLabel), k.hub[:]...)
}

func (k *Keyring) epochAAD(epoch uint32) []byte {
	aad := append([]byte(epochAADLabel), k.hub[:]...)
	return binary.BigEndian.AppendUint32(aad, epoch)
}

func (k *Keyring) localAAD(label string) []byte {
	aad := append([]byte(localAADLabel), k.hub[:]...)
	return append(aad, label...)
}

// seal is CryptoKit ChaChaPoly.seal(…).combined under the wrap key.
func (k *Keyring) seal(plain, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(k.id.Wrap[:])
	if err != nil {
		return nil, fmt.Errorf("identity: wrap key: %w", err)
	}
	out := make([]byte, chacha20poly1305.NonceSize, chacha20poly1305.NonceSize+len(plain)+aead.Overhead())
	if _, err := rand.Read(out); err != nil {
		return nil, fmt.Errorf("identity: nonce: %w", err)
	}
	return aead.Seal(out, out[:chacha20poly1305.NonceSize], plain, aad), nil
}

// open is ChaChaPoly.open(SealedBox(combined:)) under the wrap key.
func (k *Keyring) open(sealed, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(k.id.Wrap[:])
	if err != nil {
		return nil, fmt.Errorf("identity: wrap key: %w", err)
	}
	if len(sealed) < chacha20poly1305.NonceSize+aead.Overhead() {
		return nil, ErrSealedKeyUnreadable
	}
	n := chacha20poly1305.NonceSize
	plain, err := aead.Open(nil, sealed[:n], sealed[n:], aad)
	if err != nil {
		return nil, ErrSealedKeyUnreadable
	}
	return plain, nil
}

func randomKey(n int) []byte {
	b := make([]byte, n)
	// crypto/rand.Read never fails on supported platforms (Go 1.24+: it
	// crashes the program instead of returning an error).
	_, _ = rand.Read(b)
	return b
}
