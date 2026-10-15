package planusage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const credJSON = `{"claudeAiOauth":{"accessToken":"tok-SECRET","refreshToken":"r-SECRET","expiresAt":1760522400000,"subscriptionType":"max"}}`

func TestCredentials_Keychain(t *testing.T) {
	var gotArgs []string
	s := CredentialSource{UseKeychain: true, HomeDir: t.TempDir(), Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
		gotArgs = append([]string{name}, args...)
		return []byte(credJSON + "\n"), nil
	}}
	c, err := s.Load(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "tok-SECRET", c.AccessToken)
	assert.Equal(t, "max", c.Plan)
	assert.Equal(t, time.UnixMilli(1760522400000).UTC(), c.ExpiresAt)
	assert.Equal(t, []string{"/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"}, gotArgs)
}

func TestCredentials_FileFallback(t *testing.T) {
	home := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".claude"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude", ".credentials.json"), []byte(credJSON), 0o600))
	s := CredentialSource{UseKeychain: true, HomeDir: home, Run: func(context.Context, string, ...string) ([]byte, error) {
		return nil, errors.New("exit status 44")
	}}
	c, err := s.Load(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "tok-SECRET", c.AccessToken)
}

func TestCredentials_NoneAnywhere(t *testing.T) {
	s := CredentialSource{UseKeychain: true, HomeDir: t.TempDir(), Run: func(context.Context, string, ...string) ([]byte, error) {
		return nil, errors.New("exit status 44")
	}}
	_, err := s.Load(context.Background())
	assert.ErrorIs(t, err, ErrNoCredentials)
}

func TestCredentials_ErrorsNeverCarryTheToken(t *testing.T) {
	s := CredentialSource{UseKeychain: true, HomeDir: t.TempDir(), Run: func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`{"claudeAiOauth":{"accessToken":"tok-SECRET"`), nil // truncated JSON
	}}
	_, err := s.Load(context.Background())
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "SECRET")
}
