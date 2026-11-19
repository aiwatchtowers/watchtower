package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/jira"
	"watchtower/internal/oauthclient"
	"watchtower/internal/oauthpage"
)

// #1887 Task 13 (S28): the wizard's vendor checks — Google and Atlassian by
// the person's own sign-in, which is their connection and stores the
// company's bundle; Linear and Microsoft by a dry authorize.

func checkGoogleBlock() *companybundle.Google {
	return &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"}
}

func checkAtlassianBlock() *companybundle.Atlassian {
	return &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net", Confluence: true}
}

// saveCheckDraft is the wizard's draft holding the blocks the checks send.
func saveCheckDraft(t *testing.T, ws string, g *companybundle.Google, a *companybundle.Atlassian) {
	t.Helper()
	require.NoError(t, company.NewStore(ws).SaveDraft(company.Draft{
		Company: "Acme", Services: []string{"google", "atlassian"}, Step: "google", Google: g, Atlassian: a,
	}))
}

func loadCheckDraft(t *testing.T, ws string) company.Draft {
	t.Helper()
	d, state, _, err := company.NewStore(ws).LoadDraft(companyNow())
	require.NoError(t, err)
	require.Equal(t, company.DraftOK, state)
	return d
}

func storedCompany(t *testing.T, ws, slug string) (companybundle.Bundle, bool) {
	t.Helper()
	e, ok, err := company.NewStore(ws).Get(slug, "")
	require.NoError(t, err)
	return e.Bundle, ok
}

func runSignInCheck(t *testing.T, cfg *config.Config, database *db.DB, vendor string, in companyCheckInput, replace bool, forced string) companyCheckResult {
	t.Helper()
	cmd, _ := cmdWithFlags(t, companyCheckCmd, nil)
	res, err := signInCheckCompany(cmd, cfg, database, vendor, in, replace, forced)
	require.NoError(t, err)
	return res
}

// stubJiraMyself answers /myself with accountID.
func stubJiraMyself(t *testing.T, accountID string) {
	t.Helper()
	orig := jiraFetchMyself
	t.Cleanup(func() { jiraFetchMyself = orig })
	jiraFetchMyself = func(_ context.Context, token, cloudID string) (jira.Myself, error) {
		assert.Equal(t, "a", token)
		assert.Equal(t, "cloud-acme", cloudID)
		return jira.Myself{AccountID: accountID, EmailAddress: "a@example.com", DisplayName: "A"}, nil
	}
}

// exchangeRefused is the error calendar.Login / jira.Login return when the
// vendor refuses the code exchange (their "exchanging code for token: token
// exchange failed (<status>): <body>").
func exchangeRefused(body string) error {
	return fmt.Errorf("exchanging code for token: %w", fmt.Errorf("token exchange failed (401): %s", body))
}

// TestCompanyCheck_GoogleIsSignIn: the Google check signs in through the
// entered client; a refused exchange (a wrong secret) is rejected with
// Google's key and stores nothing.
func TestCompanyCheck_GoogleIsSignIn(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	googleOAuthLogin = func(_ context.Context, c calendar.GoogleOAuthConfig, _ io.Writer, _ ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		h.loginCalls++
		h.loginCfg = c
		return nil, exchangeRefused(`{"error":"invalid_client","error_description":"Unauthorized"}`)
	}

	res := runSignInCheck(t, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")

	assert.Equal(t, checkRejected, res.Result)
	assert.Equal(t, "invalid_client", res.Code)
	assert.Equal(t, 1, h.loginCalls)
	assert.Equal(t, calendar.GoogleOAuthConfig{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"}, h.loginCfg)
	_, ok := storedCompany(t, ws, "acme")
	assert.False(t, ok, "nothing stored")
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// TestCompanyCheck_AtlassianNeedsToken: an Atlassian sign-in that never
// returns a token (the browser left open past the timeout) stores no bundle
// and no row.
func TestCompanyCheck_AtlassianNeedsToken(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	jiraLogin = func(context.Context, jira.JiraOAuthConfig, io.Writer, ...jira.LoginOptions) (*jira.OAuthToken, error) {
		h.loginCalls++
		return nil, fmt.Errorf("%w after 5m0s", oauthpage.ErrLoginTimedOut)
	}

	res := runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Atlassian: checkAtlassianBlock()}, false, "")

	assert.Equal(t, checkCancelled, res.Result)
	assert.Equal(t, "timed_out", res.Code)
	assert.Equal(t, 1, h.loginCalls)
	_, ok := storedCompany(t, h.cfg.WorkspaceDir(), "acme")
	assert.False(t, ok)
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// TestCheckSignInCreatesCompanyAccount: a token back stores the bundle with
// the Atlassian block, creates the person's account tied to the company
// (its client in its own file, its owner recorded for the next match) and
// marks the draft's step.
func TestCheckSignInCreatesCompanyAccount(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	ws := h.cfg.WorkspaceDir()
	saveCheckDraft(t, ws, nil, checkAtlassianBlock())

	res := runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Atlassian: checkAtlassianBlock()}, false, "")

	require.Equal(t, checkOK, res.Result, res.Message)
	assert.Equal(t, jira.JiraOAuthConfig{ClientID: "acmeClientId01", ClientSecret: "acme-secret"}, h.loginCfg)
	assert.True(t, h.loginOpts.WithConfluence)
	assert.Equal(t, "acme", res.Slug)
	assert.Equal(t, "https://acme.atlassian.net", res.Site)
	assert.Equal(t, "a@example.com", res.Email)
	assert.True(t, res.Checked)

	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	a := accounts[0]
	assert.Equal(t, res.AccountID, a.ID)
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, "cloud-acme", a.CloudID)
	assert.Equal(t, "557058:aaaa", a.OwnerAccountID)
	assert.Equal(t, "ok", a.Status)
	c, ok, err := oauthclient.NewStore(ws, jiraClientVendor, a.ID).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, "acmeClientId01", c.ClientID)

	b, ok := storedCompany(t, ws, "acme")
	require.True(t, ok)
	assert.Equal(t, checkAtlassianBlock(), b.Atlassian)
	got, src, err := resolveJiraOAuthConfigForAccount(ws, a)
	require.NoError(t, err)
	assert.Equal(t, clientSourceCompany, src)
	assert.Equal(t, "acmeClientId01", got.ClientID)

	d := loadCheckDraft(t, ws)
	assert.True(t, d.IsChecked("atlassian"))
	assert.Equal(t, "acme", d.Slug)
}

// TestFirstCheckStoresBundle: the first (Google) check creates
// company/<slug>.json with the company name and the Google block, the
// Workspace domain from the signed-in address; the draft keeps the slug and
// the domain.
func TestFirstCheckStoresBundle(t *testing.T) {
	h := newGoogleAddHarness(t, "a@Example.com")
	ws := h.cfg.WorkspaceDir()
	saveCheckDraft(t, ws, checkGoogleBlock(), nil)

	res := runSignInCheck(t, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")

	require.Equal(t, checkOK, res.Result, res.Message)
	assert.Equal(t, "example.com", res.Domain)
	assert.True(t, res.Checked)
	b, ok := storedCompany(t, ws, "acme")
	require.True(t, ok)
	assert.Equal(t, "Acme", b.Company)
	assert.Equal(t, &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret", Domain: "example.com"}, b.Google)
	assert.Nil(t, b.Atlassian)
	fi, err := os.Stat(filepath.Join(ws, "company", "acme.json"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())

	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, res.AccountID, accounts[0].ID)
	assert.Equal(t, "acme", accounts[0].CompanySlug)
	assert.True(t, accounts[0].GmailEnabled)
	assert.True(t, accounts[0].CalendarEnabled)

	d := loadCheckDraft(t, ws)
	assert.True(t, d.IsChecked("google"))
	assert.Equal(t, "acme", d.Slug)
	assert.Equal(t, "example.com", d.Google.Domain)
}

// TestLaterCheckAddsBlock: a later check of another vendor adds its block
// to the stored bundle and keeps the first.
func TestLaterCheckAddsBlock(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	ws := h.cfg.WorkspaceDir()
	first := companybundle.Bundle{V: 1, Company: "Acme", Google: &companybundle.Google{
		ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret", Domain: "example.com"}}
	saveCompany(t, ws, first)

	res := runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Slug: "acme", Atlassian: checkAtlassianBlock()}, false, "")

	require.Equal(t, checkOK, res.Result, res.Message)
	assert.False(t, res.Checked, "no draft: the check still connects")
	b, ok := storedCompany(t, ws, "acme")
	require.True(t, ok)
	assert.Equal(t, first.Google, b.Google)
	assert.Equal(t, checkAtlassianBlock(), b.Atlassian)
}

// TestCheckOverStoredCompanyNeedsReplace: a check that changes the client a
// stored bundle of the company has answers replace_needed before any
// browser; with --replace it stores the new client and marks the company's
// other accounts of that vendor for a new login. A rotated secret alone is
// no Replace.
func TestCheckOverStoredCompanyNeedsReplace(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	ws := h.cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	ids := companyAccounts(t, h.database, "acme")
	changed := checkAtlassianBlock()
	changed.ClientID = "acmeClientId02"
	in := companyCheckInput{Company: "Acme", Atlassian: changed}

	res := runSignInCheck(t, h.cfg, h.database, "atlassian", in, false, "")
	assert.Equal(t, checkReplaceNeeded, res.Result)
	assert.Equal(t, "client_id", res.Code)
	assert.Zero(t, h.loginCalls, "no browser before the owner agreed")
	b, _ := storedCompany(t, ws, "acme")
	assert.Equal(t, "acmeClientId01", b.Atlassian.ClientID)

	res = runSignInCheck(t, h.cfg, h.database, "atlassian", in, true, "")
	require.Equal(t, checkOK, res.Result, res.Message)
	b, _ = storedCompany(t, ws, "acme")
	assert.Equal(t, "acmeClientId02", b.Atlassian.ClientID)
	assert.Equal(t, companySample("Acme").Google, b.Google, "other vendors untouched")
	other, err := h.database.GetJiraAccount(ids["jira"])
	require.NoError(t, err)
	assert.Equal(t, "error", other.Status)
	assert.Equal(t, company.ChangedAppCode, other.Error)
	g, err := h.database.GetGoogleAccount(ids["google"])
	require.NoError(t, err)
	assert.Equal(t, "ok", g.Status, "only the checked vendor's accounts")

	rotated := checkAtlassianBlock()
	rotated.ClientID, rotated.ClientSecret = "acmeClientId02", "rotated-secret"
	res = runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Atlassian: rotated}, false, "")
	assert.Equal(t, checkOK, res.Result, "a new secret of the same client is no Replace")
}

// TestEditThenRecheckRelogsSameAccount: after an edit of the checked pair,
// the re-check signs the same Atlassian user in again: the same row is
// re-logged on the new client (its file and the stored bundle updated in
// that step), not a second row.
func TestEditThenRecheckRelogsSameAccount(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	ws := h.cfg.WorkspaceDir()
	saveCheckDraft(t, ws, nil, checkAtlassianBlock())
	first := runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Atlassian: checkAtlassianBlock()}, false, "")
	require.Equal(t, checkOK, first.Result, first.Message)

	edited := checkAtlassianBlock()
	edited.ClientID, edited.ClientSecret = "acmeClientId02", "new-secret"
	saveCheckDraft(t, ws, nil, edited)
	assert.False(t, loadCheckDraft(t, ws).IsChecked("atlassian"), "an edit un-checks")
	in := companyCheckInput{Company: "Acme", Slug: loadCheckDraft(t, ws).Slug, Atlassian: edited}
	require.Equal(t, checkReplaceNeeded, runSignInCheck(t, h.cfg, h.database, "atlassian", in, false, "").Result)
	again := runSignInCheck(t, h.cfg, h.database, "atlassian", in, true, "")
	require.Equal(t, checkOK, again.Result, again.Message)

	assert.Equal(t, first.AccountID, again.AccountID, "the same user is the same row")
	accounts, err := h.database.ListJiraAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "ok", accounts[0].Status, "the re-login clears the Replace mark")
	c, _, err := oauthclient.NewStore(ws, jiraClientVendor, first.AccountID).Load()
	require.NoError(t, err)
	assert.Equal(t, oauthclient.Client{ClientID: "acmeClientId02", ClientSecret: "new-secret"}, c)
	b, _ := storedCompany(t, ws, "acme")
	assert.Equal(t, edited, b.Atlassian)
	assert.True(t, loadCheckDraft(t, ws).IsChecked("atlassian"))
}

// An Atlassian user's own row on another site, an API-token row and a
// removed row are never re-logged by a check.
func TestCompanyJiraAccountRow_MatchesOAuthRowOnSite(t *testing.T) {
	database := jiraCmdFixture(t)
	for _, a := range []db.JiraAccount{
		{CloudID: "cloud-other"}, {CloudID: "cloud-acme", AuthKind: "api_token"}, {CloudID: "cloud-acme"},
	} {
		id, err := database.CreateJiraAccount(a)
		require.NoError(t, err)
		require.NoError(t, database.SetJiraAccountOwner(id, "557058:aaaa", "", ""))
	}
	require.NoError(t, database.SetJiraAccountRemoved(3))

	id, err := companyJiraGrantRow(t.TempDir(), database, "557058:aaaa", "cloud-acme", &jira.OAuthToken{}, io.Discard)
	require.NoError(t, err)
	assert.Zero(t, id, "a new row")
}

// TestCompanyCheck_ForcedCompany: under an MDM bundle of the same company the
// check's write is stored but the overlay wins; the account works when the
// forced client is the checked one, else it shows Re-login at once.
func TestCompanyCheck_ForcedCompany(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	forcedBundle := companySample("Acme")
	forcedBundle.Google.ClientID = "9999-zzzz.apps.googleusercontent.com"
	forced := companyWire(t, forcedBundle)

	res := runSignInCheck(t, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, forced)

	require.Equal(t, checkForced, res.Result, res.Message)
	b, ok := storedCompany(t, ws, res.Slug)
	require.True(t, ok, "the check is stored")
	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", b.Google.ClientID)
	a, err := h.database.GetGoogleAccount(res.AccountID)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Equal(t, company.ChangedAppCode, a.Error)

	// The forced client is the checked one: the account works.
	h2 := newGoogleAddHarness(t, "b@example.com")
	res = runSignInCheck(t, h2.cfg, h2.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false,
		companyWire(t, companySample("Acme")))
	require.Equal(t, checkForced, res.Result)
	a, err = h2.database.GetGoogleAccount(res.AccountID)
	require.NoError(t, err)
	assert.Equal(t, "ok", a.Status)
}

// TestCompanyCheck_QuitDuringSignInStoresNothing: the wizard (or the app)
// stops the check while the browser is open: the wait ends as a cancel, and
// no file and no row exist.
func TestCompanyCheck_QuitDuringSignInStoresNothing(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	saveCheckDraft(t, ws, checkGoogleBlock(), nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	googleOAuthLogin = func(ctx context.Context, _ calendar.GoogleOAuthConfig, _ io.Writer, _ ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		cancel() // the quit arrives while the browser is open
		<-ctx.Done()
		return nil, fmt.Errorf("%w after 5m0s", oauthpage.ErrLoginTimedOut)
	}
	cmd, _ := cmdWithFlags(t, companyCheckCmd, nil)
	cmd.SetContext(ctx)

	res, err := signInCheckCompany(cmd, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")

	require.NoError(t, err)
	assert.Equal(t, checkCancelled, res.Result)
	_, ok := storedCompany(t, ws, "acme")
	assert.False(t, ok)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
	assert.False(t, loadCheckDraft(t, ws).IsChecked("google"))
}

// An edit saved while the sign-in runs leaves the step unchecked: the
// account and the bundle of the old values stay (they work), the draft
// names the company.
func TestCompanyCheck_EditDuringSignInLeavesStepUnchecked(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	saveCheckDraft(t, ws, checkGoogleBlock(), nil)
	orig := googleOAuthLogin
	googleOAuthLogin = func(ctx context.Context, c calendar.GoogleOAuthConfig, w io.Writer, o ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		saveCheckDraft(t, ws, &companybundle.Google{ClientID: "5678-efgh.apps.googleusercontent.com", ClientSecret: "s"}, nil)
		return orig(ctx, c, w, o...)
	}

	res := runSignInCheck(t, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")

	require.Equal(t, checkOK, res.Result)
	assert.False(t, res.Checked)
	_, ok := storedCompany(t, ws, "acme")
	assert.True(t, ok)
	d := loadCheckDraft(t, ws)
	assert.False(t, d.IsChecked("google"))
	assert.Equal(t, "acme", d.Slug)
}

// A company file changed between the plan's read and the write (another
// confirm or check) wins: this check stores nothing and says so.
func TestCompanyCheck_ConcurrentWriteWins(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	orig := googleOAuthLogin
	googleOAuthLogin = func(ctx context.Context, c calendar.GoogleOAuthConfig, w io.Writer, o ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		saveCompany(t, ws, companySample("Acme"))
		return orig(ctx, c, w, o...)
	}
	cmd, _ := cmdWithFlags(t, companyCheckCmd, nil)

	_, err := signInCheckCompany(cmd, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")

	require.ErrorIs(t, err, company.ErrStoredChanged)
	b, _ := storedCompany(t, ws, "acme")
	assert.Equal(t, companySample("Acme"), b)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// A Google check by a person who had the account on the shared client
// re-ties that row (one row, the company's client); a grant that lacks a
// service the row syncs is refused before anything is stored.
func TestCompanyCheck_GoogleRebindsSameUser(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "A@example.com", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)

	res := runSignInCheck(t, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")
	require.Equal(t, checkOK, res.Result, res.Message)
	assert.Equal(t, id, res.AccountID)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, "acme", accounts[0].CompanySlug)
	assert.Equal(t, "1234-abcd.apps.googleusercontent.com", accounts[0].ClientID)
}

func TestCompanyCheck_GoogleGrantTooNarrowStoresNothing(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	ws := h.cfg.WorkspaceDir()
	_, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	googleOAuthLogin = func(context.Context, calendar.GoogleOAuthConfig, io.Writer, ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		return &calendar.OAuthToken{AccessToken: "a", RefreshToken: "r", Scope: gmail.ScopeGmailReadonly}, nil
	}

	res := runSignInCheck(t, h.cfg, h.database, "google", companyCheckInput{Company: "Acme", Google: checkGoogleBlock()}, false, "")

	assert.Equal(t, checkRejected, res.Result)
	assert.Equal(t, "grant_too_narrow", res.Code)
	_, ok := storedCompany(t, ws, "acme")
	assert.False(t, ok)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Empty(t, accounts[0].CompanySlug)
}

// Re-logging an Atlassian account that uses Confluence write asks for the
// write scopes; a grant that comes back without them is refused before
// anything is stored.
func TestCompanyCheck_AtlassianKeepsConfluenceScopes(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	ws := h.cfg.WorkspaceDir()
	id, err := h.database.CreateJiraAccount(db.JiraAccount{CloudID: "cloud-acme", SiteURL: "https://acme.atlassian.net"})
	require.NoError(t, err)
	require.NoError(t, h.database.SetJiraAccountOwner(id, "557058:aaaa", "", ""))
	require.NoError(t, jira.NewTokenStore(ws, id).Save(&jira.OAuthToken{RefreshToken: "old",
		Scope: jira.OAuthScopes + " " + jira.ConfluenceWriteScopes}))
	plain := checkAtlassianBlock()
	plain.Confluence = false

	res := runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Atlassian: plain}, false, "")

	assert.True(t, h.loginOpts.WithConfluence)
	assert.True(t, h.loginOpts.WithConfluenceWrite)
	assert.Equal(t, checkRejected, res.Result, "the fake grant has no write scopes")
	assert.Equal(t, "grant_too_narrow", res.Code)
	_, ok := storedCompany(t, ws, "acme")
	assert.False(t, ok)
	tok, err := jira.NewTokenStore(ws, id).Load()
	require.NoError(t, err)
	assert.Equal(t, "old", tok.RefreshToken)
}

// An Atlassian check under an MDM bundle with another client is stored but
// its account shows Re-login at once.
func TestCompanyCheck_AtlassianForcedOtherClient(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	stubJiraMyself(t, "557058:aaaa")
	forced := companySample("Acme")
	forced.Atlassian.ClientID = "forcedClient01"

	res := runSignInCheck(t, h.cfg, h.database, "atlassian", companyCheckInput{Company: "Acme", Atlassian: checkAtlassianBlock()}, false,
		companyWire(t, forced))

	require.Equal(t, checkForced, res.Result, res.Message)
	a, err := h.database.GetJiraAccount(res.AccountID)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Equal(t, company.ChangedAppCode, a.Error)
}

func TestPlanCompanyCheck_RefusesBadInput(t *testing.T) {
	store := company.NewStore(t.TempDir())
	_, err := planCompanyCheck(store, "google", companyCheckInput{Company: "Acme", Atlassian: checkAtlassianBlock()}, false, "")
	assert.Error(t, err, "the wrong block")

	bad := checkAtlassianBlock()
	bad.Site = "http://acme.atlassian.net"
	p, err := planCompanyCheck(store, "atlassian", companyCheckInput{Company: "Acme", Atlassian: bad}, false, "")
	require.NoError(t, err)
	require.NotNil(t, p.stop)
	assert.Equal(t, checkRejected, p.stop.Result)
	assert.Equal(t, string(companybundle.RefusalSiteNotHTTPS), p.stop.Code)

	_, err = planCompanyCheck(store, "atlassian", companyCheckInput{Company: "Acme", Slug: "../acme", Atlassian: checkAtlassianBlock()}, false, "")
	assert.ErrorContains(t, err, "is stored under", "refused before any browser")

	// The slug of another company's file, or of an MDM company with no file
	// (its accounts carry it), is never taken over.
	require.NoError(t, store.Save("acme", companybundle.Bundle{V: 1, Company: "Initech"}))
	_, err = planCompanyCheck(store, "atlassian", companyCheckInput{Company: "Acme", Slug: "acme", Atlassian: checkAtlassianBlock()}, false, "")
	assert.ErrorContains(t, err, `stored under "acme-2"`)
	p, err = planCompanyCheck(store, "atlassian", companyCheckInput{Company: "Acme", Atlassian: checkAtlassianBlock()}, false, "")
	require.NoError(t, err)
	assert.Equal(t, "acme-2", p.slug)

	mdm := company.NewStore(t.TempDir())
	forced := companyWire(t, companySample("Acme"))
	_, err = planCompanyCheck(mdm, "atlassian", companyCheckInput{Company: "ACME", Slug: "acme", Atlassian: checkAtlassianBlock()}, false, forced)
	assert.ErrorContains(t, err, `stored under "acme-2"`)
}

// TestCompanyCheck_SignInErrorsClassified: the sign-in's failures as the
// vendors' Login functions return them.
func TestCompanyCheck_SignInErrorsClassified(t *testing.T) {
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	cases := []struct {
		name string
		ctx  context.Context
		err  error
		want companyCheckResult
	}{
		{"stopped", cancelled, errors.New("x"), companyCheckResult{Result: checkCancelled, Message: "the sign-in was stopped"}},
		{"timed out", context.Background(), fmt.Errorf("%w after 5m0s", oauthpage.ErrLoginTimedOut),
			companyCheckResult{Result: checkCancelled, Code: "timed_out", Message: "login timed out after 5m0s"}},
		{"said no", context.Background(), errors.New("jira authorization denied: access_denied"),
			companyCheckResult{Result: checkCancelled, Code: "access_denied", Message: "jira authorization denied: access_denied"}},
		{"redirect refused", context.Background(), errors.New("jira authorization denied: unauthorized_client"),
			companyCheckResult{Result: checkRejected, Code: "unauthorized_client", Message: "jira authorization denied: unauthorized_client"}},
		{"exchange refused", context.Background(), exchangeRefused(`{"error": "invalid_client"}`),
			companyCheckResult{Result: checkRejected, Code: "invalid_client", Message: `exchanging code for token: token exchange failed (401): {"error": "invalid_client"}`}},
		{"not cloud", context.Background(), fmt.Errorf("company Atlassian site: %w", jira.ErrNotAtlassianCloud),
			companyCheckResult{Result: checkRejected, Code: "not_atlassian_cloud", Message: "company Atlassian site: not an Atlassian Cloud site"}},
		{"other site", context.Background(), fmt.Errorf("%w https://acme.atlassian.net", errCompanySiteNotReached),
			companyCheckResult{Result: checkRejected, Code: "site_not_reached", Message: errCompanySiteNotReached.Error() + " https://acme.atlassian.net"}},
		{"unreachable", context.Background(), fmt.Errorf("exchanging code for token: %w", &url.Error{Op: "Post", URL: "https://example.com", Err: errors.New("dial tcp: no route")}),
			companyCheckResult{Result: checkNetwork, Message: `exchanging code for token: Post "https://example.com": dial tcp: no route`}},
		{"vendor down", context.Background(), errors.New(`myself failed (503): {"error":"unavailable"}`),
			companyCheckResult{Result: checkNetwork, Message: `myself failed (503): {"error":"unavailable"}`}},
		{"other", context.Background(), errors.New("no authorization code received"),
			companyCheckResult{Result: checkRejected, Message: "no authorization code received"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, classifySignInError(c.ctx, c.err))
		})
	}
}

func TestGoogleWorkspaceDomain(t *testing.T) {
	assert.Equal(t, "example.com", googleWorkspaceDomain(" A@Example.COM "))
	assert.Empty(t, googleWorkspaceDomain("a@gmail.com")) // leak-check:allow (a consumer address sample)
	assert.Empty(t, googleWorkspaceDomain(""))
}

// dryTransport answers the dry check's single GET.
type dryTransport struct {
	status   int
	location string
	calls    int
}

func (d *dryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	d.calls++
	h := http.Header{}
	if d.location != "" {
		h.Set("Location", d.location)
	}
	return &http.Response{StatusCode: d.status, Header: h, Body: io.NopCloser(strings.NewReader("")), Request: req}, nil
}

// The Linear and Microsoft checks are dry: a pass marks the draft's step,
// missing consent gives the admin consent link and marks nothing; nothing
// else is stored.
func TestCompanyCheck_DryVendors(t *testing.T) {
	ws := t.TempDir()
	store := company.NewStore(ws)
	require.NoError(t, store.SaveDraft(company.Draft{Company: "Acme", Services: []string{"linear", "microsoft"},
		Linear:    &companybundle.Linear{ClientID: "acmelinear01"},
		Microsoft: &companybundle.Microsoft{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000AA"}}))

	ok := &dryTransport{status: 200}
	res := dryCheckCompany(context.Background(), io.Discard, store, "linear", "acmelinear01", "", &http.Client{Transport: ok})
	assert.Equal(t, companyCheckResult{Result: checkOK, Checked: true}, res)
	assert.Equal(t, 1, ok.calls)

	consent := &dryTransport{status: 302, location: "http://127.0.0.1:18531/callback?error=consent_required&error_description=AADSTS65001"}
	res = dryCheckCompany(context.Background(), io.Discard, store, "microsoft", "00000000-0000-0000-0000-000000000001",
		"00000000-0000-0000-0000-0000000000AA", &http.Client{Transport: consent})
	assert.Equal(t, company.DryAdminConsent, res.Result)
	assert.Equal(t, "https://login.microsoftonline.com/00000000-0000-0000-0000-0000000000aa/adminconsent?client_id=00000000-0000-0000-0000-000000000001",
		res.AdminConsentURL)
	assert.False(t, res.Checked)

	res = dryCheckCompany(context.Background(), io.Discard, store, "microsoft", "00000000-0000-0000-0000-000000000001",
		"00000000-0000-0000-0000-0000000000AA", &http.Client{Transport: ok})
	assert.True(t, res.Checked, "the draft's own (unnormalized) values are the ones checked")

	d, _, _, err := store.LoadDraft(companyNow())
	require.NoError(t, err)
	assert.Equal(t, []string{"linear", "microsoft"}, d.CheckedVendors())
	entries, _, err := store.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries, "a dry check stores no company")

	other := dryCheckCompany(context.Background(), io.Discard, store, "linear", "typo01", "", &http.Client{Transport: ok})
	assert.False(t, other.Checked, "values the draft does not hold")
}

// The verb end to end: flags per vendor, the JSON result on stdout only.
func TestCompanyCheck_CLI(t *testing.T) {
	jiraCmdFixture(t)
	orig := companyDryHTTP
	t.Cleanup(func() { companyDryHTTP = orig })
	companyDryHTTP = &http.Client{Transport: &dryTransport{status: 200}}

	reset := func() {
		companyCheckFlags.replace, companyCheckFlags.clientID, companyCheckFlags.tenant = false, "", ""
		for _, f := range []string{"json", "client-id", "tenant", "replace"} {
			fl := companyCheckCmd.Flags().Lookup(f)
			_ = fl.Value.Set(fl.DefValue)
			fl.Changed = false
		}
	}
	t.Cleanup(reset)
	run := func(args ...string) (string, error) {
		reset()
		var out strings.Builder
		rootCmd.SetOut(&out)
		rootCmd.SetErr(io.Discard)
		rootCmd.SetIn(strings.NewReader(""))
		rootCmd.SetArgs(append([]string{"--config", flagConfig, "company", "check"}, args...))
		defer rootCmd.SetArgs(nil)
		err := rootCmd.Execute()
		return out.String(), err
	}

	out, err := run("linear", "--client-id", "acmelinear01", "--json")
	require.NoError(t, err)
	var res map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &res), out)
	assert.Equal(t, "ok", res["result"])
	for _, k := range []string{"slug", "account_id", "email", "domain", "site", "code", "message", "checked"} {
		assert.Contains(t, res, k)
	}

	_, err = run("slack")
	assert.Error(t, err)
	_, err = run("linear")
	assert.ErrorContains(t, err, "--client-id")
	_, err = run("microsoft", "--client-id", "x")
	assert.ErrorContains(t, err, "--tenant")
	_, err = run("linear", "--client-id", "x", "--replace")
	assert.ErrorContains(t, err, "--replace")
	_, err = run("google", "--client-id", "x")
	assert.ErrorContains(t, err, "stdin")
	_, err = run("google")
	assert.ErrorContains(t, err, "decoding the check")
}
