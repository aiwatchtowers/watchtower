package db

import (
	"database/sql"
	"testing"

	_ "modernc.org/sqlite"
)

// TestMigration00148_BackfillsAccessClocks replays goose to 00147, seeds
// accounts in every status, applies 00148 and checks that every clock starts
// at the upgrade: each account (removed ones too — they take part in the
// lease, ask #477) gets access_ok_at, only a revoked one gets revoked_at.
func TestMigration00148_BackfillsAccessClocks(t *testing.T) {
	t.Parallel()
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if err := gooseUpTo(raw, "migrations", 147); err != nil {
		t.Fatalf("migrate to v147: %v", err)
	}
	for _, q := range []string{
		`INSERT INTO slack_accounts (id, team_id, status) VALUES (1, 'T1', 'ok'), (2, 'T2', 'removed'), (3, 'T3', 'revoked')`,
		`INSERT INTO google_accounts (id, email, status) VALUES (1, 'a@example.com', 'revoked')`,
		`INSERT INTO jira_accounts (id, cloud_id, status) VALUES (1, 'c1', 'error')`,
		`INSERT INTO linear_accounts (id, org_id, status) VALUES (1, 'o1', 'removed')`,
	} {
		if _, err := raw.Exec(q); err != nil {
			t.Fatalf("seed: %v\n%s", err, q)
		}
	}
	if err := gooseUpTo(raw, "migrations", 148); err != nil {
		t.Fatalf("apply 00148: %v", err)
	}
	cases := []struct {
		table       string
		id          int64
		wantRevoked bool
	}{
		{"slack_accounts", 1, false},
		{"slack_accounts", 2, false},
		{"slack_accounts", 3, true},
		{"google_accounts", 1, true},
		{"jira_accounts", 1, false},
		{"linear_accounts", 1, false},
	}
	for _, c := range cases {
		var okAt, revokedAt string
		// table names come from the fixed list above
		if err := raw.QueryRow(`SELECT access_ok_at, revoked_at FROM `+c.table+` WHERE id = ?`, c.id).Scan(&okAt, &revokedAt); err != nil {
			t.Fatalf("%s %d: %v", c.table, c.id, err)
		}
		if okAt == "" {
			t.Errorf("%s %d: access_ok_at empty, want the upgrade time", c.table, c.id)
		}
		if (revokedAt != "") != c.wantRevoked {
			t.Errorf("%s %d: revoked_at = %q, want set=%v", c.table, c.id, revokedAt, c.wantRevoked)
		}
	}
}

func TestMigration00148_OneOpenPurgePerAccount(t *testing.T) {
	d := OpenTestDB(t)
	ins := `INSERT INTO account_purges (source, account_id, reason, due_at, state) VALUES ('slack', 1, 'revoked', '2026-01-01T00:00:00Z', ?)`
	if _, err := d.Exec(ins, "scheduled"); err != nil {
		t.Fatalf("first scheduled row: %v", err)
	}
	if _, err := d.Exec(ins, "running"); err == nil {
		t.Fatal("a second open row for one account must be refused")
	}
	if _, err := d.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at) VALUES ('jira', 1, 'lease', '2026-01-01T00:00:00Z')`); err != nil {
		t.Fatalf("same id under another source must insert: %v", err)
	}
	if _, err := d.Exec(`UPDATE account_purges SET state = 'done' WHERE source = 'slack'`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Exec(ins, "scheduled"); err != nil {
		t.Fatalf("a new row after done must insert: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO account_purges (source, account_id, reason, due_at) VALUES ('imap', 1, 'lease', 'x')`); err == nil {
		t.Fatal("unknown source must be refused by the CHECK")
	}
}
