package db

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestGmailUpsertAndQuery covers UpsertGmailMessage/GmailMessagesSyncedAfter
// account-scoped by migration 00043 (google_accounts): gmail_messages' primary
// key is now (account_id, id), so the same message id from two different
// connected accounts must be stored as two independent rows and each
// account's sync-after query must only see its own messages.
//
// (GetGmailAuthState/SetGmailAuthState/GetGmailLastInternalDate/
// SetGmailLastInternalDate were dropped outright by Task 2 rather than
// rewritten — GetGmailAuthState had zero callers outside internal/db, and the
// watermark pair is superseded by GetGmailAccountWatermark/
// SetGmailAccountWatermark in google_accounts_test.go.)
func TestGmailUpsertAndQuery(t *testing.T) {
	d := openTestDB(t)

	acct1, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	acct2, err := d.CreateGoogleAccount(GoogleAccount{Email: "b@y.com", Label: "B"})
	require.NoError(t, err)

	msg := GmailMessage{ID: "gm1", ThreadID: "t1", FromEmail: "sender@example.com", Subject: "Hi", SyncedAt: "2026-04-01T00:00:00Z"}
	require.NoError(t, d.UpsertGmailMessage(acct1, msg))
	// Same message id under a different account is an independent row.
	require.NoError(t, d.UpsertGmailMessage(acct2, msg))

	got1, err := d.GmailMessagesSyncedAfter(acct1, "2026-03-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, got1, 1)
	assert.Equal(t, "gm1", got1[0].ID)

	got2, err := d.GmailMessagesSyncedAfter(acct2, "2026-03-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, got2, 1)

	// synced_at cutoff excludes both.
	none, err := d.GmailMessagesSyncedAfter(acct1, "2026-05-01T00:00:00Z")
	require.NoError(t, err)
	assert.Empty(t, none)
}

func TestGmailUpsertMessage_UpdatesOnConflict(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.UpsertGmailMessage(acct, GmailMessage{ID: "gm1", Subject: "Old", SyncedAt: "2026-04-01T00:00:00Z"}))
	require.NoError(t, d.UpsertGmailMessage(acct, GmailMessage{ID: "gm1", Subject: "New", SyncedAt: "2026-04-02T00:00:00Z"}))

	got, err := d.GmailMessagesSyncedAfter(acct, "2026-03-01T00:00:00Z")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "New", got[0].Subject)
}

// TestGmailWatermark covers the account-scoped Gmail sync watermark
// (GetGmailAccountWatermark/SetGmailAccountWatermark on google_accounts,
// replacing the retired workspace.gmail_last_internal_date scalar).
func TestGmailWatermark(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	ts, err := d.GetGmailAccountWatermark(acct)
	require.NoError(t, err)
	assert.Zero(t, ts)

	require.NoError(t, d.SetGmailAccountWatermark(acct, 555.5))

	ts, err = d.GetGmailAccountWatermark(acct)
	require.NoError(t, err)
	assert.Equal(t, 555.5, ts)
}

func TestGmailChannelIDHelpers(t *testing.T) {
	assert.Equal(t, "gmail:7", GmailChannelPrefix(7))
	assert.Equal(t, "gmail:7:thread-1", GmailChannelID(7, "thread-1"))
}

// gmailPurgeFixture seeds two Google accounts, each with synced mail, its own
// Gmail inbox items and a situation fed only by them, plus cross-source rows
// that must survive any per-account purge. It returns the two account ids.
func gmailPurgeFixture(t *testing.T, d *DB) (acctA, acctB int64) {
	t.Helper()

	exec := func(query string, args ...any) {
		t.Helper()
		_, err := d.Exec(query, args...)
		require.NoError(t, err)
	}

	// Relative to now: fixed dates rot once the calendar passes them.
	now := time.Now().UTC()
	syncedAt := now.Add(-time.Hour).Format(time.RFC3339)
	eventTS := now.Add(-2 * time.Hour).Format(time.RFC3339)

	acctA, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)
	acctB, err = d.CreateGoogleAccount(GoogleAccount{Email: "b@y.com", Label: "B"})
	require.NoError(t, err)

	// Watermarks that the purge must leave alone.
	require.NoError(t, d.SetGmailAccountWatermark(acctA, 111.5))
	require.NoError(t, d.SetGmailAccountWatermark(acctB, 222.5))
	exec(`UPDATE google_accounts SET memory_gmail_last_extracted_ts = ? WHERE id = ?`, 333.5, acctA)
	exec(`UPDATE google_accounts SET memory_gmail_last_extracted_ts = ? WHERE id = ?`, 444.5, acctB)
	exec(`INSERT INTO workspace (id, name, inbox_last_processed_ts, compose_last_run_ts)
		VALUES ('T1', 'ws', 100, 200)`)

	require.NoError(t, d.UpsertGmailMessage(acctA, GmailMessage{ID: "ma1", ThreadID: "ta1", Subject: "A mail", SyncedAt: syncedAt}))
	require.NoError(t, d.UpsertGmailMessage(acctB, GmailMessage{ID: "mb1", ThreadID: "tb1", Subject: "B mail", SyncedAt: syncedAt}))

	// Inbox signals: one Gmail item per account plus an unrelated Slack one.
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (1, ?, 'ma1', 'sender@example.com', 'email_received')`, GmailChannelID(acctA, "ta1"))
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (2, ?, 'mb1', 'sender@example.com', 'email_received')`, GmailChannelID(acctB, "tb1"))
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (3, 'C1', '1.1', 'U1', 'mention')`)
	exec(`INSERT INTO inbox_feedback (inbox_item_id, rating, created_at) VALUES (1, 1, ?)`, eventTS)

	// Learned rules: one per account's Gmail channel, one keyed to a Slack
	// channel and one keyed to a sender identity.
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', ?, -1.0, 'user_rule', ?)`, "channel:"+GmailChannelID(acctA, "ta1"), eventTS)
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', ?, -1.0, 'user_rule', ?)`, "channel:"+GmailChannelID(acctB, "tb1"), eventTS)
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:C1', -1.0, 'user_rule', ?)`, eventTS)
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'sender:sender@example.com', -1.0, 'user_rule', ?)`, eventTS)

	// Situation 10: only account A's mail. 11: only account B's. 12: A's mail
	// plus a Slack signal, so it survives A's purge. 13: no signals at all —
	// a target_update situation composed from "tgt:" material.
	exec(`INSERT INTO situations (id, title) VALUES (10, 'A only')`)
	exec(`INSERT INTO situations (id, title) VALUES (11, 'B only')`)
	exec(`INSERT INTO situations (id, title) VALUES (12, 'A plus slack')`)
	exec(`INSERT INTO situations (id, title, kind) VALUES (13, 'target update', 'target_update')`)
	exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (10, 1)`)
	exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (11, 2)`)
	exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (12, 1)`)
	exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (12, 3)`)
	for _, sid := range []string{"10", "11", "12", "13"} {
		exec(`INSERT INTO feed_items (item_type, source_id, event_ts) VALUES ('situation', ?, ?)`, sid, eventTS)
	}

	return acctA, acctB
}

// gmailPurgeCount runs a scalar COUNT(*) query.
func gmailPurgeCount(t *testing.T, d *DB, query string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(query, args...).Scan(&n))
	return n
}

// gmailPurgeWatermarks reads every watermark ClearGmailData must preserve:
// both accounts' Gmail sync and memory-extraction watermarks plus the shared
// inbox/composer ones.
func gmailPurgeWatermarks(t *testing.T, d *DB) []float64 {
	t.Helper()
	out := make([]float64, 0, 6)
	rows, err := d.Query(`SELECT gmail_last_internal_date, memory_gmail_last_extracted_ts
		FROM google_accounts ORDER BY id`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var sync, mem float64
		require.NoError(t, rows.Scan(&sync, &mem))
		out = append(out, sync, mem)
	}
	require.NoError(t, rows.Err())

	var inboxTS, composeTS float64
	require.NoError(t, d.QueryRow(`SELECT inbox_last_processed_ts, compose_last_run_ts FROM workspace`).
		Scan(&inboxTS, &composeTS))
	return append(out, inboxTS, composeTS)
}

// TestClearGmailData_IsolatedToOneAccount is the core guard: purging account A
// removes A's mail, A's inbox signals and the situations they alone fed, while
// account B's rows and every non-Gmail row stay exactly as they were.
func TestClearGmailData_IsolatedToOneAccount(t *testing.T) {
	d := openTestDB(t)
	acctA, acctB := gmailPurgeFixture(t, d)

	require.NoError(t, d.ClearGmailData(acctA))

	// Account A's Gmail data is gone.
	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages WHERE account_id = ?`, acctA))
	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`, GmailChannelID(acctA, "ta1")))
	// inbox_feedback on the deleted signal cascades away with it.
	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_feedback`))

	// Account B is completely untouched.
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages WHERE account_id = ?`, acctB))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`, GmailChannelID(acctB, "tb1")))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations WHERE id = 11`))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM feed_items WHERE source_id = '11'`))

	// The Slack signal survives.
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = 'C1'`))
}

// TestClearGmailData_LearnedRules: a rule scoped to the purged account's own
// Gmail channel goes with it — it names one thread of one account and can
// never match again. Rules scoped to another account's channel, to a Slack
// channel, or to a sender identity all survive.
func TestClearGmailData_LearnedRules(t *testing.T) {
	d := openTestDB(t)
	acctA, acctB := gmailPurgeFixture(t, d)

	require.NoError(t, d.ClearGmailData(acctA))

	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = ?`,
		"channel:"+GmailChannelID(acctA, "ta1")))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = ?`,
		"channel:"+GmailChannelID(acctB, "tb1")))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = 'channel:C1'`))
	assert.Equal(t, 1, gmailPurgeCount(t, d,
		`SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = 'sender:sender@example.com'`))
}

// TestClearGmailData_OrphanedSituations: a situation left with no signals is
// swept together with its feed row, but one still holding a non-Gmail signal
// survives — and so does a signal-less situation the purge never touched,
// which the composer legitimately mints from target/track material.
func TestClearGmailData_OrphanedSituations(t *testing.T) {
	d := openTestDB(t)
	acctA, _ := gmailPurgeFixture(t, d)

	require.NoError(t, d.ClearGmailData(acctA))

	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations WHERE id = 10`))
	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM feed_items WHERE source_id = '10'`))

	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations WHERE id = 12`))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM feed_items WHERE source_id = '12'`))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situation_signals WHERE situation_id = 12`))

	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations WHERE id = 13`))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM feed_items WHERE source_id = '13'`))
}

// TestClearGmailData_PreservesWatermarks guards the design decision: no
// watermark moves, so a later sync neither re-downloads the deleted mail nor
// re-extracts memory against an emptied table, and the shared inbox/composer
// watermarks keep serving Slack, Jira and calendar.
func TestClearGmailData_PreservesWatermarks(t *testing.T) {
	d := openTestDB(t)
	acctA, _ := gmailPurgeFixture(t, d)

	before := gmailPurgeWatermarks(t, d)
	require.NoError(t, d.ClearGmailData(acctA))
	assert.Equal(t, before, gmailPurgeWatermarks(t, d))
	assert.Equal(t, []float64{111.5, 333.5, 222.5, 444.5, 100, 200}, before)
}

// TestClearGmailData_AccountIDIsNotAPrefixMatch: account 1's channel ids must
// not sweep account 11's. The purge filters on "gmail:<id>:" including the
// trailing colon, so the shorter id is never a prefix of the longer one.
func TestClearGmailData_AccountIDIsNotAPrefixMatch(t *testing.T) {
	d := openTestDB(t)

	exec := func(query string, args ...any) {
		t.Helper()
		_, err := d.Exec(query, args...)
		require.NoError(t, err)
	}
	syncedAt := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)

	// Explicit ids: CreateGoogleAccount autoincrements, and this needs one id
	// to be a decimal prefix of the other.
	exec(`INSERT INTO google_accounts (id, email) VALUES (1, 'one@x.com')`)
	exec(`INSERT INTO google_accounts (id, email) VALUES (11, 'eleven@x.com')`)
	require.NoError(t, d.UpsertGmailMessage(1, GmailMessage{ID: "m1", ThreadID: "t1", SyncedAt: syncedAt}))
	require.NoError(t, d.UpsertGmailMessage(11, GmailMessage{ID: "m11", ThreadID: "t11", SyncedAt: syncedAt}))
	exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (?, 'm1', 's@x.com', 'email_received')`, GmailChannelID(1, "t1"))
	exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (?, 'm11', 's@x.com', 'email_received')`, GmailChannelID(11, "t11"))
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', ?, -1.0, 'user_rule', datetime('now'))`, "channel:"+GmailChannelID(11, "t11"))

	require.NoError(t, d.ClearGmailData(1))

	assert.Zero(t, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`, GmailChannelID(1, "t1")))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`, GmailChannelID(11, "t11")))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages WHERE account_id = 11`))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = ?`,
		"channel:"+GmailChannelID(11, "t11")))
}

// TestClearGmailData_Degenerate: purging an account that has no Gmail rows is
// a clean no-op, and purging the same account twice changes nothing the second
// time.
func TestClearGmailData_Degenerate(t *testing.T) {
	d := openTestDB(t)
	acctA, acctB := gmailPurgeFixture(t, d)

	empty, err := d.CreateGoogleAccount(GoogleAccount{Email: "c@z.com", Label: "C"})
	require.NoError(t, err)
	require.NoError(t, d.ClearGmailData(empty))
	assert.Equal(t, 2, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages`))
	assert.Equal(t, 3, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items`))
	assert.Equal(t, 4, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations`))

	require.NoError(t, d.ClearGmailData(acctA))
	after := gmailPurgeWatermarks(t, d)
	messages := gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages`)
	items := gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items`)
	situations := gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations`)

	require.NoError(t, d.ClearGmailData(acctA))
	assert.Equal(t, messages, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages`))
	assert.Equal(t, items, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM inbox_items`))
	assert.Equal(t, situations, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM situations`))
	assert.Equal(t, after, gmailPurgeWatermarks(t, d))
	assert.Equal(t, 1, gmailPurgeCount(t, d, `SELECT COUNT(*) FROM gmail_messages WHERE account_id = ?`, acctB))
}

func TestGetGmailBodyByID(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@x.com", Label: "A"})
	require.NoError(t, err)

	require.NoError(t, d.UpsertGmailMessage(acct, GmailMessage{ID: "gm1", BodyText: "hello world", SyncedAt: "2026-04-01T00:00:00Z"}))

	body, err := d.GetGmailBodyByID("gm1")
	require.NoError(t, err)
	assert.Equal(t, "hello world", body)

	// Missing row is not an error.
	body, err = d.GetGmailBodyByID("nonexistent")
	require.NoError(t, err)
	assert.Empty(t, body)
}
