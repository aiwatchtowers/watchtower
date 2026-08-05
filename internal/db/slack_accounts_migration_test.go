package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite"
)

func TestMigration00048SlackAccounts(t *testing.T) {
	d := OpenTestDB(t)

	assertTableExists(t, d, "slack_accounts")

	if _, err := d.Exec(`INSERT INTO slack_accounts (team_id, team_name, team_domain, label, current_user_id)
		VALUES ('T1', 'Team One', 'team-one', 'Team One', '1:U0001')`); err != nil {
		t.Fatalf("insert slack account: %v", err)
	}
	var id int64
	if err := d.QueryRow(`SELECT id FROM slack_accounts WHERE team_id = 'T1'`).Scan(&id); err != nil || id == 0 {
		t.Fatalf("expected autoincrement id, got %d err=%v", id, err)
	}

	// Namespaced channel/user ids are just TEXT — no PK type change, but
	// two different accounts can now own colliding raw Slack ids.
	if _, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C001', 'general', 'public')`); err != nil {
		t.Fatalf("insert channel: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C001', 'general', 'public')`); err != nil {
		t.Fatalf("same raw id under a second account must not collide: %v", err)
	}

	// workspace.current_user_id / search_last_date are gone.
	if _, err := d.Exec(`UPDATE workspace SET current_user_id = 'x'`); err == nil {
		t.Fatal("workspace.current_user_id should be dropped")
	}
	if _, err := d.Exec(`UPDATE workspace SET search_last_date = 'x'`); err == nil {
		t.Fatal("workspace.search_last_date should be dropped")
	}
}

func TestMigration00048_FreshDBHasNoSeedRow(t *testing.T) {
	d := OpenTestDB(t)
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM slack_accounts`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("fresh DB must have no slack_accounts seed row, got %d", n)
	}
}

// TestMigration00048_UpgradesLegacySingleAccount replays goose up to 00043
// on a raw connection, seeds the pre-00048 legacy shape (single-workspace
// Slack data with bare, un-namespaced ids plus a bare-thread Gmail inbox
// item), then applies through 00048 and asserts the in-place data migration: one
// slack_accounts row minted from the workspace singleton, every Slack-
// derived id column rewritten to the "1:<rawID>" namespaced form, and the
// unrelated Gmail-scoped inbox row left untouched by the "1:" rewrite.
func TestMigration00048_UpgradesLegacySingleAccount(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 43); err != nil {
		t.Fatalf("migrate to v43: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO workspace (id, name, current_user_id, search_last_date)
		VALUES ('T1', 'Team One', 'U1', '2026-07-30')`); err != nil {
		t.Fatalf("seed workspace: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`); err != nil {
		t.Fatalf("seed channels: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO users (id, name) VALUES ('U1', 'Alice')`); err != nil {
		t.Fatalf("seed users: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1.0', 'U1', 'hi')`); err != nil {
		t.Fatalf("seed messages: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES ('C1', '1.0', 'U1', 'mention')`); err != nil {
		t.Fatalf("seed inbox_items (mention): %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:C1', 1.0, 'user_rule', '2026-07-30T00:00:00Z')`); err != nil {
		t.Fatalf("seed inbox_learned_rules: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES ('gmail:1:th1', '2.0', 'someone@x.com', 'email_received')`); err != nil {
		t.Fatalf("seed inbox_items (gmail): %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("apply through 00048: %v", err)
	}

	var accountCount int
	if err := raw.QueryRow(`SELECT COUNT(*) FROM slack_accounts`).Scan(&accountCount); err != nil {
		t.Fatalf("count slack_accounts: %v", err)
	}
	if accountCount != 1 {
		t.Fatalf("slack_accounts count = %d, want 1", accountCount)
	}
	var currentUserID, searchLastDate string
	if err := raw.QueryRow(`SELECT current_user_id, search_last_date FROM slack_accounts WHERE id = 1`).
		Scan(&currentUserID, &searchLastDate); err != nil {
		t.Fatalf("read slack_accounts: %v", err)
	}
	if currentUserID != "1:U1" {
		t.Errorf("slack_accounts.current_user_id = %q, want 1:U1", currentUserID)
	}
	if searchLastDate != "2026-07-30" {
		t.Errorf("slack_accounts.search_last_date = %q, want 2026-07-30", searchLastDate)
	}

	var channelID string
	if err := raw.QueryRow(`SELECT id FROM channels WHERE name = 'general'`).Scan(&channelID); err != nil {
		t.Fatalf("read channels.id: %v", err)
	}
	if channelID != "1:C1" {
		t.Errorf("channels.id = %q, want 1:C1", channelID)
	}

	var msgChannelID, msgUserID string
	if err := raw.QueryRow(`SELECT channel_id, user_id FROM messages WHERE ts = '1.0'`).Scan(&msgChannelID, &msgUserID); err != nil {
		t.Fatalf("read messages: %v", err)
	}
	if msgChannelID != "1:C1" {
		t.Errorf("messages.channel_id = %q, want 1:C1", msgChannelID)
	}
	if msgUserID != "1:U1" {
		t.Errorf("messages.user_id = %q, want 1:U1", msgUserID)
	}

	var mentionChannelID string
	if err := raw.QueryRow(`SELECT channel_id FROM inbox_items WHERE trigger_type = 'mention'`).Scan(&mentionChannelID); err != nil {
		t.Fatalf("read inbox_items.channel_id (mention): %v", err)
	}
	if mentionChannelID != "1:C1" {
		t.Errorf("inbox_items.channel_id (mention) = %q, want 1:C1", mentionChannelID)
	}

	var scopeKey string
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE source = 'user_rule'`).Scan(&scopeKey); err != nil {
		t.Fatalf("read inbox_learned_rules.scope_key: %v", err)
	}
	if scopeKey != "channel:1:C1" {
		t.Errorf("inbox_learned_rules.scope_key = %q, want channel:1:C1", scopeKey)
	}

	var gmailChannelID string
	if err := raw.QueryRow(`SELECT channel_id FROM inbox_items WHERE trigger_type = 'email_received'`).Scan(&gmailChannelID); err != nil {
		t.Fatalf("read inbox_items.channel_id (gmail): %v", err)
	}
	if gmailChannelID != "gmail:1:th1" {
		t.Errorf("inbox_items.channel_id (gmail) = %q, want unchanged gmail:1:th1, the '1:' rewrite guard failed", gmailChannelID)
	}
}

// TestMigration00048_PreservesSearchOverExistingMessages replays goose up to
// 00043, inserts a message (populating messages_fts via the messages_ai
// trigger, which only fires on INSERT/text-or-is_deleted-UPDATE — never on
// the id-only rewrite migration 00048 performs), then applies through 00048
// and asserts the search join (messages.channel_id = messages_fts.channel_id)
// still matches. Without 00048 also rewriting messages_fts directly, this
// join silently returns zero rows for every message synced before the
// upgrade — full-text search over all pre-migration history breaks.
func TestMigration00048_PreservesSearchOverExistingMessages(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 43); err != nil {
		t.Fatalf("migrate to v43: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`); err != nil {
		t.Fatalf("seed channels: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO users (id, name) VALUES ('U1', 'Alice')`); err != nil {
		t.Fatalf("seed users: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1.0', 'U1', 'searchable content')`); err != nil {
		t.Fatalf("seed messages (fires messages_ai trigger): %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("apply through 00048: %v", err)
	}

	var text string
	err = raw.QueryRow(`
		SELECT m.text FROM messages_fts fts
		JOIN messages m ON m.channel_id = fts.channel_id AND m.ts = fts.ts
		WHERE messages_fts MATCH 'searchable'`).Scan(&text)
	if err != nil {
		t.Fatalf("search join found no match after migration (messages_fts left stale): %v", err)
	}
	if text != "searchable content" {
		t.Errorf("matched text = %q, want %q", text, "searchable content")
	}
}

// TestMigration00048_PreservesGmailJiraSenderLearnedRules replays goose up to
// 00043, seeds bare (un-namespaced) sender: scope_key rules sourced from
// Gmail (a raw email address) and Jira (a bare issue key) alongside a real
// Slack sender: rule, then applies through 00048 and asserts only the Slack
// rule gets the "1:" prefix — the Gmail/Jira rules must stay exactly as they
// were, or a previously-taught mute/boost preference silently stops matching.
func TestMigration00048_PreservesGmailJiraSenderLearnedRules(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 43); err != nil {
		t.Fatalf("migrate to v43: %v", err)
	}

	seed := func(scopeKey string) {
		if _, err := raw.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
			VALUES ('source_mute', ?, -1.0, 'user_rule', '2026-07-30T00:00:00Z')`, scopeKey); err != nil {
			t.Fatalf("seed inbox_learned_rules %q: %v", scopeKey, err)
		}
	}
	seed("sender:U1")                  // Slack — must get namespaced
	seed("sender:someone@example.com") // Gmail — must NOT get namespaced
	seed("sender:PROJ-123")            // Jira — must NOT get namespaced
	seed("sender:watchtower")          // watchtower detector — must NOT get namespaced

	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("apply through 00048: %v", err)
	}

	rows, err := raw.Query(`SELECT scope_key FROM inbox_learned_rules WHERE rule_type = 'source_mute' ORDER BY id`)
	if err != nil {
		t.Fatalf("query scope_keys: %v", err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var scopeKey string
		if err := rows.Scan(&scopeKey); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got = append(got, scopeKey)
	}
	want := []string{"sender:1:U1", "sender:someone@example.com", "sender:PROJ-123", "sender:watchtower"}
	if len(got) != len(want) {
		t.Fatalf("scope_keys = %v, want %v", got, want)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("scope_keys[%d] = %q, want %q", i, got[i], w)
		}
	}
}

// TestMigration00048DownUpCycle replays goose up to 00043 on a raw
// connection, seeds bare (pre-namespacing) inbox_learned_rules scope_key
// rows, applies through 00048 (asserting the namespaced form), then applies 00048's
// own Down block and asserts the ORIGINAL bare scope_key is restored
// exactly — the substr off-by-one in the Down block (substr(scope_key, 9)
// for "sender:1:" and substr(scope_key, 10) for "channel:1:", each one
// short of past the second colon) produced 'sender::U1'/'channel::C1'
// instead of 'sender:U1'/'channel:C1' and slipped through because no
// existing test exercised 00048's own Down path with a plain (non-gmail)
// scope_key. Then re-applies Up and asserts re-namespacing.
func TestMigration00048DownUpCycle(t *testing.T) {
	raw, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer raw.Close()
	raw.SetMaxOpenConns(1)
	if _, err := raw.Exec("PRAGMA foreign_keys=ON"); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(raw, "migrations", 43); err != nil {
		t.Fatalf("migrate to v43: %v", err)
	}

	if _, err := raw.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'sender:U1', 1.0, 'user_rule', '2026-07-30T00:00:00Z')`); err != nil {
		t.Fatalf("seed sender scope_key: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:C1', 1.0, 'user_rule', '2026-07-30T00:00:00Z')`); err != nil {
		t.Fatalf("seed channel scope_key: %v", err)
	}

	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("apply through 00048: %v", err)
	}

	var senderKey, channelKey string
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE scope_key LIKE 'sender:%'`).Scan(&senderKey); err != nil {
		t.Fatalf("read sender scope_key after up: %v", err)
	}
	if senderKey != "sender:1:U1" {
		t.Fatalf("sender scope_key after up = %q, want sender:1:U1", senderKey)
	}
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE scope_key LIKE 'channel:%'`).Scan(&channelKey); err != nil {
		t.Fatalf("read channel scope_key after up: %v", err)
	}
	if channelKey != "channel:1:C1" {
		t.Fatalf("channel scope_key after up = %q, want channel:1:C1", channelKey)
	}

	if err := goose.DownTo(raw, "migrations", 43); err != nil {
		t.Fatalf("goose down to 43: %v", err)
	}

	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE scope_key LIKE 'sender:%'`).Scan(&senderKey); err != nil {
		t.Fatalf("read sender scope_key after down: %v", err)
	}
	if senderKey != "sender:U1" {
		t.Errorf("sender scope_key after down = %q, want sender:U1 (original bare form)", senderKey)
	}
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE scope_key LIKE 'channel:%'`).Scan(&channelKey); err != nil {
		t.Fatalf("read channel scope_key after down: %v", err)
	}
	if channelKey != "channel:C1" {
		t.Errorf("channel scope_key after down = %q, want channel:C1 (original bare form)", channelKey)
	}

	if err := goose.UpTo(raw, "migrations", 48); err != nil {
		t.Fatalf("re-apply through 00048: %v", err)
	}
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE scope_key LIKE 'sender:%'`).Scan(&senderKey); err != nil {
		t.Fatalf("read sender scope_key after re-up: %v", err)
	}
	if senderKey != "sender:1:U1" {
		t.Errorf("sender scope_key after re-up = %q, want sender:1:U1", senderKey)
	}
	if err := raw.QueryRow(`SELECT scope_key FROM inbox_learned_rules WHERE scope_key LIKE 'channel:%'`).Scan(&channelKey); err != nil {
		t.Fatalf("read channel scope_key after re-up: %v", err)
	}
	if channelKey != "channel:1:C1" {
		t.Errorf("channel scope_key after re-up = %q, want channel:1:C1", channelKey)
	}
}
