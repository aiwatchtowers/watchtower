package adopt

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/logcanary"
)

// swiftKeys is the Swift hub's identity as Desktop holds it: three raw
// 32-byte keys.
type swiftKeys struct{ sig, kx, wrap []byte }

func newSwiftKeys(t *testing.T) swiftKeys {
	t.Helper()
	k := swiftKeys{sig: make([]byte, 32), kx: make([]byte, 32), wrap: make([]byte, 32)}
	for _, b := range [][]byte{k.sig, k.kx, k.wrap} {
		if _, err := rand.Read(b); err != nil {
			t.Fatal(err)
		}
	}
	return k
}

func (k swiftKeys) payload(t *testing.T) string {
	t.Helper()
	b, err := json.Marshal(KeysPayload{HubSig: k.sig, HubKX: k.kx, Wrap: k.wrap})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// keysFixture is an adopted Mac whose sidecar keys are sealed by keys (the
// Swift hub's wrap key), as the Swift hub left them.
type keysFixture struct {
	*fixture
	keys swiftKeys
}

func newKeysFixture(t *testing.T) *keysFixture {
	t.Helper()
	f := newFixture(t)
	f.mustRun(t)
	k := newSwiftKeys(t)
	// The fixture's sealed rows are placeholders: reseal them under k.
	db, err := rawOpen(filepath.Join(f.hub, state.FileName), openRW)
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{`DELETE FROM hub_epochs`, `DELETE FROM hub_meta WHERE key = '` + state.MetaKMetaSealed + `'`} {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	_ = db.Close()
	st, err := state.Open(f.hub)
	if err != nil {
		t.Fatal(err)
	}
	id, err := identity.FromSwift(k.sig, k.kx, k.wrap)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := identity.NewKeyring(id, st, nil); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	return &keysFixture{fixture: f, keys: k}
}

func (f *keysFixture) handOver(t *testing.T, st identity.Staging, payload string) (string, error) {
	t.Helper()
	return HandOver(context.Background(), f.hub, strings.NewReader(payload), st)
}

func (f *keysFixture) identityMeta(t *testing.T) string {
	t.Helper()
	rep, err := Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	return rep.Identity
}

// opensSidecar reports whether id opens the sidecar's sealed keys.
func (f *keysFixture) opensSidecar(t *testing.T, id identity.Identity) bool {
	t.Helper()
	st, err := state.Open(f.hub)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	_, err = identity.NewKeyring(id, st, nil)
	return err == nil
}

func (f *keysFixture) adoptedOK(t *testing.T) bool {
	t.Helper()
	st, err := state.Open(f.hub)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	ok, err := HubMayStart(st)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// storeKind is one desktop-host identity store: the file store (release
// builds) and the Keychain store over the in-memory Keychain.
type storeKind struct {
	name string
	make func(hubDir string) (identity.Staging, *identity.MemKeychain)
}

var storeKinds = []storeKind{
	{"file", func(hubDir string) (identity.Staging, *identity.MemKeychain) {
		return identity.FileStore{Path: filepath.Join(hubDir, identity.FileName)}, nil
	}},
	{"keychain", func(string) (identity.Staging, *identity.MemKeychain) {
		s, m := identity.NewMemKeychainStore("watchtower-hub-test")
		return s, m
	}},
}

func eachStore(t *testing.T, fn func(t *testing.T, k storeKind)) {
	for _, k := range storeKinds {
		t.Run(k.name, func(t *testing.T) { fn(t, k) })
	}
}

func sameKeys(id identity.Identity, k swiftKeys) bool {
	return bytes.Equal(id.Signing.Seed(), k.sig) && bytes.Equal(id.Agreement.Bytes(), k.kx) && bytes.Equal(id.Wrap[:], k.wrap)
}

func TestHandOverStagesThenAdopts(t *testing.T) {
	eachStore(t, func(t *testing.T, kind storeKind) {
		f := newKeysFixture(t)
		st, _ := kind.make(f.hub)
		if got := f.identityMeta(t); got != identityNone {
			t.Fatalf("identity before = %q", got)
		}
		if f.adoptedOK(t) {
			t.Fatal("the hub may start before the keys are handed over")
		}
		ans, err := f.handOver(t, st, f.keys.payload(t))
		if err != nil || ans != IdentityAdopted {
			t.Fatalf("HandOver = %q, %v", ans, err)
		}
		if got := f.identityMeta(t); got != IdentityAdopted {
			t.Fatalf("identity = %q", got)
		}
		live, err := st.Load()
		if err != nil {
			t.Fatal(err)
		}
		if !sameKeys(live, f.keys) || len(live.RelayAuth) == 0 {
			t.Fatal("the live identity is not the handed-over one (with a relay_auth)")
		}
		if !f.opensSidecar(t, live) {
			t.Fatal("the live identity does not open the sidecar")
		}
		if _, ok, err := st.Staged(); err != nil || ok {
			t.Fatalf("a staged copy is left: %v %v", ok, err)
		}
		if !f.adoptedOK(t) {
			t.Fatal("HubMayStart is false after the hand-over")
		}
	})
}

func TestWrongKeysDeleteTheStagedCopy(t *testing.T) {
	eachStore(t, func(t *testing.T, kind storeKind) {
		f := newKeysFixture(t)
		st, _ := kind.make(f.hub)
		wrong := newSwiftKeys(t)
		ans, err := f.handOver(t, st, wrong.payload(t))
		if !errors.Is(err, ErrWrongKeys) || ans != ClassWrongKeys {
			t.Fatalf("HandOver = %q, %v", ans, err)
		}
		if _, ok, err := st.Staged(); err != nil || ok {
			t.Fatalf("the staged copy is left: %v %v", ok, err)
		}
		if _, err := st.Load(); !errors.Is(err, identity.ErrNoIdentity) {
			t.Fatalf("a live identity exists: %v", err)
		}
		if got := f.identityMeta(t); got != identityNone {
			t.Fatalf("identity = %q", got)
		}
		// The right keys still adopt afterwards.
		if ans, err := f.handOver(t, st, f.keys.payload(t)); err != nil || ans != IdentityAdopted {
			t.Fatalf("HandOver = %q, %v", ans, err)
		}
	})
}

func TestHandOverRefusesBadPayloads(t *testing.T) {
	f := newKeysFixture(t)
	st, _ := storeKinds[0].make(f.hub)
	short := base64.StdEncoding.EncodeToString([]byte("short"))
	for name, in := range map[string]string{
		"not json":  "{",
		"short key": `{"hub_sig":"` + short + `","hub_kx":"` + short + `","wrap":"` + short + `"}`,
		"over cap":  `{"hub_sig":"` + strings.Repeat("A", KeysMax) + `"}`,
	} {
		ans, err := f.handOver(t, st, in)
		if !errors.Is(err, ErrBadKeys) || ans != ClassBadKeys {
			t.Errorf("%s: HandOver = %q, %v", name, ans, err)
		}
	}
	if got := f.identityMeta(t); got != identityNone {
		t.Fatalf("identity = %q", got)
	}
}

func TestHandOverWithoutAnAdoptedSidecar(t *testing.T) {
	hub := filepath.Join(t.TempDir(), ".hub")
	st := identity.FileStore{Path: filepath.Join(hub, identity.FileName)}
	ans, err := HandOver(context.Background(), hub, strings.NewReader(newSwiftKeys(t).payload(t)), st)
	if !errors.Is(err, ErrNoSidecar) || ans != ClassNoSidecar {
		t.Fatalf("HandOver = %q, %v", ans, err)
	}
	if _, err := os.Stat(filepath.Join(hub, state.FileName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("a sidecar was created")
	}
	if _, err := DesktopStore(hub, false); !errors.Is(err, ErrNoSidecar) {
		t.Fatalf("DesktopStore = %v", err)
	}

	// A Go hub of its own (no adoption) never takes handed-over keys.
	own, err := state.Open(hub)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := identity.NewKeyring(mustIdentity(t), own, nil); err != nil {
		t.Fatal(err)
	}
	_ = own.Close()
	if ans, err := HandOver(context.Background(), hub, strings.NewReader(newSwiftKeys(t).payload(t)), st); !errors.Is(err, ErrNoSidecar) {
		t.Fatalf("HandOver over a Go hub = %q, %v", ans, err)
	}
}

func mustIdentity(t *testing.T) identity.Identity {
	t.Helper()
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// keyPoints are HandOver's kill points, in order.
var keyPoints = []string{"keys:saved", "keys:staged", "keys:verified", "keys:promoted"}

// TestHandOverCrashBeforeAdoptedKeepsDesktopItems (Review Focus 1): a kill
// at any point before adopted never answers adopted, so Desktop keeps its
// Keychain items; the hub may not start; before the promotion the staged
// identity already opens the sidecar keys; a re-run overwrites the staged
// copy and adopts.
func TestHandOverCrashBeforeAdoptedKeepsDesktopItems(t *testing.T) {
	// The matrix is exhaustive: an uninterrupted hand-over passes exactly
	// these points, in this order.
	t.Run("matrix", func(t *testing.T) {
		f := newKeysFixture(t)
		st, _ := storeKinds[0].make(f.hub)
		var seen []string
		prev := stepHook
		stepHook = func(p string) error {
			if strings.HasPrefix(p, "keys:") {
				seen = append(seen, p)
			}
			return nil
		}
		t.Cleanup(func() { stepHook = prev })
		if _, err := f.handOver(t, st, f.keys.payload(t)); err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(seen, keyPoints) {
			t.Fatalf("points = %v, want %v", seen, keyPoints)
		}
	})
	for _, point := range keyPoints {
		eachStore(t, func(t *testing.T, kind storeKind) {
			t.Run(point, func(t *testing.T) {
				f := newKeysFixture(t)
				st, _ := kind.make(f.hub)
				// Desktop's own items: deleted only on an "adopted" answer.
				desktopItems := true
				killAt(t, point)
				ans, err := f.handOver(t, st, f.keys.payload(t))
				if !errors.Is(err, errKilled) {
					t.Fatalf("HandOver = %q, %v; want the kill", ans, err)
				}
				if ans == IdentityAdopted {
					desktopItems = false
				}
				if !desktopItems {
					t.Fatal("Desktop was told adopted before the identity was adopted")
				}
				if got := f.identityMeta(t); got == IdentityAdopted || got == IdentityConfirmed {
					t.Fatalf("identity = %q after a kill at %s", got, point)
				}
				if point != "keys:saved" && f.identityMeta(t) != IdentityStaged {
					t.Fatalf("identity = %q, want staged", f.identityMeta(t))
				}
				if f.adoptedOK(t) {
					t.Fatal("the hub may start on an identity that is not adopted")
				}
				if point != "keys:promoted" {
					staged, ok, err := st.Staged()
					if err != nil || !ok {
						t.Fatalf("no staged identity: %v %v", ok, err)
					}
					if !f.opensSidecar(t, staged) {
						t.Fatal("the staged identity does not open the sidecar keys")
					}
					if _, err := st.Load(); !errors.Is(err, identity.ErrNoIdentity) {
						t.Fatalf("live identity before the promotion: %v", err)
					}
				}

				// The next launch runs the hand-over again from the top.
				ans, err = f.handOver(t, st, f.keys.payload(t))
				if err != nil || ans != IdentityAdopted {
					t.Fatalf("re-run = %q, %v", ans, err)
				}
				live, err := st.Load()
				if err != nil || !sameKeys(live, f.keys) || !f.opensSidecar(t, live) {
					t.Fatalf("live identity after the re-run: %v", err)
				}
				if _, ok, _ := st.Staged(); ok {
					t.Fatal("a staged copy is left after the re-run")
				}
				if !f.adoptedOK(t) {
					t.Fatal("HubMayStart is false after the re-run")
				}
			})
		})
	}
}

// repeatPromote answers ErrNothingStaged after promoting, as a repeat after
// a crash inside the promotion would.
type repeatPromote struct{ identity.Staging }

func (r repeatPromote) PromoteStaged() error {
	if err := r.Staging.PromoteStaged(); err != nil {
		return err
	}
	return identity.ErrNothingStaged
}

func TestHandOverNothingStagedAfterAPromotionIsAdopted(t *testing.T) {
	eachStore(t, func(t *testing.T, kind storeKind) {
		f := newKeysFixture(t)
		st, _ := kind.make(f.hub)
		ans, err := f.handOver(t, repeatPromote{st}, f.keys.payload(t))
		if err != nil || ans != IdentityAdopted {
			t.Fatalf("HandOver = %q, %v", ans, err)
		}
	})
}

// countingStore counts the writes to the store.
type countingStore struct {
	identity.Staging
	writes int
}

func (c *countingStore) SaveStaged(id identity.Identity) error {
	c.writes++
	return c.Staging.SaveStaged(id)
}

func (c *countingStore) PromoteStaged() error {
	c.writes++
	return c.Staging.PromoteStaged()
}

// drainReader reports how much of it was read.
type drainReader struct {
	r    io.Reader
	read int
}

func (d *drainReader) Read(p []byte) (int, error) {
	n, err := d.r.Read(p)
	d.read += n
	return n, err
}

func TestAdoptedAnswersAtOnce(t *testing.T) {
	eachStore(t, func(t *testing.T, kind storeKind) {
		f := newKeysFixture(t)
		st, _ := kind.make(f.hub)
		if _, err := f.handOver(t, st, f.keys.payload(t)); err != nil {
			t.Fatal(err)
		}
		before, err := st.Load()
		if err != nil {
			t.Fatal(err)
		}
		c := &countingStore{Staging: st}
		for _, v := range []string{IdentityAdopted, IdentityConfirmed} {
			if v == IdentityConfirmed {
				if err := ConfirmDeleted(f.hub); err != nil {
					t.Fatal(err)
				}
			}
			// Other keys, and more than the cap: drained, never read as keys.
			junk := newSwiftKeys(t).payload(t) + strings.Repeat(" ", 3*KeysMax)
			in := &drainReader{r: strings.NewReader(junk)}
			ans, err := HandOver(context.Background(), f.hub, in, c)
			if err != nil || ans != IdentityAdopted {
				t.Fatalf("%s: HandOver = %q, %v", v, ans, err)
			}
			if in.read != len(junk) {
				t.Fatalf("%s: stdin drained %d of %d bytes", v, in.read, len(junk))
			}
		}
		if c.writes != 0 {
			t.Fatalf("the store was written %d times", c.writes)
		}
		after, err := st.Load()
		if err != nil || !bytes.Equal(before.Signing, after.Signing) || !bytes.Equal(before.RelayAuth, after.RelayAuth) {
			t.Fatalf("the live identity changed: %v", err)
		}
	})
}

func TestConfirmDeletedOnlyAfterAdopted(t *testing.T) {
	f := newKeysFixture(t)
	st, _ := storeKinds[0].make(f.hub)
	if err := ConfirmDeleted(f.hub); !errors.Is(err, ErrNotAdopted) || KeysClass(err) != ClassNotAdopted {
		t.Fatalf("ConfirmDeleted before = %v", err)
	}
	killAt(t, "keys:verified")
	if _, err := f.handOver(t, st, f.keys.payload(t)); !errors.Is(err, errKilled) {
		t.Fatal(err)
	}
	if err := ConfirmDeleted(f.hub); !errors.Is(err, ErrNotAdopted) {
		t.Fatalf("ConfirmDeleted while staged = %v", err)
	}
	if got := f.identityMeta(t); got != IdentityStaged {
		t.Fatalf("identity = %q", got)
	}
	if _, err := f.handOver(t, st, f.keys.payload(t)); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := ConfirmDeleted(f.hub); err != nil {
			t.Fatal(err)
		}
		if got := f.identityMeta(t); got != IdentityConfirmed {
			t.Fatalf("identity = %q", got)
		}
	}
	if !f.adoptedOK(t) {
		t.Fatal("HubMayStart is false when confirmed")
	}
}

// keyFiles walks root and returns every file holding any of the key bytes
// (raw or base64), with its mode.
func keyFiles(t *testing.T, root string, k swiftKeys) map[string]fs.FileMode {
	t.Helper()
	found := map[string]fs.FileMode{}
	needles := [][]byte{}
	for _, b := range [][]byte{k.sig, k.kx, k.wrap} {
		needles = append(needles, b, []byte(base64.StdEncoding.EncodeToString(b)))
	}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := os.ReadFile(p) //nolint:gosec // G122: the test's own temp dir

		if err != nil {
			return err
		}
		for _, n := range needles {
			if bytes.Contains(b, n) {
				info, err := d.Info()
				if err != nil {
					return err
				}
				found[filepath.Base(p)] = info.Mode().Perm()
				break
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return found
}

func TestKeysNeverTouchDisk(t *testing.T) {
	eachStore(t, func(t *testing.T, kind storeKind) {
		f := newKeysFixture(t)
		st, mem := kind.make(f.hub)
		allowed := map[string]bool{}
		if mem == nil {
			allowed = map[string]bool{identity.StagedFileName: true, identity.FileName: true}
		}
		check := func(at string) {
			for name, mode := range keyFiles(t, f.root, f.keys) {
				if !allowed[name] {
					t.Errorf("%s: key bytes in %s", at, name)
				} else if mode != 0o600 {
					t.Errorf("%s: %s has mode %o", at, name, mode)
				}
			}
		}
		prev := stepHook
		stepHook = func(p string) error {
			if strings.HasPrefix(p, "keys:") {
				check(p)
			}
			return nil
		}
		t.Cleanup(func() { stepHook = prev })
		if _, err := f.handOver(t, st, f.keys.payload(t)); err != nil {
			t.Fatal(err)
		}
		check("adopted")
		if mem != nil && len(mem.Items()) != 1 {
			t.Fatalf("Keychain items = %d, want the live one only", len(mem.Items()))
		}
	})
}

func TestKeysNeverLogged(t *testing.T) {
	sink := logcanary.Capture(t)
	f := newKeysFixture(t)
	st, _ := storeKinds[0].make(f.hub)
	wrong := newSwiftKeys(t)
	_, _ = f.handOver(t, st, wrong.payload(t))
	_, _ = f.handOver(t, st, `{"hub_sig":"`+logcanary.Text("hub_sig")+`"}`)
	if _, err := f.handOver(t, st, f.keys.payload(t)); err != nil {
		t.Fatal(err)
	}
	sink.AssertClean(t)
	out := sink.String()
	if !strings.Contains(out, "key hand-over failed (wrong_keys)") || !strings.Contains(out, "identity adopted") {
		t.Fatalf("expected class lines, got %q", out)
	}
	for _, k := range []swiftKeys{f.keys, wrong} {
		for _, b := range [][]byte{k.sig, k.kx, k.wrap} {
			if strings.Contains(out, string(b)) || strings.Contains(out, base64.StdEncoding.EncodeToString(b)) {
				t.Fatal("key bytes reached the log")
			}
		}
	}
}

func TestPayloadZeroedAfterUse(t *testing.T) {
	for _, tc := range []struct {
		name string
		keys func(f *keysFixture) swiftKeys
	}{
		{"adopted", func(f *keysFixture) swiftKeys { return f.keys }},
		{"wrong keys", func(*keysFixture) swiftKeys { return newSwiftKeys(t) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newKeysFixture(t)
			st, _ := storeKinds[1].make(f.hub)
			var raw []byte
			var held [][]byte
			prev := keysHook
			keysHook = func(r []byte, p *KeysPayload) {
				raw = r
				held = [][]byte{p.HubSig, p.HubKX, p.Wrap}
			}
			t.Cleanup(func() { keysHook = prev })
			_, _ = f.handOver(t, st, tc.keys(f).payload(t))
			if len(raw) == 0 || len(held) != 3 {
				t.Fatal("the hook saw no payload")
			}
			for i, b := range append(held, raw[:cap(raw)]) {
				if len(b) == 0 || bytes.ContainsFunc(b, func(r rune) bool { return r != 0 }) {
					t.Errorf("buffer %d not zeroed", i)
				}
			}
		})
	}
}
