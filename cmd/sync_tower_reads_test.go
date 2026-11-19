package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tower"
	"watchtower/internal/tower/api"
	"watchtower/internal/tower/commands"
)

// towerFeedCall calls inbox.feed on its own goroutine; cancelling ctx
// unblocks a call that queued for a pool connection.
func towerFeedCall(ctx context.Context, call func(ctx context.Context, req api.Request) api.Response) <-chan api.Response {
	answers := make(chan api.Response, 1)
	go func() {
		answers <- call(ctx, api.Request{V: api.EnvelopeVersion, ID: "f1", Command: "inbox.feed", Params: json.RawMessage(`{}`)})
	}()
	return answers
}

// The daemon's inbox.feed — the Mac's Inbox and the hub's phone feed —
// answers while the daemon's one-connection pool is inside a write
// transaction (a sync cycle's), on the tower's own read handle.
func TestDaemonTower_FeedAnswersWhileTheDaemonPoolHoldsAWrite(t *testing.T) {
	database, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	var logs bytes.Buffer
	logger := log.New(&logs, "", 0)
	reads, closeReads := openTowerReads(context.Background(), database, logger)
	t.Cleanup(closeReads)
	if reads == nil {
		t.Fatalf("no read handle on a file database: %s", logs.String())
	}
	tw := newDaemonTower(t.TempDir(), database, reads, true, commands.Deps{}, logger)

	tx, err := database.Begin() // the pool's one connection, and the write lock
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'acme')`); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	answers := towerFeedCall(ctx, func(ctx context.Context, req api.Request) api.Response {
		return tw.Call(ctx, req, tower.Origin{Transport: "socket"})
	})
	for range 10_000_000 { // scheduler turns, not a clock
		select {
		case r := <-answers:
			if r.Status != api.StatusOK {
				t.Fatalf("inbox.feed: %+v", r)
			}
			return
		default:
			runtime.Gosched()
		}
	}
	cancel()
	<-answers
	t.Fatal("inbox.feed queued behind the daemon's held pool")
}

// A read handle that cannot be opened (an in-memory database has no file)
// is logged and the daemon's tower still answers its reads on the daemon's
// own pool.
func TestDaemonTower_ReadHandleFailureFallsBackToThePool(t *testing.T) {
	database, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	var logs bytes.Buffer
	logger := log.New(&logs, "", 0)
	reads, closeReads := openTowerReads(context.Background(), database, logger)
	closeReads() // a no-op without a handle
	if reads != nil {
		t.Fatal("an in-memory database: want no read handle")
	}
	if !strings.Contains(logs.String(), "tower: reads share the daemon's pool") {
		t.Fatalf("log = %q", logs.String())
	}
	tw := newDaemonTower(t.TempDir(), database, nil, true, commands.Deps{}, logger)
	r := tw.Call(context.Background(), api.Request{V: api.EnvelopeVersion, ID: "f1", Command: "inbox.feed", Params: json.RawMessage(`{}`)},
		tower.Origin{Transport: "socket"})
	if r.Status != api.StatusOK {
		t.Fatalf("inbox.feed on the pool: %+v", r)
	}
}
