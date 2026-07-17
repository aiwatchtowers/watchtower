package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestClearSlackData(t *testing.T) {
	db := openTestDB(t)

	exec := func(query string, args ...any) {
		t.Helper()
		_, err := db.Exec(query, args...)
		require.NoError(t, err)
	}

	// Raw Slack data.
	exec(`INSERT INTO workspace (id, name, synced_at, search_last_date, inbox_last_processed_ts, compose_last_run_ts, gmail_last_internal_date)
		VALUES ('T1', 'ws', '2026-07-01T00:00:00Z', '2026-07-01', 100, 200, 300)`)
	exec(`INSERT INTO users (id, name) VALUES ('U1', 'alice')`)
	exec(`INSERT INTO channels (id, name, type) VALUES ('C1', 'general', 'public')`)
	exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES ('C1', '1.1', 'U1', 'hello world')`)

	// AI products on top of Slack.
	exec(`INSERT INTO digests (channel_id, period_from, period_to, type, summary) VALUES ('C1', 1, 2, 'channel', 's')`)
	exec(`INSERT INTO tracks (text, channel_ids) VALUES ('t', '["C1"]')`)

	// Learned rules: one keyed to a Slack channel, one unrelated.
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:C1', -1, 'implicit', '2026-07-01T00:00:00Z')`)
	exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'channel:JIRA-1', -1, 'user_rule', '2026-07-01T00:00:00Z')`)

	// Inbox: a Slack mention and a Jira assignment.
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (1, 'C1', '1.1', 'U1', 'mention')`)
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (2, 'JIRA-1', '', 'jira', 'jira_assigned')`)
	exec(`INSERT INTO inbox_feedback (inbox_item_id, rating, created_at) VALUES (1, 1, '2026-07-01T00:00:00Z')`)

	// Situations: one purely Slack, one still fed by the Jira signal.
	exec(`INSERT INTO situations (id, title) VALUES (10, 'slack only')`)
	exec(`INSERT INTO situations (id, title) VALUES (11, 'jira backed')`)
	exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (10, 1)`)
	exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (11, 2)`)
	exec(`INSERT INTO feed_items (item_type, source_id, event_ts) VALUES ('situation', '10', '2026-07-01T00:00:00Z')`)
	exec(`INSERT INTO feed_items (item_type, source_id, event_ts) VALUES ('situation', '11', '2026-07-01T00:00:00Z')`)

	// Data from other sources must survive.
	exec(`INSERT INTO gmail_messages (id, thread_id, subject) VALUES ('g1', 'th1', 'mail')`)
	exec(`INSERT INTO targets (text, period_start, period_end) VALUES ('my target', '2026-07-01', '2026-07-31')`)

	// A memory dispute item (channel_id='memory', trigger_type='decision_made')
	// is NOT Slack-derived and must survive a Slack disconnect.
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type)
		VALUES (3, 'memory', 'dispute:bel_x', 'watchtower', 'decision_made')`)

	require.NoError(t, db.ClearSlackData())

	count := func(query string) int {
		t.Helper()
		var n int
		require.NoError(t, db.QueryRow(query).Scan(&n))
		return n
	}

	// Slack data and products are gone.
	assert.Zero(t, count(`SELECT COUNT(*) FROM messages`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM messages_fts`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM users`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM channels`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM digests`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM tracks`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM inbox_feedback`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = 'channel:C1'`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type = 'mention'`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM situations WHERE id = 10`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM feed_items WHERE source_id = '10'`))

	// Other sources survive.
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type = 'jira_assigned'`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM situations WHERE id = 11`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM feed_items WHERE source_id = '11'`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = 'channel:JIRA-1'`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM gmail_messages`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM targets`))
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM inbox_items WHERE channel_id='memory' AND trigger_type='decision_made'`))

	// Slack watermarks reset; the Gmail watermark stays.
	var syncedAt *string
	var searchLast string
	var inboxTS, composeTS, gmailTS float64
	require.NoError(t, db.QueryRow(`SELECT synced_at, search_last_date, inbox_last_processed_ts, compose_last_run_ts, gmail_last_internal_date FROM workspace`).
		Scan(&syncedAt, &searchLast, &inboxTS, &composeTS, &gmailTS))
	assert.Nil(t, syncedAt)
	assert.Empty(t, searchLast)
	assert.Zero(t, inboxTS)
	assert.Zero(t, composeTS)
	assert.Equal(t, 300.0, gmailTS)
}
