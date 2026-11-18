package chatengine

import (
	"fmt"
	"time"

	"watchtower/internal/db"
)

// handleBusy is how long an engine statement waits for another process's
// write lock (db.Open's busy timeout).
const handleBusy = 5 * time.Second

// readPool is the engine's read connections: subscriptions, pages and
// searches read beside a running write.
const readPool = 3

// OpenHandles opens the engine's own handles on the existing database at
// dbPath, apart from the daemon's single-connection pool, so a long sync
// transaction never holds a chat turn or a feed read back: write is a
// one-connection read-write handle (OpenExistingRW: IMMEDIATE transactions,
// foreign keys on), read a query_only handle with a pool of three
// (OpenExisting). Neither migrates: the daemon opened (and migrated) the
// file first.
func OpenHandles(dbPath string) (write, read *db.DB, err error) {
	write, err = db.OpenExistingRW(dbPath, handleBusy)
	if err != nil {
		return nil, nil, fmt.Errorf("chatengine: opening the write handle: %w", err)
	}
	read, err = db.OpenExisting(dbPath, handleBusy)
	if err != nil {
		_ = write.Close()
		return nil, nil, fmt.Errorf("chatengine: opening the read handle: %w", err)
	}
	read.SetMaxOpenConns(readPool)
	return write, read, nil
}
