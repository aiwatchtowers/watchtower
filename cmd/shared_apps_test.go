package cmd

import (
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/jira"
	"watchtower/internal/oauthclient"
)

// #1887 Task 19 (T10, D4, D11, D15): our shared Google client keeps the
// Calendar scopes only, and the account listings carry the retirement
// banners' flags.

const sharedGoogleID = "9999-shared.apps.googleusercontent.com"

// bakeSharedGoogle makes sharedGoogleID the build's baked Google client and
// clears the development env.
func bakeSharedGoogle(t *testing.T) {
	t.Helper()
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", "")
	t.Setenv("WATCHTOWER_GOOGLE_CLIENT_SECRET", "")
	prevID, prevSecret := calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret
	calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret = sharedGoogleID, "shared-secret"
	t.Cleanup(func() { calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret = prevID, prevSecret })
}

// googleSharedHarness is a workspace with the shared Google client baked and
// a scripted consent that records the scopes each sign-in asked for.
type googleSharedHarness struct {
	database *db.DB
	cfg      *config.Config
	scopes   [][]string
}

func newGoogleSharedHarness(t *testing.T) *googleSharedHarness {
	t.Helper()
	h := &googleSharedHarness{database: jiraCmdFixture(t)}
	var err error
	h.cfg, err = config.Load(flagConfig)
	require.NoError(t, err)
	bakeSharedGoogle(t)
	origLogin, origEmail := googleOAuthLogin, googleGrantEmail
	t.Cleanup(func() { googleOAuthLogin, googleGrantEmail = origLogin, origEmail })
	googleOAuthLogin = func(_ context.Context, _ calendar.GoogleOAuthConfig, _ io.Writer, opts ...calendar.LoginOptions) (*calendar.OAuthToken, error) {
		h.scopes = append(h.scopes, opts[0].Scopes)
		return &calendar.OAuthToken{AccessToken: "a", RefreshToken: "new-refresh", Scope: strings.Join(opts[0].Scopes, " ")}, nil
	}
	googleGrantEmail = func(context.Context, calendar.GoogleOAuthConfig, string) (string, error) { return "a@example.com", nil }
	return h
}

// TestGoogleShared_CalendarOnly: a sign-in through our shared client asks
// for Calendar only.
func TestGoogleShared_CalendarOnly(t *testing.T) {
	h := newGoogleSharedHarness(t)
	cmd, out := cmdWithFlags(t, googleAddCmd, map[string]string{"calendar": "true"})

	require.NoError(t, runGoogleAdd(cmd, nil), out.String())

	require.Len(t, h.scopes, 1)
	assert.Equal(t, []string{calendar.ScopeCalendarReadonly}, h.scopes[0])
	assert.NotContains(t, h.scopes[0], gmail.ScopeGmailReadonly)
}

// TestGoogleShared_ExistingGmailKeepsSyncing: a Gmail row that already holds
// a grant on the shared client is still wired by the daemon (D11: existing
// tokens live on until Google refuses them).
func TestGoogleShared_ExistingGmailKeepsSyncing(t *testing.T) {
	wcfg := wiringTestConfig(t)
	bakeSharedGoogle(t)
	wcfg.Calendar.Enabled, wcfg.Gmail.Enabled = true, true
	wdb := db.OpenTestDB(t)
	_, gmSeen := stubGoogleClients(t, nil, nil)
	id := newGoogleAccount(t, wdb, wcfg, "shared gmail", "shared-refresh")
	_, gm := wireGoogleSyncers(context.Background(), wcfg, wdb, quietTestLogger())
	assert.Len(t, gm, 1)
	assert.Equal(t, []string{"shared-refresh"}, *gmSeen)
	status, _ := googleStatus(t, wdb, id)
	assert.Equal(t, "ok", status)
}

// TestGoogleShared_GmailRefusedWithHint: Gmail through our shared client —
// baked, or the baked id on any other layer — is refused before any
// browser, with the way out, and leaves no row; a re-login that would carry
// the row's Gmail is refused and keeps the row's grant. A company's client,
// an own project, a development env client of another id and a flavoured
// build's baked client still get Gmail.
func TestGoogleShared_GmailRefusedWithHint(t *testing.T) {
	t.Run("add", func(t *testing.T) {
		h := newGoogleSharedHarness(t)
		cmd, out := cmdWithFlags(t, googleAddCmd, map[string]string{"gmail": "true", "calendar": "true"})

		err := runGoogleAdd(cmd, nil)

		require.ErrorIs(t, err, errGmailNeedsOwnProject, out.String())
		assert.Contains(t, err.Error(), "your company's or your own Google project")
		assert.Contains(t, err.Error(), "--client-id")
		assert.Empty(t, h.scopes, "no browser opens")
		accounts, lerr := h.database.ListGoogleAccounts()
		require.NoError(t, lerr)
		assert.Empty(t, accounts, "the refused add leaves no row")
	})

	t.Run("env naming the baked id", func(t *testing.T) {
		h := newGoogleSharedHarness(t)
		t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", sharedGoogleID)
		cmd, out := cmdWithFlags(t, googleAddCmd, map[string]string{"gmail": "true"})

		require.ErrorIs(t, runGoogleAdd(cmd, nil), errGmailNeedsOwnProject, out.String())
		assert.Empty(t, h.scopes)
	})

	t.Run("gmail login on a fresh install", func(t *testing.T) {
		h := newGoogleSharedHarness(t)
		cmd, out := cmdWithFlags(t, gmailLoginCmd, map[string]string{})

		require.ErrorIs(t, runGmailLogin(cmd, nil), errGmailNeedsOwnProject, out.String())

		assert.Empty(t, h.scopes)
		accounts, err := h.database.ListGoogleAccounts()
		require.NoError(t, err)
		assert.Empty(t, accounts, "the row the login created is rolled back")
	})

	t.Run("re-login of a shared Gmail row", func(t *testing.T) {
		h := newGoogleSharedHarness(t)
		ws := h.cfg.WorkspaceDir()
		id, err := h.database.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CalendarEnabled: true, GmailEnabled: true})
		require.NoError(t, err)
		require.NoError(t, calendar.NewAccountTokenStore(ws, id).Save(&calendar.OAuthToken{RefreshToken: "shared-refresh"}))
		cmd, out := cmdWithFlags(t, calendarLoginCmd, map[string]string{})

		// `calendar login` carries the row's Gmail (wantGmail from the row).
		err = runCalendarLogin(cmd, nil)
		require.ErrorIs(t, err, errGmailNeedsOwnProject, out.String())
		assert.Contains(t, err.Error(), "google account")

		assert.Empty(t, h.scopes)
		tok, err := calendar.NewAccountTokenStore(ws, id).Load()
		require.NoError(t, err)
		assert.Equal(t, "shared-refresh", tok.RefreshToken, "the row's grant is untouched")
		a, err := h.database.GetGoogleAccount(id)
		require.NoError(t, err)
		assert.True(t, a.GmailEnabled)
	})

	t.Run("the baked id from a bundle", func(t *testing.T) {
		h := newGoogleSharedHarness(t)
		b := companySample("Acme")
		b.Google.ClientID = sharedGoogleID
		saveCompany(t, h.cfg.WorkspaceDir(), b)
		cmd, out := cmdWithFlags(t, googleAddCmd, map[string]string{"company": "acme", "gmail": "true"})

		require.ErrorIs(t, runGoogleAdd(cmd, nil), errGmailNeedsOwnProject, out.String())
		assert.Empty(t, h.scopes)
	})

	t.Run("other clients keep Gmail", func(t *testing.T) {
		bakeSharedGoogle(t)
		want := []string{calendar.ScopeCalendarReadonly, gmail.ScopeGmailReadonly}
		for _, id := range []string{"1234-abcd.apps.googleusercontent.com", "own-project-id", "developer-project-id"} {
			got, err := googleScopesFor(id, true, true)
			require.NoError(t, err, id)
			assert.Equal(t, want, got, id)
		}
		// A flavoured build's baked client is its company's app.
		prev := BuildFlavor
		BuildFlavor = "corp"
		t.Cleanup(func() { BuildFlavor = prev })
		_, err := googleScopesFor(sharedGoogleID, false, true)
		require.NoError(t, err)
		BuildFlavor = prev
		// No baked client (a development build): nothing is shared.
		calendar.DefaultGoogleClientID = ""
		got, err := googleScopesFor("", false, true)
		require.NoError(t, err)
		assert.Equal(t, []string{gmail.ScopeGmailReadonly}, got)
	})
}

// TestConnectionsJSON_SharedFlags: `google accounts --json` flags the Gmail
// accounts on our shared Google client, `jira accounts --json` the OAuth
// sites on our shared Atlassian app (with or without a client left to
// refresh through) and carries the cutoff day; every row carries its
// company.
func TestConnectionsJSON_SharedFlags(t *testing.T) {
	t.Run("google", func(t *testing.T) {
		database := jiraCmdFixture(t)
		cfg, err := config.Load(flagConfig)
		require.NoError(t, err)
		bakeSharedGoogle(t)
		ws := cfg.WorkspaceDir()
		saveCompany(t, ws, companySample("Acme"))

		create := func(a db.GoogleAccount) int64 {
			id, err := database.CreateGoogleAccount(a)
			require.NoError(t, err)
			return id
		}
		sharedGmail := create(db.GoogleAccount{Label: "shared gmail", GmailEnabled: true, CalendarEnabled: true})
		sharedCalendar := create(db.GoogleAccount{Label: "shared calendar", CalendarEnabled: true})
		own := create(db.GoogleAccount{Label: "own", GmailEnabled: true})
		require.NoError(t, calendar.NewCredentialStore(ws, own).Save(&calendar.Credentials{ClientID: "own-id", ClientSecret: "s"}))
		tied := create(db.GoogleAccount{Label: "tied", GmailEnabled: true, CompanySlug: "acme"})
		removed := create(db.GoogleAccount{Label: "removed", GmailEnabled: true})
		_, err = database.Exec(`UPDATE google_accounts SET status = 'removed' WHERE id = ?`, removed)
		require.NoError(t, err)

		cmd, out := cmdWithFlags(t, googleAccountsCmd, map[string]string{"json": "true"})
		require.NoError(t, runGoogleAccounts(cmd, nil))
		var rows []googleAccountJSON
		require.NoError(t, json.Unmarshal(out.Bytes(), &rows), out.String())
		got := map[int64]googleAccountJSON{}
		for _, r := range rows {
			got[r.ID] = r
		}
		require.Len(t, got, 5)
		assert.True(t, got[sharedGmail].SharedGmail)
		assert.False(t, got[sharedCalendar].SharedGmail, "Calendar stays on the shared client")
		assert.False(t, got[own].SharedGmail)
		assert.False(t, got[tied].SharedGmail)
		assert.Equal(t, "acme", got[tied].CompanySlug)
		assert.False(t, got[removed].SharedGmail)
		assert.Equal(t, "shared gmail", got[sharedGmail].Label)
		assert.True(t, got[sharedGmail].GmailEnabled)

		// The env naming the baked id is the shared client too; a flavoured
		// build's baked client is its company's.
		t.Setenv("WATCHTOWER_GOOGLE_CLIENT_ID", sharedGoogleID)
		a, err := database.GetGoogleAccount(sharedGmail)
		require.NoError(t, err)
		assert.True(t, googleSharedGmail(ws, a))
		prev := BuildFlavor
		BuildFlavor = "corp"
		t.Cleanup(func() { BuildFlavor = prev })
		assert.False(t, googleSharedGmail(ws, a))
	})

	t.Run("jira", func(t *testing.T) {
		database := jiraCmdFixture(t)
		cfg, err := config.Load(flagConfig)
		require.NoError(t, err)
		ws := cfg.WorkspaceDir()
		saveCompany(t, ws, companySample("Acme"))
		t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "")
		prevID, prevCutoff := jira.DefaultJiraClientID, jira.SharedAppCutoff
		jira.DefaultJiraClientID, jira.SharedAppCutoff = "", "2027-01-15"
		t.Cleanup(func() { jira.DefaultJiraClientID, jira.SharedAppCutoff = prevID, prevCutoff })

		create := func(a db.JiraAccount) int64 {
			id, err := database.CreateJiraAccount(a)
			require.NoError(t, err)
			return id
		}
		// Not baked (D4): an untied OAuth site has no client left, still the
		// shared app's.
		unbaked := create(db.JiraAccount{CloudID: "c1", SiteURL: "https://one.example.com"})
		withFile := create(db.JiraAccount{CloudID: "c2"})
		require.NoError(t, oauthclient.NewStore(ws, jiraClientVendor, withFile).Save(oauthclient.Client{ClientID: "own-app", ClientSecret: "s"}))
		tied := create(db.JiraAccount{CloudID: "c3", CompanySlug: "acme"})
		token := create(db.JiraAccount{CloudID: "c4", AuthKind: "api_token"})
		removed := create(db.JiraAccount{CloudID: "c5"})
		_, err = database.Exec(`UPDATE jira_accounts SET status = 'removed' WHERE id = ?`, removed)
		require.NoError(t, err)

		read := func() jiraAccountsJSON {
			t.Helper()
			cmd, out := cmdWithFlags(t, jiraAccountsCmd, map[string]string{"json": "true"})
			require.NoError(t, runJiraAccounts(cmd, nil))
			var doc jiraAccountsJSON
			require.NoError(t, json.Unmarshal(out.Bytes(), &doc), out.String())
			return doc
		}
		doc := read()
		assert.Equal(t, "2027-01-15", doc.SharedAppCutoff)
		got := map[int64]jiraAccountJSON{}
		for _, r := range doc.Accounts {
			got[r.ID] = r
		}
		require.Len(t, got, 5)
		assert.True(t, got[unbaked].SharedAtlassian)
		assert.Equal(t, "oauth", got[unbaked].AuthKind)
		assert.Equal(t, "https://one.example.com", got[unbaked].SiteURL)
		assert.False(t, got[withFile].SharedAtlassian)
		assert.False(t, got[tied].SharedAtlassian)
		assert.Equal(t, "acme", got[tied].CompanySlug)
		assert.False(t, got[token].SharedAtlassian)
		assert.Equal(t, "api_token", got[token].AuthKind)
		assert.False(t, got[removed].SharedAtlassian)

		// A build that still bakes the shared app (or a development env):
		// the same site is on it.
		jira.DefaultJiraClientID = "shared-jira"
		for _, r := range read().Accounts {
			if r.ID == unbaked {
				assert.True(t, r.SharedAtlassian)
			}
		}
		// A flavoured build's baked client is its company's app.
		prevFlavor := BuildFlavor
		BuildFlavor = "corp"
		t.Cleanup(func() { BuildFlavor = prevFlavor })
		for _, r := range read().Accounts {
			assert.False(t, r.SharedAtlassian, r.ID)
		}
	})
}
