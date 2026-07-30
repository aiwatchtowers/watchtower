package db

import "testing"

// TestMigration00018GmailSource originally also asserted the gmail_auth_state
// table and workspace.gmail_last_internal_date column, both retired by
// migration 00043 (google_accounts) in favor of per-account columns on
// google_accounts — see TestMigration00043GoogleAccounts for the current
// assertions on those. The gmail_messages table and email_received
// trigger_type it introduced are still current, so those checks remain.
func TestMigration00018GmailSource(t *testing.T) {
	database := openTestDB(t) // existing helper that runs migrations on a fresh DB

	assertTableExists(t, database, "gmail_messages")

	// new trigger_type accepted
	_, err := database.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
        VALUES ('t1','m1','from@x.com','email_received')`)
	if err != nil {
		t.Fatalf("email_received rejected: %v", err)
	}
}
