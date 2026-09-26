package cmd

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/inbox"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestRemoveGoogleAccount_RevokesGrantWhenTokenPresent proves I4: removing an
// account whose token file is still on disk must revoke the OAuth grant at
// Google before/alongside deleting local state — otherwise the grant lives
// on at Google indefinitely even though Watchtower has forgotten the
// account. Uses the same httptest + package-var endpoint swap pattern as
// internal/calendar/auth_test.go's TestRevoke_Success, via the exported
// cross-package seam calendar.SetGoogleRevokeEndpointForTest.
func TestRemoveGoogleAccount_RevokesGrantWhenTokenPresent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	id, err := database.CreateGoogleAccount(db.GoogleAccount{CalendarEnabled: true})
	require.NoError(t, err)
	require.NoError(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Save(&calendar.OAuthToken{RefreshToken: "rt-123"}))

	var gotToken string
	var callCount int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		require.NoError(t, r.ParseForm())
		gotToken = r.PostForm.Get("token")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	restore := calendar.SetGoogleRevokeEndpointForTest(srv.URL)
	defer restore()

	removed, err := removeGoogleAccount(context.Background(), cfg, database, id, &bytes.Buffer{})
	require.NoError(t, err)

	assert.Equal(t, 1, callCount, "revoke endpoint must be called exactly once")
	assert.Equal(t, "rt-123", gotToken)
	assert.Contains(t, removed, "token file")

	_, getErr := database.GetGoogleAccount(id)
	assert.Error(t, getErr, "account row must be gone")
}

// TestRemoveGoogleAccount_NoTokenFileSkipsRevoke covers the degenerate case:
// an account with no token file on disk (e.g. it never completed login) must
// not attempt a revoke call at all — there's no refresh token to revoke.
func TestRemoveGoogleAccount_NoTokenFileSkipsRevoke(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	id, err := database.CreateGoogleAccount(db.GoogleAccount{})
	require.NoError(t, err)

	var called bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	restore := calendar.SetGoogleRevokeEndpointForTest(srv.URL)
	defer restore()

	removed, err := removeGoogleAccount(context.Background(), cfg, database, id, &bytes.Buffer{})
	require.NoError(t, err)
	assert.False(t, called, "revoke must not be called when there's no token to revoke")
	assert.Empty(t, removed)
}

// TestRemoveGoogleAccount_RevokeFailureStillRemovesAccount proves the revoke
// call is best-effort: a failing revoke (e.g. Google is unreachable, or the
// grant was already revoked out-of-band) must not block local removal.
func TestRemoveGoogleAccount_RevokeFailureStillRemovesAccount(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	id, err := database.CreateGoogleAccount(db.GoogleAccount{})
	require.NoError(t, err)
	require.NoError(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Save(&calendar.OAuthToken{RefreshToken: "rt-dead"}))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid_token"}`, http.StatusBadRequest)
	}))
	defer srv.Close()
	restore := calendar.SetGoogleRevokeEndpointForTest(srv.URL)
	defer restore()

	var warnOut bytes.Buffer
	removed, err := removeGoogleAccount(context.Background(), cfg, database, id, &warnOut)
	require.NoError(t, err, "a revoke failure must not fail the removal")
	assert.Contains(t, removed, "token file")
	assert.Contains(t, warnOut.String(), "could not revoke")

	_, getErr := database.GetGoogleAccount(id)
	assert.Error(t, getErr, "account row must still be gone despite the revoke failure")
}

// TestRemoveGoogleAccount_DeletesLegacyTokenLeftovers is the belt-and-braces
// half of I4: any lingering pre-multi-account google_token.json/
// gmail_token.json must be deleted on removal, even though the C1 fix to
// ensureLegacyGoogleAccount means they shouldn't normally coexist with a
// connected account.
func TestRemoveGoogleAccount_DeletesLegacyTokenLeftovers(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	id, err := database.CreateGoogleAccount(db.GoogleAccount{})
	require.NoError(t, err)
	require.NoError(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Save(&calendar.OAuthToken{RefreshToken: "legacy-cal"}))
	require.NoError(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Save(&gmail.OAuthToken{RefreshToken: "legacy-gmail"}))

	removed, err := removeGoogleAccount(context.Background(), cfg, database, id, &bytes.Buffer{})
	require.NoError(t, err)

	assert.NoFileExists(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Path())
	assert.NoFileExists(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Path())
	assert.Contains(t, removed, "legacy calendar token")
	assert.Contains(t, removed, "legacy gmail token")
}

// seedGmailAccount creates a Gmail-enabled Google account owning one received
// message in threadID, and returns the new account id. The message is synced
// relative to now so the detector's synced_at window always covers it.
func seedGmailAccount(t *testing.T, database *db.DB, email, messageID, threadID string) int64 {
	t.Helper()
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: email, GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, database.UpsertGmailMessage(id, db.GmailMessage{
		ID:        messageID,
		ThreadID:  threadID,
		FromEmail: "colleague@example.com",
		ToJSON:    `["` + email + `"]`,
		Subject:   "Quarterly numbers",
		SyncedAt:  time.Now().UTC().Format(time.RFC3339),
	}))
	return id
}

// countRows runs a scalar COUNT(*) query.
func countRows(t *testing.T, database *db.DB, query string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(query, args...).Scan(&n))
	return n
}

// TestRemoveGoogleAccount_PurgesGmailInboxRows proves the removal no longer
// leaves orphans behind: gmail_messages cascade off the deleted account row,
// but the inbox items the Gmail detector minted are keyed only by the
// "gmail:<id>:<thread>" channel-id convention and used to survive the
// removal forever, along with the learned rules scoped to them.
func TestRemoveGoogleAccount_PurgesGmailInboxRows(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	id := seedGmailAccount(t, database, "owner@x.com", "m1", "t1")
	created, err := inbox.DetectGmailAccounts(context.Background(), database, time.Now().Add(-time.Hour))
	require.NoError(t, err)
	require.Equal(t, 1, created, "detector must mint the item the removal then has to clean up")

	channelID := db.GmailChannelID(id, "t1")
	_, err = database.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', ?, -1.0, 'user_rule', datetime('now'))`, "channel:"+channelID)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, last_updated)
		VALUES ('source_mute', 'sender:colleague@example.com', -1.0, 'user_rule', datetime('now'))`)
	require.NoError(t, err)

	_, err = removeGoogleAccount(context.Background(), cfg, database, id, &bytes.Buffer{})
	require.NoError(t, err)

	assert.Zero(t, countRows(t, database, `SELECT COUNT(*) FROM inbox_items`),
		"no Gmail inbox item may outlive the account that minted it")
	assert.Zero(t, countRows(t, database, `SELECT COUNT(*) FROM gmail_messages`))
	assert.Zero(t, countRows(t, database, `SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = ?`,
		"channel:"+channelID), "a rule naming a dead account's thread can never match again")
	assert.Equal(t, 1, countRows(t, database,
		`SELECT COUNT(*) FROM inbox_learned_rules WHERE scope_key = 'sender:colleague@example.com'`),
		"sender rules are identity-scoped, not account-scoped, and must survive")
}

// TestRemoveGoogleAccount_ReconnectDoesNotDuplicateInbox is the user-visible
// symptom. Reconnecting the same mailbox mints a new google_accounts row with
// a new id, so the detector builds a different channel_id and its
// (channel_id, message_ts, trigger_type) dedup key misses anything left over
// from the old id. Before the fix the same mail showed up twice in the inbox;
// this runs the real detector on both sides of the removal and asserts one.
func TestRemoveGoogleAccount_ReconnectDoesNotDuplicateInbox(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)
	since := time.Now().Add(-time.Hour)

	oldID := seedGmailAccount(t, database, "owner@x.com", "m1", "t1")
	_, err := inbox.DetectGmailAccounts(context.Background(), database, since)
	require.NoError(t, err)

	_, err = removeGoogleAccount(context.Background(), cfg, database, oldID, &bytes.Buffer{})
	require.NoError(t, err)

	// Same mailbox reconnected: a fresh row, hence a fresh id.
	newID := seedGmailAccount(t, database, "owner@x.com", "m1", "t1")
	require.NotEqual(t, oldID, newID)
	_, err = inbox.DetectGmailAccounts(context.Background(), database, since)
	require.NoError(t, err)

	assert.Equal(t, 1, countRows(t, database, `SELECT COUNT(*) FROM inbox_items WHERE message_ts = 'm1'`),
		"reconnecting the same mailbox must not duplicate its mail in the inbox")
	assert.Equal(t, 1, countRows(t, database, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`,
		db.GmailChannelID(newID, "t1")))
}

// TestRemoveGoogleAccount_LeavesOtherAccountsAlone: the purge is scoped to the
// removed account, so a second connected mailbox keeps its mail and its inbox
// items.
func TestRemoveGoogleAccount_LeavesOtherAccountsAlone(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	idA := seedGmailAccount(t, database, "a@x.com", "ma", "ta")
	idB := seedGmailAccount(t, database, "b@y.com", "mb", "tb")
	created, err := inbox.DetectGmailAccounts(context.Background(), database, time.Now().Add(-time.Hour))
	require.NoError(t, err)
	require.Equal(t, 2, created)

	_, err = removeGoogleAccount(context.Background(), cfg, database, idA, &bytes.Buffer{})
	require.NoError(t, err)

	assert.Equal(t, 1, countRows(t, database, `SELECT COUNT(*) FROM gmail_messages WHERE account_id = ?`, idB))
	assert.Equal(t, 1, countRows(t, database, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`,
		db.GmailChannelID(idB, "tb")))
	assert.Zero(t, countRows(t, database, `SELECT COUNT(*) FROM inbox_items WHERE channel_id = ?`,
		db.GmailChannelID(idA, "ta")))
}
