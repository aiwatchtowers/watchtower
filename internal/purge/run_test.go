package purge

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"watchtower/internal/db"
)

func openPurgeDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func execAll(t *testing.T, d *db.DB, stmts ...string) {
	t.Helper()
	for _, q := range stmts {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
}

func scheduledRow(t *testing.T, d *db.DB, source string, id int64) db.AccountPurge {
	t.Helper()
	if _, err := d.ScheduleAccountPurge(source, id, ReasonRevoked, ts(t0)); err != nil {
		t.Fatal(err)
	}
	rows, err := d.ListAccountPurges(true)
	if err != nil || len(rows) != 1 {
		t.Fatalf("open rows: %+v %v", rows, err)
	}
	return rows[0]
}

func TestPurge02_RunFinishesPurged(t *testing.T) {
	cases := []struct {
		source string
		seed   []string
		tokens []string
		check  string
		rows   int64
	}{
		{"slack", []string{
			`INSERT INTO slack_accounts (id, team_id, status) VALUES (1, 'T1', 'revoked')`,
			`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1.0', '1:U1', 'hi'), ('1:C1', '2.0', '1:U1', 'hi')`,
		}, []string{"slack_token_1.json"}, `SELECT status, enabled FROM slack_accounts WHERE id = 1`, 2},
		{"google", []string{
			`INSERT INTO google_accounts (id, email, status, gmail_enabled, calendar_enabled) VALUES (1, 'a@example.com', 'revoked', 1, 1)`,
			`INSERT INTO gmail_messages (account_id, id, thread_id, internal_date) VALUES (1, 'm1', 't1', 1), (1, 'm2', 't1', 2)`,
		}, []string{"google_token_1.json", "google_credentials_1.json"}, `SELECT status, gmail_enabled + calendar_enabled FROM google_accounts WHERE id = 1`,
			3}, // two messages and the knowledge mark their delete trigger left
		{"jira", []string{
			`INSERT INTO jira_accounts (id, cloud_id, status) VALUES (1, 'c1', 'revoked')`,
			`INSERT INTO jira_boards (account_id, id, name) VALUES (1, 7, 'A'), (1, 8, 'B')`,
		}, []string{"jira_token_1.json"}, `SELECT status, enabled FROM jira_accounts WHERE id = 1`, 2},
		{"linear", []string{
			`INSERT INTO linear_accounts (id, org_id, status) VALUES (1, 'o1', 'revoked')`,
			`INSERT INTO linear_teams (account_id, id, key, name) VALUES (1, 't1', 'ENG', 'Eng'), (1, 't2', 'OPS', 'Ops')`,
		}, []string{"linear_token_1.json"}, `SELECT status, enabled FROM linear_accounts WHERE id = 1`, 2},
	}
	for _, c := range cases {
		t.Run(c.source, func(t *testing.T) {
			d := openPurgeDB(t)
			execAll(t, d, c.seed...)
			dir := t.TempDir()
			for _, name := range c.tokens {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(`{}`), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			p := scheduledRow(t, d, c.source, 1)
			done, err := Run(context.Background(), d, dir, p, time.Minute)
			if err != nil || !done {
				t.Fatalf("Run = %v, %v", done, err)
			}
			var status string
			var enabled int
			if err := d.QueryRow(c.check).Scan(&status, &enabled); err != nil {
				t.Fatal(err)
			}
			if status != "purged" || enabled != 0 {
				t.Fatalf("account after purge: %s enabled=%d", status, enabled)
			}
			for _, name := range c.tokens {
				if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
					t.Errorf("%s still on disk (%v)", name, err)
				}
			}
			all, err := d.ListAccountPurges(false)
			if err != nil || len(all) != 1 || all[0].State != "done" || all[0].RowsDeleted != c.rows || all[0].FinishedAt == "" {
				t.Fatalf("ledger: %+v %v", all, err)
			}
		})
	}
}

func TestPurge02_BudgetStopsAndResumes(t *testing.T) {
	d := openPurgeDB(t)
	execAll(t, d, `INSERT INTO slack_accounts (id, team_id, status) VALUES (1, 'T1', 'revoked')`)
	tx, err := d.Begin()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2*ChunkRows+10; i++ {
		if _, err := tx.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', ?, '1:U1', 'x')`, fmt.Sprintf("%d.0", i)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	p := scheduledRow(t, d, "slack", 1)

	// A spent budget stops before the first chunk; the row is running.
	done, err := Run(context.Background(), d, t.TempDir(), p, 0)
	if err != nil || done {
		t.Fatalf("Run with no budget = %v, %v", done, err)
	}
	open, err := d.ListAccountPurges(true)
	if err != nil || len(open) != 1 || open[0].State != "running" {
		t.Fatalf("after a stopped run: %+v %v", open, err)
	}
	// A cancelled context stops too.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if done, err := Run(ctx, d, t.TempDir(), open[0], time.Minute); err != nil || done {
		t.Fatalf("Run with a cancelled context = %v, %v", done, err)
	}
	// The next cycle resumes the running row and finishes.
	done, err = Run(context.Background(), d, t.TempDir(), open[0], time.Minute)
	if err != nil || !done {
		t.Fatalf("resumed Run = %v, %v", done, err)
	}
	all, _ := d.ListAccountPurges(false)
	if all[0].State != "done" || all[0].RowsDeleted != int64(2*ChunkRows+10) {
		t.Fatalf("ledger after resume: %+v", all[0])
	}
}
