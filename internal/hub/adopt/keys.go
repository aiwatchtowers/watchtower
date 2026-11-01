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
// A failure (not a kill) deletes the staged copy and the identity record;
// when that cleanup fails too the answer is cleanup_failed. The hub stays
// off until HubMayStart.
//
// One writer: every sidecar write here runs under the hub lock. The only
// lock-free step is the read-only check that answers an identity already
// adopted (the hub may run then).

// MetaIdentity values (hub_meta.identity_adoption; none = the key absent).
const (
	IdentityStaged    = "staged"
	IdentityAdopted   = "adopted"
	IdentityConfirmed = "confirmed"
)

// Hand-over error classes (HandOver's and ConfirmDeleted's answer).
const (
	ClassWrongKeys          = "wrong_keys"          // the keys do not open the sidecar's sealed keys
	ClassNoSidecar          = "no_sidecar"          // no adopted Swift sidecar with keys in the hub dir
	ClassAdoptionUnfinished = "adoption_unfinished" // the state adoption (Run) has not reached done
	ClassBadKeys            = "bad_keys"            // stdin is not a valid KeysPayload (or over the cap)
	ClassNotAdopted         = "not_adopted"         // --confirm-deleted before the identity was adopted
	ClassCleanupFailed      = "cleanup_failed"      // a failed hand-over could not delete its staged copy
	ClassKeychainRefused    = "keychain_refused"    // test mode met a recorded Keychain store
)

// KeysMax caps the payload read from stdin: three base64 keys fit many
// times over.
const KeysMax = 4 << 10

// Hand-over errors; none names a byte of a key.
var (
	ErrWrongKeys          = errors.New("adopt: the handed-over keys do not open the hub's sealed keys")
	ErrNoSidecar          = errors.New("adopt: no adopted hub state to hand the keys to")
	ErrAdoptionUnfinished = errors.New("adopt: the hub state adoption has not finished")
	ErrBadKeys            = errors.New("adopt: the handed-over keys are malformed")
	ErrNotAdopted         = errors.New("adopt: the identity is not adopted yet")
	ErrCleanupFailed      = errors.New("adopt: the failed hand-over's staged copy could not be removed")
	ErrKeychainRefused    = errors.New("adopt: a Keychain identity store is refused in test mode")
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

// Test seams: keysHook sees the raw stdin buffer and the decoded payload
// (to check both are zeroed); failPoint makes a step fail as a real error
// would (a kill is stepHook).
var (
	keysHook  = func(raw []byte, p *KeysPayload) {}
	failPoint = func(step string) error { return nil }
)

// picker chooses the identity store under the hub lock: the store, its kind
// and whether hub_meta already records it.
type picker func(*state.Store) (identity.Staging, string, bool, error)

// HandOver adopts the Swift hub's keys read from in (to EOF, at most
// KeysMax) into st: "adopted", or an error with its class as the answer.
// An identity already adopted or confirmed answers "adopted" at once; in is
// drained and discarded. The payload is zeroed before HandOver returns.
func HandOver(ctx context.Context, hubDir string, in io.Reader, st identity.Staging) (string, error) {
	return handOverWith(ctx, hubDir, in, func(*state.Store) (identity.Staging, string, bool, error) {
		return st, "", true, nil
	})
}

// HandOverDesktop is HandOver into a desktop host's identity store
// (identity.DesktopHostChoice). The choice is recorded in
// hub_meta.identity_store only with the adopted identity, so a refused
// hand-over records nothing. fileOnly (test mode) refuses a recorded
// Keychain store, so a test never reaches the login Keychain.
func HandOverDesktop(ctx context.Context, hubDir string, in io.Reader, keychainWorks, fileOnly bool) (string, error) {
	return handOverWith(ctx, hubDir, in, func(store *state.Store) (identity.Staging, string, bool, error) {
		if fileOnly {
			keychainWorks = false
		}
		st, kind, recorded, err := identity.DesktopHostChoice(store, hubDir, keychainWorks)
		if err != nil {
			return nil, "", false, err
		}
		if fileOnly && kind != identity.IdentityStoreFile {
			return nil, "", false, ErrKeychainRefused
		}
		return st, kind, recorded, nil
	})
}

func handOverWith(ctx context.Context, hubDir string, in io.Reader, pick picker) (string, error) {
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
		return ClassFailed, fmt.Errorf("adopt: key hand-over, reading stdin: %w", err)
	}
	raw := buf[:n]

	// Read-only first: an adopted identity answers at once, even while the
	// hub runs and holds the lock.
	if v, err := finishedIdentity(hubDir); err != nil {
		return classOfKeys(err), err
	} else if v == IdentityAdopted || v == IdentityConfirmed {
		return IdentityAdopted, nil
	}
	if tooLong {
		return ClassBadKeys, ErrBadKeys
	}

	lock, err := state.AcquireLock(hubDir)
	if err != nil {
		return classOfKeys(err), fmt.Errorf("adopt: key hand-over, the hub lock: %w", err)
	}
	defer func() { _ = lock.Release() }()
	store, err := openAdoptedLocked(hubDir)
	if err != nil {
		return classOfKeys(err), err
	}
	defer func() { _ = store.Close() }()
	// A hand-over that finished between the first read and the lock.
	if v, _, err := store.Meta(MetaIdentity); err != nil {
		return ClassFailed, fmt.Errorf("adopt: key hand-over, reading the identity record: %w", err)
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

	st, kind, recorded, err := pick(store)
	if err != nil {
		return classOfKeys(err), fmt.Errorf("adopt: key hand-over, choosing the identity store: %w", err)
	}
	ans, err := handOver(ctx, store, id, st, kind, recorded)
	if err != nil {
		var h hookError
		if !errors.As(err, &h) {
			log.Printf("hub adopt: key hand-over failed (%s)", ans)
		}
		return ans, err
	}
	log.Print("hub adopt: identity adopted")
	return IdentityAdopted, nil
}

// handOver runs the two phases once the payload is an identity, under the
// hub lock. A kill (stepHook) returns as is; every other failure after the
// staged copy may exist goes through fail, which cleans up.
func handOver(ctx context.Context, store *state.Store, id identity.Identity, st identity.Staging, kind string, recorded bool) (string, error) {
	fail := func(step, class string, err error) (string, error) {
		err = fmt.Errorf("adopt: key hand-over, %s: %w", step, err)
		if cerr := cleanup(ctx, store, st); cerr != nil {
			log.Printf("hub adopt: cleanup after a failed key hand-over failed (%s)", step)
			return ClassCleanupFailed, errors.Join(err, ErrCleanupFailed, cerr)
		}
		return class, err
	}

	if err := st.SaveStaged(id); err != nil {
		return fail("save_staged", ClassFailed, err)
	}
	if err := hook("keys:saved"); err != nil {
		return ClassFailed, err
	}
	err := failPoint("set_staged")
	if err == nil {
		err = store.SetMeta(MetaIdentity, IdentityStaged)
	}
	if err != nil {
		return fail("set_staged", ClassFailed, err)
	}
	if err := hook("keys:staged"); err != nil {
		return ClassFailed, err
	}

	// Open the sidecar's sealed keys with what the store holds as staged.
	staged, ok, err := st.Staged()
	if err == nil && !ok {
		err = errors.New("the staged identity did not read back")
	}
	if err == nil {
		err = opens(store, staged)
		staged.Zero()
	}
	if err != nil {
		return fail("verify", classOfKeys(err), err)
	}
	if err := hook("keys:verified"); err != nil {
		return ClassFailed, err
	}

	if err := st.PromoteStaged(); errors.Is(err, identity.ErrNothingStaged) {
		// A repeat after a crash inside the promotion: done when the live
		// identity opens the keys.
		live, lerr := st.Load()
		if lerr != nil {
			return fail("promote", ClassFailed, lerr)
		}
		err = opens(store, live)
		live.Zero()
		if err != nil {
			return fail("promote", classOfKeys(err), err)
		}
	} else if err != nil {
		return fail("promote", ClassFailed, err)
	}
	if err := hook("keys:promoted"); err != nil {
		return ClassFailed, err
	}

	err = failPoint("adopted")
	if err == nil {
		err = store.WithTx(ctx, func(tx *sql.Tx) error {
			if !recorded {
				if err := state.SetMetaTx(tx, identity.MetaIdentityStore, kind); err != nil {
					return err
				}
			}
			return state.SetMetaTx(tx, MetaIdentity, IdentityAdopted)
		})
	}
	if err != nil {
		return fail("adopted", ClassFailed, err)
	}
	return IdentityAdopted, nil
}

// cleanup removes a failed hand-over's staged copy and identity record.
func cleanup(ctx context.Context, store *state.Store, st identity.Staging) error {
	derr := st.DeleteStaged()
	merr := store.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, MetaIdentity)
		return err
	})
	return errors.Join(derr, merr)
}

// opens checks that id opens the sidecar's K_meta and current epoch keys.
// openAdoptedLocked already found them present, so NewKeyring writes
// nothing.
func opens(store *state.Store, id identity.Identity) error {
	_, err := identity.NewKeyring(id, store, nil)
	if errors.Is(err, identity.ErrSealedKeyUnreadable) {
		return ErrWrongKeys
	}
	return err
}

// finishedIdentity reads, read-only and without the lock, the identity
// record of a hub dir whose sidecar a finished adoption left (adopt_step
// done, adopted_at set, hub_id and K_meta present). A Go hub of its own (no
// adopt_step) or a missing sidecar is ErrNoSidecar; an adoption still on its
// way (the copy in adopt.tmp, or adopt_step before done) is
// ErrAdoptionUnfinished. Nothing is created.
func finishedIdentity(hubDir string) (string, error) {
	r := &run{hub: hubDir}
	if !exists(r.goFile()) {
		if exists(r.tmpFile()) {
			return "", ErrAdoptionUnfinished
		}
		return "", ErrNoSidecar
	}
	m, err := readMeta(r.goFile(), false, MetaAdoptStep, MetaAdoptedAt, state.MetaHubID, state.MetaKMetaSealed, MetaIdentity)
	if err != nil {
		return "", fmt.Errorf("adopt: key hand-over, reading the hub state: %w", err)
	}
	switch {
	case m[MetaAdoptStep] == "":
		return "", ErrNoSidecar
	case m[MetaAdoptStep] != string(StepDone) || m[MetaAdoptedAt] == "":
		return "", ErrAdoptionUnfinished
	case m[state.MetaHubID] == "" || m[state.MetaKMetaSealed] == "":
		return "", ErrNoSidecar
	}
	return m[MetaIdentity], nil
}

// openAdoptedLocked opens a finished adoption's sidecar read-write; the
// caller holds the hub lock. It also needs at least one epoch.
func openAdoptedLocked(hubDir string) (*state.Store, error) {
	if _, err := finishedIdentity(hubDir); err != nil {
		return nil, err
	}
	st, err := state.Open(hubDir)
	if err != nil {
		return nil, fmt.Errorf("adopt: key hand-over, opening the hub state: %w", err)
	}
	if e, err := st.Epochs(); err != nil || len(e) == 0 {
		_ = st.Close()
		if err != nil {
			return nil, fmt.Errorf("adopt: key hand-over, reading the epochs: %w", err)
		}
		return nil, ErrNoSidecar
	}
	return st, nil
}

// KeysClass is the answer class of a hand-over error.
func KeysClass(err error) string { return classOfKeys(err) }

func classOfKeys(err error) string {
	switch {
	case errors.Is(err, ErrCleanupFailed):
		return ClassCleanupFailed
	case errors.Is(err, ErrWrongKeys):
		return ClassWrongKeys
	case errors.Is(err, ErrNoSidecar):
		return ClassNoSidecar
	case errors.Is(err, ErrAdoptionUnfinished):
		return ClassAdoptionUnfinished
	case errors.Is(err, ErrBadKeys):
		return ClassBadKeys
	case errors.Is(err, ErrNotAdopted):
		return ClassNotAdopted
	case errors.Is(err, ErrKeychainRefused):
		return ClassKeychainRefused
	case errors.Is(err, state.ErrLocked):
		return ClassLocked
	}
	return ClassFailed
}

// ConfirmDeleted records that Desktop deleted its own Keychain items, on a
// hub dir whose lock the caller holds (no hub runs; with a hub running the
// CLI sends confirm_deleted over hub.sock and the hub calls
// ConfirmDeletedStore). Before a finished adoption it is ErrNoSidecar or
// ErrAdoptionUnfinished; nothing is created.
func ConfirmDeleted(hubDir string) error {
	store, err := openAdoptedLocked(hubDir)
	if err != nil {
		return err
	}
	defer func() { _ = store.Close() }()
	return ConfirmDeletedStore(store)
}

// ConfirmDeletedStore is identity adopted → confirmed in st, the writer's
// open sidecar (a repeat is no error). Before the identity is adopted it is
// ErrNotAdopted and nothing changes.
func ConfirmDeletedStore(st *state.Store) error {
	return st.WithTx(context.Background(), func(tx *sql.Tx) error {
		v, _, err := state.MetaTx(tx, MetaIdentity)
		if err != nil {
			return fmt.Errorf("adopt: confirm deleted, reading the identity record: %w", err)
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
// (awaiting_adoption; phase 3 Task 21 reads it).
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
