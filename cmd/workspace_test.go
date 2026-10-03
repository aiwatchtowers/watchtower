package cmd

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// workspaceInitHome isolates HOME (the data root) and points flagConfig at a
// config file that does not exist yet — a clean install before onboarding.
func workspaceInitHome(t *testing.T) (home, configPath string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	configPath = filepath.Join(t.TempDir(), "config.yaml")
	old := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = old })
	return home, configPath
}

// workspaceDirs lists the workspace directories under the data root.
func workspaceDirs(t *testing.T) []string {
	t.Helper()
	root, err := config.DataRoot()
	require.NoError(t, err)
	entries, err := os.ReadDir(root)
	require.NoError(t, err)
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	return names
}

func TestWorkspaceInit_FreshHomeCreatesDefaultWorkspace(t *testing.T) {
	_, configPath := workspaceInitHome(t)

	stdout, _, err := runRootCmd(t, []*cobra.Command{workspaceInitCmd},
		"workspace", "init", "--json", "--config", configPath)
	require.NoError(t, err)

	var res workspaceInitResult
	require.NoError(t, json.Unmarshal([]byte(stdout), &res))
	assert.Equal(t, "default", res.Workspace)
	assert.True(t, res.Created)
	assert.FileExists(t, res.DBPath)

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	assert.Equal(t, "default", cfg.ActiveWorkspace)
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Contains(t, string(data), "active_workspace: default",
		"the workspace is recorded in the file, not only resolved from disk")
}

func TestWorkspaceInit_CustomName(t *testing.T) {
	_, configPath := workspaceInitHome(t)

	res, err := initWorkspace(configPath, "", "acme")
	require.NoError(t, err)
	assert.Equal(t, "acme", res.Workspace)
	assert.Equal(t, []string{"acme"}, workspaceDirs(t))
}

func TestWorkspaceInit_RejectsInvalidName(t *testing.T) {
	_, configPath := workspaceInitHome(t)

	_, err := initWorkspace(configPath, "", "../escape")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid workspace name")
	assert.NoFileExists(t, configPath)
}

func TestWorkspaceInit_RepeatIsNoOp(t *testing.T) {
	_, configPath := workspaceInitHome(t)

	first, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	before, err := os.ReadFile(configPath)
	require.NoError(t, err)

	second, err := initWorkspace(configPath, "", "other")
	require.NoError(t, err)
	assert.Equal(t, "default", second.Workspace, "an existing workspace wins over --name")
	assert.False(t, second.Created)
	assert.Equal(t, first.DBPath, second.DBPath)

	after, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "a repeat run must not rewrite config.yaml")
	assert.Equal(t, []string{"default"}, workspaceDirs(t))
}

func TestWorkspaceInit_KeepsAnExplicitWorkspace(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: acme\n"), 0o600))

	res, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	assert.Equal(t, "acme", res.Workspace)
	assert.True(t, res.Created, "the named workspace had no database yet")
	assert.Equal(t, []string{"acme"}, workspaceDirs(t))
}

// A config without active_workspace on a data root holding exactly one
// workspace database resolves to it: init adopts that workspace and writes
// its name, instead of creating "default" beside it.
func TestWorkspaceInit_AdoptsTheSingleExistingWorkspace(t *testing.T) {
	home, configPath := workspaceInitHome(t)
	seedWorkspaceDB(t, home, "acme")

	res, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	assert.Equal(t, "acme", res.Workspace)
	assert.False(t, res.Created)
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Contains(t, string(data), "active_workspace: acme")
}

func TestWorkspaceInit_RefusesWhenSeveralWorkspacesHoldADatabase(t *testing.T) {
	home, configPath := workspaceInitHome(t)
	seedWorkspaceDB(t, home, "alpha")
	seedWorkspaceDB(t, home, "zenith")

	_, err := initWorkspace(configPath, "", "default")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "several workspaces hold a database")
	assert.ElementsMatch(t, []string{"alpha", "zenith"}, workspaceDirs(t))
	assert.NoFileExists(t, configPath)
}

// After init, the commands that used to fail without a Slack login work:
// the db-migrate preamble, the sync config check, the Google and Jira account
// commands, and a daemon that has no sources and idles.
func TestWorkspaceInit_UnblocksCommandsWithoutSlack(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)

	database, err := openDBFromConfig()
	require.NoError(t, err)
	require.NoError(t, database.Close())

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	require.NoError(t, validateSyncConfig(cfg))

	stdout, _, err := runRootCmd(t, nil, "google", "accounts", "--config", configPath)
	require.NoError(t, err)
	assert.Contains(t, stdout, "No Google accounts connected.")

	_, _, err = runRootCmd(t, nil, "jira", "accounts", "--config", configPath)
	require.NoError(t, err)

	database, err = db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	logger := log.New(io.Discard, "", 0)
	orchestrators := wireSlackSyncers(database, cfg, logger)
	assert.Empty(t, orchestrators)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan error, 1)
	go func() { done <- runSyncDaemon(ctx, cfg, database, logger, orchestrators) }()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(60 * time.Second):
		t.Fatal("a daemon with no sources did not stop on a cancelled context")
	}
}

func TestSaveAuthResult_AfterWorkspaceInitReusesTheWorkspace(t *testing.T) {
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)

	result := &auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"}
	info, err := saveAuthResult(newSaveAuthResultCmd(), result)
	require.NoError(t, err)
	assert.Equal(t, "default", info.Workspace)
	assert.Equal(t, []string{"default"}, workspaceDirs(t), "a Slack login must not fork a second workspace")

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	assert.Equal(t, "default", cfg.ActiveWorkspace)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	accounts, err := database.ListSlackAccounts()
	require.NoError(t, err)
	require.NoError(t, database.Close())
	require.Len(t, accounts, 1)
	assert.Equal(t, "T123", accounts[0].TeamID)

	// A re-login into the same team stays in the same workspace too.
	info, err = saveAuthResult(newSaveAuthResultCmd(), result)
	require.NoError(t, err)
	assert.Equal(t, "default", info.Workspace)
	assert.Equal(t, []string{"default"}, workspaceDirs(t))
}

// connectAcme logs into team T123 from a fresh `workspace init` workspace,
// so account #1 of "default" is Acme.
func connectAcme(t *testing.T, configPath string) {
	t.Helper()
	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	_, err = saveAuthResult(newSaveAuthResultCmd(),
		&auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"})
	require.NoError(t, err)
}

func betaLogin() *auth.OAuthResult {
	return &auth.OAuthResult{AccessToken: "xoxp-beta", TeamID: "T999", TeamName: "Beta Inc", UserID: "U789"}
}

// A login into a different team while account #1 is live is refused with a
// pointer to `slack add` (owner decision 2026-10-03): reusing the workspace
// would re-consent account #1 with the other team's token, and forking a
// team-named workspace silently switched the install away from its data.
func TestSaveAuthResult_DifferentTeamIsRefusedWithSlackAddHint(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	connectAcme(t, configPath)
	before, err := os.ReadFile(configPath)
	require.NoError(t, err)

	stubSlackIdentityServer(t, "U789", "T999", "Beta Inc", "beta")
	_, err = saveAuthResult(newSaveAuthResultCmd(), betaLogin())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "watchtower slack add")
	assert.Contains(t, err.Error(), "Acme Corp")
	assert.Contains(t, err.Error(), "--workspace <new-name>")
	assert.Less(t, len(err.Error()), 200, "the Desktop's Reconnect shows only stderr's first 200 characters")
	assert.Equal(t, []string{"default"}, workspaceDirs(t), "no team-named workspace is forked")

	after, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, string(before), string(after), "active_workspace is unchanged")
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	accounts, err := database.ListSlackAccounts()
	require.NoError(t, err)
	require.NoError(t, database.Close())
	require.Len(t, accounts, 1)
	assert.Equal(t, "T123", accounts[0].TeamID, "account #1 is not re-consented with the other team")
}

// --workspace pins the login: a different team keeps the old behaviour and
// lands in the team-named workspace.
func TestSaveAuthResult_DifferentTeamWithWorkspaceFlagKeepsOldBehaviour(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	connectAcme(t, configPath)
	old := flagWorkspace
	flagWorkspace = "default"
	t.Cleanup(func() { flagWorkspace = old })

	stubSlackIdentityServer(t, "U789", "T999", "Beta Inc", "beta")
	info, err := saveAuthResult(newSaveAuthResultCmd(), betaLogin())
	require.NoError(t, err)
	assert.Equal(t, "beta-inc", info.Workspace)
	assert.ElementsMatch(t, []string{"default", "beta-inc"}, workspaceDirs(t))
}

// A removed account #1 is no live connection to protect: the login keeps the
// old team-named workspace rather than re-consenting it with another team.
func TestSaveAuthResult_DifferentTeamOverRemovedAccountKeepsTeamNamedWorkspace(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	connectAcme(t, configPath)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountRemoved(1))
	require.NoError(t, database.Close())

	stubSlackIdentityServer(t, "U789", "T999", "Beta Inc", "beta")
	info, err := saveAuthResult(newSaveAuthResultCmd(), betaLogin())
	require.NoError(t, err)
	assert.Equal(t, "beta-inc", info.Workspace)
}

// seedWorkspaceDB creates a migrated watchtower.db for workspace name under
// home's data root.
func seedWorkspaceDB(t *testing.T, home, name string) {
	t.Helper()
	dir := filepath.Join(home, ".local", "share", "watchtower", name)
	require.NoError(t, os.MkdirAll(dir, 0o700))
	database, err := db.Open(filepath.Join(dir, "watchtower.db"))
	require.NoError(t, err)
	require.NoError(t, database.Close())
}

// --workspace selects the workspace for this run; it is written to the file
// only when the file names none yet.
func TestWorkspaceInit_HonoursTheWorkspaceFlag(t *testing.T) {
	_, configPath := workspaceInitHome(t)
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: acme\n"), 0o600))

	res, err := initWorkspace(configPath, "beta", "default")
	require.NoError(t, err)
	assert.Equal(t, "beta", res.Workspace)
	assert.True(t, res.Created)
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, "active_workspace: acme\n", string(data), "an override does not switch the configured workspace")

	_, freshConfig := workspaceInitHome(t)
	res, err = initWorkspace(freshConfig, "beta", "default")
	require.NoError(t, err)
	assert.Equal(t, "beta", res.Workspace)
	data, err = os.ReadFile(freshConfig)
	require.NoError(t, err)
	assert.Contains(t, string(data), "active_workspace: beta")
}

// Only a missing config file starts empty: an unreadable one is an error and
// is never overwritten with defaults.
func TestWriteWorkspaceScaffold_UnreadableConfigIsAnError(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a 0000 file")
	}
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("ai:\n  model: custom\n"), 0o600))
	require.NoError(t, os.Chmod(configPath, 0o000))
	t.Cleanup(func() { _ = os.Chmod(configPath, 0o600) })

	err := writeWorkspaceScaffold(configPath, "default", true)
	require.ErrorContains(t, err, "reading config")
	require.NoError(t, os.Chmod(configPath, 0o600))
	data, err := os.ReadFile(configPath)
	require.NoError(t, err)
	assert.Equal(t, "ai:\n  model: custom\n", string(data))
}

func TestSaveAuthResult_HonoursTheWorkspaceFlag(t *testing.T) {
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	home, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	seedWorkspaceDB(t, home, "other")
	old := flagWorkspace
	flagWorkspace = "other"
	t.Cleanup(func() { flagWorkspace = old })

	info, err := saveAuthResult(newSaveAuthResultCmd(),
		&auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"})
	require.NoError(t, err)
	assert.Equal(t, "other", info.Workspace)
	assert.ElementsMatch(t, []string{"default", "other"}, workspaceDirs(t))
}

// Several workspaces with a database and none selected: the login fails
// instead of guessing (or forking a third, team-named one).
func TestSaveAuthResult_AmbiguousWorkspaceFailsTheLogin(t *testing.T) {
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	home, _ := workspaceInitHome(t)
	seedWorkspaceDB(t, home, "alpha")
	seedWorkspaceDB(t, home, "zenith")

	_, err := saveAuthResult(newSaveAuthResultCmd(),
		&auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"})
	require.ErrorContains(t, err, "several workspaces hold a database")
	assert.ElementsMatch(t, []string{"alpha", "zenith"}, workspaceDirs(t))
}

// A database path that cannot be checked (not merely absent) fails the
// login rather than falling back to a team-named workspace.
func TestSaveAuthResult_UncheckableDatabaseFailsTheLogin(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	_, configPath := workspaceInitHome(t)
	res, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	dir := filepath.Dir(res.DBPath)
	require.NoError(t, os.Chmod(dir, 0o000))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	_, err = saveAuthResult(newSaveAuthResultCmd(),
		&auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"})
	require.ErrorContains(t, err, "checking database")
}

// Legacy account #1 seeded while offline has no team id yet: it is this
// install's own Slack connection, so the login stays in the workspace.
func TestSaveAuthResult_LegacyAccountWithoutTeamIsReused(t *testing.T) {
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	_, configPath := workspaceInitHome(t)
	res, err := initWorkspace(configPath, "", "default")
	require.NoError(t, err)
	database, err := db.Open(res.DBPath)
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	require.Equal(t, int64(1), id)
	require.NoError(t, database.Close())

	info, err := saveAuthResult(newSaveAuthResultCmd(),
		&auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"})
	require.NoError(t, err)
	assert.Equal(t, "default", info.Workspace)
	assert.Equal(t, []string{"default"}, workspaceDirs(t))
}

// --workspace naming a workspace with no database yet: the login creates and
// uses it rather than falling back to a team-named one.
func TestSaveAuthResult_WorkspaceFlagWithoutDatabaseIsCreated(t *testing.T) {
	stubSlackIdentityServer(t, "U456", "T123", "Acme Corp", "acme")
	workspaceInitHome(t)
	old := flagWorkspace
	flagWorkspace = "chosen"
	t.Cleanup(func() { flagWorkspace = old })

	info, err := saveAuthResult(newSaveAuthResultCmd(),
		&auth.OAuthResult{AccessToken: "xoxp-acme", TeamID: "T123", TeamName: "Acme Corp", UserID: "U456"})
	require.NoError(t, err)
	assert.Equal(t, "chosen", info.Workspace)
	assert.Equal(t, []string{"chosen"}, workspaceDirs(t))
}
