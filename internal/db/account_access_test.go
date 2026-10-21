package db

import (
	"testing"
)

type accessRow struct {
	Status, AccessOKAt, RevokedAt string
	Enabled                       int
}

func readAccess(t *testing.T, d *DB, table string, id int64) accessRow {
	t.Helper()
	var r accessRow
	enabledCol := "enabled"
	if table == "google_accounts" {
		enabledCol = "gmail_enabled"
	}
	// table and column come from the fixed test cases
	if err := d.QueryRow(`SELECT status, access_ok_at, revoked_at, `+enabledCol+` FROM `+table+` WHERE id = ?`, id).
		Scan(&r.Status, &r.AccessOKAt, &r.RevokedAt, &r.Enabled); err != nil {
		t.Fatalf("read %s %d: %v", table, id, err)
	}
	return r
}

func setAccessAuth(d *DB, source string, id int64, status string) error {
	switch source {
	case "slack":
		return d.SetSlackAccountAuthState(id, status, "msg-"+status)
	case "google":
		return d.SetGoogleAccountAuthState(id, status, "msg-"+status)
	case "jira":
		return d.SetJiraAccountAuthState(id, status, "msg-"+status)
	default:
		return d.SetLinearAccountAuthState(id, status, "msg-"+status)
	}
}

func seedAccessAccounts(t *testing.T, d *DB) {
	t.Helper()
	for _, q := range []string{
		`INSERT INTO slack_accounts (id, team_id) VALUES (1, 'T1')`,
		`INSERT INTO google_accounts (id, email, gmail_enabled) VALUES (1, 'a@example.com', 1)`,
		`INSERT INTO jira_accounts (id, cloud_id) VALUES (1, 'c1')`,
		`INSERT INTO linear_accounts (id, org_id) VALUES (1, 'o1')`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("seed: %v", err)
		}
	}
}

var accessSources = []struct{ source, table string }{
	{"slack", "slack_accounts"}, {"google", "google_accounts"},
	{"jira", "jira_accounts"}, {"linear", "linear_accounts"},
}

func TestAuthState_AccessFacts(t *testing.T) {
	d := OpenTestDB(t)
	seedAccessAccounts(t, d)
	for _, s := range accessSources {
		t.Run(s.source, func(t *testing.T) {
			if err := setAccessAuth(d, s.source, 1, "revoked"); err != nil {
				t.Fatal(err)
			}
			first := readAccess(t, d, s.table, 1)
			if first.Status != "revoked" || first.RevokedAt == "" {
				t.Fatalf("revoked must stamp revoked_at: %+v", first)
			}
			// Make the stamp distinguishable, then repeat: kept.
			if _, err := d.Exec(`UPDATE ` + s.table + ` SET revoked_at = '2026-01-01T00:00:00Z', access_ok_at = '2026-01-01T00:00:00Z' WHERE id = 1`); err != nil {
				t.Fatal(err)
			}
			if err := setAccessAuth(d, s.source, 1, "revoked"); err != nil {
				t.Fatal(err)
			}
			if got := readAccess(t, d, s.table, 1); got.RevokedAt != "2026-01-01T00:00:00Z" {
				t.Fatalf("a repeated revoked must keep revoked_at, got %q", got.RevokedAt)
			}
			if err := setAccessAuth(d, s.source, 1, "error"); err != nil {
				t.Fatal(err)
			}
			if got := readAccess(t, d, s.table, 1); got.RevokedAt != "2026-01-01T00:00:00Z" || got.AccessOKAt != "2026-01-01T00:00:00Z" {
				t.Fatalf("error must keep both clocks: %+v", got)
			}
			if err := setAccessAuth(d, s.source, 1, "ok"); err != nil {
				t.Fatal(err)
			}
			got := readAccess(t, d, s.table, 1)
			if got.RevokedAt != "" || got.AccessOKAt == "" || got.AccessOKAt == "2026-01-01T00:00:00Z" {
				t.Fatalf("ok must clear revoked_at and stamp access_ok_at: %+v", got)
			}
		})
	}
}

func TestAuthState_MissingRowErrors(t *testing.T) {
	d := OpenTestDB(t)
	for _, s := range accessSources {
		if err := setAccessAuth(d, s.source, 99, "ok"); err == nil {
			t.Errorf("%s: missing row must error", s.source)
		}
	}
}

func TestPurge01_PurgedRowAcceptsOnlyOK(t *testing.T) {
	d := OpenTestDB(t)
	seedAccessAccounts(t, d)
	for _, s := range accessSources {
		t.Run(s.source, func(t *testing.T) {
			enabledCol := "enabled = 0"
			if s.table == "google_accounts" {
				enabledCol = "gmail_enabled = 0"
			}
			if _, err := d.Exec(`UPDATE ` + s.table + ` SET status = 'purged', error = '', ` + enabledCol + ` WHERE id = 1`); err != nil {
				t.Fatal(err)
			}
			for _, st := range []string{"error", "revoked"} {
				if err := setAccessAuth(d, s.source, 1, st); err != nil {
					t.Fatalf("a refused write over purged is not an error: %v", err)
				}
				if got := readAccess(t, d, s.table, 1); got.Status != "purged" || got.RevokedAt != "" {
					t.Fatalf("%s over purged must be refused: %+v", st, got)
				}
			}
			if err := d.MarkAccountAccessOK(s.source, 1); err != nil {
				t.Fatal(err)
			}
			// The fresh row's access_ok_at is empty; a mark on a purged row
			// must not stamp it.
			if got := readAccess(t, d, s.table, 1); got.AccessOKAt != "" {
				t.Fatalf("MarkAccountAccessOK must leave a purged row alone: %+v", got)
			}
			if err := setAccessAuth(d, s.source, 1, "ok"); err != nil {
				t.Fatal(err)
			}
			got := readAccess(t, d, s.table, 1)
			if got.Status != "ok" || got.AccessOKAt == "" {
				t.Fatalf("ok over purged must revive the row: %+v", got)
			}
			wantEnabled := 1
			if s.table == "google_accounts" {
				wantEnabled = 0 // the Google switches stay as the login path sets them
			}
			if got.Enabled != wantEnabled {
				t.Fatalf("enabled after revive = %d, want %d", got.Enabled, wantEnabled)
			}
		})
	}
}

func TestMarkAccountAccessOK(t *testing.T) {
	d := OpenTestDB(t)
	seedAccessAccounts(t, d)
	if _, err := d.Exec(`UPDATE linear_accounts SET status = 'revoked', error = 'x'`); err != nil {
		t.Fatal(err)
	}
	if err := d.MarkAccountAccessOK("linear", 1); err != nil {
		t.Fatal(err)
	}
	got := readAccess(t, d, "linear_accounts", 1)
	if got.Status != "revoked" || got.AccessOKAt == "" {
		t.Fatalf("mark must stamp access_ok_at and leave status: %+v", got)
	}
	if err := d.MarkAccountAccessOK("imap", 1); err == nil {
		t.Fatal("unknown source must error")
	}
	if err := d.MarkAccountAccessOK("jira", 42); err != nil {
		t.Fatalf("missing row is not an error: %v", err)
	}
}
