package purge

import (
	"context"
	"errors"
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
	// Due an hour ago in real time: Run re-plans the account against now.
	if _, err := d.ScheduleAccountPurge(source, id, ReasonRevoked, ts(time.Now().Add(-time.Hour))); err != nil {
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

// Review #601: the plan is a snapshot. A reconnect between Plan and Run
// must stop the purge before its first delete: Run re-plans the one account
// and starts only a row that is still scheduled and still due.
func TestRun_ReconnectBetweenPlanAndRun(t *testing.T) {
	d := openPurgeDB(t)
	execAll(t, d,
		`INSERT INTO linear_accounts (id, org_id, status, revoked_at) VALUES (1, 'o1', 'revoked', '2026-10-01T00:00:00Z')`,
		`INSERT INTO linear_teams (account_id, id, key, name) VALUES (1, 't1', 'ENG', 'Eng')`,
	)
	if _, err := d.ScheduleAccountPurge("linear", 1, ReasonRevoked, ts(time.Now().Add(-time.Hour))); err != nil {
		t.Fatal(err)
	}
	plan, err := Apply(d, true, false, time.Now())
	if err != nil || len(plan.Due) != 1 {
		t.Fatalf("due rows = %+v, %v", plan.Due, err)
	}
	if err := d.SetLinearAccountAuthState(1, "ok", ""); err != nil { // the reconnect
		t.Fatal(err)
	}
	done, err := Run(context.Background(), d, t.TempDir(), plan.Due[0], time.Minute)
	if done || !errors.Is(err, ErrNoLongerDue) {
		t.Fatalf("Run = %v, %v; want ErrNoLongerDue", done, err)
	}
	var teams int
	if err := d.QueryRow(`SELECT COUNT(*) FROM linear_teams`).Scan(&teams); err != nil || teams != 1 {
		t.Fatalf("data must stay: %d %v", teams, err)
	}
	if rows, _ := d.ListAccountPurges(true); len(rows) != 1 || rows[0].State != "scheduled" {
		t.Fatalf("the row is left to the scheduler: %+v", rows)
	}
}

// Review #601: a row cancelled after the plan was read is never purged.
func TestRun_CancelledRowNotPurged(t *testing.T) {
	d := openPurgeDB(t)
	execAll(t, d,
		`INSERT INTO slack_accounts (id, team_id, status, revoked_at) VALUES (1, 'T1', 'revoked', '2026-10-01T00:00:00Z')`,
		`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1.0', '1:U1', 'hi')`,
	)
	p := scheduledRow(t, d, "slack", 1)
	if _, err := d.CancelAccountPurge(p.ID); err != nil {
		t.Fatal(err)
	}
	done, err := Run(context.Background(), d, t.TempDir(), p, time.Minute)
	if done || !errors.Is(err, ErrNoLongerDue) {
		t.Fatalf("Run = %v, %v", done, err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("messages = %d, %v", n, err)
	}
}

// Review #601: a Re-login while the purge runs keeps the account and its
// sign-in: the rows deleted so far stay deleted, the token file stays, the
// account is not marked purged, and the ledger row is done with a note.
func TestRun_ReloginDuringRunKeepsAccountAndTokens(t *testing.T) {
	d := openPurgeDB(t)
	execAll(t, d, `INSERT INTO jira_accounts (id, cloud_id, status) VALUES (1, 'c1', 'revoked')`,
		`INSERT INTO jira_boards (account_id, id, name) VALUES (1, 7, 'A')`)
	dir := t.TempDir()
	token := filepath.Join(dir, "jira_token_1.json")
	if err := os.WriteFile(token, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	p := scheduledRow(t, d, "jira", 1)
	// Started earlier, then the Re-login: access confirmed after the start.
	execAll(t, d, `UPDATE account_purges SET state = 'running', started_at = '2026-01-01T00:00:00Z'`)
	if err := d.SetJiraAccountAuthState(1, "ok", ""); err != nil {
		t.Fatal(err)
	}
	p.State = "running"
	done, err := Run(context.Background(), d, dir, p, time.Minute)
	if err != nil || !done {
		t.Fatalf("Run = %v, %v", done, err)
	}
	if _, err := os.Stat(token); err != nil {
		t.Fatalf("the token of a re-logged account must stay: %v", err)
	}
	var status string
	if err := d.QueryRow(`SELECT status FROM jira_accounts WHERE id = 1`).Scan(&status); err != nil || status != "ok" {
		t.Fatalf("status = %q, %v", status, err)
	}
	all, _ := d.ListAccountPurges(false)
	if all[0].State != "done" || all[0].Error == "" {
		t.Fatalf("ledger: %+v", all[0])
	}
}

// PURGE-02 (review #601): a purge that keeps failing ends in failed after
// MaxChunkFailures cycles, and the account keeps its status (not purged).
func TestPurge02_RepeatedFailureEndsFailed(t *testing.T) {
	d := openPurgeDB(t)
	execAll(t, d,
		`INSERT INTO slack_accounts (id, team_id, status, revoked_at) VALUES (1, 'T1', 'revoked', '2026-10-01T00:00:00Z')`,
		`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('1:C1', '1.0', '1:U1', 'hi')`,
		`CREATE TRIGGER fail_delete BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT, 'disk says no'); END`,
	)
	p := scheduledRow(t, d, "slack", 1)
	for i := 1; i <= MaxChunkFailures; i++ {
		if done, err := Run(context.Background(), d, t.TempDir(), p, time.Minute); err == nil || done {
			t.Fatalf("cycle %d: Run = %v, %v", i, done, err)
		}
		p.State = "running"
	}
	all, err := d.ListAccountPurges(false)
	if err != nil || all[0].State != "failed" || all[0].Error == "" || all[0].FinishedAt == "" {
		t.Fatalf("ledger after %d failures: %+v %v", MaxChunkFailures, all, err)
	}
	var status string
	if err := d.QueryRow(`SELECT status FROM slack_accounts WHERE id = 1`).Scan(&status); err != nil || status != "revoked" {
		t.Fatalf("status = %q, %v", status, err)
	}
}

// PURGE-02 (review #601): a token file that cannot be deleted fails the
// purge before it is marked done — the account is not reported purged while
// its sign-in is still on disk — and the next cycle retries.
func TestRun_TokenDeleteFailureKeepsRunning(t *testing.T) {
	d := openPurgeDB(t)
	execAll(t, d, `INSERT INTO slack_accounts (id, team_id, status) VALUES (1, 'T1', 'revoked')`)
	dir := t.TempDir()
	// A non-empty directory where the token file should be: Remove fails.
	stuck := filepath.Join(dir, "slack_token_1.json")
	if err := os.MkdirAll(filepath.Join(stuck, "x"), 0o700); err != nil {
		t.Fatal(err)
	}
	p := scheduledRow(t, d, "slack", 1)
	done, err := Run(context.Background(), d, dir, p, time.Minute)
	if err == nil || done {
		t.Fatalf("Run = %v, %v; want the token error", done, err)
	}
	open, _ := d.ListAccountPurges(true)
	if len(open) != 1 || open[0].State != "running" || open[0].Error == "" {
		t.Fatalf("ledger: %+v", open)
	}
	var status string
	if err := d.QueryRow(`SELECT status FROM slack_accounts WHERE id = 1`).Scan(&status); err != nil || status != "revoked" {
		t.Fatalf("status = %q, %v", status, err)
	}
	// Fixed: the next cycle finishes.
	if err := os.RemoveAll(stuck); err != nil {
		t.Fatal(err)
	}
	if done, err := Run(context.Background(), d, dir, open[0], time.Minute); err != nil || !done {
		t.Fatalf("retry = %v, %v", done, err)
	}
}

// Review #601: an access proof landing after start's re-plan but before
// StartAccountPurge (a reconnect for a revoked row, a clean pass for a lease
// row) leaves the row scheduled and deletes nothing.
func TestRun_AccessBetweenReplanAndStart(t *testing.T) {
	old := ts(time.Now().Add(-40 * 24 * time.Hour))
	cases := []struct {
		name, reason string
		seed         string
		access       func(d *db.DB) error
	}{
		{"revoked reconnect", ReasonRevoked,
			`INSERT INTO linear_accounts (id, org_id, status, revoked_at) VALUES (1, 'o1', 'revoked', '2026-10-01T00:00:00Z')`,
			func(d *db.DB) error { return d.SetLinearAccountAuthState(1, "ok", "") }},
		{"revoked clean pass", ReasonRevoked,
			`INSERT INTO linear_accounts (id, org_id, status, revoked_at) VALUES (1, 'o1', 'revoked', '2026-10-01T00:00:00Z')`,
			func(d *db.DB) error { return d.MarkAccountAccessOK("linear", 1) }},
		{"lease clean pass", ReasonLease,
			`INSERT INTO linear_accounts (id, org_id, status, access_ok_at) VALUES (1, 'o1', 'ok', '` + old + `')`,
			func(d *db.DB) error { return d.MarkAccountAccessOK("linear", 1) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := openPurgeDB(t)
			execAll(t, d, c.seed,
				`INSERT INTO linear_teams (account_id, id, key, name) VALUES (1, 't1', 'ENG', 'Eng')`)
			if _, err := d.ScheduleAccountPurge("linear", 1, c.reason, ts(time.Now().Add(-time.Hour))); err != nil {
				t.Fatal(err)
			}
			rows, err := d.ListAccountPurges(true)
			if err != nil || len(rows) != 1 {
				t.Fatalf("open rows: %+v %v", rows, err)
			}
			afterReplan = func() {
				if err := c.access(d); err != nil {
					t.Fatal(err)
				}
			}
			t.Cleanup(func() { afterReplan = func() {} })
			done, err := Run(context.Background(), d, t.TempDir(), rows[0], time.Minute)
			if done || !errors.Is(err, ErrNoLongerDue) {
				t.Fatalf("Run = %v, %v; want ErrNoLongerDue", done, err)
			}
			var teams int
			if err := d.QueryRow(`SELECT COUNT(*) FROM linear_teams`).Scan(&teams); err != nil || teams != 1 {
				t.Fatalf("data must stay: %d %v", teams, err)
			}
			if rows, _ := d.ListAccountPurges(true); len(rows) != 1 || rows[0].State != "scheduled" {
				t.Fatalf("the row is left to the scheduler: %+v", rows)
			}
		})
	}
}
