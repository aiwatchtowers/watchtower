package tower

import (
	"context"
	"path/filepath"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
)

func openPruneDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func seedLedger(t *testing.T, d *db.DB, at time.Time, ids ...string) {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback() }()
	for i, id := range ids {
		var err error
		if i%2 == 0 {
			err = db.BeginTowerRequestTx(tx, id, "test.once", at)
		} else {
			err = db.FinishTowerRequestTx(tx, id, "test.guarded", `{}`, at)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func present(t *testing.T, d *db.DB, id string) bool {
	t.Helper()
	row, err := d.GetTowerRequest(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return row != nil
}

func TestPrune_HubOffDropsOldKeepsFresh(t *testing.T) {
	// Opened outside the bubble: the pool's goroutines must not belong to it.
	d := openPruneDB(t)
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		seedLedger(t, d, start.Add(-8*24*time.Hour-time.Second), "old-begun", "old-done")
		seedLedger(t, d, start.Add(-time.Hour), "fresh")
		// Ages past the window one hour after start.
		seedLedger(t, d, start.Add(-8*24*time.Hour+30*time.Minute), "ageing")

		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() {
			RunPrune(ctx, d, time.Now)
			close(done)
		}()
		synctest.Wait()
		if present(t, d, "old-begun") || present(t, d, "old-done") {
			t.Fatal("the start prune kept rows past the window")
		}
		if !present(t, d, "fresh") || !present(t, d, "ageing") {
			t.Fatal("the start prune dropped rows inside the window")
		}

		time.Sleep(PruneInterval)
		synctest.Wait()
		if present(t, d, "ageing") {
			t.Fatal("the hourly prune kept a row that aged past the window")
		}
		if !present(t, d, "fresh") {
			t.Fatal("the hourly prune dropped a fresh row")
		}
		cancel()
		<-done
	})
}

func TestPrune_UsesTheHubLedgerWindow(t *testing.T) {
	d := openPruneDB(t)
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	seedLedger(t, d, now.Add(-actions.LedgerRetention-time.Second), "past")
	seedLedger(t, d, now.Add(-actions.LedgerRetention+time.Second), "inside")
	n, err := Prune(context.Background(), d, now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 || present(t, d, "past") || !present(t, d, "inside") {
		t.Fatalf("pruned %d; past=%v inside=%v", n, present(t, d, "past"), present(t, d, "inside"))
	}
	if actions.LedgerRetention != actions.ActionMaxAge+24*time.Hour {
		t.Fatalf("LedgerRetention = %v, want ActionMaxAge plus one day", actions.LedgerRetention)
	}
}

func TestPrune_StopWaitsForTheLoop(t *testing.T) {
	d := openPruneDB(t)
	synctest.Test(t, func(t *testing.T) {
		seedLedger(t, d, time.Now().Add(-9*24*time.Hour), "old")
		stop := StartPrune(context.Background(), d, time.Now)
		synctest.Wait()
		if present(t, d, "old") {
			t.Fatal("the start prune did not run")
		}
		returned := make(chan struct{})
		go func() {
			stop()
			close(returned)
		}()
		synctest.Wait()
		select {
		case <-returned:
		default:
			t.Fatal("stop did not return after the loop ended")
		}
	})
}

func TestPrune_RunPruneReturnsOnCancel(t *testing.T) {
	d := openPruneDB(t)
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		returned := make(chan struct{})
		go func() {
			RunPrune(ctx, d, time.Now)
			close(returned)
		}()
		synctest.Wait()
		cancel()
		synctest.Wait()
		select {
		case <-returned:
		default:
			t.Fatal("RunPrune did not return after cancel")
		}
	})
}
