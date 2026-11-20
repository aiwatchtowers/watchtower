package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/calendar"
	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"
	"watchtower/internal/jira"
	"watchtower/internal/linear"
	"watchtower/internal/media"
	"watchtower/internal/oauthclient"
)

// #1887 Task 28: the corp build bridges its accounts onto a company bundle
// built from its own baked clients, so the public build (no baked corp
// clients) refreshes every account through the same client as before.

// Placeholder corp clients (never real ids).
const (
	corpSlackID     = "1111.2222"
	corpGoogleID    = "1111-corp.apps.googleusercontent.com"
	corpGoogleSec   = "corp-google-secret"
	corpJiraID      = "corpJiraClient01"
	corpJiraSec     = "corp-jira-secret"
	corpLinearID    = "corplinear01"
	corpMicrosoftID = "00000000-0000-0000-0000-0000000000c0"
	corpCompany     = "Corp Inc"
	corpSlug        = "corp-inc"
)

// setBakedClients sets the build's baked clients (all of them; "" clears)
// and the build deny list, restored after the test. No env layer is set.
func setBakedClients(t *testing.T, slack, googleID, googleSecret, jiraID, jiraSecret, linearID, microsoftID, deny string) {
	t.Helper()
	for _, env := range []string{"WATCHTOWER_OAUTH_CLIENT_ID", "WATCHTOWER_GOOGLE_CLIENT_ID", "WATCHTOWER_GOOGLE_CLIENT_SECRET",
		"WATCHTOWER_JIRA_CLIENT_ID", "WATCHTOWER_JIRA_CLIENT_SECRET", "WATCHTOWER_LINEAR_CLIENT_ID", "WATCHTOWER_MICROSOFT_CLIENT_ID"} {
		t.Setenv(env, "")
	}
	prev := []string{auth.DefaultClientID, calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret,
		jira.DefaultJiraClientID, jira.DefaultJiraClientSecret, linear.DefaultLinearClientID, imap.DefaultMicrosoftClientID, media.BuildDenyHosts}
	t.Cleanup(func() {
		auth.DefaultClientID, calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret = prev[0], prev[1], prev[2]
		jira.DefaultJiraClientID, jira.DefaultJiraClientSecret, linear.DefaultLinearClientID = prev[3], prev[4], prev[5]
		imap.DefaultMicrosoftClientID, media.BuildDenyHosts = prev[6], prev[7]
	})
	auth.DefaultClientID, calendar.DefaultGoogleClientID, calendar.DefaultGoogleClientSecret = slack, googleID, googleSecret
	jira.DefaultJiraClientID, jira.DefaultJiraClientSecret, linear.DefaultLinearClientID = jiraID, jiraSecret, linearID
	imap.DefaultMicrosoftClientID, media.BuildDenyHosts = microsoftID, deny
}

func setCorpBaked(t *testing.T) {
	setBakedClients(t, corpSlackID, corpGoogleID, corpGoogleSec, corpJiraID, corpJiraSec, corpLinearID, corpMicrosoftID,
		"Intranet.Example.com, not a host,,wiki.example.com,Trailing.Example.org.")
}

// setPublicBaked is the public build after the corp flavor: other shared
// clients, no corp ones.
func setPublicBaked(t *testing.T) {
	setBakedClients(t, "9999.9999", "9999-public.apps.googleusercontent.com", "public-google-secret",
		"publicJira01", "public-jira-secret", "publiclinear01", "00000000-0000-0000-0000-0000000000f0", "")
}

// corpWorkspace is a corp install: one account per source on the baked
// clients, plus accounts the bridge must leave alone — another Slack team,
// an Outlook mailbox of another domain, an own Google project, an IMAP
// mailbox, an API-token Jira account and a removed Linear account.
type corpWorkspace struct {
	cfg      *config.Config
	database *db.DB
	ws       string
	ids      map[string]int64
}

func newCorpWorkspace(t *testing.T) *corpWorkspace {
	t.Helper()
	database := jiraCmdFixture(t)
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	prevForced := companyForcedBundle
	companyForcedBundle = func() string { return "" }
	t.Cleanup(func() { companyForcedBundle = prevForced })
	setCorpBaked(t)

	c := &corpWorkspace{cfg: cfg, database: database, ws: cfg.WorkspaceDir(), ids: map[string]int64{}}
	add := func(name string, id int64, err error) {
		t.Helper()
		require.NoError(t, err, name)
		c.ids[name] = id
	}
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T0CORP", TeamName: "Corp"})
	add("slack", id, err)
	id, err = database.CreateSlackAccount(db.SlackAccount{TeamID: "T0OTHER", TeamName: "Other"})
	add("slack_other_team", id, err)
	id, err = database.CreateGoogleAccount(db.GoogleAccount{Email: "a@corp.example.com"})
	add("google", id, err)
	id, err = database.CreateGoogleAccount(db.GoogleAccount{Email: "me@example.com"})
	add("google_own", id, err)
	require.NoError(t, calendar.NewCredentialStore(c.ws, id).Save(&calendar.Credentials{ClientID: "4444-own.apps.googleusercontent.com", ClientSecret: "own"}))
	id, err = database.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://corp.atlassian.net"})
	add("jira", id, err)
	id, err = database.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://corp.atlassian.net", AuthKind: "api_token"})
	add("jira_api_token", id, err)
	id, err = database.CreateLinearAccount("Corp")
	add("linear", id, err)
	id, err = database.CreateLinearAccount("Gone")
	add("linear_removed", id, err)
	_, err = database.Exec(`UPDATE linear_accounts SET status = 'removed' WHERE id = ?`, id)
	require.NoError(t, err)
	id, err = database.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "a@corp.example.com", Security: "ssl"})
	add("outlook", id, err)
	id, err = database.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "b@outlook.example.org", Security: "ssl"})
	add("outlook_personal", id, err)
	id, err = database.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "c@corp.example.com", Host: "imap.example.com", Security: "ssl"})
	add("imap", id, err)
	return c
}

// clients is the client id (and secret) each refresher of a tied-source
// account resolves now — the source a refresh asks.
func (c *corpWorkspace) clients(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	g, err := c.database.GetGoogleAccount(c.ids["google"])
	require.NoError(t, err)
	gcfg, _, err := resolveGoogleOAuthConfigForAccount(c.ws, g)
	require.NoError(t, err)
	out["google"] = gcfg.ClientID + "/" + gcfg.ClientSecret
	j, err := c.database.GetJiraAccount(c.ids["jira"])
	require.NoError(t, err)
	jcfg, err := jiraAccountOAuthSource(c.ws, func() (db.JiraAccount, error) { return j, nil })()
	require.NoError(t, err)
	out["jira"] = jcfg.ClientID + "/" + jcfg.ClientSecret
	lcfg, err := linearAccountOAuthSource(c.cfg, c.database, c.ids["linear"])()
	require.NoError(t, err)
	out["linear"] = lcfg.ClientID
	mcfg, err := resolveMicrosoftOAuthConfigForAccount(c.cfg, c.database, c.ids["outlook"])
	require.NoError(t, err)
	out["outlook"] = strings.ToLower(mcfg.ClientID) + "@" + mcfg.TenantID
	return out
}

func (c *corpWorkspace) bridge(t *testing.T) (companyBridgeResult, error) {
	t.Helper()
	return runCompanyBridge(c.ws, c.database, corpCompany, currentCorpBaked(), companyForcedBundle())
}

func (c *corpWorkspace) slugs(t *testing.T) map[string]string {
	t.Helper()
	refs, err := c.database.AccountsByCompany(corpSlug)
	require.NoError(t, err)
	out := map[string]string{}
	for _, r := range refs {
		for name, id := range c.ids {
			if id == r.ID && strings.HasPrefix(name, r.Source) {
				out[name] = corpSlug
			}
		}
	}
	return out
}

func TestBridge_TiesEveryBakedAccount(t *testing.T) {
	c := newCorpWorkspace(t)
	before := c.clients(t)
	assert.Equal(t, map[string]string{
		"google": corpGoogleID + "/" + corpGoogleSec, "jira": corpJiraID + "/" + corpJiraSec,
		"linear": corpLinearID, "outlook": corpMicrosoftID + "@",
	}, before)

	res, err := c.bridge(t)
	require.NoError(t, err)
	assert.Equal(t, bridgeMigrated, res.Result)
	assert.Equal(t, corpSlug, res.Slug)
	assert.Equal(t, "created", res.Stored)
	assert.ElementsMatch(t, []bridgeAccountJSON{
		{Source: "slack", ID: c.ids["slack"]}, {Source: "google", ID: c.ids["google"]}, {Source: "jira", ID: c.ids["jira"]},
		{Source: "linear", ID: c.ids["linear"]},
	}, res.Tied)
	assert.ElementsMatch(t, []bridgeSkipJSON{
		{Source: "slack", ID: c.ids["slack_other_team"], Reason: "other_team"},
		{Source: "outlook", ID: c.ids["outlook"], Reason: "no_tenant"},
		{Source: "outlook", ID: c.ids["outlook_personal"], Reason: "no_tenant"},
	}, res.Skipped)
	assert.Equal(t, map[string]string{
		"slack": corpSlug, "google": corpSlug, "jira": corpSlug, "linear": corpSlug,
	}, c.slugs(t), "only the accounts on the baked clients are tied")

	// The stored bundle is the one an admin would publish for these clients.
	e, ok, err := company.NewStore(c.ws).Get(corpSlug, "")
	require.NoError(t, err)
	require.True(t, ok)
	b := e.Bundle
	assert.Equal(t, corpCompany, b.Company)
	require.NotNil(t, b.Slack)
	assert.Equal(t, "T0CORP", b.Slack.TeamID)
	assert.Equal(t, corpSlackID, b.Slack.ClientID)
	require.NotNil(t, b.Atlassian)
	assert.Equal(t, "https://corp.atlassian.net", b.Atlassian.Site)
	assert.Nil(t, b.Microsoft, "no tenant is provably the company's: Outlook keeps the corp app through its record")
	assert.Equal(t, []string{"intranet.example.com", "wiki.example.com", "trailing.example.org"}, b.LinkDenyHosts,
		"the link policy's normal form first; a host a bundle refuses is dropped")
	info, err := os.Stat(filepath.Join(c.ws, "company", corpSlug+".json"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	// The marker is written, 0600.
	info, err = os.Stat(filepath.Join(c.ws, companyMigratedMarker))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	// Every tied account has its client record (Task 7a: a tie writes one),
	// holding the client its grant was issued to.
	rec, ok, err := oauthclient.NewStore(c.ws, jiraClientVendor, c.ids["jira"]).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, corpJiraID, rec.ClientID)
	rec, ok, err = oauthclient.NewStore(c.ws, outlookClientVendor, c.ids["outlook"]).Load()
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, oauthclient.Client{ClientID: corpMicrosoftID}, rec, "the grant's tenant was common: no tenant recorded")
	_, ok, err = oauthclient.NewStore(c.ws, linearClientVendor, c.ids["linear"]).Load()
	require.NoError(t, err)
	assert.True(t, ok)
	creds, err := calendar.NewCredentialStore(c.ws, c.ids["google"]).Load()
	require.NoError(t, err)
	assert.Equal(t, corpGoogleID, creds.ClientID)
	own, err := calendar.NewCredentialStore(c.ws, c.ids["google_own"]).Load()
	require.NoError(t, err)
	assert.Equal(t, "4444-own.apps.googleusercontent.com", own.ClientID, "an own project is not touched")

	// The public build (other shared clients, none of the corp's) refreshes
	// every tied account through the same client as before.
	setPublicBaked(t)
	assert.Equal(t, before, c.clients(t))
	// An untied account on a baked client keeps it too, through its record.
	personal, err := resolveMicrosoftOAuthConfigForAccount(c.cfg, c.database, c.ids["outlook_personal"])
	require.NoError(t, err)
	assert.Equal(t, imap.MicrosoftOAuthConfig{ClientID: corpMicrosoftID}, personal)
}

// TestBridge_IncludesLinearClient: the bundle carries the baked Linear
// client, and a Linear refresh after the bridge in a public-defaults process
// sends the corp client, not the shared one.
func TestBridge_IncludesLinearClient(t *testing.T) {
	c := newCorpWorkspace(t)
	_, err := c.bridge(t)
	require.NoError(t, err)
	e, _, err := company.NewStore(c.ws).Get(corpSlug, "")
	require.NoError(t, err)
	require.NotNil(t, e.Bundle.Linear)
	assert.Equal(t, corpLinearID, e.Bundle.Linear.ClientID)

	setPublicBaked(t)
	got, err := linearAccountOAuthSource(c.cfg, c.database, c.ids["linear"])()
	require.NoError(t, err)
	assert.Equal(t, corpLinearID, got.ClientID)
	assert.NotEqual(t, linear.DefaultLinearClientID, got.ClientID)
}

// TestBridge_Idempotent: a second run (every launch of the corp build runs
// it) changes nothing, and ties an account added since.
func TestBridge_Idempotent(t *testing.T) {
	c := newCorpWorkspace(t)
	first, err := c.bridge(t)
	require.NoError(t, err)
	read := func(name string) []byte {
		raw, err := os.ReadFile(filepath.Join(c.ws, name))
		require.NoError(t, err)
		return raw
	}
	files := []string{filepath.Join("company", corpSlug+".json"), companyMigratedMarker,
		"jira_client_1.json", "google_credentials_1.json"}
	snap := map[string][]byte{}
	for _, f := range files {
		snap[f] = read(f)
	}

	second, err := c.bridge(t)
	require.NoError(t, err)
	assert.Equal(t, "unchanged", second.Stored)
	assert.Equal(t, first.Tied, second.Tied)
	for _, f := range files {
		assert.Equal(t, snap[f], read(f), f)
	}

	// A Linear account added on the baked client after the bridge is tied
	// by the next launch's run.
	id, err := c.database.CreateLinearAccount("Later")
	require.NoError(t, err)
	third, err := c.bridge(t)
	require.NoError(t, err)
	assert.Contains(t, third.Tied, bridgeAccountJSON{Source: "linear", ID: id})
}

// TestBridge_FailureLeavesNoMarker: a failure at any step leaves the install
// as it was — no marker, no company file, no client records, no ties — and
// the next run succeeds.
func TestBridge_FailureLeavesNoMarker(t *testing.T) {
	for _, step := range []string{"store", "record", "tie", "marker"} {
		t.Run(step, func(t *testing.T) {
			c := newCorpWorkspace(t)
			prev := companyBridgeFault
			companyBridgeFault = func(s string) error {
				if s == step {
					return errors.New("injected failure")
				}
				return nil
			}
			t.Cleanup(func() { companyBridgeFault = prev })

			_, err := c.bridge(t)
			require.Error(t, err)
			for _, f := range []string{companyMigratedMarker, filepath.Join("company", corpSlug+".json"),
				"jira_client_1.json", "linear_client_1.json", "outlook_client_1.json", "google_credentials_1.json"} {
				assert.NoFileExists(t, filepath.Join(c.ws, f))
			}
			assert.Empty(t, c.slugs(t))

			companyBridgeFault = prev
			_, err = c.bridge(t)
			require.NoError(t, err)
			assert.FileExists(t, filepath.Join(c.ws, companyMigratedMarker))
		})
	}
}

// A stored bundle of the company with another Atlassian app (its own link,
// confirmed before the bridge ran) is never replaced: the bridge adds the
// vendors it lacks and leaves Jira accounts untied.
func TestBridge_KeepsAStoredCompanyApp(t *testing.T) {
	c := newCorpWorkspace(t)
	stored := companySample(corpCompany)
	stored.Slack, stored.Google, stored.Linear, stored.Microsoft = nil, nil, nil, nil
	saveCompany(t, c.ws, stored)
	path := filepath.Join(c.ws, "company", corpSlug+".json")
	original, err := os.ReadFile(path)
	require.NoError(t, err)

	// A failure after the merge puts the stored file back as it was.
	prev := companyBridgeFault
	companyBridgeFault = func(s string) error {
		if s == "tie" {
			return errors.New("injected failure")
		}
		return nil
	}
	_, err = c.bridge(t)
	companyBridgeFault = prev
	require.Error(t, err)
	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, original, after)

	res, err := c.bridge(t)
	require.NoError(t, err)
	assert.Equal(t, "updated", res.Stored)
	assert.Contains(t, res.Skipped, bridgeSkipJSON{Source: "jira", ID: c.ids["jira"], Reason: "company_app_differs"})
	e, _, err := company.NewStore(c.ws).Get(corpSlug, "")
	require.NoError(t, err)
	assert.Equal(t, stored.Atlassian.ClientID, e.Bundle.Atlassian.ClientID)
	require.NotNil(t, e.Bundle.Linear)
	assert.Equal(t, corpLinearID, e.Bundle.Linear.ClientID)
	_, tied := c.slugs(t)["jira"]
	assert.False(t, tied)

	// The untied Jira account still refreshes through the corp app on the
	// public build: its client record holds it.
	setPublicBaked(t)
	j, err := c.database.GetJiraAccount(c.ids["jira"])
	require.NoError(t, err)
	got, src, err := resolveJiraOAuthConfigForAccount(c.ws, j)
	require.NoError(t, err)
	assert.Equal(t, corpJiraID, got.ClientID)
	assert.Equal(t, clientSourceAccountFile, src)
}

// A stored bundle with the baked Jira client id but another secret does not
// get the account: tying it would refresh with that secret.
func TestBridge_SameIDOtherSecretIsNotTied(t *testing.T) {
	c := newCorpWorkspace(t)
	stored := companybundle.Bundle{V: 1, Company: corpCompany, Atlassian: &companybundle.Atlassian{
		ClientID: corpJiraID, ClientSecret: "rotated-secret", Site: "https://corp.atlassian.net"}}
	saveCompany(t, c.ws, stored)
	res, err := c.bridge(t)
	require.NoError(t, err)
	assert.Contains(t, res.Skipped, bridgeSkipJSON{Source: "jira", ID: c.ids["jira"], Reason: "company_app_differs"})
	setPublicBaked(t)
	j, err := c.database.GetJiraAccount(c.ids["jira"])
	require.NoError(t, err)
	got, _, err := resolveJiraOAuthConfigForAccount(c.ws, j)
	require.NoError(t, err)
	assert.Equal(t, corpJiraSec, got.ClientSecret, "the record keeps the secret the account works with")
}

// A build deny host the link policy refuses but a bundle cannot carry fails
// the run (no marker): the public build would otherwise fetch it.
func TestBridge_UnrepresentableDenyHostFails(t *testing.T) {
	c := newCorpWorkspace(t)
	media.BuildDenyHosts = "intranet.example.com,internal"
	_, err := c.bridge(t)
	require.Error(t, err)
	assert.Contains(t, err.Error(), `"internal"`)
	assert.NoFileExists(t, filepath.Join(c.ws, companyMigratedMarker))
	assert.NoFileExists(t, filepath.Join(c.ws, "company", corpSlug+".json"))
}

func TestBridge_PublicBuildNoop(t *testing.T) {
	setCorpBaked(t)
	for _, tc := range []struct{ flavor, name, reason string }{
		{"", corpCompany, "public_build"},
		{"dev", corpCompany, "public_build"},
		{"corp", "", "no_company_name"},
	} {
		res, ok := companyBridgeSkip(tc.flavor, tc.name, currentCorpBaked())
		assert.False(t, ok, tc.flavor)
		assert.Equal(t, companyBridgeResult{Result: bridgeNoop, Reason: tc.reason, Tied: []bridgeAccountJSON{}, Skipped: []bridgeSkipJSON{}}, res)
	}
	_, ok := companyBridgeSkip("corp", corpCompany, currentCorpBaked())
	assert.True(t, ok)
	setBakedClients(t, "", "", "", "", "", "", "", "")
	res, ok := companyBridgeSkip("corp", corpCompany, currentCorpBaked())
	assert.False(t, ok)
	assert.Equal(t, "no_baked_clients", res.Reason)

	// The command on the public build writes nothing, not even a workspace.
	setCorpBaked(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cmd, out := cmdWithFlags(t, companyBridgeCmd, map[string]string{"json": "true"})
	require.NoError(t, companyBridgeCmd.RunE(cmd, nil))
	assert.Contains(t, out.String(), `"result":"noop","reason":"public_build"`)
	entries, err := os.ReadDir(home)
	require.NoError(t, err)
	assert.Empty(t, entries)
}

// TestPublic_UntiedUnknownClientReloginNeeded: on the public build with no
// shared client, an account the bridge never tied resolves to no client, and
// the refresh marks it Re-login needed with unknown_client — never revoked.
func TestPublic_UntiedUnknownClientReloginNeeded(t *testing.T) {
	c := newCorpWorkspace(t)
	setBakedClients(t, "", "", "", "", "", "", "", "")
	_, err := linearAccountOAuthSource(c.cfg, c.database, c.ids["linear"])()
	require.ErrorIs(t, err, oauthclient.ErrClientRejected)
	marked, err := c.database.MarkAccountClientRejected("linear", c.ids["linear"])
	require.NoError(t, err)
	require.True(t, marked)
	l, err := c.database.GetLinearAccount(c.ids["linear"])
	require.NoError(t, err)
	assert.Equal(t, "error", l.Status)
	assert.Equal(t, oauthclient.CodeUnknownClient, l.Error)

	j, err := c.database.GetJiraAccount(c.ids["jira"])
	require.NoError(t, err)
	_, err = jiraAccountRowOAuthSource(c.ws, j)()
	require.ErrorIs(t, err, jira.ErrClientRejected)
	assert.Equal(t, jira.CodeUnknownClient, jira.ClientRejectedCode(j.CompanySlug))
}

// TestBridge_CorpBuildWithoutCompanyNameFails: build-app.sh and the Makefile
// refuse a flavored build other than dev without BUILD_COMPANY_NAME.
func TestBridge_CorpBuildWithoutCompanyNameFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash and make")
	}
	root, err := filepath.Abs("..")
	require.NoError(t, err)
	script, err := os.ReadFile(filepath.Join(root, "scripts", "build-app.sh"))
	require.NoError(t, err)
	_, block, ok := strings.Cut(string(script), "# BEGIN company-name")
	require.True(t, ok, "company-name block markers moved in build-app.sh?")
	block, _, ok = strings.Cut(block, "# END company-name")
	require.True(t, ok)
	runBlock := func(flavor, name string) (string, error) {
		cmd := exec.Command("bash", "-c", "set -euo pipefail\n#"+block)
		cmd.Env = append(os.Environ(), "FLAVOR="+flavor, "BUILD_COMPANY_NAME="+name)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	out, err := runBlock("corp", "")
	assert.Error(t, err)
	assert.Contains(t, out, "BUILD_COMPANY_NAME is required for the corp flavor")
	_, err = runBlock("corp", "Corp Inc")
	assert.NoError(t, err, "a name with a space is fine")
	_, err = runBlock("corp", `Corp's`)
	assert.Error(t, err, "a quote would break the ldflags")
	_, err = runBlock("", "")
	assert.NoError(t, err, "the public build needs no name")
	_, err = runBlock("dev", "")
	assert.NoError(t, err, "the dev build bridges nothing")

	if _, err := exec.LookPath("make"); err != nil {
		t.Skip("no make")
	}
	profile := filepath.Join(t.TempDir(), "profile")
	makeDry := func(content string) (string, error) {
		require.NoError(t, os.WriteFile(profile, []byte(content), 0o600))
		cmd := exec.Command("make", "-n", "-C", root, "build", "ENV_FILE="+profile)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	out, err = makeDry("BUILD_FLAVOR=corp\n")
	assert.Error(t, err)
	assert.Contains(t, out, "BUILD_COMPANY_NAME is required for the corp flavor")
	out, err = makeDry("BUILD_FLAVOR=corp\nBUILD_COMPANY_NAME=\"Corp Inc\"\n")
	require.NoError(t, err, out)
	assert.Contains(t, out, "-X 'watchtower/cmd.BuildCompanyName=Corp Inc'")
}

// TestBridge_PublicSlackOnRetiredIDStaysCompanyApp: the corp build's Slack app
// is the public build's retired shared app (one client id). After the bridge,
// the public build lists the tied corp account as the company's app — no
// shared-app banner, Re-login connects — while an untied row on the same id
// is still shared (ask #1644). The rows arrive as 0.28.4 left them, with no
// client id: the bridge fills it, else the tied row is never backfilled.
func TestBridge_PublicSlackOnRetiredIDStaysCompanyApp(t *testing.T) {
	c := newCorpWorkspace(t)
	other, err := c.database.CreateSlackAccount(db.SlackAccount{TeamID: "T0STR", TeamName: "Stranger"})
	require.NoError(t, err)
	// Both rows come from 0.28.4: no client id yet (migration 00196 added
	// the column); the bridge fills it before tying.
	_, err = c.bridge(t)
	require.NoError(t, err)

	setPublicBaked(t)
	setBakedClients(t, "", "", "", "", "", "", "", "")
	prevRetired := auth.RetiredSharedClientID
	auth.RetiredSharedClientID = corpSlackID
	t.Cleanup(func() { auth.RetiredSharedClientID = prevRetired })

	accounts, err := c.database.ListSlackAccounts()
	require.NoError(t, err)
	var out strings.Builder
	require.NoError(t, writeSlackAccountsJSON(&out, c.database, accounts))
	var doc slackAccountsDoc
	require.NoError(t, json.Unmarshal([]byte(out.String()), &doc))
	byID := map[int64]slackAccountJSONItem{}
	for _, a := range doc.Accounts {
		byID[a.ID] = a
	}
	corp := byID[c.ids["slack"]]
	assert.Equal(t, corpSlackID, corp.ClientID)
	assert.False(t, corp.SharedApp, "a tied corp account is the company's app")
	assert.Equal(t, "connect", corp.Relogin)
	stranger := byID[other]
	assert.True(t, stranger.SharedApp, "an untied row on the retired id is still shared")
	assert.Equal(t, corpSlackID, stranger.ClientID)
	assert.Equal(t, "move", stranger.Relogin)
}

// TestBridge_SlackOnOwnAppStaysUntied: a Slack row connected through a
// workspace's own app (its client_id, migration 00196) is not on the corp
// build's baked app, so the bridge neither ties it nor takes its team for
// the bundle; rows without a client id are the baked app's.
func TestBridge_SlackOnOwnAppStaysUntied(t *testing.T) {
	c := newCorpWorkspace(t)
	require.NoError(t, c.database.SetSlackAccountClientID(c.ids["slack"], "3000.0003"))
	_, err := c.bridge(t)
	require.NoError(t, err)

	own, err := c.database.GetSlackAccount(c.ids["slack"])
	require.NoError(t, err)
	assert.Empty(t, own.CompanySlug, "an own-app row is not the company's")
	assert.Equal(t, "3000.0003", own.ClientID, "its client id is kept")

	// The other row had no client id: backfilled with the baked app, it is
	// the oldest on that app, so its team is the bundle's and it is tied.
	other, err := c.database.GetSlackAccount(c.ids["slack_other_team"])
	require.NoError(t, err)
	assert.Equal(t, corpSlackID, other.ClientID)
	assert.Equal(t, corpSlug, other.CompanySlug)
	e, ok, err := company.NewStore(c.ws).Get(corpSlug, "")
	require.NoError(t, err)
	require.True(t, ok)
	require.NotNil(t, e.Bundle.Slack)
	assert.Equal(t, "T0OTHER", e.Bundle.Slack.TeamID, "the own-app row's team is not taken")
}

// TestBridge_WorkspaceFlagBridgesThatWorkspaceOnly: the app bridges every
// workspace with a database (`company bridge --workspace <name>`), so the run
// for an inactive one opens that workspace's database (migrating it), ties
// its accounts and writes its marker — and leaves config.yaml's
// active_workspace and the active workspace untouched.
func TestBridge_WorkspaceFlagBridgesThatWorkspaceOnly(t *testing.T) {
	active := newCorpWorkspace(t)
	prevFlavor, prevName, prevWS := BuildFlavor, BuildCompanyName, flagWorkspace
	t.Cleanup(func() { BuildFlavor, BuildCompanyName, flagWorkspace = prevFlavor, prevName, prevWS })
	BuildFlavor, BuildCompanyName = "corp", corpCompany

	otherDir := filepath.Join(filepath.Dir(active.ws), "other")
	other, err := db.Open(filepath.Join(otherDir, "watchtower.db"))
	require.NoError(t, err)
	googleID, err := other.CreateGoogleAccount(db.GoogleAccount{Email: "b@corp.example.com"})
	require.NoError(t, err)
	require.NoError(t, other.Close())
	configBefore, err := os.ReadFile(flagConfig)
	require.NoError(t, err)

	flagWorkspace = "other"
	cmd, out := cmdWithFlags(t, companyBridgeCmd, map[string]string{"json": "true"})
	require.NoError(t, companyBridgeCmd.RunE(cmd, nil))
	var res companyBridgeResult
	require.NoError(t, json.Unmarshal(out.Bytes(), &res))
	assert.Equal(t, bridgeMigrated, res.Result)
	assert.Contains(t, res.Tied, bridgeAccountJSON{Source: "google", ID: googleID})

	assert.FileExists(t, filepath.Join(otherDir, companyMigratedMarker))
	assert.NoFileExists(t, filepath.Join(active.ws, companyMigratedMarker), "the active workspace is not bridged")
	configAfter, err := os.ReadFile(flagConfig)
	require.NoError(t, err)
	assert.Equal(t, string(configBefore), string(configAfter), "active_workspace is not rewritten")
	assert.Empty(t, active.slugs(t), "no active-workspace account is tied")

	other, err = db.Open(filepath.Join(otherDir, "watchtower.db"))
	require.NoError(t, err)
	defer other.Close()
	refs, err := other.AccountsByCompany(corpSlug)
	require.NoError(t, err)
	assert.NotEmpty(t, refs, "the inactive workspace's accounts are tied in its own database")
}
