package db

import (
	"testing"
	"time"

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
	linear      []LinearAccount // Owner* fields recorded via SetLinearAccountOwner; Enabled false disables, Status "removed" removes
	mailboxes   []EmailAccount  // IMAP/Outlook accounts, created in order
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
	for _, l := range s.linear {
		id, err := d.CreateLinearAccount("")
		require.NoError(t, err)
		if !l.Enabled {
			require.NoError(t, d.SetLinearAccountEnabled(id, false))
		}
		if l.Status == "removed" {
			require.NoError(t, d.SetLinearAccountRemoved(id))
		}
		require.NoError(t, d.SetLinearAccountOwner(id, l.OwnerUserID, l.OwnerEmail, l.OwnerDisplayName))
	}
	for _, m := range s.mailboxes {
		_, err := d.CreateEmailAccount(m)
		require.NoError(t, err)
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
			slackUser: &User{ID: "1:U123", Name: "owner-a", DisplayName: "Owner A", Email: "owner-a@example.com"}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", Email: "owner-a@example.com", DisplayName: "Owner A"}},
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
			slackUser:   &User{ID: "1:U123", Name: "owner-a", DisplayName: "Owner A"},
			jiraUserMap: []JiraUserMap{{JiraAccountID: "acc-map", SlackUserID: "1:U123"}}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", JiraAccountID: "acc-map", DisplayName: "Owner A"}},
		{"google account without an email is skipped", ownerSeed{google: []GoogleAccount{{Email: ""}, {Email: "b@x.com"}}},
			Owner{ID: "google:b@x.com", Source: OwnerSourceGoogle, Email: "b@x.com", DisplayName: "b"}},
		{"slack user without display name falls back to real name", ownerSeed{
			slack:     []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			slackUser: &User{ID: "1:U123", Name: "owner-a", RealName: "Owner A Real"}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", DisplayName: "Owner A Real"}},
		{"bare-form jira_user_map row bridges a namespaced owner", ownerSeed{
			slack:       []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			jiraUserMap: []JiraUserMap{{JiraAccountID: "acc-bare", SlackUserID: "U123"}}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", JiraAccountID: "acc-bare"}},
		{"linear only", ownerSeed{linear: []LinearAccount{{Enabled: true, OwnerUserID: "user-1", OwnerEmail: "owner@example.com", OwnerDisplayName: "Owner"}}},
			Owner{ID: "linear:user-1", Source: OwnerSourceLinear, Email: "owner@example.com", DisplayName: "Owner", LinearUserIDs: []string{"user-1"}}},
		{"jira + linear: jira wins ID and enrichment, linear ids still filled", ownerSeed{
			jira:   []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}},
			linear: []LinearAccount{{Enabled: true, OwnerUserID: "user-1", OwnerEmail: "owner@example.com", OwnerDisplayName: "Owner"}}},
			Owner{ID: "jira:acc-9", Source: OwnerSourceJira, Email: "j@x.com", JiraAccountID: "acc-9", DisplayName: "J Doe", LinearUserIDs: []string{"user-1"}}},
		{"removed linear is skipped", ownerSeed{linear: []LinearAccount{{Enabled: true, Status: "removed", OwnerUserID: "user-1"}}}, Owner{}},
		{"disabled linear is skipped", ownerSeed{linear: []LinearAccount{{Enabled: false, OwnerUserID: "user-1"}}}, Owner{}},
		{"linear account without an owner id is skipped", ownerSeed{linear: []LinearAccount{{Enabled: true}, {Enabled: true, OwnerUserID: "user-2"}}},
			Owner{ID: "linear:user-2", Source: OwnerSourceLinear, LinearUserIDs: []string{"user-2"}}},
		{"two linear workspaces: first is the rung, both ids listed by account id", ownerSeed{linear: []LinearAccount{
			{Enabled: true, OwnerUserID: "user-1", OwnerEmail: "owner@example.com"}, {Enabled: true, OwnerUserID: "user-2"}}},
			Owner{ID: "linear:user-1", Source: OwnerSourceLinear, Email: "owner@example.com", DisplayName: "owner", LinearUserIDs: []string{"user-1", "user-2"}}},
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

// TestOwner01_EmailRung pins the fifth rung (ask #307): an IMAP/Outlook-only
// install resolves its owner from the first mailbox's address, and the rung
// sits below every other one, so no install that already had an owner sees
// its id change when a mailbox is connected.
func TestOwner01_EmailRung(t *testing.T) {
	imap := func(addr string) EmailAccount {
		return EmailAccount{Provider: "imap", EmailAddress: addr, Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX"}
	}
	cases := []struct {
		name string
		seed ownerSeed
		want Owner
	}{
		{"imap only, mixed-case address", ownerSeed{mailboxes: []EmailAccount{imap("Me@Example.com")}},
			Owner{ID: "email:me@example.com", Source: OwnerSourceEmail, Email: "Me@Example.com", DisplayName: "Me"}},
		{"outlook only", ownerSeed{mailboxes: []EmailAccount{{Provider: "outlook", EmailAddress: "me@example.com", Security: "ssl"}}},
			Owner{ID: "email:me@example.com", Source: OwnerSourceEmail, Email: "me@example.com", DisplayName: "me"}},
		{"mailbox without an address is skipped", ownerSeed{mailboxes: []EmailAccount{imap(""), imap("b@example.com")}},
			Owner{ID: "email:b@example.com", Source: OwnerSourceEmail, Email: "b@example.com", DisplayName: "b"}},
		{"two mailboxes: the first is the rung", ownerSeed{mailboxes: []EmailAccount{imap("a@example.com"), imap("b@example.com")}},
			Owner{ID: "email:a@example.com", Source: OwnerSourceEmail, Email: "a@example.com", DisplayName: "a"}},
		{"slack + mailbox: slack keeps the id and its email", ownerSeed{
			slack:     []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			slackUser: &User{ID: "1:U123", Name: "owner-a", DisplayName: "Owner A", Email: "owner-a@example.com"},
			mailboxes: []EmailAccount{imap("me@example.com")}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", Email: "owner-a@example.com", DisplayName: "Owner A"}},
		{"slack user without email: the mailbox fills Email", ownerSeed{
			slack:     []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
			slackUser: &User{ID: "1:U123", Name: "owner-a", DisplayName: "Owner A"},
			mailboxes: []EmailAccount{imap("me@example.com")}},
			Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123", Email: "me@example.com", DisplayName: "Owner A"}},
		{"google + mailbox: google wins", ownerSeed{google: []GoogleAccount{{Email: "g@x.com"}}, mailboxes: []EmailAccount{imap("me@example.com")}},
			Owner{ID: "google:g@x.com", Source: OwnerSourceGoogle, Email: "g@x.com", DisplayName: "g"}},
		{"jira + mailbox: jira wins ID and email", ownerSeed{
			jira:      []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}},
			mailboxes: []EmailAccount{imap("me@example.com")}},
			Owner{ID: "jira:acc-9", Source: OwnerSourceJira, Email: "j@x.com", JiraAccountID: "acc-9", DisplayName: "J Doe"}},
		{"linear + mailbox: linear wins, the mailbox fills Email", ownerSeed{
			linear:    []LinearAccount{{Enabled: true, OwnerUserID: "user-1", OwnerDisplayName: "Owner"}},
			mailboxes: []EmailAccount{imap("me@example.com")}},
			Owner{ID: "linear:user-1", Source: OwnerSourceLinear, Email: "me@example.com", DisplayName: "Owner", LinearUserIDs: []string{"user-1"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := openTestDB(t)
			seedOwner(t, d, tc.seed)
			got, err := d.ResolveOwner()
			require.NoError(t, err)
			assert.Equal(t, tc.want, got)
			assert.True(t, got.Known())
		})
	}
}

// TestOwner01_EmailRungIgnoresBareLogins: a mailbox whose "address" is a bare
// IMAP login identifies no one, so it is neither the rung nor the Email
// fallback.
func TestOwner01_EmailRungIgnoresBareLogins(t *testing.T) {
	d := openTestDB(t)
	for _, login := range []string{"jdoe", `DOMAIN\jdoe`, "@example.com"} {
		_, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: login, Security: "ssl"})
		require.NoError(t, err)
	}
	got, err := d.ResolveOwner()
	require.NoError(t, err)
	assert.Equal(t, Owner{}, got)

	seedOwner(t, d, ownerSeed{linear: []LinearAccount{{Enabled: true, OwnerUserID: "user-1"}}})
	got, err = d.ResolveOwner()
	require.NoError(t, err)
	assert.Equal(t, Owner{ID: "linear:user-1", Source: OwnerSourceLinear, LinearUserIDs: []string{"user-1"}}, got,
		"a bare login never fills Email")
}

// TestOwner01_EmailRungOrdersByID: the rung is the lowest id, not the first
// row inserted or the first address alphabetically.
func TestOwner01_EmailRungOrdersByID(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO email_accounts (id, provider, email_address) VALUES (2, 'imap', 'a@example.com')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'b@example.com')`)
	require.NoError(t, err)
	got, err := d.ResolveOwner()
	require.NoError(t, err)
	assert.Equal(t, "email:b@example.com", got.ID)
}

// TestOwner01_CalDAVOnlyHasNoOwner: a calendar account's username is not an
// identity, so a CalDAV-only install still has no owner.
func TestOwner01_CalDAVOnlyHasNoOwner(t *testing.T) {
	d := openTestDB(t)
	_, err := d.CreateCalendarAccount(CalendarAccount{Provider: "caldav", Username: "me@example.com", URL: "https://dav.example.com"})
	require.NoError(t, err)
	got, err := d.ResolveOwner()
	require.NoError(t, err)
	assert.False(t, got.Known())
	_, err = d.RequireOwner()
	require.ErrorIs(t, err, ErrNoOwner)
}

// TestOwner01_RungSwitchAdoptsBriefingAndDayPlan: a briefing and a day plan
// written under the email rung are found under the new id once the owner
// moves to Jira, so neither is generated a second time.
func TestOwner01_RungSwitchAdoptsBriefingAndDayPlan(t *testing.T) {
	d := openTestDB(t)
	const day = "2026-10-17"
	_, err := d.UpsertBriefing(Briefing{UserID: "email:x@example.com", Date: day, Role: "EM"})
	require.NoError(t, err)
	_, err = d.CreateDayPlan(&DayPlan{UserID: "email:x@example.com", PlanDate: day, Status: "active", GeneratedAt: time.Date(2026, 10, 17, 8, 0, 0, 0, time.UTC)})
	require.NoError(t, err)

	require.NoError(t, d.AdoptOwnerRows("jira:acc-9"))

	b, err := d.GetBriefing("jira:acc-9", day)
	require.NoError(t, err)
	require.NotNil(t, b)
	assert.Equal(t, "EM", b.Role)
	p, err := d.GetDayPlan("jira:acc-9", day)
	require.NoError(t, err)
	require.NotNil(t, p)
	var n int
	require.NoError(t, d.QueryRow(`SELECT (SELECT COUNT(*) FROM briefings) + (SELECT COUNT(*) FROM day_plans)`).Scan(&n))
	assert.Equal(t, 2, n, "moved, not copied")
}

// TestOwner01_AdoptKeepsTheOwnersOwnRow: a date the current owner already has
// keeps the owner's row; the older one is left alone, never merged over it.
func TestOwner01_AdoptKeepsTheOwnersOwnRow(t *testing.T) {
	d := openTestDB(t)
	const day = "2026-10-17"
	_, err := d.UpsertBriefing(Briefing{UserID: "email:x@example.com", Date: day, Role: "Old"})
	require.NoError(t, err)
	_, err = d.UpsertBriefing(Briefing{UserID: "jira:acc-9", Date: day, Role: "Mine"})
	require.NoError(t, err)
	require.NoError(t, d.AdoptOwnerRows("jira:acc-9"))
	b, err := d.GetBriefing("jira:acc-9", day)
	require.NoError(t, err)
	require.NotNil(t, b)
	assert.Equal(t, "Mine", b.Role)
	require.NoError(t, d.AdoptOwnerRows(""), "no owner adopts nothing")
}

// TestOwner01_ProfileWriteAdoptsBriefings: the profile re-key also moves the
// briefings written under the earlier id (Swift twin:
// testOwner01ProfileWriteAdoptsBriefingsAndDayPlans).
func TestOwner01_ProfileWriteAdoptsBriefings(t *testing.T) {
	d := openTestDB(t)
	_, err := d.UpsertBriefing(Briefing{UserID: "email:x@example.com", Date: "2026-10-16", Role: "Old"})
	require.NoError(t, err)
	require.NoError(t, d.UpsertOwnerProfile(Owner{ID: "jira:acc-9", Source: OwnerSourceJira}, UserProfile{Role: "EM"}))
	b, err := d.GetBriefing("jira:acc-9", "2026-10-16")
	require.NoError(t, err)
	require.NotNil(t, b)
	assert.Equal(t, "Old", b.Role)
}

func TestOwner01_SlackInstallIDUnchanged(t *testing.T) {
	// An existing Slack install that ALSO has Google + Jira connected keeps
	// its Slack id as the owner id — the one guarantee for every live install.
	d := openTestDB(t)
	seedOwner(t, d, ownerSeed{
		slack:     []SlackAccount{{TeamID: "T1", CurrentUserID: "1:U123"}},
		slackUser: &User{ID: "1:U123", Name: "owner-a", DisplayName: "Owner A", Email: "owner-a@example.com"},
		google:    []GoogleAccount{{Email: "me@x.com"}},
		jira:      []JiraAccount{{CloudID: "c1", Enabled: true, OwnerAccountID: "acc-9", OwnerEmail: "j@x.com", OwnerDisplayName: "J Doe"}},
		linear:    []LinearAccount{{Enabled: true, OwnerUserID: "user-1", OwnerEmail: "owner@example.com", OwnerDisplayName: "Owner"}},
	})
	got, err := d.ResolveOwner()
	require.NoError(t, err)
	assert.Equal(t, Owner{ID: "1:U123", Source: OwnerSourceSlack, SlackUserID: "1:U123",
		Email: "owner-a@example.com", JiraAccountID: "acc-9", DisplayName: "Owner A", LinearUserIDs: []string{"user-1"}}, got)
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
