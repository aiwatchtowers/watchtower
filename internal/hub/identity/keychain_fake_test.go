package identity

import (
	"bytes"
	"errors"
	"testing"
)

// fakeKeychain is keychainOps over a map. crashAfter counts the calls that
// still succeed; the call after them fails as if the process died there
// (nothing written), and so does every later call of that "process" until
// the test calls restart.
type fakeKeychain struct {
	items      map[string][]byte
	puts       int
	crashAfter int // -1 = never
	calls      int
	getErr     error
}

var errCrashed = errors.New("crashed")

func newFakeKeychain() *fakeKeychain {
	return &fakeKeychain{items: map[string][]byte{}, crashAfter: -1}
}

func (f *fakeKeychain) step() error {
	if f.crashAfter >= 0 && f.calls >= f.crashAfter {
		return errCrashed
	}
	f.calls++
	return nil
}

func (f *fakeKeychain) restart() { f.crashAfter, f.calls = -1, 0 }

func (f *fakeKeychain) put(service, account string, data []byte) error {
	if err := f.step(); err != nil {
		return err
	}
	f.puts++
	f.items[service+"/"+account] = bytes.Clone(data)
	return nil
}

func (f *fakeKeychain) get(service, account string, buf []byte) (int, bool, error) {
	if f.getErr != nil {
		return 0, false, f.getErr
	}
	if err := f.step(); err != nil {
		return 0, false, err
	}
	data, ok := f.items[service+"/"+account]
	if !ok {
		return 0, false, nil
	}
	if len(data) <= len(buf) {
		copy(buf, data)
	}
	return len(data), true, nil
}

func (f *fakeKeychain) del(service, account string) error {
	if err := f.step(); err != nil {
		return err
	}
	delete(f.items, service+"/"+account)
	return nil
}

func fakeStore(t *testing.T) (KeychainStore, *fakeKeychain) {
	t.Helper()
	f := newFakeKeychain()
	return KeychainStore{Service: "watchtower-hub-fake", ops: f}, f
}

func mustNew(t *testing.T) Identity {
	t.Helper()
	id, err := New()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func sameIdentity(a, b Identity) bool {
	return a.Signing.Equal(b.Signing) && a.RelayAuth.Equal(b.RelayAuth) && a.Wrap == b.Wrap &&
		bytes.Equal(a.Agreement.Bytes(), b.Agreement.Bytes())
}

func wantLive(t *testing.T, s KeychainStore, want Identity) {
	t.Helper()
	got, err := s.Load()
	if err != nil || !sameIdentity(got, want) {
		t.Fatalf("Load = %v; want the expected live identity", err)
	}
}

func wantStaged(t *testing.T, s KeychainStore, want *Identity) {
	t.Helper()
	got, ok, err := s.Staged()
	if err != nil {
		t.Fatalf("Staged: %v", err)
	}
	if want == nil {
		if ok {
			t.Fatal("Staged ok, want nothing staged")
		}
		return
	}
	if !ok || !sameIdentity(got, *want) {
		t.Fatalf("Staged ok=%v; want the staged identity", ok)
	}
}

func TestKeychainEachWriteIsOneItem(t *testing.T) {
	s, f := fakeStore(t)
	id := mustNew(t)
	if err := s.Save(id); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveStaged(id); err != nil {
		t.Fatal(err)
	}
	if f.puts != 2 || len(f.items) != 2 {
		t.Fatalf("Save+SaveStaged = %d puts, %d items; want one item each", f.puts, len(f.items))
	}
	if err := s.PromoteStaged(); err != nil {
		t.Fatal(err)
	}
	if f.puts != 3 || len(f.items) != 1 {
		t.Fatalf("PromoteStaged = %d puts total, %d items; want one write and the staged item gone", f.puts, len(f.items))
	}
	blob := f.items["watchtower-hub-fake/"+keychainAccount]
	if len(blob) != fileLen || [8]byte(blob[:8]) != fileMagic {
		t.Fatal("the live item is not one blob in the identity format")
	}
}

// A crash after the live item is written and before the staged one is
// removed leaves equal copies; Load returns the promoted identity and a
// repeat finishes.
func TestKeychainPromoteCrashBeforeStagedDelete(t *testing.T) {
	s, f := fakeStore(t)
	live, staged := mustNew(t), mustNew(t)
	if err := s.Save(live); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveStaged(staged); err != nil {
		t.Fatal(err)
	}
	f.calls, f.crashAfter = 0, 2 // get staged, put live; crash at the delete
	if err := s.PromoteStaged(); !errors.Is(err, errCrashed) {
		t.Fatalf("PromoteStaged = %v, want the crash", err)
	}
	f.restart()
	wantLive(t, s, staged)
	wantStaged(t, s, &staged)
	if err := s.PromoteStaged(); err != nil {
		t.Fatalf("repeat PromoteStaged: %v", err)
	}
	wantLive(t, s, staged)
	wantStaged(t, s, nil)
	if err := s.PromoteStaged(); !errors.Is(err, ErrNothingStaged) || !errors.Is(err, ErrNoIdentity) {
		t.Fatalf("PromoteStaged after it finished = %v, want ErrNothingStaged", err)
	}
	wantLive(t, s, staged)
}

// A crash at the live write changes nothing; a repeat promotes.
func TestKeychainPromoteCrashAtLiveWrite(t *testing.T) {
	s, f := fakeStore(t)
	live, staged := mustNew(t), mustNew(t)
	if err := s.Save(live); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveStaged(staged); err != nil {
		t.Fatal(err)
	}
	f.calls, f.crashAfter = 0, 1 // get staged; crash at the live write
	if err := s.PromoteStaged(); !errors.Is(err, errCrashed) {
		t.Fatalf("PromoteStaged = %v, want the crash", err)
	}
	f.restart()
	wantLive(t, s, live)
	wantStaged(t, s, &staged)
	if err := s.PromoteStaged(); err != nil {
		t.Fatalf("repeat PromoteStaged: %v", err)
	}
	wantLive(t, s, staged)
	wantStaged(t, s, nil)
}

// A crash at SaveStaged leaves no staged copy and the live one untouched.
func TestKeychainSaveStagedCrash(t *testing.T) {
	s, f := fakeStore(t)
	live := mustNew(t)
	if err := s.Save(live); err != nil {
		t.Fatal(err)
	}
	f.calls, f.crashAfter = 0, 0
	if err := s.SaveStaged(mustNew(t)); !errors.Is(err, errCrashed) {
		t.Fatalf("SaveStaged = %v, want the crash", err)
	}
	f.restart()
	wantStaged(t, s, nil)
	if err := s.PromoteStaged(); !errors.Is(err, ErrNothingStaged) {
		t.Fatalf("PromoteStaged = %v, want ErrNothingStaged", err)
	}
	wantLive(t, s, live)
}

// An unreadable staged item never blocks recovery: Staged reports none,
// PromoteStaged changes nothing, SaveStaged overwrites it.
func TestKeychainMalformedStagedIsNotStaged(t *testing.T) {
	good, err := encodeIdentity(mustNew(t))
	if err != nil {
		t.Fatal(err)
	}
	badVersion := bytes.Clone(good)
	badVersion[7] = 2
	for name, blob := range map[string][]byte{
		"short":       good[:40],
		"longer":      append(bytes.Clone(good), 0),
		"much longer": append(bytes.Clone(good), make([]byte, 64)...),
		"bad magic":   append([]byte("XXXXXXX\x01"), good[8:]...),
		"bad version": badVersion,
	} {
		t.Run(name, func(t *testing.T) {
			s, f := fakeStore(t)
			live := mustNew(t)
			if err := s.Save(live); err != nil {
				t.Fatal(err)
			}
			f.items["watchtower-hub-fake/"+keychainStagedAccount] = blob
			wantStaged(t, s, nil)
			if err := s.PromoteStaged(); !errors.Is(err, ErrNothingStaged) {
				t.Fatalf("PromoteStaged = %v, want ErrNothingStaged", err)
			}
			wantLive(t, s, live)
			staged := mustNew(t)
			if err := s.SaveStaged(staged); err != nil {
				t.Fatal(err)
			}
			wantStaged(t, s, &staged)
		})
	}
}

func TestKeychainMalformedLiveIsAnError(t *testing.T) {
	s, f := fakeStore(t)
	f.items["watchtower-hub-fake/"+keychainAccount] = []byte("short")
	if _, err := s.Load(); !errors.Is(err, errMalformedKeychain) {
		t.Fatalf("Load = %v, want errMalformedKeychain", err)
	}
}

// A refused Keychain call is not "nothing staged".
func TestKeychainStagedCallFailureIsAnError(t *testing.T) {
	s, f := fakeStore(t)
	f.getErr = &KeychainError{Op: "load", Status: -25308}
	if _, ok, err := s.Staged(); ok || err == nil {
		t.Fatalf("Staged = %v, %v; want the Keychain error", ok, err)
	}
	if err := s.PromoteStaged(); errors.Is(err, ErrNothingStaged) || err == nil {
		t.Fatalf("PromoteStaged = %v; want the Keychain error", err)
	}
}
