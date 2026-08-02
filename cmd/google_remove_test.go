package cmd

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"

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
