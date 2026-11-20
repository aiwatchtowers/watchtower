package cmd

import (
	"bytes"
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/jira"
	"watchtower/internal/oauthclient"
)

// TestNoArgumentlessJiraResolver (#1887 §1): every Atlassian client comes
// from a company or an account; the argument-less resolver, which could only
// ever answer with the shared app, must not come back.
func TestNoArgumentlessJiraResolver(t *testing.T) {
	files, err := filepath.Glob("*.go")
	require.NoError(t, err)
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		require.NoError(t, err, f)
		ast.Inspect(file, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.FuncDecl:
				assert.NotEqual(t, "resolveJiraOAuthConfig", x.Name.Name, "%s declares the argument-less resolver", f)
			case *ast.CallExpr:
				if id, ok := x.Fun.(*ast.Ident); ok && id.Name == "resolveJiraOAuthConfig" {
					t.Errorf("%s: argument-less resolveJiraOAuthConfig() at %s", f, fset.Position(x.Pos()))
				}
			}
			return true
		})
	}
}

// saveCompany stores b under the workspace's company directory.
func saveCompany(t *testing.T, workspaceDir string, b companybundle.Bundle) {
	t.Helper()
	slug, err := company.NewStore(workspaceDir).SlugFor(b.Company, "")
	require.NoError(t, err)
	require.NoError(t, company.NewStore(workspaceDir).Save(slug, b))
}

// TestJiraResolver_Order: the company's bundle → the account's client file →
// env → baked, each layer removed in turn.
func TestJiraResolver_Order(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	acct := db.JiraAccount{ID: 4, CompanySlug: "acme"}
	file := oauthclient.NewStore(ws, jiraClientVendor, acct.ID)
	require.NoError(t, file.Save(oauthclient.Client{ClientID: "acmeClientId01", ClientSecret: "file-secret"}))
	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "env-id")
	t.Setenv("WATCHTOWER_JIRA_CLIENT_SECRET", "env-secret")
	prevID, prevSecret := jira.DefaultJiraClientID, jira.DefaultJiraClientSecret
	jira.DefaultJiraClientID, jira.DefaultJiraClientSecret = "baked-id", "baked-secret"
	t.Cleanup(func() { jira.DefaultJiraClientID, jira.DefaultJiraClientSecret = prevID, prevSecret })

	check := func(wantSecret string, wantSrc clientSource) {
		t.Helper()
		cfg, src, err := resolveJiraOAuthConfigForAccount(ws, acct)
		require.NoError(t, err)
		assert.Equal(t, wantSecret, cfg.ClientSecret)
		assert.Equal(t, wantSrc, src)
	}
	check("acme-secret", clientSourceCompany)

	// The company is gone: the client the account signed in with.
	require.NoError(t, os.Remove(filepath.Join(ws, "company", "acme.json")))
	check("file-secret", clientSourceAccountFile)

	// No company and no client file: a tied account never falls to the
	// shared app; an untied one takes env, then baked.
	require.NoError(t, file.Delete())
	_, _, err := resolveJiraOAuthConfigForAccount(ws, acct)
	assert.ErrorIs(t, err, errNoOAuthClient)
	acct.CompanySlug = ""
	check("env-secret", clientSourceEnv)

	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "")
	check("baked-secret", clientSourceBaked)

	jira.DefaultJiraClientID = ""
	_, _, err = resolveJiraOAuthConfigForAccount(ws, acct)
	assert.ErrorIs(t, err, errNoOAuthClient)

	// An untied account never reads a company, even one of the same name.
	saveCompany(t, ws, companySample("Acme"))
	require.NoError(t, file.Save(oauthclient.Client{ClientID: "file-id"}))
	cfg, src, err := resolveJiraOAuthConfigForAccount(ws, db.JiraAccount{ID: 4})
	require.NoError(t, err)
	assert.Equal(t, "file-id", cfg.ClientID)
	assert.Equal(t, clientSourceAccountFile, src)

	// A damaged client file is reported, never a fall to the shared app.
	require.NoError(t, os.WriteFile(file.Path(), []byte("{"), 0o600))
	_, _, err = resolveJiraOAuthConfigForAccount(ws, db.JiraAccount{ID: 4})
	assert.Error(t, err)
}

// ForCompany: a stored company's client; an unknown slug, or a company with
// no Atlassian app, is an error; "" is the shared client.
func TestJiraResolver_ForCompany(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	noAtlassian := companySample("Globex")
	noAtlassian.Atlassian = nil
	saveCompany(t, ws, noAtlassian)
	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "env-id")

	cfg, src, err := resolveJiraOAuthConfigForCompany(ws, "acme")
	require.NoError(t, err)
	assert.Equal(t, jira.JiraOAuthConfig{ClientID: "acmeClientId01", ClientSecret: "acme-secret"}, cfg)
	assert.Equal(t, clientSourceCompany, src)

	_, _, err = resolveJiraOAuthConfigForCompany(ws, "initech")
	assert.ErrorIs(t, err, errUnknownCompany)
	_, _, err = resolveJiraOAuthConfigForCompany(ws, "globex")
	assert.ErrorIs(t, err, errNoOAuthClient)

	cfg, src, err = resolveJiraOAuthConfigForCompany(ws, "")
	require.NoError(t, err)
	assert.Equal(t, "env-id", cfg.ClientID)
	assert.Equal(t, clientSourceEnv, src)
}

// The forced MDM bundle wins over the stored file of the same company.
func TestJiraResolver_ForcedBundleWins(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	forced := companySample("Acme")
	forced.Atlassian.ClientID = "forcedClientId"
	wire := companyWire(t, forced)
	prev := companyForcedBundle
	companyForcedBundle = func() string { return wire }
	t.Cleanup(func() { companyForcedBundle = prev })

	cfg, _, err := resolveJiraOAuthConfigForAccount(ws, db.JiraAccount{ID: 1, CompanySlug: "acme"})
	require.NoError(t, err)
	assert.Equal(t, "forcedClientId", cfg.ClientID)
}

// jiraAddHarness scripts `jira add`: the login fake records the client it
// was given and whether it ran; resources, site validation and /myself are
// answered locally.
type jiraAddHarness struct {
	database   *db.DB
	cfg        *config.Config
	loginCalls int
	loginCfg   jira.JiraOAuthConfig
	loginOpts  jira.LoginOptions
	validated  []string
}

func newJiraAddHarness(t *testing.T, siteValid error) *jiraAddHarness {
	t.Helper()
	h := &jiraAddHarness{database: jiraCmdFixture(t)}
	var err error
	h.cfg, err = config.Load(flagConfig)
	require.NoError(t, err)

	origLogin, origRes, origValidate, origOwner := jiraLogin, jiraFetchResources, jiraValidateSite, jiraConnectOwner
	t.Cleanup(func() {
		jiraLogin, jiraFetchResources, jiraValidateSite, jiraConnectOwner = origLogin, origRes, origValidate, origOwner
	})
	jiraLogin = func(_ context.Context, c jira.JiraOAuthConfig, _ io.Writer, opts ...jira.LoginOptions) (*jira.OAuthToken, error) {
		h.loginCalls++
		h.loginCfg, h.loginOpts = c, opts[0]
		return &jira.OAuthToken{AccessToken: "a", RefreshToken: "r", Scope: jira.OAuthScopes}, nil
	}
	jiraFetchResources = func(context.Context, string) ([]jira.CloudResource, error) {
		return []jira.CloudResource{
			{ID: "cloud-other", URL: "https://other.atlassian.net", Name: "Other"},
			{ID: "cloud-acme", URL: "https://acme.atlassian.net", Name: "Acme"},
		}, nil
	}
	jiraValidateSite = func(_ context.Context, _ *http.Client, site string) error {
		h.validated = append(h.validated, site)
		return siteValid
	}
	jiraConnectOwner = func(context.Context, io.Writer, *db.DB, int64, myselfGetter) {}
	return h
}

func newJiraAddCmd(t *testing.T, flags map[string]string) (*cobra.Command, *bytes.Buffer) {
	t.Helper()
	cmd := &cobra.Command{}
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetIn(strings.NewReader(""))
	cmd.SetContext(context.Background())
	cmd.Flags().AddFlagSet(jiraAddCmd.Flags())
	for k, v := range flags {
		require.NoError(t, cmd.Flags().Set(k, v))
	}
	t.Cleanup(func() {
		// jiraAddCmd's flag values are shared through the flag set.
		for k := range flags {
			f := jiraAddCmd.Flags().Lookup(k)
			_ = f.Value.Set(f.DefValue)
			f.Changed = false
		}
	})
	return cmd, &out
}

// TestJiraAdd_CompanyUsesBundleClient: `jira add --company acme` signs in
// through the bundle's client, on the bundle's site, with Confluence (the
// bundle's confluence: true); the row is tied to acme in the same insert and
// keeps its client in its own file.
func TestJiraAdd_CompanyUsesBundleClient(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	cmd, out := newJiraAddCmd(t, map[string]string{"company": "acme"})

	require.NoError(t, runJiraAdd(cmd, nil), out.String())

	assert.Equal(t, jira.JiraOAuthConfig{ClientID: "acmeClientId01", ClientSecret: "acme-secret"}, h.loginCfg)
	assert.True(t, h.loginOpts.WithConfluence, "the bundle's confluence: true asks for Confluence")
	assert.Equal(t, []string{"https://acme.atlassian.net"}, h.validated)

	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	a := accounts[0]
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, "cloud-acme", a.CloudID, "the bundle's site, not the first one the grant reaches")
	assert.Equal(t, "ok", a.Status)
	c, ok, err := oauthclient.NewStore(h.cfg.WorkspaceDir(), jiraClientVendor, a.ID).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, oauthclient.Client{ClientID: "acmeClientId01", ClientSecret: "acme-secret"}, c)

	got, src, err := resolveJiraOAuthConfigForAccount(h.cfg.WorkspaceDir(), a)
	require.NoError(t, err)
	assert.Equal(t, "acmeClientId01", got.ClientID)
	assert.Equal(t, clientSourceCompany, src)
}

// TestJiraAdd_UnknownCompanyFailsBeforeBrowser: a slug with no stored company
// fails before any sign-in, row or site check.
func TestJiraAdd_UnknownCompanyFailsBeforeBrowser(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	cmd, _ := newJiraAddCmd(t, map[string]string{"company": "initech"})

	err := runJiraAdd(cmd, nil)
	require.ErrorIs(t, err, errUnknownCompany)
	assert.Zero(t, h.loginCalls, "no browser for an unknown company")
	assert.Empty(t, h.validated)
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// A company site that is not Atlassian Cloud is refused before the sign-in:
// no client secret or token goes anywhere on its word.
func TestJiraAdd_CompanySiteNotCloudRefused(t *testing.T) {
	h := newJiraAddHarness(t, jira.ErrNotAtlassianCloud)
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	cmd, _ := newJiraAddCmd(t, map[string]string{"company": "acme"})

	err := runJiraAdd(cmd, nil)
	require.ErrorIs(t, err, jira.ErrNotAtlassianCloud)
	assert.Zero(t, h.loginCalls)
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// The company's site is matched exactly: a grant that does not reach it
// binds no other tenant, and creates no row.
func TestJiraAdd_CompanySiteMatchedExactly(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	b := companySample("Acme")
	b.Atlassian.Site = "https://acme.atlassian.net"
	saveCompany(t, h.cfg.WorkspaceDir(), b)
	jiraFetchResources = func(context.Context, string) ([]jira.CloudResource, error) {
		return []jira.CloudResource{{ID: "cloud-x", URL: "https://acme-old.atlassian.net", Name: "Acme"}}, nil
	}
	cmd, _ := newJiraAddCmd(t, map[string]string{"company": "acme"})

	err := runJiraAdd(cmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "does not reach the company's site https://acme.atlassian.net")
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// A damaged client file stops the account's sync, and the row says so —
// never a green account that syncs nothing.
func TestBuildAtlassianClients_DamagedClientFileIsShown(t *testing.T) {
	database := jiraCmdFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1"})
	require.NoError(t, err)
	require.NoError(t, database.SetJiraAccountAuthState(id, "ok", ""))
	require.NoError(t, jira.NewTokenStore(cfg.WorkspaceDir(), id).Save(&jira.OAuthToken{AccessToken: "a"}))
	require.NoError(t, os.WriteFile(oauthclient.NewStore(cfg.WorkspaceDir(), jiraClientVendor, id).Path(), []byte("{"), 0o600))

	_, clients := buildAtlassianClients(cfg, database, quietTestLogger())
	assert.Empty(t, clients)
	a, err := database.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Contains(t, a.Error, "jira_client_")
}

// The daemon client's refresh source follows the account as it is now: the
// company's current app; a changed app is ErrClientRejected (Re-login
// needed), a missing row a plain error that marks nothing.
func TestJiraAccountOAuthSource(t *testing.T) {
	database := jiraCmdFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", CompanySlug: "acme"})
	require.NoError(t, err)
	require.NoError(t, saveJiraAccountClient(ws, id, jira.JiraOAuthConfig{ClientID: "acmeClientId01"}))

	source := jiraAccountOAuthSource(ws, func() (db.JiraAccount, error) { return database.GetJiraAccount(id) })
	got, err := source()
	require.NoError(t, err)
	assert.Equal(t, "acmeClientId01", got.ClientID)

	replaced := companySample("Acme")
	replaced.Atlassian.ClientID = "acmeClientId02"
	require.NoError(t, company.NewStore(ws).Save("acme", replaced))
	_, err = source()
	assert.ErrorIs(t, err, jira.ErrClientRejected)

	_, err = jiraAccountOAuthSource(ws, func() (db.JiraAccount, error) { return database.GetJiraAccount(999) })()
	require.Error(t, err)
	assert.NotErrorIs(t, err, jira.ErrClientRejected)
}

// --site naming another site than the company's app is refused.
func TestJiraAdd_CompanySiteFlagMustMatch(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	cmd, _ := newJiraAddCmd(t, map[string]string{"company": "acme", "site": "https://other.atlassian.net"})

	err := runJiraAdd(cmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "is for https://acme.atlassian.net")
	assert.Zero(t, h.loginCalls)
}

// TestJiraAdd_CompanyFromWizardDraft (screens §10): the wizard's Atlassian
// check signs in with the draft's client before any bundle is stored; the
// account is still tied to the company and keeps that client.
func TestJiraAdd_CompanyFromWizardDraft(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	cmd, _ := newJiraAddCmd(t, nil)
	draft := jiraAddTarget{
		Slug:  "acme",
		OAuth: jira.JiraOAuthConfig{ClientID: "draftClient", ClientSecret: "draft-secret"},
		Site:  "https://acme.atlassian.net",
	}

	require.NoError(t, addJiraAccount(cmd, h.cfg, h.database, draft))

	assert.Equal(t, draft.OAuth, h.loginCfg)
	assert.False(t, h.loginOpts.WithConfluence)
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "acme", accounts[0].CompanySlug)
	c, ok, err := oauthclient.NewStore(h.cfg.WorkspaceDir(), jiraClientVendor, accounts[0].ID).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, "draftClient", c.ClientID)
}

// Without --company, `jira add` takes the shared client and ties nothing;
// with no client on any layer it fails before the browser.
func TestJiraAdd_NoCompanyUsesSharedClient(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	prevID := jira.DefaultJiraClientID
	jira.DefaultJiraClientID = ""
	t.Cleanup(func() { jira.DefaultJiraClientID = prevID })
	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "")

	cmd, _ := newJiraAddCmd(t, map[string]string{"site": "acme"})
	err := runJiraAdd(cmd, nil)
	require.ErrorIs(t, err, errNoOAuthClient)
	assert.Zero(t, h.loginCalls)

	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "env-id")
	cmd, _ = newJiraAddCmd(t, map[string]string{"site": "acme"})
	require.NoError(t, runJiraAdd(cmd, nil))
	assert.Equal(t, "env-id", h.loginCfg.ClientID)
	assert.Empty(t, h.validated, "no company, no site check")
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Empty(t, accounts[0].CompanySlug)
	_, ok, err := oauthclient.NewStore(h.cfg.WorkspaceDir(), jiraClientVendor, accounts[0].ID).Load()
	require.NoError(t, err)
	assert.False(t, ok, "the shared client is never written to an account file")
}

// The daemon's wiring: an account with no client on any layer can never
// refresh — Re-login needed, coded by its company tie, never revoked.
func TestBuildAtlassianClients_NoClientIsReloginNeeded(t *testing.T) {
	database := jiraCmdFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	prevID := jira.DefaultJiraClientID
	jira.DefaultJiraClientID = ""
	t.Cleanup(func() { jira.DefaultJiraClientID = prevID })
	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "")

	ids := map[string]int64{}
	for _, slug := range []string{"", "gone"} {
		id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: "c-" + slug, CompanySlug: slug})
		require.NoError(t, err)
		require.NoError(t, database.SetJiraAccountAuthState(id, "ok", ""))
		require.NoError(t, jira.NewTokenStore(cfg.WorkspaceDir(), id).Save(&jira.OAuthToken{AccessToken: "a", RefreshToken: "r"}))
		ids[slug] = id
	}

	_, clients := buildAtlassianClients(cfg, database, quietTestLogger())
	assert.Empty(t, clients)
	for slug, want := range map[string]string{"": "unknown_client", "gone": "invalid_client"} {
		a, err := database.GetJiraAccount(ids[slug])
		require.NoError(t, err)
		assert.Equal(t, "error", a.Status, slug)
		assert.Equal(t, want, a.Error, slug)
	}
}

// TestJiraResolver_ClientChangedNeedsLogin: a company whose stored app is not
// the one the account's grant was issued to (a Replace whose account marking
// failed, say) never refreshes through the new app — the daemon marks the
// account invalid_client ("your company changed its app"), not revoked. A new
// secret for the same client id is just the bundle's newer secret. A re-login
// signs in through the new app and records it, which clears the mismatch.
func TestJiraResolver_ClientChangedNeedsLogin(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	ws := h.cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	cmd, _ := newJiraAddCmd(t, map[string]string{"company": "acme"})
	require.NoError(t, runJiraAdd(cmd, nil))
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	acct := accounts[0]

	// Same client id, rotated secret: the bundle's secret is used.
	rotated := companySample("Acme")
	rotated.Atlassian.ClientSecret = "acme-secret-2"
	require.NoError(t, company.NewStore(ws).Save("acme", rotated))
	got, _, err := resolveJiraOAuthConfigForAccount(ws, acct)
	require.NoError(t, err)
	assert.Equal(t, "acme-secret-2", got.ClientSecret)

	// Another app: Re-login needed, coded invalid_client by the daemon.
	replaced := companySample("Acme")
	replaced.Atlassian.ClientID = "acmeClientId02"
	require.NoError(t, company.NewStore(ws).Save("acme", replaced))
	_, _, err = resolveJiraOAuthConfigForAccount(ws, acct)
	require.ErrorIs(t, err, errClientChanged)
	assert.Contains(t, err.Error(), "your company changed its Atlassian app — sign in again")

	_, clients := buildAtlassianClients(h.cfg, h.database, quietTestLogger())
	assert.Empty(t, clients)
	marked, err := h.database.GetJiraAccount(acct.ID)
	require.NoError(t, err)
	assert.Equal(t, "error", marked.Status)
	assert.Equal(t, "invalid_client", marked.Error)

	// The re-login goes through the new app and records it.
	prevAccount := jiraFlagAccount
	jiraFlagAccount = acct.ID
	t.Cleanup(func() { jiraFlagAccount = prevAccount })
	login := &cobra.Command{}
	login.SetOut(io.Discard)
	login.SetErr(io.Discard)
	login.SetContext(context.Background())
	login.Flags().AddFlagSet(jiraLoginCmd.Flags())
	require.NoError(t, runJiraLogin(login, nil))
	assert.Equal(t, "acmeClientId02", h.loginCfg.ClientID)
	after, err := h.database.GetJiraAccount(acct.ID)
	require.NoError(t, err)
	assert.Equal(t, "ok", after.Status, "a successful login clears the code")
	got, src, err := resolveJiraOAuthConfigForAccount(ws, after)
	require.NoError(t, err)
	assert.Equal(t, "acmeClientId02", got.ClientID)
	assert.Equal(t, clientSourceCompany, src)
}
