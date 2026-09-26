package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// TestMigration00073_StampsAccountsThatAlreadyUseTheFeature replays goose up
// to 00072, seeds three Slack accounts — one whose ledger holds a real
// dispatch, one whose ledger holds ONLY the `skipped` rows the enable hook
// seeds (the common upgrade shape: enabled, seeded, owner never reacted
// since), and one with no ledger rows — applies 00073 and asserts the
// backfill: both accounts with rows are stamped as seeded, the third is not.
// Any ledger row proves the feature has polled the account; a predicate on
// status alone (`dispatched`) would re-open the upgrade swallow for the
// seeded-only install. Without the backfill, an active account's first
// post-upgrade poll would treat every reaction placed since its last poll as
// history and record it `skipped` — silent loss of owner commands on upgrade.
func TestMigration00073_StampsAccountsThatAlreadyUseTheFeature(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 72); err != nil {
		t.Fatalf("migrate to v72: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO slack_accounts (id, team_id, team_name, current_user_id) VALUES
		(1, 'T1', 'active', '1:UOWNER'),
		(2, 'T2', 'fresh', '2:UOWNER'),
		(3, 'T3', 'seeded-only', '3:UOWNER')`); err != nil {
		t.Fatalf("seed accounts: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO reaction_commands (account_id, channel_id, message_ts, emoji, status, action_id, error) VALUES
		(1, '1:C1', '111.1', 'white_check_mark', 'dispatched', 7, ''),
		(3, '3:C1', '111.1', '+1', 'skipped', 0, 'seeded on enable (pre-existing reaction)')`); err != nil {
		t.Fatalf("seed ledger: %v", err)
	}

	if err := goose.UpByOne(raw, "migrations"); err != nil {
		t.Fatalf("apply 00073: %v", err)
	}

	stamp := func(id int) string {
		var s string
		if err := raw.QueryRow(`SELECT reaction_commands_seeded_at FROM slack_accounts WHERE id = ?`, id).Scan(&s); err != nil {
			t.Fatalf("read stamp for account %d: %v", id, err)
		}
		return s
	}
	if stamp(1) == "" {
		t.Errorf("account with a dispatched ledger row must be stamped as seeded by the migration")
	}
	if stamp(3) == "" {
		t.Errorf("account whose ledger holds only hook-seeded skipped rows must be stamped too")
	}
	if got := stamp(2); got != "" {
		t.Errorf("account with no ledger rows must stay unstamped, got %q", got)
	}
}
