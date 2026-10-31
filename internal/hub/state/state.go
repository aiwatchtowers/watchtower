// Package state owns hubstate.db, the Go hub's sidecar database: linked
// phones, epochs, the exactly-once relay ledger, the control queue, held
// actions and transport tokens. Its schema starts from the Swift hub's file
// (00001, so an adopted Swift sidecar applies too) and is its own goose
// provider, never watchtower.db's. The Store is the file's only writer:
// Desktop reads it read-only, and the CLI writes only while it holds the hub
// lock (lock.go), so two writers never meet. Open does not take the hub
// lock: the caller (the hub runtime, or the CLI writing directly) holds it.
// Device ids are stored canonical uppercase (Swift uuidString): every writer
// that keys on a device id upper-cases it, and readers also match NOCASE, as
// the Swift hub does.
package state

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/db"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// FileName is the sidecar's file name inside the hub state dir.
const FileName = "hubstate.db"

// Store is a handle on <dir>/hubstate.db.
type Store struct{ db *sql.DB }

// Open opens (creating and migrating if needed) <dir>/hubstate.db. The dir
// is created 0700, or tightened to 0700 when it exists looser; the file is
// 0600 and plaintext (no SQLCipher key), like the Swift hub's GRDB file.
func Open(dir string) (*Store, error) {
	if err := ensurePrivateDir(dir); err != nil {
		return nil, err
	}
	migrations, err := fs.Sub(migrationsFS, "migrations")
	if err != nil {
		return nil, err
	}
	d, err := db.OpenSidecar(filepath.Join(dir, FileName), migrations)
	if err != nil {
		return nil, fmt.Errorf("opening the hub state: %w", err)
	}
	return &Store{db: d}, nil
}

// OpenReadOnly opens an existing <dir>/hubstate.db for reading only (the
// CLI's `hub phones` beside a running hub): no dir or file is created, no
// migration runs, and a statement that writes fails (query_only). A dir with
// no sidecar yet returns an error wrapping fs.ErrNotExist.
func OpenReadOnly(dir string) (*Store, error) {
	path := filepath.Join(dir, FileName)
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("opening the hub state: %w", err)
	}
	d, err := db.OpenExisting(path, 2*time.Second)
	if err != nil {
		return nil, fmt.Errorf("opening the hub state: %w", err)
	}
	return &Store{db: d.DB}, nil
}

// ensurePrivateDir creates dir 0700, or tightens an existing one to 0700.
func ensurePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("creating the hub state dir: %w", err)
	}
	fi, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("reading the hub state dir: %w", err)
	}
	if !fi.IsDir() {
		return errors.New("hub state dir is not a directory")
	}
	if fi.Mode().Perm() != 0o700 {
		if err := os.Chmod(dir, 0o700); err != nil {
			return fmt.Errorf("tightening the hub state dir: %w", err)
		}
	}
	return nil
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// WithTx runs fn in one write transaction (BEGIN IMMEDIATE, the sidecar
// DSN's _txlock), committed when fn returns nil and rolled back otherwise.
// Keep network and handler work out of fn: it holds the write lock.
func (s *Store) WithTx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("beginning a hub state transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("committing a hub state transaction: %w", err)
	}
	return nil
}

// write runs fn in its own transaction with a background context: the
// Store's single-statement writers.
func (s *Store) write(fn func(*sql.Tx) error) error {
	return s.WithTx(context.Background(), fn)
}

// Times are stored as the Swift hub stores them: REAL seconds since 1970.

func toReal(t time.Time) float64 { return float64(t.UnixNano()) / 1e9 }

func fromReal(f float64) time.Time {
	sec, frac := math.Modf(f)
	return time.Unix(int64(sec), int64(math.Round(frac*1e9))).UTC()
}

// u64 refuses a value SQLite's signed INTEGER cannot hold.
func u64(v uint64) (int64, error) {
	if v > math.MaxInt64 {
		return 0, fmt.Errorf("value %d does not fit the sidecar", v)
	}
	return int64(v), nil
}

// deviceKey is a device id in its stored form: canonical uppercase.
func deviceKey(id string) string { return strings.ToUpper(id) }
