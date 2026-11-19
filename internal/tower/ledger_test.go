package tower

import (
	"database/sql"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tower/api"
)

// The kill tests build the database state a daemon killed at each point
// leaves behind, then resend the same request_id. Row counts prove a write
// never applies twice.

func TestLedger_KillBetweenBegunAndWrite_Guarded(t *testing.T) {
	f := newFixture(t)
	// A guarded command writes no begun row; a kill before its commit leaves
	// nothing behind, so the resend applies it once.
	r := f.call("test.guarded", write("g1", "a"))
	wantStatus(t, r, api.StatusOK)
	if f.rows() != 1 || f.ledger("g1").State != "done" {
		t.Fatalf("rows=%d ledger=%+v", f.rows(), f.ledger("g1"))
	}
}

func TestLedger_KillBetweenBegunAndWrite_NonIdempotent(t *testing.T) {
	f := newFixture(t)
	f.seed(func(tx *sql.Tx) error { return db.BeginTowerRequestTx(tx, "o1", "test.once", fixedNow) })
	wantStatus(t, f.call("test.once", write("o1", "a")), api.StatusUnknown)
	if f.rows() != 0 || f.runs["test.once"] != 0 {
		t.Fatalf("rows=%d runs=%d, want the resend not to act", f.rows(), f.runs["test.once"])
	}
}

func TestLedger_KillBetweenWriteAndReply_Guarded(t *testing.T) {
	f := newFixture(t)
	// The write and its done row committed; the reply never left.
	first := f.call("test.guarded", write("g1", "a"))
	wantStatus(t, first, api.StatusOK)
	resend := f.call("test.guarded", write("g1", "a"))
	wantStatus(t, resend, api.StatusOK)
	if string(resend.Result) != string(first.Result) || f.rows() != 1 || f.runs["test.guarded"] != 1 {
		t.Fatalf("resend %s (first %s), rows=%d runs=%d", resend.Result, first.Result, f.rows(), f.runs["test.guarded"])
	}
}

func TestLedger_KillBetweenWriteAndReply_NonIdempotent(t *testing.T) {
	t.Run("write committed, done not yet", func(t *testing.T) {
		f := newFixture(t)
		f.seed(func(tx *sql.Tx) error {
			if err := db.BeginTowerRequestTx(tx, "o1", "test.once", fixedNow); err != nil {
				return err
			}
			_, err := tx.Exec(`INSERT INTO test_rows (note) VALUES ('a')`)
			return err
		})
		wantStatus(t, f.call("test.once", write("o1", "a")), api.StatusUnknown)
		if f.rows() != 1 || f.runs["test.once"] != 0 {
			t.Fatalf("rows=%d runs=%d, want the write once", f.rows(), f.runs["test.once"])
		}
	})
	t.Run("done committed, reply lost", func(t *testing.T) {
		f := newFixture(t)
		first := f.call("test.once", write("o1", "a"))
		wantStatus(t, first, api.StatusOK)
		resend := f.call("test.once", write("o1", "a"))
		wantStatus(t, resend, api.StatusOK)
		if string(resend.Result) != string(first.Result) || f.rows() != 1 || f.runs["test.once"] != 1 {
			t.Fatalf("resend %s (first %s), rows=%d runs=%d", resend.Result, first.Result, f.rows(), f.runs["test.once"])
		}
	})
}
