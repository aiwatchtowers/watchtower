package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/linear"
	watchtowerslack "watchtower/internal/slack"
)

// startRunningPurge gives the account a running purge.
func startRunningPurge(t *testing.T, database *db.DB, source string, id int64) {
	t.Helper()
	ok, err := database.ScheduleAccountPurge(source, id, "revoked", "2026-10-24T12:00:00Z")
	require.NoError(t, err)
	require.True(t, ok)
	rows, err := database.ListAccountPurges(true)
	require.NoError(t, err)
	for _, r := range rows {
		if r.Source == source && r.AccountID == id {
			started, err := database.StartAccountPurge(r.ID)
			require.NoError(t, err)
			require.True(t, started)
		}
	}
}

// A login landing while the account's purge runs would write credentials
// the purge then deletes: it is refused and writes nothing.
func TestSlackLoginDuringPurge_Refused(t *testing.T) {
	stubSlackIdentityServer(t, "U0OWNER", "T0TEAM", "Acme Corp", "acme")
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	database := db.OpenTestDB(t)
	id, err := database.CreateSlackAccount(db.SlackAccount{})
	require.NoError(t, err)
	startRunningPurge(t, database, "slack", id)

	_, err = connectSlackAccount(context.Background(), cfg, database, id,
		&auth.OAuthResult{AccessToken: "xoxp-new"}, false, &bytes.Buffer{})
	require.ErrorIs(t, err, errLoginDuringPurge)
	assert.Contains(t, err.Error(), "watchtower accounts purges")
	assert.False(t, watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id).Exists())
	acct, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	assert.Empty(t, acct.TeamID, "the row is not touched")
}

func TestGoogleLoginDuringPurge_Refused(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{})
	require.NoError(t, err)
	startRunningPurge(t, database, "google", id)
	orig := googleOAuthLogin
	googleOAuthLogin = func(context.Context, calendar.GoogleOAuthConfig, io.Writer, ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		return &calendar.OAuthToken{AccessToken: "new", RefreshToken: "r"}, nil
	}
	t.Cleanup(func() { googleOAuthLogin = orig })

	cmd := &cobra.Command{}
	cmd.SetOut(io.Discard)
	cmd.SetErr(io.Discard)
	cmd.SetContext(context.Background())
	_, err = loginAndSaveGoogleToken(cmd, cfg, database, id, calendar.GoogleOAuthConfig{}, nil, true, false, false)
	require.ErrorIs(t, err, errLoginDuringPurge)
	assert.False(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Exists())
}

func TestJiraLoginDuringPurge_Refused(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test"}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	id, err := database.CreateJiraAccount(db.JiraAccount{})
	require.NoError(t, err)
	startRunningPurge(t, database, "jira", id)

	cmd := &cobra.Command{}
	cmd.SetContext(context.Background())
	_, err = connectJiraAccount(cmd, cfg, database, id, &jira.OAuthToken{AccessToken: "new"},
		jira.CloudResource{ID: "c1", URL: "https://acme.example.com", Name: "acme"}, false)
	require.ErrorIs(t, err, errLoginDuringPurge)
	assert.False(t, jira.NewTokenStore(cfg.WorkspaceDir(), id).Exists())
	acct, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Empty(t, acct.CloudID, "the row is not touched")
}

func TestLinearLoginDuringPurge_Refused(t *testing.T) {
	cfg := linearTestEnv(t, &acmeViewer)
	database := db.OpenTestDB(t)
	id, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "old"}, "")
	require.NoError(t, err)
	acct, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	startRunningPurge(t, database, "linear", id)

	err = relinkLinearAccount(context.Background(), cfg, database, acct, &linear.Token{AccessToken: "fresh"})
	require.ErrorIs(t, err, errLoginDuringPurge)
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "old", tok.AccessToken, "the token is untouched")
}

// `linear add` of a removed workspace revives its account: refused too while
// that account's purge runs, and the scratch row is discarded.
func TestLinearAddDuringPurge_RevivalRefused(t *testing.T) {
	cfg := linearTestEnv(t, &acmeViewer)
	database := db.OpenTestDB(t)
	first, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "a"}, "")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(cfg.WorkspaceDir(), first).Delete())
	require.NoError(t, database.SetLinearAccountRemoved(first))
	startRunningPurge(t, database, "linear", first)

	_, _, err = connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "new"}, "")
	require.ErrorIs(t, err, errLoginDuringPurge)
	assert.False(t, linear.NewTokenStore(cfg.WorkspaceDir(), first).Exists())
	a, err := database.GetLinearAccount(first)
	require.NoError(t, err)
	assert.Equal(t, "removed", a.Status)
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 2)
	assert.Equal(t, "removed", accounts[1].Status)
	assert.False(t, linear.NewTokenStore(cfg.WorkspaceDir(), accounts[1].ID).Exists())
}
