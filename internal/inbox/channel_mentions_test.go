package inbox

import (
	"context"
	"encoding/json"
	"log"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// pendingMentionItems returns every pending mention item with its decoded
// mentions list.
func pendingMentionItems(t *testing.T, d *db.DB) ([]db.InboxItem, [][]db.InboxMention) {
	t.Helper()
	items, err := d.GetInboxItems(db.InboxFilter{Status: "pending", TriggerType: "mention"})
	require.NoError(t, err)
	lists := make([][]db.InboxMention, len(items))
	for i, it := range items {
		require.NoError(t, json.Unmarshal([]byte(it.Mentions), &lists[i]), "mentions of item %d", it.ID)
	}
	return items, lists
}

func mentionTexts(ms []db.InboxMention) []string {
	out := make([]string, len(ms))
	for i, m := range ms {
		out[i] = m.SenderID + ": " + m.Text
	}
	return out
}

// TestInbox09_ChannelMentionsAccumulate: plain (non-thread) mentions in one
// channel fold into one pending item that keeps every one of them — in one
// cycle and across cycles — instead of the newest overwriting an older,
// unread one (board #586, owner-approved 2026-10-17 in ask #310).
func TestInbox09_ChannelMentionsAccumulate(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")

	// An older pending channel item written before the mentions column
	// existed ('[]'), already read by the owner.
	oldTS := recentTS(60 * 24 * 2)
	oldID := mustCreateInboxItem(t, d, db.InboxItem{
		ChannelID: "1:C1", MessageTS: oldTS, SenderUserID: "1:U_ALICE",
		TriggerType: "mention", Snippet: "Alice asks for the budget", Permalink: "https://example.com/alice",
	})
	_, err := d.Exec(`UPDATE inbox_items SET read_at = '2026-01-01T00:00:00Z' WHERE id = ?`, oldID)
	require.NoError(t, err)

	insertMessage(t, d, "1:C1", recentTS(30), "1:U_BOB", "<@U_ME1> can you review the deck?")
	insertMessage(t, d, "1:C1", recentTS(20), "1:U_CAROL", "<@U_ME1> lunch plans?")

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)

	items, lists := pendingMentionItems(t, d)
	require.Len(t, items, 1, "one item per channel")
	assert.Equal(t, int(oldID), items[0].ID, "folded into the pending channel item")
	assert.Empty(t, items[0].ReadAt, "a new mention marks the item unread")
	require.Len(t, lists[0], 3, "the older mention is kept, not overwritten")
	assert.Equal(t, "1:U_ALICE: Alice asks for the budget", mentionTexts(lists[0])[0])
	assert.Equal(t, "https://example.com/alice", lists[0][0].Permalink)
	assert.Equal(t, "1:U_BOB", lists[0][1].SenderID)
	assert.Equal(t, "1:U_CAROL", lists[0][2].SenderID)
	assert.Equal(t, "1:U_CAROL", items[0].SenderUserID, "the item's top-level text follows the newest mention")
	assert.Contains(t, items[0].Snippet, "lunch plans")

	// A later cycle appends again.
	insertMessage(t, d, "1:C1", recentTS(10), "1:U_DAN", "<@U_ME1> standup moved")
	p = New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.NoError(t, err)
	items, lists = pendingMentionItems(t, d)
	require.Len(t, items, 1)
	require.Len(t, lists[0], 4)
	assert.Equal(t, "1:U_DAN", lists[0][3].SenderID)
}

// TestInbox09_ChannelMentionsNewItemListsAll: with no pending channel item,
// several plain mentions in one cycle create one item listing them all.
func TestInbox09_ChannelMentionsNewItemListsAll(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	insertChannel(t, d, "1:C1", "public")
	insertMessage(t, d, "1:C1", recentTS(30), "1:U_BOB", "<@U_ME1> first question")
	insertMessage(t, d, "1:C1", recentTS(20), "1:U_CAROL", "<@U_ME1> second question")

	p := New(d, testConfig(), nil, log.Default())
	created, _, err := p.Run(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, created)

	items, lists := pendingMentionItems(t, d)
	require.Len(t, items, 1)
	require.Len(t, lists[0], 2)
	assert.Contains(t, lists[0][0].Text, "first question")
	assert.Contains(t, lists[0][1].Text, "second question")
}

// TestInbox09_PendingItemLookupErrorFreezesWatermark: a failed read of the
// pending item a candidate would fold into is a detector error — never "no
// item", which would mint a duplicate and advance the watermark over it.
func TestInbox09_PendingItemLookupErrorFreezesWatermark(t *testing.T) {
	// BEHAVIOR INBOX-09 — see docs/inventory/inbox-pulse.md
	// Do not weaken or remove without explicit owner approval.
	d := newTestDB(t)
	seedWorkspaceAndUser(t, d, "1:U_ME1")
	const frozen = 1000.0
	require.NoError(t, d.SetInboxLastProcessedTS(frozen))
	insertChannel(t, d, "1:C1", "public")
	insertMessage(t, d, "1:C1", recentTS(30), "1:U_OTHER", "Hey <@U_ME1> review please")
	// Only the fold lookup reads inbox_items.thread_ts; the detectors'
	// dedup reads channel_id/message_ts.
	_, err := d.Exec(`ALTER TABLE inbox_items RENAME COLUMN thread_ts TO thread_gone`)
	require.NoError(t, err)

	p := New(d, testConfig(), nil, log.Default())
	_, _, err = p.Run(context.Background())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "finding pending inbox item")

	ts, err := d.GetInboxLastProcessedTS()
	require.NoError(t, err)
	assert.Equal(t, frozen, ts, "a failed lookup must freeze the watermark")
}
