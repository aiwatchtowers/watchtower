package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

const ownClientID = "5678-own.apps.googleusercontent.com"

func ownGoogleAddCmd(t *testing.T, secret string) (*cobra.Command, *bytes.Buffer) {
	t.Helper()
	c, out := cmdWithFlags(t, googleAddCmd, map[string]string{
		"client-id": ownClientID, "client-secret-stdin": "true", "gmail": "true", "calendar": "true",
	})
	c.SetIn(strings.NewReader(secret + "\n"))
	return c, out
}

// A policy that forbids own projects while the consent is open stores
// nothing: the tie asks the policy again before SavePersonal.
func TestGoogleAddClientID_PolicyTightenedDuringConsent(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	policytest.Set(t, nil)
	orig := googleOAuthLogin
	googleOAuthLogin = func(ctx context.Context, c calendar.GoogleOAuthConfig, w io.Writer, o ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
		return orig(ctx, c, w, o...)
	}
	c, out := ownGoogleAddCmd(t, "own-secret")

	require.ErrorIs(t, runGoogleAdd(c, nil), policy.ErrNotAllowed, out.String())

	entries, _, err := company.NewStore(h.cfg.WorkspaceDir()).LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// TestGoogleAddClientID_SavesPersonalBundle: `google add --client-id
// --client-secret-stdin` stores the own project as a personal bundle named
// after the signed-in address and ties the new account to it.
func TestGoogleAddClientID_SavesPersonalBundle(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	policytest.Set(t, nil)
	c, out := ownGoogleAddCmd(t, "own-secret")

	require.NoError(t, runGoogleAdd(c, nil), out.String())

	assert.Equal(t, calendar.GoogleOAuthConfig{ClientID: ownClientID, ClientSecret: "own-secret"}, h.loginCfg)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	a := accounts[0]
	assert.Equal(t, "bob-example-org", a.CompanySlug)
	assert.Equal(t, ownClientID, a.ClientID)
	assert.Equal(t, "ok", a.Status)

	ws := h.cfg.WorkspaceDir()
	e, ok, err := company.NewStore(ws).Get(a.CompanySlug, "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, companybundle.Bundle{V: 1, Company: "bob@example.org", Personal: true,
		Google: &companybundle.Google{ClientID: ownClientID, ClientSecret: "own-secret"}}, e.Bundle)
	got, src, err := resolveGoogleOAuthConfigForAccount(ws, a)
	require.NoError(t, err)
	assert.Equal(t, calendar.GoogleOAuthConfig{ClientID: ownClientID, ClientSecret: "own-secret"}, got)
	assert.Equal(t, clientSourceCompany, src)

	entries, _, err := company.NewStore(ws).LoadAll("")
	require.NoError(t, err)
	assert.True(t, company.IsOwnProject(a, entries, true))
}

// The same Gmail address on the shared client moves onto the own project:
// one row (the shared-Google banner's "Move Gmail to your own project").
func TestGoogleAddClientID_MovesSameAddressRow(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	policytest.Set(t, nil)
	ws := h.cfg.WorkspaceDir()
	id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "Bob@example.org", GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, calendar.NewAccountTokenStore(ws, id).Save(&calendar.OAuthToken{RefreshToken: "shared-refresh"}))
	c, out := ownGoogleAddCmd(t, "own-secret")

	require.NoError(t, runGoogleAdd(c, nil), out.String())

	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	assert.Equal(t, id, accounts[0].ID)
	assert.Equal(t, "bob-example-org", accounts[0].CompanySlug)
	assert.Contains(t, out.String(), "now signs in through bob-example-org")
}

// TestGoogleAddClientID_PolicyRefuses: AllowOwnGoogleProject = false refuses
// the own project before the secret is read: no browser, no row, no file.
func TestGoogleAddClientID_PolicyRefuses(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
	c, _ := ownGoogleAddCmd(t, "own-secret")

	err := runGoogleAdd(c, nil)

	require.ErrorIs(t, err, policy.ErrNotAllowed)
	assert.Contains(t, err.Error(), "AllowOwnGoogleProject")
	assert.Zero(t, h.loginCalls)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
	_, statErr := os.Stat(filepath.Join(h.cfg.WorkspaceDir(), "company"))
	assert.True(t, os.IsNotExist(statErr), "no company directory written")
}

// The company path is not an own project: AllowOwnGoogleProject = false
// leaves `google add --company` alone.
func TestGoogleAddCompany_NotStoppedByOwnProjectPolicy(t *testing.T) {
	h := newGoogleAddHarness(t, "a@example.com")
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	c, out := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "acme", "gmail": "true"})
	require.NoError(t, runGoogleAdd(c, nil), out.String())
}

// A malformed client fails before the browser and stores nothing; a
// cancelled sign-in stores no personal bundle either.
func TestGoogleAddClientID_NothingStoredOnFailure(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	policytest.Set(t, nil)
	c, _ := ownGoogleAddCmd(t, "bad secret with spaces")
	require.Error(t, runGoogleAdd(c, nil))
	assert.Zero(t, h.loginCalls)

	googleOAuthLogin = func(context.Context, calendar.GoogleOAuthConfig, io.Writer, ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		return nil, context.Canceled
	}
	c, _ = ownGoogleAddCmd(t, "own-secret")
	require.Error(t, runGoogleAdd(c, nil))

	entries, _, err := company.NewStore(h.cfg.WorkspaceDir()).LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries)
	accounts, err := h.database.ListGoogleAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts)
}

// ownProjectFixture is one account of each kind: on a personal bundle, on
// an untied legacy credentials file, on a company bundle, a bridged corp
// account (company bundle + its credentials file), and on the shared client.
type ownProjectFixture struct {
	cfg                                        *config.Config
	database                                   *db.DB
	personal, legacy, company, bridged, shared int64
}

func newOwnProjectFixture(t *testing.T) ownProjectFixture {
	t.Helper()
	cfg := wiringTestConfig(t)
	cfg.Gmail.Enabled, cfg.Calendar.Enabled = true, true
	database := db.OpenTestDB(t)
	ws := cfg.WorkspaceDir()
	saveCompany(t, ws, companySample("Acme"))
	slug, err := company.SavePersonal(company.NewStore(ws), "", "bob@example.org",
		companybundle.Google{ClientID: ownClientID, ClientSecret: "own-secret"})
	require.NoError(t, err)
	f := ownProjectFixture{cfg: cfg, database: database}
	add := func(label, slug string, creds bool) int64 {
		id, err := database.CreateGoogleAccount(db.GoogleAccount{Label: label, CompanySlug: slug, CalendarEnabled: true, GmailEnabled: true})
		require.NoError(t, err)
		require.NoError(t, calendar.NewAccountTokenStore(ws, id).Save(&calendar.OAuthToken{RefreshToken: "rt-" + label}))
		if creds {
			c := &calendar.Credentials{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"}
			if slug == "" {
				c = &calendar.Credentials{ClientID: "9999-legacy.apps.googleusercontent.com", ClientSecret: "legacy"}
			} else if slug != "acme" {
				c = &calendar.Credentials{ClientID: ownClientID, ClientSecret: "own-secret"}
			}
			require.NoError(t, calendar.NewCredentialStore(ws, id).Save(c))
		}
		return id
	}
	f.personal = add("personal", slug, true)
	f.legacy = add("legacy", "", true)
	f.company = add("company", "acme", false)
	f.bridged = add("bridged", "acme", true)
	f.shared = add("shared", "", false)
	return f
}

// TestOwnProjectPolicy_StopsPersonalKeepsCompanyAndBridged (POLICY-03,
// D24): AllowOwnGoogleProject = false stops the personal and the untied
// legacy account — not wired, no token refresh, stopped per cycle, purge
// leases held via the daemon verdict — with rows, tokens and credentials
// kept; company, bridged corp and shared-client accounts keep syncing.
// Dropping the policy lets them all through again.
func TestOwnProjectPolicy_StopsPersonalKeepsCompanyAndBridged(t *testing.T) {
	f := newOwnProjectFixture(t)
	ws := f.cfg.WorkspaceDir()
	calSeen, gmSeen := stubGoogleClients(t, nil, nil)
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})

	cal, gm := wireGoogleSyncers(context.Background(), f.cfg, f.database, quietTestLogger())

	wired := func() []int64 {
		var ids []int64
		for _, s := range gm {
			ids = append(ids, s.AccountID())
		}
		return ids
	}
	assert.ElementsMatch(t, []int64{f.company, f.bridged, f.shared}, wired())
	assert.Len(t, cal, 3)
	assert.NotContains(t, *gmSeen, "rt-personal", "no token refresh for a stopped account")
	assert.NotContains(t, *calSeen, "rt-legacy")

	all, err := f.database.ListGoogleAccounts()
	require.NoError(t, err)
	unwired := googleAccountsStopped(policy.Current(), ws, all)
	assert.Equal(t, map[int64]bool{f.personal: true, f.legacy: true}, unwired, "the set wiring leaves out")
	allowed := googleAccountSyncAllowed(ws, f.database, nil)
	for id, want := range map[int64]bool{f.personal: false, f.legacy: false, f.company: true, f.bridged: true, f.shared: true} {
		assert.Equal(t, want, allowed("google", id), "account %d", id)
	}
	assert.True(t, allowed("jira", f.personal), "other sources are not this key's")

	for _, id := range []int64{f.personal, f.legacy} {
		a, err := f.database.GetGoogleAccount(id)
		require.NoError(t, err)
		assert.Equal(t, "ok", a.Status, "the row is left as it is")
		assert.Empty(t, a.Error)
		assert.True(t, calendar.NewAccountTokenStore(ws, id).Exists(), "token kept")
		assert.True(t, calendar.NewCredentialStore(ws, id).Exists(), "credentials kept")
	}

	policytest.Set(t, nil)
	for _, id := range []int64{f.personal, f.legacy, f.company, f.bridged, f.shared} {
		assert.True(t, allowed("google", id), "a wired account syncs again at the next cycle")
	}
	// Unwired at start, they cannot sync until the next start: still stopped,
	// so their purge leases stay held instead of running out unsynced.
	sinceStart := googleAccountSyncAllowed(ws, f.database, unwired)
	assert.False(t, sinceStart("google", f.personal))
	assert.False(t, sinceStart("google", f.legacy))
	assert.True(t, sinceStart("google", f.company))
	_, gm = wireGoogleSyncers(context.Background(), f.cfg, f.database, quietTestLogger())
	assert.Len(t, gm, 5, "allowed again: every account wires at the next daemon start")
}

// A re-login (`google login --account`) of a stopped own project is refused
// before the browser, and `gmail sync` / `calendar sync` skip it with the
// policy's reason; a company account still signs in.
func TestOwnProjectPolicy_RefusesReloginAndCLISync(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	ws := h.cfg.WorkspaceDir()
	slug, err := company.SavePersonal(company.NewStore(ws), "", "bob@example.org",
		companybundle.Google{ClientID: ownClientID, ClientSecret: "own-secret"})
	require.NoError(t, err)
	own, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "bob@example.org", CompanySlug: slug, CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	require.NoError(t, calendar.NewAccountTokenStore(ws, own).Save(&calendar.OAuthToken{RefreshToken: "rt"}))
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})

	c, out := cmdWithFlags(t, googleLoginCmd, map[string]string{"account": strconv.FormatInt(own, 10)})
	require.ErrorIs(t, runGoogleLogin(c, nil), policy.ErrNotAllowed, out.String())
	assert.Zero(t, h.loginCalls)

	c, out = cmdWithFlags(t, gmailSyncCmd, nil)
	require.NoError(t, runGmailSync(c, nil))
	assert.Contains(t, out.String(), "AllowOwnGoogleProject")
	assert.Contains(t, out.String(), "No connected Gmail accounts to sync")
	c, out = cmdWithFlags(t, calendarSyncCmd, nil)
	require.NoError(t, runCalendarSync(c, nil))
	assert.Contains(t, out.String(), "AllowOwnGoogleProject")

	saveCompany(t, ws, companySample("Acme"))
	work, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: "acme", GmailEnabled: true})
	require.NoError(t, err)
	c, out = cmdWithFlags(t, googleLoginCmd, map[string]string{"account": strconv.FormatInt(work, 10)})
	require.NoError(t, runGoogleLogin(c, nil), out.String())
	assert.Equal(t, 1, h.loginCalls)
}

// A company directory that cannot be read stops a tied account while the
// policy forbids own projects (fail closed); with the policy off nothing is
// read and nothing stops.
func TestOwnProjectPolicy_UnreadableStoreFailsClosed(t *testing.T) {
	f := newOwnProjectFixture(t)
	ws := f.cfg.WorkspaceDir()
	dir := company.NewStore(ws).Dir
	require.NoError(t, os.Chmod(dir, 0o000))
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	a, err := f.database.GetGoogleAccount(f.company)
	require.NoError(t, err)

	stopped, err := googleOwnProjectStopped(policy.Normalize(nil), ws, a)
	require.NoError(t, err)
	assert.False(t, stopped)
	stopped, err = googleOwnProjectStopped(policy.Normalize(map[string]any{"AllowOwnGoogleProject": false}), ws, a)
	require.Error(t, err, "the real problem, not the policy's text")
	assert.True(t, stopped)

	// The daemon wires it not, and shows the real error on the row.
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
	stubGoogleClients(t, nil, nil)
	_, gm := wireGoogleSyncers(context.Background(), f.cfg, f.database, quietTestLogger())
	for _, s := range gm {
		assert.NotEqual(t, f.company, s.AccountID())
	}
	a, err = f.database.GetGoogleAccount(f.company)
	require.NoError(t, err)
	assert.Equal(t, "error", a.Status)
	assert.Contains(t, a.Error, "reading companies")
}

// A tied account whose company is not stored (a deleted or damaged file)
// counts as stopped while own projects are forbidden: its client could
// otherwise come from the credentials file written at sign-in.
func TestOwnProjectPolicy_UnknownCompanyFailsClosed(t *testing.T) {
	f := newOwnProjectFixture(t)
	ws := f.cfg.WorkspaceDir()
	id, err := f.database.CreateGoogleAccount(db.GoogleAccount{Label: "orphan", CompanySlug: "gone", GmailEnabled: true})
	require.NoError(t, err)
	a, err := f.database.GetGoogleAccount(id)
	require.NoError(t, err)

	stopped, err := googleOwnProjectStopped(policy.Normalize(map[string]any{"AllowOwnGoogleProject": false}), ws, a)
	require.Error(t, err)
	assert.True(t, stopped)
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
	assert.False(t, googleAccountSyncAllowed(ws, f.database, nil)("google", id))
}

// The daemon verdict: a row it cannot read is stopped for the pass (a
// transient error never lets a stopped account's inactivity purge in); a
// row that is gone is allowed (its removed-account lease runs).
func TestOwnProjectPolicy_UnreadableRowStopsGoneRowAllowed(t *testing.T) {
	f := newOwnProjectFixture(t)
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
	allowed := googleAccountSyncAllowed(f.cfg.WorkspaceDir(), f.database, nil)
	assert.True(t, allowed("google", 9999), "gone")
	require.NoError(t, f.database.Close())
	assert.False(t, allowed("google", f.company), "unreadable")
}

// `google add --company <personal slug>` is an own project too: refused
// while own projects are forbidden, before the browser.
func TestGoogleAddCompany_PersonalSlugRefusedByPolicy(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	slug, err := company.SavePersonal(company.NewStore(h.cfg.WorkspaceDir()), "", "bob@example.org",
		companybundle.Google{ClientID: ownClientID, ClientSecret: "own-secret"})
	require.NoError(t, err)
	policytest.Set(t, map[string]any{"AllowOwnGoogleProject": false})
	c, out := cmdWithFlags(t, googleAddCmd, map[string]string{"company": slug, "gmail": "true"})

	require.ErrorIs(t, runGoogleAdd(c, nil), policy.ErrNotAllowed, out.String())
	assert.Zero(t, h.loginCalls)
}

// A re-tie the grant does not cover is refused before the personal bundle
// is stored: nothing is left behind.
func TestGoogleAddClientID_RefusedRetieStoresNoBundle(t *testing.T) {
	h := newGoogleAddHarness(t, "bob@example.org")
	policytest.Set(t, nil)
	ws := h.cfg.WorkspaceDir()
	id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "bob@example.org", GmailEnabled: true, CalendarEnabled: true})
	require.NoError(t, err)
	require.NoError(t, calendar.NewAccountTokenStore(ws, id).Save(&calendar.OAuthToken{RefreshToken: "shared-refresh"}))
	c, out := cmdWithFlags(t, googleAddCmd, map[string]string{"client-id": ownClientID, "client-secret-stdin": "true", "gmail": "true"})
	c.SetIn(strings.NewReader("own-secret\n"))

	require.Error(t, runGoogleAdd(c, nil), out.String())

	entries, _, err := company.NewStore(ws).LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries)
	a, err := h.database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.Empty(t, a.CompanySlug)
}
