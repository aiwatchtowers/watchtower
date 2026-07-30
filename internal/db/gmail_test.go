package db

import (
	"testing"

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
