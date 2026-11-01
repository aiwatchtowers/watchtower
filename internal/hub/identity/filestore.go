package identity

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
)

// Store keeps the hub's identity.
type Store interface {
	Load() (Identity, error)
	Save(Identity) error
}

var (
	// ErrNoIdentity: no identity is stored yet (a first start creates one).
	ErrNoIdentity = errors.New("identity: no hub identity stored")
	// ErrInsecureMode: the identity file is readable or writable by anyone
	// but its owner, or is not a regular file. It is never read then.
	ErrInsecureMode = errors.New("identity: hub identity file permissions are looser than 0600")
	// ErrNothingStaged: PromoteStaged found no complete, valid staged
	// identity. It wraps ErrNoIdentity. After a promotion that finished (or
	// crashed after writing the live identity), a repeat meets this; the
	// caller checks the live identity and its own record instead.
	ErrNothingStaged = fmt.Errorf("identity: nothing staged: %w", ErrNoIdentity)
	// errMalformed never names a byte of the file.
	errMalformed = errors.New("identity: hub identity file is malformed")
)

// FileName is the identity file's name inside the hub state dir.
const FileName = "identity.key"

// fileMagic starts the file: "WTHUBID" and format version 1. The body is the
// four 32-byte raw keys: hub_sig seed, hub_kx scalar, wrap key, relay_auth
// seed.
var fileMagic = [8]byte{'W', 'T', 'H', 'U', 'B', 'I', 'D', 1}

const fileLen = len(fileMagic) + 4*32

// FileStore keeps the identity in one 0600 file (<hub dir>/identity.key) in
// a 0700 dir: the headless host's store, and a desktop host's when
// ForDesktopHost recorded "file". A file with any group or other permission bit is refused
// with ErrInsecureMode, never read.
type FileStore struct{ Path string }

// Load reads the identity; ErrNoIdentity when the file does not exist.
func (s FileStore) Load() (Identity, error) {
	f, err := os.OpenFile(s.Path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return Identity{}, ErrNoIdentity
	case errors.Is(err, syscall.ELOOP):
		return Identity{}, ErrInsecureMode
	case err != nil:
		return Identity{}, fmt.Errorf("identity: opening the identity file: %w", err)
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return Identity{}, fmt.Errorf("identity: reading the identity file: %w", err)
	}
	if !fi.Mode().IsRegular() || fi.Mode().Perm()&0o077 != 0 {
		return Identity{}, ErrInsecureMode
	}
	// One byte more than a valid file: a longer file reads n == fileLen+1
	// and is refused as malformed instead of being silently truncated.
	var buf [fileLen + 1]byte
	defer clear(buf[:])
	n, err := io.ReadFull(f, buf[:])
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return Identity{}, fmt.Errorf("identity: reading the identity file: %w", err)
	}
	return decodeIdentity(buf[:n])
}

// encodeIdentity lays an identity out in the identity format (fileMagic,
// then the four raw keys): the identity file's bytes and the Keychain
// item's data. The caller clears the result.
func encodeIdentity(id Identity) ([]byte, error) {
	if !id.complete() {
		return nil, errors.New("identity: refusing to save an incomplete identity")
	}
	kx := id.Agreement.Bytes()
	defer clear(kx)
	buf := make([]byte, 0, fileLen)
	buf = append(buf, fileMagic[:]...)
	buf = append(buf, id.Signing.Seed()...)
	buf = append(buf, kx...)
	buf = append(buf, id.Wrap[:]...)
	buf = append(buf, id.RelayAuth.Seed()...)
	return buf, nil
}

// decodeIdentity reads the identity format; anything else (a wrong length,
// magic or version, a bad key) is errMalformed.
func decodeIdentity(buf []byte) (Identity, error) {
	if len(buf) != fileLen || [8]byte(buf[:8]) != fileMagic {
		return Identity{}, errMalformed
	}
	body := buf[len(fileMagic):fileLen]
	return fromSeeds(body[0:32], body[32:64], [32]byte(body[64:96]), body[96:128])
}

// Save writes the identity atomically (a 0600 temp file in the same dir,
// synced, renamed over the old one). The dir is created 0700, or tightened
// to 0700 when it exists looser.
func (s FileStore) Save(id Identity) (err error) {
	buf, err := encodeIdentity(id)
	if err != nil {
		return err
	}
	defer clear(buf)
	dir := filepath.Dir(s.Path)
	if err := privateDir(dir); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(dir, ".identity-*.tmp")
	if err != nil {
		return fmt.Errorf("identity: creating the identity file: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return fmt.Errorf("identity: securing the identity file: %w", err)
	}
	if _, err := tmp.Write(buf); err != nil {
		return fmt.Errorf("identity: writing the identity file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("identity: syncing the identity file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("identity: closing the identity file: %w", err)
	}
	if err := os.Rename(tmp.Name(), s.Path); err != nil {
		return fmt.Errorf("identity: placing the identity file: %w", err)
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// StagedFileName is the staged identity's file next to the live one: an
// identity handed over by the Swift hub waits there until it is adopted.
const StagedFileName = "identity.staged.key"

func (s FileStore) staged() FileStore {
	return FileStore{Path: filepath.Join(filepath.Dir(s.Path), StagedFileName)}
}

// Staged reads the staged identity; ok is false when none is staged or the
// staged file is malformed (a later SaveStaged overwrites it). The file
// follows the live one's rules (0600, else ErrInsecureMode).
func (s FileStore) Staged() (Identity, bool, error) {
	id, err := s.staged().Load()
	if errors.Is(err, ErrNoIdentity) || errors.Is(err, errMalformed) {
		return Identity{}, false, nil
	}
	if err != nil {
		return Identity{}, false, err
	}
	return id, true, nil
}

// SaveStaged writes the staged identity file (0600, atomic).
func (s FileStore) SaveStaged(id Identity) error { return s.staged().Save(id) }

// PromoteStaged makes the staged identity the live one with one rename.
// The staged file is checked first (mode, format), never promoted blind;
// ErrNothingStaged when no valid staged identity exists.
func (s FileStore) PromoteStaged() error {
	st := s.staged()
	id, ok, err := s.Staged()
	if err != nil {
		return err
	}
	if !ok {
		return ErrNothingStaged
	}
	id.Zero()
	if err := os.Rename(st.Path, s.Path); err != nil {
		return fmt.Errorf("identity: promoting the staged identity: %w", err)
	}
	if d, err := os.Open(filepath.Dir(s.Path)); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// DeleteStaged removes the staged identity file; a missing file is not an
// error.
func (s FileStore) DeleteStaged() error {
	if err := os.Remove(s.staged().Path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("identity: removing the staged identity: %w", err)
	}
	return nil
}

// privateDir creates dir 0700, or tightens an existing one to 0700.
func privateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("identity: creating the hub dir: %w", err)
	}
	fi, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("identity: reading the hub dir: %w", err)
	}
	if !fi.IsDir() {
		return errors.New("identity: hub dir is not a directory")
	}
	if fi.Mode().Perm() != 0o700 {
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("identity: tightening the hub dir: %w", err)
		}
	}
	return nil
}
