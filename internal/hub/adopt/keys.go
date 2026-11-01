package adopt

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
)

// The key hand-over (spec §12.2, phase 3 Task 16) is two-phase: Desktop
// writes the Swift hub's three keys to `hub adopt --keys-stdin`; HandOver
// stores them as staged, opens the adopted sidecar's sealed keys with the
// staged identity and only then promotes it and records identity = adopted.
// Desktop deletes its own Keychain items only on that answer and then calls
// --confirm-deleted. A kill anywhere before adopted leaves Desktop's items
// in place (it never saw adopted) and the next run starts from the top:
// the staged copy is overwritten, a promoted identity is written again.
// The hub stays off until HubMayStart.

// MetaIdentity values (hub_meta.identity_adoption; none = the key absent).
const (
	IdentityStaged    = "staged"
	IdentityAdopted   = "adopted"
	IdentityConfirmed = "confirmed"
)

// Hand-over error classes (HandOver's and ConfirmDeleted's answer).
const (
	ClassWrongKeys  = "wrong_keys"  // the keys do not open the sidecar's sealed keys
	ClassNoSidecar  = "no_sidecar"  // no adopted Swift sidecar with keys in the hub dir
	ClassBadKeys    = "bad_keys"    // stdin is not a valid KeysPayload (or over the cap)
	ClassNotAdopted = "not_adopted" // --confirm-deleted before the identity was adopted
)

// KeysMax caps the payload read from stdin: three base64 keys fit many
// times over.
const KeysMax = 4 << 10

// Hand-over errors; none names a byte of a key.
var (
	ErrWrongKeys  = errors.New("adopt: the handed-over keys do not open the hub's sealed keys")
	ErrNoSidecar  = errors.New("adopt: no adopted hub state to hand the keys to")
	ErrBadKeys    = errors.New("adopt: the handed-over keys are malformed")
	ErrNotAdopted = errors.New("adopt: the identity is not adopted yet")
)

// KeysPayload is the Swift hub's identity as Desktop writes it on stdin
// (JSON, standard base64): hub_sig's Ed25519 seed, hub_kx's X25519 scalar
// and the 32-byte wrap key. relay_auth is created by the Go hub (the Swift
// hub had none).
type KeysPayload struct {
	HubSig []byte `json:"hub_sig"`
	HubKX  []byte `json:"hub_kx"`
	Wrap   []byte `json:"wrap"`
}

func (p *KeysPayload) zero() {
	clear(p.HubSig)
	clear(p.HubKX)
	clear(p.Wrap)
}

// keysHook is the test seam that sees the raw stdin buffer and the decoded
// payload, to check both are zeroed when HandOver returns.
var keysHook = func(raw []byte, p *KeysPayload) {}

// HandOver adopts the Swift hub's keys read from in (to EOF, at most
// KeysMax) into st, a desktop host's identity store: "adopted", or an error
// with its class as the answer. An identity already adopted or confirmed
// answers "adopted" at once; in is drained and discarded. The payload is
// zeroed before HandOver returns.
func HandOver(ctx context.Context, hubDir string, in io.Reader, st identity.Staging) (string, error) {
	var buf [KeysMax + 1]byte
	defer clear(buf[:])
	n, err := io.ReadFull(in, buf[:])
	tooLong := false
	switch {
	case err == nil:
		// Over the cap: drain the rest so the writer never blocks.
		tooLong = true
		_, _ = io.Copy(io.Discard, in)
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
	default:
		return ClassFailed, fmt.Errorf("adopt: reading the keys: %w", err)
	}
	raw := buf[:n]

	store, err := openAdopted(hubDir)
	if err != nil {
		return classOfKeys(err), err
	}
	defer func() { _ = store.Close() }()
	if v, _, err := store.Meta(MetaIdentity); err != nil {
		return ClassFailed, err
	} else if v == IdentityAdopted || v == IdentityConfirmed {
		return IdentityAdopted, nil
	}
	if tooLong {
		return ClassBadKeys, ErrBadKeys
	}

	lock, err := state.AcquireLock(hubDir)
	if err != nil {
		if errors.Is(err, state.ErrLocked) {
			return ClassLocked, err
		}
		return ClassFailed, err
	}
	defer func() { _ = lock.Release() }()
	// A hand-over that finished between the first read and the lock.
	if v, _, err := store.Meta(MetaIdentity); err != nil {
		return ClassFailed, err
	} else if v == IdentityAdopted || v == IdentityConfirmed {
		return IdentityAdopted, nil
	}

	var p KeysPayload
	defer p.zero()
	err = json.Unmarshal(raw, &p)
	keysHook(raw, &p)
	if err != nil {
		return ClassBadKeys, ErrBadKeys
	}
	id, err := identity.FromSwift(p.HubSig, p.HubKX, p.Wrap)
	if err != nil {
		return ClassBadKeys, ErrBadKeys
	}
	defer id.Zero()

	ans, err := handOver(ctx, store, id, st)
	if err != nil {
		log.Printf("hub adopt: key hand-over failed (%s)", ans)
		return ans, err
	}
	log.Print("hub adopt: identity adopted")
	return IdentityAdopted, nil
}

// handOver runs the two phases once the payload is an identity.
func handOver(ctx context.Context, store *state.Store, id identity.Identity, st identity.Staging) (string, error) {
	if err := st.SaveStaged(id); err != nil {
		return ClassFailed, err
	}
	if err := hook("keys:saved"); err != nil {
		return ClassFailed, err
	}
	if err := store.SetMeta(MetaIdentity, IdentityStaged); err != nil {
		return ClassFailed, err
	}
	if err := hook("keys:staged"); err != nil {
		return ClassFailed, err
	}

	// Open the sidecar's sealed keys with what the store holds as staged.
	staged, ok, err := st.Staged()
	if err == nil && !ok {
		err = errors.New("adopt: the staged identity did not read back")
	}
	if err == nil {
		err = opens(store, staged)
		staged.Zero()
	}
	if err != nil {
		cls := classOfKeys(err)
		_ = st.DeleteStaged()
		_ = clearIdentityMeta(ctx, store)
		return cls, err
	}
	if err := hook("keys:verified"); err != nil {
		return ClassFailed, err
	}

	if err := st.PromoteStaged(); errors.Is(err, identity.ErrNothingStaged) {
		// A repeat after a crash inside the promotion: done when the live
		// identity opens the keys.
		live, lerr := st.Load()
		if lerr != nil {
			return ClassFailed, err
		}
		err = opens(store, live)
		live.Zero()
		if err != nil {
			return classOfKeys(err), err
		}
	} else if err != nil {
		return ClassFailed, err
	}
	if err := hook("keys:promoted"); err != nil {
		return ClassFailed, err
	}
	if err := store.WithTx(ctx, func(tx *sql.Tx) error {
		return state.SetMetaTx(tx, MetaIdentity, IdentityAdopted)
	}); err != nil {
		return ClassFailed, err
	}
	return IdentityAdopted, nil
}

// opens checks that id opens the sidecar's K_meta and current epoch keys.
// openAdopted already found them present, so NewKeyring writes nothing.
func opens(store *state.Store, id identity.Identity) error {
	_, err := identity.NewKeyring(id, store, nil)
	if errors.Is(err, identity.ErrSealedKeyUnreadable) {
		return ErrWrongKeys
	}
	return err
}

func clearIdentityMeta(ctx context.Context, store *state.Store) error {
	return store.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, MetaIdentity)
		return err
	})
}

// openAdopted opens the hub dir's sidecar when it is an adoption's (the
// Swift file renamed in, adopt_step recorded) and holds the sealed keys:
// hub_id, K_meta and at least one epoch. A Go hub of its own, a missing
// file or one without keys is ErrNoSidecar — never a sidecar created here.
func openAdopted(hubDir string) (*state.Store, error) {
	r := &run{hub: hubDir}
	if !exists(r.goFile()) {
		return nil, ErrNoSidecar
	}
	m, err := readMeta(r.goFile(), false, MetaAdoptStep, state.MetaHubID, state.MetaKMetaSealed)
	if err != nil {
		return nil, err
	}
	if m[MetaAdoptStep] == "" || m[state.MetaHubID] == "" || m[state.MetaKMetaSealed] == "" {
		return nil, ErrNoSidecar
	}
	st, err := state.Open(hubDir)
	if err != nil {
		return nil, err
	}
	if e, err := st.Epochs(); err != nil || len(e) == 0 {
		_ = st.Close()
		if err != nil {
			return nil, err
		}
		return nil, ErrNoSidecar
	}
	return st, nil
}

// DesktopStore is the identity store a desktop host's hand-over writes:
// identity.ForDesktopHost over the adopted sidecar (recorded once in
// hub_meta.identity_store). No sidecar is created: without an adopted one it
// is ErrNoSidecar.
func DesktopStore(hubDir string, keychainWorks bool) (identity.Staging, error) {
	store, err := openAdopted(hubDir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = store.Close() }()
	return identity.ForDesktopHost(store, hubDir, keychainWorks)
}

// KeysClass is the answer class of a hand-over error.
func KeysClass(err error) string { return classOfKeys(err) }

func classOfKeys(err error) string {
	switch {
	case errors.Is(err, ErrWrongKeys):
		return ClassWrongKeys
	case errors.Is(err, ErrNoSidecar):
		return ClassNoSidecar
	case errors.Is(err, ErrBadKeys):
		return ClassBadKeys
	case errors.Is(err, ErrNotAdopted):
		return ClassNotAdopted
	case errors.Is(err, state.ErrLocked):
		return ClassLocked
	}
	return ClassFailed
}

// ConfirmDeleted records that Desktop deleted its own Keychain items:
// identity adopted → confirmed (a repeat is no error). Before the identity
// is adopted it is ErrNotAdopted and nothing changes. It takes no hub lock:
// the hub may already run once the identity is adopted.
func ConfirmDeleted(hubDir string) error {
	store, err := openAdopted(hubDir)
	if err != nil {
		return err
	}
	defer func() { _ = store.Close() }()
	return store.WithTx(context.Background(), func(tx *sql.Tx) error {
		v, _, err := state.MetaTx(tx, MetaIdentity)
		if err != nil {
			return err
		}
		switch v {
		case IdentityConfirmed:
			return nil
		case IdentityAdopted:
			return state.SetMetaTx(tx, MetaIdentity, IdentityConfirmed)
		}
		return ErrNotAdopted
	})
}

// HubMayStart reports whether the hub may run on st's identity: the
// adoption finished (adopted_at) and the key hand-over reached adopted or
// confirmed. A sidecar that never adopted (a Go hub of its own: no
// adopt_step) is true; until both are set an adopting hub stays off
// (awaiting_adoption).
func HubMayStart(st *state.Store) (bool, error) {
	step, _, err := st.Meta(MetaAdoptStep)
	if err != nil {
		return false, err
	}
	if step == "" {
		return true, nil
	}
	at, _, err := st.Meta(MetaAdoptedAt)
	if err != nil {
		return false, err
	}
	v, _, err := st.Meta(MetaIdentity)
	if err != nil {
		return false, err
	}
	return at != "" && (v == IdentityAdopted || v == IdentityConfirmed), nil
}
