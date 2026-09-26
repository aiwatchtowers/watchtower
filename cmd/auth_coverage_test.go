package cmd

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// newSaveAuthResultCmd returns a bare command whose stderr is discarded so the
// [slack] logger inside saveAuthResult stays quiet in tests.
func newSaveAuthResultCmd() *cobra.Command {
	cmd := &cobra.Command{}
	cmd.SetErr(io.Discard)
	cmd.SetContext(context.Background())
	return cmd
}

func TestSaveAuthResult_Success(t *testing.T) {
	// saveAuthResult now persists the token onto a slack_accounts row + a
	// per-account token file, NOT into config.yaml — it opens the workspace DB
	// (under HOME) and runs the identity-resolving connect flow.
	stubSlackIdentityServer(t, "U456", "T123", "My Test Team", "myteam")
	t.Setenv("HOME", t.TempDir())

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")

	oldFlagConfig := flagConfig
	flagConfig = configPath
	defer func() { flagConfig = oldFlagConfig }()

	result := &auth.OAuthResult{
		AccessToken: "xoxp-test-token-12345",
		TeamID:      "T123",
		TeamName:    "My Test Team",
		UserID:      "U456",
	}

	info, err := saveAuthResult(newSaveAuthResultCmd(), result)
	require.NoError(t, err)
	assert.Equal(t, "my-test-team", info.Workspace)
	assert.Equal(t, "T123", info.TeamID)
	assert.Equal(t, "U456", info.UserID)

	// The config file was created with the workspace scaffolding, but the token
	// no longer lives there — it moved to the DB row + token file.
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	content := string(data)
	assert.Contains(t, content, "my-test-team")
	assert.NotContains(t, content, "xoxp-test-token-12345",
		"the Slack token must no longer be written to config.yaml")

	// The account row and its per-account token file exist.
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	cfg.ActiveWorkspace = info.Workspace
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	accounts, err := database.ListSlackAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), accounts[0].ID)
	require.True(t, store.Exists(), "slack_token_%d.json must exist", accounts[0].ID)
	tok, err := store.Load()
	require.NoError(t, err)
	require.NotNil(t, tok)
	assert.Equal(t, "xoxp-test-token-12345", tok.AccessToken)
}

func TestSaveAuthResult_EmptyTeamName(t *testing.T) {
	stubSlackIdentityServer(t, "U101", "T789", "", "")
	t.Setenv("HOME", t.TempDir())

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")

	oldFlagConfig := flagConfig
	flagConfig = configPath
	defer func() { flagConfig = oldFlagConfig }()

	result := &auth.OAuthResult{
		AccessToken: "xoxp-test-token",
		TeamID:      "T789",
		TeamName:    "",
		UserID:      "U101",
	}

	info, err := saveAuthResult(newSaveAuthResultCmd(), result)
	require.NoError(t, err)
	// When team name sanitizes to empty, should use TeamID
	assert.Equal(t, "T789", info.Workspace)
}

func TestSaveAuthResult_ExistingConfig(t *testing.T) {
	stubSlackIdentityServer(t, "U001", "T001", "New Team", "newteam")
	t.Setenv("HOME", t.TempDir())

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")

	// Create existing config
	existingConfig := `active_workspace: old-workspace
ai:
  model: "custom-model"
`
	require.NoError(t, os.WriteFile(configPath, []byte(existingConfig), 0o600))

	oldFlagConfig := flagConfig
	flagConfig = configPath
	defer func() { flagConfig = oldFlagConfig }()

	result := &auth.OAuthResult{
		AccessToken: "xoxp-new-token",
		TeamID:      "T001",
		TeamName:    "New Team",
		UserID:      "U001",
	}

	info, err := saveAuthResult(newSaveAuthResultCmd(), result)
	require.NoError(t, err)
	assert.Equal(t, "new-team", info.Workspace)

	// active_workspace should be updated to the new team, and the token must NOT
	// be persisted into config.yaml.
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	content := string(data)
	assert.Contains(t, content, "new-team")
	assert.NotContains(t, content, "xoxp-new-token",
		"the Slack token must no longer be written to config.yaml")
}

func TestSaveAuthResult_WithExpiry(t *testing.T) {
	stubSlackIdentityServer(t, "U001", "T001", "Expiry Team", "expiry")
	t.Setenv("HOME", t.TempDir())

	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")

	oldFlagConfig := flagConfig
	flagConfig = configPath
	defer func() { flagConfig = oldFlagConfig }()

	result := &auth.OAuthResult{
		AccessToken: "xoxp-expiring-token",
		TeamID:      "T001",
		TeamName:    "Expiry Team",
		UserID:      "U001",
		ExpiresIn:   3600,
	}

	// Should succeed but print warning to stderr
	info, err := saveAuthResult(newSaveAuthResultCmd(), result)
	require.NoError(t, err)
	assert.Equal(t, "expiry-team", info.Workspace)
}

func TestAuthResultInfo_Fields(t *testing.T) {
	info := authResultInfo{
		Workspace: "test-ws",
		TeamID:    "T001",
		UserID:    "U001",
	}
	assert.Equal(t, "test-ws", info.Workspace)
	assert.Equal(t, "T001", info.TeamID)
	assert.Equal(t, "U001", info.UserID)
}
