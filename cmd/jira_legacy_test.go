package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// legacyJiraFixture sets up a temp HOME + config and returns the workspace dir
// and an open test DB, ready for ensureLegacyJiraAccount.
func legacyJiraFixture(t *testing.T) (*config.Config, *db.DB, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test"}
	cfg.Jira.CloudID = "cloud-legacy"
	cfg.Jira.SiteURL = "https://legacy.atlassian.net"
	// Historical misnomer: the legacy `jira login` wrote the SITE name here.
	cfg.Jira.UserDisplayName = "Legacy Site"
	database := db.OpenTestDB(t)
	wsDir := cfg.WorkspaceDir()
	require.NoError(t, os.MkdirAll(wsDir, 0o700))
	return cfg, database, wsDir
}

func writeLegacyJiraToken(t *testing.T, wsDir string) string {
	t.Helper()
	path := filepath.Join(wsDir, "jira_token.json")
	require.NoError(t, os.WriteFile(path, []byte(`{"access_token":"legacy"}`), 0o600))
	return path
}

// A workspace that never connected Jira is a clean no-op — no row, no error.
func TestEnsureLegacyJiraAccount_NoTokenIsNoOp(t *testing.T) {
	cfg, database, _ := legacyJiraFixture(t)

	id, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Zero(t, id)

	accounts, err := database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts, "a never-connected workspace must not get an account row")
}

// Token-only install: the goose seed had no synced data to work from, so Go
// mints account #1 and fills its identity from the frozen config keys.
func TestEnsureLegacyJiraAccount_TokenOnlyCreatesAccountAndMovesToken(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	legacyPath := writeLegacyJiraToken(t, wsDir)

	id, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)

	acct, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "cloud-legacy", acct.CloudID)
	assert.Equal(t, "https://legacy.atlassian.net", acct.SiteURL)
	assert.Equal(t, "Legacy Site", acct.SiteName)

	assert.NoFileExists(t, legacyPath, "legacy token must be moved, not copied")
	assert.FileExists(t, jira.NewTokenStore(wsDir, id).Path())
}

// Synced install: migration 00049 already seeded row #1 with an empty
// cloud_id (SQL cannot read config.yaml); Go fills the identity in.
func TestEnsureLegacyJiraAccount_FillsSeededRowIdentity(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	writeLegacyJiraToken(t, wsDir)

	seeded, err := database.CreateJiraAccount(db.JiraAccount{})
	require.NoError(t, err)

	id, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, seeded, id, "the seeded row must be reused, not duplicated")

	acct, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "cloud-legacy", acct.CloudID)

	accounts, err := database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1)
}

// An account that already carries an identity keeps it — the config keys are
// frozen and must never overwrite a live row.
func TestEnsureLegacyJiraAccount_DoesNotOverwriteResolvedIdentity(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	writeLegacyJiraToken(t, wsDir)

	id, err := database.CreateJiraAccount(db.JiraAccount{
		CloudID: "cloud-live", SiteURL: "https://live.atlassian.net", SiteName: "Live",
	})
	require.NoError(t, err)

	got, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, id, got)

	acct, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "cloud-live", acct.CloudID, "a resolved identity must survive the legacy seed")
	assert.Equal(t, "Live", acct.SiteName)
}

// The guard is the legacy FILE, so a second call is a no-op returning the same
// id — the step must be safe to run from every entry point, every cycle.
func TestEnsureLegacyJiraAccount_Idempotent(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	writeLegacyJiraToken(t, wsDir)

	first, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, first)

	second, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Zero(t, second, "with the legacy token gone the step is a clean no-op")

	accounts, err := database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1, "a second call must not mint another account")
}

// A per-account token already on disk wins: a legacy leftover (restored backup,
// hand-copied file) must never clobber the live grant.
func TestEnsureLegacyJiraAccount_NeverClobbersExistingAccountToken(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	legacyPath := writeLegacyJiraToken(t, wsDir)

	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud-live"})
	require.NoError(t, err)
	liveStore := jira.NewTokenStore(wsDir, id)
	require.NoError(t, liveStore.Save(&jira.OAuthToken{AccessToken: "live-token"}))

	got, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, id, got)

	live, err := liveStore.Load()
	require.NoError(t, err)
	assert.Equal(t, "live-token", live.AccessToken, "the live per-account token must survive")
	assert.FileExists(t, legacyPath, "the legacy leftover is left in place, not silently applied")
}

// With several accounts already present the step targets the oldest (#1) —
// the account the legacy single-site install conceptually became.
func TestEnsureLegacyJiraAccount_PicksOldestAccount(t *testing.T) {
	cfg, database, wsDir := legacyJiraFixture(t)
	writeLegacyJiraToken(t, wsDir)

	first, err := database.CreateJiraAccount(db.JiraAccount{})
	require.NoError(t, err)
	_, err = database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud-second"})
	require.NoError(t, err)

	got, err := ensureLegacyJiraAccount(cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, first, got)
	assert.FileExists(t, jira.NewTokenStore(wsDir, first).Path())
}
