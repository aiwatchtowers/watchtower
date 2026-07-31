package db

import (
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

// TestMigration00043GoogleAccounts covers the schema half: table exists,
// singletons gone, new columns present, workspace watermark columns dropped.
func TestMigration00043GoogleAccounts(t *testing.T) {
	d := OpenTestDB(t)

	assertTableExists(t, d, "google_accounts")
	assertTableGone(t, d, "gmail_auth_state")
	assertTableGone(t, d, "calendar_auth_state")

	// gmail_messages carries account_id in a composite PK.
	if _, err := d.Exec(`INSERT INTO google_accounts (email, label) VALUES ('a@x.com', 'A')`); err != nil {
		t.Fatalf("insert google account: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id) VALUES (1, 'm1', 'th1')`); err != nil {
		t.Fatalf("insert gmail message: %v", err)
	}
	// Same message id under a second account must NOT conflict.
	if _, err := d.Exec(`INSERT INTO google_accounts (email, label) VALUES ('b@y.com', 'B')`); err != nil {
		t.Fatalf("insert second account: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id) VALUES (2, 'm1', 'th1')`); err != nil {
		t.Fatalf("same message id under second account should insert: %v", err)
	}

	// calendar_calendars.account_id and calendar_events.ical_uid columns exist.
	if _, err := d.Exec(`INSERT INTO calendar_calendars (id, name, account_id) VALUES ('cal1', 'Cal', 1)`); err != nil {
		t.Fatalf("calendar_calendars.account_id: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO calendar_events (id, calendar_id, start_time, end_time, ical_uid)
	                     VALUES ('e1', 'cal1', '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z', 'uid1')`); err != nil {
		t.Fatalf("calendar_events.ical_uid: %v", err)
	}

	// Workspace watermark columns are gone.
	if _, err := d.Exec(`UPDATE workspace SET gmail_last_internal_date = 1`); err == nil {
		t.Fatal("workspace.gmail_last_internal_date should be dropped")
	}
	if _, err := d.Exec(`UPDATE workspace SET memory_gmail_last_extracted_ts = 1`); err == nil {
		t.Fatal("workspace.memory_gmail_last_extracted_ts should be dropped")
	}

	// Deleting an account cascades its gmail messages.
	if _, err := d.Exec(`DELETE FROM google_accounts WHERE id = 2`); err != nil {
		t.Fatalf("delete account: %v", err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM gmail_messages WHERE account_id = 2`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("cascade delete failed: n=%d err=%v", n, err)
	}
}

// TestMigration00043_FreshDBHasNoSeedRow: a brand-new install has no legacy
// Gmail/Calendar data, so the seed INSERT in 00043 must not mint an account.
func TestMigration00043_FreshDBHasNoSeedRow(t *testing.T) {
	d := OpenTestDB(t)
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM google_accounts`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("fresh DB must have no google_accounts seed row, got %d", n)
	}
}

// TestMigration00043_UpgradesLegacySingleAccount replays goose up to 00042 on
// a raw connection, seeds the pre-00043 legacy shape (single Gmail/Calendar
// account, a bare-thread Gmail inbox item, and a matching learned rule scope),
// then applies 00043 and asserts the in-place data migration: one
// google_accounts row minted with the copied watermark and gmail_enabled=1,
// gmail_messages re-keyed under account_id=1, and the inbox_items/
// inbox_learned_rules channel ids rewritten to the account-scoped
// 'gmail:1:<thread>' form.
func TestMigration00043_UpgradesLegacySingleAccount(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 42); err != nil {
		t.Fatalf("migrate to v42: %v", err)
	}

	seedLegacySingleAccountFixture(t, raw)

	if err := goose.UpByOne(raw, "migrations"); err != nil {
		t.Fatalf("apply 00043: %v", err)
	}

	assertUpgradedSingleAccountFixture(t, raw)
}

// seedLegacySingleAccountFixture seeds the pre-00043 legacy shape: a
// workspace row carrying the Gmail watermarks that 00043 must copy onto the
// minted account, a bare-thread Gmail message, and matching inbox_items /
// inbox_learned_rules rows still keyed by the un-rewritten thread id.
func seedLegacySingleAccountFixture(t *testing.T, raw *sql.DB) {
	t.Helper()
	if _, err := raw.Exec(`INSERT INTO workspace (id, name, gmail_last_internal_date, memory_gmail_last_extracted_ts)
		VALUES ('T1', 'test', 12345.0, 6789.0)`); err != nil {
		t.Fatalf("seed workspace: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO gmail_messages (id, thread_id) VALUES ('m1', 'th1')`); err != nil {
		t.Fatalf("seed gmail_messages: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES ('th1', '1.0', 'U1', 'email_received')`); err != nil {
		t.Fatalf("seed inbox_items: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:th1', 1.0, 'user_rule', '2026-07-30T00:00:00Z')`); err != nil {
		t.Fatalf("seed inbox_learned_rules: %v", err)
	}
}

// assertUpgradedSingleAccountFixture asserts 00043's in-place data
// migration of the seedLegacySingleAccountFixture shape: one google_accounts
// row minted with the copied watermark and gmail_enabled=1, gmail_messages
// re-keyed under account_id=1, and the inbox_items/inbox_learned_rules
// channel ids rewritten to the account-scoped 'gmail:1:<thread>' form.
func assertUpgradedSingleAccountFixture(t *testing.T, raw *sql.DB) {
	t.Helper()
	var accountCount int
	var gmailEnabled int
	var watermark, extractedTS float64
	if err := raw.QueryRow(`SELECT COUNT(*) FROM google_accounts`).Scan(&accountCount); err != nil {
		t.Fatalf("count google_accounts: %v", err)
	}
	if accountCount != 1 {
		t.Fatalf("google_accounts count = %d, want 1", accountCount)
	}
	if err := raw.QueryRow(`SELECT gmail_enabled, gmail_last_internal_date, memory_gmail_last_extracted_ts
		FROM google_accounts WHERE id = 1`).Scan(&gmailEnabled, &watermark, &extractedTS); err != nil {
		t.Fatalf("read google_accounts: %v", err)
	}
	if gmailEnabled != 1 {
		t.Errorf("gmail_enabled = %d, want 1", gmailEnabled)
	}
	if watermark != 12345.0 {
		t.Errorf("gmail_last_internal_date = %v, want 12345.0", watermark)
	}
	if extractedTS != 6789.0 {
		t.Errorf("memory_gmail_last_extracted_ts = %v, want 6789.0", extractedTS)
	}

	var msgAccountID int
	if err := raw.QueryRow(`SELECT account_id FROM gmail_messages WHERE id = 'm1'`).Scan(&msgAccountID); err != nil {
		t.Fatalf("read gmail_messages.account_id: %v", err)
	}
	if msgAccountID != 1 {
		t.Errorf("gmail_messages.account_id = %d, want 1", msgAccountID)
	}

	var channelID string
	if err := raw.QueryRow(`SELECT channel_id FROM inbox_items WHERE trigger_type = 'email_received'`).Scan(&channelID); err != nil {
		t.Fatalf("read inbox_items.channel_id: %v", err)
	}
	if channelID != "gmail:1:th1" {
		t.Errorf("inbox_items.channel_id = %q, want gmail:1:th1", channelID)
	}

	var scopeKey string
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE source = 'user_rule'`).Scan(&scopeKey); err != nil {
		t.Fatalf("read inbox_learned_rules.scope_key: %v", err)
	}
	if scopeKey != "channel:gmail:1:th1" {
		t.Errorf("inbox_learned_rules.scope_key = %q, want channel:gmail:1:th1", scopeKey)
	}
}

// TestMigration00043DownUpCycle: 00043's Down restores the pre-migration
// shape byte-for-byte (precedent: TestMemoryPhase5Slice1MigrationDownUpCycle
// and its siblings), so a down;up cycle on a seeded post-00043 database is
// clean. This also covers the Down-block gap the reviewer flagged: Down
// recreates calendar_auth_state but must reseed its default row exactly like
// it already does for gmail_auth_state — asserted directly below.
func TestMigration00043DownUpCycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "google-accounts-cycle.db")
	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	seedPostMigrationFixture(t, d)

	// DownTo (not a single-step Down): later migrations stack on top of
	// 00043, and this test asserts the legacy shape 00043's own Down
	// restores — so roll back everything down to 00042 explicitly.
	if err := goose.DownTo(d.DB, "migrations", 42); err != nil {
		t.Fatalf("goose down: %v", err)
	}
	assertDownMigrationRestoredLegacyShape(t, d)

	if err := goose.Up(d.DB, "migrations"); err != nil {
		t.Fatalf("goose up after down: %v", err)
	}
	assertUpMigrationReappliedShape(t, d)
}

// seedPostMigrationFixture seeds the post-00043 shape: one account, a gmail
// message and a calendar scoped to it, and Gmail-derived inbox rows already
// in the rewritten gmail:1:<thread> form.
func seedPostMigrationFixture(t *testing.T, d *DB) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO google_accounts (id, email, label, gmail_last_internal_date, memory_gmail_last_extracted_ts)
		VALUES (1, 'a@x.com', 'A', 555.0, 777.0)`); err != nil {
		t.Fatalf("seed google_accounts: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id) VALUES (1, 'm1', 'th1')`); err != nil {
		t.Fatalf("seed gmail_messages: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO calendar_calendars (id, name, account_id) VALUES ('cal1', 'Cal', 1)`); err != nil {
		t.Fatalf("seed calendar_calendars: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES ('gmail:1:th1', '1.0', 'U1', 'email_received')`); err != nil {
		t.Fatalf("seed inbox_items: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:gmail:1:th1', 1.0, 'user_rule', '2026-07-30T00:00:00Z')`); err != nil {
		t.Fatalf("seed inbox_learned_rules: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'Test')`); err != nil {
		t.Fatalf("seed workspace: %v", err)
	}
}

// assertDownMigrationRestoredLegacyShape asserts 00043's Down restores the
// pre-migration shape byte-for-byte: channel id / scope key un-rewritten,
// watermarks restored onto workspace, and calendar_auth_state recreated
// with its default row (the gap the reviewer flagged: Down previously
// recreated the table but never reseeded it, unlike gmail_auth_state).
func assertDownMigrationRestoredLegacyShape(t *testing.T, d *DB) {
	t.Helper()
	var channelID string
	if err := d.QueryRow(`SELECT channel_id FROM inbox_items WHERE trigger_type = 'email_received'`).Scan(&channelID); err != nil {
		t.Fatalf("read inbox_items.channel_id after down: %v", err)
	}
	if channelID != "th1" {
		t.Errorf("channel_id after down = %q, want th1", channelID)
	}
	var scopeKey string
	if err := d.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE source = 'user_rule'`).Scan(&scopeKey); err != nil {
		t.Fatalf("read scope_key after down: %v", err)
	}
	if scopeKey != "channel:th1" {
		t.Errorf("scope_key after down = %q, want channel:th1", scopeKey)
	}
	var gmailTS, extractedTS float64
	if err := d.QueryRow(`SELECT gmail_last_internal_date, memory_gmail_last_extracted_ts FROM workspace WHERE id = 'T1'`).Scan(&gmailTS, &extractedTS); err != nil {
		t.Fatalf("read workspace watermarks after down: %v", err)
	}
	if gmailTS != 555.0 || extractedTS != 777.0 {
		t.Errorf("workspace watermarks after down = (%v, %v), want (555, 777)", gmailTS, extractedTS)
	}
	var authStatus string
	if err := d.QueryRow(`SELECT status FROM calendar_auth_state WHERE id = 1`).Scan(&authStatus); err != nil {
		t.Fatalf("calendar_auth_state row missing after down: %v", err)
	}
	if authStatus != "ok" {
		t.Errorf("calendar_auth_state.status = %q, want ok", authStatus)
	}
	assertTableGone(t, d, "google_accounts")
}

// assertUpMigrationReappliedShape asserts that re-applying 00043 after Down
// restores the re-migrated shape.
func assertUpMigrationReappliedShape(t *testing.T, d *DB) {
	t.Helper()
	assertTableExists(t, d, "google_accounts")
	assertTableGone(t, d, "calendar_auth_state")
	assertTableGone(t, d, "gmail_auth_state")
	var accountCount int
	if err := d.QueryRow(`SELECT COUNT(*) FROM google_accounts`).Scan(&accountCount); err != nil {
		t.Fatalf("count google_accounts after re-up: %v", err)
	}
	if accountCount != 1 {
		t.Fatalf("google_accounts count after re-up = %d, want 1", accountCount)
	}
}
