package cmd

import (
	"bytes"
	"context"
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

func TestEnsureLegacyGoogleAccount_ExistingRowReturnsFirstID(t *testing.T) {
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
