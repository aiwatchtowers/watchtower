package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"sort"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// Placeholder client ids, not real Slack apps.
const (
	jsonSharedID = "1000.0001" // the retired public shared app
	jsonCorpID   = "2000.0002" // a company app a build bakes
	jsonSetupID  = "3000.0003" // a workspace app made by setup
)

// setSlackBuild sets the build's baked Slack app and retired shared id for
// one test, with the env overrides cleared.
func setSlackBuild(t *testing.T, bakedID, bakedSecret, retiredID string) {
	t.Helper()
	t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", "")
	t.Setenv("WATCHTOWER_OAUTH_CLIENT_SECRET", "")
	oldID, oldSecret, oldRetired := auth.DefaultClientID, auth.DefaultClientSecret, auth.RetiredSharedClientID
	auth.DefaultClientID, auth.DefaultClientSecret, auth.RetiredSharedClientID = bakedID, bakedSecret, retiredID
	t.Cleanup(func() {
		auth.DefaultClientID, auth.DefaultClientSecret, auth.RetiredSharedClientID = oldID, oldSecret, oldRetired
	})
}

// slackAccountsWorkspace makes a workspace with one account per client id
// (status ok) and returns the config path and the account ids.
func slackAccountsWorkspace(t *testing.T, clientIDs ...string) (string, []int64) {
	t.Helper()
	_, configPath := workspaceInitHome(t)
	_, err := initWorkspace(configPath, "", "default", false)
	require.NoError(t, err)
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	var ids []int64
	for i, cid := range clientIDs {
		team := "T0ACME" + string(rune('A'+i))
		id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: team, TeamName: "acme"})
		require.NoError(t, err)
		if cid != "" {
			require.NoError(t, database.SetSlackAccountClientID(id, cid))
		}
		require.NoError(t, database.SetSlackAccountAuthState(id, "ok", ""))
		ids = append(ids, id)
	}
	return configPath, ids
}

func runSlackAccountsJSON(t *testing.T, configPath string) map[string]any {
	t.Helper()
	stdout, _, err := runRootCmd(t, []*cobra.Command{slackCmd, slackAccountsCmd},
		"slack", "accounts", "--json", "--config", configPath)
	require.NoError(t, err)
	var doc map[string]any
	require.NoError(t, json.Unmarshal([]byte(stdout), &doc), stdout)
	return doc
}

func jsonAccounts(t *testing.T, doc map[string]any) []map[string]any {
	t.Helper()
	raw, ok := doc["accounts"].([]any)
	require.True(t, ok, "accounts is an array")
	out := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		out = append(out, r.(map[string]any))
	}
	return out
}

func slackAccountsDocKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestSlackAccountsJSON_Shape(t *testing.T) {
	setSlackBuild(t, "", "", "")
	configPath, _ := slackAccountsWorkspace(t, jsonSetupID)
	doc := runSlackAccountsJSON(t, configPath)

	assert.Equal(t, []string{"accounts", "builtin_app"}, slackAccountsDocKeys(doc))
	accounts := jsonAccounts(t, doc)
	require.Len(t, accounts, 1)
	assert.Equal(t, []string{
		"client_id", "enabled", "id", "label", "relogin", "shared_app", "status", "team_id", "team_name",
	}, slackAccountsDocKeys(accounts[0]))
	assert.Equal(t, jsonSetupID, accounts[0]["client_id"])
	assert.Equal(t, "ok", accounts[0]["status"])
	assert.Equal(t, true, accounts[0]["enabled"])
}

func TestSlackAccountsJSON_EmptyListIsAnArray(t *testing.T) {
	setSlackBuild(t, "", "", "")
	configPath, _ := slackAccountsWorkspace(t)
	doc := runSlackAccountsJSON(t, configPath)
	assert.Equal(t, []any{}, doc["accounts"])
}

func TestSlackAccountsJSON_BuiltinApp(t *testing.T) {
	t.Run("env id and secret", func(t *testing.T) {
		setSlackBuild(t, "", "", "")
		t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", jsonCorpID)
		t.Setenv("WATCHTOWER_OAUTH_CLIENT_SECRET", "test-secret")
		configPath, _ := slackAccountsWorkspace(t)
		assert.Equal(t, true, runSlackAccountsJSON(t, configPath)["builtin_app"])
	})
	t.Run("id without a secret", func(t *testing.T) {
		setSlackBuild(t, jsonCorpID, "", "")
		configPath, _ := slackAccountsWorkspace(t)
		assert.Equal(t, false, runSlackAccountsJSON(t, configPath)["builtin_app"])
	})
	t.Run("none", func(t *testing.T) {
		setSlackBuild(t, "", "", "")
		configPath, _ := slackAccountsWorkspace(t)
		assert.Equal(t, false, runSlackAccountsJSON(t, configPath)["builtin_app"])
	})
}

func TestSlackAccountsJSON_Relogin(t *testing.T) {
	cases := []struct {
		name      string
		bakedID   string
		retiredID string
		clientID  string
		want      string
	}{
		{"shared id while baked", jsonSharedID, jsonSharedID, jsonSharedID, "builtin"},
		{"shared id after nothing is baked", "", jsonSharedID, jsonSharedID, "move"},
		{"company app id", jsonCorpID, jsonSharedID, jsonSetupID, "connect"},
		{"corp-baked id while baked", jsonCorpID, jsonSharedID, jsonCorpID, "builtin"},
		{"corp-baked id after nothing is baked", "", jsonSharedID, jsonCorpID, "connect"},
		// Nothing baked and no retired id: the backfill has no source, the
		// row stays empty and signs in again through the link or MDM (A17).
		// (An empty row in a build with an app is backfilled before listing.)
		{"empty id, no built-in app", "", "", "", "connect"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			secret := ""
			if tc.bakedID != "" {
				secret = "test-secret"
			}
			setSlackBuild(t, tc.bakedID, secret, tc.retiredID)
			configPath, _ := slackAccountsWorkspace(t, tc.clientID)
			accounts := jsonAccounts(t, runSlackAccountsJSON(t, configPath))
			require.Len(t, accounts, 1)
			assert.Equal(t, tc.clientID, accounts[0]["client_id"])
			assert.Equal(t, tc.want, accounts[0]["relogin"])
		})
	}
}

// The shared-app flag follows the client id alone: the build flavor never
// changes it, and a removed row is never shared.
func TestSlackAccountsJSON_SharedAppByClientIDOnly(t *testing.T) {
	oldFlavor := BuildFlavor
	t.Cleanup(func() { BuildFlavor = oldFlavor })
	for _, flavor := range []string{"", "public", "corp"} {
		t.Run("flavor "+flavor, func(t *testing.T) {
			BuildFlavor = flavor
			setSlackBuild(t, jsonCorpID, "test-secret", jsonSharedID)
			configPath, ids := slackAccountsWorkspace(t, jsonSharedID, jsonCorpID, jsonSetupID, jsonSharedID)
			cfg, err := config.Load(configPath)
			require.NoError(t, err)
			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			require.NoError(t, database.SetSlackAccountAuthState(ids[3], "removed", ""))
			database.Close()

			accounts := jsonAccounts(t, runSlackAccountsJSON(t, configPath))
			require.Len(t, accounts, 4, "removed rows are listed")
			got := []any{accounts[0]["shared_app"], accounts[1]["shared_app"], accounts[2]["shared_app"], accounts[3]["shared_app"]}
			assert.Equal(t, []any{true, false, false, false}, got)
			assert.Equal(t, "removed", accounts[3]["status"])
		})
	}
}

// `slack accounts` runs the A17 backfill before listing.
func TestSlackAccountsJSON_BackfillsEmptyClientIDs(t *testing.T) {
	setSlackBuild(t, jsonSharedID, "test-secret", jsonSharedID)
	configPath, _ := slackAccountsWorkspace(t, "", jsonSetupID)
	accounts := jsonAccounts(t, runSlackAccountsJSON(t, configPath))
	require.Len(t, accounts, 2)
	assert.Equal(t, jsonSharedID, accounts[0]["client_id"])
	assert.Equal(t, true, accounts[0]["shared_app"])
	assert.Equal(t, jsonSetupID, accounts[1]["client_id"])
}

// The sync daemon's start runs the A17 backfill once (here through a one-shot
// sync, which shares the start path and stops at "not connected" because the
// only account is disabled).
func TestSyncStart_BackfillsSlackClientIDs(t *testing.T) {
	setSlackBuild(t, jsonCorpID, "test-secret", jsonSharedID)
	configPath, ids := slackAccountsWorkspace(t, "")
	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	require.NoError(t, database.SetSlackAccountEnabled(ids[0], false))

	_, _, err = runRootCmd(t, []*cobra.Command{syncCmd}, "sync", "--config", configPath)
	require.ErrorContains(t, err, "slack is not connected")

	a, err := database.GetSlackAccount(ids[0])
	require.NoError(t, err)
	assert.Equal(t, jsonCorpID, a.ClientID)
}

// Every connect runs the A17 backfill: an older row without a client id gets
// the build's one, while the connected row keeps the id it signed in with.
func TestConnectSlackAccount_BackfillsOtherRows(t *testing.T) {
	setSlackBuild(t, jsonCorpID, "test-secret", jsonSharedID)
	stubSlackIdentityServer(t, "U0OWNER", "T0TEAM", "Acme Corp", "acme")
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)
	oldID, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0OLD", TeamName: "acme-old"})
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)

	_, err = connectSlackAccount(context.Background(), cfg, database, id,
		&auth.OAuthResult{AccessToken: "xoxp-new"}, true, jsonSetupID, &bytes.Buffer{})
	require.NoError(t, err)

	old, err := database.GetSlackAccount(oldID)
	require.NoError(t, err)
	assert.Equal(t, jsonCorpID, old.ClientID)
	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Equal(t, jsonSetupID, acct.ClientID)
}
