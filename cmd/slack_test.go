package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	goslack "github.com/slack-go/slack"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// stubSlackIdentityServer stands up an httptest server answering auth.test and
// team.info, and points newSlackClientForToken at it for the duration of the
// test — so the seed/connect paths resolve a token's identity without a live
// network call. Restored automatically via t.Cleanup.
func stubSlackIdentityServer(t *testing.T, userID, teamID, teamName, teamDomain string) {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/auth.test", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"user_id": userID,
			"user":    "owner",
			"team_id": teamID,
		})
	})
	mux.HandleFunc("/team.info", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"team": map[string]any{
				"id":     teamID,
				"name":   teamName,
				"domain": teamDomain,
			},
		})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	original := newSlackClientForToken
	newSlackClientForToken = func(token string) *watchtowerslack.Client {
		return watchtowerslack.NewClientWithAPIUnlimited(goslack.New(token, goslack.OptionAPIURL(srv.URL+"/")))
	}
	t.Cleanup(func() { newSlackClientForToken = original })
}

// writeLegacyConfig writes a pre-multi-account config.yaml with a workspace
// Slack token and points flagConfig at it. Returns the config path.
func writeLegacyConfig(t *testing.T, token string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	content := "active_workspace: test\nworkspaces:\n  test:\n    slack_token: " + token + "\n"
	require.NoError(t, os.WriteFile(path, []byte(content), 0o600))
	original := flagConfig
	flagConfig = path
	t.Cleanup(func() { flagConfig = original })
	return path
}

func TestEnsureLegacySlackAccount_SeedsFromConfigToken(t *testing.T) {
	stubSlackIdentityServer(t, "U0OWNER", "T0TEAM", "Acme Corp", "acme")
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "xoxp-legacy-token")

	cfg := &config.Config{
		ActiveWorkspace: "test",
		Workspaces:      map[string]*config.WorkspaceConfig{"test": {SlackToken: "xoxp-legacy-token"}},
	}
	database := db.OpenTestDB(t)

	id, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, int64(1), id)

	// The per-account token file was written with the legacy token.
	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	assert.True(t, store.Exists(), "slack_token_%d.json must exist so wireSlackSyncers can find it", id)
	tok, err := store.Load()
	require.NoError(t, err)
	require.NotNil(t, tok)
	assert.Equal(t, "xoxp-legacy-token", tok.AccessToken)

	// The row carries the resolved team info + namespaced current_user_id.
	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "T0TEAM", acct.TeamID)
	assert.Equal(t, "Acme Corp", acct.TeamName)
	assert.Equal(t, "acme", acct.TeamDomain)
	assert.Equal(t, watchtowerslack.Namespace(id, "U0OWNER"), acct.CurrentUserID)
}

func TestEnsureLegacySlackAccount_SecondCallIsNoop(t *testing.T) {
	stubSlackIdentityServer(t, "U0OWNER", "T0TEAM", "Acme Corp", "acme")
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "xoxp-legacy-token")

	cfg := &config.Config{
		ActiveWorkspace: "test",
		Workspaces:      map[string]*config.WorkspaceConfig{"test": {SlackToken: "xoxp-legacy-token"}},
	}
	database := db.OpenTestDB(t)

	id1, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.Equal(t, int64(1), id1)

	id2, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, id1, id2, "second call returns the existing id without re-creating")

	accounts, err := database.ListSlackAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1, "no duplicate account row should have been created")
}

func TestEnsureLegacySlackAccount_SeededRowStillMaterializesTokenFile(t *testing.T) {
	// Reproduces the state an upgrading install is in after migration 00048
	// seeds slack_accounts row #1 (it had synced Slack data) but the token is
	// still in config.yaml, since SQL can't touch it. The row-existence guard
	// must NOT make the token-file materialization unreachable.
	stubSlackIdentityServer(t, "U0OWNER", "T0TEAM", "Acme Corp", "acme")
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "xoxp-legacy-token")

	cfg := &config.Config{
		ActiveWorkspace: "test",
		Workspaces:      map[string]*config.WorkspaceConfig{"test": {SlackToken: "xoxp-legacy-token"}},
	}
	database := db.OpenTestDB(t)

	// What migration 00048 step 2 does on an install with synced Slack data.
	seededID, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0TEAM", TeamName: "Acme Corp", CurrentUserID: "1:U0OWNER"})
	require.NoError(t, err)

	id, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Equal(t, seededID, id)

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	assert.True(t, store.Exists(),
		"account %d has no slack_token_%d.json -> wireSlackSyncers skips it -> Slack sync silently stops", id, id)
	tok, err := store.Load()
	require.NoError(t, err)
	require.NotNil(t, tok)
	assert.Equal(t, "xoxp-legacy-token", tok.AccessToken)
}

func TestEnsureLegacySlackAccount_NoConfigTokenNoRowsIsCleanNoop(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfg := &config.Config{
		ActiveWorkspace: "test",
		Workspaces:      map[string]*config.WorkspaceConfig{"test": {SlackToken: ""}},
	}
	database := db.OpenTestDB(t)

	id, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	assert.Zero(t, id, "no config token and no rows is a clean no-op, not an error")

	accounts, err := database.ListSlackAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

func TestEnsureLegacySlackAccount_OfflineStillMigratesToken(t *testing.T) {
	// Identity resolution needs the network; the token-file migration must not.
	// A daemon starting offline must still move the config token to a file so
	// Slack keeps syncing — team info fills in on the next online call.
	original := newSlackClientForToken
	newSlackClientForToken = func(token string) *watchtowerslack.Client {
		return watchtowerslack.NewClientWithAPIUnlimited(goslack.New(token, goslack.OptionAPIURL("http://127.0.0.1:0/")))
	}
	t.Cleanup(func() { newSlackClientForToken = original })

	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "xoxp-legacy-token")

	cfg := &config.Config{
		ActiveWorkspace: "test",
		Workspaces:      map[string]*config.WorkspaceConfig{"test": {SlackToken: "xoxp-legacy-token"}},
	}
	database := db.OpenTestDB(t)

	id, err := ensureLegacySlackAccount(context.Background(), cfg, database, quietTestLogger())
	require.NoError(t, err)
	require.NotZero(t, id)

	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	assert.True(t, store.Exists(), "token must migrate to a file even when identity resolution fails")
}

func TestRunSlackAccounts_ZeroAccountsPrintsHelpfulLine(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")

	var out bytes.Buffer
	cmd := &cobra.Command{}
	cmd.SetOut(&out)
	cmd.SetErr(&bytes.Buffer{})

	// Force an empty DB by pointing the workspace dir at the temp HOME.
	err := runSlackAccounts(cmd, nil)
	require.NoError(t, err, "listing zero accounts must not be an error")
	assert.Contains(t, out.String(), "No Slack accounts connected")
}

// TestWireSlackSyncers_MissingTokenRecordsAuthState: an account with no token
// file (revoked/never-connected) must flip to status="error" so Desktop shows
// it needs re-login — before this fix it was silently skipped and logged only,
// with no orchestrator ever created to self-report (Orchestrator.recordAuthResult
// only runs once Run() executes, and a missing-token account never gets that far).
func TestWireSlackSyncers_MissingTokenRecordsAuthState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test", Workspaces: map[string]*config.WorkspaceConfig{"test": {}}}
	database := db.OpenTestDB(t)

	id, err := database.CreateSlackAccount(db.SlackAccount{Label: "No Token"})
	require.NoError(t, err)
	// No token file written for this account — the store.Load() nil-token branch.

	orchs := wireSlackSyncers(database, cfg, quietTestLogger())
	assert.Empty(t, orchs, "an account with no token must not get an orchestrator")

	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", acct.Status)
	assert.Contains(t, acct.Error, "no token file")
}

// TestWireSlackSyncers_AlreadyErrorDoesNotChurn: an account already flagged
// error/revoked must not have its updated_at/error message churned every
// daemon cycle by the wiring step re-flagging the same missing token.
func TestWireSlackSyncers_AlreadyErrorDoesNotChurn(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfg := &config.Config{ActiveWorkspace: "test", Workspaces: map[string]*config.WorkspaceConfig{"test": {}}}
	database := db.OpenTestDB(t)

	id, err := database.CreateSlackAccount(db.SlackAccount{Label: "Revoked"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountAuthState(id, "revoked", "user revoked access"))

	wireSlackSyncers(database, cfg, quietTestLogger())

	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acct.Status, "wiring must not overwrite an existing non-ok status")
	assert.Equal(t, "user revoked access", acct.Error)
}

// TestSlackEnable_RemovedAccountRejected: "slack enable" on a removed account
// must fail loudly instead of silently flipping enabled=1 on a row
// ListEnabledSlackAccounts still excludes (status != 'removed') — before this
// guard, the CLI printed "Account N enabled" while sync stayed off, and
// Desktop showed a confusing enabled-toggle next to a removed/red status.
func TestSlackEnable_RemovedAccountRejected(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")

	dbPath := filepath.Join(home, ".local", "share", "watchtower", "test", "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{Label: "Removed Org"})
	require.NoError(t, err)
	require.NoError(t, database.SetSlackAccountAuthState(id, "removed", ""))
	require.NoError(t, database.SetSlackAccountEnabled(id, false))
	require.NoError(t, database.Close())

	cmd := &cobra.Command{}
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})

	err = setSlackAccountEnabled(cmd, "1", true)
	require.Error(t, err, "enabling a removed account must fail, not silently succeed")
	assert.Contains(t, err.Error(), "removed")

	database2, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database2.Close()
	acct, err := database2.GetSlackAccount(1)
	require.NoError(t, err)
	assert.False(t, acct.Enabled, "the rejected enable must not have flipped the row")
}
