package calendar

import (
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCredentialStore_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	store := NewCredentialStore(dir, 3)

	assert.False(t, store.Exists(), "fresh dir should have no credentials")

	creds := &Credentials{
		ClientID:     "123.apps.googleusercontent.com",
		ClientSecret: "secret123",
	}
	require.NoError(t, store.Save(creds))
	assert.True(t, store.Exists())

	// File mode must be 0600 (secret).
	info, err := os.Stat(store.Path())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	loaded, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, creds.ClientID, loaded.ClientID)
	assert.Equal(t, creds.ClientSecret, loaded.ClientSecret)

	require.NoError(t, store.Delete())
	assert.False(t, store.Exists())

	// Delete on a missing file is idempotent.
	require.NoError(t, store.Delete())
}
