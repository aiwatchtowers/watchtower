package company

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/calendar"
	"watchtower/internal/companybundle"
	"watchtower/internal/db"
)

func writeClientFile(t *testing.T, dir, name string, v any) {
	t.Helper()
	raw, err := json.Marshal(v)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, name), raw, 0o600))
}

// setSharedGoogle stands in for a build that bakes our shared Google client.
func setSharedGoogle(t *testing.T, id string) {
	t.Helper()
	prev := calendar.DefaultGoogleClientID
	calendar.DefaultGoogleClientID = id
	t.Cleanup(func() { calendar.DefaultGoogleClientID = prev })
}

func TestDiscover_EverySource(t *testing.T) {
	ws := t.TempDir()
	setSharedGoogle(t, "shared-google.apps.googleusercontent.com")
	s := NewStore(ws)
	require.NoError(t, s.Save("acme", companybundle.Bundle{V: 1, Company: "Acme",
		Slack:  &companybundle.Slack{TeamID: "T0000", ClientID: "000.000"},
		Linear: &companybundle.Linear{ClientID: "acmelinear01"},
	}))
	require.NoError(t, s.SaveDraft(Draft{Company: "Acme", Services: []string{"slack", "atlassian"}, Step: "atlassian",
		Slack:     DraftSlack{AppID: "A0ACME"},
		Atlassian: &companybundle.Atlassian{ClientID: "draftClientId01", ClientSecret: "typed"},
	}))
	d := db.OpenTestDB(t)
	// A Google account with its own credentials file.
	g1, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "own@example.com", ClientID: "own-1.apps.googleusercontent.com"})
	require.NoError(t, err)
	writeClientFile(t, ws, "google_credentials_"+itoa(g1)+".json", map[string]string{"client_id": "own-1.apps.googleusercontent.com", "client_secret": "s"})
	// A bridged corp account: tied to a company, on the corp's client.
	_, err = d.CreateGoogleAccount(db.GoogleAccount{Email: "corp@example.com", Label: "corp", ClientID: "corp-1.apps.googleusercontent.com", CompanySlug: "corp"})
	require.NoError(t, err)
	// A Microsoft account with its own client file (oauthclient form).
	o1, err := d.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "m@example.com", Security: "ssl"})
	require.NoError(t, err)
	writeClientFile(t, ws, "outlook_client_"+itoa(o1)+".json", map[string]string{"client_id": "00000000-0000-0000-0000-000000000001", "tenant_id": "00000000-0000-0000-0000-0000000000aa"})
	// A Jira account whose client file is damaged: skipped.
	j1, err := d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net"})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(ws, "jira_client_"+itoa(j1)+".json"), []byte("{"), 0o600))

	got, err := Discover(context.Background(), ws, d, "")
	require.NoError(t, err)
	assert.Equal(t, []Candidate{
		{Vendor: "slack", ClientID: "000.000", Label: "Acme", Source: SourceStored, SourceLabel: "Acme's saved company setup"},
		{Vendor: "slack", AppID: "A0ACME", Label: "Acme", Source: SourceDraft, SourceLabel: "Acme's saved company setup"},
		{Vendor: "google", ClientID: "own-1.apps.googleusercontent.com", Label: "own@example.com", Source: SourceCredentialsFile,
			SourceLabel: "the credentials file of own@example.com", HasSecret: true},
		{Vendor: "google", ClientID: "corp-1.apps.googleusercontent.com", Label: "corp", Source: SourceAccount,
			SourceLabel: "Google app — your connected account corp"},
		{Vendor: "atlassian", ClientID: "draftClientId01", Label: "Acme", Source: SourceDraft, SourceLabel: "Acme's saved company setup", HasSecret: true},
		{Vendor: "linear", ClientID: "acmelinear01", Label: "Acme", Source: SourceStored, SourceLabel: "Acme's saved company setup"},
		{Vendor: "microsoft", ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa",
			Label: "m@example.com", Source: SourceCredentialsFile, SourceLabel: "the credentials file of m@example.com"},
	}, got)

	// The forced MDM bundle is a source too; a personal project is not.
	forced, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Gamma", Linear: &companybundle.Linear{ClientID: "gammalinear1"}})
	require.NoError(t, err)
	require.NoError(t, s.Save("me", companybundle.Bundle{V: 1, Company: "Me", Personal: true,
		Google: &companybundle.Google{ClientID: "5678-efgh.apps.googleusercontent.com", ClientSecret: "p"}}))
	got, err = Discover(context.Background(), ws, d, forced)
	require.NoError(t, err)
	var linearIDs, googleIDs []string
	for _, c := range got {
		switch c.Vendor {
		case "linear":
			linearIDs = append(linearIDs, c.ClientID)
		case "google":
			googleIDs = append(googleIDs, c.ClientID)
		}
	}
	assert.Equal(t, []string{"acmelinear01", "gammalinear1"}, linearIDs)
	assert.NotContains(t, googleIDs, "5678-efgh.apps.googleusercontent.com")
}

func TestDiscover_SharedBakedIDNeverCandidate(t *testing.T) {
	ws := t.TempDir()
	setSharedGoogle(t, "shared-google.apps.googleusercontent.com")
	d := db.OpenTestDB(t)
	g, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", ClientID: "shared-google.apps.googleusercontent.com"})
	require.NoError(t, err)
	writeClientFile(t, ws, "google_credentials_"+itoa(g)+".json", map[string]string{"client_id": "shared-google.apps.googleusercontent.com", "client_secret": "s"})
	_, err = d.CreateGoogleAccount(db.GoogleAccount{Email: "b@example.com"}) // '' = the build default
	require.NoError(t, err)
	// A removed account's client is gone with it.
	gone, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "c@example.com", ClientID: "gone.apps.googleusercontent.com"})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE google_accounts SET status = 'purged' WHERE id = ?`, gone)
	require.NoError(t, err)

	got, err := Discover(context.Background(), ws, d, "")
	require.NoError(t, err)
	assert.Empty(t, got)
}

// TestDiscover_DuplicateKeepsFirstSource: one client found in the stored
// bundle and an account's credentials file is listed once, from the stored
// bundle, holding the file's secret.
func TestDiscover_DuplicateKeepsFirstSource(t *testing.T) {
	ws := t.TempDir()
	setSharedGoogle(t, "")
	s := NewStore(ws)
	require.NoError(t, s.Save("acme", companybundle.Bundle{V: 1, Company: "Acme",
		Microsoft: &companybundle.Microsoft{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"}}))
	d := db.OpenTestDB(t)
	o, err := d.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "m@example.com", Security: "ssl", CompanySlug: "acme"})
	require.NoError(t, err)
	writeClientFile(t, ws, "outlook_client_"+itoa(o)+".json", map[string]string{"client_id": "00000000-0000-0000-0000-000000000001", "client_secret": "s"})

	got, err := Discover(context.Background(), ws, d, "")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, SourceStored, got[0].Source)
	assert.True(t, got[0].HasSecret)
}

// TestDiscover_PersonalProjectNeverCandidate: a Google account on the
// person's own project (its credentials file and its row's client id) is
// never offered as a company's client.
func TestDiscover_PersonalProjectNeverCandidate(t *testing.T) {
	ws := t.TempDir()
	setSharedGoogle(t, "")
	const own = "5678-efgh.apps.googleusercontent.com"
	require.NoError(t, NewStore(ws).Save("me", companybundle.Bundle{V: 1, Company: "Me", Personal: true,
		Google: &companybundle.Google{ClientID: own, ClientSecret: "p"}}))
	d := db.OpenTestDB(t)
	g, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "me@example.com", ClientID: own, CompanySlug: "me"})
	require.NoError(t, err)
	writeClientFile(t, ws, "google_credentials_"+itoa(g)+".json", map[string]string{"client_id": own, "client_secret": "p"})

	got, err := Discover(context.Background(), ws, d, "")
	require.NoError(t, err)
	assert.Empty(t, got)
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
