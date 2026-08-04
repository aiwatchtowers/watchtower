package slack

import (
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTokenStore_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 3)

	assert.False(t, store.Exists(), "fresh dir should have no token")

	token := &Token{
		AccessToken: "xoxb-123456",
		TeamID:      "T123456",
		TeamName:    "My Team",
		UserID:      "U123456",
	}
	require.NoError(t, store.Save(token))
	assert.True(t, store.Exists())

	// File mode must be 0600 (secret).
	info, err := os.Stat(store.Path())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, token.AccessToken, loaded.AccessToken)
	assert.Equal(t, token.TeamID, loaded.TeamID)
	assert.Equal(t, token.TeamName, loaded.TeamName)
	assert.Equal(t, token.UserID, loaded.UserID)

	require.NoError(t, store.Delete())
	assert.False(t, store.Exists())

	// Delete on a missing file is idempotent.
	require.NoError(t, store.Delete())
}

func TestTokenStore_LoadMissing(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 3)

	// Load on a missing file should return (nil, nil).
	loaded, err := store.Load()
	assert.NoError(t, err)
	assert.Nil(t, loaded)
}

func TestTokenStore_LoadMalformedJSON(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 3)

	require.NoError(t, os.WriteFile(store.Path(), []byte("not valid json"), 0o600))

	loaded, err := store.Load()
	assert.Error(t, err)
	assert.Nil(t, loaded)
}

func TestTokenStore_Path(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 3)
	path := store.Path()

	assert.Contains(t, path, "slack_token_3.json")
}
