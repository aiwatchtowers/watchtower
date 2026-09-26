package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ownerSeed describes the identity rows one ResolveOwner case starts from.
type ownerSeed struct {
	slack       []SlackAccount // created in order as slack_accounts id 1, 2, …
	slackUser   *User          // users row for account #1's CurrentUserID
	google      []GoogleAccount
	jira        []JiraAccount // Owner* fields recorded via SetJiraAccountOwner
	jiraUserMap []JiraUserMap
}

// seedOwner creates every row of s through the production writers, so the
// resolver reads exactly what a real connect leaves behind.
func seedOwner(t *testing.T, d *DB, s ownerSeed) {
	t.Helper()
	for i, a := range s.slack {
		id, err := d.CreateSlackAccount(a)
		require.NoError(t, err)
		require.Equal(t, int64(i+1), id, "slack accounts are seeded as ids 1, 2, …")
		if a.Status == "removed" {
			require.NoError(t, d.SetSlackAccountRemoved(id))
		}
	}
	if s.slackUser != nil {
		require.NoError(t, d.UpsertUser(*s.slackUser))
	}
	for _, g := range s.google {
		_, err := d.CreateGoogleAccount(g)
		require.NoError(t, err)
	}
	for _, j := range s.jira {
		id, err := d.CreateJiraAccount(j)
		require.NoError(t, err)
		if !j.Enabled {
			require.NoError(t, d.SetJiraAccountEnabled(id, false))
		}
		require.NoError(t, d.SetJiraAccountOwner(id, j.OwnerAccountID, j.OwnerEmail, j.OwnerDisplayName))
	}
	for _, m := range s.jiraUserMap {
		require.NoError(t, d.UpsertJiraUserMap(m))
	}
}

func TestOwner01_ResolveOwnerLadder(t *testing.T) {
	cases := []struct {
		name string
		seed ownerSeed
		want Owner
	}{
		{"none", ownerSeed{}, Owner{}},
		{"slack only", ownerSeed{slack: []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			slackUser: &User{ID: "1:U123", Name: "vadym", DisplayName: "Vadym", Email: "v@slack.io"}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", Email: "v@slack.io", DisplayName: "Vadym"}},
		{"google only, mixed-case email", ownerSeed{google: []GoogleAccount{{Email: "Me@X.com"}}},
			Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "Me@X.com", DisplayName: "Me"}},
		{"jira only", ownerSeed{jira: []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}}},
			Owner{ID: "jira:acc-9", Source: OwnerSourceJira, Email: "j@x.com", JiraAccountID: "acc-9", DisplayName: "J Doe"}},
		{"google + jira: google wins ID, jira enriches", ownerSeed{
			google: []GoogleAccount{{Email: "me@x.com"}},
			jira:   []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}}},
			Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", JiraAccountID: "acc-9", DisplayName: "J Doe"}},
		{"slack without current_user_id falls through to google", ownerSeed{slack: []SlackAccount{{TeamID: "T1"}}, google: []GoogleAccount{{Email: "me@x.com"}}},
			Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", DisplayName: "me"}},
		{"removed slack is skipped", ownerSeed{slack: []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123", Status: "removed"}}, google: []GoogleAccount{{Email: "me@x.com"}}},
			Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", DisplayName: "me"}},
		{"slack #2 does not widen: account #1 stays the owner", ownerSeed{
			slack: []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U1"}, {TeamID: "T2", CurrentUserID: "2:U2"}}},
			Owner{ID: "1:U1", Source: OwnerSourceSlack, SlackUserID: "1:U1"}},
		{"removed #1 + active #2 falls to google, never #2", ownerSeed{
			slack:  []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U1", Status: "removed"}, {TeamID: "T2", CurrentUserID: "2:U2"}},
			google: []GoogleAccount{{Email: "me@x.com"}}},
			Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle, Email: "me@x.com", DisplayName: "me"}},
		{"disabled jira is skipped", ownerSeed{jira: []JiraAccount{{CloudID: "c1", Enabled: false, OwnerAccountID: "acc-9"}}}, Owner{}},
		{"slack + jira_user_map bridge fills JiraAccountID", ownerSeed{
			slack:       []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			slackUser:   &User{ID: "1:U123", Name: "vadym", DisplayName: "Vadym"},
			jiraUserMap: []JiraUserMap{{JiraAccountID: "acc-map", SlackUserID: "1:U123"}}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", JiraAccountID: "acc-map", DisplayName: "Vadym"}},
		{"google account without an email is skipped", ownerSeed{google: []GoogleAccount{{Email: ""}, {Email: "b@x.com"}}},
			Owner{ID: "google:b@x.com", Source: OwnerSourceGoogle, Email: "b@x.com", DisplayName: "b"}},
		{"slack user without display name falls back to real name", ownerSeed{
			slack:     []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			slackUser: &User{ID: "1:U123", Name: "vadym", RealName: "Vadym Real"}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", DisplayName: "Vadym Real"}},
		{"bare-form jira_user_map row bridges a namespaced owner", ownerSeed{
			slack:       []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			jiraUserMap: []JiraUserMap{{JiraAccountID: "acc-bare", SlackUserID: "U123"}}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", JiraAccountID: "acc-bare"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := openTestDB(t)
			seedOwner(t, d, tc.seed)
			got, err := d.ResolveOwner()
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
			assert.Equal(t, tc.want.ID != "", got.Known())
		})
	}
}

func TestOwner01_SlackInstallIDUnchanged(t *testing.T) {
	// An existing Slack install that ALSO has Google + Jira connected keeps
	// its Slack id as the owner id — the one guarantee for every live install.
	d := openTestDB(t)
	seedOwner(t, d, ownerSeed{
		slack:     []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
		slackUser: &User{ID: "1:U123", Name: "vadym", DisplayName: "Vadym", Email: "v@slack.io"},
		google:    []GoogleAccount{{Email: "me@x.com"}},
		jira:      []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}},
	})
	got, err := d.ResolveOwner()
	require.NoError(t, err)
	assert.Equal(t, Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123",
		Email: "v@slack.io", JiraAccountID: "acc-9", DisplayName: "Vadym"}, got)
}

func TestOwner01_ProfileSurvivesRungSwitch(t *testing.T) {
	d := openTestDB(t)
	g := Owner{ID: "google:me@x.com", Source: OwnerSourceGoogle}
	require.NoError(t, d.UpsertOwnerProfile(g, UserProfile{Role: "EM", Team: "Core"}))
	s := Owner{ID: "1:U123", Source: OwnerSourceSlack}
	p, err := d.GetOwnerProfile(s) // no row keyed 1:U123 yet → falls back to the only row
	require.NoError(t, err)
	require.NotNil(t, p)
	assert.Equal(t, "EM", p.Role)
	require.NoError(t, d.UpsertOwnerProfile(s, UserProfile{Role: "Director", Team: "Core"}))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM user_profile`).Scan(&n))
	assert.Equal(t, 1, n, "the rung switch re-keys the one row, never adds a second")
	p, err = d.GetOwnerProfile(s)
	require.NoError(t, err)
	require.NotNil(t, p)
	assert.Equal(t, "1:U123", p.SlackUserID)
	assert.Equal(t, "Director", p.Role)
}

func TestOwner01_OwnerKeyedProfileBeatsStaleRow(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertUserProfile(UserProfile{SlackUserID: "1:U123", Role: "Mine"}))
	require.NoError(t, d.UpsertUserProfile(UserProfile{SlackUserID: "legacy:x", Role: "Stale"})) // newer updated_at
	p, err := d.GetOwnerProfile(Owner{ID: "1:U123"})
	require.NoError(t, err)
	require.NotNil(t, p)
	assert.Equal(t, "Mine", p.Role, "an exact-key row always wins over the most-recent fallback")
}

func TestOwner01_UnknownOwnerProfileIsNil(t *testing.T) {
	d := openTestDB(t)
	p, err := d.GetOwnerProfile(Owner{})
	require.NoError(t, err)
	assert.Nil(t, p)
}

func TestOwner01_UnknownOwnerUpsertIsErrNoOwner(t *testing.T) {
	d := openTestDB(t)
	err := d.UpsertOwnerProfile(Owner{}, UserProfile{Role: "EM"})
	require.ErrorIs(t, err, ErrNoOwner)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM user_profile`).Scan(&n))
	assert.Equal(t, 0, n)
}

func TestOwner02_RequireOwnerUnknownIsErrNoOwner(t *testing.T) {
	d := openTestDB(t)
	_, err := d.RequireOwner()
	require.ErrorIs(t, err, ErrNoOwner)

	seedOwner(t, d, ownerSeed{google: []GoogleAccount{{Email: "Me@X.com"}}})
	o, err := d.RequireOwner()
	require.NoError(t, err)
	assert.Equal(t, "google:me@x.com", o.ID)
}
