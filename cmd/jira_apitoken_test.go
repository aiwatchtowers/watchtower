package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/atlassianpdr"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/policy/policytest"
)

// A made-up API token (leak-check:allow).
const cmdTestAPIToken = "ATATT-cmd-test-token-not-real"

// apiTokenHarness answers the site check and the token check.
type apiTokenHarness struct {
	cfg       *config.Config
	database  *db.DB
	cloudID   string
	tenantErr error
	probeErr  error
	scoped    bool
	// noConfluence: the token reads no Confluence (a Jira-only scoped token).
	noConfluence     bool
	confluenceProbes int
	confluenceErr    error
	tenantAsks       []string
	probes           []jira.APITokenCreds
}

func newAPITokenHarness(t *testing.T) *apiTokenHarness {
	t.Helper()
	h := &apiTokenHarness{database: jiraCmdFixture(t), cloudID: "cloud-acme"}
	var err error
	h.cfg, err = config.Load(flagConfig)
	require.NoError(t, err)
	origTenant, origProbe, origConfluence := jiraTenantInfo, jiraProbeAPIToken, jiraProbeConfluence
	t.Cleanup(func() { jiraTenantInfo, jiraProbeAPIToken, jiraProbeConfluence = origTenant, origProbe, origConfluence })
	jiraProbeConfluence = func(context.Context, *http.Client, string, string, jira.APITokenCreds) (bool, error) {
		h.confluenceProbes++
		return !h.noConfluence, h.confluenceErr
	}
	jiraTenantInfo = func(_ context.Context, _ *http.Client, site string) (string, error) {
		h.tenantAsks = append(h.tenantAsks, site)
		return h.cloudID, h.tenantErr
	}
	jiraProbeAPIToken = func(_ context.Context, _ *http.Client, cloudID, site string, creds jira.APITokenCreds) (jira.APITokenCreds, jira.Myself, error) {
		h.probes = append(h.probes, creds)
		if h.probeErr != nil {
			return jira.APITokenCreds{}, jira.Myself{}, h.probeErr
		}
		creds.AuthKind, creds.Scoped = jira.AuthKindAPIToken, h.scoped
		return creds, jira.Myself{AccountID: "acc-owner", EmailAddress: creds.Email, DisplayName: "Person A"}, nil
	}
	return h
}

func (h *apiTokenHarness) accounts(t *testing.T) []db.JiraAccount {
	t.Helper()
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	return accounts
}

// newTokenCmd builds a command over base's flags with flags set and stdin.
func newTokenCmd(t *testing.T, base *cobra.Command, flags map[string]string, stdin string) (*cobra.Command, *bytes.Buffer) {
	t.Helper()
	cmd := &cobra.Command{}
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetIn(strings.NewReader(stdin))
	cmd.SetContext(context.Background())
	cmd.Flags().AddFlagSet(base.Flags())
	for k, v := range flags {
		require.NoError(t, cmd.Flags().Set(k, v))
	}
	t.Cleanup(func() {
		for k := range flags {
			f := base.Flags().Lookup(k)
			_ = f.Value.Set(f.DefValue)
			f.Changed = false
		}
	})
	return cmd, &out
}

func addTokenFlags() map[string]string {
	return map[string]string{"api-token-stdin": "true", "email": "person@example.com", "site": "Acme.atlassian.net/"}
}

// TestJiraAdd_APITokenStdinOnly: the token is read from stdin only — no
// flag takes it, an argument is refused without being echoed — and it never
// reaches the command's output; it lands only in the account's 0600 token
// file.
func TestJiraAdd_APITokenStdinOnly(t *testing.T) {
	for _, c := range []*cobra.Command{jiraAddCmd, jiraLoginCmd} {
		err := c.Args(c, []string{cmdTestAPIToken})
		require.ErrorIs(t, err, errAPITokenOnStdinOnly)
		assert.NotContains(t, err.Error(), cmdTestAPIToken)
		for _, name := range []string{"api-token", "token", "api-key"} {
			assert.Nil(t, c.Flags().Lookup(name), "%s has no flag that takes a token", c.Name())
		}
	}

	h := newAPITokenHarness(t)
	var logBuf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&logBuf)
	t.Cleanup(func() { log.SetOutput(prev) })
	cmd, out := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken+"\n")

	require.NoError(t, runJiraAdd(cmd, nil), out.String())

	assert.NotContains(t, out.String(), cmdTestAPIToken)
	assert.NotContains(t, logBuf.String(), cmdTestAPIToken)
	require.Len(t, h.probes, 1)
	assert.Equal(t, cmdTestAPIToken, h.probes[0].Token)
	assert.Equal(t, []string{"https://acme.atlassian.net"}, h.tenantAsks, "the site is normalized and checked")

	accounts := h.accounts(t)
	require.Len(t, accounts, 1)
	a := accounts[0]
	assert.Equal(t, jira.AuthKindAPIToken, a.AuthKind)
	assert.Equal(t, "cloud-acme", a.CloudID)
	assert.Equal(t, "https://acme.atlassian.net", a.SiteURL)
	assert.Equal(t, "ok", a.Status)
	store := jira.NewTokenStore(h.cfg.WorkspaceDir(), a.ID)
	creds, err := store.LoadAPIToken()
	require.NoError(t, err)
	assert.Equal(t, cmdTestAPIToken, creds.Token)
	assert.Equal(t, "person@example.com", creds.Email)
	fi, err := os.Stat(store.Path())
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
}

// TestJiraAdd_APITokenFillsOwnerFromMyself: /myself, which checked the
// token, also records whose account it is (the owner ladder).
func TestJiraAdd_APITokenFillsOwnerFromMyself(t *testing.T) {
	h := newAPITokenHarness(t)
	cmd, out := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken)
	require.NoError(t, runJiraAdd(cmd, nil), out.String())
	a := h.accounts(t)[0]
	assert.Equal(t, "acc-owner", a.OwnerAccountID)
	assert.Equal(t, "person@example.com", a.OwnerEmail)
	assert.Equal(t, "Person A", a.OwnerDisplayName)
}

// TestJiraAdd_NotCloudSiteRefusedBeforeStore: a site that is not an
// atlassian.net site is refused before stdin is read or any host is asked
// (a custom domain's tenant_info is that host's own word); an atlassian.net
// site without a tenant is refused before the token is sent. Nothing is
// stored.
func TestJiraAdd_NotCloudSiteRefusedBeforeStore(t *testing.T) {
	for _, site := range []string{"https://jira.example.com", "http://acme.atlassian.net", "https://acme.atlassian.net/wiki", "https://acme.atlassian.net.example.com"} {
		h := newAPITokenHarness(t)
		flags := addTokenFlags()
		flags["site"] = site
		cmd, _ := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)

		err := runJiraAdd(cmd, nil)
		require.ErrorIs(t, err, jira.ErrNotAtlassianCloud, site)
		assert.Empty(t, h.tenantAsks, "%s: no host is asked", site)
		assert.Empty(t, h.probes, "the token is not sent")
		assert.Empty(t, h.accounts(t))
	}

	h := newAPITokenHarness(t)
	h.tenantErr = jira.ErrNotAtlassianCloud
	cmd, _ := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken)
	require.ErrorIs(t, runJiraAdd(cmd, nil), jira.ErrNotAtlassianCloud)
	assert.Empty(t, h.probes, "the token is not sent")
	assert.Empty(t, h.accounts(t))
}

// An API-token account's Confluence hints ask for a new token, not an OAuth
// login it cannot do.
func TestConfluenceHints_APITokenAccount(t *testing.T) {
	revoked, consent := confluenceHints(db.JiraAccount{ID: 4, AuthKind: jira.AuthKindAPIToken})
	for _, h := range []string{revoked, consent} {
		assert.Contains(t, h, "jira login --account 4 --api-token-stdin --with-confluence")
	}
	_, consent = confluenceHints(db.JiraAccount{ID: 4})
	assert.Equal(t, "Confluence access not granted — run: watchtower jira login --account 4 --with-confluence", consent)
}

// TestJiraAdd_APITokenNetworkStoresNothing: a check that could not run, or a
// refused token or scope, leaves no row and no token file.
func TestJiraAdd_APITokenNetworkStoresNothing(t *testing.T) {
	for _, probeErr := range []error{
		errors.New("dial tcp: connection refused"),
		jira.ErrAPITokenDead,
		&jira.ScopeError{Scope: "read:jira-user"},
	} {
		h := newAPITokenHarness(t)
		h.probeErr = probeErr
		cmd, _ := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken)
		err := runJiraAdd(cmd, nil)
		require.ErrorIs(t, err, probeErr)
		assert.NotContains(t, err.Error(), cmdTestAPIToken)
		assert.Empty(t, h.accounts(t))
		_, statErr := os.Stat(jira.NewTokenStore(h.cfg.WorkspaceDir(), 1).Path())
		assert.True(t, os.IsNotExist(statErr))
	}
}

// A 403 names the scope the token lacks.
func TestJiraAPIToken403NamesScope(t *testing.T) {
	h := newAPITokenHarness(t)
	h.probeErr = &jira.ScopeError{Scope: "read:jira-user"}
	cmd, _ := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken)
	err := runJiraAdd(cmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "This token lacks read:jira-user — create one with the listed scopes")
}

// addTokenAccount connects an API-token account through the CLI.
func addTokenAccount(t *testing.T, h *apiTokenHarness) db.JiraAccount {
	t.Helper()
	cmd, out := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken)
	require.NoError(t, runJiraAdd(cmd, nil), out.String())
	accounts := h.accounts(t)
	require.Len(t, accounts, 1)
	return accounts[0]
}

func withJiraAccountFlag(t *testing.T, id int64) {
	t.Helper()
	prev := jiraFlagAccount
	jiraFlagAccount = id
	t.Cleanup(func() { jiraFlagAccount = prev })
}

// TestJiraLogin_NewTokenClearsError: a new token for an account whose token
// died replaces it, clears api_token_dead and stamps access_ok_at; the email
// defaults to the stored one.
func TestJiraLogin_NewTokenClearsError(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	require.NoError(t, h.database.SetJiraAccountAuthState(a.ID, "error", jira.CodeAPITokenDead))
	_, err := h.database.Exec(`UPDATE jira_accounts SET access_ok_at = '' WHERE id = ?`, a.ID)
	require.NoError(t, err)
	withJiraAccountFlag(t, a.ID)
	h.scoped = true

	const next = "ATATT-next-token-not-real" // leak-check:allow
	cmd, out := newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true"}, next)
	require.NoError(t, runJiraLogin(cmd, nil), out.String())
	assert.NotContains(t, out.String(), next)

	got, err := h.database.GetJiraAccount(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "ok", got.Status)
	assert.Empty(t, got.Error)
	var okAt string
	require.NoError(t, h.database.QueryRow(`SELECT access_ok_at FROM jira_accounts WHERE id = ?`, a.ID).Scan(&okAt))
	assert.NotEmpty(t, okAt)
	creds, err := jira.NewTokenStore(h.cfg.WorkspaceDir(), a.ID).LoadAPIToken()
	require.NoError(t, err)
	assert.Equal(t, next, creds.Token)
	assert.Equal(t, "person@example.com", creds.Email)
	assert.True(t, creds.Scoped, "the kind the new token proved to be")
	assert.Equal(t, []string{"https://acme.atlassian.net", "https://acme.atlassian.net"}, h.tenantAsks)
}

// A re-auth sends the token only to the account's own tenant: a site that
// now answers with another cloudId is refused before the check.
func TestJiraLogin_APITokenOtherTenantRefused(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	withJiraAccountFlag(t, a.ID)
	h.cloudID = "cloud-someone-else"
	h.probes = nil

	cmd, _ := newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true"}, "ATATT-other") // leak-check:allow
	err := runJiraLogin(cmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "another Atlassian site")
	assert.Empty(t, h.probes, "the token is not sent")
	creds, err := jira.NewTokenStore(h.cfg.WorkspaceDir(), a.ID).LoadAPIToken()
	require.NoError(t, err)
	assert.Equal(t, cmdTestAPIToken, creds.Token)
}

// An OAuth sign-in never overwrites a token account's token file, and a
// token never goes to an OAuth account.
func TestJiraLogin_KindMismatchRefused(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	withJiraAccountFlag(t, a.ID)
	cmd, _ := newTokenCmd(t, jiraLoginCmd, nil, "")
	err := runJiraLogin(cmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--api-token-stdin")

	oauthID, err := h.database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://other.atlassian.net"})
	require.NoError(t, err)
	withJiraAccountFlag(t, oauthID)
	cmd, _ = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true"}, cmdTestAPIToken)
	err = runJiraLogin(cmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "signs in with OAuth")
}

// TestJiraAPIToken_PolicyRefusesAdd (D24): AllowAtlassianAPIToken = false
// refuses the add and the re-auth before stdin is read or the site asked.
func TestJiraAPIToken_PolicyRefusesAdd(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	h.tenantAsks = nil
	policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})

	cmd, _ := newTokenCmd(t, jiraAddCmd, addTokenFlags(), cmdTestAPIToken)
	require.ErrorIs(t, runJiraAdd(cmd, nil), jira.ErrAPITokenForbidden)
	withJiraAccountFlag(t, a.ID)
	cmd, _ = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true"}, cmdTestAPIToken)
	require.ErrorIs(t, runJiraLogin(cmd, nil), jira.ErrAPITokenForbidden)
	assert.Empty(t, h.tenantAsks)
	assert.Len(t, h.accounts(t), 1)
}

// TestJiraAPIToken_PolicyStopsSyncKeepsData (POLICY-03): with API tokens
// forbidden the daemon wires no client for a token account — no sync, no
// Confluence, no lookup — and leaves its row, status and token file as they
// are; an OAuth account keeps syncing.
func TestJiraAPIToken_PolicyStopsSyncKeepsData(t *testing.T) {
	h := newAPITokenHarness(t)
	token := addTokenAccount(t, h)
	oauthID, err := h.database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://other.atlassian.net"})
	require.NoError(t, err)
	require.NoError(t, jira.NewTokenStore(h.cfg.WorkspaceDir(), oauthID).Save(&jira.OAuthToken{AccessToken: "a", RefreshToken: "r"}))
	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "env-id")
	logger := log.New(io.Discard, "", 0)

	_, clients := buildAtlassianClients(h.cfg, h.database, logger)
	assert.NotNil(t, clients[token.ID], "allowed: the token account is wired")

	policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})
	_, clients = buildAtlassianClients(h.cfg, h.database, logger)
	assert.Nil(t, clients[token.ID])
	assert.NotNil(t, clients[oauthID])
	got, err := h.database.GetJiraAccount(token.ID)
	require.NoError(t, err)
	assert.Equal(t, "ok", got.Status, "the row is left as it is")
	_, err = jira.NewTokenStore(h.cfg.WorkspaceDir(), token.ID).LoadAPIToken()
	assert.NoError(t, err, "the token is kept")
}

// An API-token account runs the 7-day lookup instead of the report API.
func TestAtlassianPDRAccounts_APITokenLooksUp(t *testing.T) {
	c := &jira.Client{}
	got := atlassianPDRAccounts(
		[]db.JiraAccount{{ID: 1}, {ID: 2, AuthKind: jira.AuthKindAPIToken}},
		map[int64]*jira.Client{1: c, 2: c})
	require.Len(t, got, 2)
	assert.IsType(t, atlassianpdr.ClientReporter{}, got[0].Reporter)
	assert.IsType(t, atlassianpdr.LookupReporter{}, got[1].Reporter)
}

// A token pasted as the flag's value is not echoed by the flag error.
func TestJiraAPITokenFlagValueNotEchoed(t *testing.T) {
	for _, c := range []*cobra.Command{jiraAddCmd, jiraLoginCmd} {
		fs := pflag.NewFlagSet("t", pflag.ContinueOnError)
		fs.SetOutput(io.Discard)
		fs.Bool("api-token-stdin", false, "")
		err := fs.Parse([]string{"--api-token-stdin=" + cmdTestAPIToken})
		require.Error(t, err)
		got := c.FlagErrorFunc()(c, err)
		require.ErrorIs(t, got, errAPITokenFlagValue)
		assert.NotContains(t, got.Error(), cmdTestAPIToken)
		assert.Equal(t, "boom", c.FlagErrorFunc()(c, errors.New("boom")).Error(), "other flag errors pass")
	}
}

// A re-auth keeps the Confluence scopes the token was used for, like an
// OAuth re-login keeps the grant's.
func TestJiraLogin_APITokenKeepsConfluence(t *testing.T) {
	h := newAPITokenHarness(t)
	flags := addTokenFlags()
	flags["with-confluence"] = "true"
	cmd, out := newTokenCmd(t, jiraAddCmd, flags, cmdTestAPIToken)
	require.NoError(t, runJiraAdd(cmd, nil), out.String())
	a := h.accounts(t)[0]
	withJiraAccountFlag(t, a.ID)

	cmd, out = newTokenCmd(t, jiraLoginCmd, map[string]string{"api-token-stdin": "true"}, "ATATT-next") // leak-check:allow
	require.NoError(t, runJiraLogin(cmd, nil), out.String())
	tok, err := jira.NewTokenStore(h.cfg.WorkspaceDir(), a.ID).Load()
	require.NoError(t, err)
	assert.True(t, jira.HasConfluenceScopes(tok))
}

// A damaged token file is shown on the row, never left green.
func TestBuildAtlassianClients_DamagedAPITokenFileIsError(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	require.NoError(t, os.WriteFile(jira.NewTokenStore(h.cfg.WorkspaceDir(), a.ID).Path(), []byte("{"), 0o600))

	_, clients := buildAtlassianClients(h.cfg, h.database, log.New(io.Discard, "", 0))
	assert.Nil(t, clients[a.ID])
	got, err := h.database.GetJiraAccount(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
}

// The daemon's client of a token account records a 401 on the row as
// error / api_token_dead (never revoked), whichever consumer made the
// request; a policy-stopped account's row is left alone even without a
// token file.
func TestBuildAtlassianClients_APITokenDeadMarksAccount(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(site.Close)
	_, err := h.database.Exec(`UPDATE jira_accounts SET site_url = ? WHERE id = ?`, site.URL, a.ID)
	require.NoError(t, err)

	_, clients := buildAtlassianClients(h.cfg, h.database, log.New(io.Discard, "", 0))
	require.NotNil(t, clients[a.ID])
	err = clients[a.ID].Confluence().GetJSON(context.Background(), "/wiki/api/v2/spaces", nil, &struct{}{})
	require.ErrorIs(t, err, jira.ErrAPITokenDead)
	got, err := h.database.GetJiraAccount(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
	assert.Equal(t, jira.CodeAPITokenDead, got.Error)

	require.NoError(t, h.database.SetJiraAccountAuthState(a.ID, "ok", ""))
	require.NoError(t, jira.NewTokenStore(h.cfg.WorkspaceDir(), a.ID).Delete())
	policytest.Set(t, map[string]any{"AllowAtlassianAPIToken": false})
	_, clients = buildAtlassianClients(h.cfg, h.database, log.New(io.Discard, "", 0))
	assert.Nil(t, clients[a.ID])
	got, err = h.database.GetJiraAccount(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "ok", got.Status, "a policy-stopped row is left as it is")
}

// A command's or tool's client records a dead token on the row too.
func TestNewJiraClientForAccount_APITokenDeadMarksAccount(t *testing.T) {
	h := newAPITokenHarness(t)
	a := addTokenAccount(t, h)
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(site.Close)
	a.SiteURL = site.URL

	client, err := newJiraClientForAccount(h.cfg, a)
	require.NoError(t, err)
	_, err = client.GetMyself(context.Background())
	require.ErrorIs(t, err, jira.ErrAPITokenDead)
	got, err := h.database.GetJiraAccount(a.ID)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
	assert.Equal(t, jira.CodeAPITokenDead, got.Error)
}
