package jira

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTokenStore_CRUD(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 1)

	// Initially does not exist.
	assert.False(t, store.Exists())

	_, err := store.Load()
	assert.Error(t, err)

	// Save.
	token := &OAuthToken{
		AccessToken:  "access123",
		TokenType:    "Bearer",
		RefreshToken: "refresh456",
		ExpiresIn:    3600,
		Scope:        "read:jira-work",
		Expiry:       time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
	}
	require.NoError(t, store.Save(token))
	assert.True(t, store.Exists())

	// Load.
	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "access123", loaded.AccessToken)
	assert.Equal(t, "Bearer", loaded.TokenType)
	assert.Equal(t, "refresh456", loaded.RefreshToken)

	// Delete.
	require.NoError(t, store.Delete())
	assert.False(t, store.Exists())

	// Delete non-existent is OK.
	require.NoError(t, store.Delete())
}

func TestTokenStore_Path(t *testing.T) {
	store := NewTokenStore("/tmp/test-workspace", 1)
	assert.Equal(t, filepath.Join("/tmp/test-workspace", "jira_token_1.json"), store.Path())
}

func TestTokenStore_SaveCreatesDirectory(t *testing.T) {
	dir := t.TempDir()
	subDir := filepath.Join(dir, "sub", "dir")
	store := NewTokenStore(subDir, 1)

	token := &OAuthToken{AccessToken: "test"}
	require.NoError(t, store.Save(token))

	_, err := os.Stat(filepath.Join(subDir, "jira_token_1.json"))
	assert.NoError(t, err)
}

// TestTokenStore_SaveIsAtomic: a save replaces the file by rename (a new
// inode — a reader holding the old file never sees a partial write), keeps
// it 0600 and leaves no temp file behind.
func TestTokenStore_SaveIsAtomic(t *testing.T) {
	dir := t.TempDir()
	store := NewTokenStore(dir, 1)
	require.NoError(t, store.Save(&OAuthToken{AccessToken: "first"}))
	before, err := os.Stat(store.Path())
	require.NoError(t, err)

	require.NoError(t, store.Save(&OAuthToken{AccessToken: "second"}))
	after, err := os.Stat(store.Path())
	require.NoError(t, err)

	assert.False(t, os.SameFile(before, after), "the token file is replaced, not rewritten in place")
	assert.Equal(t, os.FileMode(0o600), after.Mode().Perm())
	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "second", loaded.AccessToken)
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	require.Len(t, entries, 1, "no temp file is left behind")
	assert.Equal(t, "jira_token_1.json", entries[0].Name())
}

func TestOAuthToken_IsExpired(t *testing.T) {
	tests := []struct {
		name    string
		token   OAuthToken
		expired bool
	}{
		{
			name:    "empty expiry",
			token:   OAuthToken{Expiry: ""},
			expired: true,
		},
		{
			name:    "invalid expiry",
			token:   OAuthToken{Expiry: "not-a-date"},
			expired: true,
		},
		{
			name:    "future expiry",
			token:   OAuthToken{Expiry: time.Now().Add(10 * time.Minute).UTC().Format(time.RFC3339)},
			expired: false,
		},
		{
			name:    "past expiry",
			token:   OAuthToken{Expiry: time.Now().Add(-10 * time.Minute).UTC().Format(time.RFC3339)},
			expired: true,
		},
		{
			name:    "within 60s buffer",
			token:   OAuthToken{Expiry: time.Now().Add(30 * time.Second).UTC().Format(time.RFC3339)},
			expired: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.expired, tt.token.IsExpired())
		})
	}
}

func TestListenLocal_PortRange(t *testing.T) {
	// Should be able to listen on one of the preferred ports.
	ln, err := listenLocal()
	require.NoError(t, err)
	defer ln.Close()

	addr := ln.Addr().String()
	assert.Contains(t, addr, "127.0.0.1:")
}
