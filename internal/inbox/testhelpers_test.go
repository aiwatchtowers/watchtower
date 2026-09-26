package inbox

import (
	"testing"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// insertChannel is a local fixture helper (package db has its own private
// copy; this package needs one too).
func insertChannel(t *testing.T, d *db.DB, id, chType string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES (?, ?, ?)`, id, id, chType)
	require.NoError(t, err)
}

// insertMessage is a local fixture helper mirroring internal/db's test helper.
func insertMessage(t *testing.T, d *db.DB, channelID, ts, userID, text string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO messages (channel_id, ts, user_id, text) VALUES (?, ?, ?, ?)`, channelID, ts, userID, text)
	require.NoError(t, err)
}

// mustCreateInboxItem is a local fixture helper wrapping CreateInboxItem.
func mustCreateInboxItem(t *testing.T, d *db.DB, it db.InboxItem) int64 {
	t.Helper()
	id, err := d.CreateInboxItem(it)
	require.NoError(t, err)
	return id
}

// queryInboxByTrigger returns all inbox_items with the given trigger_type.
func queryInboxByTrigger(t *testing.T, d *db.DB, triggerType string) []db.InboxItem {
	t.Helper()
	rows, err := d.Query(`SELECT id, channel_id, message_ts, thread_ts, sender_user_id,
		trigger_type, snippet, context, raw_text, permalink, status, priority,
		ai_reason, resolved_reason, snooze_until, COALESCE(waiting_user_ids,''), target_id,
		COALESCE(read_at,''), created_at, updated_at,
		COALESCE(item_class,'actionable'), COALESCE(archived_at,''), COALESCE(archive_reason,'')
		FROM inbox_items WHERE trigger_type = ?`, triggerType)
	if err != nil {
		t.Fatalf("queryInboxByTrigger: %v", err)
	}
	defer rows.Close()

	var items []db.InboxItem
	for rows.Next() {
		var it db.InboxItem
		if err := rows.Scan(
			&it.ID, &it.ChannelID, &it.MessageTS, &it.ThreadTS, &it.SenderUserID,
			&it.TriggerType, &it.Snippet, &it.Context, &it.RawText, &it.Permalink,
			&it.Status, &it.Priority, &it.AIReason, &it.ResolvedReason, &it.SnoozeUntil,
			&it.WaitingUserIDs, &it.TargetID, &it.ReadAt, &it.CreatedAt, &it.UpdatedAt,
			&it.ItemClass, &it.ArchivedAt, &it.ArchiveReason,
		); err != nil {
			t.Fatalf("queryInboxByTrigger scan: %v", err)
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("queryInboxByTrigger rows: %v", err)
	}
	return items
}
