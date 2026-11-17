package tower

import (
	"context"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// readBusy is how long a read on the tower's read handle waits for another
// process's lock (a WAL read takes none except during recovery).
const readBusy = 5 * time.Second

// readConns is how many reads the read handle runs at once: the socket's
// Inbox and screens, and the hub's phone feed, side by side.
const readConns = 4

// OpenReads opens the tower's read handle (Options.ReadDB): a read-only
// handle (db.OpenExisting, query_only) of its own on d's file, so a
// Spec.Read command — inbox.feed for the Mac's socket and for the hub's
// phone feed, tower.hello, tower.ping — never queues behind the daemon's
// one-connection pool (the sync cycle, automations, the plan poll, the hub
// and every tower write share that pool). Only those reads use it; the change
// watch opens its own (watch.go). An in-memory d has no file: an error.
// The caller closes it after the socket and the hub have stopped.
func OpenReads(ctx context.Context, d *db.DB) (*db.DB, error) {
	path, err := mainFile(ctx, d)
	if err != nil {
		return nil, fmt.Errorf("tower read handle: %w", err)
	}
	r, err := db.OpenExisting(path, readBusy)
	if err != nil {
		return nil, fmt.Errorf("tower read handle: %w", err)
	}
	r.SetMaxOpenConns(readConns)
	// Daemon-lived, as the daemon's own handle (KeepConnectionWarm there): a
	// read never pays a fresh connection's key setup — every connection
	// stays idle in the pool (database/sql keeps only 2 by default) and
	// never idle-closes.
	r.SetMaxIdleConns(readConns)
	r.KeepConnectionWarm()
	return r, nil
}
