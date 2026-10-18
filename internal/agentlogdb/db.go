// Package agentlogdb owns agentlog.db, the agent analytics database beside
// watchtower.db: its opener, its migrations and every agent_log_* query.
// The import writes here so it never takes watchtower.db's write lock.
package agentlogdb

import (
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"path/filepath"

	"watchtower/internal/db"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// DB is a handle on agentlog.db.
type DB struct{ *sql.DB }

// PathFor is agentlog.db's path for the watchtower.db at mainDBPath: the
// same workspace directory.
func PathFor(mainDBPath string) string {
	return filepath.Join(filepath.Dir(mainDBPath), "agentlog.db")
}

// Open opens (creating and migrating if needed) the agentlog.db at path.
func Open(path string) (*DB, error) {
	migrations, err := fs.Sub(migrationsFS, "migrations")
	if err != nil {
		return nil, err
	}
	d, err := db.OpenSidecar(path, migrations)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	return &DB{d}, nil
}

// withTx runs fn in one write transaction (BEGIN IMMEDIATE, see
// db.OpenSidecar's DSN), committed when fn returns nil.
func (d *DB) withTx(fn func(*sql.Tx) error) error {
	tx, err := d.Begin()
	if err != nil {
		return fmt.Errorf("beginning transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}
