package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/imap"
	"watchtower/internal/linear"
	"watchtower/internal/oauthclient"
)

// #1887 Task 7b: Google, Linear and Microsoft resolve their OAuth client per
// company and per account — the company's bundle (forced MDM first) → the
// account's own client record → env → baked — and their adds take
// --company.

// cmdWithFlags is a fresh command carrying src's flags set to flags; the
// shared flag values are reset after the test.
func cmdWithFlags(t *testing.T, src *cobra.Command, flags map[string]string) (*cobra.Command, *bytes.Buffer) {
	t.Helper()
	cmd := &cobra.Command{}
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetIn(strings.NewReader(""))
	cmd.SetContext(context.Background())
	cmd.Flags().AddFlagSet(src.Flags())
	for k, v := range flags {
		require.NoError(t, cmd.Flags().Set(k, v))
	}
	t.Cleanup(func() {
		for k := range flags {
			f := src.Flags().Lookup(k)
			_ = f.Value.Set(f.DefValue)
			f.Changed = false
		}
	})
	return cmd, &out
}

// TestGoogleResolver_Order: the company's bundle → the account's
// google_credentials_<id>.json → env → baked, each layer removed in turn.
func TestGoogleResolver_Order(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	acct := db.GoogleAccount{ID: 4, CompanySlug: "acme"}
	creds := calendar.NewCredentialStore(ws, acct.ID)
	require.NoError(t, creds.Save(&calendar.Credentials{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "file-secret"}))
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", "env-id")
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_SECRET", "env-secret")
	prevID, prevSecret := calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret
	calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret = "baked-id", "baked-secret"
	t.Cleanup(func() { calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret = prevID, prevSecret })

	check := func(wantSecret string, wantSrc clientSource) {
		t.Helper()
		cfg, src, err := resolveGoogleOAuthConfigForAccount(ws, acct)
		require.NoError(t, err)
		assert.Equal(t, wantSecret, cfg.ClientSecret)
		assert.Equal(t, wantSrc, src)
	}
	check("sample-secret", clientSourceCompany)

	// The company is gone: the client the account signed in with.
	require.NoError(t, os.Remove(filepath.Join(ws, "company", "acme.json")))
	check("file-secret", clientSourceAccountFile)

	// No company and no credentials: a tied account never falls to the
	// shared app; an untied one takes env, then baked.
	require.NoError(t, creds.Delete())
	_, _, err := resolveGoogleOAuthConfigForAccount(ws, acct)
	assert.ErrorIs(t, err, errNoOAuthClient)
	acct.CompanySlug = ""
	check("env-secret", clientSourceEnv)
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", "")
	check("baked-secret", clientSourceBaked)
	calendar.DefaultGoogleClientID = ""
	_, _, err = resolveGoogleOAuthConfigForAccount(ws, acct)
	assert.ErrorIs(t, err, errNoOAuthClient)

	// An own project (untied, its credentials file) is used as before.
	require.NoError(t, creds.Save(&calendar.Credentials{ClientID: "own-id", ClientSecret: "own-secret"}))
	check("own-secret", clientSourceAccountFile)

	// A damaged credentials file is reported, never a fall to the shared app.
	require.NoError(t, os.WriteFile(creds.Path(), []byte("{"), 0o600))
	_, _, err = resolveGoogleOAuthConfigForAccount(ws, acct)
	assert.Error(t, err)
	assert.False(t, needsCompanyRelogin(err))
}

// A tied account whose company's app is not the one its grant was issued to
// needs a re-login, named for the vendor; a new secret for the same client
// id is just used. The forced MDM bundle wins over the stored one.
func TestResolvers_ClientChangedAndForced(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	require.NoError(t, calendar.NewCredentialStore(ws, 1).Save(&calendar.Credentials{ClientID: "old-google-client"}))
	_, _, err := resolveGoogleOAuthConfigForAccount(ws, db.GoogleAccount{ID: 1, CompanySlug: "acme"})
	require.ErrorIs(t, err, errClientChanged)
	assert.Contains(t, err.Error(), "your company changed its Google app — sign in again")
	assert.True(t, needsCompanyRelogin(err))

	require.NoError(t, oauthclient.NewStore(ws, linearClientVendor, 2).Save(oauthclient.Client{ClientID: "old-linear"}))
	_, _, err = resolveLinearAccountClient(ws, db.LinearAccount{ID: 2, CompanySlug: "acme"})
	require.ErrorIs(t, err, errClientChanged)
	assert.Contains(t, err.Error(), "Linear app")

	require.NoError(t, oauthclient.NewStore(ws, outlookClientVendor, 3).Save(oauthclient.Client{ClientID: "old-ms"}))
	_, _, err = resolveOutlookAccountClient(ws, db.EmailAccount{ID: 3, CompanySlug: "acme"})
	require.ErrorIs(t, err, errClientChanged)
	assert.Contains(t, err.Error(), "Microsoft app")

	// Same client id, rotated secret: the bundle's.
	require.NoError(t, calendar.NewCredentialStore(ws, 1).Save(&calendar.Credentials{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "old"}))
	cfg, src, err := resolveGoogleOAuthConfigForAccount(ws, db.GoogleAccount{ID: 1, CompanySlug: "acme"})
	require.NoError(t, err)
	assert.Equal(t, "sample-secret", cfg.ClientSecret)
	assert.Equal(t, clientSourceCompany, src)

	forced := companySample("Acme")
	forced.Linear.ClientID = "forcedlinear01"
	wire := companyWire(t, forced)
	prev := companyForcedBundle
	companyForcedBundle = func() string { return wire }
	t.Cleanup(func() { companyForcedBundle = prev })
	lcfg, _, err := resolveLinearAccountClient(ws, db.LinearAccount{ID: 9, CompanySlug: "acme"})
	require.NoError(t, err)
	assert.Equal(t, "forcedlinear01", lcfg.ClientID)
}

// TestLinearResolver_Order: the company's bundle → linear_client_<id>.json →
// env → baked, read off the account's row.
func TestLinearResolver_Order(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := database.CreateLinearAccountForCompany("", "acme")
	require.NoError(t, err)
	file := oauthclient.NewStore(ws, linearClientVendor, id)
	require.NoError(t, file.Save(oauthclient.Client{ClientID: "acmelinear01"}))
	t.Setenv("WATCHTOWER_LINEAR_CLIENT_ID", "env-linear")
	prev := linear.DefaultLinearClientID
	linear.DefaultLinearClientID = "baked-linear"
	t.Cleanup(func() { linear.DefaultLinearClientID = prev })

	check := func(wantID string, wantSrc clientSource) {
		t.Helper()
		got, src, err := resolveLinearOAuthConfigForAccount(cfg, database, id)
		require.NoError(t, err)
		assert.Equal(t, wantID, got.ClientID)
		assert.Equal(t, wantSrc, src)
	}
	check("acmelinear01", clientSourceCompany)
	require.NoError(t, os.Remove(filepath.Join(ws, "company", "acme.json")))
	check("acmelinear01", clientSourceAccountFile)
	require.NoError(t, file.Delete())
	_, _, err = resolveLinearOAuthConfigForAccount(cfg, database, id)
	assert.ErrorIs(t, err, errNoOAuthClient)

	require.NoError(t, database.SetAccountCompany("linear", id, ""))
	check("env-linear", clientSourceEnv)
	t.Setenv("WATCHTOWER_LINEAR_CLIENT_ID", "")
	check("baked-linear", clientSourceBaked)

	_, _, err = resolveLinearOAuthConfigForAccount(cfg, database, id+100)
	assert.Error(t, err, "a missing row")
}

// TestMicrosoftResolver_Order: the company's Entra app and tenant →
// outlook_client_<id>.json (with its tenant) → env → baked on "common".
func TestMicrosoftResolver_Order(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	acct := db.EmailAccount{ID: 5, Provider: "outlook", CompanySlug: "acme"}
	file := oauthclient.NewStore(ws, outlookClientVendor, acct.ID)
	require.NoError(t, file.Save(oauthclient.Client{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}))
	t.Setenv("WATCHTOWER_MICROSOFT_CLIENT_ID", "env-ms")
	prev := imap.DefaultMicrosoftClientID
	imap.DefaultMicrosoftClientID = "baked-ms"
	t.Cleanup(func() { imap.DefaultMicrosoftClientID = prev })

	check := func(want imap.MicrosoftOAuthConfig, wantSrc clientSource) {
		t.Helper()
		got, src, err := resolveOutlookAccountClient(ws, acct)
		require.NoError(t, err)
		assert.Equal(t, want, got)
		assert.Equal(t, wantSrc, src)
	}
	check(imap.MicrosoftOAuthConfig{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}, clientSourceCompany)
	require.NoError(t, os.Remove(filepath.Join(ws, "company", "acme.json")))
	check(imap.MicrosoftOAuthConfig{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}, clientSourceAccountFile)
	require.NoError(t, file.Delete())
	_, _, err := resolveOutlookAccountClient(ws, acct)
	assert.ErrorIs(t, err, errNoOAuthClient)
	acct.CompanySlug = ""
	check(imap.MicrosoftOAuthConfig{ClientID: "env-ms"}, clientSourceEnv)
	t.Setenv("WATCHTOWER_MICROSOFT_CLIENT_ID", "")
	check(imap.MicrosoftOAuthConfig{ClientID: "baked-ms"}, clientSourceBaked)
}

// googleAddHarness scripts `google add`: the consent fake records the client
// it was given; the Gmail profile answers email.
type googleAddHarness struct {
	database   *db.DB
	cfg        *config.Config
	loginCalls int
	loginCfg   calendar.GoogleOAuthConfig
}

func newGoogleAddHarness(t *testing.T, email string) *googleAddHarness {
	t.Helper()
	h := &googleAddHarness{database: jiraCmdFixture(t)}
	var err error
	h.cfg, err = config.Load(flagConfig)
	require.NoError(t, err)
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", "shared-google")
	origLogin, origEmail := googleOAuthLogin, googleGrantEmail
	t.Cleanup(func() { googleOAuthLogin, googleGrantEmail = origLogin, origEmail })
	googleOAuthLogin = func(_ context.Context, c calendar.GoogleOAuthConfig, _ io.Writer, _ ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		h.loginCalls++
		h.loginCfg = c
		return &calendar.OAuthToken{AccessToken: "a", RefreshToken: "company-refresh",
			Scope: calendar.ScopeCalendarReadonly + " " + gmail.ScopeGmailReadonly}, nil
	}
	googleGrantEmail = func(context.Context, calendar.GoogleOAuthConfig, string) (string, error) { return email, nil }
	return h
}

// TestGoogleAdd_CompanyStoresSlugAndCredentials: `google add --company acme`
// signs in through the bundle's client; the new row is tied to acme in the
// same insert and records the client in google_credentials_<id>.json.
func TestGoogleAdd_CompanyStoresSlugAndCredentials(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	cmd, out := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "acme", "gmail": "true", "calendar": "true"})

	require.NoError(t, runGoogleAdd(cmd, nil), out.String())

	assert.Equal(t, calendar.GoogleOAuthConfig{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"}, h.loginCfg)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	a := accounts[0]
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", a.ClientID)
	assert.Equal(t, "a@example.com", a.Email)
	assert.Equal(t, "ok", a.Status)
	creds, err := calendar.NewCredentialStore(h.cfg.WorkspaceDir(), a.ID).Load()
	require.NoError(t, err)
	assert.Equal(t, &calendar.Credentials{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"}, creds)
	tok, err := calendar.NewAccountTokenStore(h.cfg.WorkspaceDir(), a.ID).Load()
	require.NoError(t, err)
	assert.Equal(t, "company-refresh", tok.RefreshToken)

	got, src, err := resolveGoogleOAuthConfigForAccount(h.cfg.WorkspaceDir(), a)
	require.NoError(t, err)
	assert.Equal(t, "sample-secret", got.ClientSecret)
	assert.Equal(t, clientSourceCompany, src)
}

// TestGoogleAdd_CompanyRebindsSameUser (Review Focus 5): a Google account the
// person had on the shared client, re-added through the company, stays one
// row — tied to the company, on the company's client and the new grant.
func TestGoogleAdd_CompanyRebindsSameUser(t *testing.T) {
	h := newGoogleAddHarness(t, "A@Example.com")
	ws := h.cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", Label: "Work", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, calendar.NewAccountTokenStore(ws, id).Save(&calendar.OAuthToken{RefreshToken: "shared-refresh"}))
	cmd, out := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "acme", "gmail": "true", "calendar": "true"})

	require.NoError(t, runGoogleAdd(cmd, nil), out.String())

	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1, "the same Google user is one row")
	a := accounts[0]
	assert.Equal(t, id, a.ID)
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", a.ClientID)
	assert.Equal(t, "Work", a.Label)
	tok, err := calendar.NewAccountTokenStore(ws, id).Load()
	require.NoError(t, err)
	assert.Equal(t, "company-refresh", tok.RefreshToken)
	got, _, err := resolveGoogleOAuthConfigForAccount(ws, a)
	require.NoError(t, err)
	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", got.ClientID)
}

// A tied Google account's re-login signs in through its company's app as it
// stands and records it, so a Replace's new app is what the account then
// refreshes with.
func TestGoogleLogin_TiedAccountRecordsCompanyClient(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: "acme", ClientID: "old-client", GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, calendar.NewCredentialStore(ws, id).Save(&calendar.Credentials{ClientID: "old-client"}))
	_, _, err = resolveGoogleOAuthConfigForAccount(ws, db.GoogleAccount{ID: id, CompanySlug: "acme"})
	require.ErrorIs(t, err, errClientChanged)
	cmd, out := cmdWithFlags(t, googleLoginCmd, map[string]string{"account": "0"})

	require.NoError(t, connectGoogleAccount(cmd, h.cfg, h.database, id, false, true, false), out.String())

	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", h.loginCfg.ClientID)
	a, err := h.database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", a.ClientID)
	_, src, err := resolveGoogleOAuthConfigForAccount(ws, a)
	require.NoError(t, err)
	assert.Equal(t, clientSourceCompany, src)
}

// TestCompanyAdd_UnknownSlugFailsBeforeBrowser: each vendor's --company add
// naming no stored company fails before any sign-in or row.
func TestCompanyAdd_UnknownSlugFailsBeforeBrowser(t *testing.T) {
	t.Run("google", func(t *testing.T) {
		h := newGoogleAddHarness(t, "a@example.com")
		cmd, _ := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "initech", "gmail": "true"})
		require.ErrorIs(t, runGoogleAdd(cmd, nil), errUnknownCompany)
		assert.Zero(t, h.loginCalls)
		accounts, err := h.database.ListGoogleAccounts()
		require.NoError(t, err)
		assert.Empty(t, accounts)
	})
	t.Run("linear", func(t *testing.T) {
		_, database := linearCmdFixture(t)
		calls := stubLinearOAuth(t, nil)
		cmd, _ := cmdWithFlags(t, linearAddCmd, map[string]string{"company": "initech"})
		require.ErrorIs(t, runLinearAdd(cmd, nil), errUnknownCompany)
		assert.Empty(t, *calls)
		accounts, err := database.ListLinearAccounts()
		require.NoError(t, err)
		assert.Empty(t, accounts)
	})
	t.Run("outlook", func(t *testing.T) {
		database := jiraCmdFixture(t)
		calls := stubOutlookLogin(t, "initech")
		require.ErrorIs(t, runOutlookLogin(outlookLoginCmd, nil), errUnknownCompany)
		assert.Empty(t, *calls)
		accounts, err := database.ListEmailAccounts()
		require.NoError(t, err)
		assert.Empty(t, accounts)
	})
}

// stubLinearOAuth records the client each Linear sign-in was given and
// answers viewer for the fresh token.
func stubLinearOAuth(t *testing.T, viewer *linear.Viewer) *[]linear.OAuthConfig {
	t.Helper()
	oldLogin, oldFetch := linearLogin, linearFetchViewer
	t.Cleanup(func() { linearLogin, linearFetchViewer = oldLogin, oldFetch })
	var calls []linear.OAuthConfig
	linearLogin = func(_ context.Context, c linear.OAuthConfig, _ io.Writer, _ linear.LoginOptions) (*linear.Token, error) {
		calls = append(calls, c)
		return &linear.Token{AccessToken: "a", RefreshToken: "r"}, nil
	}
	linearFetchViewer = func(context.Context, *linear.Token) (linear.Viewer, error) {
		if viewer == nil {
			t.Fatal("no viewer call expected")
		}
		return *viewer, nil
	}
	return &calls
}

// TestLinearAdd_CompanyClient: `linear add --company acme` signs in through
// the bundle's Linear app; the row is tied in the same insert and records the
// client with the token. Re-adding a workspace already connected on the
// shared app through the company re-ties that account instead of refusing.
func TestLinearAdd_CompanyClient(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	calls := stubLinearOAuth(t, &acmeViewer)
	cmd, out := cmdWithFlags(t, linearAddCmd, map[string]string{"company": "acme"})

	require.NoError(t, runLinearAdd(cmd, nil), out.String())

	require.Equal(t, []linear.OAuthConfig{{ClientID: "acmelinear01"}}, *calls)
	accounts, err := database.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	a := accounts[0]
	assert.Equal(t, "acme", a.CompanySlug)
	c, ok, err := oauthclient.NewStore(ws, linearClientVendor, a.ID).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, oauthclient.Client{ClientID: "acmelinear01"}, c)
	got, src, err := resolveLinearOAuthConfigForAccount(cfg, database, a.ID)
	require.NoError(t, err)
	assert.Equal(t, "acmelinear01", got.ClientID)
	assert.Equal(t, clientSourceCompany, src)

	// --company with --api-key is refused before anything.
	keyCmd, _ := cmdWithFlags(t, linearAddCmd, map[string]string{"company": "acme", "api-key": "true"})
	require.ErrorContains(t, runLinearAdd(keyCmd, nil), "cannot be combined with --api-key")
}

func TestLinearAdd_CompanyRetiesSameWorkspace(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	stubLinearOAuth(t, &acmeViewer)
	shared, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "old"}, "Work", linearTie{})
	require.NoError(t, err)
	cmd, out := cmdWithFlags(t, linearAddCmd, map[string]string{"company": "acme"})

	require.NoError(t, runLinearAdd(cmd, nil), out.String())

	a, err := database.GetLinearAccount(shared)
	require.NoError(t, err)
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, "ok", a.Status)
	tok, err := linear.NewTokenStore(ws, shared).Load()
	require.NoError(t, err)
	assert.Equal(t, "a", tok.AccessToken)
	_, src, err := resolveLinearOAuthConfigForAccount(cfg, database, shared)
	require.NoError(t, err)
	assert.Equal(t, clientSourceCompany, src)
	accounts, err := database.ListEnabledLinearAccounts()
	require.NoError(t, err)
	assert.Len(t, accounts, 1, "one live account for the workspace")

	// The shared app's add of a company account's workspace is still refused.
	_, _, err = connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "x"}, "", linearTie{})
	require.ErrorContains(t, err, "already connected")

	// Another member of the workspace never takes the account over.
	other := acmeViewer
	other.UserID, other.Email = "user-2", "other@example.com"
	linearFetchViewer = func(context.Context, *linear.Token) (linear.Viewer, error) { return other, nil }
	_, _, err = connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "y"}, "",
		linearTie{slug: "acme", client: &oauthclient.Client{ClientID: "acmelinear01"}})
	require.ErrorContains(t, err, "already connected")
	tok, err = linear.NewTokenStore(ws, shared).Load()
	require.NoError(t, err)
	assert.Equal(t, "a", tok.AccessToken)
}

// A tied Linear account's re-login signs in through its company's current
// app and records it with the token.
func TestLinearLogin_TiedAccountUsesCompanyApp(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := database.CreateLinearAccountForCompany("", "acme")
	require.NoError(t, err)
	require.NoError(t, database.UpdateLinearAccountConnection(id, acmeViewer.OrgID, acmeViewer.URLKey, acmeViewer.OrgName))
	require.NoError(t, oauthclient.NewStore(ws, linearClientVendor, id).Save(oauthclient.Client{ClientID: "old-linear"}))
	calls := stubLinearOAuth(t, &acmeViewer)
	setLinearFlagAccount(t, id)
	cmd, out, _ := newLinearCmd(context.Background())
	cmd.Flags().Bool("api-key", false, "")

	require.NoError(t, runLinearLogin(cmd, nil), out.String())

	require.Equal(t, []linear.OAuthConfig{{ClientID: "acmelinear01"}}, *calls)
	c, _, err := oauthclient.NewStore(ws, linearClientVendor, id).Load()
	require.NoError(t, err)
	assert.Equal(t, "acmelinear01", c.ClientID)
}

// The daemon's Linear refresh source follows the row as it is: a company app
// that is not the grant's is oauthclient.ErrClientRejected (Re-login needed).
func TestLinearAccountOAuthSource(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := database.CreateLinearAccountForCompany("", "acme")
	require.NoError(t, err)
	source := linearAccountOAuthSource(cfg, database, id)

	got, err := source()
	require.NoError(t, err)
	assert.Equal(t, "acmelinear01", got.ClientID)

	require.NoError(t, oauthclient.NewStore(ws, linearClientVendor, id).Save(oauthclient.Client{ClientID: "old-linear"}))
	_, err = source()
	require.ErrorIs(t, err, oauthclient.ErrClientRejected)
}

// stubOutlookLogin sets `outlook login --company slug` and records the
// client each sign-in was given; the sign-in returns a valid grant.
func stubOutlookLogin(t *testing.T, slug string) *[]imap.MicrosoftOAuthConfig {
	t.Helper()
	oldLogin, oldCompany := outlookLogin, outlookLoginFlagCompany
	t.Cleanup(func() { outlookLogin, outlookLoginFlagCompany = oldLogin, oldCompany })
	outlookLoginFlagCompany = slug
	var calls []imap.MicrosoftOAuthConfig
	outlookLogin = func(_ context.Context, c imap.MicrosoftOAuthConfig, _ io.Writer, _ ...imap.OutlookLoginOptions) (*imap.MicrosoftOAuthToken, string, error) {
		calls = append(calls, c)
		return &imap.MicrosoftOAuthToken{RefreshToken: "rt", Scope: "offline_access https://outlook.office.com/IMAP.AccessAsUser.All"}, "me@example.com", nil
	}
	return &calls
}

// TestOutlookLogin_CompanyTenantEndpoint (D16): `outlook login --company`
// signs in through the bundle's Entra app on its tenant (the imap package's
// TestMicrosoftTenant_AuthorizeAndRefresh pins the /<tenant>/oauth2/v2.0
// endpoints); the row is tied and records the client and tenant.
func TestOutlookLogin_CompanyTenantEndpoint(t *testing.T) {
	database := jiraCmdFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	saveCompany(t, cfg.WorkspaceDir(), companySample("Acme"))
	calls := stubOutlookLogin(t, "acme")
	outlookLoginCmd.SetOut(io.Discard)
	outlookLoginCmd.SetErr(io.Discard)

	require.NoError(t, runOutlookLogin(outlookLoginCmd, nil))

	want := imap.MicrosoftOAuthConfig{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}
	require.Equal(t, []imap.MicrosoftOAuthConfig{want}, *calls)
	accounts, err := database.ListEmailAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "acme", accounts[0].CompanySlug)
	c, ok, err := oauthclient.NewStore(cfg.WorkspaceDir(), outlookClientVendor, accounts[0].ID).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, oauthclient.Client{ClientID: want.ClientID, TenantID: want.TenantID}, c)
	got, src, err := resolveOutlookAccountClient(cfg.WorkspaceDir(), accounts[0])
	require.NoError(t, err)
	assert.Equal(t, want, got)
	assert.Equal(t, clientSourceCompany, src)

	// Logout removes the client record with the credentials.
	require.NoError(t, outlookLogoutCmd.RunE(outlookLogoutCmd, []string{"1"}))
	_, ok, err = oauthclient.NewStore(cfg.WorkspaceDir(), outlookClientVendor, accounts[0].ID).Load()
	require.NoError(t, err)
	assert.False(t, ok)
}

// Wiring: an account whose client needs a company re-login is Re-login
// needed — invalid_client tied, unknown_client untied — never revoked, and
// gets no syncer; a damaged credentials file shows its own error.
func TestWireGoogleSyncers_ClientNeedsReloginIsMarked(t *testing.T) {
	cfg := wiringTestConfig(t)
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", "")
	prev := calendar.DefaultGoogleClientID
	calendar.DefaultGoogleClientID = ""
	t.Cleanup(func() { calendar.DefaultGoogleClientID = prev })
	cfg.Calendar.Enabled, cfg.Gmail.Enabled = true, true
	database := db.OpenTestDB(t)
	stubGoogleClients(t, nil, nil)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))

	changed := newGoogleAccount(t, database, cfg, "changed", "r1")
	require.NoError(t, database.SetAccountCompany("google", changed, "acme"))
	require.NoError(t, calendar.NewCredentialStore(ws, changed).Save(&calendar.Credentials{ClientID: "old-client"}))
	untied := newGoogleAccount(t, database, cfg, "untied", "r2") // no client on any layer
	damaged := newGoogleAccount(t, database, cfg, "damaged", "r3")
	require.NoError(t, os.WriteFile(calendar.NewCredentialStore(ws, damaged).Path(), []byte("{"), 0o600))
	good := newGoogleAccount(t, database, cfg, "good", "r4")
	require.NoError(t, database.SetAccountCompany("google", good, "acme"))

	cal, gm := wireGoogleSyncers(context.Background(), cfg, database, quietTestLogger())
	assert.Len(t, cal, 1)
	assert.Len(t, gm, 1)

	for id, want := range map[int64]string{changed: oauthclient.CodeInvalidClient, untied: oauthclient.CodeUnknownClient} {
		a, err := database.GetGoogleAccount(id)
		require.NoError(t, err)
		assert.Equal(t, "error", a.Status, id)
		assert.Equal(t, want, a.Error, id)
	}
	a, err := database.GetGoogleAccount(damaged)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Contains(t, a.Error, "google_credentials_")
}

// A client Google refuses while the daemon wires the account is Re-login
// needed, not a revoked grant.
func TestWireGoogleSyncers_ClientRejectedIsNotRevoked(t *testing.T) {
	cfg := wiringTestConfig(t)
	cfg.Gmail.Enabled = true
	database := db.OpenTestDB(t)
	origGm := newGmailClient
	t.Cleanup(func() { newGmailClient = origGm })
	newGmailClient = func(context.Context, string, gmail.GoogleOAuthConfig) (*gmail.Client, error) {
		return nil, oauthclient.ErrClientRejected
	}
	id := newGoogleAccount(t, database, cfg, "a", "r1")

	_, gm := wireGoogleSyncers(context.Background(), cfg, database, quietTestLogger())
	assert.Empty(t, gm)
	a, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Equal(t, oauthclient.CodeUnknownClient, a.Error)
}

// The Outlook refresh resolves the client from the row at refresh time: a
// company app changed since the sign-in is Re-login needed (invalid_client)
// and no refresh goes out through the wrong client.
func TestOutlookAuthenticator_ClientChangedIsRelogin(t *testing.T) {
	cfg := wiringTestConfig(t)
	database := db.OpenTestDB(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := database.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "me@example.com", Security: "ssl", CompanySlug: "acme"})
	require.NoError(t, err)
	require.NoError(t, imap.NewCredentialStore(ws, id).Save(&imap.Credentials{RefreshToken: "rt"}))
	require.NoError(t, oauthclient.NewStore(ws, outlookClientVendor, id).Save(oauthclient.Client{ClientID: "old-ms"}))
	acct, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	orig := refreshOutlookAccessToken
	t.Cleanup(func() { refreshOutlookAccessToken = orig })
	refreshed := 0
	refreshOutlookAccessToken = func(context.Context, imap.MicrosoftOAuthConfig, string) (string, string, error) {
		refreshed++
		return "at", "", nil
	}

	auth, ok := outlookAuthenticator(cfg, database, acct, quietTestLogger()).(imap.RefreshingXOAUTH2Auth)
	require.True(t, ok)
	_, err = auth.RefreshFunc(context.Background())
	require.ErrorIs(t, err, oauthclient.ErrClientRejected)
	assert.Zero(t, refreshed)
	got, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", got.Status)
	assert.Equal(t, oauthclient.CodeInvalidClient, got.Error)

	// After a re-login through the company's app the same authenticator
	// refreshes through it, tenant included.
	require.NoError(t, oauthclient.NewStore(ws, outlookClientVendor, id).Save(oauthclient.Client{ClientID: "00000000-0000-0000-0000-000000000001"}))
	var seen imap.MicrosoftOAuthConfig
	refreshOutlookAccessToken = func(_ context.Context, c imap.MicrosoftOAuthConfig, _ string) (string, string, error) {
		seen = c
		return "at", "", nil
	}
	_, err = auth.RefreshFunc(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "00000000-0000-0000-0000-0000000000aa", seen.TenantID)
}

// A Google syncer's per-pass check follows the row and the company as they
// stand: fine while the account's client is its company's, Re-login needed
// once the company changed its app (a Replace or a forced MDM change).
func TestGoogleClientCheck(t *testing.T) {
	cfg := wiringTestConfig(t)
	database := db.OpenTestDB(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: "acme"})
	require.NoError(t, err)
	require.NoError(t, calendar.NewCredentialStore(ws, id).Save(&calendar.Credentials{ClientID: "1234-abcd.apps.googleusercontent.com"}))
	check := googleClientCheck(ws, database, id)
	require.NoError(t, check())

	changed := companySample("Acme")
	changed.Google.ClientID = "5678-efgh.apps.googleusercontent.com"
	require.NoError(t, company.NewStore(ws).Save("acme", changed))
	require.ErrorIs(t, check(), oauthclient.ErrClientRejected)
}

// Linear wiring shows a client problem on the row and wires no syncer: a
// changed company app is Re-login needed, a damaged client file its error.
func TestBuildLinearSyncers_ClientProblemsAreShown(t *testing.T) {
	cfg := wiringTestConfig(t)
	cfg.Linear.Enabled = true
	database := db.OpenTestDB(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	token := &linear.Token{AccessToken: "a", RefreshToken: "r"}
	changed, err := database.CreateLinearAccountForCompany("", "acme")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(ws, changed).Save(token))
	require.NoError(t, oauthclient.NewStore(ws, linearClientVendor, changed).Save(oauthclient.Client{ClientID: "old-linear"}))
	damaged, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(ws, damaged).Save(token))
	require.NoError(t, os.WriteFile(oauthclient.NewStore(ws, linearClientVendor, damaged).Path(), []byte("{"), 0o600))
	good, err := database.CreateLinearAccountForCompany("", "acme")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(ws, good).Save(token))

	syncers := buildLinearSyncers(cfg, database, quietTestLogger())
	require.Len(t, syncers, 1)
	assert.Equal(t, good, syncers[0].AccountID())
	a, err := database.GetLinearAccount(changed)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Equal(t, oauthclient.CodeInvalidClient, a.Error)
	a, err = database.GetLinearAccount(damaged)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Contains(t, a.Error, "linear_client_")
}

// A company Gmail grant whose address cannot be read creates no row: it
// could be the person's existing account (Review Focus 5).
func TestGoogleAdd_CompanyUnreadableAddressCreatesNothing(t *testing.T) {
	h := newGoogleAddHarness(t, "")
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	cmd, _ := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "acme", "gmail": "true"})

	require.ErrorContains(t, runGoogleAdd(cmd, nil), "could not read the Gmail address")
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// A personal API key never refreshes: its account is wired with no OAuth
// client on any layer.
func TestBuildLinearSyncers_APIKeyNeedsNoClient(t *testing.T) {
	cfg := wiringTestConfig(t)
	t.Setenv("WATCHTOWER_LINEAR_CLIENT_ID", "")
	prev := linear.DefaultLinearClientID
	linear.DefaultLinearClientID = ""
	t.Cleanup(func() { linear.DefaultLinearClientID = prev })
	cfg.Linear.Enabled = true
	database := db.OpenTestDB(t)
	id, err := database.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, linear.NewTokenStore(cfg.WorkspaceDir(), id).Save(linear.APIKeyToken("lin_api_x")))

	syncers := buildLinearSyncers(cfg, database, quietTestLogger())
	require.Len(t, syncers, 1)
	a, err := database.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "ok", a.Status)
}

// A re-tie whose new grant lacks a service the row syncs is refused and
// leaves the row as it was.
func TestGoogleAdd_CompanyRetieMustCoverServices(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	googleOAuthLogin = func(context.Context, calendar.GoogleOAuthConfig, io.Writer, ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		return &calendar.OAuthToken{AccessToken: "a", RefreshToken: "r", Scope: gmail.ScopeGmailReadonly}, nil
	}
	cmd, _ := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "acme", "gmail": "true"})

	require.ErrorContains(t, runGoogleAdd(cmd, nil), "also syncs calendar,gmail")
	a, err := h.database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Empty(t, a.CompanySlug)
	assert.True(t, a.CalendarEnabled)
	assert.False(t, calendar.NewCredentialStore(ws, id).Exists())
}

// The same Entra client id in another tenant is another app.
func TestMicrosoftResolver_TenantChangeNeedsLogin(t *testing.T) {
	ws := t.TempDir()
	saveCompany(t, ws, companySample("Acme"))
	require.NoError(t, oauthclient.NewStore(ws, outlookClientVendor, 1).Save(oauthclient.Client{
		ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "old-tenant.example.com"}))
	_, _, err := resolveOutlookAccountClient(ws, db.EmailAccount{ID: 1, CompanySlug: "acme"})
	require.ErrorIs(t, err, errClientChanged)
}

// LINEAR-03: a purged workspace comes back only by a re-login, also through
// a company's app.
func TestLinearAdd_CompanyRefusesPurged(t *testing.T) {
	cfg, database := linearCmdFixture(t)
	stubLinearOAuth(t, &acmeViewer)
	id, _, err := connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "old"}, "", linearTie{})
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE linear_accounts SET status = 'purged' WHERE id = ?`, id)
	require.NoError(t, err)

	_, _, err = connectLinearAccount(context.Background(), cfg, database, &linear.Token{AccessToken: "new"}, "",
		linearTie{slug: "acme", client: &oauthclient.Client{ClientID: "acmelinear01"}})
	require.ErrorContains(t, err, "already connected")
}
