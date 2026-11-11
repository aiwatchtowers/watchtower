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
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// PreviousEpochGrace is how long, at most, a retired epoch's relay envelopes
// are accepted and keyboxes carry the newest retired epoch's keys after it was
// retired — for every rotation, transport-switch epochs included (Go hub
// plan 3 Task 20, ask #843; relay sim rule 14's 14 days is not used).
// RetireIfDone ends it sooner. An epoch that began on the relay is erased once
// it ends (EraseExpired). A var only so the relaystaging build
// (rotation_staging.go) can shorten it; nothing else writes it.
var PreviousEpochGrace = 7 * 24 * time.Hour

// relayRotationAge: on the relay the epoch rotates when it is this old
// (relay client Phase 5, ask #1077). Only the relaystaging build changes it.
var relayRotationAge = 7 * 24 * time.Hour

// Rotation constants (spec §2.2, D10), the Swift HubKeyring's values.
const (
	// RotationAge: off the relay the epoch rotates when it is this old.
	RotationAge = 90 * 24 * time.Hour
	// ServingNobodyHold: how long after relay_serving_nobody_since the hub
	// keeps its relay keys (the relay mailbox's TTL); then it rotates once and
	// clears every offer and relay-key row (asks #1077, #1081).
	ServingNobodyHold = 14 * 24 * time.Hour
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
	// ReasonTransportSwitch: every accepted transport switch begins an
	// epoch (relay sim rule 11, internal/hub/switcher).
	ReasonTransportSwitch Reason = "transport_switch"
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
	metaAADLabel       = "wt/hub-meta/v1"
	epochAADLabel      = "wt/hub-epoch/v1"
	localAADLabel      = "wt/hub-local/v1"
	epochRelayAADLabel = "wt/hub-epoch-relay/v1"
)

// The erasure's two sidecar calls, seams only so a test can count them.
var (
	secureDeleteTx  = (*state.Store).WithSecureDeleteTx
	checkpointStore = (*state.Store).Checkpoint
)

// sealRelayFault, when set (tests only), fails the rotation's seal of a
// phone's relay keys.
var sealRelayFault func(device secure.ID) error

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

	// hubText is hub_id as stored (HubIDText).
	hubText string

	// mu guards relay, unusable and checkpointOwed; relay material is only read
	// under it.
	mu       sync.Mutex
	relay    map[secure.ID]*relayMaterial
	unusable map[secure.ID]string // last unusable row logged per device

	// relayRule, when set, says whether the hub runs on the relay, in the
	// caller's transaction (SetRelayRule); held, when set, whether the hub
	// is held (SetHeld). Both are set once, before the hub runs.
	relayRule func(*sql.Tx) (bool, error)
	held      func() bool

	// checkpointOwed (under mu): an erasure's checkpoint has not completed.
	checkpointOwed bool
}

// relayMaterial is one phone's relay inputs, checked once, and the keys
// derived from them so far ("p2h/1" → key) with, per slot, the sealed
// epoch_relay_keys row it came from (nil: the static wt/relay/v1/ key), so a
// row cleared or replaced since is never answered from the cache.
type relayMaterial struct {
	agreementKey []byte
	linkNonce    string
	peer         *ecdh.PublicKey
	nonce        []byte
	keys         map[string][]byte
	from         map[string][]byte
}

// wipe zeroes the derived keys and the nonce and drops them, so a stale
// reference finds nothing rather than zero bytes.
func (m *relayMaterial) wipe() {
	for _, k := range m.keys {
		clear(k)
	}
	clear(m.nonce)
	m.keys, m.from, m.nonce, m.peer = nil, nil, nil, nil
	m.agreementKey, m.linkNonce = nil, ""
}

// SetRelayRule sets how the keyring tells that the hub runs on the relay, read
// in the rotation's own transaction (the cadence, the on_relay mark, the
// derivation): a hub without a switcher (headless) passes its transport's
// kind, so a stale hub_meta.transport is ignored (the processor's rule,
// actions.onRelayTx). Unset (a desktop hub, an offline unlink), the current
// epoch's on_relay decides, hub_meta.transport only for an epoch from before
// it existed (OnRelayTx). Called once, before the hub runs.
func (k *Keyring) SetRelayRule(rule func(*sql.Tx) (bool, error)) { k.relayRule = rule }

// SetHeld sets the hub's held state (paused or unvouched on the relay): while
// it is held on the relay no age rotation runs, as nothing could be
// published. Called once, before the hub runs.
func (k *Keyring) SetHeld(held func() bool) { k.held = held }

// OnRelayTx is the relay rule in tx. Unset (SetRelayRule), the current
// epoch's on_relay decides: every transport change begins an epoch toward its
// target, so after a switch's rotation the current epoch already says where
// the hub runs, while hub_meta.transport changes only at its announce (an
// unlink in between must not mark an iCloud epoch as a relay one, ask #1066).
// hub_meta.transport decides only for a current epoch with no on_relay: one
// from before sidecar migration 00016 that no hub start has stamped yet
// (StampCurrentEpoch).
func (k *Keyring) OnRelayTx(tx *sql.Tx) (bool, error) {
	if k.relayRule != nil {
		return k.relayRule(tx)
	}
	epochs, err := state.EpochsTx(tx)
	if err != nil {
		return false, err
	}
	if n := len(epochs); n > 0 && epochs[n-1].OnRelay != nil {
		return *epochs[n-1].OnRelay, nil
	}
	v, ok, err := state.MetaTx(tx, state.MetaTransport)
	if err != nil {
		return false, err
	}
	return ok && v == transportRelay, nil
}

// transportRelay is hub_meta.transport's value for the relay (transport.KindRelay).
const transportRelay = "relay"

// OnRelay reports whether the hub runs on the relay, by the relay rule
// (SetRelayRule).
func (k *Keyring) OnRelay() (bool, error) {
	var on bool
	err := k.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		on, err = k.OnRelayTx(tx)
		return err
	})
	return on, err
}

// StampCurrentEpoch gives the current epoch an on_relay value when it has
// none, from the relay rule: the hub's start calls it once the rule is set
// (SetRelayRule, or the switcher's stored transport), so epoch 1 of a new
// sidecar, inserted before the hub knows its transport, begins on the relay
// or on iCloud like any later epoch (erased at its retention end on the
// relay), and a later rule-less keyring (an offline unlink) reads it. Retired
// epochs with no on_relay (from before sidecar migration 00016) stay as they
// are and are never erased (ask #1066).
func (k *Keyring) StampCurrentEpoch() error {
	return k.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		epochs, err := state.EpochsTx(tx)
		if err != nil {
			return err
		}
		n := len(epochs)
		if n == 0 || epochs[n-1].OnRelay != nil {
			return nil
		}
		on, err := k.OnRelayTx(tx)
		if err != nil {
			return err
		}
		return state.StampEpochOnRelay(tx, epochs[n-1].Epoch, on)
	})
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
	k := &Keyring{id: id, st: st, now: now, relay: map[secure.ID]*relayMaterial{}, unusable: map[secure.ID]string{}}
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
			hubText = k.hub.String()
			if err := state.SetMetaTx(tx, state.MetaHubID, hubText); err != nil {
				return err
			}
		} else if k.hub, err = secure.ParseID(hubText); err != nil {
			return errors.New("identity: hub_id is not a UUID")
		}
		k.hubText = hubText
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
			return k.insertEpoch(tx, 1, k.now(), "", nil)
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
// first_seq = the seq ceiling now and why it began ("" for epoch 1), in tx.
func (k *Keyring) insertEpoch(tx *sql.Tx, epoch uint32, at time.Time, r Reason, onRelay *bool) error {
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
	return state.InsertEpoch(tx, state.Epoch{Epoch: epoch, SealedKeys: sealed, CreatedAt: at, FirstSeq: first, Reason: string(r), OnRelay: onRelay})
}

// HubID is the hub's id.
func (k *Keyring) HubID() secure.ID { return k.hub }

// HubIDText is hub_id spelled as stored: the text the CloudKit zone names
// (DataZone-/RelayZone-<hub_id>), the link codes, the grants, the heartbeat
// and the controls carry. A hub this runtime created stores HubID().String()
// (uppercase); a hub adopted from the Swift hub keeps that hub's lowercase
// spelling, which its CloudKit zones and its phones' stored links use, and
// the phones compare hub ids as text (#1746). Never re-spell it.
func (k *Keyring) HubIDText() string { return k.hubText }

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
	if len(e.SealedKeys) == 0 {
		return nil, fmt.Errorf("%w: epoch %d was erased", ErrUnknownEpoch, e.Epoch)
	}
	plain, err := k.open(e.SealedKeys, k.epochAAD(e.Epoch))
	if err != nil || len(plain) != 64 {
		clear(plain)
		return nil, fmt.Errorf("%w: epoch %d", ErrSealedKeyUnreadable, e.Epoch)
	}
	return plain, nil
}

// retainedEpochs is the current epoch last, after every retired epoch whose
// relay-lane keys are still accepted (oldest first).
func (k *Keyring) retainedEpochs() ([]state.Epoch, error) {
	epochs, err := k.st.Epochs()
	if err != nil {
		return nil, err
	}
	if len(epochs) == 0 {
		return nil, ErrKeysUnavailable
	}
	now := k.now()
	out := make([]state.Epoch, 0, len(epochs))
	for i, e := range epochs[:len(epochs)-1] {
		if now.Before(retireAfter(e, epochs[i+1])) {
			out = append(out, e)
		}
	}
	return append(out, epochs[len(epochs)-1]), nil
}

// retireAfter is when retired epoch e's keys stop being accepted: its
// retire_after, or — on a row retired before sidecar migration 00010 —
// PreviousEpochGrace after it was retired (the next epoch's start when even
// retired_at is missing).
func retireAfter(e, next state.Epoch) time.Time {
	if e.RetireAfter != nil {
		return *e.RetireAfter
	}
	at := next.CreatedAt
	if e.RetiredAt != nil {
		at = *e.RetiredAt
	}
	return at.Add(PreviousEpochGrace)
}

// window is the current epoch and the newest retired one still retained
// (nil when none is).
func (k *Keyring) window() (current state.Epoch, previous *state.Epoch, err error) {
	kept, err := k.retainedEpochs()
	if err != nil {
		return state.Epoch{}, nil, err
	}
	current = kept[len(kept)-1]
	if len(kept) >= 2 {
		previous = &kept[len(kept)-2]
	}
	return current, previous, nil
}

// Retained is every epoch whose relay-lane keys are still accepted, oldest
// first, the current one last: each retired epoch for PreviousEpochGrace
// after its retirement unless RetireIfDone ended it sooner.
func (k *Keyring) Retained() ([]uint32, error) {
	kept, err := k.retainedEpochs()
	if err != nil {
		return nil, err
	}
	out := make([]uint32, len(kept))
	for i, e := range kept {
		out[i] = e.Epoch
	}
	return out, nil
}

// RetireIfDone is relay sim rule 14 with the 7-day cap: a retired epoch
// still retained ends now when every linked phone acked a newer epoch
// (acked: device id → its acked epoch) and nothing sealed in it is held or
// queued: heldIn (the caller's view) and, in the retiring transaction,
// state.SealedIn over held_actions and control_queue. The current epoch is
// never retired here; a retention is only ever shortened.
func (k *Keyring) RetireIfDone(acked map[string]uint32, heldIn map[uint32]bool) error {
	kept, err := k.retainedEpochs()
	if err != nil {
		return err
	}
	var candidates []uint32
	for _, e := range kept[:len(kept)-1] {
		if heldIn[e.Epoch] {
			continue
		}
		all := true
		for _, a := range acked {
			if a <= e.Epoch {
				all = false
				break
			}
		}
		if all {
			candidates = append(candidates, e.Epoch)
		}
	}
	if len(candidates) == 0 {
		return nil
	}
	now := k.now()
	var done []uint32
	err = k.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		done = done[:0]
		for _, e := range candidates {
			// Checked with the write: a held action or a queued write
			// (an owed echo, a control) sealed in e keeps its keys.
			used, err := state.SealedIn(tx, e)
			if err != nil {
				return err
			}
			if used {
				continue
			}
			if err := state.EndRetention(tx, e, now); err != nil {
				return err
			}
			done = append(done, e)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, e := range done {
		log.Printf("hub: epoch %d retired: every phone acked a newer one", e)
	}
	return nil
}

// RetireOld is RetireIfDone over the sidecar: every linked phone's acked
// epoch (devices.acked_epoch, a phone that never acked counts as 0); the
// held actions and queued writes are checked inside the retiring
// transaction (state.SealedIn). The runtime's housekeeping is its one
// caller.
func (k *Keyring) RetireOld() error {
	devices, err := k.st.Devices()
	if err != nil {
		return err
	}
	acked := make(map[string]uint32, len(devices))
	for _, d := range devices {
		acked[d.ID] = d.AckedEpoch
	}
	return k.RetireIfDone(acked, nil)
}

// KeyboxKeysFor are the keys device's keybox carries (spec §2.3): the
// current epoch's K_data and K_alert and K_meta, plus the newest retired
// epoch's while it is retained (the keybox has room for one). Strings are
// unpadded base64url. relay_kx names the pair of the epoch's wt/relay/v2/
// relay keys for this phone and previous_relay_kx the previous epoch's
// (relay client Phase 5); none means that epoch is static for it. A keybox
// sealed to dev_kx (the phone holds no offer) omits the previous epoch
// altogether when that epoch has relay keys for the phone: the phone has
// moved on from its ephemeral state (a switch to iCloud cleared its offer),
// and the keybox, the one truth for an epoch's keys, never names a pair it
// cannot open.
func (k *Keyring) KeyboxKeysFor(device secure.ID) (wire.KeyboxKeys, error) {
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
	row, linked, err := k.st.Device(device.String())
	if err != nil {
		return wire.KeyboxKeys{}, err
	}
	b64 := base64.RawURLEncoding.EncodeToString
	out := wire.KeyboxKeys{Epoch: current.Epoch, DataKey: b64(keys[:32]), AlertKey: b64(keys[32:]), MetaKey: b64(meta)}
	if out.RelayKX, err = k.relayKX(current.Epoch, device); err != nil {
		return wire.KeyboxKeys{}, err
	}
	if previous == nil {
		return out, nil
	}
	prevKX, err := k.relayKX(previous.Epoch, device)
	if err != nil {
		return wire.KeyboxKeys{}, err
	}
	if prevKX != nil && (!linked || row.KXOffer == nil) {
		return out, nil
	}
	prev, err := k.openEpoch(*previous)
	if err != nil {
		return wire.KeyboxKeys{}, err
	}
	defer clear(prev)
	epoch, data, alert := previous.Epoch, b64(prev[:32]), b64(prev[32:])
	out.PreviousEpoch, out.PreviousDataKey, out.PreviousAlertKey = &epoch, &data, &alert
	out.PreviousRelayKX = prevKX
	return out, nil
}

// relayKX is the keybox's name for device's relay-key pair of epoch, nil when
// it has none (static).
func (k *Keyring) relayKX(epoch uint32, device secure.ID) (*wire.KeyboxRelayKX, error) {
	row, ok, err := k.st.EpochRelayKeys(epoch, device.String())
	if err != nil || !ok {
		return nil, err
	}
	b64 := base64.RawURLEncoding.EncodeToString
	return &wire.KeyboxRelayKX{HubPub: b64(row.HubPub), DevicePub: b64(row.DevicePub)}, nil
}

// AckedEpochRetained is the epoch dev acked while the hub still retains it and
// it is older than the current one, else 0 (the current epoch): an epoch
// whose keys the phone is known to hold.
func (k *Keyring) AckedEpochRetained(dev state.Device) (uint32, error) {
	if dev.AckedEpoch == 0 {
		return 0, nil
	}
	kept, err := k.retainedEpochs()
	if err != nil {
		return 0, err
	}
	for _, e := range kept[:len(kept)-1] {
		if e.Epoch == dev.AckedEpoch {
			return e.Epoch, nil
		}
	}
	return 0, nil
}

// PhoneEpoch is the epoch the hub seals a phone's echoes and controls in: for
// a phone that offered a relay key, its acked epoch while retained (a keybox
// for a newer one may not have reached it, and its keys for that one cannot be
// derived without it); else 0, the current epoch, today's sealing.
//
// Only while the current epoch holds relay keys for the phone: with none, the
// current epoch is static for it and it can open it. That keeps an ack read
// after the rotation (the keybox reached the phone first, and an echo was
// sealed in the current epoch) from moving a later overwrite of that echo back
// to the acked epoch, which the phone's rollback guard (epoch first) would
// drop as older.
func (k *Keyring) PhoneEpoch(dev state.Device) (uint32, error) {
	if dev.KXOffer == nil {
		return 0, nil
	}
	current, err := k.CurrentEpoch()
	if err != nil {
		return 0, err
	}
	if _, ok, err := k.st.EpochRelayKeys(current, dev.ID); err != nil || !ok {
		return 0, err
	}
	return k.AckedEpochRetained(dev)
}

// AcceptsRelayEpoch accepts the current epoch and every retained one
// (Retained: each retired epoch at most PreviousEpochGrace after it was
// retired, D10 and ask #843). false for a device without usable relay
// material.
func (k *Keyring) AcceptsRelayEpoch(epoch uint32, device secure.ID) (bool, error) {
	usable, err := k.hasMaterial(device)
	if err != nil || !usable {
		return false, err
	}
	kept, err := k.retainedEpochs()
	if errors.Is(err, ErrKeysUnavailable) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, e := range kept {
		if e.Epoch == epoch {
			return true, nil
		}
	}
	return false, nil
}

// RelayKey is the pairwise relay key for one phone, epoch and direction: the
// epoch's sealed wt/relay/v2/ key of the phone when the rotation derived one
// (epoch_relay_keys), else the static wt/relay/v1/ key. The caller owns the
// returned slice; the cache keeps its own copy, tagged with the row it came
// from, so a row cleared (a lapse, a lost reader) or erased since is never
// answered from it. The material is checked against the row, the key derived
// or read from the cache and copied out under one hold of k.mu, so a
// concurrent re-link or removal (which wipes the old material) can never hand
// out wiped bytes.
func (k *Keyring) RelayKey(dir secure.Direction, device secure.ID, epoch uint32) ([]byte, error) {
	row, ok, err := k.st.Device(device.String())
	if err != nil {
		return nil, err
	}
	eph, hasEph, err := k.st.EpochRelayKeys(epoch, device.String())
	if err != nil {
		return nil, err
	}
	slot := string(dir) + "/" + strconv.FormatUint(uint64(epoch), 10)
	k.mu.Lock()
	defer k.mu.Unlock()
	m := k.materialLocked(device, row, ok)
	if m == nil {
		return nil, ErrUnknownDevice
	}
	var from []byte
	if hasEph {
		from = eph.SealedKeys
	}
	key, cached := m.keys[slot]
	if cached && (hasEph != (m.from[slot] != nil) || !bytes.Equal(m.from[slot], from)) {
		clear(key)
		delete(m.keys, slot)
		delete(m.from, slot)
		cached = false
	}
	if !cached {
		if hasEph {
			key, err = k.openRelayKeys(eph, device, dir)
		} else {
			key, err = secure.RelayKey(k.id.Agreement, m.peer, m.nonce, k.hub, device, epoch, dir)
		}
		if err != nil {
			return nil, fmt.Errorf("identity: deriving a relay key: %w", err)
		}
	}
	// Last line of defence: never hand out (or keep) a zeroed key.
	if len(key) != 32 || allZero(key) {
		return nil, ErrUnknownDevice
	}
	m.keys[slot] = key
	m.from[slot] = bytes.Clone(from)
	return bytes.Clone(key), nil
}

// openRelayKeys opens a relay-key row's sealed p2h ‖ h2p and returns dir's.
func (k *Keyring) openRelayKeys(row state.EpochRelayKeys, device secure.ID, dir secure.Direction) ([]byte, error) {
	plain, err := k.open(row.SealedKeys, k.epochRelayAAD(row.Epoch, device))
	if err != nil || len(plain) != 64 {
		clear(plain)
		return nil, fmt.Errorf("%w: relay keys of epoch %d", ErrSealedKeyUnreadable, row.Epoch)
	}
	defer clear(plain)
	if dir == secure.HubToPhone {
		return bytes.Clone(plain[32:]), nil
	}
	return bytes.Clone(plain[:32]), nil
}

func allZero(b []byte) bool {
	var acc byte
	for _, c := range b {
		acc |= c
	}
	return acc == 0
}

// RelayDevices is every linked phone with usable relay material (the Swift
// relayDeviceIDs): the senders the Opener accepts and the keys it tries for
// the hub's own echoes. The cache keeps exactly these.
func (k *Keyring) RelayDevices() ([]secure.ID, error) {
	rows, err := k.st.Devices()
	if err != nil {
		return nil, err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	var out []secure.ID
	keep := map[secure.ID]bool{}
	for _, row := range rows {
		id, err := secure.ParseID(row.ID)
		if err != nil {
			log.Printf("hub: a linked device id is not a UUID")
			continue
		}
		if k.materialLocked(id, row, true) != nil {
			out = append(out, id)
			keep[id] = true
		}
	}
	for id := range k.relay {
		if !keep[id] {
			k.dropLocked(id)
		}
	}
	return out, nil
}

// hasMaterial re-reads the device row and reports whether it has usable
// relay material.
func (k *Keyring) hasMaterial(device secure.ID) (bool, error) {
	row, ok, err := k.st.Device(device.String())
	if err != nil {
		return false, err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.materialLocked(device, row, ok) != nil, nil
}

// materialLocked returns the device's cached material for its current row
// (ok false = not linked): kept when the row's agreement_key and link_nonce
// are unchanged, rebuilt otherwise, nil (and the old entry dropped) when the
// device is not linked or its row is unusable (a key that does not parse or
// agree, a nonce that is not base64url). The caller holds k.mu, and the
// result is used only while it still does.
func (k *Keyring) materialLocked(device secure.ID, row state.Device, ok bool) *relayMaterial {
	cached := k.relay[device]
	if ok && cached != nil && bytes.Equal(cached.agreementKey, row.AgreementKey) && cached.linkNonce == row.LinkNonce {
		return cached
	}
	k.dropLocked(device)
	if !ok || len(row.AgreementKey) == 0 || row.LinkNonce == "" {
		delete(k.unusable, device)
		return nil
	}
	m := k.makeMaterial(row)
	if m == nil {
		// Logged once per row change, not on every lookup.
		mark := string(row.AgreementKey) + "\x00" + row.LinkNonce
		if k.unusable[device] != mark {
			k.unusable[device] = mark
			log.Printf("hub: relay material of device %s is unusable", device)
		}
		return nil
	}
	delete(k.unusable, device)
	k.relay[device] = m
	return m
}

// Wipe zeroes and forgets every cached relay material (agreement keys,
// link nonces, derived pairwise keys). The hub calls it when it stops,
// beside zeroing the Identity; a keyring used again re-derives from the
// device rows while its Identity is still intact.
func (k *Keyring) Wipe() {
	k.mu.Lock()
	defer k.mu.Unlock()
	for id := range k.relay {
		k.dropLocked(id)
	}
	clear(k.unusable)
}

// dropLocked wipes and forgets the device's cached material; the caller
// holds k.mu.
func (k *Keyring) dropLocked(device secure.ID) {
	if m := k.relay[device]; m != nil {
		m.wipe()
		delete(k.relay, device)
	}
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
		peer: peer, nonce: nonce, keys: map[string][]byte{}, from: map[string][]byte{},
	}
}

// KeyboxRecipient is the key a keybox for device is sealed to: a linked
// phone's relay key offer when it holds one (relay client Phase 5), else the
// agreement key of a linked, pending, revoked or refused device (F5).
// ErrNoKeyboxRecipient when none is stored or it does not parse.
func (k *Keyring) KeyboxRecipient(device secure.ID) (*ecdh.PublicKey, error) {
	if row, linked, err := k.st.Device(device.String()); err != nil {
		return nil, err
	} else if linked && row.KXOffer != nil {
		if pub, err := ecdh.X25519().NewPublicKey(row.KXOffer); err == nil {
			return pub, nil
		}
		log.Printf("hub: stored relay key offer of device %s does not parse", device)
	}
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
// now), the slice hashes wiped and the work alerts moved to the bumped sync
// generation (state.MoveWorkAlertsForRotation), in one transaction. The
// retired epoch stays readable for PreviousEpochGrace at most (Retained).
// Toward the relay or iCloud as the relay rule says (RotateWith).
func (k *Keyring) Rotate(r Reason) error { return k.RotateWith(r, nil) }

// ErrSkipRotation is returned by RotateWith's also to end the rotation with
// nothing written and RotateWith returns nil: Unlink returns it when the
// device is not linked (the Swift hub's removeDeviceAndRotate returns nil and
// writes nothing then).
var ErrSkipRotation = errors.New("identity: rotation skipped")

// RotateWith is Rotate with also run in the same transaction first: an
// unlink removes the device there (and writes its revoked row), so the
// device never leaves without the rotation or the other way round. also
// must only write through tx and stay short (it holds the write lock).
// ErrSkipRotation from also writes nothing and returns nil; any other error
// writes nothing and is returned. The new epoch is on the relay when the
// relay rule (SetRelayRule) says the hub runs there, read in the same
// transaction (RotateToward).
func (k *Keyring) RotateWith(r Reason, also func(*sql.Tx) error) error {
	return k.rotate(r, nil, also)
}

// RotateToward is RotateWith toward a known transport (a switch passes its
// target): the epoch is inserted with on_relay = onRelay. Toward the relay,
// every linked phone holding a relay key offer gets this epoch's wt/relay/v2/
// keys, from a fresh hub_eph each, sealed under the wrap key; the private
// halves are never stored. Toward iCloud no key is derived, every offer is
// dropped and relay_serving_nobody_since goes. One transaction: a failure
// anywhere writes nothing.
func (k *Keyring) RotateToward(r Reason, onRelay bool, also func(*sql.Tx) error) error {
	return k.rotate(r, &onRelay, also)
}

func (k *Keyring) rotate(r Reason, toward *bool, also func(*sql.Tx) error) error {
	if !validReason(r) {
		return fmt.Errorf("identity: unknown rotation reason %q", r)
	}
	var b begun
	err := k.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if also != nil {
			if err := also(tx); err != nil {
				return err
			}
		}
		var onRelay bool
		if toward != nil {
			onRelay = *toward
		} else {
			var err error
			if onRelay, err = k.OnRelayTx(tx); err != nil {
				return err
			}
		}
		var err error
		b, err = k.rotateTx(tx, r, onRelay, false)
		return err
	})
	return b.done(r, err)
}

func validReason(r Reason) bool {
	switch r {
	case ReasonAge, ReasonCap, ReasonUnlink, ReasonManual, ReasonTransportSwitch:
		return true
	}
	return false
}

// begun is what one rotation did, for its log line.
type begun struct {
	epoch          uint32
	holdEnd        bool
	ephemeral, all int
}

// done logs a committed rotation (numbers only) and maps ErrSkipRotation to
// nil.
func (b begun) done(r Reason, err error) error {
	if errors.Is(err, ErrSkipRotation) {
		return nil
	}
	if err != nil {
		return err
	}
	why := string(r)
	if b.holdEnd {
		why += ", the relay hold's end"
	}
	log.Printf("hub: epoch %d begun (%s): %d ephemeral, %d static", b.epoch, why, b.ephemeral, b.all-b.ephemeral)
	return nil
}

// rotateTx is the rotation in tx: the current epoch retired, the next one
// inserted on or off the relay, the slice hashes wiped, the work alerts moved,
// and the relay keys: toward iCloud every offer dropped (and the serving-nobody
// mark), at the hold's end every offer and relay-key row dropped and none
// derived, else each offering phone's keys derived for the new epoch.
func (k *Keyring) rotateTx(tx *sql.Tx, r Reason, onRelay, holdEnd bool) (begun, error) {
	epochs, err := state.EpochsTx(tx)
	if err != nil {
		return begun{}, err
	}
	if len(epochs) == 0 {
		return begun{}, ErrKeysUnavailable
	}
	current := epochs[len(epochs)-1].Epoch
	if current == ^uint32(0) {
		return begun{}, ErrEpochOverflow
	}
	b := begun{epoch: current + 1, holdEnd: holdEnd}
	at := k.now()
	if err := state.RetireEpoch(tx, current, at, at.Add(PreviousEpochGrace)); err != nil {
		return begun{}, err
	}
	if err := k.insertEpoch(tx, b.epoch, at, r, &onRelay); err != nil {
		return begun{}, err
	}
	if err := state.WipeSliceHashes(tx); err != nil {
		return begun{}, err
	}
	if err := state.MoveWorkAlertsForRotation(tx); err != nil {
		return begun{}, err
	}
	devices, err := state.DevicesTx(tx)
	if err != nil {
		return begun{}, err
	}
	b.all = len(devices)
	switch {
	case !onRelay:
		if err := state.ClearKXOffers(tx); err != nil {
			return begun{}, err
		}
		return b, state.DeleteMetaTx(tx, state.MetaServingNobodySince)
	case holdEnd:
		return b, state.ClearAllRelayKeys(tx)
	}
	for _, d := range devices {
		if d.KXOffer == nil {
			continue
		}
		ok, err := k.deriveRelayKeys(tx, d, b.epoch)
		if err != nil {
			return begun{}, err
		}
		if ok {
			b.ephemeral++
		}
	}
	return b, nil
}

// deriveRelayKeys draws a hub_eph for d's offer, derives both directions of
// epoch's wt/relay/v2/ keys and stores them sealed with the two publics, in
// tx; false (nothing written, logged) for a row whose static material or
// offer is unusable, which stays static.
func (k *Keyring) deriveRelayKeys(tx *sql.Tx, d state.Device, epoch uint32) (bool, error) {
	device, err := secure.ParseID(d.ID)
	if err != nil {
		log.Printf("hub: a linked device id is not a UUID")
		return false, nil
	}
	m := k.makeMaterial(d)
	if m != nil {
		defer m.wipe()
	}
	devEph, perr := ecdh.X25519().NewPublicKey(d.KXOffer)
	if m == nil || perr != nil {
		log.Printf("hub: relay material of device %s is unusable: its epoch %d stays static", device, epoch)
		return false, nil
	}
	seed := randomKey(32)
	hubEph, err := ecdh.X25519().NewPrivateKey(seed)
	clear(seed)
	if err != nil {
		return false, fmt.Errorf("identity: drawing a hub_eph: %w", err)
	}
	pair, err := k.ephemeralPair(hubEph, devEph, m.peer, m.nonce, device, epoch)
	if err != nil {
		return false, err
	}
	defer clear(pair)
	if sealRelayFault != nil {
		if err := sealRelayFault(device); err != nil {
			return false, err
		}
	}
	sealed, err := k.seal(pair, k.epochRelayAAD(epoch, device))
	if err != nil {
		return false, err
	}
	return true, state.InsertEpochRelayKeys(tx, state.EpochRelayKeys{
		Epoch: epoch, DeviceID: d.ID, HubPub: hubEph.PublicKey().Bytes(), DevicePub: devEph.Bytes(), SealedKeys: sealed,
	})
}

// ephemeralPair is p2h ‖ h2p of the wt/relay/v2/ keys between hubEph and
// devEph (64 bytes; the caller clears it). The transcript publics are taken
// from those two keys themselves, never passed separately, so they always
// name the keys the exchange used (secure.EphemeralRelayKey does not check
// that).
func (k *Keyring) ephemeralPair(hubEph *ecdh.PrivateKey, devEph, devKX *ecdh.PublicKey, nonce []byte, device secure.ID, epoch uint32) ([]byte, error) {
	hubPub, devPub := hubEph.PublicKey().Bytes(), devEph.Bytes()
	out := make([]byte, 0, 64)
	for _, dir := range []secure.Direction{secure.PhoneToHub, secure.HubToPhone} {
		key, err := secure.EphemeralRelayKey(hubEph, devEph, k.id.Agreement, devKX, hubPub, devPub, nonce, k.hub, device, epoch, dir)
		if err != nil {
			clear(out)
			return nil, fmt.Errorf("identity: deriving relay keys: %w", err)
		}
		out = append(out, key...)
		clear(key)
	}
	return out, nil
}

// due is what the rotation check found: the reason, whether the hub runs on
// the relay, and whether this is the end of the serving-nobody hold.
type due struct {
	reason  Reason
	onRelay bool
	holdEnd bool
}

// rotationDueTx: off the relay the current epoch is RotationAge old
// (ReasonAge) or has used RotationSeqCap seqs (ReasonCap); on the relay it is
// relayRotationAge old, or used the cap, unless the hub is held or
// relay_serving_nobody_since is set: then nothing is due but the hold's end,
// once ServingNobodyHold has passed since the mark and the current epoch began
// before that (so it rotates once, across a restart too). Read from the
// committed state, so a hub restarted after a rotation never rotates twice.
func (k *Keyring) rotationDueTx(tx *sql.Tx) (due, bool, error) {
	onRelay, err := k.OnRelayTx(tx)
	if err != nil {
		return due{}, false, err
	}
	epochs, err := state.EpochsTx(tx)
	if err != nil {
		return due{}, false, err
	}
	if len(epochs) == 0 {
		return due{}, false, ErrKeysUnavailable
	}
	current, now := epochs[len(epochs)-1], k.now()
	age := RotationAge
	if onRelay {
		since, set, err := servingNobodySince(tx)
		if err != nil {
			return due{}, false, err
		}
		if set {
			end := since.Add(ServingNobodyHold)
			if !now.Before(end) && current.CreatedAt.Before(end) {
				return due{reason: ReasonAge, onRelay: true, holdEnd: true}, true, nil
			}
			return due{}, false, nil
		}
		if k.held != nil && k.held() {
			return due{}, false, nil
		}
		age = relayRotationAge
	}
	if now.Sub(current.CreatedAt) >= age {
		return due{reason: ReasonAge, onRelay: onRelay}, true, nil
	}
	text, _, err := state.MetaTx(tx, state.MetaSeqCeiling)
	if err != nil {
		return due{}, false, err
	}
	ceiling, err := parseCeiling(text)
	if err != nil {
		return due{}, false, err
	}
	if ceiling >= current.FirstSeq && ceiling-current.FirstSeq >= RotationSeqCap {
		return due{reason: ReasonCap, onRelay: onRelay}, true, nil
	}
	return due{}, false, nil
}

// servingNobodySince reads relay_serving_nobody_since (unix seconds).
func servingNobodySince(tx *sql.Tx) (time.Time, bool, error) {
	v, ok, err := state.MetaTx(tx, state.MetaServingNobodySince)
	if err != nil || !ok {
		return time.Time{}, false, err
	}
	secs, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return time.Time{}, false, errors.New("identity: relay_serving_nobody_since is not a number")
	}
	return time.Unix(secs, 0), true, nil
}

// RotateIfDue rotates when a rotation is due (rotationDueTx): every 7 days on
// the relay (relayRotationAge), every 90 days elsewhere, or at the seq cap;
// on the relay not while the hub is held or serves nobody, except the hold's
// end, which derives nothing and clears every offer and relay-key row. The
// check is made again in the rotation's own transaction, after also (the
// runtime's: ErrSkipRotation while a switch runs). true when it rotated.
func (k *Keyring) RotateIfDue(also func(*sql.Tx) error) (bool, error) {
	var (
		first due
		ok    bool
	)
	err := k.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		first, ok, err = k.rotationDueTx(tx)
		return err
	})
	if err != nil || !ok {
		return false, err
	}
	var b begun
	rotated := false
	err = k.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if also != nil {
			if err := also(tx); err != nil {
				return err
			}
		}
		d, ok, err := k.rotationDueTx(tx)
		if err != nil {
			return err
		}
		if !ok {
			return ErrSkipRotation // another writer rotated or changed the state first
		}
		if b, err = k.rotateTx(tx, d.reason, d.onRelay, d.holdEnd); err != nil {
			return err
		}
		first, rotated = d, true
		return nil
	})
	if err := b.done(first.reason, err); err != nil {
		return false, err
	}
	return rotated, nil
}

// EraseExpired erases every epoch that began on the relay (on_relay = 1) and
// whose retention has ended (retire_after passed): its sealed K_data ‖
// K_alert and its relay-key rows, in one transaction on a connection set to
// secure_delete, then a best-effort wal_checkpoint(TRUNCATE) so no copy stays
// in the log. An iCloud epoch, or one with no on_relay (from before sidecar
// migration 00016: the hub's start stamps every later one, StampCurrentEpoch),
// keeps its keys (ask #1066). With nothing to erase it issues neither pragma.
// The relay-key cache drops the erased epochs. It returns how many it erased.
func (k *Keyring) EraseExpired() (int, error) {
	epochs, err := k.st.Epochs()
	if err != nil {
		return 0, err
	}
	now := k.now()
	var expired []uint32
	for i := 0; i+1 < len(epochs); i++ {
		e := epochs[i]
		if e.OnRelay == nil || !*e.OnRelay || len(e.SealedKeys) == 0 || e.RetiredAt == nil {
			continue
		}
		if !now.Before(retireAfter(e, epochs[i+1])) {
			expired = append(expired, e.Epoch)
		}
	}
	if len(expired) == 0 {
		k.checkpointIfOwed()
		return 0, nil
	}
	if err := secureDeleteTx(k.st, context.Background(), func(tx *sql.Tx) error {
		for _, e := range expired {
			if err := state.EraseEpoch(tx, e); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return 0, err
	}
	k.forgetEpochs(expired)
	log.Printf("hub: %d relay epoch(s) erased at the end of their retention", len(expired))
	k.mu.Lock()
	k.checkpointOwed = true
	k.mu.Unlock()
	k.checkpointIfOwed()
	return len(expired), nil
}

// checkpointIfOwed runs the wal_checkpoint(TRUNCATE) an erasure owes, until
// one completes: a reader blocking it (busy) or an error leaves it owed for the
// next housekeeping, so the erased pages do not stay in the log. In memory: a
// restart owes nothing, and the next start's checkpoints copy the log anyway.
func (k *Keyring) checkpointIfOwed() {
	k.mu.Lock()
	owed := k.checkpointOwed
	k.mu.Unlock()
	if !owed {
		return
	}
	if err := checkpointStore(k.st); err != nil {
		log.Printf("hub: the hub state was not checkpointed after an erasure: retried at the next housekeeping")
		return
	}
	k.mu.Lock()
	k.checkpointOwed = false
	k.mu.Unlock()
}

// forgetEpochs drops every cached relay key of the given epochs.
func (k *Keyring) forgetEpochs(epochs []uint32) {
	gone := map[string]bool{}
	for _, e := range epochs {
		gone[strconv.FormatUint(uint64(e), 10)] = true
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	for _, m := range k.relay {
		for slot, key := range m.keys {
			if _, e, _ := strings.Cut(slot, "/"); gone[e] {
				clear(key)
				delete(m.keys, slot)
				delete(m.from, slot)
			}
		}
	}
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

// epochRelayAAD binds a relay-key row's sealed keys to the hub, its epoch and
// its phone: "wt/hub-epoch-relay/v1" ‖ hub_id ‖ epoch u32 BE ‖ device_id.
func (k *Keyring) epochRelayAAD(epoch uint32, device secure.ID) []byte {
	aad := append([]byte(epochRelayAADLabel), k.hub[:]...)
	aad = binary.BigEndian.AppendUint32(aad, epoch)
	return append(aad, device[:]...)
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
