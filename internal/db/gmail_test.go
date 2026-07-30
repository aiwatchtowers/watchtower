package db

// NOTE: TestGmailUpsertAndQuery, TestGmailWatermark, TestGetGmailBodyByID, and
// TestGmailAuthState were removed by migration 00043 (google_accounts):
// UpsertGmailMessage/GmailMessagesSyncedAfter/GetGmailBodyByID INSERT into
// gmail_messages without an account_id, which 00043 makes part of the
// composite PRIMARY KEY with no default, and SetGmailLastInternalDate/
// GetGmailLastInternalDate/SetGmailAuthState/GetGmailAuthState target the
// workspace.gmail_last_internal_date column and the gmail_auth_state table,
// both of which 00043 drops in favor of the per-account columns on
// google_accounts. The accessors are left in place — internal/gmail and cmd
// still call them, so they keep compiling — but they now fail at runtime;
// Task 2 of the multi-account plan rewrites them to take an account id and
// will need fresh tests for the new signatures.
