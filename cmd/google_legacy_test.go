package cmd

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func quietTestLogger() *log.Logger {
	return log.New(&bytes.Buffer{}, "", 0)
}

// stubGoogleAccountEmailFetcher replaces the package-level email lookup seam
// for the duration of the test, so ensureLegacyGoogleAccount's best-effort
// email fill never makes a live network call in tests that don't care about
// it. Restored automatically via t.Cleanup.
func stubGoogleAccountEmailFetcher(t *testing.T, fn func(ctx context.Context, workspaceDir string, accountID int64, refreshToken string) (string, error)) {
	t.Helper()
	original := googleAccountEmailFetcher
	googleAccountEmailFetcher = fn
	t.Cleanup(func() { googleAccountEmailFetcher = original })
}

func noEmailFetcher(context.Context, string, int64, string) (string, error) {
	return "", nil
}

func TestEnsureLegacyGoogleAccount_ExistingRowReturnsFirstID(t *testing.T) {
	stubGoogleAccountEmailFetcher(t, noEmailFetcher)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	existingID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "already@there.com", CalendarEnabled: true})
	require.NoError(t, err)

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, existingID, id)

	accounts, err := database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1, "no new row should have been created")
}

func TestEnsureLegacyGoogleAccount_MigratesLegacyCalendarAndGmailTokens(t *testing.T) {
	stubGoogleAccountEmailFetcher(t, noEmailFetcher)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	require.NoError(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Save(&calendar.OAuthToken{RefreshToken: "cal-refresh"}))
	require.NoError(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Save(&gmail.OAuthToken{RefreshToken: "gmail-refresh"}))

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.NotZero(t, id)

	accounts, err := database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, id, accounts[0].ID)
	assert.True(t, accounts[0].CalendarEnabled)
	assert.True(t, accounts[0].GmailEnabled)

	// Legacy calendar token renamed to the shared per-account file.
	assert.NoFileExists(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Path())
	assert.FileExists(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Path())
	// Legacy gmail token removed — same grant, now served by the renamed file.
	assert.NoFileExists(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Path())

	token, err := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "cal-refresh", token.RefreshToken)
}

// TestEnsureLegacyGoogleAccount_SeededRowStillMigratesTokenFiles reproduces
// the exact state a real upgrading install is in *after* migration 00043 has
// run and *before* ensureLegacyGoogleAccount gets its chance:
//
//   - google_accounts row #1 exists, seeded BY THE MIGRATION (empty email,
//     calendar_enabled=1) because the install had synced Google calendars.
//   - the legacy token file google_token.json is still on disk, because only
//     Go can rename it.
//
// The old row-existence guard (`if len(accounts) > 0 { return accounts[0].ID
// }`) made the rename below unreachable for every such install — the spec
// promises this install migrates in place with "no re-sync required", which
// requires wireGoogleSyncers to find a usable google_token_<id>.json.
func TestEnsureLegacyGoogleAccount_SeededRowStillMigratesTokenFiles(t *testing.T) {
	stubGoogleAccountEmailFetcher(t, noEmailFetcher)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	// What migration 00043 step 2 does on an install with legacy Google data.
	seededID, err := database.CreateGoogleAccount(db.GoogleAccount{
		Email:           "",
		CalendarEnabled: true,
		GmailEnabled:    true,
	})
	require.NoError(t, err)

	// The legacy token files the migration cannot touch.
	require.NoError(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Save(&calendar.OAuthToken{RefreshToken: "cal-refresh"}))
	require.NoError(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Save(&gmail.OAuthToken{RefreshToken: "gmail-refresh"}))

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, seededID, id)

	accountTokenPath := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Path()

	// THE CONTRACT: after the seed step the account must own a usable token,
	// because wireGoogleSyncers skips any account whose token store is absent.
	assert.FileExists(t, accountTokenPath,
		"account %d has no google_token_%d.json -> wireGoogleSyncers skips it -> Calendar+Gmail sync silently stops", id, id)
	assert.NoFileExists(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Path(),
		"legacy google_token.json should have been renamed away")
	assert.NoFileExists(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Path(),
		"legacy gmail_token.json should have been deleted (spec)")

	// And the exact predicate wireGoogleSyncers uses.
	assert.True(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Exists(),
		"store.Exists() is the guard in wireGoogleSyncers; false means the syncer is never wired")
}

// TestEnsureLegacyGoogleAccount_RenameFailureRetriesOnNextCall proves the
// guard is retry-able: a token file that shows up only after a first,
// legacy-token-less call must still get migrated on a later call, since the
// guard is "does the account own its token file", not "does the row exist".
func TestEnsureLegacyGoogleAccount_RenameFailureRetriesOnNextCall(t *testing.T) {
	stubGoogleAccountEmailFetcher(t, noEmailFetcher)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	seededID, err := database.CreateGoogleAccount(db.GoogleAccount{CalendarEnabled: true})
	require.NoError(t, err)

	// First call: row exists, but no legacy token file has landed yet
	// (e.g. a partial upgrade, or this ran before the token file was
	// written) — must stay a clean no-op, not an error.
	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, seededID, id)
	assert.NoFileExists(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Path())

	// The legacy token file shows up later.
	require.NoError(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Save(&calendar.OAuthToken{RefreshToken: "cal-refresh"}))

	// A later call (e.g. the next daemon cycle) must pick it up.
	id2, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, seededID, id2)
	assert.FileExists(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id2).Path())
}

func TestEnsureLegacyGoogleAccount_NoLegacyTokenIsNoop(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Zero(t, id)

	accounts, err := database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

func TestEnsureLegacyGoogleAccount_CalendarOnlyLeavesGmailDisabled(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	require.NoError(t, calendar.NewTokenStore(cfg.WorkspaceDir()).Save(&calendar.OAuthToken{RefreshToken: "cal-only"}))
	require.NoFileExists(t, filepath.Join(cfg.WorkspaceDir(), "gmail_token.json"))

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)

	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.True(t, acct.CalendarEnabled)
	assert.False(t, acct.GmailEnabled)
}

func TestEnsureLegacyGoogleAccount_GmailOnlyMigratesAndLeavesCalendarDisabled(t *testing.T) {
	stubGoogleAccountEmailFetcher(t, noEmailFetcher)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	require.NoFileExists(t, filepath.Join(cfg.WorkspaceDir(), "google_token.json"))
	require.NoError(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Save(&gmail.OAuthToken{RefreshToken: "gmail-only"}))

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)

	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.False(t, acct.CalendarEnabled)
	assert.True(t, acct.GmailEnabled)

	// Legacy gmail token renamed to the shared per-account file (no
	// calendar file to prefer, since this workspace never connected
	// Calendar).
	assert.NoFileExists(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Path())
	assert.FileExists(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Path())

	token, err := gmail.NewAccountTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "gmail-only", token.RefreshToken)
}

func TestEnsureLegacyGoogleAccount_FillsEmailFromGmailProfileWhenMissing(t *testing.T) {
	var gotAccountID int64
	stubGoogleAccountEmailFetcher(t, func(_ context.Context, _ string, accountID int64, refreshToken string) (string, error) {
		gotAccountID = accountID
		assert.Equal(t, "gmail-only", refreshToken)
		return "owner@example.com", nil
	})
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	require.NoError(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Save(&gmail.OAuthToken{RefreshToken: "gmail-only"}))

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)
	assert.Equal(t, id, gotAccountID)

	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "owner@example.com", acct.Email)
}

func TestEnsureLegacyGoogleAccount_EmailLookupFailureDoesNotFailSeed(t *testing.T) {
	stubGoogleAccountEmailFetcher(t, func(context.Context, string, int64, string) (string, error) {
		return "", fmt.Errorf("network unavailable")
	})
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	require.NoError(t, gmail.NewTokenStore(cfg.WorkspaceDir()).Save(&gmail.OAuthToken{RefreshToken: "gmail-only"}))

	id, err := ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)

	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Empty(t, acct.Email)
}

func TestEnsureLegacyGoogleAccount_ExistingRowAlreadyHasEmailSkipsLookup(t *testing.T) {
	called := false
	stubGoogleAccountEmailFetcher(t, func(context.Context, string, int64, string) (string, error) {
		called = true
		return "should-not-be-used@example.com", nil
	})
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)

	_, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "already@there.com", GmailEnabled: true})
	require.NoError(t, err)

	_, err = ensureLegacyGoogleAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.False(t, called, "fetcher must not run when the row already has an email")
}
