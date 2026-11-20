package oauthclient

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The client file holds a client secret: 0600, also over an existing file
// of a looser mode, and it reads back what was saved.
func TestOAuthClientStore_Mode0600(t *testing.T) {
	ws := t.TempDir()
	s := NewStore(ws, "jira", 7)
	assert.Equal(t, filepath.Join(ws, "jira_client_7.json"), s.Path())

	_, ok, err := s.Load()
	require.NoError(t, err)
	assert.False(t, ok, "no file is no client")

	require.NoError(t, os.WriteFile(s.Path(), []byte(`{}`), 0o644))
	want := Client{ClientID: "acme-client", ClientSecret: "acme-secret"}
	require.NoError(t, s.Save(want))
	fi, err := os.Stat(s.Path())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())

	got, ok, err := s.Load()
	require.NoError(t, err)
	assert.True(t, ok)
	assert.Equal(t, want, got)

	raw, err := os.ReadFile(s.Path())
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"client_id"`)
	assert.Contains(t, string(raw), `"client_secret"`)

	require.NoError(t, s.Delete())
	require.NoError(t, s.Delete(), "deleting a missing file is not an error")
	_, ok, err = s.Load()
	require.NoError(t, err)
	assert.False(t, ok)
}

// A damaged file, or one without a client id, is an error — never an empty
// client the resolver would send to the vendor.
func TestOAuthClientStore_DamagedFileIsError(t *testing.T) {
	ws := t.TempDir()
	s := NewStore(ws, "jira", 1)
	for _, body := range []string{"{", `{"client_secret":"x"}`, `{"client_id":"a","extra":1}`} {
		require.NoError(t, os.WriteFile(s.Path(), []byte(body), 0o600))
		_, _, err := s.Load()
		assert.Error(t, err, body)
	}
	assert.Error(t, s.Save(Client{}), "saving no client id is refused")
}
