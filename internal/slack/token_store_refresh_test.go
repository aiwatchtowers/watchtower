package slack

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTokenStore_RefreshFieldsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 3)
	exp := time.Date(2026, 11, 17, 10, 0, 0, 0, time.UTC)
	refreshExp := time.Date(2027, 2, 15, 10, 0, 0, 0, time.UTC)
	require.NoError(t, store.Save(&Token{
		AccessToken: "xoxe.xoxp-a", TeamID: "T0ACME", UserID: "U0OWNER",
		RefreshToken: "xoxe-1-r", ExpiresAt: exp, RefreshExpiresAt: refreshExp,
		ClientID: "111.222", AppID: "A0APP1",
	}))
	got, err := store.Load()
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "xoxe-1-r", got.RefreshToken)
	assert.True(t, exp.Equal(got.ExpiresAt))
	assert.True(t, refreshExp.Equal(got.RefreshExpiresAt))
	assert.Equal(t, "111.222", got.ClientID)
	assert.Equal(t, "A0APP1", got.AppID)

	// A token without rotation writes none of the new keys.
	plain := NewTokenStore(dir, 4)
	require.NoError(t, plain.Save(&Token{AccessToken: "xoxp-plain", TeamID: "T0ACME"}))
	raw, err := os.ReadFile(plain.Path())
	require.NoError(t, err)
	for _, key := range []string{"refresh_token", "expires_at", "refresh_expires_at", "client_id", "app_id"} {
		assert.NotContains(t, string(raw), `"`+key+`"`)
	}
}

func TestTokenStore_RefreshFieldsOldFileLoads(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "slack_token_5.json")
	require.NoError(t, os.WriteFile(path,
		[]byte(`{"access_token":"xoxp-old","team_id":"T0ACME","team_name":"Acme","user_id":"U0OWNER"}`), 0o600))
	got, err := NewTokenStore(dir, 5).Load()
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, "xoxp-old", got.AccessToken)
	assert.Empty(t, got.RefreshToken)
	assert.True(t, got.ExpiresAt.IsZero())
	assert.True(t, got.RefreshExpiresAt.IsZero())
	assert.Empty(t, got.ClientID)
	assert.Empty(t, got.AppID)
}

func TestTokenStore_Lock(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ws")
	store := NewTokenStore(dir, 6)
	unlock, err := store.Lock(context.Background())
	require.NoError(t, err)
	_, err = os.Stat(store.Path() + ".lock")
	require.NoError(t, err, "the lock lives beside the token file")

	// A second holder waits; a cancelled context gives up.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = store.Lock(ctx)
	assert.Error(t, err)

	unlock()
	unlock2, err := store.Lock(context.Background())
	require.NoError(t, err)
	unlock2()
}
