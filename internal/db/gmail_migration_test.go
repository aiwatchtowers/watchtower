package db

import "testing"

func TestMigration00018GmailSource(t *testing.T) {
	database := openTestDB(t) // existing helper that runs migrations on a fresh DB

	// gmail tables exist
	for _, tbl := range []string{"gmail_messages", "gmail_auth_state"} {
		var name string
		err := database.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, tbl).Scan(&name)
		if err != nil {
			t.Fatalf("table %s missing: %v", tbl, err)
		}
	}

	// workspace watermark column present
	if _, err := database.Exec(`UPDATE workspace SET gmail_last_internal_date = 123.0`); err != nil {
		t.Fatalf("gmail_last_internal_date column missing: %v", err)
	}

	// new trigger_type accepted
	_, err := database.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
        VALUES ('t1','m1','from@x.com','email_received')`)
	if err != nil {
		t.Fatalf("email_received rejected: %v", err)
	}
}
