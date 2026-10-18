package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/spf13/cobra"
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
	require.NoError(t, printLinearAccounts(&buf, database, t.TempDir(), true))
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
func linearTestEnv(t *testing.T, viewer *linear.Viewer) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	oldCfg, oldFetch := flagConfig, linearFetchViewer
	flagConfig = filepath.Join(t.TempDir(), "config.yaml")
	t.Cleanup(func() { flagConfig, linearFetchViewer = oldCfg, oldFetch })
	cfg := &config.Config{ActiveWorkspace: "test"}
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	linearFetchViewer = func(_ context.Context, token *linear.Token) (linear.Viewer, error) {
		if viewer == nil || token.AccessToken == "" {
			return linear.Viewer{}, errors.New("viewer unavailable")
		}
		return *viewer, nil
	}
	return cfg
}

var acmeViewer = linear.Viewer{UserID: "user-1", Email: "owner@example.com", Name: "Owner", OrgID: "org-1", OrgName: "Acme", URLKey: "acme"}

func TestConnectLinearAccount_New(t *testing.T) {
	cfg := linearTestEnv(t, &acmeViewer)
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
	cfg := linearTestEnv(t, &acmeViewer)
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
	cfg := linearTestEnv(t, &acmeViewer)
	database := db.OpenTestDB(t)
	first, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "a"}, "Work")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(cfg.WorkspaceDir(), first).Delete())
	require.NoError(t, database.SetLinearAccountRemoved(first))

	// The workspace was renamed while the account was removed.
	renamed := acmeViewer
	renamed.OrgName, renamed.URLKey = "Acme Renamed", "acme-renamed"
	linearFetchViewer = func(context.Context, *linear.Token) (linear.Viewer, error) { return renamed, nil }
	id, revived, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "new"}, "")
	require.NoError(t, err)
	assert.True(t, revived)
	assert.Equal(t, first, id)
	a, err := database.GetLinearAccount(first)
	require.NoError(t, err)
	assert.Equal(t, "ok", a.Status)
	assert.True(t, a.Enabled)
	assert.Equal(t, "Work", a.Label)
	assert.Equal(t, "Acme Renamed", a.OrgName)
	assert.Equal(t, "acme-renamed", a.URLKey)
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
	cfg := linearTestEnv(t, &acmeViewer)
	database := db.OpenTestDB(t)
	id, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "old"}, "")
	require.NoError(t, err)
	require.NoError(t, database.SetLinearAccountAuthState(id, "revoked", "x"))
	acct, err := database.GetLinearAccount(id)
	require.NoError(t, err)

	// Wrong workspace: refused, token untouched.
	other := acmeViewer
	other.OrgID, other.OrgName = "org-2", "Other"
	linearFetchViewer = func(context.Context, *linear.Token) (linear.Viewer, error) { return other, nil }
	err = relinkLinearAccount(context.Background(), cfg, database, acct, &linear.Token{AccessToken: "wrong"})
	require.ErrorContains(t, err, "this login is for workspace Other, but account")
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "old", tok.AccessToken)

	// Same workspace, renamed since: saved, status ok, new name stored.
	renamed := acmeViewer
	renamed.OrgName, renamed.URLKey = "Acme Renamed", "acme-renamed"
	linearFetchViewer = func(context.Context, *linear.Token) (linear.Viewer, error) { return renamed, nil }
	require.NoError(t, relinkLinearAccount(context.Background(), cfg, database, acct, &linear.Token{AccessToken: "fresh"}))
	tok, err = linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "fresh", tok.AccessToken)
	acct, err = database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
	assert.Equal(t, "Acme Renamed", acct.OrgName)
	assert.Equal(t, "acme-renamed", acct.URLKey)

	// The viewer check is in memory: no scratch token file is ever written.
	scratch, err := filepath.Glob(filepath.Join(cfg.WorkspaceDir(), "linear_token_-*"))
	require.NoError(t, err)
	assert.Empty(t, scratch)
}

func TestLinearLoginCommands_EmptyClientIDFailsFast(t *testing.T) {
	t.Setenv("WATCHTOWER_LINEAR_CLIENT_ID", "")
	oldDefault, oldLogin := linear.DefaultLinearClientID, linearLogin
	t.Cleanup(func() { linear.DefaultLinearClientID, linearLogin = oldDefault, oldLogin })
	linear.DefaultLinearClientID = ""
	linearLogin = func(context.Context, linear.OAuthConfig, io.Writer, linear.LoginOptions) (*linear.Token, error) {
		t.Fatal("the browser flow must not start without a client id")
		return nil, nil
	}
	for _, c := range []*cobra.Command{linearAddCmd, linearLoginCmd} {
		err := c.RunE(c, nil)
		require.EqualError(t, err, "linear OAuth client id is not configured (set WATCHTOWER_LINEAR_CLIENT_ID)", c.Name())
	}
}

// linearCmdFixture is jiraCmdFixture plus the loaded config, for the Linear
// commands that read token files from the workspace dir.
func linearCmdFixture(t *testing.T) (*config.Config, *db.DB) {
	t.Helper()
	database := jiraCmdFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	return cfg, database
}

// newLinearCmd returns a command with a context and captured stdout/stderr.
func newLinearCmd(ctx context.Context) (*cobra.Command, *bytes.Buffer, *bytes.Buffer) {
	cmd := &cobra.Command{}
	var out, errOut bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&errOut)
	cmd.SetContext(ctx)
	return cmd, &out, &errOut
}

func setLinearFlagAccount(t *testing.T, id int64) {
	t.Helper()
	old := linearFlagAccount
	linearFlagAccount = id
	t.Cleanup(func() { linearFlagAccount = old })
}

func TestRunLinearSync_AccountFailureFailsCommand(t *testing.T) {
	_, database := linearCmdFixture(t)
	setLinearFlagAccount(t, 0)
	bad, err := database.CreateLinearAccount("bad")
	require.NoError(t, err)
	good, err := database.CreateLinearAccount("good")
	require.NoError(t, err)
	old := linearSyncAccount
	t.Cleanup(func() { linearSyncAccount = old })
	linearSyncAccount = func(_ context.Context, _ *config.Config, _ *db.DB, id int64) (int, error) {
		if id == bad {
			return 0, errors.New("linear graphql: boom")
		}
		return 2, nil
	}

	cmd, out, errOut := newLinearCmd(context.Background())
	err = runLinearSync(cmd, nil)
	require.ErrorContains(t, err, "linear graphql: boom")
	assert.ErrorContains(t, err, fmt.Sprintf("account %d", bad))
	assert.Contains(t, errOut.String(), fmt.Sprintf("account %d: sync failed", bad))
	assert.Contains(t, out.String(), fmt.Sprintf("account %d: 2 issues synced", good))
	acct, err := database.GetLinearAccount(bad)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status, "a plain failure is not an auth state")
}

func TestBuildLinearSyncers(t *testing.T) {
	cfg := wiringTestConfig(t)
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	database := db.OpenTestDB(t)
	logger := log.New(io.Discard, "", 0)
	noToken, err := database.CreateLinearAccount("no token")
	require.NoError(t, err)
	withToken, err := database.CreateLinearAccount("with token")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(cfg.WorkspaceDir(), withToken).Save(&linear.Token{AccessToken: "a", RefreshToken: "r"}))

	// Disabled: nothing is wired and no account is touched.
	assert.Empty(t, buildLinearSyncers(cfg, database, logger))
	acct, err := database.GetLinearAccount(noToken)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)

	cfg.Linear.Enabled = true
	syncers := buildLinearSyncers(cfg, database, logger)
	require.Len(t, syncers, 1)
	assert.Equal(t, withToken, syncers[0].AccountID())
	acct, err = database.GetLinearAccount(noToken)
	require.NoError(t, err)
	assert.Equal(t, "error", acct.Status, "an ok account without a token file goes to error")
	acct, err = database.GetLinearAccount(withToken)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
}

func TestRunLinearRemove_DeletesTokenKeepsData(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	setLinearFlagAccount(t, 0)
	id, err := database.CreateLinearAccount("Work")
	require.NoError(t, err)
	require.NoError(t, database.UpsertLinearTeams(id, []db.LinearTeam{{AccountID: id, ID: "t-1", Key: "ENG", Name: "Eng"}}, nil))
	store := linear.NewTokenStore(cfg.WorkspaceDir(), id)
	require.NoError(t, store.Save(&linear.Token{AccessToken: "a", RefreshToken: "r"}))
	old := linearRevoke
	t.Cleanup(func() { linearRevoke = old })
	var revoked []string
	linearRevoke = func(_ context.Context, accessToken string) error {
		revoked = append(revoked, accessToken)
		return errors.New("revoke endpoint returned 500")
	}

	cmd, out, errOut := newLinearCmd(context.Background())
	require.NoError(t, runLinearRemove(cmd, []string{strconv.FormatInt(id, 10)}))
	assert.Equal(t, []string{"a"}, revoked)
	assert.Contains(t, errOut.String(), "Warning: revoking token", "a failed revoke is reported, not fatal")
	assert.Contains(t, out.String(), "removed")
	assert.False(t, store.Exists())
	acct, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "removed", acct.Status)
	teams, err := database.ListLinearTeams(id)
	require.NoError(t, err)
	assert.Len(t, teams, 1, "synced data is kept")
}

func TestRunLinearRemove_WaitsForTokenLock(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	setLinearFlagAccount(t, 0)
	id, err := database.CreateLinearAccount("Work")
	require.NoError(t, err)
	store := linear.NewTokenStore(cfg.WorkspaceDir(), id)
	require.NoError(t, store.Save(&linear.Token{AccessToken: "a", RefreshToken: "r"}))
	old := linearRevoke
	t.Cleanup(func() { linearRevoke = old })
	linearRevoke = func(context.Context, string) error { t.Fatal("revoke must wait for the lock"); return nil }
	unlock, err := store.Lock(context.Background()) // a refresh in flight
	require.NoError(t, err)
	defer unlock()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	cmd, _, _ := newLinearCmd(ctx)
	require.ErrorContains(t, runLinearRemove(cmd, []string{strconv.FormatInt(id, 10)}), "deleting token")
	assert.True(t, store.Exists())
	acct, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
}

func TestLinearPositionalIDMustMatchAccountFlag(t *testing.T) {
	setLinearFlagAccount(t, 5)
	_, err := parseLinearAccountArg("3")
	require.EqualError(t, err, "--account and the positional id disagree (5 vs 3)")
	id, err := parseLinearAccountArg("5")
	require.NoError(t, err)
	assert.Equal(t, int64(5), id)
	cmd, _, _ := newLinearCmd(context.Background())
	require.ErrorContains(t, setLinearAccountEnabled(cmd, "3", false), "disagree")
	require.ErrorContains(t, runLinearRemove(cmd, []string{"3"}), "disagree")
}

func TestLinearTeamKeys_ReportsReadFailure(t *testing.T) {
	database := db.OpenTestDB(t)
	require.NoError(t, database.Close())
	var errOut bytes.Buffer
	assert.Empty(t, linearTeamKeys(database, 7, &errOut))
	assert.Contains(t, errOut.String(), "account 7: reading teams")
}

// newLinearKeyCmd is newLinearCmd with --api-key set and the key piped on stdin.
func newLinearKeyCmd(t *testing.T, stdin string) (*cobra.Command, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	cmd, out, errOut := newLinearCmd(context.Background())
	cmd.Flags().Bool("api-key", true, "")
	cmd.Flags().String("label", "", "")
	cmd.SetIn(strings.NewReader(stdin))
	return cmd, out, errOut
}

// stubLinearKeyFlow fails the test on any OAuth browser flow and records the
// tokens handed to the viewer call.
func stubLinearKeyFlow(t *testing.T, viewer linear.Viewer) *[]*linear.Token {
	t.Helper()
	oldLogin, oldFetch := linearLogin, linearFetchViewer
	t.Cleanup(func() { linearLogin, linearFetchViewer = oldLogin, oldFetch })
	linearLogin = func(context.Context, linear.OAuthConfig, io.Writer, linear.LoginOptions) (*linear.Token, error) {
		t.Fatal("the OAuth flow must not run with --api-key")
		return nil, nil
	}
	var seen []*linear.Token
	linearFetchViewer = func(_ context.Context, token *linear.Token) (linear.Viewer, error) {
		seen = append(seen, token)
		return viewer, nil
	}
	return &seen
}

func TestLinearAdd_APIKeyFromStdin(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	seen := stubLinearKeyFlow(t, acmeViewer)
	cmd, out, errOut := newLinearKeyCmd(t, "lin_api_x\n")

	require.NoError(t, runLinearAdd(cmd, nil))

	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), accounts[0].ID).Load()
	require.NoError(t, err)
	assert.Equal(t, "api_key", tok.TokenType)
	assert.Equal(t, "lin_api_x", tok.AccessToken)
	require.Len(t, *seen, 1)
	assert.True(t, (*seen)[0].IsAPIKey(), "the workspace is identified with a key-kind token")
	assert.NotContains(t, out.String()+errOut.String(), "lin_api_x")
}

func TestLinearAdd_APIKeyTrimmedAndEmptyRefused(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	seen := stubLinearKeyFlow(t, acmeViewer)

	cmd, _, _ := newLinearKeyCmd(t, "\n")
	require.EqualError(t, runLinearAdd(cmd, nil), "empty API key")
	assert.Empty(t, *seen, "no network call for an empty key")
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)

	cmd, _, _ = newLinearKeyCmd(t, "  lin_api_x \n")
	require.NoError(t, runLinearAdd(cmd, nil))
	accounts, err = database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), accounts[0].ID).Load()
	require.NoError(t, err)
	assert.Equal(t, "lin_api_x", tok.AccessToken)
}

func TestLinearLogin_APIKeyWrongWorkspaceRefused(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	setLinearFlagAccount(t, 0)
	stubLinearKeyFlow(t, acmeViewer)
	cmd, _, _ := newLinearKeyCmd(t, "lin_api_old\n")
	require.NoError(t, runLinearAdd(cmd, nil))
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	id := accounts[0].ID
	setLinearFlagAccount(t, id)

	other := acmeViewer
	other.OrgID, other.OrgName = "org-2", "Other"
	stubLinearKeyFlow(t, other)
	cmd, _, _ = newLinearKeyCmd(t, "lin_api_new\n")
	err = runLinearLogin(cmd, nil)
	require.ErrorContains(t, err, "this login is for workspace Other")
	tok, err := linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "lin_api_old", tok.AccessToken)

	stubLinearKeyFlow(t, acmeViewer)
	cmd, _, _ = newLinearKeyCmd(t, "lin_api_new\n")
	require.NoError(t, runLinearLogin(cmd, nil))
	tok, err = linear.NewTokenStore(cfg.WorkspaceDir(), id).Load()
	require.NoError(t, err)
	assert.Equal(t, "lin_api_new", tok.AccessToken)
	assert.True(t, tok.IsAPIKey())
}

func TestLinear03_AccountsJSONAuth(t *testing.T) {
	dir := t.TempDir()
	database := db.OpenTestDB(t)
	oauthID, err := database.CreateLinearAccount("oauth")
	require.NoError(t, err)
	keyID, err := database.CreateLinearAccount("key")
	require.NoError(t, err)
	_, err = database.CreateLinearAccount("nofile")
	require.NoError(t, err)
	corruptID, err := database.CreateLinearAccount("corrupt")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(dir, oauthID).Save(&linear.Token{AccessToken: "a", RefreshToken: "r"}))
	require.NoError(t, linear.NewTokenStore(dir, keyID).Save(linear.APIKeyToken("k")))
	require.NoError(t, os.WriteFile(linear.NewTokenStore(dir, corruptID).Path(), []byte("{not json"), 0o600))

	var buf bytes.Buffer
	require.NoError(t, printLinearAccounts(&buf, database, dir, true))
	var rows []map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &rows))
	require.Len(t, rows, 4)
	assert.Equal(t, "oauth", rows[0]["auth"])
	assert.Equal(t, "api_key", rows[1]["auth"])
	assert.Equal(t, "", rows[2]["auth"], "no token file")
	assert.Equal(t, "error", rows[3]["auth"], "a corrupt token file is not shown as blank")
}

func TestLinear03_RemoveAPIKeySkipsRevoke(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	setLinearFlagAccount(t, 0)
	id, err := database.CreateLinearAccount("Work")
	require.NoError(t, err)
	store := linear.NewTokenStore(cfg.WorkspaceDir(), id)
	require.NoError(t, store.Save(linear.APIKeyToken("lin_api_x")))
	old := linearRevoke
	t.Cleanup(func() { linearRevoke = old })
	linearRevoke = func(context.Context, string) error {
		t.Fatal("a personal API key has nothing to revoke")
		return nil
	}

	cmd, out, errOut := newLinearCmd(context.Background())
	require.NoError(t, runLinearRemove(cmd, []string{strconv.FormatInt(id, 10)}))
	assert.False(t, store.Exists())
	assert.Contains(t, errOut.String(), "revoke it in Linear's settings")
	assert.NotContains(t, out.String()+errOut.String(), "lin_api_x")
}

// failingReader fails the test on any read: a credential must not be asked
// for before the account is resolved.
type failingReader struct{ t *testing.T }

func (r failingReader) Read([]byte) (int, error) {
	r.t.Fatal("stdin must not be read before the account is resolved")
	return 0, io.EOF
}

func TestLinearLogin_MissingAccountFailsBeforeCredential(t *testing.T) {
	_, _ = linearCmdFixture(t)
	setLinearFlagAccount(t, 999)
	t.Setenv("WATCHTOWER_LINEAR_CLIENT_ID", "client-x")
	oldLogin := linearLogin
	t.Cleanup(func() { linearLogin = oldLogin })
	linearLogin = func(context.Context, linear.OAuthConfig, io.Writer, linear.LoginOptions) (*linear.Token, error) {
		t.Fatal("the OAuth flow must not start for a missing account")
		return nil, nil
	}

	cmd, _, _ := newLinearCmd(context.Background())
	cmd.Flags().Bool("api-key", false, "")
	require.Error(t, runLinearLogin(cmd, nil))

	cmd, _, _ = newLinearKeyCmd(t, "")
	cmd.SetIn(failingReader{t})
	require.Error(t, runLinearLogin(cmd, nil))
}

func TestLinearAdd_DBFailureBeforeCredential(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	old := flagConfig
	flagConfig = filepath.Join(t.TempDir(), "config.yaml") // no workspace configured
	t.Cleanup(func() { flagConfig = old })
	t.Setenv("WATCHTOWER_LINEAR_CLIENT_ID", "client-x")
	oldLogin := linearLogin
	t.Cleanup(func() { linearLogin = oldLogin })
	linearLogin = func(context.Context, linear.OAuthConfig, io.Writer, linear.LoginOptions) (*linear.Token, error) {
		t.Fatal("the OAuth flow must not start when the database cannot be opened")
		return nil, nil
	}

	cmd, _, _ := newLinearCmd(context.Background())
	cmd.Flags().Bool("api-key", false, "")
	cmd.Flags().String("label", "", "")
	require.Error(t, runLinearAdd(cmd, nil))

	cmd, _, _ = newLinearKeyCmd(t, "")
	cmd.SetIn(failingReader{t})
	require.Error(t, runLinearAdd(cmd, nil))
}
