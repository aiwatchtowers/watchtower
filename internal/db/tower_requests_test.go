package db

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"
)

func towerTx(t *testing.T, d *DB, fn func(tx *sql.Tx) error) {
	t.Helper()
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
}

func TestTowerRequests_BeginThenFinish(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	at := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)

	towerTx(t, d, func(tx *sql.Tx) error { return BeginTowerRequestTx(tx, "r1", "test.once", at) })
	got, err := d.GetTowerRequest(ctx, "r1")
	if err != nil || got == nil {
		t.Fatalf("get after begin: %v, %v", got, err)
	}
	if got.State != "begun" || got.Command != "test.once" || got.ResultJSON != "" || got.At != "2026-11-16T09:00:00Z" {
		t.Fatalf("begun row = %+v", got)
	}

	towerTx(t, d, func(tx *sql.Tx) error {
		return FinishTowerRequestTx(tx, "r1", "test.once", `{"n":1}`, at.Add(time.Minute))
	})
	got, err = d.GetTowerRequest(ctx, "r1")
	if err != nil || got == nil {
		t.Fatalf("get after finish: %v, %v", got, err)
	}
	if got.State != "done" || got.ResultJSON != `{"n":1}` || got.At != "2026-11-16T09:01:00Z" {
		t.Fatalf("done row = %+v", got)
	}

	// A second begin or finish of the same id is refused: the row is taken.
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := BeginTowerRequestTx(tx, "r1", "test.once", at); !errors.Is(err, ErrTowerRequestExists) {
		t.Fatalf("begin of a done id: %v", err)
	}
	if err := FinishTowerRequestTx(tx, "r1", "test.once", `{"n":2}`, at); !errors.Is(err, ErrTowerRequestExists) {
		t.Fatalf("finish of a done id: %v", err)
	}
	_ = tx.Rollback()

	// Finish with no begun row inserts straight to done (a guarded command).
	towerTx(t, d, func(tx *sql.Tx) error { return FinishTowerRequestTx(tx, "r2", "test.guarded", `{}`, at) })
	if got, _ := d.GetTowerRequest(ctx, "r2"); got == nil || got.State != "done" {
		t.Fatalf("guarded done row = %+v", got)
	}
	if got, err := d.GetTowerRequest(ctx, "missing"); got != nil || err != nil {
		t.Fatalf("missing id = %+v, %v", got, err)
	}
}

func TestTowerRequests_PruneDropsOldOfBothStates(t *testing.T) {
	d := openTestDB(t)
	ctx := context.Background()
	now := time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC)
	old := now.Add(-9 * 24 * time.Hour)
	fresh := now.Add(-7 * 24 * time.Hour)
	towerTx(t, d, func(tx *sql.Tx) error {
		for _, err := range []error{
			BeginTowerRequestTx(tx, "old-begun", "test.once", old),
			FinishTowerRequestTx(tx, "old-done", "test.guarded", `{}`, old),
			BeginTowerRequestTx(tx, "fresh-begun", "test.once", fresh),
			FinishTowerRequestTx(tx, "fresh-done", "test.guarded", `{}`, fresh),
		} {
			if err != nil {
				return err
			}
		}
		return nil
	})

	n, err := d.PruneTowerRequests(ctx, now.Add(-8*24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("pruned %d rows, want 2", n)
	}
	for id, want := range map[string]bool{"old-begun": false, "old-done": false, "fresh-begun": true, "fresh-done": true} {
		got, err := d.GetTowerRequest(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if (got != nil) != want {
			t.Errorf("%s present = %v, want %v", id, got != nil, want)
		}
	}
}
