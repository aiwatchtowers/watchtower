package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/linear"
)

func TestResolveLinearAccount(t *testing.T) {
	database := db.OpenTestDB(t)
	_, err := resolveLinearAccount(database, 0)
	assert.ErrorContains(t, err, "no Linear workspace connected")
	a, err := database.CreateLinearAccount("A")
	require.NoError(t, err)
	got, err := resolveLinearAccount(database, 0)
	require.NoError(t, err)
	assert.Equal(t, a, got.ID)
	b, err := database.CreateLinearAccount("B")
	require.NoError(t, err)
	_, err = resolveLinearAccount(database, 0)
	assert.ErrorContains(t, err, "--account")
	require.NoError(t, database.SetLinearAccountRemoved(b))
	_, err = resolveLinearAccount(database, b)
	assert.ErrorContains(t, err, "was removed")
}

func TestPrintLinearAccountsJSON(t *testing.T) {
	database := db.OpenTestDB(t)
	id, err := database.CreateLinearAccount("Work")
	require.NoError(t, err)
	require.NoError(t, database.UpdateLinearAccountConnection(id, "org-1", "acme", "Acme"))
	var buf bytes.Buffer
	require.NoError(t, printLinearAccounts(&buf, database, true))
	var rows []map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &rows))
	require.Len(t, rows, 1)
	assert.Equal(t, "https://linear.app/acme", rows[0]["url"])
	for _, k := range []string{"id", "label", "org_name", "url", "status", "enabled", "error"} {
		assert.Contains(t, rows[0], k)
	}
}

func TestLinearCommandsRegistered(t *testing.T) {
	for _, name := range []string{"add", "login", "accounts", "enable", "disable", "remove", "teams", "sync", "status"} {
		c, _, err := linearCmd.Find([]string{name})
		require.NoError(t, err, name)
		assert.Equal(t, name, c.Name())
	}
}

// linearTestEnv points HOME and the config path at temp dirs and stubs the
// viewer call, so add/login run without a browser or the network.
func linearTestEnv(t *testing.T, viewers map[int64]linear.Viewer) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	oldCfg, oldFetch := flagConfig, linearFetchViewer
	flagConfig = filepath.Join(t.TempDir(), "config.yaml")
	t.Cleanup(func() { flagConfig, linearFetchViewer = oldCfg, oldFetch })
	cfg := &config.Config{ActiveWorkspace: "test"}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	linearFetchViewer = func(_ context.Context, _ *config.Config, id int64) (linear.Viewer, error) {
		if v, ok := viewers[id]; ok {
			return v, nil
		}
		if v, ok := viewers[0]; ok {
			return v, nil
		}
		return linear.Viewer{}, errors.New("viewer unavailable")
	}
	return cfg
}

var acmeViewer = linear.Viewer{UserID: "user-1", Email: "owner@example.com", Name: "Owner", OrgID: "org-1", OrgName: "Acme", URLKey: "acme"}

func TestConnectLinearAccount_New(t *testing.T) {
	cfg := linearTestEnv(t, map[int64]linear.Viewer{0: acmeViewer})
	database := db.OpenTestDB(t)
	id, revived, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "a"}, "")
	require.NoError(t, err)
	assert.False(t, revived)
	a, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "org-1", a.OrgID)
	assert.Equal(t, "user-1", a.OwnerUserID)
}

func TestConnectLinearAccount_DuplicateRefused(t *testing.T) {
	cfg := linearTestEnv(t, map[int64]linear.Viewer{0: acmeViewer})
	database := db.OpenTestDB(t)
	first, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "a"}, "")
	require.NoError(t, err)
	_, _, err = connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "b"}, "")
	require.ErrorContains(t, err, fmt.Sprintf("already connected as account %d", first))
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 2)
	assert.Equal(t, "removed", accounts[1].Status)
	assert.False(t, linear.NewTokenStore(cfg.WorkspaceDir(), accounts[1].ID).Exists())
}

func TestConnectLinearAccount_RevivesRemoved(t *testing.T) {
	cfg := linearTestEnv(t, map[int64]linear.Viewer{0: acmeViewer})
	database := db.OpenTestDB(t)
	first, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "a"}, "Work")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(cfg.WorkspaceDir(), first).Delete())
	require.NoError(t, database.SetLinearAccountRemoved(first))

	id, revived, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "new"}, "")
	require.NoError(t, err)
	assert.True(t, revived)
	assert.Equal(t, first, id)
	a, err := database.GetLinearAccount(first)
	require.NoError(t, err)
	assert.Equal(t, "ok", a.Status)
	assert.True(t, a.Enabled)
	assert.Equal(t, "Work", a.Label)
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), first).Load()
	require.NoError(t, err)
	assert.Equal(t, "new", tok.AccessToken)
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 2)
	assert.Equal(t, "removed", accounts[1].Status)
	assert.False(t, linear.NewTokenStore(cfg.WorkspaceDir(), accounts[1].ID).Exists())
}

func TestConnectLinearAccount_FailureLeavesNothingHalfConnected(t *testing.T) {
	cfg := linearTestEnv(t, nil) // viewer fetch fails
	database := db.OpenTestDB(t)
	_, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "a"}, "")
	require.Error(t, err)
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "removed", accounts[0].Status)
	assert.False(t, linear.NewTokenStore(cfg.WorkspaceDir(), accounts[0].ID).Exists())
}

func TestRelinkLinearAccount(t *testing.T) {
	cfg := linearTestEnv(t, map[int64]linear.Viewer{0: acmeViewer})
	database := db.OpenTestDB(t)
	id, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "old"}, "")
	require.NoError(t, err)
	require.NoError(t, database.SetLinearAccountAuthState(id, "revoked", "x"))
	acct, err := database.GetLinearAccount(id)
	require.NoError(t, err)

	// Wrong workspace: refused, token untouched.
	other := acmeViewer
	other.OrgID, other.OrgName = "org-2", "Other"
	linearFetchViewer = func(context.Context, *config.Config, int64) (linear.Viewer, error) { return other, nil }
	err = relinkLinearAccount(context.Background(), cfg, database, acct, &linear.Token{AccessToken: "wrong"})
	require.ErrorContains(t, err, "this login is for workspace Other, but account")
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "old", tok.AccessToken)

	// Same workspace: saved, status ok.
	linearFetchViewer = func(context.Context, *config.Config, int64) (linear.Viewer, error) { return acmeViewer, nil }
	require.NoError(t, relinkLinearAccount(context.Background(), cfg, database, acct, &linear.Token{AccessToken: "fresh"}))
	tok, err = linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "fresh", tok.AccessToken)
	acct, err = database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
}
