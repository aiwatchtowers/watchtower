package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// InitTestTemplate migrates a throw-away in-memory database once, snapshots
// it with sqlite3_serialize, and installs openMemoryHook so that every
// subsequent Open(":memory:") call returns a clone deserialized from that
// snapshot instead of running goose from scratch.
//
// Call this from TestMain in any package whose tests make heavy use of
// db.Open(":memory:") (db.OpenTestDB included). Without it every
// Open(":memory:") runs the full goose migration suite — ~8 s each under
// -race on a loaded machine, which is what pushed the race pass on main over
// its per-package timeout.
//
// The snapshot is the migrated database byte for byte, so a clone carries
// everything a real migration leaves behind — schema, FTS5 shadow tables,
// goose version rows and every migration-seeded data row — with nothing to
// keep in sync by hand.
//
// Safe to call multiple times (second call is a no-op).
func InitTestTemplate() error {
	if openMemoryHook != nil {
		return nil // already initialised
	}
	snapshot, err := migratedSnapshot()
	if err != nil {
		return err
	}
	openMemoryHook = func() (*DB, error) {
		return cloneFromSnapshot(snapshot)
	}
	return nil
}

// serializer / deserializer are the modernc.org/sqlite driver connection's
// snapshot methods, reached through sql.Conn.Raw.
type serializer interface{ Serialize() ([]byte, error) }
type deserializer interface{ Deserialize([]byte) error }

// migratedSnapshot migrates a throw-away in-memory DB and returns its
// serialized image.
func migratedSnapshot() ([]byte, error) {
	sqlDB, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		return nil, fmt.Errorf("opening template DB: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)
	defer sqlDB.Close()

	tmpl := &DB{DB: sqlDB}
	if err := tmpl.setPragmas(); err != nil {
		return nil, fmt.Errorf("template pragmas: %w", err)
	}
	if err := tmpl.migrate(); err != nil {
		return nil, fmt.Errorf("template migrations: %w", err)
	}

	var snapshot []byte
	err = withDriverConn(sqlDB, func(dc any) error {
		s, ok := dc.(serializer)
		if !ok {
			return errors.New("sqlite driver connection does not support Serialize")
		}
		var serr error
		snapshot, serr = s.Serialize()
		return serr
	})
	if err != nil {
		return nil, fmt.Errorf("serializing template DB: %w", err)
	}
	if len(snapshot) == 0 {
		return nil, errors.New("serializing template DB: empty snapshot")
	}
	return snapshot, nil
}

// cloneFromSnapshot opens a fresh in-memory DB and loads snapshot into it.
// The pool is capped at one connection (as Open does), so the connection the
// snapshot is loaded into is the one every later query uses — an in-memory
// database is private to its connection.
func cloneFromSnapshot(snapshot []byte) (*DB, error) {
	dst, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		return nil, fmt.Errorf("opening clone DB: %w", err)
	}
	dst.SetMaxOpenConns(1)

	err = withDriverConn(dst, func(dc any) error {
		d, ok := dc.(deserializer)
		if !ok {
			return errors.New("sqlite driver connection does not support Deserialize")
		}
		return d.Deserialize(snapshot)
	})
	if err != nil {
		dst.Close()
		return nil, fmt.Errorf("deserializing clone DB: %w", err)
	}

	db := &DB{DB: dst}
	if err := db.setPragmas(); err != nil {
		dst.Close()
		return nil, fmt.Errorf("clone pragmas: %w", err)
	}
	return db, nil
}

// withDriverConn runs fn against the pool's underlying driver connection.
func withDriverConn(sqlDB *sql.DB, fn func(driverConn any) error) error {
	conn, err := sqlDB.Conn(context.Background())
	if err != nil {
		return fmt.Errorf("acquiring driver connection: %w", err)
	}
	defer func() { _ = conn.Close() }() // returns the connection to the pool
	return conn.Raw(fn)
}
