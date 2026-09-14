package db

import (
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"
)

// TestMigration00070_FreezesSituationsAndDropsDeadTables replays goose up to
// 00069, seeds the state the inbox demolition has to clean up — an "open"
// situation nothing writes any more, a pending decision_made item whose only
// renderer was the Dashboard, rows in the three tables only that Dashboard
// read, and the four retired prompt rows — then applies 00070 and asserts
// each is handled. The negative controls (a done situation, a pending
// mention, a live prompt) pin the UPDATEs and the DELETE to their scope
// instead of letting a blanket rewrite pass.
func TestMigration00070_FreezesSituationsAndDropsDeadTables(t *testing.T) {
	raw := openMigratedTo(t, 69)

	exec := func(query string, args ...any) {
		t.Helper()
		_, err := raw.Exec(query, args...)
		require.NoError(t, err)
	}

	// Situations: one open (must freeze), one already done (must not move).
	exec(`INSERT INTO situations (id, title, status, updated_at) VALUES (1, 'open one', 'open', '2026-09-01T00:00:00Z')`)
	exec(`INSERT INTO situations (id, title, status, updated_at) VALUES (2, 'done one', 'done', '2026-09-01T00:00:00Z')`)

	// Inbox items: a pending decision_made (must resolve), a pending mention
	// (must stay pending — the demolition keeps trigger detection alive).
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, status)
		VALUES (1, 'memory', 'dispute:bel_x', 'watchtower', 'decision_made', 'pending')`)
	exec(`INSERT INTO inbox_items (id, channel_id, message_ts, sender_user_id, trigger_type, status)
		VALUES (2, '1:C1', '1.1', '1:U1', 'mention', 'pending')`)

	// Rows in the tables about to be dropped, so the DROP is not a no-op.
	exec(`INSERT INTO inbox_feedback (inbox_item_id, rating, created_at) VALUES (2, 1, '2026-09-01T00:00:00Z')`)
	exec(`INSERT INTO feed_items (item_type, source_id, event_ts) VALUES ('situation', '1', '2026-09-01T00:00:00Z')`)

	// Prompts: the four retired ids plus a live control.
	for _, id := range []string{"inbox.triage", "inbox.compose", "inbox.situation_card", "inbox.situation_learn", "digest.channel"} {
		exec(`INSERT INTO prompts (id, template) VALUES (?, 'x')`, id)
	}

	require.NoError(t, goose.UpTo(raw, "migrations", 70))

	for _, tbl := range []string{"inbox_feedback", "feed_items", "feed_state"} {
		var n int
		require.NoError(t, raw.QueryRow(
			`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, tbl).Scan(&n))
		assert.Zero(t, n, "%s must be dropped", tbl)
	}

	var openCount int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM situations WHERE status='open'`).Scan(&openCount))
	assert.Zero(t, openCount, "no situation may stay open once the composer is gone")

	var frozen, untouched string
	require.NoError(t, raw.QueryRow(`SELECT status FROM situations WHERE id = 1`).Scan(&frozen))
	assert.Equal(t, "stale", frozen)
	require.NoError(t, raw.QueryRow(`SELECT status FROM situations WHERE id = 2`).Scan(&untouched))
	assert.Equal(t, "done", untouched, "a terminal situation must not be rewritten")

	var decisionStatus, mentionStatus string
	require.NoError(t, raw.QueryRow(`SELECT status FROM inbox_items WHERE id = 1`).Scan(&decisionStatus))
	assert.Equal(t, "resolved", decisionStatus)
	require.NoError(t, raw.QueryRow(`SELECT status FROM inbox_items WHERE id = 2`).Scan(&mentionStatus))
	assert.Equal(t, "pending", mentionStatus, "trigger items keep feeding Catch-Up")

	var retired int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM prompts
		WHERE id IN ('inbox.triage','inbox.compose','inbox.situation_card','inbox.situation_learn')`).Scan(&retired))
	assert.Zero(t, retired, "the retired prompt rows must be deregistered")

	var live int
	require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM prompts WHERE id = 'digest.channel'`).Scan(&live))
	assert.Equal(t, 1, live, "the DELETE must be scoped to the retired ids")
}
