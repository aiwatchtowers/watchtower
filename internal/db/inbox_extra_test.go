package db

import (
	"testing"
	"time"
)

// seedInboxItem inserts a minimal pending inbox item and returns its id.
func seedInboxItem(t *testing.T, d *DB, sender, channel, trigger string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, created_at, updated_at)
		VALUES (?,?,?,?,'pending','medium',?,?)`,
		channel, "1.0", sender, trigger,
		time.Now().UTC().Format(time.RFC3339),
		time.Now().UTC().Format(time.RFC3339),
	)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

func TestInbox_ArchiveExpired(t *testing.T) {
	database := openTestDB(t)

	// Ambient item 8 days old
	oldT := time.Now().Add(-8 * 24 * time.Hour).UTC().Format(time.RFC3339)
	_, _ = database.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, item_class, created_at, updated_at)
		VALUES ('C1','1.0','U1','decision_made','pending','low','ambient',?,?)`, oldT, oldT)

	n, err := database.ArchiveExpiredAmbient(7 * 24 * time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("want 1 archived, got %d", n)
	}

	// Verify archived_at set + reason
	var reason string
	var arch string
	_ = database.QueryRow(`SELECT archive_reason, archived_at FROM inbox_items WHERE item_class='ambient'`).Scan(&reason, &arch)
	if reason != "seen_expired" {
		t.Errorf("reason=%q", reason)
	}
	if arch == "" {
		t.Error("archived_at empty")
	}
}

func TestInbox_ArchiveStale(t *testing.T) {
	database := openTestDB(t)
	oldT := time.Now().Add(-15 * 24 * time.Hour).UTC().Format(time.RFC3339)
	_, _ = database.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, status, priority, item_class, created_at, updated_at)
		VALUES ('C1','1.0','U1','mention','pending','medium','actionable',?,?)`, oldT, oldT)
	n, _ := database.ArchiveStaleActionable(14 * 24 * time.Hour)
	if n != 1 {
		t.Errorf("want 1, got %d", n)
	}
}

func TestInbox_FeedQuery_ExcludesArchivedAndTerminated(t *testing.T) {
	database := openTestDB(t)
	alive := seedInboxItem(t, database, "U1", "C1", "mention")
	archived := seedInboxItem(t, database, "U2", "C2", "mention")
	_, _ = database.Exec(`UPDATE inbox_items SET archived_at=? WHERE id=?`, time.Now().Format(time.RFC3339), archived)
	resolved := seedInboxItem(t, database, "U3", "C3", "mention")
	_, _ = database.Exec(`UPDATE inbox_items SET status='resolved' WHERE id=?`, resolved)

	got, err := database.ListInboxFeed(50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || int64(got[0].ID) != alive {
		t.Errorf("expected only alive item, got %+v", got)
	}
}
