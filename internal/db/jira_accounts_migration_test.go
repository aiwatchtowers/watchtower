package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

func TestMigration00049JiraAccounts(t *testing.T) {
	d := OpenTestDB(t)

	assertTableExists(t, d, "jira_accounts")

	if _, err := d.Exec(`INSERT INTO jira_accounts (cloud_id, site_url, site_name, label)
		VALUES ('cloud-1', 'https://one.atlassian.net', 'One', 'Work')`); err != nil {
		t.Fatalf("insert jira account: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO jira_accounts (cloud_id, site_url, site_name)
		VALUES ('cloud-2', 'https://two.atlassian.net', 'Two')`); err != nil {
		t.Fatalf("insert second jira account: %v", err)
	}

	// Composite PKs: the same raw board id / issue key / sprint id under two
	// different accounts must both insert.
	for _, q := range []string{
		`INSERT INTO jira_boards (account_id, id, name) VALUES (1, 7, 'Board A')`,
		`INSERT INTO jira_boards (account_id, id, name) VALUES (2, 7, 'Board B')`,
		`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
			VALUES (1, 'OPS-1', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01')`,
		`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
			VALUES (2, 'OPS-1', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01')`,
		`INSERT INTO jira_sprints (account_id, id, board_id, name, state) VALUES (1, 3, 7, 'S1', 'active')`,
		`INSERT INTO jira_sprints (account_id, id, board_id, name, state) VALUES (2, 3, 7, 'S1', 'active')`,
		`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at) VALUES (1, 'OPS', '2026-01-01')`,
		`INSERT INTO jira_sync_state (account_id, project_key, last_synced_at) VALUES (2, 'OPS', '2026-02-02')`,
		`INSERT INTO jira_releases (account_id, id, project_key, name) VALUES (1, 5, 'OPS', 'v1')`,
		`INSERT INTO jira_releases (account_id, id, project_key, name) VALUES (2, 5, 'OPS', 'v1')`,
		`INSERT INTO jira_custom_fields (account_id, id, name, field_type) VALUES (1, 'customfield_10001', 'Epic Link', 'string')`,
		`INSERT INTO jira_custom_fields (account_id, id, name, field_type) VALUES (2, 'customfield_10001', 'Epic Link', 'string')`,
	} {
		if _, err := d.Exec(q); err != nil {
			t.Fatalf("same raw id under a second account must not collide: %v\n%s", err, q)
		}
	}

	// The same (account_id, key) pair DOES collide.
	if _, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES (1, 'OPS-1', 'OPS', 'dup', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01')`); err == nil {
		t.Fatal("duplicate (account_id, key) must be rejected")
	}

	// workspace.memory_jira_last_extracted_ts is gone (moved to jira_accounts).
	if _, err := d.Exec(`UPDATE workspace SET memory_jira_last_extracted_ts = 1`); err == nil {
		t.Fatal("workspace.memory_jira_last_extracted_ts should be dropped")
	}
}

func TestMigration00049_FreshDBHasNoSeedRow(t *testing.T) {
	d := OpenTestDB(t)
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM jira_accounts`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("fresh DB must have no jira_accounts seed row, got %d", n)
	}
}

// TestMigration00049_UpgradesLegacySingleAccount replays goose up to 00048 on
// a raw connection, seeds the pre-00049 legacy shape (un-scoped Jira boards,
// issues, sprints, sync state, releases plus the workspace memory watermark),
// then applies 00049 and asserts the in-place migration: one jira_accounts
// row minted (empty cloud_id — ensureLegacyJiraAccount fills it from config),
// the watermark carried onto the row, every jira table re-parented to
// account_id = 1, and the unscoped tables (jira_user_map, jira_slack_links)
// untouched.
func TestMigration00049_UpgradesLegacySingleAccount(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("migrate to v48: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO workspace (id, name, memory_jira_last_extracted_ts)
		VALUES ('T1', 'Team One', 1234.5)`); err != nil {
		t.Fatalf("seed workspace: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_boards (id, name, project_key) VALUES (7, 'Board', 'OPS')`); err != nil {
		t.Fatalf("seed jira_boards: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_issues (key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES ('OPS-1', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01')`); err != nil {
		t.Fatalf("seed jira_issues: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_sprints (id, board_id, name, state) VALUES (3, 7, 'S1', 'active')`); err != nil {
		t.Fatalf("seed jira_sprints: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_sync_state (project_key, last_synced_at) VALUES ('OPS', '2026-01-01')`); err != nil {
		t.Fatalf("seed jira_sync_state: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_releases (id, project_key, name) VALUES (5, 'OPS', 'v1')`); err != nil {
		t.Fatalf("seed jira_releases: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_user_map (jira_account_id, slack_user_id) VALUES ('acc-1', '1:U1')`); err != nil {
		t.Fatalf("seed jira_user_map: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_slack_links (issue_key, channel_id, message_ts) VALUES ('OPS-1', '1:C1', '1.0')`); err != nil {
		t.Fatalf("seed jira_slack_links: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 49); err != nil {
		t.Fatalf("apply 00049: %v", err)
	}

	var accountCount int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM jira_accounts`).Scan(&accountCount); err != nil {
		t.Fatalf("count jira_accounts: %v", err)
	}
	if accountCount != 1 {
		t.Fatalf("jira_accounts count = %d, want 1", accountCount)
	}
	var watermark float64
	if err := raw.QueryRow(`SELECT memory_jira_last_extracted_ts FROM jira_accounts WHERE id = 1`).Scan(&watermark); err != nil {
		t.Fatalf("read jira_accounts watermark: %v", err)
	}
	if watermark != 1234.5 {
		t.Errorf("jira_accounts.memory_jira_last_extracted_ts = %v, want 1234.5", watermark)
	}

	for _, check := range []struct{ table, where string }{
		{"jira_boards", "id = 7"},
		{"jira_issues", "key = 'OPS-1'"},
		{"jira_sprints", "id = 3"},
		{"jira_sync_state", "project_key = 'OPS'"},
		{"jira_releases", "id = 5"},
	} {
		var acct int64
		if err := raw.QueryRow(`SELECT account_id FROM ` + check.table + ` WHERE ` + check.where).Scan(&acct); err != nil {
			t.Fatalf("read %s.account_id: %v", check.table, err)
		}
		if acct != 1 {
			t.Errorf("%s.account_id = %d, want 1", check.table, acct)
		}
	}

	// Unscoped tables survive byte-identical.
	var slackUserID string
	if err := raw.QueryRow(`SELECT slack_user_id FROM jira_user_map WHERE jira_account_id = 'acc-1'`).Scan(&slackUserID); err != nil {
		t.Fatalf("read jira_user_map: %v", err)
	}
	if slackUserID != "1:U1" {
		t.Errorf("jira_user_map.slack_user_id = %q, want 1:U1", slackUserID)
	}
	var linkKey string
	if err := raw.QueryRow(`SELECT issue_key FROM jira_slack_links WHERE message_ts = '1.0'`).Scan(&linkKey); err != nil {
		t.Fatalf("read jira_slack_links: %v", err)
	}
	if linkKey != "OPS-1" {
		t.Errorf("jira_slack_links.issue_key = %q, want OPS-1 (unscoped, untouched)", linkKey)
	}
}

// TestMigration00049DownUpCycle seeds the legacy shape at 00048, applies
// 00049, walks its own Down back to 00048 and asserts the single-PK shape
// with account #1's rows and the restored workspace watermark, then re-applies
// Up and asserts re-scoping — the migration must round-trip.
func TestMigration00049DownUpCycle(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("migrate to v48: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO workspace (id, name, memory_jira_last_extracted_ts)
		VALUES ('T1', 'Team One', 42)`); err != nil {
		t.Fatalf("seed workspace: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO jira_issues (key, project_key, summary, status, status_category, created_at, updated_at, synced_at)
		VALUES ('OPS-1', 'OPS', 's', 'Open', 'To Do', '2026-01-01', '2026-01-01', '2026-01-01')`); err != nil {
		t.Fatalf("seed jira_issues: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 49); err != nil {
		t.Fatalf("apply 00049: %v", err)
	}
	if err := goose.DownTo(raw, "migrations", 48); err != nil {
		t.Fatalf("goose down to 48: %v", err)
	}

	var key string
	if err := raw.QueryRow(`SELECT key FROM jira_issues WHERE key = 'OPS-1'`).Scan(&key); err != nil {
		t.Fatalf("read jira_issues after down: %v", err)
	}
	var watermark float64
	if err := raw.QueryRow(`SELECT memory_jira_last_extracted_ts FROM workspace`).Scan(&watermark); err != nil {
		t.Fatalf("read workspace watermark after down: %v", err)
	}
	if watermark != 42 {
		t.Errorf("workspace.memory_jira_last_extracted_ts after down = %v, want 42", watermark)
	}

	if err := goose.UpTo(raw, "migrations", 49); err != nil {
		t.Fatalf("re-apply 00049: %v", err)
	}
	var acct int64
	if err := raw.QueryRow(`SELECT account_id FROM jira_issues WHERE key = 'OPS-1'`).Scan(&acct); err != nil {
		t.Fatalf("read jira_issues.account_id after re-up: %v", err)
	}
	if acct != 1 {
		t.Errorf("jira_issues.account_id after re-up = %d, want 1", acct)
	}
}
